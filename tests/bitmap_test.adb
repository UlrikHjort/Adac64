-- ***************************************************************************
--                      AdaC64 - Bitmap_Test
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

--  Bitmap editor model test: colour limits, colour reduction, files, and
--  the exported viewer assembled and run in the emulator, comparing the
--  VIC-II's output with the editor's rendering pixel by pixel; the same
--  for the picture sent to a Plus/4 in the TED's layout.

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Types; use Types;
with Interfaces; use Interfaces;
with Bitmap_Data; use Bitmap_Data;
with Asm;
with Machine;
with Video;

procedure Bitmap_Test is
   Failures : Natural := 0;
   Ok, Clash : Boolean;
   Size : Natural;
   Dir : constant String := "obj/tests_dbg";

   procedure Check (Cond : Boolean; What : String) is
   begin
      Put_Line ((if Cond then "ok   " else "FAIL ") & What);
      if not Cond then
         Failures := Failures + 1;
      end if;
   end Check;

   procedure Draw_Test_Picture is
      C : Boolean;
   begin
      for Y in 0 .. 199 loop
         for X in 0 .. Width - 1 loop
            --  diagonal bands of four colours and a circle
            Set_Pixel (X, Y, Byte ((X / 9 + Y / 13) mod 4 + 2), C);
            if (X * (320 / Width) - 160) ** 2 + (Y - 100) ** 2 < 60 ** 2 then
               Set_Pixel (X, Y, 7, C);
            end if;
         end loop;
      end loop;
   end Draw_Test_Picture;

   A, B : Image;
