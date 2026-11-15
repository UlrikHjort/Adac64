-- ***************************************************************************
--                      AdaC64 - VIC_I
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

--  MOS 6560 (NTSC) / 6561 (PAL) Video Interface Chip of the VIC-20:
--  video (drawn a raster line at a time from the current registers)
--  and its sound (three square-wave voices and noise).
--
--  Fetch reads the VIC's 14-bit address space; Color reads the 4-bit
--  colour RAM (index 0 .. 1023).

with Ada.Streams;
with Types; use Types;

generic
   with function Fetch (Addr : Word) return Byte;
   with function Color (Index : Natural) return Byte;
package VIC_I is

   type Standard_Kind is (PAL, NTSC);
   procedure Set_Standard (S : Standard_Kind);
   function Clock_Hz return Natural;           --  CPU clock
   function Cycles_Per_Line return Positive;
   function Lines_Per_Frame return Positive;

   procedure Reset;
   function Read (Reg : Natural) return Byte;  --  $9000 + Reg (0 .. 15)
   procedure Write (Reg : Natural; Value : Byte);
   procedure Tick (Cycles : Natural);

   Frame_Done : Boolean := False;   --  set at the end of every frame

   Pot_X, Pot_Y : Byte := 16#FF#;   --  paddle inputs ($9008 / $9009)

   procedure Set_Light_Pen (FX, FY : Float; On : Boolean);
   --  Light pen at FX / FY (0 .. 1) across the shown picture; while On the
   --  VIC latches the beam position into $9006 / $9007 once per frame,
   --  when the beam passes the pen (as in VICE)

   function Raster return Natural;
   function Screen_Address return Word;   --  VIC address of the matrix
   function Register (Reg : Natural) return Byte;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end VIC_I;
