-- ***************************************************************************
--                      AdaC64 - Media
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************

with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Characters.Handling;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;

package body Media is

   Image      : Byte_Array_Access := null;
   Image_Kind : Media_Kind := None;
   Image_Name : Unbounded_String;
   Image_Path : Unbounded_String;
   Writable   : Boolean := True;

   procedure Free is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

   --  Sector view used by the D64 routines: the D64 itself, or the
   --  sectors decoded from a G64's GCR tracks.
   Disk : Byte_Array_Access := null;
   Max_Sectors : constant := 768;
   Good : array (0 .. Max_Sectors - 1) of Boolean := (others => True);
   Unreliable : Boolean := False;    --  last lookup touched a bad sector

   function Sector_Good (Index : Natural) return Boolean is
     (Index > Good'Last or else Good (Index));

   function Last_Lookup_Unreliable return Boolean is (Unreliable);

   GCR_Value : constant array (0 .. 31) of Integer :=
     (16#0A# => 0, 16#0B# => 1, 16#12# => 2, 16#13# => 3, 16#0E# => 4,
      16#0F# => 5, 16#16# => 6, 16#17# => 7, 16#09# => 8, 16#19# => 9,
      16#1A# => 10, 16#1B# => 11, 16#0D# => 12, 16#1D# => 13,
      16#1E# => 14, 16#15# => 15, others => -1);

   procedure Decode_G64 is
      SPT : constant array (1 .. 35) of Natural :=
        (1 .. 17 => 21, 18 .. 24 => 19, 25 .. 30 => 18, 31 .. 35 => 17);
      function LE16 (I : Natural) return Natural is
        (Natural (Image (I)) + 256 * Natural (Image (I + 1)));
      function LE32 (I : Natural) return Natural is
        (LE16 (I) + 65536 * LE16 (I + 2));
      Base : Natural := 0;
   begin
      Disk := new Byte_Array'(0 .. 174_847 => 0);
      Good := (others => False);
      for T in 1 .. 35 loop
         declare
            Off : constant Natural := LE32 (12 + 4 * (2 * T - 2));
         begin
            if Off /= 0 and then Off + 2 <= Image'Last then
               declare
                  Len  : constant Natural := LE16 (Off);
                  Bits : constant Natural := Len * 8;
                  Pending : Integer := -1;
                  Ones : Natural := 0;
                  P : Natural := 0;

                  function Bit (Q : Natural) return Natural is
                     R : constant Natural := Q mod Bits;
                  begin
                     return Natural
                       (Shift_Right (Image (Off + 2 + R / 8), 7 - R mod 8)
                        and 1);
                  end Bit;

                  --  Decode Count bytes starting at bit Q; Ok is False on
                  --  any invalid GCR code.
                  procedure Get (Q : Natural; Dst : out Byte_Array;
                                 Ok : out Boolean) is
                     V : Natural;
                     N1, N2 : Integer;
                  begin
                     Ok := True;
                     for K in Dst'Range loop
                        V := 0;
                        for B in 0 .. 9 loop
                           V := V * 2 + Bit (Q + (K - Dst'First) * 10 + B);
                        end loop;
                        N1 := GCR_Value (V / 32);
                        N2 := GCR_Value (V mod 32);
                        if N1 < 0 or else N2 < 0 then
                           Ok := False;
                           Dst (K) := 0;
                        else
                           Dst (K) := Byte (N1 * 16 + N2);
                        end if;
                     end loop;
                  end Get;
               begin
                  if Len > 0 and then Off + 1 + Len <= Image'Last then
                     while P < Bits + 3000 loop
                        if Bit (P) = 1 then
                           Ones := Ones + 1;
                           P := P + 1;
                        elsif Ones >= 10 then
                           Ones := 0;
                           declare
                              Hdr : Byte_Array (0 .. 7);
                              Blk : Byte_Array (0 .. 259);
                              Ok  : Boolean;
                              Chk : Byte := 0;
                           begin
                              Get (P, Hdr (0 .. 0), Ok);
                              if Ok and then Hdr (0) = 16#08# then
                                 --  The two $0F padding bytes need not be
                                 --  valid GCR in real dumps
                                 Get (P, Hdr (0 .. 5), Ok);
                                 Pending :=
                                   (if Ok and then Natural (Hdr (3)) = T
                                      and then Natural (Hdr (2)) < SPT (T)
                                    then Integer (Hdr (2)) else -1);
                                 P := P + 80;
                              elsif Ok and then Hdr (0) = 16#07#
                                and then Pending >= 0
                              then
                                 --  Only $07, the data and the checksum
                                 --  must decode; the two padding bytes
                                 --  after them often do not.
                                 Get (P, Blk (0 .. 257), Ok);
                                 for K in 1 .. 256 loop
                                    Chk := Chk xor Blk (K);
                                 end loop;
                                 if Ok and then Chk = Blk (257) then
                                    Disk (Base + Pending * 256 ..
                                            Base + Pending * 256 + 255) :=
                                      Blk (1 .. 256);
                                    Good (Base / 256 + Pending) := True;
                                 end if;
                                 Pending := -1;
                                 P := P + 2600;
                              else
                                 P := P + 1;
                              end if;
                           end;
                        else
                           Ones := 0;
                           P := P + 1;
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
         Base := Base + SPT (T) * 256;
      end loop;
   exception
      when others =>
         Disk := null;
   end Decode_G64;


   ---------------------------------------------------------------------
   --  File helpers
   ---------------------------------------------------------------------

   function Read_File (Path : String) return Byte_Array_Access is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Size : Natural;
      Result : Byte_Array_Access;
   begin
      Open (F, In_File, Path);
      Size := Natural (Ada.Streams.Stream_IO.Size (F));
      Result := new Byte_Array (0 .. Size - 1);
      if Size > 0 then
         Byte_Array'Read (Stream (F), Result.all);
      end if;
      Close (F);
      return Result;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         return null;
   end Read_File;

   function Ends_With (S, Suffix : String) return Boolean is
     (S'Length >= Suffix'Length and then
      Ada.Characters.Handling.To_Lower
        (S (S'Last - Suffix'Length + 1 .. S'Last)) = Suffix);

   procedure Attach (Path : String; Ok : out Boolean) is
      Data : constant Byte_Array_Access := Read_File (Path);
   begin
      Ok := False;
      if Data = null then
         return;
      end if;
      Detach;
      Image := Data;
      if Data'Length > 8 and then Data (0) = Character'Pos ('G')
        and then Data (1) = Character'Pos ('C')
        and then Data (2) = Character'Pos ('R')
      then
         Image_Kind := G64;
      elsif Ends_With (Path, ".d71") or else Data'Length in 349_696 | 351_062
      then
         Image_Kind := D71;
      elsif Ends_With (Path, ".d64") or else Data'Length in 174_848 | 175_531
        | 196_608 | 197_376
      then
         Image_Kind := D64;
      elsif Ends_With (Path, ".t64") or else
        (Data'Length > 64 and then Data (0) = Character'Pos ('C')
         and then Data (1) = Character'Pos ('6'))
      then
         Image_Kind := T64;
      else
         Image_Kind := PRG;
      end if;
      Good := (others => True);
      Disk := null;
      if Image_Kind in D64 | D71 then
         Disk := Image;
      elsif Image_Kind = G64 then
         Decode_G64;
      end if;
      Image_Name := To_Unbounded_String (Ada.Directories.Simple_Name (Path));
      Image_Path := To_Unbounded_String (Path);
      --  Probe whether the file may be written back
      declare
         use Ada.Streams.Stream_IO;
         F : File_Type;
      begin
         Open (F, Append_File, Path);
         Close (F);
         Writable := True;
      exception
         when others => Writable := False;
      end;
      Ok := True;
   end Attach;

   procedure Detach is
   begin
      if Image /= null then
         Free (Image);
      end if;
      Image_Kind := None;
      Disk := null;
      Image_Name := Null_Unbounded_String;
   end Detach;

   function Kind return Media_Kind is (Image_Kind);
   function Attached_Name return String is (To_String (Image_Name));
   function Attached_Path return String is (To_String (Image_Path));
   function Image_Data return Byte_Array_Access is (Image);
   function Image_Writable return Boolean is (Writable);

   procedure Save_Image is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      if Image = null or else Image_Kind not in D64 | D71 | G64
        or else not Writable
      then
         return;
      end if;
      Create (F, Out_File, To_String (Image_Path));
      Byte_Array'Write (Stream (F), Image.all);
      Close (F);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Save_Image;

   ---------------------------------------------------------------------
   --  Name matching
   ---------------------------------------------------------------------

   function Strip_Drive (Name : Byte_Array) return Byte_Array is
   begin
      --  Remove "0:" / ":" prefixes and trailing ",P,R" style options
      for I in Name'Range loop
         if Name (I) = Character'Pos (':') then
            return Strip_Drive (Name (I + 1 .. Name'Last));
         end if;
      end loop;
      for I in Name'Range loop
         if Name (I) = Character'Pos (',') then
            return Name (Name'First .. I - 1);
         end if;
      end loop;
      return Name;
   end Strip_Drive;

   function Upper (B : Byte) return Byte is
   begin
      if B in Character'Pos ('a') .. Character'Pos ('z') then
         return B - 32;
      elsif B in 16#C1# .. 16#DA# then   --  shifted PETSCII letters
         return B - 16#80#;
      end if;
      return B;
   end Upper;

   function Matches (Pattern : Byte_Array; Name : Byte_Array) return Boolean
   is
      P : Natural := Pattern'First;
      N : Natural := Name'First;
   begin
      while P <= Pattern'Last loop
         if Pattern (P) = Character'Pos ('*') then
            return True;
         end if;
         if N > Name'Last then
            return False;
         end if;
         if Pattern (P) /= Character'Pos ('?')
           and then Upper (Pattern (P)) /= Upper (Name (N))
         then
            return False;
         end if;
         P := P + 1;
         N := N + 1;
      end loop;
      return N > Name'Last;
   end Matches;

   function Trim_A0 (Name : Byte_Array) return Byte_Array is
   begin
      for I in Name'Range loop
         if Name (I) = 16#A0# then
            return Name (Name'First .. I - 1);
         end if;
      end loop;
      return Name;
   end Trim_A0;

   ---------------------------------------------------------------------
   --  Directory listing builder
   ---------------------------------------------------------------------

   type Listing is record
      Buf  : Byte_Array (0 .. 16#FFFF#);
      Len  : Natural := 0;
   end record;

   procedure Emit (L : in out Listing; B : Byte) is
   begin
      if L.Len <= L.Buf'Last then
         L.Buf (L.Len) := B;
         L.Len := L.Len + 1;
      end if;
   end Emit;

   procedure Emit (L : in out Listing; C : Character) is
   begin
      Emit (L, Byte (Character'Pos (C)));
   end Emit;

   procedure Emit (L : in out Listing; S : String) is
   begin
      for C of S loop
         Emit (L, Character'Pos (C));
      end loop;
   end Emit;

   Line_Start : Natural := 0;

   procedure Begin_Line (L : in out Listing; Number : Natural) is
   begin
      Line_Start := L.Len;
      Emit (L, 1);  --  link placeholder
      Emit (L, 1);
      Emit (L, Byte (Number mod 256));
      Emit (L, Byte ((Number / 256) mod 256));
   end Begin_Line;

   procedure End_Line (L : in out Listing) is
      Next : constant Natural := 16#0401# + (L.Len + 1) - 2;
   begin
      Emit (L, 0);
      L.Buf (Line_Start) := Byte (Next mod 256);
      L.Buf (Line_Start + 1) := Byte (Next / 256);
   end End_Line;

   procedure Start_Listing (L : in out Listing; Disk_Name, Id : Byte_Array) is
   begin
      L.Len := 0;
      Emit (L, 16#01#);
      Emit (L, 16#04#);
      Begin_Line (L, 0);
      Emit (L, 16#12#);   --  reverse on
      Emit (L, '"');
      for I in 0 .. 15 loop
         if I + Disk_Name'First <= Disk_Name'Last then
            declare
               B : constant Byte := Disk_Name (Disk_Name'First + I);
            begin
               Emit (L, (if B = 16#A0# then 16#20# else B));
            end;
         else
            Emit (L, ' ');
         end if;
      end loop;
      Emit (L, '"');
      Emit (L, ' ');
      for B of Id loop
         Emit (L, (if B = 16#A0# then 16#20# else B));
      end loop;
      End_Line (L);
   end Start_Listing;

   procedure Add_Entry (L : in out Listing; Blocks : Natural;
                        Name : Byte_Array; Type_Str : String) is
      Pad : Natural;
   begin
      Begin_Line (L, Blocks);
      Pad := (if Blocks < 10 then 3 elsif Blocks < 100 then 2 else 1);
      Emit (L, String'(1 .. Pad => ' '));
      Emit (L, '"');
      for B of Name loop
         Emit (L, B);
      end loop;
      Emit (L, '"');
      Emit (L, String'(1 .. 17 - Name'Length => ' '));
      Emit (L, Type_Str);
      End_Line (L);
   end Add_Entry;

   function Finish_Listing (L : in out Listing; Free_Blocks : Natural)
     return Byte_Array_Access is
   begin
      Begin_Line (L, Free_Blocks);
      Emit (L, "BLOCKS FREE.");
      Emit (L, String'(1 .. 13 => ' '));
      End_Line (L);
      Emit (L, 0);
      Emit (L, 0);
      return new Byte_Array'(L.Buf (0 .. L.Len - 1));
   end Finish_Listing;

   ---------------------------------------------------------------------
   --  D64
   ---------------------------------------------------------------------

   function Sectors_On (Track : Natural) return Natural is
     (if Track <= 17 then 21
      elsif Track <= 24 then 19
      elsif Track <= 30 then 18
      else 17);

   function Sector_Offset (Track, Sector : Natural) return Integer is
      Off : Natural := 0;
   begin
      if Image_Kind = D71 and then Track in 36 .. 70 then
         declare
            O : constant Integer := Sector_Offset (Track - 35, Sector);
         begin
            return (if O < 0 then -1 else 683 * 256 + O);
         end;
      end if;
      if Track < 1 or else Track > 40 or else Sector >= Sectors_On (Track)
      then
         return -1;
      end if;
      for T in 1 .. Track - 1 loop
         Off := Off + Sectors_On (T);
      end loop;
      Off := (Off + Sector) * 256;
      if Off + 255 > Disk'Last then
         return -1;
      end if;
      return Off;
   end Sector_Offset;

   function Read_Chain (Track, Sector : Natural) return Byte_Array_Access is
      Buf : Byte_Array (0 .. 200_000);
      Len : Natural := 0;
      T : Natural := Track;
      S : Natural := Sector;
      Guard : Natural := 0;
      Off : Integer;
   begin
      loop
         Off := Sector_Offset (T, S);
         exit when Off < 0;
         if not Sector_Good (Off / 256) then
            Unreliable := True;
         end if;
         Guard := Guard + 1;
         exit when Guard > 800;
         declare
            NT : constant Natural := Natural (Disk (Off));
            NS : constant Natural := Natural (Disk (Off + 1));
            Last : constant Natural := (if NT = 0 then NS else 255);
         begin
            if Last >= 2 then
               for I in 2 .. Last loop
                  Buf (Len) := Disk (Off + I);
                  Len := Len + 1;
               end loop;
            end if;
            exit when NT = 0;
            T := NT;
            S := NS;
         end;
      end loop;
      return new Byte_Array'(Buf (0 .. Len - 1));
   end Read_Chain;

   type Dir_Visitor is access procedure
     (File_Type : Byte; Track, Sector : Natural; Name : Byte_Array;
      Blocks : Natural; Stop : in out Boolean);

   procedure Walk_Directory (Visit : Dir_Visitor) is
      T : Natural := 18;
      S : Natural := 1;
      Off : Integer;
      Stop : Boolean := False;
      Guard : Natural := 0;
   begin
      loop
         Off := Sector_Offset (T, S);
         exit when Off < 0;
         if not Sector_Good (Off / 256) then
            Unreliable := True;
         end if;
         Guard := Guard + 1;
         exit when Guard > 40;
         for E in 0 .. 7 loop
            declare
               B : constant Natural := Off + E * 32;
               FT : constant Byte := Disk (B + 2);
            begin
               if FT /= 0 then
                  Visit (FT, Natural (Disk (B + 3)), Natural (Disk (B + 4)),
                         Trim_A0 (Disk (B + 5 .. B + 20)),
                         Natural (Disk (B + 30)) +
                           256 * Natural (Disk (B + 31)), Stop);
                  exit when Stop;
               end if;
            end;
         end loop;
         exit when Stop;
         exit when Disk (Off) = 0;
         T := Natural (Disk (Off));
         S := Natural (Disk (Off + 1));
      end loop;
   end Walk_Directory;

   Type_Names : constant array (Byte range 0 .. 7) of String (1 .. 3) :=
     ("DEL", "SEQ", "PRG", "USR", "REL", "???", "???", "???");

   function D64_Directory return Byte_Array_Access is
      L : Listing;
      BAM : constant Integer := Sector_Offset (18, 0);
      Free_Blocks : Natural := 0;

      procedure Visit (File_Type : Byte; Track, Sector : Natural;
                       Name : Byte_Array; Blocks : Natural;
                       Stop : in out Boolean) is
         pragma Unreferenced (Track, Sector, Stop);
         TS : String := Type_Names (File_Type and 7);
      begin
         if (File_Type and 16#80#) = 0 then
            TS := "*" & TS (1 .. 2);
         end if;
         Add_Entry (L, Blocks, Name, TS);
      end Visit;
   begin
      Start_Listing (L, Disk (BAM + 16#90# .. BAM + 16#9F#),
                     Disk (BAM + 16#A2# .. BAM + 16#A6#));
      Walk_Directory (Visit'Unrestricted_Access);
      for T in 1 .. 35 loop
         if T /= 18 then
            Free_Blocks := Free_Blocks + Natural (Disk (BAM + 4 * T));
         end if;
      end loop;
      if Image_Kind = D71 then
         --  Free counts of side 2 (tracks 36..70) at $DD..$FF of 18/0
         for T in 36 .. 70 loop
            if T /= 53 then
               Free_Blocks := Free_Blocks + Natural (Disk (BAM + 16#DD# + T - 36));
            end if;
         end loop;
      end if;
      return Finish_Listing (L, Free_Blocks);
   end D64_Directory;

   procedure D64_Find (Pattern : Byte_Array; Data : out Byte_Array_Access;
                       Found : out Boolean) is
      Hit_T, Hit_S : Natural := 0;
      Hit : Boolean := False;

      procedure Visit (File_Type : Byte; Track, Sector : Natural;
                       Name : Byte_Array; Blocks : Natural;
                       Stop : in out Boolean) is
         pragma Unreferenced (Blocks);
      begin
         if (File_Type and 7) /= 0 and then Matches (Pattern, Name) then
            Hit_T := Track;
            Hit_S := Sector;
            Hit := True;
            Stop := True;
         end if;
      end Visit;
   begin
      Walk_Directory (Visit'Unrestricted_Access);
      Found := Hit;
      Data := (if Hit then Read_Chain (Hit_T, Hit_S) else null);
   end D64_Find;

   ---------------------------------------------------------------------
   --  T64
   ---------------------------------------------------------------------

   function T64_Entries return Natural is
     --  "Used entries" ($24) is often 0 in real files: fall back to the
     --  maximum entry count ($22).
     (if Image'Length < 64 then 0
      else Natural'Min
        (Natural'Max (Natural (Image (16#24#)) +
                        256 * Natural (Image (16#25#)),
                      Natural (Image (16#22#)) +
                        256 * Natural (Image (16#23#))),
         (Image'Length - 64) / 32));

   procedure T64_Entry (I : Natural; Start_Addr, End_Addr : out Natural;
                        Offset : out Natural; Used : out Boolean) is
      B : constant Natural := 64 + I * 32;
   begin
      Used := Image (B) /= 0;
      Start_Addr := Natural (Image (B + 2)) + 256 * Natural (Image (B + 3));
      End_Addr := Natural (Image (B + 4)) + 256 * Natural (Image (B + 5));
      Offset := Natural (Image (B + 8)) + 256 * Natural (Image (B + 9)) +
        65536 * Natural (Image (B + 10));
   end T64_Entry;

   function T64_Name (I : Natural) return Byte_Array is
      B : constant Natural := 64 + I * 32 + 16;
      Last : Integer := B + 15;
   begin
      while Last >= B and then Image (Last) in 16#20# | 16#A0# | 0 loop
         Last := Last - 1;
      end loop;
      return Image (B .. Last);
   end T64_Name;

   function T64_Load (I : Natural) return Byte_Array_Access is
      S, E, Off : Natural;
      Used : Boolean;
      Len : Natural;
   begin
      T64_Entry (I, S, E, Off, Used);
      if E <= S or else E = 16#FFFF# then
         --  Some T64 files have a broken end address
         E := S + (Image'Length - Off);
      end if;
      Len := Natural'Min (E - S, Image'Length - Off);
      declare
         R : constant Byte_Array_Access := new Byte_Array (0 .. Len + 1);
      begin
         R (0) := Byte (S mod 256);
         R (1) := Byte (S / 256);
         R (2 .. Len + 1) := Image (Off .. Off + Len - 1);
         return R;
      end;
   end T64_Load;

   ---------------------------------------------------------------------
   --  Host directory
   ---------------------------------------------------------------------

   function Dir return String is
     (if Host_Dir = null then "." else Host_Dir.all);

   function To_Petscii (S : String) return Byte_Array is
      R : Byte_Array (0 .. S'Length - 1);
   begin
      for I in S'Range loop
         R (I - S'First) := Character'Pos
           (Ada.Characters.Handling.To_Upper (S (I)));
      end loop;
      return R;
   end To_Petscii;

   function To_Host (Name : Byte_Array) return String is
      R : String (1 .. Name'Length);
      B : Byte;
   begin
      for I in Name'Range loop
         B := Upper (Name (I));
         if B in Character'Pos ('A') .. Character'Pos ('Z') then
            B := B + 32;
         elsif B not in 16#20# .. 16#7E# or else
           B in Character'Pos ('/') | Character'Pos ('\')
         then
            B := Character'Pos ('_');
         end if;
         R (I - Name'First + 1) := Character'Val (B);
      end loop;
      return R;
   end To_Host;

   procedure Host_Find (Pattern : Byte_Array; Data : out Byte_Array_Access;
                        Found : out Boolean) is
      use Ada.Directories;
      Search : Search_Type;
      Item : Directory_Entry_Type;
   begin
      Found := False;
      Data := null;
      Start_Search (Search, Dir, "*", (Ordinary_File => True,
                                        others => False));
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         declare
            N : constant String := Simple_Name (Item);
         begin
            if Ends_With (N, ".prg") and then
              Matches (Pattern, To_Petscii (N (N'First .. N'Last - 4)))
            then
               Data := Read_File (Full_Name (Item));
               Found := Data /= null;
               exit;
            end if;
         end;
      end loop;
      End_Search (Search);
   exception
      when others =>
         Found := False;
   end Host_Find;

   function Host_Directory return Byte_Array_Access is
      use Ada.Directories;
      L : Listing;
      Search : Search_Type;
      Item : Directory_Entry_Type;
   begin
      Start_Listing (L, To_Petscii ("HOST DIRECTORY"), To_Petscii ("AD 2A"));
      begin
         Start_Search (Search, Dir, "*", (Ordinary_File => True,
                                           others => False));
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Item);
            declare
               N : constant String := Simple_Name (Item);
            begin
               if Ends_With (N, ".prg") and then N'Length <= 20 then
                  Add_Entry (L, Natural ((Size (Item) + 253) / 254),
                             To_Petscii (N (N'First .. N'Last - 4)), "PRG");
               end if;
            end;
         end loop;
         End_Search (Search);
      exception
         when others => null;
      end;
      return Finish_Listing (L, 664);
   end Host_Directory;

   ---------------------------------------------------------------------
   --  Public operations
   ---------------------------------------------------------------------

   procedure Find_File
     (Name  : Byte_Array;
      Data  : out Byte_Array_Access;
      Found : out Boolean)
   is
      Pattern : constant Byte_Array := Strip_Drive (Name);
      Is_Dir : constant Boolean :=
        Name'Length >= 1 and then Name (Name'First) = Character'Pos ('$');
   begin
      Found := False;
      Data := null;
      Unreliable := False;
      case Image_Kind is
         when G64 | D71 =>
            if Disk = null then
               null;
            elsif Is_Dir then
               Data := D64_Directory;
               Found := True;
            else
               D64_Find (Pattern, Data, Found);
            end if;
         when None =>
            if Is_Dir then
               Data := Host_Directory;
               Found := True;
            else
               Host_Find (Pattern, Data, Found);
            end if;
         when D64 =>
            if Is_Dir then
               Data := D64_Directory;
               Found := True;
            else
               D64_Find (Pattern, Data, Found);
            end if;
         when T64 =>
            if Is_Dir then
               declare
                  L : Listing;
                  S, E, Off : Natural;
                  Used : Boolean;
               begin
                  Start_Listing (L, Image (16#28# .. 16#3B#),
                                 To_Petscii ("T64  "));
                  for I in 0 .. T64_Entries - 1 loop
                     T64_Entry (I, S, E, Off, Used);
                     if Used then
                        Add_Entry (L, (E - S + 253) / 254, T64_Name (I),
                                   "PRG");
                     end if;
                  end loop;
                  Data := Finish_Listing (L, 0);
                  Found := True;
               end;
            else
               for I in 0 .. T64_Entries - 1 loop
                  declare
                     S, E, Off : Natural;
                     Used : Boolean;
                  begin
                     T64_Entry (I, S, E, Off, Used);
                     if Used and then
                       (Pattern'Length = 0 or else
                        Matches (Pattern, T64_Name (I)))
                     then
                        Data := T64_Load (I);
                        Found := True;
                        exit;
                     end if;
                  end;
               end loop;
            end if;
         when PRG =>
            if Is_Dir then
               declare
                  L : Listing;
                  N : constant String := To_String (Image_Name);
                  Base : constant String :=
                    (if Ends_With (N, ".prg") then N (N'First .. N'Last - 4)
                     else N);
               begin
                  Start_Listing (L, To_Petscii ("PRG FILE"),
                                 To_Petscii ("00 2A"));
                  Add_Entry (L, (Image'Length + 253) / 254,
                             To_Petscii (Base (Base'First ..
                               Base'First + Natural'Min (Base'Length, 16) - 1)),
                             "PRG");
                  Data := Finish_Listing (L, 0);
                  Found := True;
               end;
            else
               Data := new Byte_Array'(Image.all);
               Found := True;
            end if;
      end case;
   end Find_File;

   procedure Save_File (Name : Byte_Array; Data : Byte_Array; Ok : out Boolean)
   is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Clean : constant Byte_Array := Strip_Drive (Name);
      --  Strip "@" (save-with-replace) prefix
      Start : constant Natural :=
        (if Clean'Length > 0 and then Clean (Clean'First) = Character'Pos ('@')
         then Clean'First + 1 else Clean'First);
      Path : constant String :=
        Ada.Directories.Compose (Dir, To_Host (Clean (Start .. Clean'Last)),
                                 "prg");
   begin
      Create (F, Out_File, Path);
      Byte_Array'Write (Stream (F), Data);
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Save_File;

   function Start_Program_Name (For_C128 : Boolean := False) return String is
      Result : Unbounded_String;
      Found  : Boolean := False;

      procedure Visit (File_Type : Byte; Track, Sector : Natural;
                       Name : Byte_Array; Blocks : Natural;
                       Stop : in out Boolean) is
         pragma Unreferenced (Blocks);
         Off : constant Integer := Sector_Offset (Track, Sector);
      begin
         if (File_Type and 7) = 2 and then Off >= 0
           and then Disk (Off + 2) = 16#01#
           and then (if For_C128 then Disk (Off + 3) in 16#1C# | 16#40#
                     else Disk (Off + 3) = 16#08#)
         then
            for B of Name loop
               Append (Result,
                       (if B in 16#20# .. 16#5F# and then B /= 16#22#
                        then Character'Val (B) else '?'));
            end loop;
            Found := True;
            Stop := True;
         end if;
      end Visit;
   begin
      if Image_Kind not in D64 | D71 | G64 or else Disk = null then
         return "";
      end if;
      Walk_Directory (Visit'Unrestricted_Access);
      return (if Found then To_String (Result) else "");
   exception
      when others => return "";
   end Start_Program_Name;

   function Has_Boot_Sector return Boolean is
     (Image_Kind in D64 | D71 | G64 and then Disk /= null
      and then Disk'Length > 3
      and then Disk (0) = Character'Pos ('C')
      and then Disk (1) = Character'Pos ('B')
      and then Disk (2) = Character'Pos ('M'));

   function First_Program_Name return String is
      Result : Unbounded_String;
      Clean  : Boolean := True;

      procedure Visit (File_Type : Byte; Track, Sector : Natural;
                       Name : Byte_Array; Blocks : Natural;
                       Stop : in out Boolean) is
         pragma Unreferenced (Track, Sector, Blocks);
      begin
         if (File_Type and 7) = 2 then
            for B of Name loop
               if B in 16#20# .. 16#5F# and then B /= 16#22# then
                  Append (Result, Character'Val (B));
               else
                  Clean := False;
               end if;
            end loop;
            Stop := True;
         end if;
      end Visit;
   begin
      if Image_Kind not in D64 | D71 | G64 or else Disk = null then
         return "*";
      end if;
      Walk_Directory (Visit'Unrestricted_Access);
      return (if Clean and then Length (Result) > 0 then To_String (Result)
              else "*");
   exception
      when others => return "*";
   end First_Program_Name;

   function First_Load_Address return Word is
      Data : Byte_Array_Access;
      Found : Boolean;
      Star : constant Byte_Array (0 .. 0) := (0 => Character'Pos ('*'));
   begin
      if Image_Kind = None then
         return 0;
      end if;
      Find_File (Star, Data, Found);
      if Found and then Data /= null and then Data'Length >= 2 then
         return R : constant Word := Make_Word (Data (0), Data (1)) do
            Free (Data);
         end return;
      end if;
      return 0;
   end First_Load_Address;

end Media;
