import glob
import re
import sys

PAT = re.compile(r"\[sim-day-trace\] (.*)")


def load(label):
    path = f"tmp/simtrace_{label}.txt"
    rows = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = PAT.search(line)
        if not m:
            continue
        fields = dict(re.findall(r"(\w+)=(\S+)", m[1]))
        if "effect_hash" not in fields:
            continue
        rows[int(fields["day"])] = fields
    return rows


a, b = load(sys.argv[1]), load(sys.argv[2])
keys = ["input_day", "input_hash", "env_day", "econ_day", "econ_sample", "econ_hash",
        "climate_hash", "trigger_hash", "modifier_hash", "effect_hash"]
first = {}
for day in sorted(set(a) & set(b)):
    for k in keys:
        if k not in first and a[day].get(k) != b[day].get(k):
            first[k] = day
print("first differing day per field:")
for k in keys:
    print(f"  {k:14s} {first.get(k, '-')}")
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 12
start = min(first.values()) if first else 0
print("\nrows around first divergence:")
for day in sorted(set(a) & set(b)):
    if start - 3 <= day <= start + limit:
        da, db = a[day], b[day]
        diff = [k for k in keys if da.get(k) != db.get(k)]
        print(f"day {day}: input {da['input_day']}/{db['input_day']} env {da['env_day']}/{db['env_day']} "
              f"econ_day {da['econ_day']}/{db['econ_day']} sample {da['econ_sample']}/{db['econ_sample']} diff={diff}")
