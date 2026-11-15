-- ***************************************************************************
--                      AdaC64 - IEEE_Drive
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

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Media;
with Interfaces; use Interfaces;

package body IEEE_Drive is

   Dev_DAV, Dev_NRFD, Dev_NDAC, Dev_EOI : Boolean := False;
   Dev_Raw : Byte := 16#FF#;

   function DAV return Boolean is (CPU_DAV or else Dev_DAV);
   function NRFD return Boolean is (CPU_NRFD or else Dev_NRFD);
   function NDAC return Boolean is (CPU_NDAC or else Dev_NDAC);
   function EOI return Boolean is (CPU_EOI or else Dev_EOI);
   function Data return Byte is (CPU_Data and Dev_Raw);

   type Name_Mode is (None, Opening, Writing);

   Listening, Talking : Boolean := False;
   Was_ATN   : Boolean := False;
   Accepted  : Boolean := False;     --  the byte on the bus was taken
   Seen      : Boolean := False;
   --  talking: the listener pulled NRFD after DAV (it is reading the byte);
   --  only then does releasing NDAC mean the byte was taken. (The PET
   --  releases NRFD and NDAC when it starts an ATN sequence, which would
   --  otherwise look like a byte being taken.)
   Channel   : Natural := 0;
   Mode      : Name_Mode := None;
   Name      : Unbounded_String;     --  being received (OPEN)
   Save_Name : Unbounded_String;
   Save_Buf  : Unbounded_String;     --  bytes as characters
   Saving    : Boolean := False;

   Send : Byte_Array_Access := null;
   Send_Pos : Natural := 0;

   procedure Free is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

   procedure Reset is
   begin
      Dev_DAV := False;
      Dev_NRFD := False;
      Dev_NDAC := False;
      Dev_EOI := False;
      Dev_Raw := 16#FF#;
      Listening := False;
      Talking := False;
      Was_ATN := False;
      Accepted := False;
      Seen := False;
      Mode := None;
      Saving := False;
      if Send /= null then
         Free (Send);
      end if;
   end Reset;

   function To_Bytes (S : Unbounded_String) return Byte_Array is
      R : Byte_Array (0 .. Length (S) - 1);
   begin
      for I in R'Range loop
         R (I) := Character'Pos (Element (S, I + 1));
      end loop;
      return R;
   end To_Bytes;

   --  The name of an OPEN is complete (on UNLISTEN)
   procedure Opened is
      Found : Boolean;
      N : constant Byte_Array := To_Bytes (Name);
      First : Natural := N'First;
   begin
      --  "0:NAME" / "@0:NAME": the drive number goes
      for I in N'Range loop
         if N (I) = Character'Pos (':') then
            First := I + 1;
            exit;
         end if;
      end loop;
      if Channel = 1 then                       --  SAVE
         Save_Name := To_Unbounded_String ("");
         for I in First .. N'Last loop
            Append (Save_Name, Character'Val (N (I)));
         end loop;
         Save_Buf := Null_Unbounded_String;
         Saving := True;
      elsif Channel /= 15 then                  --  LOAD (and data files)
         if Send /= null then
            Free (Send);
         end if;
         Media.Find_File (N, Send, Found);
         if not Found and then Send /= null then
            Free (Send);
         end if;
         Send_Pos := 0;
      end if;
   end Opened;

   procedure Command (B : Byte) is
      Dev : constant Natural := Natural (B and 16#1F#);
   begin
      case B and 16#F0# is
         when 16#20# | 16#30# =>
            if B = 16#3F# then                         --  UNLISTEN
               if Listening and then Mode = Opening then
                  Opened;
               end if;
               Mode := None;
               Listening := False;
            else
               Listening := Dev = Device;
               if Listening then
                  Talking := False;
               end if;
            end if;
         when 16#40# | 16#50# =>
            if B = 16#5F# then                         --  UNTALK
               Talking := False;
            else
               Talking := Dev = Device;
               if Talking then
                  Listening := False;
               end if;
            end if;
         when 16#60# | 16#70# =>                       --  SECOND
            if Listening or else Talking then
               Channel := Natural (B and 15);
               Mode := (if Listening and then Channel = 1 and then Saving
                        then Writing else None);
            end if;
         when 16#E0# =>                                --  CLOSE
            if Listening and then Natural (B and 15) = 1 and then Saving then
               declare
                  Ok : Boolean;
               begin
                  Media.Save_File (To_Bytes (Save_Name),
                                   To_Bytes (Save_Buf), Ok);
               end;
               Saving := False;
            end if;
         when 16#F0# =>                                --  OPEN
            if Listening then
               Channel := Natural (B and 15);
               Mode := Opening;
               Name := Null_Unbounded_String;
            end if;
         when others =>
            null;
      end case;
   end Command;

   procedure Received (B : Byte) is
   begin
      case Mode is
         when Opening => Append (Name, Character'Val (B));
         when Writing => Append (Save_Buf, Character'Val (B));
         when None => null;
      end case;
   end Received;

   procedure Update is
   begin
      if CPU_ATN then
         --  every device listens under ATN
         Dev_DAV := False;
         Dev_EOI := False;
         Dev_Raw := 16#FF#;
         Seen := False;
         if not Was_ATN then
            Was_ATN := True;
            Accepted := False;
            Dev_NDAC := True;
            Dev_NRFD := False;
         end if;
      elsif Was_ATN then
         Was_ATN := False;
         Accepted := False;
         Dev_NDAC := Listening;
         Dev_NRFD := False;
      end if;

      if CPU_ATN or else Listening then
         if CPU_DAV and then not Accepted then
            declare
               B : constant Byte := not CPU_Data;
            begin
               Accepted := True;
               Dev_NRFD := True;
               Dev_NDAC := False;               --  taken
               if CPU_ATN then
                  Command (B);
               else
                  Received (B);
               end if;
            end;
         elsif not CPU_DAV and then Accepted then
            Accepted := False;
            Dev_NDAC := True;
            Dev_NRFD := False;                  --  ready for the next
         end if;
         if not CPU_ATN and then not Listening then
            Dev_NDAC := False;
            Dev_NRFD := False;
         end if;
      elsif Talking and then Send /= null then
         Dev_NDAC := False;
         Dev_NRFD := False;
         if Dev_DAV then
            if CPU_NRFD then
               Seen := True;
            end if;
            if Seen and then not CPU_NDAC then  --  the listener took it
               Seen := False;
               Dev_DAV := False;
               Dev_EOI := False;
               Dev_Raw := 16#FF#;
               Send_Pos := Send_Pos + 1;
            elsif not CPU_NDAC then
               --  NDAC released without NRFD: the computer is starting
               --  an ATN sequence (it waits for DAV to go). A real drive
               --  is too slow to have offered the byte by then: withdraw
               --  it, it is sent again later.
               Dev_DAV := False;
               Dev_EOI := False;
               Dev_Raw := 16#FF#;
            end if;
         elsif Send_Pos <= Send'Last and then not CPU_NRFD
           and then CPU_NDAC
         then
            Dev_Raw := not Send (Send_Pos);
            Dev_EOI := Send_Pos = Send'Last;
            Dev_DAV := True;
         end if;
      else
         Dev_NDAC := False;
         Dev_NRFD := False;
         Dev_DAV := False;
         Dev_EOI := False;
         Dev_Raw := 16#FF#;
      end if;
   end Update;

end IEEE_Drive;
