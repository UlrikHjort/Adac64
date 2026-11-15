; VIC-20 test cartridge at $A000: the KERNAL finds "A0CBM" and jumps here
        *= $a000
        !word cold, warm
        !byte $41, $30, $c3, $c2, $cd     ; "A0CBM"
cold    jsr $fd8d       ; RAMTAS: memory test, pointers
        jsr $fd52       ; RESTOR: KERNAL vectors
        jsr $fdf9       ; IOINIT: VIAs
        jsr $e518       ; CINT: screen editor, clear screen
        cli
        ldx #0
-       lda message,x
        beq +
        jsr $ffd2
        inx
        bne -
+       lda #$2e        ; red border, light? background
        sta $900f
        lda #0
        sta $fb
loop    inc $fb
        jmp loop
warm    jmp $feb2       ; NMI: to the KERNAL
message !pet "cartridge ok", 13, 0
        !fill $c000 - *, $aa
