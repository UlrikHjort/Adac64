with Interfaces; use Interfaces;
with Video; use Video;

package body VIC_II is

   Regs : array (0 .. 16#3F#) of Byte := (others => 0);

   --  Internal counters
   VC, VC_Base : Natural := 0;
   RC          : Natural := 0;
   Display_State : Boolean := False;
   Bad_Line    : Boolean := False;
   DEN_Latch   : Boolean := False;
   Badline_Checked : Boolean := False;
   VBorder     : Boolean := True;

   IRQ_Flags   : Byte := 0;
   IRQ_Enable  : Byte := 0;
   Sprite_Sprite_Coll : Byte := 0;
   Sprite_Bg_Coll     : Byte := 0;

   --  Line buffers fetched during bad lines
   VM_Buf  : array (0 .. 39) of Byte := (others => 0);
   Col_Buf : array (0 .. 39) of Byte := (others => 0);

   --  Sprite state
   type Sprite_State is record
      Active  : Boolean := False;
      MC_Base : Natural := 0;
      Exp_FF  : Boolean := True;
   end record;
   Sprites : array (0 .. 7) of Sprite_State;

   --  Per-line pixel buffers
   subtype Line_X is Natural range 0 .. VIC_Width - 1;
   Line_Col : array (Line_X) of Byte;
   Line_FG  : array (Line_X) of Boolean;
   Spr_Col  : array (Line_X) of Byte;
   Spr_Mask : array (Line_X) of Byte;
   Spr_Prio : array (Line_X) of Boolean;   --  behind foreground

   function Bit (V : Byte; N : Natural) return Boolean is
     ((Shift_Right (V, N) and 1) /= 0);
   pragma Inline (Bit);

   function Compare_Line return Natural is
     (Natural (Regs (16#12#)) +
        (if Bit (Regs (16#11#), 7) then 256 else 0));

   procedure Update_IRQ is
   begin
      IRQ := (IRQ_Flags and IRQ_Enable and 16#0F#) /= 0;
   end Update_IRQ;

   procedure Raise_IRQ (B : Byte) is
   begin
      IRQ_Flags := IRQ_Flags or B;
      Update_IRQ;
   end Raise_IRQ;

   procedure Reset is
   begin
      Regs := (others => 0);
      Raster := 0;
      Line_Cycle := 0;
      VC := 0; VC_Base := 0; RC := 0;
      Display_State := False;
      Bad_Line := False;
      DEN_Latch := False;
      VBorder := True;
      IRQ_Flags := 0;
      IRQ_Enable := 0;
      IRQ := False;
      Stall_Cycles := 0;
      Sprites := (others => <>);
      Key_Lines := 16#FF#;
      Fast_Mode := False;
   end Reset;

   ---------------------------------------------------------------------
   --  Line rendering
   ---------------------------------------------------------------------

   procedure Draw_Graphics is
      D011 : constant Byte := Regs (16#11#);
      D016 : constant Byte := Regs (16#16#);
      D018 : constant Byte := Regs (16#18#);
      ECM  : constant Boolean := Bit (D011, 6);
      BMM  : constant Boolean := Bit (D011, 5);
      MCM  : constant Boolean := Bit (D016, 4);
      XScroll : constant Natural := Natural (D016 and 7);
      Char_Base : constant Word := Word (D018 and 16#0E#) * 1024;
      Bmp_Base  : constant Word := Word (D018 and 16#08#) * 1024;
      BG : constant array (0 .. 3) of Byte :=
        (Regs (16#21#) and 15, Regs (16#22#) and 15,
         Regs (16#23#) and 15, Regs (16#24#) and 15);
      Invalid : constant Boolean := ECM and then (BMM or else MCM);
      X0 : Natural;
      G, C, Col : Byte;
      Px : Natural;

      procedure Put (X : Natural; Color : Byte; FG : Boolean) is
      begin
         if X <= Line_X'Last then
            Line_Col (X) := (if Invalid then 0 else Color);
            Line_FG (X) := FG;
         end if;
      end Put;
      pragma Inline (Put);
   begin
      for I in 0 .. 39 loop
         if Display_State then
            C := VM_Buf (I);
            Col := Col_Buf (I);
            if BMM then
               G := Mem_Read
                 (Bmp_Base + Word (((VC + I) * 8 + RC) mod 8192));
            else
               declare
                  Code : constant Byte := (if ECM then C and 16#3F# else C);
               begin
                  G := Mem_Read (Char_Base + Word (Code) * 8 + Word (RC));
               end;
            end if;
         else
            C := 0;
            Col := 0;
            G := Mem_Read (if ECM then 16#39FF# else 16#3FFF#);
         end if;

         X0 := 32 + XScroll + I * 8;

         if not BMM and then not ECM and then not (MCM and then Bit (Col, 3))
         then
            --  Standard text (or hires char in MC mode)
            declare
               FGC : constant Byte := (if MCM then Col and 7 else Col);
            begin
               for B in 0 .. 7 loop
                  Px := X0 + B;
                  if Bit (G, 7 - B) then
                     Put (Px, FGC, True);
                  else
                     Put (Px, BG (0), False);
                  end if;
               end loop;
            end;

         elsif not BMM and then not ECM then
            --  Multicolour text
            for P in 0 .. 3 loop
               declare
                  Bits : constant Natural :=
                    Natural (Shift_Right (G, 6 - 2 * P) and 3);
                  Color : constant Byte :=
                    (case Bits is
                       when 0 => BG (0),
                       when 1 => BG (1),
                       when 2 => BG (2),
                       when others => Col and 7);
               begin
                  Put (X0 + 2 * P, Color, Bits >= 2);
                  Put (X0 + 2 * P + 1, Color, Bits >= 2);
               end;
            end loop;

         elsif not BMM then
            --  ECM text (or invalid ECM+MCM)
            for B in 0 .. 7 loop
               Px := X0 + B;
               if Bit (G, 7 - B) then
                  Put (Px, Col, True);
               else
                  Put (Px, BG (Natural (Shift_Right (C, 6))), False);
               end if;
            end loop;

         elsif not MCM then
            --  Hires bitmap
            for B in 0 .. 7 loop
               Px := X0 + B;
               if Bit (G, 7 - B) then
                  Put (Px, Shift_Right (C, 4), True);
               else
                  Put (Px, C and 15, False);
               end if;
            end loop;

         else
            --  Multicolour bitmap
            for P in 0 .. 3 loop
               declare
                  Bits : constant Natural :=
                    Natural (Shift_Right (G, 6 - 2 * P) and 3);
                  Color : constant Byte :=
                    (case Bits is
                       when 0 => BG (0),
                       when 1 => Shift_Right (C, 4),
                       when 2 => C and 15,
                       when others => Col);
               begin
                  Put (X0 + 2 * P, Color, Bits >= 2);
                  Put (X0 + 2 * P + 1, Color, Bits >= 2);
               end;
            end loop;
         end if;
      end loop;
   end Draw_Graphics;

   procedure Draw_Sprites (Visible : Boolean) is
      Enable : constant Byte := Regs (16#15#);
      VM_Base : constant Word := Word (Shift_Right (Regs (16#18#), 4)) * 1024;
      SS : Byte := 0;
      SB : Byte := 0;
   begin
      Spr_Mask := (others => 0);
      for N in reverse 0 .. 7 loop
         if Sprites (N).Active and then Bit (Enable, N) then
            declare
               Ptr  : constant Word := Word (Mem_Read (VM_Base + 16#3F8# +
                                                       Word (N)));
               Addr : constant Word := Ptr * 64 + Word (Sprites (N).MC_Base);
               Data : constant U32 :=
                 Shift_Left (U32 (Mem_Read (Addr)), 16) or
                 Shift_Left (U32 (Mem_Read (Addr + 1)), 8) or
                 U32 (Mem_Read (Addr + 2));
               XPos : Integer := Integer (Regs (N * 2)) +
                 (if Bit (Regs (16#10#), N) then 256 else 0);
               XExp : constant Boolean := Bit (Regs (16#1D#), N);
               MC   : constant Boolean := Bit (Regs (16#1C#), N);
               Behind : constant Boolean := Bit (Regs (16#1B#), N);
               Own  : constant Byte := Regs (16#27# + N) and 15;
               MC0  : constant Byte := Regs (16#25#) and 15;
               MC1  : constant Byte := Regs (16#26#) and 15;
               Width : constant Natural := (if XExp then 48 else 24);
               Mask : constant Byte := Shift_Left (1, N);
               Px   : Integer;
               Bits : Natural;
               Color : Byte;
               Idx  : Natural;
            begin
               if XPos >= 16#1F8# then
                  XPos := XPos - 16#200#;
               end if;
               for I in 0 .. Width - 1 loop
                  Px := XPos + 8 + I;
                  if Px in Line_X then
                     Idx := (if XExp then I / 2 else I);
                     if MC then
                        Bits := Natural (Shift_Right
                                  (Data, 22 - 2 * (Idx / 2)) and 3);
                     else
                        Bits := (if (Shift_Right (Data, 23 - Idx) and 1) /= 0
                                 then 2 else 0);
                     end if;
                     if Bits /= 0 then
                        Color := (case Bits is
                                     when 1 => MC0,
                                     when 2 => Own,
                                     when others => MC1);
                        if Spr_Mask (Px) /= 0 then
                           SS := SS or Spr_Mask (Px) or Mask;
                        end if;
                        Spr_Mask (Px) := Spr_Mask (Px) or Mask;
                        if Line_FG (Px) then
                           SB := SB or Mask;
                        end if;
                        --  Lower numbered sprites drawn later win
                        Spr_Col (Px) := Color;
                        Spr_Prio (Px) := Behind;
                     end if;
                  end if;
               end loop;
            end;
         end if;
      end loop;

      if SS /= 0 then
         if Sprite_Sprite_Coll = 0 then
            Raise_IRQ (16#04#);
         end if;
         Sprite_Sprite_Coll := Sprite_Sprite_Coll or SS;
      end if;
      if SB /= 0 then
         if Sprite_Bg_Coll = 0 then
            Raise_IRQ (16#02#);
         end if;
         Sprite_Bg_Coll := Sprite_Bg_Coll or SB;
      end if;

      if Visible then
         for X in Line_X loop
            if Spr_Mask (X) /= 0 then
               if not (Spr_Prio (X) and then Line_FG (X)) then
                  Line_Col (X) := Spr_Col (X);
               end if;
            end if;
         end loop;
      end if;
   end Draw_Sprites;

   procedure Render_Line is
      Visible : constant Boolean :=
        Raster >= First_Visible_Line
        and then Raster < First_Visible_Line + VIC_Height;
      Border : constant Byte := Regs (16#20#) and 15;
      CSEL : constant Boolean := Bit (Regs (16#16#), 3);
      Left  : constant Natural := (if CSEL then 32 else 39);
      Right : constant Natural := (if CSEL then 352 else 343);
      Y : Natural;
   begin
      Line_FG := (others => False);
      Line_Col := (others => Regs (16#21#) and 15);

      if not VBorder then
         Draw_Graphics;
      end if;

      Draw_Sprites (Visible);

      if not Visible then
         return;
      end if;

      if VBorder then
         Line_Col := (others => Border);
      else
         for X in 0 .. Left - 1 loop
            Line_Col (X) := Border;
         end loop;
         for X in Right .. Line_X'Last loop
            Line_Col (X) := Border;
         end loop;
      end if;

      Y := Raster - First_Visible_Line;
      for X in Line_X loop
         VIC_FB (Y, X) := VIC_Palette (Line_Col (X));
      end loop;
   end Render_Line;

   ---------------------------------------------------------------------
   --  Timing
   ---------------------------------------------------------------------

   procedure Check_Bad_Line is
      D011 : constant Byte := Regs (16#11#);
   begin
      if Raster = 16#30# and then Bit (D011, 4) then
         DEN_Latch := True;
      end if;
      Bad_Line := DEN_Latch
        and then Raster in 16#30# .. 16#F7#
        and then Natural (D011 and 7) = Raster mod 8;

      VC := VC_Base;
      if Bad_Line then
         Display_State := True;
         RC := 0;
         if not Fast_Mode then
            Stall_Cycles := Stall_Cycles + 40;
         end if;
         declare
            VM_Base : constant Word :=
              Word (Shift_Right (Regs (16#18#), 4)) * 1024;
         begin
            for I in 0 .. 39 loop
               VM_Buf (I) := Mem_Read (VM_Base + Word ((VC + I) mod 1024));
               Col_Buf (I) := Color_Read ((VC + I) mod 1024) and 15;
            end loop;
         end;
      end if;
   end Check_Bad_Line;

   procedure Start_Line is
      D011 : constant Byte := Regs (16#11#);
      RSEL : constant Boolean := Bit (D011, 3);
      Top    : constant Natural := (if RSEL then 51 else 55);
      Bottom : constant Natural := (if RSEL then 251 else 247);
      Active_Sprites : Natural := 0;
   begin
      if Raster = 0 then
         VC_Base := 0;
         DEN_Latch := False;
      end if;

      if Raster = Compare_Line then
         Raise_IRQ (16#01#);
      end if;

      if Raster = Bottom then
         VBorder := True;
      elsif Raster = Top and then Bit (D011, 4) then
         VBorder := False;
      end if;

      for N in 0 .. 7 loop
         if Sprites (N).Active and then Bit (Regs (16#15#), N) then
            Active_Sprites := Active_Sprites + 1;
         end if;
      end loop;
      if not Fast_Mode then
         Stall_Cycles := Stall_Cycles + 2 * Active_Sprites;
      end if;
   end Start_Line;

   procedure End_Line is
   begin
      Render_Line;

      if Display_State then
         VC := VC + 40;
      end if;
      if RC = 7 then
         VC_Base := VC;
         if not Bad_Line then
            Display_State := False;
         end if;
      end if;
      if Display_State then
         RC := (RC + 1) mod 8;
      end if;

      --  Sprite DMA bookkeeping
      for N in 0 .. 7 loop
         declare
            S : Sprite_State renames Sprites (N);
         begin
            if S.Active then
               if Bit (Regs (16#17#), N) then
                  S.Exp_FF := not S.Exp_FF;
                  if S.Exp_FF then
                     S.MC_Base := S.MC_Base + 3;
                  end if;
               else
                  S.MC_Base := S.MC_Base + 3;
               end if;
               if S.MC_Base >= 63 then
                  S.Active := False;
               end if;
            end if;
            if not S.Active and then Bit (Regs (16#15#), N)
              and then Natural (Regs (N * 2 + 1)) = Raster mod 256
            then
               S.Active := True;
               S.MC_Base := 0;
               S.Exp_FF := True;
            end if;
         end;
      end loop;

      Bad_Line := False;
      Raster := Raster + 1;
      if Raster >= Lines_Per_Frame then
         Raster := 0;
         Frame_Done := True;
      end if;
   end End_Line;

   procedure Tick (Cycles : Natural) is
   begin
      Line_Cycle := Line_Cycle + Cycles;
      loop
         if not Badline_Checked and then Line_Cycle >= 12 then
            Badline_Checked := True;
            Check_Bad_Line;
         end if;
         exit when Line_Cycle < Cycles_Per_Line;
         End_Line;
         Line_Cycle := Line_Cycle - Cycles_Per_Line;
         Badline_Checked := False;
         Start_Line;
      end loop;
   end Tick;

   ---------------------------------------------------------------------
   --  Register access
   ---------------------------------------------------------------------

   function Read (Reg : Natural) return Byte is
      R : constant Natural := Reg mod 64;
   begin
      case R is
         when 16#11# =>
            return (Regs (16#11#) and 16#7F#) or
              (if Raster >= 256 then 16#80# else 0);
         when 16#12# =>
            return Byte (Raster mod 256);
         when 16#16# =>
            return Regs (16#16#) or 16#C0#;
         when 16#18# =>
            return Regs (16#18#) or 16#01#;
         when 16#19# =>
            return IRQ_Flags or 16#70# or (if IRQ then 16#80# else 0);
         when 16#1A# =>
            return IRQ_Enable or 16#F0#;
         when 16#1E# =>
            declare
               V : constant Byte := Sprite_Sprite_Coll;
            begin
               Sprite_Sprite_Coll := 0;
               return V;
            end;
         when 16#1F# =>
            declare
               V : constant Byte := Sprite_Bg_Coll;
            begin
               Sprite_Bg_Coll := 0;
               return V;
            end;
         when 16#20# .. 16#2E# =>
            return Regs (R) or 16#F0#;
         when 16#2F# =>
            return (if Has_C128_Regs then Key_Lines or 16#F8# else 16#FF#);
         when 16#30# =>
            return (if Has_C128_Regs
                    then (if Fast_Mode then 16#FD# else 16#FC#)
                    else 16#FF#);
         when 16#31# .. 16#3F# =>
            return 16#FF#;
         when others =>
            return Regs (R);
      end case;
   end Read;

   procedure Write (Reg : Natural; Value : Byte) is
      R : constant Natural := Reg mod 64;
      Old_Compare : constant Natural := Compare_Line;
   begin
      case R is
         when 16#19# =>
            IRQ_Flags := IRQ_Flags and not (Value and 16#0F#);
            Update_IRQ;
         when 16#1A# =>
            IRQ_Enable := Value and 16#0F#;
            Update_IRQ;
         when 16#1E# | 16#1F# =>
            null;
         when 16#2F# =>
            Key_Lines := Value;
         when 16#30# =>
            if Has_C128_Regs then
               Fast_Mode := Bit (Value, 0);
            end if;
         when 16#31# .. 16#3F# =>
            null;
         when others =>
            Regs (R) := Value;
            if R = 16#11# or else R = 16#12# then
               if Compare_Line /= Old_Compare
                 and then Compare_Line = Raster
               then
                  Raise_IRQ (16#01#);
               end if;
               if R = 16#11# and then Raster = 16#30#
                 and then Bit (Value, 4)
               then
                  DEN_Latch := True;
               end if;
               --  Late bad-line condition (used by FLD / line crunch)
               if R = 16#11# and then Badline_Checked
                 and then not Bad_Line and then DEN_Latch
                 and then Raster in 16#30# .. 16#F7#
                 and then Natural (Value and 7) = Raster mod 8
                 and then Line_Cycle < 54
               then
                  Bad_Line := True;
                  Display_State := True;
                  RC := 0;
               end if;
            end if;
      end case;
   end Write;

end VIC_II;
