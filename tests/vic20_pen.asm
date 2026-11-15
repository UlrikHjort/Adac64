; read the VIC-20 light pen latch ($9006 / $9007) into $fb / $fc
        *= $1001
        !basic
        lda $9006
        sta $fb
        lda $9007
        sta $fc
        rts
