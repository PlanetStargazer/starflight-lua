import subprocess,sys,random
snap=sys.argv[1] if len(sys.argv)>1 else '/var/tmp/snap_port'
only=sys.argv[2] if len(sys.argv)>2 else None
random.seed(5)
def run(name,th,maxev=200000):
    if only and only not in name: return
    r=subprocess.run(['tools/forced.sh',snap,th,str(maxev)],capture_output=True,text=True)
    print('%-26s %s'%(name,(r.stdout+r.stderr).strip().split('\n')[0][:140]),flush=True)
def rv(n=1): return [random.choice([0,1,2,3,7,15,16,100,255,256,1000,4095,32767,65535,-1,-2,-100,-32768,12345,54321,random.randint(0,65535)]) for _ in range(n)]
def tests(word,nargs,count=3,extra=''):
    th=''
    for _ in range(count):
        th+=' '.join(str(v) for v in rv(nargs))+' '+word+' '
    run(word,extra+th)
tests('4*',1); tests('3+',1); tests('2^N',1,6); tests('+BIT',1,5); tests('S->D',1,4); tests('D2*',2,4); tests('D16*',2,4)
tests('D+',4,3); tests('DNEGATE',2,3); tests('U/MOD',3,4); tests('/MOD',2,6); tests('/',2,6); tests('*',2,4); tests('U*',2,4)
tests('<',2,6); tests('>',2,6); tests('U<',2,6); tests('0<',1,4); tests('0>',1,4); tests('=',2,4)
tests('EASY-BITS',4,3); tests('DIGIT',2,6)
run('DIGIT chars','48 10 DIGIT 57 10 DIGIT 65 16 DIGIT 70 16 DIGIT 71 16 DIGIT 97 16 DIGIT 49 2 DIGIT 50 2 DIGIT')
run('RECADD','3 21 100 5 RECADD 0 21 0 0 RECADD 10 16 1000 64 RECADD 7 100 300 2 RECADD 20 50 900 1 RECADD')
tests('BVSA>OFFBLK',1,6); tests('DOFFBLK',1,6); tests('VA>BLK',2,5)
tests('(SLIPPER)',1,6); tests('TOGGLE',2,2,'1000 ')
run('P@/P!','100 200 P! 100 P@ 1000 P@ 5 PORT')
run('mem ops','7 @DS 4000 C!L 4000 @DS C@L 12345 @DS 4002 !L 4002 @DS @L 8 SWAP DROP')
run('RP@','RP@ DROP')
run('<LCMOVE','@DS 4000 @DS 4100 20 <LCMOVE')
run('CMOVE>','4000 4100 20 CMOVE>')
run('VFILL/VMOVE','1 2 3 VFILL 4 5 6 VMOVE 7 8 9 VMOVE-')
run('L+-@','@DS 4001 L+-@ @DS 4003 L+-@')
run('L1.5@','@DS 4000 L1.5@')
run('W4D5C','7 3 W4D5C')
run('E>CGA','5 E>CGA 9 E>CGA 0 E>CGA 15 E>CGA')
run('C>EGA','5 C>EGA 9 C>EGA 0 C>EGA 15 C>EGA')
run('PLOT','S/RON 5 COLOR ! 20 30 PLOT 6 COLOR ! 159 0 PLOT SETCOLO')
run('W8E4F','40960 0 41472 0 W8E4F')
run('BUFFERXY','10 20 1 1 BUFFERXY 7 9 2 2 BUFFERXY 3 4 0 0 BUFFERXY')
run('WLD>SCR','100 200 WLD>SCR 7 8 WLD>SCR')
run('SCR>BLT','50 60 SCR>BLT 0 0 SCR>BLT')
run('?INVIS','10 20 ?INVIS 5000 5000 ?INVIS 0 0 ?INVIS')
run('SHL-BIT','5 3 SHL-BIT 65535 255 SHL-BIT')
run('?ILOCUS','10 20 5 0 50 ?ILOCUS')
run('?IID','7 0 3 10 20 ?IID')
run('@IW/!IW','IXSEG @ @IW IXSEG @ 5 !IW IXSEG @ @IW')
run('XCHGICON','1 2 XCHGICON 2 1 XCHGICON')
run('?TERMINAL stack','4 5 6')
