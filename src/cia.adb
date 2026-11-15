-- ***************************************************************************
--                      AdaC64 - CIA
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

package body CIA is

   procedure Reset (C : in out Chip) is
   begin
      C := (others => <>);
   end Reset;

   procedure Update_IRQ (C : in out Chip) is
   begin
      if (C.ICR_Flags and C.ICR_Mask and 16#1F#) /= 0 then
         C.IRQ := True;
      end if;
   end Update_IRQ;

   procedure Set_SDR (C : in out Chip; Value : Byte) is
   begin
      if (C.CRA and 16#40#) = 0 then
         C.SDR := Value;
         C.ICR_Flags := C.ICR_Flags or 16#08#;
         Update_IRQ (C);
      end if;
   end Set_SDR;

   procedure Set_Flag (C : in out Chip; Bit : Byte) is
   begin
      C.ICR_Flags := C.ICR_Flags or Bit;
      Update_IRQ (C);
   end Set_Flag;

   --  Count a timer down by N; returns number of underflows.
   function Count (T : in out Timer; N : Natural) return Natural is
      Under : Natural := 0;
   begin
      if not T.Running or else N = 0 then
         return 0;
      end if;
      T.Counter := T.Counter - N;
      while T.Counter < 0 loop
         Under := Under + 1;
         if T.One_Shot then
            T.Running := False;
            T.Counter := T.Latch;
            exit;
         end if;
         T.Counter := T.Counter + T.Latch + 1;
      end loop;
      return Under;
   end Count;

   procedure Tick (C : in out Chip; Cycles : Natural) is
      UA, UB : Natural := 0;
   begin
      --  Timer A counts phi2 unless in CNT mode (CNT not connected)
      if (C.CRA and 16#20#) = 0 then
         UA := Count (C.TA, Cycles);
      end if;
      if UA > 0 then
         C.ICR_Flags := C.ICR_Flags or 16#01#;
         if (C.CRA and 16#08#) /= 0 then
            C.CRA := C.CRA and not 16#01#;
         end if;
      end if;

      case Shift_Right (C.CRB, 5) and 3 is
         when 0 =>
            UB := Count (C.TB, Cycles);
         when 2 | 3 =>
            UB := Count (C.TB, UA);
         when others =>
            null;
      end case;
      if UB > 0 then
         C.ICR_Flags := C.ICR_Flags or 16#02#;
         if (C.CRB and 16#08#) /= 0 then
            C.CRB := C.CRB and not 16#01#;
         end if;
      end if;

      if UA > 0 or else UB > 0 then
         Update_IRQ (C);
      end if;
   end Tick;

   function BCD_Inc (V : Byte) return Byte is
      R : Byte := V + 1;
   begin
      if (R and 16#0F#) > 9 then
         R := (R and 16#F0#) + 16#10#;
      end if;
      return R;
   end BCD_Inc;

   procedure Tick_TOD (C : in out Chip) is
      Div : constant Natural := (if (C.CRA and 16#80#) /= 0 then 5 else 6);
   begin
      if C.TOD_Stopped then
         return;
      end if;
      C.TOD_Divider := C.TOD_Divider + 1;
      if C.TOD_Divider < Div then
         return;
      end if;
      C.TOD_Divider := 0;

      C.TOD.Tenths := C.TOD.Tenths + 1;
      if C.TOD.Tenths >= 10 then
         C.TOD.Tenths := 0;
         C.TOD.Sec := BCD_Inc (C.TOD.Sec);
         if C.TOD.Sec >= 16#60# then
            C.TOD.Sec := 0;
            C.TOD.Min := BCD_Inc (C.TOD.Min);
            if C.TOD.Min >= 16#60# then
               C.TOD.Min := 0;
               declare
                  PM : Byte := C.TOD.Hr and 16#80#;
                  H  : Byte := C.TOD.Hr and 16#1F#;
               begin
                  H := BCD_Inc (H);
                  if H = 16#12# then
                     PM := PM xor 16#80#;
                  elsif H = 16#13# then
                     H := 1;
                  end if;
                  C.TOD.Hr := PM or H;
               end;
            end if;
         end if;
      end if;

      if C.TOD = C.Alarm then
         C.ICR_Flags := C.ICR_Flags or 16#04#;
         Update_IRQ (C);
      end if;
   end Tick_TOD;

   function Port_A_Out (C : Chip) return Byte is
     (C.PRA or not C.DDRA);
   function Port_B_Out (C : Chip) return Byte is
     (C.PRB or not C.DDRB);

   function Peek (C : Chip; Reg : Natural) return Byte is
   begin
      case Reg mod 16 is
         when 0 => return Port_A_Out (C);
         when 1 => return Port_B_Out (C);
         when 2 => return C.DDRA;
         when 3 => return C.DDRB;
         when 4 => return Byte (C.TA.Counter mod 256);
         when 5 => return Byte ((C.TA.Counter / 256) mod 256);
         when 6 => return Byte (C.TB.Counter mod 256);
         when 7 => return Byte ((C.TB.Counter / 256) mod 256);
         when 8 => return C.TOD.Tenths;
         when 9 => return C.TOD.Sec;
         when 10 => return C.TOD.Min;
         when 11 => return C.TOD.Hr;
         when 12 => return C.SDR;
         when 13 =>
            return C.ICR_Flags or (if C.IRQ then 16#80# else 0);
         when 14 => return C.CRA;
         when others => return C.CRB;
      end case;
   end Peek;

   function Read (C : in out Chip; Reg : Natural) return Byte is
      R : constant Natural := Reg mod 16;
   begin
      case R is
         when 8 =>
            declare
               V : constant Byte :=
                 (if C.TOD_Latched then C.TOD_Latch.Tenths
                  else C.TOD.Tenths);
            begin
               C.TOD_Latched := False;
               return V;
            end;
         when 9 =>
            return (if C.TOD_Latched then C.TOD_Latch.Sec else C.TOD.Sec);
         when 10 =>
            return (if C.TOD_Latched then C.TOD_Latch.Min else C.TOD.Min);
         when 11 =>
            if not C.TOD_Latched then
               C.TOD_Latch := C.TOD;
               C.TOD_Latched := True;
            end if;
            return C.TOD_Latch.Hr;
         when 13 =>
            declare
               V : constant Byte :=
                 C.ICR_Flags or (if C.IRQ then 16#80# else 0);
            begin
               C.ICR_Flags := 0;
               C.IRQ := False;
               return V;
            end;
         when 14 => return C.CRA and not 16#10#;
         when 15 => return C.CRB and not 16#10#;
         when others =>
            return Peek (C, R);
      end case;
   end Read;

   procedure Write (C : in out Chip; Reg : Natural; Value : Byte) is
      R : constant Natural := Reg mod 16;
      Alarm_Mode : constant Boolean := (C.CRB and 16#80#) /= 0;
   begin
      case R is
         when 0 => C.PRA := Value;
         when 1 => C.PRB := Value;
         when 2 => C.DDRA := Value;
         when 3 => C.DDRB := Value;
         when 4 =>
            C.TA.Latch := (C.TA.Latch / 256) * 256 + Integer (Value);
         when 5 =>
            C.TA.Latch := Integer (Value) * 256 + C.TA.Latch mod 256;
            if not C.TA.Running then
               C.TA.Counter := C.TA.Latch;
            end if;
         when 6 =>
            C.TB.Latch := (C.TB.Latch / 256) * 256 + Integer (Value);
         when 7 =>
            C.TB.Latch := Integer (Value) * 256 + C.TB.Latch mod 256;
            if not C.TB.Running then
               C.TB.Counter := C.TB.Latch;
            end if;
         when 8 =>
            if Alarm_Mode then
               C.Alarm.Tenths := Value and 16#0F#;
            else
               C.TOD.Tenths := Value and 16#0F#;
               C.TOD_Stopped := False;
            end if;
         when 9 =>
            if Alarm_Mode then
               C.Alarm.Sec := Value and 16#7F#;
            else
               C.TOD.Sec := Value and 16#7F#;
            end if;
         when 10 =>
            if Alarm_Mode then
               C.Alarm.Min := Value and 16#7F#;
            else
               C.TOD.Min := Value and 16#7F#;
            end if;
         when 11 =>
            if Alarm_Mode then
               C.Alarm.Hr := Value and 16#9F#;
            else
               C.TOD.Hr := Value and 16#9F#;
               C.TOD_Stopped := True;
            end if;
         when 12 =>
            C.SDR := Value;
            --  Serial output: signal "shift complete" immediately
            if (C.CRA and 16#40#) /= 0 then
               C.ICR_Flags := C.ICR_Flags or 16#08#;
               Update_IRQ (C);
            end if;
         when 13 =>
            if (Value and 16#80#) /= 0 then
               C.ICR_Mask := C.ICR_Mask or (Value and 16#1F#);
            else
               C.ICR_Mask := C.ICR_Mask and not (Value and 16#1F#);
            end if;
            Update_IRQ (C);
         when 14 =>
            C.CRA := Value and not 16#10#;
            C.TA.Running := (Value and 16#01#) /= 0;
            C.TA.One_Shot := (Value and 16#08#) /= 0;
            if (Value and 16#10#) /= 0 then
               C.TA.Counter := C.TA.Latch;
            end if;
         when others =>
            C.CRB := Value and not 16#10#;
            C.TB.Running := (Value and 16#01#) /= 0;
            C.TB.One_Shot := (Value and 16#08#) /= 0;
            if (Value and 16#10#) /= 0 then
               C.TB.Counter := C.TB.Latch;
            end if;
      end case;
   end Write;

end CIA;
