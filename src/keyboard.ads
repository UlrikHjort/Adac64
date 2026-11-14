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
