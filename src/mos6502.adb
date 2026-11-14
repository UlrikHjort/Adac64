with Interfaces; use Interfaces;

package body MOS6502 is
   pragma Suppress (All_Checks);

   --  The 6502 polls IRQ using the I flag as it was before the last
   --  instruction for CLI, SEI and PLP (so an IRQ pending at CLI is taken
   --  one instruction later, and one can still occur right after SEI).
   Poll_I : Boolean := True;

   type Mnemonic is
     (ADC, AND_Op, ASL, BCC, BCS, BEQ, BIT_Op, BMI, BNE, BPL, BRK, BVC, BVS,
      CLC, CLD, CLI, CLV, CMP, CPX, CPY, DEC, DEX, DEY, EOR, INC, INX, INY,
      JMP, JSR, LDA, LDX, LDY, LSR, NOP, ORA, PHA, PHP, PLA, PLP, ROL, ROR,
      RTI, RTS, SBC, SEC, SED, SEI, STA, STX, STY, TAX, TAY, TSX, TXA, TXS,
      TYA,
      --  undocumented
      SLO, RLA, SRE, RRA, SAX, LAX, DCP, ISC, ANC, ALR, ARR, ANE, LXA, SBX,
      SHA, SHX, SHY, TAS, LAS, JAM);

   type Mode is
     (Imp, Acc, Imm, ZP, ZPX, ZPY, Abso, AbsX, AbsY, IndX, IndY, Ind, Rel);

   type Access_Kind is (K_Read, K_Write, K_RMW, K_Other);

   type Mnemonic_Table is array (Byte) of Mnemonic;

   Mnem : constant Mnemonic_Table :=
     (
      --  0x00
      BRK, ORA, JAM, SLO, NOP, ORA, ASL, SLO,
      PHP, ORA, ASL, ANC, NOP, ORA, ASL, SLO,
      --  0x10
      BPL, ORA, JAM, SLO, NOP, ORA, ASL, SLO,
      CLC, ORA, NOP, SLO, NOP, ORA, ASL, SLO,
      --  0x20
      JSR, AND_Op, JAM, RLA, BIT_Op, AND_Op, ROL, RLA,
      PLP, AND_Op, ROL, ANC, BIT_Op, AND_Op, ROL, RLA,
      --  0x30
      BMI, AND_Op, JAM, RLA, NOP, AND_Op, ROL, RLA,
      SEC, AND_Op, NOP, RLA, NOP, AND_Op, ROL, RLA,
      --  0x40
      RTI, EOR, JAM, SRE, NOP, EOR, LSR, SRE,
      PHA, EOR, LSR, ALR, JMP, EOR, LSR, SRE,
      --  0x50
      BVC, EOR, JAM, SRE, NOP, EOR, LSR, SRE,
      CLI, EOR, NOP, SRE, NOP, EOR, LSR, SRE,
      --  0x60
      RTS, ADC, JAM, RRA, NOP, ADC, ROR, RRA,
      PLA, ADC, ROR, ARR, JMP, ADC, ROR, RRA,
      --  0x70
      BVS, ADC, JAM, RRA, NOP, ADC, ROR, RRA,
      SEI, ADC, NOP, RRA, NOP, ADC, ROR, RRA,
      --  0x80
      NOP, STA, NOP, SAX, STY, STA, STX, SAX,
      DEY, NOP, TXA, ANE, STY, STA, STX, SAX,
      --  0x90
      BCC, STA, JAM, SHA, STY, STA, STX, SAX,
      TYA, STA, TXS, TAS, SHY, STA, SHX, SHA,
      --  0xA0
      LDY, LDA, LDX, LAX, LDY, LDA, LDX, LAX,
      TAY, LDA, TAX, LXA, LDY, LDA, LDX, LAX,
      --  0xB0
      BCS, LDA, JAM, LAX, LDY, LDA, LDX, LAX,
      CLV, LDA, TSX, LAS, LDY, LDA, LDX, LAX,
      --  0xC0
      CPY, CMP, NOP, DCP, CPY, CMP, DEC, DCP,
      INY, CMP, DEX, SBX, CPY, CMP, DEC, DCP,
      --  0xD0
      BNE, CMP, JAM, DCP, NOP, CMP, DEC, DCP,
      CLD, CMP, NOP, DCP, NOP, CMP, DEC, DCP,
      --  0xE0
      CPX, SBC, NOP, ISC, CPX, SBC, INC, ISC,
      INX, SBC, NOP, SBC, CPX, SBC, INC, ISC,
      --  0xF0
      BEQ, SBC, JAM, ISC, NOP, SBC, INC, ISC,
      SED, SBC, NOP, ISC, NOP, SBC, INC, ISC);

   type Mode_Table is array (Byte) of Mode;
   type Cycle_Table is array (Byte) of Natural;

   Modes  : Mode_Table;
   Cycles_Base : Cycle_Table;

   function Kind (M : Mnemonic) return Access_Kind is
   begin
      case M is
         when LDA | LDX | LDY | LAX | ORA | AND_Op | EOR | ADC | SBC | CMP
            | CPX | CPY | BIT_Op | NOP | ANC | ALR | ARR | ANE | LXA | SBX
            | LAS =>
            return K_Read;
         when STA | STX | STY | SAX | SHA | SHX | SHY | TAS =>
            return K_Write;
         when ASL | LSR | ROL | ROR | INC | DEC | SLO | RLA | SRE | RRA
            | DCP | ISC =>
            return K_RMW;
         when others =>
            return K_Other;
      end case;
   end Kind;

   procedure Build_Tables is
      Row, Col : Natural;
      M : Mode;
   begin
      for Op in Byte loop
         Row := Natural (Op / 16);
         Col := Natural (Op mod 16);
         if Row mod 2 = 0 then
            case Col is
               when 0 =>
                  M := (if Row >= 8 then Imm
                        elsif Row = 2 then Abso
                        else Imp);
               when 1 | 3 => M := IndX;
               when 2 => M := (if Row >= 8 then Imm else Imp);
               when 4 .. 7 => M := ZP;
               when 8 => M := Imp;
               when 9 => M := Imm;
               when 10 => M := (if Row < 8 then Acc else Imp);
               when 11 => M := Imm;
               when others =>
                  M := (if Op = 16#6C# then Ind else Abso);
            end case;
         else
            case Col is
               when 0 => M := Rel;
               when 1 | 3 => M := IndY;
               when 2 => M := Imp;
               when 4 .. 7 =>
                  M := (if Op in 16#96# | 16#97# | 16#B6# | 16#B7#
                        then ZPY else ZPX);
               when 8 | 10 => M := Imp;
               when 9 | 11 => M := AbsY;
               when others =>
                  M := (if Op in 16#9E# | 16#9F# | 16#BE# | 16#BF#
                        then AbsY else AbsX);
            end case;
         end if;
         Modes (Op) := M;

         declare
            K : constant Access_Kind := Kind (Mnem (Op));
            C : Natural;
         begin
            case M is
               when Imp | Acc | Imm => C := 2;
               when ZP =>
                  C := (if K = K_RMW then 5 else 3);
               when ZPX | ZPY =>
                  C := (if K = K_RMW then 6 else 4);
               when Abso =>
                  C := (if K = K_RMW then 6 else 4);
               when AbsX | AbsY =>
                  C := (case K is when K_RMW => 7, when K_Write => 5,
                                  when others => 4);
               when IndX =>
                  C := (if K = K_RMW then 8 else 6);
               when IndY =>
                  C := (case K is when K_RMW => 8, when K_Write => 6,
                                  when others => 5);
               when Ind => C := 5;
               when Rel => C := 2;
            end case;
            Cycles_Base (Op) := C;
         end;
      end loop;

      --  Special cases
      Cycles_Base (16#00#) := 7;  --  BRK
      Cycles_Base (16#20#) := 6;  --  JSR
      Cycles_Base (16#40#) := 6;  --  RTI
      Cycles_Base (16#60#) := 6;  --  RTS
      Cycles_Base (16#08#) := 3;  --  PHP
      Cycles_Base (16#48#) := 3;  --  PHA
      Cycles_Base (16#28#) := 4;  --  PLP
      Cycles_Base (16#68#) := 4;  --  PLA
      Cycles_Base (16#4C#) := 3;  --  JMP abs
   end Build_Tables;

   ---------------------------------------------------------------------
   --  Helpers
   ---------------------------------------------------------------------

   procedure Set_NZ (V : Byte) is
   begin
      Flag_N := (V and 16#80#) /= 0;
      Flag_Z := V = 0;
   end Set_NZ;
   pragma Inline (Set_NZ);

   function Get_P (B_Flag : Boolean := True) return Byte is
      P : Byte := 16#20#;
   begin
      if Flag_N then P := P or 16#80#; end if;
      if Flag_V then P := P or 16#40#; end if;
      if B_Flag then P := P or 16#10#; end if;
      if Flag_D then P := P or 16#08#; end if;
      if Flag_I then P := P or 16#04#; end if;
      if Flag_Z then P := P or 16#02#; end if;
      if Flag_C then P := P or 16#01#; end if;
      return P;
   end Get_P;

   procedure Set_P (Value : Byte) is
   begin
      Flag_N := (Value and 16#80#) /= 0;
      Flag_V := (Value and 16#40#) /= 0;
      Flag_D := (Value and 16#08#) /= 0;
      Flag_I := (Value and 16#04#) /= 0;
      Flag_Z := (Value and 16#02#) /= 0;
      Flag_C := (Value and 16#01#) /= 0;
   end Set_P;

   procedure Push (Value : Byte) is
   begin
      Write (16#0100# or Word (SP), Value);
      SP := SP - 1;
   end Push;

   function Pull return Byte is
   begin
      SP := SP + 1;
      return Read (16#0100# or Word (SP));
   end Pull;

   function Fetch return Byte is
      V : constant Byte := Read (PC);
   begin
      PC := PC + 1;
      return V;
   end Fetch;
   pragma Inline (Fetch);

   function Fetch_Word return Word is
      L : constant Byte := Fetch;
      H : constant Byte := Fetch;
   begin
      return Make_Word (L, H);
   end Fetch_Word;

   procedure Do_RTS is
      L : constant Byte := Pull;
      H : constant Byte := Pull;
   begin
      PC := Make_Word (L, H) + 1;
   end Do_RTS;

   procedure Interrupt (Vector : Word; Brk : Boolean) is
   begin
      Push (Hi (PC));
      Push (Lo (PC));
      Push (Get_P (B_Flag => Brk));
      Flag_I := True;
      PC := Make_Word (Read (Vector), Read (Vector + 1));
   end Interrupt;

   function Base_Cycles (Op : Byte) return Natural is (Cycles_Base (Op));

   procedure Reset is
   begin
      A := 0; X := 0; Y := 0;
      SP := 16#FD#;
      Flag_I := True;
      Flag_D := False;
      Jammed := False;
      NMI_Pending := False;
      Poll_I := True;
      PC := Make_Word (Read (16#FFFC#), Read (16#FFFD#));
   end Reset;

   ---------------------------------------------------------------------
   --  ALU
   ---------------------------------------------------------------------

   procedure Op_ADC (M : Byte) is
      AI : constant Integer := Integer (A);
      MI : constant Integer := Integer (M);
      CI : constant Integer := (if Flag_C then 1 else 0);
   begin
      if Flag_D then
         declare
            Tmp : Integer := (AI mod 16) + (MI mod 16) + CI;
         begin
            if Tmp > 9 then
               Tmp := Tmp + 6;
            end if;
            if Tmp <= 16#0F# then
               Tmp := (Tmp mod 16) + (AI - AI mod 16) + (MI - MI mod 16);
            else
               Tmp := (Tmp mod 16) + (AI - AI mod 16) + (MI - MI mod 16)
                 + 16#10#;
            end if;
            Flag_Z := ((AI + MI + CI) mod 256) = 0;
            Flag_N := (Tmp / 16#80#) mod 2 = 1;
            Flag_V := ((AI / 128) mod 2 /= (Tmp / 128) mod 2)
              and then ((AI / 128) = (MI / 128));
            if (Tmp mod 16#200#) - (Tmp mod 16#10#) > 16#90# then
               Tmp := Tmp + 16#60#;
            end if;
            Flag_C := (Tmp mod 16#1000#) - (Tmp mod 16#10#) > 16#F0#;
            A := Byte (Tmp mod 256);
         end;
      else
         declare
            Sum : constant Integer := AI + MI + CI;
            R   : constant Byte := Byte (Sum mod 256);
         begin
            Flag_C := Sum > 255;
            Flag_V := ((A xor R) and (M xor R) and 16#80#) /= 0;
            A := R;
            Set_NZ (A);
         end;
      end if;
   end Op_ADC;

   procedure Op_SBC (M : Byte) is
      AI : constant Integer := Integer (A);
      MI : constant Integer := Integer (M);
      BI : constant Integer := (if Flag_C then 0 else 1);
      Diff : constant Integer := AI - MI - BI;
      R : constant Byte := Byte (Diff mod 256);
   begin
      Flag_V := ((A xor M) and (A xor R) and 16#80#) /= 0;
      Flag_C := Diff >= 0;
      Set_NZ (R);
      if Flag_D then
         declare
            Lo_N : Integer := (AI mod 16) - (MI mod 16) - BI;
            Hi_N : Integer := (AI / 16) - (MI / 16);
         begin
            if Lo_N < 0 then
               Lo_N := Lo_N - 6;
               Hi_N := Hi_N - 1;
            end if;
            if Hi_N < 0 then
               Hi_N := Hi_N - 6;
            end if;
            A := Byte (((Hi_N mod 16) * 16 + (Lo_N mod 16)) mod 256);
         end;
      else
         A := R;
      end if;
   end Op_SBC;

   procedure Compare (Reg, M : Byte) is
   begin
      Flag_C := Reg >= M;
      Set_NZ (Reg - M);
   end Compare;

   function Op_ASL (V : Byte) return Byte is
   begin
      Flag_C := (V and 16#80#) /= 0;
      return R : constant Byte := Shift_Left (V, 1) do
         Set_NZ (R);
      end return;
   end Op_ASL;

   function Op_LSR (V : Byte) return Byte is
   begin
      Flag_C := (V and 1) /= 0;
      return R : constant Byte := Shift_Right (V, 1) do
         Set_NZ (R);
      end return;
   end Op_LSR;

   function Op_ROL (V : Byte) return Byte is
      R : constant Byte := Shift_Left (V, 1) or (if Flag_C then 1 else 0);
   begin
      Flag_C := (V and 16#80#) /= 0;
      Set_NZ (R);
      return R;
   end Op_ROL;

   function Op_ROR (V : Byte) return Byte is
      R : constant Byte :=
        Shift_Right (V, 1) or (if Flag_C then 16#80# else 0);
   begin
      Flag_C := (V and 1) /= 0;
      Set_NZ (R);
      return R;
   end Op_ROR;

   ---------------------------------------------------------------------
   --  Step
   ---------------------------------------------------------------------

   procedure Step (Cycles : out Natural) is
      Op    : Byte;
      Old_I : constant Boolean := Flag_I;
      M     : Mode;
      EA    : Word := 0;
      Cross : Boolean := False;
      Extra : Natural := 0;
      V     : Byte;
   begin
      if NMI_Pending then
         NMI_Pending := False;
         Jammed := False;
         Interrupt (16#FFFA#, Brk => False);
         Poll_I := True;
         Cycles := 7;
         return;
      elsif IRQ_Line and then not Poll_I then
         Interrupt (16#FFFE#, Brk => False);
         Poll_I := True;
         Cycles := 7;
         return;
      end if;

      if Jammed then
         Cycles := 2;
         return;
      end if;

      Op := Fetch;
      M := Modes (Op);
      Current_Cycles := Cycles_Base (Op);

      --  Effective address computation
      case M is
         when Imp | Acc | Rel => null;
         when Imm =>
            EA := PC;
            PC := PC + 1;
         when ZP =>
            EA := Word (Fetch);
         when ZPX =>
            EA := Word (Fetch + X);
         when ZPY =>
            EA := Word (Fetch + Y);
         when Abso =>
            EA := Fetch_Word;
         when AbsX =>
            declare
               Base : constant Word := Fetch_Word;
            begin
               EA := Base + Word (X);
               Cross := (Base and 16#FF00#) /= (EA and 16#FF00#);
            end;
         when AbsY =>
            declare
               Base : constant Word := Fetch_Word;
            begin
               EA := Base + Word (Y);
               Cross := (Base and 16#FF00#) /= (EA and 16#FF00#);
            end;
         when IndX =>
            declare
               Z : constant Byte := Fetch + X;
            begin
               EA := Make_Word (Read (Word (Z)), Read (Word (Z + 1)));
            end;
         when IndY =>
            declare
               Z    : constant Byte := Fetch;
               Base : constant Word :=
                 Make_Word (Read (Word (Z)), Read (Word (Z + 1)));
            begin
               EA := Base + Word (Y);
               Cross := (Base and 16#FF00#) /= (EA and 16#FF00#);
            end;
         when Ind =>
            declare
               Ptr : constant Word := Fetch_Word;
               Ptr2 : constant Word :=
                 (Ptr and 16#FF00#) or Word (Lo (Ptr) + 1);
            begin
               EA := Make_Word (Read (Ptr), Read (Ptr2));
            end;
      end case;

      case Mnem (Op) is
         --  Loads / stores
         when LDA =>
            A := Read (EA); Set_NZ (A);
            if Cross then Extra := 1; end if;
         when LDX =>
            X := Read (EA); Set_NZ (X);
            if Cross then Extra := 1; end if;
         when LDY =>
            Y := Read (EA); Set_NZ (Y);
            if Cross then Extra := 1; end if;
         when STA => Write (EA, A);
         when STX => Write (EA, X);
         when STY => Write (EA, Y);

         --  Transfers
         when TAX => X := A; Set_NZ (X);
         when TAY => Y := A; Set_NZ (Y);
         when TXA => A := X; Set_NZ (A);
         when TYA => A := Y; Set_NZ (A);
         when TSX => X := SP; Set_NZ (X);
         when TXS => SP := X;

         --  Stack
         when PHA => Push (A);
         when PHP => Push (Get_P (B_Flag => True));
         when PLA => A := Pull; Set_NZ (A);
         when PLP => Set_P (Pull);

         --  Logic
         when AND_Op =>
            A := A and Read (EA); Set_NZ (A);
            if Cross then Extra := 1; end if;
         when ORA =>
            A := A or Read (EA); Set_NZ (A);
            if Cross then Extra := 1; end if;
         when EOR =>
            A := A xor Read (EA); Set_NZ (A);
            if Cross then Extra := 1; end if;
         when BIT_Op =>
            V := Read (EA);
            Flag_Z := (A and V) = 0;
            Flag_N := (V and 16#80#) /= 0;
            Flag_V := (V and 16#40#) /= 0;

         --  Arithmetic
         when ADC =>
            Op_ADC (Read (EA));
            if Cross then Extra := 1; end if;
         when SBC =>
            Op_SBC (Read (EA));
            if Cross then Extra := 1; end if;
         when CMP =>
            Compare (A, Read (EA));
            if Cross then Extra := 1; end if;
         when CPX => Compare (X, Read (EA));
         when CPY => Compare (Y, Read (EA));

         --  Increments
         when INC =>
            V := Read (EA); Write (EA, V); V := V + 1;
            Write (EA, V); Set_NZ (V);
         when DEC =>
            V := Read (EA); Write (EA, V); V := V - 1;
            Write (EA, V); Set_NZ (V);
         when INX => X := X + 1; Set_NZ (X);
         when INY => Y := Y + 1; Set_NZ (Y);
         when DEX => X := X - 1; Set_NZ (X);
         when DEY => Y := Y - 1; Set_NZ (Y);

         --  Shifts
         when ASL | LSR | ROL | ROR =>
            if M = Acc then
               A := (case Mnem (Op) is
                       when ASL => Op_ASL (A),
                       when LSR => Op_LSR (A),
                       when ROL => Op_ROL (A),
                       when others => Op_ROR (A));
            else
               V := Read (EA);
               Write (EA, V);   --  dummy write (RMW behaviour)
               V := (case Mnem (Op) is
                       when ASL => Op_ASL (V),
                       when LSR => Op_LSR (V),
                       when ROL => Op_ROL (V),
                       when others => Op_ROR (V));
               Write (EA, V);
            end if;

         --  Jumps
         when JMP => PC := EA;
         when JSR =>
            declare
               Ret : constant Word := PC - 1;
            begin
               Push (Hi (Ret));
               Push (Lo (Ret));
               PC := EA;
            end;
         when RTS => Do_RTS;
         when RTI =>
            Set_P (Pull);
            declare
               L : constant Byte := Pull;
               H : constant Byte := Pull;
            begin
               PC := Make_Word (L, H);
            end;
         when BRK =>
            PC := PC + 1;
            Interrupt (16#FFFE#, Brk => True);

         --  Branches
         when BCC | BCS | BEQ | BNE | BMI | BPL | BVC | BVS =>
            declare
               Off   : constant Byte := Fetch;
               Taken : Boolean;
            begin
               case Mnem (Op) is
                  when BCC => Taken := not Flag_C;
                  when BCS => Taken := Flag_C;
                  when BEQ => Taken := Flag_Z;
                  when BNE => Taken := not Flag_Z;
                  when BMI => Taken := Flag_N;
                  when BPL => Taken := not Flag_N;
                  when BVC => Taken := not Flag_V;
                  when others => Taken := Flag_V;
               end case;
               if Taken then
                  declare
                     Target : Word;
                  begin
                     if Off >= 16#80# then
                        Target := PC - Word (256 - Natural (Off));
                     else
                        Target := PC + Word (Off);
                     end if;
                     Extra := 1;
                     if (Target and 16#FF00#) /= (PC and 16#FF00#) then
                        Extra := 2;
                     end if;
                     PC := Target;
                  end;
               end if;
            end;

         --  Flags
         when CLC => Flag_C := False;
         when SEC => Flag_C := True;
         when CLD => Flag_D := False;
         when SED => Flag_D := True;
         when CLI => Flag_I := False;
         when SEI => Flag_I := True;
         when CLV => Flag_V := False;

         when NOP =>
            if M /= Imp then
               V := Read (EA);
               if Cross then Extra := 1; end if;
            end if;

         --  Undocumented opcodes
         when SLO =>
            V := Read (EA); Write (EA, V);
            V := Op_ASL (V); Write (EA, V);
            A := A or V; Set_NZ (A);
         when RLA =>
            V := Read (EA); Write (EA, V);
            V := Op_ROL (V); Write (EA, V);
            A := A and V; Set_NZ (A);
         when SRE =>
            V := Read (EA); Write (EA, V);
            V := Op_LSR (V); Write (EA, V);
            A := A xor V; Set_NZ (A);
         when RRA =>
            V := Read (EA); Write (EA, V);
            V := Op_ROR (V); Write (EA, V);
            Op_ADC (V);
         when SAX =>
            Write (EA, A and X);
         when LAX =>
            A := Read (EA); X := A; Set_NZ (A);
            if Cross then Extra := 1; end if;
         when DCP =>
            V := Read (EA); Write (EA, V);
            V := V - 1; Write (EA, V);
            Compare (A, V);
         when ISC =>
            V := Read (EA); Write (EA, V);
            V := V + 1; Write (EA, V);
            Op_SBC (V);
         when ANC =>
            A := A and Read (EA); Set_NZ (A);
            Flag_C := Flag_N;
         when ALR =>
            A := A and Read (EA);
            A := Op_LSR (A);
         when ARR =>
            A := A and Read (EA);
            A := Shift_Right (A, 1) or (if Flag_C then 16#80# else 0);
            Set_NZ (A);
            Flag_C := (A and 16#40#) /= 0;
            Flag_V := ((A and 16#40#) /= 0) xor ((A and 16#20#) /= 0);
         when ANE =>
            A := (A or 16#EE#) and X and Read (EA); Set_NZ (A);
         when LXA =>
            A := (A or 16#EE#) and Read (EA); X := A; Set_NZ (A);
         when SBX =>
            declare
               T : constant Byte := A and X;
               Mv : constant Byte := Read (EA);
            begin
               Flag_C := T >= Mv;
               X := T - Mv;
               Set_NZ (X);
            end;
         when SHA =>
            Write (EA, A and X and (Hi (EA) + 1));
         when SHX =>
            Write (EA, X and (Hi (EA) + 1));
         when SHY =>
            Write (EA, Y and (Hi (EA) + 1));
         when TAS =>
            SP := A and X;
            Write (EA, SP and (Hi (EA) + 1));
         when LAS =>
            V := Read (EA) and SP;
            A := V; X := V; SP := V; Set_NZ (V);
            if Cross then Extra := 1; end if;
         when JAM =>
            Jammed := True;
            PC := PC - 1;
      end case;

      Cycles := Cycles_Base (Op) + Extra;
      Poll_I := (if Op in 16#58# | 16#78# | 16#28# then Old_I else Flag_I);
   end Step;

begin
   Build_Tables;
end MOS6502;
