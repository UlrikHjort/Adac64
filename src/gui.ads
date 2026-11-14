--  GtkAda front end.

with Machine;

package GUI is

   procedure Run (Model : Machine.Model_Type; ROM_Dir : String;
                  File : String;
                  Model_Given : Boolean := False;
                  Key80_Given : Boolean := False;
                  REU_Given : Boolean := False);
   --  Model_Given / Key80_Given: set on the command line (they override
   --  the saved settings).

end GUI;
