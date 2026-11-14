--  Commodore 1541 disk drive: its own 6502, 2 KB RAM, 16 KB DOS ROM,
--  two 6522 VIAs (serial bus / disk controller) and a GCR disk surface
--  generated from the attached D64 image.  The drive is run in lockstep
--  with the computer through Run_Until.


package Drive1541 is

   procedure Load_ROM (Path : String; Ok : out Boolean);
   function ROM_Loaded return Boolean;

   procedure Reset;
   --  Power-on reset of the drive (time base restarts at 0).

   procedure Insert_Disk;
   --  Build the GCR tracks from Media.Image_Data (a D64).

   procedure Eject_Disk;
   --  Write back modified tracks and remove the disk.

   procedure Flush;
   --  Write modified tracks back into the D64 image and its file.

   procedure Run_Until (C64_Cycles : Long_Long_Integer);
   --  Run the drive until it has caught up with the given computer time
   --  (computer cycles at 985248 Hz; the drive runs at 1 MHz).

   procedure Set_Time (C64_Cycles : Long_Long_Integer);
   --  Align the drive clock with the computer time (drive was idle).

   procedure ATN_Changed;
   --  The computer changed the ATN line (drives VIA1 CA1).

   function LED_On return Boolean;
   function Motor_On return Boolean;
   function Current_Track return Natural;    --  1 .. 42 (half tracks rounded)

end Drive1541;
