import sys
a=open(sys.argv[1]).read().split('\n'); b=open(sys.argv[2]).read().split('\n')
n=min(len(a),len(b))
for i in range(n):
    if a[i]!=b[i]:
        print('first difference at line',i+1)
        for j in range(max(0,i-6),min(n,i+3)):
            print('%5d  O: %-22s V: %s'%(j+1,a[j],b[j]))
        break
else:
    print('identical over',n,'lines', '(lens %d %d)'%(len(a),len(b)))
