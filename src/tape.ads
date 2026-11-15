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
--  The read signal goes to CIA1's FLAG input; the CPU port supplies the
--  motor control (bit 5, active low) and reads the PLAY sense (bit 4).

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

   function Counter return Natural;
   --  position in percent

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Tape;
