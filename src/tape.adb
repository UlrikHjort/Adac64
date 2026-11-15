-- ***************************************************************************
--                      AdaC64 - Tape
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
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;
with Types; use Types;

package body Tape is

   Data    : Byte_Array_Access := null;
   Version : Natural := 0;
   Pos     : Natural := 0;          --  index of the next pulse byte
   Left    : Integer := 0;          --  cycles until the current pulse ends
   Pressed : Boolean := False;
   Label   : Unbounded_String;

   procedure Free is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

   Header : constant := 20;

   procedure Attach (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Sig : constant String := "C64-TAPE-RAW";
   begin
      Ok := False;
      Detach;
      Open (F, In_File, Path);
      Data := new Byte_Array (0 .. Natural (Size (F)) - 1);
      Byte_Array'Read (Stream (F), Data.all);
      Close (F);
      if Data'Length < Header then
         Detach;
         return;
      end if;
      for I in Sig'Range loop
         if Data (I - 1) /= Character'Pos (Sig (I)) then
            Detach;
            return;
         end if;
      end loop;
      Version := Natural (Data (12));
      Label := To_Unbounded_String (Ada.Directories.Simple_Name (Path));
      Rewind;
      Pressed := True;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Detach;
   end Attach;

   procedure Detach is
   begin
      if Data /= null then
         Free (Data);
      end if;
      Pressed := False;
      Label := Null_Unbounded_String;
   end Detach;

   function Present return Boolean is (Data /= null);
   function Name return String is (To_String (Label));
   procedure Play is
   begin
      Pressed := Present;
   end Play;
   procedure Stop is
   begin
      Pressed := False;
   end Stop;
   function Playing return Boolean is (Pressed);

   procedure Rewind is
   begin
      Pos := Header;
      Left := 0;
   end Rewind;

   function Counter return Natural is
     (if Data = null or else Data'Length <= Header then 0
      else (Pos - Header) * 100 / (Data'Length - Header));

   --  Length in cycles of the pulse starting at Pos (advances Pos)
   function Next_Pulse return Integer is
      B : Byte;
   begin
      if Pos > Data'Last then
         return -1;                       --  end of tape
      end if;
      B := Data (Pos);
      Pos := Pos + 1;
      if B /= 0 then
         return Integer (B) * 8;
      elsif Version >= 1 and then Pos + 2 <= Data'Last then
         declare
            L : constant Integer := Integer (Data (Pos)) +
              256 * Integer (Data (Pos + 1)) + 65536 * Integer (Data (Pos + 2));
         begin
            Pos := Pos + 3;
            return L;
         end;
      else
         return 256 * 8;                  --  version 0 overflow
      end if;
   end Next_Pulse;

   procedure Tick (Cycles : Natural; Pulse : out Natural) is
   begin
      Pulse := 0;
      if Data = null or else not Pressed or else not Motor then
         return;
      end if;
      Left := Left - Cycles;
      while Left <= 0 loop
         declare
            L : constant Integer := Next_Pulse;
         begin
            if L < 0 then
               Pressed := False;           --  end of tape: STOP
               Left := 0;
               return;
            end if;
            if Left < 0 or else Pos > Header + 1 then
               Pulse := Pulse + 1;
            end if;
            Left := Left + Integer'Max (L, 1);
         end;
      end loop;
   end Tick;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Natural'Write (S, Pos);
      Integer'Write (S, Left);
      Boolean'Write (S, Pressed);
      Boolean'Write (S, Motor);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Natural'Read (S, Pos);
      Integer'Read (S, Left);
      Boolean'Read (S, Pressed);
      Boolean'Read (S, Motor);
      if Data = null then
         Pressed := False;
         Pos := Header;
      elsif Pos > Data'Last + 1 then
         Pos := Header;
      end if;
   end Load_State;

end Tape;
