--  Datasette with TAP (raw pulse) images.
--
--  The read signal goes to CIA1's FLAG input; the CPU port supplies the
--  motor control (bit 5, active low) and reads the PLAY sense (bit 4).

with Ada.Streams;

package Tape is

   procedure Attach (Path : String; Ok : out Boolean);
   procedure Detach;
   function Present return Boolean;
   function Name return String;

   procedure Play;          --  press PLAY (done automatically on attach)
   procedure Stop;
   procedure Rewind;
   function Playing return Boolean;   --  PLAY pressed

   Motor : Boolean := False;          --  set by the machine from the port

   procedure Tick (Cycles : Natural; Pulse : out Natural);
   --  Advance the tape; Pulse = number of read pulses (falling edges on
   --  the FLAG line) that happened.

   function Counter return Natural;
   --  position in percent

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Tape;
