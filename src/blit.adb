-- ***************************************************************************
--                      AdaC64 - Blit
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

with System;
with Glib; use Glib;
with Cairo.Image_Surface; use Cairo.Image_Surface;
with Cairo.Surface;
with Cairo.Png;
with Types; use Types;
with Video; use Video;

package body Blit is

   function Width (S : Source) return Natural is
     (case S is when VIC_Screen => VIC_Visible_Width,
                when VDC_Screen => VDC_Width);
   function Height (S : Source) return Natural is
     (case S is when VIC_Screen => VIC_Visible_Lines,
                when VDC_Screen => VDC_Height);

   procedure Copy (S : Source; Surface : Cairo.Cairo_Surface) is
      W : constant Natural := Width (S);
      H : constant Natural := Height (S);
      Stride : constant Natural := Natural (Get_Stride (Surface)) / 4;
      Addr : constant System.Address := Get_Data_Generic (Surface);
      type Pixels is array (0 .. H - 1, 0 .. Stride - 1) of Pixel;
      Dst : Pixels;
      for Dst'Address use Addr;
      pragma Import (Ada, Dst);
   begin
      Cairo.Surface.Flush (Surface);
      for Y in 0 .. H - 1 loop
         for X in 0 .. W - 1 loop
            Dst (Y, X) := (case S is
                              when VIC_Screen => VIC_FB (Y, X),
                              when VDC_Screen => VDC_FB (Y, X));
         end loop;
      end loop;
      Cairo.Surface.Mark_Dirty (Surface);
   end Copy;

   procedure Save_PNG (S : Source; Path : String) is
      Surf : constant Cairo.Cairo_Surface :=
        Create (Cairo_Format_RGB24, Gint (Width (S)), Gint (Height (S)));
      Status : Cairo.Cairo_Status;
   begin
      Copy (S, Surf);
      Status := Cairo.Png.Write_To_Png (Surf, Path);
      pragma Unreferenced (Status);
      Cairo.Surface.Destroy (Surf);
   end Save_PNG;

end Blit;
