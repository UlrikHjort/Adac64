; Mega-Cart test image, high ROM bank 5: started after the software reset
; with low bank 3 in $2000-$7FFF. Results: $fd/$fe = low bank bytes ($33),
; $fc = cartridge RAM read back ($5a), $fa = NVRAM read back ($77),
; $900F = $2e when everything ran
        *= $a000
        !word start, start
        !byte $41, $30, $c3, $c2, $cd     ; "A0CBM"
start   sei
        lda $2000
        sta $fd
        lda $7fff
        sta $fe
        lda #$77
        sta $0400       ; NVRAM in RAM123
        lda $0400
        sta $fa
        ldx #ramtest_end - ramtest - 1
-       lda ramtest,x   ; the RAM test switches this bank out: run it
        sta $0340,x     ; from the cassette buffer
        dex
        bpl -
        jmp $0340
ramtest lda #$c0        ; high: RAM, writable
        sta $9c80
        lda #$80        ; low: RAM
        sta $9d00
        lda #$5a
        sta $4000
        lda $4000
        sta $fc
        lda #$2e
        sta $900f
-       clv             ; (relocated: no absolute jump)
        bvc -
ramtest_end
