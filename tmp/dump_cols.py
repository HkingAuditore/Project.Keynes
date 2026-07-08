import csv, sys
csv.field_size_limit(sys.maxsize)
path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260707_202818.csv"
with open(path, newline='', encoding='utf-8-sig') as f:
    r = csv.reader(f)
    header = next(r)
keys = ['native_daily','ocean','phys_','_phys','wind_','psi','slp','upwell','current','stage_','slice','job']
seen = [h for h in header if any(k in h.lower() for k in keys)]
print("NUM CANDIDATE COLS:", len(seen))
for h in seen:
    print(h)
