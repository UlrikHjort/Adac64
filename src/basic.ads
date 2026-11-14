--  Commodore BASIC tokenizer / detokenizer (BASIC V2 for the C64,
--  BASIC 7.0 for the C128).
--
--  Text form (as with petcat): one numbered line per text line,
--  keywords in any case; inside strings lower-case letters are the normal
--  (unshifted) PETSCII letters and upper-case letters the shifted ones.
--  Control and other special characters are written in braces:
--    {clr} {home} {up} {down} {left} {rght} {rvon} {rvof} {del} {inst}
--    {blk} {wht} {red} {cyn} {pur} {grn} {blu} {yel} {orng} {brn} {lred}
--    {gry1} {gry2} {lgrn} {lblu} {gry3} {f1}..{f8} {ret} {sret} {lower}
--    {upper} {pi} {pound} {$xx} (any byte), with repeats {3 down} {down*3}
--  "?" is PRINT, "^" the power operator ("↑"), "_" is "←", "£" also works.

with Types; use Types;
with Ada.Strings.Unbounded;

package Basic is

   type Dialect is (V2, V7);   --  C64 BASIC 2.0, C128 BASIC 7.0

   function Is_Source (Path : String) return Boolean;   --  .bas
   function Load_Address (D : Dialect) return Word is
     (if D = V2 then 16#0801# else 16#1C01#);

   procedure Tokenize_File (Path : String; D : Dialect);
   procedure Tokenize_Text (Text : String; D : Dialect);
   --  Results:
   function Error_Count return Natural;
   function Error_Line (I : Positive) return Natural;   --  source line
   function Error_Text (I : Positive) return String;
   function Program_Length return Natural;            --  bytes after load
   function Program_Byte (I : Natural) return Byte;   --  0-based
   function Program_Load return Word;
   function Source_Line_Of (Basic_Line : Natural) return Natural;
   --  Text line (1-based) of a BASIC line number (0: none).

   procedure Build (Source : String; D : Dialect;
                    PRG : out Ada.Strings.Unbounded.Unbounded_String;
                    Ok : out Boolean);
   --  Tokenize Source and write Source with .prg; messages to Report.
   type Report_Proc is access procedure (Line : String);
   Report : Report_Proc := null;

   type Reader is access function (Addr : Word) return Byte;
   function Detokenize (Read : not null Reader; Load : Word; D : Dialect)
                        return String;
   --  List the program linked from Load (memory read through Read).

   function List_PRG (Path : String; Ok : out Boolean) return String;
   --  Detokenize a .prg file (dialect from its load address).

end Basic;
