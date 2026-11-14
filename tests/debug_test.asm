; program used by debug_test (debugger API)
        *= $0801
        !basic
counter = $fb
start   lda #0
        sta counter
main    jsr sub             ; step over this
after   inc counter
        lda counter
        sta $d020           ; watchpoint target
        cmp #3
        bne main
done    jmp done

sub     ldx #10
-       dex
        bne -
        jsr inner
back    rts

inner   nop
        rts
