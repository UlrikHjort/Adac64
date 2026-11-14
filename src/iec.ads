--  The Commodore serial (IEC) bus: open-collector ATN, CLK and DATA lines.
--  True means "line pulled low" (asserted).

package IEC is

   --  Computer side (from CIA2 port A through the 7406 inverters)
   C64_ATN, C64_CLK, C64_DATA : Boolean := False;

   --  Drive side (from 1541 VIA1 port B)
   Drive_CLK, Drive_DATA, Drive_ATNA : Boolean := False;
   Drive_Present : Boolean := False;

   function ATN return Boolean is (C64_ATN);

   function CLK return Boolean is
     (C64_CLK or else (Drive_Present and then Drive_CLK));

   --  The 1541 hardware pulls DATA low whenever ATN and its ATN-acknowledge
   --  output disagree, which is how a drive answers ATN automatically.
   function DATA return Boolean is
     (C64_DATA or else
        (Drive_Present and then (Drive_DATA or else (C64_ATN /= Drive_ATNA))));

end IEC;
