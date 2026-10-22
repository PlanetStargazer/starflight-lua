#!/bin/bash
# tools/dm.sh N "keys" : dump both memories at event N and print differing ranges
N=$1; K="$2"
DUMP_AT=$N luajit tools/oracle.lua /var/tmp/oracle.log $((N+1)) "$K" 1000000 >/dev/null
DUMP_AT=$N luajit tools/vmlog.lua /var/tmp/vm.log $((N+1)) "$K" 1000000 >/dev/null
python3 - <<'P'
import re
names={}
for l in open('src/names1.lua'):
    m=re.match(r'\[(\d+)\]="(.*)",',l)
    if m: names[int(m[1])]=m[2]
a=open('/var/tmp/oracle.mem','rb').read(); b=open('/var/tmp/vm.mem','rb').read()
d=[i for i in range(0x100,0x10000) if a[i]!=b[i] and not (0x5663<=i<0x5665 or 0x6A89<=i<0x6A8D)]
print('differing bytes:',len(d))
runs=[]
for i in d:
    if runs and i-runs[-1][1]<=6: runs[-1][1]=i
    else: runs.append([i,i])
def near(x):
    best=None
    for k in sorted(names):
        if k<=x: best=k
        else: break
    return '%s+%d'%(names[best],x-best) if best else '?'
for s,e in runs[:30]:
    print('%04X-%04X %-22s O=%s V=%s'%(s,e,near(s),a[s:e+1].hex()[:48],b[s:e+1].hex()[:48]))
P
python3 - <<'P'
a=open('/var/tmp/oracle.mem.ega','rb').read(); b=open('/var/tmp/vm.mem.ega','rb').read()
for p in range(4):
    d=[i for i in range(0x10000) if a[p*0x10000+i]!=b[p*0x10000+i]]
    if d:
        print('plane',p,'differs in',len(d),'bytes; first',['%04X O=%02X V=%02X'%(i,a[p*0x10000+i],b[p*0x10000+i]) for i in d[:8]])
P
python3 - <<'P'
a=open('/var/tmp/oracle.mem.full','rb').read(); b=open('/var/tmp/vm.mem.full','rb').read()
d=[i for i in range(0xA0000) if a[i]!=b[i] and not (0x1920<=i<0x11920)]
print('far memory differing bytes:',len(d))
runs=[]
for i in d:
    if runs and i-runs[-1][1]<=16: runs[-1][1]=i
    else: runs.append([i,i])
for s,e in runs[:25]:
    print('%05X-%05X (seg %04X:%04X) O=%s V=%s'%(s,e,s>>4,s&15,a[s:e+1].hex()[:40],b[s:e+1].hex()[:40]))
P
