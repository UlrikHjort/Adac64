--  AdaC64 - a Commodore 64 / 128 emulator written in Ada with GtkAda.
--
--  Usage: adac64 [options] [file.d64|file.t64|file.prg]
--    --c64 / --c128     start as a Commodore 64 / 128 (default: last used)
--    --80 / --40        C128: 40/80 key down (80 columns) / up
--    --roms DIR         ROM directory (default /usr/share/vice)
--    --drive-rom FILE   1541 DOS ROM (16 KB); default: search ROM dirs
--    --fast-drive       use KERNAL traps instead of the emulated 1541
--    --no-fast-load     with the 1541: KERNAL LOAD through the drive too
--    --list-joysticks   list host game controllers and exit
--    --reu KB           RAM expansion: 128, 256, 512, 1024 .. 16384 (0 = none)
--    --attach FILE      attach a disk image without autostarting
--    --headless N       run N frames without GUI, then save screenshots
--    --png FILE         screenshot file for headless mode (default shot.png)
--    --type TEXT        type TEXT after boot (use \n for RETURN)
--    --type-at F TEXT   type TEXT at frame F (repeatable)
--    --save-snapshot F save the machine state after the run
--    --load-snapshot F start from a saved machine state
--    --break ADDR       stop at a breakpoint (hex address)
--    --monitor "C;C"    run monitor commands after the headless run
--    --keys-at F TEXT   type TEXT through the keyboard matrix at frame F
--    --dump FILE        headless: write the 64 KB CPU view of memory
--    --wav FILE         headless: record SID output to a WAV file

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Types;
with Machine;
with Blit;
with GUI;
with Monitor_Commands;
with Keyboard;
with Host_Joystick;
with REU;
with SID;
with Wav_Sink;

procedure AdaC64 is
   procedure Print_Line (S : String) is
   begin
      Ada.Text_IO.Put_Line (S);
   end Print_Line;
   subtype Machine_Word is Types.Word;
   Model    : Machine.Model_Type := Machine.C64;
   Model_Given, Key80_Given, REU_Given : Boolean := False;
   ROM_Dir  : Unbounded_String := To_Unbounded_String ("/usr/share/vice");
   Headless : Natural := 0;
   PNG      : Unbounded_String := To_Unbounded_String ("shot.png");
   File     : Unbounded_String;
   Text     : Unbounded_String;
   Wav      : Unbounded_String;
   Attach   : Unbounded_String;
   Dump     : Unbounded_String;
   Save_Snap, Load_Snap : Unbounded_String;
   Mon_Cmds : Unbounded_String;
   type Timed_Text is record
      Frame : Natural := 0;
      Text  : Unbounded_String;
   end record;
   Timed : array (1 .. 16) of Timed_Text;
   Timed_Count : Natural := 0;
   I        : Positive := 1;
   Ok       : Boolean;

   function Unescape (S : String) return String is
      R : Unbounded_String;
      J : Positive := S'First;
   begin
      while J <= S'Last loop
         if S (J) = '\' and then J < S'Last and then S (J + 1) = 'n' then
            Append (R, ASCII.LF);
            J := J + 2;
         else
            Append (R, S (J));
            J := J + 1;
         end if;
      end loop;
      return To_String (R);
   end Unescape;
