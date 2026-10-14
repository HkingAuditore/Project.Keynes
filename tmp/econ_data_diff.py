def load(p,tag):
    r={}
    for l in open(p):
        if l.startswith(tag):
            d=dict(kv.split('=',1) for kv in l.split()[1:]); r[d['day']]=d
    return r
a=load('tmp/simtrace_tr_a.txt','[econ-data]'); b=load('tmp/simtrace_tr_b.txt','[econ-data]')
for k in sorted(set(a)&set(b),key=int)[:20]:
    print(k,'gen',a[k]['gen'],b[k]['gen'],[f for f in a[k] if a[k][f]!=b[k].get(f)])
