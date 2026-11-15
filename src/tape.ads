-- ***************************************************************************
--                      AdaC64 - Tape
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

--  Datasette with TAP (raw pulse) images.
--
--  C64 / VIC-20: the read signal goes to CIA1's FLAG input (VIA2 CA1 on the
--  VIC-20); the CPU port supplies the motor control (bit 5, active low)
--  and reads the PLAY sense (bit 4).
--  C16 / Plus/4 ("C16-TAPE-RAW" images): the read line is a level on CPU
--  port bit 4 (Tick_Level / Level); version 2 images store half-waves,
--  version 1 full waves, in single-clock (886 kHz) units.

with Ada.Streams;

package Tape is

   procedure Attach (Path : String; Ok : out Boolean);
   procedure Detach;
   function Present return Boolean;
   function Name return String;

   procedure Play;          --  press PLAY (done automatically on attach)
   procedure Stop;
   procedure Rewind;
   function Playing return Boolean;   --  PLAY pressed

   Motor : Boolean := False;          --  set by the machine from the port

   procedure Tick (Cycles : Natural; Pulse : out Natural);
   --  Advance the tape; Pulse = number of read pulses (falling edges on
   --  the FLAG line) that happened.

   function Is_C16 return Boolean;   --  a C16 / Plus/4 image

   procedure Tick_Level (Cycles : Natural);
   --  C16 / Plus/4: advance the tape by Cycles TED double-clock cycles
   function Level return Boolean;     --  the read line

   function Counter return Natural;
   --  position in percent

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Tape;
