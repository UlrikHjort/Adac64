#!/bin/sh
# BASIC tokenizer test: the emulated C64 / C128 types each program in and
# its own tokenizer must produce the same bytes as `adac64 --basic`; then
# listing and re-tokenizing must round-trip.
set -e
B=bin/adac64
T=${TMPDIR:-/tmp}/adac64_basic_test.$$
mkdir -p $T
check() {   # file model address
  cp tests/$1 $T/$1
  if [ $2 = c128 ]; then $B --basic $T/$1 --c128 >/dev/null; else $B --basic $T/$1 >/dev/null; fi
  P=$T/${1%.bas}.prg
  TXT=$(sed 's/$/\\n/' tests/$1 | tr -d '\n')
  $B --$2 --headless 1400 --png $T/s.png --dump $T/mem.bin --type "$TXT" >/dev/null
  N=$(($(stat -c %s $P) - 2))
  tail -c +3 $P > $T/ours.bin
  dd if=$T/mem.bin of=$T/real.bin bs=1 skip=$(($3)) count=$N 2>/dev/null
  cmp -s $T/ours.bin $T/real.bin && echo "basic: $1 matches the $2 tokenizer ($N bytes)" \
    || { echo "basic: $1 DIFFERS from the $2 tokenizer"; exit 1; }
  $B --list $P > $T/round.bas
  if [ $2 = c128 ]; then $B --basic $T/round.bas --c128 >/dev/null; else $B --basic $T/round.bas >/dev/null; fi
  cmp -s $P $T/round.prg && echo "basic: $1 list/tokenize round trip ok" \
    || { echo "basic: $1 round trip FAILED"; exit 1; }
}
check basic_v2.bas c64 0x801
check basic_v7.bas c128 0x1c01
rm -rf $T
