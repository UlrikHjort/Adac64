-- ***************************************************************************
--                      AdaC64 - Debug_Test
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

--  Debugger API test: assembles debug_test.asm, runs it in the emulator
--  and exercises breakpoints, step over/into/out, run-to and watchpoints.

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Types; use Types;
with Interfaces; use Interfaces;
with Machine; use Machine;
with Asm;

procedure Debug_Test is
   Failures : Natural := 0;
   Ok : Boolean;
   V : Integer;

   function Addr (Name : String) return Word is
   begin
      if not Asm.Lookup (Name, V) then
         raise Program_Error with "no label " & Name;
      end if;
      return Word (V);
   end Addr;

   procedure Check (Cond : Boolean; What : String) is
   begin
      Put_Line ((if Cond then "ok   " else "FAIL ") & What);
      if not Cond then
         Failures := Failures + 1;
      end if;
   end Check;

   procedure Run_Until_Stop (Max_Frames : Natural := 400) is
   begin
      for F in 1 .. Max_Frames loop
         Run_Frame;
         exit when Break_Hit;
      end loop;
   end Run_Until_Stop;

begin
   Asm.Assemble ("tests/debug_test.asm");
   Check (not Asm.Has_Errors and then Asm.Has_Output, "assembled");
   Power_On (C64, "/usr/share/vice", Ok);
   Check (Ok, "power on");
   declare
      Data : Byte_Array (0 .. Natural (Asm.High_Address - Asm.Low_Address));
   begin
      for I in Data'Range loop
         Data (I) := Asm.Output_Byte (Asm.Low_Address + Word (I));
      end loop;
      Set_Breakpoint (Addr ("main"));
      Inject_And_Run (Data, Asm.Low_Address, "RUN");
   end;
   Run_Until_Stop (600);
   Check (Break_Hit and then CPU_PC = Addr ("main"), "breakpoint at main");
   Check (Last_Stop = Breakpoint, "reason breakpoint: " & Stop_Text);

   Step_Over;          --  JSR sub runs to completion
   Run_Until_Stop;
   Check (Break_Hit and then CPU_PC = Addr ("after"),
          "step over jsr -> after");

   Clear_Breakpoints;
   Resume;
   Run_To (Addr ("main"));
   Run_Until_Stop;
   Check (CPU_PC = Addr ("main"), "run to main");
   Step_Instruction;   --  into sub
   Check (CPU_PC = Addr ("sub"), "step into jsr -> sub");
   Step_Instruction;
   Step_Out;           --  run until sub returns
   Run_Until_Stop;
   Check (Break_Hit and then CPU_PC = Addr ("after"),
          "step out -> after (nested jsr inside)");

   Add_Watch (16#D020#, 16#D020#, False, True);
   Resume;
   Run_Until_Stop;
   Check (Last_Stop = Watch_Write, "watch write: " & Stop_Text);
   Check (CPU_PC = Addr ("after") + 7, "stopped after the sta $d020");
   Clear_Watches;

   Request_Break;
   Resume;
   Request_Break;
   Run_Until_Stop;
   Check (Last_Stop = Paused, "pause: " & Stop_Text);

   Resume;
   for F in 1 .. 50 loop
      Run_Frame;
   end loop;
   Check (not Break_Hit and then CPU_PC = Addr ("done")
          and then Peek (16#FB#) = 3, "program finished (counter = 3)");

   --  Soft reset keeps RAM (the program and its counter), hard reset not
   declare
      Prog_Byte : constant Byte := Peek (Addr ("start"));
   begin
      Reset (Hard => False);
      for F in 1 .. 150 loop
         Run_Frame;
      end loop;
      --  (the KERNAL clears zero page and BASIC's NEW zeroes the first
      --  line link at $0801, as on a real C64; the code itself survives)
      Check (Peek (Addr ("start")) = Prog_Byte,
             "soft reset keeps the program in RAM");
      Reset (Hard => True);
      for F in 1 .. 150 loop
         Run_Frame;
      end loop;
      Check (Peek (Addr ("start")) /= Prog_Byte, "hard reset clears RAM");
   end;

   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("all passed");
   end if;
end Debug_Test;
