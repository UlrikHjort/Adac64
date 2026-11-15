-- ***************************************************************************
--                      AdaC64 - Charset_Editor
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

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Characters.Handling;
with Ada.Directories;

with Glib; use Glib;
with Gdk.Event; use Gdk.Event;
with Gdk.Types; use Gdk.Types;
with Gdk.Types.Keysyms; use Gdk.Types.Keysyms;
with Gtk.Box; use Gtk.Box;
with Gtk.Check_Button; use Gtk.Check_Button;
with Gtk.Toggle_Button; use Gtk.Toggle_Button;
with Gtk.Dialog; use Gtk.Dialog;
with Gtk.Drawing_Area; use Gtk.Drawing_Area;
with Gtk.Enums; use Gtk.Enums;
with Gtk.File_Chooser;
with Gtk.File_Chooser_Dialog; use Gtk.File_Chooser_Dialog;
with Gtk.File_Filter; use Gtk.File_Filter;
with Gtk.Frame; use Gtk.Frame;
with Gtk.GEntry; use Gtk.GEntry;
with Gtk.Label; use Gtk.Label;
with Gtk.Separator_Tool_Item; use Gtk.Separator_Tool_Item;
with Gtk.Tool_Button; use Gtk.Tool_Button;
with Gtk.Toolbar; use Gtk.Toolbar;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Window; use Gtk.Window;
with Cairo; use Cairo;

with Types; use Types;
with Interfaces; use Interfaces;
with Video;
with Machine; use type Machine.Model_Type;
with Settings;
with Charset_Data; use Charset_Data;

