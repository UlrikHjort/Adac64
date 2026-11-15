-- ***************************************************************************
--                      AdaC64 - Z80
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

--  Zilog Z80 CPU core (used by the C128 for CP/M).
--
--  Instruction-stepped; all documented instructions plus the commonly
--  used undocumented ones (IXH/IXL/IYH/IYL, SLL, DDCB register copies).
--  Memory and I/O ports are generic formal subprograms.

with Ada.Streams;
with Types; use Types;

generic
   with function Read (Addr : Word) return Byte;
   with procedure Write (Addr : Word; Value : Byte);
   with function In_Port (Port : Word) return Byte;
   with procedure Out_Port (Port : Word; Value : Byte);
package Z80 is

   type Reg_File is record
      A, F, B, C, D, E, H, L : Byte := 0;
   end record;

   Main, Alt : Reg_File;
   IX, IY  : Word := 16#FFFF#;
   SP      : Word := 16#FFFF#;
   PC      : Word := 0;
   I, R    : Byte := 0;
   IFF1, IFF2 : Boolean := False;
   IM      : Natural range 0 .. 2 := 0;
   Halted  : Boolean := False;

   INT_Line    : Boolean := False;   --  level triggered
   NMI_Pending : Boolean := False;

   procedure Reset;
   procedure Step (T_States : out Natural);

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Z80;
