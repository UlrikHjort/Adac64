--  GtkAda front end.

with Ada.Strings.Unbounded;
with Machine;

package GUI is

   Drive_Choice : Ada.Strings.Unbounded.Unbounded_String;
   Standard_Given : Boolean := False;   --  --pal / --ntsc on the command line
   SID_Given : Boolean := False;        --  --sid on the command line
   Paddles_Given : Boolean := False;    --  --paddles on the command line
   Open_Forge : Boolean := False;      --  --forge: open the forge window
   Forge_File : Ada.Strings.Unbounded.Unbounded_String;
   --  "1541" / "1571" from the command line ("" = use the saved setting)

   procedure Run (Model : Machine.Model_Type; ROM_Dir : String;
                  File : String;
                  Model_Given : Boolean := False;
                  Key80_Given : Boolean := False;
                  REU_Given : Boolean := False);
   --  Model_Given / Key80_Given: set on the command line (they override
   --  the saved settings).

end GUI;
