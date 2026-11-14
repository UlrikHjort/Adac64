with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;

with MOS6502;
with VIC_II;
with CIA;
with SID;
with VDC;
with Keyboard;
with Media;
with CRT;
use type CRT.Cart_Type;
with Drive1541;
use type Media.Media_Kind;
with IEC;
with Ada.Directories;
with Ada.Command_Line;

package body Machine is

   ---------------------------------------------------------------------
   --  Flat memory: RAM banks followed by all ROM images
   ---------------------------------------------------------------------

   RAM_Size         : constant := 16#20000#;          --  2 x 64K
   ROM_C64_Basic    : constant := 16#20000#;          --  8K
   ROM_C64_Kernal   : constant := 16#22000#;          --  8K
   ROM_C64_Char     : constant := 16#24000#;          --  4K
   ROM_C128_Kernal  : constant := 16#25000#;          --  16K
   ROM_C128_BasicLo : constant := 16#29000#;          --  16K
   ROM_C128_BasicHi : constant := 16#2D000#;          --  16K
   ROM_C128_Char    : constant := 16#31000#;          --  4K (C128 half)
   ROM_Empty        : constant := 16#32000#;          --  256 bytes of $FF
   Write_Sink       : constant := 16#32100#;          --  discarded writes
   Cart_Base        : constant := 16#32200#;          --  cartridge banks
   Mem_Size         : constant := Cart_Base + CRT.Max_Banks * CRT.Bank_Size;

   Mem : Byte_Array (0 .. Mem_Size - 1) := (others => 16#FF#);
   Color_RAM : Byte_Array (0 .. 2047) := (others => 0);

   IO_Page : constant Integer := -1;

   type Page_Map is array (Byte) of Integer;
   Read_Map  : Page_Map := (others => 0);
   Write_Map : Page_Map := (others => 0);

   Current_Model : Model_Type := C64;
   C64_Mode      : Boolean := True;    --  memory map is C64 style
   Err : Unbounded_String;

   --  CPU port ($00/$01)
   Port_DDR  : Byte := 0;
   Port_Data : Byte := 0;

   --  C128 MMU
   MMU_CR  : Byte := 0;
   MMU_PCR : array (1 .. 4) of Byte := (others => 0);
   MMU_MCR : Byte := 0;
   MMU_RCR : Byte := 0;
   MMU_P0L, MMU_P0H : Byte := 0;
   MMU_P1L : Byte := 1;
   MMU_P1H : Byte := 0;
   P0H_Latch, P1H_Latch : Byte := 0;

   --  Derived state
   VIC_Bank_Base   : Natural := 0;
   VIC_RAM_Base    : Natural := 0;
   VIC_Char_ROM    : Boolean := True;
   VIC_Char_Base   : Natural := ROM_C64_Char;
   CPU_Color_Bank  : Natural := 0;
   VIC_Color_Bank  : Natural := 0;
   Kernal_High     : Boolean := True;   --  KERNAL ROM visible at $FFxx

   CIA1, CIA2 : CIA.Chip;

   --  Cartridge port
   Cart_Present : Boolean := False;
   Cart_Info    : CRT.Image;
   Cart_Bank    : Natural := 0;
   Cart_Exrom   : Boolean := False;     --  True = line asserted (low)
   Cart_Game    : Boolean := False;
   Cart_RAM     : Byte_Array (0 .. 255) := (others => 0);   --  EasyFlash

   function Ultimax return Boolean is
     (Cart_Present and then Cart_Game and then not Cart_Exrom);
   function ROML_Offset return Natural is
     (Cart_Base + (Cart_Bank mod CRT.Max_Banks) * CRT.Bank_Size);
   function ROMH_Offset return Natural is
     (if Cart_Info.Has_ROMH (Cart_Bank mod CRT.Max_Banks)
      then ROML_Offset + 16#2000#
      else ROML_Offset);       --  e.g. Ocean: ROMH mirrors the bank
   NMI_Prev : Boolean := False;
   Half_Cycle : Natural := 0;
   Frames : Natural := 0;
   Total_Cycles : Long_Long_Integer := 0;   --  1 MHz device time
   Drive_On : Boolean := False;             --  true drive participating
   TOD_Div : Natural := 0;

   --  Typing / autostart
   Type_Queue : Unbounded_String;
   type Auto_State is (Idle, Wait_Ready, Wait_Load);
   Auto : Auto_State := Idle;
   Auto_Command : Unbounded_String;
   Auto_Frames : Natural := 0;

   ---------------------------------------------------------------------
   --  Forward declarations
   ---------------------------------------------------------------------

   function Bus_Read (Addr : Word) return Byte;
   procedure Update_Drive_State;
   procedure Bus_Write (Addr : Word; Value : Byte);
   function VIC_Mem (Addr : Word) return Byte;
   function VIC_Color (Index : Natural) return Byte;

   package CPU is new MOS6502 (Read => Bus_Read, Write => Bus_Write);
   package VIC is new VIC_II (Mem_Read => VIC_Mem, Color_Read => VIC_Color);

   function VIA_Fast return Boolean is (VIC.Fast_Mode and then not C64_Mode);

   ---------------------------------------------------------------------
   --  Memory map construction
   ---------------------------------------------------------------------

   procedure Update_VIC_Bank is
      PA : constant Byte := CIA.Port_A_Out (CIA2);
   begin
      VIC_Bank_Base := Natural (3 - (PA and 3)) * 16#4000#;
   end Update_VIC_Bank;

   procedure Map_C64 is
      Lines  : constant Byte := Port_Data or not Port_DDR;
      LORAM  : constant Boolean := (Lines and 1) /= 0;
      HIRAM  : constant Boolean := (Lines and 2) /= 0;
      CHAREN : constant Boolean := (Lines and 4) /= 0;
      Exrom  : constant Boolean := Cart_Present and then Cart_Exrom;
      Game   : constant Boolean := Cart_Present and then Cart_Game;
   begin
      for P in Byte loop
         Read_Map (P) := Natural (P) * 256;
         Write_Map (P) := Natural (P) * 256;
      end loop;
      VIC_RAM_Base := 0;
      VIC_Char_ROM := True;
      VIC_Char_Base := ROM_C64_Char;
      CPU_Color_Bank := 0;
      VIC_Color_Bank := 0;

      if Game and then not Exrom then
         --  Ultimax: 4K RAM, cartridge ROML/ROMH, I/O, nothing else
         for P in Byte range 16#10# .. 16#FF# loop
            Read_Map (P) := ROM_Empty;
            Write_Map (P) := Write_Sink;
         end loop;
         for P in Byte range 16#80# .. 16#9F# loop
            Read_Map (P) := ROML_Offset + Natural (P - 16#80#) * 256;
         end loop;
         for P in Byte range 16#D0# .. 16#DF# loop
            Read_Map (P) := IO_Page;
            Write_Map (P) := IO_Page;
         end loop;
         for P in Byte range 16#E0# .. 16#FF# loop
            Read_Map (P) := ROMH_Offset + Natural (P - 16#E0#) * 256;
         end loop;
         Kernal_High := False;
         VIC_Char_ROM := False;
         return;
      end if;

      if Exrom and then LORAM and then HIRAM then
         for P in Byte range 16#80# .. 16#9F# loop
            Read_Map (P) := ROML_Offset + Natural (P - 16#80#) * 256;
         end loop;
      end if;
      if Exrom and then Game and then HIRAM then
         for P in Byte range 16#A0# .. 16#BF# loop
            Read_Map (P) := ROMH_Offset + Natural (P - 16#A0#) * 256;
         end loop;
      elsif LORAM and then HIRAM then
         for P in Byte range 16#A0# .. 16#BF# loop
            Read_Map (P) := ROM_C64_Basic + Natural (P - 16#A0#) * 256;
         end loop;
      end if;
      if HIRAM then
         for P in Byte range 16#E0# .. 16#FF# loop
            Read_Map (P) := ROM_C64_Kernal + Natural (P - 16#E0#) * 256;
         end loop;
      end if;
      if LORAM or else HIRAM then
         for P in Byte range 16#D0# .. 16#DF# loop
            if CHAREN then
               Read_Map (P) := IO_Page;
               Write_Map (P) := IO_Page;
            else
               Read_Map (P) := ROM_C64_Char + Natural (P - 16#D0#) * 256;
            end if;
         end loop;
      end if;
      Kernal_High := HIRAM;
   end Map_C64;

   procedure Map_C128 is
      Bank : constant Natural := Natural (Shift_Right (MMU_CR, 6) and 1);
      Common_Size : constant Natural :=
        (case MMU_RCR and 3 is
           when 0 => 16#400#, when 1 => 16#1000#,
           when 2 => 16#2000#, when others => 16#4000#);
      Share_Bottom : constant Boolean := (MMU_RCR and 4) /= 0;
      Share_Top    : constant Boolean := (MMU_RCR and 8) /= 0;
      Lines : constant Byte := Port_Data or not Port_DDR;
   begin
      for P in Byte loop
         declare
            Addr : constant Natural := Natural (P) * 256;
            RB : Natural := Bank;
            RAM_Off : Natural;
         begin
            if Share_Bottom and then Addr < Common_Size then
               RB := 0;
            elsif Share_Top and then Addr >= 16#10000# - Common_Size then
               RB := 0;
            end if;
            RAM_Off := RB * 16#10000# + Addr;
            Read_Map (P) := RAM_Off;
            Write_Map (P) := RAM_Off;

            case Addr is
               when 16#4000# .. 16#7FFF# =>
                  if (MMU_CR and 2) = 0 then
                     Read_Map (P) := ROM_C128_BasicLo + (Addr - 16#4000#);
                  end if;
               when 16#8000# .. 16#BFFF# =>
                  case Shift_Right (MMU_CR, 2) and 3 is
                     when 0 =>
                        Read_Map (P) := ROM_C128_BasicHi + (Addr - 16#8000#);
                     when 1 | 2 =>
                        Read_Map (P) := ROM_Empty;
                     when others => null;
                  end case;
               when 16#C000# .. 16#FFFF# =>
                  if Addr in 16#D000# .. 16#DFFF# and then (MMU_CR and 1) = 0
                  then
                     Read_Map (P) := IO_Page;
                     Write_Map (P) := IO_Page;
                  else
                     case Shift_Right (MMU_CR, 4) and 3 is
                        when 0 =>
                           if Addr in 16#D000# .. 16#DFFF# then
                              Read_Map (P) := ROM_C128_Char +
                                (Addr - 16#D000#);
                           else
                              Read_Map (P) := ROM_C128_Kernal +
                                (Addr - 16#C000#);
                           end if;
                        when 1 | 2 =>
                           Read_Map (P) := ROM_Empty;
                        when others => null;
                     end case;
                  end if;
               when others => null;
            end case;
         end;
      end loop;

      --  Zero page and stack relocation
      if MMU_P0L /= 0 or else (MMU_P0H and 1) /= 0 then
         declare
            Phys : constant Natural :=
              Natural (MMU_P0H and 1) * 16#10000# + Natural (MMU_P0L) * 256;
         begin
            Read_Map (MMU_P0L) := Read_Map (0);
            Write_Map (MMU_P0L) := Write_Map (0);
            Read_Map (0) := Phys;
            Write_Map (0) := Phys;
         end;
      end if;
      if MMU_P1L /= 1 or else (MMU_P1H and 1) /= 0 then
         declare
            Phys : constant Natural :=
              Natural (MMU_P1H and 1) * 16#10000# + Natural (MMU_P1L) * 256;
         begin
            Read_Map (MMU_P1L) := Read_Map (1);
            Write_Map (MMU_P1L) := Write_Map (1);
            Read_Map (1) := Phys;
            Write_Map (1) := Phys;
         end;
      end if;

      Kernal_High := (Shift_Right (MMU_CR, 4) and 3) = 0;
      VIC_RAM_Base := Natural (Shift_Right (MMU_RCR, 6) and 1) * 16#10000#;
      VIC_Char_ROM := (Lines and 4) = 0;
      VIC_Char_Base := ROM_C128_Char;
      CPU_Color_Bank := Natural (Lines and 1);
      VIC_Color_Bank := Natural (Shift_Right (Lines, 1) and 1);
   end Map_C128;

   procedure Rebuild_Map is
   begin
      if C64_Mode then
         Map_C64;
      else
         Map_C128;
      end if;
   end Rebuild_Map;

   ---------------------------------------------------------------------
   --  VIC memory access
   ---------------------------------------------------------------------

   function VIC_Mem (Addr : Word) return Byte is
      A16 : constant Natural := VIC_Bank_Base + Natural (Addr and 16#3FFF#);
   begin
      --  In Ultimax mode the VIC sees ROMH in the top 4K of each bank
      if Ultimax and then (Addr and 16#3000#) = 16#3000# then
         return Mem (ROMH_Offset + 16#1000# + Natural (Addr and 16#0FFF#));
      end if;
      if VIC_Char_ROM and then (A16 mod 16#8000#) / 16#1000# = 1 then
         return Mem (VIC_Char_Base + A16 mod 16#1000#);
      end if;
      return Mem (VIC_RAM_Base + A16);
   end VIC_Mem;

   function VIC_Color (Index : Natural) return Byte is
     (Color_RAM (VIC_Color_Bank * 1024 + Index));

   ---------------------------------------------------------------------
   --  I/O
   ---------------------------------------------------------------------

   function CIA1_Port_Read (Reg : Natural) return Byte is
      PA : constant Byte := CIA.Port_A_Out (CIA1) and not Keyboard.Joy2;
      PB : constant Byte := CIA.Port_B_Out (CIA1) and not Keyboard.Joy1;
      Ext : constant Byte := (if VIC.Has_C128_Regs then VIC.Key_Lines
                              else 16#FF#);
   begin
      if Reg = 0 then
         return PA and Keyboard.Scan_Cols (PB);
      else
         return PB and Keyboard.Scan_Rows (PA, Ext);
      end if;
   end CIA1_Port_Read;

   procedure Sync_Drive (Write_Delay : Natural := 0) is
      --  Bring the drive up to the moment of the current bus access
      --  (approximated as the last cycle of the executing instruction).
      --  A write by the computer becomes visible to the drive one cycle
      --  later (CIA output, 7406 inverter and VIA input latch), so for
      --  writes the drive is run one cycle further before the change.
      Offset : Natural := (if CPU.Current_Cycles > 0
                           then CPU.Current_Cycles - 1 else 0);
   begin
      if Drive_On then
         if VIA_Fast then
            Offset := Offset / 2;
         end if;
         Drive1541.Run_Until
           (Total_Cycles + Long_Long_Integer (Offset + Write_Delay));
      end if;
   end Sync_Drive;

   procedure Update_IEC_Outputs is
      PA  : constant Byte := CIA2.PRA and CIA2.DDRA;
      Old_ATN : constant Boolean := IEC.C64_ATN;
   begin
      IEC.C64_ATN  := (PA and 16#08#) /= 0;
      IEC.C64_CLK  := (PA and 16#10#) /= 0;
      IEC.C64_DATA := (PA and 16#20#) /= 0;
      if IEC.C64_ATN /= Old_ATN and then Drive_On then
         Drive1541.ATN_Changed;
      end if;
   end Update_IEC_Outputs;

   function CIA2_Port_A_Read return Byte is
      PA : constant Byte := CIA.Port_A_Out (CIA2);
      V  : Byte := PA and 16#3F#;
   begin
      Sync_Drive;
      if not IEC.CLK then
         V := V or 16#40#;
      end if;
      if not IEC.DATA then
         V := V or 16#80#;
      end if;
      return V;
   end CIA2_Port_A_Read;

   function MMU_Read (Reg : Natural) return Byte is
   begin
      case Reg is
         when 0 => return MMU_CR;
         when 1 .. 4 => return MMU_PCR (Reg);
         when 5 =>
            return (MMU_MCR and 16#49#) or 16#06# or
              (if Cart_Present and then Cart_Game then 0 else 16#10#) or
              (if Cart_Present and then Cart_Exrom then 0 else 16#20#) or
              (if Key_4080_Down then 0 else 16#80#);
         when 6 => return MMU_RCR or 16#30#;
         when 7 => return MMU_P0L;
         when 8 => return MMU_P0H or 16#F0#;
         when 9 => return MMU_P1L;
         when 10 => return MMU_P1H or 16#F0#;
         when 11 => return 16#20#;
         when others => return 16#FF#;
      end case;
   end MMU_Read;

   procedure MMU_Write (Reg : Natural; Value : Byte) is
   begin
      case Reg is
         when 0 => MMU_CR := Value;
         when 1 .. 4 => MMU_PCR (Reg) := Value;
         when 5 =>
            MMU_MCR := Value;
            if (Value and 16#40#) /= 0 then
               C64_Mode := True;      --  GO64
               VIC.Has_C128_Regs := True;
            end if;
         when 6 => MMU_RCR := Value;
         when 7 =>
            MMU_P0L := Value;
            MMU_P0H := P0H_Latch;
         when 8 => P0H_Latch := Value;
         when 9 =>
            MMU_P1L := Value;
            MMU_P1H := P1H_Latch;
         when 10 => P1H_Latch := Value;
         when others => null;
      end case;
      Rebuild_Map;
   end MMU_Write;

   procedure Cart_IO_Write (Addr : Word; Value : Byte) is
      Old_Bank : constant Natural := Cart_Bank;
      Old_Lines : constant Boolean := Cart_Exrom xor Cart_Game;
      Old_E : constant Boolean := Cart_Exrom;
   begin
      if not Cart_Present then
         return;
      end if;
      case Cart_Info.Kind is
         when CRT.Ocean =>
            if Addr in 16#DE00# .. 16#DEFF# then
               Cart_Bank := Natural (Value and 16#3F#);
            end if;
         when CRT.Magic_Desk =>
            if Addr in 16#DE00# .. 16#DEFF# then
               Cart_Bank := Natural (Value and 16#7F#);
               Cart_Exrom := (Value and 16#80#) = 0;
            end if;
         when CRT.Game_System =>
            if Addr in 16#DE00# .. 16#DEFF# then
               Cart_Bank := Natural (Addr and 16#3F#);
            end if;
         when CRT.Easy_Flash =>
            if Addr = 16#DE00# then
               Cart_Bank := Natural (Value and 16#3F#);
            elsif Addr = 16#DE02# then
               Cart_Exrom := (Value and 2) /= 0;
               --  Bit 2 selects whether bit 0 or the boot jumper drives GAME
               Cart_Game := (if (Value and 4) /= 0 then (Value and 1) /= 0
                             else True);
            elsif Addr in 16#DF00# .. 16#DFFF# then
               Cart_RAM (Natural (Addr and 16#FF#)) := Value;
            end if;
         when others =>
            null;
      end case;
      if Cart_Bank /= Old_Bank or else Cart_Exrom /= Old_E
        or else (Cart_Exrom xor Cart_Game) /= Old_Lines
      then
         Rebuild_Map;
      end if;
   end Cart_IO_Write;

   function Cart_IO_Read (Addr : Word) return Byte is
   begin
      if Cart_Present then
         case Cart_Info.Kind is
            when CRT.Dinamic =>
               if Addr in 16#DE00# .. 16#DEFF# then
                  Cart_Bank := Natural (Addr and 16#0F#);
                  Rebuild_Map;
               end if;
            when CRT.Easy_Flash =>
               if Addr in 16#DF00# .. 16#DFFF# then
                  return Cart_RAM (Natural (Addr and 16#FF#));
               end if;
            when others =>
               null;
         end case;
      end if;
      return 16#FF#;
   end Cart_IO_Read;

   function IO_Read (Addr : Word) return Byte is
      Off : constant Natural := Natural (Addr and 16#FF#);
   begin
      case Addr is
         when 16#D000# .. 16#D3FF# =>
            return VIC.Read (Natural (Addr and 16#3F#));
         when 16#D400# .. 16#D7FF# =>
            if Current_Model = C128 then
               case Addr is
                  when 16#D500# .. 16#D5FF# =>
                     if not C64_Mode then
                        return MMU_Read (Off);
                     end if;
                     return SID.Read (Off);
                  when 16#D600# .. 16#D6FF# =>
                     if Off mod 2 = 0 then
                        return VDC.Read_Status;
                     else
                        return VDC.Read_Data;
                     end if;
                  when 16#D700# .. 16#D7FF# =>
                     return 16#FF#;
                  when others =>
                     return SID.Read (Off);
               end case;
            end if;
            return SID.Read (Off);
         when 16#D800# .. 16#DBFF# =>
            return Color_RAM (CPU_Color_Bank * 1024 +
                                Natural (Addr - 16#D800#)) or 16#F0#;
         when 16#DC00# .. 16#DCFF# =>
            if Off mod 16 <= 1 then
               return CIA1_Port_Read (Off mod 16);
            end if;
            return CIA.Read (CIA1, Off);
         when 16#DD00# .. 16#DDFF# =>
            if Off mod 16 = 0 then
               return CIA2_Port_A_Read;
            end if;
            return CIA.Read (CIA2, Off);
         when others =>
            return Cart_IO_Read (Addr);
      end case;
   end IO_Read;

   procedure IO_Write (Addr : Word; Value : Byte) is
      Off : constant Natural := Natural (Addr and 16#FF#);
   begin
      case Addr is
         when 16#D000# .. 16#D3FF# =>
            VIC.Write (Natural (Addr and 16#3F#), Value);
         when 16#D400# .. 16#D7FF# =>
            if Current_Model = C128 then
               case Addr is
                  when 16#D500# .. 16#D5FF# =>
                     if not C64_Mode then
                        MMU_Write (Off, Value);
                     else
                        SID.Write (Off, Value);
                     end if;
                  when 16#D600# .. 16#D6FF# =>
                     if Off mod 2 = 0 then
                        VDC.Write_Address (Value);
                     else
                        VDC.Write_Data (Value);
                     end if;
                  when 16#D700# .. 16#D7FF# =>
                     null;
                  when others =>
                     SID.Write (Off, Value);
               end case;
            else
               SID.Write (Off, Value);
            end if;
         when 16#D800# .. 16#DBFF# =>
            Color_RAM (CPU_Color_Bank * 1024 + Natural (Addr - 16#D800#)) :=
              Value and 16#0F#;
         when 16#DC00# .. 16#DCFF# =>
            CIA.Write (CIA1, Off, Value);
         when 16#DD00# .. 16#DDFF# =>
            if Off mod 16 = 0 or else Off mod 16 = 2 then
               Sync_Drive (Write_Delay => 1);
            end if;
            CIA.Write (CIA2, Off, Value);
            if Off mod 16 = 0 or else Off mod 16 = 2 then
               Update_VIC_Bank;
               Update_IEC_Outputs;
            end if;
         when others =>
            Cart_IO_Write (Addr, Value);
      end case;
   end IO_Write;

   ---------------------------------------------------------------------
   --  CPU bus
   ---------------------------------------------------------------------

   function Port_Read return Byte is
      Input : constant Byte :=
        (if Current_Model = C128 then 16#57# else 16#17#);
   begin
      return (Port_Data and Port_DDR) or (Input and not Port_DDR);
   end Port_Read;

   function Bus_Read (Addr : Word) return Byte is
      Page : constant Byte := Hi (Addr);
      Off  : Integer;
   begin
      if Addr < 2 then
         return (if Addr = 0 then Port_DDR else Port_Read);
      end if;
      if Page = 16#FF# and then not C64_Mode
        and then Addr <= 16#FF04#
      then
         return MMU_Read (Natural (Addr - 16#FF00#));
      end if;
      Off := Read_Map (Page);
      if Off >= 0 then
         return Mem (Off + Natural (Addr and 16#FF#));
      end if;
      return IO_Read (Addr);
   end Bus_Read;

   procedure Bus_Write (Addr : Word; Value : Byte) is
      Page : constant Byte := Hi (Addr);
      Off  : Integer;
   begin
      if Addr < 2 then
         if Addr = 0 then
            Port_DDR := Value;
         else
            Port_Data := Value;
         end if;
         --  The CPU still writes the underlying RAM
         Mem (Write_Map (0) + Natural (Addr)) := Value;
         Rebuild_Map;
         return;
      end if;
      if Page = 16#FF# and then not C64_Mode
        and then Addr <= 16#FF04#
      then
         if Addr = 16#FF00# then
            MMU_CR := Value;
         else
            MMU_CR := MMU_PCR (Natural (Addr - 16#FF00#));
         end if;
         Rebuild_Map;
         return;
      end if;
      Off := Write_Map (Page);
      if Off >= 0 then
         Mem (Off + Natural (Addr and 16#FF#)) := Value;
      else
         IO_Write (Addr, Value);
      end if;
   end Bus_Write;

   ---------------------------------------------------------------------
   --  ROM loading
   ---------------------------------------------------------------------

   procedure Load_ROM (Path : String; Offset : Natural; Size : Natural;
                       Skip : Natural := 0; Ok : in out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Buf : Byte_Array (0 .. Skip + Size - 1);
   begin
      Open (F, In_File, Path);
      Byte_Array'Read (Stream (F), Buf);
      Close (F);
      Mem (Offset .. Offset + Size - 1) := Buf (Skip .. Skip + Size - 1);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Append (Err, "Cannot load ROM " & Path & ASCII.LF);
         Ok := False;
   end Load_ROM;

   procedure Update_Drive_State is
      Want : constant Boolean :=
        True_Drive and then Drive1541.ROM_Loaded
        and then Media.Kind = Media.D64;
   begin
      if Want and then not Drive_On then
         Drive1541.Reset;
         --  Line up the drive's clock with the computer's
         Drive1541.Set_Time (Total_Cycles);
      end if;
      Drive_On := Want;
      IEC.Drive_Present := Want;
   end Update_Drive_State;

   procedure Find_Drive_ROM (ROM_Dir : String) is
      Ok : Boolean := False;
      Exe_Dir : constant String :=
        Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name);

      procedure Try (Path : String) is
      begin
         if not Ok and then Ada.Directories.Exists (Path) then
            Drive1541.Load_ROM (Path, Ok);
         end if;
      exception
         when others => null;
      end Try;
   begin
      if Drive1541.ROM_Loaded then
         return;
      end if;
      if Length (Drive_ROM_Path) > 0 then
         Try (To_String (Drive_ROM_Path));
      end if;
      Try (ROM_Dir & "/DRIVES/dos1541-325302-01+901229-05.bin");
      Try (ROM_Dir & "/DRIVES/dos1541");
      Try (Exe_Dir & "/../roms/drives/dos1541.bin");
      Try ("roms/drives/dos1541.bin");
      Try (Exe_Dir & "/../roms/drives/1541-II.251968-03.bin");
   exception
      when others => null;
   end Find_Drive_ROM;

   procedure Attach (Path : String; Ok : out Boolean) is
   begin
      Drive1541.Eject_Disk;
      Media.Attach (Path, Ok);
      if Ok and then Media.Kind = Media.D64 then
         Drive1541.Insert_Disk;
      end if;
      Update_Drive_State;
   end Attach;

   procedure Attach_Cartridge (Path : String; Ok : out Boolean) is
      Info : CRT.Image;
      Data : Byte_Array_Access;
      procedure Free is new Ada.Unchecked_Deallocation
        (Byte_Array, Byte_Array_Access);
   begin
      CRT.Load (Path, Info, Data, Ok);
      if Ok and then Info.Kind = CRT.Unsupported then
         Ok := False;
         Err := To_Unbounded_String
           ("Unsupported cartridge hardware type" & Info.Hw_Type'Image);
      end if;
      if Ok then
         Mem (Cart_Base .. Mem'Last) := Data.all;
         Cart_Info := Info;
         Cart_Present := True;
         Reset;
      end if;
      if Data /= null then
         Free (Data);
      end if;
   end Attach_Cartridge;

   procedure Detach_Cartridge is
   begin
      Cart_Present := False;
      Cart_Info := (others => <>);
      Reset;
   end Detach_Cartridge;

   function Cartridge_Name return String is
     (if Cart_Present then Cart_Info.Name else "");

   procedure Detach is
   begin
      Drive1541.Eject_Disk;
      Media.Detach;
      Update_Drive_State;
   end Detach;

   procedure Set_True_Drive (On : Boolean) is
   begin
      True_Drive := On;
      Update_Drive_State;
   end Set_True_Drive;

   function Drive_Active return Boolean is (Drive_On);
   function Drive_ROM_Found return Boolean is (Drive1541.ROM_Loaded);
   function Drive_LED return Boolean is (Drive_On and then Drive1541.LED_On);
   function Drive_Motor return Boolean is
     (Drive_On and then Drive1541.Motor_On);
   function Drive_Track return Natural is (Drive1541.Current_Track);

   NMI_Count, IRQ_Count : Natural := 0;
   Last_NMI_PC : Word := 0;

   function Debug_Info return String is
     ("nmi=" & NMI_Count'Image & " (last from" & Last_NMI_PC'Image & ")" &
      " irq=" & IRQ_Count'Image & " jam=" & CPU.Jammed'Image &
      " drivePC=" & Drive1541.Get_PC'Image &
      " cia2 mask=" & CIA2.ICR_Mask'Image & " flags=" & CIA2.ICR_Flags'Image);

   function Drive_Peek (Addr : Natural) return Byte is
     (Drive1541.Peek_RAM (Addr));

   procedure Shutdown is
   begin
      Drive1541.Flush;
   end Shutdown;

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean) is
   begin
      Find_Drive_ROM (ROM_Dir);
      Ok := True;
      Err := Null_Unbounded_String;
      Current_Model := M;
      case M is
         when C64 =>
            declare
               D : constant String := ROM_Dir & "/C64/";
            begin
               Load_ROM (D & "basic-901226-01.bin", ROM_C64_Basic, 8192,
                         Ok => Ok);
               Load_ROM (D & "kernal-901227-03.bin", ROM_C64_Kernal, 8192,
                         Ok => Ok);
               Load_ROM (D & "chargen-901225-01.bin", ROM_C64_Char, 4096,
                         Ok => Ok);
            end;
         when C128 =>
            declare
               D : constant String := ROM_Dir & "/C128/";
            begin
               Load_ROM (D & "basic64-901226-01.bin", ROM_C64_Basic, 8192,
                         Ok => Ok);
               Load_ROM (D & "kernal64-901227-03.bin", ROM_C64_Kernal, 8192,
                         Ok => Ok);
               Load_ROM (D & "chargen-390059-01.bin", ROM_C64_Char, 4096,
                         Ok => Ok);
               Load_ROM (D & "chargen-390059-01.bin", ROM_C128_Char, 4096,
                         Skip => 4096, Ok => Ok);
               Load_ROM (D & "kernal-318020-05.bin", ROM_C128_Kernal, 16384,
                         Ok => Ok);
               Load_ROM (D & "basiclo-318018-04.bin", ROM_C128_BasicLo,
                         16384, Ok => Ok);
               Load_ROM (D & "basichi-318019-04.bin", ROM_C128_BasicHi,
                         16384, Ok => Ok);
            end;
      end case;
      Mem (ROM_Empty .. ROM_Empty + 255) := (others => 16#FF#);
      Reset;
   end Power_On;

   function Model return Model_Type is (Current_Model);
   function In_C64_Mode return Boolean is (C64_Mode);
   function Error_Message return String is (To_String (Err));
   function VDC_Enabled return Boolean is (Current_Model = C128);
   function Frame_Count return Natural is (Frames);
   function Get_PC return Word is (CPU.PC);

   procedure Reset is
   begin
      --  Power-up RAM pattern: alternating 64-byte blocks of $00 / $FF
      for I in 0 .. RAM_Size - 1 loop
         Mem (I) := (if (I / 64) mod 2 = 0 then 16#00# else 16#FF#);
      end loop;
      Color_RAM := (others => 0);

      Port_DDR := 0;
      Port_Data := 0;
      MMU_CR := 0;
      MMU_PCR := (others => 0);
      MMU_MCR := 0;
      MMU_RCR := 0;
      MMU_P0L := 0; MMU_P0H := 0;
      MMU_P1L := 1; MMU_P1H := 0;
      P0H_Latch := 0; P1H_Latch := 0;
      C64_Mode := Current_Model = C64;

      Cart_Bank := 0;
      Cart_Exrom := Cart_Info.Exrom_Low;
      Cart_Game := Cart_Info.Game_Low;
      if Cart_Info.Kind = CRT.Easy_Flash then
         Cart_Exrom := False;    --  boots in Ultimax mode (boot jumper)
         Cart_Game := True;
      end if;
      CIA.Reset (CIA1);
      CIA.Reset (CIA2);
      VIC.Reset;
      VIC.Has_C128_Regs := Current_Model = C128;
      SID.Reset;
      VDC.Reset;
      Keyboard.Release_All;
      Update_VIC_Bank;
      Rebuild_Map;
      NMI_Prev := False;
      Half_Cycle := 0;
      Total_Cycles := 0;
      IEC.C64_ATN := False;
      IEC.C64_CLK := False;
      IEC.C64_DATA := False;
      Update_Drive_State;
      if Drive1541.ROM_Loaded then
         Drive1541.Reset;
      end if;
      CPU.IRQ_Line := False;
      CPU.Reset;
   end Reset;

   function Peek (Addr : Word) return Byte is
      Off : constant Integer := Read_Map (Hi (Addr));
   begin
      if Addr < 2 then
         return (if Addr = 0 then Port_DDR else Port_Read);
      elsif Off >= 0 then
         return Mem (Off + Natural (Addr and 16#FF#));
      else
         return 16#FF#;
      end if;
   end Peek;

   procedure Poke (Addr : Word; Value : Byte) is
   begin
      Mem (Natural (Addr)) := Value;
   end Poke;

   ---------------------------------------------------------------------
   --  KERNAL traps
   ---------------------------------------------------------------------

   procedure Free is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

   function RAM_Bank_Of (KBank : Byte) return Natural is
     (if C64_Mode then 0
      elsif KBank <= 3 then Natural (KBank mod 2)
      else 0);

   function Read_Name return Byte_Array is
      Len  : constant Natural := Natural (Bus_Read (16#B7#));
      Ptr  : constant Natural := Natural (Bus_Read (16#BB#)) +
        256 * Natural (Bus_Read (16#BC#));
      Bank : constant Natural :=
        (if C64_Mode then 0 else RAM_Bank_Of (Bus_Read (16#C7#)));
      Name : Byte_Array (0 .. Len - 1);
   begin
      for I in Name'Range loop
         if C64_Mode then
            Name (I) := Bus_Read (Word ((Ptr + I) mod 16#10000#));
         else
            Name (I) := Mem (Bank * 16#10000# + (Ptr + I) mod 16#10000#);
         end if;
      end loop;
      return Name;
   end Read_Name;

   procedure Trap_Return (Ok : Boolean; Error_Code : Byte := 0) is
   begin
      CPU.Flag_C := not Ok;
      if not Ok then
         CPU.A := Error_Code;
      end if;
      Bus_Write (16#90#, 0);
      CPU.Do_RTS;
   end Trap_Return;

   procedure Trap_Load is
      Dev : constant Byte := Bus_Read (16#BA#);
      SA  : constant Byte := Bus_Read (16#B9#);
      Verify : constant Boolean := CPU.A /= 0;
      Data : Byte_Array_Access;
      Found : Boolean;
   begin
      if Dev = 1 then
         if Media.Kind not in Media.T64 | Media.PRG then
            return;    --  real tape routine
         end if;
      elsif Dev /= 8 or else Drive_On then
         return;
      end if;

      Media.Find_File (Read_Name, Data, Found);
      if not Found or else Data = null or else Data'Length < 2 then
         if Data /= null then
            Free (Data);
         end if;
         Trap_Return (False, 4);   --  FILE NOT FOUND
         return;
      end if;

      declare
         File_Addr : constant Natural :=
           Natural (Data (0)) + 256 * Natural (Data (1));
         Load_Addr : constant Natural :=
           (if SA = 0 then Natural (CPU.X) + 256 * Natural (CPU.Y)
            else File_Addr);
         Bank : constant Natural :=
           RAM_Bank_Of (if C64_Mode then 0 else Bus_Read (16#C6#));
         End_Addr : constant Natural :=
           (Load_Addr + Data'Length - 2) mod 16#10000#;
      begin
         if not Verify then
            for I in 2 .. Data'Last loop
               Mem (Bank * 16#10000# + (Load_Addr + I - 2) mod 16#10000#) :=
                 Data (I);
            end loop;
         end if;
         CPU.X := Byte (End_Addr mod 256);
         CPU.Y := Byte (End_Addr / 256);
         Bus_Write (16#AE#, CPU.X);
         Bus_Write (16#AF#, CPU.Y);
      end;
      Free (Data);
      Trap_Return (True);
   exception
      when others =>
         Trap_Return (False, 4);   --  malformed image: FILE NOT FOUND
   end Trap_Load;

   procedure Trap_Save is
      Dev : constant Byte := Bus_Read (16#BA#);
      ZP  : constant Word := Word (CPU.A);
      Start_Addr : constant Natural := Natural (Bus_Read (ZP)) +
        256 * Natural (Bus_Read (ZP + 1));
      End_Addr : constant Natural := Natural (CPU.X) + 256 * Natural (CPU.Y);
      Bank : constant Natural :=
        RAM_Bank_Of (if C64_Mode then 0 else Bus_Read (16#C6#));
      Ok : Boolean;
   begin
      if Dev /= 8 or else Drive_On or else End_Addr < Start_Addr then
         return;
      end if;
      declare
         Data : Byte_Array (0 .. End_Addr - Start_Addr + 1);
      begin
         Data (0) := Byte (Start_Addr mod 256);
         Data (1) := Byte (Start_Addr / 256);
         for I in 0 .. End_Addr - Start_Addr - 1 loop
            Data (I + 2) := Mem (Bank * 16#10000# + Start_Addr + I);
         end loop;
         Media.Save_File (Read_Name, Data, Ok);
      end;
      Trap_Return (Ok, 5);    --  DEVICE NOT PRESENT on failure
   exception
      when others =>
         Trap_Return (False, 5);
   end Trap_Save;

   ---------------------------------------------------------------------
   --  Keyboard buffer injection and autostart
   ---------------------------------------------------------------------

   procedure Type_Text (S : String) is
   begin
      Append (Type_Queue, S);
   end Type_Text;

   function To_Petscii (C : Character) return Byte is
   begin
      case C is
         when 'a' .. 'z' => return Character'Pos (C) - 32;
         when ASCII.LF | ASCII.CR => return 16#0D#;
         when others => return Character'Pos (C);
      end case;
   end To_Petscii;

   procedure Feed_Keyboard is
      Count_Addr : constant Word := (if C64_Mode then 16#C6# else 16#D0#);
      Buf_Addr   : constant Word := (if C64_Mode then 16#0277# else 16#034A#);
      N : Natural;
   begin
      if Length (Type_Queue) = 0 or else Bus_Read (Count_Addr) /= 0 then
         return;
      end if;
      N := Natural'Min (Length (Type_Queue), 10);
      for I in 1 .. N loop
         Bus_Write (Buf_Addr + Word (I - 1),
                    To_Petscii (Element (Type_Queue, I)));
      end loop;
      Bus_Write (Count_Addr, Byte (N));
      Delete (Type_Queue, 1, N);
   end Feed_Keyboard;

   function Screen_Contains (Text : String) return Boolean is
      function Code (C : Character) return Byte is
        (case C is
            when 'A' .. 'Z' => Character'Pos (C) - 64,
            when 'a' .. 'z' => Character'Pos (C) - 96,
            when others => Character'Pos (C));

      function Search (Get : access function (I : Natural) return Byte;
                       Size : Natural) return Boolean is
      begin
         for Start in 0 .. Size - Text'Length loop
            declare
               Hit : Boolean := True;
            begin
               for K in Text'Range loop
                  if (Get (Start + K - Text'First) and 16#7F#) /=
                    Code (Text (K))
                  then
                     Hit := False;
                     exit;
                  end if;
               end loop;
               if Hit then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Search;

      function VIC_Screen (I : Natural) return Byte is
        (Mem (16#0400# + I));
      function VDC_Screen (I : Natural) return Byte is
        (VDC.Peek_VRAM (Natural (VDC.Peek_Reg (12)) * 256 +
                          Natural (VDC.Peek_Reg (13)) + I));
   begin
      if Search (VIC_Screen'Access, 1000) then
         return True;
      end if;
      return Current_Model = C128 and then Search (VDC_Screen'Access, 2000);
   end Screen_Contains;

   procedure Autostart (Path : String; Ok : out Boolean) is
   begin
      if Path'Length > 4 and then
        (Path (Path'Last - 3 .. Path'Last) = ".crt"
         or else Path (Path'Last - 3 .. Path'Last) = ".CRT")
      then
         Type_Queue := Null_Unbounded_String;
         Attach_Cartridge (Path, Ok);
         return;
      end if;
      Attach (Path, Ok);
      if not Ok then
         return;
      end if;
      Reset;
      Type_Queue := Null_Unbounded_String;
      declare
         LA : constant Word := Media.First_Load_Address;
         Cmd : Unbounded_String;
      begin
         if Current_Model = C128 then
            if LA = 16#1C01# or else LA = 0 then
               Cmd := To_Unbounded_String ("LOAD""*"",8" & ASCII.LF & "RUN"
                                           & ASCII.LF);
            else
               Cmd := To_Unbounded_String
                 ("BLOAD""*"",U8" & ASCII.LF & "SYS" &
                  Natural'Image (Natural (LA)) & ASCII.LF);
            end if;
         elsif LA = 16#0801# or else LA = 0 then
            Cmd := To_Unbounded_String ("LOAD""*"",8,1" & ASCII.LF & "RUN"
                                        & ASCII.LF);
         elsif LA >= 16#2000# and then Media.Start_Program_Name /= "" then
            --  First file looks like data (e.g. a game part loaded high):
            --  start the first BASIC program on the disk instead.
            Cmd := To_Unbounded_String
              ("LOAD""" & Media.Start_Program_Name & """,8" & ASCII.LF &
               "RUN" & ASCII.LF);
         else
            Cmd := To_Unbounded_String ("LOAD""*"",8,1" & ASCII.LF & "SYS" &
                                        Natural'Image (Natural (LA)) &
                                        ASCII.LF);
         end if;
         Auto_Command := Cmd;
      end;
      Auto := Wait_Ready;
      Auto_Frames := 0;
   end Autostart;

   function Autostart_Busy return Boolean is (Auto /= Idle);

   procedure Autostart_Step is
   begin
      case Auto is
         when Idle => null;
         when Wait_Ready =>
            Auto_Frames := Auto_Frames + 1;
            if Screen_Contains ("READY.") or else Auto_Frames > 600 then
               Type_Text (To_String (Auto_Command));
               Auto := Wait_Load;
               Auto_Frames := 0;
            end if;
         when Wait_Load =>
            Auto_Frames := Auto_Frames + 1;
            --  Done once everything typed (including RUN) was consumed
            if Length (Type_Queue) = 0 and then Auto_Frames > 10
              and then Bus_Read (if C64_Mode then 16#C6# else 16#D0#) = 0
            then
               Auto := Idle;
            end if;
      end case;
   end Autostart_Step;

   ---------------------------------------------------------------------
   --  Main loop
   ---------------------------------------------------------------------

   procedure Clock_Devices (N : Natural) is
   begin
      Total_Cycles := Total_Cycles + Long_Long_Integer (N);
      VIC.Tick (N);
      CIA.Tick (CIA1, N);
      CIA.Tick (CIA2, N);
      SID.Clock (N);
      if Current_Model = C128 then
         VDC.Tick (N);
      end if;
   end Clock_Devices;

   procedure Run_Frame is
      N : Natural;
      Dev : Natural;
      NMI_Now : Boolean;
   begin
      VIC.Frame_Done := False;
      while not VIC.Frame_Done loop
         if VIC.Stall_Cycles > 0 then
            N := VIC.Stall_Cycles;
            VIC.Stall_Cycles := 0;
            Clock_Devices (N);
         else
            if Kernal_High then
               if CPU.PC = 16#FFD5# then
                  Trap_Load;
               elsif CPU.PC = 16#FFD8# then
                  Trap_Save;
               end if;
            end if;

            CPU.IRQ_Line := VIC.IRQ or else CIA1.IRQ;
            NMI_Now := CIA2.IRQ or else Keyboard.Restore_Down;
            if NMI_Now and then not NMI_Prev then
               CPU.NMI_Pending := True;
               NMI_Count := NMI_Count + 1;
               Last_NMI_PC := CPU.PC;
            end if;
            if CPU.IRQ_Line and then not CPU.Flag_I then
               IRQ_Count := IRQ_Count + 1;
            end if;
            NMI_Prev := NMI_Now;

            CPU.Step (N);

            if VIC.Fast_Mode and then not C64_Mode then
               Dev := (N + Half_Cycle) / 2;
               Half_Cycle := (N + Half_Cycle) mod 2;
            else
               Dev := N;
            end if;
            if Dev > 0 then
               Clock_Devices (Dev);
            end if;
         end if;
         if Drive_On then
            Drive1541.Run_Until (Total_Cycles);
         end if;
      end loop;

      --  50 Hz TOD input
      CIA.Tick_TOD (CIA1);
      CIA.Tick_TOD (CIA2);
      TOD_Div := TOD_Div + 1;

      if Current_Model = C128 then
         VDC.Render_Frame;
      end if;

      Feed_Keyboard;
      Autostart_Step;
      Frames := Frames + 1;
   end Run_Frame;

end Machine;