begin
   --  Multicolour: background + 3 colours per cell, a 4th clashes
   Bitmap_Data.Mode := Multicolour;
   Clear (0, 1);
   Set_Pixel (0, 0, 2, Clash);
   Set_Pixel (1, 0, 3, Clash);
   Set_Pixel (2, 0, 4, Clash);
   Check (not Clash and then Bitmap_Data.Pixel (0, 0) = 2 and then Bitmap_Data.Pixel (1, 0) = 3
          and then Bitmap_Data.Pixel (2, 0) = 4, "multicolour: three colours in a cell");
   Set_Pixel (3, 0, 0, Clash);
   Check (not Clash and then Bitmap_Data.Pixel (3, 0) = 0, "background is free");
   Set_Pixel (0, 1, 3, Clash);
   Set_Pixel (3, 1, 5, Clash);
   Check (Clash and then Bitmap_Data.Pixel (3, 1) = 5, "a fourth colour clashes");
   Check (Bitmap_Data.Pixel (1, 0) = 3, "...and replaces the colour used least");

   --  Hires: two colours per cell
   Bitmap_Data.Mode := Hires;
   Clear (0, 1);
   Set_Pixel (0, 0, 2, Clash);
   Check (not Clash and then Bitmap_Data.Pixel (0, 0) = 2 and then Bitmap_Data.Pixel (1, 0) = 0,
          "hires: new ink for an empty cell");
   Set_Pixel (1, 0, 5, Clash);
   Check (Clash and then Bitmap_Data.Pixel (1, 0) = 5, "hires: a third colour clashes");

   --  Render / Encode keep a picture that fits the limits
   for M in Mode_Kind loop
      Bitmap_Data.Mode := M;
      Clear (6, 1);
      Draw_Test_Picture;
      Render (A);
      Encode (A, M);
      Render (B);
      Check (A = B, Mode_Kind'Image (M) & ": encode (render) reproduces " &
             "the picture");
   end loop;

   --  Files
   for M in Mode_Kind loop
      Bitmap_Data.Mode := M;
      Clear (6, 1);
      Draw_Test_Picture;
      Border := 11;
      Render (A);
      Save (Dir & "/pic." & (if M = Hires then "art" else "kla"), Ok);
      Clear (0, 0);
      Load (Dir & "/pic." & (if M = Hires then "art" else "kla"), Ok, Size);
      Render (B);
      Check (Ok and then Bitmap_Data.Mode = M and then A = B and then
             Size = (if M = Hires then 9009 else 10003),
             (if M = Hires then "Art Studio" else "Koala") & " round trip (" &
               Size'Image & " bytes)");
   end loop;

   --  The exported viewer, run on the emulated C64
   Machine.Power_On (Machine.C64, "/usr/share/vice", Ok);
   for M in Mode_Kind loop
      Bitmap_Data.Mode := M;
      Clear (6, 1);
      Draw_Test_Picture;
      Border := 0;
      Render (A);
      Export_Viewer (Dir & "/view.asm", "pic", Ok);
      Asm.Assemble (Dir & "/view.asm");
      Check (not Asm.Has_Errors, "viewer assembles");
      declare
         D : Byte_Array (0 .. Natural (Asm.High_Address - Asm.Low_Address));
         Same : Boolean := True;
         Bad : Natural := 0;
      begin
         for I in D'Range loop
            D (I) := Asm.Output_Byte (Asm.Low_Address + Word (I));
         end loop;
         Machine.Inject_And_Run (D, Asm.Low_Address, "RUN");
         for F in 1 .. 250 loop
            Machine.Run_Frame;
         end loop;
         --  The display window starts 32 pixels in and 35 lines down
         for Y in 0 .. 199 loop
            for X in 0 .. 319 loop
               if Video.VIC_FB (Y + 35, X + 32) /= Video.VIC_Palette (A (Y, X))
               then
                  Same := False;
                  Bad := Bad + 1;
               end if;
            end loop;
         end loop;
         Check (Same, Mode_Kind'Image (M) & ": the VIC-II shows exactly the " &
                "editor's picture" & (if Same then "" else " (" & Bad'Image &
                  " pixels differ)"));
      end;
   end loop;

   --  C16 / Plus/4: the picture in the TED's layout (as the editor sends
   --  it) on the emulated Plus/4, compared with the editor's rendering in
   --  TED colours; multicolour bit pair 11 becomes one colour
   Machine.Power_On (Machine.Plus4, "/usr/share/vice", Ok);
   if not Ok then
      Put_Line ("skip Plus/4 (ROMs not installed)");
   else
      for F in 1 .. 150 loop
         Machine.Run_Frame;
      end loop;
      for M in Mode_Kind loop
         Bitmap_Data.Mode := M;
         Clear (6, 1);
         Draw_Test_Picture;
         Border := 0;
         declare
            P : constant TED_Picture := To_TED;
            Same : Boolean := True;
            Bad : Natural := 0;
         begin
            From_TED (P);            --  what the TED can show of it
            Render (A);
            for I in Bitmap'Range loop
               Machine.Poke (16#2000# + Word (I), Bitmap (I));
            end loop;
            for I in Screen'Range loop
               Machine.Poke (16#1C00# + Word (I), P.Hues (I));
               Machine.Poke (16#1800# + Word (I), P.Lums (I));
            end loop;
            Machine.Monitor_Poke (16#FF06#, 16#3B#);
            Machine.Monitor_Poke
              (16#FF07#, (if M = Multicolour then 16#18# else 16#08#));
            Machine.Monitor_Poke
              (16#FF12#, (Machine.IO_Peek (16#FF12#) and 16#C3#) or 16#08#);
            Machine.Monitor_Poke (16#FF14#, 16#18#);
            Machine.Monitor_Poke (16#FF15#, P.BG0);
            Machine.Monitor_Poke (16#FF16#, P.BG1);
            for F in 1 .. 3 loop
               Machine.Run_Frame;
            end loop;
            --  The TED's display window starts 32 pixels in, 40 lines down
            for Y in 0 .. 199 loop
               for X in 0 .. 319 loop
                  if Video.VIC_FB (Y + 40, X + 32) /=
                    Video.TED_Palette (Video.To_TED (A (Y, X)))
                  then
                     Same := False;
                     Bad := Bad + 1;
                  end if;
               end loop;
            end loop;
            Check (Same, Mode_Kind'Image (M) & ": the TED shows exactly the "
                   & "editor's picture" & (if Same then "" else " (" &
                     Bad'Image & " pixels differ)"));
         end;
      end loop;
   end if;

   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("bitmap: all passed");
   end if;
end Bitmap_Test;
