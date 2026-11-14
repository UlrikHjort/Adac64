--  MOS 8563 VDC: the C128 80-column video controller.

with Ada.Streams;
with Types; use Types;

package VDC is

   procedure Reset;
   procedure Set_Frame_Cycles (N : Natural);   --  computer cycles per frame

   function Read_Status return Byte;           --  $D600
   function Read_Data return Byte;             --  $D601
   procedure Write_Address (Value : Byte);     --  $D600
   procedure Write_Data (Value : Byte);        --  $D601

   procedure Render_Frame;
   --  Render the current screen into Video.VDC_FB (called once per frame).

   procedure Tick (Cycles : Natural);
   --  Advance the internal raster position (for the vblank status bit).

   function Peek_VRAM (Addr : Natural) return Byte;
   function Peek_Reg (N : Natural) return Byte;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   --  Snapshot support (call between frames).

end VDC;
