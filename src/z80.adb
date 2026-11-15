-- ***************************************************************************
--                      AdaC64 - Z80
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

package body Z80 is
   pragma Suppress (All_Checks);

   FS : constant Byte := 16#80#;
   FZ : constant Byte := 16#40#;
   FY : constant Byte := 16#20#;
   FH : constant Byte := 16#10#;
   FX : constant Byte := 16#08#;
   FP : constant Byte := 16#04#;
   FN : constant Byte := 16#02#;
   FC : constant Byte := 16#01#;

   type Index_Mode is (None, Use_IX, Use_IY);
   Mode : Index_Mode := None;
   Disp_Fetched : Boolean := False;
   Disp_Addr : Word := 0;
   EI_Delay : Boolean := False;
   Cycles : Natural := 0;

   Parity : array (Byte) of Boolean;

   ---------------------------------------------------------------------
   --  Basic access
   ---------------------------------------------------------------------

   function Fetch return Byte is
      V : constant Byte := Read (PC);
   begin
      PC := PC + 1;
      return V;
   end Fetch;

   function Fetch16 return Word is
      L : constant Byte := Fetch;
      H : constant Byte := Fetch;
   begin
      return Make_Word (L, H);
   end Fetch16;

   function Read16 (A : Word) return Word is
     (Make_Word (Read (A), Read (A + 1)));

   procedure Write16 (A : Word; V : Word) is
   begin
      Write (A, Lo (V));
      Write (A + 1, Hi (V));
   end Write16;

   procedure Push (V : Word) is
   begin
      SP := SP - 1;
      Write (SP, Hi (V));
      SP := SP - 1;
      Write (SP, Lo (V));
   end Push;

   function Pop return Word is
      L : constant Byte := Read (SP);
      H : Byte;
   begin
      SP := SP + 1;
      H := Read (SP);
      SP := SP + 1;
      return Make_Word (L, H);
   end Pop;

   procedure Inc_R is
   begin
      R := (R and 16#80#) or ((R + 1) and 16#7F#);
   end Inc_R;

   ---------------------------------------------------------------------
   --  Register pairs
   ---------------------------------------------------------------------

   function BC return Word is (Make_Word (Main.C, Main.B));
   function DE return Word is (Make_Word (Main.E, Main.D));
   function HL_Real return Word is (Make_Word (Main.L, Main.H));
   procedure Set_BC (V : Word) is
   begin
      Main.B := Hi (V); Main.C := Lo (V);
   end Set_BC;
   procedure Set_DE (V : Word) is
   begin
      Main.D := Hi (V); Main.E := Lo (V);
   end Set_DE;
   procedure Set_HL_Real (V : Word) is
   begin
      Main.H := Hi (V); Main.L := Lo (V);
   end Set_HL_Real;

   --  HL, or IX/IY under a prefix
   function HL return Word is
     (case Mode is
        when None => HL_Real, when Use_IX => IX, when Use_IY => IY);

   procedure Set_HL (V : Word) is
   begin
      case Mode is
         when None => Set_HL_Real (V);
         when Use_IX => IX := V;
         when Use_IY => IY := V;
      end case;
   end Set_HL;

   function RP (P : Natural) return Word is
     (case P is
        when 0 => BC, when 1 => DE, when 2 => HL, when others => SP);

   procedure Set_RP (P : Natural; V : Word) is
   begin
      case P is
         when 0 => Set_BC (V);
         when 1 => Set_DE (V);
         when 2 => Set_HL (V);
         when others => SP := V;
      end case;
   end Set_RP;

   function RP2 (P : Natural) return Word is
     (case P is
        when 0 => BC, when 1 => DE, when 2 => HL,
        when others => Make_Word (Main.F, Main.A));

   procedure Set_RP2 (P : Natural; V : Word) is
   begin
      case P is
         when 0 => Set_BC (V);
         when 1 => Set_DE (V);
         when 2 => Set_HL (V);
         when others => Main.A := Hi (V); Main.F := Lo (V);
      end case;
   end Set_RP2;

   --  Address of (HL) or (IX+d) / (IY+d); d is fetched once
   function Mem_Addr return Word is
   begin
      if Mode = None then
         return HL_Real;
      end if;
      if not Disp_Fetched then
         declare
            D : constant Byte := Fetch;
            Base : constant Word := (if Mode = Use_IX then IX else IY);
         begin
            Disp_Addr := (if D >= 16#80# then Base - Word (256 - Natural (D))
                          else Base + Word (D));
            Disp_Fetched := True;
            Cycles := Cycles + 8;
         end;
      end if;
      return Disp_Addr;
   end Mem_Addr;

   --  8-bit registers: 0 B, 1 C, 2 D, 3 E, 4 H, 5 L, 6 (HL), 7 A.
   --  Index = True allows IXH/IXL substitution for H/L.
   function Get8 (Idx : Natural; Index : Boolean := True) return Byte is
   begin
      case Idx is
         when 0 => return Main.B;
         when 1 => return Main.C;
         when 2 => return Main.D;
         when 3 => return Main.E;
         when 4 =>
            if Index and then Mode = Use_IX then return Hi (IX);
            elsif Index and then Mode = Use_IY then return Hi (IY);
            else return Main.H;
            end if;
         when 5 =>
            if Index and then Mode = Use_IX then return Lo (IX);
            elsif Index and then Mode = Use_IY then return Lo (IY);
            else return Main.L;
            end if;
         when 6 =>
            Cycles := Cycles + 3;
            return Read (Mem_Addr);
         when others => return Main.A;
      end case;
   end Get8;

   procedure Set8 (Idx : Natural; V : Byte; Index : Boolean := True) is
   begin
      case Idx is
         when 0 => Main.B := V;
         when 1 => Main.C := V;
         when 2 => Main.D := V;
         when 3 => Main.E := V;
         when 4 =>
            if Index and then Mode = Use_IX then
               IX := Make_Word (Lo (IX), V);
            elsif Index and then Mode = Use_IY then
               IY := Make_Word (Lo (IY), V);
            else
               Main.H := V;
            end if;
         when 5 =>
            if Index and then Mode = Use_IX then
               IX := Make_Word (V, Hi (IX));
            elsif Index and then Mode = Use_IY then
               IY := Make_Word (V, Hi (IY));
            else
               Main.L := V;
            end if;
         when 6 =>
            Cycles := Cycles + 3;
            Write (Mem_Addr, V);
         when others => Main.A := V;
      end case;
   end Set8;

   ---------------------------------------------------------------------
   --  Flags and ALU
   ---------------------------------------------------------------------

   function SZXY (V : Byte) return Byte is
     ((V and (FS or FY or FX)) or (if V = 0 then FZ else 0));

   function SZPXY (V : Byte) return Byte is
     (SZXY (V) or (if Parity (V) then FP else 0));

   function Carry return Byte is (Main.F and FC);

   procedure ALU (Op : Natural; V : Byte) is
      A  : constant Byte := Main.A;
      AI : constant Integer := Integer (A);
      VI : constant Integer := Integer (V);
      R  : Integer;
      Res : Byte;
      CI : constant Integer := Integer (Carry);
   begin
      case Op is
         when 0 | 1 =>   --  ADD / ADC
            R := AI + VI + (if Op = 1 then CI else 0);
            Res := Byte (R mod 256);
            Main.F := SZXY (Res) or
              (if ((AI mod 16) + (VI mod 16) + (if Op = 1 then CI else 0))
                    > 15 then FH else 0) or
              (if ((A xor not V) and (A xor Res) and 16#80#) /= 0
               then FP else 0) or
              (if R > 255 then FC else 0);
            Main.A := Res;
         when 2 | 3 | 7 =>   --  SUB / SBC / CP
            R := AI - VI - (if Op = 3 then CI else 0);
            Res := Byte (R mod 256);
            Main.F := (SZXY (Res) and not (FX or FY)) or
              ((if Op = 7 then V else Res) and (FX or FY)) or FN or
              (if ((AI mod 16) - (VI mod 16) - (if Op = 3 then CI else 0))
                    < 0 then FH else 0) or
              (if ((A xor V) and (A xor Res) and 16#80#) /= 0
               then FP else 0) or
              (if R < 0 then FC else 0);
            if Op /= 7 then
               Main.A := Res;
            end if;
         when 4 =>       --  AND
            Main.A := A and V;
            Main.F := SZPXY (Main.A) or FH;
         when 5 =>       --  XOR
            Main.A := A xor V;
            Main.F := SZPXY (Main.A);
         when others =>  --  OR
            Main.A := A or V;
            Main.F := SZPXY (Main.A);
      end case;
   end ALU;

   function Inc8 (V : Byte) return Byte is
      R : constant Byte := V + 1;
   begin
      Main.F := Carry or SZXY (R) or
        (if (V and 16#0F#) = 16#0F# then FH else 0) or
        (if V = 16#7F# then FP else 0);
      return R;
   end Inc8;

   function Dec8 (V : Byte) return Byte is
      R : constant Byte := V - 1;
   begin
      Main.F := Carry or SZXY (R) or FN or
        (if (V and 16#0F#) = 0 then FH else 0) or
        (if V = 16#80# then FP else 0);
      return R;
   end Dec8;

   function Add16 (A, B : Word) return Word is
      R : constant Natural := Natural (A) + Natural (B);
      Res : constant Word := Word (R mod 65536);
   begin
      Main.F := (Main.F and (FS or FZ or FP)) or
        (Hi (Res) and (FX or FY)) or
        (if (Natural (A) mod 4096) + (Natural (B) mod 4096) > 4095
         then FH else 0) or
        (if R > 65535 then FC else 0);
      return Res;
   end Add16;

   function Adc16 (A, B : Word) return Word is
      CI : constant Natural := Natural (Carry);
      R : constant Natural := Natural (A) + Natural (B) + CI;
      Res : constant Word := Word (R mod 65536);
   begin
      Main.F := (Hi (Res) and (FS or FX or FY)) or
        (if Res = 0 then FZ else 0) or
        (if (Natural (A) mod 4096) + (Natural (B) mod 4096) + CI > 4095
         then FH else 0) or
        (if ((A xor not B) and (A xor Res) and 16#8000#) /= 0
         then FP else 0) or
        (if R > 65535 then FC else 0);
      return Res;
   end Adc16;

   function Sbc16 (A, B : Word) return Word is
      CI : constant Integer := Integer (Carry);
      R : constant Integer := Integer (A) - Integer (B) - CI;
      Res : constant Word := Word (R mod 65536);
   begin
      Main.F := (Hi (Res) and (FS or FX or FY)) or FN or
        (if Res = 0 then FZ else 0) or
        (if Integer (A) mod 4096 - Integer (B) mod 4096 - CI < 0
         then FH else 0) or
        (if ((A xor B) and (A xor Res) and 16#8000#) /= 0
         then FP else 0) or
        (if R < 0 then FC else 0);
      return Res;
   end Sbc16;

   function Rotate (Op : Natural; V : Byte) return Byte is
      R : Byte;
      C : Byte;
   begin
      case Op is
         when 0 => C := Shift_Right (V, 7); R := Shift_Left (V, 1) or C;
         when 1 => C := V and 1; R := Shift_Right (V, 1) or Shift_Left (C, 7);
         when 2 => C := Shift_Right (V, 7); R := Shift_Left (V, 1) or Carry;
         when 3 => C := V and 1;
            R := Shift_Right (V, 1) or Shift_Left (Carry, 7);
         when 4 => C := Shift_Right (V, 7); R := Shift_Left (V, 1);
         when 5 => C := V and 1; R := Shift_Right (V, 1) or (V and 16#80#);
         when 6 => C := Shift_Right (V, 7); R := Shift_Left (V, 1) or 1;
         when others => C := V and 1; R := Shift_Right (V, 1);
      end case;
      Main.F := SZPXY (R) or C;
      return R;
   end Rotate;

   function Condition (Y : Natural) return Boolean is
     (case Y is
        when 0 => (Main.F and FZ) = 0,
        when 1 => (Main.F and FZ) /= 0,
        when 2 => (Main.F and FC) = 0,
        when 3 => (Main.F and FC) /= 0,
        when 4 => (Main.F and FP) = 0,
        when 5 => (Main.F and FP) /= 0,
        when 6 => (Main.F and FS) = 0,
        when others => (Main.F and FS) /= 0);

   procedure Jump_Rel is
      D : constant Byte := Fetch;
   begin
      PC := (if D >= 16#80# then PC - Word (256 - Natural (D))
             else PC + Word (D));
   end Jump_Rel;

   procedure DAA is
      A : constant Byte := Main.A;
      Corr : Byte := 0;
      C : Byte := Carry;
      R : Byte;
   begin
      if (Main.F and FH) /= 0 or else (A and 16#0F#) > 9 then
         Corr := 16#06#;
      end if;
      if C /= 0 or else A > 16#99# then
         Corr := Corr or 16#60#;
         C := FC;
      end if;
      if (Main.F and FN) /= 0 then
         R := A - Corr;
      else
         R := A + Corr;
      end if;
      Main.F := SZPXY (R) or C or (Main.F and FN) or
        ((A xor R) and FH);
      Main.A := R;
   end DAA;

   ---------------------------------------------------------------------
   --  CB prefix
   ---------------------------------------------------------------------

   procedure Exec_CB (Op : Byte; Indexed : Boolean) is
      X : constant Natural := Natural (Shift_Right (Op, 6));
      Y : constant Natural := Natural (Shift_Right (Op, 3) and 7);
      Z : constant Natural := Natural (Op and 7);
      Src : constant Natural := (if Indexed then 6 else Z);
      V : constant Byte := Get8 (Src, Index => False);
      R : Byte := V;
   begin
      Cycles := Cycles + 8;
      case X is
         when 0 => R := Rotate (Y, V);
         when 1 =>
            declare
               Set : constant Boolean := (Shift_Right (V, Y) and 1) /= 0;
            begin
               Main.F := Carry or FH or
                 (if Set then 0 else FZ or FP) or
                 (if Set and then Y = 7 then FS else 0) or
                 ((if Indexed then Hi (Disp_Addr) else V) and (FX or FY));
            end;
            return;
         when 2 => R := V and not Shift_Left (1, Y);
         when others => R := V or Shift_Left (1, Y);
      end case;
      Set8 (Src, R, Index => False);
      if Indexed and then Z /= 6 then
         Set8 (Z, R, Index => False);    --  undocumented register copy
      end if;
   end Exec_CB;

   ---------------------------------------------------------------------
   --  ED prefix
   ---------------------------------------------------------------------

   procedure Block (Y, Z : Natural) is
      Inc : constant Boolean := Y mod 2 = 0;          --  y=4,6: increment
      Rep : constant Boolean := Y >= 6;
      Step_V : constant Word := (if Inc then 1 else 16#FFFF#);
   begin
      Cycles := Cycles + 16;
      case Z is
         when 0 =>   --  LDI / LDD / LDIR / LDDR
            declare
               V : constant Byte := Read (HL_Real);
               N : constant Byte := V + Main.A;
            begin
               Write (DE, V);
               Set_HL_Real (HL_Real + Step_V);
               Set_DE (DE + Step_V);
               Set_BC (BC - 1);
               Main.F := (Main.F and (FS or FZ or FC)) or
                 (if BC /= 0 then FP else 0) or
                 (N and FX) or (if (N and 2) /= 0 then FY else 0);
               if Rep and then BC /= 0 then
                  PC := PC - 2;
                  Cycles := Cycles + 5;
               end if;
            end;
         when 1 =>   --  CPI / CPD / CPIR / CPDR
            declare
               V : constant Byte := Read (HL_Real);
               R : constant Byte := Main.A - V;
               H : constant Boolean := (Main.A and 15) < (V and 15);
            begin
               Set_HL_Real (HL_Real + Step_V);
               Set_BC (BC - 1);
               Main.F := Carry or FN or (R and FS) or
                 (if R = 0 then FZ else 0) or (if H then FH else 0) or
                 (if BC /= 0 then FP else 0);
               if Rep and then BC /= 0 and then R /= 0 then
                  PC := PC - 2;
                  Cycles := Cycles + 5;
               end if;
            end;
         when 2 =>   --  INI / IND / INIR / INDR
            declare
               V : constant Byte := In_Port (BC);
            begin
               Write (HL_Real, V);
               Set_HL_Real (HL_Real + Step_V);
               Main.B := Main.B - 1;
               Main.F := SZXY (Main.B) or FN;
               if Rep and then Main.B /= 0 then
                  PC := PC - 2;
                  Cycles := Cycles + 5;
               end if;
            end;
         when others =>   --  OUTI / OUTD / OTIR / OTDR
            declare
               V : constant Byte := Read (HL_Real);
            begin
               Main.B := Main.B - 1;
               Out_Port (BC, V);
               Set_HL_Real (HL_Real + Step_V);
               Main.F := SZXY (Main.B) or FN;
               if Rep and then Main.B /= 0 then
                  PC := PC - 2;
                  Cycles := Cycles + 5;
               end if;
            end;
      end case;
   end Block;

   procedure Exec_ED (Op : Byte) is
      X : constant Natural := Natural (Shift_Right (Op, 6));
      Y : constant Natural := Natural (Shift_Right (Op, 3) and 7);
      Z : constant Natural := Natural (Op and 7);
      P : constant Natural := Y / 2;
      Q : constant Natural := Y mod 2;
   begin
      Mode := None;
      Cycles := Cycles + 8;
      if X = 1 then
         case Z is
            when 0 =>
               declare
                  V : constant Byte := In_Port (BC);
               begin
                  Main.F := Carry or SZPXY (V);
                  if Y /= 6 then
                     Set8 (Y, V);
                  end if;
                  Cycles := Cycles + 4;
               end;
            when 1 =>
               Out_Port (BC, (if Y = 6 then 0 else Get8 (Y)));
               Cycles := Cycles + 4;
            when 2 =>
               if Q = 0 then
                  Set_HL_Real (Sbc16 (HL_Real, RP (P)));
               else
                  Set_HL_Real (Adc16 (HL_Real, RP (P)));
               end if;
               Cycles := Cycles + 7;
            when 3 =>
               declare
                  A : constant Word := Fetch16;
               begin
                  if Q = 0 then
                     Write16 (A, RP (P));
                  else
                     Set_RP (P, Read16 (A));
                  end if;
                  Cycles := Cycles + 12;
               end;
            when 4 =>
               declare
                  V : constant Byte := Main.A;
               begin
                  Main.A := 0;
                  ALU (2, V);
               end;
            when 5 =>
               PC := Pop;
               IFF1 := IFF2;
               Cycles := Cycles + 6;
            when 6 =>
               IM := (case Y mod 4 is when 2 => 1, when 3 => 2,
                                      when others => 0);
            when others =>
               case Y is
                  when 0 => I := Main.A; Cycles := Cycles + 1;
                  when 1 => R := Main.A; Cycles := Cycles + 1;
                  when 2 =>
                     Main.A := I;
                     Main.F := Carry or SZXY (Main.A) or
                       (if IFF2 then FP else 0);
                     Cycles := Cycles + 1;
                  when 3 =>
                     Main.A := R;
                     Main.F := Carry or SZXY (Main.A) or
                       (if IFF2 then FP else 0);
                     Cycles := Cycles + 1;
                  when 4 =>   --  RRD
                     declare
                        M : constant Byte := Read (HL_Real);
                     begin
                        Write (HL_Real, Shift_Left (Main.A, 4) or
                                 Shift_Right (M, 4));
                        Main.A := (Main.A and 16#F0#) or (M and 15);
                        Main.F := Carry or SZPXY (Main.A);
                        Cycles := Cycles + 10;
                     end;
                  when 5 =>   --  RLD
                     declare
                        M : constant Byte := Read (HL_Real);
                     begin
                        Write (HL_Real, Shift_Left (M, 4) or (Main.A and 15));
                        Main.A := (Main.A and 16#F0#) or Shift_Right (M, 4);
                        Main.F := Carry or SZPXY (Main.A);
                        Cycles := Cycles + 10;
                     end;
                  when others => null;
               end case;
         end case;
      elsif X = 2 and then Z <= 3 and then Y >= 4 then
         Block (Y, Z);
      end if;
   end Exec_ED;

   ---------------------------------------------------------------------
   --  Unprefixed (and DD/FD) instructions
   ---------------------------------------------------------------------

   procedure Exec_Main (Op : Byte) is
      X : constant Natural := Natural (Shift_Right (Op, 6));
      Y : constant Natural := Natural (Shift_Right (Op, 3) and 7);
      Z : constant Natural := Natural (Op and 7);
      P : constant Natural := Y / 2;
      Q : constant Natural := Y mod 2;
   begin
      Cycles := Cycles + 4;
      case X is
         when 0 =>
            case Z is
               when 0 =>
                  case Y is
                     when 0 => null;
                     when 1 =>
                        declare
                           T : constant Reg_File := Main;
                        begin
                           Main.A := Alt.A; Main.F := Alt.F;
                           Alt.A := T.A; Alt.F := T.F;
                        end;
                     when 2 =>
                        Main.B := Main.B - 1;
                        if Main.B /= 0 then
                           Jump_Rel;
                           Cycles := Cycles + 9;
                        else
                           PC := PC + 1;
                           Cycles := Cycles + 4;
                        end if;
                     when 3 =>
                        Jump_Rel;
                        Cycles := Cycles + 8;
                     when others =>
                        if Condition (Y - 4) then
                           Jump_Rel;
                           Cycles := Cycles + 8;
                        else
                           PC := PC + 1;
                           Cycles := Cycles + 3;
                        end if;
                  end case;
               when 1 =>
                  if Q = 0 then
                     Set_RP (P, Fetch16);
                     Cycles := Cycles + 6;
                  else
                     Set_HL (Add16 (HL, RP (P)));
                     Cycles := Cycles + 7;
                  end if;
               when 2 =>
                  Cycles := Cycles + 3;
                  case P is
                     when 0 =>
                        if Q = 0 then Write (BC, Main.A);
                        else Main.A := Read (BC);
                        end if;
                     when 1 =>
                        if Q = 0 then Write (DE, Main.A);
                        else Main.A := Read (DE);
                        end if;
                     when 2 =>
                        declare
                           A : constant Word := Fetch16;
                        begin
                           if Q = 0 then Write16 (A, HL);
                           else Set_HL (Read16 (A));
                           end if;
                           Cycles := Cycles + 9;
                        end;
                     when others =>
                        declare
                           A : constant Word := Fetch16;
                        begin
                           if Q = 0 then Write (A, Main.A);
                           else Main.A := Read (A);
                           end if;
                           Cycles := Cycles + 6;
                        end;
                  end case;
               when 3 =>
                  Set_RP (P, (if Q = 0 then RP (P) + 1 else RP (P) - 1));
                  Cycles := Cycles + 2;
               when 4 =>
                  declare
                     V : constant Byte := Get8 (Y);
                  begin
                     Set8 (Y, Inc8 (V));
                  end;
               when 5 =>
                  declare
                     V : constant Byte := Get8 (Y);
                  begin
                     Set8 (Y, Dec8 (V));
                  end;
               when 6 =>
                  if Y = 6 then
                     declare
                        A : constant Word := Mem_Addr;   --  d before n
                        N : constant Byte := Fetch;
                     begin
                        Write (A, N);
                        Cycles := Cycles + 6;
                     end;
                  else
                     Set8 (Y, Fetch);
                     Cycles := Cycles + 3;
                  end if;
               when others =>
                  case Y is
                     when 0 | 1 | 2 | 3 =>
                        declare
                           F_Save : constant Byte :=
                             Main.F and (FS or FZ or FP);
                        begin
                           Main.A := Rotate (Y, Main.A);
                           Main.F := F_Save or (Main.F and FC) or
                             (Main.A and (FX or FY));
                        end;
                     when 4 => DAA;
                     when 5 =>
                        Main.A := not Main.A;
                        Main.F := (Main.F and (FS or FZ or FP or FC)) or
                          FH or FN or (Main.A and (FX or FY));
                     when 6 =>
                        Main.F := (Main.F and (FS or FZ or FP)) or FC or
                          (Main.A and (FX or FY));
                     when others =>
                        Main.F := ((Main.F and (FS or FZ or FP)) or
                                   (Main.A and (FX or FY)) or
                                   (if (Main.F and FC) /= 0 then FH else FC));
                  end case;
            end case;

         when 1 =>
            if Z = 6 and then Y = 6 then
               Halted := True;
               PC := PC - 1;
            else
               --  With (IX+d), the other operand is the real H/L
               declare
                  Mem : constant Boolean := Y = 6 or else Z = 6;
                  V : constant Byte := Get8 (Z, Index => not Mem);
               begin
                  Set8 (Y, V, Index => not Mem);
               end;
            end if;

         when 2 =>
            ALU (Y, Get8 (Z));

         when others =>
            case Z is
               when 0 =>
                  if Condition (Y) then
                     PC := Pop;
                     Cycles := Cycles + 7;
                  else
                     Cycles := Cycles + 1;
                  end if;
               when 1 =>
                  if Q = 0 then
                     Set_RP2 (P, Pop);
                     Cycles := Cycles + 6;
                  else
                     case P is
                        when 0 =>
                           PC := Pop;
                           Cycles := Cycles + 6;
                        when 1 =>
                           declare
                              T : constant Reg_File := Main;
                           begin
                              Main.B := Alt.B; Main.C := Alt.C;
                              Main.D := Alt.D; Main.E := Alt.E;
                              Main.H := Alt.H; Main.L := Alt.L;
                              Alt.B := T.B; Alt.C := T.C;
                              Alt.D := T.D; Alt.E := T.E;
                              Alt.H := T.H; Alt.L := T.L;
                           end;
                        when 2 => PC := HL;
                        when others =>
                           SP := HL;
                           Cycles := Cycles + 2;
                     end case;
                  end if;
               when 2 =>
                  declare
                     A : constant Word := Fetch16;
                  begin
                     if Condition (Y) then
                        PC := A;
                     end if;
                     Cycles := Cycles + 6;
                  end;
               when 3 =>
                  case Y is
                     when 0 =>
                        PC := Fetch16;
                        Cycles := Cycles + 6;
                     when 1 => null;   --  CB handled by the caller
                     when 2 =>
                        Out_Port (Make_Word (Fetch, Main.A), Main.A);
                        Cycles := Cycles + 7;
                     when 3 =>
                        Main.A := In_Port (Make_Word (Fetch, Main.A));
                        Cycles := Cycles + 7;
                     when 4 =>
                        declare
                           T : constant Word := Read16 (SP);
                        begin
                           Write16 (SP, HL);
                           Set_HL (T);
                           Cycles := Cycles + 15;
                        end;
                     when 5 =>
                        declare
                           T : constant Word := DE;
                        begin
                           Set_DE (HL_Real);
                           Set_HL_Real (T);
                        end;
                     when 6 =>
                        IFF1 := False;
                        IFF2 := False;
                     when others =>
                        IFF1 := True;
                        IFF2 := True;
                        EI_Delay := True;
                  end case;
               when 4 =>
                  declare
                     A : constant Word := Fetch16;
                  begin
                     if Condition (Y) then
                        Push (PC);
                        PC := A;
                        Cycles := Cycles + 13;
                     else
                        Cycles := Cycles + 6;
                     end if;
                  end;
               when 5 =>
                  if Q = 0 then
                     Push (RP2 (P));
                     Cycles := Cycles + 7;
                  elsif P = 0 then
                     declare
                        A : constant Word := Fetch16;
                     begin
                        Push (PC);
                        PC := A;
                        Cycles := Cycles + 13;
                     end;
                  end if;
                  --  DD/ED/FD prefixes are handled by the caller
               when 6 =>
                  ALU (Y, Fetch);
                  Cycles := Cycles + 3;
               when others =>
                  Push (PC);
                  PC := Word (Y * 8);
                  Cycles := Cycles + 7;
            end case;
      end case;
   end Exec_Main;

   ---------------------------------------------------------------------
   --  Step
   ---------------------------------------------------------------------

   procedure Interrupt_Entry (Vector : Word) is
   begin
      if Halted then
         Halted := False;
         PC := PC + 1;
      end if;
      Push (PC);
      PC := Vector;
   end Interrupt_Entry;

   procedure Step (T_States : out Natural) is
      Op : Byte;
   begin
      Cycles := 0;

      if NMI_Pending then
         NMI_Pending := False;
         IFF2 := IFF1;
         IFF1 := False;
         Inc_R;
         Interrupt_Entry (16#0066#);
         T_States := 11;
         return;
      end if;
      if INT_Line and then IFF1 and then not EI_Delay then
         IFF1 := False;
         IFF2 := False;
         Inc_R;
         case IM is
            when 2 =>
               Interrupt_Entry (Read16 (Make_Word (16#FF#, I)));
               T_States := 19;
            when others =>
               Interrupt_Entry (16#0038#);
               T_States := 13;
         end case;
         return;
      end if;
      EI_Delay := False;

      if Halted then
         Inc_R;
         T_States := 4;
         return;
      end if;

      Mode := None;
      Disp_Fetched := False;
      Op := Fetch;
      Inc_R;
      while Op = 16#DD# or else Op = 16#FD# loop
         Mode := (if Op = 16#DD# then Use_IX else Use_IY);
         Cycles := Cycles + 4;
         Op := Fetch;
         Inc_R;
      end loop;

      if Op = 16#CB# then
         if Mode /= None then
            declare
               A : constant Word := Mem_Addr;
               pragma Unreferenced (A);
               Sub : constant Byte := Fetch;
            begin
               Exec_CB (Sub, Indexed => True);
            end;
         else
            Inc_R;
            Exec_CB (Fetch, Indexed => False);
         end if;
      elsif Op = 16#ED# then
         Inc_R;
         Exec_ED (Fetch);
      else
         Exec_Main (Op);
      end if;
      T_States := Natural'Max (Cycles, 4);
   end Step;

   procedure Reset is
   begin
      PC := 0;
      I := 0;
      R := 0;
      IFF1 := False;
      IFF2 := False;
      IM := 0;
      Halted := False;
      SP := 16#FFFF#;
      Main.A := 16#FF#;
      Main.F := 16#FF#;
      NMI_Pending := False;
      EI_Delay := False;
   end Reset;

   procedure Save_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
   begin
      Reg_File'Write (S, Main);
      Reg_File'Write (S, Alt);
      Word'Write (S, IX); Word'Write (S, IY); Word'Write (S, SP);
      Word'Write (S, PC);
      Byte'Write (S, I); Byte'Write (S, R);
      Boolean'Write (S, IFF1); Boolean'Write (S, IFF2);
      Natural'Write (S, IM); Boolean'Write (S, Halted);
      Boolean'Write (S, INT_Line); Boolean'Write (S, NMI_Pending);
   end Save_State;

   procedure Load_State (S : not null access Ada.Streams.Root_Stream_Type'Class)
   is
      M : Natural;
   begin
      Reg_File'Read (S, Main);
      Reg_File'Read (S, Alt);
      Word'Read (S, IX); Word'Read (S, IY); Word'Read (S, SP);
      Word'Read (S, PC);
      Byte'Read (S, I); Byte'Read (S, R);
      Boolean'Read (S, IFF1); Boolean'Read (S, IFF2);
      Natural'Read (S, M);
      IM := M;
      Boolean'Read (S, Halted);
      Boolean'Read (S, INT_Line); Boolean'Read (S, NMI_Pending);
   end Load_State;

begin
   for V in Byte loop
      declare
         N : Natural := 0;
      begin
         for B in 0 .. 7 loop
            if (Shift_Right (V, B) and 1) /= 0 then
               N := N + 1;
            end if;
         end loop;
         Parity (V) := N mod 2 = 0;
      end;
   end loop;
end Z80;
