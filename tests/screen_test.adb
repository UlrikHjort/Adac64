-- ***************************************************************************
--                      AdaC64 - Screen_Test
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

--  Screen editor model test: screen codes, fill, .scr files and the
--  exported source.

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Directories;
with Types; use Types;
with Interfaces; use Interfaces;
with Screen_Data; use Screen_Data;
with Asm;

procedure Screen_Test is
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
begin
   Check (Screen_Code ('a') = 1 and then Screen_Code ('@') = 0
          and then Screen_Code ('A') = 65 and then Screen_Code ('1') = 49
          and then Screen_Code (' ') = 32 and then Screen_Code ('a', True) = 129,
          "screen codes (a=1 @=0 A=65 shifted, reverse +128)");

   Clear;
   for X in 5 .. 15 loop
      Current (10, X) := (160, 2);     --  a wall
   end loop;
   Flood_Fill (0, 0, (81, 7));
   Check (Current (0, 0) = (81, 7) and then Current (24, 39) = (81, 7)
          and then Current (10, 5) = (160, 2), "flood fill stops at cells "
          & "that differ");

   Current (3, 4) := (1, 1);
   Border_Color := 0;
   Background_Color := 11;
   Save (Dir & "/test.scr", Ok);
   Check (Ok and then Natural (Ada.Directories.Size (Dir & "/test.scr")) = 2002,
          "save 2002 bytes");
   declare
      Saved : constant Screen := Current;
   begin
      Clear;
      Border_Color := 14;
      Load (Dir & "/test.scr", Ok);
      Check (Ok and then Current = Saved and then Border_Color = 0
             and then Background_Color = 11, "load round trip with colours");
   end;

   --  1000-byte files are screen codes only
   declare
      use Ada.Text_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Dir & "/codes.bin");
      for I in 1 .. 1000 loop
         Put (F, Character'Val (I mod 256));
      end loop;
      Close (F);
      Load (Dir & "/codes.bin", Ok);
      Check (Ok and then Current (0, 1).Code = 2 and then Current (0, 1).Color = 14,
             "load a plain 1000-byte screen");
   end;

   Load (Dir & "/test.scr", Ok);
   Export_Source (Dir & "/test_scr.asm", "title", Ok);
   declare
      use Ada.Text_IO;
      F : File_Type;
      Same : Boolean := True;
      V : Integer;
   begin
      Create (F, Out_File, Dir & "/wraps.asm");
      Put_Line (F, "*= $4000");
      Put_Line (F, "!source ""test_scr.asm""");
      Close (F);
      Asm.Assemble (Dir & "/wraps.asm");
      for Y in Row_Range loop
         for X in Col_Range loop
            Same := Same
              and then Asm.Output_Byte (16#4000# + Word (Y * 40 + X))
                = Current (Y, X).Code
              and then Asm.Output_Byte (16#4000# + 1000 + Word (Y * 40 + X))
                = Current (Y, X).Color;
         end loop;
      end loop;
      Check (not Asm.Has_Errors and then Same, "exported source assembles to "
             & "the codes and colours");
      Check (Asm.Lookup ("title_colors", V) and then V = 16#4000# + 1000
             and then Asm.Lookup ("title_background", V) and then V = 11,
             "labels and colour constants");
   end;

   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("screen: all passed");
   end if;
end Screen_Test;
