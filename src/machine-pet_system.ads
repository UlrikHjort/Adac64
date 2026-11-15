-- ***************************************************************************
--                      AdaC64 - Machine.PET_System
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

--  The Commodore PET 4032 (BASIC 4, 40 columns, graphics keyboard): 32K
--  RAM, 1K screen at $8000, two 6520 PIAs (keyboard, retrace interrupt,
--  IEEE-488 data and handshake), a 6522 VIA (IEEE handshake, character
--  set, sound on CB2) and a 6545 CRTC; drive 8 is IEEE_Drive.

with Ada.Streams;

private package Machine.PET_System is

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean);
   procedure Set_Standard (V : Video_Standard);
   function Frame_Rate return Float;
   procedure Reset (Hard : Boolean);

   procedure Rebuild_Map;
   function IO_Read (Addr : Word) return Byte;
   procedure IO_Write (Addr : Word; Value : Byte);
   function IO_Peek (Addr : Word) return Byte;
   procedure Clock (N : Natural);
   procedure Interrupt_Lines (IRQ, NMI : out Boolean);

   function Frame_Done return Boolean;
   procedure Clear_Frame;
   procedure End_Of_Frame;

   function Screen_Byte (I : Natural) return Byte;
   function Beam_Text return String;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Machine.PET_System;
