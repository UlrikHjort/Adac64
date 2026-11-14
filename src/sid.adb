with Interfaces; use Interfaces;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;

package body SID is
   pragma Suppress (All_Checks);

   Regs : array (0 .. 31) of Byte := (others => 0);

   type Env_State is (Attack, Decay_Sustain, Release);

   type Voice is record
      Acc        : U32 := 0;        --  24-bit phase accumulator
      Freq       : U32 := 0;
      PW         : U32 := 0;        --  12-bit pulse width
      Control    : Byte := 0;
      Noise      : U32 := 16#7FFFF8#;
      Prev_Bit19 : Boolean := False;
      Env        : Env_State := Release;
      Level      : Natural := 0;    --  0 .. 255
      Rate_Count : Natural := 0;
      Exp_Count  : Natural := 0;
      Hold_Zero  : Boolean := True;
      MSB_Rise   : Boolean := False;   --  for hard sync
   end record;

   Voices : array (0 .. 2) of Voice;

   Rate_Periods : constant array (0 .. 15) of Natural :=
     (9, 32, 63, 95, 149, 220, 267, 313,
      392, 977, 1954, 3126, 3907, 11720, 19532, 31251);

   Sustain_Levels : constant array (0 .. 15) of Natural :=
     (0, 16#11#, 16#22#, 16#33#, 16#44#, 16#55#, 16#66#, 16#77#,
      16#88#, 16#99#, 16#AA#, 16#BB#, 16#CC#, 16#DD#, 16#EE#, 16#FF#);

   --  Cycles remaining until the next output sample
   Cycles_Per_Sample : constant Float := Float (Clock_Rate) /
                                          Float (Sample_Rate);
   Cycle_Acc : Float := 0.0;

   --  Filter state (Chamberlin state variable filter)
   Filt_LP, Filt_BP : Float := 0.0;

   --  DC-blocking high-pass on the output
   DC_Prev_In, DC_Prev_Out : Float := 0.0;

   Last_Write : Byte := 0;

   procedure Reset is
   begin
      Regs := (others => 0);
      Voices := (others => <>);
      Cycle_Acc := 0.0;
      Filt_LP := 0.0;
      Filt_BP := 0.0;
   end Reset;

   function Read (Reg : Natural) return Byte is
   begin
      case Reg mod 32 is
         when 16#19# | 16#1A# =>
            return 16#FF#;    --  paddles not connected
         when 16#1B# =>
            return Byte (Shift_Right (Voices (2).Acc, 16) and 16#FF#);
         when 16#1C# =>
            return Byte (Voices (2).Level);
         when others =>
            return Last_Write;
      end case;
   end Read;

   procedure Write (Reg : Natural; Value : Byte) is
      R : constant Natural := Reg mod 32;
      V : constant Natural := R / 7;
      O : constant Natural := R mod 7;
   begin
      Regs (R) := Value;
      Last_Write := Value;
      if R < 21 then
         declare
            Vo : Voice renames Voices (V);
            Base : constant Natural := V * 7;
         begin
            case O is
               when 0 | 1 =>
                  Vo.Freq := U32 (Regs (Base)) or
                    Shift_Left (U32 (Regs (Base + 1)), 8);
               when 2 | 3 =>
                  Vo.PW := U32 (Regs (Base + 2)) or
                    Shift_Left (U32 (Regs (Base + 3) and 15), 8);
               when 4 =>
                  declare
                     Old_Gate : constant Boolean := (Vo.Control and 1) /= 0;
                     New_Gate : constant Boolean := (Value and 1) /= 0;
                  begin
                     if not Old_Gate and then New_Gate then
                        Vo.Env := Attack;
                        Vo.Hold_Zero := False;
                     elsif Old_Gate and then not New_Gate then
                        Vo.Env := Release;
                     end if;
                     if (Value and 8) /= 0 then
                        Vo.Acc := 0;
                        Vo.Noise := 16#7FFFF8#;
                     end if;
                     Vo.Control := Value;
                  end;
               when others =>
                  null;
            end case;
         end;
      end if;
   end Write;

   procedure Clock_Envelope (Idx : Natural; Cycles : Natural) is
      Vo : Voice renames Voices (Idx);
      AD : constant Byte := Regs (Idx * 7 + 5);
      SR : constant Byte := Regs (Idx * 7 + 6);
      Rate : Natural;
      Period : Natural;
   begin

      case Vo.Env is
         when Attack => Rate := Natural (Shift_Right (AD, 4));
         when Decay_Sustain => Rate := Natural (AD and 15);
         when Release => Rate := Natural (SR and 15);
      end case;
      Period := Rate_Periods (Rate);

      Vo.Rate_Count := Vo.Rate_Count + Cycles;
      while Vo.Rate_Count >= Period loop
         Vo.Rate_Count := Vo.Rate_Count - Period;

         if Vo.Env = Attack then
            Vo.Level := Vo.Level + 1;
            if Vo.Level >= 255 then
               Vo.Level := 255;
               Vo.Env := Decay_Sustain;
            end if;
         else
            --  Exponential decay approximation
            declare
               Exp_Period : constant Natural :=
                 (if Vo.Level >= 16#5D# then 1
                  elsif Vo.Level >= 16#36# then 2
                  elsif Vo.Level >= 16#1A# then 4
                  elsif Vo.Level >= 16#0E# then 8
                  elsif Vo.Level >= 16#06# then 16
                  else 30);
            begin
               Vo.Exp_Count := Vo.Exp_Count + 1;
               if Vo.Exp_Count >= Exp_Period then
                  Vo.Exp_Count := 0;
                  if Vo.Env = Decay_Sustain then
                     if Vo.Level > Sustain_Levels
                       (Natural (Shift_Right (SR, 4)))
                     then
                        Vo.Level := Vo.Level - 1;
                     end if;
                  elsif Vo.Level > 0 then
                     Vo.Level := Vo.Level - 1;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Clock_Envelope;

   function Waveform (I : Natural) return Integer is
      Vo  : Voice renames Voices (I);
      Src : constant Natural := (if I = 0 then 2 else I - 1);
      Acc : constant U32 := Vo.Acc;
      Ctl : constant Byte := Vo.Control;
      Out_V : U32 := 16#FFF#;
      Any : Boolean := False;
   begin
      if (Ctl and 16#10#) /= 0 then    --  triangle
         declare
            Msb : U32 := Acc and 16#800000#;
            T : U32;
         begin
            if (Ctl and 16#04#) /= 0 then   --  ring modulation
               Msb := Msb xor (Voices (Src).Acc and 16#800000#);
            end if;
            T := Shift_Right (Acc, 11) and 16#FFF#;
            if Msb /= 0 then
               T := T xor 16#FFF#;
            end if;
            Out_V := Out_V and T;
            Any := True;
         end;
      end if;
      if (Ctl and 16#20#) /= 0 then    --  sawtooth
         Out_V := Out_V and Shift_Right (Acc, 12);
         Any := True;
      end if;
      if (Ctl and 16#40#) /= 0 then    --  pulse
         if (Ctl and 16#08#) /= 0
           or else Shift_Right (Acc, 12) >= Vo.PW
         then
            Out_V := Out_V and 16#FFF#;
         else
            Out_V := 0;
         end if;
         Any := True;
      end if;
      if (Ctl and 16#80#) /= 0 then    --  noise
         declare
            N : constant U32 := Vo.Noise;
            NV : constant U32 :=
              Shift_Left (Shift_Right (N, 22) and 1, 11) or
              Shift_Left (Shift_Right (N, 20) and 1, 10) or
              Shift_Left (Shift_Right (N, 16) and 1, 9) or
              Shift_Left (Shift_Right (N, 13) and 1, 8) or
              Shift_Left (Shift_Right (N, 11) and 1, 7) or
              Shift_Left (Shift_Right (N, 7) and 1, 6) or
              Shift_Left (Shift_Right (N, 4) and 1, 5) or
              Shift_Left (Shift_Right (N, 2) and 1, 4);
         begin
            Out_V := Out_V and NV;
            Any := True;
         end;
      end if;
      if not Any then
         return 0;
      end if;
      --  Centre around zero, scale by envelope (result about +-2048*255)
      return (Integer (Out_V) - 2048) * Vo.Level;
   end Waveform;

   procedure Clock_Oscillators (Cycles : Natural) is
   begin
      for I in Voices'Range loop
         declare
            Vo : Voice renames Voices (I);
            Old : constant U32 := Vo.Acc;
         begin
            if (Vo.Control and 8) = 0 then
               Vo.Acc := (Vo.Acc + Vo.Freq * U32 (Cycles)) and 16#FFFFFF#;
            end if;
            Vo.MSB_Rise := (Old and 16#800000#) = 0
              and then (Vo.Acc and 16#800000#) /= 0;
            --  Noise LFSR clocked on bit 19 rising edges
            declare
               B19 : constant Boolean := (Vo.Acc and 16#80000#) /= 0;
               Steps : Natural := 0;
            begin
               if Vo.Freq * U32 (Cycles) >= 16#100000# then
                  Steps := Natural (Vo.Freq * U32 (Cycles) / 16#100000#);
               elsif B19 and then not Vo.Prev_Bit19 then
                  Steps := 1;
               end if;
               for S in 1 .. Steps loop
                  declare
                     N : constant U32 := Vo.Noise;
                     FB : constant U32 :=
                       (Shift_Right (N, 22) xor Shift_Right (N, 17)) and 1;
                  begin
                     Vo.Noise := (Shift_Left (N, 1) or FB) and 16#7FFFFF#;
                  end;
               end loop;
               Vo.Prev_Bit19 := B19;
            end;
         end;
      end loop;
      --  Hard sync
      for I in Voices'Range loop
         declare
            Src : constant Natural := (if I = 0 then 2 else I - 1);
         begin
            if (Voices (I).Control and 2) /= 0
              and then Voices (Src).MSB_Rise
            then
               Voices (I).Acc := 0;
            end if;
         end;
      end loop;
   end Clock_Oscillators;

   function Make_Sample return Sample is
      Filt_Route : constant Byte := Regs (16#17#);
      Mode_Vol   : constant Byte := Regs (16#18#);
      Volume     : constant Float := Float (Mode_Vol and 15) / 15.0;
      Direct, Filtered : Float := 0.0;
      V : Float;
      Out_F : Float;
   begin
      for I in Voices'Range loop
         V := Float (Waveform (I)) / (2048.0 * 255.0);   --  -1 .. 1
         if I = 2 and then (Mode_Vol and 16#80#) /= 0
           and then (Filt_Route and 4) = 0
         then
            null;   --  voice 3 disconnected
         elsif (Filt_Route and Shift_Left (1, I)) /= 0 then
            Filtered := Filtered + V;
         else
            Direct := Direct + V;
         end if;
      end loop;

      if (Mode_Vol and 16#70#) /= 0 and then (Filt_Route and 7) /= 0 then
         declare
            Cutoff_Reg : constant Natural :=
              Natural (Regs (16#15#) and 7) + Natural (Regs (16#16#)) * 8;
            Fc : constant Float := 30.0 + Float (Cutoff_Reg) * 5.8;
            F  : constant Float :=
              2.0 * Sin (Ada.Numerics.Pi * Float'Min (Fc, 12_000.0) /
                         Float (Sample_Rate));
            Res : constant Float := Float (Shift_Right (Filt_Route, 4));
            Q  : constant Float := 1.0 / (0.707 + Res / 15.0 * 1.5);
            HP : Float;
            Sum : Float := 0.0;
         begin
            HP := Filtered - Filt_LP - Q * Filt_BP;
            Filt_BP := Filt_BP + F * HP;
            Filt_LP := Filt_LP + F * Filt_BP;
            if (Mode_Vol and 16#10#) /= 0 then Sum := Sum + Filt_LP; end if;
            if (Mode_Vol and 16#20#) /= 0 then Sum := Sum + Filt_BP; end if;
            if (Mode_Vol and 16#40#) /= 0 then Sum := Sum + HP; end if;
            Direct := Direct + Sum;
         end;
      elsif (Filt_Route and 7) /= 0 then
         null;   --  filter selected but no mode: voices silent
      end if;

      --  Volume register DC offset makes "digi" playback audible
      Out_F := Direct * Volume * 0.3 + Volume * 0.15;

      --  DC blocker
      declare
         Y : constant Float := Out_F - DC_Prev_In + 0.995 * DC_Prev_Out;
      begin
         DC_Prev_In := Out_F;
         DC_Prev_Out := Y;
         Out_F := Y;
      end;

      Out_F := Float'Max (-1.0, Float'Min (1.0, Out_F));
      return Sample (Integer (Out_F * 32000.0));
   end Make_Sample;

   procedure Advance (N : Natural) is
   begin
      Clock_Oscillators (N);
      for I in Voices'Range loop
         Clock_Envelope (I, N);
      end loop;
   end Advance;

   procedure Clock (Cycles : Natural) is
      Left : Natural := Cycles;
      N    : Natural;
   begin
      while Left > 0 loop
         N := Natural (Float'Ceiling (Cycle_Acc));
         if N < 1 then
            N := 1;
         end if;
         if N > Left then
            N := Left;
         end if;
         Advance (N);
         Left := Left - N;
         Cycle_Acc := Cycle_Acc - Float (N);
         if Cycle_Acc <= 0.0 then
            Cycle_Acc := Cycle_Acc + Cycles_Per_Sample;
            if Sink /= null then
               Sink (Make_Sample);
            end if;
         end if;
      end loop;
   end Clock;

end SID;
