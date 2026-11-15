--  Bitmap editor window (Forge): hires and multicolour pictures with
--  the VIC-II's colour limits, image import with colour reduction.
--
--  Left / right button paint with the left / right colour (choose them
--  by clicking the palette with that button).  Tools: pencil, line,
--  fill, pick.  Ctrl+Z undo, Ctrl+S save, G cell grid.

with Gtk.Window;

package Bitmap_Editor is

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "");
   function Is_Open return Boolean;
   function Is_Bitmap_File (Path : String) return Boolean;
   --  .kla .koa .art .dd
   function Is_Image_File (Path : String) return Boolean;
   --  .png .jpg .jpeg .gif .bmp: opening one imports it

end Bitmap_Editor;
