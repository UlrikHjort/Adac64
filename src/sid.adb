with Interfaces; use Interfaces;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;

package body SID is
   pragma Suppress (All_Checks);

   type Reg_Array is array (0 .. 31) of Byte;
   Regs : Reg_Array := (others => 0);

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

   type Voice_Array is array (0 .. 2) of Voice;
   Voices : Voice_Array;

   Rate_Periods : constant array (0 .. 15) of Natural :=
     (9, 32, 63, 95, 149, 220, 267, 313,
      392, 977, 1954, 3126, 3907, 11720, 19532, 31251);

   Sustain_Levels : constant array (0 .. 15) of Natural :=
     (0, 16#11#, 16#22#, 16#33#, 16#44#, 16#55#, 16#66#, 16#77#,
      16#88#, 16#99#, 16#AA#, 16#BB#, 16#CC#, 16#DD#, 16#EE#, 16#FF#);

   --  Cycles remaining until the next output sample
   Cycles_Per_Sample : Float := Float (Clock_Rate) /
                                          Float (Sample_Rate);
   Cycle_Acc : Float := 0.0;

   --  Filter state (Chamberlin state variable filter)
   Filt_LP, Filt_BP : Float := 0.0;

   --  DC-blocking high-pass on the output
   DC_Prev_In, DC_Prev_Out : Float := 0.0;

   Last_Write : Byte := 0;

   Chip : Chip_Model := MOS6581;

   --  Combined waveforms (index: control bits 6..4 = P S T) as a function
   --  of the 12-bit sawtooth value.  On the real chips the selected
   --  waveform outputs are wired together and zero bits pull their
   --  neighbours down: the 6581 gives sparse, quiet results, the 8580
   --  fuller ones.  The tables come from a neighbour-weighted bit model.
   type Combo_Table is array (Chip_Model, 3 .. 7, 0 .. 4095) of U32;
   Combo : Combo_Table;

   --  Filter cutoff coefficient per FC register value (11 bits), for a
   --  Chamberlin filter run at 4x the output sample rate.
   Oversample : constant := 4;
   type Cutoff_Table is array (Chip_Model, 0 .. 2047) of Float;
   Cutoff_F : Cutoff_Table;

   procedure Set_Model (M : Chip_Model) is
   begin
      Chip := M;
   end Set_Model;

   function Model return Chip_Model is (Chip);

   procedure Build_Tables is
      type Point is record
         Reg : Natural;
         Hz  : Float;
      end record;
      type Curve is array (Positive range <>) of Point;
      --  Measured cutoff curves (approximately, after reSID's f0 points);
      --  the 6581 has its characteristic jump at register value 1024.
      C6581 : constant Curve :=
        ((0, 220.0), (128, 230.0), (256, 250.0), (384, 300.0),
         (512, 420.0), (640, 780.0), (768, 1600.0), (832, 2300.0),
         (896, 3200.0), (960, 4300.0), (992, 5000.0), (1008, 5400.0),
         (1016, 5700.0), (1023, 6000.0), (1024, 4600.0), (1032, 4800.0),
         (1056, 5300.0), (1088, 6000.0), (1120, 6600.0), (1152, 7200.0),
         (1280, 9500.0), (1408, 12000.0), (1536, 14500.0),
         (1664, 16000.0), (1792, 17100.0), (1920, 17700.0),
         (2047, 18000.0));
      C8580 : constant Curve :=
        ((0, 30.0), (128, 800.0), (256, 1600.0), (384, 2500.0),
         (512, 3300.0), (640, 4100.0), (768, 4800.0), (896, 5600.0),
         (1024, 6500.0), (1152, 7500.0), (1280, 8400.0), (1408, 9200.0),
         (1536, 9800.0), (1664, 10500.0), (1792, 11000.0),
         (1920, 11700.0), (2047, 12500.0));

      function Interp (C : Curve; R : Natural) return Float is
      begin
         for K in C'First .. C'Last - 1 loop
            if R >= C (K).Reg and then R < C (K + 1).Reg then
               return C (K).Hz + (C (K + 1).Hz - C (K).Hz) *
                 Float (R - C (K).Reg) / Float (C (K + 1).Reg - C (K).Reg);
            end if;
         end loop;
         return C (C'Last).Hz;
      end Interp;

      type Thresholds is array (3 .. 7) of Float;
      Thr : constant array (Chip_Model) of Thresholds :=
        (MOS6581 => (3 => 0.80, 4 => 1.0, 5 => 0.90, 6 => 0.93, 7 => 0.85),
         MOS8580 => (3 => 0.62, 4 => 1.0, 5 => 0.70, 6 => 0.72, 7 => 0.68));
      Weight : array (0 .. 11) of Float;
   begin
      for M in Chip_Model loop
         for R in 0 .. 2047 loop
            declare
               Hz : constant Float :=
                 (if M = MOS6581 then Interp (C6581, R) else Interp (C8580, R));
            begin
               Cutoff_F (M, R) := 2.0 * Sin (Ada.Numerics.Pi * Hz /
                                    Float (Sample_Rate * Oversample));
            end;
         end loop;
      end loop;

      for D in Weight'Range loop
         Weight (D) := 0.5 ** D;
      end loop;
      for M in Chip_Model loop
         for C in 3 .. 7 loop
            for Saw in 0 .. 4095 loop
               declare
                  Tri : constant Natural :=
                    (if Saw >= 2048 then 4095 - (Saw * 2) mod 4096
                     else (Saw * 2) mod 4096);
                  Inp : array (0 .. 11) of Float;
                  N : Float;
                  V : U32 := 0;
               begin
                  for I in 0 .. 11 loop
                     N := 0.0;
                     Inp (I) := 0.0;
                     if C mod 2 = 1 then
                        Inp (I) := Inp (I) + Float ((Tri / 2 ** I) mod 2);
                        N := N + 1.0;
                     end if;
                     if (C / 2) mod 2 = 1 then
                        Inp (I) := Inp (I) + Float ((Saw / 2 ** I) mod 2);
                        N := N + 1.0;
                     end if;
                     Inp (I) := (if N > 0.0 then Inp (I) / N else 1.0);
                  end loop;
                  for I in 0 .. 11 loop
                     if Inp (I) >= 1.0 then
                        declare
                           Num, Den : Float := 0.0;
                        begin
                           for J in 0 .. 11 loop
                              Num := Num + Weight (abs (I - J)) * Inp (J);
                              Den := Den + Weight (abs (I - J));
                           end loop;
                           if Num / Den >= Thr (M) (C) then
                              V := V or Shift_Left (1, I);
                           end if;
                        end;
                     end if;
                  end loop;
                  Combo (M, C, Saw) := V;
               end;
            end loop;
         end loop;
      end loop;
   end Build_Tables;

   procedure Set_Clock (Hz : Natural) is
   begin
      Clock_Rate := Hz;
      Cycles_Per_Sample := Float (Hz) / Float (Sample_Rate);
   end Set_Clock;

   procedure Reset is
   begin
      Regs := (others => 0);
      Voices := (others => <>);
      Cycle_Acc := 0.0;
      Filt_LP := 0.0;
      Filt_BP := 0.0;
   end Reset;

   function Wave_Bits (I : Natural; Any : out Boolean) return U32;

   function Read (Reg : Natural) return Byte is
   begin
      case Reg mod 32 is
         when 16#19# | 16#1A# =>
            return 16#FF#;    --  paddles not connected
         when 16#1B# =>    --  OSC3: upper 8 bits of voice 3's waveform
            declare
               Any : Boolean;
               W : constant U32 := Wave_Bits (2, Any);
            begin
               return Byte (Shift_Right (W, 4) and 16#FF#);
            end;
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
      Left, Dist : Natural;
   begin

      case Vo.Env is
         when Attack => Rate := Natural (Shift_Right (AD, 4));
         when Decay_Sustain => Rate := Natural (AD and 15);
         when Release => Rate := Natural (SR and 15);
      end case;
      Period := Rate_Periods (Rate);

      --  15-bit rate counter that fires when it equals the period.  If
      --  the period is lowered below the current count the counter has to
      --  wrap around first (the well-known "ADSR delay bug").
      Left := Cycles;
      loop
         Dist := (if Vo.Rate_Count < Period then Period - Vo.Rate_Count
                  else 32768 - Vo.Rate_Count + Period);
         exit when Left < Dist;
         Left := Left - Dist;
         Vo.Rate_Count := 0;

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
                 (if Vo.Level > 16#5D# then 1
                  elsif Vo.Level > 16#36# then 2
                  elsif Vo.Level > 16#1A# then 4
                  elsif Vo.Level > 16#0E# then 8
                  elsif Vo.Level > 16#06# then 16
                  elsif Vo.Level > 0 then 30
                  else 1);
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
      Vo.Rate_Count := (Vo.Rate_Count + Left) mod 32768;
   end Clock_Envelope;

   function Wave_Bits (I : Natural; Any : out Boolean) return U32 is
      Vo  : Voice renames Voices (I);
      Src : constant Natural := (if I = 0 then 2 else I - 1);
      Acc : constant U32 := Vo.Acc;
      Ctl : constant Byte := Vo.Control;
      Sel : constant Natural := Natural (Shift_Right (Ctl, 4) and 7);
      Saw : constant U32 := Shift_Right (Acc, 12);
      Pulse_High : constant Boolean :=
        (Ctl and 16#08#) /= 0 or else Saw >= Vo.PW;
      Out_V : U32 := 16#FFF#;
   begin
      Any := (Ctl and 16#F0#) /= 0;
      case Sel is
         when 0 =>
            null;
         when 1 =>    --  triangle (with optional ring modulation)
            declare
               Msb : U32 := Acc and 16#800000#;
            begin
               if (Ctl and 16#04#) /= 0 then
                  Msb := Msb xor (Voices (Src).Acc and 16#800000#);
               end if;
               Out_V := Shift_Right (Acc, 11) and 16#FFF#;
               if Msb /= 0 then
                  Out_V := Out_V xor 16#FFF#;
               end if;
            end;
         when 2 =>
            Out_V := Saw;
         when 4 =>
            Out_V := (if Pulse_High then 16#FFF# else 0);
         when others =>   --  combined waveforms
            if Sel >= 4 and then not Pulse_High then
               Out_V := 0;
            else
               Out_V := Combo (Chip, Sel, Natural (Saw));
            end if;
      end case;
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
         end;
      end if;
      return (if Any then Out_V else 0);
   end Wave_Bits;

   function Waveform (I : Natural) return Integer is
      Any : Boolean;
      W   : constant U32 := Wave_Bits (I, Any);
   begin
      if not Any then
         return 0;
      end if;
      --  Centre around zero, scale by envelope (result about +-2048*255)
      return (Integer (W) - 2048) * Voices (I).Level;
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
            F  : constant Float := Cutoff_F (Chip, Cutoff_Reg);
            Res : constant Float := Float (Shift_Right (Filt_Route, 4));
            --  6581: Q 0.707 .. 1.7; the 8580 resonates harder (up to 2.6)
            Q  : constant Float :=
              (if Chip = MOS6581 then 1.0 / (0.707 + Res / 15.0)
               else 2.0 ** ((4.0 - Res) / 8.0));
            HP : Float := 0.0;
            Sum : Float := 0.0;
         begin
            for K in 1 .. Oversample loop
               HP := Filtered - Filt_LP - Q * Filt_BP;
               Filt_BP := Filt_BP + F * HP;
               Filt_LP := Filt_LP + F * Filt_BP;
            end loop;
            if Chip = MOS6581 then
               --  the 6581 filter saturates on loud input
               Filt_BP := Filt_BP / (1.0 + 0.05 * abs Filt_BP);
               Filt_LP := Filt_LP / (1.0 + 0.05 * abs Filt_LP);
            end if;
            if (Mode_Vol and 16#10#) /= 0 then Sum := Sum + Filt_LP; end if;
            if (Mode_Vol and 16#20#) /= 0 then Sum := Sum + Filt_BP; end if;
            if (Mode_Vol and 16#40#) /= 0 then Sum := Sum + HP; end if;
            Direct := Direct + Sum;
         end;
      elsif (Filt_Route and 7) /= 0 then
         null;   --  filter selected but no mode: voices silent
      end if;

      --  Volume register DC offset makes "digi" playback audible
      --  (large on the 6581, almost none on the 8580)
      Out_F := Direct * Volume * 0.3 +
        Volume * (if Chip = MOS6581 then 0.15 else 0.02);

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

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Reg_Array'Write (S, Regs);
      Voice_Array'Write (S, Voices);
      Float'Write (S, Cycle_Acc);
      Float'Write (S, Filt_LP);
      Float'Write (S, Filt_BP);
      Float'Write (S, DC_Prev_In);
      Float'Write (S, DC_Prev_Out);
      Byte'Write (S, Last_Write);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Reg_Array'Read (S, Regs);
      Voice_Array'Read (S, Voices);
      Float'Read (S, Cycle_Acc);
      Float'Read (S, Filt_LP);
      Float'Read (S, Filt_BP);
      Float'Read (S, DC_Prev_In);
      Float'Read (S, DC_Prev_Out);
      Byte'Read (S, Last_Write);
   end Load_State;

begin
   Build_Tables;
end SID;
