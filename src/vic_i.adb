with Interfaces; use Interfaces;
with Video;
with SID; use type SID.Sink_Proc;

package body VIC_I is

   Regs : array (0 .. 15) of Byte := (others => 0);
   Standard : Standard_Kind := PAL;

   Line  : Natural := 0;
   Cycle : Natural := 0;

   --  Light pen: latched position, target in beam coordinates
   LP_X : Byte := 87;
   LP_Y : Byte := 234;
   Pen_On : Boolean := False;
   Pen_Line, Pen_Cycle : Natural := 0;
   Pen_Latched : Boolean := False;

   --  VIC-20 colours (after VICE's default palette)
   Palette : constant array (Byte range 0 .. 15) of Types.Pixel :=
     (16#000000#, 16#FFFFFF#, 16#B61F21#, 16#4DF0FF#,
      16#B43FFF#, 16#44E237#, 16#1A34FF#, 16#DCD71B#,
      16#CA5400#, 16#E9B072#, 16#E79293#, 16#9AF7FD#,
      16#E09FFF#, 16#8FE493#, 16#8290FF#, 16#E5DE85#);

   --  Part of the picture that is shown, as in VICE: the whole line
   --  (4 pixels per cycle) and the lines from Win_Y on
   function Win_Y return Natural is (28);

   procedure Set_Standard (S : Standard_Kind) is
   begin
      Standard := S;
      Video.First_Visible_Line := 0;
      Video.VIC_Visible_Lines := (if S = PAL then 284 else 233);
      Video.VIC_Visible_Width := (if S = PAL then 284 else 260);
      --  pixel width / height: dot clock 4.43 MHz (PAL) or 4.09 MHz (NTSC)
      --  against the 7.88 / 8.18 MHz of the C64 the window is made for
      Video.X_Aspect := (if S = PAL then 1.78 else 2.0);
      Cycle := 0;
      Line := 0;
   end Set_Standard;

   function Clock_Hz return Natural is
     (if Standard = PAL then 1_108_405 else 1_022_727);
   function Cycles_Per_Line return Positive is
     (if Standard = PAL then 71 else 65);
   function Lines_Per_Frame return Positive is
     (if Standard = PAL then 312 else 261);

   ---------------------------------------------------------------------
   --  Sound
   ---------------------------------------------------------------------

   type Voice is record
      Counter : Natural := 0;
      Out_High : Boolean := False;
   end record;
   Voices : array (0 .. 3) of Voice;
   --  CPU cycles per output toggle unit: bass, alto, soprano, noise
   Divider : constant array (0 .. 3) of Positive := (256, 128, 64, 32);
   Noise_LFSR : Unsigned_16 := 16#ACE1#;
   Sample_Acc : Float := 0.0;
   DC_Prev_In, DC_Prev_Out : Float := 0.0;

   procedure Sound_Tick (Cycles : Natural) is
      Per_Sample : constant Float :=
        Float (Clock_Hz) / Float (SID.Sample_Rate);
   begin
      for N in 1 .. Cycles loop
         for V in 0 .. 3 loop
            declare
               R : constant Byte := Regs (16#0A# + V);
            begin
               if (R and 16#80#) /= 0 then
                  Voices (V).Counter := Voices (V).Counter + 1;
                  --  period: Divider * (127 - value) cycles, as measured
                  --  against VICE (value 127 = the highest pitch)
                  if Voices (V).Counter >=
                    Divider (V) * Natural'Max (1, 127 - Natural (R and 16#7F#))
                      / 2
                  then
                     Voices (V).Counter := 0;
                     if V = 3 then
                        --  noise: 16-bit LFSR
                        declare
                           B : constant Unsigned_16 :=
                             (Noise_LFSR xor Shift_Right (Noise_LFSR, 2) xor
                              Shift_Right (Noise_LFSR, 3) xor
                              Shift_Right (Noise_LFSR, 5)) and 1;
                        begin
                           Noise_LFSR := Shift_Right (Noise_LFSR, 1) or
                             Shift_Left (B, 15);
                           Voices (V).Out_High := (Noise_LFSR and 1) /= 0;
                        end;
                     else
                        Voices (V).Out_High := not Voices (V).Out_High;
                     end if;
                  end if;
               end if;
            end;
         end loop;
         Sample_Acc := Sample_Acc + 1.0;
         if Sample_Acc >= Per_Sample then
            Sample_Acc := Sample_Acc - Per_Sample;
            declare
               Sum : Float := 0.0;
               Vol : constant Float := Float (Regs (16#0E#) and 15) / 15.0;
               Y : Float;
            begin
               for V in 0 .. 3 loop
                  if (Regs (16#0A# + V) and 16#80#) /= 0
                    and then Voices (V).Out_High
                  then
                     Sum := Sum + 1.0;
                  end if;
               end loop;
               --  DC blocker, as the VIC-20's output is AC coupled
               Y := Sum * Vol * 0.22 - DC_Prev_In + 0.995 * DC_Prev_Out;
               DC_Prev_In := Sum * Vol * 0.22;
               DC_Prev_Out := Y;
               if SID.Sink /= null then
                  SID.Sink (SID.Sample
                    (Integer (Float'Max (-1.0, Float'Min (1.0, Y)) * 30000.0)));
               end if;
            end;
         end if;
      end loop;
   end Sound_Tick;

   ---------------------------------------------------------------------
   --  Registers
   ---------------------------------------------------------------------

   procedure Reset_Video;

   procedure Reset is
   begin
      Regs := (others => 0);
      Line := 0;
      Cycle := 0;
      Frame_Done := False;
      Voices := (others => <>);
      Reset_Video;
   end Reset;

   function Raster return Natural is (Line);

   function Read (Reg : Natural) return Byte is
      R : constant Natural := Reg mod 16;
   begin
      case R is
         when 3 =>
            return (Regs (3) and 16#7F#) or
              (if Line mod 2 = 1 then 16#80# else 0);
         when 4 =>
            return Byte ((Line / 2) mod 256);
         when 6 =>
            return LP_X;           --  light pen
         when 7 =>
            return LP_Y;
         when 8 =>
            return Pot_X;          --  paddles
         when 9 =>
            return Pot_Y;
         when others =>
            return Regs (R);
      end case;
   end Read;

   procedure Write (Reg : Natural; Value : Byte) is
   begin
      Regs (Reg mod 16) := Value;
   end Write;

   function Register (Reg : Natural) return Byte is (Regs (Reg mod 16));

   function Screen_Address return Word is
     (Word (Shift_Right (Regs (5), 4)) * 16#400# +
      (if (Regs (2) and 16#80#) /= 0 then 16#200# else 0));

   ---------------------------------------------------------------------
   --  Video
   ---------------------------------------------------------------------

   --  Drawing follows the beam: every CPU cycle puts 4 pixels of the
   --  current line on screen with the registers as they are then.  The
   --  text area works like the chip (and VICE): while idle the vertical
   --  origin is compared with the raster every cycle; once open the area
   --  runs until its row counter reaches the number of rows, using an
   --  internal character-line counter and matrix pointer, so programs can
   --  change height, rows or addresses in the middle of the frame.
   type Area_State is (Idle, Pending, Display, Done);
   Area : Area_State := Idle;
   Y_Counter   : Natural := 0;   --  pixel line within the character row
   Row_Counter : Natural := 0;
   Memptr      : Natural := 0;   --  matrix index of the current row
   H_Open      : Boolean := False;
   H_Start     : Natural := 0;   --  first pixel of the text in this line
   Line_Cols   : Natural := 0;   --  columns latched when the line opened
   Line_Blank  : Boolean := True;
   Was_Blank   : Boolean := True;
   Cell : Natural := Natural'Last;
   Bits, Col_Nib : Byte := 0;

   procedure Reset_Video is
   begin
      Area := Idle;
      Row_Counter := 0;
      Y_Counter := 0;
      Memptr := 0;
   end Reset_Video;

   function Char_Height return Natural is
     (if (Regs (3) and 1) /= 0 then 16 else 8);
   function Rows_Reg return Natural is
     (Natural (Shift_Right (Regs (3), 1) and 16#3F#));

   procedure Draw_Cycle (L, C : Natural) is
      Y : constant Integer := L - Win_Y;
   begin
      --  vertical flip-flop
      if Area = Idle and then Natural (Regs (1)) = L / 2 then
         Area := (if Rows_Reg = 0 then Done else Pending);
      end if;
      --  horizontal flip-flop
      if Area in Pending | Display and then not H_Open
        and then Natural (Regs (0) and 16#7F#) = C
      then
         H_Open := True;
         H_Start := C * 4;
         Line_Cols := Natural (Regs (2) and 16#7F#);
         Cell := Natural'Last;
         if Area = Pending then
            Area := Display;
         end if;
         if Line_Cols > 0 then
            Line_Blank := False;
         end if;
      end if;
      --  next character row
      if Area = Display and then C = 0
        and then (Y_Counter = Char_Height or else Y_Counter = 2 * Char_Height)
      then
         Y_Counter := 0;
         Memptr := Memptr + (if Was_Blank then 0 else Line_Cols);
         Row_Counter := Row_Counter + 1;
         if Row_Counter >= Rows_Reg then
            Area := Done;
         end if;
      end if;

      if Y not in 0 .. Video.VIC_Visible_Lines - 1
        or else C * 4 >= Video.VIC_Visible_Width
      then
         return;
      end if;
      declare
         Back   : constant Byte := Shift_Right (Regs (15), 4);
         Border : constant Byte := Regs (15) and 7;
         Aux    : constant Byte := Shift_Right (Regs (14), 4);
         Normal : constant Boolean := (Regs (15) and 8) /= 0;
         Char_H : constant Natural := Char_Height;
         P      : Byte;
      begin
         for X in C * 4 .. C * 4 + 3 loop
            if Area = Display and then H_Open and then X >= H_Start
              and then X < H_Start + Line_Cols * 8
            then
               declare
                  Col : constant Natural := (X - H_Start) / 8;
                  Bit : constant Natural := (X - H_Start) mod 8;
               begin
                  if Col /= Cell then
                     Cell := Col;
                     declare
                        Addr : constant Word :=
                          (Screen_Address + Word ((Memptr + Col) mod 16#4000#))
                          and 16#3FFF#;
                        Code : constant Byte := Fetch (Addr);
                     begin
                        Bits := Fetch
                          ((Word (Regs (5) and 15) * 16#400# +
                            Word (Code) * Word (Char_H) +
                            Word (Y_Counter mod Char_H))
                           and 16#3FFF#);
                        Col_Nib := Color (Natural (Addr and 16#3FF#)) and 15;
                     end;
                  end if;
                  if (Col_Nib and 8) /= 0 then
                     --  multicolour: two-pixel-wide bit pairs
                     case Shift_Right (Bits, 6 - 2 * (Bit / 2)) and 3 is
                        when 0 => P := Back;
                        when 1 => P := Border;
                        when 2 => P := Col_Nib and 7;
                        when others => P := Aux;
                     end case;
                  else
                     P := (if ((Shift_Right (Bits, 7 - Bit) and 1) /= 0)
                             = Normal then Col_Nib and 7 else Back);
                  end if;
               end;
            else
               P := Border;
            end if;
            if X < Video.VIC_Visible_Width then
               Video.VIC_FB (Y, X) := Palette (P);
            end if;
         end loop;
      end;
   end Draw_Cycle;

   procedure Set_Light_Pen (FX, FY : Float; On : Boolean) is
      function Clamp (F : Float) return Float is
        (Float'Max (0.0, Float'Min (0.999, F)));
   begin
      Pen_On := On;
      Pen_Line := 28 + Natural (Clamp (FY) * Float (Video.VIC_Visible_Lines));
      Pen_Cycle := Natural (Clamp (FX) * Float (Video.VIC_Visible_Width)) / 4;
   end Set_Light_Pen;

   procedure Tick (Cycles : Natural) is
   begin
      Sound_Tick (Cycles);
      for N in 1 .. Cycles loop
         if Pen_On and then not Pen_Latched and then Line = Pen_Line
           and then Cycle = Pen_Cycle
         then
            --  the pen sees the beam
            LP_X := Byte ((2 * ((Cycle + 1) mod Cycles_Per_Line)) mod 256)
              or 1;
            LP_Y := Byte ((Line / 2) mod 256);
            Pen_Latched := True;
         end if;
         Draw_Cycle (Line, Cycle);
         Cycle := Cycle + 1;
         if Cycle >= Cycles_Per_Line then
            --  end of line
            Cycle := 0;
            if Area = Display then
               Y_Counter := Y_Counter + 1;
            end if;
            Was_Blank := Line_Blank;
            Line_Blank := True;
            H_Open := False;
            Line := Line + 1;
            if Line >= Lines_Per_Frame then
               --  end of frame
               Line := 0;
               Area := Idle;
               Row_Counter := 0;
               Y_Counter := 0;
               Memptr := 0;
               Pen_Latched := False;
               Frame_Done := True;
            end if;
         end if;
      end loop;
   end Tick;

   type Reg_Array is array (0 .. 15) of Byte;
   type Voice_Array is array (0 .. 3) of Voice;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Reg_Array'Write (S, Reg_Array (Regs));
      Standard_Kind'Write (S, Standard);
      Natural'Write (S, Line);
      Natural'Write (S, Cycle);
      Byte'Write (S, LP_X);
      Byte'Write (S, LP_Y);
      Voice_Array'Write (S, Voice_Array (Voices));
      Unsigned_16'Write (S, Noise_LFSR);
      Area_State'Write (S, Area);
      Natural'Write (S, Y_Counter);
      Natural'Write (S, Row_Counter);
      Natural'Write (S, Memptr);
      Boolean'Write (S, H_Open);
      Natural'Write (S, H_Start);
      Natural'Write (S, Line_Cols);
      Boolean'Write (S, Line_Blank);
      Boolean'Write (S, Was_Blank);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
      R : Reg_Array;
      V : Voice_Array;
      Std : Standard_Kind;
   begin
      Reg_Array'Read (S, R);
      Standard_Kind'Read (S, Std);
      Set_Standard (Std);
      for I in R'Range loop
         Regs (I) := R (I);
      end loop;
      Natural'Read (S, Line);
      Natural'Read (S, Cycle);
      Byte'Read (S, LP_X);
      Byte'Read (S, LP_Y);
      Voice_Array'Read (S, V);
      for I in V'Range loop
         Voices (I) := V (I);
      end loop;
      Unsigned_16'Read (S, Noise_LFSR);
      Area_State'Read (S, Area);
      Natural'Read (S, Y_Counter);
      Natural'Read (S, Row_Counter);
      Natural'Read (S, Memptr);
      Boolean'Read (S, H_Open);
      Natural'Read (S, H_Start);
      Natural'Read (S, Line_Cols);
      Boolean'Read (S, Line_Blank);
      Boolean'Read (S, Was_Blank);
      Cell := Natural'Last;
      Frame_Done := False;
   end Load_State;

end VIC_I;
