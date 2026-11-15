-- ***************************************************************************
--                      AdaC64 - TED
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
with Video;
with SID; use type SID.Sink_Proc;

package body TED is

   --  Colours: bits 0-3 hue, bits 4-6 luminance (as VICE shows them)
   type TED_Palette is array (Byte range 0 .. 127) of Pixel;
   Palette : constant TED_Palette :=
     (16#000000#, 16#313131#, 16#740d00#, 16#004e56#,
      16#6c0081#, 16#006000#, 16#2312bb#, 16#3d4b00#,
      16#6a2300#, 16#573900#, 16#1e5800#, 16#75004c#,
      16#005a10#, 16#0029aa#, 16#4200bb#, 16#005f00#,
      16#000000#, 16#444444#, 16#83251b#, 16#005f66#,
      16#7c0b90#, 16#007000#, 16#3729c9#, 16#4f5c00#,
      16#7a3700#, 16#674b00#, 16#336800#, 16#84155d#,
      16#006a27#, 16#1a3cb8#, 16#5318c8#, 16#146f00#,
      16#000000#, 16#565656#, 16#923930#, 16#036f76#,
      16#8b239f#, 16#127f00#, 16#4a3cd6#, 16#606c00#,
      16#894a00#, 16#775c00#, 16#457800#, 16#932b6d#,
      16#007a3b#, 16#2f4ec6#, 16#642ed5#, 16#2a7e00#,
      16#000000#, 16#666666#, 16#a04b43#, 16#1e7e85#,
      16#9937ad#, 16#298e07#, 16#5b4ee3#, 16#707c00#,
      16#985b00#, 16#866c00#, 16#578700#, 16#a13e7d#,
      16#1c894d#, 16#425fd3#, 16#7441e3#, 16#3d8d00#,
      16#000000#, 16#8d8d8d#, 16#c3746d#, 16#4ea3a9#,
      16#bc63cf#, 16#57b23e#, 16#8277ff#, 16#96a000#,
      16#bb8236#, 16#aa9200#, 16#7eab00#, 16#c469a1#,
      16#4dad76#, 16#6c86f3#, 16#996bff#, 16#68b105#,
      16#000000#, 16#a2a2a2#, 16#d78b84#, 16#67b8be#,
      16#d17be3#, 16#6fc759#, 16#988dff#, 16#abb505#,
      16#cf9851#, 16#bfa825#, 16#95c007#, 16#d880b6#,
      16#66c18d#, 16#839cff#, 16#af82ff#, 16#7fc62a#,
      16#000000#, 16#cccccc#, 16#feb5af#, 16#95e0e6#,
      16#f7a7ff#, 16#9cee88#, 16#c2b8ff#, 16#d4de46#,
      16#f6c281#, 16#e7d15c#, 16#bfe748#, 16#ffacdf#,
      16#94e9b7#, 16#afc6ff#, 16#d7aeff#, 16#abed60#,
      16#000000#, 16#ffffff#, 16#ffebe5#, 16#ccffff#,
      16#ffddff#, 16#d3ffc1#, 16#f7edff#, 16#ffff87#,
      16#fff7bb#, 16#ffff99#, 16#f3ff88#, 16#ffe2ff#,
      16#ccffec#, 16#e4faff#, 16#ffe3ff#, 16#e1ff9d#);

   type Reg_Array is array (0 .. 63) of Byte;
   Regs : Reg_Array := (others => 0);

   Std : Standard_Kind := PAL;
   Lines : Positive := 312;
   Vsync_Line : Natural := 257;
   First_TV_Line : constant := 19;    --  first line shown (after vsync)

   Last_DMA_Line : constant := 16#CB#;

   R   : Natural := 0;                --  raster line
   Cyc : Natural := 0;                --  double-clock cycle in the line
   TV_Line : Natural := 0;            --  lines since vertical sync

   --  Timers: remaining double-clock cycles (they count at single clock)
   type Timer_Array is array (1 .. 3) of Natural;
   Remaining : Timer_Array := (others => 0);
   Running   : array (1 .. 3) of Boolean := (others => False);
   T_Start   : Timer_Array := (others => 0);    --  value written
   Status    : Byte := 0;             --  $FF09 bits 1, 3, 4, 6

   --  Video
   type Buf40 is array (0 .. 39) of Byte;
   Vbuf, Cbuf, Cbuf_Next : Buf40 := (others => 0);
   Ycounter : Natural := 0;
   Row_Ptr, Next_Row_Ptr : Natural := 0;    --  0 .. 1023
   Idle : Boolean := True;
   Allow_Bad : Boolean := False;
   Fetch_On : Boolean := False;       --  CPU single speed in the window
   Window : Boolean := False;         --  vertical display window open
   DMA_Line : Boolean := False;
   Cursor_Phase : Natural := 0;       --  0 .. 31, cursor shown in 16 .. 31
   Crsr_Pos : Natural := 0;

   function Bit (V : Byte; N : Natural) return Boolean is
     ((Shift_Right (V, N) and 1) /= 0);

   function Cursor_Visible return Boolean is (Cursor_Phase >= 16);
   function YScroll return Natural is (Natural (Regs (6) and 7));
   function DEN return Boolean is (Bit (Regs (6), 4));

   ---------------------------------------------------------------------
   --  Sound: two square-wave voices (voice 2 can be noise), stepped every
   --  8 double-clock cycles as in VICE
   ---------------------------------------------------------------------

   Snd_Div : Natural := 0;
   Count : array (1 .. 2) of Natural := (others => 0);
   Sign  : array (1 .. 2) of Boolean := (others => False);
   Noise_SR : Unsigned_8 := 16#FF#;
   Sample_Acc : Float := 0.0;
   DC_Prev_In, DC_Prev_Out : Float := 0.0;

   function Freq (V : Positive) return Natural is
     (if V = 1 then Natural (Regs (16#0E#)) + 256 * Natural (Regs (16#12#) and 3)
      else Natural (Regs (16#0F#)) + 256 * Natural (Regs (16#10#) and 3));

   procedure Sound_Step is
      Ctrl : constant Byte := Regs (16#11#);
   begin
      for V in 1 .. 2 loop
         declare
            Reload : constant Natural := (Freq (V) + 1) mod 1024;
            Period : constant Positive := 1024 - Reload;
         begin
            Count (V) := Count (V) + 1;
            if Count (V) >= Period then
               Count (V) := 0;
               Sign (V) := not Sign (V);
               if V = 2 then
                  Noise_SR := Shift_Left (Noise_SR, 1) or
                    ((Shift_Right (Noise_SR, 7) xor Shift_Right (Noise_SR, 5)
                      xor Shift_Right (Noise_SR, 4)
                      xor Shift_Right (Noise_SR, 1)) and 1);
               end if;
            end if;
            if Freq (V) = 16#3FE# or else Bit (Ctrl, 7) then
               Sign (V) := True;            --  constant level (D/A use)
            end if;
         end;
      end loop;
   end Sound_Step;

   procedure Sound_Output is
      Ctrl : constant Byte := Regs (16#11#);
      Vol  : constant Float :=
        Float (Natural'Min (8, Natural (Ctrl and 15))) / 8.0;
      Noise : constant Boolean := (Ctrl and 16#60#) = 16#40#;
      Sum  : Float := 0.0;
      Y : Float;
   begin
      if Bit (Ctrl, 4) and then Sign (1) then
         Sum := Sum + 1.0;
      end if;
      if Noise then
         if (Noise_SR and 1) = 0 then
            Sum := Sum + 1.0;
         end if;
      elsif Bit (Ctrl, 5) and then Sign (2) then
         Sum := Sum + 1.0;
      end if;
      Sum := Sum * Vol * 0.57;            --  level as in VICE
      --  AC coupled output
      Y := Sum - DC_Prev_In + 0.995 * DC_Prev_Out;
      DC_Prev_In := Sum;
      DC_Prev_Out := Y;
      if SID.Sink /= null then
         SID.Sink (SID.Sample
           (Integer (Float'Max (-1.0, Float'Min (1.0, Y)) * 30000.0)));
      end if;
   end Sound_Output;

   ---------------------------------------------------------------------
   --  Interrupts
   ---------------------------------------------------------------------

   function IRQ return Boolean is
     ((Status and Regs (16#0A#) and 16#5E#) /= 0);

   function Compare_Line return Natural is
     (Natural (Regs (16#0B#)) + (if Bit (Regs (16#0A#), 0) then 256 else 0));

   ---------------------------------------------------------------------
   --  Pixels
   ---------------------------------------------------------------------

   function Char_Base return Natural is
     (Natural (Regs (16#13#) and
        (if Bit (Regs (6), 6) or else Bit (Regs (7), 7) then 16#F8#
         else 16#FC#)) * 256);

   function Video_ROM return Boolean is (Bit (Regs (16#12#), 2));

   --  Graphics colour (7 bits) at graphics x position GX (0 .. 319 + 7)
   Cached_Char : Integer := -1;
   Cached_Data : Byte := 0;

   function Graphics_Color (GX : Natural) return Byte is
      Ch : constant Natural := GX / 8;
      Px : constant Natural := GX mod 8;
      ECM : constant Boolean := Bit (Regs (6), 6);
      BMM : constant Boolean := Bit (Regs (6), 5);
      MCM : constant Boolean := Bit (Regs (7), 4);
      BG0 : constant Byte := Regs (16#15#) and 16#7F#;
      V, C, D : Byte;
   begin
      if Idle or else Ch > 39 then
         return BG0;
      end if;
      V := Vbuf (Ch);
      C := Cbuf (Ch);
      if ECM and then (BMM or else MCM) then
         return 0;                           --  invalid mode: black
      end if;
      if Cached_Char /= Ch then
         Cached_Char := Ch;
         if BMM then
            Cached_Data := Fetch
              (Word ((Natural (Regs (16#12#) and 16#38#) * 1024
                      + (Row_Ptr * 8 + Ycounter + Ch * 8) mod 8192)
                     mod 65536), Video_ROM);
         else
            declare
               Code : constant Natural :=
                 (if ECM then Natural (V and 16#3F#)
                  elsif Bit (Regs (7), 7) then Natural (V)
                  else Natural (V and 16#7F#));
               Addr : constant Natural :=
                 (Char_Base + Code * 8 + Ycounter) mod 65536;
            begin
               Cached_Data := Fetch (Word (Addr), Video_ROM);
            end;
         end if;
      end if;
      D := Cached_Data;
      if BMM then
         declare
            C1 : constant Byte := Shift_Left (C and 7, 4) or Shift_Right (V, 4);
            C0 : constant Byte := (C and 16#70#) or (V and 16#0F#);
         begin
            if MCM then
               case Shift_Right (D, 6 - (Px / 2) * 2) and 3 is
                  when 0 => return BG0;
                  when 1 => return C1;
                  when 2 => return C0;
                  when others => return Regs (16#16#) and 16#7F#;
               end case;
            end if;
            return (if Bit (D, 7 - Px) then C1 else C0);
         end;
      end if;
      if ECM then
         return (if Bit (D, 7 - Px) then C and 16#7F#
                 else (case Shift_Right (V, 6) is
                          when 0 => BG0,
                          when 1 => Regs (16#16#) and 16#7F#,
                          when 2 => Regs (16#17#) and 16#7F#,
                          when others => Regs (16#18#) and 16#7F#));
      end if;
      if MCM then
         if Bit (C, 3) then
            case Shift_Right (D, 6 - (Px / 2) * 2) and 3 is
               when 0 => return BG0;
               when 1 => return Regs (16#16#) and 16#7F#;
               when 2 => return Regs (16#17#) and 16#7F#;
               when others => return C and 16#77#;
            end case;
         end if;
         return (if Bit (D, 7 - Px) then C and 16#77# else BG0);
      end if;
      --  standard text: reverse characters, flashing, the cursor
      if not Bit (Regs (7), 7) and then Bit (V, 7) then
         D := not D;
      end if;
      if Bit (C, 7) and then not Cursor_Visible then
         D := (if not Bit (Regs (7), 7) and then Bit (V, 7) then 16#FF#
               else 0);
      end if;
      if Cursor_Visible and then (Row_Ptr + Ch) mod 1024 = Crsr_Pos then
         D := not D;
      end if;
      return (if Bit (D, 7 - Px) then C and 16#7F# else BG0);
   end Graphics_Color;

   procedure Draw (X0 : Natural) is
      Y : constant Integer := TV_Line - First_TV_Line;
      Left  : constant Natural := (if Bit (Regs (7), 3) then 32 else 39);
      Right : constant Natural := (if Bit (Regs (7), 3) then 352 else 343);
      XS : constant Natural := Natural (Regs (7) and 7);
      Border : constant Byte := Regs (16#19#) and 16#7F#;
   begin
      if Y < 0 or else Y >= Video.VIC_Visible_Lines then
         return;
      end if;
      for X in X0 .. X0 + 3 loop
         if X < Video.VIC_Width then
            declare
               Col : Byte := Border;
            begin
               if Window and then X >= Left and then X < Right then
                  Col := (if X - 32 >= XS
                          then Graphics_Color (X - 32 - XS)
                          else Regs (16#15#) and 16#7F#);
               end if;
               Video.VIC_FB (Y, X) := Palette (Col);
            end;
         end if;
      end loop;
   end Draw;

   ---------------------------------------------------------------------
   --  Lines
   ---------------------------------------------------------------------

   function Matrix_Base return Word is
     (Word (Natural (Regs (16#14#) and 16#F8#) * 256));

   procedure Start_Line is
      Attr_Fetch, Matrix_Fetch : Boolean;
      Base : constant Natural := Natural (Matrix_Base);
   begin
      if R = Compare_Line then
         Status := Status or 2;
      end if;
      Attr_Fetch := Allow_Bad and then R mod 8 = YScroll
        and then R < Last_DMA_Line;
      Matrix_Fetch := Allow_Bad and then R mod 8 = (YScroll + 1) mod 8
        and then R > 0 and then R <= Last_DMA_Line;
      if Attr_Fetch then
         for I in Buf40'Range loop
            Cbuf_Next (I) := Fetch
              (Word ((Base + (Next_Row_Ptr + I) mod 1024) mod 65536),
               ROM_Enabled);
         end loop;
      end if;
      if Matrix_Fetch then
         for I in Buf40'Range loop
            Vbuf (I) := Fetch
              (Word ((Base + 16#400# + (Next_Row_Ptr + I) mod 1024) mod 65536),
               ROM_Enabled);
         end loop;
         Cbuf := Cbuf_Next;
         Row_Ptr := Next_Row_Ptr;
         Next_Row_Ptr := (Next_Row_Ptr + 40) mod 1024;
         Ycounter := 0;
         Idle := False;
      end if;
      DMA_Line := Attr_Fetch or else Matrix_Fetch;
      Cached_Char := -1;
   end Start_Line;

   procedure End_Line is
      Start_25 : constant Natural := 4;
      Stop_25  : constant Natural := 16#CB#;
      Start_24 : constant Natural := 8;
      Stop_24  : constant Natural := 16#C7#;
   begin
      if not Idle then
         if Ycounter = 7 then
            Ycounter := 0;
            Idle := True;          --  until the next row's fetch
         else
            Ycounter := Ycounter + 1;
         end if;
      end if;
      if R = Last_DMA_Line then
         Idle := True;
      end if;
      R := R + 1;
      TV_Line := TV_Line + 1;
      if R = Lines or else R >= 512 then
         R := 0;
      end if;
      if R = 0 then
         Next_Row_Ptr := 0;
         Row_Ptr := 0;
         Fetch_On := DEN;
         Allow_Bad := DEN;
      end if;
      if R = 16#CC# then
         Fetch_On := False;
      end if;
      if Bit (Regs (6), 3) then
         if R = Start_25 and then DEN then
            Window := True;
         elsif R = Stop_25 + 1 then
            Window := False;
         end if;
      else
         if R = Start_24 and then DEN then
            Window := True;
         elsif R = Stop_24 + 1 then
            Window := False;
         end if;
      end if;
      if R = Vsync_Line then
         TV_Line := 0;
         Frame_Done := True;
         Cursor_Phase := (Cursor_Phase + 1) mod 32;
      end if;
   end End_Line;

   procedure Tick is
   begin
      if Cyc = 0 then
         Start_Line;
      end if;
      if Cyc >= 7 then
         Draw ((Cyc - 7) * 4);
      end if;

      --  timers count down (at single clock: two of these cycles each)
      for T in 1 .. 3 loop
         if Running (T) then
            if Remaining (T) <= 1 then
               Status := Status or (case T is when 1 => 16#08#,
                                               when 2 => 16#10#,
                                               when others => 16#40#);
               Remaining (T) :=
                 (if T = 1 then (if T_Start (1) = 0 then 65536 else T_Start (1))
                  else 65536) * 2;
            else
               Remaining (T) := Remaining (T) - 1;
            end if;
         end if;
      end loop;

      Snd_Div := Snd_Div + 1;
      if Snd_Div = 8 then
         Snd_Div := 0;
         Sound_Step;
      end if;
      Sample_Acc := Sample_Acc + 1.0;
      if Sample_Acc >= Float (Clock_Hz) / Float (SID.Sample_Rate) then
         Sample_Acc := Sample_Acc - Float (Clock_Hz) / Float (SID.Sample_Rate);
         Sound_Output;
      end if;

      Cyc := Cyc + 1;
      if Cyc = Cycles_Per_Line then
         Cyc := 0;
         End_Line;
      end if;
   end Tick;

   function CPU_Blocked return Boolean is
   begin
      if DMA_Line and then Cyc in 4 .. 89 then
         return True;                       --  the bad-line DMA
      elsif Bit (Regs (16#13#), 1) then
         return Cyc mod 2 = 0;              --  single clock
      elsif Fetch_On and then Cyc in 4 .. 100 then
         return Cyc mod 2 = 0;              --  single clock in the window
      else
         return Cyc in 92 | 94 | 96 | 98 | 100;   --  RAM refresh
      end if;
   end CPU_Blocked;

   ---------------------------------------------------------------------
   --  Registers
   ---------------------------------------------------------------------

   procedure Set_Standard (S : Standard_Kind) is
   begin
      Std := S;
      Lines := (if S = PAL then 312 else 262);
      Vsync_Line := (if S = PAL then 257 else 229);
      Video.First_Visible_Line := 0;
      Video.VIC_Visible_Lines := (if S = PAL then 288 else 242);
      Video.VIC_Visible_Width := Video.VIC_Width;
      Video.X_Aspect := 1.0;
   end Set_Standard;

   function Clock_Hz return Natural is
     (if Std = PAL then 1_773_447 else 1_789_772);
   function Lines_Per_Frame return Positive is (Lines);

   procedure Reset is
   begin
      Regs := (others => 0);
      Regs (16#13#) := (if ROM_Enabled then 1 else 0);
      R := 0;
      Cyc := 0;
      TV_Line := 0;
      Remaining := (others => 0);
      Running := (others => False);
      T_Start := (others => 0);
      Status := 0;
      Idle := True;
      Allow_Bad := False;
      Fetch_On := False;
      Window := False;
      DMA_Line := False;
      Ycounter := 0;
      Row_Ptr := 0;
      Next_Row_Ptr := 0;
      Cursor_Phase := 0;
      Crsr_Pos := 0;
      Count := (others => 0);
      Sign := (others => False);
      Noise_SR := 16#FF#;
   end Reset;

   function Timer_Value (T : Positive) return Natural is
     (Remaining (T) / 2);

   function Read (Reg : Natural) return Byte is
      N : constant Natural := Reg mod 64;
   begin
      case N is
         when 0 => return Byte (Timer_Value (1) mod 256);
         when 1 => return Byte ((Timer_Value (1) / 256) mod 256);
         when 2 => return Byte (Timer_Value (2) mod 256);
         when 3 => return Byte ((Timer_Value (2) / 256) mod 256);
         when 4 => return Byte (Timer_Value (3) mod 256);
         when 5 => return Byte ((Timer_Value (3) / 256) mod 256);
         when 9 =>
            return Status or 16#25# or (if IRQ then 16#80# else 0);
         when 16#0A# => return (Regs (16#0A#) and 16#5F#) or 16#A0#;
         when 16#0C# => return Regs (16#0C#) or 16#FC#;
         when 16#10# => return (Regs (16#10#) and 3) or 16#C0#;
         when 16#12# => return Regs (16#12#) or 16#C0#;
         when 16#13# =>
            return (Regs (16#13#) and 16#FE#) or (if ROM_Enabled then 1 else 0);
         when 16#15# .. 16#19# => return Regs (N) or 16#80#;
         when 16#1A# => return Byte (Shift_Right (Unsigned_16 (Next_Row_Ptr), 8)
                                      and 3) or 16#FC#;
         when 16#1B# => return Byte (Next_Row_Ptr mod 256);
         when 16#1C# => return (if R >= 256 then 16#FF# else 16#FE#);
         when 16#1D# => return Byte (R mod 256);
         when 16#1E# =>
            declare
               X : Integer := (Cyc - 16) * 4;
            begin
               if X < 0 then
                  X := X + Cycles_Per_Line * 4;
               end if;
               return Byte ((X / 2) mod 256) and 16#FE#;
            end;
         when 16#1F# =>
            return 16#80# or Byte ((Cursor_Phase mod 16) * 8) or Byte (Ycounter);
         when 16#20# .. 16#3F# => return 16#FF#;
         when others => return Regs (N);
      end case;
   end Read;

   function Register (Reg : Natural) return Byte is
     (case Reg mod 64 is
         when 9 => Status or 16#25# or (if IRQ then 16#80# else 0),
         when 16#13# => (Regs (16#13#) and 16#FE#) or
                        (if ROM_Enabled then 1 else 0),
         when 16#1C# => (if R >= 256 then 16#FF# else 16#FE#),
         when 16#1D# => Byte (R mod 256),
         when others => Regs (Reg mod 64));

   procedure Write (Reg : Natural; Value : Byte) is
      N : constant Natural := Reg mod 64;
   begin
      case N is
         when 0 | 2 | 4 =>
            --  low byte: the timer stops
            declare
               T : constant Positive := N / 2 + 1;
            begin
               T_Start (T) := (T_Start (T) / 256) * 256 + Natural (Value);
               Remaining (T) := T_Start (T) * 2;
               Running (T) := False;
            end;
         when 1 | 3 | 5 =>
            --  high byte: it starts
            declare
               T : constant Positive := N / 2 + 1;
            begin
               T_Start (T) := T_Start (T) mod 256 + 256 * Natural (Value);
               Remaining (T) :=
                 (if T_Start (T) = 0 then 65536 else T_Start (T)) * 2;
               Running (T) := True;
            end;
         when 9 =>
            Status := Status and not (Value and 16#5E#);
         when 16#0A# =>
            Regs (N) := Value and 16#5F#;
         when 16#0C# | 16#0D# =>
            Regs (N) := Value;
            Crsr_Pos := Natural (Regs (16#0C#) and 3) * 256
              + Natural (Regs (16#0D#));
         when 16#12# =>
            Regs (N) := Value and 16#3F#;
         when 16#13# =>
            Regs (N) := (Value and 16#FE#) or (Regs (N) and 1);
         when 16#15# .. 16#19# =>
            Regs (N) := Value and 16#7F#;
         when 16#1A# =>
            Next_Row_Ptr := Natural (Value and 3) * 256 + Next_Row_Ptr mod 256;
         when 16#1B# =>
            Next_Row_Ptr := (Next_Row_Ptr / 256) * 256 + Natural (Value);
         when 16#1C# =>
            R := Natural (Value and 1) * 256 + R mod 256;
         when 16#1D# =>
            R := (R / 256) * 256 + Natural (Value);
         when 16#1E# =>
            null;
         when 16#1F# =>
            Ycounter := Natural (Value and 7);
            Cursor_Phase := (Cursor_Phase / 16) * 16
              + Natural (Shift_Right (Value, 3) and 15);
         when 16#11# =>
            Regs (N) := Value;
            if Bit (Value, 7) then
               Count := (others => 0);
               Noise_SR := 16#FF#;
            end if;
         when 16#20# .. 16#3F# =>
            null;
         when others =>
            Regs (N) := Value;
      end case;
      if N = 6 and then R = 0 then
         Allow_Bad := DEN;
      end if;
   end Write;

   function Raster return Natural is (R);
   function Line_Cycle return Natural is (Cyc);

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Reg_Array'Write (S, Regs);
      Standard_Kind'Write (S, Std);
      Natural'Write (S, R); Natural'Write (S, Cyc); Natural'Write (S, TV_Line);
      Timer_Array'Write (S, Remaining); Timer_Array'Write (S, T_Start);
      for B of Running loop
         Boolean'Write (S, B);
      end loop;
      Byte'Write (S, Status);
      Buf40'Write (S, Vbuf); Buf40'Write (S, Cbuf);
      Buf40'Write (S, Cbuf_Next);
      Natural'Write (S, Ycounter); Natural'Write (S, Row_Ptr);
      Natural'Write (S, Next_Row_Ptr);
      Boolean'Write (S, Idle); Boolean'Write (S, Allow_Bad);
      Boolean'Write (S, Fetch_On); Boolean'Write (S, Window);
      Boolean'Write (S, DMA_Line);
      Natural'Write (S, Cursor_Phase); Natural'Write (S, Crsr_Pos);
      Boolean'Write (S, ROM_Enabled);
      Natural'Write (S, Snd_Div);
      for V in 1 .. 2 loop
         Natural'Write (S, Count (V));
         Boolean'Write (S, Sign (V));
      end loop;
      Unsigned_8'Write (S, Noise_SR);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Reg_Array'Read (S, Regs);
      Standard_Kind'Read (S, Std);
      Set_Standard (Std);
      Natural'Read (S, R); Natural'Read (S, Cyc); Natural'Read (S, TV_Line);
      Timer_Array'Read (S, Remaining); Timer_Array'Read (S, T_Start);
      for B of Running loop
         Boolean'Read (S, B);
      end loop;
      Byte'Read (S, Status);
      Buf40'Read (S, Vbuf); Buf40'Read (S, Cbuf);
      Buf40'Read (S, Cbuf_Next);
      Natural'Read (S, Ycounter); Natural'Read (S, Row_Ptr);
      Natural'Read (S, Next_Row_Ptr);
      Boolean'Read (S, Idle); Boolean'Read (S, Allow_Bad);
      Boolean'Read (S, Fetch_On); Boolean'Read (S, Window);
      Boolean'Read (S, DMA_Line);
      Natural'Read (S, Cursor_Phase); Natural'Read (S, Crsr_Pos);
      Boolean'Read (S, ROM_Enabled);
      Natural'Read (S, Snd_Div);
      for V in 1 .. 2 loop
         Natural'Read (S, Count (V));
         Boolean'Read (S, Sign (V));
      end loop;
      Unsigned_8'Read (S, Noise_SR);
      Cached_Char := -1;
   end Load_State;

end TED;
