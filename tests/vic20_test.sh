#!/bin/sh
# VIC-20 test: RAM sizing per expansion, and the same program loaded by
# fast load, through the emulated 1541 and from tape (it sets $900F = 8).
# Skipped when the VIC-20 ROMs are not installed (see README, ROMs).
B=bin/adac64
[ -f roms/vic20/basic.901486-01.bin ] || { echo "vic20: ROMs not installed, skipped"; exit 0; }
set -e
T=${TMPDIR:-/tmp}/adac64_vic20_test.$$
mkdir -p $T
fail() { echo "vic20: $1 FAILED"; rm -rf $T; exit 1; }
# BASIC start and end of RAM (TXTTAB $2B/$2C, MEMSIZ $37/$38)
for cfg in "0k 01 10 00 1E" "3k 01 04 00 1E" "8k 01 12 00 40" "24k 01 12 00 80"; do
  set -- $cfg
  R=$($B --vic20 $1 --headless 200 --png $T/s.png --monitor "m 2b 2c;m 37 38" | grep -E '^00(2B|37)' | cut -c7-11 | tr '\n' ' ')
  [ "$R" = "$2 $3 $4 $5 " ] || fail "memory $1 (got $R)"
  echo "vic20: memory $1: BASIC \$$3$2, top \$$5$4"
done
cp tests/vic20.bas $T/v.bas
$B --vic20 --basic $T/v.bas >/dev/null
$B --mkd64 $T/v.d64 $T/v.prg >/dev/null
python3 -I tests/tools/mktap.py $T/v.tap V $T/v.prg >/dev/null
check() {   # name, frames, options...
  N=$1; F=$2; shift 2
  R=$($B --vic20 "$@" --headless $F --png $T/s.png --monitor "m 900f 900f" | grep '^900F' | cut -c7-8)
  [ "$R" = "08" ] || fail "$N (\$900F = $R)"
  echo "vic20: $N: loaded and ran"
}
check "fast load" 600 $T/v.d64
check "1541 drive" 2500 --no-fast-load $T/v.d64
check "tape" 6000 $T/v.tap
# cartridges: 8K and 4K .prg, raw .bin, split -6000/-a000, 16K image, .crt
cart() {   # name, file, expected $900F
  R=$($B --vic20 --headless 200 --png $T/s.png --monitor "m 900f 900f" "$2" | grep '^900F' | cut -c7-8)
  [ "$R" = "$3" ] || fail "cartridge $1 (\$900F = $R)"
  echo "vic20: cartridge $1 started"
}
$B --asm tests/vic20_cart.asm -o $T/c8.prg >/dev/null
sed 's/!fill $c000 - \*, $aa/!fill $b000 - *, $aa/' tests/vic20_cart.asm > $T/c4.asm
$B --asm $T/c4.asm -o $T/c4.prg >/dev/null
tail -c +3 $T/c8.prg > $T/c8.bin
$B --asm tests/vic20_cart_lo.asm -o $T/g-6000.prg >/dev/null
$B --asm tests/vic20_cart_hi.asm -o $T/g-a000.prg >/dev/null
(head -c 2 $T/g-6000.prg; tail -c +3 $T/g-6000.prg; tail -c +3 $T/g-a000.prg) > $T/g16.prg
cart "8K .prg" $T/c8.prg 2E
cart "4K .prg (mirrored)" $T/c4.prg 2E
cart "raw .bin" $T/c8.bin 2E
cart "split -a000 + -6000" $T/g-a000.prg 3D
cart "16K image at \$6000" $T/g16.prg 3D
if command -v cartconv >/dev/null; then
  cartconv -t vic20 -i $T/c8.prg -o $T/c8.crt >/dev/null 2>&1
  cart "VICE .crt" $T/c8.crt 2E
fi
# snapshots: 600 frames + snapshot + 300 frames = 900 frames straight
# (the test cartridge counts in $fb all the time)
R1=$($B --vic20 --headless 900 --png $T/s.png --monitor "m fb fb" $T/c8.prg | grep '^00FB' | cut -c7-8)
$B --vic20 --headless 600 --png $T/s.png --save-snapshot $T/c.snap $T/c8.prg >/dev/null
R2=$($B --vic20 --headless 300 --png $T/s.png --load-snapshot $T/c.snap --monitor "m fb fb" | grep '^00FB' | cut -c7-8)
[ -n "$R1" ] && [ "$R1" = "$R2" ] || fail "snapshot ($R1 / $R2)"
echo "vic20: snapshot: resumed run matches the straight run (\$fb = $R1)"
# video timing: VIA1 timer between two passes of raster line 0
$B --asm tests/vic20_frame.asm -o $T/frame.prg >/dev/null
for std in "pal 22143" "ntsc 16956"; do
  set -- $std
  R=$($B --vic20 --$1 --headless 300 --png $T/s.png --monitor "m fb fc" $T/frame.prg | grep '^00FB' | cut -c7-11)
  V=$(python3 -c "lo,hi='$R'.split(); print(0xffff-(int(hi,16)*256+int(lo,16)))")
  [ "$V" = "$2" ] || fail "$1 frame timing ($V cycles)"
  echo "vic20: $1 frame: $V cycles measured (71 x 312 / 65 x 261 minus the loop)"
done
# keyboard: every key typed through the matrix arrives as the right PETSCII
$B --vic20 8k --basic tests/vic20_keys.bas >/dev/null
mv tests/vic20_keys.prg $T/keys.prg
K='abcdefghijklmnopqrstuvwxyz0123456789+-*/=@:;,.!"#$%&()<>?'
$B --vic20 8k --headless 2600 --png $T/s.png --keys-at 400 "$K" --dump $T/mem.bin $T/keys.prg >/dev/null
python3 -I -c "
import sys
t=sys.argv[1]; m=open(sys.argv[2],'rb').read()
exp=bytes(ord(c)-32 if 'a'<=c<='z' else ord(c) for c in t)
sys.exit(0 if m[0x1300:0x1300+len(t)]==exp else 1)" "$K" $T/mem.bin || fail "keyboard"
echo "vic20: keyboard: all ${#K} keys arrive as the right characters"
rm -rf $T
