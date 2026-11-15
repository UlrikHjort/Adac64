; Raster bars: a colour table scrolled through the border and
; background, one colour per raster line, 50 times a second
        *= $0801
        !basic
        jsr $e544               ; clear the screen
        sei
        lda #0
        sta $d020
        sta $d021
        ldx #0
-       lda text,x              ; the title in the middle of the screen
        beq frame
        and #$3f
        sta $0400+12*40+8,x
        lda #1
        sta $d800+12*40+8,x
        inx
        bne -
frame
-       lda $d011               ; wait for the raster to reach line 50
        bpl -
-       lda $d012
        cmp #50
        bne -
        ldy offset
        ldx #250
line    lda colours,y           ; a new colour on every line
        lda $d012
-       cmp $d012
        beq -
        lda colours,y
        sta $d020
        sta $d021
        iny
        dex
        bne line
        lda #0
        sta $d020
        sta $d021
        inc offset
        jmp frame

offset  !byte 0
text    !text "ADAC64 FORGE: RASTER BARS",0
        !align 255, 0
colours                         ; each colour 2 lines; 2 x 128 bytes so it
                                ; wraps around smoothly
        !byte 9,9,2,2,8,8,10,10,15,15,7,7,1,1,7,7
        !byte 15,15,10,10,8,8,2,2,9,9,6,6,14,14,3,3
        !byte 13,13,1,1,13,13,3,3,14,14,6,6,11,11,12,12
        !byte 15,15,1,1,15,15,12,12,11,11,5,5,13,13,7,7
        !byte 1,1,7,7,13,13,5,5,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 9,9,2,2,8,8,10,10,15,15,7,7,1,1,7,7
        !byte 15,15,10,10,8,8,2,2,9,9,6,6,14,14,3,3
        !byte 13,13,1,1,13,13,3,3,14,14,6,6,11,11,12,12
        !byte 15,15,1,1,15,15,12,12,11,11,5,5,13,13,7,7
        !byte 1,1,7,7,13,13,5,5,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
