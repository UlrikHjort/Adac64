--  The complete C64 / C128 system: memory map, I/O dispatch, CPU, chips,
--  KERNAL load/save traps and the per-frame run loop.

with Ada.Strings.Unbounded;
with Types; use Types;
with Drive1541;

package Machine is

   type Model_Type is (C64, C128);

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean);
   --  Load the ROM set for the model and perform a hard reset.

   function Model return Model_Type;
   function In_C64_Mode return Boolean;   --  C64, or C128 after GO64
   function Error_Message return String;

   procedure Reset;
   --  Hard reset (RAM pattern re-initialised, chips reset).

   procedure Run_Frame;
   --  Emulate one PAL frame (312 raster lines).

   Key_4080_Down : Boolean := False;   --  C128 40/80 DISPLAY key locked down

   type Video_Standard is (PAL, NTSC);
   procedure Set_Video_Standard (V : Video_Standard);
   --  Takes effect immediately (call Reset afterwards).
   function Standard return Video_Standard;
   function Frame_Rate return Float;     --  50.125 (PAL) / 59.826 (NTSC)

   procedure Type_Text (S : String);
   --  Queue text to be fed into the KERNAL keyboard buffer.

   procedure Autostart (Path : String; Ok : out Boolean);
   --  Attach the image/file, reset, and LOAD + RUN the first program.

   function Autostart_Busy return Boolean;

   function Frame_Count return Natural;
   function Peek (Addr : Word) return Byte;     --  CPU view, no side effects
   procedure Poke (Addr : Word; Value : Byte);  --  RAM bank 0
   function RAM_Peek (Addr : Word) return Byte; --  RAM bank 0 (under ROM/IO)
   function VIC_Peek (Addr : Word) return Byte;
   --  What the VIC-II sees at Addr ($0000-$3FFF) in its current bank
   --  (character ROM at $1000-$1FFF in banks 0 and 2).
   function VIC_Bank_Address return Word;          --  $0000/$4000/$8000/$C000
   function Char_ROM_Peek (Offset : Natural) return Byte;   --  0 .. 4095
   function IO_Peek (Addr : Word) return Byte;
   --  VIC-II / colour RAM / CIA register at $D000-$DFFF, whatever is
   --  banked in for the CPU (no side effects).
   function Get_PC return Word;
   function Screen_Contains (Text : String) return Boolean;
   --  True when Text (ASCII) is visible on the 40- or 80-column screen.

   function VDC_Enabled return Boolean;
   --  True when the machine has a VDC (C128).

   --  Disk drive 8
   True_Drive : Boolean := True;
   --  Use the emulated 1541 (needs a drive ROM) for D64 images; otherwise
   --  the KERNAL LOAD/SAVE traps are used.

   Fast_Kernal_Load : Boolean := True;
   --  With the emulated 1541 active, serve KERNAL LOADs from drive 8
   --  instantly from the image, straight into RAM (like a fast-load
   --  cartridge); custom loaders still talk to the emulated drive.

   Drive_ROM_Path : Ada.Strings.Unbounded.Unbounded_String;
   --  Optional explicit 1541 ROM file (16 KB).

   procedure Attach (Path : String; Ok : out Boolean);

   procedure Attach_Cartridge (Path : String; Ok : out Boolean);
   --  Insert a .crt cartridge and reset.
   procedure Detach_Cartridge;
   function Cartridge_Name return String;   --  "" when none
   procedure Detach;
   procedure Set_True_Drive (On : Boolean);
   procedure Set_Drive_Type (M : Drive1541.Drive_Model);
   function Drive_Type return Drive1541.Drive_Model;
   function Drive_Active return Boolean;
   function Z80_Used return Boolean;
   --  True when the C128's Z80 took over after boot (e.g. CP/M runs).   --  1541 emulated on the bus now
   function Drive_ROM_Found return Boolean;
   function Drive_LED return Boolean;
   function Drive_Motor return Boolean;
   function Drive_Track return Natural;

   function Drive_Peek (Addr : Natural) return Byte;
   function Debug_Info return String;

   procedure Save_Snapshot (Path : String; Ok : out Boolean);
   procedure Load_Snapshot (Path : String; Ok : out Boolean);
   --  Complete machine state (computer, drive, cartridge); call between
   --  frames.  The attached disk image is re-attached by path.

   --  Debugger (machine-code monitor)
   procedure Step_Instruction;            --  one C64 CPU instruction
   procedure Step_Over;      --  like Step_Instruction, but runs a JSR to its end
   procedure Step_Out;       --  run until the current subroutine returns
   procedure Run_To (Addr : Word);   --  resume, stop when PC = Addr
   procedure Request_Break;  --  stop at the next instruction boundary

   type Stop_Reason is (None, Breakpoint, Watch_Read, Watch_Write,
                        Step_Done, Paused);
   function Last_Stop return Stop_Reason;
   function Stop_Text return String;      --  "breakpoint at $C000" ...

   procedure Add_Watch (From, To : Word; On_Read, On_Write : Boolean);
   procedure Remove_Watch (From : Word);
   procedure Clear_Watches;
   function Watch_List return String;
   --  Stop after a CPU instruction that reads/writes From .. To

   function Is_Breakpoint (Addr : Word) return Boolean;
   function Cycle_Count return Long_Long_Integer;   --  since power-on

   procedure Inject_And_Run (Data : Byte_Array; Load : Word;
                             Command : String; With_Reset : Boolean := True);
   --  Reset (optional), wait for READY, copy Data into RAM at Load (BASIC
   --  pointers are set when Load = $0801) and type Command (e.g. "RUN").
   procedure Set_Breakpoint (Addr : Word);
   procedure Clear_Breakpoint (Addr : Word);
   procedure Clear_Breakpoints;
   function Breakpoint_List return String;
   function Break_Hit return Boolean;     --  Run_Frame stopped at one
   procedure Resume;                      --  continue after a break
   function Register_Text (Drive : Boolean := False) return String;
   function Monitor_Peek (Addr : Word; Drive : Boolean := False) return Byte;
   procedure Monitor_Poke (Addr : Word; Value : Byte; Drive : Boolean := False);
   function CPU_PC (Drive : Boolean := False) return Word;
   procedure Monitor_Set_PC (Addr : Word);

   procedure Shutdown;
   --  Write back any modified disk tracks.

end Machine;
