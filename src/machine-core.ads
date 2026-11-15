-- ***************************************************************************
--                      AdaC64 - Machine.Core
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

--  What all machines share: the flat memory with its page maps, the 6502
--  and its bus, emulated time, the drive's synchronisation and ROM
--  loading. Accesses to I/O pages and everything else that differs per
--  machine are passed on to the machine's own package (Machine.*_System).

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with MOS6502;
with CRT;

private package Machine.Core is

   ---------------------------------------------------------------------
   --  Flat memory: RAM banks followed by all ROM images
   ---------------------------------------------------------------------

   RAM_Size         : constant := 16#20000#;          --  2 x 64K
   ROM_C64_Basic    : constant := 16#20000#;          --  8K (VIC-20 BASIC)
   ROM_C64_Kernal   : constant := 16#22000#;          --  8K (VIC-20 KERNAL)
   ROM_C64_Char     : constant := 16#24000#;          --  4K (VIC-20 chars)
   ROM_C128_Kernal  : constant := 16#25000#;          --  16K
   ROM_C128_BasicLo : constant := 16#29000#;          --  16K
   ROM_C128_BasicHi : constant := 16#2D000#;          --  16K
   ROM_C128_Char    : constant := 16#31000#;          --  4K (C128 half)
   ROM_Empty        : constant := 16#32000#;          --  256 bytes of $FF
   Write_Sink       : constant := 16#32100#;          --  discarded writes
   Cart_Base        : constant := 16#32200#;          --  cartridge banks
   V20_XRAM         : constant := Cart_Base + CRT.Max_Banks * CRT.Bank_Size;
   --  VIC-20 Mega-Cart: 32K RAM at V20_XRAM, 8K NVRAM after it; its 2 MB
   --  ROM uses the cartridge bank area at Cart_Base
   Mem_Size         : constant := V20_XRAM + 16#A000#;

   Mem : Byte_Array (0 .. Mem_Size - 1) := (others => 16#FF#);
   Color_RAM : Byte_Array (0 .. 2047) := (others => 0);

   --  Page map entries: an offset into Mem, or one of these
   IO_Page    : constant Integer := -1;   --  the machine's IO_Read / Write
   Color_Page : constant Integer := -2;   --  Z80 view of colour RAM (C128)

   type Page_Map is array (Byte) of Integer;
   Read_Map  : Page_Map := (others => 0);
   Write_Map : Page_Map := (others => 0);

   ---------------------------------------------------------------------
   --  Machine state shared by all models
   ---------------------------------------------------------------------

   Current_Model    : Model_Type := C64;
   Current_Standard : Video_Standard := PAL;
   C64_Mode         : Boolean := True;
   --  C64-style memory map and KERNAL zero page (also the VIC-20); False
   --  on a C128 in C128 mode
   Has_CPU_Port     : Boolean := True;    --  6510/8502 port at $00/$01
   Kernal_High      : Boolean := True;    --  KERNAL ROM visible at $FFxx
   Err : Unbounded_String;

   NMI_Prev     : Boolean := False;
   Half_Cycle   : Natural := 0;           --  C128 2 MHz: odd CPU cycle
   Frames       : Natural := 0;
   Total_Cycles : Long_Long_Integer := 0; --  device (1 MHz) time
   Drive_On     : Boolean := False;       --  true drive participating
   NMI_Count, IRQ_Count : Natural := 0;
   Last_NMI_PC : Word := 0;

   --  Sub-instruction timing: during CPU.Step, I/O accesses first clock
   --  the chips up to the cycle on which the access happens (the last
   --  cycle of the instruction), so writes take effect at the right time.
   In_Step      : Boolean := False;
   Instr_Ticked : Natural := 0;    --  cycles already clocked this step

   ---------------------------------------------------------------------
   --  Watchpoints (checked by the bus while the CPU executes)
   ---------------------------------------------------------------------

   type Watch is record
      From, To : Word := 0;
      On_Read, On_Write : Boolean := False;
   end record;
   Max_Watches : constant := 16;
   Watches : array (1 .. Max_Watches) of Watch;
   Watch_Count : Natural := 0;
   Watch_Hit   : Boolean := False;
   Watch_Write_Hit : Boolean := False;
   Watch_Addr  : Word := 0;

   ---------------------------------------------------------------------
   --  CPU and bus
   ---------------------------------------------------------------------

   function Bus_Read (Addr : Word) return Byte;
   procedure Bus_Write (Addr : Word; Value : Byte);
   package CPU is new MOS6502 (Read => Bus_Read, Write => Bus_Write);

   function IO_Read (Addr : Word) return Byte;
   procedure IO_Write (Addr : Word; Value : Byte);
   --  An I/O page access: the chips are brought up to the cycle of the
   --  access, then the machine's own I/O handles it

   procedure Rebuild_Map;                 --  the machine's memory map
   procedure Clock_Devices (N : Natural); --  advance the chips N cycles

   function Fast_Mode return Boolean;     --  C128 at 2 MHz
   procedure Catch_Up;
   procedure Sync_Drive (Write_Delay : Natural := 0);
   --  Bring the drive up to the moment of the current bus access

   procedure Update_Drive_State;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   procedure Load_ROM (Path : String; Offset : Natural; Size : Natural;
                       Skip : Natural := 0; Ok : in out Boolean);
   --  Ok is only cleared (on failure; Err tells which file)

   function Read_All (Path : String; Ok : out Boolean) return Byte_Array;

   procedure Free is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

end Machine.Core;
