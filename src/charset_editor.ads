-- ***************************************************************************
--                      AdaC64 - Charset_Editor
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
