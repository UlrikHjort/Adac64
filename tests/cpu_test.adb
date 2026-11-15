-- ***************************************************************************
--                      AdaC64 - CPU_Test
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

--  Runs Klaus Dormann's 6502 functional test against the CPU core.
--  Usage: cpu_test 6502_functional_test.bin [success_address_hex]

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;
with Types; use Types;
with MOS6502;

procedure CPU_Test is
   RAM : Byte_Array (0 .. 65535) := (others => 0);

   function Read (A : Word) return Byte is (RAM (Natural (A)));
   procedure Write (A : Word; V : Byte) is
   begin
      RAM (Natural (A)) := V;
   end Write;

   package CPU is new MOS6502 (Read, Write);

   Success : Word := 16#3469#;
   Last_PC : Word := 0;
   Cycles  : Natural;
   Total   : Long_Long_Integer := 0;
   Instr   : Long_Long_Integer := 0;
begin
   declare
      use Ada.Streams.Stream_IO;
      F : Ada.Streams.Stream_IO.File_Type;
   begin
      Open (F, Ada.Streams.Stream_IO.In_File, Argument (1));
      Byte_Array'Read (Stream (F), RAM);
      Ada.Streams.Stream_IO.Close (F);
   end;
   if Argument_Count >= 2 then
      Success := Word'Value ("16#" & Argument (2) & "#");
   end if;

   CPU.Reset;
   CPU.PC := 16#0400#;
   loop
      Last_PC := CPU.PC;
      CPU.Step (Cycles);
      Total := Total + Long_Long_Integer (Cycles);
      Instr := Instr + 1;
      exit when CPU.PC = Last_PC;   --  trapped in a "jmp *" / branch loop
      exit when Instr > 200_000_000;
   end loop;

   if CPU.PC = Success then
      Put_Line ("PASS at $" & Word'Image (CPU.PC) & " after" &
                Instr'Image & " instructions," & Total'Image & " cycles");
   else
      Put_Line ("FAIL: trapped at PC =" & Word'Image (CPU.PC) &
                " (hex " & Natural'Image (Natural (CPU.PC) / 4096) & "...)");
      Put_Line ("A=" & CPU.A'Image & " X=" & CPU.X'Image & " Y=" &
                CPU.Y'Image & " P=" & CPU.Get_P'Image);
      Set_Exit_Status (Failure);
   end if;
end CPU_Test;
