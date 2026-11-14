--  The complete C64 / C128 system: memory map, I/O dispatch, CPU, chips,
--  KERNAL load/save traps and the per-frame run loop.

with Types; use Types;

package Machine is

   type Model_Type is (C64, C128);

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean);
   --  Load the ROM set for the model and perform a hard reset.

   function Model return Model_Type;
   function In_C64_Mode return Boolean;   --  C64, or C128 after GO64
   function Error_Message return String;

   procedure Reset;
   --  Hard reset (RAM pattern re-initialised, chips reset).

   procedure Run_Frame;
   --  Emulate one PAL frame (312 raster lines).

   Key_4080_Down : Boolean := False;   --  C128 40/80 DISPLAY key locked down

   procedure Type_Text (S : String);
   --  Queue text to be fed into the KERNAL keyboard buffer.

   procedure Autostart (Path : String; Ok : out Boolean);
   --  Attach the image/file, reset, and LOAD + RUN the first program.

   function Autostart_Busy return Boolean;

   function Frame_Count return Natural;
   function Peek (Addr : Word) return Byte;     --  CPU view, no side effects
   procedure Poke (Addr : Word; Value : Byte);  --  RAM bank 0
   function Get_PC return Word;
   function Screen_Contains (Text : String) return Boolean;
   --  True when Text (ASCII) is visible on the 40- or 80-column screen.

   function VDC_Enabled return Boolean;
   --  True when the machine has a VDC (C128).

end Machine;
