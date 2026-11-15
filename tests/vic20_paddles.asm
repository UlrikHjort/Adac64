; read the two VIC-20 paddles ($9008 / $9009) into $fb / $fc
        *= $1001
        !basic
        lda $9008
        sta $fb
        lda $9009
        sta $fc
        rts
