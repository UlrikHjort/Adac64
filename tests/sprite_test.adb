--  Sprite editor model test: pixels, operations, .spr files and the
--  exported ACME source (assembled with our assembler).

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Directories;
with Types; use Types;
with Interfaces; use Interfaces;
with Sprite_Data; use Sprite_Data;
with Asm;

procedure Sprite_Test is
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

   S, T : Sprite;
begin
   --  Hires pixels
   Set_Pixel (S, 0, 0, Sprite_Color);
   Set_Pixel (S, 23, 20, Sprite_Color);
   Check (S.Data (0) = 16#80# and then S.Data (62) = 16#01#, "hires corners");
   T := S;
   Mirror_X (T);
   Check (T.Data (0) = 16#00# and then T.Data (2) = 16#01#
          and then T.Data (60) = 16#80#, "mirror x");
   T := S;
   Mirror_Y (T);
   Check (T.Data (60) = 16#80# and then T.Data (2) = 16#01#, "mirror y");
   T := S;
   Shift (T, 1, 0);
   Check (T.Data (0) = 16#40# and then T.Data (60) = 16#80#,
          "shift right wraps");
   T := S;
   Shift (T, 0, -1);
   Check (T.Data (59) = 16#01# and then T.Data (60) = 16#80#,
          "shift up wraps");
   T := S;
   Invert (T);
   Check (T.Data (0) = 16#7F# and then T.Data (1) = 16#FF#, "invert");

   --  Multicolour: pairs of bits
   S := (others => <>);
   S.Multi := True;
   Set_Pixel (S, 0, 0, Multi_1);
   Set_Pixel (S, 3, 0, Sprite_Color);   --  pixel 1 (x = 2..3)
   Set_Pixel (S, 4, 0, Multi_2);
   Check (S.Data (0) = 2#01_10_11_00#, "multicolour bit pairs");
   Check (Sprite_Data.Pixel (S, 1, 0) = Multi_1
          and then Sprite_Data.Pixel (S, 2, 0) = Sprite_Color,
          "multicolour pixels are two wide");
   T := S;
   Mirror_X (T);
   Check (T.Data (2) = 2#00_11_10_01#, "multicolour mirror keeps pairs");
   T := S;
   Flood_Fill (T, 20, 10, Multi_2);
   Check (T.Data (62) = 16#FF# and then T.Data (0) = 2#01_10_11_11#,
          "flood fill");

   --  Files: a set of three sprites
   Reset_Set;
   Put (1, S);
   S.Color := 7;
   S.Data (30) := 16#AA#;
   Insert (2, S);
   T := (others => <>);
   T.Color := 2;
   Set_Pixel (T, 12, 10, Sprite_Color);
   Insert (3, T);
   Save (Dir & "/test.spr", Ok);
   Check (Ok and then Natural (Ada.Directories.Size (Dir & "/test.spr")) = 192,
          "save 3 sprites = 192 bytes");
   declare
      A : constant Sprite := Get (1);
      B : constant Sprite := Get (2);
      C : constant Sprite := Get (3);
   begin
      Reset_Set;
      Load (Dir & "/test.spr", Ok);
      Check (Ok and then Sprite_Data.Count = 3 and then Get (1) = A and then Get (2) = B
             and then Get (3) = C, "load round trip (data, colour, mode)");
   end;

   --  Exported source assembles to the same bytes as the .spr file
   Export_Source (Dir & "/test_spr.asm", "sprites", Ok);
   Check (Ok, "export source");
   declare
      use Ada.Text_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Dir & "/wrap.asm");
      Put_Line (F, "*= $2000");
      Put_Line (F, "!source ""test_spr.asm""");
      Close (F);
   end;
   Asm.Assemble (Dir & "/wrap.asm");
   Check (not Asm.Has_Errors, "exported source assembles");
   declare
      Same : Boolean := Asm.Low_Address = 16#2000#
        and then Natural (Asm.High_Address) = 16#2000# + 191;
      V : Integer;
   begin
      for I in 1 .. 3 loop
         for J in 0 .. 62 loop
            Same := Same and then
              Asm.Output_Byte (16#2000# + Word ((I - 1) * 64 + J))
                = Get (I).Data (J);
         end loop;
      end loop;
      Check (Same, "assembled bytes equal the sprite data");
      Check (Asm.Lookup ("sprites_2", V) and then V = 16#2080#,
             "labels per sprite (sprites_2 = $2080)");
   end;

   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("sprites: all passed");
   end if;
end Sprite_Test;
