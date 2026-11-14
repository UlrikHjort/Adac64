--  Disk/tape image handling for the KERNAL LOAD/SAVE traps.
--
--  Supported: D64 (35/40 track), T64, and raw PRG files.  When no image
--  is attached, device 8 maps to a host directory: LOAD reads NAME.prg,
--  SAVE writes NAME.prg.

with Types; use Types;

package Media is

   type Media_Kind is (None, D64, T64, PRG);

   procedure Attach (Path : String; Ok : out Boolean);
   procedure Detach;
   function Kind return Media_Kind;
   function Attached_Name return String;

   Host_Dir : access String := null;    --  null = current directory

   procedure Find_File
     (Name  : Byte_Array;          --  PETSCII file name
      Data  : out Byte_Array_Access;   --  includes 2-byte load address
      Found : out Boolean);
   --  "$" yields a BASIC directory listing.  Wildcards '*' and '?' work.

   procedure Save_File (Name : Byte_Array; Data : Byte_Array; Ok : out Boolean);
   --  Save to the host directory (always, regardless of attached image).

   function First_Load_Address return Word;
   --  Load address of the first file on the attached medium (0 if none).

end Media;
