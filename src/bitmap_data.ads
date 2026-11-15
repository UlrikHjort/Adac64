--  Bitmap pictures for Forge's bitmap editor, kept in the C64's own
--  format, so the VIC-II's colour limits always hold:
--    hires        320 x 200, per 8 x 8 cell two colours (screen RAM
--                 high nibble = 1 bits, low nibble = 0 bits)
--    multicolour  160 x 200 (double-wide pixels), per 4 x 8 cell the
--                 background ($D021, 00) and three colours: screen RAM
--                 high nibble (01), low nibble (10), colour RAM (11)
--
--  Files: Koala Painter (.kla/.koa, multicolour, 10003 bytes), Art Studio
--  (.art, hires, 9009 bytes) and Doodle (.dd, hires, 9218 bytes).

with Types; use Types;

package Bitmap_Data is

   type Mode_Kind is (Hires, Multicolour);
   Mode : Mode_Kind := Multicolour;

   Bitmap : Byte_Array (0 .. 7999) := (others => 0);
   Screen : Byte_Array (0 .. 999) := (others => 16#10#);
   Colors : Byte_Array (0 .. 999) := (others => 1);
   Background : Byte := 0;
   Border : Byte := 0;

   function Width return Positive is (if Mode = Hires then 320 else 160);
   --  in pixels of the current mode (multicolour pixels are 2 wide)
   Height : constant := 200;

   function Pixel (X, Y : Natural) return Byte;    --  colour 0 .. 15
   procedure Set_Pixel (X, Y : Natural; C : Byte; Clash : out Boolean);
   --  Clash: the cell had no room for C, so one of its colours (the one
   --  used least) was replaced, recolouring those pixels.
   procedure Flood_Fill (X, Y : Natural; C : Byte; Clash : out Boolean);
   procedure Clear (Back : Byte := 0; Ink : Byte := 1);

   function Cell_Colors (CX, CY : Natural) return String;
   --  e.g. "1, 5 (bg 0)" for the status line

   --  Full-resolution colour picture (multicolour pixels doubled)
   type Image is array (0 .. 199, 0 .. 319) of Byte;
   procedure Render (Img : out Image);
   procedure Encode (Img : Image; M : Mode_Kind);
   --  Convert a picture of C64 colours into the given mode, choosing the
   --  best colours per cell (and the background for multicolour)
   function Nearest (R, G, B : Natural) return Byte;  --  closest C64 colour

   procedure Load (Path : String; Ok : out Boolean; Message : out Natural);
   --  Message: file size, for errors
   procedure Save (Path : String; Ok : out Boolean);
   --  Koala for multicolour, Art Studio for hires
   procedure Export_Viewer (Path, Label : String; Ok : out Boolean);
   --  A complete ACME program that shows the picture (assemble and run)

   type Reader is access function (Addr : Word) return Byte;
   procedure Load_Memory (VIC : not null Reader; Bitmap_At, Screen_At : Word;
                          IO : not null Reader);
   --  From the running machine (colour RAM through IO at $D800)

end Bitmap_Data;
