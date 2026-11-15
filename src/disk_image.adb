with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;

package body Disk_Image is

   Tracks : constant := 35;
   subtype Track_Number is Positive range 1 .. Tracks;
   Dir_Track : constant := 18;

   function Sectors (T : Track_Number) return Positive is
     (case T is
        when 1 .. 17 => 21,
        when 18 .. 24 => 19,
        when 25 .. 30 => 18,
        when others => 17);

   function Offset (T : Track_Number; S : Natural) return Natural is
      O : Natural := 0;
   begin
      for I in 1 .. T - 1 loop
         O := O + Sectors (I) * 256;
      end loop;
      return O + S * 256;
   end Offset;

   Image_Size : constant := 174_848;
   Image : Byte_Array (0 .. Image_Size - 1) := (others => 0);
   Used  : array (Track_Number, 0 .. 20) of Boolean :=
     (others => (others => False));
   Files : Natural := 0;
   Last_Error : Unbounded_String;

   function File_Count return Natural is (Files);
   function Error return String is (To_String (Last_Error));

   function PETSCII (C : Character) return Byte is
     (case C is
        when 'a' .. 'z' => Byte (Character'Pos (C) - 32),
        when others => Byte (Character'Pos (C) mod 128));

   procedure Put_Name (At_Offset : Natural; Name : String; Len : Positive) is
   begin
      for I in 0 .. Len - 1 loop
         Image (At_Offset + I) :=
           (if I < Name'Length then PETSCII (Name (Name'First + I))
            else 16#A0#);
      end loop;
   end Put_Name;

   procedure Allocate (T : Track_Number; S : Natural) is
   begin
      Used (T, S) := True;
   end Allocate;

   function Free_On (T : Track_Number) return Natural is
      N : Natural := 0;
   begin
      for S in 0 .. Sectors (T) - 1 loop
         if not Used (T, S) then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Free_On;

   function Blocks_Free return Natural is
      N : Natural := 0;
   begin
      for T in Track_Number loop
         if T /= Dir_Track then
            N := N + Free_On (T);
         end if;
      end loop;
      return N;
   end Blocks_Free;

   --  BAM at 18/0
   procedure Write_BAM is
      B : constant Natural := Offset (Dir_Track, 0);
   begin
      for T in Track_Number loop
         declare
            E : constant Natural := B + 4 + (T - 1) * 4;
            Bits : Unsigned_32 := 0;
         begin
            for S in 0 .. Sectors (T) - 1 loop
               if not Used (T, S) then
                  Bits := Bits or Shift_Left (1, S);
               end if;
            end loop;
            Image (E) := Byte (Free_On (T));
            Image (E + 1) := Byte (Bits and 255);
            Image (E + 2) := Byte (Shift_Right (Bits, 8) and 255);
            Image (E + 3) := Byte (Shift_Right (Bits, 16) and 255);
         end;
      end loop;
   end Write_BAM;

   procedure Create (Disk_Name : String; Disk_Id : String := "01") is
      B : constant Natural := Offset (Dir_Track, 0);
   begin
      Image := (others => 0);
      Used := (others => (others => False));
      Files := 0;
      Allocate (Dir_Track, 0);
      Allocate (Dir_Track, 1);
      Image (B) := Dir_Track;           --  first directory sector
      Image (B + 1) := 1;
      Image (B + 2) := 16#41#;          --  'A' (1541 DOS format)
      Put_Name (B + 16#90#, Disk_Name, 16);
      Image (B + 16#A0#) := 16#A0#;
      Image (B + 16#A1#) := 16#A0#;
      Put_Name (B + 16#A2#, Disk_Id, 2);
      Image (B + 16#A4#) := 16#A0#;
      Image (B + 16#A5#) := Character'Pos ('2');
      Image (B + 16#A6#) := Character'Pos ('A');
      for I in 16#A7# .. 16#AA# loop
         Image (B + I) := 16#A0#;
      end loop;
      --  empty directory sector 18/1: no next sector
      Image (Offset (Dir_Track, 1)) := 0;
      Image (Offset (Dir_Track, 1) + 1) := 16#FF#;
      Write_BAM;
   end Create;

   --  Next free sector for file data, 1541 style
   procedure Next_Free (T : in out Track_Number; S : in out Natural;
                        First : Boolean; Found : out Boolean) is
      Order : constant array (1 .. 34) of Track_Number :=
        (17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1,
         19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35);
      Start_Index : Positive := 1;
   begin
      Found := False;
      if not First then
         for I in Order'Range loop
            if Order (I) = T then
               Start_Index := I;
            end if;
         end loop;
      end if;
      for I in Start_Index .. Order'Last loop
         declare
            TT : constant Track_Number := Order (I);
            N  : constant Positive := Sectors (TT);
            Try : Natural :=
              (if First or else TT /= T then 0 else (S + 10) mod N);
         begin
            for K in 1 .. N loop
               if not Used (TT, Try) then
                  T := TT;
                  S := Try;
                  Found := True;
                  return;
               end if;
               Try := (Try + 1) mod N;
            end loop;
         end;
      end loop;
   end Next_Free;

   --  A free directory slot: (sector offset, entry offset)
   procedure Dir_Slot (Entry_Offset : out Natural; Ok : out Boolean) is
      S : Natural := 1;
   begin
      loop
         declare
            O : constant Natural := Offset (Dir_Track, S);
         begin
            for E in 0 .. 7 loop
               if Image (O + E * 32 + 2) = 0 then
                  Entry_Offset := O + E * 32;
                  Ok := True;
                  return;
               end if;
            end loop;
            if Image (O) = 0 then
               --  chain a new directory sector (interleave 3)
               declare
                  Next : Natural := (S + 3) mod Sectors (Dir_Track);
               begin
                  for K in 1 .. Sectors (Dir_Track) loop
                     exit when not Used (Dir_Track, Next);
                     Next := (Next + 1) mod Sectors (Dir_Track);
                  end loop;
                  if Used (Dir_Track, Next) then
                     Ok := False;
                     Entry_Offset := 0;
                     return;
                  end if;
                  Allocate (Dir_Track, Next);
                  Image (O) := Dir_Track;
                  Image (O + 1) := Byte (Next);
                  Image (Offset (Dir_Track, Next)) := 0;
                  Image (Offset (Dir_Track, Next) + 1) := 16#FF#;
               end;
            end if;
            S := Natural (Image (O + 1));
         end;
      end loop;
   end Dir_Slot;

   procedure Add_File (Name : String; Data : Byte_Array;
                       Kind : File_Type := PRG; Ok : out Boolean) is
      Blocks : constant Natural := Natural'Max (1, (Data'Length + 253) / 254);
      Dir_Entry : Natural;
      T : Track_Number := 17;
      S : Natural := 0;
      First_T : Track_Number := 17;
      First_S : Natural := 0;
      Found : Boolean;
      Pos : Natural := Data'First;
      Prev_O : Integer := -1;
   begin
      Ok := False;
      if Blocks > Blocks_Free then
         Last_Error := To_Unbounded_String
           ("disk full (" & Name & " needs" & Blocks'Image & " blocks," &
            Blocks_Free'Image & " free)");
         return;
      end if;
      Dir_Slot (Dir_Entry, Found);
      if not Found then
         Last_Error := To_Unbounded_String ("directory full");
         return;
      end if;
      for B in 1 .. Blocks loop
         Next_Free (T, S, B = 1, Found);
         if not Found then
            Last_Error := To_Unbounded_String ("disk full");
            return;
         end if;
         Allocate (T, S);
         if B = 1 then
            First_T := T;
            First_S := S;
         end if;
         declare
            O : constant Natural := Offset (T, S);
            N : constant Natural := Natural'Min (254, Data'Last + 1 - Pos);
         begin
            if Prev_O >= 0 then
               Image (Prev_O) := Byte (T);
               Image (Prev_O + 1) := Byte (S);
            end if;
            Image (O .. O + 255) := (others => 0);
            if N > 0 then
               Image (O + 2 .. O + 1 + N) := Data (Pos .. Pos + N - 1);
            end if;
            Pos := Pos + N;
            --  last sector: track 0, sector = index of the last byte
            Image (O) := 0;
            Image (O + 1) := Byte (N + 1);
            Prev_O := O;
         end;
      end loop;
      Image (Dir_Entry + 2) :=
        (case Kind is when PRG => 16#82#, when SEQ => 16#81#,
                      when USR => 16#83#);
      Image (Dir_Entry + 3) := Byte (First_T);
      Image (Dir_Entry + 4) := Byte (First_S);
      Put_Name (Dir_Entry + 5, Name, 16);
      Image (Dir_Entry + 30) := Byte (Blocks mod 256);
      Image (Dir_Entry + 31) := Byte (Blocks / 256);
      Files := Files + 1;
      Write_BAM;
      Ok := True;
   end Add_File;

   procedure Save (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : Ada.Streams.Stream_IO.File_Type;
   begin
      Create (F, Out_File, Path);
      Byte_Array'Write (Stream (F), Image);
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Save;

begin
   Create ("EMPTY");
end Disk_Image;
