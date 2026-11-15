-- ***************************************************************************
--                      AdaC64 - Machine.VIC20_System
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

with Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Directories;
with Ada.Command_Line;
with Interfaces; use Interfaces;
with VIC_I;
with VIA;
with SID;
with Keyboard;
with Paddles;
with Tape;
with Drive1541;
with IEC;
with Final_Expansion;
with Machine.Core; use Machine.Core;

package body Machine.VIC20_System is

   --  VIC-20
   function V20_Fetch (Addr : Word) return Byte;
   function V20_Color (Index : Natural) return Byte;
   package V20 is new VIC_I (Fetch => V20_Fetch, Color => V20_Color);
   V20_VIA1, V20_VIA2 : VIA.Chip;
   V20_Mem : VIC20_Memory := Unexpanded;
   V20_Block5 : Boolean := False;    --  RAM at $A000 (cartridge images)

   --  VIC-20 cartridge ROM per 8K block (1 = $2000, 2 = $4000, 3 = $6000,
   --  5 = $A000), stored at Cart_Base + block * 8K
   type V20_Block_Set is array (1 .. 5) of Boolean;
   V20_Cart : V20_Block_Set := (others => False);
   V20_Cart_Name : Unbounded_String;

   --  Mega-Cart (as in VICE): bank registers $9C80 (high: $A000) and
   --  $9D00 (low: $2000-$7FFF), bit 7 = RAM, bit 6 (high) = RAM writable;
   --  the registers only count after a software reset ($9E00) has
   --  toggled the OE flip-flop - until then both act as bank $7F
   MC_Present  : Boolean := False;
   MC_Bank_Low, MC_Bank_High : Byte := 0;
   MC_OE       : Boolean := False;
   MC_NVRAM_En : Boolean := True;
   MC_Soft_Reset : Boolean := False;     --  requested by a $9E00 write
   MC_Pending : Boolean := False;        --  a .crt turned out to be one
   MC_RAM   : constant := V20_XRAM;
   MC_NVRAM : constant := V20_XRAM + 16#8000#;
   MC_ROM   : constant := Cart_Base;
   procedure Map_Mega_Cart;
   function V20_Cart_Offset (B : Positive) return Natural is
     (Cart_Base + B * 16#2000#);

   function Has_3K return Boolean is
     (V20_Mem in Plus_3K | Plus_35K);
   function Blocks return Natural is
     (case V20_Mem is
        when Unexpanded | Plus_3K => 0,
        when Plus_8K => 1, when Plus_16K => 2,
        when Plus_24K | Plus_35K => 3);

   --  VIC-20: RAM where present, ROMs at $8000 / $C000 / $E000, I/O at
   --  $9000-$9FFF, nothing elsewhere (reads give $FF)
   procedure Map_VIC20 is
      procedure Set (From, To : Byte; Read_Off, Write_Off : Integer) is
      begin
         for P in From .. To loop
            Read_Map (P) := (if Read_Off < 0 then Read_Off
                             else Read_Off + Natural (P - From) * 256);
            Write_Map (P) := (if Write_Off < 0 then Write_Off
                              elsif Write_Off = Write_Sink then Write_Sink
                              else Write_Off + Natural (P - From) * 256);
         end loop;
      end Set;
      procedure RAM (From, To : Byte) is
      begin
         Set (From, To, Natural (From) * 256, Natural (From) * 256);
      end RAM;
      procedure None (From, To : Byte) is
      begin
         for P in From .. To loop
            Read_Map (P) := ROM_Empty;
            Write_Map (P) := Write_Sink;
         end loop;
      end None;
   begin
      RAM (16#00#, 16#03#);
      if Has_3K then
         RAM (16#04#, 16#0F#);
      else
         None (16#04#, 16#0F#);
      end if;
      RAM (16#10#, 16#1F#);
      for B in 1 .. 3 loop
         if V20_Cart (B) then
            Set (Byte (B * 16#20#), Byte (B * 16#20# + 16#1F#),
                 V20_Cart_Offset (B), Write_Sink);
         elsif Blocks >= B then
            RAM (Byte (B * 16#20#), Byte (B * 16#20# + 16#1F#));
         else
            None (Byte (B * 16#20#), Byte (B * 16#20# + 16#1F#));
         end if;
      end loop;
      Set (16#80#, 16#8F#, ROM_C64_Char, Write_Sink);
      Set (16#90#, 16#9F#, IO_Page, IO_Page);
      if MC_Present then
         Map_Mega_Cart;
      elsif V20_Cart (5) then
         Set (16#A0#, 16#BF#, V20_Cart_Offset (5), Write_Sink);
      elsif V20_Mem = Plus_35K or else V20_Block5 then
         RAM (16#A0#, 16#BF#);
      else
         None (16#A0#, 16#BF#);
      end if;
      Set (16#C0#, 16#DF#, ROM_C64_Basic, Write_Sink);
      Set (16#E0#, 16#FF#, ROM_C64_Kernal, Write_Sink);
      if Final_Expansion.Present then
         --  every access goes to the cartridge (see Final_Expansion)
         Set (16#04#, 16#0F#, IO_Page, IO_Page);
         Set (16#20#, 16#7F#, IO_Page, IO_Page);
         Set (16#A0#, 16#BF#, IO_Page, IO_Page);
      end if;
      Kernal_High := True;
   end Map_VIC20;

   procedure Map_Mega_Cart is
      BL : constant Byte := (if MC_OE then MC_Bank_Low else 16#7F#);
      BH : constant Byte := (if MC_OE then MC_Bank_High else 16#7F#);
      RAM_Low  : constant Boolean := (BL and 16#80#) /= 0;
      RAM_High : constant Boolean := (BH and 16#80#) /= 0;
      Writable : constant Boolean :=
        (BH and 16#40#) /= 0 and then RAM_Low and then RAM_High;
      Low_ROM  : constant Natural :=
        MC_ROM + Natural (BL and 16#7F#) * 16#2000#;
      High_ROM : constant Natural :=
        MC_ROM + 16#100000# + Natural (BH and 16#7F#) * 16#2000#;
   begin
      --  RAM123 ($0400-$0FFF): NVRAM
      for P in Byte range 16#04# .. 16#0F# loop
         Read_Map (P) := (if MC_NVRAM_En then MC_NVRAM + Natural (P) * 256
                          else ROM_Empty);
         Write_Map (P) := (if MC_NVRAM_En then MC_NVRAM + Natural (P) * 256
                           else Write_Sink);
      end loop;
      --  blocks 1-3: the low ROM bank (the same 8K in all three) or RAM
      for P in Byte range 16#20# .. 16#7F# loop
         Read_Map (P) :=
           (if not RAM_Low then Low_ROM + Natural (P mod 16#20#) * 256
            elsif RAM_High then MC_RAM + Natural (P) * 256
            else ROM_Empty);
         Write_Map (P) := (if Writable then MC_RAM + Natural (P) * 256
                           else Write_Sink);
      end loop;
      --  block 5: the high ROM bank, the low one, or RAM
      for P in Byte range 16#A0# .. 16#BF# loop
         Read_Map (P) :=
           (if not RAM_High then High_ROM + Natural (P - 16#A0#) * 256
            elsif not RAM_Low then Low_ROM + Natural (P - 16#A0#) * 256
            else MC_RAM + Natural (P - 16#A0#) * 256);
         Write_Map (P) :=
           (if Writable then MC_RAM + Natural (P - 16#A0#) * 256
            else Write_Sink);
      end loop;
   end Map_Mega_Cart;


   procedure Rebuild_Map renames Map_VIC20;
   function V20_IO_Read (Addr : Word) return Byte;
   procedure V20_IO_Write (Addr : Word; Value : Byte);
   function IO_Read (Addr : Word) return Byte renames V20_IO_Read;
   procedure IO_Write (Addr : Word; Value : Byte) renames V20_IO_Write;

   ---------------------------------------------------------------------
   --  VIC-20 I/O
   ---------------------------------------------------------------------

   --  The VIC sees CPU $8000-$9FFF at its $0000-$1FFF and CPU $0000-$1FFF
   --  at $2000-$3FFF
   function V20_Fetch (Addr : Word) return Byte is
      A : constant Natural := Natural (Addr and 16#3FFF#);
      CPU_Addr : constant Natural :=
        (if A >= 16#2000# then A - 16#2000# else 16#8000# + A);
   begin
      if CPU_Addr >= 16#8000# then
         return (if CPU_Addr < 16#9000#
                 then Mem (ROM_C64_Char + CPU_Addr - 16#8000#) else 16#FF#);
      elsif CPU_Addr in 16#0400# .. 16#0FFF# then
         if Final_Expansion.Present then
            return Final_Expansion.Peek (Word (CPU_Addr));
         elsif MC_Present then
            return Mem (Read_Map (Byte (CPU_Addr / 256)) + CPU_Addr mod 256);
         elsif not Has_3K then
            return 16#FF#;
         end if;
      end if;
      return Mem (CPU_Addr);
   end V20_Fetch;

   function V20_Color (Index : Natural) return Byte is
     (Color_RAM (Index mod 1024) and 15);

   --  VIC-20 keyboard: VIA2 port B selects columns, port A reads rows.
   --  The keys are the C64's, at other matrix positions.
   C64_Col_Of_Row : constant array (0 .. 7) of Natural := (7, 1, 2, 3, 4, 5, 6, 0);
   C64_Row_Of_Col : constant array (0 .. 7) of Natural := (0, 1, 2, 7, 4, 5, 6, 3);

   function V20_Key (Col, Row : Natural) return Boolean is
     ((Shift_Right (Keyboard.Matrix (C64_Col_Of_Row (Row)),
                    C64_Row_Of_Col (Col)) and 1) /= 0);

   --  The joystick lines; with paddles they carry the paddle buttons
   function V20_Joy return Byte is
     (if Paddles.Active then Paddles.Fire_Bits
      elsif Paddles.Pen_Active then Paddles.Pen_Bits
      else Keyboard.Joy1 or Keyboard.Joy2);

   procedure V20_Inputs is
      Cols : constant Byte := V20_VIA2.ORB or not V20_VIA2.DDRB;
      Rows : Byte := 16#FF#;
      J : constant Byte := V20_Joy;
      PA1 : Byte := 16#FF#;
   begin
      for C in 0 .. 7 loop
         if (Shift_Right (Cols, C) and 1) = 0 then
            for R in 0 .. 7 loop
               if V20_Key (C, R) then
                  Rows := Rows and not Shift_Left (1, R);
               end if;
            end loop;
         end if;
      end loop;
      V20_VIA2.Port_A_In := Rows;
      V20_VIA2.Port_B_In := (if (J and 8) /= 0 then 16#7F# else 16#FF#);
      --  VIA1 port A: serial CLK in (PA0), DATA in (PA1), joystick,
      --  cassette switch
      Sync_Drive;
      if IEC.CLK then
         PA1 := PA1 and not 16#01#;
      end if;
      if IEC.DATA then
         PA1 := PA1 and not 16#02#;
      end if;
      if (J and 1) /= 0 then PA1 := PA1 and not 16#04#; end if;
      if (J and 2) /= 0 then PA1 := PA1 and not 16#08#; end if;
      if (J and 4) /= 0 then PA1 := PA1 and not 16#10#; end if;
      if (J and 16) /= 0 then PA1 := PA1 and not 16#20#; end if;
      if Tape.Present and then Tape.Playing then
         PA1 := PA1 and not 16#40#;
      end if;
      V20_VIA1.Port_A_In := PA1;
   end V20_Inputs;

   --  Serial bus outputs: ATN = VIA1 PA7, CLK = VIA2 CA2, DATA = VIA2 CB2
   --  (all through inverters: high = line pulled low)
   procedure V20_Outputs is
      Old_ATN : constant Boolean := IEC.C64_ATN;
   begin
      IEC.C64_ATN := (VIA.Port_A_Out (V20_VIA1) and 16#80#) /= 0;
      IEC.C64_CLK := VIA.CA2_High (V20_VIA2);
      IEC.C64_DATA := VIA.CB2_High (V20_VIA2);
      Tape.Motor := not VIA.CA2_High (V20_VIA1);
      if IEC.C64_ATN /= Old_ATN and then Drive_On then
         Drive1541.ATN_Changed;
      end if;
   end V20_Outputs;

   function V20_IO_Read (Addr : Word) return Byte is
      R : Byte := 16#FF#;
   begin
      if Final_Expansion.Present and then Final_Expansion.Handles (Addr) then
         return Final_Expansion.Read (Addr, Total_Cycles);
      end if;
      case Addr is
         when 16#9000# .. 16#90FF# =>
            V20.Pot_X := (if Paddles.Active then Paddles.Value (1) else 16#FF#);
            V20.Pot_Y := (if Paddles.Active then Paddles.Value (2) else 16#FF#);
            return V20.Read (Natural (Addr and 15));
         when 16#9100# .. 16#93FF# =>
            V20_Inputs;
            if (Addr and 16#10#) /= 0 then
               R := R and VIA.Read (V20_VIA1, Natural (Addr and 15));
            end if;
            if (Addr and 16#20#) /= 0 then
               R := R and VIA.Read (V20_VIA2, Natural (Addr and 15));
            end if;
            return R;
         when 16#9400# .. 16#97FF# =>
            return (Color_RAM (Natural (Addr - 16#9400#)) and 15) or 16#F0#;
         when 16#9800# .. 16#9FFF# =>
            if MC_Present and then MC_NVRAM_En then
               --  I/O 2 and I/O 3 show NVRAM $1800-$1FFF
               return Mem (MC_NVRAM + 16#1800# + Natural (Addr - 16#9800#));
            end if;
            return 16#FF#;
         when others =>
            return 16#FF#;
      end case;
   end V20_IO_Read;

   procedure V20_IO_Write (Addr : Word; Value : Byte) is
   begin
      if Final_Expansion.Present and then Final_Expansion.Handles (Addr) then
         Final_Expansion.Write (Addr, Value, Total_Cycles);
         return;
      end if;
      case Addr is
         when 16#9000# .. 16#90FF# =>
            V20.Write (Natural (Addr and 15), Value);
         when 16#9100# .. 16#93FF# =>
            Sync_Drive (Write_Delay => 1);
            if (Addr and 16#10#) /= 0 then
               VIA.Write (V20_VIA1, Natural (Addr and 15), Value);
            end if;
            if (Addr and 16#20#) /= 0 then
               VIA.Write (V20_VIA2, Natural (Addr and 15), Value);
            end if;
            V20_Outputs;
         when 16#9400# .. 16#97FF# =>
            Color_RAM (Natural (Addr - 16#9400#)) := Value and 15;
         when 16#9800# .. 16#9FFF# =>
            if MC_Present then
               if MC_NVRAM_En then
                  Mem (MC_NVRAM + 16#1800# + Natural (Addr - 16#9800#)) :=
                    Value;
               end if;
               if Addr >= 16#9C00# then
                  case Addr and 16#180# is
                     when 16#080# => MC_Bank_High := Value;
                     when 16#100# => MC_Bank_Low := Value;
                     when 16#180# =>
                        MC_NVRAM_En := (Value and 1) = 0;
                        MC_Bank_High := Value;
                        MC_Bank_Low := Value;
                     when others => null;
                  end case;
                  if (Addr and 16#200#) /= 0 then
                     MC_Soft_Reset := True;    --  done after the instruction
                  end if;
                  Map_VIC20;
               end if;
            end if;
         when others =>
            null;
      end case;
   end V20_IO_Write;

   ---------------------------------------------------------------------
   --  VIC-20 cartridges: VICE .crt ("VIC20 CARTRIDGE", generic type) and
   --  raw images (with or without load address) placed like VICE does;
   --  split images (name-2000 / -4000 / -6000 / -a000) are joined.
   ---------------------------------------------------------------------

   --  Copy Data to CPU address Addr in the cartridge blocks
   procedure V20_Place (Addr : Natural; Data : Byte_Array; Ok : out Boolean) is
   begin
      Ok := True;
      for I in Data'Range loop
         declare
            A : constant Natural := Addr + (I - Data'First);
            B : constant Natural := A / 16#2000#;
         begin
            if B not in 1 .. 3 | 5 then
               Ok := False;
               Err := To_Unbounded_String
                 ("cartridge data outside $2000-$7FFF / $A000-$BFFF");
               return;
            end if;
            Mem (V20_Cart_Offset (B) + A mod 16#2000#) := Data (I);
            V20_Cart (B) := True;
         end;
      end loop;
   end V20_Place;

   procedure V20_Load_Raw (D : Byte_Array; Ok : out Boolean) is
      Has_Addr : constant Boolean := D'Length mod 16#800# = 2;
      Addr : constant Natural :=
        (if Has_Addr then Natural (D (D'First)) + 256 * Natural (D (D'First + 1))
         else 0);
      Body_D : constant Byte_Array :=
        (if Has_Addr then D (D'First + 2 .. D'Last) else D);
      Len : constant Natural := Body_D'Length;
   begin
      if not Has_Addr and then D'Length mod 16#800# /= 0 then
         Ok := False;
         Err := To_Unbounded_String ("not a VIC-20 cartridge image (size)");
         return;
      end if;
      if Len = 16#8000# then
         V20_Place (16#2000#, Body_D (Body_D'First .. Body_D'First + 16#5FFF#), Ok);
         if Ok then
            V20_Place (16#A000#, Body_D (Body_D'First + 16#6000# .. Body_D'Last), Ok);
         end if;
      elsif Len = 16#4000# and then Addr in 16#2000# | 16#4000# | 16#6000# then
         V20_Place (Addr, Body_D (Body_D'First .. Body_D'First + 16#1FFF#), Ok);
         if Ok then
            V20_Place (16#A000#, Body_D (Body_D'First + 16#2000# .. Body_D'Last), Ok);
         end if;
      elsif Len = 16#2000# then
         V20_Place ((if Addr = 0 then 16#A000# else Addr), Body_D, Ok);
      elsif Len = 16#1000# then
         declare
            A : constant Natural := (if Addr = 0 then 16#A000# else Addr);
         begin
            V20_Place (A, Body_D, Ok);
            if Ok and then A mod 16#2000# = 0 then
               V20_Place (A + 16#1000#, Body_D, Ok);   --  4K mirrored in 8K
            end if;
         end;
      elsif Len = 16#0800# then
         V20_Place ((if Addr = 0 then 16#B000# else Addr), Body_D, Ok);
      else
         Ok := False;
         Err := To_Unbounded_String ("not a VIC-20 cartridge image (size)");
      end if;
   end V20_Load_Raw;

   procedure Attach_Mega_Cart is
   begin
      MC_Present := True;
      MC_OE := False;
      MC_NVRAM_En := True;
      MC_Soft_Reset := False;
      MC_Bank_Low := 0;
      MC_Bank_High := 0;
      Mem (MC_RAM .. MC_RAM + 16#9FFF#) := (others => 16#FF#);
      Machine.Reset;
   end Attach_Mega_Cart;

   procedure V20_Load_CRT (D : Byte_Array; Ok : out Boolean) is
      function BE16 (I : Natural) return Natural is
        (Natural (D (I)) * 256 + Natural (D (I + 1)));
      function BE32 (I : Natural) return Natural is
        (BE16 (I) * 65536 + BE16 (I + 2));
      P : Natural := D'First + BE32 (D'First + 16#10#);
   begin
      Ok := False;
      if BE16 (D'First + 16#16#) = 1 then
         --  Mega-Cart: 256 chips of 8K, low half then high half
         for Chip in 0 .. 255 loop
            exit when P + 15 + 16#2000# > D'Last;
            exit when Character'Val (D (P)) /= 'C';
            Mem (MC_ROM + Chip * 16#2000# ..
                 MC_ROM + Chip * 16#2000# + 16#1FFF#) :=
              D (P + 16 .. P + 15 + 16#2000#);
            P := P + BE32 (P + 4);
         end loop;
         MC_Pending := True;
         Ok := True;
         return;
      elsif BE16 (D'First + 16#16#) = 5 then
         --  Final Expansion: 64 chips of 8K, the flash in order
         declare
            Flash : Byte_Array (0 .. Final_Expansion.Flash_Size - 1) :=
              (others => 16#FF#);
         begin
            for Chip in 0 .. 63 loop
               exit when P + 15 + 16#2000# > D'Last;
               exit when Character'Val (D (P)) /= 'C';
               Flash (Chip * 16#2000# .. Chip * 16#2000# + 16#1FFF#) :=
                 D (P + 16 .. P + 15 + 16#2000#);
               P := P + BE32 (P + 4);
            end loop;
            Final_Expansion.Load (Flash);
         end;
         Final_Expansion.Present := True;
         MC_Pending := True;     --  (attached: nothing to place in blocks)
         Ok := True;
         return;
      end if;
      if BE16 (D'First + 16#16#) /= 0 then
         Err := To_Unbounded_String
           ("only generic VIC-20 cartridges (.crt type 0) are supported");
         return;
      end if;
      while P + 16 <= D'Last loop
         exit when Character'Val (D (P)) /= 'C';
         declare
            Packet : constant Natural := BE32 (P + 4);
            Start  : constant Natural := BE16 (P + 12);
            Len    : constant Natural := BE16 (P + 14);
         begin
            V20_Place (Start, D (P + 16 .. P + 15 + Len), Ok);
            exit when not Ok or else Packet = 0;
            P := P + Packet;
         end;
      end loop;
   end V20_Load_CRT;

   procedure Attach_Cartridge (Path : String; Ok : out Boolean) is
      D : constant Byte_Array := Read_All (Path, Ok);
      Lower : constant String := Ada.Characters.Handling.To_Lower (Path);
      Suffixes : constant array (1 .. 4) of String (1 .. 5) :=
        ("-2000", "-4000", "-6000", "-a000");
   begin
      if not Ok then
         Err := To_Unbounded_String ("cannot read " & Path);
         return;
      end if;
      V20_Cart := (others => False);
      MC_Present := False;
      Final_Expansion.Present := False;
      if D'Length = 16#80000# then
         --  a raw 512K image is a Final Expansion flash image
         Final_Expansion.Load (D);
         Final_Expansion.Present := True;
         V20_Cart_Name :=
           To_Unbounded_String (Ada.Directories.Simple_Name (Path));
         Machine.Reset;
         return;
      end if;
      if D'Length = 16#200000# then
         --  a raw 2 MB image is a Mega-Cart
         Mem (MC_ROM .. MC_ROM + 16#1FFFFF#) := D;
         V20_Cart_Name :=
           To_Unbounded_String (Ada.Directories.Simple_Name (Path));
         Attach_Mega_Cart;
         return;
      end if;
      for B in 1 .. 5 loop
         Mem (V20_Cart_Offset (B) .. V20_Cart_Offset (B) + 16#1FFF#) :=
           (others => 16#FF#);
      end loop;
      if D'Length > 64 and then Character'Val (D (D'First)) = 'V'
        and then Character'Val (D (D'First + 3)) = '2'
      then
         MC_Pending := False;
         V20_Load_CRT (D, Ok);
         if Ok and then MC_Pending then
            V20_Cart_Name :=
              To_Unbounded_String (Ada.Directories.Simple_Name (Path));
            if Final_Expansion.Present then
               Machine.Reset;
            else
               Attach_Mega_Cart;
            end if;
            return;
         end if;
      else
         V20_Load_Raw (D, Ok);
         --  the other parts of a split image
         for S of Suffixes loop
            declare
               I : constant Natural := Ada.Strings.Fixed.Index (Lower, S);
            begin
               if Ok and then I > 0 then
                  for T of Suffixes loop
                     if T /= S then
                        declare
                           Other : String := Path;
                           Part_Ok : Boolean;
                        begin
                           Other (I .. I + 4) := T;
                           if not Ada.Directories.Exists (Other) then
                              Other (I + 1 .. I + 4) :=
                                Ada.Characters.Handling.To_Upper (T (2 .. 5));
                           end if;
                           if Ada.Directories.Exists (Other) then
                              V20_Load_Raw (Read_All (Other, Part_Ok), Part_Ok);
                           end if;
                        end;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end if;
      if Ok then
         V20_Cart_Name := To_Unbounded_String (Ada.Directories.Simple_Name (Path));
         Machine.Reset;         --  the KERNAL starts it (A0CBM at $A004)
      else
         V20_Cart := (others => False);
      end if;
   end Attach_Cartridge;

   procedure Detach_Cartridge is
   begin
      MC_Present := False;
      Final_Expansion.Present := False;
      V20_Cart := (others => False);
      V20_Cart_Name := Null_Unbounded_String;
   end Detach_Cartridge;

   function Cartridge_Name return String is (To_String (V20_Cart_Name));

   --  Raw cartridge images (.bin .rom .a0), split images, and .prg files
   --  loading at $A000 / $B000
   type String_Array is array (Positive range <>) of String (1 .. 5);

   function Is_Cartridge (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
      function Ends (E : String) return Boolean is
        (L'Length > E'Length and then L (L'Last - E'Length + 1 .. L'Last) = E);
      Ok : Boolean;
   begin
      if Ends (".bin") or else Ends (".rom") or else Ends (".a0") then
         return True;
      end if;
      for S of String_Array'("-2000", "-4000", "-6000", "-a000") loop
         if Ada.Strings.Fixed.Index (L, S) > 0 then
            return True;
         end if;
      end loop;
      if Ends (".prg") then
         declare
            D : constant Byte_Array := Read_All (Path, Ok);
         begin
            return Ok and then D'Length > 2 and then D (D'First) = 0
              and then (D (D'First + 1) in 16#A0# | 16#B0#
                        or else (D'Length - 2 in 16#4000# | 16#8000#
                                 and then D (D'First + 1)
                                   in 16#20# | 16#40# | 16#60#));
         end;
      end if;
      return False;
   end Is_Cartridge;

   VIC20_ROM_Dir : Unbounded_String;

   --  VIC-20 ROMs: roms/vic20 (zimmers.net names) next to the program or
   --  in the current directory, or <roms>/VIC20 (VICE names)
   function Find_VIC20_ROM (Names : String) return String is
      Exe_Dir : constant String :=
        Ada.Directories.Containing_Directory
          (Ada.Directories.Containing_Directory
             (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)));
      Dirs : constant array (1 .. 3) of Unbounded_String :=
        (To_Unbounded_String (Exe_Dir & "/roms/vic20"),
         To_Unbounded_String ("roms/vic20"),
         VIC20_ROM_Dir & "/VIC20");
      From : Positive := Names'First;
   begin
      for D of Dirs loop
         From := Names'First;
         for I in Names'Range loop
            if Names (I) = ' ' or else I = Names'Last then
               declare
                  N : constant String :=
                    Names (From .. (if Names (I) = ' ' then I - 1 else I));
                  P : constant String := To_String (D) & "/" & N;
               begin
                  if Ada.Directories.Exists (P) then
                     return P;
                  end if;
               end;
               From := I + 1;
            end if;
         end loop;
      end loop;
      return "";
   exception
      when others =>
         return "";
   end Find_VIC20_ROM;

   procedure Load_VIC20_Kernal (Ok : out Boolean) is
      P : constant String :=
        Find_VIC20_ROM (if Standard = PAL
                        then "kernal.901486-07.bin kernal-901486-07.bin"
                        else "kernal.901486-06.bin kernal-901486-06.bin");
   begin
      Ok := P /= "";
      if Ok then
         Load_ROM (P, ROM_C64_Kernal, 8192, Ok => Ok);   --  (in out)
      else
         Err := To_Unbounded_String
           ("VIC-20 KERNAL ROM not found (" &
            (if Standard = PAL then "kernal.901486-07.bin"
             else "kernal.901486-06.bin") &
            " in roms/vic20, see the README)");
      end if;
   end Load_VIC20_Kernal;

   procedure Load_VIC20_ROMs (ROM_Dir : String; Ok : out Boolean) is
      Basic_P : constant String :=
        Find_VIC20_ROM ("basic.901486-01.bin basic-901486-01.bin");
      Char_P : constant String :=
        Find_VIC20_ROM ("characters.901460-03.bin chargen-901460-03.bin "
                        & "chargen");
   begin
      VIC20_ROM_Dir := To_Unbounded_String (ROM_Dir);
      if Basic_P = "" or else Char_P = "" then
         Ok := False;
         Err := To_Unbounded_String
           ("VIC-20 ROMs not found: basic.901486-01.bin and " &
            "characters.901460-03.bin go into roms/vic20 (see the README)");
         return;
      end if;
      Ok := True;                          --  Load_ROM only clears it
      Load_ROM (Basic_P, ROM_C64_Basic, 8192, Ok => Ok);
      if Ok then
         Load_ROM (Char_P, ROM_C64_Char, 4096, Ok => Ok);
      end if;
      if Ok then
         Load_VIC20_Kernal (Ok);
      end if;
   end Load_VIC20_ROMs;

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean) is
   begin
      Load_VIC20_ROMs (ROM_Dir, Ok);
   end Load_ROMs;

   procedure Set_Memory (M : VIC20_Memory) is
   begin
      V20_Mem := M;
   end Set_Memory;

   function Memory return VIC20_Memory is (V20_Mem);

   procedure Choose_Memory (Load_Address : Word) is
   begin
      --  Pick the RAM expansion the program was made for
      V20_Block5 := False;
      case Load_Address is
         when 16#1001# => V20_Mem := Unexpanded;
         when 16#0401# => V20_Mem := Plus_3K;
         when 16#1201# =>
            if Blocks = 0 then
               V20_Mem := Plus_24K;
            end if;
         when 16#A000# =>
            V20_Mem := Unexpanded;
            V20_Block5 := True;        --  cartridge image in RAM
         when 16#2000# .. 16#7FFF# =>
            --  machine code loading into the expansion blocks
            declare
               Need : constant Positive :=
                 Natural (Load_Address) / 16#2000#;
            begin
               if Blocks < Need then
                  V20_Mem := (case Need is
                                when 1 => Plus_8K, when 2 => Plus_16K,
                                when others => Plus_24K);
               end if;
            end;
         when others => null;
      end case;
   end Choose_Memory;

   procedure Set_Standard (V : Video_Standard) is
   begin
      V20.Set_Standard (if V = PAL then V20.PAL else V20.NTSC);
      Drive1541.Set_Host_Clock (V20.Clock_Hz);
      SID.Set_Clock (V20.Clock_Hz);
      if Length (VIC20_ROM_Dir) > 0 then
         declare
            Dummy : Boolean;
         begin
            Load_VIC20_Kernal (Dummy);   --  6560 / 6561 KERNAL
         end;
      end if;
   end Set_Standard;

   function Frame_Rate return Float is
     (Float (V20.Clock_Hz) / Float (V20.Cycles_Per_Line * V20.Lines_Per_Frame));

   procedure Reset (Hard : Boolean) is
   begin
   VIA.Reset (V20_VIA1);
   VIA.Reset (V20_VIA2);
   V20.Reset;
   if Final_Expansion.Present then
      if Hard then
         Final_Expansion.Power_Up;
      else
         Final_Expansion.Reset;
      end if;
   end if;
   if MC_Present then
      --  power-up / reset button: OE off; a software reset ($9E00)
      --  toggles it, which switches the bank registers in or out
      if MC_Soft_Reset then
         MC_OE := not MC_OE;
      else
         MC_OE := False;
         if Hard then
            MC_NVRAM_En := True;
         end if;
      end if;
      MC_Soft_Reset := False;
   end if;
   end Reset;

   procedure Clock (N : Natural) is
      Pulses : Natural;
   begin
      if Tape.Present then
         Tape.Tick (N, Pulses);
         for P in 1 .. Pulses loop        --  read pulse on VIA2 CA1
            VIA.Set_CA1 (V20_VIA2, False);
            VIA.Set_CA1 (V20_VIA2, True);
         end loop;
      end if;
      VIA.Tick (V20_VIA1, N);
      VIA.Tick (V20_VIA2, N);
      V20.Tick (N);
   end Clock;

   procedure Interrupt_Lines (IRQ, NMI : out Boolean) is
   begin
      --  RESTORE goes to VIA1 CA1; VIA1 drives NMI, VIA2 IRQ
      VIA.Set_CA1 (V20_VIA1, not Keyboard.Restore_Down);
      IRQ := VIA.IRQ (V20_VIA2);
      NMI := VIA.IRQ (V20_VIA1);
   end Interrupt_Lines;

   function Soft_Reset_Pending return Boolean is (MC_Soft_Reset);

   function Frame_Done return Boolean is (V20.Frame_Done);

   procedure Clear_Frame is
   begin
      V20.Frame_Done := False;
   end Clear_Frame;

   procedure End_Of_Frame is
   begin
      V20.Set_Light_Pen (Paddles.Pen_X, Paddles.Pen_Y,
                         Paddles.Pen_Active and then Paddles.Pen_Down);
   end End_Of_Frame;

   procedure Poke (Addr : Word; Value : Byte) is
      W : constant Integer := Write_Map (Hi (Addr));
   begin
      --  through the cartridge's banking (loads into its RAM)
      if Addr < 16#9000# and then Final_Expansion.Present
        and then Final_Expansion.Handles (Addr)
      then
         Final_Expansion.Write (Addr, Value, Total_Cycles);
      elsif W >= 0 then
         Mem (W + Natural (Addr and 16#FF#)) := Value;
      end if;
   end Poke;

   function Screen_Byte (I : Natural) return Byte is
     (Mem (Natural (Mem (16#0288#)) * 256 + I));

   function Beam_Text return String is
     ("  raster" & V20.Raster'Image);

   function V20_VIA_Peek (V : VIA.Chip; Reg : Natural) return Byte is
     (case Reg is
        when 0 => V.ORB, when 1 | 15 => V.ORA, when 2 => V.DDRB,
        when 3 => V.DDRA, when 4 => Byte (V.T1_Counter mod 256),
        when 5 => Byte ((V.T1_Counter / 256) mod 256),
        when 6 => Byte (V.T1_Latch mod 256),
        when 7 => Byte ((V.T1_Latch / 256) mod 256),
        when 8 => Byte (V.T2_Counter mod 256),
        when 9 => Byte ((V.T2_Counter / 256) mod 256),
        when 10 => V.SR, when 11 => V.ACR, when 12 => V.PCR,
        when 13 => V.IFR or (if VIA.IRQ (V) then 16#80# else 0),
        when others => V.IER or 16#80#);

   function IO_Peek (Addr : Word) return Byte is
   begin
      if Final_Expansion.Present and then Final_Expansion.Handles (Addr) then
         return Final_Expansion.Peek (Addr);
      end if;
      case Addr is
         when 16#9000# .. 16#90FF# =>
            return (if (Addr and 15) in 3 | 4 then V20.Read (Natural (Addr and 15))
                    elsif (Addr and 15) = 8
                    then (if Paddles.Active then Paddles.Value (1) else 16#FF#)
                    elsif (Addr and 15) = 9
                    then (if Paddles.Active then Paddles.Value (2) else 16#FF#)
                    else V20.Register (Natural (Addr and 15)));
         when 16#9100# .. 16#93FF# =>
            return (if (Addr and 16#10#) /= 0
                    then V20_VIA_Peek (V20_VIA1, Natural (Addr and 15))
                    elsif (Addr and 16#20#) /= 0
                    then V20_VIA_Peek (V20_VIA2, Natural (Addr and 15))
                    else 16#FF#);
         when 16#9400# .. 16#97FF# =>
            return (Color_RAM (Natural (Addr - 16#9400#)) and 15) or 16#F0#;
         when others =>
            return 16#FF#;
      end case;
   end IO_Peek;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      VIA.Chip'Write (S, V20_VIA1);
      VIA.Chip'Write (S, V20_VIA2);
      V20.Save_State (S);
      VIC20_Memory'Write (S, V20_Mem);
      Boolean'Write (S, V20_Block5);
      V20_Block_Set'Write (S, V20_Cart);
      String'Output (S, To_String (V20_Cart_Name));
      Boolean'Write (S, MC_Present);
      Byte'Write (S, MC_Bank_Low);
      Byte'Write (S, MC_Bank_High);
      Boolean'Write (S, MC_OE);
      Boolean'Write (S, MC_NVRAM_En);
      Final_Expansion.Save_State (S);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      VIA.Chip'Read (S, V20_VIA1);
      VIA.Chip'Read (S, V20_VIA2);
      V20.Load_State (S);
      VIC20_Memory'Read (S, V20_Mem);
      Boolean'Read (S, V20_Block5);
      V20_Block_Set'Read (S, V20_Cart);
      V20_Cart_Name := To_Unbounded_String (String'Input (S));
      Boolean'Read (S, MC_Present);
      Byte'Read (S, MC_Bank_Low);
      Byte'Read (S, MC_Bank_High);
      Boolean'Read (S, MC_OE);
      Boolean'Read (S, MC_NVRAM_En);
      MC_Soft_Reset := False;
      Final_Expansion.Load_State (S);
      Drive1541.Set_Host_Clock (V20.Clock_Hz);
   end Load_State;

end Machine.VIC20_System;
