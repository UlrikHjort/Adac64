--  Sprite editor window (forge).
--
--  Left button draws with the selected pen, right button erases,
--  Shift+click flood-fills.  Keys: PgUp/PgDn previous/next sprite,
--  Ctrl+Z undo, Ctrl+C/Ctrl+V copy/paste sprite, Ctrl+S save,
--  M multicolour on/off, 1-4 select pen.

with Gtk.Window;

package Sprite_Editor is

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "");
   function Is_Open return Boolean;

   function Is_Sprite_File (Path : String) return Boolean;   --  .spr

end Sprite_Editor;
