import sys,struct
G={0x0A:0,0x0B:1,0x12:2,0x13:3,0x0E:4,0x0F:5,0x16:6,0x17:7,0x09:8,0x19:9,0x1A:10,0x1B:11,0x0D:12,0x1D:13,0x1E:14,0x15:15}
d=open(sys.argv[1],'rb').read()
offs=struct.unpack('<84I', d[12:12+336])
def track_bits(t):
    o=offs[(t-1)*2]
    if not o: return None
    n=struct.unpack('<H',d[o:o+2])[0]; raw=d[o+2:o+2+n]
    return ''.join(format(b,'08b') for b in raw)
def gcr_decode(bits, nbytes):
    out=[]; bad=0
    for i in range(nbytes):
        hi=G.get(int(bits[i*10:i*10+5],2)); lo=G.get(int(bits[i*10+5:i*10+10],2))
        if hi is None or lo is None: bad+=1; hi=hi or 0; lo=lo or 0
        out.append(hi<<4|lo)
    return bytes(out),bad
def sectors(t):
    b=track_bits(t)
    if b is None: return {}
    bb=b+b[:6000]; res={}; i=0; pend=None
    while i < len(b)+3000:
        j=bb.find('1111111111',i)
        if j<0: break
        k=j
        while k<len(bb) and bb[k]=='1': k+=1
        blk,bad=gcr_decode(bb[k:k+2700], 4)
        if blk[0]==8:
            h,bad=gcr_decode(bb[k:],8); pend=(h[2],h[3],bad)
        elif blk[0]==7 and pend:
            data,bad=gcr_decode(bb[k:],260)
            chk=0
            for x in data[1:257]: chk^=x
            res.setdefault(pend[0],[]).append((data[1:257], chk==data[257], bad, pend[1]))
            pend=None
        i=k+1
    return res
if __name__=='__main__':
    t=int(sys.argv[2]); s=sectors(t)
    for sec in sorted(s):
        for data,ok,bad,ht in s[sec]:
            print('t%d s%d hdrtrk %d chk_ok %s badgcr %d link %d/%d'%(t,sec,ht,ok,bad,data[0],data[1]))
