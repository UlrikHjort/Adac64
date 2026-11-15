#!/bin/sh
# PET 4032 test: the boot screen, the keyboard matrix, LOAD and RUN from a
# D64 through the virtual IEEE-488 drive, SAVE and loading it back, and
# snapshots. Skipped when the PET ROMs are not installed.
B=bin/adac64
[ -f roms/pet/basic-4.901465-23-20-21.bin ] || { echo "pet: ROMs not installed, skipped"; exit 0; }
set -e
T=${TMPDIR:-/tmp}/adac64_pet_test.$$
mkdir -p $T
fail() { echo "pet: $1 FAILED"; rm -rf $T; exit 1; }
screen() {   # dump file -> the screen as text
  python3 -I -c "
import sys
m=open(sys.argv[1],'rb').read()[0x8000:0x8000+1000]
print(''.join(chr(c+64) if 1<=c<=26 else chr(c) if 32<=c<64 else ' ' for c in m))" "$1"
}
$B --pet --headless 300 --png $T/s.png --dump $T/m.bin >/dev/null
case "$(screen $T/m.bin)" in
  *"*** COMMODORE BASIC 4.0 ***"*"31743 BYTES FREE"*READY.*) echo "pet: boots (BASIC 4.0, 31743 bytes free)";;
  *) fail "boot screen";;
esac
cp tests/pet_keys.bas $T/keys.bas
$B --pet --basic $T/keys.bas >/dev/null
K='abcdefghijklmnopqrstuvwxyz0123456789+-*/=@:;,.!"#$%&()<>?'
$B --pet --headless 2600 --png $T/s.png --keys-at 400 "$K" --dump $T/m.bin $T/keys.prg >/dev/null
python3 -I -c "
import sys
t=sys.argv[1]; m=open(sys.argv[2],'rb').read()
exp=bytes(ord(c)-32 if 'a'<=c<='z' else ord(c) for c in t)
sys.exit(0 if m[0x4000:0x4000+len(t)]==exp else 1)" "$K" $T/m.bin || fail "keyboard"
echo "pet: keyboard: all ${#K} keys arrive as the right characters"
printf '10 print "hello from the pet"\n20 poke 32768+999,42\n' > $T/hello.bas
$B --pet --basic $T/hello.bas >/dev/null
$B --mkd64 $T/h.d64 $T/hello.prg >/dev/null
$B --pet --headless 600 --png $T/s.png --dump $T/m.bin $T/h.d64 >/dev/null
case "$(screen $T/m.bin)" in
  *"HELLO FROM THE PET"*) echo "pet: LOAD and RUN from a D64 through the IEEE-488 drive";;
  *) fail "IEEE load";;
esac
# DIRECTORY (BASIC 4 reads it a byte at a time, with TALK / UNTALK
# between bytes) and DLOAD
$B --pet --headless 1100 --png $T/s.png --keys-at 300 'directory\n' --keys-at 600 'dload"hello"\n' --keys-at 800 'run\n' --dump $T/m.bin --attach $T/h.d64 >/dev/null
case "$(screen $T/m.bin)" in
  *" 0 "*" 1    \"HELLO\""*PRG*" 663 BLOCKS FREE."*"HELLO FROM THE PET"*) echo "pet: DIRECTORY and DLOAD";;
  *) fail "DIRECTORY / DLOAD";;
esac
# SAVE goes to the current directory; load it back and run it
A=$(pwd)/$B
(cd $T && $A --pet --headless 900 --png s.png --keys-at 200 'new\n10 print "saved by the pet"\nsave"newprog",8\n' >/dev/null)
[ -f $T/newprog.prg ] || fail "SAVE (no newprog.prg)"
(cd $T && $A --pet --headless 600 --png s.png --keys-at 200 'load"newprog",8\n' --keys-at 400 'run\n' --dump m.bin >/dev/null)
case "$(screen $T/m.bin)" in
  *"SAVED BY THE PET"*) echo "pet: SAVE through the IEEE-488 drive, loaded back and run";;
  *) fail "SAVE / load back";;
esac
# snapshots: 300 frames + snapshot + 300 frames = 600 frames straight
$B --pet --headless 600 --png $T/a.png $T/h.d64 >/dev/null
$B --pet --headless 300 --png $T/s.png --save-snapshot $T/p.snap $T/h.d64 >/dev/null
$B --pet --headless 300 --png $T/b.png --load-snapshot $T/p.snap >/dev/null
cmp -s $T/a.png $T/b.png || fail "snapshot"
echo "pet: snapshot: resumed run matches the straight run"
rm -rf $T
