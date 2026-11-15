#!/usr/bin/env python3
"""Build a D81 (1581) image (test helper).

usage: mkd81.py out.d81 DISKNAME file.prg [file.prg ...]
80 tracks of 40 sectors; header 40/0, BAM 40/1 (tracks 1-40) and 40/2
(41-80), directory from 40/3. Files go to tracks 39 down and 41 up
(the last one onto the second half, so both BAM sectors are used).
"""
import sys, os

def off(t, s): return ((t - 1) * 40 + s) * 256

def main():
    out, name, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    img = bytearray(819200)
    used = {40: set(range(0, 4))}
    def alloc(high):
        order = range(41, 81) if high else range(39, 0, -1)
        for t in order:
            for s in range(40):
                if s not in used.setdefault(t, set()):
                    used[t].add(s); return t, s
        raise SystemExit("disk full")
    entries = []
    for i, path in enumerate(files):
        data = open(path, 'rb').read()
        chunks = [data[k:k+254] for k in range(0, len(data), 254)] or [b'']
        high = len(files) > 1 and i == len(files) - 1
        secs = [alloc(high) for _ in chunks]
        for j, (c, (t, s)) in enumerate(zip(chunks, secs)):
            o = off(t, s)
            img[o], img[o+1] = secs[j+1] if j+1 < len(secs) else (0, len(c)+1)
            img[o+2:o+2+len(c)] = c
        entries.append((os.path.splitext(os.path.basename(path))[0].upper()[:16], secs[0], len(secs)))
    d = off(40, 3); img[d], img[d+1] = 0, 0xFF
    for i, (n, (t, s), blocks) in enumerate(entries):
        e = d + i*32
        img[e+2] = 0x82; img[e+3], img[e+4] = t, s
        img[e+5:e+21] = n.encode().ljust(16, b'\xa0')
        img[e+30], img[e+31] = blocks & 255, blocks >> 8
    h = off(40, 0)
    img[h:h+4] = bytes([40, 3, 0x44, 0])
    img[h+4:h+0x14] = name.upper().encode()[:16].ljust(16, b'\xa0')
    img[h+0x14:h+0x1D] = b'\xa0\xa0AD\xa03D\xa0\xa0'
    for k, (b, t0) in enumerate(((off(40, 1), 1), (off(40, 2), 41))):
        nxt = (40, 2) if k == 0 else (0, 0xFF)
        img[b:b+6] = bytes([nxt[0], nxt[1], 0x44, 0xBB, ord('A'), ord('D')])
        img[b+6] = 0xC0
        for t in range(t0, t0 + 40):
            free = [s for s in range(40) if s not in used.get(t, set())]
            bits = sum(1 << s for s in free)
            e = b + 0x10 + 6 * (t - t0)
            img[e] = len(free)
            img[e+1:e+6] = bits.to_bytes(5, 'little')
    open(out, 'wb').write(img)

main()
