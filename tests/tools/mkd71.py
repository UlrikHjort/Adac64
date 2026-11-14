#!/usr/bin/env python3
"""Build a double-sided D71 image (test helper).

usage: mkd71.py out.d71 DISKNAME side1.prg [side2.prg ...]
The first file is stored on side 1 (tracks 17 down), the others on side 2
(tracks 36 up), so loading them exercises the head switch.
"""
import sys, os
SPT1 = [21]*17 + [19]*7 + [18]*6 + [17]*5
SPT = SPT1 + SPT1                       # tracks 1..70
def off(t, s): return (sum(SPT[:t-1]) + s) * 256

def main():
    out, name, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    img = bytearray(349696)
    used = {18: {0, 1}, 53: set(range(SPT[52]))}
    def alloc(side2):
        order = range(36, 71) if side2 else list(range(17, 0, -1)) + list(range(19, 36))
        for t in order:
            if t == 53: continue
            for s in range(SPT[t-1]):
                if s not in used.setdefault(t, set()):
                    used[t].add(s); return t, s
        raise SystemExit("disk full")
    entries = []
    for i, path in enumerate(files):
        data = open(path, 'rb').read()
        chunks = [data[k:k+254] for k in range(0, len(data), 254)] or [b'']
        secs = [alloc(i > 0) for _ in chunks]
        for j, (c, (t, s)) in enumerate(zip(chunks, secs)):
            o = off(t, s)
            img[o], img[o+1] = secs[j+1] if j+1 < len(secs) else (0, len(c)+1)
            img[o+2:o+2+len(c)] = c
        entries.append((os.path.splitext(os.path.basename(path))[0].upper()[:16], secs[0], len(secs)))
    d = off(18, 1); img[d], img[d+1] = 0, 0xFF
    for i, (n, (t, s), blocks) in enumerate(entries):
        e = d + i*32
        img[e+2] = 0x82; img[e+3], img[e+4] = t, s
        img[e+5:e+21] = n.encode().ljust(16, b'\xa0')
        img[e+30], img[e+31] = blocks & 255, blocks >> 8
    b = off(18, 0)
    img[b:b+4] = bytes([18, 1, 0x41, 0x80])          # 0x80: double sided
    for t in range(1, 36):
        free = [s for s in range(SPT[t-1]) if s not in used.get(t, set())]
        bits = sum(1 << s for s in free)
        img[b+4*t:b+4*t+4] = bytes([len(free), bits & 255, (bits >> 8) & 255, (bits >> 16) & 255])
    b2 = off(53, 0)
    for t in range(36, 71):
        free = [s for s in range(SPT[t-1]) if s not in used.get(t, set())]
        bits = sum(1 << s for s in free)
        img[b + 0xDD + (t-36)] = len(free)
        img[b2 + 3*(t-36): b2 + 3*(t-36) + 3] = bytes([bits & 255, (bits >> 8) & 255, (bits >> 16) & 255])
    img[b+0x90:b+0xA0] = name.upper().encode()[:16].ljust(16, b'\xa0')
    img[b+0xA0:b+0xAB] = b'\xa0\xa0AD\xa02A\xa0\xa0\xa0\xa0'
    open(out, 'wb').write(img)
main()
