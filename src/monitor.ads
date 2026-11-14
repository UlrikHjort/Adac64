--  Machine-code monitor window (debugger).
--
--  Commands (numbers are hex, '$' optional):
--    r              registers           z [n]       step n instructions
--    d [addr]       disassemble         m [a [b]]   memory dump
--    > addr bb ..   write bytes         g [addr]    go (optionally set PC)
--    b addr         set breakpoint      bd [addr]   delete one / all
--    bl             list breakpoints    dev c | 8   view C64 or 1541 CPU
--    x              close and continue  h, ?        help

with Gtk.Window;

package Monitor is

   function Active return Boolean;
   --  True while the monitor holds the machine stopped.

   procedure Open (Parent : Gtk.Window.Gtk_Window; Reason : String := "");

   type Refresh_Proc is access procedure;
   On_Change : Refresh_Proc := null;
   --  Called after commands that change machine state (to redraw).

end Monitor;
