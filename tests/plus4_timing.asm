; Plus/4 timing: loop iterations per frame (screen on, screen off, single
; clock) and TED timer 2 ticks per frame. Results (lo, hi) at $1800-$1807
        *= $1001
        !basic
        sei
        lda #0
        sta $ff0a       ; no TED interrupts
        jsr measure     ; screen on
        sta $1800
        sty $1801
        lda $ff06
        and #$ef
        sta $ff06       ; screen off
        jsr frame       ; (takes effect from the next frame)
        jsr measure
        sta $1802
        sty $1803
        lda $ff06
        ora #$10
        sta $ff06
        lda $ff13
        ora #2
        sta $ff13       ; single clock
        jsr measure
        sta $1804
        sty $1805
        lda $ff13
        and #$fd
        sta $ff13
        ; timer 2 ticks in one frame
        jsr frame
        lda #$ff
        sta $ff02
        sta $ff03       ; start at $ffff
        jsr frame
        lda $ff02       ; (low byte first)
        ldy $ff03
        sta $1806
        sty $1807
        lda #$2e
        sta $ff19
-       jmp -

frame   ; wait for raster line 1
-       lda $ff1d
        cmp #1
        bne -
        lda $ff1c
        and #1
        bne -
        rts

measure jsr frame
        ldx #0
        ldy #0
-       inx             ; while still on line 1
        bne +
        iny
+       lda $ff1d
        cmp #1
        beq -
-       inx             ; until line 1 again
        bne +
        iny
+       lda $ff1d
        cmp #1
        bne -
        lda $ff1c
        and #1
        bne -
        txa
        rts
