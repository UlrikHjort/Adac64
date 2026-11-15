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

--  MOS 6520 / 6821 Peripheral Interface Adapter: two 8-bit ports with data
--  direction registers, and the control lines CA1 / CB1 (inputs) and
--  CA2 / CB2 (inputs or outputs). The machine supplies the pins' input
--  levels when a port is read.

with Interfaces; use Interfaces;
with Types; use Types;

package PIA is

   type Chip is record
      ORA, DDRA, CRA : Byte := 0;
      ORB, DDRB, CRB : Byte := 0;
      CA1, CA2, CB1, CB2 : Boolean := True;    --  input pin levels
   end record;

   procedure Reset (P : in out Chip);

   function Read (P : in out Chip; Reg : Natural; Input : Byte) return Byte;
   --  Reg 0 .. 3; Input = the pins of the port read (registers 0 / 2)
   function Peek (P : Chip; Reg : Natural; Input : Byte) return Byte;
   procedure Write (P : in out Chip; Reg : Natural; Value : Byte);

   procedure Set_CA1 (P : in out Chip; Level : Boolean);
   procedure Set_CB1 (P : in out Chip; Level : Boolean);
   procedure Set_CA2 (P : in out Chip; Level : Boolean);   --  when an input
   procedure Set_CB2 (P : in out Chip; Level : Boolean);

   function Port_A_Out (P : Chip) return Byte is (P.ORA or not P.DDRA);
   function Port_B_Out (P : Chip) return Byte is (P.ORB or not P.DDRB);
   function CA2_Out (P : Chip) return Boolean;   --  (high when an input)
   function CB2_Out (P : Chip) return Boolean;
   function IRQ_A (P : Chip) return Boolean;
   function IRQ_B (P : Chip) return Boolean;

end PIA;
