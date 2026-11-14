--  MOS 6502 / 6510 / 8502 CPU core.
--
--  Instruction-stepped with exact per-instruction cycle counts, including
--  page-crossing penalties and the commonly used undocumented opcodes.
--  The bus is supplied as generic formal subprograms so the calls can be
--  inlined by the compiler.

with Types; use Types;

generic
   with function Read (Addr : Word) return Byte;
   with procedure Write (Addr : Word; Value : Byte);
package MOS6502 is

   --  Registers (public so that machine-level traps can inspect/modify them)
   A, X, Y : Byte := 0;
   SP      : Byte := 16#FD#;
   PC      : Word := 0;

   --  Status flags
   Flag_N, Flag_V, Flag_D, Flag_I, Flag_Z, Flag_C : Boolean := False;

   --  Interrupt inputs
   IRQ_Line    : Boolean := False;   --  level triggered, active when True
   NMI_Pending : Boolean := False;   --  set on falling edge of NMI

   Jammed : Boolean := False;        --  CPU executed a KIL/JAM opcode

   Current_Cycles : Natural := 0;
   --  Base cycle count of the instruction being executed (valid during
   --  Step, so bus handlers can estimate when an access happens).

   function Base_Cycles (Op : Byte) return Natural;
   --  Cycle count of an opcode without page-cross / branch penalties.

   procedure Reset;
   --  Load PC from the reset vector and initialise registers.

   procedure Step (Cycles : out Natural);
   --  Execute one instruction (or take a pending interrupt).

   function Get_P (B_Flag : Boolean := True) return Byte;
   procedure Set_P (Value : Byte);

   procedure Push (Value : Byte);
   function Pull return Byte;

   procedure Do_RTS;
   --  Perform the effect of an RTS instruction (used by KERNAL traps).

end MOS6502;
