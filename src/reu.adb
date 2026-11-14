with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;

package body REU is

   RAM : Byte_Array_Access := null;
   KB  : Size_KB := 0;

   Status    : Byte := 0;
   Command   : Byte := 16#10#;
   C64_Addr  : Word := 0;
   REU_Addr  : U32 := 0;       --  24 bit (bank in bits 16..23)
   Length    : Word := 16#FFFF#;
   IRQ_Mask  : Byte := 0;
   Addr_Ctrl : Byte := 0;

   --  Shadow registers for autoload
   S_C64_Addr : Word := 0;
   S_REU_Addr : U32 := 0;
   S_Length   : Word := 16#FFFF#;

   procedure Free is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

   function Size return Size_KB is (KB);
   function Present return Boolean is (KB > 0);

   function Mask return U32 is (U32 (KB) * 1024 - 1);

   procedure Set_Size (KB : Size_KB) is
   begin
      if RAM /= null then
         Free (RAM);
      end if;
      REU.KB := KB;
      if KB > 0 then
         RAM := new Byte_Array'(0 .. Natural (KB) * 1024 - 1 => 0);
      end if;
      Reset;
   end Set_Size;

   procedure Reset is
   begin
      Status := (if KB >= 256 then 16#10# else 0);
      Command := 16#10#;
      C64_Addr := 0; REU_Addr := 0; Length := 16#FFFF#;
      S_C64_Addr := 0; S_REU_Addr := 0; S_Length := 16#FFFF#;
      IRQ_Mask := 0;
      Addr_Ctrl := 0;
      Stall_Cycles := 0;
   end Reset;

   function IRQ return Boolean is ((Status and 16#80#) /= 0);

   procedure Update_IRQ is
   begin
      if (IRQ_Mask and 16#80#) /= 0
        and then (Status and IRQ_Mask and 16#60#) /= 0
      then
         Status := Status or 16#80#;
      end if;
   end Update_IRQ;

   procedure Execute is
      Kind  : constant Byte := Command and 3;
      Count : constant Natural :=
        (if Length = 0 then 65_536 else Natural (Length));
      Fix_C64 : constant Boolean := (Addr_Ctrl and 16#80#) /= 0;
      Fix_REU : constant Boolean := (Addr_Ctrl and 16#40#) /= 0;
      CA : Word := C64_Addr;
      RA : U32 := REU_Addr;
      Done : Natural := 0;
      V, W : Byte;
   begin
      if RAM = null or else Bus_Read = null or else Bus_Write = null then
         return;
      end if;
      for I in 1 .. Count loop
         Done := I;
         case Kind is
            when 0 =>    --  C64 -> REU
               RAM (Natural (RA and Mask)) := Bus_Read (CA);
            when 1 =>    --  REU -> C64
               Bus_Write (CA, RAM (Natural (RA and Mask)));
            when 2 =>    --  swap
               V := Bus_Read (CA);
               W := RAM (Natural (RA and Mask));
               Bus_Write (CA, W);
               RAM (Natural (RA and Mask)) := V;
            when others =>   --  verify
               if Bus_Read (CA) /= RAM (Natural (RA and Mask)) then
                  Status := Status or 16#20#;   --  fault
               end if;
         end case;
         if not Fix_C64 then
            CA := CA + 1;
         end if;
         if not Fix_REU then
            RA := (RA + 1) and 16#FF_FFFF#;
         end if;
         exit when Kind = 3 and then (Status and 16#20#) /= 0;
      end loop;

      Stall_Cycles := Stall_Cycles + Done * (if Kind = 2 then 2 else 1);
      if Done = Count then
         Status := Status or 16#40#;           --  end of block
      end if;

      if (Command and 16#20#) /= 0 then
         --  Autoload: restore the start registers
         C64_Addr := S_C64_Addr;
         REU_Addr := S_REU_Addr;
         Length := S_Length;
      else
         C64_Addr := CA;
         REU_Addr := RA;
         Length := Word ((Count - Done) mod 65_536);
         if Length = 0 then
            Length := 1;
         end if;
      end if;
      Command := (Command and not 16#80#) or 16#10#;
      Update_IRQ;
   end Execute;

   function Read (Reg : Natural) return Byte is
   begin
      if not Present then
         return 16#FF#;
      end if;
      case Reg mod 32 is
         when 0 =>
            declare
               V : constant Byte := Status;
            begin
               Status := Status and 16#1F#;   --  reading clears 5..7
               return V;
            end;
         when 1 => return Command;
         when 2 => return Lo (C64_Addr);
         when 3 => return Hi (C64_Addr);
         when 4 => return Byte (REU_Addr and 16#FF#);
         when 5 => return Byte (Shift_Right (REU_Addr, 8) and 16#FF#);
         when 6 => return Byte (Shift_Right (REU_Addr, 16) and 16#FF#) or
              (if KB <= 512 then 16#F8# else 0);
         when 7 => return Lo (Length);
         when 8 => return Hi (Length);
         when 9 => return IRQ_Mask or 16#1F#;
         when 10 => return Addr_Ctrl or 16#3F#;
         when others => return 16#FF#;
      end case;
   end Read;

   procedure Write (Reg : Natural; Value : Byte) is
   begin
      if not Present then
         return;
      end if;
      case Reg mod 32 is
         when 1 =>
            Command := Value;
            if (Value and 16#80#) /= 0 and then (Value and 16#10#) /= 0 then
               Execute;            --  immediate
            end if;
         when 2 =>
            C64_Addr := (C64_Addr and 16#FF00#) or Word (Value);
            S_C64_Addr := C64_Addr;
         when 3 =>
            C64_Addr := (C64_Addr and 16#00FF#) or Shift_Left (Word (Value), 8);
            S_C64_Addr := C64_Addr;
         when 4 =>
            REU_Addr := (REU_Addr and 16#FF_FF00#) or U32 (Value);
            S_REU_Addr := REU_Addr;
         when 5 =>
            REU_Addr := (REU_Addr and 16#FF_00FF#) or Shift_Left (U32 (Value), 8);
            S_REU_Addr := REU_Addr;
         when 6 =>
            REU_Addr := (REU_Addr and 16#00_FFFF#) or
              Shift_Left (U32 (Value), 16);
            S_REU_Addr := REU_Addr;
         when 7 =>
            Length := (Length and 16#FF00#) or Word (Value);
            S_Length := Length;
         when 8 =>
            Length := (Length and 16#00FF#) or Shift_Left (Word (Value), 8);
            S_Length := Length;
         when 9 =>
            IRQ_Mask := Value and 16#E0#;
            Update_IRQ;
         when 10 =>
            Addr_Ctrl := Value and 16#C0#;
         when others =>
            null;
      end case;
   end Write;

   procedure FF00_Written is
   begin
      if Present and then (Command and 16#90#) = 16#80# then
         Execute;
      end if;
   end FF00_Written;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Size_KB'Write (S, KB);
      Byte'Write (S, Status); Byte'Write (S, Command);
      Word'Write (S, C64_Addr); U32'Write (S, REU_Addr);
      Word'Write (S, Length); Byte'Write (S, IRQ_Mask);
      Byte'Write (S, Addr_Ctrl);
      Word'Write (S, S_C64_Addr); U32'Write (S, S_REU_Addr);
      Word'Write (S, S_Length);
      if RAM /= null then
         Byte_Array'Write (S, RAM.all);
      end if;
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
      K : Size_KB;
   begin
      Size_KB'Read (S, K);
      if K /= KB then
         Set_Size (K);
      end if;
      Byte'Read (S, Status); Byte'Read (S, Command);
      Word'Read (S, C64_Addr); U32'Read (S, REU_Addr);
      Word'Read (S, Length); Byte'Read (S, IRQ_Mask);
      Byte'Read (S, Addr_Ctrl);
      Word'Read (S, S_C64_Addr); U32'Read (S, S_REU_Addr);
      Word'Read (S, S_Length);
      if RAM /= null then
         Byte_Array'Read (S, RAM.all);
      end if;
   end Load_State;

end REU;
