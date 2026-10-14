import re, sys

def counts(path):
    out = {}
    pending = 0
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("[main-write] fn=capture_runtime_inputs"):
            pending += 1
        elif line.startswith("[input-capture]"):
            m = re.search(r"day=(\d+)", line)
            if m:
                out[int(m.group(1))] = pending
            pending = 0
    return out

runs = [counts(p) for p in sys.argv[1:]]
days = sorted(set().union(*runs))
for d in days:
    vals = [r.get(d, "-") for r in runs]
    if len(set(vals)) > 1 or any(v != 1 and v != "-" for v in vals):
        print(d, vals)
