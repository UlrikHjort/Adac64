-- ***************************************************************************
--                      AdaC64 - Drive1541
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

--  Commodore 1541 disk drive: its own 6502, 2 KB RAM, 16 KB DOS ROM,
--  two 6522 VIAs (serial bus / disk controller) and a GCR disk surface
--  generated from the attached D64 image.  The drive is run in lockstep
--  with the computer through Run_Until.


with Ada.Streams;
with Types; use Types;

package Drive1541 is

   type Drive_Model is (D1541, D1571);

   procedure Load_ROM (Path : String; Ok : out Boolean);
   --  16 KB = 1541 DOS, 32 KB = 1571 DOS.
   function ROM_Loaded return Boolean;            --  for the current model
   function Has_ROM (M : Drive_Model) return Boolean;

   procedure Set_Model (M : Drive_Model);
   function Model return Drive_Model;

   --  1571 fast serial (burst) link with the C128 (byte level)
   procedure Fast_Byte_From_Host (Value : Byte);
   type Fast_Proc is access procedure (Value : Byte);
   To_Host : Fast_Proc := null;

   procedure Reset;
   --  Power-on reset of the drive (time base restarts at 0).

   procedure Insert_Disk;
   --  Build the GCR tracks from Media.Image_Data (a D64).

   procedure Eject_Disk;
   --  Write back modified tracks and remove the disk.

   procedure Flush;
   --  Write modified tracks back into the D64 image and its file.

   procedure Run_Until (C64_Cycles : Long_Long_Integer);
   --  Run the drive until it has caught up with the given computer time
   --  (computer cycles at 985248 Hz; the drive runs at 1 MHz).

   procedure Set_Host_Clock (Hz : Natural);
   --  Computer clock (985248 Hz PAL, 1022727 Hz NTSC).

   procedure Set_Time (C64_Cycles : Long_Long_Integer);
   --  Align the drive clock with the computer time (drive was idle).

   procedure ATN_Changed;
   --  The computer changed the ATN line (drives VIA1 CA1).

   function Peek_RAM (Addr : Natural) return Byte;
   --  Drive RAM (debugging).

   function Get_PC return Word;
   function Peek (Addr : Word) return Byte;           --  no side effects
   procedure Poke (Addr : Word; Value : Byte);        --  RAM only
   function Register_Text return String;

   function LED_On return Boolean;
   function Motor_On return Boolean;
   function Current_Track return Natural;    --  1 .. 42 (half tracks rounded)

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   --  Snapshot support (call between frames).

end Drive1541;
