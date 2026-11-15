-- ***************************************************************************
--                      AdaC64 - Bitmap_Data
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
with Ada.Strings.Fixed;
with Ada.Strings;
with Interfaces; use Interfaces;
with Video;

package body Bitmap_Data is

   ---------------------------------------------------------------------
   --  Pixels
   ---------------------------------------------------------------------

   function Cell_Of (X, Y : Natural) return Natural is
     (if Mode = Hires then (Y / 8) * 40 + X / 8 else (Y / 8) * 40 + X / 4);

   function Byte_Of (X, Y : Natural) return Natural is
     (Cell_Of (X, Y) * 8 + Y mod 8);

   --  Raw value of a pixel: hires 0/1, multicolour 0..3
   function Value (X, Y : Natural) return Natural is
      B : constant Byte := Bitmap (Byte_Of (X, Y));
   begin
      if Mode = Hires then
         return Natural (Shift_Right (B, 7 - X mod 8) and 1);
      end if;
      return Natural (Shift_Right (B, 6 - 2 * (X mod 4)) and 3);
   end Value;

   procedure Set_Value (X, Y : Natural; V : Natural) is
      I : constant Natural := Byte_Of (X, Y);
   begin
      if Mode = Hires then
         declare
            M : constant Byte := Shift_Left (1, 7 - X mod 8);
         begin
            Bitmap (I) := (if V = 1 then Bitmap (I) or M
                           else Bitmap (I) and not M);
         end;
      else
         declare
            Sh : constant Natural := 6 - 2 * (X mod 4);
         begin
            Bitmap (I) := (Bitmap (I) and not Shift_Left (3, Sh))
              or Shift_Left (Byte (V), Sh);
         end;
      end if;
   end Set_Value;

   --  Colour of value V in a cell
   function Slot_Color (Cell, V : Natural) return Byte is
   begin
      if Mode = Hires then
         return (if V = 1 then Shift_Right (Screen (Cell), 4)
                 else Screen (Cell) and 15);
      end if;
      case V is
         when 0 => return Background;
         when 1 => return Shift_Right (Screen (Cell), 4);
         when 2 => return Screen (Cell) and 15;
         when others => return Colors (Cell) and 15;
      end case;
   end Slot_Color;

   procedure Set_Slot (Cell, V : Natural; C : Byte) is
   begin
      if Mode = Hires then
         if V = 1 then
            Screen (Cell) := (Screen (Cell) and 15) or Shift_Left (C, 4);
         else
            Screen (Cell) := (Screen (Cell) and 16#F0#) or C;
         end if;
      else
         case V is
            when 1 => Screen (Cell) := (Screen (Cell) and 15) or Shift_Left (C, 4);
            when 2 => Screen (Cell) := (Screen (Cell) and 16#F0#) or C;
            when 3 => Colors (Cell) := C;
            when others => null;
         end case;
      end if;
   end Set_Slot;

   function Pixel (X, Y : Natural) return Byte is
     (Slot_Color (Cell_Of (X, Y), Value (X, Y)));

   --  How many pixels of the cell use each value
   type Counts is array (0 .. 3) of Natural;
   function Count_Cell (Cell : Natural) return Counts is
      R : Counts := (others => 0);
      CX : constant Natural := Cell mod 40;
      CY : constant Natural := Cell / 40;
      W  : constant Natural := (if Mode = Hires then 8 else 4);
   begin
      for Y in CY * 8 .. CY * 8 + 7 loop
         for X in CX * W .. CX * W + W - 1 loop
            R (Value (X, Y)) := R (Value (X, Y)) + 1;
         end loop;
      end loop;
      return R;
   end Count_Cell;

   procedure Set_Pixel (X, Y : Natural; C : Byte; Clash : out Boolean) is
      Cell : constant Natural := Cell_Of (X, Y);
      N : constant Counts := Count_Cell (Cell);
      Last : constant Natural := (if Mode = Hires then 1 else 3);
      First_Free : constant Natural := (if Mode = Hires then 0 else 1);
   begin
      Clash := False;
      if X >= Width or else Y >= Height then
         return;
      end if;
      --  A value that already has this colour
      if Mode = Multicolour and then C = Background then
         Set_Value (X, Y, 0);
         return;
      end if;
      for V in First_Free .. Last loop
         if Slot_Color (Cell, V) = C then
            Set_Value (X, Y, V);
            return;
         end if;
      end loop;
      --  An unused value (not counting the pixel being replaced)
      declare
         Old : constant Natural := Value (X, Y);
      begin
         for V in First_Free .. Last loop
            if N (V) = 0 or else (N (V) = 1 and then V = Old) then
               Set_Slot (Cell, V, C);
               Set_Value (X, Y, V);
               return;
            end if;
         end loop;
      end;
      --  No room: replace the colour used least
      declare
         Best : Natural := First_Free;
      begin
         for V in First_Free .. Last loop
            if N (V) < N (Best) then
               Best := V;
            end if;
         end loop;
         Set_Slot (Cell, Best, C);
         Set_Value (X, Y, Best);
         Clash := True;
      end;
   end Set_Pixel;

   procedure Flood_Fill (X, Y : Natural; C : Byte; Clash : out Boolean) is
      Target : constant Byte := Pixel (X, Y);
      Any_Clash : Boolean := False;
      --  Explicit stack (a picture is 64000 pixels)
      type Point is record
         X, Y : Natural;
      end record;
      type Stack is array (1 .. 64_000) of Point;
      type Stack_Access is access Stack;
      S : constant Stack_Access := new Stack;
      Top : Natural := 0;
      procedure Push (PX, PY : Integer) is
      begin
         if PX in 0 .. Width - 1 and then PY in 0 .. Height - 1
           and then Top < S'Last
         then
            Top := Top + 1;
            S (Top) := (PX, PY);
         end if;
      end Push;
      Cl : Boolean;
   begin
      Clash := False;
      if Target = C then
         return;
      end if;
      Push (X, Y);
      while Top > 0 loop
         declare
            P : constant Point := S (Top);
         begin
            Top := Top - 1;
            if Pixel (P.X, P.Y) = Target then
               Set_Pixel (P.X, P.Y, C, Cl);
               Any_Clash := Any_Clash or Cl;
               if Pixel (P.X, P.Y) = C then
                  Push (P.X - 1, P.Y);
                  Push (P.X + 1, P.Y);
                  Push (P.X, P.Y - 1);
                  Push (P.X, P.Y + 1);
               end if;
            end if;
         end;
      end loop;
      Clash := Any_Clash;
   end Flood_Fill;

   procedure Clear (Back : Byte := 0; Ink : Byte := 1) is
   begin
      Bitmap := (others => 0);
      Background := Back;
      if Mode = Hires then
         Screen := (others => Shift_Left (Ink, 4) or Back);
      else
         Screen := (others => Shift_Left (Ink, 4) or Ink);
         Colors := (others => Ink);
      end if;
   end Clear;

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   function Cell_Colors (CX, CY : Natural) return String is
      Cell : constant Natural := CY * 40 + CX;
   begin
      if Mode = Hires then
         return Img (Integer (Slot_Color (Cell, 1))) & " on " &
           Img (Integer (Slot_Color (Cell, 0)));
      end if;
      return Img (Integer (Slot_Color (Cell, 1))) & ", " &
        Img (Integer (Slot_Color (Cell, 2))) & ", " &
        Img (Integer (Slot_Color (Cell, 3))) & " (bg " &
        Img (Integer (Background)) & ")";
   end Cell_Colors;

   ---------------------------------------------------------------------
   --  Rendering and colour reduction
   ---------------------------------------------------------------------

   procedure Render (Img : out Image) is
   begin
      for Y in 0 .. 199 loop
         if Mode = Hires then
            for X in 0 .. 319 loop
               Img (Y, X) := Pixel (X, Y);
            end loop;
         else
            for X in 0 .. 159 loop
               Img (Y, 2 * X) := Pixel (X, Y);
               Img (Y, 2 * X + 1) := Img (Y, 2 * X);
            end loop;
         end if;
      end loop;
   end Render;

   function RGB (C : Byte; Shift : Natural) return Integer is
     (Integer (Shift_Right (Video.VIC_Palette (C and 15), Shift) and 255));

   function Distance (A, B : Byte) return Natural is
     ((RGB (A, 16) - RGB (B, 16)) ** 2 + (RGB (A, 8) - RGB (B, 8)) ** 2 +
      (RGB (A, 0) - RGB (B, 0)) ** 2);

   function Nearest (R, G, B : Natural) return Byte is
      Best : Byte := 0;
      Best_D : Natural := Natural'Last;
   begin
      for C in Byte range 0 .. 15 loop
         declare
            D : constant Natural :=
              (RGB (C, 16) - R) ** 2 + (RGB (C, 8) - G) ** 2 +
              (RGB (C, 0) - B) ** 2;
         begin
            if D < Best_D then
               Best_D := D;
               Best := C;
            end if;
         end;
      end loop;
      return Best;
   end Nearest;

   type Histogram is array (Byte range 0 .. 15) of Natural;

   function Top (H : Histogram; Exclude : Byte := 16) return Byte is
      Best : Byte := 16;
   begin
      for C in Byte range 0 .. 15 loop
         if C /= Exclude and then H (C) > 0
           and then (Best = 16 or else H (C) > H (Best))
         then
            Best := C;
         end if;
      end loop;
      return Best;
   end Top;

   procedure Encode (Img : Image; M : Mode_Kind) is
   begin
      Mode := M;
      Bitmap := (others => 0);
      if M = Multicolour then
         --  Background: the most common colour of the picture
         declare
            H : Histogram := (others => 0);
         begin
            for Y in 0 .. 199 loop
               for X in 0 .. 159 loop
                  H (Img (Y, 2 * X)) := H (Img (Y, 2 * X)) + 1;
               end loop;
            end loop;
            Background := Top (H);
         end;
      end if;
      for Cell in 0 .. 999 loop
         declare
            CX : constant Natural := Cell mod 40;
            CY : constant Natural := Cell / 40;
            H : Histogram := (others => 0);
            W : constant Natural := (if M = Hires then 8 else 4);
            Step : constant Natural := (if M = Hires then 1 else 2);
            Pal : array (0 .. 3) of Byte := (others => 16);
            N : Natural;
         begin
            for Y in CY * 8 .. CY * 8 + 7 loop
               for X in CX * W .. CX * W + W - 1 loop
                  H (Img (Y, X * Step)) := H (Img (Y, X * Step)) + 1;
               end loop;
            end loop;
            if M = Hires then
               Pal (0) := Top (H);                      --  0 bits
               H (Pal (0)) := 0;
               Pal (1) := Top (H);
               if Pal (1) = 16 then
                  Pal (1) := Pal (0);
               end if;
               Screen (Cell) := Shift_Left (Pal (1), 4) or Pal (0);
               N := 1;
            else
               Pal (0) := Background;
               H (Background) := 0;
               for V in 1 .. 3 loop
                  Pal (V) := Top (H);
                  if Pal (V) /= 16 then
                     H (Pal (V)) := 0;
                  else
                     Pal (V) := Background;
                  end if;
               end loop;
               Screen (Cell) := Shift_Left (Pal (1), 4) or Pal (2);
               Colors (Cell) := Pal (3);
               N := 3;
            end if;
            for Y in CY * 8 .. CY * 8 + 7 loop
               for X in CX * W .. CX * W + W - 1 loop
                  declare
                     C : constant Byte := Img (Y, X * Step);
                     Best : Natural := 0;
                  begin
                     for V in 0 .. N loop
                        if Distance (C, Pal (V)) < Distance (C, Pal (Best))
                        then
                           Best := V;
                        end if;
                     end loop;
                     Set_Value (X, Y, Best);
                  end;
               end loop;
            end loop;
         end;
      end loop;
   end Encode;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   procedure Load (Path : String; Ok : out Boolean; Message : out Natural) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      Open (F, In_File, Path);
      declare
         Len : constant Natural := Natural (Size (F));
         D : Byte_Array (0 .. Len - 1);
      begin
         Message := Len;
         Byte_Array'Read (Stream (F), D);
         Close (F);
         if Len in 10001 | 10003 | 10006 then
            --  Koala Painter (load address $6000)
            declare
               B : constant Natural := (if Len = 10001 then 0 else 2);
            begin
               Mode := Multicolour;
               Bitmap := D (B .. B + 7999);
               Screen := D (B + 8000 .. B + 8999);
               Colors := D (B + 9000 .. B + 9999);
               for C of Colors loop
                  C := C and 15;
               end loop;
               Background := D (B + 10000) and 15;
               Ok := True;
            end;
         elsif Len in 9002 .. 9009 then
            --  Art Studio (load address $2000)
            Mode := Hires;
            Bitmap := D (2 .. 8001);
            Screen := D (8002 .. 9001);
            Border := (if Len > 9002 then D (9002) and 15 else 0);
            Ok := True;
         elsif Len = 9218 then
            --  Doodle (load address $5C00): screen, then bitmap at $6000
            Mode := Hires;
            Screen := D (2 .. 1001);
            Bitmap := D (1026 .. 9025);
            Ok := True;
         end if;
      end;
   exception
      when others =>
         Ok := False;
         Message := 0;
   end Load;

   procedure Save (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      procedure B (V : Byte) is
      begin
         Byte'Write (Stream (F), V);
      end B;
   begin
      Create (F, Out_File, Path);
      if Mode = Multicolour then
         B (16#00#);
         B (16#60#);
         Byte_Array'Write (Stream (F), Bitmap);
         Byte_Array'Write (Stream (F), Screen);
         Byte_Array'Write (Stream (F), Colors);
         B (Background);
      else
         B (16#00#);
         B (16#20#);
         Byte_Array'Write (Stream (F), Bitmap);
         Byte_Array'Write (Stream (F), Screen);
         B (Border);
         for I in 1 .. 6 loop
            B (0);
         end loop;
      end if;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Save;

   procedure Export_Viewer (Path, Label : String; Ok : out Boolean) is
      use Ada.Text_IO;
      F : File_Type;
      H : constant String := "0123456789abcdef";
      function Hex (V : Byte) return String is
        ("$" & H (Natural (V / 16) + 1) & H (Natural (V mod 16) + 1));
      procedure Table (Name : String; D : Byte_Array) is
      begin
         Put_Line (F, Name);
         for I in D'Range loop
            if (I - D'First) mod 20 = 0 then
               Put (F, "        !byte ");
            end if;
            Put (F, Hex (D (I)));
            if (I - D'First) mod 20 = 19 or else I = D'Last then
               New_Line (F);
            else
               Put (F, ",");
            end if;
         end loop;
      end Table;
      Multi : constant Boolean := Mode = Multicolour;
   begin
      Create (F, Out_File, Path);
      Put_Line (F, "; " & (if Multi then "multicolour" else "hires") &
                  " bitmap exported by AdaC64 Forge - assemble and run it");
      Put_Line (F, "; (bitmap at $2000, screen RAM at $0400)");
      Put_Line (F, "        *= $0801");
      Put_Line (F, "        !basic");
      Put_Line (F, "        sei");
      Put_Line (F, "        lda #$3b        ; bitmap mode, screen on");
      Put_Line (F, "        sta $d011");
      Put_Line (F, "        lda #" & (if Multi then "$18" else "$08") &
                  (if Multi then "        ; multicolour" else
                     "        ; hires"));
      Put_Line (F, "        sta $d016");
      Put_Line (F, "        lda #$18        ; screen $0400, bitmap $2000");
      Put_Line (F, "        sta $d018");
      Put_Line (F, "        lda #" & Hex (Border));
      Put_Line (F, "        sta $d020");
      Put_Line (F, "        lda #" & Hex (Background));
      Put_Line (F, "        sta $d021");
      Put_Line (F, "        ldx #0");
      Put_Line (F, "-");
      Put_Line (F, "        !for i, 0, 3 {");
      Put_Line (F, "        lda " & Label & "_screen + i * 250, x");
      Put_Line (F, "        sta $0400 + i * 250, x");
      if Multi then
         Put_Line (F, "        lda " & Label & "_colors + i * 250, x");
         Put_Line (F, "        sta $d800 + i * 250, x");
      end if;
      Put_Line (F, "        }");
      Put_Line (F, "        inx");
      Put_Line (F, "        cpx #250");
      Put_Line (F, "        bne -");
      Put_Line (F, "        cli");
      Put_Line (F, "        jmp *           ; keep showing it");
      Put_Line (F, "");
      Put_Line (F, "        *= $2000");
      Table (Label & "_bitmap", Bitmap);
      Table (Label & "_screen", Screen);
      if Multi then
         Table (Label & "_colors", Colors);
      end if;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Export_Viewer;

   procedure Load_Memory (VIC : not null Reader; Bitmap_At, Screen_At : Word;
                          IO : not null Reader) is
   begin
      for I in Bitmap'Range loop
         Bitmap (I) := VIC (Bitmap_At + Word (I));
      end loop;
      for I in Screen'Range loop
         Screen (I) := VIC (Screen_At + Word (I));
         Colors (I) := IO (16#D800# + Word (I)) and 15;
      end loop;
      Background := IO (16#D021#) and 15;
      Border := IO (16#D020#) and 15;
      Mode := (if (IO (16#D016#) and 16#10#) /= 0 then Multicolour else Hires);
   end Load_Memory;

   function To_TED return TED_Picture is
      P : TED_Picture;
      Count : array (Byte range 0 .. 15) of Natural := (others => 0);
      Common : Byte := 0;
   begin
      for I in Screen'Range loop
         declare
            C1 : constant Byte := Video.To_TED (Shift_Right (Screen (I), 4));
            C0 : constant Byte := Video.To_TED (Screen (I) and 15);
         begin
            P.Hues (I) := Shift_Left (C1 and 15, 4) or (C0 and 15);
            P.Lums (I) := Shift_Right (C1, 4) or (C0 and 16#70#);
         end;
         Count (Colors (I) and 15) := Count (Colors (I) and 15) + 1;
      end loop;
      for C in Count'Range loop
         if Count (C) > Count (Common) then
            Common := C;
         end if;
      end loop;
      P.BG0 := Video.To_TED (Background);
      P.BG1 := Video.To_TED (Common);
      return P;
   end To_TED;

   procedure From_TED (P : TED_Picture) is
   begin
      for I in Screen'Range loop
         declare
            V : constant Byte := P.Hues (I);
            C : constant Byte := P.Lums (I);
            C1 : constant Byte := Shift_Right (V, 4) or Shift_Left (C and 7, 4);
            C0 : constant Byte := (V and 15) or (C and 16#70#);
         begin
            Screen (I) := Shift_Left (Video.From_TED (C1), 4)
              or Video.From_TED (C0);
            Colors (I) := Video.From_TED (P.BG1);
         end;
      end loop;
      Background := Video.From_TED (P.BG0);
   end From_TED;

end Bitmap_Data;
