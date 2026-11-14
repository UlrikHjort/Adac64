--  MOS 6526 Complex Interface Adapter.
--
--  Port pins are handled by the machine: the CIA keeps the output and
--  data-direction registers, and the machine combines them with external
--  inputs when the port registers are read.

with Types; use Types;

package CIA is

   type Timer is record
      Counter   : Integer := 16#FFFF#;
      Latch     : Integer := 16#FFFF#;
      Running   : Boolean := False;
      One_Shot  : Boolean := False;
      Underflow : Boolean := False;   --  underflow happened in last Tick
   end record;

   type TOD_Clock is record
      Tenths, Sec, Min, Hr : Byte := 0;   --  BCD, Hr bit 7 = PM
   end record;

   type Chip is record
      PRA, PRB, DDRA, DDRB : Byte := 0;
      TA, TB     : Timer;
      CRA, CRB   : Byte := 0;
      ICR_Flags  : Byte := 0;
      ICR_Mask   : Byte := 0;
      IRQ        : Boolean := False;
      SDR        : Byte := 0;

      TOD        : TOD_Clock;
      Alarm      : TOD_Clock;
      TOD_Latch  : TOD_Clock;
      TOD_Latched : Boolean := False;
      TOD_Stopped : Boolean := False;
      TOD_Divider : Natural := 0;
   end record;

   procedure Reset (C : in out Chip);

   procedure Tick (C : in out Chip; Cycles : Natural);
   --  Advance the timers by the given number of phi2 cycles.

   procedure Tick_TOD (C : in out Chip);
   --  Called at the mains frequency (50 Hz).

   function Read (C : in out Chip; Reg : Natural) return Byte;
   --  Register read. Port registers (0, 1) return only the output-latch
   --  view; the machine overrides these.

   function Peek (C : Chip; Reg : Natural) return Byte;
   --  Side-effect free read (for debugging).

   procedure Write (C : in out Chip; Reg : Natural; Value : Byte);

   procedure Set_Flag (C : in out Chip; Bit : Byte);
   --  Raise an interrupt source (e.g. FLAG pin).

   procedure Set_SDR (C : in out Chip; Value : Byte);
   --  A byte shifted in from the serial port (only in input mode).

   function Port_A_Out (C : Chip) return Byte;
   function Port_B_Out (C : Chip) return Byte;
   --  Port output values; input bits read as 1 (pulled up).

end CIA;
