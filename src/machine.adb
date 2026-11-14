with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;

with MOS6502;
with Z80;
with VIC_II;
with CIA;
with SID;
with VDC;
with Keyboard;
with Media;
with Video;
with Disasm;
with CRT;
with REU;
with Tape;
use type CRT.Cart_Type;
with Drive1541;
use type Media.Media_Kind;
use type Drive1541.Drive_Model;
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
   Color_Page : constant Integer := -2;   --  Z80 view of colour RAM

   type Page_Map is array (Byte) of Integer;
   Read_Map  : Page_Map := (others => 0);
   Write_Map : Page_Map := (others => 0);
   Z80_Read_Map  : Page_Map := (others => 0);   --  C128 Z80 view
   Z80_Write_Map : Page_Map := (others => 0);

   --  C128 dual CPU: MMU MCR bit 0 selects the 8502 (1) or the Z80 (0)
   Z80_Active   : Boolean := False;
   CPU_Started  : Boolean := True;     --  8502 has left reset
   Z80_Half     : Natural := 0;
   Z80_Frames   : Natural := 0;        --  safety net if the Z80 hangs
   Z80_Was_Used : Boolean := False;    --  Z80 re-activated after boot

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
   Total_Cycles : Long_Long_Integer := 0;
   Fast_In_Count, Fast_Out_Count : Natural := 0;   --  fast serial bytes   --  1 MHz device time
   Drive_On : Boolean := False;             --  true drive participating
   TOD_Div : Natural := 0;

   --  Typing / autostart
   Type_Queue : Unbounded_String;
   type Auto_State is
     (Idle, Wait_Ready, Wait_Load, Wait_Check, Wait_Boot, Wait_Tape);
   Quiet_Frames : Natural := 0;
   Tape_Autostart : Boolean := False;
   Auto_Path : Unbounded_String;
   Fast_Frames : Natural := 0;
   Auto : Auto_State := Idle;
   Auto_Command : Unbounded_String;
   Auto_Frames : Natural := 0;

   ---------------------------------------------------------------------
   --  Forward declarations
   ---------------------------------------------------------------------

   function Bus_Read (Addr : Word) return Byte;
   procedure Update_Drive_State;
   procedure Clock_Devices (N : Natural);

   --  Sub-instruction timing: during CPU.Step, I/O accesses first clock
   --  the chips up to the cycle on which the access happens (the last
   --  cycle of the instruction), so writes take effect at the right time.
   In_Step      : Boolean := False;
   Instr_Ticked : Natural := 0;    --  cycles already clocked this step
   procedure Bus_Write (Addr : Word; Value : Byte);
   function VIC_Mem (Addr : Word) return Byte;
   function VIC_Color (Index : Natural) return Byte;

   package CPU is new MOS6502 (Read => Bus_Read, Write => Bus_Write);

   function Z80_Mem_Read (Addr : Word) return Byte;
   procedure Z80_Mem_Write (Addr : Word; Value : Byte);
   function Z80_In (Port : Word) return Byte;
   procedure Z80_Out (Port : Word; Value : Byte);
   package ZCPU is new Z80 (Read => Z80_Mem_Read, Write => Z80_Mem_Write,
                            In_Port => Z80_In, Out_Port => Z80_Out);
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

      --  Z80 view: same banking, but I/O is only reachable through IN/OUT
      --  (RAM at $D000-$DFFF), and in RAM bank 0 with I/O enabled the Z80
      --  BIOS ROM (upper 4K of the KERNAL ROM image) is at $0000-$0FFF.
      Z80_Read_Map := Read_Map;
      Z80_Write_Map := Write_Map;
      for P in Byte range 16#D0# .. 16#DF# loop
         if Z80_Read_Map (P) = IO_Page then
            Z80_Read_Map (P) := Write_Map (16#CF#) + 256 * Natural (P - 16#CF#);
            Z80_Write_Map (P) := Z80_Read_Map (P);
         end if;
      end loop;
      if (MMU_CR and 16#C0#) = 0 then
         --  Bank 0: BIOS ROM reads; writes go to RAM at $D000-$DFFF
         for P in Byte range 0 .. 16#0F# loop
            Z80_Read_Map (P) := ROM_C128_Kernal + 16#1000# + Natural (P) * 256;
            Z80_Write_Map (P) := 16#D000# + Natural (P) * 256;
         end loop;
      end if;
      if (MMU_CR and 1) = 0 then
         --  With I/O enabled the Z80 sees colour RAM at $1000-$13FF
         for P in Byte range 16#10# .. 16#13# loop
            Z80_Read_Map (P) := Color_Page;
            Z80_Write_Map (P) := Color_Page;
         end loop;
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

   procedure Catch_Up is
      Target : constant Natural :=
        (if CPU.Current_Cycles > 0 then CPU.Current_Cycles - 1 else 0);
   begin
      if In_Step and then not VIA_Fast and then Target > Instr_Ticked then
         Clock_Devices (Target - Instr_Ticked);
         Instr_Ticked := Target;
      end if;
   end Catch_Up;

   procedure Sync_Drive (Write_Delay : Natural := 0) is
      --  Bring the drive up to the moment of the current bus access
      --  (the last cycle of the executing instruction; the other chips
      --  have already been clocked there by Catch_Up).
      --  A write by the computer becomes visible to the drive one cycle
      --  later (CIA output, 7406 inverter and VIA input latch), so for
      --  writes the drive is run one cycle further before the change.
      Offset : Natural := (if In_Step
                             and then CPU.Current_Cycles > Instr_Ticked + 1
                           then CPU.Current_Cycles - 1 - Instr_Ticked
                           else 0);
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
               Z80_Active := False;
            elsif Current_Model = C128 then
               if (Value and 1) = 0 then
                  Z80_Active := True;
                  if CPU_Started then
                     Z80_Was_Used := True;    --  CP/M and the like
                  end if;
               else
                  Z80_Active := False;
                  Z80_Frames := 0;
                  if not CPU_Started then
                     --  The 8502 leaves reset when the Z80 hands over
                     CPU_Started := True;
                     CPU.Reset;
                     CPU.PC := Make_Word (Mem (ROM_C128_Kernal + 16#3FFC#),
                                          Mem (ROM_C128_Kernal + 16#3FFD#));
                  end if;
               end if;
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

   procedure REU_Stall is
   begin
      --  The CPU is halted while the REU does its DMA
      if REU.Stall_Cycles > 0 then
         VIC.Stall_Cycles := VIC.Stall_Cycles + REU.Stall_Cycles;
         REU.Stall_Cycles := 0;
      end if;
   end REU_Stall;

   function IO_Read (Addr : Word) return Byte is
      Off : constant Natural := Natural (Addr and 16#FF#);
   begin
      Catch_Up;
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
         when 16#DF00# .. 16#DFFF# =>
            if REU.Present then
               return REU.Read (Natural (Addr and 16#1F#));
            end if;
            return Cart_IO_Read (Addr);
         when others =>
            return Cart_IO_Read (Addr);
      end case;
   end IO_Read;

   procedure IO_Write (Addr : Word; Value : Byte) is
      Off : constant Natural := Natural (Addr and 16#FF#);
   begin
      Catch_Up;
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
            --  C128 fast serial: a byte shifted out (FSDIR = output) goes
            --  to a 1571
            if Off mod 16 = 12 and then Current_Model = C128
              and then not C64_Mode and then (MMU_MCR and 8) /= 0
              and then Drive_On
            then
               Sync_Drive (Write_Delay => 1);
               Fast_Out_Count := Fast_Out_Count + 1;
               Drive1541.Fast_Byte_From_Host (Value);
            end if;
         when 16#DD00# .. 16#DDFF# =>
            if Off mod 16 = 0 or else Off mod 16 = 2 then
               Sync_Drive (Write_Delay => 1);
            end if;
            CIA.Write (CIA2, Off, Value);
            if Off mod 16 = 0 or else Off mod 16 = 2 then
               Update_VIC_Bank;
               Update_IEC_Outputs;
            end if;
         when 16#DF00# .. 16#DFFF# =>
            if REU.Present then
               REU.Write (Natural (Addr and 16#1F#), Value);
               REU_Stall;
            else
               Cart_IO_Write (Addr, Value);
            end if;
         when others =>
            Cart_IO_Write (Addr, Value);
      end case;
   end IO_Write;

   ---------------------------------------------------------------------
   --  CPU bus
   ---------------------------------------------------------------------

   function Port_Read return Byte is
      --  Bit 4: cassette sense (0 = PLAY pressed); C128 bit 6: CAPS key
      Input : constant Byte :=
        (if Current_Model = C128 then 16#47# else 16#07#) or
        (if Tape.Playing then 0 else 16#10#);
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
         --  Bit 5 drives the cassette motor (active low)
         Tape.Motor := (Port_DDR and 16#20#) /= 0
           and then (Port_Data and 16#20#) = 0;
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
         if Addr = 16#FF00# then
            REU.FF00_Written;
            REU_Stall;
         end if;
         return;
      end if;
      if Addr = 16#FF00# then
         REU.FF00_Written;      --  C64: the write also goes to RAM below
         REU_Stall;
      end if;
      Off := Write_Map (Page);
      if Off >= 0 then
         Mem (Off + Natural (Addr and 16#FF#)) := Value;
      else
         IO_Write (Addr, Value);
      end if;
   end Bus_Write;

   ---------------------------------------------------------------------
   --  Z80 bus (C128)
   ---------------------------------------------------------------------

   function Z80_Mem_Read (Addr : Word) return Byte is
   begin
      if Hi (Addr) = 16#FF# and then Addr <= 16#FF04# then
         return MMU_Read (Natural (Addr - 16#FF00#));
      end if;
      if Z80_Read_Map (Hi (Addr)) = Color_Page then
         return Color_RAM (CPU_Color_Bank * 1024 + Natural (Addr - 16#1000#))
           or 16#F0#;
      end if;
      return Mem (Z80_Read_Map (Hi (Addr)) + Natural (Addr and 16#FF#));
   end Z80_Mem_Read;

   procedure Z80_Mem_Write (Addr : Word; Value : Byte) is
   begin
      if Hi (Addr) = 16#FF# and then Addr <= 16#FF04# then
         if Addr = 16#FF00# then
            MMU_CR := Value;
         else
            MMU_CR := MMU_PCR (Natural (Addr - 16#FF00#));
         end if;
         Rebuild_Map;
         return;
      end if;
      if Z80_Write_Map (Hi (Addr)) = Color_Page then
         Color_RAM (CPU_Color_Bank * 1024 + Natural (Addr - 16#1000#)) :=
           Value and 16#0F#;
         return;
      end if;
      Mem (Z80_Write_Map (Hi (Addr)) + Natural (Addr and 16#FF#)) := Value;
   end Z80_Mem_Write;

   --  The Z80 reaches the C128 I/O chips through its I/O space
   function Z80_In (Port : Word) return Byte is
   begin
      if Port in 16#D000# .. 16#DFFF# then
         return IO_Read (Port);
      end if;
      return 16#FF#;
   end Z80_In;

   procedure Z80_Out (Port : Word; Value : Byte) is
   begin
      if Port in 16#D000# .. 16#DFFF# then
         IO_Write (Port, Value);
      end if;
   end Z80_Out;

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
        and then Media.Kind in Media.D64 | Media.D71 | Media.G64;
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
      if Length (Drive_ROM_Path) > 0 then
         Try (To_String (Drive_ROM_Path));
         Ok := False;
      end if;
      if not Drive1541.Has_ROM (Drive1541.D1541) then
         Try (ROM_Dir & "/DRIVES/dos1541-325302-01+901229-05.bin");
         Try (ROM_Dir & "/DRIVES/dos1541");
         Try (Exe_Dir & "/../roms/drives/dos1541.bin");
         Try ("roms/drives/dos1541.bin");
         Try (Exe_Dir & "/../roms/drives/1541-II.251968-03.bin");
      end if;
      Ok := False;
      if not Drive1541.Has_ROM (Drive1541.D1571) then
         Try (ROM_Dir & "/DRIVES/dos1571-310654-05.bin");
         Try (ROM_Dir & "/DRIVES/dos1571");
         Try (Exe_Dir & "/../roms/drives/1571-rom.310654-05.bin");
         Try ("roms/drives/1571-rom.310654-05.bin");
      end if;
   exception
      when others => null;
   end Find_Drive_ROM;

   procedure Attach (Path : String; Ok : out Boolean) is
   begin
      Drive1541.Eject_Disk;
      Media.Attach (Path, Ok);
      if Ok and then Media.Kind in Media.D64 | Media.D71 | Media.G64 then
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

   procedure Fast_Byte_To_Host (Value : Byte) is
   begin
      Fast_In_Count := Fast_In_Count + 1;
      if Current_Model = C128 and then not C64_Mode
        and then (MMU_MCR and 8) = 0
      then
         CIA.Set_SDR (CIA1, Value);
      end if;
   end Fast_Byte_To_Host;

   procedure Set_Drive_Type (M : Drive1541.Drive_Model) is
   begin
      if M /= Drive1541.Model then
         Drive1541.Eject_Disk;
         Drive1541.Set_Model (M);
         if Media.Kind in Media.D64 | Media.D71 | Media.G64 then
            Drive1541.Insert_Disk;
         end if;
         Drive_On := False;
         Update_Drive_State;
      end if;
   end Set_Drive_Type;

   function Drive_Type return Drive1541.Drive_Model is (Drive1541.Model);

   procedure Set_True_Drive (On : Boolean) is
   begin
      True_Drive := On;
      Update_Drive_State;
   end Set_True_Drive;

   function Drive_Active return Boolean is (Drive_On);
   function Z80_Used return Boolean is (Z80_Was_Used);
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
      " cia2 mask=" & CIA2.ICR_Mask'Image & " flags=" & CIA2.ICR_Flags'Image &
      " fast serial in/out=" & Fast_In_Count'Image & Fast_Out_Count'Image &
      (if Tape.Present then " tape" & Tape.Counter'Image & "% motor=" &
         Tape.Motor'Image & " play=" & Tape.Playing'Image else ""));

   function Drive_Peek (Addr : Natural) return Byte is
     (Drive1541.Peek_RAM (Addr));

   procedure Shutdown is
   begin
      Drive1541.Flush;
   end Shutdown;

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean) is
   begin
      Drive1541.To_Host := Fast_Byte_To_Host'Access;
      REU.Bus_Read := Bus_Read'Access;
      REU.Bus_Write := Bus_Write'Access;
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

   Current_Standard : Video_Standard := PAL;

   procedure Set_Video_Standard (V : Video_Standard) is
      Hz : constant Natural := (if V = PAL then 985_248 else 1_022_727);
   begin
      Current_Standard := V;
      VIC.Cycles_Per_Line := (if V = PAL then 63 else 65);
      VIC.Lines_Per_Frame := (if V = PAL then 312 else 263);
      SID.Set_Clock (Hz);
      Drive1541.Set_Host_Clock (Hz);
      VDC.Set_Frame_Cycles (VIC.Cycles_Per_Line * VIC.Lines_Per_Frame);
      Video.First_Visible_Line := (if V = PAL then 16 else 14);
      Video.VIC_Visible_Lines := (if V = PAL then Video.VIC_Height else 249);
   end Set_Video_Standard;

   function Standard return Video_Standard is (Current_Standard);
   function Frame_Rate return Float is
     (if Current_Standard = PAL then 985_248.0 / 19_656.0
      else 1_022_727.0 / 17_095.0);
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
      REU.Reset;
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
      ZCPU.Reset;
      Z80_Half := 0;
      Z80_Frames := 0;
      --  A C128 powers up with the Z80 running its BIOS, which then hands
      --  the bus to the 8502 (see MMU_Write).
      Z80_Active := Current_Model = C128;
      Z80_Was_Used := False;
      CPU_Started := Current_Model /= C128;
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
      elsif Dev /= 8 or else (Drive_On and then not Fast_Kernal_Load) then
         return;
      end if;

      Media.Find_File (Read_Name, Data, Found);
      if Drive_On and then
        (not Found or else Media.Last_Lookup_Unreliable
         or else Data = null or else Data'Length < 2)
      then
         --  Let the emulated 1541 handle it (error message, protection,
         --  sectors that do not decode cleanly).
         if Data /= null then
            Free (Data);
         end if;
         return;
      end if;
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
                    and then not (Text (K) in 'A' .. 'Z' | 'a' .. 'z'
                                  and then (Get (Start + K - Text'First)
                                              and 16#7F#) =
                                    Code (Text (K)) + 64)
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
        (Path (Path'Last - 3 .. Path'Last) = ".tap"
         or else Path (Path'Last - 3 .. Path'Last) = ".TAP")
      then
         Tape.Attach (Path, Ok);
         if Ok then
            Reset;
            Tape.Rewind;
            Tape.Play;
            Type_Queue := Null_Unbounded_String;
            Auto_Command := To_Unbounded_String
              ("LOAD" & ASCII.LF & "RUN" & ASCII.LF);
            Auto := Wait_Ready;
            Tape_Autostart := True;
            Auto_Frames := 0;
         end if;
         return;
      end if;
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
         LA   : constant Word := Media.First_Load_Address;
         Name : constant String := Media.First_Program_Name;
         Q    : constant String := """" & Name & """";
         Cmd  : Unbounded_String;
         NL   : constant Character := ASCII.LF;
         function Addr return String is (Natural'Image (Natural (LA)));
      begin
         Auto_Path := To_Unbounded_String (Path);
         if Current_Model = C128 and then Media.Has_Boot_Sector then
            --  Boot disk (e.g. CP/M): the KERNAL boots it by itself; stay
            --  "busy" (the GUI warps) until the drive has been quiet.
            Auto := Wait_Boot;
            Auto_Frames := 0;
            Quiet_Frames := 0;
            return;
         elsif Current_Model = C128 then
            --  DLOAD like a C128 user (some loaders read its buffer)
            if LA in 16#1C01# | 16#4001# | 16#1201# or else LA = 0 then
               Cmd := To_Unbounded_String ("DLOAD" & Q & NL & "RUN" & NL);
            elsif Media.Start_Program_Name (For_C128 => True) /= "" then
               Cmd := To_Unbounded_String
                 ("DLOAD""" & Media.Start_Program_Name (For_C128 => True) &
                  """" & NL & "RUN" & NL);
            else
               Cmd := To_Unbounded_String
                 ("BLOAD" & Q & ",U8" & NL &
                  (if LA >= 16#4000# then "BANK0:SYS" else "SYS") & Addr & NL);
            end if;
         elsif LA = 16#0801# or else LA = 0 then
            Cmd := To_Unbounded_String ("LOAD" & Q & ",8,1" & NL & "RUN" & NL);
         elsif LA >= 16#2000# and then Media.Start_Program_Name /= "" then
            --  First file looks like data (e.g. a game part loaded high):
            --  start the first BASIC program on the disk instead.
            Cmd := To_Unbounded_String
              ("LOAD""" & Media.Start_Program_Name & """,8" & NL &
               "RUN" & NL);
         else
            Cmd := To_Unbounded_String
              ("LOAD" & Q & ",8,1" & NL & "SYS" & Addr & NL);
         end if;
         Auto_Command := Cmd;
      end;
      Auto := Wait_Ready;
      Auto_Frames := 0;
   end Autostart;

   function Autostart_Busy return Boolean is
     (Auto in Wait_Ready | Wait_Load | Wait_Boot | Wait_Tape);

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
            if (Length (Type_Queue) = 0 and then Auto_Frames > 10
                and then Bus_Read (if C64_Mode then 16#C6# else 16#D0#) = 0)
              or else Auto_Frames > 600
            then
               Fast_Frames := 0;
               Auto := (if Tape_Autostart then Wait_Tape
                        elsif Current_Model = C128 and then not C64_Mode
                          and then not Key_4080_Down
                        then Wait_Check else Idle);
               Quiet_Frames := 0;
               Auto_Frames := 0;
            end if;
         when Wait_Tape =>
            --  Warp while the tape runs (turbo loaders keep the motor on)
            Auto_Frames := Auto_Frames + 1;
            Quiet_Frames := (if Tape.Motor and then Tape.Playing then 0
                             else Quiet_Frames + 1);
            if Quiet_Frames > 250 or else Auto_Frames > 200_000 then
               Auto := Idle;
               Tape_Autostart := False;
            end if;
         when Wait_Boot =>
            Auto_Frames := Auto_Frames + 1;
            Quiet_Frames := (if Drive_Motor then 0 else Quiet_Frames + 1);
            if (Auto_Frames > 300 and then Quiet_Frames > 150)
              or else Auto_Frames > 15_000
            then
               Auto := Idle;
            end if;
         when Wait_Check =>
            --  An 80-column program started in 40-column mode usually
            --  says so; restart it with the 40/80 key down.
            Auto_Frames := Auto_Frames + 1;
            --  FAST (2 MHz) blanks the 40-column screen: a program running
            --  in FAST mode for a while is meant for the 80-column screen.
            Fast_Frames := (if VIC.Fast_Mode then Fast_Frames + 1 else 0);
            if Fast_Frames > 250
              or else Screen_Contains ("80 COL") or else Screen_Contains ("80-COL")
              or else Screen_Contains ("80 ZEICHEN")
              or else Screen_Contains ("80 SPALTEN")
            then
               Key_4080_Down := True;
               declare
                  Ok : Boolean;
               begin
                  Autostart (To_String (Auto_Path), Ok);
               end;
            elsif Auto_Frames > 400 then
               Auto := Idle;
            end if;
      end case;
   end Autostart_Step;

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   Snapshot_Magic : constant String := "ADAC64SNAP7";

   procedure Save_Snapshot (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
   begin
      Create (F, Out_File, Path);
      S := Stream (F);
      String'Write (S, Snapshot_Magic);
      Model_Type'Write (S, Current_Model);
      Video_Standard'Write (S, Current_Standard);
      String'Output (S, Media.Attached_Path);
      Byte_Array'Write (S, Mem);
      Byte_Array'Write (S, Color_RAM);
      Boolean'Write (S, C64_Mode);
      Byte'Write (S, Port_DDR); Byte'Write (S, Port_Data);
      Byte'Write (S, MMU_CR);
      for P of MMU_PCR loop
         Byte'Write (S, P);
      end loop;
      Byte'Write (S, MMU_MCR); Byte'Write (S, MMU_RCR);
      Byte'Write (S, MMU_P0L); Byte'Write (S, MMU_P0H);
      Byte'Write (S, MMU_P1L); Byte'Write (S, MMU_P1H);
      Byte'Write (S, P0H_Latch); Byte'Write (S, P1H_Latch);
      CIA.Chip'Write (S, CIA1); CIA.Chip'Write (S, CIA2);
      Boolean'Write (S, NMI_Prev); Natural'Write (S, Half_Cycle);
      Natural'Write (S, Frames); Long_Long_Integer'Write (S, Total_Cycles);
      Boolean'Write (S, Key_4080_Down); Boolean'Write (S, True_Drive);
      Boolean'Write (S, Drive_On);
      Boolean'Write (S, Cart_Present); CRT.Image'Write (S, Cart_Info);
      Natural'Write (S, Cart_Bank); Boolean'Write (S, Cart_Exrom);
      Boolean'Write (S, Cart_Game); Byte_Array'Write (S, Cart_RAM);
      Byte'Write (S, CPU.A); Byte'Write (S, CPU.X); Byte'Write (S, CPU.Y);
      Byte'Write (S, CPU.SP); Word'Write (S, CPU.PC);
      Byte'Write (S, CPU.Get_P);
      Boolean'Write (S, CPU.IRQ_Line); Boolean'Write (S, CPU.NMI_Pending);
      Boolean'Write (S, CPU.Jammed);
      Boolean'Write (S, IEC.C64_ATN); Boolean'Write (S, IEC.C64_CLK);
      Boolean'Write (S, IEC.C64_DATA);
      Boolean'Write (S, Z80_Active); Boolean'Write (S, CPU_Started);
      Boolean'Write (S, Z80_Was_Used);
      Natural'Write (S, Z80_Half);
      ZCPU.Save_State (S);
      REU.Save_State (S);
      Tape.Save_State (S);
      VIC.Save_State (S);
      SID.Save_State (S);
      VDC.Save_State (S);
      Drive1541.Save_State (S);
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Save_Snapshot;

   procedure Load_Snapshot (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
      Magic : String (Snapshot_Magic'Range);
      P : Byte;
   begin
      Ok := False;
      Open (F, In_File, Path);
      S := Stream (F);
      String'Read (S, Magic);
      if Magic /= Snapshot_Magic then
         Close (F);
         Err := To_Unbounded_String ("Not an AdaC64 snapshot");
         return;
      end if;
      Model_Type'Read (S, Current_Model);
      declare
         V : Video_Standard;
      begin
         Video_Standard'Read (S, V);
         Set_Video_Standard (V);
      end;
      declare
         Disk_Path : constant String := String'Input (S);
         Attached : Boolean;
      begin
         Drive1541.Eject_Disk;
         if Disk_Path /= "" and then Disk_Path /= Media.Attached_Path then
            Media.Attach (Disk_Path, Attached);
            if not Attached then
               Media.Detach;
            end if;
         elsif Disk_Path = "" then
            Media.Detach;
         end if;
      end;
      Byte_Array'Read (S, Mem);
      Byte_Array'Read (S, Color_RAM);
      Boolean'Read (S, C64_Mode);
      Byte'Read (S, Port_DDR); Byte'Read (S, Port_Data);
      Byte'Read (S, MMU_CR);
      for P of MMU_PCR loop
         Byte'Read (S, P);
      end loop;
      Byte'Read (S, MMU_MCR); Byte'Read (S, MMU_RCR);
      Byte'Read (S, MMU_P0L); Byte'Read (S, MMU_P0H);
      Byte'Read (S, MMU_P1L); Byte'Read (S, MMU_P1H);
      Byte'Read (S, P0H_Latch); Byte'Read (S, P1H_Latch);
      CIA.Chip'Read (S, CIA1); CIA.Chip'Read (S, CIA2);
      Boolean'Read (S, NMI_Prev); Natural'Read (S, Half_Cycle);
      Natural'Read (S, Frames); Long_Long_Integer'Read (S, Total_Cycles);
      Boolean'Read (S, Key_4080_Down); Boolean'Read (S, True_Drive);
      Boolean'Read (S, Drive_On);
      Boolean'Read (S, Cart_Present); CRT.Image'Read (S, Cart_Info);
      Natural'Read (S, Cart_Bank); Boolean'Read (S, Cart_Exrom);
      Boolean'Read (S, Cart_Game); Byte_Array'Read (S, Cart_RAM);
      Byte'Read (S, CPU.A); Byte'Read (S, CPU.X); Byte'Read (S, CPU.Y);
      Byte'Read (S, CPU.SP); Word'Read (S, CPU.PC);
      Byte'Read (S, P);
      CPU.Set_P (P);
      Boolean'Read (S, CPU.IRQ_Line); Boolean'Read (S, CPU.NMI_Pending);
      Boolean'Read (S, CPU.Jammed);
      Boolean'Read (S, IEC.C64_ATN); Boolean'Read (S, IEC.C64_CLK);
      Boolean'Read (S, IEC.C64_DATA);
      Boolean'Read (S, Z80_Active); Boolean'Read (S, CPU_Started);
      Boolean'Read (S, Z80_Was_Used);
      Natural'Read (S, Z80_Half);
      ZCPU.Load_State (S);
      REU.Load_State (S);
      Tape.Load_State (S);
      VIC.Load_State (S);
      SID.Load_State (S);
      VDC.Load_State (S);
      Drive1541.Load_State (S);
      Close (F);
      IEC.Drive_Present := Drive_On;
      Keyboard.Release_All;
      Type_Queue := Null_Unbounded_String;
      Auto := Idle;
      Update_VIC_Bank;
      Rebuild_Map;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Err := To_Unbounded_String ("Snapshot could not be read");
         Ok := False;
   end Load_Snapshot;

   ---------------------------------------------------------------------
   --  Main loop
   ---------------------------------------------------------------------

   procedure Clock_Devices (N : Natural) is
      Pulses : Natural;
   begin
      Total_Cycles := Total_Cycles + Long_Long_Integer (N);
      if Tape.Present then
         Tape.Tick (N, Pulses);
         if Pulses > 0 then
            CIA.Set_Flag (CIA1, 16#10#);    --  read pulse on FLAG
         end if;
      end if;
      VIC.Tick (N);
      CIA.Tick (CIA1, N);
      CIA.Tick (CIA2, N);
      SID.Clock (N);
      if Current_Model = C128 then
         VDC.Tick (N);
      end if;
   end Clock_Devices;

   ---------------------------------------------------------------------
   --  Debugger support
   ---------------------------------------------------------------------

   Max_Breakpoints : constant := 16;
   Breakpoints : array (1 .. Max_Breakpoints) of Word := (others => 0);
   BP_Count    : Natural := 0;
   Break_Flag  : Boolean := False;
   Skip_Break  : Boolean := False;   --  do not re-trigger at resume point

   procedure Set_Breakpoint (Addr : Word) is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            return;
         end if;
      end loop;
      if BP_Count < Max_Breakpoints then
         BP_Count := BP_Count + 1;
         Breakpoints (BP_Count) := Addr;
      end if;
   end Set_Breakpoint;

   procedure Clear_Breakpoint (Addr : Word) is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            Breakpoints (I) := Breakpoints (BP_Count);
            BP_Count := BP_Count - 1;
            return;
         end if;
      end loop;
   end Clear_Breakpoint;

   procedure Clear_Breakpoints is
   begin
      BP_Count := 0;
   end Clear_Breakpoints;

   function Breakpoint_List return String is
      R : Unbounded_String;
   begin
      for I in 1 .. BP_Count loop
         Append (R, " $" & Disasm.Hex4 (Breakpoints (I)));
      end loop;
      return (if BP_Count = 0 then " (none)" else To_String (R));
   end Breakpoint_List;

   function Break_Hit return Boolean is (Break_Flag);

   procedure Resume is
   begin
      Break_Flag := False;
      Skip_Break := True;
   end Resume;

   function At_Breakpoint return Boolean is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = CPU.PC then
            return True;
         end if;
      end loop;
      return False;
   end At_Breakpoint;

   function Monitor_Peek (Addr : Word; Drive : Boolean := False) return Byte
   is
   begin
      if Drive then
         return Drive1541.Peek (Addr);
      end if;
      if Addr >= 2 and then Read_Map (Hi (Addr)) = IO_Page then
         case Addr is
            when 16#D000# .. 16#D3FF# =>
               return (if (Addr and 16#3F#) in 16#1E# | 16#1F# then 0
                       else VIC.Read (Natural (Addr and 16#3F#)));
            when 16#D800# .. 16#DBFF# =>
               return Color_RAM (CPU_Color_Bank * 1024 +
                                   Natural (Addr - 16#D800#)) or 16#F0#;
            when 16#DC00# .. 16#DCFF# =>
               return CIA.Peek (CIA1, Natural (Addr and 15));
            when 16#DD00# .. 16#DDFF# =>
               return CIA.Peek (CIA2, Natural (Addr and 15));
            when others =>
               return 16#FF#;
         end case;
      end if;
      return Peek (Addr);
   end Monitor_Peek;

   procedure Monitor_Poke (Addr : Word; Value : Byte; Drive : Boolean := False)
   is
   begin
      if Drive then
         Drive1541.Poke (Addr, Value);
      else
         Bus_Write (Addr, Value);
      end if;
   end Monitor_Poke;

   function Flags_Text (N, V, D, I, Z, C : Boolean) return String is
     ((if N then 'N' else '.') & (if V then 'V' else '.') & "-B" &
      (if D then 'D' else '.') & (if I then 'I' else '.') &
      (if Z then 'Z' else '.') & (if C then 'C' else '.'));

   function Register_Text (Drive : Boolean := False) return String is
   begin
      if Drive then
         return Drive1541.Register_Text;
      end if;
      return "PC=$" & Disasm.Hex4 (CPU.PC) & " A=$" & Disasm.Hex2 (CPU.A) &
        " X=$" & Disasm.Hex2 (CPU.X) & " Y=$" & Disasm.Hex2 (CPU.Y) &
        " SP=$" & Disasm.Hex2 (CPU.SP) & " " &
        Flags_Text (CPU.Flag_N, CPU.Flag_V, CPU.Flag_D, CPU.Flag_I,
                    CPU.Flag_Z, CPU.Flag_C) &
        "  raster" & VIC.Raster'Image & " cycle" & VIC.Line_Cycle'Image &
        "  $01=$" & Disasm.Hex2 (Port_Read);
   end Register_Text;

   function CPU_PC (Drive : Boolean := False) return Word is
     (if Drive then Drive1541.Get_PC else CPU.PC);

   procedure Monitor_Set_PC (Addr : Word) is
   begin
      CPU.PC := Addr;
   end Monitor_Set_PC;

   ---------------------------------------------------------------------
   --  Main loop
   ---------------------------------------------------------------------

   procedure End_Of_Frame is
   begin
      if Z80_Active and then not CPU_Started then
         --  Safety net: the Z80 BIOS never handed over; start the 8502
         Z80_Frames := Z80_Frames + 1;
         if Z80_Frames > 10 then
            Z80_Active := False;
            CPU_Started := True;
            CPU.Reset;
            MMU_CR := 0;
            Rebuild_Map;
            CPU.Reset;
         end if;
      end if;
      --  50 Hz TOD input
      CIA.Tick_TOD (CIA1);
      CIA.Tick_TOD (CIA2);
      TOD_Div := TOD_Div + 1;

      if Current_Model = C128 then
         VDC.Render_Frame;
      end if;

      Feed_Keyboard;
      Keyboard.Tick_Typing;
      Autostart_Step;
      Frames := Frames + 1;
   end End_Of_Frame;

   --  Advance the system by one CPU instruction (or one VIC stall period).
   --  Returns True when a CPU instruction was executed.
   function Step_System return Boolean is
      N : Natural;
      Dev : Natural;
      NMI_Now : Boolean;
      Executed : Boolean := False;
   begin
      if VIC.Stall_Cycles > 0 then
         N := VIC.Stall_Cycles;
         VIC.Stall_Cycles := 0;
         Clock_Devices (N);
      elsif Z80_Active then
         ZCPU.INT_Line := VIC.IRQ or else CIA1.IRQ or else REU.IRQ;
         NMI_Now := CIA2.IRQ or else Keyboard.Restore_Down;
         if NMI_Now and then not NMI_Prev then
            ZCPU.NMI_Pending := True;
         end if;
         NMI_Prev := NMI_Now;
         ZCPU.Step (N);
         --  ~2 MHz effective: two T-states per 1 MHz device cycle
         Dev := (N + Z80_Half) / 2;
         Z80_Half := (N + Z80_Half) mod 2;
         if Dev > 0 then
            Clock_Devices (Dev);
         end if;
      else
         if Kernal_High then
            if CPU.PC = 16#FFD5# then
               Trap_Load;
            elsif CPU.PC = 16#FFD8# then
               Trap_Save;
            end if;
         end if;

         CPU.IRQ_Line := VIC.IRQ or else CIA1.IRQ or else REU.IRQ;
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

         Instr_Ticked := 0;
         In_Step := True;
         CPU.Step (N);
         In_Step := False;
         Executed := True;

         if VIC.Fast_Mode and then not C64_Mode then
            Dev := (N + Half_Cycle) / 2;
            Half_Cycle := (N + Half_Cycle) mod 2;
         else
            Dev := (if N > Instr_Ticked then N - Instr_Ticked else 0);
         end if;
         Instr_Ticked := 0;
         if Dev > 0 then
            Clock_Devices (Dev);
         end if;
      end if;
      if Drive_On then
         Drive1541.Run_Until (Total_Cycles);
      end if;
      return Executed;
   end Step_System;

   procedure Run_Frame is
   begin
      if Break_Flag then
         return;          --  stopped at a breakpoint until Resume
      end if;
      while not VIC.Frame_Done loop
         if BP_Count > 0 and then VIC.Stall_Cycles = 0 then
            if not Skip_Break and then At_Breakpoint then
               Break_Flag := True;
               return;
            end if;
            Skip_Break := False;
         end if;
         declare
            Dummy : constant Boolean := Step_System;
            pragma Unreferenced (Dummy);
         begin
            null;
         end;
      end loop;
      VIC.Frame_Done := False;
      End_Of_Frame;
   end Run_Frame;

   procedure Step_Instruction is
   begin
      loop
         exit when Step_System;
      end loop;
      if VIC.Frame_Done then
         VIC.Frame_Done := False;
         End_Of_Frame;
      end if;
      Skip_Break := True;
   end Step_Instruction;

end Machine;
