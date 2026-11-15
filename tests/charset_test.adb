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

   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("charset: all passed");
   end if;
end Charset_Test;
