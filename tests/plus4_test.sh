#!/bin/sh
# C16 / Plus/4 test: the boot screens, the keyboard matrix, CPU timing
# (loop iterations per frame with the screen on, off and in single clock,
# as measured in VICE), loading through fast load and the emulated 1541,
# and snapshots. Skipped when the Plus/4 ROMs are not installed.
B=bin/adac64
[ -f roms/plus4/basic-318006-01.bin ] || { echo "plus4: ROMs not installed, skipped"; exit 0; }
set -e
T=${TMPDIR:-/tmp}/adac64_plus4_test.$$
mkdir -p $T
fail() { echo "plus4: $1 FAILED"; rm -rf $T; exit 1; }
screen() {   # dump file -> the first three screen lines as text
  python3 -I -c "
import sys
m=open(sys.argv[1],'rb').read()[0x0c00:0x0c00+120]
print(''.join(chr(c+64) if 1<=c<=26 else chr(c) if 32<=c<64 else ' ' for c in m))" "$1"
}
$B --plus4 --headless 200 --png $T/s.png --dump $T/m.bin >/dev/null
case "$(screen $T/m.bin)" in
  *"COMMODORE BASIC V3.5 60671 BYTES FREE"*"3-PLUS-1 ON KEY F1"*) echo "plus4: Plus/4 boots (60671 bytes free, 3-plus-1)";;
  *) fail "Plus/4 boot screen";;
esac
$B --c16 --headless 200 --png $T/s.png --dump $T/m.bin >/dev/null
case "$(screen $T/m.bin)" in
  *"COMMODORE BASIC V3.5 12277 BYTES FREE"*) echo "plus4: C16 boots (12277 bytes free)";;
  *) fail "C16 boot screen";;
esac
# keyboard: every key typed through the matrix arrives as the right PETSCII
cp tests/plus4_keys.bas $T/keys.bas
$B --plus4 --basic $T/keys.bas >/dev/null
K='abcdefghijklmnopqrstuvwxyz0123456789+-*/=@:;,.!"#$%&()<>?'
$B --plus4 --headless 2600 --png $T/s.png --keys-at 400 "$K" --dump $T/mem.bin $T/keys.prg >/dev/null
python3 -I -c "
import sys
t=sys.argv[1]; m=open(sys.argv[2],'rb').read()
exp=bytes(ord(c)-32 if 'a'<=c<='z' else ord(c) for c in t)
sys.exit(0 if m[0x3000:0x3000+len(t)]==exp else 1)" "$K" $T/mem.bin || fail "keyboard"
echo "plus4: keyboard: all ${#K} keys arrive as the right characters"
# timing: VICE gives $065e / $0979 / $04f0 iterations (screen on / off /
# single clock); the program sets $ff19 = $2e when done
$B --asm tests/plus4_timing.asm -o $T/t.prg >/dev/null
$B --mkd64 $T/t.d64 $T/t.prg >/dev/null
timing() {   # name, options...
  N=$1; shift
  R=$($B --plus4 "$@" --monitor "m 1800 1805;m ff19 ff19" | grep -E '^(1800|FF19)' | cut -c7-23 | tr '\n' ' ')
  case "$R" in
    "5E 06 79 09 F0 04 2E 00 00 FF 01 00 "|"5E 06 78 09 F1 04 2E 00 00 FF 01 00 ") echo "plus4: $N: loaded, ran, timing as in VICE";;
    *) fail "$N ($R)";;
  esac
}
timing "fast load" --headless 600 --png $T/s.png $T/t.prg
timing "1541 drive" --headless 3000 --png $T/s.png --no-fast-load $T/t.d64
# snapshots: 300 frames + snapshot + 600 frames = 900 frames straight
$B --plus4 --headless 900 --png $T/a.png $T/t.prg >/dev/null
$B --plus4 --headless 300 --png $T/s.png --save-snapshot $T/p.snap $T/t.prg >/dev/null
$B --plus4 --headless 600 --png $T/b.png --load-snapshot $T/p.snap >/dev/null
cmp -s $T/a.png $T/b.png || fail "snapshot"
echo "plus4: snapshot: resumed run matches the straight run"
rm -rf $T
