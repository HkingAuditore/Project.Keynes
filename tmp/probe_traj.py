import glob
import pandas as pd


def snap(label, day):
    df = pd.read_csv(sorted(glob.glob(f"tmp/country_ai_record_*_{label}.csv"))[-1])
    return df[df.day <= day].sort_values("day").groupby("slot").tail(1)


for seed in ["20260719", "20260718", "3"]:
    print("== seed", seed)
    print("year  pop(rr/sf)     kgeo(rr/sf)    load(rr/sf)  sat(rr/sf)   ess(rr/sf)")
    for y in [3, 6, 9, 12, 15, 18, 21, 25]:
        a = snap("rr_probe_" + seed, y * 365)
        b = snap("sf_probe_" + seed, y * 365)
        s = lambda d, c: d[c].sum()
        m = lambda d, c: d[c].mean() / 65536
        print(f"{y:3d}  {s(a,'population'):5.0f}/{s(b,'population'):<5.0f}  "
              f"{s(a,'carrying_k_geo'):6.0f}/{s(b,'carrying_k_geo'):<6.0f}  "
              f"{m(a,'carrying_load_q16'):4.2f}/{m(b,'carrying_load_q16'):<4.2f}  "
              f"{m(a,'satisfaction_q16'):4.2f}/{m(b,'satisfaction_q16'):<4.2f}  "
              f"{m(a,'essentials_q16'):4.2f}/{m(b,'essentials_q16'):<4.2f}")
