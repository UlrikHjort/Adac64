--  CRT cartridge image files (the VICE/CCS64 format).

with Types; use Types;

package CRT is

   Max_Banks : constant := 128;
   Bank_Size : constant := 16#4000#;    --  ROML (8K) followed by ROMH (8K)

   type Cart_Type is
     (Normal, Ocean, Magic_Desk, Game_System, Dinamic, Easy_Flash,
      Unsupported);

   type Bank_Flags is array (0 .. Max_Banks - 1) of Boolean;

   type Image is record
      Kind       : Cart_Type := Normal;
      Hw_Type    : Natural := 0;        --  number from the CRT header
      Exrom_Low  : Boolean := False;    --  initial line states (True = asserted)
      Game_Low   : Boolean := False;
      Banks      : Natural := 0;
      Has_ROMH   : Bank_Flags := (others => False);
      Name       : String (1 .. 32) := (others => ' ');
   end record;

   procedure Load (Path : String; Info : out Image;
                   Data : out Byte_Array_Access; Ok : out Boolean);
   --  Data receives Banks * Bank_Size bytes: bank n's ROML at n*$4000 and
   --  ROMH at n*$4000 + $2000.  Unused space is $FF.

end CRT;
