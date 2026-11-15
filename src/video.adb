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

with Interfaces; use Interfaces;

package body Video is

   function Distance (A, B : Pixel) return Natural is
      function C (P : Pixel; Shift : Natural) return Integer is
        (Integer (Shift_Right (Unsigned_32 (P), Shift) and 16#FF#));
      DR : constant Integer := C (A, 16) - C (B, 16);
      DG : constant Integer := C (A, 8) - C (B, 8);
      DB : constant Integer := C (A, 0) - C (B, 0);
   begin
      return DR * DR + DG * DG + DB * DB;
   end Distance;

   function Brightness (P : Pixel) return Natural is
     (299 * Natural (Shift_Right (Unsigned_32 (P), 16) and 16#FF#)
      + 587 * Natural (Shift_Right (Unsigned_32 (P), 8) and 16#FF#)
      + 114 * Natural (Unsigned_32 (P) and 16#FF#));

   --  The TED's hues are the C64's colours 0-9 by name; the C64's light
   --  colours and greys are brighter luminances of them
   Hue_Of : constant array (Byte range 0 .. 15) of Byte :=
     (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 2, 1, 1, 5, 6, 1);

   function To_TED (C : Byte) return Byte is
      V : constant Natural := Brightness (VIC_Palette (C mod 16));
      Best : Byte := 0;
      Best_D : Natural := Natural'Last;
   begin
      if C mod 16 = 0 then
         return 0;
      end if;
      for Lum in Byte range 0 .. 7 loop
         declare
            T : constant Byte := Lum * 16 + Hue_Of (C mod 16);
            D : constant Natural :=
              abs (Integer (Brightness (TED_Palette (T))) - Integer (V));
         begin
            if D < Best_D then
               Best_D := D;
               Best := T;
            end if;
         end;
      end loop;
      return Best;
   end To_TED;

   function From_TED (C : Byte) return Byte is
      Best : Byte := 0;
      Best_D : Natural := Natural'Last;
   begin
      for V in VIC_Palette'Range loop
         if To_TED (V) = C mod 128 then
            return V;                       --  one we send ourselves
         end if;
      end loop;
      for V in VIC_Palette'Range loop
         if Distance (VIC_Palette (V), TED_Palette (C mod 128)) < Best_D then
            Best_D := Distance (VIC_Palette (V), TED_Palette (C mod 128));
            Best := V;
         end if;
      end loop;
      return Best;
   end From_TED;

end Video;
