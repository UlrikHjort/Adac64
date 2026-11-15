-- ***************************************************************************
--                      AdaC64 - CRT
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

--  CRT cartridge image files (the VICE/CCS64 format).

with Types; use Types;

package CRT is

   Max_Banks : constant := 128;
   Bank_Size : constant := 16#4000#;    --  ROML (8K) followed by ROMH (8K)

   type Cart_Type is
     (Normal, Ocean, Magic_Desk, Game_System, Dinamic, Easy_Flash,
      Unsupported);

   type Bank_Flags is array (0 .. Max_Banks - 1) of Boolean;

   type Image is record
      Kind       : Cart_Type := Normal;
      Hw_Type    : Natural := 0;        --  number from the CRT header
      Exrom_Low  : Boolean := False;    --  initial line states (True = asserted)
      Game_Low   : Boolean := False;
      Banks      : Natural := 0;
      Has_ROMH   : Bank_Flags := (others => False);
      Name       : String (1 .. 32) := (others => ' ');
   end record;

   procedure Load (Path : String; Info : out Image;
                   Data : out Byte_Array_Access; Ok : out Boolean);
   --  Data receives Banks * Bank_Size bytes: bank n's ROML at n*$4000 and
   --  ROMH at n*$4000 + $2000.  Unused space is $FF.

end CRT;
