#!/bin/sh
# D64 writer test: files survive, the BAM is right, and the emulated 1541
# loads and runs the program from the disk.
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
rm -rf $T
