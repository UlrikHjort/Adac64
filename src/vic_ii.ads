--  MOS 6569 VIC-II (PAL) video chip.
--
--  Pixels are produced 8 per cycle as emulated time advances, using the
--  register values of that moment (sprites are composed per line).  Bad
--  lines and sprite DMA steal cycles from the CPU through Stall_Cycles,
--  which the machine consumes before executing the next instruction.

with Ada.Streams;
with Types; use Types;

generic
   with function Mem_Read (Addr : Word) return Byte;
   --  14-bit address inside the current VIC bank (bank and character ROM
   --  mapping is done by the machine).
   with function Color_Read (Index : Natural) return Byte;
   --  Colour RAM nibble, 0 .. 1023.
package VIC_II is

   Cycles_Per_Line : Natural := 63;     --  PAL 6569; NTSC 6567R8: 65
   Lines_Per_Frame : Natural := 312;    --  PAL; NTSC: 263

   Raster        : Natural := 0;
   Line_Cycle    : Natural := 0;
   IRQ           : Boolean := False;
   Stall_Cycles  : Natural := 0;
   Frame_Done    : Boolean := False;   --  set when raster wraps to 0

   --  C128 extra registers ($D02F keyboard lines, $D030 clock)
   Key_Lines     : Byte := 16#FF#;
   Fast_Mode     : Boolean := False;
   Has_C128_Regs : Boolean := False;

   procedure Reset;
   procedure Tick (Cycles : Natural);
   function Read (Reg : Natural) return Byte;
   procedure Write (Reg : Natural; Value : Byte);

   procedure Set_Light_Pen (FX, FY : Float; On : Boolean);
   --  A light pen at FX / FY (0 .. 1) across the shown picture: while On
   --  the VIC latches the beam position into $D013 / $D014 (and raises
   --  IRQ bit 3) when the beam passes the pen, once per frame

   procedure Set_LP_Line (Low : Boolean);
   --  The LP input (CIA1 port B bit 4 / joystick 1 fire): going low
   --  latches the current beam position, once per frame; still low at the
   --  start of a frame latches again there (as in VICE)

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   --  Snapshot support (call between frames).

end VIC_II;
