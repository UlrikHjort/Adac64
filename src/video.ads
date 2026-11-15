-- ***************************************************************************
--                      AdaC64 - Video
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

--  Framebuffers and palettes shared between the video chips and the GUI.

with Types; use Types;

package Video is

   --  VIC-II output (PAL): 384 x 272 visible pixels
   VIC_Width  : constant := 384;
   VIC_Height : constant := 272;
   First_Visible_Line : Natural := 16;    --  NTSC: 14
   VIC_Visible_Lines  : Natural := VIC_Height;   --  NTSC: 249
   VIC_Visible_Width  : Natural := VIC_Width;    --  VIC-20: 284 / 260
   X_Aspect : Float := 1.0;
   --  Width of a framebuffer pixel relative to its height (the VIC-20's
   --  pixels are almost twice as wide as the C64's)

   FB_Lines : constant := 288;        --  room for the VIC-20's 284 lines
   type VIC_Frame is array (0 .. FB_Lines - 1, 0 .. VIC_Width - 1) of Pixel;
   VIC_FB : VIC_Frame := (others => (others => 0));

   --  VDC (8563) output: up to 640 x 200 text/bitmap area plus border
   VDC_Width  : constant := 704;
   VDC_Height : constant := 264;

   type VDC_Frame is array (0 .. VDC_Height - 1, 0 .. VDC_Width - 1) of Pixel;
   VDC_FB : VDC_Frame := (others => (others => 0));

   type Palette is array (Byte range 0 .. 15) of Pixel;

   --  "Pepto" PAL VIC-II palette
   VIC_Palette : constant Palette :=
     (16#000000#, 16#FFFFFF#, 16#68372B#, 16#70A4B2#,
      16#6F3D86#, 16#588D43#, 16#352879#, 16#B8C76F#,
      16#6F4F25#, 16#433900#, 16#9A6759#, 16#444444#,
      16#6C6C6C#, 16#9AD284#, 16#6C5EB5#, 16#959595#);

   --  RGBI palette used by the VDC (bit 3 = R, 2 = G, 1 = B, 0 = I)
   VDC_Palette : constant Palette :=
     (16#000000#, 16#555555#, 16#0000AA#, 16#5555FF#,
      16#00AA00#, 16#55FF55#, 16#00AAAA#, 16#55FFFF#,
      16#AA0000#, 16#FF5555#, 16#AA00AA#, 16#FF55FF#,
      16#AA5500#, 16#FFFF55#, 16#AAAAAA#, 16#FFFFFF#);

   --  TED (C16 / Plus/4) colours: bits 0-3 hue, bits 4-6 luminance, as
   --  VICE shows them
   type TED_Palette_Type is array (Byte range 0 .. 127) of Pixel;
   TED_Palette : constant TED_Palette_Type :=
     (16#000000#, 16#313131#, 16#740d00#, 16#004e56#,
      16#6c0081#, 16#006000#, 16#2312bb#, 16#3d4b00#,
      16#6a2300#, 16#573900#, 16#1e5800#, 16#75004c#,
      16#005a10#, 16#0029aa#, 16#4200bb#, 16#005f00#,
      16#000000#, 16#444444#, 16#83251b#, 16#005f66#,
      16#7c0b90#, 16#007000#, 16#3729c9#, 16#4f5c00#,
      16#7a3700#, 16#674b00#, 16#336800#, 16#84155d#,
      16#006a27#, 16#1a3cb8#, 16#5318c8#, 16#146f00#,
      16#000000#, 16#565656#, 16#923930#, 16#036f76#,
      16#8b239f#, 16#127f00#, 16#4a3cd6#, 16#606c00#,
      16#894a00#, 16#775c00#, 16#457800#, 16#932b6d#,
      16#007a3b#, 16#2f4ec6#, 16#642ed5#, 16#2a7e00#,
      16#000000#, 16#666666#, 16#a04b43#, 16#1e7e85#,
      16#9937ad#, 16#298e07#, 16#5b4ee3#, 16#707c00#,
      16#985b00#, 16#866c00#, 16#578700#, 16#a13e7d#,
      16#1c894d#, 16#425fd3#, 16#7441e3#, 16#3d8d00#,
      16#000000#, 16#8d8d8d#, 16#c3746d#, 16#4ea3a9#,
      16#bc63cf#, 16#57b23e#, 16#8277ff#, 16#96a000#,
      16#bb8236#, 16#aa9200#, 16#7eab00#, 16#c469a1#,
      16#4dad76#, 16#6c86f3#, 16#996bff#, 16#68b105#,
      16#000000#, 16#a2a2a2#, 16#d78b84#, 16#67b8be#,
      16#d17be3#, 16#6fc759#, 16#988dff#, 16#abb505#,
      16#cf9851#, 16#bfa825#, 16#95c007#, 16#d880b6#,
      16#66c18d#, 16#839cff#, 16#af82ff#, 16#7fc62a#,
      16#000000#, 16#cccccc#, 16#feb5af#, 16#95e0e6#,
      16#f7a7ff#, 16#9cee88#, 16#c2b8ff#, 16#d4de46#,
      16#f6c281#, 16#e7d15c#, 16#bfe748#, 16#ffacdf#,
      16#94e9b7#, 16#afc6ff#, 16#d7aeff#, 16#abed60#,
      16#000000#, 16#ffffff#, 16#ffebe5#, 16#ccffff#,
      16#ffddff#, 16#d3ffc1#, 16#f7edff#, 16#ffff87#,
      16#fff7bb#, 16#ffff99#, 16#f3ff88#, 16#ffe2ff#,
      16#ccffec#, 16#e4faff#, 16#ffe3ff#, 16#e1ff9d#);

   function To_TED (C : Byte) return Byte;
   --  The TED colour for VIC-II colour C (0 .. 15): the same hue (light
   --  colours and greys as brighter luminances), the closest brightness
   function From_TED (C : Byte) return Byte;
   --  The VIC-II colour nearest to TED colour C (bit 7 ignored)

end Video;
