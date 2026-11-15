--  MOS 6560 (NTSC) / 6561 (PAL) Video Interface Chip of the VIC-20:
--  video (drawn a raster line at a time from the current registers)
--  and its sound (three square-wave voices and noise).
--
--  Fetch reads the VIC's 14-bit address space; Color reads the 4-bit
--  colour RAM (index 0 .. 1023).

with Types; use Types;

generic
   with function Fetch (Addr : Word) return Byte;
   with function Color (Index : Natural) return Byte;
package VIC_I is

   type Standard_Kind is (PAL, NTSC);
   procedure Set_Standard (S : Standard_Kind);
   function Clock_Hz return Natural;           --  CPU clock
   function Cycles_Per_Line return Positive;
   function Lines_Per_Frame return Positive;

   procedure Reset;
   function Read (Reg : Natural) return Byte;  --  $9000 + Reg (0 .. 15)
   procedure Write (Reg : Natural; Value : Byte);
   procedure Tick (Cycles : Natural);

   Frame_Done : Boolean := False;   --  set at the end of every frame

   function Raster return Natural;
   function Screen_Address return Word;   --  VIC address of the matrix
   function Register (Reg : Natural) return Byte;

end VIC_I;
