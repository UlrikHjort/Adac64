-- ***************************************************************************
--                      AdaC64 - Charset_Data
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

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings;
with Interfaces; use Interfaces;
with Machine;

package body Charset_Data is

   type Glyph_Array is array (Char_Code) of Glyph;
   Set : Glyph_Array := (others => (others => 0));
   Used : Natural := 256;

   function Get (C : Char_Code) return Glyph is (Set (C));
   function Count return Natural is (Used);

   procedure Put (C : Char_Code; G : Glyph) is
   begin
      Set (C) := G;
   end Put;

   function Pixel (G : Glyph; X, Y : Row_Range) return Pen is
      B : constant Byte := G (Y);
   begin
      if Multicolour then
         case Shift_Right (B, 6 - 2 * (X / 2)) and 3 is
            when 0 => return Background;
            when 1 => return Multi_1;
            when 2 => return Multi_2;
            when others => return Char_Color;
         end case;
      end if;
      return (if (Shift_Right (B, 7 - X) and 1) /= 0 then Char_Color
              else Background);
   end Pixel;

   procedure Set_Pixel (G : in out Glyph; X, Y : Row_Range; P : Pen) is
   begin
      if Multicolour then
         declare
            Sh : constant Natural := 6 - 2 * (X / 2);
            V  : constant Byte :=
              (case P is
                 when Background => 0, when Multi_1 => 1,
                 when Multi_2 => 2, when Char_Color => 3);
         begin
            G (Y) := (G (Y) and not Shift_Left (3, Sh)) or Shift_Left (V, Sh);
         end;
      elsif P = Background then
         G (Y) := G (Y) and not Shift_Left (1, 7 - X);
      else
         G (Y) := G (Y) or Shift_Left (1, 7 - X);
      end if;
   end Set_Pixel;

   procedure Invert (G : in out Glyph) is
   begin
      for B of G loop
         B := not B;
      end loop;
   end Invert;

   function Step return Positive is (if Multicolour then 2 else 1);

   procedure Mirror_X (G : in out Glyph) is
      T : constant Glyph := G;
   begin
      for Y in Row_Range loop
         for X in 0 .. 8 / Step - 1 loop
            Set_Pixel (G, X * Step, Y, Pixel (T, (8 / Step - 1 - X) * Step, Y));
         end loop;
      end loop;
   end Mirror_X;

   procedure Mirror_Y (G : in out Glyph) is
      T : constant Glyph := G;
   begin
      for Y in Row_Range loop
         G (Y) := T (7 - Y);
      end loop;
   end Mirror_Y;

   procedure Shift (G : in out Glyph; DX, DY : Integer) is
      T : constant Glyph := G;
      Cols : constant Positive := 8 / Step;
   begin
      for Y in Row_Range loop
         for X in 0 .. Cols - 1 loop
            Set_Pixel (G, X * Step, Y,
                       Pixel (T, ((X - DX) mod Cols) * Step, (Y - DY) mod 8));
         end loop;
      end loop;
   end Shift;

   procedure Rotate (G : in out Glyph) is
      T : constant Glyph := G;
   begin
      --  clockwise, on hires pixels (a multicolour glyph is rotated as
      --  bits as well, which is what most editors do)
      for Y in Row_Range loop
         G (Y) := 0;
         for X in Row_Range loop
            if (Shift_Right (T (7 - X), 7 - Y) and 1) /= 0 then
               G (Y) := G (Y) or Shift_Left (1, 7 - X);
            end if;
         end loop;
      end loop;
   end Rotate;

   procedure Flood_Fill (G : in out Glyph; X, Y : Row_Range; P : Pen) is
      Target : constant Pen := Pixel (G, X, Y);
      procedure Fill (FX, FY : Integer) is
      begin
         if FX not in Row_Range or else FY not in Row_Range
           or else Pixel (G, FX, FY) /= Target
         then
            return;
         end if;
         Set_Pixel (G, FX, FY, P);
         Fill (FX - Step, FY);
         Fill (FX + Step, FY);
         Fill (FX, FY - 1);
         Fill (FX, FY + 1);
      end Fill;
   begin
      if Target /= P then
         Fill (X - X mod Step, Y);
      end if;
   end Flood_Fill;

   procedure Load_ROM (Lower_Case : Boolean) is
      Base : constant Natural := (if Lower_Case then 2048 else 0);
   begin
      for C in Char_Code loop
         for Y in Row_Range loop
            Set (C) (Y) := Machine.Char_ROM_Peek (Base + C * 8 + Y);
         end loop;
      end loop;
      Used := 256;
   end Load_ROM;

   procedure Clear_All is
   begin
      Set := (others => (others => 0));
      Used := 256;
   end Clear_All;

   procedure Load (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      declare
         Len : constant Natural := Natural (Size (F));
         Buf : Byte_Array (0 .. Len - 1);
         Skip : constant Natural := (if Len mod 8 = 2 then 2 else 0);
      begin
         Byte_Array'Read (Stream (F), Buf);
         Close (F);
         Set := (others => (others => 0));
         Used := Natural'Max (1, Natural'Min (256, (Len - Skip + 7) / 8));
         for I in 0 .. Natural'Min (Len - Skip, 2048) - 1 loop
            Set (I / 8) (I mod 8) := Buf (Skip + I);
         end loop;
      end;
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Load;

   procedure Save (Path : String; Ok : out Boolean; Chars : Positive := 256)
   is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Path);
      for C in 0 .. Natural'Min (Chars, 256) - 1 loop
         for Y in Row_Range loop
            Byte'Write (Stream (F), Set (C) (Y));
         end loop;
      end loop;
      Close (F);
      Used := Natural'Min (Chars, 256);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Save;

   procedure Export_Source (Path, Label : String; Ok : out Boolean;
                            Chars : Positive := 256) is
      use Ada.Text_IO;
      F : File_Type;
      function Img (N : Integer) return String is
        (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));
   begin
      Create (F, Out_File, Path);
      Put_Line (F, ";" & Chars'Image & " characters exported by AdaC64 Forge"
                & " (8 bytes each; align to 2048 bytes for the VIC)");
      Put_Line (F, "; " & (if Multicolour then "multicolour" else "hires") &
                  ", background" & Background_Color'Image &
                  ", $d022" & Multi_Color_1'Image &
                  ", $d023" & Multi_Color_2'Image);
      Put_Line (F, Label);
      for C in 0 .. Natural'Min (Chars, 256) - 1 loop
         Put (F, "        !byte ");
         for Y in Row_Range loop
            Put (F, "%");
            for Bit in reverse 0 .. 7 loop
               Put (F, (if (Shift_Right (Set (C) (Y), Bit) and 1) /= 0
                        then '#' else '.'));
            end loop;
            if Y < 7 then
               Put (F, ",");
            end if;
         end loop;
         Put_Line (F, "  ; " & Img (C));
      end loop;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Export_Source;

   procedure Load_Memory (Read : not null Reader; Addr : Word) is
   begin
      for C in Char_Code loop
         for Y in Row_Range loop
            Set (C) (Y) := Read (Addr + Word (C * 8 + Y));
         end loop;
      end loop;
      Used := 256;
   end Load_Memory;

end Charset_Data;
