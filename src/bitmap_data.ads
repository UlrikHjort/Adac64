-- ***************************************************************************
--                      AdaC64 - Bitmap_Data
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

--  Bitmap pictures for Forge's bitmap editor, kept in the C64's own
--  format, so the VIC-II's colour limits always hold:
--    hires        320 x 200, per 8 x 8 cell two colours (screen RAM
--                 high nibble = 1 bits, low nibble = 0 bits)
--    multicolour  160 x 200 (double-wide pixels), per 4 x 8 cell the
--                 background ($D021, 00) and three colours: screen RAM
--                 high nibble (01), low nibble (10), colour RAM (11)
--
--  Files: Koala Painter (.kla/.koa, multicolour, 10003 bytes), Art Studio
--  (.art, hires, 9009 bytes) and Doodle (.dd, hires, 9218 bytes).

with Types; use Types;

package Bitmap_Data is

   type Mode_Kind is (Hires, Multicolour);
   Mode : Mode_Kind := Multicolour;

   Bitmap : Byte_Array (0 .. 7999) := (others => 0);
   Screen : Byte_Array (0 .. 999) := (others => 16#10#);
   Colors : Byte_Array (0 .. 999) := (others => 1);
   Background : Byte := 0;
   Border : Byte := 0;

   function Width return Positive is (if Mode = Hires then 320 else 160);
   --  in pixels of the current mode (multicolour pixels are 2 wide)
   Height : constant := 200;

   function Pixel (X, Y : Natural) return Byte;    --  colour 0 .. 15
   procedure Set_Pixel (X, Y : Natural; C : Byte; Clash : out Boolean);
   --  Clash: the cell had no room for C, so one of its colours (the one
   --  used least) was replaced, recolouring those pixels.
   procedure Flood_Fill (X, Y : Natural; C : Byte; Clash : out Boolean);
   procedure Clear (Back : Byte := 0; Ink : Byte := 1);

   function Cell_Colors (CX, CY : Natural) return String;
   --  e.g. "1, 5 (bg 0)" for the status line

   --  Full-resolution colour picture (multicolour pixels doubled)
   type Image is array (0 .. 199, 0 .. 319) of Byte;
   procedure Render (Img : out Image);
   procedure Encode (Img : Image; M : Mode_Kind);
   --  Convert a picture of C64 colours into the given mode, choosing the
   --  best colours per cell (and the background for multicolour)
   function Nearest (R, G, B : Natural) return Byte;  --  closest C64 colour

   procedure Load (Path : String; Ok : out Boolean; Message : out Natural);
   --  Message: file size, for errors
   procedure Save (Path : String; Ok : out Boolean);
   --  Koala for multicolour, Art Studio for hires
   procedure Export_Viewer (Path, Label : String; Ok : out Boolean);
   --  A complete ACME program that shows the picture (assemble and run)

   type Reader is access function (Addr : Word) return Byte;
   procedure Load_Memory (VIC : not null Reader; Bitmap_At, Screen_At : Word;
                          IO : not null Reader);
   --  From the running machine (colour RAM through IO at $D800)

   --  C16 / Plus/4 (TED) layout: the bitmap is the same; per cell a hue
   --  byte (high nibble: the 1 / 01 colour, low: the 0 / 10 colour) and a
   --  luminance byte (bits 0-2: the 1 / 01 colour, 4-6: the 0 / 10 colour);
   --  multicolour bit pair 11 is one colour for the whole picture ($FF16)
   --  where the C64 has one per cell, so the most common one is used
   type TED_Picture is record
      Hues, Lums : Byte_Array (0 .. 999);
      BG0, BG1 : Byte;          --  $FF15 (background), $FF16 (pair 11)
   end record;
   function To_TED return TED_Picture;
   procedure From_TED (P : TED_Picture);   --  sets Screen, Colors, Background

end Bitmap_Data;
