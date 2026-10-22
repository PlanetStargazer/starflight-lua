import subprocess,sys
snap=sys.argv[1] if len(sys.argv)>1 else '/var/tmp/snap_port'
only=sys.argv[2] if len(sys.argv)>2 else None
def run(name,th,maxev=3000000):
    if only and only not in name: return
    r=subprocess.run(['tools/forced.sh',snap,th,str(maxev)],capture_output=True,text=True)
    print('%-34s %s'%(name,(r.stdout+r.stderr).strip().split('\n')[0][:150]),flush=True)
def poly(pts):
    th='INIT-VIEWSCREEN-POLY DCLIPSET '
    for i,(y,x) in enumerate(pts):
        th+='%d NEB-TABLE %d + ! %d NEB-TABLE %d + ! '%(y,4*i,x,4*i+2)
    th+='%d #IN ! '%len(pts)
    return th
for name,pts in [('poly triangle',[(20,30),(50,100),(90,40)]),
                 ('poly quad',[(10,10),(10,120),(150,120),(150,10)]),
                 ('poly clipped',[(-20,10),(120,230),(60,-30)]),
                 ('poly concave',[(10,10),(100,20),(40,60),(120,100),(150,5)]),
                 ('poly one point',[(30,40)]),
                 ('poly line',[(30,40),(60,90)])]:
    run(name,'6 COLOR ! '+poly(pts)+'CLIPPER SCANPOLY LFILLPOLY')
run('POLY-WINDOW-FILL','DCLIPSET 40 20 100 80 9 POLY-WINDOW-FILL')
bltsetup='@DS BLTSEG ! %d ABLT ! %d WBLT ! %d LBLT ! %d XBLT ! %d YBLT ! '
for name,(a,w,l,x,y),xor in [('BLT inside',(0x1000,16,10,20,100),0),('BLT clip right',(0x1100,20,12,145,100),0),
        ('BLT clip left',(0x1200,24,12,65526,100),0),('BLT clip top',(0x1300,17,12,40,3),0),
        ('BLT xor',(0x1400,13,9,50,60),1),('BLT wide',(0x1500,40,6,5,150),0)]:
    run(name,'DCLIPSET 12 COLOR ! %d XORMODE ! '%xor+bltsetup%(a,w,l,x,y)+'BLT')
run('TILE 4x4','5000 COLORMAP 40 30 4 4 TILEFILL')
run('TILE 8x8','9000 COLORMAP 40 30 8 8 TILEFILL')
run('TILE 6x3','DCLIPSET 12000 COLORMAP 41 50 6 3 TILEFILL')
run('circle','DCLIPSET 3 COLOR ! 80 100 30 .CIRCLE')
run('circle edge','DCLIPSET 3 COLOR ! 150 190 40 .CIRCLE')
run('ellipse','DCLIPSET 5 COLOR ! 80 100 25 3 2 .ELLIPSE')
run('fillcirc','DCLIPSET 4 COLOR ! 80 100 30 FILLCIRC')
run('fillellip','DCLIPSET 6 COLOR ! 60 90 20 2 1 FILLELLIP')
run('fillcirc clipped','DCLIPSET 4 COLOR ! 150 20 30 FILLCIRC')
run('L@PIXEL','10 10 L@PIXEL DROP 77 50 L@PIXEL DROP')
run('LCOPYBLK','4 190 76 100 4 191 LCOPYBLK')
run('LCOPYBLK up','4 100 76 90 4 99 LCOPYBLK')
run('V>DISPLAY','>MAINVIEW V>DISPLAY')
