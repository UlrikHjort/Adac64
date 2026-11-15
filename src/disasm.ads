-- ***************************************************************************
--                      AdaC64 - Disasm
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

--  6502 disassembler and hex helpers for the machine-code monitor.

with Types; use Types;

package Disasm is

   type Reader is access function (Addr : Word) return Byte;

   type Addr_Mode is (Imp, Acc, Imm, ZP, ZPX, ZPY, Abso, AbsX, AbsY,
                      IndX, IndY, Ind, Rel);
   function Mode_Of (Op : Byte) return Addr_Mode;
   function Mnemonic (Op : Byte) return String;    --  "LDA" (illegal ones too)
   function Length_Of (M : Addr_Mode) return Natural;

   function Hex2 (B : Byte) return String;
   function Hex4 (W : Word) return String;

   procedure Disassemble (Read : Reader; Addr : Word;
                          Text : out String; Last : out Natural;
                          Length : out Natural);
   --  One instruction at Addr: "C000  A9 00     LDA #$00" in Text (1 .. Last)

end Disasm;