begin
   while I <= Argument_Count loop
      declare
         A : constant String := Argument (I);
      begin
         if A = "--c128" then
            Model := Machine.C128;
            Model_Given := True;
         elsif A = "--c64" then
            Model := Machine.C64;
            Model_Given := True;
         elsif A = "--80" then
            Machine.Key_4080_Down := True;
            Key80_Given := True;
         elsif A = "--40" then
            Machine.Key_4080_Down := False;
            Key80_Given := True;
         elsif A = "--roms" and then I < Argument_Count then
            I := I + 1;
            ROM_Dir := To_Unbounded_String (Argument (I));
         elsif A = "--headless" and then I < Argument_Count then
            I := I + 1;
            Headless := Natural'Value (Argument (I));
         elsif A = "--png" and then I < Argument_Count then
            I := I + 1;
            PNG := To_Unbounded_String (Argument (I));
         elsif A = "--list-joysticks" then
            Host_Joystick.Scan;
            for J in 0 .. Host_Joystick.Count - 1 loop
               Host_Joystick.Open (J);
               delay 0.2;
               Host_Joystick.Poll;
               Put_Line ("js" &
                         Ada.Strings.Fixed.Trim
                           (Host_Joystick.Device_Number (J)'Image,
                            Ada.Strings.Left) & ": " &
                         Host_Joystick.Name (J) &
                         (if Host_Joystick.Selected = J then "" else
                          "  (cannot open)") &
                         "  state=" & Keyboard.Host_Joystick_Bits'Image &
                         (if J = Host_Joystick.Auto_Select
                          then "  <- default" else ""));
               Host_Joystick.Close;
            end loop;
            return;
         elsif A = "--reu" and then I < Argument_Count then
            I := I + 1;
            REU.Set_Size (REU.Size_KB'Value (Argument (I)));
            REU_Given := True;
         elsif A = "--attach" and then I < Argument_Count then
            I := I + 1;
            Attach := To_Unbounded_String (Argument (I));
         elsif A = "--drive-rom" and then I < Argument_Count then
            I := I + 1;
            Machine.Drive_ROM_Path := To_Unbounded_String (Argument (I));
         elsif A = "--type-at" and then I + 1 < Argument_Count then
            Timed_Count := Timed_Count + 1;
            Timed (Timed_Count) :=
              (Natural'Value (Argument (I + 1)),
               To_Unbounded_String (Unescape (Argument (I + 2))));
            I := I + 2;
         elsif A = "--save-snapshot" and then I < Argument_Count then
            I := I + 1;
            Save_Snap := To_Unbounded_String (Argument (I));
         elsif A = "--load-snapshot" and then I < Argument_Count then
            I := I + 1;
            Load_Snap := To_Unbounded_String (Argument (I));
         elsif A = "--break" and then I < Argument_Count then
            I := I + 1;
            Machine.Set_Breakpoint
              (Types.Word'Value ("16#" & Argument (I) & "#"));
         elsif A = "--monitor" and then I < Argument_Count then
            I := I + 1;
            Mon_Cmds := To_Unbounded_String (Argument (I));
         elsif A = "--keys-at" and then I + 1 < Argument_Count then
            Timed_Count := Timed_Count + 1;
            Timed (Timed_Count) :=
              (Natural'Value (Argument (I + 1)),
               To_Unbounded_String (ASCII.NUL & Unescape (Argument (I + 2))));
            I := I + 2;
         elsif A = "--dump" and then I < Argument_Count then
            I := I + 1;
            Dump := To_Unbounded_String (Argument (I));
         elsif A = "--no-fast-load" then
            Machine.Fast_Kernal_Load := False;
         elsif A = "--fast-drive" then
            Machine.True_Drive := False;
         elsif A = "--wav" and then I < Argument_Count then
            I := I + 1;
            Wav := To_Unbounded_String (Argument (I));
         elsif A = "--type" and then I < Argument_Count then
            I := I + 1;
            Text := To_Unbounded_String (Unescape (Argument (I)));
         else
            File := To_Unbounded_String (A);
         end if;
      end;
      I := I + 1;
   end loop;

   if Headless = 0 then
      GUI.Run (Model, To_String (ROM_Dir), To_String (File),
               Model_Given, Key80_Given, REU_Given);
      return;
   end if;

   if Length (Wav) > 0 then
      SID.Sink := Wav_Sink.Push'Access;
   end if;
   Machine.Power_On (Model, To_String (ROM_Dir), Ok);
   if not Ok then
      Put_Line (Standard_Error, Machine.Error_Message);
      Set_Exit_Status (Failure);
      return;
   end if;
   if Length (Attach) > 0 then
      Machine.Attach (To_String (Attach), Ok);
   end if;
   if Length (Load_Snap) > 0 then
      Machine.Load_Snapshot (To_String (Load_Snap), Ok);
      if not Ok then
         Put_Line (Standard_Error, Machine.Error_Message);
      end if;
   end if;
   if Length (File) > 0 then
      Machine.Autostart (To_String (File), Ok);
      if not Ok then
         Put_Line (Standard_Error, "Cannot open " & To_String (File));
      end if;
   end if;

   declare
      Typed : Boolean := Length (Text) = 0;
   begin
      for F in 1 .. Headless loop
         Machine.Run_Frame;
         if Machine.Break_Hit then
            Put_Line ("break at frame" & F'Image);
            exit;
         end if;
         for T of Timed (1 .. Timed_Count) loop
            if T.Frame = F then
               declare
                  Txt : constant String := To_String (T.Text);
               begin
                  if Txt'Length > 0 and then Txt (Txt'First) = ASCII.NUL then
                     Keyboard.Type_Keys (Txt (Txt'First + 1 .. Txt'Last));
                  else
                     Machine.Type_Text (Txt);
                  end if;
               end;
            end if;
         end loop;
         if not Typed and then Machine.Screen_Contains ("READY.") then
            Machine.Type_Text (To_String (Text));
            Typed := True;
         end if;
      end loop;
   end;

   Put_Line ("PC=" & Machine.Get_PC'Image & " frames=" &
             Machine.Frame_Count'Image &
             " $01=" & Machine.Peek (1)'Image);
   if Length (Mon_Cmds) > 0 then
      Monitor_Commands.Output := Print_Line'Unrestricted_Access;
      declare
         C : constant String := To_String (Mon_Cmds);
         Start : Positive := C'First;
      begin
         for K in C'Range loop
            if C (K) = ';' or else K = C'Last then
               Monitor_Commands.Execute
                 (C (Start .. (if C (K) = ';' then K - 1 else K)));
               Start := K + 1;
            end if;
         end loop;
      end;
   end if;
   if Length (Save_Snap) > 0 then
      Machine.Save_Snapshot (To_String (Save_Snap), Ok);
   end if;
   Machine.Shutdown;
   if Length (Dump) > 0 then
      declare
         F : File_Type;
      begin
         Create (F, Out_File, To_String (Dump));
         for A in 0 .. 65535 loop
            Put (F, Character'Val (Machine.Peek (Machine_Word (A))));
         end loop;
         for A in 0 .. 2047 loop
            Put (F, Character'Val (Machine.Drive_Peek (A)));
         end loop;
         Close (F);
      end;
   end if;
   Put_Line (Machine.Debug_Info);
   Put_Line ("drive: active=" & Machine.Drive_Active'Image & " track=" &
             Machine.Drive_Track'Image & " motor=" &
             Machine.Drive_Motor'Image);
   Blit.Save_PNG (Blit.VIC_Screen, To_String (PNG));
   if Length (Wav) > 0 then
      Wav_Sink.Save (To_String (Wav));
   end if;
   if Machine.VDC_Enabled then
      declare
         P : constant String := To_String (PNG);
         Slash : constant Natural :=
           Ada.Strings.Fixed.Index (P, "/", Ada.Strings.Backward);
      begin
         Blit.Save_PNG (Blit.VDC_Screen,
                        P (P'First .. Slash) & "vdc_" & P (Slash + 1 .. P'Last));
      end;
   end if;
end AdaC64;
