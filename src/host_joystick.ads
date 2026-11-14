--  Host game controllers through the Linux joystick API (/dev/input/jsN).
--  The selected device drives the emulated joystick port chosen in the
--  Keyboard package (together with the keyboard joystick keys).

package Host_Joystick is

   Max_Devices : constant := 8;

   procedure Scan;
   --  Look for /dev/input/js0 .. js7.

   function Count return Natural;
   function Name (Index : Natural) return String;   --  0-based
   function Device_Number (Index : Natural) return Natural;  --  N of jsN

   procedure Open (Index : Natural);
   procedure Close;
   function Selected return Integer;    --  index into the scan, -1 = none

   procedure Poll;
   --  Read pending events and update the emulated joystick.

   function Find (Device_Name : String) return Integer;
   --  Index of the device with this name, or -1.

   function Auto_Select return Integer;
   --  The first device that looks like a joystick or gamepad (not a wheel).

end Host_Joystick;
