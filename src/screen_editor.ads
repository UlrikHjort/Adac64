-- ***************************************************************************
--                      AdaC64 - Screen_Editor
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
