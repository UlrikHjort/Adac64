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

with Interfaces; use Interfaces;

package body Keyboard is

   type Shift_Mode is (Natural_Shift, Force_Shift, Force_No_Shift);

   type Key_Pos is record
      Col : Column := 0;
      R   : Row := 0;
   end record;

   type Mapping is record
      Valid : Boolean := False;
      Key   : Key_Pos;
      Shift : Shift_Mode := Natural_Shift;
      Joy   : Byte := 0;          --  joystick bits instead of a key
      Restore : Boolean := False;
   end record;

   No_Map : constant Mapping := (others => <>);

   --  Active host keys, indexed by hardware keycode
   Active : array (0 .. 1023) of Mapping := (others => No_Map);

   --  Matrix positions
   K_DEL    : constant Key_Pos := (0, 0);
   K_RETURN : constant Key_Pos := (0, 1);
   K_RIGHT  : constant Key_Pos := (0, 2);
   K_F7     : constant Key_Pos := (0, 3);
   K_F1     : constant Key_Pos := (0, 4);
   K_F3     : constant Key_Pos := (0, 5);
   K_F5     : constant Key_Pos := (0, 6);
   K_DOWN   : constant Key_Pos := (0, 7);
   K_LSHIFT : constant Key_Pos := (1, 7);
   K_PLUS   : constant Key_Pos := (5, 0);
   K_MINUS  : constant Key_Pos := (5, 3);
   K_DOT    : constant Key_Pos := (5, 4);
   K_COLON  : constant Key_Pos := (5, 5);
   K_AT     : constant Key_Pos := (5, 6);
   K_COMMA  : constant Key_Pos := (5, 7);
   K_POUND  : constant Key_Pos := (6, 0);
   K_STAR   : constant Key_Pos := (6, 1);
   K_SEMI   : constant Key_Pos := (6, 2);
   K_HOME   : constant Key_Pos := (6, 3);
   K_RSHIFT : constant Key_Pos := (6, 4);
   K_EQUAL  : constant Key_Pos := (6, 5);
   K_UPARR  : constant Key_Pos := (6, 6);
   K_SLASH  : constant Key_Pos := (6, 7);
   K_LEFTARR : constant Key_Pos := (7, 1);
   K_CTRL   : constant Key_Pos := (7, 2);
   K_SPACE  : constant Key_Pos := (7, 4);
   K_CBM    : constant Key_Pos := (7, 5);
   K_STOP   : constant Key_Pos := (7, 7);
   --  C128 extra keys
   K_HELP   : constant Key_Pos := (8, 0);
   K_TAB    : constant Key_Pos := (8, 3);
   K_ESC    : constant Key_Pos := (9, 0);
   K_LF     : constant Key_Pos := (9, 3);
   K_ALT    : constant Key_Pos := (10, 0);
   K_NOSCRL : constant Key_Pos := (10, 7);
   K_KP8 : constant Key_Pos := (8, 1);
   K_KP5 : constant Key_Pos := (8, 2);
   K_KP2 : constant Key_Pos := (8, 4);
   K_KP4 : constant Key_Pos := (8, 5);
   K_KP7 : constant Key_Pos := (8, 6);
   K_KP1 : constant Key_Pos := (8, 7);
   K_KPPLUS  : constant Key_Pos := (9, 1);
   K_KPMINUS : constant Key_Pos := (9, 2);
   K_KPENTER : constant Key_Pos := (9, 4);
   K_KP6 : constant Key_Pos := (9, 5);
   K_KP9 : constant Key_Pos := (9, 6);
   K_KP3 : constant Key_Pos := (9, 7);
   K_KP0 : constant Key_Pos := (10, 1);
   K_KPDOT : constant Key_Pos := (10, 2);

   type Pos_Array is array (Character range <>) of Key_Pos;

   Letters : constant Pos_Array ('a' .. 'z') :=
     ('a' => (1, 2), 'b' => (3, 4), 'c' => (2, 4), 'd' => (2, 2),
      'e' => (1, 6), 'f' => (2, 5), 'g' => (3, 2), 'h' => (3, 5),
      'i' => (4, 1), 'j' => (4, 2), 'k' => (4, 5), 'l' => (5, 2),
      'm' => (4, 4), 'n' => (4, 7), 'o' => (4, 6), 'p' => (5, 1),
      'q' => (7, 6), 'r' => (2, 1), 's' => (1, 5), 't' => (2, 6),
      'u' => (3, 6), 'v' => (3, 7), 'w' => (1, 1), 'x' => (2, 7),
      'y' => (3, 1), 'z' => (1, 4));

   Digit_Keys : constant Pos_Array ('0' .. '9') :=
     ('0' => (4, 3), '1' => (7, 0), '2' => (7, 3), '3' => (1, 0),
      '4' => (1, 3), '5' => (2, 0), '6' => (2, 3), '7' => (3, 0),
      '8' => (3, 3), '9' => (4, 0));

   function Key (P : Key_Pos; S : Shift_Mode := Natural_Shift)
     return Mapping is
     ((Valid => True, Key => P, Shift => S, Joy => 0, Restore => False));

   function Joy (Bits : Byte) return Mapping is
     ((Valid => True, Key => (0, 0), Shift => Natural_Shift,
       Joy => Bits, Restore => False));

   --  GDK key values
   GDK_BackSpace : constant := 16#FF08#;
   GDK_Tab       : constant := 16#FF09#;
   GDK_Linefeed  : constant := 16#FF0A#;
   GDK_Return    : constant := 16#FF0D#;
   GDK_Escape    : constant := 16#FF1B#;
   GDK_Home      : constant := 16#FF50#;
   GDK_Left      : constant := 16#FF51#;
   GDK_Up        : constant := 16#FF52#;
   GDK_Right     : constant := 16#FF53#;
   GDK_Down      : constant := 16#FF54#;
   GDK_Page_Up   : constant := 16#FF55#;
   GDK_Page_Down : constant := 16#FF56#;
   GDK_End       : constant := 16#FF57#;
   GDK_Insert    : constant := 16#FF63#;
   GDK_Delete    : constant := 16#FFFF#;
   GDK_KP_Enter  : constant := 16#FF8D#;
   GDK_KP_Home   : constant := 16#FF95#;
   GDK_KP_Left   : constant := 16#FF96#;
   GDK_KP_Up     : constant := 16#FF97#;
   GDK_KP_Right  : constant := 16#FF98#;
   GDK_KP_Down   : constant := 16#FF99#;
   GDK_KP_Page_Up : constant := 16#FF9A#;
   GDK_KP_Page_Down : constant := 16#FF9B#;
   GDK_KP_End    : constant := 16#FF9C#;
   GDK_KP_Begin  : constant := 16#FF9D#;
   GDK_KP_Insert : constant := 16#FF9E#;
   GDK_KP_Delete : constant := 16#FF9F#;
   GDK_KP_Multiply : constant := 16#FFAA#;
   GDK_KP_Add    : constant := 16#FFAB#;
   GDK_KP_Subtract : constant := 16#FFAD#;
   GDK_KP_Decimal : constant := 16#FFAE#;
   GDK_KP_Divide : constant := 16#FFAF#;
   GDK_KP_0      : constant := 16#FFB0#;
   GDK_KP_9      : constant := 16#FFB9#;
   GDK_F1        : constant := 16#FFBE#;
   GDK_F8        : constant := 16#FFC5#;
   GDK_Shift_L   : constant := 16#FFE1#;
   GDK_Shift_R   : constant := 16#FFE2#;
   GDK_Control_L : constant := 16#FFE3#;
   GDK_Control_R : constant := 16#FFE4#;
   GDK_Alt_L     : constant := 16#FFE9#;
   GDK_Alt_R     : constant := 16#FFEA#;
   GDK_Super_L   : constant := 16#FFEB#;
   GDK_Scroll_Lock : constant := 16#FF14#;
   GDK_Pause     : constant := 16#FF13#;
   GDK_Sterling  : constant := 16#00A3#;
   GDK_Section   : constant := 16#00A7#;
   GDK_Dead_Circumflex : constant := 16#FE52#;
   GDK_Dead_Acute : constant := 16#FE51#;
   GDK_Dead_Grave : constant := 16#FE50#;

   J_Up    : constant Byte := 1;
   J_Down  : constant Byte := 2;
   J_Left  : constant Byte := 4;
   J_Right : constant Byte := 8;
   J_Fire  : constant Byte := 16;

   function Joystick_Mapping (KV : Unsigned_32) return Mapping is
   begin
      if Joystick_Port = 0 then
         return No_Map;
      end if;
      case Joystick_Keys is
         when Keypad =>
            case KV is
               when GDK_KP_0 + 8 | GDK_KP_Up => return Joy (J_Up);
               when GDK_KP_0 + 2 | GDK_KP_Down => return Joy (J_Down);
               when GDK_KP_0 + 4 | GDK_KP_Left => return Joy (J_Left);
               when GDK_KP_0 + 6 | GDK_KP_Right => return Joy (J_Right);
               when GDK_KP_0 + 7 | GDK_KP_Home => return Joy (J_Up or J_Left);
               when GDK_KP_0 + 9 | GDK_KP_Page_Up =>
                  return Joy (J_Up or J_Right);
               when GDK_KP_0 + 1 | GDK_KP_End => return Joy (J_Down or J_Left);
               when GDK_KP_0 + 3 | GDK_KP_Page_Down =>
                  return Joy (J_Down or J_Right);
               when GDK_KP_0 | GDK_KP_Insert | GDK_KP_0 + 5 | GDK_KP_Begin
                  | GDK_Control_R | GDK_KP_Enter =>
                  return Joy (J_Fire);
               when others => return No_Map;
            end case;
         when Cursor_Keys =>
            case KV is
               when GDK_Up => return Joy (J_Up);
               when GDK_Down => return Joy (J_Down);
               when GDK_Left => return Joy (J_Left);
               when GDK_Right => return Joy (J_Right);
               when GDK_Control_R | GDK_Alt_R => return Joy (J_Fire);
               when others => return No_Map;
            end case;
      end case;
   end Joystick_Mapping;

   --  C16 / Plus/4: the keys that are not where the C64 has them
   function Map_Key_Plus4 (KV : Unsigned_32) return Mapping is
      function K (C : Column; R : Row; S : Shift_Mode := Force_No_Shift)
        return Mapping is (Key ((C, R), S));
   begin
      if KV in 16#20# .. 16#7E# then
         case Character'Val (KV) is
            when '+' => return K (6, 6);
            when '-' => return K (5, 6);
            when '*' => return K (6, 1);
            when '/' => return K (6, 7);
            when '=' => return K (6, 5);
            when ':' => return K (5, 5);
            when ';' => return K (6, 2);
            when ',' => return K (5, 7);
            when '.' => return K (5, 4);
            when '@' => return K (0, 7);
            when '<' => return K (5, 7, Force_Shift);
            when '>' => return K (5, 4, Force_Shift);
            when '?' => return K (6, 7, Force_Shift);
            when '[' => return K (5, 5, Force_Shift);
            when ']' => return K (6, 2, Force_Shift);
            when '\' => return K (0, 2);
            when others => return No_Map;
         end case;
      end if;
      case KV is
         when GDK_Return => return K (0, 1, Natural_Shift);
         when GDK_BackSpace | GDK_Delete => return K (0, 0, Natural_Shift);
         when GDK_Insert => return K (0, 0, Force_Shift);
         when GDK_Home => return K (7, 1, Natural_Shift);
         when GDK_End => return K (7, 1, Force_Shift);
         when GDK_Right => return K (6, 3);
         when GDK_Left => return K (6, 0);
         when GDK_Down => return K (5, 0);
         when GDK_Up => return K (5, 3);
         when GDK_F1 => return K (0, 4);
         when GDK_F1 + 1 => return K (0, 5);
         when GDK_F1 + 2 => return K (0, 6);
         when GDK_F1 + 3 => return K (0, 4, Force_Shift);
         when GDK_F1 + 4 => return K (0, 5, Force_Shift);
         when GDK_F1 + 5 => return K (0, 6, Force_Shift);
         when GDK_F1 + 6 => return K (0, 3);              --  HELP
         when GDK_F8 => return K (0, 3, Force_Shift);
         when GDK_Shift_L | GDK_Shift_R => return K (1, 7, Natural_Shift);
         when GDK_Control_L | GDK_Control_R => return K (7, 2, Natural_Shift);
         when GDK_Alt_L | GDK_Super_L => return K (7, 5, Natural_Shift);
         when GDK_Escape => return K (7, 7, Natural_Shift);   --  RUN/STOP
         when GDK_Tab => return K (6, 4, Natural_Shift);      --  ESC
         when GDK_Sterling => return K (0, 2);
         when others => return No_Map;
      end case;
   end Map_Key_Plus4;

   --  PET graphics keyboard (row, column) as (Col, R) here
   function Map_Key_PET (KV : Unsigned_32) return Mapping is
      function K (Row : Column; Col : Keyboard.Row;
                  S : Shift_Mode := Force_No_Shift) return Mapping is
        (Key ((Row, Col), S));
   begin
      if KV in 16#20# .. 16#7E# then
         case Character'Val (KV) is
            when 'a' | 'A' => return K (4, 0, Natural_Shift);
            when 'b' | 'B' => return K (6, 2, Natural_Shift);
            when 'c' | 'C' => return K (6, 1, Natural_Shift);
            when 'd' | 'D' => return K (4, 1, Natural_Shift);
            when 'e' | 'E' => return K (2, 1, Natural_Shift);
            when 'f' | 'F' => return K (5, 1, Natural_Shift);
            when 'g' | 'G' => return K (4, 2, Natural_Shift);
            when 'h' | 'H' => return K (5, 2, Natural_Shift);
            when 'i' | 'I' => return K (3, 3, Natural_Shift);
            when 'j' | 'J' => return K (4, 3, Natural_Shift);
            when 'k' | 'K' => return K (5, 3, Natural_Shift);
            when 'l' | 'L' => return K (4, 4, Natural_Shift);
            when 'm' | 'M' => return K (6, 3, Natural_Shift);
            when 'n' | 'N' => return K (7, 2, Natural_Shift);
            when 'o' | 'O' => return K (2, 4, Natural_Shift);
            when 'p' | 'P' => return K (3, 4, Natural_Shift);
            when 'q' | 'Q' => return K (2, 0, Natural_Shift);
            when 'r' | 'R' => return K (3, 1, Natural_Shift);
            when 's' | 'S' => return K (5, 0, Natural_Shift);
            when 't' | 'T' => return K (2, 2, Natural_Shift);
            when 'u' | 'U' => return K (2, 3, Natural_Shift);
            when 'v' | 'V' => return K (7, 1, Natural_Shift);
            when 'w' | 'W' => return K (3, 0, Natural_Shift);
            when 'x' | 'X' => return K (7, 0, Natural_Shift);
            when 'y' | 'Y' => return K (3, 2, Natural_Shift);
            when 'z' | 'Z' => return K (6, 0, Natural_Shift);
            when '0' => return K (8, 6);
            when '1' => return K (6, 6);
            when '2' => return K (7, 6);
            when '3' => return K (6, 7);
            when '4' => return K (4, 6);
            when '5' => return K (5, 6);
            when '6' => return K (4, 7);
            when '7' => return K (2, 6);
            when '8' => return K (3, 6);
            when '9' => return K (2, 7);
            when '!' => return K (0, 0);
            when '"' => return K (1, 0);
            when '#' => return K (0, 1);
            when '$' => return K (1, 1);
            when '%' => return K (0, 2);
            when ''' => return K (1, 2);
            when '&' => return K (0, 3);
            when '\' => return K (1, 3);
            when '(' => return K (0, 4);
            when ')' => return K (1, 4);
            when '^' => return K (2, 5);
            when '/' => return K (3, 7);
            when ':' => return K (5, 4);
            when '*' => return K (5, 7);
            when ';' => return K (6, 4);
            when ',' => return K (7, 3);
            when '?' => return K (7, 4);
            when '+' => return K (7, 7);
            when '@' => return K (8, 1);
            when ']' => return K (8, 2);
            when '>' => return K (8, 4);
            when '-' => return K (8, 7);
            when '[' => return K (9, 1);
            when '<' => return K (9, 3);
            when '.' => return K (9, 6);
            when '=' => return K (9, 7);
            when ' ' => return K (9, 2, Natural_Shift);
            when '_' | '`' => return K (0, 5);           --  left arrow
            when others => return No_Map;
         end case;
      end if;
      case KV is
         when GDK_Return | GDK_KP_Enter => return K (6, 5, Natural_Shift);
         when GDK_BackSpace | GDK_Delete => return K (1, 7);
         when GDK_Insert => return K (1, 7, Force_Shift);
         when GDK_Home => return K (0, 6);
         when GDK_End => return K (0, 6, Force_Shift);    --  CLR
         when GDK_Down => return K (1, 6);
         when GDK_Up => return K (1, 6, Force_Shift);
         when GDK_Right => return K (0, 7);
         when GDK_Left => return K (0, 7, Force_Shift);
         when GDK_Escape => return K (9, 4, Natural_Shift);   --  STOP
         when GDK_Tab => return K (9, 0, Natural_Shift);      --  RVS
         when GDK_Shift_L => return K (8, 0, Natural_Shift);
         when GDK_Shift_R => return K (8, 5, Natural_Shift);
         when others => return No_Map;
      end case;
   end Map_Key_PET;

   function Map_Key (KV : Unsigned_32) return Mapping is
      J : constant Mapping := Joystick_Mapping (KV);
   begin
      if Layout = PET then
         return Map_Key_PET (KV);           --  (no joystick port)
      end if;
      if J.Valid then
         return J;
      end if;
      if Layout = Plus4 then
         declare
            P : constant Mapping := Map_Key_Plus4 (KV);
         begin
            if P.Valid then
               return P;
            elsif KV not in Character'Pos ('a') .. Character'Pos ('z')
                          | Character'Pos ('A') .. Character'Pos ('Z')
                          | Character'Pos ('0') .. Character'Pos ('9')
                          | Character'Pos (' ') .. Character'Pos (')')
            then
               return No_Map;        --  no such key on the Plus/4
            end if;
         end;
      end if;

      if KV in 16#20# .. 16#7E# then
         declare
            C : constant Character := Character'Val (KV);
         begin
            case C is
               when 'a' .. 'z' => return Key (Letters (C));
               when 'A' .. 'Z' =>
                  return Key (Letters (Character'Val
                                (Character'Pos (C) + 32)));
               when '0' .. '9' => return Key (Digit_Keys (C), Force_No_Shift);
               when ' ' => return Key (K_SPACE);
               when '!' => return Key (Digit_Keys ('1'), Force_Shift);
               when '"' => return Key (Digit_Keys ('2'), Force_Shift);
               when '#' => return Key (Digit_Keys ('3'), Force_Shift);
               when '$' => return Key (Digit_Keys ('4'), Force_Shift);
               when '%' => return Key (Digit_Keys ('5'), Force_Shift);
               when '&' => return Key (Digit_Keys ('6'), Force_Shift);
               when ''' => return Key (Digit_Keys ('7'), Force_Shift);
               when '(' => return Key (Digit_Keys ('8'), Force_Shift);
               when ')' => return Key (Digit_Keys ('9'), Force_Shift);
               when '+' => return Key (K_PLUS, Force_No_Shift);
               when '-' => return Key (K_MINUS, Force_No_Shift);
               when '*' => return Key (K_STAR, Force_No_Shift);
               when '/' => return Key (K_SLASH, Force_No_Shift);
               when '=' => return Key (K_EQUAL, Force_No_Shift);
               when ':' => return Key (K_COLON, Force_No_Shift);
               when ';' => return Key (K_SEMI, Force_No_Shift);
               when ',' => return Key (K_COMMA, Force_No_Shift);
               when '.' => return Key (K_DOT, Force_No_Shift);
               when '@' => return Key (K_AT, Force_No_Shift);
               when '<' => return Key (K_COMMA, Force_Shift);
               when '>' => return Key (K_DOT, Force_Shift);
               when '?' => return Key (K_SLASH, Force_Shift);
               when '[' => return Key (K_COLON, Force_Shift);
               when ']' => return Key (K_SEMI, Force_Shift);
               when '^' => return Key (K_UPARR, Force_No_Shift);
               when '_' => return Key (K_LEFTARR, Force_No_Shift);
               when '\' => return Key (K_POUND, Force_No_Shift);
               when '`' => return Key (K_LEFTARR, Force_No_Shift);
               when '{' => return Key (K_COLON, Force_Shift);
               when '}' => return Key (K_SEMI, Force_Shift);
               when '|' => return Key (K_POUND, Force_Shift);
               when '~' => return Key (K_UPARR, Force_Shift);
               when others => return No_Map;
            end case;
         end;
      end if;

      case KV is
         when GDK_Return => return Key (K_RETURN);
         when GDK_KP_Enter => return Key (K_KPENTER);
         when GDK_BackSpace => return Key (K_DEL);
         when GDK_Delete => return Key (K_DEL);
         when GDK_Insert => return Key (K_DEL, Force_Shift);
         when GDK_Home => return Key (K_HOME);
         when GDK_End => return Key (K_HOME, Force_Shift);
         when GDK_Right => return Key (K_RIGHT, Force_No_Shift);
         when GDK_Left => return Key (K_RIGHT, Force_Shift);
         when GDK_Down => return Key (K_DOWN, Force_No_Shift);
         when GDK_Up => return Key (K_DOWN, Force_Shift);
         when GDK_F1 => return Key (K_F1, Force_No_Shift);
         when GDK_F1 + 1 => return Key (K_F1, Force_Shift);
         when GDK_F1 + 2 => return Key (K_F3, Force_No_Shift);
         when GDK_F1 + 3 => return Key (K_F3, Force_Shift);
         when GDK_F1 + 4 => return Key (K_F5, Force_No_Shift);
         when GDK_F1 + 5 => return Key (K_F5, Force_Shift);
         when GDK_F1 + 6 => return Key (K_F7, Force_No_Shift);
         when GDK_F8 => return Key (K_F7, Force_Shift);
         when GDK_Shift_L => return Key (K_LSHIFT);
         when GDK_Shift_R => return Key (K_RSHIFT);
         when GDK_Control_L | GDK_Control_R => return Key (K_CTRL);
         when GDK_Alt_L | GDK_Super_L => return Key (K_CBM);
         when GDK_Escape => return Key (K_STOP);
         when GDK_Tab => return Key (K_TAB);
         when GDK_Linefeed => return Key (K_LF);
         when GDK_Page_Up =>
            return (Valid => True, Key => (0, 0), Shift => Natural_Shift,
                    Joy => 0, Restore => True);
         when GDK_Page_Down => return Key (K_HELP);
         when GDK_Pause => return Key (K_ESC);
         when GDK_Alt_R => return Key (K_ALT);
         when GDK_Scroll_Lock => return Key (K_NOSCRL);
         when GDK_Sterling => return Key (K_POUND, Force_No_Shift);
         when GDK_Section | GDK_Dead_Acute => return Key (K_LEFTARR);
         when GDK_Dead_Circumflex => return Key (K_UPARR, Force_No_Shift);
         when GDK_Dead_Grave => return Key (K_LEFTARR);
         when GDK_KP_0 => return Key (K_KP0);
         when GDK_KP_0 + 1 => return Key (K_KP1);
         when GDK_KP_0 + 2 => return Key (K_KP2);
         when GDK_KP_0 + 3 => return Key (K_KP3);
         when GDK_KP_0 + 4 => return Key (K_KP4);
         when GDK_KP_0 + 5 => return Key (K_KP5);
         when GDK_KP_0 + 6 => return Key (K_KP6);
         when GDK_KP_0 + 7 => return Key (K_KP7);
         when GDK_KP_0 + 8 => return Key (K_KP8);
         when GDK_KP_9 => return Key (K_KP9);
         when GDK_KP_Add => return Key (K_KPPLUS);
         when GDK_KP_Subtract => return Key (K_KPMINUS);
         when GDK_KP_Decimal | GDK_KP_Delete => return Key (K_KPDOT);
         when GDK_KP_Multiply => return Key (K_STAR, Force_No_Shift);
         when GDK_KP_Divide => return Key (K_SLASH, Force_No_Shift);
         when others => return No_Map;
      end case;
   end Map_Key;

   Host_Bits : Byte := 0;

   --  Positional mapping by X11 hardware keycode (evdev code + 8) for the
   --  main key block; other keys use the symbolic mapping.
   function Positional_Map (Code : Natural) return Mapping is
      function P (C : Column; R : Row) return Mapping is (Key ((C, R)));
   begin
      case Code is
         when 49 => return P (7, 1);                 --  `  -> left arrow
         when 10 => return P (7, 0);                 --  1
         when 11 => return P (7, 3);                 --  2
         when 12 => return P (1, 0);                 --  3
         when 13 => return P (1, 3);                 --  4
         when 14 => return P (2, 0);                 --  5
         when 15 => return P (2, 3);                 --  6
         when 16 => return P (3, 0);                 --  7
         when 17 => return P (3, 3);                 --  8
         when 18 => return P (4, 0);                 --  9
         when 19 => return P (4, 3);                 --  0
         when 20 => return P (5, 0);                 --  -  -> +
         when 21 => return P (5, 3);                 --  =  -> -
         when 22 => return P (0, 0);                 --  Backspace -> DEL
         when 23 => return P (7, 2);                 --  Tab -> CTRL
         when 24 => return P (7, 6);                 --  q
         when 25 => return P (1, 1);                 --  w
         when 26 => return P (1, 6);                 --  e
         when 27 => return P (2, 1);                 --  r
         when 28 => return P (2, 6);                 --  t
         when 29 => return P (3, 1);                 --  y
         when 30 => return P (3, 6);                 --  u
         when 31 => return P (4, 1);                 --  i
         when 32 => return P (4, 6);                 --  o
         when 33 => return P (5, 1);                 --  p
         when 34 => return P (5, 6);                 --  [  -> @
         when 35 => return P (6, 1);                 --  ]  -> *
         when 36 => return P (0, 1);                 --  Return
         when 37 => return P (7, 5);                 --  Ctrl_L -> C=
         when 38 => return P (1, 2);                 --  a
         when 39 => return P (1, 5);                 --  s
         when 40 => return P (2, 2);                 --  d
         when 41 => return P (2, 5);                 --  f
         when 42 => return P (3, 2);                 --  g
         when 43 => return P (3, 5);                 --  h
         when 44 => return P (4, 2);                 --  j
         when 45 => return P (4, 5);                 --  k
         when 46 => return P (5, 2);                 --  l
         when 47 => return P (5, 5);                 --  ;  -> :
         when 48 => return P (6, 2);                 --  '  -> ;
         when 51 => return P (6, 5);                 --  \ -> =
         when 94 => return P (6, 0);                 --  <> -> pound
         when 119 => return P (6, 6);                --  Delete -> up arrow
         when 50 => return P (1, 7);                 --  Shift_L
         when 52 => return P (1, 4);                 --  z
         when 53 => return P (2, 7);                 --  x
         when 54 => return P (2, 4);                 --  c
         when 55 => return P (3, 7);                 --  v
         when 56 => return P (3, 4);                 --  b
         when 57 => return P (4, 7);                 --  n
         when 58 => return P (4, 4);                 --  m
         when 59 => return P (5, 7);                 --  ,
         when 60 => return P (5, 4);                 --  .
         when 61 => return P (6, 7);                 --  /
         when 62 => return P (6, 4);                 --  Shift_R
         when 65 => return P (7, 4);                 --  space
         when others => return No_Map;
      end case;
   end Positional_Map;

   procedure Rebuild is
      Force_S, Force_NS : Boolean := False;
      J : Byte := Host_Bits;
   begin
      Matrix := (others => 0);
      Restore_Down := False;
      for M of Active loop
         if M.Valid then
            if M.Joy /= 0 then
               J := J or M.Joy;
            elsif M.Restore then
               Restore_Down := True;
            else
               Matrix (M.Key.Col) := Matrix (M.Key.Col) or
                 Shift_Left (1, M.Key.R);
               case M.Shift is
                  when Force_Shift => Force_S := True;
                  when Force_No_Shift => Force_NS := True;
                  when Natural_Shift => null;
               end case;
            end if;
         end if;
      end loop;
      if Layout = PET then
         --  shift keys at row 8, columns 0 and 5
         if Force_S then
            Matrix (8) := Matrix (8) or 1;
         elsif Force_NS then
            Matrix (8) := Matrix (8) and not 16#21#;
         end if;
      elsif Force_S then
         Matrix (K_LSHIFT.Col) := Matrix (K_LSHIFT.Col) or
           Shift_Left (1, K_LSHIFT.R);
      elsif Force_NS then
         Matrix (K_LSHIFT.Col) := Matrix (K_LSHIFT.Col) and
           not Shift_Left (1, K_LSHIFT.R);
         if Layout = C64 then         --  (the Plus/4 has ESC there)
            Matrix (K_RSHIFT.Col) := Matrix (K_RSHIFT.Col) and
              not Shift_Left (1, K_RSHIFT.R);
         end if;
      end if;
      Joy1 := 0;
      Joy2 := 0;
      case Joystick_Port is
         when 1 => Joy1 := J;
         when 2 => Joy2 := J;
         when 0 => null;
      end case;
   end Rebuild;

   procedure Set_Host_Joystick (Bits : Byte) is
   begin
      if Bits /= Host_Bits then
         Host_Bits := Bits;
         Rebuild;
      end if;
   end Set_Host_Joystick;

   function Host_Joystick_Bits return Byte is (Host_Bits);

   procedure Key_Event
     (Keyval  : Unsigned_32;
      Keycode : Natural;
      Pressed : Boolean)
   is
      Code : constant Natural := Keycode mod Active'Length;
   begin
      if Pressed then
         declare
            J : constant Mapping := Joystick_Mapping (Keyval);
            PM : constant Mapping :=
              (if Positional and then not J.Valid and then Layout = C64
               then Positional_Map (Keycode) else No_Map);
            M : constant Mapping := (if PM.Valid then PM else Map_Key (Keyval));
         begin
            if M.Valid then
               Active (Code) := M;
            end if;
         end;
      else
         Active (Code) := No_Map;
      end if;
      Rebuild;
   end Key_Event;

   procedure Release_All is
   begin
      Active := (others => No_Map);
      Rebuild;
   end Release_All;

   procedure Press (Col : Column; R : Row; Down : Boolean) is
   begin
      if Down then
         Matrix (Col) := Matrix (Col) or Shift_Left (1, R);
      else
         Matrix (Col) := Matrix (Col) and not Shift_Left (1, R);
      end if;
   end Press;

   function Scan_Rows (Col_Select : Byte; Ext_Select : Byte) return Byte is
      Rows : Byte := 0;
   begin
      for C in 0 .. 7 loop
         if (Col_Select and Shift_Left (1, C)) = 0 then
            Rows := Rows or Matrix (C);
         end if;
      end loop;
      for C in 8 .. 10 loop
         if (Ext_Select and Shift_Left (1, C - 8)) = 0 then
            Rows := Rows or Matrix (C);
         end if;
      end loop;
      return not Rows;
   end Scan_Rows;

   function Scan_Cols (Row_Select : Byte) return Byte is
      Cols : Byte := 0;
   begin
      for C in 0 .. 7 loop
         if (Matrix (C) and not Row_Select) /= 0 then
            Cols := Cols or Shift_Left (1, C);
         end if;
      end loop;
      return not Cols;
   end Scan_Cols;

   Typing : String (1 .. 4096);
   Typing_Len, Typing_Pos : Natural := 0;
   Typing_Phase : Natural := 0;
   Typing_Code : constant Natural := 1000;   --  pseudo hardware keycode

   procedure Type_Keys (S : String) is
   begin
      for C of S loop
         if Typing_Len < Typing'Last then
            Typing_Len := Typing_Len + 1;
            Typing (Typing_Len) := C;
         end if;
      end loop;
   end Type_Keys;

   procedure Tick_Typing is
   begin
      if Typing_Pos >= Typing_Len then
         Typing_Pos := 0;
         Typing_Len := 0;
         return;
      end if;
      Typing_Phase := Typing_Phase + 1;
      if Typing_Phase = 1 then
         declare
            C : constant Character := Typing (Typing_Pos + 1);
            KV : constant Unsigned_32 :=
              (if C = ASCII.LF or else C = ASCII.CR then GDK_Return
               else Character'Pos (C));
         begin
            Active (Typing_Code) := Map_Key (KV);
            Rebuild;
         end;
      elsif Typing_Phase = 4 then
         Active (Typing_Code) := No_Map;
         Rebuild;
      elsif Typing_Phase >= 7 then
         Typing_Phase := 0;
         Typing_Pos := Typing_Pos + 1;
      end if;
   end Tick_Typing;

end Keyboard;
