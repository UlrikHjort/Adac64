with Ada.Real_Time; use Ada.Real_Time;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Gdk.Types; use type Gdk.Types.Gdk_Modifier_Type;
with Interfaces; use Interfaces;

with Glib; use Glib;
with Glib.Main;
with Gdk.Event; use Gdk.Event;
with Gtk.Main;
with Gtk.Window; use Gtk.Window;
with Gtk.Box; use Gtk.Box;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Menu; use Gtk.Menu;
with Gtk.Menu_Bar; use Gtk.Menu_Bar;
with Gtk.Menu_Item; use Gtk.Menu_Item;
with Gtk.Check_Menu_Item; use Gtk.Check_Menu_Item;
with Gtk.Radio_Menu_Item; use Gtk.Radio_Menu_Item;
with Gtk.Separator_Menu_Item; use Gtk.Separator_Menu_Item;
with Gtk.Drawing_Area; use Gtk.Drawing_Area;
with Gtk.Label; use Gtk.Label;
with Gtk.Dialog; use Gtk.Dialog;
with Gtk.File_Chooser;
with Gtk.File_Chooser_Dialog; use Gtk.File_Chooser_Dialog;
with Gtk.File_Filter; use Gtk.File_Filter;
with Gtk.Message_Dialog; use Gtk.Message_Dialog;
with Gtk.Dnd;
with Gtk.Selection_Data;
with Gdk.Drag_Contexts;
with Glib.Convert;
with GNAT.Strings;
with Cairo; use Cairo;
with Cairo.Image_Surface;
with Cairo.Pattern;

with Machine; use Machine;
with Keyboard;
with Media;
with Audio;
with SID;
with Blit;

