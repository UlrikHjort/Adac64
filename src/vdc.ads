-- ***************************************************************************
--                      AdaC64 - VDC
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

--  MOS 8563 VDC: the C128 80-column video controller.

with Ada.Streams;
with Types; use Types;

package VDC is

   procedure Reset;
   procedure Set_Frame_Cycles (N : Natural);   --  computer cycles per frame

   function Read_Status return Byte;           --  $D600
   function Read_Data return Byte;             --  $D601
   procedure Write_Address (Value : Byte);     --  $D600
   procedure Write_Data (Value : Byte);        --  $D601

   procedure Render_Frame;
   --  Render the current screen into Video.VDC_FB (called once per frame).

   procedure Tick (Cycles : Natural);
   --  Advance the internal raster position (for the vblank status bit).

   function Peek_VRAM (Addr : Natural) return Byte;
   function Peek_Reg (N : Natural) return Byte;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   --  Snapshot support (call between frames).

end VDC;
