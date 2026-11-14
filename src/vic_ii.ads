--  MOS 6569 VIC-II (PAL) video chip.
--
--  Rendering is done one raster line at a time.  Bad lines and sprite DMA
--  steal cycles from the CPU through Stall_Cycles, which the machine
--  consumes before executing the next instruction.

with Types; use Types;

generic
   with function Mem_Read (Addr : Word) return Byte;
   --  14-bit address inside the current VIC bank (bank and character ROM
   --  mapping is done by the machine).
   with function Color_Read (Index : Natural) return Byte;
   --  Colour RAM nibble, 0 .. 1023.
package VIC_II is

   Cycles_Per_Line : constant := 63;
   Lines_Per_Frame : constant := 312;

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

end VIC_II;
