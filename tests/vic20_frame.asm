; cycles per frame: VIA1 timer 2 between two passes of raster line 0
        *= $1001
        !basic
        sei
-       lda $9004       ; raster / 2
        bne -
        lda #$ff
        sta $9118       ; T2 latch low
        sta $9119       ; T2 high: starts counting down from $ffff
-       lda $9004       ; leave line 0/1
        beq -
-       lda $9004       ; and wait for it again
        bne -
        lda $9118
        sta $fb
        lda $9119
        sta $fc
        cli
        ldx #0          ; show $fc $fb as hex in the top-left corner
        lda $fc
        jsr hex
        lda $fb
        jsr hex
-       jmp -
hex     pha
        lsr
        lsr
        lsr
        lsr
        jsr digit
        pla
        and #15
digit   cmp #10
        bcc +
        sbc #9          ; A-F are screen codes 1-6
        bne ++
+       ora #$30
++      sta $1e00,x
        lda #0
        sta $9600,x     ; black
        inx
        rts
