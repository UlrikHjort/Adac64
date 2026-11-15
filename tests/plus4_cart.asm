; C16 / Plus/4 test cartridge (C1 low, 16K): the KERNAL finds "CBM" at
; $8007 at reset and starts module 1. Sets the border to $2e and counts in
; $fb; fills the rest of the 16K with $aa
        *= $8000
        jmp start       ; cold start
        jmp start       ; (warm start)
        !byte 1         ; module number: start at reset
        !text "CBM"
start   sei
        lda #$2e
        sta $ff19
        lda #0
        sta $fb
-       inc $fb
        ldx #0
--      dex
        bne --
        jmp -
        !fill $c000 - *, $aa
