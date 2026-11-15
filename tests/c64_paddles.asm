; read both paddles of control port 2 with interrupts off
        *= $0801
        !basic
        sei
        lda #$c0
        sta $dc02       ; CIA1 port A bits 6/7 as outputs
        lda #$80
        sta $dc00       ; select port 2 for the SID
        ldx #0
-       dex             ; let the SID sample (512 cycles)
        bne -
        lda $d419
        sta $fb
        lda $d41a
        sta $fc
        lda #$ff
        sta $dc02
        cli
        rts
