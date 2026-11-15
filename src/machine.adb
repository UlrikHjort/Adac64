-- ***************************************************************************
--                      AdaC64 - Machine
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

with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Directories;
with Ada.Characters.Handling;
with Ada.Command_Line;
with Interfaces; use Interfaces;

with Keyboard;
with Paddles;
with Media;
with Disasm;
with Video;
with Tape;
with Drive1541;
use type Media.Media_Kind;
use type Drive1541.Drive_Model;
with IEC;
with Machine.Core; use Machine.Core;
with Machine.C64_System;
with Machine.VIC20_System;
with Machine.Plus4_System;

package body Machine is

   package C64S renames Machine.C64_System;
   package V20S renames Machine.VIC20_System;
   package P4S renames Machine.Plus4_System;

   function Is_TED return Boolean is (Current_Model in Plus4 | C16);

   --  KERNAL zero page and keyboard buffer: the C64's (also the VIC-20's
   --  and the C128's in C64 mode), the C128's, or the Plus/4's
   function ZP_FNLEN return Word is (if Is_TED then 16#AB# else 16#B7#);
   function ZP_SA return Word is (if Is_TED then 16#AD# else 16#B9#);
   function ZP_FA return Word is (if Is_TED then 16#AE# else 16#BA#);
   function ZP_FNADR return Word is (if Is_TED then 16#AF# else 16#BB#);
   function ZP_EAL return Word is (if Is_TED then 16#9D# else 16#AE#);
   function Key_Count_Addr return Word is
     (if Is_TED then 16#EF# elsif C64_Mode then 16#C6# else 16#D0#);
   function Key_Buffer_Addr return Word is
     (if Is_TED then 16#0527# elsif C64_Mode then 16#0277# else 16#034A#);

   --  Typing / autostart
   Type_Queue : Unbounded_String;
   type Auto_State is
     (Idle, Wait_Ready, Wait_Load, Wait_Check, Wait_Boot, Wait_Tape,
      Wait_Inject);
   Inject_Data : Byte_Array_Access := null;
   Inject_Load : Word := 0;
   Quiet_Frames : Natural := 0;
   Tape_Autostart : Boolean := False;
   Auto_Path : Unbounded_String;
   Fast_Frames : Natural := 0;
   Auto : Auto_State := Idle;
   Auto_Command : Unbounded_String;
   Auto_Frames : Natural := 0;


   ---------------------------------------------------------------------
   --  Drive and media
   ---------------------------------------------------------------------

   procedure Find_Drive_ROM (ROM_Dir : String) is
      Ok : Boolean := False;
      Exe_Dir : constant String :=
        Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name);

      procedure Try (Path : String) is
      begin
         if not Ok and then Ada.Directories.Exists (Path) then
            Drive1541.Load_ROM (Path, Ok);
         end if;
      exception
         when others => null;
      end Try;
   begin
      if Length (Drive_ROM_Path) > 0 then
         Try (To_String (Drive_ROM_Path));
         Ok := False;
      end if;
      if not Drive1541.Has_ROM (Drive1541.D1541) then
         Try (ROM_Dir & "/DRIVES/dos1541-325302-01+901229-05.bin");
         Try (ROM_Dir & "/DRIVES/dos1541");
         Try (Exe_Dir & "/../roms/drives/dos1541.bin");
         Try ("roms/drives/dos1541.bin");
         Try (Exe_Dir & "/../roms/drives/1541-II.251968-03.bin");
      end if;
      Ok := False;
      if not Drive1541.Has_ROM (Drive1541.D1571) then
         Try (ROM_Dir & "/DRIVES/dos1571-310654-05.bin");
         Try (ROM_Dir & "/DRIVES/dos1571");
         Try (Exe_Dir & "/../roms/drives/1571-rom.310654-05.bin");
         Try ("roms/drives/1571-rom.310654-05.bin");
      end if;
   exception
      when others => null;
   end Find_Drive_ROM;

   procedure Attach (Path : String; Ok : out Boolean) is
   begin
      Drive1541.Eject_Disk;
      Media.Attach (Path, Ok);
      if Ok and then Media.Kind in Media.D64 | Media.D71 | Media.G64 then
         Drive1541.Insert_Disk;
      end if;
      Update_Drive_State;
   end Attach;

   procedure Attach_Cartridge (Path : String; Ok : out Boolean) is
   begin
      case Current_Model is
         when VIC20 => V20S.Attach_Cartridge (Path, Ok);
         when C64 | C128 => C64S.Attach_Cartridge (Path, Ok);
         when Plus4 | C16 => P4S.Attach_Cartridge (Path, Ok);
      end case;
   end Attach_Cartridge;

   procedure Detach_Cartridge is
   begin
      V20S.Detach_Cartridge;
      C64S.Detach_Cartridge;
      P4S.Detach_Cartridge;
      Reset;
   end Detach_Cartridge;

   function Cartridge_Name return String is
     (case Current_Model is
         when VIC20 => V20S.Cartridge_Name,
         when C64 | C128 => C64S.Cartridge_Name,
         when Plus4 | C16 => P4S.Cartridge_Name);

   procedure Detach is
   begin
      Drive1541.Eject_Disk;
      Media.Detach;
      Update_Drive_State;
   end Detach;

   procedure Set_Drive_Type (M : Drive1541.Drive_Model) is
   begin
      if M /= Drive1541.Model then
         Drive1541.Eject_Disk;
         Drive1541.Set_Model (M);
         if Media.Kind in Media.D64 | Media.D71 | Media.G64 then
            Drive1541.Insert_Disk;
         end if;
         Drive_On := False;
         Update_Drive_State;
      end if;
   end Set_Drive_Type;

   function Drive_Type return Drive1541.Drive_Model is (Drive1541.Model);

   procedure Set_True_Drive (On : Boolean) is
   begin
      True_Drive := On;
      Update_Drive_State;
   end Set_True_Drive;

   function Drive_Active return Boolean is (Drive_On);
   function Z80_Used return Boolean is (C64S.Z80_Used);
   function Drive_ROM_Found return Boolean is (Drive1541.ROM_Loaded);
   function Drive_LED return Boolean is (Drive_On and then Drive1541.LED_On);
   function Drive_Motor return Boolean is
     (Drive_On and then Drive1541.Motor_On);
   function Drive_Track return Natural is (Drive1541.Current_Track);

   function Debug_Info return String is
     ("nmi=" & NMI_Count'Image & " (last from" & Last_NMI_PC'Image & ")" &
      " irq=" & IRQ_Count'Image & " jam=" & CPU.Jammed'Image &
      " drivePC=" & Drive1541.Get_PC'Image &
      (if Current_Model in C64 | C128 then C64S.Debug_Text else "") &
      (if Tape.Present then " tape" & Tape.Counter'Image & "% motor=" &
         Tape.Motor'Image & " play=" & Tape.Playing'Image else ""));

   function Drive_Peek (Addr : Natural) return Byte is
     (Drive1541.Peek_RAM (Addr));

   procedure Shutdown is
   begin
      Drive1541.Flush;
   end Shutdown;

   procedure Set_VIC20_Memory (M : VIC20_Memory) is
   begin
      V20S.Set_Memory (M);
   end Set_VIC20_Memory;

   function VIC20_Memory_Config return VIC20_Memory is (V20S.Memory);

   Initialised : Boolean := False;

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean) is
   begin
      if not Initialised then
         C64S.Init;
         Initialised := True;
      end if;
      Find_Drive_ROM (ROM_Dir);
      Ok := True;
      Err := Null_Unbounded_String;
      Current_Model := M;
      case M is
         when VIC20 => V20S.Load_ROMs (ROM_Dir, Ok);
         when C64 | C128 => C64S.Load_ROMs (ROM_Dir, Ok);
         when Plus4 | C16 => P4S.Load_ROMs (ROM_Dir, Ok);
      end case;
      Mem (ROM_Empty .. ROM_Empty + 255) := (others => 16#FF#);
      Set_Video_Standard (Standard);   --  timing of the model's video chip
      Reset;
   end Power_On;

   function Model return Model_Type is (Current_Model);
   function In_C64_Mode return Boolean is
     (C64_Mode and then Current_Model in C64 | C128);

   function Basic_Start return Word is
     (case Current_Model is
        when VIC20 | Plus4 | C16 => Make_Word (Peek (16#2B#), Peek (16#2C#)),
        when others =>
          (if C64_Mode then 16#0801# else 16#1C01#));
   function Error_Message return String is (To_String (Err));
   function VDC_Enabled return Boolean is (Current_Model = C128);
   function Frame_Count return Natural is (Frames);

   procedure Set_Video_Standard (V : Video_Standard) is
   begin
      Current_Standard := V;
      case Current_Model is
         when VIC20 => V20S.Set_Standard (V);
         when C64 | C128 => C64S.Set_Standard (V);
         when Plus4 | C16 => P4S.Set_Standard (V);
      end case;
   end Set_Video_Standard;

   function Standard return Video_Standard is (Current_Standard);
   function Frame_Rate return Float is
     (if Current_Model = VIC20 then V20S.Frame_Rate
      elsif Is_TED then P4S.Frame_Rate
      elsif Current_Standard = PAL then 985_248.0 / 19_656.0
      else 1_022_727.0 / 17_095.0);
   function Get_PC return Word is (CPU.PC);

   procedure Reset (Hard : Boolean := True) is
   begin
      if Hard then
         --  Power-up RAM pattern: alternating 64-byte blocks of $00 / $FF
         for I in 0 .. RAM_Size - 1 loop
            Mem (I) := (if (I / 64) mod 2 = 0 then 16#00# else 16#FF#);
         end loop;
         Color_RAM := (others => 0);
      end if;
      C64_Mode := Current_Model /= C128;
      Has_CPU_Port := Current_Model /= VIC20;
      Keyboard.Layout := (if Is_TED then Keyboard.Plus4 else Keyboard.C64);
      case Current_Model is
         when VIC20 => V20S.Reset (Hard);
         when C64 | C128 => C64S.Reset (Hard);
         when Plus4 | C16 => P4S.Reset (Hard);
      end case;
      Keyboard.Release_All;
      Rebuild_Map;
      NMI_Prev := False;
      Half_Cycle := 0;
      Total_Cycles := 0;
      IEC.C64_ATN := False;
      IEC.C64_CLK := False;
      IEC.C64_DATA := False;
      Update_Drive_State;
      if Drive1541.ROM_Loaded then
         Drive1541.Reset;
      end if;
      CPU.IRQ_Line := False;
      CPU.Reset;
   end Reset;

   function Peek (Addr : Word) return Byte is
      Off : constant Integer := Read_Map (Hi (Addr));
   begin
      if Addr < 2 and then Has_CPU_Port then
         return (if Is_TED then P4S.Port_Read (Addr)
                 else C64S.Port_Read (Addr));
      elsif Off >= 0 then
         return Mem (Off + Natural (Addr and 16#FF#));
      elsif Current_Model = VIC20 and then Addr not in 16#9000# .. 16#9BFF#
      then
         return V20S.IO_Peek (Addr);   --  cartridge areas (Final Expansion)
      elsif Is_TED then
         return P4S.IO_Peek (Addr);
      else
         return 16#FF#;
      end if;
   end Peek;

   procedure Poke (Addr : Word; Value : Byte) is
   begin
      if Current_Model = VIC20 then
         V20S.Poke (Addr, Value);
      elsif Is_TED then
         P4S.Poke (Addr, Value);
      else
         Mem (Natural (Addr)) := Value;
      end if;
   end Poke;

   function RAM_Peek (Addr : Word) return Byte is (Mem (Natural (Addr)));

   function VIC_Peek (Addr : Word) return Byte is (C64S.VIC_Peek (Addr));

   function TED_RAM_Peek (Addr : Word) return Byte is (P4S.RAM_Read (Addr));
   function TED_Color_Peek (Addr : Word) return Byte is
     (Video.From_TED (P4S.RAM_Read (Addr) and 16#7F#));
   function TED_Char_Peek (Addr : Word) return Byte is
     (if (P4S.IO_Peek (16#FF12#) and 4) /= 0 and then Addr >= 16#8000#
      then P4S.ROM_Peek (Addr) else P4S.RAM_Read (Addr));
   function VIC_Bank_Address return Word is (C64S.VIC_Bank_Address);
   function Char_ROM_Peek (Offset : Natural) return Byte is
     (C64S.Char_ROM_Peek (Offset));

   ---------------------------------------------------------------------
   --  KERNAL traps
   ---------------------------------------------------------------------


   function RAM_Bank_Of (KBank : Byte) return Natural is
     (if C64_Mode then 0
      elsif KBank <= 3 then Natural (KBank mod 2)
      else 0);

   function Read_Name return Byte_Array is
      Len  : constant Natural := Natural (Bus_Read (ZP_FNLEN));
      Ptr  : constant Natural := Natural (Bus_Read (ZP_FNADR)) +
        256 * Natural (Bus_Read (ZP_FNADR + 1));
      Bank : constant Natural :=
        (if C64_Mode then 0 else RAM_Bank_Of (Bus_Read (16#C7#)));
      Name : Byte_Array (0 .. Len - 1);
   begin
      for I in Name'Range loop
         if Is_TED then
            --  BASIC keeps strings under the ROM
            Name (I) := P4S.RAM_Read (Word ((Ptr + I) mod 16#10000#));
         elsif C64_Mode then
            Name (I) := Bus_Read (Word ((Ptr + I) mod 16#10000#));
         else
            Name (I) := Mem (Bank * 16#10000# + (Ptr + I) mod 16#10000#);
         end if;
      end loop;
      return Name;
   end Read_Name;

   procedure Trap_Return (Ok : Boolean; Error_Code : Byte := 0) is
   begin
      CPU.Flag_C := not Ok;
      if not Ok then
         CPU.A := Error_Code;
      end if;
      Bus_Write (16#90#, 0);
      CPU.Do_RTS;
   end Trap_Return;

   procedure Trap_Load is
      Dev : constant Byte := Bus_Read (ZP_FA);
      SA  : constant Byte := Bus_Read (ZP_SA);
      Verify : constant Boolean := CPU.A /= 0;
      Data : Byte_Array_Access;
      Found : Boolean;
      --  The KERNAL's STOP vector: the load loop calls it after every
      --  byte, and autostarting loaders overwrite it to take over in the
      --  middle of the LOAD (and read the rest of the file themselves)
      Stop_Vec : constant Natural := (if Is_TED then 16#0326# else 16#0328#);
   begin
      if Dev = 1 then
         if Media.Kind not in Media.T64 | Media.PRG then
            return;    --  real tape routine
         end if;
      elsif Dev /= 8 or else (Drive_On and then not Fast_Kernal_Load) then
         return;
      end if;

      Media.Find_File (Read_Name, Data, Found);
      if Drive_On and then
        (not Found or else Media.Last_Lookup_Unreliable
         or else Data = null or else Data'Length < 2)
      then
         --  Let the emulated 1541 handle it (error message, protection,
         --  sectors that do not decode cleanly).
         if Data /= null then
            Free (Data);
         end if;
         return;
      end if;
      if not Found or else Data = null or else Data'Length < 2 then
         if Data /= null then
            Free (Data);
         end if;
         Trap_Return (False, 4);   --  FILE NOT FOUND
         return;
      end if;

      declare
         File_Addr : constant Natural :=
           Natural (Data (0)) + 256 * Natural (Data (1));
         Load_Addr : constant Natural :=
           (if SA = 0 then Natural (CPU.X) + 256 * Natural (CPU.Y)
            else File_Addr);
         Bank : constant Natural :=
           RAM_Bank_Of (if C64_Mode then 0 else Bus_Read (16#C6#));
         End_Addr : constant Natural :=
           (Load_Addr + Data'Length - 2) mod 16#10000#;
      begin
         if Drive_On and then Load_Addr <= Stop_Vec + 1
           and then Load_Addr + Data'Length - 2 > Stop_Vec
         then
            --  an autostarting loader: the real LOAD through the drive
            Free (Data);
            return;
         end if;
         if not Verify then
            for I in 2 .. Data'Last loop
               if Current_Model in VIC20 | Plus4 | C16 then
                  Poke (Word ((Load_Addr + I - 2) mod 16#10000#), Data (I));
               else
                  Mem (Bank * 16#10000# + (Load_Addr + I - 2) mod 16#10000#)
                    := Data (I);
               end if;
            end loop;
         end if;
         CPU.X := Byte (End_Addr mod 256);
         CPU.Y := Byte (End_Addr / 256);
         Bus_Write (ZP_EAL, CPU.X);
         Bus_Write (ZP_EAL + 1, CPU.Y);
      end;
      Free (Data);
      Trap_Return (True);
   exception
      when others =>
         Trap_Return (False, 4);   --  malformed image: FILE NOT FOUND
   end Trap_Load;

   procedure Trap_Save is
      Dev : constant Byte := Bus_Read (ZP_FA);
      ZP  : constant Word := Word (CPU.A);
      Start_Addr : constant Natural := Natural (Bus_Read (ZP)) +
        256 * Natural (Bus_Read (ZP + 1));
      End_Addr : constant Natural := Natural (CPU.X) + 256 * Natural (CPU.Y);
      Bank : constant Natural :=
        RAM_Bank_Of (if C64_Mode then 0 else Bus_Read (16#C6#));
      Ok : Boolean;
   begin
      if Dev /= 8 or else Drive_On or else End_Addr < Start_Addr then
         return;
      end if;
      declare
         Data : Byte_Array (0 .. End_Addr - Start_Addr + 1);
      begin
         Data (0) := Byte (Start_Addr mod 256);
         Data (1) := Byte (Start_Addr / 256);
         for I in 0 .. End_Addr - Start_Addr - 1 loop
            Data (I + 2) :=
              (if Is_TED then P4S.RAM_Read (Word (Start_Addr + I))
               elsif Current_Model = VIC20 then Peek (Word (Start_Addr + I))
               else Mem (Bank * 16#10000# + Start_Addr + I));
         end loop;
         Media.Save_File (Read_Name, Data, Ok);
      end;
      Trap_Return (Ok, 5);    --  DEVICE NOT PRESENT on failure
   exception
      when others =>
         Trap_Return (False, 5);
   end Trap_Save;

   ---------------------------------------------------------------------
   --  Keyboard buffer injection and autostart
   ---------------------------------------------------------------------

   procedure Type_Text (S : String) is
   begin
      Append (Type_Queue, S);
   end Type_Text;

   function To_Petscii (C : Character) return Byte is
   begin
      case C is
         when 'a' .. 'z' => return Character'Pos (C) - 32;
         when ASCII.LF | ASCII.CR => return 16#0D#;
         when others => return Character'Pos (C);
      end case;
   end To_Petscii;

   procedure Feed_Keyboard is
      Count_Addr : constant Word := Key_Count_Addr;
      Buf_Addr   : constant Word := Key_Buffer_Addr;
      N : Natural;
   begin
      if Length (Type_Queue) = 0 or else Bus_Read (Count_Addr) /= 0 then
         return;
      end if;
      N := Natural'Min (Length (Type_Queue), 10);
      for I in 1 .. N loop
         Bus_Write (Buf_Addr + Word (I - 1),
                    To_Petscii (Element (Type_Queue, I)));
      end loop;
      Bus_Write (Count_Addr, Byte (N));
      Delete (Type_Queue, 1, N);
   end Feed_Keyboard;

   function Screen_Contains (Text : String) return Boolean is
      function Code (C : Character) return Byte is
        (case C is
            when 'A' .. 'Z' => Character'Pos (C) - 64,
            when 'a' .. 'z' => Character'Pos (C) - 96,
            when others => Character'Pos (C));

      function Search (Get : access function (I : Natural) return Byte;
                       Size : Natural) return Boolean is
      begin
         for Start in 0 .. Size - Text'Length loop
            declare
               Hit : Boolean := True;
            begin
               for K in Text'Range loop
                  if (Get (Start + K - Text'First) and 16#7F#) /=
                    Code (Text (K))
                    and then not (Text (K) in 'A' .. 'Z' | 'a' .. 'z'
                                  and then (Get (Start + K - Text'First)
                                              and 16#7F#) =
                                    Code (Text (K)) + 64)
                  then
                     Hit := False;
                     exit;
                  end if;
               end loop;
               if Hit then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Search;

      function VIC_Screen (I : Natural) return Byte is
        (if Current_Model = VIC20 then V20S.Screen_Byte (I)
         elsif Is_TED then P4S.Screen_Byte (I)
         else C64S.Screen_Byte (I));
      function VDC_Screen (I : Natural) return Byte is
        (C64S.VDC_Screen_Byte (I));
   begin
      if Search (VIC_Screen'Access,
                 (if Current_Model = VIC20 then 506 else 1000))
      then
         return True;
      end if;
      return Current_Model = C128 and then Search (VDC_Screen'Access, 2000);
   end Screen_Contains;

   procedure Autostart (Path : String; Ok : out Boolean) is
   begin
      if Path'Length > 4 and then
        (Path (Path'Last - 3 .. Path'Last) = ".tap"
         or else Path (Path'Last - 3 .. Path'Last) = ".TAP")
      then
         Tape.Attach (Path, Ok);
         if Ok then
            Reset;
            Tape.Rewind;
            Tape.Play;
            Type_Queue := Null_Unbounded_String;
            Auto_Command := To_Unbounded_String
              ("LOAD" & ASCII.LF & "RUN" & ASCII.LF);
            Auto := Wait_Ready;
            Tape_Autostart := True;
            Auto_Frames := 0;
         end if;
         return;
      end if;
      if Path'Length > 4 and then
        (Path (Path'Last - 3 .. Path'Last) = ".crt"
         or else Path (Path'Last - 3 .. Path'Last) = ".CRT")
      then
         Type_Queue := Null_Unbounded_String;
         Attach_Cartridge (Path, Ok);
         return;
      end if;
      if (Current_Model = VIC20 and then V20S.Is_Cartridge (Path))
        or else (Is_TED and then Path'Length > 4
                 and then Ada.Characters.Handling.To_Lower
                            (Path (Path'Last - 3 .. Path'Last))
                          in ".bin" | ".rom")
      then
         Type_Queue := Null_Unbounded_String;
         Auto := Idle;
         Attach_Cartridge (Path, Ok);
         return;
      end if;
      Attach (Path, Ok);
      if not Ok then
         return;
      end if;
      if Current_Model = VIC20 then
         V20S.Choose_Memory (Media.First_Load_Address);
      end if;
      Reset;
      Type_Queue := Null_Unbounded_String;
      declare
         LA   : constant Word := Media.First_Load_Address;
         Name : constant String := Media.First_Program_Name;
         Q    : constant String := """" & Name & """";
         Cmd  : Unbounded_String;
         NL   : constant Character := ASCII.LF;
         function Addr return String is (Natural'Image (Natural (LA)));
      begin
         Auto_Path := To_Unbounded_String (Path);
         if Current_Model in VIC20 | Plus4 | C16 then
            if LA in 16#0401# | 16#1001# | 16#1201# or else LA = 0 then
               Cmd := To_Unbounded_String ("LOAD" & Q & ",8" & NL & "RUN" & NL);
            elsif LA = 16#A000# and then Current_Model = VIC20 then
               Cmd := To_Unbounded_String
                 ("LOAD" & Q & ",8,1" & NL & "SYS64802" & NL);
            else
               Cmd := To_Unbounded_String
                 ("LOAD" & Q & ",8,1" & NL & "SYS" & Addr & NL);
            end if;
            Auto_Command := Cmd;
            Auto := Wait_Ready;
            Auto_Frames := 0;
            return;
         elsif Current_Model = C128 and then Media.Has_Boot_Sector then
            --  Boot disk (e.g. CP/M): the KERNAL boots it by itself; stay
            --  "busy" (the GUI warps) until the drive has been quiet.
            Auto := Wait_Boot;
            Auto_Frames := 0;
            Quiet_Frames := 0;
            return;
         elsif Current_Model = C128 then
            --  DLOAD like a C128 user (some loaders read its buffer)
            if LA in 16#1C01# | 16#4001# | 16#1201# or else LA = 0 then
               Cmd := To_Unbounded_String ("DLOAD" & Q & NL & "RUN" & NL);
            elsif Media.Start_Program_Name (For_C128 => True) /= "" then
               Cmd := To_Unbounded_String
                 ("DLOAD""" & Media.Start_Program_Name (For_C128 => True) &
                  """" & NL & "RUN" & NL);
            else
               Cmd := To_Unbounded_String
                 ("BLOAD" & Q & ",U8" & NL &
                  (if LA >= 16#4000# then "BANK0:SYS" else "SYS") & Addr & NL);
            end if;
         elsif LA = 16#0801# or else LA = 0 then
            Cmd := To_Unbounded_String ("LOAD" & Q & ",8,1" & NL & "RUN" & NL);
         elsif LA >= 16#2000# and then Media.Start_Program_Name /= "" then
            --  First file looks like data (e.g. a game part loaded high):
            --  start the first BASIC program on the disk instead.
            Cmd := To_Unbounded_String
              ("LOAD""" & Media.Start_Program_Name & """,8" & NL &
               "RUN" & NL);
         else
            Cmd := To_Unbounded_String
              ("LOAD" & Q & ",8,1" & NL & "SYS" & Addr & NL);
         end if;
         Auto_Command := Cmd;
      end;
      Auto := Wait_Ready;
      Auto_Frames := 0;
   end Autostart;

   function Autostart_Busy return Boolean is
     (Auto in Wait_Ready | Wait_Load | Wait_Boot | Wait_Tape | Wait_Inject);

   procedure Inject_And_Run (Data : Byte_Array; Load : Word;
                             Command : String; With_Reset : Boolean := True)
   is
   begin
      Inject_Data := new Byte_Array'(Data);
      Inject_Load := Load;
      Auto_Command := To_Unbounded_String (Command & ASCII.LF);
      Type_Queue := Null_Unbounded_String;
      if With_Reset then
         Reset;
      end if;
      Auto := Wait_Inject;
      Auto_Frames := 0;
   end Inject_And_Run;

   procedure Autostart_Step is
   begin
      case Auto is
         when Idle => null;
         when Wait_Inject =>
            Auto_Frames := Auto_Frames + 1;
            if Screen_Contains ("READY.") or else Auto_Frames > 600 then
               if Inject_Data /= null then
                  for I in Inject_Data'Range loop
                     declare
                        A : constant Natural :=
                          Natural (Inject_Load) + (I - Inject_Data'First);
                     begin
                        exit when A > 16#FFFF#;
                        Poke (Word (A), Inject_Data (I));
                     end;
                  end loop;
                  declare
                     End_A : constant Natural := Natural'Min
                       (Natural (Inject_Load) + Inject_Data'Length, 16#FFFF#);
                  begin
                     if C64_Mode and then Inject_Load = Basic_Start then
                        --  VARTAB / ARYTAB / STREND after the program
                        for Z in 0 .. 2 loop
                           Poke (Word (16#2D# + 2 * Z), Byte (End_A mod 256));
                           Poke (Word (16#2E# + 2 * Z), Byte (End_A / 256));
                        end loop;
                     elsif not C64_Mode and then Inject_Load = 16#1C01# then
                        Poke (16#1210#, Byte (End_A mod 256));
                        Poke (16#1211#, Byte (End_A / 256));
                     end if;
                  end;
               end if;
               Type_Text (To_String (Auto_Command));
               Tape_Autostart := False;
               Auto := Wait_Load;
               Auto_Frames := 0;
            end if;
         when Wait_Ready =>
            Auto_Frames := Auto_Frames + 1;
            --  A VIC-20 is at READY before a 1541 has finished starting
            --  up (about 2 seconds); a LOAD sent earlier goes unanswered.
            if (Screen_Contains ("READY.")
                and then (Current_Model in C64 | C128 or else not Drive_On
                          or else Auto_Frames > 100))
              or else Auto_Frames > 600
            then
               Type_Text (To_String (Auto_Command));
               Auto := Wait_Load;
               Auto_Frames := 0;
            end if;
         when Wait_Load =>
            Auto_Frames := Auto_Frames + 1;
            --  Done once everything typed (including RUN) was consumed
            if (Length (Type_Queue) = 0 and then Auto_Frames > 10
                and then Bus_Read (Key_Count_Addr) = 0)
              or else Auto_Frames > 600
            then
               Fast_Frames := 0;
               Auto := (if Tape_Autostart then Wait_Tape
                        elsif Current_Model = C128 and then not C64_Mode
                          and then not Key_4080_Down
                        then Wait_Check else Idle);
               Quiet_Frames := 0;
               Auto_Frames := 0;
            end if;
         when Wait_Tape =>
            --  Warp while the tape runs (turbo loaders keep the motor on)
            Auto_Frames := Auto_Frames + 1;
            Quiet_Frames := (if Tape.Motor and then Tape.Playing then 0
                             else Quiet_Frames + 1);
            if Quiet_Frames > 250 or else Auto_Frames > 200_000 then
               Auto := Idle;
               Tape_Autostart := False;
            end if;
         when Wait_Boot =>
            Auto_Frames := Auto_Frames + 1;
            Quiet_Frames := (if Drive_Motor then 0 else Quiet_Frames + 1);
            if (Auto_Frames > 300 and then Quiet_Frames > 150)
              or else Auto_Frames > 15_000
            then
               Auto := Idle;
            end if;
         when Wait_Check =>
            --  An 80-column program started in 40-column mode usually
            --  says so; restart it with the 40/80 key down.
            Auto_Frames := Auto_Frames + 1;
            --  FAST (2 MHz) blanks the 40-column screen: a program running
            --  in FAST mode for a while is meant for the 80-column screen.
            Fast_Frames := (if C64S.Fast_2MHz then Fast_Frames + 1 else 0);
            if Fast_Frames > 250
              or else Screen_Contains ("80 COL") or else Screen_Contains ("80-COL")
              or else Screen_Contains ("80 ZEICHEN")
              or else Screen_Contains ("80 SPALTEN")
            then
               Key_4080_Down := True;
               declare
                  Ok : Boolean;
               begin
                  Autostart (To_String (Auto_Path), Ok);
               end;
            elsif Auto_Frames > 400 then
               Auto := Idle;
            end if;
      end case;
   end Autostart_Step;

   ---------------------------------------------------------------------
   --  Snapshots: the common part, then the machine's own
   ---------------------------------------------------------------------

   Snapshot_Magic : constant String := "ADAC64SNAP8";

   procedure Save_Snapshot (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
   begin
      Create (F, Out_File, Path);
      S := Stream (F);
      String'Write (S, Snapshot_Magic);
      Model_Type'Write (S, Current_Model);
      Video_Standard'Write (S, Current_Standard);
      String'Output (S, Media.Attached_Path);
      Byte_Array'Write (S, Mem);
      Byte_Array'Write (S, Color_RAM);
      Boolean'Write (S, C64_Mode);
      Boolean'Write (S, NMI_Prev); Natural'Write (S, Half_Cycle);
      Natural'Write (S, Frames); Long_Long_Integer'Write (S, Total_Cycles);
      Boolean'Write (S, True_Drive);
      Boolean'Write (S, Drive_On);
      Byte'Write (S, CPU.A); Byte'Write (S, CPU.X); Byte'Write (S, CPU.Y);
      Byte'Write (S, CPU.SP); Word'Write (S, CPU.PC);
      Byte'Write (S, CPU.Get_P);
      Boolean'Write (S, CPU.IRQ_Line); Boolean'Write (S, CPU.NMI_Pending);
      Boolean'Write (S, CPU.Jammed);
      Boolean'Write (S, IEC.C64_ATN); Boolean'Write (S, IEC.C64_CLK);
      Boolean'Write (S, IEC.C64_DATA);
      Tape.Save_State (S);
      Drive1541.Save_State (S);
      case Current_Model is
         when VIC20 => V20S.Save_State (S);
         when C64 | C128 => C64S.Save_State (S);
         when Plus4 | C16 => P4S.Save_State (S);
      end case;
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Save_Snapshot;

   procedure Load_Snapshot (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
      Magic : String (Snapshot_Magic'Range);
      P : Byte;
   begin
      Ok := False;
      Open (F, In_File, Path);
      S := Stream (F);
      String'Read (S, Magic);
      if Magic /= Snapshot_Magic then
         Close (F);
         Err := To_Unbounded_String
           ("Not an AdaC64 snapshot (or one from an older version)");
         return;
      end if;
      Model_Type'Read (S, Current_Model);
      Has_CPU_Port := Current_Model /= VIC20;
      Keyboard.Layout := (if Is_TED then Keyboard.Plus4 else Keyboard.C64);
      declare
         V : Video_Standard;
      begin
         Video_Standard'Read (S, V);
         Set_Video_Standard (V);
      end;
      declare
         Disk_Path : constant String := String'Input (S);
         Attached : Boolean;
      begin
         Drive1541.Eject_Disk;
         if Disk_Path /= "" and then Disk_Path /= Media.Attached_Path then
            Media.Attach (Disk_Path, Attached);
            if not Attached then
               Media.Detach;
            end if;
         elsif Disk_Path = "" then
            Media.Detach;
         end if;
      end;
      Byte_Array'Read (S, Mem);
      Byte_Array'Read (S, Color_RAM);
      Boolean'Read (S, C64_Mode);
      Boolean'Read (S, NMI_Prev); Natural'Read (S, Half_Cycle);
      Natural'Read (S, Frames); Long_Long_Integer'Read (S, Total_Cycles);
      Boolean'Read (S, True_Drive);
      Boolean'Read (S, Drive_On);
      Byte'Read (S, CPU.A); Byte'Read (S, CPU.X); Byte'Read (S, CPU.Y);
      Byte'Read (S, CPU.SP); Word'Read (S, CPU.PC);
      Byte'Read (S, P);
      CPU.Set_P (P);
      Boolean'Read (S, CPU.IRQ_Line); Boolean'Read (S, CPU.NMI_Pending);
      Boolean'Read (S, CPU.Jammed);
      Boolean'Read (S, IEC.C64_ATN); Boolean'Read (S, IEC.C64_CLK);
      Boolean'Read (S, IEC.C64_DATA);
      Tape.Load_State (S);
      Drive1541.Load_State (S);
      case Current_Model is
         when VIC20 => V20S.Load_State (S);
         when C64 | C128 => C64S.Load_State (S);
         when Plus4 | C16 => P4S.Load_State (S);
      end case;
      Close (F);
      IEC.Drive_Present := Drive_On;
      Keyboard.Release_All;
      Type_Queue := Null_Unbounded_String;
      Auto := Idle;
      Rebuild_Map;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Err := To_Unbounded_String ("Snapshot could not be read");
         Ok := False;
   end Load_Snapshot;

   ---------------------------------------------------------------------
   --  Debugger support
   ---------------------------------------------------------------------

   Max_Breakpoints : constant := 64;
   Breakpoints : array (1 .. Max_Breakpoints) of Word := (others => 0);
   BP_Count    : Natural := 0;
   Break_Flag  : Boolean := False;
   Skip_Break  : Boolean := False;   --  do not re-trigger at resume point

   procedure Set_Breakpoint (Addr : Word) is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            return;
         end if;
      end loop;
      if BP_Count < Max_Breakpoints then
         BP_Count := BP_Count + 1;
         Breakpoints (BP_Count) := Addr;
      end if;
   end Set_Breakpoint;

   procedure Clear_Breakpoint (Addr : Word) is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            Breakpoints (I) := Breakpoints (BP_Count);
            BP_Count := BP_Count - 1;
            return;
         end if;
      end loop;
   end Clear_Breakpoint;

   procedure Clear_Breakpoints is
   begin
      BP_Count := 0;
   end Clear_Breakpoints;

   function Breakpoint_List return String is
      R : Unbounded_String;
   begin
      for I in 1 .. BP_Count loop
         Append (R, " $" & Disasm.Hex4 (Breakpoints (I)));
      end loop;
      return (if BP_Count = 0 then " (none)" else To_String (R));
   end Breakpoint_List;

   function Break_Hit return Boolean is (Break_Flag);

   Reason      : Stop_Reason := None;
   Pause_Req   : Boolean := False;
   Temp_Addr   : Integer := -1;      --  Run_To / Step_Over target
   Temp_SP     : Byte := 0;
   Out_Active  : Boolean := False;   --  Step_Out
   Out_SP      : Byte := 0;

   function Debugging return Boolean is
     (BP_Count > 0 or else Watch_Count > 0 or else Temp_Addr >= 0
      or else Out_Active or else Pause_Req);

   procedure Stop (R : Stop_Reason) is
   begin
      Break_Flag := True;
      Reason := R;
      Temp_Addr := -1;
      Out_Active := False;
      Pause_Req := False;
   end Stop;

   procedure Resume is
   begin
      Break_Flag := False;
      Skip_Break := True;
      Watch_Hit := False;
   end Resume;

   function Last_Stop return Stop_Reason is (Reason);

   function Stop_Text return String is
   begin
      case Reason is
         when None => return "";
         when Breakpoint => return "breakpoint at $" & Disasm.Hex4 (CPU.PC);
         when Watch_Read =>
            return "read of $" & Disasm.Hex4 (Watch_Addr) & " (PC $" &
              Disasm.Hex4 (CPU.PC) & ")";
         when Watch_Write =>
            return "write to $" & Disasm.Hex4 (Watch_Addr) & " (PC $" &
              Disasm.Hex4 (CPU.PC) & ")";
         when Step_Done => return "stopped at $" & Disasm.Hex4 (CPU.PC);
         when Paused => return "paused at $" & Disasm.Hex4 (CPU.PC);
      end case;
   end Stop_Text;

   procedure Request_Break is
   begin
      if not Break_Flag then
         Pause_Req := True;
      end if;
   end Request_Break;

   procedure Run_To (Addr : Word) is
   begin
      Temp_Addr := Integer (Addr);
      Temp_SP := 0;
      Resume;
   end Run_To;

   procedure Step_Out is
   begin
      Out_Active := True;
      Out_SP := CPU.SP;
      Resume;
   end Step_Out;

   procedure Add_Watch (From, To : Word; On_Read, On_Write : Boolean) is
   begin
      for I in 1 .. Watch_Count loop
         if Watches (I).From = From then
            Watches (I) := (From, To, On_Read, On_Write);
            return;
         end if;
      end loop;
      if Watch_Count < Max_Watches then
         Watch_Count := Watch_Count + 1;
         Watches (Watch_Count) := (From, To, On_Read, On_Write);
      end if;
   end Add_Watch;

   procedure Remove_Watch (From : Word) is
   begin
      for I in 1 .. Watch_Count loop
         if Watches (I).From = From then
            Watches (I) := Watches (Watch_Count);
            Watch_Count := Watch_Count - 1;
            return;
         end if;
      end loop;
   end Remove_Watch;

   procedure Clear_Watches is
   begin
      Watch_Count := 0;
      Watch_Hit := False;
   end Clear_Watches;

   function Watch_List return String is
      R : Unbounded_String;
   begin
      for I in 1 .. Watch_Count loop
         Append (R, " $" & Disasm.Hex4 (Watches (I).From) &
                 (if Watches (I).To /= Watches (I).From
                  then "-$" & Disasm.Hex4 (Watches (I).To) else "") &
                 (if Watches (I).On_Read then " r" else "") &
                 (if Watches (I).On_Write then " w" else ""));
      end loop;
      return (if Watch_Count = 0 then " (none)" else To_String (R));
   end Watch_List;

   function Cycle_Count return Long_Long_Integer is (Total_Cycles);

   function Is_Breakpoint (Addr : Word) return Boolean is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            return True;
         end if;
      end loop;
      return False;
   end Is_Breakpoint;

   function At_Breakpoint return Boolean is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = CPU.PC then
            return True;
         end if;
      end loop;
      return False;
   end At_Breakpoint;

   procedure Claim_VIC is
   begin
      if not C64_Mode then
         Mem (16#D8#) := 16#FF#;      --  bank 0 RAM: GRAPHM
      end if;
   end Claim_VIC;

   function IO_Peek (Addr : Word) return Byte is
     (case Current_Model is
         when VIC20 => V20S.IO_Peek (Addr),
         when C64 | C128 => C64S.IO_Peek (Addr),
         when Plus4 | C16 => P4S.IO_Peek (Addr));

   function Monitor_Peek (Addr : Word; Drive : Boolean := False) return Byte
   is
   begin
      if Drive then
         return Drive1541.Peek (Addr);
      end if;
      if Addr >= 2 and then Read_Map (Hi (Addr)) = IO_Page then
         return IO_Peek (Addr);
      end if;
      return Peek (Addr);
   end Monitor_Peek;

   procedure Monitor_Poke (Addr : Word; Value : Byte; Drive : Boolean := False)
   is
   begin
      if Drive then
         Drive1541.Poke (Addr, Value);
      else
         Bus_Write (Addr, Value);
      end if;
   end Monitor_Poke;

   function Flags_Text (N, V, D, I, Z, C : Boolean) return String is
     ((if N then 'N' else '.') & (if V then 'V' else '.') & "-B" &
      (if D then 'D' else '.') & (if I then 'I' else '.') &
      (if Z then 'Z' else '.') & (if C then 'C' else '.'));

   function Register_Text (Drive : Boolean := False) return String is
   begin
      if Drive then
         return Drive1541.Register_Text;
      end if;
      return "PC=$" & Disasm.Hex4 (CPU.PC) & " A=$" & Disasm.Hex2 (CPU.A) &
        " X=$" & Disasm.Hex2 (CPU.X) & " Y=$" & Disasm.Hex2 (CPU.Y) &
        " SP=$" & Disasm.Hex2 (CPU.SP) & " " &
        Flags_Text (CPU.Flag_N, CPU.Flag_V, CPU.Flag_D, CPU.Flag_I,
                    CPU.Flag_Z, CPU.Flag_C) &
        (case Current_Model is
            when VIC20 => V20S.Beam_Text,
            when C64 | C128 => C64S.Beam_Text,
            when Plus4 | C16 => P4S.Beam_Text) &
        (if Has_CPU_Port then "  $01=$" & Disasm.Hex2 (Peek (1))
         else "");
   end Register_Text;

   function CPU_PC (Drive : Boolean := False) return Word is
     (if Drive then Drive1541.Get_PC else CPU.PC);

   procedure Monitor_Set_PC (Addr : Word) is
   begin
      CPU.PC := Addr;
   end Monitor_Set_PC;

   ---------------------------------------------------------------------
   --  Main loop
   ---------------------------------------------------------------------

   function Frame_Flag return Boolean is
     (case Current_Model is
         when VIC20 => V20S.Frame_Done,
         when C64 | C128 => C64S.Frame_Done,
         when Plus4 | C16 => P4S.Frame_Done);

   procedure Clear_Frame_Flag is
   begin
      V20S.Clear_Frame;
      C64S.Clear_Frame;
      P4S.Clear_Frame;
   end Clear_Frame_Flag;

   procedure End_Of_Frame is
   begin
      case Current_Model is
         when VIC20 => V20S.End_Of_Frame;
         when C64 | C128 => C64S.End_Of_Frame;
         when Plus4 | C16 => P4S.End_Of_Frame;
      end case;
      Feed_Keyboard;
      Keyboard.Tick_Typing;
      Paddles.Tick (Keyboard.Joy1 or Keyboard.Joy2);
      Autostart_Step;
      Frames := Frames + 1;
   end End_Of_Frame;

   function Stall_Pending return Boolean is
     (Current_Model in C64 | C128 and then C64S.Stalled);

   --  Advance the system by one CPU instruction (or one VIC stall period).
   --  Returns True when a CPU instruction was executed.
   function Step_System return Boolean is
      N : Natural;
      Dev : Natural;
      IRQ_Now, NMI_Now : Boolean;
      Executed : Boolean := False;
      Stall : constant Natural :=
        (if Current_Model in C64 | C128 then C64S.Take_Stall else 0);
   begin
      if Stall > 0 then
         Clock_Devices (Stall);
      elsif Current_Model = C128 and then C64S.Z80_Running then
         C64S.Step_Z80 (Dev);
         if Dev > 0 then
            Clock_Devices (Dev);
         end if;
      else
         if Kernal_High then
            if CPU.PC = 16#FFD5# then
               Trap_Load;
            elsif CPU.PC = 16#FFD8# then
               Trap_Save;
            end if;
         end if;

         case Current_Model is
            when VIC20 => V20S.Interrupt_Lines (IRQ_Now, NMI_Now);
            when C64 | C128 => C64S.Interrupt_Lines (IRQ_Now, NMI_Now);
            when Plus4 | C16 => P4S.Interrupt_Lines (IRQ_Now, NMI_Now);
         end case;
         CPU.IRQ_Line := IRQ_Now;
         if NMI_Now and then not NMI_Prev then
            CPU.NMI_Pending := True;
            NMI_Count := NMI_Count + 1;
            Last_NMI_PC := CPU.PC;
         end if;
         if CPU.IRQ_Line and then not CPU.Flag_I then
            IRQ_Count := IRQ_Count + 1;
         end if;
         NMI_Prev := NMI_Now;

         Instr_Ticked := 0;
         In_Step := True;
         CPU.Step (N);
         In_Step := False;
         Executed := True;

         if Fast_Mode then
            Dev := (N + Half_Cycle) / 2;
            Half_Cycle := (N + Half_Cycle) mod 2;
         else
            Dev := (if N > Instr_Ticked then N - Instr_Ticked else 0);
         end if;
         Instr_Ticked := 0;
         if Dev > 0 then
            if Is_TED then
               P4S.Run_CPU (Dev);      --  TED cycles the CPU may use
            else
               Clock_Devices (Dev);
            end if;
         end if;
      end if;
      if Drive_On then
         Drive1541.Run_Until (Total_Cycles);
      end if;
      if Current_Model = VIC20 and then V20S.Soft_Reset_Pending then
         Reset (Hard => False);          --  Mega-Cart $9E00: keeps RAM
      end if;
      return Executed;
   end Step_System;

   function At_Breakpoint_Now return Boolean is
     (BP_Count > 0 and then At_Breakpoint);

   procedure Run_Frame is
      Executed : Boolean;
      Op : Byte := 0;
   begin
      if Break_Flag then
         return;          --  stopped at a breakpoint until Resume
      end if;
      while not Frame_Flag loop
         if Debugging and then not Stall_Pending
           and then not (Current_Model = C128 and then C64S.Z80_Running)
         then
            if Pause_Req then
               Stop (Paused);
               return;
            end if;
            if not Skip_Break then
               if At_Breakpoint_Now then
                  Stop (Breakpoint);
                  return;
               end if;
               if Temp_Addr >= 0 and then Integer (CPU.PC) = Temp_Addr
                 and then CPU.SP >= Temp_SP
               then
                  Stop (Step_Done);
                  return;
               end if;
            end if;
            Skip_Break := False;
            if Out_Active then
               Op := Peek (CPU.PC);
            end if;
         end if;
         Executed := Step_System;
         if Executed and then (Watch_Hit or else Out_Active) then
            if Watch_Hit then
               Watch_Hit := False;
               Stop (if Watch_Write_Hit then Watch_Write else Watch_Read);
               return;
            end if;
            if Op in 16#60# | 16#40# and then CPU.SP > Out_SP then
               Stop (Step_Done);
               return;
            end if;
         end if;
      end loop;
      Clear_Frame_Flag;
      End_Of_Frame;
   end Run_Frame;

   procedure Step_Instruction is
   begin
      loop
         exit when Step_System;
      end loop;
      Watch_Hit := False;
      if Frame_Flag then
         Clear_Frame_Flag;
         End_Of_Frame;
      end if;
      Skip_Break := True;
      Reason := Step_Done;
   end Step_Instruction;

   procedure Step_Over is
   begin
      if Peek (CPU.PC) = 16#20# then          --  JSR: run to the next one
         Temp_Addr := Integer (CPU.PC + 3);
         Temp_SP := CPU.SP;
         Resume;
      else
         Step_Instruction;
      end if;
   end Step_Over;

end Machine;
