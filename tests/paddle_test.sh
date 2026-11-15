#!/bin/sh
# Paddles on the mouse: a position of 0.25 / 0.75 across the picture must
# read 191 / 64 on the VIC-20 ($9008/$9009) and on the C64 (SID $D419/$D41A
# for control port 2, read with interrupts off as real programs do).
B=bin/adac64
T=${TMPDIR:-/tmp}/adac64_paddle_test.$$
mkdir -p $T
fail() { echo "paddles: $1 FAILED"; rm -rf $T; exit 1; }
$B --asm tests/c64_paddles.asm -o $T/c.prg >/dev/null
R=$($B --c64 --paddles mouse --paddle-pos 0.25 0.75 --headless 300 --png $T/s.png --monitor "m fb fc" $T/c.prg | grep '^00FB' | cut -c7-11)
[ "$R" = "BF 40" ] || fail "C64 ($R)"
echo "paddles: C64 POTX/POTY read 191 / 64"
if [ -f roms/vic20/basic.901486-01.bin ]; then
  $B --asm tests/vic20_paddles.asm -o $T/v.prg >/dev/null
  R=$($B --vic20 --paddles mouse --paddle-pos 0.25 0.75 --headless 300 --png $T/s.png --monitor "m fb fc" $T/v.prg | grep '^00FB' | cut -c7-11)
  [ "$R" = "BF 40" ] || fail "VIC-20 ($R)"
  echo "paddles: VIC-20 \$9008/\$9009 read 191 / 64"
  # light pen in the middle of the picture: beam at line 170, cycle 35
  $B --asm tests/vic20_pen.asm -o $T/p.prg >/dev/null
  R=$($B --vic20 --pen 0.5 0.5 --headless 300 --png $T/s.png --monitor "m fb fc" $T/p.prg | grep '^00FB' | cut -c7-11)
  [ "$R" = "49 55" ] || fail "VIC-20 light pen ($R)"
  echo "paddles: VIC-20 light pen latched x \$49, y \$55"
fi
rm -rf $T
