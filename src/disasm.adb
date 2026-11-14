with Interfaces; use Interfaces;

package body Disasm is

   Digits16 : constant String := "0123456789ABCDEF";

   function Hex2 (B : Byte) return String is
     (Digits16 (Natural (B / 16) + 1) & Digits16 (Natural (B mod 16) + 1));
   function Hex4 (W : Word) return String is (Hex2 (Hi (W)) & Hex2 (Lo (W)));

   Names : constant String :=
     "BRKORAJAMSLONOPORAASLSLOPHPORAASLANCNOPORAASLSLO" &
     "BPLORAJAMSLONOPORAASLSLOCLCORANOPSLONOPORAASLSLO" &
     "JSRANDJAMRLABITANDROLRLAPLPANDROLANCBITANDROLRLA" &
     "BMIANDJAMRLANOPANDROLRLASECANDNOPRLANOPANDROLRLA" &
     "RTIEORJAMSRENOPEORLSRSREPHAEORLSRALRJMPEORLSRSRE" &
     "BVCEORJAMSRENOPEORLSRSRECLIEORNOPSRENOPEORLSRSRE" &
     "RTSADCJAMRRANOPADCRORRRAPLAADCRORARRJMPADCRORRRA" &
     "BVSADCJAMRRANOPADCRORRRASEIADCNOPRRANOPADCRORRRA" &
     "NOPSTANOPSAXSTYSTASTXSAXDEYNOPTXAANESTYSTASTXSAX" &
     "BCCSTAJAMSHASTYSTASTXSAXTYASTATXSTASSHYSTASHXSHA" &
     "LDYLDALDXLAXLDYLDALDXLAXTAYLDATAXLXALDYLDALDXLAX" &
     "BCSLDAJAMLAXLDYLDALDXLAXCLVLDATSXLASLDYLDALDXLAX" &
     "CPYCMPNOPDCPCPYCMPDECDCPINYCMPDEXSBXCPYCMPDECDCP" &
     "BNECMPJAMDCPNOPCMPDECDCPCLDCMPNOPDCPNOPCMPDECDCP" &
     "CPXSBCNOPISCCPXSBCINCISCINXSBCNOPSBCCPXSBCINCISC" &
     "BEQSBCJAMISCNOPSBCINCISCSEDSBCNOPISCNOPSBCINCISC";

   subtype Mode is Addr_Mode;

   function Mnemonic (Op : Byte) return String is
     (Names (Natural (Op) * 3 + 1 .. Natural (Op) * 3 + 3));

   function Length_Of (M : Addr_Mode) return Natural is
     (case M is
        when Imp | Acc => 1,
        when Abso | AbsX | AbsY | Ind => 3,
        when others => 2);

   function Mode_Of (Op : Byte) return Mode is
      R : constant Natural := Natural (Op / 16);
      C : constant Natural := Natural (Op mod 16);
   begin
      if R mod 2 = 0 then
         case C is
            when 0 => return (if R >= 8 then Imm elsif R = 2 then Abso
                              else Imp);
            when 1 | 3 => return IndX;
            when 2 => return (if R >= 8 then Imm else Imp);
            when 4 .. 7 => return ZP;
            when 8 => return Imp;
            when 9 | 11 => return Imm;
            when 10 => return (if R < 8 then Acc else Imp);
            when others => return (if Op = 16#6C# then Ind else Abso);
         end case;
      else
         case C is
            when 0 => return Rel;
            when 1 | 3 => return IndY;
            when 2 | 8 | 10 => return Imp;
            when 4 .. 7 =>
               return (if Op in 16#96# | 16#97# | 16#B6# | 16#B7#
                       then ZPY else ZPX);
            when 9 | 11 => return AbsY;
            when others =>
               return (if Op in 16#9E# | 16#9F# | 16#BE# | 16#BF#
                       then AbsY else AbsX);
         end case;
      end if;
   end Mode_Of;

   procedure Disassemble (Read : Reader; Addr : Word;
                          Text : out String; Last : out Natural;
                          Length : out Natural)
   is
      Op : constant Byte := Read (Addr);
      M  : constant Mode := Mode_Of (Op);
      B1 : constant Byte := Read (Addr + 1);
      B2 : constant Byte := Read (Addr + 2);
      W  : constant Word := Make_Word (B1, B2);
      Mn : constant String :=
        Names (Natural (Op) * 3 + 1 .. Natural (Op) * 3 + 3);
      Arg : constant String :=
        (case M is
           when Imp => "",
           when Acc => "A",
           when Imm => "#$" & Hex2 (B1),
           when ZP => "$" & Hex2 (B1),
           when ZPX => "$" & Hex2 (B1) & ",X",
           when ZPY => "$" & Hex2 (B1) & ",Y",
           when Abso => "$" & Hex4 (W),
           when AbsX => "$" & Hex4 (W) & ",X",
           when AbsY => "$" & Hex4 (W) & ",Y",
           when IndX => "($" & Hex2 (B1) & ",X)",
           when IndY => "($" & Hex2 (B1) & "),Y",
           when Ind => "($" & Hex4 (W) & ")",
           when Rel =>
             "$" & Hex4 (Addr + 2 + (if B1 >= 16#80#
                                      then Word (B1) or 16#FF00#
                                      else Word (B1))));
      N : constant Natural :=
        (case M is
           when Imp | Acc => 1,
           when Abso | AbsX | AbsY | Ind => 3,
           when others => 2);
      Bytes : constant String :=
        Hex2 (Op) & (if N >= 2 then " " & Hex2 (B1) else "   ") &
        (if N = 3 then " " & Hex2 (B2) else "   ");
      Line : constant String :=
        Hex4 (Addr) & "  " & Bytes & "  " & Mn & (if Arg = "" then ""
                                                  else " " & Arg);
   begin
      Length := N;
      Last := Text'First + Line'Length - 1;
      Text (Text'First .. Last) := Line;
   end Disassemble;

end Disasm;