package body Charset_Editor is

   Cell : constant := 40;           --  editor pixel size
   Set_Scale : constant := 2;       --  charset overview: 16 x 16 per char

   Win      : Gtk_Window := null;
   Parent_W : Gtk_Window := null;
   Grid, Pens, Overview, Text_Area : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Multi_Check, Live : Gtk_Check_Button;
   Sample   : Gtk_Entry;

   Current  : Char_Code := 1;
   Pen_Sel  : Pen := Char_Color;
   File     : Unbounded_String;
   Modified : Boolean := False;
   Painting : Boolean := False;
   Paint_Pen : Pen := Char_Color;
   Clip     : Glyph := (others => 0);
   Updating : Boolean := False;

   Max_Undo : constant := 64;
   type Undo_Entry is record
      Code : Char_Code := 0;
      G    : Glyph := (others => 0);
   end record;
   Undo_Stack : array (1 .. Max_Undo) of Undo_Entry;
   Undo_Count : Natural := 0;

   function Is_Open return Boolean is (Win /= null and then Win.Get_Visible);

   function Is_Charset_File (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
   begin
      return L'Length > 4 and then
        (L (L'Last - 3 .. L'Last) = ".chr" or else
         L (L'Last - 3 .. L'Last) = ".64c");
   end Is_Charset_File;

   function Hex2 (N : Natural) return String is
      H : constant String := "0123456789ABCDEF";
   begin
      return H (N / 16 mod 16 + 1) & H (N mod 16 + 1);
   end Hex2;

   procedure Set_RGB (Cr : Cairo_Context; C : Byte) is
      P : constant Types.Pixel := Video.VIC_Palette (C and 15);
   begin
      Set_Source_Rgb (Cr, Gdouble (Shift_Right (P, 16) and 255) / 255.0,
                      Gdouble (Shift_Right (P, 8) and 255) / 255.0,
                      Gdouble (P and 255) / 255.0);
   end Set_RGB;

   --  In multicolour mode only colours 0-7 are possible for a character
   function Shown_Char_Color return Byte is
     (if Multicolour then Text_Color and 7 else Text_Color);

   function Pen_Color (P : Pen) return Byte is
     (case P is
        when Background => Background_Color,
        when Char_Color => Shown_Char_Color,
        when Multi_1 => Multi_Color_1,
        when Multi_2 => Multi_Color_2);

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   Show_Addr : constant Word := 16#3000#;

   procedure Send_Glyph (C : Char_Code) is
      G : constant Glyph := Get (C);
   begin
      for Y in Row_Range loop
         Machine.Poke (Show_Addr + Word (C * 8 + Y), G (Y));
      end loop;
   end Send_Glyph;

   function Is_TED return Boolean is
     (Machine.Model in Machine.Plus4 | Machine.C16);

   --  C16 / Plus/4: the charset into RAM at $3000 for the TED ($FF12 bit 2
   --  = RAM, $FF13 = $30), the colours mapped to the nearest TED colours
   procedure Send_To_TED (Quiet : Boolean) is
      Matrix : constant Word :=
        Word (Machine.IO_Peek (16#FF14#) and 16#F8#) * 256;
      FF07 : constant Byte := Machine.IO_Peek (16#FF07#);
   begin
      for C in Char_Code loop
         Send_Glyph (C);
      end loop;
      Machine.Monitor_Poke (16#FF12#, Machine.IO_Peek (16#FF12#) and 16#3B#);
      Machine.Monitor_Poke (16#FF13#,
                            16#30# or (Machine.IO_Peek (16#FF13#) and 2));
      Machine.Monitor_Poke
        (16#FF07#, (if Multicolour then FF07 or 16#90# else FF07 or 16#80#)
                     and (if Multicolour then 16#FF# else 16#EF#));
      Machine.Monitor_Poke (16#FF15#, Video.To_TED (Background_Color));
      Machine.Monitor_Poke (16#FF16#, Video.To_TED (Multi_Color_1));
      Machine.Monitor_Poke (16#FF17#, Video.To_TED (Multi_Color_2));
      for I in 0 .. 999 loop
         Machine.Poke
           (Matrix + Word (I),
            (if Multicolour then (Video.To_TED (Text_Color and 7) and 16#77#)
                                 or 8
             else Video.To_TED (Text_Color)));
      end loop;
      if not Quiet then
         Status.Set_Text ("the emulator's screen now uses this charset " &
                          "(at $3000: $FF12 bit 2 = 0, $FF13 = $30; " &
                          "256 characters)");
      end if;
   end Send_To_TED;

   procedure Send_To_Emulator (Quiet : Boolean := False) is
      D016 : constant Byte := Machine.IO_Peek (16#D016#);
   begin
      if Is_TED then
         Send_To_TED (Quiet);
         return;
      end if;
      if Machine.Model not in Machine.C64 | Machine.C128 then
         if not Quiet then
            Status.Set_Text ("the VIC-20 has no VIC-II: this editor works "
                             & "with the C64, C128, C16 and Plus/4");
         end if;
         return;
      end if;
      if Machine.VIC_Bank_Address /= 0 then
         if not Quiet then
            Status.Set_Text ("show in emulator needs VIC bank 0 (e.g. at the"
                             & " READY prompt)");
         end if;
         return;
      end if;
      Machine.Claim_VIC;
      for C in Char_Code loop
         Send_Glyph (C);
      end loop;
      Machine.Monitor_Poke
        (16#D018#, (Machine.IO_Peek (16#D018#) and 16#F0#) or 16#0C#);
      Machine.Monitor_Poke
        (16#D016#, (if Multicolour then D016 or 16#10#
                    else D016 and not 16#10#));
      Machine.Monitor_Poke (16#D021#, Background_Color);
      Machine.Monitor_Poke (16#D022#, Multi_Color_1);
      Machine.Monitor_Poke (16#D023#, Multi_Color_2);
      for I in 0 .. 999 loop
         Machine.Monitor_Poke
           (16#D800# + Word (I),
            (if Multicolour then 8 or (Text_Color and 7) else Text_Color));
      end loop;
      if not Quiet then
         Status.Set_Text ("the emulator's screen now uses this charset " &
                          "(at $3000, $D018 bits 1-3 = 6)");
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
      Offset : constant Word :=
        Word (Machine.IO_Peek (16#D018#) and 16#0E#) * 16#400#;
   begin
      if Is_TED then
         declare
            Base : constant Word :=
              Word (Machine.IO_Peek (16#FF13#) and 16#F8#) * 256;
         begin
            Load_TED_Charset (Machine.TED_Char_Peek'Access,
                              Machine.IO_Peek (16#FF06#),
                              Machine.IO_Peek (16#FF07#),
                              Machine.IO_Peek (16#FF13#));
            Multicolour := (Machine.IO_Peek (16#FF07#) and 16#10#) /= 0;
            Background_Color := Video.From_TED (Machine.IO_Peek (16#FF15#));
            Multi_Color_1 := Video.From_TED (Machine.IO_Peek (16#FF16#));
            Multi_Color_2 := Video.From_TED (Machine.IO_Peek (16#FF17#));
            Modified := True;
            Undo_Count := 0;
            Status.Set_Text ("grabbed the charset at $" &
                             Hex2 (Natural (Base) / 256) & "00" &
                             (if (Machine.IO_Peek (16#FF12#) and 4) /= 0
                              then " (ROM)" else "") &
                             (if Multicolour then " (multicolour)" else "") &
                             "; colours mapped to the nearest C64 ones");
         end;
         return;
      end if;
      Load_Memory (Machine.VIC_Peek'Access, Offset);
      Multicolour := (Machine.IO_Peek (16#D016#) and 16#10#) /= 0;
      Background_Color := Machine.IO_Peek (16#D021#) and 15;
      Multi_Color_1 := Machine.IO_Peek (16#D022#) and 15;
      Multi_Color_2 := Machine.IO_Peek (16#D023#) and 15;
      Modified := True;
      Undo_Count := 0;
      Status.Set_Text ("grabbed the charset at $" &
                       Hex2 (Natural (Machine.VIC_Bank_Address + Offset) / 256)
                       & "00" & (if Multicolour then " (multicolour)" else ""));
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Drawing
   ---------------------------------------------------------------------

   procedure Update_Title is
   begin
      Win.Set_Title ("Charset editor - " &
                     (if File = Null_Unbounded_String then "untitled.chr"
                      else Ada.Directories.Simple_Name (To_String (File))) &
                     (if Modified then " *" else "") &
                     "  (character" & Current'Image & " = $" &
                     Hex2 (Current) & ")");
   end Update_Title;

   procedure Redraw_All is
   begin
      Updating := True;
      Multi_Check.Set_Active (Multicolour);
      Updating := False;
      Grid.Queue_Draw;
      Pens.Queue_Draw;
      Overview.Queue_Draw;
      Text_Area.Queue_Draw;
      Update_Title;
   end Redraw_All;

   procedure Changed is
   begin
      Modified := True;
      Redraw_All;
      if Live.Get_Active and then Machine.VIC_Bank_Address = 0 then
         Send_Glyph (Current);
      end if;
   end Changed;

   procedure Draw_Glyph (Cr : Cairo_Context; G : Glyph; X0, Y0, S : Gdouble)
   is
   begin
      for Y in Row_Range loop
         for X in Row_Range loop
            declare
               P : constant Pen := Charset_Data.Pixel (G, X, Y);
            begin
               if P /= Background then
                  Set_RGB (Cr, Pen_Color (P));
                  Rectangle (Cr, X0 + Gdouble (X) * S, Y0 + Gdouble (Y) * S,
                             S, S);
                  Cairo.Fill (Cr);
               end if;
            end;
         end loop;
      end loop;
   end Draw_Glyph;

   function On_Grid_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      Step : constant Natural := (if Multicolour then 2 else 1);
   begin
      Set_RGB (Cr, Background_Color);
      Paint (Cr);
      Draw_Glyph (Cr, Get (Current), 0.0, 0.0, Gdouble (Cell));
      Set_Line_Width (Cr, 1.0);
      Set_Source_Rgba (Cr, 0.0, 0.0, 0.0, 0.3);
      for I in 0 .. 8 loop
         if I mod Step = 0 then
            Move_To (Cr, Gdouble (I * Cell) + 0.5, 0.0);
            Line_To (Cr, Gdouble (I * Cell) + 0.5, Gdouble (8 * Cell));
         end if;
         Move_To (Cr, 0.0, Gdouble (I * Cell) + 0.5);
         Line_To (Cr, Gdouble (8 * Cell), Gdouble (I * Cell) + 0.5);
      end loop;
      Stroke (Cr);
      return True;
   end On_Grid_Draw;

   function On_Overview_Draw (Self : access Gtk_Widget_Record'Class;
                              Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      S : constant Gdouble := Gdouble (Set_Scale);
   begin
      Set_RGB (Cr, Background_Color);
      Paint (Cr);
      for C in Char_Code loop
         Draw_Glyph (Cr, Get (C), Gdouble ((C mod 32) * 8 * Set_Scale),
                     Gdouble ((C / 32) * 8 * Set_Scale), S);
      end loop;
      Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
      Set_Line_Width (Cr, 2.0);
      Rectangle (Cr, Gdouble ((Current mod 32) * 8 * Set_Scale) - 1.0,
                 Gdouble ((Current / 32) * 8 * Set_Scale) - 1.0,
                 Gdouble (8 * Set_Scale) + 2.0, Gdouble (8 * Set_Scale) + 2.0);
      Stroke (Cr);
      return True;
   end On_Overview_Draw;

   --  ASCII to screen codes (upper/graphics set; lower case for the
   --  lower-case set)
   function Screen_Code (C : Character) return Char_Code is
      P : constant Natural := Character'Pos (C);
   begin
      case C is
         when 'a' .. 'z' => return P - 96;
         when 'A' .. 'Z' => return P;         --  shifted letters
         when '@' | '[' .. '_' => return P - 64;
         when ' ' .. '?' => return P;
         when others => return 32;
      end case;
   end Screen_Code;

   function On_Text_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      T : constant String := Sample.Get_Text;
      Row : constant String := "abcdefghijklmnopqrstuvwxyz0123456789";
   begin
      Set_RGB (Cr, Background_Color);
      Paint (Cr);
      for I in T'Range loop
         exit when I - T'First >= 40;
         Draw_Glyph (Cr, Get (Screen_Code (T (I))),
                     4.0 + Gdouble ((I - T'First) * 16), 4.0, 2.0);
      end loop;
      for I in Row'Range loop
         Draw_Glyph (Cr, Get (Screen_Code (Row (I))),
                     4.0 + Gdouble ((I - Row'First) * 16), 24.0, 2.0);
      end loop;
      --  the current character tiled (to check how it joins up)
      for TY in 0 .. 2 loop
         for TX in 0 .. 7 loop
            Draw_Glyph (Cr, Get (Current), 4.0 + Gdouble (TX * 16),
                        48.0 + Gdouble (TY * 16), 2.0);
         end loop;
      end loop;
      return True;
   end On_Text_Draw;

   Pen_Y : constant := 4;
   Pal_Y : constant := 64;

   function On_Pens_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      Names : constant array (Pen) of access constant String :=
        (new String'("1 bg"), new String'("2 char"), new String'("3 $d022"),
         new String'("4 $d023"));
      Order : constant array (0 .. 3) of Pen :=
        (Background, Char_Color, Multi_1, Multi_2);
   begin
      Select_Font_Face (Cr, "Sans", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 11.0);
      for I in Order'Range loop
         declare
            P : constant Pen := Order (I);
            X : constant Gdouble := 4.0 + Gdouble (I) * 64.0;
         begin
            Set_RGB (Cr, Pen_Color (P));
            Rectangle (Cr, X, Gdouble (Pen_Y), 56.0, 32.0);
            Cairo.Fill (Cr);
            if P = Pen_Sel then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 3.0);
               Rectangle (Cr, X - 1.5, Gdouble (Pen_Y) - 1.5, 59.0, 35.0);
               Stroke (Cr);
            end if;
            if Multicolour or else P in Background | Char_Color then
               Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
            else
               Set_Source_Rgb (Cr, 0.55, 0.55, 0.55);
            end if;
            Move_To (Cr, X, Gdouble (Pen_Y) + 48.0);
            Show_Text (Cr, Names (P).all);
         end;
      end loop;
      for C in Byte range 0 .. 15 loop
         declare
            X : constant Gdouble := 4.0 + Gdouble (C mod 8) * 30.0;
            Y : constant Gdouble := Gdouble (Pal_Y) + Gdouble (C / 8) * 30.0;
         begin
            Set_RGB (Cr, C);
            Rectangle (Cr, X, Y, 26.0, 26.0);
            Cairo.Fill (Cr);
            if C = Pen_Color (Pen_Sel) then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 2.0);
               Rectangle (Cr, X - 1.0, Y - 1.0, 28.0, 28.0);
               Stroke (Cr);
            end if;
         end;
      end loop;
      Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
      Move_To (Cr, 4.0, Gdouble (Pal_Y) + 72.0);
      Show_Text (Cr, (if Multicolour then
                        "multicolour: the character colour can be 0-7"
                      else "click a colour to give it to the selected pen"));
      return True;
   end On_Pens_Draw;

   ---------------------------------------------------------------------
   --  Editing
   ---------------------------------------------------------------------

   procedure Push_Undo is
   begin
      if Undo_Count = Max_Undo then
         Undo_Stack (1 .. Max_Undo - 1) := Undo_Stack (2 .. Max_Undo);
         Undo_Count := Max_Undo - 1;
      end if;
      Undo_Count := Undo_Count + 1;
      Undo_Stack (Undo_Count) := (Current, Get (Current));
   end Push_Undo;

   procedure Undo is
   begin
      if Undo_Count = 0 then
         Status.Set_Text ("nothing to undo");
         return;
      end if;
      Current := Undo_Stack (Undo_Count).Code;
      Put (Current, Undo_Stack (Undo_Count).G);
      Undo_Count := Undo_Count - 1;
      Changed;
   end Undo;

   type Glyph_Op is access procedure (G : in out Glyph);
   procedure Apply (Op : Glyph_Op) is
      G : Glyph := Get (Current);
   begin
      Push_Undo;
      Op (G);
      Put (Current, G);
      Changed;
   end Apply;

   procedure Paint_At (X, Y : Gdouble; Fill_Area : Boolean) is
      PX : constant Integer := Integer (Gdouble'Floor (X / Gdouble (Cell)));
      PY : constant Integer := Integer (Gdouble'Floor (Y / Gdouble (Cell)));
      G : Glyph := Get (Current);
      P : Pen := Paint_Pen;
   begin
      if PX not in Row_Range or else PY not in Row_Range then
         return;
      end if;
      if not Multicolour and then P in Multi_1 | Multi_2 then
         P := Char_Color;
      end if;
      if Fill_Area then
         Flood_Fill (G, PX, PY, P);
      elsif Charset_Data.Pixel (G, PX, PY) = P then
         return;
      else
         Set_Pixel (G, PX, PY, P);
      end if;
      Put (Current, G);
      Changed;
   end Paint_At;

   function On_Grid_Press (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
   begin
      Push_Undo;
      Paint_Pen := (if Event.Button = 3 then Background else Pen_Sel);
      Painting := True;
      Paint_At (Event.X, Event.Y, (Event.State and Shift_Mask) /= 0);
      return True;
   end On_Grid_Press;

   function On_Grid_Release (Self : access Gtk_Widget_Record'Class;
                             Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Painting := False;
      return True;
   end On_Grid_Release;

   function On_Grid_Motion (Self : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
   begin
      if Painting then
         Paint_At (Event.X, Event.Y, False);
      end if;
      return True;
   end On_Grid_Motion;

   function On_Overview_Press (Self : access Gtk_Widget_Record'Class;
                               Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      CX : constant Integer :=
        Integer (Gdouble'Floor (Event.X / Gdouble (8 * Set_Scale)));
      CY : constant Integer :=
        Integer (Gdouble'Floor (Event.Y / Gdouble (8 * Set_Scale)));
   begin
      if CX in 0 .. 31 and then CY in 0 .. 7 then
         Current := CY * 32 + CX;
         Redraw_All;
      end if;
      return True;
   end On_Overview_Press;

   function On_Pens_Press (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      Order : constant array (0 .. 3) of Pen :=
        (Background, Char_Color, Multi_1, Multi_2);
   begin
      if Event.Y < Gdouble (Pen_Y + 36) then
         for I in Order'Range loop
            if Event.X >= 4.0 + Gdouble (I) * 64.0
              and then Event.X < 60.0 + Gdouble (I) * 64.0
            then
               Pen_Sel := Order (I);
            end if;
         end loop;
      elsif Event.Y >= Gdouble (Pal_Y) and then Event.Y < Gdouble (Pal_Y) + 60.0
      then
         declare
            Col : constant Integer :=
              Integer (Gdouble'Floor ((Event.X - 4.0) / 30.0));
            Row : constant Integer :=
              Integer (Gdouble'Floor ((Event.Y - Gdouble (Pal_Y)) / 30.0));
         begin
            if Col in 0 .. 7 and then Row in 0 .. 1 then
               declare
                  C : constant Byte := Byte (Row * 8 + Col);
               begin
                  case Pen_Sel is
                     when Background => Background_Color := C;
                     when Char_Color => Charset_Data.Text_Color := C;
                     when Multi_1 => Multi_Color_1 := C;
                     when Multi_2 => Multi_Color_2 := C;
                  end case;
                  if Live.Get_Active then
                     Send_To_Emulator (Quiet => True);
                  end if;
               end;
            end if;
         end;
      end if;
      Redraw_All;
      return True;
   end On_Pens_Press;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   function Choose (Title : String; Save : Boolean; Pattern : String;
                    Name : String) return String is
      Dlg : Gtk_File_Chooser_Dialog;
      W : Gtk_Widget;
      F : Gtk_File_Filter;
      R : Unbounded_String;
      pragma Unreferenced (W);
      Last : constant String := Settings.Get ("forge_dir", Settings.Get ("studio_dir", ""));
   begin
      Gtk_New (Dlg, Title, Win,
               (if Save then Gtk.File_Chooser.Action_Save
                else Gtk.File_Chooser.Action_Open));
      W := Dlg.Add_Button ("_Cancel", Gtk_Response_Cancel);
      W := Dlg.Add_Button ((if Save then "_Save" else "_Open"),
                           Gtk_Response_Accept);
      Gtk_New (F);
      F.Set_Name (Pattern);
      F.Add_Pattern (Pattern);
      if Pattern = "*.chr" then
         F.Add_Pattern ("*.64c");
         F.Add_Pattern ("*.bin");
      end if;
      Gtk.File_Chooser.Add_Filter (+Dlg, F);
      if Save then
         Gtk.File_Chooser.Set_Do_Overwrite_Confirmation (+Dlg, True);
         Gtk.File_Chooser.Set_Current_Name (+Dlg, Name);
      end if;
      if Last /= "" then
         declare
            Dummy : constant Boolean :=
              Gtk.File_Chooser.Set_Current_Folder (+Dlg, Last);
         begin
            null;
         end;
      end if;
      if Dlg.Run = Gtk_Response_Accept then
         R := To_Unbounded_String (Gtk.File_Chooser.Get_Filename (+Dlg));
         Settings.Set ("forge_dir",
                       Ada.Directories.Containing_Directory (To_String (R)));
      end if;
      Dlg.Destroy;
      return To_String (R);
   end Choose;

   procedure Load_File (Path : String) is
      Ok : Boolean;
   begin
      Charset_Data.Load (Path, Ok);
      if Ok then
         File := To_Unbounded_String (Path);
         Modified := False;
         Undo_Count := 0;
         Status.Set_Text ("loaded" & Count'Image & " characters from " & Path);
      else
         Status.Set_Text ("cannot read " & Path);
      end if;
      Redraw_All;
   end Load_File;

   procedure Save_Colors is
   begin
      Settings.Set ("charset_bg", Integer (Background_Color));
      Settings.Set ("charset_mc1", Integer (Multi_Color_1));
      Settings.Set ("charset_mc2", Integer (Multi_Color_2));
      Settings.Set ("charset_fg", Integer (Charset_Data.Text_Color));
      Settings.Set ("charset_multi", Multicolour);
   end Save_Colors;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
   begin
      if Ask or else File = Null_Unbounded_String then
         declare
            P : constant String :=
              Choose ("Save charset", True, "*.chr", "charset.chr");
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String (P);
         end;
      end if;
      Charset_Data.Save (To_String (File), Ok, Count);
      Save_Colors;
      if Ok then
         Modified := False;
         Status.Set_Text ("saved" & Count'Image & " characters to " &
                          To_String (File));
      else
         Status.Set_Text ("cannot write " & To_String (File));
      end if;
      Update_Title;
   end Save_File;

   procedure Export is
      Base : constant String :=
        (if File = Null_Unbounded_String then "charset"
         else Ada.Directories.Base_Name (To_String (File)));
      P : constant String :=
        Choose ("Export charset as assembly source", True, "*.asm",
                Base & ".asm");
      Ok : Boolean;
      Label : String := Base;
   begin
      if P = "" then
         return;
      end if;
      for C of Label loop
         if not (Ada.Characters.Handling.Is_Alphanumeric (C) or else C = '_')
         then
            C := '_';
         end if;
      end loop;
      Charset_Data.Export_Source (P, Label, Ok, Count);
      Status.Set_Text (if Ok then "exported to " & P else "cannot write " & P);
   end Export;

   ---------------------------------------------------------------------
   --  Actions
   ---------------------------------------------------------------------

   type Action is
     (A_New, A_ROM_Upper, A_ROM_Lower, A_Open, A_Save, A_Save_As, A_Export,
      A_Copy, A_Paste, A_Undo,
      A_Clear, A_Invert, A_Mirror_X, A_Mirror_Y, A_Rotate,
      A_Left, A_Right, A_Up, A_Down, A_Show, A_Grab);

   procedure Op_Clear (G : in out Glyph) is
   begin
      G := (others => 0);
   end Op_Clear;
   procedure Op_Invert (G : in out Glyph) is
   begin
      Invert (G);
   end Op_Invert;
   procedure Op_Mirror_X (G : in out Glyph) is
   begin
      Mirror_X (G);
   end Op_Mirror_X;
   procedure Op_Mirror_Y (G : in out Glyph) is
   begin
      Mirror_Y (G);
   end Op_Mirror_Y;
   procedure Op_Rotate (G : in out Glyph) is
   begin
      Rotate (G);
   end Op_Rotate;
   procedure Op_Left (G : in out Glyph) is
   begin
      Shift (G, -1, 0);
   end Op_Left;
   procedure Op_Right (G : in out Glyph) is
   begin
      Shift (G, 1, 0);
   end Op_Right;
   procedure Op_Up (G : in out Glyph) is
   begin
      Shift (G, 0, -1);
   end Op_Up;
   procedure Op_Down (G : in out Glyph) is
   begin
      Shift (G, 0, 1);
   end Op_Down;

   procedure Whole_Set_Changed (Msg : String) is
   begin
      Undo_Count := 0;
      Modified := True;
      Status.Set_Text (Msg);
      Redraw_All;
      if Live.Get_Active then
         Send_To_Emulator (Quiet => True);
      end if;
   end Whole_Set_Changed;

   procedure Do_Action (A : Action) is
   begin
      case A is
         when A_New =>
            Clear_All;
            File := Null_Unbounded_String;
            Whole_Set_Changed ("empty charset");
            Modified := False;
         when A_ROM_Upper =>
            Load_ROM (False);
            Whole_Set_Changed ("copied the ROM charset (upper case/graphics)");
         when A_ROM_Lower =>
            Load_ROM (True);
            Whole_Set_Changed ("copied the ROM charset (lower/upper case)");
         when A_Open =>
            declare
               P : constant String := Choose ("Open charset", False, "*.chr",
                                              "");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Save => Save_File (False);
         when A_Save_As => Save_File (True);
         when A_Export => Export;
         when A_Copy =>
            Clip := Get (Current);
            Status.Set_Text ("copied character" & Current'Image);
         when A_Paste =>
            Push_Undo;
            Put (Current, Clip);
            Changed;
         when A_Undo => Undo;
         when A_Clear => Apply (Op_Clear'Access);
         when A_Invert => Apply (Op_Invert'Access);
         when A_Mirror_X => Apply (Op_Mirror_X'Access);
         when A_Mirror_Y => Apply (Op_Mirror_Y'Access);
         when A_Rotate => Apply (Op_Rotate'Access);
         when A_Left => Apply (Op_Left'Access);
         when A_Right => Apply (Op_Right'Access);
         when A_Up => Apply (Op_Up'Access);
         when A_Down => Apply (Op_Down'Access);
         when A_Show =>
            Send_To_Emulator;
            if Parent_W /= null then
               Parent_W.Present;
            end if;
         when A_Grab =>
            Grab_From_Emulator;
            Redraw_All;
      end case;
   end Do_Action;

   Tool_Items : array (Action) of Gtk_Tool_Button;

   procedure On_Tool (Item : access Gtk_Tool_Button_Record'Class) is
   begin
      for A in Action loop
         if Gtk_Tool_Button (Item) = Tool_Items (A) then
            Do_Action (A);
            return;
         end if;
      end loop;
   end On_Tool;

   procedure On_Multi (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Updating or else Multicolour = Self.Get_Active then
         return;
      end if;
      Multicolour := Self.Get_Active;
      if not Multicolour and then Pen_Sel in Multi_1 | Multi_2 then
         Pen_Sel := Char_Color;
      end if;
      Redraw_All;
      if Live.Get_Active then
         Send_To_Emulator (Quiet => True);
      end if;
   end On_Multi;

   procedure On_Live (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Self.Get_Active then
         Send_To_Emulator;
      end if;
   end On_Live;

   function On_Sample (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Text_Area.Queue_Draw;
      return False;
   end On_Sample;

   function On_Key (Self : access Gtk_Widget_Record'Class;
                    Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self);
      Ctrl : constant Boolean := (Event.State and Control_Mask) /= 0;
      K : constant Gdk_Key_Type := Event.Keyval;
   begin
      if Sample.Has_Focus then
         return False;      --  typing into the text preview
      end if;
      if Ctrl and then K = GDK_LC_z then
         Undo;
      elsif Ctrl and then K = GDK_LC_c then
         Do_Action (A_Copy);
      elsif Ctrl and then K = GDK_LC_v then
         Do_Action (A_Paste);
      elsif Ctrl and then K = GDK_LC_s then
         Save_File (False);
      elsif K = GDK_Left or else K = GDK_Page_Up then
         Current := (Current - 1) mod 256;
         Redraw_All;
      elsif K = GDK_Right or else K = GDK_Page_Down then
         Current := (Current + 1) mod 256;
         Redraw_All;
      elsif K = GDK_Up then
         Current := (Current - 32) mod 256;
         Redraw_All;
      elsif K = GDK_Down then
         Current := (Current + 32) mod 256;
         Redraw_All;
      elsif K = GDK_LC_m then
         Multi_Check.Set_Active (not Multi_Check.Get_Active);
      elsif K in GDK_1 .. GDK_4 then
         Pen_Sel := (case K - GDK_1 is
                       when 0 => Background, when 1 => Char_Color,
                       when 2 => Multi_1, when others => Multi_2);
         Redraw_All;
      else
         return False;
      end if;
      return True;
   end On_Key;

   function On_Delete (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Save_Colors;
      if File /= Null_Unbounded_String then
         Settings.Set ("charset_file", To_String (File));
      end if;
      Win.Hide;
      return True;
   end On_Delete;

   procedure Build is
      VBox, HBox, Right, Row : Gtk_Box;
      Tools : Gtk_Toolbar;
      Frame : Gtk_Frame;

      procedure Tool (Label : String; A : Action; Tip : String;
                      Icon : String := "") is
      begin
         Gtk_New (Tool_Items (A), Label => Label);
         if Icon /= "" then
            Tool_Items (A).Set_Icon_Name (Icon);
         end if;
         Tool_Items (A).Set_Tooltip_Text (Tip);
         Tool_Items (A).Set_Is_Important (True);
         Tool_Items (A).On_Clicked (On_Tool'Access);
         Tools.Insert (Tool_Items (A));
      end Tool;

      procedure Sep is
         S : Gtk_Separator_Tool_Item;
      begin
         Gtk_New (S);
         Tools.Insert (S);
      end Sep;

      function Area (W, H : Gint; Clicks : Boolean := True)
                     return Gtk_Drawing_Area is
         A : Gtk_Drawing_Area;
      begin
         Gtk_New (A);
         A.Set_Size_Request (W, H);
         if Clicks then
            A.Add_Events (Button_Press_Mask or Button_Release_Mask
                          or Button_Motion_Mask);
         end if;
         return A;
      end Area;
   begin
      Gtk_New (Win);
      Win.Set_Default_Size (1000, 760);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Tool ("New", A_New, "Empty charset", "document-new");
      Tool ("ROM", A_ROM_Upper, "Start from the C64 character ROM " &
            "(upper case and graphics)");
      Tool ("ROM lower", A_ROM_Lower, "Start from the lower-case ROM charset");
      Tool ("Open", A_Open, "Open a .chr file", "document-open");
      Tool ("Save", A_Save, "Save (Ctrl+S)", "document-save");
      Tool ("Save as", A_Save_As, "Save under a new name");
      Tool ("Export .asm", A_Export, "Write the charset as ACME source");
      Sep;
      Tool ("Copy", A_Copy, "Copy the character (Ctrl+C)");
      Tool ("Paste", A_Paste, "Paste into this character (Ctrl+V)");
      Tool ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Text);
      Tool ("Clear", A_Clear, "Clear the character");
      Tool ("Invert", A_Invert, "Invert (reverse)");
      Tool ("Flip H", A_Mirror_X, "Mirror left-right");
      Tool ("Flip V", A_Mirror_Y, "Mirror top-bottom");
      Tool ("Rotate", A_Rotate, "Rotate 90 degrees clockwise");
      Tool ("Shift <", A_Left, "Scroll left (wraps)");
      Tool ("Shift >", A_Right, "Scroll right (wraps)");
      Tool ("Shift ^", A_Up, "Scroll up (wraps)");
      Tool ("Shift v", A_Down, "Scroll down (wraps)");
      Sep;
      Tool ("Show in emulator", A_Show,
            "Make the emulator's text screen use this charset (at $3000; " &
            "needs VIC bank 0, e.g. at READY)");
      Tool ("Grab from emulator", A_Grab,
            "Copy the charset the VIC is using in the running program");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 8);
      VBox.Pack_Start (HBox, Expand => False, Fill => False);

      Grid := Area (8 * Cell + 1, 8 * Cell + 1);
      Grid.On_Draw (On_Grid_Draw'Access);
      Grid.On_Button_Press_Event (On_Grid_Press'Access);
      Grid.On_Button_Release_Event (On_Grid_Release'Access);
      Grid.On_Motion_Notify_Event (On_Grid_Motion'Access);
      Gtk_New (Frame, "Character (left: draw, right: erase, shift: fill)");
      Frame.Add (Grid);
      Frame.Set_Valign (Align_Start);
      HBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 6);

      Gtk_New_Vbox (Right, Spacing => 6);
      HBox.Pack_Start (Right, Expand => True, Fill => True);
      Pens := Area (270, 145);
      Pens.On_Draw (On_Pens_Draw'Access);
      Pens.On_Button_Press_Event (On_Pens_Press'Access);
      Gtk_New (Frame, "Pens (keys 1-4) and colours");
      Frame.Add (Pens);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New_Hbox (Row, Spacing => 8);
      Gtk_New (Multi_Check, "Multicolour (M)");
      Multi_Check.On_Toggled (On_Multi'Access);
      Row.Pack_Start (Multi_Check, Expand => False, Fill => False);
      Gtk_New (Live, "Live in emulator");
      Live.Set_Tooltip_Text ("Send every change to the emulator's screen");
      Live.On_Toggled (On_Live'Access);
      Row.Pack_Start (Live, Expand => False, Fill => False);
      Right.Pack_Start (Row, Expand => False, Fill => False);

      Gtk_New (Sample);
      Sample.Set_Text ("hello, world! 0123456789");
      Sample.Set_Tooltip_Text ("Text shown with the charset (lower case = " &
                               "normal letters)");
      Sample.On_Key_Release_Event (On_Sample'Access);
      Text_Area := Area (40 * 16 + 8, 100, Clicks => False);
      Text_Area.On_Draw (On_Text_Draw'Access);
      declare
         Box : Gtk_Box;
      begin
         Gtk_New_Vbox (Box);
         Box.Pack_Start (Sample, Expand => False, Fill => False);
         Box.Pack_Start (Text_Area, Expand => False, Fill => False);
         Gtk_New (Frame, "Text preview");
         Frame.Add (Box);
      end;
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Overview := Area (32 * 8 * Set_Scale, 8 * 8 * Set_Scale);
      Overview.On_Draw (On_Overview_Draw'Access);
      Overview.On_Button_Press_Event (On_Overview_Press'Access);
      Gtk_New (Frame, "Charset (click a character; cursor keys move)");
      Frame.Add (Overview);
      Frame.Set_Halign (Align_Start);
      VBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 6);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      VBox.Pack_Start (Status, Expand => False, Fill => False);

      Background_Color := Byte (Settings.Get ("charset_bg", 6) mod 16);
      Multi_Color_1 := Byte (Settings.Get ("charset_mc1", 11) mod 16);
      Multi_Color_2 := Byte (Settings.Get ("charset_mc2", 12) mod 16);
      Charset_Data.Text_Color := Byte (Settings.Get ("charset_fg", 14) mod 16);
      Multicolour := Settings.Get ("charset_multi", False);
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
   begin
      Parent_W := Parent;
      if Win = null then
         Build;
         Win.Show_All;
         declare
            Last : constant String := Settings.Get ("charset_file", "");
         begin
            if File = "" and then Last /= ""
              and then Ada.Directories.Exists (Last)
            then
               Load_File (Last);
            elsif File = "" then
               Load_ROM (False);     --  start from the ROM characters
            end if;
         end;
         Status.Set_Text ("click a character below to edit it; " &
                          "ROM / ROM lower start from the built-in charset");
      end if;
      if File /= "" then
         if Ada.Directories.Exists (File) then
            Load_File (Ada.Directories.Full_Name (File));
         else
            Load_ROM (False);
            Charset_Editor.File := To_Unbounded_String (File);
         end if;
      end if;
      Redraw_All;
      Win.Show_All;
      Win.Present;
   end Open;

end Charset_Editor;
