with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;

package body Wav_Sink is

   Max : constant := SID.Sample_Rate * 120;
   type Buffer is array (0 .. Max - 1) of SID.Sample;
   type Buffer_Access is access Buffer;
   Buf : constant Buffer_Access := new Buffer;
   Count : Natural := 0;

   procedure Push (S : SID.Sample) is
   begin
      if Count < Max then
         Buf (Count) := S;
         Count := Count + 1;
      end if;
   end Push;

   procedure Save (Path : String) is
      F : File_Type;
      S : Stream_Access;
      Data_Bytes : constant Unsigned_32 := Unsigned_32 (Count * 2);
   begin
      Create (F, Out_File, Path);
      S := Stream (F);
      String'Write (S, "RIFF");
      Unsigned_32'Write (S, 36 + Data_Bytes);
      String'Write (S, "WAVEfmt ");
      Unsigned_32'Write (S, 16);
      Unsigned_16'Write (S, 1);                       --  PCM
      Unsigned_16'Write (S, 1);                       --  mono
      Unsigned_32'Write (S, SID.Sample_Rate);
      Unsigned_32'Write (S, SID.Sample_Rate * 2);
      Unsigned_16'Write (S, 2);
      Unsigned_16'Write (S, 16);
      String'Write (S, "data");
      Unsigned_32'Write (S, Data_Bytes);
      for I in 0 .. Count - 1 loop
         SID.Sample'Write (S, Buf (I));
      end loop;
      Close (F);
   end Save;

end Wav_Sink;
