-- ***************************************************************************
--                      AdaC64 - Disk_Image
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

--  Writing new D64 disk images (35 tracks, 683 blocks) for Forge.
--
--  Files are laid out like a 1541 does it: starting next to the
--  directory track (17 downwards, then 19 upwards) with a sector
--  interleave of 10; the directory uses track 18 with interleave 3.

with Types; use Types;

package Disk_Image is

   type File_Type is (PRG, SEQ, USR);

   procedure Create (Disk_Name : String; Disk_Id : String := "01");
   --  Start an empty disk (names are ASCII; letters become PETSCII
   --  upper case as on a real directory listing).

   procedure Add_File (Name : String; Data : Byte_Array;
                       Kind : File_Type := PRG; Ok : out Boolean);
   --  Data includes the 2-byte load address for PRG files.  Fails when
   --  the disk or the directory (144 entries) is full.

   function Blocks_Free return Natural;
   function File_Count return Natural;
   function Error return String;          --  why the last Add_File failed

   procedure Save (Path : String; Ok : out Boolean);

end Disk_Image;
