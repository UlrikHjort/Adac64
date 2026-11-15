#!/bin/sh
# D64 writer test: files survive, the BAM is right, and the emulated 1541
# loads and runs the program from the disk; D81 images read through the
# KERNAL.
set -e
B=bin/adac64
T=${TMPDIR:-/tmp}/adac64_disk_test.$$
mkdir -p $T
cp tests/debug_test.asm $T/prog.asm
$B --asm $T/prog.asm >/dev/null
head -c 40000 /dev/urandom > $T/big.prg
printf 'some text' > $T/notes.seq
$B --mkd64 $T/t.d64 $T/prog.prg $T/big.prg $T/notes.seq
python3 -I tests/disk_check.py $T/t.d64 prog=$T/prog.prg big=$T/big.prg notes=$T/notes.seq
R=$($B --no-fast-load --headless 900 --png $T/s.png --monitor "m fb fb" $T/t.d64 | grep '^00FB' | cut -c7-8)
[ "$R" = "03" ] && echo "disk: program loaded through the 1541 and ran" \
  || { echo "disk: program did NOT run from the disk ($R)"; exit 1; }
# D81: directory, a program (autostarted) and a 79-block file in the second
# BAM half, loaded through the KERNAL from the image
printf '10 print "hello from d81"\n20 poke 53280,5\n' > $T/hello.bas
$B --basic $T/hello.bas >/dev/null
head -c 20000 /dev/urandom > $T/big81.bin
(printf '\000\100'; cat $T/big81.bin) > $T/big81.prg
python3 -I tests/tools/mkd81.py $T/t.d81 "TEST DISK" $T/hello.prg $T/big81.prg
R=$($B --headless 400 --png $T/s.png --monitor "m d020 d020" $T/t.d81 | grep '^D020' | cut -c8)
[ "$R" = "5" ] || { echo "disk: D81 program did not run ($R)"; exit 1; }
$B --headless 900 --png $T/s.png --keys-at 300 'load"$",8\nlist\n' --keys-at 500 'load"big81",8,1\n' --dump $T/m.bin $T/t.d81 >/dev/null
python3 -I -c "
import sys
m=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
s=''.join(chr(c+64) if 1<=c<=26 else chr(c) if 32<=c<64 else ' ' for c in m[0x400:0x400+1000])
ok = m[0x4000:0x4000+len(b)]==b and '3080 BLOCKS FREE' in s and '\"BIG81\"' in s
sys.exit(0 if ok else 1)" $T/m.bin $T/big81.bin || { echo "disk: D81 directory / file FAILED"; exit 1; }
echo "disk: D81 image: program ran, directory and a 79-block file read"
# the same image through an emulated 1581 (if its ROM is installed),
# without fast loading, and a SAVE onto the disk
if [ -f roms/drives/1581-rom.318045-02.bin ]; then
  R=$($B --drive 1581 --no-fast-load --headless 1500 --png $T/s.png --monitor "m d020 d020" $T/t.d81 | grep '^D020' | cut -c8)
  [ "$R" = "5" ] || { echo "disk: 1581 did not load the program ($R)"; exit 1; }
  $B --drive 1581 --no-fast-load --headless 1500 --png $T/s.png --attach $T/t.d81 --keys-at 300 '10 print "saved on a 1581"\nsave"newprog",8\n' >/dev/null
  $B --drive 1581 --no-fast-load --headless 1500 --png $T/s.png --attach $T/t.d81 --keys-at 300 'load"newprog",8\n' --keys-at 1000 'run\n' --dump $T/m.bin >/dev/null
  python3 -I -c "
import sys
m=open(sys.argv[1],'rb').read()
s=''.join(chr(c+64) if 1<=c<=26 else chr(c) if 32<=c<64 else ' ' for c in m[0x400:0x400+1000])
sys.exit(0 if 'SAVED ON A 1581' in s else 1)" $T/m.bin || { echo "disk: 1581 SAVE / load back FAILED"; exit 1; }
  echo "disk: 1581: program loaded through the drive; SAVE and load back work"
fi
rm -rf $T
