#!/bin/bash
# usage: rungame.sh image outdir frames [extra args]
ADAC64="$(cd "$(dirname "$0")/../../bin" && pwd)/adac64"
img="$1"; out="$2"; frames="$3"; shift 3
name=$(basename "$img"); work="$out/work/$name"; mkdir -p "$work"
cp "$img" "$work/$name"; chmod u+w "$work/$name"
cd "$work" && timeout 120 "$ADAC64" --headless "$frames" --png "$out/$name.png" "$@" "$name" > "$out/$name.log" 2>&1
echo "$? $name" >> "$out/status.txt"
