-- ***************************************************************************
--                      AdaC64 - Machine.C64_System
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with Z80;
with VIC_II;
with CIA;
with SID;
with VDC;
with Keyboard;
with Paddles;
with Video;
with CRT;
with REU;
with Tape;
with Drive1541;
with IEC;
use type CRT.Cart_Type;
with Machine.Core; use Machine.Core;

package body Machine.C64_System is

   Z80_Read_Map  : Page_Map := (others => 0);   --  C128 Z80 view
   Z80_Write_Map : Page_Map := (others => 0);

   --  C128 dual CPU: MMU MCR bit 0 selects the 8502 (1) or the Z80 (0)
   Z80_Active   : Boolean := False;
   CPU_Started  : Boolean := True;     --  8502 has left reset
   Z80_Half     : Natural := 0;
   Z80_Frames   : Natural := 0;        --  safety net if the Z80 hangs
   Z80_Was_Used : Boolean := False;    --  Z80 re-activated after boot

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
   Fast_In_Count, Fast_Out_Count : Natural := 0;   --  fast serial bytes
   TOD_Div : Natural := 0;

   function VIC_Mem (Addr : Word) return Byte;
   function VIC_Color (Index : Natural) return Byte;
   function Z80_Mem_Read (Addr : Word) return Byte;
   procedure Z80_Mem_Write (Addr : Word; Value : Byte);
   function Z80_In (Port : Word) return Byte;
   procedure Z80_Out (Port : Word; Value : Byte);
   package ZCPU is new Z80 (Read => Z80_Mem_Read, Write => Z80_Mem_Write,
                            In_Port => Z80_In, Out_Port => Z80_Out);
   package VIC is new VIC_II (Mem_Read => VIC_Mem, Color_Read => VIC_Color);

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

   function VIC_Peek (Addr : Word) return Byte is (VIC_Mem (Addr));
   function VIC_Bank_Address return Word is (Word (VIC_Bank_Base));
   function Char_ROM_Peek (Offset : Natural) return Byte is
     (Mem (VIC_Char_Base + Offset mod 4096));

   function VIC_Color (Index : Natural) return Byte is
     (Color_RAM (VIC_Color_Bank * 1024 + Index));

   ---------------------------------------------------------------------
   --  I/O
   ---------------------------------------------------------------------

   --  The port the paddles are plugged into (the joystick port setting)
   function Paddle_Port return Natural is
     (if Keyboard."=" (Keyboard.Joystick_Port, 1) then 1 else 2);

   --  Joystick bits of a control port; with paddles in that port only
   --  their buttons (on the left / right lines)
   --  (a light pen sits in port 1, its button on "up" as VICE's default
   --  pen type)
   function Port_Joy (Port : Natural) return Byte is
     (if Paddles.Active and then Port = Paddle_Port then Paddles.Fire_Bits
      elsif Port = 1 then Keyboard.Joy1
        or (if Paddles.Pen_Active and then Paddles.Pen_Down then 1 else 0)
      else Keyboard.Joy2);

   --  The VIC-II's LP input is CIA1 port B bit 4 (joystick 1 fire)
   procedure Check_LP_Line is
   begin
      VIC.Set_LP_Line
        (((CIA.Port_B_Out (CIA1) and not Port_Joy (1)) and 16#10#) = 0);
   end Check_LP_Line;

   --  SID POTX / POTY: CIA1 port A bits 6 / 7 select which control port
   --  the SID reads
   procedure Update_SID_Pots is
      Sel : constant Byte := CIA.Port_A_Out (CIA1) and 16#C0#;
      Port : constant Natural :=
        (if Sel = 16#40# then 1 elsif Sel = 16#80# then 2 else 0);
   begin
      if Paddles.Active and then Port = Paddle_Port then
         SID.Pot_X := Paddles.Value (1);
         SID.Pot_Y := Paddles.Value (2);
      else
         SID.Pot_X := 16#FF#;
         SID.Pot_Y := 16#FF#;
      end if;
   end Update_SID_Pots;

   function CIA1_Port_Read (Reg : Natural) return Byte is
      PA : constant Byte := CIA.Port_A_Out (CIA1) and not Port_Joy (2);
      PB : constant Byte := CIA.Port_B_Out (CIA1) and not Port_Joy (1);
      Ext : constant Byte := (if VIC.Has_C128_Regs then VIC.Key_Lines
                              else 16#FF#);
   begin
      if Reg = 0 then
         return PA and Keyboard.Scan_Cols (PB);
      else
         return PB and Keyboard.Scan_Rows (PA, Ext);
      end if;
   end CIA1_Port_Read;

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
      case Addr is
         when 16#D000# .. 16#D3FF# =>
            return VIC.Read (Natural (Addr and 16#3F#));
         when 16#D400# .. 16#D7FF# =>
            Update_SID_Pots;
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
            if Off mod 16 in 1 | 3 then
               Check_LP_Line;
            end if;
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
   --  CPU port and MMU configuration registers
   ---------------------------------------------------------------------

   function Port_In return Byte is
      --  Bit 4: cassette sense (0 = PLAY pressed); C128 bit 6: CAPS key
      Input : constant Byte :=
        (if Current_Model = C128 then 16#47# else 16#07#) or
        (if Tape.Playing then 0 else 16#10#);
   begin
      return (Port_Data and Port_DDR) or (Input and not Port_DDR);
   end Port_In;

   function Port_Read (Addr : Word) return Byte is
     (if Addr = 0 then Port_DDR else Port_In);

   procedure Port_Write (Addr : Word; Value : Byte) is
   begin
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
   end Port_Write;

   procedure MMU_Config_Write (Addr : Word; Value : Byte) is
   begin
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
   end MMU_Config_Write;

   procedure FF00_Written is
   begin
      REU.FF00_Written;
      REU_Stall;
   end FF00_Written;

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

   procedure Fast_Byte_To_Host (Value : Byte) is
   begin
      Fast_In_Count := Fast_In_Count + 1;
      if Current_Model = C128 and then not C64_Mode
        and then (MMU_MCR and 8) = 0
      then
         CIA.Set_SDR (CIA1, Value);
      end if;
   end Fast_Byte_To_Host;

   procedure Init is
   begin
      Drive1541.To_Host := Fast_Byte_To_Host'Access;
      REU.Bus_Read := Bus_Read'Access;
      REU.Bus_Write := Bus_Write'Access;
   end Init;

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean) is
   begin
      case Current_Model is
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
         when others =>
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
   end Load_ROMs;

   procedure Set_Standard (V : Video_Standard) is
      Hz : constant Natural := (if V = PAL then 985_248 else 1_022_727);
   begin
      VIC.Cycles_Per_Line := (if V = PAL then 63 else 65);
      VIC.Lines_Per_Frame := (if V = PAL then 312 else 263);
      SID.Set_Clock (Hz);
      Drive1541.Set_Host_Clock (Hz);
      VDC.Set_Frame_Cycles (VIC.Cycles_Per_Line * VIC.Lines_Per_Frame);
      Video.First_Visible_Line := (if V = PAL then 16 else 14);
      Video.VIC_Visible_Lines := (if V = PAL then Video.VIC_Height else 249);
      Video.VIC_Visible_Width := Video.VIC_Width;
      Video.X_Aspect := 1.0;
   end Set_Standard;

   procedure Reset (Hard : Boolean) is
      pragma Unreferenced (Hard);
   begin
      Port_DDR := 0;
      Port_Data := 0;
      MMU_CR := 0;
      MMU_PCR := (others => 0);
      MMU_MCR := 0;
      MMU_RCR := 0;
      MMU_P0L := 0; MMU_P0H := 0;
      MMU_P1L := 1; MMU_P1H := 0;
      P0H_Latch := 0; P1H_Latch := 0;
      C64_Mode := Current_Model /= C128;    --  (the VIC-20 uses no MMU)

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
      Update_VIC_Bank;
      ZCPU.Reset;
      Z80_Half := 0;
      Z80_Frames := 0;
      --  A C128 powers up with the Z80 running its BIOS, which then hands
      --  the bus to the 8502 (see MMU_Write).
      Z80_Active := Current_Model = C128;
      Z80_Was_Used := False;
      CPU_Started := Current_Model /= C128;
   end Reset;

   ---------------------------------------------------------------------
   --  Cartridges
   ---------------------------------------------------------------------

   procedure Attach_Cartridge (Path : String; Ok : out Boolean) is
      Info : CRT.Image;
      Data : Byte_Array_Access;
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
         Machine.Reset;
      end if;
      if Data /= null then
         Free (Data);
      end if;
   end Attach_Cartridge;

   procedure Detach_Cartridge is
   begin
      Cart_Present := False;
      Cart_Info := (others => <>);
   end Detach_Cartridge;

   function Cartridge_Name return String is
     (if Cart_Present then Cart_Info.Name else "");

   ---------------------------------------------------------------------
   --  Running
   ---------------------------------------------------------------------

   procedure Clock (N : Natural) is
      Pulses : Natural;
   begin
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
   end Clock;

   function Fast_2MHz return Boolean is (VIC.Fast_Mode and then not C64_Mode);

   function Take_Stall return Natural is
      N : constant Natural := VIC.Stall_Cycles;
   begin
      VIC.Stall_Cycles := 0;
      return N;
   end Take_Stall;

   function Stalled return Boolean is (VIC.Stall_Cycles > 0);

   function Z80_Running return Boolean is (Z80_Active);
   function Z80_Used return Boolean is (Z80_Was_Used);

   procedure Step_Z80 (Device_Cycles : out Natural) is
      N : Natural;
      NMI_Now : Boolean;
   begin
      ZCPU.INT_Line := VIC.IRQ or else CIA1.IRQ or else REU.IRQ;
      NMI_Now := CIA2.IRQ or else Keyboard.Restore_Down;
      if NMI_Now and then not NMI_Prev then
         ZCPU.NMI_Pending := True;
      end if;
      NMI_Prev := NMI_Now;
      ZCPU.Step (N);
      --  ~2 MHz effective: two T-states per 1 MHz device cycle
      Device_Cycles := (N + Z80_Half) / 2;
      Z80_Half := (N + Z80_Half) mod 2;
   end Step_Z80;

   procedure Interrupt_Lines (IRQ, NMI : out Boolean) is
   begin
      IRQ := VIC.IRQ or else CIA1.IRQ or else REU.IRQ;
      NMI := CIA2.IRQ or else Keyboard.Restore_Down;
   end Interrupt_Lines;

   function Frame_Done return Boolean is (VIC.Frame_Done);

   procedure Clear_Frame is
   begin
      VIC.Frame_Done := False;
   end Clear_Frame;

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
      VIC.Set_Light_Pen (Paddles.Pen_X, Paddles.Pen_Y,
                         Paddles.Pen_Active and then Paddles.Pen_Down);
      Check_LP_Line;
   end End_Of_Frame;

   ---------------------------------------------------------------------
   --  Inspection
   ---------------------------------------------------------------------

   function Screen_Byte (I : Natural) return Byte is (Mem (16#0400# + I));

   function VDC_Screen_Byte (I : Natural) return Byte is
     (VDC.Peek_VRAM (Natural (VDC.Peek_Reg (12)) * 256 +
                       Natural (VDC.Peek_Reg (13)) + I));

   function IO_Peek (Addr : Word) return Byte is
   begin
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
   end IO_Peek;

   function Beam_Text return String is
     ("  raster" & VIC.Raster'Image & " cycle" & VIC.Line_Cycle'Image);

   function Debug_Text return String is
     (" cia2 mask=" & CIA2.ICR_Mask'Image & " flags=" & CIA2.ICR_Flags'Image &
      " fast serial in/out=" & Fast_In_Count'Image & Fast_Out_Count'Image);

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
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
      Boolean'Write (S, Key_4080_Down);
      Boolean'Write (S, Cart_Present); CRT.Image'Write (S, Cart_Info);
      Natural'Write (S, Cart_Bank); Boolean'Write (S, Cart_Exrom);
      Boolean'Write (S, Cart_Game); Byte_Array'Write (S, Cart_RAM);
      Boolean'Write (S, Z80_Active); Boolean'Write (S, CPU_Started);
      Boolean'Write (S, Z80_Was_Used);
      Natural'Write (S, Z80_Half);
      ZCPU.Save_State (S);
      REU.Save_State (S);
      VIC.Save_State (S);
      SID.Save_State (S);
      VDC.Save_State (S);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
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
      Boolean'Read (S, Key_4080_Down);
      Boolean'Read (S, Cart_Present); CRT.Image'Read (S, Cart_Info);
      Natural'Read (S, Cart_Bank); Boolean'Read (S, Cart_Exrom);
      Boolean'Read (S, Cart_Game); Byte_Array'Read (S, Cart_RAM);
      Boolean'Read (S, Z80_Active); Boolean'Read (S, CPU_Started);
      Boolean'Read (S, Z80_Was_Used);
      Natural'Read (S, Z80_Half);
      ZCPU.Load_State (S);
      REU.Load_State (S);
      VIC.Load_State (S);
      SID.Load_State (S);
      VDC.Load_State (S);
      Update_VIC_Bank;
   end Load_State;

end Machine.C64_System;
