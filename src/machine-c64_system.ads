-- ***************************************************************************
--                      AdaC64 - Machine.C64_System
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

--  The C64 and the C128: VIC-II, two CIAs, SID, the CPU port, the C128's
--  MMU, VDC and Z80, the REU and .crt cartridges on the expansion port.

with Ada.Streams;

private package Machine.C64_System is

   procedure Init;
   --  Once, before the first Power_On (hooks to the drive and the REU)
   procedure Load_ROMs (ROM_Dir : String; Ok : in out Boolean);
   procedure Set_Standard (V : Video_Standard);
   procedure Reset (Hard : Boolean);

   procedure Rebuild_Map;
   function IO_Read (Addr : Word) return Byte;
   procedure IO_Write (Addr : Word; Value : Byte);
   function IO_Peek (Addr : Word) return Byte;   --  no side effects
   procedure Clock (N : Natural);

   --  CPU port ($00 / $01) and the C128 MMU configuration at $FF00-$FF04
   function Port_Read (Addr : Word) return Byte;
   procedure Port_Write (Addr : Word; Value : Byte);
   function MMU_Read (Reg : Natural) return Byte;
   procedure MMU_Config_Write (Addr : Word; Value : Byte);
   procedure FF00_Written;            --  C64: a write to $FF00 (REU)

   function Fast_2MHz return Boolean; --  C128 FAST
   function Take_Stall return Natural;
   function Stalled return Boolean;
   --  Cycles the CPU is halted (bad lines, sprites, REU DMA)
   function Z80_Running return Boolean;
   function Z80_Used return Boolean;
   procedure Step_Z80 (Device_Cycles : out Natural);
   procedure Interrupt_Lines (IRQ, NMI : out Boolean);

   function Frame_Done return Boolean;
   procedure Clear_Frame;
   procedure End_Of_Frame;

   procedure Attach_Cartridge (Path : String; Ok : out Boolean);
   procedure Detach_Cartridge;
   function Cartridge_Name return String;

   function Screen_Byte (I : Natural) return Byte;  --  40-column screen
   function VDC_Screen_Byte (I : Natural) return Byte;
   function VIC_Peek (Addr : Word) return Byte;
   function VIC_Bank_Address return Word;
   function Char_ROM_Peek (Offset : Natural) return Byte;

   function Beam_Text return String;   --  raster line and cycle
   function Debug_Text return String;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Machine.C64_System;
