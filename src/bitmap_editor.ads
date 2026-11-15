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
