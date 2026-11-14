#!/usr/bin/env python3
"""Build a 35-track D64 image from PRG files (test helper).

usage: mkd64.py out.d64 DISKNAME file1.prg [file2.prg ...]
"""
import sys, os

SPT = [21]*17 + [19]*7 + [18]*6 + [17]*5

def offset(t, s):
    return (sum(SPT[:t-1]) + s) * 256

def main():
    out, diskname, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    img = bytearray(174848)
    used = {18: {0, 1}}
    def alloc():
        for t in list(range(17, 0, -1)) + list(range(19, 36)):
            for s in range(SPT[t-1]):
                if s not in used.setdefault(t, set()):
                    used[t].add(s)
                    return t, s
        raise SystemExit("disk full")
    entries = []
    for path in files:
        data = open(path, 'rb').read()
        chunks = [data[i:i+254] for i in range(0, len(data), 254)] or [b'']
        secs = [alloc() for _ in chunks]
        for i, (c, (t, s)) in enumerate(zip(chunks, secs)):
            o = offset(t, s)
            if i + 1 < len(secs):
                img[o], img[o+1] = secs[i+1]
            else:
                img[o], img[o+1] = 0, len(c) + 1
            img[o+2:o+2+len(c)] = c
        name = os.path.splitext(os.path.basename(path))[0].upper()[:16]
        entries.append((name, secs[0], len(secs)))
    # directory sector 18/1
    d = offset(18, 1)
    img[d], img[d+1] = 0, 0xFF
    for i, (name, (t, s), blocks) in enumerate(entries[:8]):
        e = d + i*32
        img[e+2] = 0x82
        img[e+3], img[e+4] = t, s
        n = name.encode('ascii').ljust(16, b'\xa0')
        img[e+5:e+21] = n
        img[e+30], img[e+31] = blocks & 255, blocks >> 8
    # BAM 18/0
    b = offset(18, 0)
    img[b:b+4] = bytes([18, 1, 0x41, 0])
    for t in range(1, 36):
        free = [s for s in range(SPT[t-1]) if s not in used.get(t, set())]
        bits = sum(1 << s for s in free)
        img[b+4*t:b+4*t+4] = bytes([len(free), bits & 255, (bits >> 8) & 255,
                                    (bits >> 16) & 255])
    img[b+0x90:b+0xA0] = diskname.upper().encode('ascii')[:16].ljust(16, b'\xa0')
    img[b+0xA0:b+0xAB] = b'\xa0\xa0AD\xa02A\xa0\xa0\xa0\xa0'
    open(out, 'wb').write(img)

main()
