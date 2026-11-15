--  Character sets for the forge's charset editor: 256 characters of
--  8 x 8 pixels (multicolour: 4 x 8 double-wide pixels).
--
--  .chr files are the raw bytes (8 per character, up to 2048); a 2-byte
--  load address (PRG) is skipped when loading.  The colours are not part
--  of a charset (they come from colour RAM and $D021-$D023).

with Types; use Types;

package Charset_Data is

   subtype Char_Code is Natural range 0 .. 255;
   subtype Row_Range is Natural range 0 .. 7;
   type Glyph is array (Row_Range) of Byte;

   type Pen is (Background, Char_Color, Multi_1, Multi_2);
   --  Multicolour bit pairs: 00 background ($D021), 01 $D022, 10 $D023,
   --  11 the character's colour (colour RAM, 8..15 selects multicolour)

   Multicolour : Boolean := False;
   Background_Color : Byte := 6;
   Multi_Color_1 : Byte := 11;     --  $D022
   Multi_Color_2 : Byte := 12;     --  $D023
   Text_Color : Byte := 14;        --  colour used to show the characters

   function Get (C : Char_Code) return Glyph;
   procedure Put (C : Char_Code; G : Glyph);
   function Count return Natural;      --  characters in the file (<= 256)

   function Pixel (G : Glyph; X, Y : Row_Range) return Pen;
   procedure Set_Pixel (G : in out Glyph; X, Y : Row_Range; P : Pen);
   procedure Invert (G : in out Glyph);
   procedure Mirror_X (G : in out Glyph);
   procedure Mirror_Y (G : in out Glyph);
   procedure Shift (G : in out Glyph; DX, DY : Integer);   --  wraps
   procedure Rotate (G : in out Glyph);                    --  90 degrees
   procedure Flood_Fill (G : in out Glyph; X, Y : Row_Range; P : Pen);

   procedure Load_ROM (Lower_Case : Boolean);   --  the C64 character ROM
   procedure Clear_All;
   procedure Load (Path : String; Ok : out Boolean);
   procedure Save (Path : String; Ok : out Boolean; Chars : Positive := 256);
   procedure Export_Source (Path, Label : String; Ok : out Boolean;
                            Chars : Positive := 256);

   type Reader is access function (Addr : Word) return Byte;
   procedure Load_Memory (Read : not null Reader; Addr : Word);
   --  All 256 characters from 2048 bytes at Addr

end Charset_Data;
