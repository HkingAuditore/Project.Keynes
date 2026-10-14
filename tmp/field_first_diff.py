import sys

A = sys.argv[1] if len(sys.argv) > 1 else 'tmp/simtrace_tr_a.txt'
B = sys.argv[2] if len(sys.argv) > 2 else 'tmp/simtrace_tr_b.txt'
SKIP = {'gen', 'env', 'build'}


def load(path, tag):
    out = {}
    for line in open(path):
        if not line.startswith(tag + ' '):
            continue
        d = dict(kv.split('=', 1) for kv in line.split()[1:] if '=' in kv)
        out.setdefault(d.get('day'), d)
    return out


for tag in ('[climate-round-in]', '[climate-sub-in]', '[economy-input]', '[env-fields]', '[econ-data]'):
    a, b = load(A, tag), load(B, tag)
    first = {}
    for day in sorted(set(a) & set(b), key=lambda x: int(x)):
        for f, v in a[day].items():
            if f in SKIP or f == 'day':
                continue
            if v != b[day].get(f) and f not in first:
                first[f] = int(day)
    print(tag, len(a), len(b), sorted(first.items(), key=lambda x: x[1])[:30])
