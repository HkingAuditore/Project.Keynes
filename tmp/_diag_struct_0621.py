import pandas as pd, numpy as np
from collections import Counter

CSV = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260621_024425.csv'

cols = ['tick_idx','phys_sim_day','was_skipped_day','cell_index']
rows = 0
ticks = set()
days = set()
skipped = Counter()
tick_rows = Counter()
day_ticks = {}        # sim_day -> set(tick)
tick_skipflag = {}    # tick -> set(skipflag)

for ch in pd.read_csv(CSV, usecols=cols, chunksize=500000):
    rows += len(ch)
    tk = ch['tick_idx'].astype(int).values
    sd = ch['phys_sim_day'].astype(int).values
    sk = ch['was_skipped_day'].astype(str).values
    for t in np.unique(tk):
        tick_rows[int(t)] += int((tk == t).sum())
    ticks.update(np.unique(tk).tolist())
    days.update(np.unique(sd).tolist())
    for s in sk:
        skipped[s] += 1
    # day -> ticks
    df = pd.DataFrame({'t': tk, 'd': sd, 's': sk})
    for d, sub in df.groupby('d'):
        day_ticks.setdefault(int(d), set()).update(sub['t'].unique().tolist())
    for t, sub in df.groupby('t'):
        tick_skipflag.setdefault(int(t), set()).update(sub['s'].unique().tolist())

print(f"total_rows = {rows:,}")
print(f"unique_ticks = {len(ticks)}  range = [{min(ticks)}, {max(ticks)}]")
print(f"unique_sim_days = {len(days)}  range = [{min(days)}, {max(days)}]")
print(f"skipped flag dist = {dict(skipped)}")
print(f"rows per tick: min={min(tick_rows.values())} max={max(tick_rows.values())}")

# how many ticks per sim_day (cadence)
dt = sorted(day_ticks.items())
print(f"\nsim_day count = {len(dt)}")
print("first 10 (sim_day -> n_ticks):", [(d, len(s)) for d, s in dt[:10]])
print("last 10  (sim_day -> n_ticks):", [(d, len(s)) for d, s in dt[-10:]])

# per-tick skip flag: how many ticks are pure-skipped vs not
pure_skip = sum(1 for t, fl in tick_skipflag.items() if fl == {'true'})
pure_noskip = sum(1 for t, fl in tick_skipflag.items() if fl == {'false'})
mixed = len(tick_skipflag) - pure_skip - pure_noskip
print(f"\nticks all-skipped(true)={pure_skip}  all-noskip(false)={pure_noskip}  mixed={mixed}")

# distinct (sim_day) advanced count = how many real weather-evolving days
print(f"\n>>> distinct sim_days that the data spans = {len(days)}")
