--  Sprite sets for the studio's sprite editor: pixel access, editing
--  operations and files.
--
--  .spr files are raw 64-byte blocks (63 bytes of sprite data plus an
--  attribute byte: bits 0-3 colour, bit 7 multicolour), so they can be
--  included directly with !binary.  A 2-byte load address (PRG) is
--  skipped when loading.

with Types; use Types;

package Sprite_Data is

   Width  : constant := 24;
   Height : constant := 21;
   Max_Sprites : constant := 256;

   type Sprite is record
      Data  : Byte_Array (0 .. 62) := (others => 0);
      Color : Byte := 1;
      Multi : Boolean := False;
   end record;

   --  What a pixel shows: background (transparent), the sprite's own
   --  colour, or one of the shared multicolours ($D025 / $D026)
   type Pen is (Background, Sprite_Color, Multi_1, Multi_2);

   subtype X_Range is Natural range 0 .. Width - 1;
   subtype Y_Range is Natural range 0 .. Height - 1;

   function Pixel (S : Sprite; X : X_Range; Y : Y_Range) return Pen;
   procedure Set_Pixel (S : in out Sprite; X : X_Range; Y : Y_Range;
                        P : Pen);
   --  X is always in hires pixels; in multicolour mode a pixel is two
   --  hires pixels wide (X and X xor 1 are the same pixel).

   procedure Clear (S : in out Sprite);
   procedure Invert (S : in out Sprite);
   procedure Mirror_X (S : in out Sprite);
   procedure Mirror_Y (S : in out Sprite);
   procedure Shift (S : in out Sprite; DX, DY : Integer);  --  wraps around
   procedure Flood_Fill (S : in out Sprite; X : X_Range; Y : Y_Range;
                         P : Pen);

   --  The set
   function Count return Natural;
   function Get (I : Positive) return Sprite;
   procedure Put (I : Positive; S : Sprite);
   procedure Insert (Before : Positive; S : Sprite);  --  Before = Count+1 appends
   procedure Delete (I : Positive);
   procedure Reset_Set;                                --  one empty sprite

   Background_Color : Byte := 6;
   Multi_Color_1    : Byte := 11;
   Multi_Color_2    : Byte := 1;

   procedure Load (Path : String; Ok : out Boolean);
   procedure Save (Path : String; Ok : out Boolean);
   procedure Export_Source (Path : String; Label : String; Ok : out Boolean);
   --  ACME source with one "!byte %..." line per row (the picture is
   --  readable in the source)

   type Reader is access function (Addr : Word) return Byte;
   function From_Memory (Read : not null Reader; Addr : Word;
                         Color : Byte; Multi : Boolean) return Sprite;

end Sprite_Data;
