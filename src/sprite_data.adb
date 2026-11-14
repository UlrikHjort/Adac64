with Ada.Containers.Vectors;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings;
with Interfaces; use Interfaces;

package body Sprite_Data is

   package Sprite_Vectors is new Ada.Containers.Vectors (Positive, Sprite);
   Set : Sprite_Vectors.Vector;

   ---------------------------------------------------------------------
   --  Pixels
   ---------------------------------------------------------------------

   function Pixel (S : Sprite; X : X_Range; Y : Y_Range) return Pen is
      B : constant Byte := S.Data (Y * 3 + X / 8);
   begin
      if S.Multi then
         case Shift_Right (B, 6 - 2 * ((X / 2) mod 4)) and 3 is
            when 0 => return Background;
            when 1 => return Multi_1;
            when 2 => return Sprite_Color;
            when others => return Multi_2;
         end case;
      end if;
      return (if (Shift_Right (B, 7 - X mod 8) and 1) /= 0
              then Sprite_Color else Background);
   end Pixel;

   procedure Set_Pixel (S : in out Sprite; X : X_Range; Y : Y_Range;
                        P : Pen) is
      I : constant Natural := Y * 3 + X / 8;
   begin
      if S.Multi then
         declare
            Sh : constant Natural := 6 - 2 * ((X / 2) mod 4);
            V  : constant Byte :=
              (case P is
                 when Background => 0, when Multi_1 => 1,
                 when Sprite_Color => 2, when Multi_2 => 3);
         begin
            S.Data (I) := (S.Data (I) and not Shift_Left (3, Sh))
              or Shift_Left (V, Sh);
         end;
      else
         declare
            M : constant Byte := Shift_Left (1, 7 - X mod 8);
         begin
            if P = Background then
               S.Data (I) := S.Data (I) and not M;
            else
               S.Data (I) := S.Data (I) or M;
            end if;
         end;
      end if;
   end Set_Pixel;

   procedure Clear (S : in out Sprite) is
   begin
      S.Data := (others => 0);
   end Clear;

   procedure Invert (S : in out Sprite) is
   begin
      for B of S.Data loop
         B := not B;
      end loop;
   end Invert;

   procedure Mirror_X (S : in out Sprite) is
      T : constant Sprite := S;
      Step : constant Positive := (if S.Multi then 2 else 1);
   begin
      for Y in Y_Range loop
         for X in 0 .. Width / Step - 1 loop
            Set_Pixel (S, X * Step, Y,
                       Pixel (T, (Width / Step - 1 - X) * Step, Y));
         end loop;
      end loop;
   end Mirror_X;

   procedure Mirror_Y (S : in out Sprite) is
      T : constant Sprite := S;
   begin
      for Y in Y_Range loop
         S.Data (Y * 3 .. Y * 3 + 2) :=
           T.Data ((Height - 1 - Y) * 3 .. (Height - 1 - Y) * 3 + 2);
      end loop;
   end Mirror_Y;

   procedure Shift (S : in out Sprite; DX, DY : Integer) is
      T : constant Sprite := S;
      Step : constant Positive := (if S.Multi then 2 else 1);
      Cols : constant Positive := Width / Step;
   begin
      for Y in Y_Range loop
         for X in 0 .. Cols - 1 loop
            Set_Pixel (S, X * Step, Y,
                       Pixel (T, ((X - DX) mod Cols) * Step,
                              (Y - DY) mod Height));
         end loop;
      end loop;
   end Shift;

   procedure Flood_Fill (S : in out Sprite; X : X_Range; Y : Y_Range;
                         P : Pen) is
      Step : constant Positive := (if S.Multi then 2 else 1);
      Target : constant Pen := Pixel (S, X, Y);
      procedure Fill (FX, FY : Integer) is
      begin
         if FX < 0 or else FX >= Width or else FY < 0 or else FY >= Height
           or else Pixel (S, FX, FY) /= Target
         then
            return;
         end if;
         Set_Pixel (S, FX, FY, P);
         Fill (FX - Step, FY);
         Fill (FX + Step, FY);
         Fill (FX, FY - 1);
         Fill (FX, FY + 1);
      end Fill;
   begin
      if Target /= P then
         Fill (X - X mod Step, Y);
      end if;
   end Flood_Fill;

   ---------------------------------------------------------------------
   --  The set
   ---------------------------------------------------------------------

   function Count return Natural is (Natural (Set.Length));
   function Get (I : Positive) return Sprite is (Set (I));

   procedure Put (I : Positive; S : Sprite) is
   begin
      Set.Replace_Element (I, S);
   end Put;

   procedure Insert (Before : Positive; S : Sprite) is
   begin
      if Count < Max_Sprites then
         Set.Insert (Before, S);
      end if;
   end Insert;

   procedure Delete (I : Positive) is
   begin
      Set.Delete (I);
      if Count = 0 then
         Set.Append ((others => <>));
      end if;
   end Delete;

   procedure Reset_Set is
   begin
      Set.Clear;
      Set.Append ((others => <>));
   end Reset_Set;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   procedure Load (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      declare
         Len : constant Natural := Natural (Size (F));
         Buf : Byte_Array (0 .. Len - 1);
         Skip : constant Natural := (if Len mod 64 = 2 then 2 else 0);
         N : constant Natural := (Len - Skip + 63) / 64;
      begin
         Byte_Array'Read (Stream (F), Buf);
         Close (F);
         Set.Clear;
         for I in 0 .. Natural'Min (N, Max_Sprites) - 1 loop
            declare
               S : Sprite;
               Base : constant Natural := Skip + I * 64;
            begin
               for J in 0 .. 62 loop
                  S.Data (J) := (if Base + J < Len then Buf (Base + J) else 0);
               end loop;
               if Base + 63 < Len then
                  S.Color := Buf (Base + 63) and 15;
                  S.Multi := (Buf (Base + 63) and 16#80#) /= 0;
               end if;
               Set.Append (S);
            end;
         end loop;
         if Set.Is_Empty then
            Set.Append ((others => <>));
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
      for S of Set loop
         Byte_Array'Write (Stream (F), S.Data);
         Byte'Write (Stream (F), (S.Color and 15) or
                       (if S.Multi then 16#80# else 0));
      end loop;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Save;

   Hex_Digits : constant String := "0123456789abcdef";

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   procedure Export_Source (Path : String; Label : String; Ok : out Boolean)
   is
      use Ada.Text_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Path);
      Put_Line (F, ";" & Count'Image & " sprites exported by AdaC64 studio" &
                  " (64 bytes each; keep them 64-byte aligned)");
      Put_Line (F, "; background" & Background_Color'Image &
                  ", multicolour 1 ($d025)" & Multi_Color_1'Image &
                  ", multicolour 2 ($d026)" & Multi_Color_2'Image);
      Put_Line (F, "; multicolour rows: .. background  .# multicolour 1  " &
                  "#. sprite colour  ## multicolour 2");
      Put_Line (F, "        !align 63, 0");
      Put_Line (F, Label);
      for I in 1 .. Count loop
         declare
            S : constant Sprite := Set (I);
         begin
            Put_Line (F, Label & "_" & Img (I - 1) & "   ; colour" &
                        S.Color'Image & (if S.Multi then ", multicolour"
                                         else ", hires"));
            for Y in Y_Range loop
               Put (F, "        !byte ");
               for C in 0 .. 2 loop
                  Put (F, "%");
                  for Bit in reverse 0 .. 7 loop
                     Put (F, (if (Shift_Right (S.Data (Y * 3 + C), Bit) and 1)
                              /= 0 then '#' else '.'));
                  end loop;
                  if C < 2 then
                     Put (F, ",");
                  end if;
               end loop;
               New_Line (F);
            end loop;
            Put_Line (F, "        !byte $" &
                        (if S.Multi then "8" else "0") &
                        Hex_Digits (Natural (S.Color and 15) + 1) &
                        "        ; colour / multicolour flag (unused by the VIC)");
         end;
      end loop;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Export_Source;

   function From_Memory (Read : not null Reader; Addr : Word;
                         Color : Byte; Multi : Boolean) return Sprite is
      S : Sprite;
   begin
      for J in 0 .. 62 loop
         S.Data (J) := Read (Addr + Word (J));
      end loop;
      S.Color := Color and 15;
      S.Multi := Multi;
      return S;
   end From_Memory;

begin
   Reset_Set;
end Sprite_Data;
