-- ***************************************************************************
--                      AdaC64 - Machine.Plus4_System
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

--  The Commodore Plus/4 (64K, 3-plus-1 ROMs, ACIA) and C16 (16K): the TED,
--  the 7501 CPU port (serial bus), ROM banking ($FDD0, $FF3E / $FF3F),
--  the keyboard latch and the 6529 ports.
--
--  The emulated time unit is the TED's double clock (1.77 MHz): the CPU
--  gets the cycles the TED leaves it (Run_CPU).

with Ada.Streams;

private package Machine.Plus4_System is

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean);
   procedure Set_Standard (V : Video_Standard);
   function Frame_Rate return Float;
   function Clock_Hz return Natural;
   procedure Reset (Hard : Boolean);

   procedure Rebuild_Map;
   function IO_Read (Addr : Word) return Byte;
   procedure IO_Write (Addr : Word; Value : Byte);
   function IO_Peek (Addr : Word) return Byte;   --  no side effects
   function Port_Read (Addr : Word) return Byte;
   procedure Port_Write (Addr : Word; Value : Byte);
   procedure Poke (Addr : Word; Value : Byte);  --  into RAM
   function RAM_Read (Addr : Word) return Byte;
   function ROM_Peek (Addr : Word) return Byte;  --  $8000-$FFFF as banked

   procedure Clock (N : Natural);         --  N TED cycles
   procedure Run_CPU (K : Natural);
   --  K CPU cycles: each waits for a TED cycle the CPU may use
   procedure Wait_Free;
   --  Before a bus access: let the TED take the cycles the CPU cannot use
   procedure Interrupt_Lines (IRQ, NMI : out Boolean);

   function Frame_Done return Boolean;
   procedure Clear_Frame;
   procedure End_Of_Frame;

   procedure Attach_Cartridge (Path : String; Ok : out Boolean);
   --  VICE .crt ("PLUS4 CARTRIDGE", generic: C1 / C2, low / high, 4K-16K
   --  chips) or a raw image: 16K = C1 low, 32K = C1 low + high
   procedure Detach_Cartridge;
   function Cartridge_Name return String;

   function Screen_Byte (I : Natural) return Byte;
   function Beam_Text return String;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Machine.Plus4_System;
