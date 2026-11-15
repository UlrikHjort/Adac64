--  Charset editor window (forge).
--
--  Left button draws, right erases, Shift+click fills; click a character
--  in the set below to edit it.  Keys: cursor keys / PgUp / PgDn select
--  characters, Ctrl+Z undo, Ctrl+C/V copy/paste, Ctrl+S save,
--  M multicolour, 1-4 pens.

with Gtk.Window;

package Charset_Editor is

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "");
   function Is_Open return Boolean;
   function Is_Charset_File (Path : String) return Boolean;   --  .chr .64c

end Charset_Editor;
