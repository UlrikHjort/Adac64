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

   type Mode_Kind is (Off, Mouse, Joystick);
   Mode : Mode_Kind := Off;

   function Active return Boolean is (Mode /= Off);

   Value : array (1 .. 2) of Byte := (others => 128);
   Fire  : array (1 .. 2) of Boolean := (others => False);

   procedure Set_Mouse (FX, FY : Float);
   --  Mouse position as fractions (0.0 .. 1.0) across the picture
   procedure Set_Mouse_Button (Button : Positive; Down : Boolean);

   procedure Tick (Joy : Byte);
   --  Once per frame: in joystick mode, turn the paddles from the
   --  joystick bits (0 up, 1 down, 2 left, 3 right, 4 fire).

   function Fire_Bits return Byte;
   --  The paddle buttons as joystick bits: paddle 1 = left (bit 2),
   --  paddle 2 = right (bit 3)

end Paddles;
