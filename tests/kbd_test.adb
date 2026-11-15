-- ***************************************************************************
--                      AdaC64 - Kbd_Test
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

--  Checks the host-key -> C64 matrix mapping.
with Ada.Text_IO; use Ada.Text_IO;
with Interfaces; use Interfaces;
with Keyboard; use Keyboard;

procedure Kbd_Test is
   Failures : Natural := 0;

   function Down (C, R : Natural) return Boolean is
     ((Matrix (C) and Shift_Left (1, R)) /= 0);

   procedure Check (Name : String; KV : Unsigned_32; C, R : Natural;
                    Shift : Boolean; Host_Shift : Boolean := False) is
   begin
      Release_All;
      if Host_Shift then
         Key_Event (16#FFE1#, 50, True);
      end if;
      Key_Event (KV, 10, True);
      if not Down (C, R) or else Down (1, 7) /= Shift then
         Put_Line ("FAIL " & Name);
         Failures := Failures + 1;
      end if;
      Key_Event (KV, 10, False);
      if Down (C, R) then
         Put_Line ("FAIL release " & Name);
         Failures := Failures + 1;
      end if;
   end Check;
begin
   Joystick_Port := 0;
   Check ("a", Character'Pos ('a'), 1, 2, False);
   Check ("A (host shift)", Character'Pos ('A'), 1, 2, True, True);
   Check ("quote", Character'Pos ('"'), 7, 3, True, True);
   Check ("2 under host shift forced off?", Character'Pos ('2'), 7, 3, False);
   Check ("slash via shift (DK layout)", Character'Pos ('/'), 6, 7, False,
          True);
   Check ("colon", Character'Pos (':'), 5, 5, False, True);
   Check ("return", 16#FF0D#, 0, 1, False);
   Check ("cursor up", 16#FF52#, 0, 7, True);
   Check ("F2", 16#FFBF#, 0, 4, True);
   Check ("escape=stop", 16#FF1B#, 7, 7, False);
   --  Reverse/row scanning: select column 7, row 3 should read low
   Release_All;
   Key_Event (Character'Pos ('2'), 10, True);
   if Scan_Rows (not 16#80#, 16#FF#) /= (not Shift_Left (Unsigned_8'(1), 3))
   then
      Put_Line ("FAIL scan");
      Failures := Failures + 1;
   end if;
   --  Joystick on keypad
   Joystick_Port := 2;
   Release_All;
   Key_Event (16#FFB8#, 20, True);   --  KP_8
   Key_Event (16#FFE4#, 21, True);   --  Control_R
   if Joy2 /= 16#11# then
      Put_Line ("FAIL joystick" & Joy2'Image);
      Failures := Failures + 1;
   end if;
   Put_Line (if Failures = 0 then "keyboard: all tests passed"
             else Failures'Image & " failures");
end Kbd_Test;
