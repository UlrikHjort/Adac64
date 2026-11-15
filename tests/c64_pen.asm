; C64 light pen: $fb/$fc = the position latched by the pen ($D013/$D014),
; $fd = the raster line latched when the program pulls CIA1 PB4 (the LP
; input) low at line 100, $fe = $D019 IRQ bit 3 after that
        *= $0801
        !basic
        sei
        lda #$0f
        sta $d019       ; clear the latch flag
-       lda $d019
        and #8
        beq -
        lda $d013
        sta $fb
        lda $d014
        sta $fc
-       lda $d011       ; wait for the next frame...
        bpl -
-       lda $d011
        bmi -
-       lda $d012       ; ...and its line 100
        cmp #100
        bne -
        lda #8
        sta $d019
        lda #$10
        sta $dc03       ; PB4 as output
        lda #$00
        sta $dc01       ; LP low
        lda $d014
        sta $fd
        lda $d019
        and #8
        sta $fe
        lda #$ff
        sta $dc01
        lda #$00
        sta $dc03
-       jmp -
