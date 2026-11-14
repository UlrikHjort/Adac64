--  Commodore RAM Expansion Unit (1700 / 1764 / 1750 and larger) with its
--  8726 DMA controller at $DF00-$DF0A.
--
--  The machine supplies the computer side of the bus (as seen by the CPU,
--  including I/O) and is told how many cycles the CPU must be halted.

with Ada.Streams;
with Types; use Types;

package REU is

   type Size_KB is range 0 .. 16_384;    --  0 = no REU

   procedure Set_Size (KB : Size_KB);    --  128, 256, 512, 1024 .. 16384
   function Size return Size_KB;
   function Present return Boolean;

   procedure Reset;

   function Read (Reg : Natural) return Byte;
   procedure Write (Reg : Natural; Value : Byte);

   procedure FF00_Written;
   --  A write to $FF00 starts a transfer armed with the FF00 trigger.

   function IRQ return Boolean;

   type Bus_Read_Func is access function (Addr : Word) return Byte;
   type Bus_Write_Proc is access procedure (Addr : Word; Value : Byte);
   Bus_Read  : Bus_Read_Func := null;
   Bus_Write : Bus_Write_Proc := null;

   Stall_Cycles : Natural := 0;
   --  Cycles of the last transfer (the CPU is halted during DMA).

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end REU;
