-- ***************************************************************************
--                      AdaC64 - PIA
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

package body PIA is

   function Bit (V : Byte; N : Natural) return Boolean is
     ((Shift_Right (V, N) and 1) /= 0);

   procedure Reset (P : in out Chip) is
   begin
      P := (others => <>);
   end Reset;

   --  Control register: 0 C1 IRQ enable, 1 C1 edge (1 = rising), 2 port
   --  (1) or DDR (0) at register 0 / 2, 3-5 C2 (bit 5 = 1: output, bit 4
   --  = 1 manual with the level in bit 3; bit 5 = 0: input, edge in bit 4,
   --  IRQ enable in bit 3), 6 C2 flag, 7 C1 flag

   function IRQ_Of (CR : Byte) return Boolean is
     ((Bit (CR, 7) and then Bit (CR, 0))
      or else (Bit (CR, 6) and then not Bit (CR, 5) and then Bit (CR, 3)));

   function IRQ_A (P : Chip) return Boolean is (IRQ_Of (P.CRA));
   function IRQ_B (P : Chip) return Boolean is (IRQ_Of (P.CRB));

   function C2_Out (CR : Byte) return Boolean is
     (not Bit (CR, 5) or else not Bit (CR, 4) or else Bit (CR, 3));

   function CA2_Out (P : Chip) return Boolean is (C2_Out (P.CRA));
   function CB2_Out (P : Chip) return Boolean is (C2_Out (P.CRB));

   function Peek (P : Chip; Reg : Natural; Input : Byte) return Byte is
   begin
      case Reg mod 4 is
         when 0 =>
            return (if Bit (P.CRA, 2)
                    then (Input and not P.DDRA) or (P.ORA and P.DDRA)
                    else P.DDRA);
         when 1 => return P.CRA;
         when 2 =>
            --  port B output pins read back the output register
            return (if Bit (P.CRB, 2)
                    then (Input and not P.DDRB) or (P.ORB and P.DDRB)
                    else P.DDRB);
         when others => return P.CRB;
      end case;
   end Peek;

   function Read (P : in out Chip; Reg : Natural; Input : Byte) return Byte
   is
      V : constant Byte := Peek (P, Reg, Input);
   begin
      if Reg mod 4 = 0 and then Bit (P.CRA, 2) then
         P.CRA := P.CRA and 16#3F#;             --  reading clears the flags
      elsif Reg mod 4 = 2 and then Bit (P.CRB, 2) then
         P.CRB := P.CRB and 16#3F#;
      end if;
      return V;
   end Read;

   procedure Write (P : in out Chip; Reg : Natural; Value : Byte) is
   begin
      case Reg mod 4 is
         when 0 =>
            if Bit (P.CRA, 2) then
               P.ORA := Value;
            else
               P.DDRA := Value;
            end if;
         when 1 => P.CRA := (P.CRA and 16#C0#) or (Value and 16#3F#);
         when 2 =>
            if Bit (P.CRB, 2) then
               P.ORB := Value;
            else
               P.DDRB := Value;
            end if;
         when others => P.CRB := (P.CRB and 16#C0#) or (Value and 16#3F#);
      end case;
   end Write;

   procedure Edge (CR : in out Byte; Old_Level : in out Boolean;
                   Level : Boolean; Edge_Bit, Flag : Natural) is
   begin
      if Level /= Old_Level then
         if Level = Bit (CR, Edge_Bit) then        --  the active edge
            CR := CR or Shift_Left (1, Flag);
         end if;
         Old_Level := Level;
      end if;
   end Edge;

   procedure Set_CA1 (P : in out Chip; Level : Boolean) is
   begin
      Edge (P.CRA, P.CA1, Level, 1, 7);
   end Set_CA1;

   procedure Set_CB1 (P : in out Chip; Level : Boolean) is
   begin
      Edge (P.CRB, P.CB1, Level, 1, 7);
   end Set_CB1;

   procedure Set_CA2 (P : in out Chip; Level : Boolean) is
   begin
      if not Bit (P.CRA, 5) then
         Edge (P.CRA, P.CA2, Level, 4, 6);
      end if;
   end Set_CA2;

   procedure Set_CB2 (P : in out Chip; Level : Boolean) is
   begin
      if not Bit (P.CRB, 5) then
         Edge (P.CRB, P.CB2, Level, 4, 6);
      end if;
   end Set_CB2;

end PIA;
