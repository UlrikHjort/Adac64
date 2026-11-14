--  6502 disassembler and hex helpers for the machine-code monitor.

with Types; use Types;

package Disasm is

   type Reader is access function (Addr : Word) return Byte;

   function Hex2 (B : Byte) return String;
   function Hex4 (W : Word) return String;

   procedure Disassemble (Read : Reader; Addr : Word;
                          Text : out String; Last : out Natural;
                          Length : out Natural);
   --  One instruction at Addr: "C000  A9 00     LDA #$00" in Text (1 .. Last)

end Disasm;
