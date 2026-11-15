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
use type SID.Chip_Model;
with Blit;
with Video;
with Paddles; use type Paddles.Mode_Kind;
with Monitor;
with Forge;
with Settings;
with Tape;
with Drive1541;
use type Drive1541.Drive_Model;
with REU;
use type REU.Size_KB;
use type Keyboard.Joy_Keyset;
with Gtk.Clipboard;
with Gdk.Property;
with Pango.Layout;
with Host_Joystick;
with Disasm;

package body GUI is

   Win      : Gtk_Window;
   Bar      : Gtk_Menu_Bar;
   Is_Fullscreen : Boolean := False;
   Integer_Scale : Boolean := False;
   CRT_Filter    : Boolean := False;
   Last_Dir      : Unbounded_String;
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
   Item_FastLd  : Gtk_Check_Menu_Item;
   Item_C64, Item_C128, Item_VIC20 : Gtk_Radio_Menu_Item;
   V20_Items : array (Machine.VIC20_Memory) of Gtk_Radio_Menu_Item;
   Paddle_Items : array (Paddles.Mode_Kind) of Gtk_Radio_Menu_Item;
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

   function V20_Mem_Name return String is
     (case Machine.VIC20_Memory_Config is
        when Machine.Unexpanded => "",
        when Machine.Plus_3K => " +3K",
        when Machine.Plus_8K => " +8K",
        when Machine.Plus_16K => " +16K",
        when Machine.Plus_24K => " +24K",
        when Machine.Plus_35K => " +35K");

   function Model_Name return String is
     (case Machine.Model is
        when C64 => "C64",
        when C128 => (if Machine.In_C64_Mode then "C128 (C64 mode)"
                      else "C128"),
        when VIC20 => "VIC-20" & V20_Mem_Name);

   function Short (S : String) return String is
     (if S'Length > 24 then S (S'First .. S'First + 21) & ".." else S);

   procedure Update_Status is
      Drive_Str : constant String :=
        (if Machine.Drive_Active then
            (if Machine.Drive_Type = Drive1541.D1571 then "1571 "
             else "1541 ") & (if Machine.Drive_LED then "[*]" else "[ ]") &
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
         (if Tape.Present then
             "  |  tape" & Tape.Counter'Image & "%" &
             (if Tape.Motor and then Tape.Playing then " >" else "")
          else "") &
         (if Machine.Cartridge_Name /= "" then
             "  |  cart: " & Ada.Strings.Fixed.Trim
               (Machine.Cartridge_Name, Ada.Strings.Right)
          else "") &
         (if Machine.Model = C128 then
             (if Show_VDC then "  |  80 col" else "  |  40 col")
          else "") &
         "  |  joy port" & Keyboard.Joystick_Port'Image &
         (if Host_Joystick.Selected >= 0
          then " (" & Short (Host_Joystick.Name (Host_Joystick.Selected)) & ")"
          else "") &
         "  |  F9 autostart  F10 40/80  F11 warp  F12 reset (Ctrl: hard)  Shift+F9/F10 quick save/load");
   end Update_Status;

   procedure Sync_Menu is
   begin
      Updating_Menu := True;
      Item_VDC.Set_Active (Show_VDC);
      Item_Warp.Set_Active (Warp);
      Item_4080.Set_Active (Machine.Key_4080_Down);
      Item_Pause.Set_Active (Paused);
      Item_TDE.Set_Active (Machine.True_Drive);
      Item_FastLd.Set_Active (Machine.Fast_Kernal_Load);
      Item_TDE.Set_Sensitive (Machine.Drive_ROM_Found);
      case Machine.Model is
         when C64 => Item_C64.Set_Active (True);
         when C128 => Item_C128.Set_Active (True);
         when VIC20 => Item_VIC20.Set_Active (True);
      end case;
      V20_Items (Machine.VIC20_Memory_Config).Set_Active (True);
      if Paddle_Items (Paddles.Mode) /= null then
         Paddle_Items (Paddles.Mode).Set_Active (True);
      end if;
      for M in Machine.VIC20_Memory loop
         V20_Items (M).Set_Sensitive (Machine.Model = VIC20);
      end loop;
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

   type Ext_List is array (1 .. 10) of String (1 .. 3);
   Extensions : constant Ext_List :=
     ("d64", "d71", "g64", "t64", "tap", "prg", "crt", "bin", "rom", "a0 ");

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
      Filter_C64.Set_Name
        ("Commodore files (d64, d71, g64, t64, tap, prg, crt, bin, rom)");
      for Ext of Extensions loop
         Filter_C64.Add_Pattern
           ("*." & Ada.Strings.Fixed.Trim (Ext, Ada.Strings.Right));
         Filter_C64.Add_Pattern
           ("*." & Ada.Characters.Handling.To_Upper
              (Ada.Strings.Fixed.Trim (Ext, Ada.Strings.Right)));
      end loop;
      Gtk_New (Filter_All);
      Filter_All.Set_Name ("All files");
      Filter_All.Add_Pattern ("*");
      Gtk.File_Chooser.Add_Filter (+Dlg, Filter_C64);
      Gtk.File_Chooser.Add_Filter (+Dlg, Filter_All);
      if Length (Last_Dir) > 0 then
         declare
            Ok : constant Boolean :=
              Gtk.File_Chooser.Set_Current_Folder (+Dlg, To_String (Last_Dir));
            pragma Unreferenced (Ok);
         begin
            null;
         end;
      end if;
      if Dlg.Run = Gtk_Response_Accept then
         Result := To_Unbounded_String
           (Gtk.File_Chooser.Get_Filename (+Dlg));
         begin
            Last_Dir := To_Unbounded_String
              (Ada.Directories.Containing_Directory (To_String (Result)));
         exception
            when others => null;
         end;
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
      Path : constant String :=
        Choose_File (if Machine.Model = VIC20
                     then "Insert VIC-20 cartridge (.crt, .prg, .bin, .rom)"
                     else "Insert cartridge (.crt)");
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

   procedure Refresh_Screen is
   begin
      if Show_VDC then
         Blit.Copy (Blit.VDC_Screen, VDC_Surf);
      else
         Blit.Copy (Blit.VIC_Screen, VIC_Surf);
      end if;
      Area.Queue_Draw;
   end Refresh_Screen;

   procedure On_Monitor (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Keyboard.Release_All;
      Monitor.Open (Win, "stopped");
   end On_Monitor;

   procedure Toggle_Fullscreen is
   begin
      Is_Fullscreen := not Is_Fullscreen;
      if Is_Fullscreen then
         Bar.Hide;
         Status.Hide;
         Win.Fullscreen;
      else
         Win.Unfullscreen;
         Bar.Show;
         Status.Show;
      end if;
   end Toggle_Fullscreen;

   procedure Paste_Text is
      Clip : constant Gtk.Clipboard.Gtk_Clipboard :=
        Gtk.Clipboard.Get (Gdk.Property.Atom_Intern ("CLIPBOARD"));
      Text : constant String := Clip.Wait_For_Text;
      Clean : Unbounded_String;
   begin
      for C of Text loop
         if C = ASCII.LF or else C in ' ' .. '~' then
            Append (Clean, C);
         end if;
      end loop;
      if Machine.Z80_Used then
         Keyboard.Type_Keys (To_String (Clean));     --  CP/M scans the matrix
      else
         Machine.Type_Text (To_String (Clean));      --  KERNAL buffer
      end if;
   exception
      when others => null;
   end Paste_Text;

   procedure On_Fullscreen (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Toggle_Fullscreen;
   end On_Fullscreen;

   procedure On_Integer_Scale
     (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      Integer_Scale := Item.Get_Active;
      Area.Queue_Draw;
   end On_Integer_Scale;

   procedure On_CRT (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      CRT_Filter := Item.Get_Active;
      Area.Queue_Draw;
   end On_CRT;

   procedure On_Positional
     (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      Keyboard.Positional := Item.Get_Active;
      Keyboard.Release_All;
   end On_Positional;

   procedure On_Paste (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Paste_Text;
   end On_Paste;

   type REU_Choice is range 0 .. 5;
   REU_Sizes : constant array (REU_Choice) of REU.Size_KB :=
     (0, 128, 256, 512, 2048, 16384);
   REU_Items : array (REU_Choice) of Gtk_Radio_Menu_Item;

   procedure On_REU (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      for C in REU_Items'Range loop
         if Gtk_Radio_Menu_Item (Item) = REU_Items (C) then
            REU.Set_Size (REU_Sizes (C));
            Machine.Reset;
            Sync_Menu;
         end if;
      end loop;
   end On_REU;

   Item_1541, Item_1571 : Gtk_Radio_Menu_Item;

   procedure On_Drive_Type (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      if Gtk_Radio_Menu_Item (Item) = Item_1571 then
         if not Drive1541.Has_ROM (Drive1541.D1571) then
            Message ("No 1571 ROM found (roms/drives/1571-rom.310654-05.bin" &
                     " or <roms>/DRIVES/dos1571).");
            Updating_Menu := True;
            Item_1541.Set_Active (True);
            Updating_Menu := False;
            return;
         end if;
         Machine.Set_Drive_Type (Drive1541.D1571);
      else
         Machine.Set_Drive_Type (Drive1541.D1541);
      end if;
      Update_Status;
   end On_Drive_Type;

   Item_PAL, Item_NTSC : Gtk_Radio_Menu_Item;

   procedure On_Standard (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      Machine.Set_Video_Standard
        (if Gtk_Radio_Menu_Item (Item) = Item_NTSC then Machine.NTSC
         else Machine.PAL);
      Machine.Reset;
      Start_Time := Clock;
      Frames_Run := 0;
      Sync_Menu;
   end On_Standard;

   Item_6581, Item_8580 : Gtk_Radio_Menu_Item;

   procedure On_SID_Model (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      SID.Set_Model (if Gtk_Radio_Menu_Item (Item) = Item_8580
                     then SID.MOS8580 else SID.MOS6581);
   end On_SID_Model;

   procedure Save_Settings is
   begin
      Forge.Save_State;
      Settings.Set ("sid", (if SID.Model = SID.MOS8580 then "8580" else "6581"));
      Settings.Set ("standard",
                    (if Machine.Standard = Machine.NTSC then "ntsc" else "pal"));
      Settings.Set ("drive", (if Machine.Drive_Type = Drive1541.D1571
                              then "1571" else "1541"));
      Settings.Set ("reu", Integer (REU.Size));
      Settings.Set ("model", (case Machine.Model is
                                 when C128 => "c128", when VIC20 => "vic20",
                                 when C64 => "c64"));
      Settings.Set ("vic20mem",
                    Machine.VIC20_Memory'Image (Machine.VIC20_Memory_Config));
      Settings.Set ("key4080", Machine.Key_4080_Down);
      Settings.Set ("joyport", Integer (Keyboard.Joystick_Port));
      Settings.Set ("joykeys",
                    (if Keyboard.Joystick_Keys = Keyboard.Keypad
                     then "keypad" else "cursor"));
      Settings.Set ("controller",
                    (if Host_Joystick.Selected >= 0
                     then Host_Joystick.Name (Host_Joystick.Selected)
                     else "none"));
      Settings.Set ("truedrive", Machine.True_Drive);
      Settings.Set ("fastload", Machine.Fast_Kernal_Load);
      Settings.Set ("mute", Audio.Muted);
      Settings.Set ("positional", Keyboard.Positional);
      Settings.Set ("paddles", Paddles.Mode_Kind'Image (Paddles.Mode));
      Settings.Set ("integerscale", Integer_Scale);
      Settings.Set ("crt", CRT_Filter);
      Settings.Set ("lastdir", To_String (Last_Dir));
      declare
         W, H : Gint;
      begin
         Win.Get_Size (W, H);
         if not Is_Fullscreen then
            Settings.Set ("width", Integer (W));
            Settings.Set ("height", Integer (H));
         end if;
      end;
      Settings.Save;
   end Save_Settings;

   procedure On_Attach_Tape (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
      Path : constant String := Choose_File ("Insert tape (.tap)");
      Ok : Boolean;
   begin
      if Path /= "" then
         Tape.Attach (Path, Ok);
         if not Ok then
            Message ("Not a TAP image: " & Path);
         end if;
         Update_Status;
      end if;
   end On_Attach_Tape;

   procedure On_Tape_Play (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Tape.Play;
   end On_Tape_Play;

   procedure On_Tape_Stop (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Tape.Stop;
   end On_Tape_Stop;

   procedure On_Tape_Rewind (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Tape.Rewind;
   end On_Tape_Rewind;

   procedure On_Quit (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Win.Destroy;
   end On_Quit;

   procedure On_Reset (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Machine.Reset (Hard => False);
      Show_VDC := Machine.Model = C128 and then Machine.Key_4080_Down;
      Sync_Menu;
   end On_Reset;

   procedure On_Hard_Reset (Item : access Gtk_Menu_Item_Record'Class) is
      pragma Unreferenced (Item);
   begin
      Machine.Reset (Hard => True);
      Show_VDC := Machine.Model = C128 and then Machine.Key_4080_Down;
      Sync_Menu;
   end On_Hard_Reset;

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
      elsif Gtk_Radio_Menu_Item (Item) = Item_VIC20
        and then Machine.Model /= VIC20
      then
         Start_Machine (VIC20);
      end if;
      Sync_Menu;
   end On_Model;

   procedure On_V20_Memory (Item : access Gtk_Check_Menu_Item_Record'Class)
   is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      for M in Machine.VIC20_Memory loop
         if Gtk_Radio_Menu_Item (Item) = V20_Items (M)
           and then M /= Machine.VIC20_Memory_Config
         then
            Machine.Set_VIC20_Memory (M);
            if Machine.Model = VIC20 then
               Machine.Reset;          --  the KERNAL sizes RAM at power-on
            end if;
         end if;
      end loop;
      Sync_Menu;
   end On_V20_Memory;

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

   procedure On_Fast_Load (Item : access Gtk_Check_Menu_Item_Record'Class)
   is
   begin
      if not Updating_Menu then
         Machine.Fast_Kernal_Load := Item.Get_Active;
      end if;
   end On_Fast_Load;

   procedure On_Mute (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      Audio.Muted := Item.Get_Active;
   end On_Mute;

   Joy_Items : array (Keyboard.Joy_Port) of Gtk_Radio_Menu_Item;
   Host_Items : array (-1 .. Host_Joystick.Max_Devices - 1)
     of Gtk_Radio_Menu_Item;

   procedure On_Host_Joy (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      for I in Host_Items'Range loop
         if Host_Items (I) /= null
           and then Gtk_Radio_Menu_Item (Item) = Host_Items (I)
         then
            if I < 0 then
               Host_Joystick.Close;
            else
               Host_Joystick.Open (I);
            end if;
         end if;
      end loop;
      Update_Status;
   end On_Host_Joy;
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
         ASCII.LF & "  F11 warp, F12 soft reset, Ctrl+F12 hard reset" & ASCII.LF & ASCII.LF &
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

   --  Where the picture was drawn last (for paddles on the mouse)
   Pic_X, Pic_Y : Float := 0.0;
   Pic_W, Pic_H : Float := 1.0;

   function On_Area_Motion (Self : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
   begin
      Paddles.Set_Mouse ((Float (Event.X) - Pic_X) / Pic_W,
                         (Float (Event.Y) - Pic_Y) / Pic_H);
      return False;
   end On_Area_Motion;

   function On_Area_Button (Self : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
   begin
      if Paddles.Mode = Paddles.Mouse and then Event.Button in 1 | 3 then
         Paddles.Set_Mouse_Button ((if Event.Button = 1 then 1 else 2),
                                   Event.The_Type = Button_Press);
         return True;
      end if;
      return False;
   end On_Area_Button;

   procedure On_Paddles (Item : access Gtk_Check_Menu_Item_Record'Class) is
   begin
      if Updating_Menu or else not Item.Get_Active then
         return;
      end if;
      for M in Paddles.Mode_Kind loop
         if Gtk_Radio_Menu_Item (Item) = Paddle_Items (M) then
            Paddles.Mode := M;
            Paddles.Fire := (others => False);
         end if;
      end loop;
   end On_Paddles;

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
      X_Aspect : constant Float := (if Show_VDC then 1.0 else Video.X_Aspect);
      Fit : constant Float :=
        Float'Min (W / (SW * X_Aspect), H / (SH * Y_Aspect));
      Scale : constant Float :=
        (if Integer_Scale and then Fit >= 1.0 then Float'Floor (Fit) else Fit);
      OX : constant Float := Float'Floor ((W - SW * Scale * X_Aspect) / 2.0);
      OY : constant Float := Float'Floor ((H - SH * Scale * Y_Aspect) / 2.0);
   begin
      Pic_X := OX;
      Pic_Y := OY;
      Pic_W := SW * Scale * X_Aspect;
      Pic_H := SH * Scale * Y_Aspect;
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Paint (Cr);
      Translate (Cr, Gdouble (OX), Gdouble (OY));
      Cairo.Scale (Cr, Gdouble (Scale * X_Aspect), Gdouble (Scale * Y_Aspect));
      Rectangle (Cr, 0.0, 0.0, Gdouble (SW), Gdouble (SH));
      Clip (Cr);
      Set_Source_Surface (Cr, Surf, 0.0, 0.0);
      Cairo.Pattern.Set_Filter (Get_Source (Cr), Cairo.Pattern.Cairo_Filter_Nearest);
      Paint (Cr);
      if CRT_Filter and then Scale * Y_Aspect >= 2.0 then
         --  Darken the lower part of every emulated scanline
         Cairo.Identity_Matrix (Cr);
         Set_Source_Rgba (Cr, 0.0, 0.0, 0.0, 0.35);
         declare
            LH : constant Float := Scale * Y_Aspect;
         begin
            for Y in 0 .. Natural (SH) - 1 loop
               Rectangle (Cr, Gdouble (OX),
                          Gdouble (OY + (Float (Y) + 0.55) * LH),
                          Gdouble (SW * Scale * X_Aspect), Gdouble (0.45 * LH));
            end loop;
         end;
         Fill (Cr);
      end if;
      return True;
   end On_Draw;

   function On_Key_Press (Self  : access Gtk_Widget_Record'Class;
                          Event : Gdk_Event_Key) return Boolean
   is
      pragma Unreferenced (Self);
      KV : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Event.Keyval);
   begin
      if (Event.State and Gdk.Types.Mod1_Mask) /= 0 and then KV = 16#FF0D# then
         Keyboard.Release_All;
         Toggle_Fullscreen;                          --  Alt+Return
         return True;
      end if;
      if (Event.State and Gdk.Types.Control_Mask) /= 0
        and then (Event.State and Gdk.Types.Shift_Mask) /= 0
        and then KV in Character'Pos ('V') | Character'Pos ('v')
      then
         Keyboard.Release_All;
         Paste_Text;                                 --  Ctrl+Shift+V
         return True;
      end if;
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
         when 16#FFC9# =>    --  F12 (Shift+F12: monitor)
            if (Event.State and Gdk.Types.Shift_Mask) /= 0 then
               Keyboard.Release_All;
               Monitor.Open (Win, "stopped");
            else
               --  F12: reset button; Ctrl+F12: power off and on
               Machine.Reset
                 (Hard => (Event.State and Gdk.Types.Control_Mask) /= 0);
               Sync_Menu;
            end if;
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
      Save_Settings;
      Gtk.Main.Main_Quit;
   end On_Destroy;

   --  In the forge the emulator window only hides; the forge quits
   function On_Win_Delete (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if Open_Forge then
         Win.Hide;
         return True;
      end if;
      return False;
   end On_Win_Delete;

   procedure Quit_App is
   begin
      Win.Destroy;
   end Quit_App;

   ---------------------------------------------------------------------
   --  Emulation pacing
   ---------------------------------------------------------------------


   function On_Timer_Data (Unused : Integer) return Boolean;

   package Timer_Sources is new Glib.Main.Generic_Sources (Integer);

   function On_Timer return Boolean is
      Now : constant Time := Clock;
      Ran : Natural := 0;
   begin
      Host_Joystick.Poll;
      if Paused or else Monitor.Active then
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
              Integer (Float (Elapsed) * Machine.Frame_Rate) - Frames_Run;
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

      if Forge.Is_Open then
         Forge.Tick;
      end if;
      if Machine.Break_Hit and then not Monitor.Active
        and then not Forge.Is_Open
      then
         Keyboard.Release_All;
         Refresh_Screen;
         Monitor.Open (Win, "breakpoint at $" &
                         Disasm.Hex4 (Machine.CPU_PC));
         return True;
      end if;

      if Ran > 0 then
         --  Follow the C128 KERNAL's active screen (MODE flag at $D7)
         if Machine.Model = C128 then
            declare
               --  Under CP/M (Z80) $D7 is not the KERNAL's MODE flag; the
               --  CP/M BIOS uses the screen selected by the 40/80 key.
               Now_VDC : constant Boolean :=
                 not Machine.In_C64_Mode
                 and then (if Machine.Z80_Used then Machine.Key_4080_Down
                           else (Machine.Peek (16#D7#) and 16#80#) /= 0);
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

   function On_Timer_Data (Unused : Integer) return Boolean is
     (On_Timer);

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
                  File : String;
                  Model_Given : Boolean := False;
                  Key80_Given : Boolean := False;
                  REU_Given : Boolean := False) is
      VBox : Gtk_Box;
      M_File, M_Machine, M_Input, M_View, M_Help : Gtk_Menu;
      Mute, Item_Pos, Item_Int, Item_CRT : Gtk_Check_Menu_Item;
      Start_Model : Model_Type := Model;
      Model_Group, Joy_Group, Keyset_Group, Host_Group, REU_Group,
      Drive_Group, Std_Group, SID_Group, V20_Group, Paddle_Group :
        Widget_SList.GSlist :=
        Widget_SList.Null_List;
      Timer : Glib.Main.G_Source_Id;
      pragma Unreferenced (Timer);
   begin
      ROMs := To_Unbounded_String (ROM_Dir);
      Gtk.Main.Init;

      --  Settings (command-line options take precedence)
      Settings.Load;
      if not Model_Given then
         Start_Model := (if Settings.Get ("model", "c64") = "c128" then C128
                         elsif Settings.Get ("model", "c64") = "vic20" then VIC20
                         else C64);
      end if;
      begin
         Machine.Set_VIC20_Memory
           (Machine.VIC20_Memory'Value
              (Settings.Get ("vic20mem", "UNEXPANDED")));
      exception
         when Constraint_Error => null;
      end;
      if not Key80_Given then
         Machine.Key_4080_Down := Settings.Get ("key4080", False);
      end if;
      Machine.True_Drive := Settings.Get ("truedrive", Machine.True_Drive);
      Machine.Fast_Kernal_Load :=
        Settings.Get ("fastload", Machine.Fast_Kernal_Load);
      Audio.Muted := Settings.Get ("mute", False);
      Keyboard.Positional := Settings.Get ("positional", False);
      if not Paddles_Given then
         begin
            Paddles.Mode :=
              Paddles.Mode_Kind'Value (Settings.Get ("paddles", "OFF"));
         exception
            when Constraint_Error => null;
         end;
      end if;
      Integer_Scale := Settings.Get ("integerscale", False);
      CRT_Filter := Settings.Get ("crt", False);
      Last_Dir := To_Unbounded_String (Settings.Get ("lastdir", ""));

      Gtk_New (Win);
      Win.Set_Title ("AdaC64");
      Win.Set_Default_Size (Gint (Settings.Get ("width", 800)),
                            Gint (Settings.Get ("height", 640)));
      Win.On_Destroy (On_Destroy'Access);
      Win.On_Delete_Event (On_Win_Delete'Access);
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
      Add_Item (M_File, "Insert _tape (.tap)...", On_Attach_Tape'Access);
      Add_Item (M_File, "Tape: play", On_Tape_Play'Access);
      Add_Item (M_File, "Tape: stop", On_Tape_Stop'Access);
      Add_Item (M_File, "Tape: rewind", On_Tape_Rewind'Access);
      Add_Separator (M_File);
      Add_Item (M_File, "Insert _cartridge...", On_Attach_Cart'Access);
      Add_Item (M_File, "Remove cartridge", On_Detach_Cart'Access);
      Add_Separator (M_File);
      Add_Check (M_File, "True drive emulation (D64/D71/G64)", Item_TDE,
                 On_True_Drive'Access);
      Add_Radio (M_File, "Drive 8 is a 1541", Drive_Group, Item_1541,
                 On_Drive_Type'Access);
      Add_Radio (M_File, "Drive 8 is a 1571 (C128 burst mode)", Drive_Group,
                 Item_1571, On_Drive_Type'Access);
      Add_Check (M_File, "Fast KERNAL loading (with true drive)",
                 Item_FastLd, On_Fast_Load'Access);
      Add_Separator (M_File);
      Add_Item (M_File, "_Quit", On_Quit'Access);

      M_Machine := Add_Menu (Bar, "_Machine");
      Add_Radio (M_Machine, "Commodore 64", Model_Group, Item_C64,
                 On_Model'Access);
      Add_Radio (M_Machine, "Commodore 128", Model_Group, Item_C128,
                 On_Model'Access);
      Add_Radio (M_Machine, "Commodore VIC-20", Model_Group, Item_VIC20,
                 On_Model'Access);
      for M in Machine.VIC20_Memory loop
         Add_Radio (M_Machine,
                    "   VIC-20 RAM: " &
                    (case M is
                       when Machine.Unexpanded => "unexpanded (5K)",
                       when Machine.Plus_3K => "+3K",
                       when Machine.Plus_8K => "+8K",
                       when Machine.Plus_16K => "+16K",
                       when Machine.Plus_24K => "+24K",
                       when Machine.Plus_35K => "+35K (all blocks)"),
                    V20_Group, V20_Items (M), On_V20_Memory'Access);
      end loop;
      Add_Radio (M_Machine, "PAL (Europe, 50 Hz)", Std_Group, Item_PAL,
                 On_Standard'Access);
      Add_Radio (M_Machine, "NTSC (America, 60 Hz)", Std_Group, Item_NTSC,
                 On_Standard'Access);
      Add_Radio (M_Machine, "SID 6581 (original C64)", SID_Group, Item_6581,
                 On_SID_Model'Access);
      Add_Radio (M_Machine, "SID 8580 (C64C / C128DCR)", SID_Group, Item_8580,
                 On_SID_Model'Access);
      Add_Separator (M_Machine);
      Add_Item (M_Machine, "_Soft reset (F12)", On_Reset'Access);
      Add_Item (M_Machine, "_Hard reset (Ctrl+F12)", On_Hard_Reset'Access);
      Add_Separator (M_Machine);
      Add_Item (M_Machine, "Save _snapshot...", On_Save_Snapshot'Access);
      Add_Item (M_Machine, "_Load snapshot...", On_Load_Snapshot'Access);
      Add_Item (M_Machine, "Mo_nitor (Shift+F12)", On_Monitor'Access);
      Add_Item (M_Machine, "Paste text (Ctrl+Shift+V)", On_Paste'Access);
      Add_Item (M_Machine, "_Quick save (Shift+F9)", On_Quick_Save'Access);
      Add_Item (M_Machine, "Quick _load (Shift+F10)", On_Quick_Load'Access);
      Add_Separator (M_Machine);
      Add_Check (M_Machine, "_Pause", Item_Pause, On_Pause'Access);
      Add_Check (M_Machine, "_Warp mode (F11)", Item_Warp, On_Warp'Access);
      Add_Check (M_Machine, "_Mute sound", Mute, On_Mute'Access);
      Add_Separator (M_Machine);
      Add_Radio (M_Machine, "No RAM expansion", REU_Group, REU_Items (0),
                 On_REU'Access);
      for C in REU_Choice range 1 .. REU_Choice'Last loop
         Add_Radio (M_Machine,
                    "REU" & REU_Sizes (C)'Image & " KB" &
                    (case C is when 1 => " (1700)", when 2 => " (1764)",
                               when 3 => " (1750)", when others => ""),
                    REU_Group, REU_Items (C), On_REU'Access);
      end loop;
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
      Add_Separator (M_Input);
      Add_Check (M_Input, "Positional keyboard mapping", Item_Pos,
                 On_Positional'Access);
      Add_Separator (M_Input);
      Host_Joystick.Scan;
      Add_Radio (M_Input, "No paddles", Paddle_Group,
                 Paddle_Items (Paddles.Off), On_Paddles'Access);
      Add_Radio (M_Input, "Paddles on the mouse (x / y, buttons fire)",
                 Paddle_Group, Paddle_Items (Paddles.Mouse), On_Paddles'Access);
      Add_Radio (M_Input, "Paddles on the joystick (left/right, up/down)",
                 Paddle_Group, Paddle_Items (Paddles.Joystick),
                 On_Paddles'Access);
      Add_Separator (M_Input);
      Add_Radio (M_Input, "No game controller", Host_Group, Host_Items (-1),
                 On_Host_Joy'Access);
      for I in 0 .. Host_Joystick.Count - 1 loop
         Add_Radio (M_Input, "Controller: " & Host_Joystick.Name (I),
                    Host_Group, Host_Items (I), On_Host_Joy'Access);
      end loop;

      M_View := Add_Menu (Bar, "_View");
      Add_Item (M_View, "_Fullscreen (Alt+Enter)", On_Fullscreen'Access);
      Add_Check (M_View, "_Integer scaling", Item_Int, On_Integer_Scale'Access);
      Add_Check (M_View, "_CRT scanlines", Item_CRT, On_CRT'Access);

      M_Help := Add_Menu (Bar, "_Help");
      Add_Item (M_Help, "_Keyboard", On_Keys_Help'Access);
      Add_Item (M_Help, "_About", On_About'Access);

      Gtk_New (Area);
      Area.Set_Size_Request (384, 272);
      Area.On_Draw (On_Draw'Access);
      Area.Add_Events (Pointer_Motion_Mask or Button_Press_Mask
                       or Button_Release_Mask);
      Area.On_Motion_Notify_Event (On_Area_Motion'Access);
      Area.On_Button_Press_Event (On_Area_Button'Access);
      Area.On_Button_Release_Event (On_Area_Button'Access);
      Gtk.Dnd.Dest_Set (Area, Gtk.Dnd.Dest_Default_All,
                        Actions => Gdk.Drag_Contexts.Action_Copy);
      Gtk.Dnd.Dest_Add_Uri_Targets (Area);
      Area.On_Drag_Data_Received (On_Drop'Access);
      VBox.Pack_Start (Area, Expand => True, Fill => True);

      Gtk_New (Status, "");
      Status.Set_Halign (Gtk.Widget.Align_Start);
      Status.Set_Ellipsize (Pango.Layout.Ellipsize_End);
      Status.Set_Margin_Start (6);
      VBox.Pack_Start (Status, Expand => False, Fill => False, Padding => 2);

      VIC_Surf := Cairo.Image_Surface.Create      --  largest size of any model
        (Cairo.Image_Surface.Cairo_Format_RGB24,
         Gint (Video.VIC_Width), Gint (Video.FB_Lines));
      VDC_Surf := Cairo.Image_Surface.Create
        (Cairo.Image_Surface.Cairo_Format_RGB24,
         Gint (Blit.Width (Blit.VDC_Screen)),
         Gint (Blit.Height (Blit.VDC_Screen)));

      SID.Sink := Audio.Push'Access;
      Monitor.On_Change := Refresh_Screen'Access;
      Forge.Refresh_Screen := Refresh_Screen'Access;
      Audio.Start;

      Updating_Menu := True;
      declare
         Port : constant Integer := Settings.Get ("joyport", 2);
      begin
         Keyboard.Joystick_Port :=
           (if Port in 0 .. 2 then Keyboard.Joy_Port (Port) else 2);
         Joy_Items (Keyboard.Joystick_Port).Set_Active (True);
      end;
      if Settings.Get ("joykeys", "keypad") = "cursor" then
         Keyboard.Joystick_Keys := Keyboard.Cursor_Keys;
         Keyset_Cursor.Set_Active (True);
      else
         Keyset_Keypad.Set_Active (True);
      end if;
      declare
         Wanted : constant String := Settings.Get ("controller", "");
         Dev : Integer :=
           (if Wanted = "" then Host_Joystick.Auto_Select
            elsif Wanted = "none" then -1
            else Host_Joystick.Find (Wanted));
      begin
         if Wanted /= "" and then Wanted /= "none" and then Dev < 0 then
            Dev := Host_Joystick.Auto_Select;   --  saved device unplugged
         end if;
         if Dev >= 0 then
            Host_Joystick.Open (Dev);
            Host_Items (Dev).Set_Active (True);
         else
            Host_Items (-1).Set_Active (True);
         end if;
      end;
      if not REU_Given then
         REU.Set_Size (REU.Size_KB (Settings.Get ("reu", 0)));
      end if;
      for C in REU_Items'Range loop
         if REU_Sizes (C) = REU.Size then
            REU_Items (C).Set_Active (True);
         end if;
      end loop;
      Mute.Set_Active (Audio.Muted);
      Item_Pos.Set_Active (Keyboard.Positional);
      Item_Int.Set_Active (Integer_Scale);
      Item_CRT.Set_Active (CRT_Filter);
      Updating_Menu := False;

      if not SID_Given and then Settings.Get ("sid", "6581") = "8580" then
         SID.Set_Model (SID.MOS8580);
      end if;
      Updating_Menu := True;
      if SID.Model = SID.MOS8580 then
         Item_8580.Set_Active (True);
      else
         Item_6581.Set_Active (True);
      end if;
      Updating_Menu := False;
      if not Standard_Given and then Settings.Get ("standard", "pal") = "ntsc"
      then
         Machine.Set_Video_Standard (Machine.NTSC);
      end if;
      Updating_Menu := True;
      if Machine.Standard = Machine.NTSC then
         Item_NTSC.Set_Active (True);
      else
         Item_PAL.Set_Active (True);
      end if;
      Updating_Menu := False;
      Start_Machine (Start_Model);
      declare
         Want : constant String :=
           (if Length (Drive_Choice) > 0 then To_String (Drive_Choice)
            else Settings.Get ("drive", "1541"));
      begin
         if Want = "1571" and then Drive1541.Has_ROM (Drive1541.D1571) then
            Machine.Set_Drive_Type (Drive1541.D1571);
         end if;
         Updating_Menu := True;
         if Machine.Drive_Type = Drive1541.D1571 then
            Item_1571.Set_Active (True);
         else
            Item_1541.Set_Active (True);
         end if;
         Updating_Menu := False;
      end;
      if File /= "" then
         Do_Autostart (File);
      end if;
      Sync_Menu;

      Win.Show_All;
      if Open_Forge then
         Win.Set_Title ("AdaC64 (forge)");
         Forge.Quit_App := Quit_App'Access;
         Forge.Open (Win, To_String (Forge_File));
      end if;
      --  Run below GTK's redraw priority (120), so the window is still
      --  painted and responsive while the emulation runs flat out (warp).
      Timer := Timer_Sources.Timeout_Add
        (4, On_Timer_Data'Access, 0,
         Priority => 130);
      Gtk.Main.Main;
      Machine.Shutdown;
      Audio.Stop;
   end Run;

end GUI;
