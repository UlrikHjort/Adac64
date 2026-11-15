; Mega-Cart test image, boot bank (high ROM bank $7F, the one at $A000
; after power-up): select high bank 5 / low bank 3 and restart through
; the cartridge's software reset, which switches the bank registers in
        *= $a000
        !word start, start
        !byte $41, $30, $c3, $c2, $cd     ; "A0CBM"
start   lda #$05
        sta $9c80       ; high bank ($A000)
        lda #$03
        sta $9d00       ; low bank ($2000-$7FFF)
        sta $9e00       ; software reset
-       jmp -
