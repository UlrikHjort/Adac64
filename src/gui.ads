-- ***************************************************************************
--                      AdaC64 - GUI
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

--  GtkAda front end.

with Ada.Strings.Unbounded;
with Machine;

package GUI is

   Drive_Choice : Ada.Strings.Unbounded.Unbounded_String;
   Standard_Given : Boolean := False;   --  --pal / --ntsc on the command line
   SID_Given : Boolean := False;        --  --sid on the command line
   Paddles_Given : Boolean := False;    --  --paddles on the command line
   Open_Forge : Boolean := False;      --  --forge: open the forge window
   Forge_File : Ada.Strings.Unbounded.Unbounded_String;
   --  "1541" / "1571" from the command line ("" = use the saved setting)

   procedure Run (Model : Machine.Model_Type; ROM_Dir : String;
                  File : String;
                  Model_Given : Boolean := False;
                  Key80_Given : Boolean := False;
                  REU_Given : Boolean := False);
   --  Model_Given / Key80_Given: set on the command line (they override
   --  the saved settings).

end GUI;
