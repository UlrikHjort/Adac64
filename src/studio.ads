--  AdaC64 Studio: assembler IDE and source-level debugger around the
--  running emulator.
--
--  Keys (studio window):
--    F5        build & run / continue when stopped   Ctrl+F5  rebuild & run
--    F6        pause                                 F7       build
--    F9        toggle breakpoint (or click the gutter)
--    F10       step over        F11  step into       Shift+F11  step out
--    Ctrl+F10  run to cursor    Ctrl+N/O/S  new/open/save   Ctrl+W close tab

with Gtk.Window;

package Studio is

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "");
   --  Show the studio window (opening File, or the files of last time).

   function Is_Open return Boolean;

   procedure Tick;
   --  Called regularly by the emulator loop: notices breakpoints and
   --  refreshes the debugger panels.

   type Proc is access procedure;
   Refresh_Screen : Proc := null;   --  redraw the emulator window
   Quit_App : Proc := null;
   --  Set when the studio is the main window (adac64-studio): closing the
   --  studio then quits the program instead of hiding it.

   procedure Save_State;
   --  Remember the open files in the settings.

end Studio;
