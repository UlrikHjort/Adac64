; Final Expansion 3 test image: placed at flash $6000 (block 5, bank 0 in
; start mode). Copies its test to $1000 and runs it there, since the test
; switches block 5 away. Results in $f0-$fa, $900F = $2e at the end:
;   $f0 = $a0  register A reads back
;   $f1 = $11  super RAM bank 0 kept apart from bank 1
;   $f2 = $22  RAM 1 mode reads bank 1
;   $f3 = $01, $f4 = $a4  flash autoselect: AMD 29F040
;   $f5 = $5a  flash byte programmed
;   $f6 = $ff  flash sector erased
;   $f7 = $00  a register write while locked is ignored
;   $f8 = $33  A13 inversion
;   $f9 = $44  RAM123
;   $fa = $44  RAM123 read-only
rega = $9c02
regb = $9c03
        *= $a000
        !word start, start
        !byte $41, $30, $c3, $c2, $cd     ; "A0CBM"
start   sei
        ldx #0
-       lda test,x
        sta $1000,x
        inx
        bne -
        jmp $1000

test
        !pseudopc $1000 {
        sta $a000       ; a block 5 write unlocks the registers
        lda #$a0        ; super RAM, bank 0
        sta rega
        lda rega
        sta $f0
        lda #$11
        sta $2000
        lda #$a1        ; bank 1
        sta rega
        lda #$22
        sta $2000
        lda #$a0
        sta rega
        lda $2000
        sta $f1
        lda #$80        ; RAM 1 mode: blocks read bank 1
        sta rega
        lda $2000
        sta $f2
        lda #$20        ; flash mode, bank 0
        sta rega
        jsr unlock
        lda #$90        ; autoselect
        sta $2555
        lda $2000
        sta $f3
        lda $2001
        sta $f4
        lda #$f0        ; back to reading
        sta $2000
        jsr unlock
        lda #$a0        ; program a byte
        sta $2555
        lda #$5a
        sta $2100
        lda $2100
        sta $f5
        jsr unlock
        lda #$80        ; erase...
        sta $2555
        jsr unlock
        lda #$30        ; ...sector 0
        sta $2000
-       lda $2000       ; until DQ6 stops toggling
        cmp $2000
        bne -
        lda $2100
        sta $f6
        lda #$00        ; start mode
        sta rega
        lda $a000       ; a block 5 read locks them
        lda #$80
        sta rega        ; ignored
        sta $a000       ; unlock
        lda rega
        sta $f7
        lda #$a0        ; super RAM, A13 inverted: $2000 is RAM $2000
        sta rega
        lda #$20
        sta regb
        lda #$33
        sta $2000
        lda #$00
        sta regb
        lda $4000       ; block 2 = RAM $2000
        sta $f8
        lda #$80        ; RAM 1 mode, RAM123 writable
        sta rega
        lda #$44
        sta $0400
        lda $0400
        sta $f9
        lda #$81        ; RAM123 read-only
        sta rega
        lda #$55
        sta $0400
        lda $0400
        sta $fa
        lda #$2e
        sta $900f
-       clv
        bvc -
unlock  lda #$aa
        sta $2555
        lda #$55
        sta $22aa
        rts
        }
