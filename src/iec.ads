-- ***************************************************************************
--                      AdaC64 - IEC
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

--  The Commodore serial (IEC) bus: open-collector ATN, CLK and DATA lines.
--  True means "line pulled low" (asserted).

package IEC is

   --  Computer side (from CIA2 port A through the 7406 inverters)
   C64_ATN, C64_CLK, C64_DATA : Boolean := False;

   --  Drive side (from 1541 VIA1 port B)
   Drive_CLK, Drive_DATA, Drive_ATNA : Boolean := False;
   Drive_Present : Boolean := False;

   function ATN return Boolean is (C64_ATN);

   function CLK return Boolean is
     (C64_CLK or else (Drive_Present and then Drive_CLK));

   --  The 1541 hardware pulls DATA low whenever ATN and its ATN-acknowledge
   --  output disagree, which is how a drive answers ATN automatically.
   function DATA return Boolean is
     (C64_DATA or else
        (Drive_Present and then (Drive_DATA or else (C64_ATN /= Drive_ATNA))));

end IEC;
