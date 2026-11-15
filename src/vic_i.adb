with Interfaces; use Interfaces;
with Video;
with SID; use type SID.Sink_Proc;

package body VIC_I is

   Regs : array (0 .. 15) of Byte := (others => 0);
   Standard : Standard_Kind := PAL;

   Line  : Natural := 0;
   Cycle : Natural := 0;

   --  VIC-20 colours (after VICE's default palette)
   Palette : constant array (Byte range 0 .. 15) of Types.Pixel :=
     (16#000000#, 16#FFFFFF#, 16#B61F21#, 16#4DF0FF#,
      16#B43FFF#, 16#44E237#, 16#1A34FF#, 16#DCD71B#,
      16#CA5400#, 16#E9B072#, 16#E79293#, 16#9AF7FD#,
      16#E09FFF#, 16#8FE493#, 16#8290FF#, 16#E5DE85#);

   --  Part of the picture that is shown: Win_Width VIC pixels (drawn
   --  two framebuffer pixels wide) from Win_X, lines from Win_Y
   Win_Width : constant := 192;
   function Win_X return Natural is (if Standard = PAL then 40 else 12);
   function Win_Y return Natural is (if Standard = PAL then 32 else 12);

   procedure Set_Standard (S : Standard_Kind) is
   begin
      Standard := S;
      Video.First_Visible_Line := 0;
      Video.VIC_Visible_Lines := (if S = PAL then 272 else 249);
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

   procedure Reset is
   begin
      Regs := (others => 0);
      Line := 0;
      Cycle := 0;
      Frame_Done := False;
      Voices := (others => <>);
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
         when 6 | 7 =>
            return 0;              --  light pen
         when 8 | 9 =>
            return 16#FF#;         --  paddles not connected
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

   procedure Draw_Line (L : Natural) is
      Y : constant Integer := L - Win_Y;
   begin
      if Y not in 0 .. Video.VIC_Visible_Lines - 1 then
         return;
      end if;
      declare
         H_Org  : constant Natural := Natural (Regs (0) and 16#7F#) * 4;
         V_Org  : constant Natural := Natural (Regs (1)) * 2;
         Cols   : constant Natural := Natural (Regs (2) and 16#7F#);
         Rows   : constant Natural := Natural (Shift_Right (Regs (3), 1) and 16#3F#);
         Tall   : constant Boolean := (Regs (3) and 1) /= 0;
         Char_H : constant Natural := (if Tall then 16 else 8);
         Screen : constant Word := Screen_Address;
         Chars  : constant Word := Word (Regs (5) and 15) * 16#400#;
         Back   : constant Byte := Shift_Right (Regs (15), 4);
         Border : constant Byte := Regs (15) and 7;
         Aux    : constant Byte := Shift_Right (Regs (14), 4);
         Normal : constant Boolean := (Regs (15) and 8) /= 0;
         In_Rows : constant Boolean :=
           L >= V_Org and then L < V_Org + Rows * Char_H;
         Row    : constant Natural := (if In_Rows then (L - V_Org) / Char_H
                                       else 0);
         Y_In   : constant Natural := (if In_Rows then (L - V_Org) mod Char_H
                                       else 0);
         Cell   : Natural := Natural'Last;
         Bits   : Byte := 0;
         Col_Nib : Byte := 0;
         C      : Byte;
      begin
         for X in Win_X .. Win_X + Win_Width - 1 loop
            if In_Rows and then X >= H_Org and then X < H_Org + Cols * 8 then
               declare
                  Col : constant Natural := (X - H_Org) / 8;
                  Bit : constant Natural := (X - H_Org) mod 8;
               begin
                  if Row * Cols + Col /= Cell then
                     Cell := Row * Cols + Col;
                     declare
                        Addr : constant Word :=
                          (Screen + Word (Cell)) and 16#3FFF#;
                        Code : constant Byte := Fetch (Addr);
                     begin
                        Bits := Fetch ((Chars + Word (Code) * Word (Char_H) +
                                        Word (Y_In)) and 16#3FFF#);
                        Col_Nib := Color (Natural (Addr and 16#3FF#)) and 15;
                     end;
                  end if;
                  if (Col_Nib and 8) /= 0 then
                     --  multicolour: two-pixel-wide bit pairs
                     case Shift_Right (Bits, 6 - 2 * (Bit / 2)) and 3 is
                        when 0 => C := Back;
                        when 1 => C := Border;
                        when 2 => C := Col_Nib and 7;
                        when others => C := Aux;
                     end case;
                  else
                     declare
                        On : constant Boolean :=
                          (Shift_Right (Bits, 7 - Bit) and 1) /= 0;
                     begin
                        C := (if On = Normal then Col_Nib and 7 else Back);
                     end;
                  end if;
               end;
            else
               C := Border;
            end if;
            declare
               P : constant Types.Pixel := Palette (C);
               FX : constant Natural := (X - Win_X) * 2;
            begin
               Video.VIC_FB (Y, FX) := P;
               Video.VIC_FB (Y, FX + 1) := P;
            end;
         end loop;
      end;
   end Draw_Line;

   procedure Tick (Cycles : Natural) is
      Left : Natural := Cycles;
      Step : Natural;
   begin
      Sound_Tick (Cycles);
      while Left > 0 loop
         Step := Natural'Min (Left, Cycles_Per_Line - Cycle);
         Cycle := Cycle + Step;
         Left := Left - Step;
         if Cycle >= Cycles_Per_Line then
            Cycle := 0;
            Draw_Line (Line);
            Line := Line + 1;
            if Line >= Lines_Per_Frame then
               Line := 0;
               Frame_Done := True;
            end if;
         end if;
      end loop;
   end Tick;

end VIC_I;
