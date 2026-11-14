
package body VIA is

   procedure Reset (V : in out Chip) is
   begin
      V := (others => <>);
   end Reset;

   procedure Tick (V : in out Chip; Cycles : Natural) is
   begin
      if Cycles = 0 then
         return;
      end if;

      --  Timer 1: one-shot (interrupts once) or free-running (ACR bit 6)
      V.T1_Counter := V.T1_Counter - Cycles;
      while V.T1_Counter < 0 loop
         if (V.ACR and 16#40#) /= 0 then
            V.IFR := V.IFR or IFR_T1;
            V.T1_Counter := V.T1_Counter + V.T1_Latch + 2;
         else
            if V.T1_Armed then
               V.IFR := V.IFR or IFR_T1;
               V.T1_Armed := False;
            end if;
            V.T1_Counter := V.T1_Counter + 16#10000#;
         end if;
      end loop;

      --  Timer 2: one-shot interval mode only (pulse counting not wired)
      if (V.ACR and 16#20#) = 0 then
         V.T2_Counter := V.T2_Counter - Cycles;
         while V.T2_Counter < 0 loop
            if V.T2_Armed then
               V.IFR := V.IFR or IFR_T2;
               V.T2_Armed := False;
            end if;
            V.T2_Counter := V.T2_Counter + 16#10000#;
         end loop;
      end if;
   end Tick;

   function Read (V : in out Chip; Reg : Natural) return Byte is
   begin
      case Reg mod 16 is
         when 0 =>
            V.IFR := V.IFR and not (IFR_CB1 or IFR_CB2);
            return (V.ORB and V.DDRB) or (V.Port_B_In and not V.DDRB);
         when 1 =>
            V.IFR := V.IFR and not (IFR_CA1 or IFR_CA2);
            return (V.ORA and V.DDRA) or (V.Port_A_In and not V.DDRA);
         when 15 =>
            return (V.ORA and V.DDRA) or (V.Port_A_In and not V.DDRA);
         when 2 => return V.DDRB;
         when 3 => return V.DDRA;
         when 4 =>
            V.IFR := V.IFR and not IFR_T1;
            return Byte (V.T1_Counter mod 256);
         when 5 => return Byte ((V.T1_Counter / 256) mod 256);
         when 6 => return Byte (V.T1_Latch mod 256);
         when 7 => return Byte ((V.T1_Latch / 256) mod 256);
         when 8 =>
            V.IFR := V.IFR and not IFR_T2;
            return Byte (V.T2_Counter mod 256);
         when 9 => return Byte ((V.T2_Counter / 256) mod 256);
         when 10 =>
            V.IFR := V.IFR and not IFR_SR;
            return V.SR;
         when 11 => return V.ACR;
         when 12 => return V.PCR;
         when 13 =>
            return V.IFR or (if IRQ (V) then 16#80# else 0);
         when others =>
            return V.IER or 16#80#;
      end case;
   end Read;

   procedure Write (V : in out Chip; Reg : Natural; Value : Byte) is
   begin
      case Reg mod 16 is
         when 0 =>
            V.ORB := Value;
            V.IFR := V.IFR and not (IFR_CB1 or IFR_CB2);
         when 1 =>
            V.ORA := Value;
            V.IFR := V.IFR and not (IFR_CA1 or IFR_CA2);
         when 15 => V.ORA := Value;
         when 2 => V.DDRB := Value;
         when 3 => V.DDRA := Value;
         when 4 | 6 =>
            V.T1_Latch := (V.T1_Latch / 256) * 256 + Integer (Value);
         when 5 =>
            V.T1_Latch := Integer (Value) * 256 + V.T1_Latch mod 256;
            V.T1_Counter := V.T1_Latch;
            V.IFR := V.IFR and not IFR_T1;
            V.T1_Armed := True;
         when 7 =>
            V.T1_Latch := Integer (Value) * 256 + V.T1_Latch mod 256;
            V.IFR := V.IFR and not IFR_T1;
         when 8 =>
            V.T2_Latch_Lo := Value;
         when 9 =>
            V.T2_Counter := Integer (Value) * 256 + Integer (V.T2_Latch_Lo);
            V.IFR := V.IFR and not IFR_T2;
            V.T2_Armed := True;
         when 10 =>
            V.SR := Value;
            V.IFR := V.IFR and not IFR_SR;
         when 11 => V.ACR := Value;
         when 12 => V.PCR := Value;
         when 13 =>
            V.IFR := V.IFR and not (Value and 16#7F#);
         when others =>
            if (Value and 16#80#) /= 0 then
               V.IER := V.IER or (Value and 16#7F#);
            else
               V.IER := V.IER and not (Value and 16#7F#);
            end if;
      end case;
   end Write;

   procedure Set_CA1 (V : in out Chip; Level : Boolean) is
      Positive_Edge : constant Boolean := (V.PCR and 1) /= 0;
   begin
      if Level /= V.CA1 then
         if Level = Positive_Edge then
            V.IFR := V.IFR or IFR_CA1;
         end if;
         V.CA1 := Level;
      end if;
   end Set_CA1;

   function CA2_High (V : Chip) return Boolean is
     (if (V.PCR and 16#0C#) = 16#0C# then (V.PCR and 16#02#) /= 0 else True);

   function CB2_High (V : Chip) return Boolean is
     (if (V.PCR and 16#C0#) = 16#C0# then (V.PCR and 16#20#) /= 0 else True);

end VIA;
