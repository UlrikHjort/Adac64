-- ***************************************************************************
--                      AdaC64 - Charset_Test
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

--  Charset editor model test: ROM import, pixels, operations, files and
--  exported source.

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Types; use Types;
with Interfaces; use Interfaces;
with Machine;
with Charset_Data; use Charset_Data;
with Asm;
with Video;

procedure Charset_Test is
   Failures : Natural := 0;
   Ok : Boolean;
   Dir : constant String := "obj/tests_dbg";

   procedure Check (Cond : Boolean; What : String) is
   begin
      Put_Line ((if Cond then "ok   " else "FAIL ") & What);
      if not Cond then
         Failures := Failures + 1;
      end if;
   end Check;

   G, T : Glyph;
begin
   Machine.Power_On (Machine.C64, "/usr/share/vice", Ok);
   Load_ROM (False);
   --  Screen code 1 is "A": the chargen file has it at offset 8
   declare
      package SIO renames Ada.Streams.Stream_IO;
      F : SIO.File_Type;
      Rom : Byte_Array (0 .. 4095);
   begin
      SIO.Open (F, SIO.In_File, "/usr/share/vice/C64/chargen-901225-01.bin");
      Byte_Array'Read (SIO.Stream (F), Rom);
      SIO.Close (F);
      Check ((for all Y in Row_Range => Get (1) (Y) = Rom (8 + Y)),
             "ROM import (upper case A)");
      Load_ROM (True);
      Check ((for all Y in Row_Range => Get (1) (Y) = Rom (2048 + 8 + Y)),
             "ROM import (lower case a)");
   end;

   G := (16#80#, others => 0);
   T := G;
   Mirror_X (T);
   Check (T (0) = 16#01#, "mirror x");
   T := G;
   Rotate (T);
   Check (T (0) = 16#01# and then (for all Y in 1 .. 7 => T (Y) = 0),
          "rotate: top-left goes to top-right");
   T := G;
   Shift (T, 0, 1);
   Check (T (1) = 16#80# and then T (0) = 0, "shift down");
   Multicolour := True;
   G := (others => 0);
   Set_Pixel (G, 0, 0, Multi_1);
   Set_Pixel (G, 2, 0, Multi_2);
   Set_Pixel (G, 5, 0, Char_Color);
   Check (G (0) = 2#01_10_11_00#, "multicolour pairs (01 $d022, 10 $d023, "
          & "11 colour RAM)");
   Flood_Fill (G, 0, 4, Char_Color);
   Check (G (7) = 16#FF#, "multicolour flood fill");
   Multicolour := False;

   Load_ROM (False);
   Save (Dir & "/test.chr", Ok);
   Check (Ok and then Natural (Ada.Directories.Size (Dir & "/test.chr"))
          = 2048, "save 2048 bytes");
   declare
      A : constant Glyph := Get (65);
   begin
      Clear_All;
      Load (Dir & "/test.chr", Ok);
      Check (Ok and then Get (65) = A and then Charset_Data.Count = 256, "load round trip");
   end;
   Export_Source (Dir & "/test_chr.asm", "font", Ok);
   declare
      use Ada.Text_IO;
      F : File_Type;
      Same : Boolean := True;
   begin
      Create (F, Out_File, Dir & "/wrapc.asm");
      Put_Line (F, "*= $3000");
      Put_Line (F, "!source ""test_chr.asm""");
      Close (F);
      Asm.Assemble (Dir & "/wrapc.asm");
      for C in Char_Code loop
         for Y in Row_Range loop
            Same := Same and then
              Asm.Output_Byte (16#3000# + Word (C * 8 + Y)) = Get (C) (Y);
         end loop;
      end loop;
      Check (not Asm.Has_Errors and then Same
             and then Asm.High_Address = 16#37FF#,
             "exported source assembles to the same 2048 bytes");
   end;

   --  C16 / Plus/4: colours to the TED and back, and the TED's 128-char
   --  mode (characters 128-255 are reversed copies)
   Check ((for all C in Byte range 0 .. 15 =>
             Video.From_TED (Video.To_TED (C)) = C),
          "every C64 colour maps to a TED colour and back");
   declare
      TED_Mem : Byte_Array (0 .. 16#FFFF#) := (others => 0);
      function Rd (A : Word) return Byte is (TED_Mem (Natural (A)));
   begin
      for I in 0 .. 1023 loop
         TED_Mem (16#3000# + I) := Byte (I mod 251);
      end loop;
      Load_TED_Charset (Rd'Unrestricted_Access, 16#1B#, 16#08#, 16#30#);
      Check (Get (5) (3) = Byte ((5 * 8 + 3) mod 251)
             and then Get (128 + 5) (3) = not Byte ((5 * 8 + 3) mod 251),
             "TED charset: 128 characters, 128-255 reversed");
      Load_TED_Charset (Rd'Unrestricted_Access, 16#1B#, 16#88#, 16#30#);
      Check (Get (128 + 5) (3) = TED_Mem (16#3000# + 16#400# + 5 * 8 + 3),
             "TED charset: 256 characters");
   end;

   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("charset: all passed");
   end if;
end Charset_Test;
