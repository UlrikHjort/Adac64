--  Collects SID samples in memory and writes them as a WAV file
--  (used by headless mode for testing).

with SID;

package Wav_Sink is
   procedure Push (S : SID.Sample);
   procedure Save (Path : String);
end Wav_Sink;
