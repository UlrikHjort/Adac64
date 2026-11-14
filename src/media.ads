--  Disk/tape image handling for the KERNAL LOAD/SAVE traps.
--
--  Supported: D64 (35/40 track), T64, and raw PRG files.  When no image
--  is attached, device 8 maps to a host directory: LOAD reads NAME.prg,
--  SAVE writes NAME.prg.

with Types; use Types;

package Media is

   type Media_Kind is (None, D64, D71, G64, T64, PRG);

   procedure Attach (Path : String; Ok : out Boolean);
   procedure Detach;
   function Kind return Media_Kind;
   function Attached_Name return String;
   function Attached_Path return String;

   Host_Dir : access String := null;    --  null = current directory

   procedure Find_File
     (Name  : Byte_Array;          --  PETSCII file name
      Data  : out Byte_Array_Access;   --  includes 2-byte load address
      Found : out Boolean);
   --  "$" yields a BASIC directory listing.  Wildcards '*' and '?' work.

   function Last_Lookup_Unreliable return Boolean;
   --  True if the last Find_File read sectors that did not decode cleanly
   --  from a G64 (copy protection or damage).

   procedure Save_File (Name : Byte_Array; Data : Byte_Array; Ok : out Boolean);
   --  Save to the host directory (always, regardless of attached image).

   function Image_Data return Byte_Array_Access;
   --  The attached image itself (D64 sectors), for the true drive emulation.

   function Image_Writable return Boolean;
   --  False if the image file is read-only (drive reports write protect).

   procedure Save_Image;
   --  Write the (modified) attached image back to its file.

   function First_Load_Address return Word;

   function Start_Program_Name (For_C128 : Boolean := False) return String;
   --  D64/G64: name of the first BASIC PRG ($0801, or $1C01/$4001 for the
   --  C128), or "".

   function First_Program_Name return String;

   function Has_Boot_Sector return Boolean;
   --  Track 1 sector 0 starts with "CBM": the C128 KERNAL boots it itself.
   --  D64/G64: name of the first PRG ("*" if unknown or unprintable).
   --  Load address of the first file on the attached medium (0 if none).

end Media;
