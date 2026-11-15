-- ***************************************************************************
--                      AdaC64 - IEEE_Drive
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

--  A disk drive on the PET's IEEE-488 bus, done in software: it answers
--  the bus handshake (DAV / NRFD / NDAC, ATN, EOI) whenever the computer
--  changes a line, takes LISTEN / TALK / OPEN / CLOSE commands under ATN,
--  and serves LOAD (files and the "$" directory) and SAVE from the
--  attached image or the host directory through Media.
--
--  Lines are True when asserted (pulled low). The data lines are given as
--  the raw bus levels (the PET puts the inverted byte on them).

with Types; use Types;

package IEEE_Drive is

   Device : Natural := 8;

   --  The computer's outputs
   CPU_ATN, CPU_DAV, CPU_NRFD, CPU_NDAC, CPU_EOI : Boolean := False;
   CPU_Data : Byte := 16#FF#;

   procedure Update;
   --  Call after the computer changed any of its outputs

   --  The bus as the computer reads it
   function ATN return Boolean is (CPU_ATN);
   function DAV return Boolean;
   function NRFD return Boolean;
   function NDAC return Boolean;
   function EOI return Boolean;
   function Data return Byte;

   procedure Reset;

end IEEE_Drive;
