--  Audio output through PulseAudio's simple API, fed by a ring buffer.
--  The fill level of the ring buffer is used to pace the emulation.

with SID;

package Audio is

   procedure Start;
   procedure Stop;
   function Available return Boolean;

   procedure Push (S : SID.Sample);
   --  Sample sink for the SID (collected locally, see Flush).

   procedure Flush;
   --  Move collected samples into the ring buffer (call once per frame).

   function Buffered return Natural;
   --  Number of samples waiting in the ring buffer.

   Muted : Boolean := False;

end Audio;
