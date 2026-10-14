def load(p):
    r={}
    for l in open(p):
        if l.startswith('[economy-input]'):
            d=dict(kv.split('=',1) for kv in l.split()[1:]); r.setdefault(d['day'],[]).append(d)
    return r
a=load('tmp/simtrace_tr_a.txt'); b=load('tmp/simtrace_tr_b.txt')
for k in sorted(set(a)|set(b),key=int):
    for x,y in zip(a.get(k,[]),b.get(k,[])):
        print(k,x['worker_climate'],x['env'],x['build'],[f for f in x if x[f]!=y.get(f)])
    if len(a.get(k,[]))!=len(b.get(k,[])): print(k,'count',len(a.get(k,[])),len(b.get(k,[])))
