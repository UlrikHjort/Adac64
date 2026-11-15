-- ***************************************************************************
--                      AdaC64 - Machine.Plus4_System
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
with Ada.Directories;
with Ada.Command_Line;
with Interfaces; use Interfaces;
with TED;
with Keyboard;
with Tape;
with Drive1541;
with IEC;
with SID;
with Machine.Core; use Machine.Core;

package body Machine.Plus4_System is

   --  ROM images (16K each) in the ROM area of Mem; cartridges C1 / C2
   --  (low and high halves) in the cartridge area
   P4_Basic  : constant := ROM_C64_Basic;          --  $20000
   P4_Kernal : constant := ROM_C64_Basic + 16#4000#;
   P4_FLo    : constant := ROM_C64_Basic + 16#8000#;   --  3-plus-1
   P4_FHi    : constant := ROM_C64_Basic + 16#C000#;

   Lo_Banks : constant array (0 .. 3) of Natural :=
     (P4_Basic, P4_FLo, Cart_Base, Cart_Base + 16#8000#);
   Hi_Banks : constant array (0 .. 3) of Natural :=
     (P4_Kernal, P4_FHi, Cart_Base + 16#4000#, Cart_Base + 16#C000#);

   ROM_Cfg   : Natural := 0;       --  $FDD0 + n: bits 0-1 low, 2-3 high
   Port_DDR, Port_Data, Port_Out : Byte := 0;
   PIO1      : Byte := 16#FF#;     --  6529 at $FD10 (user port)
   PIO2      : Byte := 16#FF#;     --  6529 at $FD30 (keyboard columns)
   Kbd_Latch : Byte := 16#FF#;     --  $FF08
   ACIA_Regs : array (0 .. 3) of Byte := (others => 0);

   function RAM_Pages return Positive is
     (if Current_Model = C16 then 16#40# else 16#100#);

   function RAM_Read (Addr : Word) return Byte is
     (Mem (Natural (Addr) mod (RAM_Pages * 256)));

   procedure Poke (Addr : Word; Value : Byte) is
   begin
      Mem (Natural (Addr) mod (RAM_Pages * 256)) := Value;
   end Poke;

   function ROM_Byte (Addr : Word) return Byte is
     (if Addr < 16#C000#
      then Mem (Lo_Banks (ROM_Cfg mod 4) + Natural (Addr - 16#8000#))
      else Mem (Hi_Banks (ROM_Cfg / 4) + Natural (Addr - 16#C000#)));

   function ROM_Peek (Addr : Word) return Byte is (ROM_Byte (Addr));

   --  The TED's memory: RAM, or ROM (as banked for the CPU) when it fetches
   --  from ROM in the upper half
   function TED_Fetch (Addr : Word; ROM : Boolean) return Byte is
     (if ROM and then Addr >= 16#8000# then ROM_Byte (Addr)
      else RAM_Read (Addr));

   package T is new TED (Fetch => TED_Fetch);

   function Clock_Hz return Natural is (T.Clock_Hz);

   ---------------------------------------------------------------------
   --  Memory map
   ---------------------------------------------------------------------

   procedure Rebuild_Map is
      Pages : constant Positive := RAM_Pages;
   begin
      for P in Byte loop
         Read_Map (P) := (Natural (P) mod Pages) * 256;
         Write_Map (P) := Read_Map (P);
      end loop;
      if T.ROM_Enabled then
         for P in Byte range 16#80# .. 16#BF# loop
            Read_Map (P) := Lo_Banks (ROM_Cfg mod 4) + Natural (P - 16#80#) * 256;
         end loop;
         for P in Byte range 16#C0# .. 16#FF# loop
            Read_Map (P) := Hi_Banks (ROM_Cfg / 4) + Natural (P - 16#C0#) * 256;
         end loop;
         --  $FC00-$FCFF is always the KERNAL's (bank switching code)
         Read_Map (16#FC#) := P4_Kernal + 16#3C00#;
      end if;
      for P in Byte range 16#FD# .. 16#FF# loop
         Read_Map (P) := IO_Page;
         Write_Map (P) := IO_Page;
      end loop;
      Kernal_High := T.ROM_Enabled and then ROM_Cfg / 4 = 0;
   end Rebuild_Map;

   ---------------------------------------------------------------------
   --  CPU port: serial bus (DATA / CLK / ATN out on bits 0-2, CLK / DATA
   --  in on bits 6 / 7), cassette motor (bit 3) and read (bit 4)
   ---------------------------------------------------------------------

   procedure Update_Port is
      Old_ATN : constant Boolean := IEC.C64_ATN;
   begin
      Port_Out := (Port_Out and not Port_DDR) or (Port_Data and Port_DDR);
      IEC.C64_DATA := (Port_Out and 1) /= 0;
      IEC.C64_CLK := (Port_Out and 2) /= 0;
      IEC.C64_ATN := (Port_Out and 4) /= 0;
      Tape.Motor := (Port_DDR and Port_Data and 8) = 0;
      if IEC.C64_ATN /= Old_ATN and then Drive_On then
         Drive1541.ATN_Changed;
      end if;
   end Update_Port;

   function Port_Read (Addr : Word) return Byte is
      --  cassette lines: write (bit 1) and motor sense (bit 3) idle high,
      --  the read line (bit 4) from the tape
      Input : Byte :=
        16#0A# or (if not Tape.Is_C16 or else Tape.Level then 16#10# else 0);
   begin
      if Addr = 0 then
         return Port_DDR;
      end if;
      Sync_Drive;
      if not IEC.DATA then
         Input := Input or 16#80#;
      end if;
      if not IEC.CLK then
         Input := Input or 16#40#;
      end if;
      return ((Input and not Port_DDR) or (Port_Out and Port_DDR)) and 16#DF#;
   end Port_Read;

   procedure Port_Write (Addr : Word; Value : Byte) is
   begin
      Sync_Drive (Write_Delay => 1);
      if Addr = 0 then
         Port_DDR := Value and 16#DF#;
      else
         Port_Data := Value;
      end if;
      Mem (Natural (Addr)) := Value;        --  also written to RAM
      Update_Port;
   end Port_Write;

   ---------------------------------------------------------------------
   --  I/O ($FD00-$FFFF)
   ---------------------------------------------------------------------

   --  $FF08: the keyboard rows of the columns selected in PIO2, and the
   --  joysticks selected by the value written (bit 2: port 1, bit 1: 2)
   procedure Latch_Keyboard (Value : Byte) is
      Rows : Byte := 16#FF#;
      J1 : constant Byte := Keyboard.Joy1;
      J2 : constant Byte := Keyboard.Joy2;
   begin
      for C in 0 .. 7 loop
         if (Shift_Right (PIO2, C) and 1) = 0 then
            Rows := Rows and not Keyboard.Matrix (C);
         end if;
      end loop;
      if (Value and 4) = 0 then
         Rows := Rows and not (J1 and 15);
         if (J1 and 16) /= 0 then
            Rows := Rows and not 16#40#;
         end if;
      end if;
      if (Value and 2) = 0 then
         Rows := Rows and not (J2 and 15);
         if (J2 and 16) /= 0 then
            Rows := Rows and not 16#80#;
         end if;
      end if;
      Kbd_Latch := Rows;
   end Latch_Keyboard;

   function IO_Peek (Addr : Word) return Byte is
   begin
      case Addr is
         when 16#FD00# .. 16#FD0F# =>
            if Current_Model = C16 then
               return 16#FF#;
            end if;
            return (if Addr mod 4 = 1 then ACIA_Regs (1) or 16#10#
                    else ACIA_Regs (Natural (Addr mod 4)));
         when 16#FD10# .. 16#FD1F# =>
            return (if Tape.Playing then PIO1 and not 4 else PIO1);
         when 16#FD30# .. 16#FD3F# => return PIO2;
         when 16#FEC0# .. 16#FEFF# => return 0;     --  no 1551 drive
         when 16#FF08# => return Kbd_Latch;
         when 16#FF00# .. 16#FF07# | 16#FF09# .. 16#FF1F# =>
            return T.Register (Natural (Addr - 16#FF00#));
         when 16#FF20# .. 16#FFFF# =>
            if T.ROM_Enabled then
               return ROM_Byte (Addr);
            elsif Addr in 16#FF3E# .. 16#FF3F# then
               return 16#FF#;
            end if;
            return RAM_Read (Addr);
         when others => return 16#FF#;
      end case;
   end IO_Peek;

   function IO_Read (Addr : Word) return Byte is
   begin
      if Addr in 16#FF00# .. 16#FF07# | 16#FF09# .. 16#FF1F# then
         return T.Read (Natural (Addr - 16#FF00#));
      end if;
      return IO_Peek (Addr);
   end IO_Read;

   procedure IO_Write (Addr : Word; Value : Byte) is
   begin
      case Addr is
         when 16#FD00# .. 16#FD0F# =>
            ACIA_Regs (Natural (Addr mod 4)) := Value;
         when 16#FD10# .. 16#FD1F# => PIO1 := Value;
         when 16#FD30# .. 16#FD3F# => PIO2 := Value;
         when 16#FDD0# .. 16#FDDF# =>
            ROM_Cfg := Natural (Addr and 15);
            Rebuild_Map;
         when 16#FF08# => Latch_Keyboard (Value);
         when 16#FF00# .. 16#FF07# | 16#FF09# .. 16#FF1F# =>
            T.Write (Natural (Addr - 16#FF00#), Value);
         when 16#FF3E# =>
            T.ROM_Enabled := True;
            Rebuild_Map;
         when 16#FF3F# =>
            T.ROM_Enabled := False;
            Rebuild_Map;
         when 16#FF20# .. 16#FF3D# | 16#FF40# .. 16#FFFF# =>
            Poke (Addr, Value);
         when others => null;
      end case;
   end IO_Write;

   ---------------------------------------------------------------------
   --  Time
   ---------------------------------------------------------------------

   procedure Clock (N : Natural) is
   begin
      for I in 1 .. N loop
         T.Tick;
      end loop;
      if Tape.Present then
         Tape.Tick_Level (N);
      end if;
   end Clock;

   procedure Run_CPU (K : Natural) is
   begin
      for I in 1 .. K loop
         while T.CPU_Blocked loop
            Clock_Devices (1);
         end loop;
         Clock_Devices (1);
      end loop;
   end Run_CPU;

   procedure Wait_Free is
   begin
      while T.CPU_Blocked loop
         Clock_Devices (1);
      end loop;
   end Wait_Free;

   procedure Interrupt_Lines (IRQ, NMI : out Boolean) is
   begin
      IRQ := T.IRQ;
      NMI := False;
   end Interrupt_Lines;

   function Frame_Done return Boolean is (T.Frame_Done);

   procedure Clear_Frame is
   begin
      T.Frame_Done := False;
   end Clear_Frame;

   procedure End_Of_Frame is null;

   function Frame_Rate return Float is
     (Float (T.Clock_Hz) / Float (T.Cycles_Per_Line * T.Lines_Per_Frame));

   ---------------------------------------------------------------------
   --  Cartridges: C1 low / high at Cart_Base, C2 low / high after them
   ---------------------------------------------------------------------

   Cart_Name : Unbounded_String;

   --  Copy Data into a 16K cartridge ROM (Slot 0 .. 3 = C1 low, C1 high,
   --  C2 low, C2 high); smaller chips repeat to fill it
   procedure Place (Slot : Natural; Data : Byte_Array) is
      Base : constant Natural := Cart_Base + Slot * 16#4000#;
   begin
      for I in 0 .. 16#3FFF# loop
         Mem (Base + I) := Data (Data'First + I mod Data'Length);
      end loop;
   end Place;

   procedure Attach_Cartridge (Path : String; Ok : out Boolean) is
      D : constant Byte_Array := Read_All (Path, Ok);
      function BE16 (I : Natural) return Natural is
        (Natural (D (I)) * 256 + Natural (D (I + 1)));
      function BE32 (I : Natural) return Natural is
        (BE16 (I) * 65536 + BE16 (I + 2));
      Sig : constant String := "PLUS4 CARTRIDGE ";
      Is_CRT : Boolean := D'Length > 64;
   begin
      if not Ok then
         Err := To_Unbounded_String ("cannot read " & Path);
         return;
      end if;
      Mem (Cart_Base .. Cart_Base + 16#FFFF#) := (others => 16#FF#);
      for I in Sig'Range loop
         Is_CRT := Is_CRT
           and then D (D'First + I - 1) = Character'Pos (Sig (I));
      end loop;
      if Is_CRT then
         if BE16 (D'First + 16#16#) /= 0 then
            Ok := False;
            Err := To_Unbounded_String
              ("only generic Plus/4 cartridges (.crt type 0) are supported");
            return;
         end if;
         declare
            P : Natural := D'First + BE32 (D'First + 16#10#);
         begin
            while P + 16 <= D'Last
              and then Character'Val (D (P)) = 'C'
            loop
               declare
                  Packet : constant Natural := BE32 (P + 4);
                  Bank   : constant Natural := BE16 (P + 10);
                  Start  : constant Natural := BE16 (P + 12);
                  Len    : constant Natural := BE16 (P + 14);
               begin
                  if Bank > 1 or else Start not in 16#8000# | 16#C000#
                    or else Len not in 16#1000# | 16#2000# | 16#4000#
                    or else P + 15 + Len > D'Last
                  then
                     Ok := False;
                     Err := To_Unbounded_String
                       ("unexpected chip in the cartridge file");
                     return;
                  end if;
                  Place (Bank * 2 + (if Start = 16#C000# then 1 else 0),
                         D (P + 16 .. P + 15 + Len));
                  exit when Packet = 0;
                  P := P + Packet;
               end;
            end loop;
         end;
      elsif D'Length in 16#1000# | 16#2000# | 16#4000# then
         Place (0, D);
      elsif D'Length = 16#8000# then
         Place (0, D (D'First .. D'First + 16#3FFF#));
         Place (1, D (D'First + 16#4000# .. D'Last));
      else
         Ok := False;
         Err := To_Unbounded_String ("not a Plus/4 cartridge image (size)");
         return;
      end if;
      Cart_Name := To_Unbounded_String (Ada.Directories.Simple_Name (Path));
      Machine.Reset;          --  the KERNAL starts it ("CBM" at $8007)
   end Attach_Cartridge;

   procedure Detach_Cartridge is
   begin
      Mem (Cart_Base .. Cart_Base + 16#FFFF#) := (others => 16#FF#);
      Cart_Name := Null_Unbounded_String;
   end Detach_Cartridge;

   function Cartridge_Name return String is (To_String (Cart_Name));

   function Screen_Byte (I : Natural) return Byte is
     (RAM_Read (Word ((Natural (T.Matrix_Base) + 16#400# + I) mod 65536)));

   function Beam_Text return String is
     ("  raster" & T.Raster'Image & " cycle" & T.Line_Cycle'Image);

   ---------------------------------------------------------------------
   --  ROMs and reset
   ---------------------------------------------------------------------

   ROM_Root : Unbounded_String;

   --  roms/plus4 next to the program or in the current directory, or
   --  <roms>/PLUS4 (VICE's directory)
   function Find_ROM (Names : String) return String is
      Exe_Dir : constant String :=
        Ada.Directories.Containing_Directory
          (Ada.Directories.Containing_Directory
             (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)));
      Dirs : constant array (1 .. 3) of Unbounded_String :=
        (To_Unbounded_String (Exe_Dir & "/roms/plus4"),
         To_Unbounded_String ("roms/plus4"),
         ROM_Root & "/PLUS4");
      From : Positive;
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
   end Find_ROM;

   procedure Load_Kernal (Ok : in out Boolean) is
      P : constant String :=
        Find_ROM (if Current_Standard = PAL
                  then "kernal-318004-05.bin kernal.318004-05.bin"
                  else "kernal-318005-05.bin kernal.318005-05.bin");
   begin
      if P = "" then
         Ok := False;
         Append (Err, "Plus/4 KERNAL ROM not found (" &
                   (if Current_Standard = PAL then "kernal-318004-05.bin"
                    else "kernal-318005-05.bin") &
                   " in roms/plus4, see the README)" & ASCII.LF);
      else
         Load_ROM (P, P4_Kernal, 16#4000#, Ok => Ok);
      end if;
   end Load_Kernal;

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean) is
      Basic : constant String :=
        Find_ROM ("basic-318006-01.bin basic.318006-01.bin");
      Lo : constant String :=
        Find_ROM ("3plus1-317053-01.bin 3plus1low.317053-01.bin");
      Hi : constant String :=
        Find_ROM ("3plus1-317054-01.bin 3plus1high.317054-01.bin");
   begin
      ROM_Root := To_Unbounded_String (ROM_Dir);
      Mem (P4_Basic .. P4_FHi + 16#3FFF#) := (others => 16#FF#);
      if Length (Cart_Name) = 0 then
         Mem (Cart_Base .. Cart_Base + 16#FFFF#) := (others => 16#FF#);
      end if;
      if Basic = "" then
         Ok := False;
         Append (Err, "Plus/4 BASIC ROM not found (basic-318006-01.bin in " &
                   "roms/plus4, see the README)" & ASCII.LF);
      else
         Load_ROM (Basic, P4_Basic, 16#4000#, Ok => Ok);
      end if;
      Load_Kernal (Ok);
      if Current_Model = Plus4 and then Lo /= "" and then Hi /= "" then
         Load_ROM (Lo, P4_FLo, 16#4000#, Ok => Ok);
         Load_ROM (Hi, P4_FHi, 16#4000#, Ok => Ok);
      end if;
   end Load_ROMs;

   procedure Set_Standard (V : Video_Standard) is
      Dummy : Boolean := True;
   begin
      T.Set_Standard (if V = PAL then T.PAL else T.NTSC);
      Drive1541.Set_Host_Clock (T.Clock_Hz);
      SID.Set_Clock (T.Clock_Hz);
      if Length (ROM_Root) > 0 then
         Load_Kernal (Dummy);             --  PAL / NTSC KERNAL
      end if;
   end Set_Standard;

   procedure Reset (Hard : Boolean) is
      pragma Unreferenced (Hard);
   begin
      ROM_Cfg := 0;
      Port_DDR := 0;
      Port_Data := 0;
      Port_Out := 0;
      PIO1 := 16#FF#;
      PIO2 := 16#FF#;
      Kbd_Latch := 16#FF#;
      ACIA_Regs := (others => 0);
      T.ROM_Enabled := True;
      T.Reset;
      Update_Port;
   end Reset;

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Natural'Write (S, ROM_Cfg);
      Byte'Write (S, Port_DDR); Byte'Write (S, Port_Data);
      Byte'Write (S, Port_Out);
      Byte'Write (S, PIO1); Byte'Write (S, PIO2); Byte'Write (S, Kbd_Latch);
      for A of ACIA_Regs loop
         Byte'Write (S, A);
      end loop;
      T.Save_State (S);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Natural'Read (S, ROM_Cfg);
      Byte'Read (S, Port_DDR); Byte'Read (S, Port_Data);
      Byte'Read (S, Port_Out);
      Byte'Read (S, PIO1); Byte'Read (S, PIO2); Byte'Read (S, Kbd_Latch);
      for A of ACIA_Regs loop
         Byte'Read (S, A);
      end loop;
      T.Load_State (S);
      Drive1541.Set_Host_Clock (T.Clock_Hz);
   end Load_State;

end Machine.Plus4_System;
