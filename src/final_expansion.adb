-- ***************************************************************************
--                      AdaC64 - Final_Expansion
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

with Interfaces; use Interfaces;

package body Final_Expansion is

   RAM_Size : constant := 16#80000#;

   RAM   : Byte_Array (0 .. RAM_Size - 1) := (others => 16#FF#);
   Flash : Byte_Array (0 .. Flash_Size - 1) := (others => 16#FF#);

   Reg_A, Reg_B : Byte := 0;
   Lock_Bit : Boolean := True;

   Open_Bus : constant Byte := 16#FF#;

   --  register A ($9C02): mode (bits 7-5), bank (bits 3-0, 32K steps) or
   --  block selects / RAM123 read-only (bits 4-0, in the RAM modes);
   --  register B ($9C03): blocks off (bits 4-0), A13 / A14 inverted
   --  (bits 5 / 6), registers off (bit 7)
   Mode_Start     : constant Byte := 16#00#;
   Mode_Flash     : constant Byte := 16#20#;
   Mode_Super_ROM : constant Byte := 16#40#;
   Mode_ROM_RAM   : constant Byte := 16#60#;
   Mode_RAM1      : constant Byte := 16#80#;
   Mode_Super_RAM : constant Byte := 16#A0#;
   Mode_RAM2      : constant Byte := 16#C0#;

   function Mode return Byte is (Reg_A and 16#E0#);

   ---------------------------------------------------------------------
   --  AM29F040B flash (VICE's flash040core, type B)
   ---------------------------------------------------------------------

   type Flash_State is
     (Read_Array, Magic_1, Magic_2, Autoselect, Byte_Program,
      Byte_Program_Error, Erase_Magic_1, Erase_Magic_2, Erase_Select,
      Chip_Erase, Sector_Erase, Sector_Erase_Timeout, Sector_Erase_Suspend);

   State, Base_State : Flash_State := Read_Array;
   Program_Byte : Byte := 0;
   Last_Read    : Byte := 0;
   Erase_Mask   : array (0 .. 7) of Boolean := (others => False);
   Alarm_On     : Boolean := False;
   Alarm_At     : Long_Long_Integer := 0;

   Sector_Timeout_Cycles : constant := 50;
   Sector_Erase_Cycles   : constant := 1_000_000;
   Chip_Erase_Cycles     : constant := 8_000_000;

   function Magic_1_Addr (A : Natural) return Boolean is
     (A mod 16#800# = 16#555#);
   function Magic_2_Addr (A : Natural) return Boolean is
     (A mod 16#800# = 16#2AA#);

   procedure Set_Alarm (Now : Long_Long_Integer; Cycles : Natural) is
   begin
      Alarm_On := True;
      Alarm_At := Now + Long_Long_Integer (Cycles);
   end Set_Alarm;

   procedure Advance (Now : Long_Long_Integer) is
   begin
      while Alarm_On and then Now >= Alarm_At loop
         Alarm_On := False;
         case State is
            when Sector_Erase_Timeout =>
               State := Sector_Erase;
               Set_Alarm (Alarm_At, Sector_Erase_Cycles);
            when Sector_Erase =>
               for S in Erase_Mask'Range loop
                  if Erase_Mask (S) then
                     Flash (S * 16#10000# .. S * 16#10000# + 16#FFFF#) :=
                       (others => 16#FF#);
                     Flash_Changed := True;
                     Erase_Mask (S) := False;
                     exit;
                  end if;
               end loop;
               if (for some M of Erase_Mask => M) then
                  Set_Alarm (Alarm_At, Sector_Erase_Cycles);
               else
                  State := Base_State;
               end if;
            when Chip_Erase =>
               Flash := (others => 16#FF#);
               Flash_Changed := True;
               State := Base_State;
            when others =>
               null;
         end case;
      end loop;
   end Advance;

   procedure Flash_Store (A : Natural; Value : Byte; Now : Long_Long_Integer)
   is
   begin
      case State is
         when Read_Array =>
            if Magic_1_Addr (A) and then Value = 16#AA# then
               State := Magic_1;
            end if;
         when Magic_1 =>
            State := (if Magic_2_Addr (A) and then Value = 16#55#
                      then Magic_2 else Base_State);
         when Magic_2 =>
            if Magic_1_Addr (A) then
               case Value is
                  when 16#90# =>
                     State := Autoselect;
                     Base_State := Autoselect;
                  when 16#F0# =>
                     State := Read_Array;
                     Base_State := Read_Array;
                  when 16#A0# => State := Byte_Program;
                  when 16#80# => State := Erase_Magic_1;
                  when others => State := Base_State;
               end case;
            else
               State := Base_State;
            end if;
         when Byte_Program =>
            Program_Byte := Value;
            Flash (A) := Flash (A) and Value;
            Flash_Changed := True;
            State := (if Flash (A) = Value then Base_State
                      else Byte_Program_Error);
         when Erase_Magic_1 =>
            State := (if Magic_1_Addr (A) and then Value = 16#AA#
                      then Erase_Magic_2 else Base_State);
         when Erase_Magic_2 =>
            State := (if Magic_2_Addr (A) and then Value = 16#55#
                      then Erase_Select else Base_State);
         when Erase_Select =>
            if Magic_1_Addr (A) and then Value = 16#10# then
               State := Chip_Erase;
               Program_Byte := 0;
               Set_Alarm (Now, Chip_Erase_Cycles);
            elsif Value = 16#30# then
               Erase_Mask (A / 16#10000#) := True;
               Program_Byte := 0;
               State := Sector_Erase_Timeout;
               Set_Alarm (Now, Sector_Timeout_Cycles);
            else
               State := Base_State;
            end if;
         when Sector_Erase_Timeout =>
            if Value = 16#30# then
               Erase_Mask (A / 16#10000#) := True;
            else
               State := Base_State;
               Erase_Mask := (others => False);
               Alarm_On := False;
            end if;
         when Sector_Erase =>
            if Value = 16#B0# then
               State := Sector_Erase_Suspend;
               Alarm_On := False;
            end if;
         when Sector_Erase_Suspend =>
            if Value = 16#30# then
               State := Sector_Erase;
               Set_Alarm (Now, Sector_Erase_Cycles);
            end if;
         when Byte_Program_Error | Autoselect =>
            if Magic_1_Addr (A) and then Value = 16#AA# then
               State := Magic_1;
            end if;
            if Value = 16#F0# then
               State := Read_Array;
               Base_State := Read_Array;
            end if;
         when Chip_Erase =>
            null;
      end case;
   end Flash_Store;

   function Flash_Read (A : Natural; Now : Long_Long_Integer) return Byte is
      V : Byte;
   begin
      case State is
         when Autoselect =>
            V := (case A mod 256 is
                     when 0 => 16#01#,          --  AMD
                     when 1 => 16#A4#,          --  29F040
                     when 2 => 0,
                     when others => Flash (A));
         when Byte_Program_Error =>
            --  DQ7 inverted data, DQ6 toggles (2 us), DQ5 timeout
            V := ((Program_Byte xor 16#80#) and 16#80#)
              or (if (Now / 2) mod 2 = 1 then 16#40# else 0) or 16#20#;
         when Sector_Erase_Suspend | Chip_Erase | Sector_Erase
            | Sector_Erase_Timeout =>
            V := Program_Byte;
            Program_Byte := Program_Byte xor 16#40#;
            if State /= Sector_Erase_Timeout then
               V := V or 16#08#;
            end if;
         when others =>
            V := Flash (A);
      end case;
      Last_Read := V;
      return V;
   end Flash_Read;

   ---------------------------------------------------------------------
   --  Banking
   ---------------------------------------------------------------------

   Base_Of : constant array (0 .. 5) of Natural :=
     (0 => 0, 1 => 0, 2 => 16#2000#, 3 => 16#4000#, 4 => 0, 5 => 16#6000#);
   Sel_Bit : constant array (1 .. 5) of Byte :=
     (1 => 16#02#, 2 => 16#04#, 3 => 16#08#, 4 => 0, 5 => 16#10#);
   Off_Bit : constant array (0 .. 5) of Byte :=
     (0 => 16#01#, 1 => 16#02#, 2 => 16#04#, 3 => 16#08#, 4 => 0,
      5 => 16#10#);

   function Calc (Addr : Word; Bank : Natural; Base : Natural) return Natural
   is
      F : Unsigned_32 :=
        Unsigned_32 (Addr and 16#1FFF#) + Unsigned_32 (Bank * 16#8000# + Base);
   begin
      if (Reg_B and 16#20#) /= 0 then
         F := F xor 16#2000#;       --  A13 inverted
      end if;
      if (Reg_B and 16#40#) /= 0 then
         F := F xor 16#4000#;       --  A14 inverted
      end if;
      return Natural (F);
   end Calc;

   function Block_Of (Addr : Word) return Natural is
     (case Addr is
         when 16#0400# .. 16#0FFF# => 0,
         when 16#2000# .. 16#3FFF# => 1,
         when 16#4000# .. 16#5FFF# => 2,
         when 16#6000# .. 16#7FFF# => 3,
         when others => 5);

   function Read_Bank (Sel : Boolean) return Natural is
     (case Mode is
         when Mode_Flash | Mode_Super_ROM | Mode_Super_RAM =>
            Natural (Reg_A and 16#0F#),
         when Mode_ROM_RAM => (if Sel then 0 else 1),
         when Mode_RAM1 => 1,
         when Mode_RAM2 => (if Sel then 2 else 1),
         when others => 0);

   function Write_Bank (Sel : Boolean) return Natural is
     (case Mode is
         when Mode_Flash | Mode_Super_RAM => Natural (Reg_A and 16#0F#),
         when Mode_Super_ROM | Mode_Start => 1,
         when Mode_ROM_RAM | Mode_RAM1 => (if Sel then 2 else 1),
         when Mode_RAM2 => 1,
         when others => 0);

   function Locked return Boolean is
     ((Reg_B and 16#80#) /= 0
      or else (Mode = Mode_Start and then Lock_Bit));

   function Block_Read (Addr : Word; Now : Long_Long_Integer;
                        Side_Effects : Boolean) return Byte
   is
      B : constant Natural := Block_Of (Addr);
      Sel : Boolean;
      F : Natural;
   begin
      if (Reg_B and Off_Bit (B)) /= 0 then
         return Open_Bus;
      end if;
      if B = 0 then
         return (if Mode in Mode_ROM_RAM | Mode_RAM1 | Mode_RAM2
                    | Mode_Super_ROM | Mode_Super_RAM
                 then RAM (Calc (Addr, 0, 0)) else Open_Bus);
      end if;
      Sel := (Reg_A and Sel_Bit (B)) /= 0;
      F := Calc (Addr, Read_Bank (Sel), Base_Of (B));
      case Mode is
         when Mode_Start =>
            if B /= 5 then
               return Open_Bus;
            end if;
         when Mode_Flash | Mode_Super_ROM =>
            null;
         when Mode_ROM_RAM =>
            if not Sel then
               return RAM (F);
            end if;
         when Mode_RAM1 | Mode_RAM2 | Mode_Super_RAM =>
            return RAM (F);
         when others =>
            return Open_Bus;
      end case;
      if Side_Effects then
         Advance (Now);
         return Flash_Read (F, Now);
      end if;
      return Flash (F);
   end Block_Read;

   function Read (Addr : Word; Now : Long_Long_Integer) return Byte is
   begin
      if Addr >= 16#9C00# and then Addr <= 16#9FFF# then
         if not Locked then
            case Addr and 3 is
               when 2 => return Reg_A;
               when 3 => return Reg_B;
               when others => null;
            end case;
         end if;
         return Open_Bus;
      end if;
      if Addr >= 16#A000# then
         Lock_Bit := True;
      end if;
      return Block_Read (Addr, Now, True);
   end Read;

   function Peek (Addr : Word) return Byte is
   begin
      if Addr >= 16#9C00# and then Addr <= 16#9FFF# then
         return (case Addr and 3 is
                    when 2 => Reg_A, when 3 => Reg_B, when others => Open_Bus);
      end if;
      return Block_Read (Addr, 0, False);
   end Peek;

   procedure Write (Addr : Word; Value : Byte; Now : Long_Long_Integer) is
      B : Natural;
      Sel : Boolean;
      F : Natural;
   begin
      if Addr >= 16#9C00# and then Addr <= 16#9FFF# then
         if not Locked then
            case Addr and 3 is
               when 2 => Reg_A := Value;
               when 3 => Reg_B := Value;
               when others => null;
            end case;
         end if;
         return;
      end if;
      B := Block_Of (Addr);
      if B = 5 then
         Lock_Bit := False;
      end if;
      if (Reg_B and Off_Bit (B)) /= 0 then
         return;
      end if;
      if B = 0 then
         case Mode is
            when Mode_ROM_RAM | Mode_RAM1 | Mode_RAM2 =>
               if (Reg_A and 16#01#) = 0 then        --  not read-only
                  RAM (Calc (Addr, 0, 0)) := Value;
               end if;
            when Mode_Super_ROM | Mode_Super_RAM =>
               RAM (Calc (Addr, 0, 0)) := Value;
            when others =>
               null;
         end case;
         return;
      end if;
      Sel := (Reg_A and Sel_Bit (B)) /= 0;
      F := Calc (Addr, Write_Bank (Sel), Base_Of (B));
      case Mode is
         when Mode_Flash =>
            Advance (Now);
            Flash_Store (F, Value, Now);
         when Mode_ROM_RAM | Mode_Start | Mode_RAM1 | Mode_RAM2
            | Mode_Super_ROM | Mode_Super_RAM =>
            RAM (F) := Value;
         when others =>
            null;
      end case;
   end Write;

   ---------------------------------------------------------------------

   procedure Reset is
   begin
      State := Read_Array;
      Base_State := Read_Array;
      Program_Byte := 0;
      Erase_Mask := (others => False);
      Alarm_On := False;
      Reg_A := 0;
      Reg_B := 0;
      Lock_Bit := True;
   end Reset;

   procedure Power_Up is
   begin
      --  VICE's pattern: $FF, inverted every 2 bytes (offset 1) and every
      --  256 bytes
      for I in RAM'Range loop
         RAM (I) := 16#FF#
           xor (if ((I + 1) / 2) mod 2 = 1 then 16#FF# else 0)
           xor (if (I / 256) mod 2 = 1 then 16#FF# else 0);
      end loop;
      Reset;
   end Power_Up;

   procedure Load (Data : Byte_Array) is
      Len : constant Natural := Natural'Min (Data'Length, Flash_Size);
      At_Off : Natural := 0;
   begin
      Flash := (others => 16#FF#);
      if Len < 16#8000# then
         --  in 4K steps, as close to the 32K boundary as possible
         At_Off := 16#8000# - ((Len + 16#FFF#) / 16#1000#) * 16#1000#;
      end if;
      Flash (At_Off .. At_Off + Len - 1) :=
        Data (Data'First .. Data'First + Len - 1);
      Flash_Changed := False;
      Power_Up;
   end Load;

   function Flash_Image return Byte_Array is (Flash);

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Boolean'Write (S, Present);
      if not Present then
         return;
      end if;
      Byte_Array'Write (S, RAM);
      Byte_Array'Write (S, Flash);
      Byte'Write (S, Reg_A);
      Byte'Write (S, Reg_B);
      Boolean'Write (S, Lock_Bit);
      Flash_State'Write (S, State);
      Flash_State'Write (S, Base_State);
      Byte'Write (S, Program_Byte);
      Byte'Write (S, Last_Read);
      for M of Erase_Mask loop
         Boolean'Write (S, M);
      end loop;
      Boolean'Write (S, Alarm_On);
      Long_Long_Integer'Write (S, Alarm_At);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Boolean'Read (S, Present);
      if not Present then
         return;
      end if;
      Byte_Array'Read (S, RAM);
      Byte_Array'Read (S, Flash);
      Byte'Read (S, Reg_A);
      Byte'Read (S, Reg_B);
      Boolean'Read (S, Lock_Bit);
      Flash_State'Read (S, State);
      Flash_State'Read (S, Base_State);
      Byte'Read (S, Program_Byte);
      Byte'Read (S, Last_Read);
      for M of Erase_Mask loop
         Boolean'Read (S, M);
      end loop;
      Boolean'Read (S, Alarm_On);
      Long_Long_Integer'Read (S, Alarm_At);
   end Load_State;

end Final_Expansion;
