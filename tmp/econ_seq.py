import sys,re
def load(p):
    out=[]
    for line in open(p):
        if line.startswith('[econ-data] '):
            d=dict(kv.split('=',1) for kv in line.split()[1:])
            out.append((int(d['day']),d['pop'][:6],d['funds'][:6],d['active'][:6],d['resource'][:6]))
    return out
a=load('tmp/simtrace_pp_a.txt'); b=load('tmp/simtrace_pp_b.txt')
for i in range(min(len(a),len(b),30)):
    print(a[i], b[i], 'SAME' if a[i][1:]==b[i][1:] else '')
