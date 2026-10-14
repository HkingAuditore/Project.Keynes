import sys

KEYS = ('base', 'soil', 'moist', 'temp', 'wtype', 'wint', 'veg', 'tta')


def segments(path):
    """Main-thread writes grouped by the input-capture day that follows them."""
    out = {}
    pending = []
    last = None
    for line in open(path):
        if line.startswith('[main-write]'):
            fields = dict(kv.split('=', 1) for kv in line.split()[1:] if '=' in kv)
            changed = [k for k in KEYS if last is not None and fields[k] != last[k]]
            last = fields
            pending.append((fields['fn'], fields['committed'], tuple(changed),
                            fields['base']))
        elif line.startswith('[input-capture]'):
            day = int(line.split('day=')[1].split()[0])
            out.setdefault(day, []).extend(pending)
            pending = []
    return out


a = segments(sys.argv[1] if len(sys.argv) > 1 else 'tmp/simtrace_tr_a.txt')
b = segments(sys.argv[2] if len(sys.argv) > 2 else 'tmp/simtrace_tr_b.txt')


def writers(seg):
    return [(fn, ch) for fn, _c, ch, _b in seg if ch]


shown = 0
for day in sorted(set(a) & set(b)):
    wa, wb = writers(a[day]), writers(b[day])
    base_a = a[day][-1][3] if a[day] else None
    base_b = b[day][-1][3] if b[day] else None
    if wa != wb or base_a != base_b:
        print('day', day, 'base_at_capture_equal=', base_a == base_b)
        print('  A:', wa)
        print('  B:', wb)
        shown += 1
        if shown >= 6:
            break
if shown == 0:
    print('no difference in main-thread write segments')
