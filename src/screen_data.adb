-- ***************************************************************************
--                      AdaC64 - Screen_Data
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
with Ada.Text_IO;
with Interfaces; use Interfaces;

package body Screen_Data is

   procedure Clear (Code : Byte := 32; Color : Byte := 14) is
   begin
      Current := (others => (others => (Code, Color)));
   end Clear;

   procedure Flood_Fill (X : Col_Range; Y : Row_Range; New_Cell : Cell) is
      Target : constant Cell := Current (Y, X);
      procedure Fill (FX, FY : Integer) is
      begin
         if FX not in Col_Range or else FY not in Row_Range
           or else Current (FY, FX) /= Target
         then
            return;
         end if;
         Current (FY, FX) := New_Cell;
         Fill (FX - 1, FY);
         Fill (FX + 1, FY);
         Fill (FX, FY - 1);
         Fill (FX, FY + 1);
      end Fill;
   begin
      if Target /= New_Cell then
         Fill (X, Y);
      end if;
   end Flood_Fill;

   function Screen_Code (C : Character; Reverse_Video : Boolean := False)
                         return Byte is
      P : constant Natural := Character'Pos (C);
      R : Byte;
   begin
      case C is
         when 'a' .. 'z' => R := Byte (P - 96);
         when 'A' .. 'Z' => R := Byte (P);       --  shifted letters
         when '@' | '[' .. '_' => R := Byte (P - 64);
         when ' ' .. '?' => R := Byte (P);
         when others => R := 32;
      end case;
      return (if Reverse_Video then R or 16#80# else R);
   end Screen_Code;

   procedure Load (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      declare
         Len : constant Natural := Natural (Size (F));
         Buf : Byte_Array (0 .. Len - 1);
         Skip : constant Natural :=
           (if Len in 1002 | 2004 then 2 else 0);   --  2002 = .scr itself
         N : constant Natural := Len - Skip;
      begin
         Byte_Array'Read (Stream (F), Buf);
         Close (F);
         if N < 1000 then
            Ok := False;
            return;
         end if;
         for I in 0 .. 999 loop
            Current (I / 40, I mod 40).Code := Buf (Skip + I);
            Current (I / 40, I mod 40).Color :=
              (if N >= 2000 then Buf (Skip + 1000 + I) and 15 else 14);
         end loop;
         if N >= 2002 then
            Border_Color := Buf (Skip + 2000) and 15;
            Background_Color := Buf (Skip + 2001) and 15;
         end if;
      end;
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Load;

   procedure Save (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Path);
      for Y in Row_Range loop
         for X in Col_Range loop
            Byte'Write (Stream (F), Current (Y, X).Code);
         end loop;
      end loop;
      for Y in Row_Range loop
         for X in Col_Range loop
            Byte'Write (Stream (F), Current (Y, X).Color);
         end loop;
      end loop;
      Byte'Write (Stream (F), Border_Color);
      Byte'Write (Stream (F), Background_Color);
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Save;

   procedure Export_Source (Path, Label : String; Ok : out Boolean) is
      use Ada.Text_IO;
      F : File_Type;
      H : constant String := "0123456789abcdef";
      function Hex (B : Byte) return String is
        ("$" & H (Natural (B / 16) + 1) & H (Natural (B mod 16) + 1));

      procedure Table (Name : String; Colors : Boolean) is
      begin
         Put_Line (F, Name);
         for Y in Row_Range loop
            Put (F, "        !byte ");
            for X in Col_Range loop
               Put (F, Hex (if Colors then Current (Y, X).Color
                            else Current (Y, X).Code));
               if X < Col_Range'Last then
                  Put (F, ",");
               end if;
            end loop;
            New_Line (F);
         end loop;
      end Table;
   begin
      Create (F, Out_File, Path);
      Put_Line (F, "; 40 x 25 screen exported by AdaC64 Forge");
      Put_Line (F, Label & "_border     = " & Hex (Border_Color));
      Put_Line (F, Label & "_background = " & Hex (Background_Color));
      Put_Line (F, ";");
      Put_Line (F, "; to show it (screen at $0400):");
      Put_Line (F, ";         ldx #0");
      Put_Line (F, ";     -   lda " & Label & "_chars,x");
      Put_Line (F, ";         sta $0400,x   ; same for +250, +500, +750");
      Put_Line (F, ";         lda " & Label & "_colors,x");
      Put_Line (F, ";         sta $d800,x");
      Put_Line (F, ";         inx");
      Put_Line (F, ";         cpx #250");
      Put_Line (F, ";         bne -");
      Table (Label & "_chars", False);
      Table (Label & "_colors", True);
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Export_Source;

   procedure Load_Memory (Codes : not null Reader; Code_Addr : Word;
                          Colors : not null Reader; Color_Addr : Word) is
   begin
      for Y in Row_Range loop
         for X in Col_Range loop
            Current (Y, X) :=
              (Codes (Code_Addr + Word (Y * 40 + X)),
               Colors (Color_Addr + Word (Y * 40 + X)) and 15);
         end loop;
      end loop;
   end Load_Memory;

begin
   Clear;
end Screen_Data;
