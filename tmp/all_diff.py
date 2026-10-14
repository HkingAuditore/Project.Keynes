import sys
def load(p, maxday=3):
    out={}
    for line in open(p):
        if line.startswith('[main-write]'): continue
        parts=line.split()
        tag=parts[0]
        d=dict(kv.split('=',1) for kv in parts[1:] if '=' in kv)
        day=d.get('day')
        if day is None or int(day)>maxday: continue
        out.setdefault((tag,day),d)
    return out
a=load(sys.argv[1]); b=load(sys.argv[2])
for k in sorted(set(a)|set(b), key=lambda k:(int(k[1]),k[0])):
    if k not in a or k not in b: print('missing',k); continue
    diff=[f for f in a[k] if a[k][f]!=b[k].get(f) and f not in ('env_day',)]
    if diff: print(k, diff[:12])
