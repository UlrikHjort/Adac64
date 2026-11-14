--  Command interpreter of the machine-code monitor (independent of the GUI,
--  so it can also be driven from headless mode).  See Monitor for the list
--  of commands.

package Monitor_Commands is

   type Output_Proc is access procedure (Line : String);
   Output : Output_Proc := null;

   Resume_Requested : Boolean := False;
   --  Set by "g" / "x": the caller should continue emulation.

   type Change_Proc is access procedure;
   On_Change : Change_Proc := null;

   procedure Execute (Line : String);
   procedure Show_Registers;

end Monitor_Commands;
