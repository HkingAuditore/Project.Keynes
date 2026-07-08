import csv
path = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_record_20260707_215611.csv"
with open(path, newline='', encoding='utf-8', errors='replace') as f:
    r = csv.reader(f)
    header = next(r)
# find columns containing these tokens
tokens = ['sus', 'frame', 'tick', 'native_daily_sim', 'ocean_currents', 'enum_atlas',
          'natural_resource', 'season_refresh', 'dynamic_visual']
seen = []
for h in header:
    low = h.lower()
    if any(t in low for t in tokens):
        seen.append(h)
for h in seen:
    print(h)
print("---total matched---", len(seen))
print("---first 40 cols---")
for h in header[:40]:
    print(h)
