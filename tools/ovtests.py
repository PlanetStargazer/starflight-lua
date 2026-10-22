import subprocess,sys
snap=sys.argv[1] if len(sys.argv)>1 else '/var/tmp/snap_port'
only=sys.argv[2] if len(sys.argv)>2 else None
def run(name,th,maxev=6000000):
    if only and only not in name: return
    r=subprocess.run(['tools/forced.sh',snap,th,str(maxev)],capture_output=True,text=True)
    print('%-34s %s'%(name,(r.stdout+r.stderr).strip().split('\n')[0][:160]),flush=True)
run('mercator gen','FRACT-OV 1234 MERCATOR-GEN')
run('mercator gen 2','FRACT-OV 777 MERCATOR-GEN')
run('C*/','ORBIT-OV 7 9 5 C*/ -100 3 7 C*/ 100 100 3 C*/ 5 5 0 C*/ 127 127 1 C*/')
run('quad interp','ORBIT-OV 10 20 30 40 50 60 70 80 SETQUAD 2 3 WDD2C DROP DROP')
run('quad interp 2','ORBIT-OV 100 -20 330 40 -50 60 70 -81 SETQUAD 0 4 WDD2C DROP DROP 4 1 WDD2C DROP DROP 1 1 WDD2C')
run('WE16B translate','ORBIT-OV 5 #IN ! 12 @DBD4 C! 3 @DBD8 C! 200 @DBDC C! 3DSEG @ SWAP DROP 100 VIN ! 3000 @5DDE ! WE16B')
def setmem(base, vals):
    t=''
    for off,(v,kind) in vals:
        t+='%d @%X %d + %s '%(v,base,off,'C!' if kind=='b' else '!')
    return t
mat=[(0,(1,'b')),(2,(2,'b')),(4,(3,'b')),(6,(100,'w')),(8,(4,'b')),(10,(5,'b')),(12,(6,'b')),(14,(200,'w')),(16,(7,'b')),(18,(8,'b')),(20,(9,'b')),(22,(300,'w'))]
run('WE1B6 rotate','ORBIT-OV 6 #IN ! 3000 @5DDE ! 4000 VOUT ! '+setmem(0xDCC2,mat)+'WE1B6')
mat2=[(0,(-5,'b')),(2,(2,'b')),(4,(120,'b')),(6,(-100,'w')),(8,(4,'b')),(10,(-77,'b')),(12,(6,'b')),(14,(20,'w')),(16,(127,'b')),(18,(-128,'b')),(20,(9,'b')),(22,(30,'w'))]
run('WE1B6 rotate 2','ORBIT-OV 9 #IN ! 3000 @5DDE ! 4000 VOUT ! '+setmem(0xDCC2,mat2)+'WE1B6')
run('WE228 project','ORBIT-OV 5 #IN ! 4000 VOUT ! 80 @5DEC ! 100 @5DFA ! 3 @DC14 ! 5 @DC10 ! WE228')
run('PORTMENU |EGA','PORTMENU-OV 1 |EGA 0 |EGA')
run('SITE |EGA','SITE-OV 1 |EGA 0 |EGA')
run('GAME PRMSAV/LOD','GAME-OV 11 22 33 PAD PRMSAV 44 55 PAD PRMLOD')
run('GAME RETSAV','GAME-OV 1 2 PAD RETSAV')
run('MAPS CBLTP','MAPS-OV 10 20 CBLTP')
run('MOVE CBLTP','MOVE-OV 10 20 CBLTP')
