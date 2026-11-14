with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;

with MOS6502;
with CIA;
with VIA;
with IEC;
with Media;
use type Media.Media_Kind;

package body Drive1541 is

   RAM : Byte_Array (0 .. 2047) := (others => 0);
   ROM_1541 : Byte_Array (0 .. 16383) := (others => 0);
   ROM_1571 : Byte_Array (0 .. 32767) := (others => 0);
   Have_1541, Have_1571 : Boolean := False;
   Current_Model : Drive_Model := D1541;

   --  1571 extras
   Drive_CIA   : CIA.Chip;
   WD_Regs     : Byte_Array (0 .. 3) := (others => 0);
   --  WD1770: 0 = status (read) / command (write), 1 track, 2 sector, 3 data
   WD_Status   : Byte := 0;
   WD_Busy     : Long_Long_Integer := 0;   --  remaining busy time (1/2 us)
   WD_Result   : Byte := 0;                --  status when the command ends
   Side        : Natural := 0;          --  head (disk side)
   Fast_Clock  : Boolean := False;      --  2 MHz
   Fast_Out    : Boolean := False;      --  fast serial direction: output
   Byte_Level  : Boolean := False;      --  /BYTE READY line (VIA1 PA7)

   function Is_1571 return Boolean is (Current_Model = D1571);

   VIA1, VIA2 : VIA.Chip;
   Drive_Time : Long_Long_Integer := 0;
   Host_Clock : Long_Long_Integer := 985_248;

   ---------------------------------------------------------------------
   --  Disk surface
   ---------------------------------------------------------------------

   --  Tracks are indexed by half-track: track T is half-track 2*T.
   Min_Half : constant := 2;
   Max_Half : constant := 185;      --  side 1 half-tracks are offset by 100
   Side_Offset : constant := 100;
   Max_Tracks : constant := 42;
   type Track_Data is record
      Data  : Byte_Array_Access := null;
      Len   : Natural := 0;         --  bytes
      Dirty : Boolean := False;
      File_Offset : Natural := 0;   --  G64: where the track lives in the file
   end record;
   Tracks : array (Min_Half .. Max_Half) of Track_Data;

   type Disk_Kind is (No_Disk, D64_Disk, D71_Disk, G64_Disk);
   Disk : Disk_Kind := No_Disk;
   Disk_Tracks  : Natural := 0;     --  tracks present in a D64

   Half_Track : Natural := 36;      --  track 18

   function Cur return Natural is (Half_Track + Side * Side_Offset);
   Bit_Pos    : Natural := 0;       --  bit position on the current track
   Bit_Clock  : Natural := 0;       --  in 1/8 cycle units
   One_Count  : Natural := 0;       --  consecutive 1 bits read
   Bit_Count  : Natural := 0;       --  bits in the current byte
   Shift_In   : Byte := 0;
   Shift_Out  : Byte := 0;
   Sync       : Boolean := False;
   Read_Latch : Byte := 0;
   Motor_Was_On : Boolean := False;

   function Disk_Present return Boolean is (Disk /= No_Disk);

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
      if Track > 35 and then Disk = D71_Disk then
         return 683 * 256 + Sector_Offset (Track - 35, Sector);
      end if;
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

   procedure Build_Track (Phys : Natural; S : Natural := 0) is
      --  Phys = physical track on the given side; on side 1 of a D71 the
      --  headers carry track numbers 36..70 (logical track T)
      T    : constant Natural := Phys + (if S = 1 then 35 else 0);
      Img  : constant Byte_Array_Access := Media.Image_Data;
      Len  : constant Natural := Track_Bytes (Zone_Of (Phys));
      Data : constant Byte_Array_Access := new Byte_Array'(0 .. Len - 1 => 0);
      Pos  : Natural := 0;
   begin
      Tracks (2 * Phys + S * Side_Offset) :=
        (Data => Data, Len => Len, others => <>);
      if T > Disk_Tracks or else (S = 1 and then Phys > 35) then
         return;     --  unformatted: no sync marks
      end if;
      declare
         BAM : constant Natural := Sector_Offset (18, 0);
         Id1 : constant Byte := Img (BAM + 16#A2#);
         Id2 : constant Byte := Img (BAM + 16#A3#);
         N   : constant Natural := Sectors_On (Phys);
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

   function Get_Bit (Trk : Track_Data; P : Natural) return Natural is
      Q : constant Natural := P mod (Trk.Len * 8);
   begin
      return Natural (Shift_Right (Trk.Data (Q / 8), 7 - Q mod 8) and 1);
   end Get_Bit;

   --  Decode GCR bytes (5 GCR bytes -> 4 data bytes)
   procedure Decode (Src : Byte_Array; Dst : out Byte_Array) is
      Q : Natural := Src'First;
      D : Natural := Dst'First;
      Bits : Unsigned_64;
   begin
      while D + 3 <= Dst'Last and then Q + 4 <= Src'Last loop
         Bits := 0;
         for K in 0 .. 4 loop
            Bits := Shift_Left (Bits, 8) or Unsigned_64 (Src (Q + K));
         end loop;
         Q := Q + 5;
         for K in 0 .. 3 loop
            Dst (D) := Shift_Left
              (GCR_Decode (Shift_Right (Bits, 35 - K * 10) and 31), 4) or
              GCR_Decode (Shift_Right (Bits, 30 - K * 10) and 31);
            D := D + 1;
         end loop;
      end loop;
   end Decode;

   --  Decode a modified (bit-level) track back into the D64 image
   procedure Decode_Track (Phys : Natural; S : Natural := 0) is
      T    : constant Natural := Phys + (if S = 1 then 35 else 0);
      Img  : constant Byte_Array_Access := Media.Image_Data;
      Trk  : Track_Data renames Tracks (2 * Phys + S * Side_Offset);
      Total : constant Natural := Trk.Len * 8;
      Pending_Sector : Integer := -1;
      Ones : Natural := 0;
      P : Natural := 0;

      --  Read Count framed bytes starting at bit position Start
      function Read_Bytes (Start, Count : Natural) return Byte_Array is
         R : Byte_Array (0 .. Count - 1) := (others => 0);
      begin
         for I in R'Range loop
            for B in 0 .. 7 loop
               R (I) := Shift_Left (R (I), 1) or
                 Byte (Get_Bit (Trk, Start + I * 8 + B));
            end loop;
         end loop;
         return R;
      end Read_Bytes;
   begin
      if Img = null or else T > Disk_Tracks or else Trk.Data = null then
         return;
      end if;
      --  One revolution plus a full data block, so a block that starts
      --  just before the scan origin is decoded after wrapping.
      while P < Total + 3000 loop
         if Get_Bit (Trk, P) = 1 then
            Ones := Ones + 1;
            P := P + 1;
         elsif Ones >= 10 then
            --  End of a sync mark: a block starts at this 0 bit
            Ones := 0;
            declare
               First : Byte_Array (0 .. 3);
            begin
               Decode (Read_Bytes (P, 5), First);
               if First (0) = 16#08# then
                  declare
                     Hdr : Byte_Array (0 .. 7);
                  begin
                     Decode (Read_Bytes (P, 10), Hdr);
                     Pending_Sector :=
                       (if Natural (Hdr (3)) = T
                          and then Natural (Hdr (2)) < Sectors_On (Phys)
                        then Integer (Hdr (2)) else -1);
                     P := P + 80;
                  end;
               elsif First (0) = 16#07# and then Pending_Sector >= 0 then
                  declare
                     Blk : Byte_Array (0 .. 259);
                     Off : constant Natural :=
                       Sector_Offset (T, Natural (Pending_Sector));
                  begin
                     Decode (Read_Bytes (P, 325), Blk);
                     Img (Off .. Off + 255) := Blk (1 .. 256);
                     Pending_Sector := -1;
                     P := P + 325 * 8;
                  end;
               else
                  P := P + 1;
               end if;
            end;
         else
            Ones := 0;
            P := P + 1;
         end if;
      end loop;
   end Decode_Track;

   procedure Flush is
      Changed : Boolean := False;
      Img : constant Byte_Array_Access := Media.Image_Data;
   begin
      if not Disk_Present or else Img = null then
         return;
      end if;
      for H in Tracks'Range loop
         if Tracks (H).Dirty then
            case Disk is
               when D64_Disk | D71_Disk =>
                  if H mod 2 = 0 then
                     Decode_Track ((H mod Side_Offset) / 2, H / Side_Offset);
                  end if;
               when G64_Disk =>
                  declare
                     Trk : Track_Data renames Tracks (H);
                  begin
                     Img (Trk.File_Offset .. Trk.File_Offset + Trk.Len - 1) :=
                       Trk.Data.all;
                  end;
               when No_Disk =>
                  null;
            end case;
            Tracks (H).Dirty := False;
            Changed := True;
         end if;
      end loop;
      if Changed then
         Media.Save_Image;
      end if;
   end Flush;

   function LE16 (D : Byte_Array; I : Natural) return Natural is
     (Natural (D (I)) + 256 * Natural (D (I + 1)));
   function LE32 (D : Byte_Array; I : Natural) return Natural is
     (LE16 (D, I) + 65536 * LE16 (D, I + 2));

   procedure Insert_G64 (Img : Byte_Array) is
      Count : constant Natural := Natural'Min (Natural (Img (9)), 84);
   begin
      for I in 0 .. Count - 1 loop
         declare
            Off : constant Natural := LE32 (Img, 12 + 4 * I);
         begin
            if Off /= 0 and then Off + 2 <= Img'Last then
               declare
                  Len : constant Natural := LE16 (Img, Off);
               begin
                  if Len > 0 and then Off + 1 + Len <= Img'Last then
                     declare
                        D : constant Byte_Array_Access :=
                          new Byte_Array (0 .. Len - 1);
                     begin
                        D.all := Img (Off + 2 .. Off + 1 + Len);
                        Tracks (Min_Half + I) :=
                          (Data => D, Len => Len, Dirty => False,
                           File_Offset => Off + 2);
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      Disk := G64_Disk;
   end Insert_G64;

   procedure Insert_Disk is
      Img : constant Byte_Array_Access := Media.Image_Data;
   begin
      Eject_Disk;
      if Img = null then
         return;
      end if;
      if Media.Kind = Media.G64 then
         if Img'Length > 12 + 84 * 8 then
            Insert_G64 (Img.all);
         end if;
      elsif Media.Kind = Media.D71 then
         Disk := D71_Disk;
         Disk_Tracks := 70;
         for T in 1 .. Max_Tracks loop
            Build_Track (T, 0);
            Build_Track (T, 1);
         end loop;
      elsif Img'Length >= 174_848 then
         Disk_Tracks := (if Img'Length >= 196_608 then 40 else 35);
         Disk := D64_Disk;
         for T in 1 .. Max_Tracks loop
            Build_Track (T);
         end loop;
      end if;
      Bit_Pos := 0;
   exception
      when others =>
         Disk := No_Disk;
   end Insert_Disk;

   procedure Eject_Disk is
   begin
      Flush;
      Disk := No_Disk;
      Disk_Tracks := 0;
      for H in Tracks'Range loop
         Tracks (H) := (others => <>);
      end loop;
   end Eject_Disk;

   function Head_Has_Data return Boolean is
     (Cur in Tracks'Range and then Tracks (Cur).Data /= null);

   ---------------------------------------------------------------------
   --  Disk controller (VIA2) helpers
   ---------------------------------------------------------------------

   function Motor_On return Boolean is ((VIA.Port_B_Out (VIA2) and 4) /= 0);
   function LED_On return Boolean is ((VIA.Port_B_Out (VIA2) and 8) /= 0);
   function Current_Track return Natural is (Half_Track / 2);

   Last_Phase : Byte := 0;

   --  Keep the angular position when the head changes track or side
   procedure Head_Moved (Old : Natural) is
   begin
      if Old in Tracks'Range and then Tracks (Old).Data /= null
        and then Head_Has_Data
      then
         Bit_Pos := Natural (Long_Long_Integer (Bit_Pos) *
                               Long_Long_Integer (Tracks (Cur).Len) /
                               Long_Long_Integer (Tracks (Old).Len));
      end if;
      if Old in Tracks'Range and then Tracks (Old).Dirty then
         Flush;
      end if;
   end Head_Moved;

   procedure VIA2_Changed is
      Phase : constant Byte := VIA2.ORB and 3;
      Old_Half : constant Natural := Half_Track;
   begin
      case (Phase - Last_Phase) and 3 is
         when 1 =>
            if Half_Track < Max_Half then
               Half_Track := Half_Track + 1;
            end if;
         when 3 =>
            if Half_Track > Min_Half then
               Half_Track := Half_Track - 1;
            end if;
         when others => null;
      end case;
      Last_Phase := Phase;

      if Half_Track /= Old_Half and then Disk_Present then
         Head_Moved (Old_Half + Side * Side_Offset);
      end if;

      if Motor_Was_On and then not Motor_On then
         Flush;
      end if;
      Motor_Was_On := Motor_On;
   end VIA2_Changed;

   ---------------------------------------------------------------------
   --  Drive CPU bus
   ---------------------------------------------------------------------

   --  WD1770 floppy controller (MFM).  No MFM disk is ever present, so
   --  seeks complete and sector searches end with "record not found".
   procedure WD_Command (Cmd : Byte) is
      Motor : constant Byte := 16#80#;
   begin
      if (Cmd and 16#F0#) = 16#D0# then          --  type IV: force interrupt
         WD_Busy := 0;
         WD_Status := Motor or (if WD_Regs (1) = 0 then 16#04# else 0);
         return;
      end if;
      if (Cmd and 16#80#) = 0 then               --  type I: head moves
         case Cmd and 16#F0# is
            when 16#00# => WD_Regs (1) := 0;                   --  restore
            when 16#10# => WD_Regs (1) := WD_Regs (3);         --  seek
            when 16#40# | 16#50# => WD_Regs (1) := WD_Regs (1) + 1;
            when 16#60# | 16#70# =>
               if WD_Regs (1) > 0 then
                  WD_Regs (1) := WD_Regs (1) - 1;
               end if;
            when others => null;                                --  step
         end case;
         WD_Result := Motor or 16#20# or            --  spin-up done
           (if WD_Regs (1) = 0 then 16#04# else 0);
         WD_Busy := 6_000;                          --  3 ms
      else                                          --  types II / III
         WD_Result := Motor or 16#10#;              --  record not found
         WD_Busy := 400_000;                        --  0.2 s of searching
      end if;
      WD_Status := Motor or 1;                      --  busy
   end WD_Command;

   procedure WD_Tick (Half_Us : Long_Long_Integer) is
   begin
      if WD_Busy > 0 then
         WD_Busy := WD_Busy - Half_Us;
         if WD_Busy <= 0 then
            WD_Busy := 0;
            WD_Status := WD_Result;
         end if;
      end if;
   end WD_Tick;

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
            if Is_1571 then
               --  PA7 = /BYTE READY, PA0 = /TRACK 0 sensor
               VIA1.Port_A_In := 16#7E# or
                 (if Byte_Level then 0 else 16#80#) or
                 (if Half_Track = 2 then 0 else 1);
            end if;
            return VIA.Read (VIA1, Natural (Addr and 15));
         when 16#1C00# .. 16#1FFF# =>
            VIA2.Port_B_In :=
              (if Media.Image_Writable then 16#10# else 0) or
              (if Sync then 0 else 16#80#);
            VIA2.Port_A_In := Read_Latch;
            if (Addr and 15) in 1 | 15 then
               Byte_Level := False;     --  data byte taken
            end if;
            return VIA.Read (VIA2, Natural (Addr and 15));
         when 16#2000# .. 16#3FFF# =>
            if Is_1571 then
               --  WD1770 (MFM controller): idle, not busy
               return (if (Addr and 3) = 0 then WD_Status
                       else WD_Regs (Natural (Addr and 3)));
            end if;
            return Hi (Addr);
         when 16#4000# .. 16#7FFF# =>
            if Is_1571 then
               return CIA.Read (Drive_CIA, Natural (Addr and 15));
            end if;
            return Hi (Addr);
         when 16#8000# .. 16#FFFF# =>
            if Is_1571 then
               return ROM_1571 (Natural (Addr and 16#7FFF#));
            end if;
            return ROM_1541 (Natural (Addr and 16#3FFF#));
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
            if Is_1571 then
               declare
                  PA : constant Byte := VIA1.ORA or not VIA1.DDRA;
                  New_Side : constant Natural :=
                    Natural (Shift_Right (PA, 2) and 1);
               begin
                  Fast_Clock := (PA and 16#20#) /= 0;
                  Fast_Out := (PA and 16#02#) /= 0;
                  if New_Side /= Side then
                     declare
                        Old : constant Natural := Cur;
                     begin
                        Side := New_Side;
                        Head_Moved (Old);
                     end;
                  end if;
               end;
            end if;
         when 16#1C00# .. 16#1FFF# =>
            VIA.Write (VIA2, Natural (Addr and 15), Value);
            VIA2_Changed;
         when 16#2000# .. 16#3FFF# =>
            if Is_1571 then
               if (Addr and 3) = 0 then
                  WD_Command (Value);
               else
                  WD_Regs (Natural (Addr and 3)) := Value;
               end if;
            end if;
         when 16#4000# .. 16#7FFF# =>
            if Is_1571 then
               CIA.Write (Drive_CIA, Natural (Addr and 15), Value);
               --  Fast serial: a byte shifted out goes to the computer
               if (Addr and 15) = 12 and then Fast_Out
                 and then (Drive_CIA.CRA and 16#40#) /= 0
                 and then To_Host /= null
               then
                  To_Host (Value);
               end if;
            end if;
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
      Byte_Level := True;
   end Byte_Ready;

   --  One bit cell under the head (read or write)
   procedure Process_Bit is
   begin
      if not Head_Has_Data then
         --  No flux transitions: the controller still frames bytes
         Sync := False;
         One_Count := 0;
         Bit_Count := Bit_Count + 1;
         if Bit_Count >= 8 then
            Bit_Count := 0;
            Read_Latch := 0;
            Byte_Ready;
         end if;
         return;
      end if;

      declare
         Trk : Track_Data renames Tracks (Cur);
         Total : constant Natural := Trk.Len * 8;
      begin
         if Bit_Pos >= Total then
            Bit_Pos := 0;
         end if;
         if not VIA.CB2_High (VIA2) then
            --  Write mode: the shift register is reloaded from port A
            --  every 8 bits, which also signals BYTE READY.
            if Bit_Count = 0 then
               Shift_Out := VIA2.ORA;
               Byte_Ready;
            end if;
            declare
               Mask : constant Byte := Shift_Right (16#80#, Bit_Pos mod 8);
               Idx  : constant Natural := Bit_Pos / 8;
            begin
               if (Shift_Out and 16#80#) /= 0 then
                  Trk.Data (Idx) := Trk.Data (Idx) or Mask;
               else
                  Trk.Data (Idx) := Trk.Data (Idx) and not Mask;
               end if;
            end;
            Shift_Out := Shift_Left (Shift_Out, 1);
            Bit_Count := (Bit_Count + 1) mod 8;
            Trk.Dirty := True;
            Sync := False;
            One_Count := 0;
         else
            declare
               B : constant Natural := Get_Bit (Trk, Bit_Pos);
            begin
               if B = 1 then
                  One_Count := One_Count + 1;
               else
                  One_Count := 0;
               end if;
               if One_Count >= 10 then
                  --  SYNC: byte framing is held in reset
                  Sync := True;
                  Bit_Count := 0;
               else
                  Sync := False;
                  Shift_In := Shift_Left (Shift_In, 1) or Byte (B);
                  Bit_Count := Bit_Count + 1;
                  if Bit_Count = 8 then
                     Bit_Count := 0;
                     Read_Latch := Shift_In;
                     Byte_Ready;
                  end if;
               end if;
            end;
         end if;
         Bit_Pos := (Bit_Pos + 1) mod Total;
      end;
   end Process_Bit;

   procedure Rotate (Half_Us : Natural) is
      Per_Bit : Natural;     --  bit cell length in 1/8 microseconds
   begin
      if not Disk_Present or else not Motor_On then
         Sync := False;
         return;
      end if;
      Per_Bit := 32 - 2 * Natural (Shift_Right (VIA2.ORB, 5) and 3);
      Bit_Clock := Bit_Clock + Half_Us * 4;
      while Bit_Clock >= Per_Bit loop
         Bit_Clock := Bit_Clock - Per_Bit;
         Process_Bit;
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
      if Size (F) = 16384 then
         Byte_Array'Read (Stream (F), ROM_1541);
         Have_1541 := True;
         Ok := True;
      elsif Size (F) = 32768 then
         Byte_Array'Read (Stream (F), ROM_1571);
         Have_1571 := True;
         Ok := True;
      else
         Ok := False;
      end if;
      Close (F);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Load_ROM;

   function ROM_Loaded return Boolean is
     (if Is_1571 then Have_1571 else Have_1541);
   function Has_ROM (M : Drive_Model) return Boolean is
     (if M = D1571 then Have_1571 else Have_1541);
   function Model return Drive_Model is (Current_Model);

   procedure Set_Model (M : Drive_Model) is
   begin
      Current_Model := M;
      Reset;
   end Set_Model;

   procedure Fast_Byte_From_Host (Value : Byte) is
   begin
      if Is_1571 and then not Fast_Out then
         CIA.Set_SDR (Drive_CIA, Value);
      end if;
   end Fast_Byte_From_Host;
   function Peek_RAM (Addr : Natural) return Byte is (RAM (Addr mod 2048));
   function Get_PC return Word is (CPU.PC);

   function Peek (Addr : Word) return Byte is
   begin
      case Addr is
         when 16#0000# .. 16#17FF# => return RAM (Natural (Addr and 16#07FF#));
         when 16#8000# .. 16#FFFF# =>
            return (if Is_1571 then ROM_1571 (Natural (Addr and 16#7FFF#))
                    else ROM_1541 (Natural (Addr and 16#3FFF#)));
         when others => return 16#FF#;
      end case;
   end Peek;

   procedure Poke (Addr : Word; Value : Byte) is
   begin
      if Addr < 16#1800# then
         RAM (Natural (Addr and 16#07FF#)) := Value;
      end if;
   end Poke;

   function Register_Text return String is
      H : constant String := "0123456789ABCDEF";
      function X2 (B : Byte) return String is
        (H (Natural (B / 16) + 1) & H (Natural (B mod 16) + 1));
      P : constant Byte := CPU.Get_P;
      F : String (1 .. 8) := "NV-BDIZC";
   begin
      for I in 0 .. 7 loop
         if (Shift_Right (P, 7 - I) and 1) = 0 and then I /= 2 then
            F (I + 1) := '.';
         end if;
      end loop;
      return (if Is_1571 then "1571" else "1541") & " PC=$" & X2 (Hi (CPU.PC)) & X2 (Lo (CPU.PC)) &
        " A=$" & X2 (CPU.A) & " X=$" & X2 (CPU.X) & " Y=$" & X2 (CPU.Y) &
        " SP=$" & X2 (CPU.SP) & " " & F &
        "  track" & Natural'Image (Half_Track / 2) &
        (if Half_Track mod 2 = 1 then ".5" else "") &
        (if Motor_On then " motor" else "") & (if LED_On then " LED" else "") &
        (if Is_1571 then " side" & Side'Image &
           (if Fast_Clock then " 2MHz" else " 1MHz") else "");
   end Register_Text;

   procedure Reset is
   begin
      RAM := (others => 0);
      VIA.Reset (VIA1);
      VIA.Reset (VIA2);
      CIA.Reset (Drive_CIA);
      WD_Regs := (others => 0);
      WD_Status := 0;
      WD_Busy := 0;
      Fast_Clock := False;
      Fast_Out := False;
      Byte_Level := False;
      if Side /= 0 then
         declare
            Old : constant Natural := Cur;
         begin
            Side := 0;
            Head_Moved (Old);
         end;
      end if;
      Update_Bus_Outputs;
      VIA.Set_CA1 (VIA1, IEC.ATN);
      Drive_Time := 0;
      Bit_Clock := 0;
      Bit_Count := 0;
      One_Count := 0;
      Sync := False;
      Last_Phase := 0;
      Motor_Was_On := False;
      CPU.IRQ_Line := False;
      CPU.Reset;
   end Reset;

   procedure Set_Host_Clock (Hz : Natural) is
   begin
      Host_Clock := Long_Long_Integer (Hz);
   end Set_Host_Clock;

   procedure Set_Time (C64_Cycles : Long_Long_Integer) is
   begin
      Drive_Time := C64_Cycles * 2_000_000 / Host_Clock;
   end Set_Time;

   procedure ATN_Changed is
   begin
      VIA.Set_CA1 (VIA1, IEC.ATN);
   end ATN_Changed;

   procedure Run_Until (C64_Cycles : Long_Long_Integer) is
      --  Drive time is counted in half microseconds (the 1571 can run
      --  its CPU at 2 MHz)
      Target : constant Long_Long_Integer := C64_Cycles * 2_000_000 / Host_Clock;
      N : Natural;
      Unit : Long_Long_Integer;
   begin
      while Drive_Time < Target loop
         Unit := (if Fast_Clock then 1 else 2);
         CPU.IRQ_Line := VIA.IRQ (VIA1) or else VIA.IRQ (VIA2)
           or else (Is_1571 and then Drive_CIA.IRQ);
         --  Do not start an instruction whose bus access (its last cycle)
         --  would happen at or after the target time: the computer has not
         --  reached that moment yet.
         if not (CPU.IRQ_Line and then not CPU.Flag_I) then
            declare
               Need : constant Natural :=
                 CPU.Base_Cycles (Drive_Read (CPU.PC));
            begin
               exit when Drive_Time + (Long_Long_Integer (Need) - 1) * Unit
                 >= Target;
            end;
         end if;
         CPU.Step (N);
         VIA.Tick (VIA1, N);
         VIA.Tick (VIA2, N);
         if Is_1571 then
            CIA.Tick (Drive_CIA, N);
            WD_Tick (Long_Long_Integer (N) * Unit);
         end if;
         Rotate (N * Natural (Unit));
         Drive_Time := Drive_Time + Long_Long_Integer (N) * Unit;
      end loop;
   end Run_Until;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Byte_Array'Write (S, RAM);
      VIA.Chip'Write (S, VIA1);
      VIA.Chip'Write (S, VIA2);
      Long_Long_Integer'Write (S, Drive_Time);
      Byte'Write (S, CPU.A); Byte'Write (S, CPU.X); Byte'Write (S, CPU.Y);
      Byte'Write (S, CPU.SP); Word'Write (S, CPU.PC);
      Byte'Write (S, CPU.Get_P);
      Boolean'Write (S, CPU.IRQ_Line); Boolean'Write (S, CPU.NMI_Pending);
      Boolean'Write (S, CPU.Jammed);
      Natural'Write (S, Half_Track); Natural'Write (S, Bit_Pos);
      Natural'Write (S, Bit_Clock); Natural'Write (S, One_Count);
      Natural'Write (S, Bit_Count); Byte'Write (S, Shift_In);
      Byte'Write (S, Shift_Out); Boolean'Write (S, Sync);
      Byte'Write (S, Read_Latch); Boolean'Write (S, Motor_Was_On);
      Byte'Write (S, Last_Phase);
      Disk_Kind'Write (S, Disk); Natural'Write (S, Disk_Tracks);
      for T of Tracks loop
         Natural'Write (S, T.Len);
         Boolean'Write (S, T.Dirty);
         Natural'Write (S, T.File_Offset);
         if T.Data /= null then
            Byte_Array'Write (S, T.Data.all);
         end if;
      end loop;
      Drive_Model'Write (S, Current_Model);
      Natural'Write (S, Side);
      Boolean'Write (S, Fast_Clock); Boolean'Write (S, Fast_Out);
      Boolean'Write (S, Byte_Level);
      Byte_Array'Write (S, WD_Regs);
      CIA.Chip'Write (S, Drive_CIA);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
      P : Byte;
   begin
      Byte_Array'Read (S, RAM);
      VIA.Chip'Read (S, VIA1);
      VIA.Chip'Read (S, VIA2);
      Long_Long_Integer'Read (S, Drive_Time);
      Byte'Read (S, CPU.A); Byte'Read (S, CPU.X); Byte'Read (S, CPU.Y);
      Byte'Read (S, CPU.SP); Word'Read (S, CPU.PC);
      Byte'Read (S, P);
      CPU.Set_P (P);
      Boolean'Read (S, CPU.IRQ_Line); Boolean'Read (S, CPU.NMI_Pending);
      Boolean'Read (S, CPU.Jammed);
      Natural'Read (S, Half_Track); Natural'Read (S, Bit_Pos);
      Natural'Read (S, Bit_Clock); Natural'Read (S, One_Count);
      Natural'Read (S, Bit_Count); Byte'Read (S, Shift_In);
      Byte'Read (S, Shift_Out); Boolean'Read (S, Sync);
      Byte'Read (S, Read_Latch); Boolean'Read (S, Motor_Was_On);
      Byte'Read (S, Last_Phase);
      Disk_Kind'Read (S, Disk); Natural'Read (S, Disk_Tracks);
      for T of Tracks loop
         Natural'Read (S, T.Len);
         Boolean'Read (S, T.Dirty);
         Natural'Read (S, T.File_Offset);
         T.Data := null;
         if T.Len > 0 then
            T.Data := new Byte_Array (0 .. T.Len - 1);
            Byte_Array'Read (S, T.Data.all);
         end if;
      end loop;
      Drive_Model'Read (S, Current_Model);
      Natural'Read (S, Side);
      Boolean'Read (S, Fast_Clock); Boolean'Read (S, Fast_Out);
      Boolean'Read (S, Byte_Level);
      Byte_Array'Read (S, WD_Regs);
      CIA.Chip'Read (S, Drive_CIA);
      Update_Bus_Outputs;
   end Load_State;

begin
   for N in Byte range 0 .. 15 loop
      GCR_Decode (GCR_Code (N)) := N;
   end loop;
end Drive1541;
