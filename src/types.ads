--  Basic types shared by all emulator components.
with Interfaces;

package Types is
   pragma Preelaborate;

   subtype Byte is Interfaces.Unsigned_8;
   subtype Word is Interfaces.Unsigned_16;
   subtype U32  is Interfaces.Unsigned_32;

   use type Interfaces.Unsigned_16;

   type Byte_Array is array (Natural range <>) of Byte;
   type Byte_Array_Access is access all Byte_Array;

   function Lo (W : Word) return Byte is (Byte (W and 16#FF#));
   function Hi (W : Word) return Byte is (Byte (Interfaces.Shift_Right (W, 8)));
   function Make_Word (L, H : Byte) return Word is
     (Word (L) or Interfaces.Shift_Left (Word (H), 8));

   --  Pixel framebuffers hold 0x00RRGGBB values (Cairo RGB24 layout).
   subtype Pixel is U32;
end Types;
