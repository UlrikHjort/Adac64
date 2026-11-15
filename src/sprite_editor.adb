with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Strings;
with Ada.Characters.Handling;
with Ada.Directories;

with Glib; use Glib;
with Glib.Main; use type Glib.Main.G_Source_Id;
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
with Gtk.Scrolled_Window; use Gtk.Scrolled_Window;
with Gtk.Separator_Tool_Item; use Gtk.Separator_Tool_Item;
with Gtk.Spin_Button; use Gtk.Spin_Button;
with Gtk.Tool_Button; use Gtk.Tool_Button;
with Gtk.Toolbar; use Gtk.Toolbar;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Window; use Gtk.Window;
with Cairo; use Cairo;

with Types; use Types;
with Interfaces; use Interfaces;
with Video;
with Machine;
with Settings;
with Sprite_Data; use Sprite_Data;

package body Sprite_Editor is

   Cell : constant := 18;          --  editor pixel size (screen pixels)
   Thumb_W : constant := 24 * 2 + 8;

   Win      : Gtk_Window := null;
   Parent_W : Gtk_Window := null;
   Grid, Preview, Pens, Strip : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Multi_Check, Expand_X, Expand_Y, Animate, Live : Gtk_Check_Button;
   Anim_From, Anim_To, Anim_Speed : Gtk_Spin_Button;

   Current  : Positive := 1;
   Pen_Sel  : Pen := Sprite_Color;
   File     : Unbounded_String;
   Modified : Boolean := False;
   Painting : Boolean := False;
   Paint_Pen : Pen := Sprite_Color;
   Clip     : Sprite;
   Has_Clip : Boolean := False;
   Anim_Frame : Positive := 1;
   Anim_Timer : Glib.Main.G_Source_Id := 0;
   Updating : Boolean := False;

   Max_Undo : constant := 64;
   type Undo_Entry is record
      Index : Positive := 1;
      S     : Sprite;
   end record;
   Undo_Stack : array (1 .. Max_Undo) of Undo_Entry;
   Undo_Count : Natural := 0;

   function Is_Open return Boolean is (Win /= null and then Win.Get_Visible);

   function Is_Sprite_File (Path : String) return Boolean is
     (Path'Length > 4 and then Ada.Characters.Handling.To_Lower
        (Path (Path'Last - 3 .. Path'Last)) = ".spr");

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   Color_Names : constant array (Byte range 0 .. 15) of access constant String
     := (new String'("black"), new String'("white"), new String'("red"),
         new String'("cyan"), new String'("purple"), new String'("green"),
         new String'("blue"), new String'("yellow"), new String'("orange"),
         new String'("brown"), new String'("light red"),
         new String'("dark grey"), new String'("grey"),
         new String'("light green"), new String'("light blue"),
         new String'("light grey"));

   procedure Set_RGB (Cr : Cairo_Context; C : Byte) is
      P : constant Types.Pixel := Video.VIC_Palette (C and 15);
   begin
      Set_Source_Rgb (Cr, Gdouble (Shift_Right (P, 16) and 255) / 255.0,
                      Gdouble (Shift_Right (P, 8) and 255) / 255.0,
                      Gdouble (P and 255) / 255.0);
   end Set_RGB;

   function Pen_Color (S : Sprite; P : Pen) return Byte is
     (case P is
        when Background => Background_Color,
        when Sprite_Color => S.Color,
        when Multi_1 => Multi_Color_1,
        when Multi_2 => Multi_Color_2);

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   function VIC_Bank return Word is (Machine.VIC_Bank_Address);

   --  Screen offset inside the VIC bank
   function Screen_Offset return Word is
     (Word (Shift_Right (Machine.IO_Peek (16#D018#), 4)) * 16#400#);

   function Screen_Base return Word is (VIC_Bank + Screen_Offset);

   Show_Addr : constant Word := 16#0340#;     --  cassette buffer, pointer 13

   procedure Send_To_Emulator (S : Sprite; Quiet : Boolean := False) is
      function Bit (On : Boolean; Old : Byte) return Byte is
        (if On then Old or 1 else Old and 16#FE#);
   begin
      if VIC_Bank /= 0 then
         if not Quiet then
            Status.Set_Text ("show in emulator needs VIC bank 0 (e.g. at the" &
                             " READY prompt)");
         end if;
         return;
      end if;
      for J in 0 .. 62 loop
         Machine.Poke (Show_Addr + Word (J), S.Data (J));
      end loop;
      Machine.Poke (Screen_Base + 16#3F8#, Byte (Show_Addr / 64));
      Machine.Monitor_Poke (16#D000#, 172);
      Machine.Monitor_Poke (16#D001#, 139);
      Machine.Monitor_Poke (16#D010#, Machine.IO_Peek (16#D010#) and 16#FE#);
      Machine.Monitor_Poke (16#D027#, S.Color);
      Machine.Monitor_Poke (16#D025#, Multi_Color_1);
      Machine.Monitor_Poke (16#D026#, Multi_Color_2);
      Machine.Monitor_Poke
        (16#D01C#, Bit (S.Multi, Machine.IO_Peek (16#D01C#)));
      Machine.Monitor_Poke
        (16#D01D#, Bit (Expand_X.Get_Active, Machine.IO_Peek (16#D01D#)));
      Machine.Monitor_Poke
        (16#D017#, Bit (Expand_Y.Get_Active, Machine.IO_Peek (16#D017#)));
      Machine.Monitor_Poke (16#D015#, Machine.IO_Peek (16#D015#) or 1);
      if not Quiet then
         Status.Set_Text ("sprite 0 of the emulator shows sprite" &
                          Natural'Image (Current - 1) & " (data at $0340)");
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
      Enabled : constant Byte := Machine.IO_Peek (16#D015#);
      Bank : constant Word := VIC_Bank;
      Got  : Natural := 0;
      First : constant Positive := Count + 1;
   begin
      for K in 0 .. 7 loop
         if (Shift_Right (Enabled, K) and 1) /= 0 and then Count < Max_Sprites
         then
            declare
               Ptr : constant Byte :=
                 Machine.VIC_Peek (Screen_Offset + 16#3F8# + Word (K));
               S : constant Sprite := From_Memory
                 (Machine.VIC_Peek'Access, Word (Ptr) * 64,
                  Machine.IO_Peek (16#D027# + Word (K)) and 15,
                  (Shift_Right (Machine.IO_Peek (16#D01C#), K) and 1) /= 0);
            begin
               Insert (Count + 1, S);
               Got := Got + 1;
            end;
         end if;
      end loop;
      if Got = 0 then
         Status.Set_Text ("no sprites are switched on in the emulator");
         return;
      end if;
      Background_Color := Machine.IO_Peek (16#D021#) and 15;
      Multi_Color_1 := Machine.IO_Peek (16#D025#) and 15;
      Multi_Color_2 := Machine.IO_Peek (16#D026#) and 15;
      Current := First;
      Modified := True;
      Status.Set_Text ("grabbed" & Got'Image & " sprites (VIC bank $" &
                       Img (Natural (Bank) / 16#4000#) & ") as sprites" &
                       Natural'Image (First - 1) & " -" &
                       Natural'Image (Count - 1));
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Redrawing
   ---------------------------------------------------------------------

   procedure Update_Title is
   begin
      Win.Set_Title ("Sprite editor - " &
                     (if File = Null_Unbounded_String then "untitled.spr"
                      else Ada.Directories.Simple_Name (To_String (File))) &
                     (if Modified then " *" else "") &
                     "  (sprite" & Natural'Image (Current - 1) & " of" &
                     Count'Image & ")");
   end Update_Title;

   procedure Sync_Controls is
   begin
      Updating := True;
      Multi_Check.Set_Active (Get (Current).Multi);
      Anim_From.Set_Range (0.0, Gdouble (Count - 1));
      Anim_To.Set_Range (0.0, Gdouble (Count - 1));
      Updating := False;
   end Sync_Controls;

   procedure Redraw_All is
   begin
      Sync_Controls;
      Grid.Queue_Draw;
      Preview.Queue_Draw;
      Pens.Queue_Draw;
      Strip.Set_Size_Request (Gint (Count * Thumb_W + 4), 54);
      Strip.Queue_Draw;
      Update_Title;
   end Redraw_All;

   procedure Changed (Live_Update : Boolean := True) is
   begin
      Modified := True;
      Redraw_All;
      if Live_Update and then Live.Get_Active then
         Send_To_Emulator (Get (Current), Quiet => True);
      end if;
   end Changed;

   procedure Draw_Sprite (Cr : Cairo_Context; S : Sprite;
                          X0, Y0 : Gdouble; SX, SY : Gdouble;
                          With_Background : Boolean) is
   begin
      if With_Background then
         Set_RGB (Cr, Background_Color);
         Rectangle (Cr, X0, Y0, 24.0 * SX, 21.0 * SY);
         Cairo.Fill (Cr);
      end if;
      for Y in Y_Range loop
         for X in X_Range loop
            declare
               P : constant Pen := Sprite_Data.Pixel (S, X, Y);
            begin
               if P /= Background then
                  Set_RGB (Cr, Pen_Color (S, P));
                  Rectangle (Cr, X0 + Gdouble (X) * SX, Y0 + Gdouble (Y) * SY,
                             SX, SY);
                  Cairo.Fill (Cr);
               end if;
            end;
         end loop;
      end loop;
   end Draw_Sprite;

   function On_Grid_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      S : constant Sprite := Get (Current);
      Step : constant Natural := (if S.Multi then 2 else 1);
   begin
      Draw_Sprite (Cr, S, 0.0, 0.0, Gdouble (Cell), Gdouble (Cell), True);
      --  Grid lines: pixels, and bytes (every 8 hires pixels)
      Set_Line_Width (Cr, 1.0);
      Set_Source_Rgba (Cr, 0.0, 0.0, 0.0, 0.25);
      for X in 0 .. 24 loop
         if X mod Step = 0 then
            Move_To (Cr, Gdouble (X * Cell) + 0.5, 0.0);
            Line_To (Cr, Gdouble (X * Cell) + 0.5, Gdouble (21 * Cell));
         end if;
      end loop;
      for Y in 0 .. 21 loop
         Move_To (Cr, 0.0, Gdouble (Y * Cell) + 0.5);
         Line_To (Cr, Gdouble (24 * Cell), Gdouble (Y * Cell) + 0.5);
      end loop;
      Stroke (Cr);
      Set_Source_Rgba (Cr, 0.0, 0.0, 0.0, 0.6);
      for X in 1 .. 2 loop
         Move_To (Cr, Gdouble (X * 8 * Cell) + 0.5, 0.0);
         Line_To (Cr, Gdouble (X * 8 * Cell) + 0.5, Gdouble (21 * Cell));
      end loop;
      Stroke (Cr);
      return True;
   end On_Grid_Draw;

   function On_Preview_Draw (Self : access Gtk_Widget_Record'Class;
                             Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      Frame_I : constant Positive :=
        (if Animate.Get_Active then Anim_Frame else Current);
      S : constant Sprite := Get (Natural'Min (Frame_I, Count));
      SX : constant Gdouble := (if Expand_X.Get_Active then 8.0 else 4.0);
      SY : constant Gdouble := (if Expand_Y.Get_Active then 8.0 else 4.0);
   begin
      Set_RGB (Cr, Background_Color);
      Paint (Cr);
      Draw_Sprite (Cr, S, 8.0, 8.0, SX, SY, False);
      --  actual size (1:1, with expansion) at the right
      Draw_Sprite (Cr, S, 8.0 + 24.0 * 8.0 + 16.0, 8.0,
                   SX / 4.0, SY / 4.0, False);
      return True;
   end On_Preview_Draw;

   --  Pens: four swatches on top, the 16 C64 colours below
   Pen_Y : constant := 4;
   Pal_Y : constant := 64;
   Swatch : constant := 26;

   function On_Pens_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      S : constant Sprite := Get (Current);
      Names : constant array (Pen) of access constant String :=
        (new String'("1 bg"), new String'("2 sprite"), new String'("3 multi1"),
         new String'("4 multi2"));
   begin
      Select_Font_Face (Cr, "Sans", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 11.0);
      for P in Pen loop
         declare
            X : constant Gdouble := 4.0 + Gdouble (Pen'Pos (P)) * 62.0;
            Usable : constant Boolean :=
              S.Multi or else P in Background | Sprite_Color;
         begin
            Set_RGB (Cr, Pen_Color (S, P));
            Rectangle (Cr, X, Gdouble (Pen_Y), 56.0, 32.0);
            Cairo.Fill (Cr);
            if P = Pen_Sel then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 3.0);
               Rectangle (Cr, X - 1.5, Gdouble (Pen_Y) - 1.5, 59.0, 35.0);
               Stroke (Cr);
            end if;
            Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
            Move_To (Cr, X, Gdouble (Pen_Y) + 48.0);
            if not Usable then
               Set_Source_Rgb (Cr, 0.55, 0.55, 0.55);   --  multicolour only
            end if;
            Show_Text (Cr, Names (P).all);
         end;
      end loop;
      for C in Byte range 0 .. 15 loop
         declare
            X : constant Gdouble := 4.0 + Gdouble (C mod 8) * (Gdouble (Swatch) + 4.0);
            Y : constant Gdouble :=
              Gdouble (Pal_Y) + Gdouble (C / 8) * (Gdouble (Swatch) + 4.0);
         begin
            Set_RGB (Cr, C);
            Rectangle (Cr, X, Y, Gdouble (Swatch), Gdouble (Swatch));
            Cairo.Fill (Cr);
            if C = Pen_Color (S, Pen_Sel) then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 2.0);
               Rectangle (Cr, X - 1.0, Y - 1.0, Gdouble (Swatch) + 2.0,
                          Gdouble (Swatch) + 2.0);
               Stroke (Cr);
            end if;
         end;
      end loop;
      Set_Source_Rgb (Cr, 0.1, 0.1, 0.1);
      Move_To (Cr, 4.0, Gdouble (Pal_Y) + 2.0 * (Gdouble (Swatch) + 4.0) + 12.0);
      Show_Text (Cr, "click a colour to give it to the selected pen (" &
                   Color_Names (Pen_Color (S, Pen_Sel)).all & ")");
      return True;
   end On_Pens_Draw;

   function On_Strip_Draw (Self : access Gtk_Widget_Record'Class;
                           Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Select_Font_Face (Cr, "Sans", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 9.0);
      for I in 1 .. Count loop
         declare
            X : constant Gdouble := 4.0 + Gdouble ((I - 1) * Thumb_W);
         begin
            Draw_Sprite (Cr, Get (I), X, 2.0, 2.0, 2.0, True);
            if I = Current then
               Set_Source_Rgb (Cr, 1.0, 0.2, 0.2);
               Set_Line_Width (Cr, 2.0);
               Rectangle (Cr, X - 1.0, 1.0, 50.0, 44.0);
               Stroke (Cr);
            end if;
            Set_Source_Rgb (Cr, 0.2, 0.2, 0.2);
            Move_To (Cr, X, 53.0);
            Show_Text (Cr, Img (I - 1));
         end;
      end loop;
      return True;
   end On_Strip_Draw;

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
      declare
         E : constant Undo_Entry := Undo_Stack (Undo_Count);
      begin
         Undo_Count := Undo_Count - 1;
         if E.Index <= Count then
            Current := E.Index;
            Put (E.Index, E.S);
            Changed;
         end if;
      end;
   end Undo;

   --  Apply an operation to the current sprite (with undo)
   type Sprite_Op is access procedure (S : in out Sprite);
   procedure Apply (Op : Sprite_Op) is
      S : Sprite := Get (Current);
   begin
      Push_Undo;
      Op (S);
      Put (Current, S);
      Changed;
   end Apply;

   procedure Paint_At (X, Y : Gdouble; Fill_Area : Boolean) is
      PX : constant Integer := Integer (Gdouble'Floor (X / Gdouble (Cell)));
      PY : constant Integer := Integer (Gdouble'Floor (Y / Gdouble (Cell)));
      S : Sprite := Get (Current);
      P : Pen := Paint_Pen;
   begin
      if PX not in X_Range or else PY not in Y_Range then
         return;
      end if;
      if not S.Multi and then P in Multi_1 | Multi_2 then
         P := Sprite_Color;
      end if;
      if Fill_Area then
         Flood_Fill (S, PX, PY, P);
      elsif Sprite_Data.Pixel (S, PX, PY) = P then
         return;
      else
         Set_Pixel (S, PX, PY, P);
      end if;
      Put (Current, S);
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

   function On_Pens_Press (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      X : constant Gdouble := Event.X;
      Y : constant Gdouble := Event.Y;
   begin
      if Y < Gdouble (Pen_Y + 36) then
         for P in Pen loop
            if X >= 4.0 + Gdouble (Pen'Pos (P)) * 62.0
              and then X < 60.0 + Gdouble (Pen'Pos (P)) * 62.0
            then
               Pen_Sel := P;
            end if;
         end loop;
      elsif Y >= Gdouble (Pal_Y) and then Y < Gdouble (Pal_Y) + 60.0 then
         declare
            Col : constant Integer := Integer (Gdouble'Floor ((X - 4.0) / 30.0));
            Row : constant Integer :=
              Integer (Gdouble'Floor ((Y - Gdouble (Pal_Y)) / 30.0));
         begin
            if Col in 0 .. 7 and then Row in 0 .. 1 then
               declare
                  C : constant Byte := Byte (Row * 8 + Col);
                  S : Sprite := Get (Current);
               begin
                  case Pen_Sel is
                     when Background => Background_Color := C;
                     when Multi_1 => Multi_Color_1 := C;
                     when Multi_2 => Multi_Color_2 := C;
                     when Sprite_Color =>
                        Push_Undo;
                        S.Color := C;
                        Put (Current, S);
                  end case;
                  Changed;
               end;
            end if;
         end;
      end if;
      Redraw_All;
      return True;
   end On_Pens_Press;

   function On_Strip_Press (Self : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      I : constant Integer :=
        Integer (Gdouble'Floor ((Event.X - 4.0) / Gdouble (Thumb_W))) + 1;
   begin
      if I in 1 .. Count then
         Current := I;
         Redraw_All;
      end if;
      return True;
   end On_Strip_Press;

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

   procedure Save_Colors is
   begin
      Settings.Set ("sprite_bg", Integer (Background_Color));
      Settings.Set ("sprite_mc1", Integer (Multi_Color_1));
      Settings.Set ("sprite_mc2", Integer (Multi_Color_2));
   end Save_Colors;

   procedure Load_File (Path : String) is
      Ok : Boolean;
   begin
      Sprite_Data.Load (Path, Ok);
      if Ok then
         File := To_Unbounded_String (Path);
         Current := 1;
         Modified := False;
         Undo_Count := 0;
         Status.Set_Text ("loaded" & Count'Image & " sprites from " & Path);
      else
         Status.Set_Text ("cannot read " & Path);
      end if;
      Redraw_All;
   end Load_File;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
   begin
      if Ask or else File = Null_Unbounded_String then
         declare
            P : constant String :=
              Choose ("Save sprites", True, "*.spr", "sprites.spr");
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String (P);
         end;
      end if;
      Sprite_Data.Save (To_String (File), Ok);
      Save_Colors;
      if Ok then
         Modified := False;
         Status.Set_Text ("saved" & Count'Image & " sprites to " &
                          To_String (File) & " (" & Img (Count * 64) &
                          " bytes)");
      else
         Status.Set_Text ("cannot write " & To_String (File));
      end if;
      Update_Title;
   end Save_File;

   procedure Export is
      Base : constant String :=
        (if File = Null_Unbounded_String then "sprites"
         else Ada.Directories.Base_Name (To_String (File)));
      P : constant String :=
        Choose ("Export sprites as assembly source", True, "*.asm",
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
      Sprite_Data.Export_Source (P, Label, Ok);
      Status.Set_Text (if Ok then "exported to " & P & " (labels " & Label &
                         "_0 ...)" else "cannot write " & P);
   end Export;

   ---------------------------------------------------------------------
   --  Toolbar actions
   ---------------------------------------------------------------------

   type Action is
     (A_New, A_Open, A_Save, A_Save_As, A_Export,
      A_Prev, A_Next, A_Add, A_Dup, A_Delete, A_Copy, A_Paste, A_Undo,
      A_Clear, A_Invert, A_Mirror_X, A_Mirror_Y,
      A_Left, A_Right, A_Up, A_Down, A_Show, A_Grab);

   procedure Op_Clear (S : in out Sprite) is
   begin
      Clear (S);
   end Op_Clear;
   procedure Op_Invert (S : in out Sprite) is
   begin
      Invert (S);
   end Op_Invert;
   procedure Op_Mirror_X (S : in out Sprite) is
   begin
      Mirror_X (S);
   end Op_Mirror_X;
   procedure Op_Mirror_Y (S : in out Sprite) is
   begin
      Mirror_Y (S);
   end Op_Mirror_Y;
   procedure Op_Left (S : in out Sprite) is
   begin
      Shift (S, -1, 0);
   end Op_Left;
   procedure Op_Right (S : in out Sprite) is
   begin
      Shift (S, 1, 0);
   end Op_Right;
   procedure Op_Up (S : in out Sprite) is
   begin
      Shift (S, 0, -1);
   end Op_Up;
   procedure Op_Down (S : in out Sprite) is
   begin
      Shift (S, 0, 1);
   end Op_Down;

   procedure Do_Action (A : Action) is
   begin
      case A is
         when A_New =>
            Reset_Set;
            File := Null_Unbounded_String;
            Current := 1;
            Modified := False;
            Undo_Count := 0;
            Redraw_All;
         when A_Open =>
            declare
               P : constant String := Choose ("Open sprites", False, "*.spr",
                                              "");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Save => Save_File (False);
         when A_Save_As => Save_File (True);
         when A_Export => Export;
         when A_Prev =>
            if Current > 1 then
               Current := Current - 1;
               Redraw_All;
            end if;
         when A_Next =>
            if Current < Count then
               Current := Current + 1;
               Redraw_All;
            end if;
         when A_Add =>
            declare
               S : Sprite;
            begin
               S.Multi := Get (Current).Multi;
               S.Color := Get (Current).Color;
               Insert (Current + 1, S);
               Current := Natural'Min (Current + 1, Count);
               Changed (False);
            end;
         when A_Dup =>
            Insert (Current + 1, Get (Current));
            Current := Natural'Min (Current + 1, Count);
            Changed (False);
         when A_Delete =>
            Delete (Current);
            Current := Natural'Min (Current, Count);
            Undo_Count := 0;
            Changed (False);
         when A_Copy =>
            Clip := Get (Current);
            Has_Clip := True;
            Status.Set_Text ("copied sprite" & Natural'Image (Current - 1));
         when A_Paste =>
            if Has_Clip then
               Push_Undo;
               Put (Current, Clip);
               Changed;
            end if;
         when A_Undo => Undo;
         when A_Clear => Apply (Op_Clear'Access);
         when A_Invert => Apply (Op_Invert'Access);
         when A_Mirror_X => Apply (Op_Mirror_X'Access);
         when A_Mirror_Y => Apply (Op_Mirror_Y'Access);
         when A_Left => Apply (Op_Left'Access);
         when A_Right => Apply (Op_Right'Access);
         when A_Up => Apply (Op_Up'Access);
         when A_Down => Apply (Op_Down'Access);
         when A_Show =>
            Send_To_Emulator (Get (Current));
            if Parent_W /= null then
               Parent_W.Present;      --  bring the emulator window up
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
      S : Sprite := Get (Current);
   begin
      if Updating or else S.Multi = Self.Get_Active then
         return;
      end if;
      Push_Undo;
      S.Multi := Self.Get_Active;
      Put (Current, S);
      if not S.Multi and then Pen_Sel in Multi_1 | Multi_2 then
         Pen_Sel := Sprite_Color;
      end if;
      Changed;
   end On_Multi;

   procedure On_View_Toggle (Self : access Gtk_Toggle_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Preview.Queue_Draw;
      if Live.Get_Active then
         Send_To_Emulator (Get (Current), Quiet => True);
      end if;
   end On_View_Toggle;

   function On_Anim_Timer return Boolean is
      From : constant Positive := Natural (Anim_From.Get_Value_As_Int) + 1;
      To   : constant Positive := Natural (Anim_To.Get_Value_As_Int) + 1;
   begin
      if Win = null or else not Animate.Get_Active then
         Anim_Timer := 0;
         return False;
      end if;
      if Anim_Frame < From or else Anim_Frame >= To or else To > Count then
         Anim_Frame := From;
      else
         Anim_Frame := Anim_Frame + 1;
      end if;
      Anim_Frame := Natural'Min (Anim_Frame, Count);
      Preview.Queue_Draw;
      if Live.Get_Active then
         Send_To_Emulator (Get (Anim_Frame), Quiet => True);
      end if;
      return True;
   end On_Anim_Timer;

   procedure Start_Animation is
      Fps : constant Natural :=
        Natural'Max (1, Natural (Anim_Speed.Get_Value_As_Int));
   begin
      if Anim_Timer /= 0 then
         Glib.Main.Remove (Anim_Timer);
         Anim_Timer := 0;
      end if;
      if Animate.Get_Active then
         Anim_Frame := Natural (Anim_From.Get_Value_As_Int) + 1;
         Anim_Timer := Glib.Main.Timeout_Add
           (Guint (1000 / Fps), On_Anim_Timer'Access);
      end if;
      Preview.Queue_Draw;
   end Start_Animation;

   procedure On_Animate (Self : access Gtk_Toggle_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Start_Animation;
   end On_Animate;

   procedure On_Speed (Self : access Gtk_Spin_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      if Animate.Get_Active then
         Start_Animation;
      end if;
   end On_Speed;

   function On_Key (Self : access Gtk_Widget_Record'Class;
                    Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self);
      Ctrl : constant Boolean := (Event.State and Control_Mask) /= 0;
      K : constant Gdk_Key_Type := Event.Keyval;
   begin
      if Ctrl and then K = GDK_LC_z then
         Undo;
      elsif Ctrl and then K = GDK_LC_c then
         Do_Action (A_Copy);
      elsif Ctrl and then K = GDK_LC_v then
         Do_Action (A_Paste);
      elsif Ctrl and then K = GDK_LC_s then
         Save_File (False);
      elsif K = GDK_Page_Up then
         Do_Action (A_Prev);
      elsif K = GDK_Page_Down then
         Do_Action (A_Next);
      elsif K = GDK_LC_m then
         Multi_Check.Set_Active (not Multi_Check.Get_Active);
      elsif K in GDK_1 .. GDK_4 then
         Pen_Sel := Pen'Val (Natural (K - GDK_1));
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
         Settings.Set ("sprite_file", To_String (File));
      end if;
      Win.Hide;
      return True;
   end On_Delete;

   ---------------------------------------------------------------------
   --  Construction
   ---------------------------------------------------------------------

   procedure Build is
      VBox, HBox, Right, Row : Gtk_Box;
      Tools : Gtk_Toolbar;
      Frame : Gtk_Frame;
      Scroll : Gtk_Scrolled_Window;
      L : Gtk_Label;

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

      function Area (W, H : Gint) return Gtk_Drawing_Area is
         A : Gtk_Drawing_Area;
      begin
         Gtk_New (A);
         A.Set_Size_Request (W, H);
         A.Add_Events (Button_Press_Mask or Button_Release_Mask
                       or Button_Motion_Mask);
         return A;
      end Area;
   begin
      Gtk_New (Win);
      Win.Set_Default_Size (1060, 720);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Tool ("New", A_New, "New sprite set", "document-new");
      Tool ("Open", A_Open, "Open a .spr file", "document-open");
      Tool ("Save", A_Save, "Save (Ctrl+S)", "document-save");
      Tool ("Save as", A_Save_As, "Save under a new name");
      Tool ("Export .asm", A_Export, "Write the sprites as ACME source");
      Sep;
      Tool ("<", A_Prev, "Previous sprite (PgUp)", "go-previous");
      Tool (">", A_Next, "Next sprite (PgDn)", "go-next");
      Tool ("Add", A_Add, "Insert an empty sprite after this one", "list-add");
      Tool ("Dup", A_Dup, "Duplicate this sprite");
      Tool ("Del", A_Delete, "Delete this sprite", "list-remove");
      Tool ("Copy", A_Copy, "Copy (Ctrl+C)");
      Tool ("Paste", A_Paste, "Paste (Ctrl+V)");
      Tool ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Text);
      Tool ("Clear", A_Clear, "Clear the sprite");
      Tool ("Invert", A_Invert, "Invert all bits");
      Tool ("Flip H", A_Mirror_X, "Mirror left-right");
      Tool ("Flip V", A_Mirror_Y, "Mirror top-bottom");
      Tool ("Shift <", A_Left, "Scroll left (wraps)");
      Tool ("Shift >", A_Right, "Scroll right (wraps)");
      Tool ("Shift ^", A_Up, "Scroll up (wraps)");
      Tool ("Shift v", A_Down, "Scroll down (wraps)");
      Sep;
      Tool ("Show in emulator", A_Show,
            "Display this sprite as sprite 0 of the running machine " &
            "(data at $0340; needs VIC bank 0, e.g. at READY)");
      Tool ("Grab from emulator", A_Grab,
            "Copy the sprites currently switched on in the emulator into " &
            "the set");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 8);
      VBox.Pack_Start (HBox, Expand => True, Fill => True);

      Grid := Area (24 * Cell + 1, 21 * Cell + 1);
      Grid.On_Draw (On_Grid_Draw'Access);
      Grid.On_Button_Press_Event (On_Grid_Press'Access);
      Grid.On_Button_Release_Event (On_Grid_Release'Access);
      Grid.On_Motion_Notify_Event (On_Grid_Motion'Access);
      Gtk_New (Frame, "Sprite (left: draw, right: erase, shift: fill)");
      Frame.Add (Grid);
      Frame.Set_Valign (Align_Start);
      HBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 6);

      Gtk_New_Vbox (Right, Spacing => 6);
      HBox.Pack_Start (Right, Expand => True, Fill => True);

      Pens := Area (260, 140);
      Pens.On_Draw (On_Pens_Draw'Access);
      Pens.On_Button_Press_Event (On_Pens_Press'Access);
      Gtk_New (Frame, "Pens (keys 1-4) and colours");
      Frame.Add (Pens);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New_Hbox (Row, Spacing => 8);
      Gtk_New (Multi_Check, "Multicolour (M)");
      Multi_Check.On_Toggled (On_Multi'Access);
      Row.Pack_Start (Multi_Check, Expand => False, Fill => False);
      Gtk_New (Expand_X, "Expand X");
      Expand_X.On_Toggled (On_View_Toggle'Access);
      Row.Pack_Start (Expand_X, Expand => False, Fill => False);
      Gtk_New (Expand_Y, "Expand Y");
      Expand_Y.On_Toggled (On_View_Toggle'Access);
      Row.Pack_Start (Expand_Y, Expand => False, Fill => False);
      Gtk_New (Live, "Live in emulator");
      Live.Set_Tooltip_Text ("Send every change to sprite 0 of the emulator");
      Live.On_Toggled (On_View_Toggle'Access);
      Row.Pack_Start (Live, Expand => False, Fill => False);
      Right.Pack_Start (Row, Expand => False, Fill => False);

      Preview := Area (24 * 8 + 16 + 24 * 2 + 24, 21 * 8 + 16);
      Preview.On_Draw (On_Preview_Draw'Access);
      Gtk_New (Frame, "Preview (enlarged and actual size)");
      Frame.Add (Preview);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New_Hbox (Row, Spacing => 6);
      Gtk_New (Animate, "Animate sprites");
      Animate.On_Toggled (On_Animate'Access);
      Row.Pack_Start (Animate, Expand => False, Fill => False);
      Gtk_New (Anim_From, 0.0, 255.0, 1.0);
      Gtk_New (Anim_To, 0.0, 255.0, 1.0);
      Gtk_New (Anim_Speed, 1.0, 50.0, 1.0);
      Anim_Speed.Set_Value (8.0);
      Anim_Speed.On_Value_Changed (On_Speed'Access);
      Row.Pack_Start (Anim_From, Expand => False, Fill => False);
      Gtk_New (L, "to");
      Row.Pack_Start (L, Expand => False, Fill => False);
      Row.Pack_Start (Anim_To, Expand => False, Fill => False);
      Gtk_New (L, "frames/s");
      Row.Pack_Start (Anim_Speed, Expand => False, Fill => False);
      Row.Pack_Start (L, Expand => False, Fill => False);
      Right.Pack_Start (Row, Expand => False, Fill => False);

      Strip := Area (Thumb_W, 54);
      Strip.On_Draw (On_Strip_Draw'Access);
      Strip.On_Button_Press_Event (On_Strip_Press'Access);
      Gtk_New (Scroll);
      Scroll.Set_Policy (Policy_Automatic, Policy_Never);
      Scroll.Set_Size_Request (-1, 80);
      Scroll.Add (Strip);
      Gtk_New (Frame, "Sprites (click to select)");
      Frame.Add (Scroll);
      VBox.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      VBox.Pack_Start (Status, Expand => False, Fill => False);

      Background_Color := Byte (Settings.Get ("sprite_bg", 6) mod 16);
      Multi_Color_1 := Byte (Settings.Get ("sprite_mc1", 11) mod 16);
      Multi_Color_2 := Byte (Settings.Get ("sprite_mc2", 1) mod 16);
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
   begin
      Parent_W := Parent;
      if Win = null then
         Build;
         Win.Show_All;
         declare
            Last : constant String := Settings.Get ("sprite_file", "");
         begin
            if File = "" and then Last /= ""
              and then Ada.Directories.Exists (Last)
            then
               Load_File (Last);
            end if;
         end;
         Status.Set_Text ("draw with the left button; pens 1-4; " &
                          "PgUp/PgDn change sprite; Ctrl+Z undo");
      end if;
      if File /= "" then
         if Ada.Directories.Exists (File) then
            Load_File (Ada.Directories.Full_Name (File));
         else
            Sprite_Data.Reset_Set;
            Sprite_Editor.File := To_Unbounded_String (File);
            Current := 1;
         end if;
      end if;
      Redraw_All;
      Win.Show_All;
      Win.Present;
   end Open;

end Sprite_Editor;
