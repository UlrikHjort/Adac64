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
