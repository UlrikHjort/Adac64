-- ***************************************************************************
--                      AdaC64 - Bitmap_Editor
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
with Ada.Strings.Fixed;
with Ada.Strings;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Directories;
with System;

with Glib; use Glib;
with Glib.Error; use Glib.Error;
with Gdk.Event; use Gdk.Event;
with Gdk.Types; use Gdk.Types;
with Gdk.Types.Keysyms; use Gdk.Types.Keysyms;
with Gdk.Pixbuf; use Gdk.Pixbuf;
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
with Cairo.Image_Surface;
with Pango.Layout;
with Cairo.Surface;
with Cairo.Pattern;
with Cairo.Png;

with Types; use Types;
with Interfaces; use Interfaces;
with Video;
with Machine; use type Machine.Model_Type;
with Settings;
with Bitmap_Data; use Bitmap_Data;

package body Bitmap_Editor is

   Margin : constant := 16;
   Scale  : Positive := 2;

   Win      : Gtk_Window := null;
   Parent_W : Gtk_Window := null;
   Canvas, Pens : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Grid_Check, Live, Dither, Large : Gtk_Check_Button;
   Surface  : Cairo_Surface := Null_Surface;

   type Tool_Kind is (T_Pencil, T_Line, T_Fill, T_Pick);
   Tool : Tool_Kind := T_Pencil;
   Tool_Buttons : array (Tool_Kind) of Gtk_Toggle_Tool_Button;
   Mode_Buttons : array (Mode_Kind) of Gtk_Toggle_Tool_Button;

   Left_Color  : Byte := 1;
   Right_Color : Byte := 0;
   type Pen_Target is (Pen_Background, Pen_Border);
   File     : Unbounded_String;
   Modified : Boolean := False;
   Painting : Boolean := False;
   Paint_Color : Byte := 1;
   Line_X0, Line_Y0, Line_X1, Line_Y1 : Integer := -1;
   Updating : Boolean := False;
   Clashes  : Natural := 0;

   Max_Undo : constant := 24;
   type Snapshot is record
      M : Mode_Kind;
      B : Byte_Array (0 .. 7999);
      S, C : Byte_Array (0 .. 999);
      Back, Bord : Byte;
   end record;
   type Snapshot_Access is access Snapshot;
   Undo_Stack : array (1 .. Max_Undo) of Snapshot_Access;
   Undo_Count : Natural := 0;

   function Is_Open return Boolean is (Win /= null and then Win.Get_Visible);

   function Is_Bitmap_File (Path : String) return Boolean is
      L : constant String := To_Lower (Path);
      function Ends (E : String) return Boolean is
        (L'Length > E'Length and then L (L'Last - E'Length + 1 .. L'Last) = E);
   begin
      return Ends (".kla") or else Ends (".koa") or else Ends (".art")
        or else Ends (".dd");
   end Is_Bitmap_File;

   function Is_Image_File (Path : String) return Boolean is
      L : constant String := To_Lower (Path);
      function Ends (E : String) return Boolean is
        (L'Length > E'Length and then L (L'Last - E'Length + 1 .. L'Last) = E);
   begin
      return Ends (".png") or else Ends (".jpg") or else Ends (".jpeg")
        or else Ends (".gif") or else Ends (".bmp");
   end Is_Image_File;

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   procedure Set_RGB (Cr : Cairo_Context; C : Byte) is
      P : constant Types.Pixel := Video.VIC_Palette (C and 15);
   begin
      Set_Source_Rgb (Cr, Gdouble (Shift_Right (P, 16) and 255) / 255.0,
                      Gdouble (Shift_Right (P, 8) and 255) / 255.0,
                      Gdouble (P and 255) / 255.0);
   end Set_RGB;

   ---------------------------------------------------------------------
   --  Rendering into a 320 x 200 surface
   ---------------------------------------------------------------------

   procedure Update_Surface is
      Pic : Image;
   begin
      if Surface = Null_Surface then
         Surface := Cairo.Image_Surface.Create
           (Cairo.Image_Surface.Cairo_Format_RGB24, 320, 200);
      end if;
      Render (Pic);
      Cairo.Surface.Flush (Surface);
      declare
         Stride : constant Natural := Natural (Cairo.Image_Surface.Get_Stride (Surface)) / 4;
         type Pixels is array (0 .. 199, 0 .. Stride - 1) of Types.Pixel;
         Dst : Pixels;
         for Dst'Address use Cairo.Image_Surface.Get_Data_Generic (Surface);
         pragma Import (Ada, Dst);
      begin
         for Y in 0 .. 199 loop
            for X in 0 .. 319 loop
               Dst (Y, X) := Video.VIC_Palette (Pic (Y, X));
            end loop;
         end loop;
      end;
      Cairo.Surface.Mark_Dirty (Surface);
   end Update_Surface;

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   procedure Send_To_Emulator (Quiet : Boolean := False) is
   begin
      if Machine.Model not in Machine.C64 | Machine.C128 then
         if not Quiet then
            Status.Set_Text ("the " & (if Machine.Model = Machine.VIC20
                                       then "VIC-20" else "C16 / Plus/4")
                             & " has no VIC-II: this editor works with "
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
      for I in Bitmap'Range loop
         Machine.Poke (16#2000# + Word (I), Bitmap (I));
      end loop;
      for I in Screen'Range loop
         Machine.Poke (16#0400# + Word (I), Screen (I));
         Machine.Monitor_Poke (16#D800# + Word (I), Colors (I));
      end loop;
      Machine.Monitor_Poke (16#D011#, 16#3B#);
      Machine.Monitor_Poke (16#D016#,
                            (if Mode = Multicolour then 16#18# else 16#08#));
      Machine.Monitor_Poke (16#D018#, 16#18#);
      Machine.Monitor_Poke (16#D020#, Border);
      Machine.Monitor_Poke (16#D021#, Background);
      if not Quiet then
         Status.Set_Text ("the emulator shows the picture (bitmap $2000, " &
                          "screen $0400); RUN/STOP + RESTORE gets the text " &
                          "screen back");
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
      D011 : constant Byte := Machine.IO_Peek (16#D011#);
      D018 : constant Byte := Machine.IO_Peek (16#D018#);
   begin
      if (D011 and 16#20#) = 0 then
         Status.Set_Text ("the emulator is not in bitmap mode ($D011 bit 5)");
         return;
      end if;
      Load_Memory (Machine.VIC_Peek'Access,
                   Word (D018 and 16#08#) * 16#400#,
                   Word (Shift_Right (D018, 4)) * 16#400#,
                   Machine.IO_Peek'Access);
      Modified := True;
      Status.Set_Text ("grabbed a " & (if Mode = Hires then "hires" else
                         "multicolour") & " picture from the emulator");
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Redrawing
   ---------------------------------------------------------------------

   procedure Update_Title is
   begin
      Win.Set_Title ("Bitmap editor - " &
                     (if File = Null_Unbounded_String then "untitled"
                      else Ada.Directories.Simple_Name (To_String (File))) &
                     (if Modified then " *" else "") & "  (" &
                     (if Mode = Hires then "hires 320 x 200"
                      else "multicolour 160 x 200") & ")");
   end Update_Title;

   procedure Sync_Modes is
   begin
      Updating := True;
      for M in Mode_Kind loop
         Mode_Buttons (M).Set_Active (M = Mode);
      end loop;
      for T in Tool_Kind loop
         Tool_Buttons (T).Set_Active (T = Tool);
      end loop;
      Updating := False;
   end Sync_Modes;

   procedure Redraw_All is
   begin
      Update_Surface;
      Sync_Modes;
      Canvas.Queue_Draw;
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

   procedure Resize_Canvas is
   begin
      Canvas.Set_Size_Request (Gint (320 * Scale + 2 * Margin),
                               Gint (200 * Scale + 2 * Margin));
   end Resize_Canvas;

   function On_Canvas_Draw (Self : access Gtk_Widget_Record'Class;
                            Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      S : constant Gdouble := Gdouble (Scale);
   begin
      Set_RGB (Cr, Border);
      Paint (Cr);
      Save (Cr);
      Translate (Cr, Gdouble (Margin), Gdouble (Margin));
      Cairo.Scale (Cr, S, S);
      Set_Source_Surface (Cr, Surface, 0.0, 0.0);
      Cairo.Pattern.Set_Filter (Get_Source (Cr), Cairo.Pattern.Cairo_Filter_Nearest);
      Rectangle (Cr, 0.0, 0.0, 320.0, 200.0);
      Cairo.Fill (Cr);
      Restore (Cr);
      if Grid_Check.Get_Active then
         Set_Source_Rgba (Cr, 0.5, 0.5, 0.5, 0.4);
         Set_Line_Width (Cr, 1.0);
         for X in 0 .. 40 loop
            Move_To (Cr, Gdouble (Margin + X * 8 * Scale) + 0.5,
                     Gdouble (Margin));
            Line_To (Cr, Gdouble (Margin + X * 8 * Scale) + 0.5,
                     Gdouble (Margin + 200 * Scale));
         end loop;
         for Y in 0 .. 25 loop
            Move_To (Cr, Gdouble (Margin),
                     Gdouble (Margin + Y * 8 * Scale) + 0.5);
            Line_To (Cr, Gdouble (Margin + 320 * Scale),
                     Gdouble (Margin + Y * 8 * Scale) + 0.5);
         end loop;
         Stroke (Cr);
      end if;
      if Tool = T_Line and then Line_X0 >= 0 then
         declare
            PW : constant Gdouble :=
              Gdouble (Scale * (if Mode = Hires then 1 else 2));
         begin
            Set_Source_Rgba (Cr, 1.0, 0.3, 0.3, 0.8);
            Set_Line_Width (Cr, 1.5);
            Move_To (Cr, Gdouble (Margin) + (Gdouble (Line_X0) + 0.5) * PW,
                     Gdouble (Margin) + (Gdouble (Line_Y0) + 0.5) * S);
            Line_To (Cr, Gdouble (Margin) + (Gdouble (Line_X1) + 0.5) * PW,
                     Gdouble (Margin) + (Gdouble (Line_Y1) + 0.5) * S);
            Stroke (Cr);
         end;
      end if;
      return True;
   end On_Canvas_Draw;

   Pal_Y : constant := 70;

   function On_Pens_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      procedure Swatch (X : Gdouble; C : Byte; Label : String) is
      begin
         Set_RGB (Cr, C);
         Rectangle (Cr, X, 4.0, 60.0, 30.0);
         Cairo.Fill (Cr);
         Set_Source_Rgb (Cr, 0.4, 0.4, 0.4);
         Set_Line_Width (Cr, 1.0);
         Rectangle (Cr, X + 0.5, 4.5, 59.0, 29.0);
         Stroke (Cr);
         Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
         Move_To (Cr, X, 48.0);
         Show_Text (Cr, Label);
      end Swatch;
   begin
      Select_Font_Face (Cr, "Sans", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 11.0);
      Swatch (4.0, Left_Color, "left");
      Swatch (70.0, Right_Color, "right");
      Swatch (146.0, Background, (if Mode = Multicolour then "background"
                                  else "(background)"));
      Swatch (222.0, Border, "border");
      for C in Byte range 0 .. 15 loop
         declare
            X : constant Gdouble := 4.0 + Gdouble (C mod 8) * 34.0;
            Y : constant Gdouble := Gdouble (Pal_Y) + Gdouble (C / 8) * 34.0;
         begin
            Set_RGB (Cr, C);
            Rectangle (Cr, X, Y, 30.0, 30.0);
            Cairo.Fill (Cr);
            if C = Left_Color or else C = Right_Color then
               Set_Source_Rgb (Cr, 1.0, 0.25, 0.25);
               Set_Line_Width (Cr, 2.0);
               Rectangle (Cr, X - 1.0, Y - 1.0, 32.0, 32.0);
               Stroke (Cr);
            end if;
         end;
      end loop;
      Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
      Move_To (Cr, 4.0, Gdouble (Pal_Y) + 82.0);
      Show_Text (Cr, "palette: left / right click picks the pen colour;");
      Move_To (Cr, 4.0, Gdouble (Pal_Y) + 96.0);
      Show_Text (Cr, "click background / border, then a colour, to set them");
      return True;
   end On_Pens_Draw;

   ---------------------------------------------------------------------
   --  Editing
   ---------------------------------------------------------------------

   procedure Push_Undo is
      S : Snapshot_Access;
   begin
      if Undo_Count = Max_Undo then
         S := Undo_Stack (1);
         Undo_Stack (1 .. Max_Undo - 1) := Undo_Stack (2 .. Max_Undo);
         Undo_Count := Max_Undo - 1;
      else
         S := Undo_Stack (Undo_Count + 1);
         if S = null then
            S := new Snapshot;
         end if;
      end if;
      S.all := (Mode, Bitmap, Screen, Colors, Background, Border);
      Undo_Count := Undo_Count + 1;
      Undo_Stack (Undo_Count) := S;
   end Push_Undo;

   procedure Undo is
   begin
      if Undo_Count = 0 then
         Status.Set_Text ("nothing to undo");
         return;
      end if;
      declare
         S : constant Snapshot_Access := Undo_Stack (Undo_Count);
      begin
         Mode := S.M;
         Bitmap := S.B;
         Screen := S.S;
         Colors := S.C;
         Background := S.Back;
         Border := S.Bord;
      end;
      Undo_Count := Undo_Count - 1;
      Changed;
   end Undo;

   procedure Pixel_At (EX, EY : Gdouble; X, Y : out Integer) is
      PW : constant Positive := Scale * (if Mode = Hires then 1 else 2);
   begin
      X := Integer (Gdouble'Floor ((EX - Gdouble (Margin)) / Gdouble (PW)));
      Y := Integer (Gdouble'Floor ((EY - Gdouble (Margin)) / Gdouble (Scale)));
   end Pixel_At;

   procedure Plot (X, Y : Integer) is
      Clash : Boolean;
   begin
      if X in 0 .. Width - 1 and then Y in 0 .. Height - 1 then
         Set_Pixel (X, Y, Paint_Color, Clash);
         if Clash then
            Clashes := Clashes + 1;
         end if;
      end if;
   end Plot;

   procedure Draw_Line (X0, Y0, X1, Y1 : Integer) is
      DX : constant Integer := abs (X1 - X0);
      DY : constant Integer := -abs (Y1 - Y0);
      SX : constant Integer := (if X0 < X1 then 1 else -1);
      SY : constant Integer := (if Y0 < Y1 then 1 else -1);
      E  : Integer := DX + DY;
      X  : Integer := X0;
      Y  : Integer := Y0;
   begin
      loop
         Plot (X, Y);
         exit when X = X1 and then Y = Y1;
         if 2 * E >= DY then
            E := E + DY;
            X := X + SX;
         end if;
         if 2 * E <= DX then
            E := E + DX;
            Y := Y + SY;
         end if;
      end loop;
   end Draw_Line;

   procedure Report_Clashes is
   begin
      if Clashes > 0 then
         Status.Set_Text ("colour clash: a cell had no room for the colour, " &
                          "so its least-used colour was replaced (" &
                          Img (Clashes) & "x)");
      end if;
   end Report_Clashes;

   Last_X, Last_Y : Integer := -1;

   function On_Press (Self : access Gtk_Widget_Record'Class;
                      Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      X, Y : Integer;
   begin
      Pixel_At (Event.X, Event.Y, X, Y);
      if X not in 0 .. Width - 1 or else Y not in 0 .. Height - 1 then
         return True;
      end if;
      Paint_Color := (if Event.Button = 3 then Right_Color else Left_Color);
      Clashes := 0;
      case Tool is
         when T_Pencil =>
            Push_Undo;
            Painting := True;
            Plot (X, Y);
            Last_X := X;
            Last_Y := Y;
            Changed;
         when T_Line =>
            Painting := True;
            Line_X0 := X;
            Line_Y0 := Y;
            Line_X1 := X;
            Line_Y1 := Y;
            Canvas.Queue_Draw;
         when T_Fill =>
            Push_Undo;
            declare
               C : Boolean;
            begin
               Flood_Fill (X, Y, Paint_Color, C);
               if C then
                  Clashes := 1;
               end if;
            end;
            Changed;
         when T_Pick =>
            if Event.Button = 3 then
               Right_Color := Bitmap_Data.Pixel (X, Y);
            else
               Left_Color := Bitmap_Data.Pixel (X, Y);
            end if;
            Tool := T_Pencil;
            Redraw_All;
      end case;
      Report_Clashes;
      return True;
   end On_Press;

   function On_Release (Self : access Gtk_Widget_Record'Class;
                        Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if Painting and then Tool = T_Line and then Line_X0 >= 0 then
         Push_Undo;
         Draw_Line (Line_X0, Line_Y0, Line_X1, Line_Y1);
         Line_X0 := -1;
         Changed;
         Report_Clashes;
      end if;
      Painting := False;
      return True;
   end On_Release;

   function On_Motion (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
      X, Y : Integer;
   begin
      Pixel_At (Event.X, Event.Y, X, Y);
      if Painting and then Tool = T_Pencil then
         Draw_Line (Last_X, Last_Y, X, Y);   --  no gaps when moving fast
         Last_X := X;
         Last_Y := Y;
         Changed;
         Report_Clashes;
      elsif Painting and then Tool = T_Line then
         Line_X1 := X;
         Line_Y1 := Y;
         Canvas.Queue_Draw;
      elsif X in 0 .. Width - 1 and then Y in 0 .. Height - 1 then
         declare
            CX : constant Natural := (if Mode = Hires then X / 8 else X / 4);
         begin
            Status.Set_Text ("x" & X'Image & ", y" & Y'Image & "   cell" &
                             CX'Image & "," & Natural'Image (Y / 8) &
                             ": colours " & Cell_Colors (CX, Y / 8));
         end;
      end if;
      return True;
   end On_Motion;

   Target : Pen_Target := Pen_Background;
   Choosing_Target : Boolean := False;

   function On_Pens_Press (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
   begin
      if Event.Y < 40.0 then
         if Event.X >= 146.0 and then Event.X < 206.0 then
            Target := Pen_Background;
            Choosing_Target := True;
            Status.Set_Text ("click a colour for the background ($D021)");
         elsif Event.X >= 222.0 and then Event.X < 282.0 then
            Target := Pen_Border;
            Choosing_Target := True;
            Status.Set_Text ("click a colour for the border ($D020)");
         end if;
      elsif Event.Y >= Gdouble (Pal_Y) and then Event.Y < Gdouble (Pal_Y) + 68.0
      then
         declare
            Col : constant Integer :=
              Integer (Gdouble'Floor ((Event.X - 4.0) / 34.0));
            Row : constant Integer :=
              Integer (Gdouble'Floor ((Event.Y - Gdouble (Pal_Y)) / 34.0));
         begin
            if Col in 0 .. 7 and then Row in 0 .. 1 then
               declare
                  C : constant Byte := Byte (Row * 8 + Col);
               begin
                  if Choosing_Target then
                     Push_Undo;
                     if Target = Pen_Background then
                        Background := C;
                     else
                        Border := C;
                     end if;
                     Choosing_Target := False;
                     Changed;
                  elsif Event.Button = 3 then
                     Right_Color := C;
                  else
                     Left_Color := C;
                  end if;
               end;
            end if;
         end;
      end if;
      Pens.Queue_Draw;
      return True;
   end On_Pens_Press;

   ---------------------------------------------------------------------
   --  Image import
   ---------------------------------------------------------------------

   procedure Import_Image (Path : String) is
      Src : Gdk_Pixbuf;
      Err : GError;
      M : constant Mode_Kind := Mode;
      W : constant Gint := (if M = Hires then 320 else 160);
   begin
      Gdk_New_From_File (Src, Path, Err);
      if Src = null then
         Status.Set_Text ("cannot read the image " & Path);
         if Err /= null then
            Error_Free (Err);
         end if;
         return;
      end if;
      declare
         SW : constant Gint := Get_Width (Src);
         SH : constant Gint := Get_Height (Src);
         --  fit into the picture, keeping the shape (multicolour pixels
         --  are twice as wide)
         FX : constant Float := Float (W) / Float (SW) *
           (if M = Hires then 1.0 else 2.0);
         FY : constant Float := 200.0 / Float (SH);
         F  : constant Float := Float'Min (FX, FY);
         DW : constant Gint := Gint'Max (1, Gint (Float (SW) * F /
                                 (if M = Hires then 1.0 else 2.0)));
         DH : constant Gint := Gint'Max (1, Gint (Float (SH) * F));
         Scaled : constant Gdk_Pixbuf :=
           Scale_Simple (Src, Gint'Min (DW, W), Gint'Min (DH, 200),
                         Interp_Hyper);
         NC : constant Natural := Natural (Get_N_Channels (Scaled));
         RS : constant Natural := Natural (Get_Rowstride (Scaled));
         PW : constant Natural := Natural (Get_Width (Scaled));
         PH : constant Natural := Natural (Get_Height (Scaled));
         OX : constant Natural := (Natural (W) - PW) / 2;
         OY : constant Natural := (200 - PH) / 2;
         Addr : constant System.Address := Get_Pixels (Scaled).all'Address;
         type Raw is array (0 .. RS * PH - 1) of Byte;
         Data : Raw;
         for Data'Address use Addr;
         pragma Import (Ada, Data);
         --  Error-diffusion buffer in RGB
         type Plane is array (0 .. 199, 0 .. 319) of Float;
         type Plane_Access is access Plane;
         R : constant Plane_Access := new Plane'(others => (others => 0.0));
         G : constant Plane_Access := new Plane'(others => (others => 0.0));
         B : constant Plane_Access := new Plane'(others => (others => 0.0));
         Pic : Image := (others => (others => 0));
         Do_Dither : constant Boolean := Dither.Get_Active;
      begin
         for Y in 0 .. PH - 1 loop
            for X in 0 .. PW - 1 loop
               R (OY + Y, OX + X) := Float (Data (Y * RS + X * NC));
               G (OY + Y, OX + X) := Float (Data (Y * RS + X * NC + 1));
               B (OY + Y, OX + X) := Float (Data (Y * RS + X * NC + 2));
            end loop;
         end loop;
         for Y in 0 .. 199 loop
            for X in 0 .. Natural (W) - 1 loop
               declare
                  function Clamp (V : Float) return Natural is
                    (Natural (Float'Max (0.0, Float'Min (255.0, V))));
                  C : constant Byte :=
                    Nearest (Clamp (R (Y, X)), Clamp (G (Y, X)),
                             Clamp (B (Y, X)));
                  P : constant Types.Pixel := Video.VIC_Palette (C);
                  ER : constant Float :=
                    R (Y, X) - Float (Shift_Right (P, 16) and 255);
                  EG : constant Float :=
                    G (Y, X) - Float (Shift_Right (P, 8) and 255);
                  EB : constant Float := B (Y, X) - Float (P and 255);
                  procedure Spread (DX, DY : Integer; K : Float) is
                  begin
                     if X + DX in 0 .. Natural (W) - 1 and then Y + DY <= 199
                     then
                        R (Y + DY, X + DX) := R (Y + DY, X + DX) + ER * K;
                        G (Y + DY, X + DX) := G (Y + DY, X + DX) + EG * K;
                        B (Y + DY, X + DX) := B (Y + DY, X + DX) + EB * K;
                     end if;
                  end Spread;
               begin
                  if M = Hires then
                     Pic (Y, X) := C;
                  else
                     Pic (Y, 2 * X) := C;
                     Pic (Y, 2 * X + 1) := C;
                  end if;
                  if Do_Dither then          --  Floyd-Steinberg
                     Spread (1, 0, 7.0 / 16.0);
                     Spread (-1, 1, 3.0 / 16.0);
                     Spread (0, 1, 5.0 / 16.0);
                     Spread (1, 1, 1.0 / 16.0);
                  end if;
               end;
            end loop;
         end loop;
         Push_Undo;
         Encode (Pic, M);
         Unref (Scaled);
      end;
      Unref (Src);
      Changed;
      Status.Set_Text ("imported " & Ada.Directories.Simple_Name (Path) &
                       " (" & (if M = Hires then "hires" else "multicolour") &
                       (if Dither.Get_Active then ", dithered" else "") &
                       "; colours chosen per cell)");
   end Import_Image;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   function Choose (Title : String; Save : Boolean; Name : String;
                    Patterns : String) return String is
      Dlg : Gtk_File_Chooser_Dialog;
      W : Gtk_Widget;
      F : Gtk_File_Filter;
      R : Unbounded_String;
      pragma Unreferenced (W);
      Last : constant String :=
        Settings.Get ("forge_dir", Settings.Get ("studio_dir", ""));
      From : Positive := Patterns'First;
   begin
      Gtk_New (Dlg, Title, Win,
               (if Save then Gtk.File_Chooser.Action_Save
                else Gtk.File_Chooser.Action_Open));
      W := Dlg.Add_Button ("_Cancel", Gtk_Response_Cancel);
      W := Dlg.Add_Button ((if Save then "_Save" else "_Open"),
                           Gtk_Response_Accept);
      Gtk_New (F);
      F.Set_Name (Patterns);
      for I in Patterns'Range loop
         if Patterns (I) = ' ' or else I = Patterns'Last then
            declare
               P : constant String :=
                 Patterns (From .. (if Patterns (I) = ' ' then I - 1 else I));
            begin
               F.Add_Pattern (P);
               F.Add_Pattern (To_Upper (P));
            end;
            From := I + 1;
         end if;
      end loop;
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

   function Base return String is
     (if File = Null_Unbounded_String then "picture"
      else Ada.Directories.Base_Name (To_String (File)));

   procedure Load_File (Path : String) is
      Ok : Boolean;
      Size : Natural;
   begin
      Push_Undo;
      Bitmap_Data.Load (Path, Ok, Size);
      if Ok then
         File := To_Unbounded_String (Path);
         Modified := False;
         Status.Set_Text ("loaded " & Path);
      else
         Status.Set_Text ("not a Koala (10003 bytes), Art Studio (9009) or " &
                          "Doodle (9218) file:" & Size'Image & " bytes");
      end if;
      Redraw_All;
   end Load_File;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
      Ext : constant String := (if Mode = Hires then ".art" else ".kla");
   begin
      if Ask or else File = Null_Unbounded_String
        or else not Is_Bitmap_File (To_String (File))
        or else (Mode = Hires) /= (To_Lower (Ada.Directories.Extension
                                     (To_String (File))) in "art" | "dd")
      then
         declare
            P : constant String :=
              Choose ("Save picture (" & (if Mode = Hires then "Art Studio"
                      else "Koala") & ")", True, Base & Ext, "*" & Ext);
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String (P);
         end;
      end if;
      Bitmap_Data.Save (To_String (File), Ok);
      if Ok then
         Modified := False;
         Status.Set_Text ("saved " & To_String (File));
      else
         Status.Set_Text ("cannot write " & To_String (File));
      end if;
      Update_Title;
   end Save_File;

   procedure Export_Asm is
      P : constant String :=
        Choose ("Export a viewer program (ACME source)", True, Base & ".asm",
                "*.asm");
      Ok : Boolean;
      Label : String := Base;
   begin
      if P = "" then
         return;
      end if;
      for C of Label loop
         if not (Is_Alphanumeric (C) or else C = '_') then
            C := '_';
         end if;
      end loop;
      Export_Viewer (P, Label, Ok);
      Status.Set_Text (if Ok then "exported " & P & ": open it in Forge and " &
                         "press F5 to see the picture"
                       else "cannot write " & P);
   end Export_Asm;

   procedure Export_PNG is
      P : constant String :=
        Choose ("Export as PNG", True, Base & ".png", "*.png");
      St : Cairo_Status;
      pragma Unreferenced (St);
   begin
      if P /= "" then
         St := Cairo.Png.Write_To_Png (Surface, P);
         Status.Set_Text ("wrote " & P & " (320 x 200)");
      end if;
   end Export_PNG;

   ---------------------------------------------------------------------
   --  Actions
   ---------------------------------------------------------------------

   type Action is (A_New, A_Open, A_Save, A_Save_As, A_Import, A_Export,
                   A_PNG, A_Undo, A_Show, A_Grab);
   Action_Buttons : array (Action) of Gtk_Tool_Button;

   procedure Do_Action (A : Action) is
   begin
      case A is
         when A_New =>
            Push_Undo;
            Clear (Right_Color, Left_Color);
            File := Null_Unbounded_String;
            Changed;
            Modified := False;
            Update_Title;
         when A_Open =>
            declare
               P : constant String :=
                 Choose ("Open picture", False, "", "*.kla *.koa *.art *.dd");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Save => Save_File (False);
         when A_Save_As => Save_File (True);
         when A_Import =>
            declare
               P : constant String :=
                 Choose ("Import an image (converted to the current mode)",
                         False, "", "*.png *.jpg *.jpeg *.gif *.bmp");
            begin
               if P /= "" then
                  Import_Image (P);
               end if;
            end;
         when A_Export => Export_Asm;
         when A_PNG => Export_PNG;
         when A_Undo => Undo;
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
      for T in Tool_Kind loop
         if Gtk_Toggle_Tool_Button (Item) = Tool_Buttons (T) then
            Tool := T;
         end if;
      end loop;
      for M in Mode_Kind loop
         if Gtk_Toggle_Tool_Button (Item) = Mode_Buttons (M)
           and then M /= Mode
         then
            --  Convert the picture to the other mode
            declare
               Pic : Image;
            begin
               Push_Undo;
               Render (Pic);
               Encode (Pic, M);
               Changed;
               Status.Set_Text ("converted to " & (if M = Hires then "hires"
                                else "multicolour") & " (Ctrl+Z goes back)");
            end;
         end if;
      end loop;
      Redraw_All;
   end On_Tool;

   procedure On_Option (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Gtk_Check_Button (Self) = Large then
         Scale := (if Large.Get_Active then 3 else 2);
         Resize_Canvas;
      elsif Gtk_Check_Button (Self) = Live and then Live.Get_Active then
         Send_To_Emulator;
      end if;
      Canvas.Queue_Draw;
   end On_Option;

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
      elsif K = GDK_LC_g and then not Ctrl then
         Grid_Check.Set_Active (not Grid_Check.Get_Active);
      else
         return False;
      end if;
      return True;
   end On_Key;

   function On_Delete (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if File /= Null_Unbounded_String then
         Settings.Set ("bitmap_file", To_String (File));
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

      procedure Toggle (B : out Gtk_Toggle_Tool_Button; Label, Tip : String) is
      begin
         Gtk_New (B);
         B.Set_Label (Label);
         B.Set_Tooltip_Text (Tip);
         B.Set_Is_Important (True);
         B.On_Toggled (On_Tool'Access);
         Tools.Insert (B);
      end Toggle;

      procedure Sep is
         S : Gtk_Separator_Tool_Item;
      begin
         Gtk_New (S);
         Tools.Insert (S);
      end Sep;

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
      Win.Set_Default_Size (1060, 600);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Act ("New", A_New, "Clear the picture (right colour, left colour as " &
           "ink)", "document-new");
      Act ("Open", A_Open, "Open a Koala, Art Studio or Doodle picture",
           "document-open");
      Act ("Save", A_Save, "Save (Ctrl+S): Koala for multicolour, Art Studio "
           & "for hires", "document-save");
      Act ("Save as", A_Save_As, "Save under a new name");
      Act ("Import image", A_Import,
           "Convert a PNG / JPEG / GIF into the current mode");
      Act ("Export .asm", A_Export,
           "Write a program that shows the picture (ACME source)");
      Act ("Export PNG", A_PNG, "Save the picture as a PNG image");
      Act ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      Sep;
      Act ("Show in emulator", A_Show,
           "Show the picture on the emulator (needs VIC bank 0, e.g. at READY)");
      Act ("Grab from emulator", A_Grab,
           "Take the bitmap picture the running program shows");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Text);
      Toggle (Tool_Buttons (T_Pencil), "Pencil", "Draw freehand");
      Toggle (Tool_Buttons (T_Line), "Line", "Drag to draw a line");
      Toggle (Tool_Buttons (T_Fill), "Fill", "Flood fill an area");
      Toggle (Tool_Buttons (T_Pick), "Pick", "Take a colour from the picture");
      Sep;
      Toggle (Mode_Buttons (Hires), "Hires",
              "320 x 200, two colours per 8 x 8 cell (converts the picture)");
      Toggle (Mode_Buttons (Multicolour), "Multicolour",
              "160 x 200, background + three colours per cell (converts)");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 8);
      VBox.Pack_Start (HBox, Expand => False, Fill => False);

      Gtk_New (Canvas);
      Resize_Canvas;
      Canvas.Add_Events (Button_Press_Mask or Button_Release_Mask
                         or Button_Motion_Mask or Pointer_Motion_Mask);
      Canvas.On_Draw (On_Canvas_Draw'Access);
      Canvas.On_Button_Press_Event (On_Press'Access);
      Canvas.On_Button_Release_Event (On_Release'Access);
      Canvas.On_Motion_Notify_Event (On_Motion'Access);
      Gtk_New (Frame, "Picture");
      Frame.Add (Canvas);
      Frame.Set_Valign (Align_Start);
      HBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 6);

      Gtk_New_Vbox (Right, Spacing => 6);
      HBox.Pack_Start (Right, Expand => True, Fill => True);
      Gtk_New (Pens);
      Pens.Set_Size_Request (290, 175);
      Pens.Add_Events (Button_Press_Mask);
      Pens.On_Draw (On_Pens_Draw'Access);
      Pens.On_Button_Press_Event (On_Pens_Press'Access);
      Gtk_New (Frame, "Colours");
      Frame.Add (Pens);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New_Vbox (Row, Spacing => 2);
      Check (Grid_Check, "Cell grid (G)", "Show the 8 x 8 colour cells");
      Check (Large, "Large (3x)", "Show the picture three times enlarged");
      Check (Dither, "Dither when importing",
             "Floyd-Steinberg dithering for photos", On => True);
      Check (Live, "Live in emulator", "Send every change to the emulator");
      Right.Pack_Start (Row, Expand => False, Fill => False);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      Status.Set_Ellipsize (Pango.Layout.Ellipsize_End);
      VBox.Pack_Start (Status, Expand => False, Fill => False);
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
   begin
      Parent_W := Parent;
      if Win = null then
         Clear (0, 1);
         Build;
         Win.Show_All;
         declare
            Last : constant String := Settings.Get ("bitmap_file", "");
         begin
            if File = "" and then Last /= ""
              and then Ada.Directories.Exists (Last)
            then
               Load_File (Last);
            end if;
         end;
         Status.Set_Text ("draw with the left / right button; Import image "
                          & "converts a photo; Show in emulator displays it "
                          & "on the C64");
      end if;
      if File /= "" then
         if Is_Image_File (File) then
            Import_Image (File);
         elsif Ada.Directories.Exists (File) then
            Load_File (Ada.Directories.Full_Name (File));
         else
            Bitmap_Editor.File := To_Unbounded_String (File);
         end if;
      end if;
      Redraw_All;
      Win.Show_All;
      Win.Present;
   end Open;

end Bitmap_Editor;
