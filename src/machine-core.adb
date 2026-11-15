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

with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;
with Drive1541;
with IEC;
with Media;
use type Media.Media_Kind;
with Machine.C64_System;
with Machine.VIC20_System;
with Machine.Plus4_System;

package body Machine.Core is

   procedure Check_Watch (Addr : Word; Is_Write : Boolean) is
   begin
      for I in 1 .. Watch_Count loop
         if Addr >= Watches (I).From and then Addr <= Watches (I).To
           and then (if Is_Write then Watches (I).On_Write
                     else Watches (I).On_Read)
         then
            if not Watch_Hit then
               Watch_Hit := True;
               Watch_Write_Hit := Is_Write;
               Watch_Addr := Addr;
            end if;
         end if;
      end loop;
   end Check_Watch;

   function Fast_Mode return Boolean is
     (Current_Model = C128 and then C64_System.Fast_2MHz);

   procedure Catch_Up is
      Target : constant Natural :=
        (if CPU.Current_Cycles > 0 then CPU.Current_Cycles - 1 else 0);
   begin
      if In_Step and then Current_Model in Plus4 | C16 then
         if Target > Instr_Ticked then
            Plus4_System.Run_CPU (Target - Instr_Ticked);
            Instr_Ticked := Target;
         end if;
         Plus4_System.Wait_Free;       --  the access's own cycle
      elsif In_Step and then not Fast_Mode and then Target > Instr_Ticked then
         Clock_Devices (Target - Instr_Ticked);
         Instr_Ticked := Target;
      end if;
   end Catch_Up;

   procedure Sync_Drive (Write_Delay : Natural := 0) is
      --  The drive is run up to the last cycle of the executing
      --  instruction (the other chips have already been clocked there by
      --  Catch_Up). A write by the computer becomes visible to the drive
      --  one cycle later (CIA output, 7406 inverter and VIA input latch),
      --  so for writes the drive is run one cycle further first.
      Offset : Natural := (if In_Step
                             and then CPU.Current_Cycles > Instr_Ticked + 1
                           then CPU.Current_Cycles - 1 - Instr_Ticked
                           else 0);
   begin
      if Drive_On then
         if Fast_Mode then
            Offset := Offset / 2;
         end if;
         Drive1541.Run_Until
           (Total_Cycles + Long_Long_Integer (Offset + Write_Delay));
      end if;
   end Sync_Drive;

   procedure Rebuild_Map is
   begin
      case Current_Model is
         when VIC20 => VIC20_System.Rebuild_Map;
         when C64 | C128 => C64_System.Rebuild_Map;
         when Plus4 | C16 => Plus4_System.Rebuild_Map;
      end case;
   end Rebuild_Map;

   procedure Clock_Devices (N : Natural) is
   begin
      Total_Cycles := Total_Cycles + Long_Long_Integer (N);
      case Current_Model is
         when VIC20 => VIC20_System.Clock (N);
         when C64 | C128 => C64_System.Clock (N);
         when Plus4 | C16 => Plus4_System.Clock (N);
      end case;
   end Clock_Devices;

   function IO_Read (Addr : Word) return Byte is
   begin
      Catch_Up;
      case Current_Model is
         when VIC20 => return VIC20_System.IO_Read (Addr);
         when C64 | C128 => return C64_System.IO_Read (Addr);
         when Plus4 | C16 => return Plus4_System.IO_Read (Addr);
      end case;
   end IO_Read;

   procedure IO_Write (Addr : Word; Value : Byte) is
   begin
      Catch_Up;
      case Current_Model is
         when VIC20 => VIC20_System.IO_Write (Addr, Value);
         when C64 | C128 => C64_System.IO_Write (Addr, Value);
         when Plus4 | C16 => Plus4_System.IO_Write (Addr, Value);
      end case;
   end IO_Write;

   function Bus_Read (Addr : Word) return Byte is
      Page : constant Byte := Hi (Addr);
      Off  : Integer;
   begin
      if Watch_Count > 0 and then In_Step then
         Check_Watch (Addr, False);
      end if;
      if Addr < 2 and then Has_CPU_Port then
         if Current_Model in Plus4 | C16 then
            Catch_Up;          --  the tape and serial lines at this cycle
            return Plus4_System.Port_Read (Addr);
         end if;
         return C64_System.Port_Read (Addr);
      end if;
      if Page = 16#FF# and then not C64_Mode and then Addr <= 16#FF04# then
         return C64_System.MMU_Read (Natural (Addr - 16#FF00#));
      end if;
      Off := Read_Map (Page);
      if Off >= 0 then
         return Mem (Off + Natural (Addr and 16#FF#));
      end if;
      return IO_Read (Addr);
   end Bus_Read;

   procedure Bus_Write (Addr : Word; Value : Byte) is
      Page : constant Byte := Hi (Addr);
      Off  : Integer;
   begin
      if Watch_Count > 0 and then In_Step then
         Check_Watch (Addr, True);
      end if;
      if Addr < 2 and then Has_CPU_Port then
         if Current_Model in Plus4 | C16 then
            Catch_Up;
            Plus4_System.Port_Write (Addr, Value);
         else
            C64_System.Port_Write (Addr, Value);
         end if;
         return;
      end if;
      if Page = 16#FF# and then not C64_Mode and then Addr <= 16#FF04# then
         C64_System.MMU_Config_Write (Addr, Value);
         return;
      end if;
      if Addr = 16#FF00# and then Current_Model in C64 | C128 then
         C64_System.FF00_Written;  --  REU trigger; also goes to RAM below
      end if;
      Off := Write_Map (Page);
      if Off >= 0 then
         Mem (Off + Natural (Addr and 16#FF#)) := Value;
      else
         IO_Write (Addr, Value);
      end if;
   end Bus_Write;

   procedure Update_Drive_State is
      --  the 1581 reads D81 disks, the 1541 / 1571 the GCR ones
      Want : constant Boolean :=
        True_Drive and then Drive1541.ROM_Loaded
        and then (if Drive1541."=" (Drive1541.Model, Drive1541.D1581)
                  then Media.Kind = Media.D81
                  else Media.Kind in Media.D64 | Media.D71 | Media.G64);
   begin
      if Want and then not Drive_On then
         Drive1541.Reset;
         --  Line up the drive's clock with the computer's
         Drive1541.Set_Time (Total_Cycles);
      end if;
      Drive_On := Want;
      IEC.Drive_Present := Want;
   end Update_Drive_State;

   procedure Load_ROM (Path : String; Offset : Natural; Size : Natural;
                       Skip : Natural := 0; Ok : in out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Buf : Byte_Array (0 .. Skip + Size - 1);
   begin
      Open (F, In_File, Path);
      Byte_Array'Read (Stream (F), Buf);
      Close (F);
      Mem (Offset .. Offset + Size - 1) := Buf (Skip .. Skip + Size - 1);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Append (Err, "Cannot load ROM " & Path & ASCII.LF);
         Ok := False;
   end Load_ROM;

   function Read_All (Path : String; Ok : out Boolean) return Byte_Array is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      declare
         D : Byte_Array (0 .. Natural (Size (F)) - 1);
      begin
         Byte_Array'Read (Stream (F), D);
         Close (F);
         Ok := True;
         return D;
      end;
   exception
      when others =>
         Ok := False;
         return (1 .. 0 => 0);
   end Read_All;

end Machine.Core;
