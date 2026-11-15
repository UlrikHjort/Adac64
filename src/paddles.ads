-- ***************************************************************************
--                      AdaC64 - Paddles
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

--  Paddles (a pair of potentiometers with a fire button each) for the
--  VIC-20 ($9008 / $9009) and the C64 (SID $D419 / $D41A).
--
--  Mouse mode: the mouse position over the picture sets the paddles
--  (x = paddle 1, y = paddle 2; moving right / down lowers the value, as
--  in VICE), the left / right button fire paddle 1 / 2.
--  Joystick mode: left / right turn paddle 1, up / down paddle 2, fire is
--  paddle 1's button (any joystick source: keys or a game controller).
--  While paddles are on, the joystick lines carry only the paddle buttons.

with Types; use Types;

package Paddles is

   type Mode_Kind is (Off, Mouse, Joystick, Light_Pen);
   Mode : Mode_Kind := Off;
   --  Light_Pen (VIC-20): the mouse is a light pen; holding the left button
   --  is "pen on the screen" (the VIC latches the beam position when it
   --  passes the pen, and the pen's switch shows on the fire line).

   function Active return Boolean is (Mode in Mouse | Joystick);
   function Pen_Active return Boolean is (Mode = Light_Pen);

   Pen_X, Pen_Y : Float := 0.5;     --  pen position across the picture
   Pen_Down : Boolean := False;

   Value : array (1 .. 2) of Byte := (others => 128);
   Fire  : array (1 .. 2) of Boolean := (others => False);

   procedure Set_Mouse (FX, FY : Float);
   --  Mouse position as fractions (0.0 .. 1.0) across the picture
   procedure Set_Mouse_Button (Button : Positive; Down : Boolean);

   procedure Tick (Joy : Byte);
   --  Once per frame: in joystick mode, turn the paddles from the
   --  joystick bits (0 up, 1 down, 2 left, 3 right, 4 fire).

   function Fire_Bits return Byte;
   function Pen_Bits return Byte is (if Pen_Down then 16 else 0);
   --  The paddle buttons as joystick bits: paddle 1 = left (bit 2),
   --  paddle 2 = right (bit 3)

end Paddles;
