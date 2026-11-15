# Check a D64 written by adac64 --mkd64: every file's sector chain gives
# back the original bytes, and the BAM marks exactly the used sectors.
# usage: disk_check.py image.d64 name=file ...
import sys
d = open(sys.argv[1], 'rb').read()
spt = [21]*17 + [19]*7 + [18]*6 + [17]*5
def off(t, s): return sum(spt[:t-1])*256 + s*256
used = {(18, 0)}
def chain(t, s):
    out = b''
    while True:
        used.add((t, s)); o = off(t, s)
        if d[o] == 0: return out + d[o+2:o+d[o+1]+1]
        out += d[o+2:o+256]; t, s = d[o], d[o+1]
files = {}; t, s = 18, 1
while True:
    used.add((t, s)); o = off(t, s)
    for e in range(8):
        en = o + e*32
        if d[en+2]:
            name = bytes(c for c in d[en+5:en+21] if c != 0xa0).decode().lower()
            files[name] = chain(d[en+3], d[en+4])
    if d[o] == 0: break
    t, s = d[o], d[o+1]
bad = 0
for arg in sys.argv[2:]:
    n, f = arg.split('=')
    ok = files.get(n) == open(f, 'rb').read()
    print('disk: %-6s %s' % (n, 'data ok' if ok else 'DIFFERENT')); bad += not ok
b = off(18, 0); bam_bad = 0
for tr in range(1, 36):
    bits = d[b+4+(tr-1)*4+1] | d[b+4+(tr-1)*4+2] << 8 | d[b+4+(tr-1)*4+3] << 16
    for se in range(spt[tr-1]):
        free = bool(bits >> se & 1)
        if free == ((tr, se) in used): bam_bad += 1
print('disk: BAM', 'consistent' if not bam_bad else '%d WRONG' % bam_bad)
sys.exit(1 if bad or bam_bad else 0)
