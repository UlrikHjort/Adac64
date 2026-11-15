-- ***************************************************************************
--                      AdaC64 - Final_Expansion
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

--  Final Expansion 3 for the VIC-20 (as emulated by VICE): 512K RAM,
--  512K flash (AM29F040B), and two registers at $9C02 / $9C03 that pick a
--  mode and banks for RAM123 ($0400-$0FFF) and blocks 1, 2, 3 and 5.
--
--  Every access to those areas goes through Read / Write (reads and
--  writes map differently, accesses to block 5 lock and unlock the
--  registers, and the flash has a command state machine), so the machine
--  routes them here. Now is the CPU cycle count, for the erase timing.

with Ada.Streams;
with Types; use Types;

package Final_Expansion is

   Present : Boolean := False;

   Flash_Size : constant := 16#80000#;

   procedure Load (Data : Byte_Array);
   --  Flash contents (512K or less; an image under 32K is placed as close
   --  to the 32K boundary as VICE places it); also does Power_Up
   procedure Power_Up;              --  RAM power-up pattern, then Reset
   procedure Reset;                 --  registers and flash state

   function Handles (Addr : Word) return Boolean is
     (Addr in 16#0400# .. 16#0FFF# | 16#2000# .. 16#7FFF#
            | 16#A000# .. 16#BFFF# | 16#9C00# .. 16#9FFF#);

   function Read (Addr : Word; Now : Long_Long_Integer) return Byte;
   procedure Write (Addr : Word; Value : Byte; Now : Long_Long_Integer);
   function Peek (Addr : Word) return Byte;
   --  What a read would give, without side effects (monitor, VIC)

   Flash_Changed : Boolean := False;   --  programmed or erased since Load

   function Flash_Image return Byte_Array;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Final_Expansion;
