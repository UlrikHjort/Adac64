with Ada.Containers.Vectors;
with Ada.Containers; use type Ada.Containers.Count_Type;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Ordered_Maps;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Strings;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Directories;
with Ada.Text_IO;
with Ada.Streams.Stream_IO;
with Ada.Exceptions; use Ada.Exceptions;
with Interfaces; use Interfaces;
with Disasm; use Disasm;

package body Asm is

   Asm_Error : exception;

   function To_U (I : Integer) return Unsigned_32 is (Unsigned_32'Mod (I));
   function From_U (U : Unsigned_32) return Integer is
     (if U >= 2**31 then Integer (Long_Long_Integer (U) - 2**32)
      else Integer (U));
   function Interfaces_And (A, B : Integer) return Integer is
     (From_U (To_U (A) and To_U (B)));
   function Interfaces_Or (A, B : Integer) return Integer is
     (From_U (To_U (A) or To_U (B)));
   function Interfaces_Xor (A, B : Integer) return Integer is
     (From_U (To_U (A) xor To_U (B)));
   Max_Passes : constant := 12;
   Max_Depth  : constant := 64;

   ---------------------------------------------------------------------
   --  Opcode table: (mnemonic, mode) -> opcode, built from the
   --  disassembler's decoding table
   ---------------------------------------------------------------------

   type Mode_Ops is array (Addr_Mode) of Integer;
   No_Ops : constant Mode_Ops := (others => -1);
   package Op_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Mode_Ops);
   Ops : Op_Maps.Map;

   procedure Build_Ops is
      procedure Alias (New_Name, Old : String) is
         E : constant Mode_Ops := Ops (Old);
      begin
         Ops.Include (New_Name, E);
      end Alias;
   begin
      for Op in Byte loop
         declare
            Mn : constant String := Mnemonic (Op);
            M  : constant Addr_Mode := Mode_Of (Op);
            E  : Mode_Ops :=
              (if Ops.Contains (Mn) then Ops (Mn) else No_Ops);
         begin
            if E (M) < 0 then
               E (M) := Integer (Op);
            end if;
            Ops.Include (Mn, E);
         end;
      end loop;
      declare
         E : Mode_Ops := Ops ("NOP");
      begin
         E (Imp) := 16#EA#;
         Ops.Include ("NOP", E);
      end;
      Alias ("ISB", "ISC");
      Alias ("INS", "ISC");
      Alias ("DCM", "DCP");
      Alias ("ASR", "ALR");
      Alias ("AXS", "SBX");
      Alias ("LSE", "SRE");
      Alias ("KIL", "JAM");
      Alias ("XAA", "ANE");
      Alias ("AXA", "SHA");
      Alias ("AHX", "SHA");
      Alias ("LAE", "LAS");
   end Build_Ops;

   ---------------------------------------------------------------------
   --  Sources
   ---------------------------------------------------------------------

   package Text_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);
   package Nat_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   type Line_Set is record
      Text : Text_Vectors.Vector;
      File : Nat_Vectors.Vector;
      Line : Nat_Vectors.Vector;
   end record;

   package Set_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Line_Set);

   Files : Text_Vectors.Vector;     --  full names, index = file number
   Cache : Set_Maps.Map;

   function File_Index (Full : String) return Positive is
   begin
      for I in 1 .. Natural (Files.Length) loop
         if Files (I) = Full then
            return I;
         end if;
      end loop;
      Files.Append (Full);
      return Natural (Files.Length);
   end File_Index;

   --  Put block braces on lines of their own ("!if x { nop }" becomes
   --  "!if x {", "nop", "}"); "} else {" stays together.
   procedure Split_Braces (S : in out Line_Set; L : String;
                           Idx, N : Positive) is
      From : Positive := L'First;
      In_Str : Boolean := False;
      I : Natural := L'First;

      procedure Put (T : String) is
      begin
         if Trim (T, Ada.Strings.Both) /= "" then
            S.Text.Append (T);
            S.File.Append (Idx);
            S.Line.Append (N);
         end if;
      end Put;
   begin
      while I <= L'Last loop
         if In_Str then
            if L (I) = '"' then
               In_Str := False;
            end if;
         elsif L (I) = '"' then
            In_Str := True;
         elsif L (I) = ''' and then I + 2 <= L'Last and then L (I + 2) = '''
         then
            I := I + 2;
         elsif L (I) = ';' then
            exit;
         elsif L (I) = '{' then
            Put (L (From .. I));
            From := I + 1;
         elsif L (I) = '}'
           and then Trim (L (From .. I - 1), Ada.Strings.Both) /= ""
         then
            Put (L (From .. I - 1));
            From := I;
         end if;
         I := I + 1;
      end loop;
      if From <= L'Last then
         Put (L (From .. L'Last));
      elsif From = L'First then
         Put (L);
      end if;
   end Split_Braces;

   function Load (Full : String) return Line_Set is
      use Ada.Text_IO;
      F : File_Type;
      S : Line_Set;
      N : Natural := 0;
      Idx : constant Positive := File_Index (Full);
   begin
      if Cache.Contains (Full) then
         return Cache (Full);
      end if;
      begin
         Open (F, In_File, Full);
      exception
         when others =>
            raise Asm_Error with "cannot open " & Full;
      end;
      while not End_Of_File (F) loop
         declare
            L : constant String := Get_Line (F);
            Last : Natural := L'Last;
         begin
            if Last >= L'First and then L (Last) = ASCII.CR then
               Last := Last - 1;
            end if;
            N := N + 1;
            Split_Braces (S, L (L'First .. Last), Idx, N);
         end;
      end loop;
      Close (F);
      Cache.Include (Full, S);
      return S;
   end Load;

   ---------------------------------------------------------------------
   --  Assembly state
   ---------------------------------------------------------------------

   type Sym is record
      Value    : Integer := 0;
      Pass     : Natural := 0;
      Settable : Boolean := False;
      Label    : Boolean := False;
      Display  : Unbounded_String;
   end record;
   package Sym_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Sym);
   Symbols : Sym_Maps.Map;

   type Macro_Rec is record
      Lines  : Text_Vectors.Vector;
      Params : Text_Vectors.Vector;
   end record;
   package Macro_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Macro_Rec);
   Macros : Macro_Maps.Map;

   package Int_Vectors is new Ada.Containers.Vectors (Positive, Integer);
   package Anon_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Int_Vectors.Vector, "<", Int_Vectors."=");
   package Last_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Integer);
   Plus_Prev, Plus_Cur : Anon_Maps.Map;
   Minus_Last : Last_Maps.Map;

   type Err is record
      File : Natural := 0;
      Line : Natural := 0;
      Text : Unbounded_String;
      Warn : Boolean := False;
   end record;
   package Err_Vectors is new Ada.Containers.Vectors (Positive, Err);
   Errors : Err_Vectors.Vector;

   type Loc is record
      File : Natural := 0;
      Line : Natural := 0;
      Code : Boolean := False;    --  an instruction (not data)
   end record;
   type Loc_Array is array (0 .. 65535) of Loc;
   type Bool_Array is array (0 .. 65535) of Boolean;

   Mem  : Byte_Array (0 .. 65535) := (others => 0);
   Used : Bool_Array := (others => False);
   Map  : Loc_Array;

   Pass       : Natural := 0;
   PC         : Integer := 16#0801#;
   Changed    : Boolean := False;
   Low, High  : Integer := -1;
   Start      : Integer := -1;
   Basic      : Boolean := False;
   Plain      : Boolean := False;
   Out_Name   : Unbounded_String;
   Init_Fill  : Byte := 0;
   Cur_File   : Natural := 0;
   Cur_Line   : Natural := 0;
   Depth      : Natural := 0;
   Zone_Scope : Unbounded_String;
   Cheap_Scope : Unbounded_String;
   Zone_Count, Macro_Count : Natural := 0;

   procedure Error (Msg : String; Warn : Boolean := False) is
   begin
      Errors.Append ((Cur_File, Cur_Line, To_Unbounded_String (Msg), Warn));
   end Error;

   ---------------------------------------------------------------------
   --  Lexical helpers
   ---------------------------------------------------------------------

   function Is_Id_Start (C : Character) return Boolean is
     (Is_Letter (C) or else C = '_');
   function Is_Id_Char (C : Character) return Boolean is
     (Is_Alphanumeric (C) or else C = '_');

   --  Index of the ';' starting a comment (or S'Last + 1)
   function Comment_Start (S : String) return Positive is
      I : Natural := S'First;
      In_Str : Boolean := False;
   begin
      while I <= S'Last loop
         if In_Str then
            if S (I) = '"' then
               In_Str := False;
            end if;
         elsif S (I) = '"' then
            In_Str := True;
         elsif S (I) = ''' and then I + 2 <= S'Last and then S (I + 2) = '''
         then
            I := I + 2;
         elsif S (I) = ';' then
            return I;
         end if;
         I := I + 1;
      end loop;
      return S'Last + 1;
   end Comment_Start;

   function Strip (S : String) return String is
     (Trim (S (S'First .. Comment_Start (S) - 1), Ada.Strings.Both));

   --  Split at top-level occurrences of Sep (outside strings, character
   --  literals and - for ',' - brackets).
   function Split (S : String; Sep : Character) return Text_Vectors.Vector
   is
      R : Text_Vectors.Vector;
      From : Positive := S'First;
      Level : Integer := 0;
      In_Str : Boolean := False;
      I : Natural := S'First;
   begin
      while I <= S'Last loop
         declare
            C : constant Character := S (I);
         begin
            if In_Str then
               if C = '"' then
                  In_Str := False;
               end if;
            elsif C = '"' then
               In_Str := True;
            elsif C = ''' and then I + 2 <= S'Last and then S (I + 2) = '''
            then
               I := I + 2;
            elsif Sep = ',' and then C in '(' | '[' then
               Level := Level + 1;
            elsif Sep = ',' and then C in ')' | ']' then
               Level := Level - 1;
            elsif C = Sep and then Level <= 0 then
               R.Append (Trim (S (From .. I - 1), Ada.Strings.Both));
               From := I + 1;
            end if;
         end;
         I := I + 1;
      end loop;
      R.Append (Trim (S (From .. S'Last), Ada.Strings.Both));
      return R;
   end Split;

   function Remove_Spaces (S : String) return String is
      R : String (1 .. S'Length);
      N : Natural := 0;
      In_Str : Boolean := False;
      I : Natural := S'First;
   begin
      while I <= S'Last loop
         if S (I) = '"' then
            In_Str := not In_Str;
         elsif not In_Str and then S (I) = ''' and then I + 2 <= S'Last
           and then S (I + 2) = '''
         then
            R (N + 1 .. N + 3) := S (I .. I + 2);
            N := N + 3;
            I := I + 3;
            goto Next;
         end if;
         if In_Str or else (S (I) /= ' ' and then S (I) /= ASCII.HT) then
            N := N + 1;
            R (N) := S (I);
         end if;
         I := I + 1;
         <<Next>>
      end loop;
      return R (1 .. N);
   end Remove_Spaces;

   function Is_String (S : String) return Boolean is
     (S'Length >= 2 and then S (S'First) = '"' and then S (S'Last) = '"');

   function String_Value (S : String) return String is
     (S (S'First + 1 .. S'Last - 1));

   ---------------------------------------------------------------------
   --  Symbols
   ---------------------------------------------------------------------

   function Scoped (Name : String) return String is
   begin
      if Name (Name'First) = '.' then
         return To_String (Zone_Scope) & Name;
      elsif Name (Name'First) = '@' then
         return To_String (Cheap_Scope) & Name;
      else
         return Name;
      end if;
   end Scoped;

   procedure Define (Name : String; Value : Integer;
                     Label : Boolean; Settable : Boolean := False) is
      Key : constant String := Scoped (Name);
      S : Sym;
   begin
      if Symbols.Contains (Key) then
         S := Symbols (Key);
         if S.Pass = Pass and then not (S.Settable and then Settable) then
            raise Asm_Error with "symbol already defined: " & Name;
         end if;
         if S.Value /= Value and then not Settable then
            Changed := True;
         end if;
      else
         Changed := Changed or else not Settable;
      end if;
      S.Value := Value;
      S.Pass := Pass;
      S.Settable := Settable;
      S.Label := Label;
      S.Display := To_Unbounded_String (Name);
      Symbols.Include (Key, S);
      if Name (Name'First) /= '.' and then Name (Name'First) /= '@' then
         Cheap_Scope := To_Unbounded_String (Name);
      end if;
   end Define;

   ---------------------------------------------------------------------
   --  Expressions
   ---------------------------------------------------------------------

   function Eval (S : String; Known : out Boolean) return Integer is
      Pos : Natural := S'First;

      function At_End return Boolean is (Pos > S'Last);

      procedure Skip is
      begin
         while Pos <= S'Last and then S (Pos) in ' ' | ASCII.HT loop
            Pos := Pos + 1;
         end loop;
      end Skip;

      function Next_Is (T : String) return Boolean is
      begin
         Skip;
         return Pos + T'Length - 1 <= S'Last
           and then S (Pos .. Pos + T'Length - 1) = T;
      end Next_Is;

      function Expr return Integer;

      function Anon_Ref (Name : String) return Integer is
      begin
         if Name (Name'First) = '-' then
            if Minus_Last.Contains (Name) then
               return Minus_Last (Name);
            end if;
         else
            declare
               Count : constant Natural :=
                 (if Plus_Cur.Contains (Name)
                  then Natural (Plus_Cur (Name).Length) else 0);
            begin
               if Plus_Prev.Contains (Name)
                 and then Natural (Plus_Prev (Name).Length) > Count
               then
                  return Plus_Prev (Name) (Count + 1);
               end if;
            end;
         end if;
         Known := False;
         Error ("anonymous label " & Name & " not found");
         return 0;
      end Anon_Ref;

      function Primary return Integer is
         V : Integer := 0;
         Start_Pos : Natural;
      begin
         Skip;
         if At_End then
            raise Asm_Error with "value expected";
         end if;
         case S (Pos) is
            when '(' | '[' =>
               declare
                  Close : constant Character :=
                    (if S (Pos) = '(' then ')' else ']');
               begin
                  Pos := Pos + 1;
                  V := Expr;
                  Skip;
                  if At_End or else S (Pos) /= Close then
                     raise Asm_Error with "missing " & Close;
                  end if;
                  Pos := Pos + 1;
                  return V;
               end;
            when '$' =>
               Pos := Pos + 1;
               Start_Pos := Pos;
               while not At_End and then Is_Hexadecimal_Digit (S (Pos)) loop
                  V := V * 16 + Integer'Value ("16#" & S (Pos) & "#");
                  Pos := Pos + 1;
               end loop;
               if Pos = Start_Pos then
                  raise Asm_Error with "hex digits expected";
               end if;
               return V;
            when '%' =>
               Pos := Pos + 1;
               Start_Pos := Pos;
               while not At_End and then S (Pos) in '0' | '1' | '.' | '#' loop
                  V := V * 2 + (if S (Pos) in '1' | '#' then 1 else 0);
                  Pos := Pos + 1;
               end loop;
               if Pos = Start_Pos then
                  raise Asm_Error with "binary digits expected";
               end if;
               return V;
            when '0' .. '9' =>
               if Pos + 1 <= S'Last and then S (Pos) = '0'
                 and then S (Pos + 1) in 'x' | 'X'
               then
                  Pos := Pos + 2;
                  while not At_End and then Is_Hexadecimal_Digit (S (Pos))
                  loop
                     V := V * 16 + Integer'Value ("16#" & S (Pos) & "#");
                     Pos := Pos + 1;
                  end loop;
                  return V;
               end if;
               while not At_End and then Is_Digit (S (Pos)) loop
                  V := V * 10 + (Character'Pos (S (Pos)) - 48);
                  Pos := Pos + 1;
               end loop;
               return V;
            when ''' =>
               if Pos + 2 <= S'Last and then S (Pos + 2) = ''' then
                  V := Character'Pos (S (Pos + 1));
                  Pos := Pos + 3;
                  return V;
               end if;
               raise Asm_Error with "bad character constant";
            when '"' =>
               if Pos + 2 <= S'Last and then S (Pos + 2) = '"' then
                  V := Character'Pos (S (Pos + 1));
                  Pos := Pos + 3;
                  return V;
               end if;
               raise Asm_Error with "string not allowed here";
            when '*' =>
               Pos := Pos + 1;
               return PC;
            when others =>
               if Is_Id_Start (S (Pos)) or else
                 (S (Pos) in '.' | '@' and then Pos < S'Last
                  and then Is_Id_Char (S (Pos + 1)))
               then
                  Start_Pos := Pos;
                  Pos := Pos + 1;
                  while not At_End and then Is_Id_Char (S (Pos)) loop
                     Pos := Pos + 1;
                  end loop;
                  declare
                     Name : constant String := S (Start_Pos .. Pos - 1);
                     Key  : constant String := Scoped (Name);
                  begin
                     if Symbols.Contains (Key) then
                        return Symbols (Key).Value;
                     end if;
                     Known := False;
                     Error ("undefined symbol: " & Name);
                     return 0;
                  end;
               end if;
               raise Asm_Error with "syntax error at '" & S (Pos .. S'Last)
                 & "'";
         end case;
      end Primary;

      function Unary return Integer is
      begin
         Skip;
         if At_End then
            raise Asm_Error with "value expected";
         end if;
         case S (Pos) is
            when '-' | '+' =>
               declare
                  C : constant Character := S (Pos);
                  J : Natural := Pos;
               begin
                  while J <= S'Last and then S (J) = C loop
                     J := J + 1;
                  end loop;
                  declare
                     Run_End : constant Natural := J - 1;
                  begin
                     while J <= S'Last and then S (J) in ' ' | ASCII.HT loop
                        J := J + 1;
                     end loop;
                     if J > S'Last or else S (J) in ',' | ')' | ']' then
                        declare
                           Name : constant String := S (Pos .. Run_End);
                        begin
                           Pos := Run_End + 1;
                           return Anon_Ref (Name);
                        end;
                     end if;
                  end;
                  Pos := Pos + 1;
                  return (if C = '-' then -Unary else Unary);
               end;
            when '<' =>
               Pos := Pos + 1;
               return Unary mod 256;
            when '>' =>
               Pos := Pos + 1;
               return (Unary / 256) mod 256;
            when '~' | '!' =>
               Pos := Pos + 1;
               return -Unary - 1;
            when others =>
               return Primary;
         end case;
      end Unary;

      function Mul return Integer is
         V : Integer := Unary;
         R : Integer;
      begin
         loop
            Skip;
            exit when At_End;
            case S (Pos) is
               when '*' =>
                  Pos := Pos + 1;
                  V := V * Unary;
               when '/' | '%' =>
                  declare
                     Op : constant Character := S (Pos);
                  begin
                     Pos := Pos + 1;
                     R := Unary;
                     if R = 0 then
                        if Known then
                           raise Asm_Error with "division by zero";
                        end if;
                        V := 0;
                     else
                        V := (if Op = '/' then V / R else V mod R);
                     end if;
                  end;
               when others =>
                  exit;
            end case;
         end loop;
         return V;
      end Mul;

      function Add return Integer is
         V : Integer := Mul;
      begin
         loop
            Skip;
            exit when At_End;
            if S (Pos) = '+' then
               Pos := Pos + 1;
               V := V + Mul;
            elsif S (Pos) = '-' then
               Pos := Pos + 1;
               V := V - Mul;
            else
               exit;
            end if;
         end loop;
         return V;
      end Add;

      function Shift return Integer is
         V : Integer := Add;
      begin
         loop
            if Next_Is ("<<") then
               Pos := Pos + 2;
               V := V * 2 ** Add;
            elsif Next_Is (">>") then
               Pos := Pos + 2;
               V := V / 2 ** Add;
            else
               exit;
            end if;
         end loop;
         return V;
      end Shift;

      function Bit_And return Integer is
         V : Integer := Shift;
      begin
         while Next_Is ("&") and then not Next_Is ("&&") loop
            Pos := Pos + 1;
            V := Interfaces_And (V, Shift);
         end loop;
         return V;
      end Bit_And;

      function Bit_Xor return Integer is
         V : Integer := Bit_And;
      begin
         while Next_Is ("^") loop
            Pos := Pos + 1;
            V := Interfaces_Xor (V, Bit_And);
         end loop;
         return V;
      end Bit_Xor;

      function Bit_Or return Integer is
         V : Integer := Bit_Xor;
      begin
         while Next_Is ("|") and then not Next_Is ("||") loop
            Pos := Pos + 1;
            V := Interfaces_Or (V, Bit_Xor);
         end loop;
         return V;
      end Bit_Or;

      function Compare return Integer is
         V : constant Integer := Bit_Or;
         function B (X : Boolean) return Integer is (if X then 1 else 0);
      begin
         if Next_Is ("==") then
            Pos := Pos + 2;
            return B (V = Bit_Or);
         elsif Next_Is ("!=") or else Next_Is ("<>") then
            Pos := Pos + 2;
            return B (V /= Bit_Or);
         elsif Next_Is ("<=") then
            Pos := Pos + 2;
            return B (V <= Bit_Or);
         elsif Next_Is (">=") then
            Pos := Pos + 2;
            return B (V >= Bit_Or);
         elsif Next_Is ("=") then
            Pos := Pos + 1;
            return B (V = Bit_Or);
         elsif Next_Is ("<") then
            Pos := Pos + 1;
            return B (V < Bit_Or);
         elsif Next_Is (">") then
            Pos := Pos + 1;
            return B (V > Bit_Or);
         end if;
         return V;
      end Compare;

      function Logic return Integer is
         V : Integer := Compare;
      begin
         loop
            if Next_Is ("&&") then
               Pos := Pos + 2;
               V := (if Compare /= 0 and then V /= 0 then 1 else 0);
            elsif Next_Is ("||") then
               Pos := Pos + 2;
               V := (if Compare /= 0 or else V /= 0 then 1 else 0);
            else
               exit;
            end if;
         end loop;
         return V;
      end Logic;

      function Expr return Integer is (Logic);

      V : Integer;
   begin
      Known := True;
      if S'Length = 0 then
         raise Asm_Error with "value expected";
      end if;
      V := Expr;
      Skip;
      if not At_End then
         raise Asm_Error with "syntax error at '" & S (Pos .. S'Last) & "'";
      end if;
      return V;
   end Eval;

   ---------------------------------------------------------------------
   --  Output
   ---------------------------------------------------------------------

   procedure Emit (B : Integer) is
   begin
      if PC < 0 or else PC > 65535 then
         raise Asm_Error with "program counter outside $0000-$FFFF";
      end if;
      Mem (PC) := Byte (B mod 256);
      Used (PC) := True;
      if Low < 0 or else PC < Low then
         Low := PC;
      end if;
      if PC > High then
         High := PC;
      end if;
      PC := PC + 1;
   end Emit;

   procedure Emit_Word (W : Integer) is
   begin
      Emit (W mod 256);
      Emit ((W / 256) mod 256);
   end Emit_Word;

   procedure Mark_Line (Code : Boolean := False) is
   begin
      if PC in 0 .. 65535 then
         Map (PC) := (Cur_File, Cur_Line, Code);
      end if;
   end Mark_Line;

   ---------------------------------------------------------------------
   --  Instructions
   ---------------------------------------------------------------------

   procedure Check_Byte (V : Integer; Known : Boolean; What : String) is
   begin
      if Known and then V not in -128 .. 255 then
         raise Asm_Error with What & " out of range ($" &
           Hex4 (Word (V mod 65536)) & ")";
      end if;
   end Check_Byte;

   --  Index of the parenthesis matching the one at S (First)
   function Matching (S : String; First : Positive) return Natural is
      Level : Natural := 0;
   begin
      for I in First .. S'Last loop
         if S (I) = '(' then
            Level := Level + 1;
         elsif S (I) = ')' then
            Level := Level - 1;
            if Level = 0 then
               return I;
            end if;
         end if;
      end loop;
      return 0;
   end Matching;

   procedure Instruction (Mn : String; Operand : String) is
      E : constant Mode_Ops := Ops (Mn);
      Op : constant String := Remove_Spaces (Operand);
      U  : constant String := To_Upper (Op);
      Known : Boolean;
      V : Integer;

      procedure Out1 (M : Addr_Mode) is
      begin
         Mark_Line (Code => True);
         Emit (E (M));
      end Out1;

      procedure Out2 (M : Addr_Mode; Val : Integer) is
      begin
         Mark_Line (Code => True);
         Emit (E (M));
         Emit (Val mod 256);
      end Out2;

      procedure Out3 (M : Addr_Mode; Val : Integer) is
      begin
         Mark_Line (Code => True);
         Emit (E (M));
         Emit_Word (Val mod 65536);
      end Out3;

      procedure Mem_Mode (Expr : String; Z, A : Addr_Mode) is
      begin
         V := Eval (Expr, Known);
         if E (Z) >= 0
           and then ((Known and then V in 0 .. 255) or else E (A) < 0)
         then
            Check_Byte (V, Known, "zero-page address");
            Out2 (Z, V);
         elsif E (A) >= 0 then
            if Known and then V not in 0 .. 65535 then
               raise Asm_Error with "address out of range";
            end if;
            Out3 (A, V);
         else
            raise Asm_Error with "illegal addressing mode for " & Mn;
         end if;
      end Mem_Mode;
   begin
      if Op'Length = 0 then
         if E (Imp) >= 0 then
            Out1 (Imp);
         elsif E (Acc) >= 0 then
            Out1 (Acc);
         else
            raise Asm_Error with Mn & " needs an operand";
         end if;
      elsif U = "A" and then E (Acc) >= 0 then
         Out1 (Acc);
      elsif Op (Op'First) = '#' then
         if E (Imm) < 0 then
            raise Asm_Error with "no immediate mode for " & Mn;
         end if;
         V := Eval (Op (Op'First + 1 .. Op'Last), Known);
         Check_Byte (V, Known, "immediate value");
         Out2 (Imm, V);
      elsif E (Rel) >= 0 then
         V := Eval (Op, Known);
         declare
            Offset : constant Integer := V - (PC + 2);
         begin
            if Known and then Offset not in -128 .. 127 then
               raise Asm_Error with "branch out of range (" &
                 Trim (Offset'Image, Ada.Strings.Left) & " bytes)";
            end if;
            Out2 (Rel, (if Known then Offset else 0));
         end;
      elsif Op (Op'First) = '('
        and then U'Length > 4
        and then U (U'Last - 2 .. U'Last) = ",X)"
        and then Matching (Op, Op'First) = Op'Last
      then
         if E (IndX) < 0 then
            raise Asm_Error with "no (zp,x) mode for " & Mn;
         end if;
         V := Eval (Op (Op'First + 1 .. Op'Last - 3), Known);
         Check_Byte (V, Known, "zero-page address");
         Out2 (IndX, V);
      elsif Op (Op'First) = '('
        and then U'Length > 4
        and then U (U'Last - 1 .. U'Last) = ",Y"
        and then Matching (Op, Op'First) = Op'Last - 2
      then
         if E (IndY) < 0 then
            raise Asm_Error with "no (zp),y mode for " & Mn;
         end if;
         V := Eval (Op (Op'First + 1 .. Op'Last - 3), Known);
         Check_Byte (V, Known, "zero-page address");
         Out2 (IndY, V);
      elsif Op (Op'First) = '(' and then E (Ind) >= 0
        and then Matching (Op, Op'First) = Op'Last
      then
         V := Eval (Op (Op'First + 1 .. Op'Last - 1), Known);
         Out3 (Ind, V);
      elsif U'Length > 2 and then U (U'Last - 1 .. U'Last) = ",X" then
         Mem_Mode (Op (Op'First .. Op'Last - 2), ZPX, AbsX);
      elsif U'Length > 2 and then U (U'Last - 1 .. U'Last) = ",Y" then
         Mem_Mode (Op (Op'First .. Op'Last - 2), ZPY, AbsY);
      else
         Mem_Mode (Op, ZP, Abso);
      end if;
   end Instruction;

   ---------------------------------------------------------------------
   --  Directives
   ---------------------------------------------------------------------

   type Encoding is (Raw, Pet, Scr);

   function Convert (C : Character; Enc : Encoding) return Integer is
      P : constant Integer := Character'Pos (C);
   begin
      case Enc is
         when Raw =>
            return P;
         when Pet =>
            if C in 'a' .. 'z' then
               return P - 32;
            elsif C in 'A' .. 'Z' then
               return P + 128;
            end if;
            return P;
         when Scr =>
            if C in 'a' .. 'z' then
               return P - 96;
            elsif C in 'A' .. 'Z' then
               return P;          --  shifted letters (upper/lower set)
            elsif C in '@' | '[' .. '_' then
               return P - 64;
            elsif C = '`' then
               return 64;
            end if;
            return P;
      end case;
   end Convert;

   procedure Data (Args : String; Size : Positive; Enc : Encoding) is
      Known : Boolean;
      V : Integer;
   begin
      if Args = "" then
         raise Asm_Error with "data expected";
      end if;
      Mark_Line;
      for A of Split (Args, ',') loop
         if Is_String (A) then
            for C of String_Value (A) loop
               if Size = 1 then
                  Emit (Convert (C, Enc));
               else
                  Emit_Word (Convert (C, Enc));
               end if;
            end loop;
         else
            V := Eval (A, Known);
            if Size = 1 then
               if Enc /= Raw and then Known and then V in 0 .. 255 then
                  V := Convert (Character'Val (V), Enc);
               end if;
               Check_Byte (V, Known, "byte value");
               Emit (V);
            else
               if Known and then V not in -32768 .. 65535 then
                  raise Asm_Error with "word value out of range";
               end if;
               Emit_Word (V mod 65536);
            end if;
         end if;
      end loop;
   end Data;

   function Must_Eval (S : String) return Integer is
      Known : Boolean;
      V : constant Integer := Eval (S, Known);
   begin
      return V;
   end Must_Eval;

   function Dir_Of_Current return String is
   begin
      if Cur_File in 1 .. Natural (Files.Length) then
         return Ada.Directories.Containing_Directory (Files (Cur_File));
      end if;
      return Ada.Directories.Current_Directory;
   end Dir_Of_Current;

   function Resolve (Name : String) return String is
   begin
      if Name'Length > 0 and then Name (Name'First) = '/' then
         return Name;
      end if;
      return Ada.Directories.Compose (Dir_Of_Current, Name);
   exception
      when others =>
         return Dir_Of_Current & "/" & Name;
   end Resolve;

   procedure Binary (Args : String) is
      use Ada.Streams.Stream_IO;
      A : constant Text_Vectors.Vector := Split (Args, ',');
      F : File_Type;
      Size : Integer := -1;
      Skip_N : Natural := 0;
   begin
      if not Is_String (A (1)) then
         raise Asm_Error with "file name expected";
      end if;
      if Natural (A.Length) >= 2 and then A (2) /= "" then
         Size := Must_Eval (A (2));
      end if;
      if Natural (A.Length) >= 3 then
         Skip_N := Must_Eval (A (3));
      end if;
      begin
         Open (F, In_File, Resolve (String_Value (A (1))));
      exception
         when others =>
            raise Asm_Error with "cannot open " & String_Value (A (1));
      end;
      declare
         Len : constant Natural := Natural (Ada.Streams.Stream_IO.Size (F));
         Buf : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Len));
         Last : Ada.Streams.Stream_Element_Offset;
         N : Natural;
      begin
         Read (F, Buf, Last);
         Close (F);
         N := (if Size >= 0 then Size else Integer'Max (0, Len - Skip_N));
         Mark_Line;
         for I in 1 .. N loop
            declare
               K : constant Natural := Skip_N + I;
            begin
               Emit (if K <= Len
                     then Integer (Buf (Ada.Streams.Stream_Element_Offset (K)))
                     else 0);
            end;
         end loop;
      end;
   end Binary;

   procedure Basic_Stub (Args : String) is
      Known : Boolean := True;
      Target : Integer;
      function Digits_Of (N : Integer) return Natural is
        (Trim (Integer'Image (N), Ada.Strings.Left)'Length);
   begin
      if Args /= "" then
         Target := Eval (Args, Known);
      else
         Target := PC + 12;
         for I in 1 .. 3 loop
            Target := PC + 8 + Digits_Of (Target);
         end loop;
      end if;
      declare
         Num : constant String := Trim (Integer'Image (Target),
                                        Ada.Strings.Left);
      begin
         Mark_Line;
         Emit_Word (PC + 6 + Num'Length);   --  link to the end marker
         Emit_Word (10);                     --  line number
         Emit (16#9E#);                      --  SYS
         for C of Num loop
            Emit (Character'Pos (C));
         end loop;
         Emit (0);
         Emit_Word (0);
      end;
      if Start < 0 then
         Start := Target;
         Basic := True;
      end if;
   end Basic_Stub;

   procedure Process (Set : Line_Set; First, Last : Natural);

   procedure Include (Name : String) is
      Saved_File : constant Natural := Cur_File;
      Saved_Line : constant Natural := Cur_Line;
   begin
      if Depth >= Max_Depth then
         raise Asm_Error with "includes nested too deeply";
      end if;
      declare
         S : constant Line_Set := Load (Resolve (Name));
      begin
         Depth := Depth + 1;
         Process (S, 1, Natural (S.Text.Length));
         Depth := Depth - 1;
      end;
      Cur_File := Saved_File;
      Cur_Line := Saved_Line;
   end Include;

   procedure Directive (Name : String; Args : String) is
      A : Text_Vectors.Vector;
   begin
      if Name in "byte" | "by" | "8" | "db" then
         Data (Args, 1, Raw);
      elsif Name in "word" | "wo" | "16" | "dw" | "addr" then
         Data (Args, 2, Raw);
      elsif Name in "text" | "tx" | "ascii" | "raw" then
         Data (Args, 1, Raw);
      elsif Name in "pet" | "petscii" then
         Data (Args, 1, Pet);
      elsif Name in "scr" | "screen" then
         Data (Args, 1, Scr);
      elsif Name in "fill" | "fi" then
         A := Split (Args, ',');
         declare
            N : constant Integer := Must_Eval (A (1));
            V : constant Integer :=
              (if Natural (A.Length) >= 2 then Must_Eval (A (2)) else 0);
         begin
            if N < 0 or else N > 65536 then
               raise Asm_Error with "bad fill count";
            end if;
            Mark_Line;
            for I in 1 .. N loop
               Emit (V);
            end loop;
         end;
      elsif Name in "skip" | "res" then
         PC := PC + Must_Eval (Args);
      elsif Name = "align" then
         A := Split (Args, ',');
         declare
            Mask : constant Integer := Must_Eval (A (1));
            Val  : constant Integer :=
              (if Natural (A.Length) >= 2 then Must_Eval (A (2)) else 0);
            Fill : constant Integer :=
              (if Natural (A.Length) >= 3 then Must_Eval (A (3)) else 0);
            Count : Natural := 0;
         begin
            if Natural (A.Length) = 1 then
               --  ".align n": next multiple of n
               if Mask > 0 then
                  while PC mod Mask /= 0 loop
                     Emit (Fill);
                     Count := Count + 1;
                  end loop;
               end if;
            else
               while Interfaces_And (PC, Mask) /= Val loop
                  Emit (Fill);
                  Count := Count + 1;
                  exit when Count > 65536;
               end loop;
            end if;
         end;
      elsif Name in "binary" | "bin" | "incbin" then
         Binary (Args);
      elsif Name in "source" | "src" | "include" then
         if not Is_String (Args) then
            raise Asm_Error with "file name expected";
         end if;
         Include (String_Value (Args));
      elsif Name = "to" then
         A := Split (Args, ',');
         if not Is_String (A (1)) then
            raise Asm_Error with "file name expected";
         end if;
         Out_Name := To_Unbounded_String (Resolve (String_Value (A (1))));
         Plain := Natural (A.Length) >= 2 and then To_Lower (A (2)) = "plain";
      elsif Name in "zone" | "zn" then
         Zone_Count := Zone_Count + 1;
         Zone_Scope := To_Unbounded_String ("z" & Zone_Count'Image);
      elsif Name = "basic" then
         Basic_Stub (Args);
      elsif Name = "set" then
         declare
            Eq : constant Natural := Index (Args, "=");
         begin
            if Eq = 0 then
               raise Asm_Error with "!set name = value";
            end if;
            Define (Trim (Args (Args'First .. Eq - 1), Ada.Strings.Both),
                    Must_Eval (Args (Eq + 1 .. Args'Last)), False, True);
         end;
      elsif Name in "warn" | "error" then
         Error ((if Is_String (Args) then String_Value (Args) else Args),
                Warn => Name = "warn");
      elsif Name = "initmem" then
         Init_Fill := Byte (Must_Eval (Args) mod 256);
      elsif Name in "org" | "pc" then
         PC := Must_Eval (Args);
      elsif Name in "cpu" | "sl" | "symbollist" | "convtab" | "ct" then
         null;
      else
         raise Asm_Error with "unknown directive !" & Name;
      end if;
   end Directive;

   Dot_Directives : constant array (1 .. 15) of access constant String :=
     (new String'("byte"), new String'("db"), new String'("word"),
      new String'("dw"), new String'("text"), new String'("fill"),
      new String'("align"), new String'("org"), new String'("include"),
      new String'("incbin"), new String'("res"), new String'("binary"),
      new String'("pet"), new String'("screen"), new String'("addr"));

   function Is_Dot_Directive (N : String) return Boolean is
   begin
      for D of Dot_Directives loop
         if D.all = N then
            return True;
         end if;
      end loop;
      return False;
   end Is_Dot_Directive;

   ---------------------------------------------------------------------
   --  Macros
   ---------------------------------------------------------------------

   function Substitute (Line : String; Params, Args : Text_Vectors.Vector)
                        return String
   is
      R : Unbounded_String;
      I : Natural := Line'First;
      In_Str : Boolean := False;
   begin
      while I <= Line'Last loop
         if Line (I) = '"' then
            In_Str := not In_Str;
            Append (R, Line (I));
            I := I + 1;
         elsif not In_Str and then
           (Is_Id_Start (Line (I))
            or else (Line (I) in '.' | '@' and then I < Line'Last
                     and then Is_Id_Start (Line (I + 1))))
         then
            declare
               J : Natural := I + 1;
            begin
               while J <= Line'Last and then Is_Id_Char (Line (J)) loop
                  J := J + 1;
               end loop;
               declare
                  Word_S : constant String := Line (I .. J - 1);
                  Done : Boolean := False;
               begin
                  for K in 1 .. Natural (Params.Length) loop
                     if Params (K) = Word_S then
                        Append (R, Args (K));
                        Done := True;
                        exit;
                     end if;
                  end loop;
                  if not Done then
                     Append (R, Word_S);
                  end if;
               end;
               I := J;
            end;
         else
            Append (R, Line (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (R);
   end Substitute;

   procedure Macro_Call (Name : String; Arg_Text : String) is
      Args : constant Text_Vectors.Vector :=
        (if Arg_Text = "" then Text_Vectors.Empty_Vector
         else Split (Arg_Text, ','));
      S : Line_Set;
      Saved_Zone : constant Unbounded_String := Zone_Scope;
      Saved_File : constant Natural := Cur_File;
      Saved_Line : constant Natural := Cur_Line;
   begin
      if not Macros.Contains (Name) then
         raise Asm_Error with "unknown macro " & Name;
      end if;
      declare
         M : constant Macro_Rec := Macros (Name);
      begin
         if Args.Length /= M.Params.Length then
            raise Asm_Error with "macro " & Name & " takes" &
              M.Params.Length'Image & " arguments";
         end if;
         for L of M.Lines loop
            S.Text.Append (Substitute (L, M.Params, Args));
            S.File.Append (Cur_File);
            S.Line.Append (Cur_Line);
         end loop;
      end;
      if Depth >= Max_Depth then
         raise Asm_Error with "macros nested too deeply";
      end if;
      Macro_Count := Macro_Count + 1;
      Zone_Scope := To_Unbounded_String ("m" & Macro_Count'Image);
      Depth := Depth + 1;
      Process (S, 1, Natural (S.Text.Length));
      Depth := Depth - 1;
      Zone_Scope := Saved_Zone;
      Cur_File := Saved_File;
      Cur_Line := Saved_Line;
   end Macro_Call;

   ---------------------------------------------------------------------
   --  Statements and lines
   ---------------------------------------------------------------------

   function All_Same (S : String; C : Character) return Boolean is
     (S'Length > 0 and then (for all X of S => X = C));

   function Valid_Name (S : String) return Boolean is
     (S'Length > 0
      and then (Is_Id_Start (S (S'First))
                or else (S (S'First) in '.' | '@' and then S'Length > 1))
      and then (for all I in S'First + 1 .. S'Last => Is_Id_Char (S (I))));

   procedure Statement (S : String) is
      Tok_End : Natural := S'First;
   begin
      if S (S'First) = '*' then
         declare
            R : constant String :=
              Trim (S (S'First + 1 .. S'Last), Ada.Strings.Both);
            Known : Boolean;
            V : Integer;
         begin
            if R'Length = 0 or else R (R'First) /= '=' then
               raise Asm_Error with "*= expected";
            end if;
            V := Eval (R (R'First + 1 .. R'Last), Known);
            if Known then
               PC := V;
            end if;
            return;
         end;
      end if;

      while Tok_End <= S'Last
        and then S (Tok_End) not in ' ' | ASCII.HT | '='
      loop
         Tok_End := Tok_End + 1;
      end loop;
      declare
         Tok  : constant String := S (S'First .. Tok_End - 1);
         Rest : constant String :=
           Trim (S (Tok_End .. S'Last), Ada.Strings.Both);
      begin
         if Tok'Length = 0 then
            raise Asm_Error with "syntax error";
         end if;
         if Tok (Tok'First) = '!' then
            Directive (To_Lower (Tok (Tok'First + 1 .. Tok'Last)), Rest);
            return;
         end if;
         if Tok (Tok'First) = '.' and then Tok'Length > 1
           and then Is_Dot_Directive (To_Lower (Tok (Tok'First + 1 .. Tok'Last)))
         then
            Directive (To_Lower (Tok (Tok'First + 1 .. Tok'Last)), Rest);
            return;
         end if;
         if Tok (Tok'First) = '+' and then Tok'Length > 1
           and then Is_Id_Start (Tok (Tok'First + 1))
         then
            Macro_Call (Tok (Tok'First + 1 .. Tok'Last), Rest);
            return;
         end if;
         if All_Same (Tok, '-') then
            Minus_Last.Include (Tok, PC);
            if Rest /= "" then
               Statement (Rest);
            end if;
            return;
         end if;
         if All_Same (Tok, '+') then
            declare
               V : Int_Vectors.Vector :=
                 (if Plus_Cur.Contains (Tok) then Plus_Cur (Tok)
                  else Int_Vectors.Empty_Vector);
               K : constant Positive := Natural (V.Length) + 1;
            begin
               if not Plus_Prev.Contains (Tok)
                 or else Natural (Plus_Prev (Tok).Length) < K
                 or else Plus_Prev (Tok) (K) /= PC
               then
                  Changed := True;
               end if;
               V.Append (PC);
               Plus_Cur.Include (Tok, V);
            end;
            if Rest /= "" then
               Statement (Rest);
            end if;
            return;
         end if;
         if Tok'Length = 3 and then Ops.Contains (To_Upper (Tok))
           and then (Rest'Length = 0 or else Rest (Rest'First) /= '=')
         then
            Instruction (To_Upper (Tok), Rest);
            return;
         end if;
         if not Valid_Name (Tok) then
            raise Asm_Error with "syntax error: " & S;
         end if;
         if Rest'Length > 0 and then Rest (Rest'First) = '='
           and then (Rest'Length = 1 or else Rest (Rest'First + 1) /= '=')
         then
            declare
               Known : Boolean;
               V : constant Integer :=
                 Eval (Rest (Rest'First + 1 .. Rest'Last), Known);
            begin
               Define (Tok, V, False);
            end;
            return;
         end if;
         Define (Tok, PC, True);
         if Rest /= "" then
            Statement (Rest);
         end if;
      end;
   end Statement;

   procedure Line_Statements (T : String) is
   begin
      for P of Split (T, ':') loop
         if P /= "" then
            begin
               Statement (P);
            exception
               when E : Asm_Error =>
                  Error (Exception_Message (E));
            end;
         end if;
      end loop;
   end Line_Statements;

   --  Find the line holding the '}' that closes the block opened on
   --  line Open; Rest is what follows that '}'.
   procedure Block_End (Set : Line_Set; Open, Last : Natural;
                        Close : out Natural; Rest : out Unbounded_String) is
      Level : Natural := 1;
   begin
      for J in Open + 1 .. Last loop
         declare
            T : constant String := Strip (Set.Text (J));
            In_Str : Boolean := False;
         begin
            for I in T'Range loop
               if T (I) = '"' then
                  In_Str := not In_Str;
               elsif not In_Str and then T (I) = '{' then
                  Level := Level + 1;
               elsif not In_Str and then T (I) = '}' then
                  Level := Level - 1;
                  if Level = 0 then
                     Close := J;
                     Rest := To_Unbounded_String
                       (Trim (T (I + 1 .. T'Last), Ada.Strings.Both));
                     return;
                  end if;
               end if;
            end loop;
         end;
      end loop;
      Close := Last + 1;
      Rest := Null_Unbounded_String;
      raise Asm_Error with "missing } for block";
   end Block_End;

   function Block_Cond (Head : String; Is_Block : out Boolean)
                        return Boolean is
      Sp : Natural := Index (Head, " ");
   begin
      if Sp = 0 then
         Sp := Head'Last + 1;
      end if;
      declare
         Kw : constant String := To_Lower (Head (Head'First .. Sp - 1));
         Arg : constant String :=
           Trim (Head (Sp .. Head'Last), Ada.Strings.Both);
         Known : Boolean;
      begin
         Is_Block := True;
         if Kw = "!if" then
            declare
               V : constant Integer := Eval (Arg, Known);
            begin
               return Known and then V /= 0;
            end;
         elsif Kw = "!ifdef" then
            return Symbols.Contains (Scoped (Arg));
         elsif Kw = "!ifndef" then
            return not Symbols.Contains (Scoped (Arg));
         end if;
         Is_Block := False;
         return False;
      end;
   end Block_Cond;

   procedure Block (Set : Line_Set; L : Natural; Head : String;
                    Last : Natural; Next : out Natural) is
      Close : Natural;
      Rest  : Unbounded_String;
      Sp : Natural := Index (Head, " ");
   begin
      Block_End (Set, L, Last, Close, Rest);
      Next := Close + 1;
      if Sp = 0 then
         Sp := Head'Last + 1;
      end if;
      declare
         Kw  : constant String := To_Lower (Head (Head'First .. Sp - 1));
         Arg : constant String := Trim (Head (Sp .. Head'Last), Ada.Strings.Both);
         Is_Cond : Boolean;
         Cond : Boolean;
         R : constant String := To_String (Rest);
         Else_Close : Natural := 0;
         Else_Rest : Unbounded_String;
      begin
         if R'Length >= 4 and then To_Lower (R (R'First .. R'First + 3)) = "else"
         then
            if R (R'Last) /= '{' then
               raise Asm_Error with "else needs {";
            end if;
            Block_End (Set, Close, Last, Else_Close, Else_Rest);
            Next := Else_Close + 1;
         elsif R /= "" then
            raise Asm_Error with "unexpected text after }";
         end if;

         if Kw = "!macro" then
            declare
               Parts : constant Text_Vectors.Vector :=
                 Split (Arg, ',');
               First : constant String := Parts (1);
               Sp2 : constant Natural := Index (First, " ");
               M : Macro_Rec;
               Name : constant String :=
                 (if Sp2 = 0 then First else First (First'First .. Sp2 - 1));
            begin
               if Sp2 /= 0 then
                  M.Params.Append
                    (Trim (First (Sp2 .. First'Last), Ada.Strings.Both));
               end if;
               for K in 2 .. Natural (Parts.Length) loop
                  M.Params.Append (Parts (K));
               end loop;
               for J in L + 1 .. Close - 1 loop
                  M.Lines.Append (Set.Text (J));
               end loop;
               Macros.Include (Name, M);
            end;
            return;
         elsif Kw = "!for" then
            declare
               Parts : constant Text_Vectors.Vector := Split (Arg, ',');
               Var : constant String := Parts (1);
               From, To : Integer;
            begin
               if Parts.Length = 2 then
                  From := 1;
                  To := Must_Eval (Parts (2));
               elsif Parts.Length = 3 then
                  From := Must_Eval (Parts (2));
                  To := Must_Eval (Parts (3));
               else
                  raise Asm_Error with "!for var, first, last {";
               end if;
               for I in From .. To loop
                  Define (Var, I, False, True);
                  Process (Set, L + 1, Close - 1);
               end loop;
            end;
            return;
         elsif Kw in "!zone" | "!zn" then
            declare
               Saved : constant Unbounded_String := Zone_Scope;
            begin
               Zone_Count := Zone_Count + 1;
               Zone_Scope := To_Unbounded_String ("z" & Zone_Count'Image);
               Process (Set, L + 1, Close - 1);
               Zone_Scope := Saved;
            end;
            return;
         end if;

         Cond := Block_Cond (Head, Is_Cond);
         if not Is_Cond then
            raise Asm_Error with "unknown block " & Kw;
         end if;
         if Cond then
            Process (Set, L + 1, Close - 1);
         elsif Else_Close > 0 then
            Process (Set, Close + 1, Else_Close - 1);
         end if;
      end;
   end Block;

   procedure Process (Set : Line_Set; First, Last : Natural) is
      L : Natural := First;
      Next : Natural;
   begin
      while L <= Last loop
         Cur_File := Set.File (L);
         Cur_Line := Set.Line (L);
         declare
            T : constant String := Strip (Set.Text (L));
         begin
            Next := L + 1;
            if T'Length > 0 and then T (T'Last) = '{' then
               begin
                  Block (Set, L, Trim (T (T'First .. T'Last - 1),
                         Ada.Strings.Both), Last, Next);
               exception
                  when E : Asm_Error =>
                     Cur_File := Set.File (L);
                     Cur_Line := Set.Line (L);
                     Error (Exception_Message (E));
               end;
            elsif T'Length > 0 and then T (T'First) = '}' then
               Error ("unexpected }");
            elsif T'Length > 0 then
               Line_Statements (T);
            end if;
         end;
         L := Next;
      end loop;
   end Process;

   ---------------------------------------------------------------------
   --  Results
   ---------------------------------------------------------------------

   type Sym_Entry is record
      Name  : Unbounded_String;
      Value : Integer;
   end record;
   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Sym_Entry);
   Sym_List : Entry_Vectors.Vector;
   package Addr_Maps is new Ada.Containers.Ordered_Maps
     (Integer, Unbounded_String);
   Labels : Addr_Maps.Map;

   procedure Assemble (Path : String) is
      Full : constant String :=
        (if Ada.Directories.Exists (Path)
         then Ada.Directories.Full_Name (Path) else Path);
   begin
      Files.Clear;
      Cache.Clear;
      Symbols.Clear;
      Macros.Clear;
      Plus_Prev.Clear;
      Sym_List.Clear;
      Labels.Clear;
      for P in 1 .. Max_Passes loop
         Pass := P;
         PC := 16#0801#;
         Changed := False;
         Errors.Clear;
         Used := (others => False);
         Map := (others => (0, 0, False));
         Low := -1;
         High := -1;
         Start := -1;
         Basic := False;
         Plain := False;
         Out_Name := Null_Unbounded_String;
         Init_Fill := 0;
         Cur_File := 0;
         Cur_Line := 0;
         Depth := 0;
         Zone_Scope := To_Unbounded_String ("z0");
         Cheap_Scope := Null_Unbounded_String;
         Zone_Count := 0;
         Macro_Count := 0;
         Plus_Cur.Clear;
         Minus_Last.Clear;
         begin
            declare
               S : constant Line_Set := Load (Full);
            begin
               Process (S, 1, Natural (S.Text.Length));
            end;
         exception
            when E : Asm_Error =>
               Error (Exception_Message (E));
               exit;
         end;
         Plus_Prev := Plus_Cur;
         exit when not Changed;
         if P = Max_Passes then
            Error ("symbol values do not settle (" & P'Image & " passes)");
         end if;
      end loop;
      if Start < 0 then
         Start := Low;
      end if;
      --  Symbol list and address -> label map (globals preferred)
      for C in Symbols.Iterate loop
         declare
            S : constant Sym := Sym_Maps.Element (C);
         begin
            Sym_List.Append ((S.Display, S.Value));
            if S.Label then
               declare
                  N : constant String := To_String (S.Display);
                  Global : constant Boolean :=
                    N (N'First) /= '.' and then N (N'First) /= '@';
               begin
                  if Global or else not Labels.Contains (S.Value) then
                     if not (Labels.Contains (S.Value) and then Global
                             and then To_String (Labels (S.Value)) (1)
                               not in '.' | '@')
                     then
                        Labels.Include (S.Value, S.Display);
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Assemble;

   function Error_Count return Natural is (Natural (Errors.Length));
   function Has_Errors return Boolean is
     (for some E of Errors => not E.Warn);
   function Error_File (I : Positive) return String is
     (if Errors (I).File in 1 .. Natural (Files.Length)
      then Files (Errors (I).File) else "");
   function Error_Line (I : Positive) return Natural is (Errors (I).Line);
   function Error_Text (I : Positive) return String is
     (To_String (Errors (I).Text));
   function Is_Warning (I : Positive) return Boolean is (Errors (I).Warn);

   function Has_Output return Boolean is (Low >= 0);
   function Low_Address return Word is (Word (Integer'Max (Low, 0)));
   function High_Address return Word is (Word (Integer'Max (High, 0)));
   function Output_Byte (A : Word) return Byte is
     (if Used (Natural (A)) then Mem (Natural (A)) else Init_Fill);
   function Start_Address return Word is (Word (Integer'Max (Start, 0)));
   function Has_Basic_Stub return Boolean is (Basic);
   function Output_Name return String is (To_String (Out_Name));

   procedure Write_PRG (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      if Low < 0 then
         return;
      end if;
      Create (F, Out_File, Path);
      if not Plain then
         Byte'Write (Stream (F), Byte (Low mod 256));
         Byte'Write (Stream (F), Byte (Low / 256));
      end if;
      for A in Low .. High loop
         Byte'Write (Stream (F), Output_Byte (Word (A)));
      end loop;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Write_PRG;

   procedure Write_Labels (Path : String; Ok : out Boolean) is
      use Ada.Text_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Path);
      for C in Labels.Iterate loop
         if Addr_Maps.Key (C) in 0 .. 65535 then
            Put_Line (F, "al C:" &
                        To_Lower (Hex4 (Word (Addr_Maps.Key (C)))) & " " &
                        (if To_String (Addr_Maps.Element (C)) (1) = '.'
                         then "" else ".") &
                        To_String (Addr_Maps.Element (C)));
         end if;
      end loop;
      Close (F);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Write_Labels;

   function File_Count return Natural is (Natural (Files.Length));
   function File_Name (I : Positive) return String is (Files (I));

   function Is_Code (A : Word) return Boolean is (Map (Natural (A)).Code);

   procedure Line_Of (A : Word; File : out Natural; Line : out Natural) is
   begin
      File := Map (Natural (A)).File;
      Line := Map (Natural (A)).Line;
   end Line_Of;

   procedure Address_Of (File : String; Line : Positive;
                         Found : out Boolean; A : out Word;
                         Code_Only : Boolean := False) is
      Idx : Natural := 0;
   begin
      Found := False;
      A := 0;
      for I in 1 .. Natural (Files.Length) loop
         if Files (I) = File then
            Idx := I;
         end if;
      end loop;
      if Idx = 0 then
         return;
      end if;
      for X in Map'Range loop
         if Map (X).File = Idx and then Map (X).Line = Line
           and then (Map (X).Code or else not Code_Only)
         then
            Found := True;
            A := Word (X);
            return;
         end if;
      end loop;
   end Address_Of;

   function Label_At (A : Word) return String is
     (if Labels.Contains (Integer (A)) then To_String (Labels (Integer (A)))
      else "");

   function Symbol_Count return Natural is (Natural (Sym_List.Length));
   function Symbol_Name (I : Positive) return String is
     (To_String (Sym_List (I).Name));
   function Symbol_Value (I : Positive) return Integer is (Sym_List (I).Value);

   function Lookup (Name : String; Value : out Integer) return Boolean is
   begin
      if Symbols.Contains (Name) then
         Value := Symbols (Name).Value;
         return True;
      end if;
      Value := 0;
      return False;
   end Lookup;

   function Is_Source (Path : String) return Boolean is
      L : constant String := To_Lower (Path);
      function Ends (E : String) return Boolean is
        (L'Length > E'Length and then L (L'Last - E'Length + 1 .. L'Last) = E);
   begin
      return Ends (".asm") or else Ends (".a") or else Ends (".s")
        or else Ends (".src") or else Ends (".a65");
   end Is_Source;

   function Strip_Ext (P : String) return String is
      Dot : constant Natural := Index (P, ".", Ada.Strings.Backward);
      Sl  : constant Natural := Index (P, "/", Ada.Strings.Backward);
   begin
      return (if Dot > Sl then P (P'First .. Dot - 1) else P);
   end Strip_Ext;

   function Default_Output (Source : String) return String is
     (if Length (Out_Name) > 0 then To_String (Out_Name)
      else Strip_Ext (Source) & ".prg");

   procedure Build (Source : String; PRG : out Ada_String; Ok : out Boolean)
   is
      Dummy : Boolean;
   begin
      Assemble (Source);
      if Report /= null then
         for I in 1 .. Error_Count loop
            Report.all
              ((if Error_File (I) = "" then Source else Error_File (I)) & ":"
               & Trim (Error_Line (I)'Image, Ada.Strings.Left) & ": "
               & (if Is_Warning (I) then "warning: " else "error: ")
               & Error_Text (I));
         end loop;
      end if;
      PRG := To_Unbounded_String (Default_Output (Source));
      Ok := not Has_Errors and then Has_Output;
      if Ok then
         Write_PRG (To_String (PRG), Ok);
         if Ok then
            Write_Labels (Strip_Ext (To_String (PRG)) & ".lbl", Dummy);
         end if;
         if Report /= null then
            Report.all
              ((if Ok then "wrote " else "cannot write ") & To_String (PRG)
               & " ($" & Hex4 (Low_Address) & "-$" & Hex4 (High_Address)
               & "," & Natural'Image (High - Low + 1) & " bytes)");
         end if;
      elsif Report /= null and then not Has_Errors then
         Report.all ("no code generated");
      end if;
   end Build;

begin
   Build_Ops;
end Asm;
