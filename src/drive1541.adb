with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;
with Types; use Types;

with MOS6502;
with VIA;
with IEC;
with Media;

package body Drive1541 is

   RAM : Byte_Array (0 .. 2047) := (others => 0);
   ROM : Byte_Array (0 .. 16383) := (others => 0);
   Have_ROM : Boolean := False;

   VIA1, VIA2 : VIA.Chip;
   Drive_Time : Long_Long_Integer := 0;

   ---------------------------------------------------------------------
   --  Disk surface
   ---------------------------------------------------------------------

   Max_Tracks : constant := 42;
   type Track_Data is record
      Data  : Byte_Array_Access := null;
      Len   : Natural := 0;
      Dirty : Boolean := False;
   end record;
   Tracks : array (1 .. Max_Tracks) of Track_Data;
   Disk_Present : Boolean := False;
   Disk_Tracks  : Natural := 0;     --  tracks present in the D64

   Half_Track : Natural := 36;      --  track 18
   Head_Pos   : Natural := 0;       --  byte position on the track
   Byte_Clock : Natural := 0;
   Sync       : Boolean := False;
   Read_Latch : Byte := 0;
   Motor_Was_On : Boolean := False;

   function Sectors_On (Track : Natural) return Natural is
     (if Track <= 17 then 21
      elsif Track <= 24 then 19
      elsif Track <= 30 then 18
      else 17);

   function Zone_Of (Track : Natural) return Natural is
     (if Track <= 17 then 3
      elsif Track <= 24 then 2
      elsif Track <= 30 then 1
      else 0);

   Track_Bytes : constant array (0 .. 3) of Natural := (6250, 6666, 7142, 7692);

   function Sector_Offset (Track, Sector : Natural) return Natural is
      Off : Natural := 0;
   begin
      for T in 1 .. Track - 1 loop
         Off := Off + Sectors_On (T);
      end loop;
      return (Off + Sector) * 256;
   end Sector_Offset;

   GCR_Code : constant array (Byte range 0 .. 15) of Unsigned_64 :=
     (16#0A#, 16#0B#, 16#12#, 16#13#, 16#0E#, 16#0F#, 16#16#, 16#17#,
      16#09#, 16#19#, 16#1A#, 16#1B#, 16#0D#, 16#1D#, 16#1E#, 16#15#);

   GCR_Decode : array (Unsigned_64 range 0 .. 31) of Byte := (others => 0);

   --  Encode Src (multiple of 4 bytes) as GCR into Dst starting at Pos
   procedure Encode (Src : Byte_Array; Dst : in out Byte_Array;
                     Pos : in out Natural) is
      I : Natural := Src'First;
      Bits : Unsigned_64;
   begin
      while I + 3 <= Src'Last loop
         Bits := 0;
         for K in 0 .. 3 loop
            Bits := Shift_Left (Bits, 10) or
              Shift_Left (GCR_Code (Shift_Right (Src (I + K), 4)), 5) or
              GCR_Code (Src (I + K) and 15);
         end loop;
         for K in reverse 0 .. 4 loop
            Dst (Pos) := Byte (Shift_Right (Bits, K * 8) and 16#FF#);
            Pos := Pos + 1;
         end loop;
         I := I + 4;
      end loop;
   end Encode;

   procedure Fill (Dst : in out Byte_Array; Pos : in out Natural;
                   Count : Natural; Value : Byte) is
   begin
      for K in 1 .. Count loop
         if Pos <= Dst'Last then
            Dst (Pos) := Value;
            Pos := Pos + 1;
         end if;
      end loop;
   end Fill;

   procedure Build_Track (T : Natural) is
      Img  : constant Byte_Array_Access := Media.Image_Data;
      Len  : constant Natural := Track_Bytes (Zone_Of (T));
      Data : constant Byte_Array_Access := new Byte_Array'(0 .. Len - 1 => 0);
      Pos  : Natural := 0;
   begin
      Tracks (T) := (Data => Data, Len => Len, Dirty => False);
      if T > Disk_Tracks then
         return;     --  unformatted: no sync marks
      end if;
      declare
         BAM : constant Natural := Sector_Offset (18, 0);
         Id1 : constant Byte := Img (BAM + 16#A2#);
         Id2 : constant Byte := Img (BAM + 16#A3#);
         N   : constant Natural := Sectors_On (T);
         Gap : constant Natural := (Len - N * 354) / N;
      begin
         for S in 0 .. N - 1 loop
            declare
               Hdr : constant Byte_Array (0 .. 7) :=
                 (16#08#, Byte (S) xor Byte (T) xor Id2 xor Id1,
                  Byte (S), Byte (T), Id2, Id1, 16#0F#, 16#0F#);
               Blk : Byte_Array (0 .. 259);
               Off : constant Natural := Sector_Offset (T, S);
               Chk : Byte := 0;
            begin
               Fill (Data.all, Pos, 5, 16#FF#);
               Encode (Hdr, Data.all, Pos);
               Fill (Data.all, Pos, 9, 16#55#);
               Fill (Data.all, Pos, 5, 16#FF#);
               Blk (0) := 16#07#;
               for K in 0 .. 255 loop
                  Blk (K + 1) := Img (Off + K);
                  Chk := Chk xor Img (Off + K);
               end loop;
               Blk (257) := Chk;
               Blk (258) := 0;
               Blk (259) := 0;
               Encode (Blk, Data.all, Pos);
               Fill (Data.all, Pos, Gap, 16#55#);
            end;
         end loop;
         Fill (Data.all, Pos, Len - Pos, 16#55#);
      end;
   end Build_Track;

   --  Decode a modified track back into the D64 image
   procedure Decode_Track (T : Natural) is
      Img  : constant Byte_Array_Access := Media.Image_Data;
      Trk  : Track_Data renames Tracks (T);
      Len  : constant Natural := Trk.Len;
      Pending_Sector : Integer := -1;

      function At_Pos (P : Natural) return Byte is
        (Trk.Data (P mod Len));

      procedure Decode (P : Natural; Count : Natural; Dst : out Byte_Array) is
         Q : Natural := P;
         D : Natural := Dst'First;
         Bits : Unsigned_64;
      begin
         for G in 1 .. Count / 4 loop
            Bits := 0;
            for K in 0 .. 4 loop
               Bits := Shift_Left (Bits, 8) or Unsigned_64 (At_Pos (Q));
               Q := Q + 1;
            end loop;
            for K in 0 .. 3 loop
               Dst (D) := Shift_Left
                 (GCR_Decode (Shift_Right (Bits, 35 - K * 10) and 31), 4) or
                 GCR_Decode (Shift_Right (Bits, 30 - K * 10) and 31);
               D := D + 1;
            end loop;
         end loop;
      end Decode;

      P : Natural := 0;
   begin
      if Img = null or else T > Disk_Tracks then
         return;
      end if;
      --  Start on a gap byte before a sync so every sync is seen whole,
      --  and scan a little beyond one revolution to finish the last block.
      P := Len - 1;
      while P > 0 and then At_Pos (P) = 16#FF# loop
         P := P - 1;
      end loop;
      declare
         Stop : constant Natural := P + Len + 400;
      begin
         while P < Stop loop
            if At_Pos (P) = 16#FF# and then At_Pos (P + 1) = 16#FF# then
               while At_Pos (P) = 16#FF# and then P < Stop + Len loop
                  P := P + 1;
               end loop;
               declare
                  First : Byte_Array (0 .. 3);
               begin
                  Decode (P, 4, First);
                  if First (0) = 16#08# then
                     declare
                        Hdr : Byte_Array (0 .. 7);
                     begin
                        Decode (P, 8, Hdr);
                        if Natural (Hdr (3)) = T
                          and then Natural (Hdr (2)) < Sectors_On (T)
                        then
                           Pending_Sector := Integer (Hdr (2));
                        end if;
                        P := P + 10;
                     end;
                  elsif First (0) = 16#07# and then Pending_Sector >= 0 then
                     declare
                        Blk : Byte_Array (0 .. 259);
                        Off : constant Natural :=
                          Sector_Offset (T, Natural (Pending_Sector));
                     begin
                        Decode (P, 260, Blk);
                        Img (Off .. Off + 255) := Blk (1 .. 256);
                        Pending_Sector := -1;
                        P := P + 325;
                     end;
                  else
                     P := P + 1;
                  end if;
               end;
            else
               P := P + 1;
            end if;
         end loop;
      end;
   end Decode_Track;

   procedure Flush is
      Changed : Boolean := False;
   begin
      if not Disk_Present then
         return;
      end if;
      for T in Tracks'Range loop
         if Tracks (T).Dirty then
            Decode_Track (T);
            Tracks (T).Dirty := False;
            Changed := True;
         end if;
      end loop;
      if Changed then
         Media.Save_Image;
      end if;
   end Flush;

   procedure Insert_Disk is
      Img : constant Byte_Array_Access := Media.Image_Data;
   begin
      Eject_Disk;
      if Img = null or else Img'Length < 174_848 then
         return;
      end if;
      Disk_Tracks := (if Img'Length >= 196_608 then 40 else 35);
      for T in Tracks'Range loop
         Build_Track (T);
      end loop;
      Disk_Present := True;
      Head_Pos := 0;
   end Insert_Disk;

   procedure Eject_Disk is
   begin
      Flush;
      Disk_Present := False;
      Disk_Tracks := 0;
      for T in Tracks'Range loop
         Tracks (T) := (others => <>);
      end loop;
   end Eject_Disk;

   function Track_Of_Head return Natural is
     (if Half_Track mod 2 = 0 then Half_Track / 2 else 0);

   ---------------------------------------------------------------------
   --  Disk controller (VIA2) helpers
   ---------------------------------------------------------------------

   function Motor_On return Boolean is ((VIA.Port_B_Out (VIA2) and 4) /= 0);
   function LED_On return Boolean is ((VIA.Port_B_Out (VIA2) and 8) /= 0);
   function Current_Track return Natural is ((Half_Track + 1) / 2);

   Last_Phase : Byte := 0;

   procedure VIA2_Changed is
      Phase : constant Byte := VIA2.ORB and 3;
      Old_Track : constant Natural := Track_Of_Head;
   begin
      case (Phase - Last_Phase) and 3 is
         when 1 =>
            if Half_Track < 2 * Max_Tracks then
               Half_Track := Half_Track + 1;
            end if;
         when 3 =>
            if Half_Track > 2 then
               Half_Track := Half_Track - 1;
            end if;
         when others => null;
      end case;
      Last_Phase := Phase;

      if Track_Of_Head /= Old_Track and then Disk_Present then
         --  Keep the angular position when moving between tracks
         if Old_Track /= 0 and then Track_Of_Head /= 0 then
            Head_Pos := Head_Pos * Tracks (Track_Of_Head).Len /
              Tracks (Old_Track).Len;
         end if;
         if Old_Track /= 0 and then Tracks (Old_Track).Dirty then
            Flush;
         end if;
      end if;

      if Motor_Was_On and then not Motor_On then
         Flush;
      end if;
      Motor_Was_On := Motor_On;
   end VIA2_Changed;

   ---------------------------------------------------------------------
   --  Drive CPU bus
   ---------------------------------------------------------------------

   function Drive_Read (Addr : Word) return Byte;
   procedure Drive_Write (Addr : Word; Value : Byte);

   package CPU is new MOS6502 (Read => Drive_Read, Write => Drive_Write);

   procedure Update_Bus_Outputs is
      PB : constant Byte := VIA.Port_B_Out (VIA1);
   begin
      IEC.Drive_DATA := (PB and 16#02#) /= 0;
      IEC.Drive_CLK  := (PB and 16#08#) /= 0;
      IEC.Drive_ATNA := (PB and 16#10#) /= 0;
   end Update_Bus_Outputs;

   function Drive_Read (Addr : Word) return Byte is
   begin
      case Addr is
         when 16#0000# .. 16#17FF# =>
            return RAM (Natural (Addr and 16#07FF#));
         when 16#1800# .. 16#1BFF# =>
            --  Serial bus inputs (inverted); device number jumpers = 8
            VIA1.Port_B_In :=
              (if IEC.DATA then 16#01# else 0) or
              (if IEC.CLK then 16#04# else 0) or
              (if IEC.ATN then 16#80# else 0);
            return VIA.Read (VIA1, Natural (Addr and 15));
         when 16#1C00# .. 16#1FFF# =>
            VIA2.Port_B_In :=
              (if Media.Image_Writable then 16#10# else 0) or
              (if Sync then 0 else 16#80#);
            VIA2.Port_A_In := Read_Latch;
            return VIA.Read (VIA2, Natural (Addr and 15));
         when 16#8000# .. 16#FFFF# =>
            return ROM (Natural (Addr and 16#3FFF#));
         when others =>
            return Hi (Addr);
      end case;
   end Drive_Read;

   procedure Drive_Write (Addr : Word; Value : Byte) is
   begin
      case Addr is
         when 16#0000# .. 16#17FF# =>
            RAM (Natural (Addr and 16#07FF#)) := Value;
         when 16#1800# .. 16#1BFF# =>
            VIA.Write (VIA1, Natural (Addr and 15), Value);
            Update_Bus_Outputs;
         when 16#1C00# .. 16#1FFF# =>
            VIA.Write (VIA2, Natural (Addr and 15), Value);
            VIA2_Changed;
         when others =>
            null;
      end case;
   end Drive_Write;

   ---------------------------------------------------------------------
   --  Rotation
   ---------------------------------------------------------------------

   procedure Byte_Ready is
   begin
      if VIA.CA2_High (VIA2) then
         CPU.Flag_V := True;      --  BYTE READY drives the 6502 SO pin
      end if;
      VIA2.IFR := VIA2.IFR or VIA.IFR_CA1;
   end Byte_Ready;

   procedure Rotate (Cycles : Natural) is
      T : constant Natural := Track_Of_Head;
      Zone : Natural;
      Per_Byte : Natural;
   begin
      if not Disk_Present or else not Motor_On then
         Sync := False;
         return;
      end if;
      Zone := Natural (Shift_Right (VIA2.ORB, 5) and 3);
      Per_Byte := 32 - 2 * Zone;
      Byte_Clock := Byte_Clock + Cycles;
      while Byte_Clock >= Per_Byte loop
         Byte_Clock := Byte_Clock - Per_Byte;
         if T = 0 then
            --  Between tracks: no flux transitions
            Sync := False;
            Read_Latch := 0;
            Byte_Ready;
         else
            declare
               Trk : Track_Data renames Tracks (T);
            begin
               Head_Pos := (Head_Pos + 1) mod Trk.Len;
               if not VIA.CB2_High (VIA2) then
                  --  Write mode
                  Trk.Data (Head_Pos) := VIA.Port_A_Out (VIA2) or
                    (VIA2.ORA and not VIA2.DDRA);
                  Trk.Dirty := True;
                  Sync := False;
                  Byte_Ready;
               else
                  declare
                     B : constant Byte := Trk.Data (Head_Pos);
                     Prev : constant Byte :=
                       Trk.Data ((Head_Pos + Trk.Len - 1) mod Trk.Len);
                     Next : constant Byte :=
                       Trk.Data ((Head_Pos + 1) mod Trk.Len);
                  begin
                     Sync := B = 16#FF# and then
                       (Prev = 16#FF# or else Next = 16#FF#);
                     if not Sync then
                        Read_Latch := B;
                        Byte_Ready;
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Rotate;

   ---------------------------------------------------------------------
   --  Public operations
   ---------------------------------------------------------------------

   procedure Load_ROM (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      if Size (F) /= 16384 then
         Close (F);
         Ok := False;
         return;
      end if;
      Byte_Array'Read (Stream (F), ROM);
      Close (F);
      Have_ROM := True;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Load_ROM;

   function ROM_Loaded return Boolean is (Have_ROM);

   procedure Reset is
   begin
      RAM := (others => 0);
      VIA.Reset (VIA1);
      VIA.Reset (VIA2);
      Update_Bus_Outputs;
      VIA.Set_CA1 (VIA1, IEC.ATN);
      Drive_Time := 0;
      Byte_Clock := 0;
      Sync := False;
      Last_Phase := 0;
      Motor_Was_On := False;
      CPU.IRQ_Line := False;
      CPU.Reset;
   end Reset;

   procedure Set_Time (C64_Cycles : Long_Long_Integer) is
   begin
      Drive_Time := C64_Cycles * 1_000_000 / 985_248;
   end Set_Time;

   procedure ATN_Changed is
   begin
      VIA.Set_CA1 (VIA1, IEC.ATN);
   end ATN_Changed;

   procedure Run_Until (C64_Cycles : Long_Long_Integer) is
      Target : constant Long_Long_Integer := C64_Cycles * 1_000_000 / 985_248;
      N : Natural;
   begin
      while Drive_Time < Target loop
         CPU.IRQ_Line := VIA.IRQ (VIA1) or else VIA.IRQ (VIA2);
         CPU.Step (N);
         VIA.Tick (VIA1, N);
         VIA.Tick (VIA2, N);
         Rotate (N);
         Drive_Time := Drive_Time + Long_Long_Integer (N);
      end loop;
   end Run_Until;

begin
   for N in Byte range 0 .. 15 loop
      GCR_Decode (GCR_Code (N)) := N;
   end loop;
end Drive1541;
