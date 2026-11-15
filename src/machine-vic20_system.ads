-- ***************************************************************************
--                      AdaC64 - Machine.VIC20_System
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

--  The VIC-20: the 6560 / 6561 VIC, two 6522 VIAs, the RAM expansion and
--  cartridges (plain ROM images, Mega-Cart, Final Expansion 3).

with Ada.Streams;

private package Machine.VIC20_System is

   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean);
   procedure Set_Standard (V : Video_Standard);
   function Frame_Rate return Float;
   procedure Reset (Hard : Boolean);

   procedure Set_Memory (M : VIC20_Memory);
   function Memory return VIC20_Memory;
   procedure Choose_Memory (Load_Address : Word);
   --  Autostart: the RAM expansion a program loading there was made for

   procedure Rebuild_Map;
   function IO_Read (Addr : Word) return Byte;
   procedure IO_Write (Addr : Word; Value : Byte);
   function IO_Peek (Addr : Word) return Byte;    --  no side effects
   procedure Poke (Addr : Word; Value : Byte);
   --  Store as a program load does (into cartridge RAM where it is banked)
   procedure Clock (N : Natural);
   procedure Interrupt_Lines (IRQ, NMI : out Boolean);
   function Soft_Reset_Pending return Boolean;    --  Mega-Cart $9E00

   function Frame_Done return Boolean;
   procedure Clear_Frame;
   procedure End_Of_Frame;

   function Is_Cartridge (Path : String) return Boolean;
   procedure Attach_Cartridge (Path : String; Ok : out Boolean);
   procedure Detach_Cartridge;
   function Cartridge_Name return String;

   function Screen_Byte (I : Natural) return Byte;   --  22 x 23 screen
   function Beam_Text return String;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Machine.VIC20_System;
