# minimal 6502 disassembler: dis.py file base start end
import sys
M="BRK ORA KIL SLO NOP ORA ASL SLO PHP ORA ASL ANC NOP ORA ASL SLO BPL ORA KIL SLO NOP ORA ASL SLO CLC ORA NOP SLO NOP ORA ASL SLO JSR AND KIL RLA BIT AND ROL RLA PLP AND ROL ANC BIT AND ROL RLA BMI AND KIL RLA NOP AND ROL RLA SEC AND NOP RLA NOP AND ROL RLA RTI EOR KIL SRE NOP EOR LSR SRE PHA EOR LSR ALR JMP EOR LSR SRE BVC EOR KIL SRE NOP EOR LSR SRE CLI EOR NOP SRE NOP EOR LSR SRE RTS ADC KIL RRA NOP ADC ROR RRA PLA ADC ROR ARR JMP ADC ROR RRA BVS ADC KIL RRA NOP ADC ROR RRA SEI ADC NOP RRA NOP ADC ROR RRA NOP STA NOP SAX STY STA STX SAX DEY NOP TXA ANE STY STA STX SAX BCC STA KIL SHA STY STA STX SAX TYA STA TXS TAS SHY STA SHX SHA LDY LDA LDX LAX LDY LDA LDX LAX TAY LDA TAX LXA LDY LDA LDX LAX BCS LDA KIL LAX LDY LDA LDX LAX CLV LDA TSX LAS LDY LDA LDX LAX CPY CMP NOP DCP CPY CMP DEC DCP INY CMP DEX SBX CPY CMP DEC DCP BNE CMP KIL DCP NOP CMP DEC DCP CLD CMP NOP DCP NOP CMP DEC DCP CPX SBC NOP ISC CPX SBC INC ISC INX SBC NOP SBC CPX SBC INC ISC BEQ SBC KIL ISC NOP SBC INC ISC SED SBC NOP ISC NOP SBC INC ISC".split()
def mode(op):
    r,c=op>>4,op&15
    if r%2==0:
        if c==0: return 'imm' if r>=8 else ('abs' if r==2 else 'imp')
        if c in(1,3): return 'izx'
        if c==2: return 'imm' if r>=8 else 'imp'
        if 4<=c<=7: return 'zp'
        if c in (8,10): return 'imp'
        if c in (9,11): return 'imm'
        return 'ind' if op==0x6c else 'abs'
    if c==0: return 'rel'
    if c in(1,3): return 'izy'
    if c==2: return 'imp'
    if 4<=c<=7: return 'zpy' if op in(0x96,0x97,0xb6,0xb7) else 'zpx'
    if c in(8,10): return 'imp'
    if c in(9,11): return 'aby'
    return 'aby' if op in(0x9e,0x9f,0xbe,0xbf) else 'abx'
L={'imp':1,'imm':2,'zp':2,'zpx':2,'zpy':2,'izx':2,'izy':2,'rel':2,'abs':3,'abx':3,'aby':3,'ind':3}
F={'imp':'','imm':'#$%02X','zp':'$%02X','zpx':'$%02X,X','zpy':'$%02X,Y','izx':'($%02X,X)','izy':'($%02X),Y','abs':'$%04X','abx':'$%04X,X','aby':'$%04X,Y','ind':'($%04X)'}
d=open(sys.argv[1],'rb').read(); base=int(sys.argv[2],16); pc=int(sys.argv[3],16); end=int(sys.argv[4],16)
while pc<end:
    op=d[pc-base]; m=mode(op); n=L[m]; b=d[pc-base:pc-base+n]
    if m=='rel': arg='$%04X'%((pc+2+(b[1]-256 if b[1]>127 else b[1]))&0xffff)
    elif n==2: arg=F[m]%b[1]
    elif n==3: arg=F[m]%(b[1]|b[2]<<8)
    else: arg=''
    print('%04X  %-9s %s %s'%(pc,b.hex(),M[op],arg)); pc+=n
