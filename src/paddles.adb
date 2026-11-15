with Interfaces; use Interfaces;
package body Paddles is

   Hold : array (1 .. 2) of Natural := (others => 0);   --  acceleration

   function To_Value (F : Float) return Byte is
     (Byte (255 - Integer (Float'Max (0.0, Float'Min (1.0, F)) * 255.0)));

   procedure Set_Mouse (FX, FY : Float) is
   begin
      Pen_X := FX;
      Pen_Y := FY;
      if Mode = Mouse then
         Value (1) := To_Value (FX);
         Value (2) := To_Value (FY);
      end if;
   end Set_Mouse;

   procedure Set_Mouse_Button (Button : Positive; Down : Boolean) is
   begin
      if Mode = Light_Pen and then Button = 1 then
         Pen_Down := Down;
      end if;
      if Mode = Mouse and then Button <= 2 then
         Fire (Button) := Down;
      end if;
   end Set_Mouse_Button;

   procedure Tick (Joy : Byte) is
      procedure Turn (P : Positive; Up, Down : Boolean) is
         Step : Natural;
      begin
         if Up = Down then
            Hold (P) := 0;
            return;
         end if;
         Hold (P) := Hold (P) + 1;
         Step := Natural'Min (1 + Hold (P) / 3, 8);   --  speeds up when held
         if Up then
            Value (P) := Byte (Natural'Min (255, Natural (Value (P)) + Step));
         else
            Value (P) := Byte (Integer'Max (0, Integer (Value (P)) - Step));
         end if;
      end Turn;
   begin
      if Mode /= Joystick then
         return;
      end if;
      --  left raises paddle 1 and right lowers it (like the mouse), up
      --  raises paddle 2
      Turn (1, (Joy and 4) /= 0, (Joy and 8) /= 0);
      Turn (2, (Joy and 1) /= 0, (Joy and 2) /= 0);
      Fire (1) := (Joy and 16) /= 0;
      Fire (2) := False;
   end Tick;

   function Fire_Bits return Byte is
     ((if Fire (1) then 4 else 0) or (if Fire (2) then 8 else 0));

end Paddles;
