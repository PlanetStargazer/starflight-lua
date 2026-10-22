import random,sys
seed=int(sys.argv[1]); n=int(sys.argv[2])
prefix="5 ENTER 2 20*SP RIGHT RIGHT ENTER LEFT RIGHT RIGHT ENTER"
random.seed(seed)
toks=["UP"]*6+["DOWN"]*6+["LEFT"]*6+["RIGHT"]*6+["ENTER"]*4+["SP"]*2+list("5678yn")
print(prefix+" "+" ".join(random.choice(toks) for _ in range(n)))
