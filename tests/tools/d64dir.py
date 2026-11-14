import sys
SPT=[21]*17+[19]*7+[18]*6+[17]*10
def off(t,s): return (sum(SPT[:t-1])+s)*256
for p in sys.argv[1:]:
    d=open(p,'rb').read(); print("==",p)
    if p.lower().endswith('.t64'):
        print(d[:32], 'entries', d[0x24]|d[0x25]<<8, 'used', d[0x22]|d[0x23]<<8)
        for i in range(max(1,d[0x22]|d[0x23]<<8)):
            e=d[64+32*i:96+32*i]; print(' ', e[:16].hex(), e[16:32])
        continue
    t,s=18,1; n=0
    while t and n<20:
        o=off(t,s); n+=1
        for k in range(8):
            e=d[o+32*k:o+32*k+32]
            if e[2]: print('  %02x %3d/%2d %-16s %d blk' % (e[2],e[3],e[4],e[5:21].split(b'\xa0')[0].decode('latin1'),e[30]|e[31]<<8), end='')
            if e[2] and e[3]:
                fo=off(e[3],e[4]); print('  load $%04x' % (d[fo+2]|d[fo+3]<<8))
            elif e[2]: print()
        t,s=d[o],d[o+1]
