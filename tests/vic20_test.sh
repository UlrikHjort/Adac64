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
rm -rf $T
