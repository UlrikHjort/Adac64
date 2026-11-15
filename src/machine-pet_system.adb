-- ***************************************************************************
--                      AdaC64 - Machine.PET_System
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
with PIA;
with VIA;
with IEEE_Drive;
with Keyboard;
with Video;
with SID; use type SID.Sink_Proc;
with Machine.Core; use Machine.Core;

package body Machine.PET_System is

   PET_Basic  : constant := ROM_C64_Basic;              --  12K, $B000
   PET_Editor : constant := ROM_C64_Basic + 16#3000#;   --  2K,  $E000
   PET_Kernal : constant := ROM_C64_Basic + 16#3800#;   --  4K,  $F000
   PET_Chars  : constant := ROM_C64_Basic + 16#4800#;   --  2K (two sets)

   PIA1, PIA2 : PIA.Chip;
   V : VIA.Chip;
   CRTC_Index : Natural := 0;
   CRTC : array (0 .. 31) of Byte := (others => 0);
   Pattern : Byte := 0;            --  the sound's shift register bits

   Line   : Natural := 0;          --  raster line in the frame
   Line_Cycle : Natural := 0;
   Done   : Boolean := False;

   function Bit (B : Byte; N : Natural) return Boolean is
     ((Shift_Right (B, N) and 1) /= 0);

   ---------------------------------------------------------------------
   --  CRTC timing (40 columns: one character per microsecond)
   ---------------------------------------------------------------------

   function Cycles_Per_Line return Positive is
     (if CRTC (0) = 0 then 64 else Natural (CRTC (0)) + 1);
   function Scan_Lines return Positive is (Natural (CRTC (9) and 31) + 1);
   function Lines_Per_Frame return Positive is
     (if CRTC (4) = 0
      then (if Current_Standard = PAL then 312 else 262)
      else (Natural (CRTC (4) and 127) + 1) * Scan_Lines
           + Natural (CRTC (5) and 31));
   function Rows return Natural is (Natural (CRTC (6) and 127));
   function Cols return Natural is (Natural (CRTC (1)));
   function Vsync_Line return Natural is
     (Natural (CRTC (7) and 127) * Scan_Lines);
   function Offscreen return Boolean is (Line >= Rows * Scan_Lines);

   ---------------------------------------------------------------------
   --  Memory map
   ---------------------------------------------------------------------

   procedure Rebuild_Map is
   begin
      for P in Byte loop
         case P is
            when 16#00# .. 16#7F# =>
               Read_Map (P) := Natural (P) * 256;
               Write_Map (P) := Read_Map (P);
            when 16#80# .. 16#8F# =>        --  1K screen, mirrored
               Read_Map (P) := 16#8000# + Natural (P mod 4) * 256;
               Write_Map (P) := Read_Map (P);
            when 16#B0# .. 16#DF# =>
               Read_Map (P) := PET_Basic + Natural (P - 16#B0#) * 256;
               Write_Map (P) := Write_Sink;
            when 16#E0# .. 16#E7# =>
               Read_Map (P) := PET_Editor + Natural (P - 16#E0#) * 256;
               Write_Map (P) := Write_Sink;
            when 16#E8# =>
               Read_Map (P) := IO_Page;
               Write_Map (P) := IO_Page;
            when 16#F0# .. 16#FF# =>
               Read_Map (P) := PET_Kernal + Natural (P - 16#F0#) * 256;
               Write_Map (P) := Write_Sink;
            when others =>                   --  empty sockets
               Read_Map (P) := ROM_Empty;
               Write_Map (P) := Write_Sink;
         end case;
      end loop;
      Kernal_High := False;    --  (no KERNAL traps: drive 8 is IEEE_Drive)
   end Rebuild_Map;

   ---------------------------------------------------------------------
   --  I/O at $E810 (PIA1), $E820 (PIA2), $E840 (VIA), $E880 (CRTC);
   --  address bits 4-7 select the chips
   ---------------------------------------------------------------------

   function Keyboard_Row return Byte is
      Row : constant Natural := Natural (PIA.Port_A_Out (PIA1) and 15);
   begin
      return (if Row <= 9 then not Keyboard.Matrix (Row) else 16#FF#);
   end Keyboard_Row;

   function PIA1_A_In return Byte is
     (16#BF# or (if IEEE_Drive.EOI then 0 else 16#40#));

   function VIA_B_In return Byte is
     (16#FF# and not (if IEEE_Drive.NDAC then 1 else 0)
             and not (if Offscreen then 16#20# else 0)
             and not (if IEEE_Drive.NRFD then 16#40# else 0)
             and not (if IEEE_Drive.DAV then 16#80# else 0));

   --  The computer's outputs onto the IEEE bus
   procedure Bus_Outputs is
      PB : constant Byte := V.ORB or not V.DDRB;
   begin
      IEEE_Drive.CPU_NRFD := not Bit (PB, 1);
      IEEE_Drive.CPU_ATN := not Bit (PB, 2);
      IEEE_Drive.CPU_NDAC := not PIA.CA2_Out (PIA2);
      IEEE_Drive.CPU_DAV := not PIA.CB2_Out (PIA2);
      IEEE_Drive.CPU_EOI := not PIA.CA2_Out (PIA1);
      IEEE_Drive.CPU_Data := PIA.Port_B_Out (PIA2);
      IEEE_Drive.Update;
   end Bus_Outputs;

   function IO_Peek (Addr : Word) return Byte is
      R : Byte := 16#FF#;
   begin
      if Bit (Lo (Addr), 4) then
         R := R and PIA.Peek (PIA1, Natural (Addr and 3),
                              (if (Addr and 3) = 0 then PIA1_A_In
                               else Keyboard_Row));
      end if;
      if Bit (Lo (Addr), 5) then
         R := R and PIA.Peek (PIA2, Natural (Addr and 3),
                              (if (Addr and 3) = 0 then IEEE_Drive.Data
                               else 16#FF#));
      end if;
      if Bit (Lo (Addr), 6) then
         R := R and (case Addr and 15 is
                        when 0 => (VIA_B_In and not V.DDRB) or (V.ORB and V.DDRB),
                        when others => 16#FF#);
      end if;
      if Bit (Lo (Addr), 7) and then (Addr and 1) = 1 then
         R := R and CRTC (CRTC_Index);
      end if;
      return R;
   end IO_Peek;

   function IO_Read (Addr : Word) return Byte is
      R : Byte := 16#FF#;
   begin
      if Bit (Lo (Addr), 4) then
         R := R and PIA.Read (PIA1, Natural (Addr and 3),
                              (if (Addr and 3) = 0 then PIA1_A_In
                               else Keyboard_Row));
      end if;
      if Bit (Lo (Addr), 5) then
         R := R and PIA.Read (PIA2, Natural (Addr and 3),
                              (if (Addr and 3) = 0 then IEEE_Drive.Data
                               else 16#FF#));
      end if;
      if Bit (Lo (Addr), 6) then
         V.Port_B_In := VIA_B_In;
         V.Port_A_In := 16#FF#;
         R := R and VIA.Read (V, Natural (Addr and 15));
      end if;
      if Bit (Lo (Addr), 7) and then (Addr and 1) = 1 then
         R := R and CRTC (CRTC_Index);
      end if;
      return R;
   end IO_Read;

   procedure IO_Write (Addr : Word; Value : Byte) is
   begin
      if Bit (Lo (Addr), 4) then
         PIA.Write (PIA1, Natural (Addr and 3), Value);
      end if;
      if Bit (Lo (Addr), 5) then
         PIA.Write (PIA2, Natural (Addr and 3), Value);
      end if;
      if Bit (Lo (Addr), 6) then
         VIA.Write (V, Natural (Addr and 15), Value);
         if (Addr and 15) = 10 then
            Pattern := Value;             --  the sound's bit pattern
         end if;
      end if;
      if Bit (Lo (Addr), 7) then
         if (Addr and 1) = 0 then
            CRTC_Index := Natural (Value and 31);
         else
            CRTC (CRTC_Index) := Value;
         end if;
      end if;
      if (Lo (Addr) and 16#70#) /= 0 then
         Bus_Outputs;
      end if;
   end IO_Write;

   ---------------------------------------------------------------------
   --  Video: the frame drawn at vertical sync, green on black
   ---------------------------------------------------------------------

   Green : constant Pixel := 16#4DF600#;    --  as VICE shows it

   procedure Render is
      SL : constant Natural := Scan_Lines;
      X0 : constant Integer := (Video.VIC_Width - Cols * 8) / 2;
      Y0 : constant Integer := (Video.VIC_Visible_Lines - Rows * SL) / 2;
      Start : constant Natural :=
        Natural (CRTC (12) and 16#3F#) * 256 + Natural (CRTC (13));
      Set : constant Natural := (if VIA.CA2_High (V) then 1024 else 0);
   begin
      Video.VIC_FB := (others => (others => 0));
      for R in 0 .. Rows - 1 loop
         for C in 0 .. Cols - 1 loop
            declare
               Code : constant Byte :=
                 Mem (16#8000# + (Start + R * Cols + C) mod 1024);
            begin
               for Y in 0 .. Natural'Min (SL, 8) - 1 loop
                  declare
                     D : Byte := Mem (PET_Chars + Set
                                      + Natural (Code and 16#7F#) * 8 + Y);
                     FY : constant Integer := Y0 + R * SL + Y;
                  begin
                     if Bit (Code, 7) then
                        D := not D;
                     end if;
                     for X in 0 .. 7 loop
                        declare
                           FX : constant Integer := X0 + C * 8 + X;
                        begin
                           if FX in 0 .. Video.VIC_Width - 1
                             and then FY in 0 .. Video.FB_Lines - 1
                             and then Bit (D, 7 - X)
                           then
                              Video.VIC_FB (FY, FX) := Green;
                           end if;
                        end;
                     end loop;
                  end;
               end loop;
            end;
         end loop;
      end loop;
   end Render;

   ---------------------------------------------------------------------
   --  Sound: the VIA's shift register free running at timer 2's rate
   --  (ACR mode 4), its bits on CB2
   ---------------------------------------------------------------------

   Bit_Time : Natural := 0;
   Sample_Acc : Float := 0.0;
   DC_In, DC_Out : Float := 0.0;

   procedure Sound (N : Natural) is
      Free_Run : constant Boolean := (V.ACR and 16#1C#) = 16#10#;
      Period : constant Positive := Natural (V.T2_Latch_Lo) + 2;
   begin
      for I in 1 .. N loop
         if Free_Run then
            Bit_Time := Bit_Time + 1;
            if Bit_Time >= Period then
               Bit_Time := 0;
               Pattern := Rotate_Left (Pattern, 1);
            end if;
         end if;
         Sample_Acc := Sample_Acc + 1.0;
         if Sample_Acc >= 1.0E6 / Float (SID.Sample_Rate) then
            Sample_Acc := Sample_Acc - 1.0E6 / Float (SID.Sample_Rate);
            declare
               High : constant Boolean := Free_Run and then Bit (Pattern, 7);
               X : constant Float := (if High then 0.14 else 0.0);
               Y : constant Float := X - DC_In + 0.995 * DC_Out;
            begin
               DC_In := X;
               DC_Out := Y;
               if SID.Sink /= null then
                  SID.Sink (SID.Sample (Integer (Y * 30000.0)));
               end if;
            end;
         end if;
      end loop;
   end Sound;

   ---------------------------------------------------------------------
   --  Time
   ---------------------------------------------------------------------

   procedure Clock (N : Natural) is
   begin
      VIA.Tick (V, N);
      Sound (N);
      Line_Cycle := Line_Cycle + N;
      while Line_Cycle >= Cycles_Per_Line loop
         Line_Cycle := Line_Cycle - Cycles_Per_Line;
         Line := Line + 1;
         if Line >= Lines_Per_Frame then
            Line := 0;
         end if;
         --  vertical retrace on PIA1 CB1 (low during sync)
         if Line = Vsync_Line then
            PIA.Set_CB1 (PIA1, False);
            Render;
            Done := True;
         elsif Line = (Vsync_Line + 4 * Scan_Lines) mod Lines_Per_Frame then
            PIA.Set_CB1 (PIA1, True);
         end if;
      end loop;
   end Clock;

   procedure Interrupt_Lines (IRQ, NMI : out Boolean) is
   begin
      IRQ := PIA.IRQ_A (PIA1) or else PIA.IRQ_B (PIA1)
        or else PIA.IRQ_A (PIA2) or else PIA.IRQ_B (PIA2) or else VIA.IRQ (V);
      NMI := False;
   end Interrupt_Lines;

   function Frame_Done return Boolean is (Done);

   procedure Clear_Frame is
   begin
      Done := False;
   end Clear_Frame;

   procedure End_Of_Frame is null;

   function Frame_Rate return Float is
     (1.0E6 / Float (Cycles_Per_Line * Lines_Per_Frame));

   function Screen_Byte (I : Natural) return Byte is
     (Mem (16#8000# + I mod 1024));

   function Beam_Text return String is
     ("  line" & Line'Image & " cycle" & Line_Cycle'Image);

   ---------------------------------------------------------------------
   --  ROMs and reset
   ---------------------------------------------------------------------

   ROM_Root : Unbounded_String;

   function Find_ROM (Name : String) return String is
      Exe_Dir : constant String :=
        Ada.Directories.Containing_Directory
          (Ada.Directories.Containing_Directory
             (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)));
      Dirs : constant array (1 .. 3) of Unbounded_String :=
        (To_Unbounded_String (Exe_Dir & "/roms/pet"),
         To_Unbounded_String ("roms/pet"), ROM_Root & "/PET");
   begin
      for Dir of Dirs loop
         if Ada.Directories.Exists (To_String (Dir) & "/" & Name) then
            return To_String (Dir) & "/" & Name;
         end if;
      end loop;
      return "";
   exception
      when others => return "";
   end Find_ROM;

   procedure Load (Name : String; Offset, Size : Natural; Ok : in out Boolean)
   is
      P : constant String := Find_ROM (Name);
   begin
      if P = "" then
         Ok := False;
         Append (Err, "PET ROM not found: " & Name &
                   " (in roms/pet, see the README)" & ASCII.LF);
      else
         Load_ROM (P, Offset, Size, Ok => Ok);
      end if;
   end Load;

   procedure Load_Editor (Ok : in out Boolean) is
   begin
      Load ((if Current_Standard = PAL then "edit-4-40-n-50Hz.901498-01.bin"
             else "edit-4-40-n-60Hz.901499-01.bin"), PET_Editor, 16#800#, Ok);
   end Load_Editor;

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean) is
   begin
      ROM_Root := To_Unbounded_String (ROM_Dir);
      Load ("basic-4.901465-23-20-21.bin", PET_Basic, 16#3000#, Ok);
      Load ("kernal-4.901465-22.bin", PET_Kernal, 16#1000#, Ok);
      Load ("characters-2.901447-10.bin", PET_Chars, 16#800#, Ok);
      Load_Editor (Ok);
   end Load_ROMs;

   procedure Set_Standard (V : Video_Standard) is
      pragma Unreferenced (V);
      Dummy : Boolean := True;
   begin
      Video.First_Visible_Line := 0;
      Video.VIC_Visible_Lines := 266;           --  (as VICE shows it)
      Video.VIC_Visible_Width := Video.VIC_Width;
      Video.X_Aspect := 1.0;
      if Length (ROM_Root) > 0 then
         Load_Editor (Dummy);          --  50 or 60 Hz editor
      end if;
   end Set_Standard;

   procedure Reset (Hard : Boolean) is
      pragma Unreferenced (Hard);
   begin
      PIA.Reset (PIA1);
      PIA.Reset (PIA2);
      VIA.Reset (V);
      CRTC := (others => 0);
      CRTC_Index := 0;
      Line := 0;
      Line_Cycle := 0;
      IEEE_Drive.Reset;
      Bus_Outputs;
   end Reset;

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      PIA.Chip'Write (S, PIA1);
      PIA.Chip'Write (S, PIA2);
      VIA.Chip'Write (S, V);
      Natural'Write (S, CRTC_Index);
      for R of CRTC loop
         Byte'Write (S, R);
      end loop;
      Natural'Write (S, Line);
      Natural'Write (S, Line_Cycle);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      PIA.Chip'Read (S, PIA1);
      PIA.Chip'Read (S, PIA2);
      VIA.Chip'Read (S, V);
      Natural'Read (S, CRTC_Index);
      for R of CRTC loop
         Byte'Read (S, R);
      end loop;
      Natural'Read (S, Line);
      Natural'Read (S, Line_Cycle);
      IEEE_Drive.Reset;
      Bus_Outputs;
   end Load_State;

end Machine.PET_System;
