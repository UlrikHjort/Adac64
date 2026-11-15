-- ***************************************************************************
--                      AdaC64 - TED
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

--  MOS 7360 / 8360 TED of the C16 and Plus/4: video (text, bitmap,
--  multicolour and extended colour modes, 121 colours, hardware cursor and
--  flashing), three 16-bit timers, the raster interrupt and two sound
--  voices. It also clocks the CPU: Tick advances it one double-clock
--  cycle (1.77 MHz PAL), and CPU_Blocked tells whether the CPU may use
--  that cycle (single-clock phases, RAM refresh and the bad-line DMA).
--
--  Fetch reads the TED's view of memory: ROM = True for character /
--  bitmap data with ROM selected ($FF12 bit 2), or screen data while the
--  CPU has ROM banked in.

with Ada.Streams;
with Types; use Types;

generic
   with function Fetch (Addr : Word; ROM : Boolean) return Byte;
package TED is

   type Standard_Kind is (PAL, NTSC);
   procedure Set_Standard (S : Standard_Kind);
   function Clock_Hz return Natural;               --  double clock
   Cycles_Per_Line : constant := 114;
   function Lines_Per_Frame return Positive;

   procedure Reset;
   function Read (Reg : Natural) return Byte;      --  $FF00 + Reg (0 .. 63)
   procedure Write (Reg : Natural; Value : Byte);
   procedure Tick;                                 --  one double-clock cycle
   function CPU_Blocked return Boolean;
   function IRQ return Boolean;

   ROM_Enabled : Boolean := True;   --  $FF3E / $FF3F state ($FF13 bit 0)
   Frame_Done  : Boolean := False;  --  set at vertical sync

   function Raster return Natural;
   function Line_Cycle return Natural;
   function Matrix_Base return Word;   --  attributes; characters at +$400
   function Register (Reg : Natural) return Byte;   --  without side effects

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end TED;
