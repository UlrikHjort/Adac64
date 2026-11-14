--  MOS 6581 / 8580 SID sound chip.
--
--  Samples are generated synchronously with the emulated clock
--  (Clock is called with the number of elapsed cycles), so register
--  writes take effect with sample accuracy.

with Ada.Streams;
with Types; use Types;

package SID is

   Sample_Rate : constant := 44_100;
   Clock_Rate  : Natural := 985_248;    --  phi2 (PAL; NTSC 1_022_727)

   procedure Set_Clock (Hz : Natural);

   type Chip_Model is (MOS6581, MOS8580);
   procedure Set_Model (M : Chip_Model);
   function Model return Chip_Model;
   --  6581: original C64 (sparse combined waveforms, non-linear filter,
   --  loud volume-register digis); 8580: C64C/C128DCR.

   type Sample is range -32768 .. 32767;
   for Sample'Size use 16;

   procedure Reset;
   procedure Write (Reg : Natural; Value : Byte);
   function Read (Reg : Natural) return Byte;

   procedure Clock (Cycles : Natural);
   --  Advance the SID; produced samples are pushed to the sample sink.

   type Sink_Proc is access procedure (S : Sample);
   Sink : Sink_Proc := null;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   --  Snapshot support (call between frames).

end SID;
