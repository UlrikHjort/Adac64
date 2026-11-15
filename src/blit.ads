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

--  Copying the emulator framebuffers into Cairo surfaces, and PNG export.

with Cairo;

package Blit is

   type Source is (VIC_Screen, VDC_Screen);

   function Width (S : Source) return Natural;
   function Height (S : Source) return Natural;

   PAL_Blur : Boolean := False;
   --  Mix each pixel with its left and right neighbours (1/4, 1/2, 1/4),
   --  as a PAL TV's limited bandwidth does (not for the 80-column VDC)

   procedure Copy (S : Source; Surface : Cairo.Cairo_Surface);
   --  Surface must be an RGB24 image surface of the source's size.

   procedure Save_PNG (S : Source; Path : String);

end Blit;
