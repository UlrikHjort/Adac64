--  Screen editor window (Forge): 40 x 25 text screens drawn with the
--  charset of the charset editor.
--
--  Tools: draw (left: character, right: space), colour only, fill, text
--  (click, then type), pick (eyedropper), copy area (drag) and paste
--  area (click).  Ctrl+Z undo, Ctrl+S save, R reverse, G grid.

with Gtk.Window;

package Screen_Editor is

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "");
   function Is_Open return Boolean;
   function Is_Screen_File (Path : String) return Boolean;   --  .scr

end Screen_Editor;
