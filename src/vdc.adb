-- ***************************************************************************
--                      AdaC64 - VDC
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************

with Interfaces; use Interfaces;
with Video; use Video;

package body VDC is

   VRAM : Byte_Array (0 .. 16#FFFF#) := (others => 0);
   type Reg_Array is array (0 .. 63) of Byte;
   Regs : Reg_Array := (others => 0);
   Sel  : Natural := 0;

   Frame_Cycle : Natural := 0;
   Frame_Count : Natural := 0;
   Cycles_Per_Frame : Natural := 19_656;

   Read_Mask : constant array (0 .. 37) of Byte :=
     (16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#E0#, 16#00#, 16#00#,
      16#FC#, 16#E0#, 16#80#, 16#E0#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#E0#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#10#, 16#E0#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#F0#, 16#00#);

   function Addr_Mask return Natural is
     (if (Regs (28) and 16#10#) /= 0 then 16#FFFF# else 16#3FFF#);

   function Update_Addr return Natural is
     (Natural (Regs (18)) * 256 + Natural (Regs (19)));

   procedure Set_Update_Addr (A : Natural) is
   begin
      Regs (18) := Byte ((A / 256) mod 256);
      Regs (19) := Byte (A mod 256);
   end Set_Update_Addr;

   procedure Set_Frame_Cycles (N : Natural) is
   begin
      Cycles_Per_Frame := N;
   end Set_Frame_Cycles;

   procedure Reset is
   begin
      Regs := (others => 0);
      --  Reasonable defaults until the KERNAL programs the chip
      Regs (0) := 126; Regs (1) := 80; Regs (2) := 102; Regs (4) := 32;
      Regs (6) := 25; Regs (9) := 7; Regs (22) := 16#78#; Regs (23) := 8;
      Regs (25) := 16#47#; Regs (26) := 16#F0#; Regs (28) := 16#20#;
      Regs (20) := 16#08#;
      Sel := 0;
   end Reset;

   function Read_Status return Byte is
      VBlank : constant Boolean := Frame_Cycle > (Cycles_Per_Frame * 85) / 100;
   begin
      return 16#80# or (if VBlank then 16#20# else 0) or 16#01#;
   end Read_Status;

   function Read_Data return Byte is
   begin
      case Sel is
         when 31 =>
            declare
               A : constant Natural := Update_Addr;
               V : constant Byte := VRAM (A mod (Addr_Mask + 1));
            begin
               Set_Update_Addr ((A + 1) mod 16#10000#);
               return V;
            end;
         when 0 .. 30 | 32 .. 37 =>
            return Regs (Sel) or Read_Mask (Sel);
         when others =>
            return 16#FF#;
      end case;
   end Read_Data;

   procedure Write_Address (Value : Byte) is
   begin
      Sel := Natural (Value and 16#3F#);
   end Write_Address;

   procedure Write_Data (Value : Byte) is
   begin
      case Sel is
         when 31 =>
            declare
               A : constant Natural := Update_Addr;
            begin
               VRAM (A mod (Addr_Mask + 1)) := Value;
               Regs (31) := Value;
               Set_Update_Addr ((A + 1) mod 16#10000#);
            end;
         when 30 =>
            Regs (30) := Value;
            declare
               Count : Natural := Natural (Value);
               A : Natural := Update_Addr;
               Src : Natural := Natural (Regs (32)) * 256 + Natural (Regs (33));
               Mask : constant Natural := Addr_Mask;
            begin
               if Count = 0 then
                  Count := 256;
               end if;
               if (Regs (24) and 16#80#) /= 0 then
                  --  Block copy
                  for I in 1 .. Count loop
                     VRAM (A mod (Mask + 1)) := VRAM (Src mod (Mask + 1));
                     Regs (31) := VRAM (Src mod (Mask + 1));
                     A := (A + 1) mod 16#10000#;
                     Src := (Src + 1) mod 16#10000#;
                  end loop;
                  Regs (32) := Byte (Src / 256);
                  Regs (33) := Byte (Src mod 256);
               else
                  --  Block fill with R31
                  for I in 1 .. Count loop
                     VRAM (A mod (Mask + 1)) := Regs (31);
                     A := (A + 1) mod 16#10000#;
                  end loop;
               end if;
               Set_Update_Addr (A);
            end;
         when 0 .. 29 | 32 .. 63 =>
            Regs (Sel) := Value;
         when others =>
            null;
      end case;
   end Write_Data;

   function Peek_VRAM (Addr : Natural) return Byte is
     (VRAM (Addr mod 16#10000#));
   function Peek_Reg (N : Natural) return Byte is (Regs (N mod 64));

   procedure Tick (Cycles : Natural) is
   begin
      Frame_Cycle := Frame_Cycle + Cycles;
      if Frame_Cycle >= Cycles_Per_Frame then
         Frame_Cycle := Frame_Cycle - Cycles_Per_Frame;
         Frame_Count := Frame_Count + 1;
      end if;
   end Tick;

   procedure Render_Frame is
      Cols    : constant Natural := Natural'Min (Natural (Regs (1)), 88);
      Rows    : constant Natural := Natural'Min (Natural (Regs (6)), 32);
      Char_H  : constant Natural := Natural (Regs (9) and 16#1F#) + 1;
      Disp_H  : constant Natural :=
        Natural'Min (Natural (Regs (23) and 16#1F#) + 1, Char_H);
      Char_W  : constant Natural := 8;
      Bitmap  : constant Boolean := (Regs (25) and 16#80#) /= 0;
      Attr_On : constant Boolean := (Regs (25) and 16#40#) /= 0;
      Double  : constant Boolean := (Regs (25) and 16#10#) /= 0;
      Rev_Scr : constant Boolean := (Regs (24) and 16#40#) /= 0;
      FG_Def  : constant Byte := Shift_Right (Regs (26), 4);
      BG_Col  : constant Byte := Regs (26) and 15;
      Disp_Start : constant Natural := Natural (Regs (12)) * 256 +
                                        Natural (Regs (13));
      Attr_Start : constant Natural := Natural (Regs (20)) * 256 +
                                        Natural (Regs (21));
      Cursor  : constant Natural := Natural (Regs (14)) * 256 +
                                     Natural (Regs (15));
      Cur_Mode  : constant Natural := Natural (Shift_Right (Regs (10), 5) and 3);
      Cur_Start : constant Natural := Natural (Regs (10) and 16#1F#);
      Cur_End   : constant Natural := Natural (Regs (11) and 16#1F#);
      Char_Base : constant Natural := Natural (Regs (28) and 16#E0#) * 256;
      Underline : constant Natural := Natural (Regs (29) and 16#1F#);
      Stride  : constant Natural := Cols + Natural (Regs (27));
      Mask    : constant Natural := Addr_Mask;
      Blink_Slow : constant Boolean := (Frame_Count / 16) mod 2 = 0;
      Blink_Fast : constant Boolean := (Frame_Count / 8) mod 2 = 0;
      Cursor_On : constant Boolean :=
        (case Cur_Mode is
           when 0 => True,
           when 1 => False,
           when 2 => Blink_Fast,
           when others => Blink_Slow);
      Scale_X : constant Natural := (if Double then 2 else 1);
      Width   : constant Natural := Cols * Char_W * Scale_X;
      Height  : constant Natural := Rows * Char_H;
      Off_X   : constant Integer := (VDC_Width - Integer (Width)) / 2;
      Off_Y   : constant Integer := (VDC_Height - Integer (Height)) / 2;
      Border  : constant Pixel := VDC_Palette (BG_Col);
   begin
      for Y in VDC_FB'Range (1) loop
         for X in VDC_FB'Range (2) loop
            VDC_FB (Y, X) := Border;
         end loop;
      end loop;

      for R in 0 .. Rows - 1 loop
         for C in 0 .. Cols - 1 loop
            declare
               Offs : constant Natural := R * Stride + C;
               Code : constant Byte := VRAM ((Disp_Start + Offs) mod (Mask + 1));
               Attr : constant Byte :=
                 (if Attr_On then VRAM ((Attr_Start + Offs) mod (Mask + 1))
                  else FG_Def);
               FG   : constant Byte := (if Attr_On then Attr and 15 else FG_Def);
               Alt  : constant Boolean := Attr_On and then (Attr and 16#80#) /= 0;
               Rev  : constant Boolean := Attr_On and then (Attr and 16#40#) /= 0;
               Und  : constant Boolean := Attr_On and then (Attr and 16#20#) /= 0;
               Blk  : constant Boolean := Attr_On and then (Attr and 16#10#) /= 0;
               Is_Cursor : constant Boolean :=
                 (Disp_Start + Offs) mod 16#10000# = Cursor;
               Bits : Byte;
               Y, X : Integer;
               On   : Boolean;
            begin
               for Line in 0 .. Char_H - 1 loop
                  if Bitmap then
                     Bits := VRAM ((Disp_Start + (R * Char_H + Line) * Stride
                                    + C) mod (Mask + 1));
                  elsif Line < Disp_H then
                     Bits := VRAM ((Char_Base
                                    + (if Alt then 4096 else 0)
                                    + Natural (Code) * 16 + Line)
                                   mod (Mask + 1));
                  else
                     Bits := 0;
                  end if;
                  if Und and then Line = Underline then
                     Bits := 16#FF#;
                  end if;
                  if Blk and then not Blink_Slow then
                     Bits := 0;
                  end if;
                  if Rev then
                     Bits := not Bits;
                  end if;
                  if Is_Cursor and then Cursor_On
                    and then Line >= Cur_Start and then Line <= Cur_End
                  then
                     Bits := not Bits;
                  end if;
                  if Rev_Scr then
                     Bits := not Bits;
                  end if;
                  Y := Off_Y + R * Char_H + Line;
                  if Y in VDC_FB'Range (1) then
                     for B in 0 .. 7 loop
                        On := (Shift_Right (Bits, 7 - B) and 1) /= 0;
                        for S in 0 .. Scale_X - 1 loop
                           X := Off_X + (C * 8 + B) * Scale_X + S;
                           if X in VDC_FB'Range (2) then
                              VDC_FB (Y, X) :=
                                (if On then VDC_Palette (FG)
                                 else VDC_Palette (BG_Col));
                           end if;
                        end loop;
                     end loop;
                  end if;
               end loop;
            end;
         end loop;
      end loop;
   end Render_Frame;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte_Array'Write (S, VRAM);
      Reg_Array'Write (S, Regs);
      Natural'Write (S, Sel);
      Natural'Write (S, Frame_Cycle);
      Natural'Write (S, Frame_Count);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte_Array'Read (S, VRAM);
      Reg_Array'Read (S, Regs);
      Natural'Read (S, Sel);
      Natural'Read (S, Frame_Cycle);
      Natural'Read (S, Frame_Count);
   end Load_State;

end VDC;
