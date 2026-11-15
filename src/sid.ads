-- ***************************************************************************
--                      AdaC64 - SID
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

--  MOS 6581 / 8580 SID sound chip.
--
--  Samples are generated synchronously with the emulated clock
--  (Clock is called with the number of elapsed cycles), so register
--  writes take effect with sample accuracy.

with Ada.Streams;
with Types; use Types;

package SID is

   Sample_Rate : constant := 44_100;
   Clock_Rate  : Natural := 985_248;    --  phi2 (PAL; NTSC 1_022_727)

   procedure Set_Clock (Hz : Natural);

   type Chip_Model is (MOS6581, MOS8580);
   procedure Set_Model (M : Chip_Model);
   function Model return Chip_Model;
   --  6581: original C64 (sparse combined waveforms, non-linear filter,
   --  loud volume-register digis); 8580: C64C/C128DCR.

   type Sample is range -32768 .. 32767;
   for Sample'Size use 16;

   Pot_X, Pot_Y : Byte := 16#FF#;   --  paddle inputs ($D419 / $D41A)

   procedure Reset;
   procedure Write (Reg : Natural; Value : Byte);
   function Read (Reg : Natural) return Byte;

   procedure Clock (Cycles : Natural);
   --  Advance the SID; produced samples are pushed to the sample sink.

   type Sink_Proc is access procedure (S : Sample);
   Sink : Sink_Proc := null;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   --  Snapshot support (call between frames).

end SID;
