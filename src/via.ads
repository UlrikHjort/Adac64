--  MOS 6522 Versatile Interface Adapter (used twice in the 1541).
--
--  The owner sets the external pin levels (Port_A_In / Port_B_In) before
--  reads and inspects the output registers after writes.

with Interfaces; use Interfaces;
with Types; use Types;

package VIA is

   type Chip is record
      ORA, ORB, DDRA, DDRB : Byte := 0;
      Port_A_In, Port_B_In : Byte := 16#FF#;   --  external pin levels
      T1_Counter : Integer := 16#FFFF#;
      T1_Latch   : Integer := 16#FFFF#;
      T1_Armed   : Boolean := False;
      T2_Counter : Integer := 16#FFFF#;
      T2_Latch_Lo : Byte := 16#FF#;
      T2_Armed   : Boolean := False;
      SR, ACR, PCR : Byte := 0;
      IFR, IER   : Byte := 0;
      CA1        : Boolean := False;
   end record;

   IFR_CA2 : constant Byte := 16#01#;
   IFR_CA1 : constant Byte := 16#02#;
   IFR_SR  : constant Byte := 16#04#;
   IFR_CB2 : constant Byte := 16#08#;
   IFR_CB1 : constant Byte := 16#10#;
   IFR_T2  : constant Byte := 16#20#;
   IFR_T1  : constant Byte := 16#40#;

   procedure Reset (V : in out Chip);
   procedure Tick (V : in out Chip; Cycles : Natural);
   function Read (V : in out Chip; Reg : Natural) return Byte;
   procedure Write (V : in out Chip; Reg : Natural; Value : Byte);

   function IRQ (V : Chip) return Boolean is
     ((V.IFR and V.IER and 16#7F#) /= 0);

   procedure Set_CA1 (V : in out Chip; Level : Boolean);
   --  Drive the CA1 input; the active edge (PCR bit 0) raises IFR_CA1.

   function Port_A_Out (V : Chip) return Byte is (V.ORA and V.DDRA);
   function Port_B_Out (V : Chip) return Byte is (V.ORB and V.DDRB);
   --  Bits actively driven high by the VIA (inputs read as 0 here).

   function CA2_High (V : Chip) return Boolean;
   function CB2_High (V : Chip) return Boolean;
   --  Levels of the CA2/CB2 outputs in manual output mode
   --  (other modes report high).

end VIA;
