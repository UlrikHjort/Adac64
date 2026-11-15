        *= $a000
        !word cold, warm
        !byte $41, $30, $c3, $c2, $cd
cold    jsr $fd8d
        jsr $fd52
        jsr $fdf9
        jsr $e518
        cli
        jmp $6000       ; into the other half
warm    jmp $feb2
        !fill $c000 - *, $ff
