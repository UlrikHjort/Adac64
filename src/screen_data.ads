--  Text screens for Forge's screen editor: 40 x 25 screen codes with a
--  colour per cell, plus border and background colour.  The characters
--  are drawn with Charset_Data (shared with the charset editor).
--
--  .scr files: 1000 screen codes, 1000 colours, border, background
--  (2002 bytes).  Loading also accepts 1000 (codes only) or 2000 bytes,
--  with or without a 2-byte load address.

with Types; use Types;

package Screen_Data is

   Columns : constant := 40;
   Rows    : constant := 25;
   subtype Col_Range is Natural range 0 .. Columns - 1;
   subtype Row_Range is Natural range 0 .. Rows - 1;

   type Cell is record
      Code  : Byte := 32;      --  screen code (32 = space)
      Color : Byte := 14;
   end record;
   type Screen is array (Row_Range, Col_Range) of Cell;

   Current : Screen;
   Border_Color : Byte := 14;
   Background_Color : Byte := 6;

   procedure Clear (Code : Byte := 32; Color : Byte := 14);
   procedure Flood_Fill (X : Col_Range; Y : Row_Range; New_Cell : Cell);
   --  Fill the 4-connected area of cells equal to the one at X, Y

   function Screen_Code (C : Character; Reverse_Video : Boolean := False)
                         return Byte;
   --  ASCII to screen code: a-z -> letters, A-Z -> shifted letters

   procedure Load (Path : String; Ok : out Boolean);
   procedure Save (Path : String; Ok : out Boolean);
   procedure Export_Source (Path, Label : String; Ok : out Boolean);

   type Reader is access function (Addr : Word) return Byte;
   procedure Load_Memory (Codes : not null Reader; Code_Addr : Word;
                          Colors : not null Reader; Color_Addr : Word);

end Screen_Data;
