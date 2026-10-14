import sys

ignore = {'gen', 'env', 'build'}


def load(path, tag):
    rows = {}
    for line in open(path):
        if line.startswith(tag):
            fields = dict(kv.split('=', 1) for kv in line.split()[1:] if '=' in kv)
            rows[fields['day']] = fields
    return rows


a_path = sys.argv[1] if len(sys.argv) > 1 else 'tmp/simtrace_tr_a.txt'
b_path = sys.argv[2] if len(sys.argv) > 2 else 'tmp/simtrace_tr_b.txt'
for tag in ('[economy-input]', '[econ-data]'):
    a = load(a_path, tag)
    b = load(b_path, tag)
    days = sorted(set(a) & set(b), key=int)
    first = None
    for day in days:
        diff = [f for f in a[day] if f not in ignore and a[day][f] != b[day].get(f)]
        if diff:
            first = (day, diff)
            break
    print(tag, 'common_days=%d' % len(days),
          'first_diff=%s' % (str(first) if first else 'none'))
