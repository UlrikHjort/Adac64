-- ***************************************************************************
--                      AdaC64 - MOS6502
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
