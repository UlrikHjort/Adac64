-- ***************************************************************************
--                      AdaC64 - Keyboard
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

--  C64 / C128 keyboard matrix and joystick state, plus mapping of host
--  (GDK) key values onto the matrix.

with Interfaces;
with Types; use Types;

package Keyboard is

   --  Matrix columns 0..7 are selected by CIA1 port A; columns 8..10 are
   --  the C128 extra lines K0..K2 driven by VIC register $D02F.
   subtype Column is Natural range 0 .. 10;
   subtype Row is Natural range 0 .. 7;

   type Matrix_Type is array (Column) of Byte;   --  bit set = key down
   Matrix : Matrix_Type := (others => 0);

   --  Joystick bits (active high here): 0 up, 1 down, 2 left, 3 right, 4 fire
   Joy1, Joy2 : Byte := 0;

   type Joy_Keyset is (Keypad, Cursor_Keys);
   type Joy_Port is range 0 .. 2;    --  0 = no joystick emulation
   Joystick_Port : Joy_Port := 2;
   Joystick_Keys : Joy_Keyset := Keypad;

   Restore_Down : Boolean := False;

   type Layout_Kind is (C64, Plus4, PET);
   --  PET: the graphics keyboard (10 rows of 8; Matrix (row) holds a row's
   --  keys; digits and most symbols have keys of their own)
   Layout : Layout_Kind := C64;
   --  Plus4: the C16 / Plus/4 matrix (the keys outside the letters and
   --  digits sit elsewhere; F1-F3, HELP, ESC and four cursor keys)

   Positional : Boolean := False;
   --  False: symbolic mapping (type the character you mean).
   --  True:  positional mapping (PC key positions = C64 key positions,
   --         shift works like on the C64 keyboard).

   procedure Key_Event
     (Keyval  : Interfaces.Unsigned_32;
      Keycode : Natural;
      Pressed : Boolean);
   --  Host key event. Keycode is the hardware keycode used to pair
   --  press and release events.

   procedure Release_All;

   function Scan_Rows (Col_Select : Byte; Ext_Select : Byte) return Byte;
   --  Returns the row lines (active low) for the selected columns
   --  (active low in Col_Select / Ext_Select).

   function Scan_Cols (Row_Select : Byte) return Byte;
   --  Reverse scan: columns (active low) seen when rows are driven.

   procedure Press (Col : Column; R : Row; Down : Boolean);

   procedure Set_Host_Joystick (Bits : Byte);
   --  State of a host game controller (same bit layout as Joy1/Joy2); it
   --  is combined with the keyboard joystick keys.

   function Host_Joystick_Bits return Byte;

   procedure Type_Keys (S : String);
   --  Queue text to be typed through the keyboard matrix (works for
   --  programs that scan the keyboard themselves, e.g. CP/M); LF = RETURN.

   procedure Tick_Typing;
   --  Advance matrix typing; call once per frame.

end Keyboard;
