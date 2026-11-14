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
