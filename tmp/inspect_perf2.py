import csv, sys

path = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_record_20260707_215611.csv"
with open(path, newline='', encoding='utf-8', errors='replace') as f:
    r = csv.reader(f)
    header = next(r)
    ncols = len(header)
    nrows = sum(1 for _ in r)

print("ncols", ncols)
print("nrows", nrows)

families = ['t_sus', 'j_native_daily_sim', 'j_ocean_currents', 'enum_atlas',
            'bd_climate', 'bd_weather', 't_natres', 't_dyn_atlas', 't_season',
            'j_']
counts = {}
for h in header:
    for p in families:
        if h.startswith(p):
            counts[p] = counts.get(p, 0) + 1
            break
print("family_counts", counts)

# Show full list of j_ family columns (these are the per-job timers)
j_cols = [h for h in header if h.startswith('j_')]
print("=== j_ columns (count=%d) ===" % len(j_cols))
for h in j_cols:
    print(h)
