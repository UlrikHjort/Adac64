-- ***************************************************************************
--                      AdaC64 - Basic
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

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Strings;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;
with Ada.Exceptions;

package body Basic is

   ---------------------------------------------------------------------
   --  Keywords
   ---------------------------------------------------------------------

   V2_Names : constant array (16#80# .. 16#CB#) of access constant String :=
     (new String'("end"), new String'("for"), new String'("next"),
      new String'("data"), new String'("input#"), new String'("input"),
      new String'("dim"), new String'("read"), new String'("let"),
      new String'("goto"), new String'("run"), new String'("if"),
      new String'("restore"), new String'("gosub"), new String'("return"),
      new String'("rem"), new String'("stop"), new String'("on"),
      new String'("wait"), new String'("load"), new String'("save"),
      new String'("verify"), new String'("def"), new String'("poke"),
      new String'("print#"), new String'("print"), new String'("cont"),
      new String'("list"), new String'("clr"), new String'("cmd"),
      new String'("sys"), new String'("open"), new String'("close"),
      new String'("get"), new String'("new"), new String'("tab("),
      new String'("to"), new String'("fn"), new String'("spc("),
      new String'("then"), new String'("not"), new String'("step"),
      new String'("+"), new String'("-"), new String'("*"),
      new String'("/"), new String'("^"), new String'("and"),
      new String'("or"), new String'(">"), new String'("="),
      new String'("<"), new String'("sgn"), new String'("int"),
      new String'("abs"), new String'("usr"), new String'("fre"),
      new String'("pos"), new String'("sqr"), new String'("rnd"),
      new String'("log"), new String'("exp"), new String'("cos"),
      new String'("sin"), new String'("tan"), new String'("atn"),
      new String'("peek"), new String'("len"), new String'("str$"),
      new String'("val"), new String'("asc"), new String'("chr$"),
      new String'("left$"), new String'("right$"), new String'("mid$"),
      new String'("go"));

   V7_Names : constant array (16#CC# .. 16#FD#) of access constant String :=
     (new String'("rgr"), new String'("rclr"), null, new String'("joy"),
      new String'("rdot"), new String'("dec"), new String'("hex$"),
      new String'("err$"), new String'("instr"), new String'("else"),
      new String'("resume"), new String'("trap"), new String'("tron"),
      new String'("troff"), new String'("sound"), new String'("vol"),
      new String'("auto"), new String'("pudef"), new String'("graphic"),
      new String'("paint"), new String'("char"), new String'("box"),
      new String'("circle"), new String'("gshape"), new String'("sshape"),
      new String'("draw"), new String'("locate"), new String'("color"),
      new String'("scnclr"), new String'("scale"), new String'("help"),
      new String'("do"), new String'("loop"), new String'("exit"),
      new String'("directory"), new String'("dsave"), new String'("dload"),
      new String'("header"), new String'("scratch"), new String'("collect"),
      new String'("copy"), new String'("rename"), new String'("backup"),
      new String'("delete"), new String'("renumber"), new String'("key"),
      new String'("monitor"), new String'("using"), new String'("until"),
      new String'("while"));

   --  $CE xx functions and $FE xx statements
   CE_Names : constant array (2 .. 10) of access constant String :=
     (new String'("pot"), new String'("bump"), new String'("pen"),
      new String'("rsppos"), new String'("rsprite"), new String'("rspcolor"),
      new String'("xor"), new String'("rwindow"), new String'("pointer"));

   FE_Names : constant array (2 .. 16#26#) of access constant String :=
     (new String'("bank"), new String'("filter"), new String'("play"),
      new String'("tempo"), new String'("movspr"), new String'("sprite"),
      new String'("sprcolor"), new String'("rreg"), new String'("envelope"),
      new String'("sleep"), new String'("catalog"), new String'("dopen"),
      new String'("append"), new String'("dclose"), new String'("bsave"),
      new String'("bload"), new String'("record"), new String'("concat"),
      new String'("dverify"), new String'("dclear"), new String'("sprsav"),
      new String'("collision"), new String'("begin"), new String'("bend"),
      new String'("window"), new String'("boot"), new String'("width"),
      new String'("sprdef"), new String'("quit"), new String'("stash"),
      null, new String'("fetch"), null, new String'("swap"),
      new String'("off"), new String'("fast"), new String'("slow"));

   ---------------------------------------------------------------------
   --  Control codes
   ---------------------------------------------------------------------

   type Code_Name is record
      Name : access constant String;
      Code : Byte;
   end record;

   function C (S : String; B : Byte) return Code_Name is ((new String'(S), B));

   Codes : constant array (Positive range <>) of Code_Name :=
     (C ("wht", 16#05#), C ("dish", 16#08#), C ("ensh", 16#09#),
      C ("ret", 16#0D#), C ("return", 16#0D#), C ("lower", 16#0E#),
      C ("down", 16#11#), C ("rvon", 16#12#), C ("rvs on", 16#12#),
      C ("home", 16#13#), C ("del", 16#14#), C ("red", 16#1C#),
      C ("rght", 16#1D#), C ("right", 16#1D#), C ("grn", 16#1E#),
      C ("blu", 16#1F#), C ("orng", 16#81#), C ("f1", 16#85#),
      C ("f3", 16#86#), C ("f5", 16#87#), C ("f7", 16#88#),
      C ("f2", 16#89#), C ("f4", 16#8A#), C ("f6", 16#8B#),
      C ("f8", 16#8C#), C ("sret", 16#8D#), C ("upper", 16#8E#),
      C ("blk", 16#90#), C ("up", 16#91#), C ("rvof", 16#92#),
      C ("rvs off", 16#92#), C ("clr", 16#93#), C ("inst", 16#94#),
      C ("brn", 16#95#), C ("lred", 16#96#), C ("gry1", 16#97#),
      C ("gry2", 16#98#), C ("lgrn", 16#99#), C ("lblu", 16#9A#),
      C ("gry3", 16#9B#), C ("pur", 16#9C#), C ("left", 16#9D#),
      C ("yel", 16#9E#), C ("cyn", 16#9F#), C ("pi", 16#FF#),
      C ("pound", 16#5C#), C ("space", 16#20#), C ("shift space", 16#A0#));

   ---------------------------------------------------------------------
   --  Results
   ---------------------------------------------------------------------

   type Err is record
      Line : Natural;
      Text : Unbounded_String;
   end record;
   package Err_Vectors is new Ada.Containers.Vectors (Positive, Err);
   Errors : Err_Vectors.Vector;

   type Line_Map is record
      Number, Source : Natural;
   end record;
   package Map_Vectors is new Ada.Containers.Vectors (Positive, Line_Map);
   Lines : Map_Vectors.Vector;

   Prog : Byte_Array (0 .. 65535) := (others => 0);
   Prog_Len : Natural := 0;
   Prog_Load : Word := 16#0801#;

   Bad_Input : exception;

   function Error_Count return Natural is (Natural (Errors.Length));
   function Error_Line (I : Positive) return Natural is (Errors (I).Line);
   function Error_Text (I : Positive) return String is
     (To_String (Errors (I).Text));
   function Program_Length return Natural is (Prog_Len);
   function Program_Byte (I : Natural) return Byte is (Prog (I));
   function Program_Load return Word is (Prog_Load);

   function Source_Line_Of (Basic_Line : Natural) return Natural is
   begin
      for L of Lines loop
         if L.Number = Basic_Line then
            return L.Source;
         end if;
      end loop;
      return 0;
   end Source_Line_Of;

   function Is_Source (Path : String) return Boolean is
     (Path'Length > 4
      and then To_Lower (Path (Path'Last - 3 .. Path'Last)) = ".bas");

   ---------------------------------------------------------------------
   --  Tokenizer
   ---------------------------------------------------------------------

   --  One tokenized line (without link / number / terminator)
   procedure Crunch (S : String; D : Dialect; Out_B : in out Byte_Array;
                     N : out Natural) is
      I : Natural := S'First;
      In_Quote, In_Rem, In_Data : Boolean := False;

      procedure Put (B : Byte) is
      begin
         if N >= Out_B'Length then
            raise Bad_Input with "line too long";
         end if;
         Out_B (Out_B'First + N) := B;
         N := N + 1;
      end Put;

      --  A plain character; Quoted: inside a string (case matters)
      procedure Put_Char (Ch : Character; Quoted : Boolean) is
         P : constant Natural := Character'Pos (Ch);
      begin
         if Ch in 'a' .. 'z' then
            Put (Byte (P - 32));
         elsif Ch in 'A' .. 'Z' then
            Put (if Quoted then Byte (P + 128) else Byte (P));
         elsif P in 32 .. 93 or else Ch = '_' or else Ch = '^' then
            Put (Byte (P));
         elsif Ch = '\' then
            Put (16#5C#);
         else
            raise Bad_Input with "character '" & Ch &
              "' not allowed (use {$xx})";
         end if;
      end Put_Char;

      --  {name}, {N name}, {name*N}, {$xx}
      procedure Brace is
         Close : constant Natural := Index (S (I .. S'Last), "}");
      begin
         if Close = 0 then
            raise Bad_Input with "missing }";
         end if;
         declare
            Inner : constant String :=
              To_Lower (Trim (S (I + 1 .. Close - 1), Ada.Strings.Both));
            Count : Natural := 1;
            Name  : Unbounded_String := To_Unbounded_String (Inner);
            Star  : constant Natural := Index (Inner, "*");
            Sp    : constant Natural := Index (Inner, " ");
            Found : Boolean := False;
         begin
            if Star > 0 then
               Name := To_Unbounded_String
                 (Trim (Inner (Inner'First .. Star - 1), Ada.Strings.Both));
               Count := Natural'Value (Inner (Star + 1 .. Inner'Last));
            elsif Sp > 0 and then Is_Digit (Inner (Inner'First)) then
               Count := Natural'Value (Inner (Inner'First .. Sp - 1));
               Name := To_Unbounded_String
                 (Trim (Inner (Sp + 1 .. Inner'Last), Ada.Strings.Both));
            end if;
            declare
               Nm : constant String := To_String (Name);
               B  : Byte := 0;
            begin
               if Nm'Length >= 2 and then Nm (Nm'First) = '$' then
                  B := Byte'Value ("16#" & Nm (Nm'First + 1 .. Nm'Last) & "#");
                  Found := True;
               elsif Nm'Length >= 1 and then (for all X of Nm => Is_Digit (X))
               then
                  B := Byte'Value (Nm);
                  Found := True;
               else
                  for Cd of Codes loop
                     if Cd.Name.all = Nm then
                        B := Cd.Code;
                        Found := True;
                        exit;
                     end if;
                  end loop;
               end if;
               if not Found then
                  raise Bad_Input with "unknown code {" & Nm & "}";
               end if;
               for R in 1 .. Count loop
                  Put (B);
               end loop;
            end;
         exception
            when Constraint_Error =>
               raise Bad_Input with "bad code {" & Inner & "}";
         end;
         I := Close + 1;
      end Brace;

      --  Longest keyword at I; Code = 0 when none
      procedure Match (Len : out Natural; Code : out Natural) is
         procedure Try (Name : access constant String; Cd : Natural) is
         begin
            if Name /= null and then Name'Length > Len
              and then I + Name'Length - 1 <= S'Last
              and then To_Lower (S (I .. I + Name'Length - 1)) = Name.all
            then
               Len := Name'Length;
               Code := Cd;
            end if;
         end Try;
      begin
         Len := 0;
         Code := 0;
         for T in V2_Names'Range loop
            Try (V2_Names (T), T);
         end loop;
         if D = V7 then
            for T in V7_Names'Range loop
               Try (V7_Names (T), T);
            end loop;
            for T in CE_Names'Range loop
               Try (CE_Names (T), 16#CE00# + T);
            end loop;
            for T in FE_Names'Range loop
               Try (FE_Names (T), 16#FE00# + T);
            end loop;
         end if;
      end Match;

      UTF : Natural;
   begin
      N := 0;
      while I <= S'Last loop
         declare
            Ch : constant Character := S (I);
         begin
            --  UTF-8 for £ π ← ↑
            UTF := 0;
            if Character'Pos (Ch) >= 16#C0# then
               if I + 1 <= S'Last and then S (I .. I + 1) = "£" then
                  Put (16#5C#);
                  UTF := 2;
               elsif I + 1 <= S'Last and then S (I .. I + 1) = "π" then
                  Put (16#FF#);
                  UTF := 2;
               elsif I + 2 <= S'Last and then S (I .. I + 2) = "←" then
                  Put (16#5F#);
                  UTF := 3;
               elsif I + 2 <= S'Last and then S (I .. I + 2) = "↑" then
                  Put (if In_Quote or In_Rem then 16#5E# else 16#AE#);
                  UTF := 3;
               else
                  raise Bad_Input with "unsupported character (use {$xx})";
               end if;
            end if;
            if UTF > 0 then
               I := I + UTF;
            elsif Ch = '{' then
               Brace;
            elsif In_Quote then
               if Ch = '"' then
                  In_Quote := False;
               end if;
               Put_Char (Ch, True);
               I := I + 1;
            elsif In_Rem then
               Put_Char (Ch, True);
               I := I + 1;
            elsif Ch = '"' then
               In_Quote := True;
               Put (16#22#);
               I := I + 1;
            elsif In_Data then
               if Ch = ':' then
                  In_Data := False;
               end if;
               Put_Char (Ch, False);
               I := I + 1;
            elsif Ch = '?' then
               Put (16#99#);
               I := I + 1;
            else
               declare
                  Len, Code : Natural;
               begin
                  Match (Len, Code);
                  if Len > 0 then
                     if Code > 16#FF# then
                        Put (Byte (Code / 256));
                        Put (Byte (Code mod 256));
                     else
                        Put (Byte (Code));
                     end if;
                     In_Rem := Code = 16#8F#;
                     In_Data := Code = 16#83#;
                     I := I + Len;
                  else
                     Put_Char (Ch, False);
                     I := I + 1;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Crunch;

   procedure Tokenize_Text (Text : String; D : Dialect) is
      Line_No : Natural := 0;
      From : Positive := Text'First;
      Last_Number : Integer := -1;
      Addr : Natural := Natural (Load_Address (D));

      procedure Error (Msg : String) is
      begin
         Errors.Append ((Line_No, To_Unbounded_String (Msg)));
      end Error;

      procedure Do_Line (Raw : String) is
         L : constant String := Trim (Raw, Ada.Strings.Both);
         P : Natural := L'First;
         Num : Natural := 0;
         Buf : Byte_Array (0 .. 254);
         N : Natural;
      begin
         if L = "" then
            return;
         end if;
         while P <= L'Last and then Is_Digit (L (P)) loop
            Num := Num * 10 + (Character'Pos (L (P)) - 48);
            P := P + 1;
            if Num > 63999 then
               Error ("line number too large");
               return;
            end if;
         end loop;
         if P = L'First then
            Error ("line number expected");
            return;
         end if;
         if Num <= Last_Number then
            Error ("line" & Num'Image & " is not after line" &
                   Last_Number'Image);
            return;
         end if;
         Last_Number := Num;
         while P <= L'Last and then L (P) = ' ' loop
            P := P + 1;
         end loop;
         begin
            Crunch (L (P .. L'Last), D, Buf, N);
         exception
            when E : Bad_Input =>
               Error (Ada.Exceptions.Exception_Message (E));
               return;
         end;
         if N > 250 then
            Error ("line longer than 250 bytes");
         end if;
         --  link, number, text, 0
         declare
            Next : constant Natural := Addr + 4 + N + 1;
            Off  : constant Natural := Addr - Natural (Load_Address (D));
         begin
            if Off + 4 + N + 1 + 2 > Prog'Length then
               Error ("program too large");
               return;
            end if;
            Prog (Off) := Byte (Next mod 256);
            Prog (Off + 1) := Byte (Next / 256);
            Prog (Off + 2) := Byte (Num mod 256);
            Prog (Off + 3) := Byte (Num / 256);
            Prog (Off + 4 .. Off + 3 + N) := Buf (0 .. N - 1);
            Prog (Off + 4 + N) := 0;
            Addr := Next;
            Lines.Append ((Num, Line_No));
         end;
      end Do_Line;
   begin
      Errors.Clear;
      Lines.Clear;
      Prog_Load := Load_Address (D);
      for I in Text'Range loop
         if Text (I) = ASCII.LF or else I = Text'Last then
            Line_No := Line_No + 1;
            declare
               Stop : Natural := (if Text (I) = ASCII.LF then I - 1 else I);
            begin
               if Stop >= From and then Text (Stop) = ASCII.CR then
                  Stop := Stop - 1;
               end if;
               Do_Line (Text (From .. Stop));
            end;
            From := I + 1;
         end if;
      end loop;
      declare
         Off : constant Natural := Addr - Natural (Load_Address (D));
      begin
         Prog (Off) := 0;
         Prog (Off + 1) := 0;
         Prog_Len := Off + 2;
      end;
   end Tokenize_Text;

   procedure Tokenize_File (Path : String; D : Dialect) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Open (F, In_File, Path);
      declare
         S : String (1 .. Natural (Size (F)));
      begin
         String'Read (Stream (F), S);
         Close (F);
         Tokenize_Text (S, D);
      end;
   exception
      when Name_Error | Use_Error =>
         Errors.Clear;
         Errors.Append ((0, To_Unbounded_String ("cannot open " & Path)));
         Prog_Len := 0;
   end Tokenize_File;

   procedure Build (Source : String; D : Dialect;
                    PRG : out Unbounded_String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Out_Path : constant String :=
        Source (Source'First .. Source'Last - 4) & ".prg";
   begin
      Tokenize_File (Source, D);
      PRG := To_Unbounded_String (Out_Path);
      if Report /= null then
         for I in 1 .. Error_Count loop
            Report.all (Source & ":" &
                          Trim (Error_Line (I)'Image, Ada.Strings.Left) &
                          ": error: " & Error_Text (I));
         end loop;
      end if;
      Ok := Error_Count = 0;
      if not Ok then
         return;
      end if;
      Create (F, Out_File, Out_Path);
      Byte'Write (Stream (F), Byte (Prog_Load mod 256));
      Byte'Write (Stream (F), Byte (Prog_Load / 256));
      for I in 0 .. Prog_Len - 1 loop
         Byte'Write (Stream (F), Prog (I));
      end loop;
      Close (F);
      if Report /= null then
         Report.all ("wrote " & Out_Path & " (" &
                       Trim (Natural (Lines.Length)'Image, Ada.Strings.Left) &
                       " lines," & Prog_Len'Image & " bytes, BASIC " &
                       (if D = V2 then "V2" else "7.0") & ")");
      end if;
   exception
      when others =>
         Ok := False;
         if Report /= null then
            Report.all ("cannot write " & Out_Path);
         end if;
   end Build;

   ---------------------------------------------------------------------
   --  Detokenizer
   ---------------------------------------------------------------------

   function Hex2 (B : Byte) return String is
      H : constant String := "0123456789abcdef";
   begin
      return H (Natural (B / 16) + 1) & H (Natural (B mod 16) + 1);
   end Hex2;

   function Char_Text (B : Byte; Quoted : Boolean) return String is
   begin
      case B is
         when 16#41# .. 16#5A# =>
            return (1 => Character'Val (B + 32));
         when 16#C1# .. 16#DA# =>
            return (1 => Character'Val (B - 128));
         when 16#20# .. 16#40# | 16#5B# | 16#5D# =>
            return (1 => Character'Val (B));
         when 16#5C# =>
            return "£";
         when 16#5E# =>
            return "^";
         when 16#5F# =>
            return "_";
         when 16#7B# | 16#7D# =>
            return "{$" & Hex2 (B) & "}";
         when 16#FF# =>
            return "{pi}";
         when others =>
            if Quoted or else B < 16#20# then
               for Cd of Codes loop
                  if Cd.Code = B and then Cd.Code /= 16#20#
                    and then Cd.Code /= 16#5C#
                  then
                     return "{" & Cd.Name.all & "}";
                  end if;
               end loop;
            end if;
            return "{$" & Hex2 (B) & "}";
      end case;
   end Char_Text;

   function Detokenize (Read : not null Reader; Load : Word; D : Dialect)
                        return String is
      R : Unbounded_String;
      P : Natural := Natural (Load);
      function Rd (A : Natural) return Byte is (Read (Word (A mod 65536)));
   begin
      for Count in 1 .. 10_000 loop
         declare
            Link : constant Natural :=
              Natural (Rd (P)) + 256 * Natural (Rd (P + 1));
            Num  : constant Natural :=
              Natural (Rd (P + 2)) + 256 * Natural (Rd (P + 3));
            Q : Natural := P + 4;
            In_Quote, In_Rem : Boolean := False;
            B : Byte;
         begin
            exit when Link = 0 or else Link <= P or else Link > 65535;
            Append (R, Trim (Num'Image, Ada.Strings.Left) & " ");
            loop
               B := Rd (Q);
               exit when B = 0 or else Q >= Link;
               Q := Q + 1;
               if In_Quote or else In_Rem then
                  if B = 16#22# then
                     In_Quote := False;
                  end if;
                  declare
                     T : constant String := Char_Text (B, True);
                     Run : Natural := 1;
                  begin
                     if T'Length > 2 and then T (T'First) = '{'
                       and then T (T'First + 1) /= '$'
                     then
                        while Q < Link and then Rd (Q) = B loop
                           Run := Run + 1;
                           Q := Q + 1;
                        end loop;
                     end if;
                     if Run > 1 then
                        Append (R, "{" & Trim (Run'Image, Ada.Strings.Left)
                                & " " & T (T'First + 1 .. T'Last));
                     else
                        Append (R, T);
                     end if;
                  end;
               elsif B = 16#22# then
                  In_Quote := True;
                  Append (R, '"');
               elsif Natural (B) in V2_Names'Range then
                  Append (R, V2_Names (Natural (B)).all);
                  In_Rem := B = 16#8F#;
               elsif D = V7 and then B in 16#CE# | 16#FE# then
                  declare
                     X : constant Natural := Natural (Rd (Q));
                  begin
                     Q := Q + 1;
                     if B = 16#CE# and then X in CE_Names'Range then
                        Append (R, CE_Names (X).all);
                     elsif B = 16#FE# and then X in FE_Names'Range
                       and then FE_Names (X) /= null
                     then
                        Append (R, FE_Names (X).all);
                     else
                        Append (R, "{$" & Hex2 (B) & "}{$" &
                                  Hex2 (Byte (X)) & "}");
                     end if;
                  end;
               elsif D = V7 and then Natural (B) in V7_Names'Range
                 and then V7_Names (Natural (B)) /= null
               then
                  Append (R, V7_Names (Natural (B)).all);
               else
                  Append (R, Char_Text (B, False));
               end if;
            end loop;
            Append (R, ASCII.LF);
            P := Link;
         end;
      end loop;
      return To_String (R);
   end Detokenize;

   File_Data : Byte_Array (0 .. 65535);
   File_Load : Natural := 0;
   File_Len  : Natural := 0;

   function File_Read (A : Word) return Byte is
     (if Natural (A) >= File_Load and then Natural (A) < File_Load + File_Len
      then File_Data (Natural (A) - File_Load) else 0);

   function List_PRG (Path : String; Ok : out Boolean) return String is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Lo, Hi : Byte;
   begin
      Open (F, In_File, Path);
      Byte'Read (Stream (F), Lo);
      Byte'Read (Stream (F), Hi);
      File_Load := Natural (Lo) + 256 * Natural (Hi);
      File_Len := 0;
      while not End_Of_File (F) and then File_Len < File_Data'Length loop
         Byte'Read (Stream (F), File_Data (File_Len));
         File_Len := File_Len + 1;
      end loop;
      Close (F);
      Ok := True;
      return Detokenize (File_Read'Access, Word (File_Load),
                         (if File_Load = 16#1C01# then V7 else V2));
   exception
      when others =>
         Ok := False;
         return "";
   end List_PRG;

end Basic;