package body GUI is

   Win      : Gtk_Window;
   Area     : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   VIC_Surf : Cairo_Surface;
   VDC_Surf : Cairo_Surface;

   ROMs        : Unbounded_String;
   Show_VDC    : Boolean := False;
   Warp        : Boolean := False;
   Paused      : Boolean := False;

   Item_Warp    : Gtk_Check_Menu_Item;
   Item_VDC     : Gtk_Check_Menu_Item;
   Item_4080    : Gtk_Check_Menu_Item;
   Item_Pause   : Gtk_Check_Menu_Item;
   Item_TDE     : Gtk_Check_Menu_Item;
   Item_C64, Item_C128 : Gtk_Radio_Menu_Item;
   Updating_Menu : Boolean := False;
   Was_VDC : Boolean := False;

   Start_Time   : Time := Clock;
   Frames_Run   : Natural := 0;     --  for time-based pacing
   FPS_Time     : Time := Clock;
   FPS_Frames   : Natural := 0;
   LED_Time     : Time := Clock;
   FPS          : Natural := 0;

   Audio_Target : constant := 2 * 882 + 441;    --  ~50 ms of samples

   ---------------------------------------------------------------------
   --  Helpers
   ---------------------------------------------------------------------

   procedure Message (Text : String) is
      Dlg : Gtk_Message_Dialog;
      R : Gtk_Response_Type;
      pragma Unreferenced (R);
   begin
      Gtk_New (Dlg, Win, Modal, Message_Info, Buttons_Ok, Text);
      R := Dlg.Run;
      Dlg.Destroy;
   end Message;

   function Model_Name return String is
     (case Machine.Model is
        when C64 => "C64",
        when C128 => (if Machine.In_C64_Mode then "C128 (C64 mode)"
                      else "C128"));

   procedure Update_Status is
      Drive_Str : constant String :=
        (if Machine.Drive_Active then
            "1541 " & (if Machine.Drive_LED then "[*]" else "[ ]") &
            " T" & Ada.Strings.Fixed.Trim (Machine.Drive_Track'Image,
                                           Ada.Strings.Left) & " "
         else "fast ");
      Media_Str : constant String :=
        (case Media.Kind is
           when Media.None => "drive 8: host directory",
           when others => "drive 8: " & Drive_Str & Media.Attached_Name);
      Img : constant String := Ada.Strings.Fixed.Trim (FPS'Image,
                                                      Ada.Strings.Left);
   begin
      Status.Set_Text
        (Model_Name & "  |  " & Img & " fps" &
         (if Warp then " (warp)" else "") &
         (if Paused then "  |  PAUSED" else "") &
         "  |  " & Media_Str &
         (if Machine.Cartridge_Name /= "" then
             "  |  cart: " & Ada.Strings.Fixed.Trim
               (Machine.Cartridge_Name, Ada.Strings.Right)
          else "") &
         (if Machine.Model = C128 then
             (if Show_VDC then "  |  80 col" else "  |  40 col")
          else "") &
         "  |  joy port" & Keyboard.Joystick_Port'Image &
         "  |  F9 autostart  F10 40/80  F11 warp  F12 reset  Shift+F9/F10 quick save/load");
   end Update_Status;

   procedure Sync_Menu is
   begin
      Updating_Menu := True;
      Item_VDC.Set_Active (Show_VDC);
      Item_Warp.Set_Active (Warp);
      Item_4080.Set_Active (Machine.Key_4080_Down);
      Item_Pause.Set_Active (Paused);
      Item_TDE.Set_Active (Machine.True_Drive);
      Item_TDE.Set_Sensitive (Machine.Drive_ROM_Found);
      if Machine.Model = C64 then
         Item_C64.Set_Active (True);
      else
         Item_C128.Set_Active (True);
      end if;
      Item_VDC.Set_Sensitive (Machine.Model = C128);
      Item_4080.Set_Sensitive (Machine.Model = C128);
      Updating_Menu := False;
      Update_Status;
   end Sync_Menu;

   procedure Start_Machine (M : Model_Type) is
      Ok : Boolean;
   begin
      Machine.Power_On (M, To_String (ROMs), Ok);
      if not Ok then
         Message ("Could not load ROMs:" & ASCII.LF & Machine.Error_Message);
      end if;
      Show_VDC := M = C128 and then Machine.Key_4080_Down;
      Keyboard.Release_All;
   end Start_Machine;

   type Ext_List is array (1 .. 4) of String (1 .. 3);
   Extensions : constant Ext_List := ("d64", "t64", "prg", "crt");

   function Choose_Save_File (Title : String) return String is
      Dlg : Gtk_File_Chooser_Dialog;
      W : Gtk_Widget;
      pragma Unreferenced (W);
      Result : Unbounded_String;
   begin
      Gtk_New (Dlg, Title, Win, Gtk.File_Chooser.Action_Save);
      W := Dlg.Add_Button ("_Cancel", Gtk_Response_Cancel);
      W := Dlg.Add_Button ("_Save", Gtk_Response_Accept);
      Gtk.File_Chooser.Set_Do_Overwrite_Confirmation (+Dlg, True);
      Gtk.File_Chooser.Set_Current_Name (+Dlg, "snapshot.a64s");
      if Dlg.Run = Gtk_Response_Accept then
         Result := To_Unbounded_String
           (Gtk.File_Chooser.Get_Filename (+Dlg));
      end if;
      Dlg.Destroy;
      Keyboard.Release_All;
      return To_String (Result);
   end Choose_Save_File;

   function Quick_Snapshot_Path return String is
      Home : constant String :=
        (if Ada.Environment_Variables.Exists ("HOME")
         then Ada.Environment_Variables.Value ("HOME") else ".");
      Dir : constant String := Home & "/.local/share/adac64";
   begin
      if not Ada.Directories.Exists (Dir) then
         Ada.Directories.Create_Path (Dir);
      end if;
      return Dir & "/quick.a64s";
   exception
      when others => return "quick.a64s";
   end Quick_Snapshot_Path;

   procedure Snapshot_Save (Path : String) is
      Ok : Boolean;
   begin
      if Path /= "" then
         Machine.Save_Snapshot (Path, Ok);
         if not Ok then
            Message ("Could not write snapshot " & Path);
         end if;
      end if;
   end Snapshot_Save;

   procedure Snapshot_Load (Path : String) is
      Ok : Boolean;
   begin
      if Path /= "" then
         if not Ada.Directories.Exists (Path) then
            Message ("No snapshot " & Path);
            return;
         end if;
         Machine.Load_Snapshot (Path, Ok);
         if not Ok then
            Message ("Could not load snapshot " & Path & ASCII.LF &
                     Machine.Error_Message);
         end if;
         Was_VDC := not Was_VDC;    --  re-evaluate 40/80 view
         Sync_Menu;
      end if;
   end Snapshot_Load;

   function Choose_File (Title : String) return String is
      Dlg : Gtk_File_Chooser_Dialog;
      Filter_C64, Filter_All : Gtk_File_Filter;
      W : Gtk_Widget;
      pragma Unreferenced (W);
      Result : Unbounded_String;
   begin
      Gtk_New (Dlg, Title, Win, Gtk.File_Chooser.Action_Open);
      W := Dlg.Add_Button ("_Cancel", Gtk_Response_Cancel);
      W := Dlg.Add_Button ("_Open", Gtk_Response_Accept);
      Gtk_New (Filter_C64);
      Filter_C64.Set_Name ("C64 files (d64, t64, prg, crt)");
      for Ext of Extensions loop
         Filter_C64.Add_Pattern ("*." & Ext);
         Filter_C64.Add_Pattern ("*." & Ada.Characters.Handling.To_Upper (Ext));
      end loop;
      Gtk_New (Filter_All);
      Filter_All.Set_Name ("All files");
      Filter_All.Add_Pattern ("*");
      Gtk.File_Chooser.Add_Filter (+Dlg, Filter_C64);
      Gtk.File_Chooser.Add_Filter (+Dlg, Filter_All);
      if Dlg.Run = Gtk_Response_Accept then
         Result := To_Unbounded_String
           (Gtk.File_Chooser.Get_Filename (+Dlg));
      end if;
      Dlg.Destroy;
      Keyboard.Release_All;
      return To_String (Result);
   end Choose_File;

   procedure Do_Autostart (Path : String) is
      Ok : Boolean;
   begin
      if Path = "" then
         return;
      end if;
      begin
         Machine.Autostart (Path, Ok);
      exception
         when others => Ok := False;
      end;
      if not Ok then
         Message ("Cannot open " & Path);
      end if;
      Show_VDC := Machine.Model = C128 and then Machine.Key_4080_Down;
      Sync_Menu;
   end Do_Autostart;

   procedure Do_Attach (Path : String) is
      Ok : Boolean;
   begin
      if Path = "" then
         return;
      end if;
      begin
         Machine.Attach (Path, Ok);
      exception
         when others => Ok := False;
      end;
      if not Ok then
         Message ("Cannot open " & Path);
      end if;
      Update_Status;
   end Do_Attach;

   procedure Toggle_Display is
   begin
      if Machine.Model = C128 then
         Show_VDC := not Show_VDC;
         Sync_Menu;
         Area.Queue_Draw;
      end if;
   end Toggle_Display;

   ---------------------------------------------------------------------
   --  Menu callbacks
   ---------------------------------------------------------------------

   procedure On_Autostart (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Do_Autostart (Choose_File ("Autostart disk/tape/program"));
   end On_Autostart;

   procedure On_Attach (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Do_Attach (Choose_File ("Attach image to drive 8"));
   end On_Attach;

   procedure On_Detach (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Machine.Detach;
      Update_Status;
   end On_Detach;

   procedure On_Attach_Cart (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
      Path : constant String := Choose_File ("Insert cartridge (.crt)");
      Ok : Boolean;
   begin
      if Path /= "" then
         begin
            Machine.Attach_Cartridge (Path, Ok);
         exception
            when others => Ok := False;
         end;
         if not Ok then
            Message ("Cannot use cartridge " & Path & ASCII.LF &
                     Machine.Error_Message);
         end if;
         Sync_Menu;
      end if;
   end On_Attach_Cart;

   procedure On_Detach_Cart (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Machine.Detach_Cartridge;
      Sync_Menu;
   end On_Detach_Cart;

   procedure On_Save_Snapshot (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Snapshot_Save (Choose_Save_File ("Save snapshot"));
   end On_Save_Snapshot;

   procedure On_Load_Snapshot (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Snapshot_Load (Choose_File ("Load snapshot"));
   end On_Load_Snapshot;

   procedure On_Quick_Save (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Snapshot_Save (Quick_Snapshot_Path);
   end On_Quick_Save;

   procedure On_Quick_Load (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Snapshot_Load (Quick_Snapshot_Path);
   end On_Quick_Load;

   procedure On_Quit (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Win.Destroy;
   end On_Quit;

   procedure On_Reset (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Machine.Reset;
      Show_VDC := Machine.Model = C128 and then Machine.Key_4080_Down;
      Sync_Menu;
   end On_Reset;

   procedure On_Model (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      if Gtk_Radio_Menu_Item (Item) = Item_C64 and then Machine.Model /= C64
      then
         Start_Machine (C64);
      elsif Gtk_Radio_Menu_Item (Item) = Item_C128
        and then Machine.Model /= C128
      then
         Start_Machine (C128);
      end if;
      Sync_Menu;
   end On_Model;

   procedure On_Warp (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if not Updating_Menu then
         Warp := Item.Get_Active;
         Update_Status;
      end if;
   end On_Warp;

   procedure On_Pause (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if not Updating_Menu then
         Paused := Item.Get_Active;
         Update_Status;
      end if;
   end On_Pause;

   procedure On_Show_VDC (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if not Updating_Menu then
         Show_VDC := Item.Get_Active;
         Update_Status;
         Area.Queue_Draw;
      end if;
   end On_Show_VDC;

   procedure On_4080 (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if not Updating_Menu then
         Machine.Key_4080_Down := Item.Get_Active;
         Update_Status;
      end if;
   end On_4080;

   procedure On_True_Drive
     (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if not Updating_Menu then
         Machine.Set_True_Drive (Item.Get_Active);
         Update_Status;
      end if;
   end On_True_Drive;

   procedure On_Mute (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      Audio.Muted := Item.Get_Active;
   end On_Mute;

   Joy_Items : array (Keyboard.Joy_Port) of Gtk_Radio_Menu_Item;
   Keyset_Keypad, Keyset_Cursor : Gtk_Radio_Menu_Item;

   procedure On_Joy (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      for P in Joy_Items'Range loop
         if Gtk_Radio_Menu_Item (Item) = Joy_Items (P) then
            Keyboard.Joystick_Port := P;
         end if;
      end loop;
      if Gtk_Radio_Menu_Item (Item) = Keyset_Keypad then
         Keyboard.Joystick_Keys := Keyboard.Keypad;
      elsif Gtk_Radio_Menu_Item (Item) = Keyset_Cursor then
         Keyboard.Joystick_Keys := Keyboard.Cursor_Keys;
      end if;
      Keyboard.Release_All;
      Update_Status;
   end On_Joy;

   procedure On_Swap_Joy (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      case Keyboard.Joystick_Port is
         when 1 => Joy_Items (2).Set_Active (True);
         when 2 => Joy_Items (1).Set_Active (True);
         when 0 => null;
      end case;
   end On_Swap_Joy;

   procedure On_Keys_Help (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Message
        ("Keyboard mapping (symbolic):" & ASCII.LF &
         "  Esc = RUN/STOP      PgUp = RESTORE" & ASCII.LF &
         "  Tab = C128 TAB      Left Alt = C= (Commodore)" & ASCII.LF &
         "  Home = CLR/HOME     End = SHIFT+CLR/HOME" & ASCII.LF &
         "  Insert = INST       Backspace/Delete = DEL" & ASCII.LF &
         "  F1-F8 = F1-F8       Ctrl = CTRL" & ASCII.LF &
         "  \ = Pound   _ or ` = Left arrow   ^ = Up arrow" & ASCII.LF &
         "  PgDn = C128 HELP    Pause = C128 ESC    Right Alt = C128 ALT"
         & ASCII.LF & ASCII.LF &
         "Joystick (keypad set): keypad 8/2/4/6 (+ diagonals 7/9/1/3)," &
         ASCII.LF & "  fire = keypad 0/5/Enter or Right Ctrl" & ASCII.LF &
         "Joystick (cursor set): arrow keys, fire = Right Ctrl/Right Alt" &
         ASCII.LF & ASCII.LF &
         "Host keys: F9 autostart, F10 40/80 column view (C128)," &
         ASCII.LF & "  F11 warp, F12 reset" & ASCII.LF & ASCII.LF &
         "Drive 8 without an image = the current directory (NAME.prg);" &
         ASCII.LF & "SAVE""NAME"",8 always writes NAME.prg there.");
   end On_Keys_Help;

   procedure On_About (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Message ("AdaC64" & ASCII.LF &
               "Commodore 64 / 128 emulator in Ada and GtkAda." & ASCII.LF &
               "CPU 6510/8502, VIC-II, SID, 2 x CIA, MMU, VDC 8563.");
   end On_About;

   ---------------------------------------------------------------------
   --  Event handlers
   ---------------------------------------------------------------------

   function On_Draw (Self : access Gtk_Widget_Record'Class;
                     Cr   : Cairo_Context) return Boolean
   is
      Src : constant Blit.Source :=
        (if Show_VDC then Blit.VDC_Screen else Blit.VIC_Screen);
      Surf : constant Cairo_Surface :=
        (if Show_VDC then VDC_Surf else VIC_Surf);
      W  : constant Float := Float (Self.Get_Allocated_Width);
      H  : constant Float := Float (Self.Get_Allocated_Height);
      SW : constant Float := Float (Blit.Width (Src));
      SH : constant Float := Float (Blit.Height (Src));
      Y_Aspect : constant Float := (if Show_VDC then 2.0 else 1.0);
      Scale : constant Float := Float'Min (W / SW, H / (SH * Y_Aspect));
      OX : constant Float := (W - SW * Scale) / 2.0;
      OY : constant Float := (H - SH * Scale * Y_Aspect) / 2.0;
   begin
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Paint (Cr);
      Translate (Cr, Gdouble (OX), Gdouble (OY));
      Cairo.Scale (Cr, Gdouble (Scale), Gdouble (Scale * Y_Aspect));
      Set_Source_Surface (Cr, Surf, 0.0, 0.0);
      Cairo.Pattern.Set_Filter (Get_Source (Cr), Cairo.Pattern.Cairo_Filter_Nearest);
      Paint (Cr);
      return True;
   end On_Draw;

   function On_Key_Press (Self  : access Gtk_Widget_Record'Class;
                          Event : Gdk_Event_Key) return Boolean
   is
      pragma Unreferenced (Self);
      KV : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Event.Keyval);
   begin
      if (Event.State and Gdk.Types.Shift_Mask) /= 0
        and then KV in 16#FFC6# | 16#FFC7#
      then
         Keyboard.Release_All;
         if KV = 16#FFC6# then
            Snapshot_Save (Quick_Snapshot_Path);     --  Shift+F9
         else
            Snapshot_Load (Quick_Snapshot_Path);     --  Shift+F10
         end if;
         return True;
      end if;
      case KV is
         when 16#FFC6# =>    --  F9
            Do_Autostart (Choose_File ("Autostart disk/tape/program"));
         when 16#FFC7# =>    --  F10
            Toggle_Display;
         when 16#FFC8# =>    --  F11
            Warp := not Warp;
            Sync_Menu;
         when 16#FFC9# =>    --  F12
            Machine.Reset;
            Sync_Menu;
         when others =>
            Keyboard.Key_Event (KV, Natural (Event.Hardware_Keycode), True);
      end case;
      return True;
   end On_Key_Press;

   function On_Key_Release (Self  : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Key) return Boolean
   is
      pragma Unreferenced (Self);
   begin
      Keyboard.Key_Event (Interfaces.Unsigned_32 (Event.Keyval),
                          Natural (Event.Hardware_Keycode), False);
      return True;
   end On_Key_Release;

   function On_Focus_Out (Self  : access Gtk_Widget_Record'Class;
                          Event : Gdk_Event_Focus) return Boolean
   is
      pragma Unreferenced (Self, Event);
   begin
      Keyboard.Release_All;
      return False;
   end On_Focus_Out;

   procedure On_Drop
     (Self    : access Gtk_Widget_Record'Class;
      Context : not null access Gdk.Drag_Contexts.Drag_Context_Record'Class;
      X, Y    : Gint;
      Data    : Gtk.Selection_Data.Gtk_Selection_Data;
      Info    : Guint;
      Time    : Guint)
   is
      pragma Unreferenced (Self, Context, X, Y, Info, Time);
      use type GNAT.Strings.String_Access;
      URIs : GNAT.Strings.String_List :=
        Gtk.Selection_Data.Get_Uris (Data);
   begin
      if URIs'Length > 0 and then URIs (URIs'First) /= null then
         declare
            Path : constant String :=
              Glib.Convert.Filename_From_URI (URIs (URIs'First).all, null);
         begin
            Do_Autostart (Path);
         end;
      end if;
      for U of URIs loop
         GNAT.Strings.Free (U);
      end loop;
   end On_Drop;

   procedure On_Destroy (Self : access Gtk_Widget_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Gtk.Main.Main_Quit;
   end On_Destroy;

   ---------------------------------------------------------------------
   --  Emulation pacing
   ---------------------------------------------------------------------


   function On_Timer return Boolean is
      Now : constant Time := Clock;
      Ran : Natural := 0;
   begin
      if Paused then
         return True;
      end if;

      if Warp or else Machine.Autostart_Busy then
         --  Run as fast as possible for ~15 ms of wall time
         declare
            Deadline : constant Time := Now + Milliseconds (15);
         begin
            loop
               Machine.Run_Frame;
               Ran := Ran + 1;
               exit when Clock >= Deadline;
            end loop;
         end;
         Audio.Flush;   --  samples beyond the ring capacity are dropped
         Start_Time := Clock;
         Frames_Run := 0;
      elsif Audio.Available then
         while Audio.Buffered < Audio_Target and then Ran < 4 loop
            Machine.Run_Frame;
            Audio.Flush;
            Ran := Ran + 1;
         end loop;
      else
         declare
            Elapsed : constant Duration := To_Duration (Now - Start_Time);
            Due : constant Integer :=
              Integer (Float (Elapsed) * 50.125) - Frames_Run;
         begin
            if Due > 10 then
               --  Fell far behind (e.g. modal dialog): resynchronise
               Start_Time := Now;
               Frames_Run := 0;
            end if;
            for F in 1 .. Integer'Min (Due, 3) loop
               Machine.Run_Frame;
               Audio.Flush;
               Ran := Ran + 1;
               Frames_Run := Frames_Run + 1;
            end loop;
         end;
      end if;

      if Ran > 0 then
         --  Follow the C128 KERNAL's active screen (MODE flag at $D7)
         if Machine.Model = C128 then
            declare
               Now_VDC : constant Boolean :=
                 not Machine.In_C64_Mode
                 and then (Machine.Peek (16#D7#) and 16#80#) /= 0;
            begin
               if Now_VDC /= Was_VDC then
                  Was_VDC := Now_VDC;
                  Show_VDC := Now_VDC;
                  Sync_Menu;
               end if;
            end;
         end if;
         if Show_VDC then
            Blit.Copy (Blit.VDC_Screen, VDC_Surf);
         else
            Blit.Copy (Blit.VIC_Screen, VIC_Surf);
         end if;
         Area.Queue_Draw;
         FPS_Frames := FPS_Frames + Ran;
      end if;

      if Now - LED_Time >= Milliseconds (200) then
         LED_Time := Now;
         if Machine.Drive_Active then
            Update_Status;
         end if;
      end if;

      if Now - FPS_Time >= Seconds (1) then
         FPS := FPS_Frames;
         FPS_Frames := 0;
         FPS_Time := Now;
         Update_Status;
      end if;
      return True;
   end On_Timer;

   ---------------------------------------------------------------------
   --  Construction
   ---------------------------------------------------------------------

   function Add_Menu (Bar : Gtk_Menu_Bar; Title : String) return Gtk_Menu is
      Item : Gtk_Menu_Item;
      Menu : Gtk_Menu;
   begin
      Gtk_New_With_Mnemonic (Item, Title);
      Gtk_New (Menu);
      Item.Set_Submenu (Menu);
      Bar.Append (Item);
      return Menu;
   end Add_Menu;

   procedure Add_Item (Menu : Gtk_Menu; Label : String;
                       Cb : Cb_Gtk_Menu_Item_Void) is
      Item : Gtk_Menu_Item;
   begin
      Gtk_New_With_Mnemonic (Item, Label);
      Item.On_Activate (Cb);
      Menu.Append (Item);
   end Add_Item;

   procedure Add_Check (Menu : Gtk_Menu; Label : String;
                        Item : out Gtk_Check_Menu_Item;
                        Cb : Cb_Gtk_Check_Menu_Item_Void) is
   begin
      Gtk_New_With_Mnemonic (Item, Label);
      Item.On_Toggled (Cb);
      Menu.Append (Item);
   end Add_Check;

   procedure Add_Separator (Menu : Gtk_Menu) is
      Sep : Gtk_Separator_Menu_Item;
   begin
      Gtk_New (Sep);
      Menu.Append (Sep);
   end Add_Separator;

   procedure Add_Radio (Menu : Gtk_Menu; Label : String;
                        Group : in out Widget_SList.GSlist;
                        Item : out Gtk_Radio_Menu_Item;
                        Cb : Cb_Gtk_Check_Menu_Item_Void) is
   begin
      Gtk_New (Item, Group, Label);
      Group := Item.Get_Group;
      Item.On_Toggled (Cb);
      Menu.Append (Item);
   end Add_Radio;

   procedure Run (Model : Machine.Model_Type; ROM_Dir : String;
                  File : String) is
      VBox : Gtk_Box;
      Bar  : Gtk_Menu_Bar;
      M_File, M_Machine, M_Input, M_Help : Gtk_Menu;
      Mute : Gtk_Check_Menu_Item;
      pragma Warnings (Off, Mute);
      Model_Group, Joy_Group, Keyset_Group : Widget_SList.GSlist :=
        Widget_SList.Null_List;
      Timer : Glib.Main.G_Source_Id;
      pragma Unreferenced (Timer);
   begin
      ROMs := To_Unbounded_String (ROM_Dir);
      Gtk.Main.Init;

      Gtk_New (Win);
      Win.Set_Title ("AdaC64");
      Win.Set_Default_Size (800, 640);
      Win.On_Destroy (On_Destroy'Access);
      Win.On_Key_Press_Event (On_Key_Press'Access);
      Win.On_Key_Release_Event (On_Key_Release'Access);
      Win.On_Focus_Out_Event (On_Focus_Out'Access);

      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Bar);
      VBox.Pack_Start (Bar, Expand => False, Fill => False);

      M_File := Add_Menu (Bar, "_File");
      Add_Item (M_File, "_Autostart image... (F9)", On_Autostart'Access);
      Add_Item (M_File, "Attach image to _drive 8...", On_Attach'Access);
      Add_Item (M_File, "D_etach image (use host directory)",
                On_Detach'Access);
      Add_Separator (M_File);
      Add_Item (M_File, "Insert _cartridge...", On_Attach_Cart'Access);
      Add_Item (M_File, "Remove cartridge", On_Detach_Cart'Access);
      Add_Separator (M_File);
      Add_Check (M_File, "True 1541 drive emulation (D64)", Item_TDE,
                 On_True_Drive'Access);
      Add_Separator (M_File);
      Add_Item (M_File, "_Quit", On_Quit'Access);

      M_Machine := Add_Menu (Bar, "_Machine");
      Add_Radio (M_Machine, "Commodore 64", Model_Group, Item_C64,
                 On_Model'Access);
      Add_Radio (M_Machine, "Commodore 128", Model_Group, Item_C128,
                 On_Model'Access);
      Add_Separator (M_Machine);
      Add_Item (M_Machine, "_Reset (F12)", On_Reset'Access);
      Add_Separator (M_Machine);
      Add_Item (M_Machine, "Save _snapshot...", On_Save_Snapshot'Access);
      Add_Item (M_Machine, "_Load snapshot...", On_Load_Snapshot'Access);
      Add_Item (M_Machine, "_Quick save (Shift+F9)", On_Quick_Save'Access);
      Add_Item (M_Machine, "Quick _load (Shift+F10)", On_Quick_Load'Access);
      Add_Separator (M_Machine);
      Add_Check (M_Machine, "_Pause", Item_Pause, On_Pause'Access);
      Add_Check (M_Machine, "_Warp mode (F11)", Item_Warp, On_Warp'Access);
      Add_Check (M_Machine, "_Mute sound", Mute, On_Mute'Access);
      Add_Separator (M_Machine);
      Add_Check (M_Machine, "C128: 40/80 key down (boot in 80 columns)",
                 Item_4080, On_4080'Access);
      Add_Check (M_Machine, "C128: show 80-column VDC screen (F10)",
                 Item_VDC, On_Show_VDC'Access);

      M_Input := Add_Menu (Bar, "_Input");
      Add_Radio (M_Input, "No joystick", Joy_Group, Joy_Items (0),
                 On_Joy'Access);
      Add_Radio (M_Input, "Joystick in port 1", Joy_Group, Joy_Items (1),
                 On_Joy'Access);
      Add_Radio (M_Input, "Joystick in port 2", Joy_Group, Joy_Items (2),
                 On_Joy'Access);
      Add_Item (M_Input, "_Swap joystick port", On_Swap_Joy'Access);
      Add_Separator (M_Input);
      Add_Radio (M_Input, "Joystick on keypad + Right Ctrl", Keyset_Group,
                 Keyset_Keypad, On_Joy'Access);
      Add_Radio (M_Input, "Joystick on cursor keys + Right Ctrl",
                 Keyset_Group, Keyset_Cursor, On_Joy'Access);

      M_Help := Add_Menu (Bar, "_Help");
      Add_Item (M_Help, "_Keyboard", On_Keys_Help'Access);
      Add_Item (M_Help, "_About", On_About'Access);

      Gtk_New (Area);
      Area.Set_Size_Request (384, 272);
      Area.On_Draw (On_Draw'Access);
      Gtk.Dnd.Dest_Set (Area, Gtk.Dnd.Dest_Default_All,
                        Actions => Gdk.Drag_Contexts.Action_Copy);
      Gtk.Dnd.Dest_Add_Uri_Targets (Area);
      Area.On_Drag_Data_Received (On_Drop'Access);
      VBox.Pack_Start (Area, Expand => True, Fill => True);

      Gtk_New (Status, "");
      Status.Set_Halign (Gtk.Widget.Align_Start);
      Status.Set_Margin_Start (6);
      VBox.Pack_Start (Status, Expand => False, Fill => False, Padding => 2);

      VIC_Surf := Cairo.Image_Surface.Create
        (Cairo.Image_Surface.Cairo_Format_RGB24,
         Gint (Blit.Width (Blit.VIC_Screen)),
         Gint (Blit.Height (Blit.VIC_Screen)));
      VDC_Surf := Cairo.Image_Surface.Create
        (Cairo.Image_Surface.Cairo_Format_RGB24,
         Gint (Blit.Width (Blit.VDC_Screen)),
         Gint (Blit.Height (Blit.VDC_Screen)));

      SID.Sink := Audio.Push'Access;
      Audio.Start;

      Updating_Menu := True;
      Joy_Items (2).Set_Active (True);
      Keyset_Keypad.Set_Active (True);
      Updating_Menu := False;

      Start_Machine (Model);
      if File /= "" then
         Do_Autostart (File);
      end if;
      Sync_Menu;

      Win.Show_All;
      Timer := Glib.Main.Timeout_Add (4, On_Timer'Access);
      Gtk.Main.Main;
      Machine.Shutdown;
      Audio.Stop;
   end Run;

end GUI;
