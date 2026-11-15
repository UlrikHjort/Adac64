-- ***************************************************************************
--                      AdaC64 - CRT
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

with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;

package body CRT is

   function Be16 (D : Byte_Array; I : Natural) return Natural is
     (Natural (D (I)) * 256 + Natural (D (I + 1)));
   function Be32 (D : Byte_Array; I : Natural) return Natural is
     (Be16 (D, I) * 65536 + Be16 (D, I + 2));

   procedure Load (Path : String; Info : out Image;
                   Data : out Byte_Array_Access; Ok : out Boolean)
   is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Raw : Byte_Array_Access;
      Signature : constant String := "C64 CARTRIDGE   ";
   begin
      Ok := False;
      Info := (others => <>);
      Data := null;
      Open (F, In_File, Path);
      Raw := new Byte_Array (0 .. Natural (Size (F)) - 1);
      Byte_Array'Read (Stream (F), Raw.all);
      Close (F);

      if Raw'Length < 64 then
         return;
      end if;
      for I in Signature'Range loop
         if Raw (I - 1) /= Character'Pos (Signature (I)) then
            return;
         end if;
      end loop;

      Info.Hw_Type := Be16 (Raw.all, 16#16#);
      Info.Exrom_Low := Raw (16#18#) = 0;
      Info.Game_Low := Raw (16#19#) = 0;
      for I in 1 .. 32 loop
         declare
            B : constant Byte := Raw (16#1F# + I);
         begin
            Info.Name (I) := (if B in 16#20# .. 16#7E#
                              then Character'Val (B) else ' ');
         end;
      end loop;
      Info.Kind :=
        (case Info.Hw_Type is
           when 0 => Normal,
           when 5 => Ocean,
           when 15 => Game_System,
           when 17 => Dinamic,
           when 19 => Magic_Desk,
           when 32 => Easy_Flash,
           when others => Unsupported);

      Data := new Byte_Array'(0 .. Max_Banks * Bank_Size - 1 => 16#FF#);

      declare
         P : Natural := Be32 (Raw.all, 16#10#);
      begin
         while P + 16 <= Raw'Length
           and then Raw (P) = Character'Pos ('C')
           and then Raw (P + 1) = Character'Pos ('H')
         loop
            declare
               Packet : constant Natural := Be32 (Raw.all, P + 4);
               Bank   : constant Natural := Be16 (Raw.all, P + 10);
               Load_A : constant Natural := Be16 (Raw.all, P + 12);
               Length : constant Natural := Be16 (Raw.all, P + 14);
               Src    : constant Natural := P + 16;
               Dst    : Natural;
            begin
               exit when Packet < 16 or else Bank >= Max_Banks;
               Dst := Bank * Bank_Size +
                 (if Load_A >= 16#A000# then 16#2000# else 0);
               if Load_A >= 16#A000# then
                  Info.Has_ROMH (Bank) := True;
               elsif Length > 16#2000# then
                  Info.Has_ROMH (Bank) := True;   --  16K chip at $8000
               end if;
               for I in 0 .. Natural'Min (Length, Bank_Size) - 1 loop
                  exit when Src + I > Raw'Last;
                  Data (Dst + I) := Raw (Src + I);
               end loop;
               Info.Banks := Natural'Max (Info.Banks, Bank + 1);
               P := P + Packet;
            end;
         end loop;
      end;
      Ok := Info.Banks > 0;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Load;

end CRT;
