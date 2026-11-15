        *= $6000
low     lda #$3d        ; a different colour proves $6000 is mapped
        sta $900f
        lda #0
        sta $fb
-       inc $fb
        jmp -
        !fill $8000 - *, $ee
