with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Strings;
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
with Gtk.Label; use Gtk.Label;
with Gtk.Separator_Tool_Item; use Gtk.Separator_Tool_Item;
with Gtk.Tool_Button; use Gtk.Tool_Button;
with Gtk.Toggle_Tool_Button; use Gtk.Toggle_Tool_Button;
with Gtk.Toolbar; use Gtk.Toolbar;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Window; use Gtk.Window;
with Cairo; use Cairo;

with Types; use Types;
with Interfaces; use Interfaces;
with Video;
with Machine; use type Machine.Model_Type;
with Settings;
with Charset_Data; use type Charset_Data.Glyph;
with Screen_Data; use Screen_Data;

package body Screen_Editor is

   Scale  : constant := 2;
   Char_Px : constant := 8 * Scale;
   Margin : constant := 24;           --  border shown around the screen

   Win      : Gtk_Window := null;
   Parent_W : Gtk_Window := null;
   Canvas, Chars, Pens : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Rev_Check, Grid_Check, Live, With_Charset : Gtk_Check_Button;

   type Tool_Kind is (T_Draw, T_Color, T_Fill, T_Text, T_Pick, T_Copy,
                      T_Paste);
   Tool : Tool_Kind := T_Draw;
   Tool_Buttons : array (Tool_Kind) of Gtk_Toggle_Tool_Button;

   Cur_Code  : Byte := 81;           --  ball
   Cur_Color : Byte := 1;
   type Pen is (Char_Pen, Background_Pen, Border_Pen);
   Pen_Sel : Pen := Char_Pen;

   File     : Unbounded_String;
   Modified : Boolean := False;
   Painting : Boolean := False;
   Paint_Right : Boolean := False;
   Updating : Boolean := False;

   --  Text tool cursor (-1: none)
   Text_X, Text_Y : Integer := -1;

   --  Copy area: selection and clipboard
   Sel_X0, Sel_Y0, Sel_X1, Sel_Y1 : Integer := -1;
   type Clip_Array is array (Row_Range, Col_Range) of Cell;
   Clip : Clip_Array;
   Clip_W, Clip_H : Natural := 0;

   Max_Undo : constant := 32;
   type Undo_Entry is record
      S : Screen;
      Border, Back : Byte;
   end record;
   Undo_Stack : array (1 .. Max_Undo) of Undo_Entry;
   Undo_Count : Natural := 0;

   function Is_Open return Boolean is (Win /= null and then Win.Get_Visible);

   function Is_Screen_File (Path : String) return Boolean is
     (Path'Length > 4 and then Ada.Characters.Handling.To_Lower
        (Path (Path'Last - 3 .. Path'Last)) = ".scr");

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   function Hex2 (B : Byte) return String is
      H : constant String := "0123456789ABCDEF";
   begin
      return H (Natural (B / 16) + 1) & H (Natural (B mod 16) + 1);
   end Hex2;

   procedure Set_RGB (Cr : Cairo_Context; C : Byte) is
      P : constant Types.Pixel := Video.VIC_Palette (C and 15);
   begin
      Set_Source_Rgb (Cr, Gdouble (Shift_Right (P, 16) and 255) / 255.0,
                      Gdouble (Shift_Right (P, 8) and 255) / 255.0,
                      Gdouble (P and 255) / 255.0);
   end Set_RGB;

   procedure Ensure_Charset is
   begin
      for C in Charset_Data.Char_Code loop
         if Charset_Data.Get (C) /= (Charset_Data.Row_Range => 0) then
            return;
         end if;
      end loop;
      Charset_Data.Load_ROM (False);
   end Ensure_Charset;

   --  One character cell, as the VIC draws it in (multicolour) text mode
   procedure Draw_Char (Cr : Cairo_Context; Code, Color : Byte;
                        X0, Y0 : Gdouble; S : Gdouble) is
      G : constant Charset_Data.Glyph :=
        Charset_Data.Get (Charset_Data.Char_Code (Code));
      Multi : constant Boolean := Charset_Data.Multicolour and then Color >= 8;
   begin
      for Y in Charset_Data.Row_Range loop
         if Multi then
            for P in 0 .. 3 loop
               declare
                  V : constant Byte := Shift_Right (G (Y), 6 - 2 * P) and 3;
               begin
                  if V /= 0 then
                     Set_RGB (Cr, (case V is
                                     when 1 => Charset_Data.Multi_Color_1,
                                     when 2 => Charset_Data.Multi_Color_2,
                                     when others => Color and 7));
                     Rectangle (Cr, X0 + Gdouble (P * 2) * S,
                                Y0 + Gdouble (Y) * S, 2.0 * S, S);
                     Cairo.Fill (Cr);
                  end if;
               end;
            end loop;
         else
            for X in 0 .. 7 loop
               if (Shift_Right (G (Y), 7 - X) and 1) /= 0 then
                  Set_RGB (Cr, Color);
                  Rectangle (Cr, X0 + Gdouble (X) * S, Y0 + Gdouble (Y) * S,
                             S, S);
                  Cairo.Fill (Cr);
               end if;
            end loop;
         end if;
      end loop;
   end Draw_Char;

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   procedure Send_Charset is
   begin
      for C in Charset_Data.Char_Code loop
         for Y in Charset_Data.Row_Range loop
            Machine.Poke (16#3000# + Word (C * 8 + Y),
                          Charset_Data.Get (C) (Y));
         end loop;
      end loop;
      Machine.Monitor_Poke
        (16#D018#, (Machine.IO_Peek (16#D018#) and 16#F0#) or 16#0C#);
      Machine.Monitor_Poke
        (16#D016#, (if Charset_Data.Multicolour
                    then Machine.IO_Peek (16#D016#) or 16#10#
                    else Machine.IO_Peek (16#D016#) and not 16#10#));
      Machine.Monitor_Poke (16#D022#, Charset_Data.Multi_Color_1);
      Machine.Monitor_Poke (16#D023#, Charset_Data.Multi_Color_2);
   end Send_Charset;

   procedure Send_To_Emulator (Quiet : Boolean := False) is
      Screen_At : constant Word :=
        Word (Shift_Right (Machine.IO_Peek (16#D018#), 4)) * 16#400#;
   begin
      if Machine.Model = Machine.VIC20 then
         if not Quiet then
            Status.Set_Text ("the VIC-20 has no VIC-II: this editor works with "
                             & "the C64 and C128");
         end if;
         return;
      end if;
      if Machine.VIC_Bank_Address /= 0 then
         if not Quiet then
            Status.Set_Text ("show in emulator needs VIC bank 0 (e.g. at the "
                             & "READY prompt)");
         end if;
         return;
      end if;
      Machine.Claim_VIC;
      for Y in Row_Range loop
         for X in Col_Range loop
            Machine.Poke (Screen_At + Word (Y * 40 + X), Current (Y, X).Code);
            Machine.Monitor_Poke (16#D800# + Word (Y * 40 + X),
                                  Current (Y, X).Color);
         end loop;
      end loop;
      Machine.Monitor_Poke (16#D020#, Border_Color);
      Machine.Monitor_Poke (16#D021#, Background_Color);
      if With_Charset.Get_Active then
         Send_Charset;
      end if;
      if not Quiet then
         Status.Set_Text ("the emulator shows the screen (at $" &
                          Hex2 (Byte (Screen_At / 256)) & "00)" &
                          (if With_Charset.Get_Active
                           then " with the charset at $3000" else ""));
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
      D018 : constant Byte := Machine.IO_Peek (16#D018#);
   begin
      Load_Memory (Machine.VIC_Peek'Access,
                   Word (Shift_Right (D018, 4)) * 16#400#,
                   Machine.IO_Peek'Access, 16#D800#);
      Border_Color := Machine.IO_Peek (16#D020#) and 15;
      Background_Color := Machine.IO_Peek (16#D021#) and 15;
      Charset_Data.Load_Memory (Machine.VIC_Peek'Access,
                                Word (D018 and 16#0E#) * 16#400#);
      Charset_Data.Multicolour := (Machine.IO_Peek (16#D016#) and 16#10#) /= 0;
      Charset_Data.Background_Color := Background_Color;
      Charset_Data.Multi_Color_1 := Machine.IO_Peek (16#D022#) and 15;
      Charset_Data.Multi_Color_2 := Machine.IO_Peek (16#D023#) and 15;
      Modified := True;
      Status.Set_Text ("grabbed the screen and its charset from the emulator"
                       & (if (Machine.IO_Peek (16#D011#) and 16#20#) /= 0
                          then " (it is in bitmap mode: only text screens "
                          & "make sense here)" else ""));
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Drawing
   ---------------------------------------------------------------------

   procedure Update_Title is
   begin
      Win.Set_Title ("Screen editor - " &
                     (if File = Null_Unbounded_String then "untitled.scr"
                      else Ada.Directories.Simple_Name (To_String (File))) &
                     (if Modified then " *" else ""));
   end Update_Title;

   procedure Redraw_All is
   begin
      Canvas.Queue_Draw;
      Chars.Queue_Draw;
      Pens.Queue_Draw;
      Update_Title;
   end Redraw_All;

   procedure Changed is
   begin
      Modified := True;
      Redraw_All;
      if Live.Get_Active then
         Send_To_Emulator (Quiet => True);
      end if;
   end Changed;

   function On_Canvas_Draw (Self : access Gtk_Widget_Record'Class;
                            Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      S : constant Gdouble := Gdouble (Scale);
   begin
      Set_RGB (Cr, Border_Color);
      Paint (Cr);
      Set_RGB (Cr, Background_Color);
      Rectangle (Cr, Gdouble (Margin), Gdouble (Margin),
                 Gdouble (40 * Char_Px), Gdouble (25 * Char_Px));
      Cairo.Fill (Cr);
      for Y in Row_Range loop
         for X in Col_Range loop
            Draw_Char (Cr, Current (Y, X).Code, Current (Y, X).Color,
                       Gdouble (Margin + X * Char_Px),
                       Gdouble (Margin + Y * Char_Px), S);
         end loop;
      end loop;
      if Grid_Check.Get_Active then
         Set_Source_Rgba (Cr, 0.5, 0.5, 0.5, 0.35);
         Set_Line_Width (Cr, 1.0);
         for X in 0 .. 40 loop
            Move_To (Cr, Gdouble (Margin + X * Char_Px) + 0.5, Gdouble (Margin));
            Line_To (Cr, Gdouble (Margin + X * Char_Px) + 0.5,
                     Gdouble (Margin + 25 * Char_Px));
         end loop;
         for Y in 0 .. 25 loop
            Move_To (Cr, Gdouble (Margin), Gdouble (Margin + Y * Char_Px) + 0.5);
            Line_To (Cr, Gdouble (Margin + 40 * Char_Px),
                     Gdouble (Margin + Y * Char_Px) + 0.5);
         end loop;
         Stroke (Cr);
      end if;
      --  Text cursor
      if Tool = T_Text and then Text_X >= 0 then
         Set_Source_Rgb (Cr, 1.0, 0.3, 0.3);
         Set_Line_Width (Cr, 2.0);
         Rectangle (Cr, Gdouble (Margin + Text_X * Char_Px),
                    Gdouble (Margin + Text_Y * Char_Px),
                    Gdouble (Char_Px), Gdouble (Char_Px));
         Stroke (Cr);
      end if;
      --  Copy selection
      if Sel_X0 >= 0 then
         Set_Source_Rgb (Cr, 1.0, 1.0, 0.3);
         Set_Line_Width (Cr, 2.0);
         Rectangle (Cr,
                    Gdouble (Margin + Integer'Min (Sel_X0, Sel_X1) * Char_Px),
                    Gdouble (Margin + Integer'Min (Sel_Y0, Sel_Y1) * Char_Px),
                    Gdouble ((abs (Sel_X1 - Sel_X0) + 1) * Char_Px),
                    Gdouble ((abs (Sel_Y1 - Sel_Y0) + 1) * Char_Px));
         Stroke (Cr);
      end if;
      return True;
   end On_Canvas_Draw;

   function On_Chars_Draw (Self : access Gtk_Widget_Record'Class;
                           Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Set_RGB (Cr, Background_Color);
      Paint (Cr);
      for C in 0 .. 255 loop
         Draw_Char (Cr, Byte (C), Cur_Color, Gdouble ((C mod 16) * 18 + 1),
                    Gdouble ((C / 16) * 18 + 1), 2.0);
      end loop;
      Set_Source_Rgb (Cr, 1.0, 0.25, 0.25);
      Set_Line_Width (Cr, 2.0);
      Rectangle (Cr, Gdouble (Natural (Cur_Code) mod 16 * 18),
                 Gdouble (Natural (Cur_Code) / 16 * 18), 18.0, 18.0);
      Stroke (Cr);
      return True;
   end On_Chars_Draw;

   Pal_Y : constant := 64;

   function Pen_Value (P : Pen) return Byte is
     (case P is
        when Char_Pen => Cur_Color,
        when Background_Pen => Background_Color,
        when Border_Pen => Border_Color);

   function On_Pens_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      Names : constant array (Pen) of access constant String :=
        (new String'("character"), new String'("background"),
         new String'("border"));
   begin
      Select_Font_Face (Cr, "Sans", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 11.0);
      for P in Pen loop
         declare
            X : constant Gdouble := 4.0 + Gdouble (Pen'Pos (P)) * 82.0;
         begin
            Set_RGB (Cr, Pen_Value (P));
            Rectangle (Cr, X, 4.0, 74.0, 30.0);
            Cairo.Fill (Cr);
            if P = Pen_Sel then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 3.0);
               Rectangle (Cr, X - 1.5, 2.5, 77.0, 33.0);
               Stroke (Cr);
            end if;
            Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
            Move_To (Cr, X, 48.0);
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
            if C = Pen_Value (Pen_Sel) then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 2.0);
               Rectangle (Cr, X - 1.0, Y - 1.0, 28.0, 28.0);
               Stroke (Cr);
            end if;
         end;
      end loop;
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
      Undo_Stack (Undo_Count) := (Current, Border_Color, Background_Color);
   end Push_Undo;

   procedure Undo is
   begin
      if Undo_Count = 0 then
         Status.Set_Text ("nothing to undo");
         return;
      end if;
      Current := Undo_Stack (Undo_Count).S;
      Border_Color := Undo_Stack (Undo_Count).Border;
      Background_Color := Undo_Stack (Undo_Count).Back;
      Undo_Count := Undo_Count - 1;
      Changed;
   end Undo;

   function Draw_Code return Byte is
     (if Rev_Check.Get_Active then Cur_Code or 16#80# else Cur_Code);

   procedure Cell_At (EX, EY : Gdouble; X, Y : out Integer) is
   begin
      X := Integer (Gdouble'Floor ((EX - Gdouble (Margin)) / Gdouble (Char_Px)));
      Y := Integer (Gdouble'Floor ((EY - Gdouble (Margin)) / Gdouble (Char_Px)));
   end Cell_At;

   procedure Set_Tool (T : Tool_Kind) is
   begin
      Tool := T;
      Updating := True;
      for K in Tool_Kind loop
         Tool_Buttons (K).Set_Active (K = T);
      end loop;
      Updating := False;
      if T /= T_Copy then
         Sel_X0 := -1;
      end if;
      Status.Set_Text
        (case T is
           when T_Draw => "draw: left button places the character, right " &
                          "button a space",
           when T_Color => "colour: changes only the colour of cells",
           when T_Fill => "fill: replaces the area of equal cells",
           when T_Text => "text: click where to type, then type " &
                          "(lower case = letters; Return, Backspace, arrows)",
           when T_Pick => "pick: click a cell to take its character and colour",
           when T_Copy => "copy area: drag a rectangle",
           when T_Paste => (if Clip_W = 0 then "paste: copy an area first"
                            else "paste: click to place the copied area (" &
                              Img (Clip_W) & " x " & Img (Clip_H) & ")"));
      Redraw_All;
   end Set_Tool;

   procedure Apply_At (X, Y : Integer; First : Boolean) is
   begin
      if X not in Col_Range or else Y not in Row_Range then
         return;
      end if;
      case Tool is
         when T_Draw =>
            Current (Y, X) := (if Paint_Right then (32, Current (Y, X).Color)
                               else (Draw_Code, Cur_Color));
            Changed;
         when T_Color =>
            Current (Y, X).Color := Cur_Color;
            Changed;
         when T_Fill =>
            if First then
               Flood_Fill (X, Y, (Draw_Code, Cur_Color));
               Changed;
            end if;
         when T_Text =>
            if First then
               Text_X := X;
               Text_Y := Y;
               Redraw_All;
            end if;
         when T_Pick =>
            if First then
               Cur_Code := Current (Y, X).Code and 16#7F#;
               Updating := True;
               Rev_Check.Set_Active (Current (Y, X).Code >= 16#80#);
               Updating := False;
               Cur_Color := Current (Y, X).Color;
               Set_Tool (T_Draw);
               Status.Set_Text ("picked character $" &
                                Hex2 (Current (Y, X).Code) & ", colour" &
                                Cur_Color'Image);
            end if;
         when T_Copy =>
            if First then
               Sel_X0 := X;
               Sel_Y0 := Y;
            end if;
            Sel_X1 := X;
            Sel_Y1 := Y;
            Redraw_All;
         when T_Paste =>
            if First and then Clip_W > 0 then
               for CY in 0 .. Clip_H - 1 loop
                  for CX in 0 .. Clip_W - 1 loop
                     if X + CX in Col_Range and then Y + CY in Row_Range then
                        Current (Y + CY, X + CX) := Clip (CY, CX);
                     end if;
                  end loop;
               end loop;
               Changed;
            end if;
      end case;
   end Apply_At;

   procedure Finish_Copy is
      X0 : constant Integer := Integer'Min (Sel_X0, Sel_X1);
      Y0 : constant Integer := Integer'Min (Sel_Y0, Sel_Y1);
   begin
      if Sel_X0 < 0 then
         return;
      end if;
      Clip_W := abs (Sel_X1 - Sel_X0) + 1;
      Clip_H := abs (Sel_Y1 - Sel_Y0) + 1;
      for CY in 0 .. Clip_H - 1 loop
         for CX in 0 .. Clip_W - 1 loop
            Clip (CY, CX) := Current (Y0 + CY, X0 + CX);
         end loop;
      end loop;
      Status.Set_Text ("copied " & Img (Clip_W) & " x " & Img (Clip_H) &
                       " cells; choose Paste and click to place them");
   end Finish_Copy;

   function On_Canvas_Press (Self : access Gtk_Widget_Record'Class;
                             Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      X, Y : Integer;
   begin
      Cell_At (Event.X, Event.Y, X, Y);
      if X not in Col_Range or else Y not in Row_Range then
         return True;
      end if;
      if Tool in T_Draw | T_Color | T_Fill | T_Paste then
         Push_Undo;
      end if;
      Painting := True;
      Paint_Right := Event.Button = 3;
      Apply_At (X, Y, True);
      return True;
   end On_Canvas_Press;

   function On_Canvas_Release (Self : access Gtk_Widget_Record'Class;
                               Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Painting := False;
      if Tool = T_Copy then
         Finish_Copy;
      end if;
      return True;
   end On_Canvas_Release;

   function On_Canvas_Motion (Self : access Gtk_Widget_Record'Class;
                              Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
      X, Y : Integer;
   begin
      Cell_At (Event.X, Event.Y, X, Y);
      if X in Col_Range and then Y in Row_Range then
         if Painting and then Tool in T_Draw | T_Color | T_Copy then
            Apply_At (X, Y, False);
         elsif not Painting then
            Status.Set_Text ("column" & X'Image & ", row" & Y'Image &
                             ": character $" & Hex2 (Current (Y, X).Code) &
                             ", colour" & Current (Y, X).Color'Image &
                             " ($" & Hex2 (Byte ((16#0400# + Y * 40 + X) / 256))
                             & Hex2 (Byte ((16#0400# + Y * 40 + X) mod 256)) &
                             ")");
         end if;
      end if;
      return True;
   end On_Canvas_Motion;

   function On_Chars_Press (Self : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      CX : constant Integer := Integer (Gdouble'Floor (Event.X / 18.0));
      CY : constant Integer := Integer (Gdouble'Floor (Event.Y / 18.0));
   begin
      if CX in 0 .. 15 and then CY in 0 .. 15 then
         Cur_Code := Byte (CY * 16 + CX);
         if Tool not in T_Draw | T_Fill | T_Text then
            Set_Tool (T_Draw);
         end if;
         Redraw_All;
      end if;
      return True;
   end On_Chars_Press;

   function On_Pens_Press (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
   begin
      if Event.Y < 40.0 then
         for P in Pen loop
            if Event.X >= 4.0 + Gdouble (Pen'Pos (P)) * 82.0
              and then Event.X < 78.0 + Gdouble (Pen'Pos (P)) * 82.0
            then
               Pen_Sel := P;
            end if;
         end loop;
      elsif Event.Y >= Gdouble (Pal_Y) then
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
                     when Char_Pen => Cur_Color := C;
                     when Background_Pen =>
                        Push_Undo;
                        Background_Color := C;
                        Charset_Data.Background_Color := C;
                        Changed;
                     when Border_Pen =>
                        Push_Undo;
                        Border_Color := C;
                        Changed;
                  end case;
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
      Last : constant String :=
        Settings.Get ("forge_dir", Settings.Get ("studio_dir", ""));
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
      Screen_Data.Load (Path, Ok);
      if Ok then
         File := To_Unbounded_String (Path);
         Modified := False;
         Undo_Count := 0;
         Status.Set_Text ("loaded " & Path);
      else
         Status.Set_Text ("cannot read " & Path & " (1000, 2000 or 2002 bytes)");
      end if;
      Redraw_All;
   end Load_File;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
   begin
      if Ask or else File = Null_Unbounded_String then
         declare
            P : constant String :=
              Choose ("Save screen", True, "*.scr", "screen.scr");
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String (P);
         end;
      end if;
      Screen_Data.Save (To_String (File), Ok);
      if Ok then
         Modified := False;
         Status.Set_Text ("saved " & To_String (File) & " (2002 bytes)");
      else
         Status.Set_Text ("cannot write " & To_String (File));
      end if;
      Update_Title;
   end Save_File;

   procedure Export is
      Base : constant String :=
        (if File = Null_Unbounded_String then "screen"
         else Ada.Directories.Base_Name (To_String (File)));
      P : constant String :=
        Choose ("Export screen as assembly source", True, "*.asm",
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
      Screen_Data.Export_Source (P, Label, Ok);
      Status.Set_Text (if Ok then "exported to " & P & " (" & Label &
                         "_chars, " & Label & "_colors)"
                       else "cannot write " & P);
   end Export;

   ---------------------------------------------------------------------
   --  Actions
   ---------------------------------------------------------------------

   type Action is (A_New, A_Open, A_Save, A_Save_As, A_Export, A_Undo,
                   A_ROM_Upper, A_ROM_Lower, A_Show, A_Grab);
   Action_Buttons : array (Action) of Gtk_Tool_Button;

   procedure Do_Action (A : Action) is
   begin
      case A is
         when A_New =>
            Push_Undo;
            Clear (32, Cur_Color);
            File := Null_Unbounded_String;
            Changed;
            Modified := False;
            Update_Title;
         when A_Open =>
            declare
               P : constant String := Choose ("Open screen", False, "*.scr",
                                              "");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Save => Save_File (False);
         when A_Save_As => Save_File (True);
         when A_Export => Export;
         when A_Undo => Undo;
         when A_ROM_Upper | A_ROM_Lower =>
            Charset_Data.Load_ROM (A = A_ROM_Lower);
            Charset_Data.Multicolour := False;
            Changed;
            Status.Set_Text ("the charset (shared with the charset editor) is "
                             & "now the ROM " &
                             (if A = A_ROM_Lower then "lower case" else
                                "upper case/graphics") & " set");
         when A_Show =>
            Send_To_Emulator;
            if Parent_W /= null then
               Parent_W.Present;
            end if;
         when A_Grab =>
            Push_Undo;
            Grab_From_Emulator;
            Redraw_All;
      end case;
   end Do_Action;

   procedure On_Action (Item : access Gtk_Tool_Button_Record'Class) is
   begin
      for A in Action loop
         if Gtk_Tool_Button (Item) = Action_Buttons (A) then
            Do_Action (A);
            return;
         end if;
      end loop;
   end On_Action;

   procedure On_Tool (Item : access Gtk_Toggle_Tool_Button_Record'Class) is
   begin
      if Updating then
         return;
      end if;
      for K in Tool_Kind loop
         if Gtk_Toggle_Tool_Button (Item) = Tool_Buttons (K) then
            Set_Tool (K);
            return;
         end if;
      end loop;
   end On_Tool;

   procedure On_Option (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Updating then
         return;
      end if;
      if Gtk_Check_Button (Self) = Live and then Live.Get_Active then
         Send_To_Emulator;
      end if;
      Redraw_All;
   end On_Option;

   procedure Type_Char (Code : Byte) is
   begin
      if Text_X < 0 then
         return;
      end if;
      Push_Undo;
      Current (Text_Y, Text_X) :=
        ((if Rev_Check.Get_Active then Code or 16#80# else Code), Cur_Color);
      Text_X := Text_X + 1;
      if Text_X > Col_Range'Last then
         Text_X := 0;
         Text_Y := (Text_Y + 1) mod Rows;
      end if;
      Changed;
   end Type_Char;

   function On_Key (Self : access Gtk_Widget_Record'Class;
                    Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self);
      Ctrl : constant Boolean := (Event.State and Control_Mask) /= 0;
      K : constant Gdk_Key_Type := Event.Keyval;
   begin
      if Ctrl and then K = GDK_LC_z then
         Undo;
      elsif Ctrl and then K = GDK_LC_s then
         Save_File (False);
      elsif Tool = T_Text and then Text_X >= 0 and then not Ctrl then
         if K in 32 .. 126 then
            Type_Char (Screen_Code (Character'Val (K)));
         elsif K = GDK_BackSpace then
            if Text_X > 0 then
               Text_X := Text_X - 1;
               Push_Undo;
               Current (Text_Y, Text_X).Code := 32;
               Changed;
            end if;
         elsif K = GDK_Return then
            Text_X := 0;
            Text_Y := (Text_Y + 1) mod Rows;
            Redraw_All;
         elsif K = GDK_Left then
            Text_X := Integer'Max (0, Text_X - 1);
            Redraw_All;
         elsif K = GDK_Right then
            Text_X := Integer'Min (Col_Range'Last, Text_X + 1);
            Redraw_All;
         elsif K = GDK_Up then
            Text_Y := Integer'Max (0, Text_Y - 1);
            Redraw_All;
         elsif K = GDK_Down then
            Text_Y := Integer'Min (Row_Range'Last, Text_Y + 1);
            Redraw_All;
         elsif K = GDK_Escape then
            Text_X := -1;
            Redraw_All;
         else
            return False;
         end if;
      elsif K = GDK_LC_r and then not Ctrl then
         Rev_Check.Set_Active (not Rev_Check.Get_Active);
      elsif K = GDK_LC_g and then not Ctrl then
         Grid_Check.Set_Active (not Grid_Check.Get_Active);
      else
         return False;
      end if;
      return True;
   end On_Key;

   function On_Focus (Self : access Gtk_Widget_Record'Class;
                      Event : Gdk_Event_Focus) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Redraw_All;          --  the charset may have changed in its editor
      return False;
   end On_Focus;

   function On_Delete (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if File /= Null_Unbounded_String then
         Settings.Set ("screen_file", To_String (File));
      end if;
      Win.Hide;
      return True;
   end On_Delete;

   procedure Build is
      VBox, HBox, Right, Row : Gtk_Box;
      Tools : Gtk_Toolbar;
      Frame : Gtk_Frame;

      procedure Act (Label : String; A : Action; Tip : String;
                     Icon : String := "") is
      begin
         Gtk_New (Action_Buttons (A), Label => Label);
         if Icon /= "" then
            Action_Buttons (A).Set_Icon_Name (Icon);
         end if;
         Action_Buttons (A).Set_Tooltip_Text (Tip);
         Action_Buttons (A).Set_Is_Important (True);
         Action_Buttons (A).On_Clicked (On_Action'Access);
         Tools.Insert (Action_Buttons (A));
      end Act;

      procedure Tool_Btn (Label : String; K : Tool_Kind; Tip : String) is
      begin
         Gtk_New (Tool_Buttons (K));
         Tool_Buttons (K).Set_Label (Label);
         Tool_Buttons (K).Set_Tooltip_Text (Tip);
         Tool_Buttons (K).Set_Is_Important (True);
         Tool_Buttons (K).On_Toggled (On_Tool'Access);
         Tools.Insert (Tool_Buttons (K));
      end Tool_Btn;

      procedure Sep is
         S : Gtk_Separator_Tool_Item;
      begin
         Gtk_New (S);
         Tools.Insert (S);
      end Sep;

      function Area (W, H : Gint) return Gtk_Drawing_Area is
         A : Gtk_Drawing_Area;
      begin
         Gtk_New (A);
         A.Set_Size_Request (W, H);
         A.Add_Events (Button_Press_Mask or Button_Release_Mask
                       or Button_Motion_Mask or Pointer_Motion_Mask);
         return A;
      end Area;

      procedure Check (C : out Gtk_Check_Button; Label, Tip : String;
                       On : Boolean := False) is
      begin
         Gtk_New (C, Label);
         C.Set_Tooltip_Text (Tip);
         C.Set_Active (On);
         C.On_Toggled (On_Option'Access);
         Row.Pack_Start (C, Expand => False, Fill => False);
      end Check;
   begin
      Gtk_New (Win);
      Win.Set_Default_Size (1060, 640);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Win.On_Focus_In_Event (On_Focus'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Act ("New", A_New, "Clear the screen", "document-new");
      Act ("Open", A_Open, "Open a .scr file", "document-open");
      Act ("Save", A_Save, "Save (Ctrl+S)", "document-save");
      Act ("Save as", A_Save_As, "Save under a new name");
      Act ("Export .asm", A_Export, "Write the screen as ACME source");
      Act ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      Sep;
      Act ("ROM upper", A_ROM_Upper,
           "Use the ROM charset (upper case and graphics)");
      Act ("ROM lower", A_ROM_Lower, "Use the ROM lower-case charset");
      Sep;
      Act ("Show in emulator", A_Show,
           "Put the screen on the emulator's display (needs VIC bank 0, " &
           "e.g. at READY)");
      Act ("Grab from emulator", A_Grab,
           "Take the running program's text screen and charset");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Text);
      Tool_Btn ("Draw", T_Draw, "Draw characters (right button: space)");
      Tool_Btn ("Colour", T_Color, "Paint colours only");
      Tool_Btn ("Fill", T_Fill, "Flood fill");
      Tool_Btn ("Text", T_Text, "Click and type");
      Tool_Btn ("Pick", T_Pick, "Take character and colour from a cell");
      Tool_Btn ("Copy area", T_Copy, "Drag a rectangle to copy it");
      Tool_Btn ("Paste area", T_Paste, "Click to place the copied rectangle");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 8);
      VBox.Pack_Start (HBox, Expand => False, Fill => False);

      Canvas := Area (40 * Char_Px + 2 * Margin, 25 * Char_Px + 2 * Margin);
      Canvas.On_Draw (On_Canvas_Draw'Access);
      Canvas.On_Button_Press_Event (On_Canvas_Press'Access);
      Canvas.On_Button_Release_Event (On_Canvas_Release'Access);
      Canvas.On_Motion_Notify_Event (On_Canvas_Motion'Access);
      Gtk_New (Frame, "Screen");
      Frame.Add (Canvas);
      Frame.Set_Valign (Align_Start);
      HBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 6);

      Gtk_New_Vbox (Right, Spacing => 6);
      HBox.Pack_Start (Right, Expand => True, Fill => True);
      Chars := Area (16 * 18 + 2, 16 * 18 + 2);
      Chars.On_Draw (On_Chars_Draw'Access);
      Chars.On_Button_Press_Event (On_Chars_Press'Access);
      Gtk_New (Frame, "Characters (from the charset editor)");
      Frame.Add (Chars);
      Frame.Set_Halign (Align_Start);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Pens := Area (250, 128);
      Pens.On_Draw (On_Pens_Draw'Access);
      Pens.On_Button_Press_Event (On_Pens_Press'Access);
      Gtk_New (Frame, "Colours");
      Frame.Add (Pens);
      Frame.Set_Halign (Align_Start);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New_Hbox (Row, Spacing => 8);
      Check (Rev_Check, "Reverse (R)", "Draw / type reversed characters");
      Check (Grid_Check, "Grid (G)", "Show the character grid");
      Right.Pack_Start (Row, Expand => False, Fill => False);
      Gtk_New_Hbox (Row, Spacing => 8);
      Check (Live, "Live in emulator", "Send every change to the emulator");
      Check (With_Charset, "with charset",
             "Also send the charset (to $3000)", On => True);
      Right.Pack_Start (Row, Expand => False, Fill => False);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      VBox.Pack_Start (Status, Expand => False, Fill => False);
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
   begin
      Parent_W := Parent;
      Ensure_Charset;
      if Win = null then
         Build;
         Win.Show_All;
         Set_Tool (T_Draw);
         declare
            Last : constant String := Settings.Get ("screen_file", "");
         begin
            if File = "" and then Last /= ""
              and then Ada.Directories.Exists (Last)
            then
               Load_File (Last);
            end if;
         end;
      end if;
      if File /= "" then
         if Ada.Directories.Exists (File) then
            Load_File (Ada.Directories.Full_Name (File));
         else
            Clear;
            Screen_Editor.File := To_Unbounded_String (File);
         end if;
      end if;
      Redraw_All;
      Win.Show_All;
      Win.Present;
   end Open;

end Screen_Editor;
