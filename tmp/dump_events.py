import csv
from collections import defaultdict
from pathlib import Path
p = Path = __import__("pathlib").Path
pref = Path("tmp/economy_record_20260831_140522_v25_cell650_q45_r10_summary.csv")
births=[]; deaths=[]; dips=[]
with pref.open(encoding="utf-8-sig") as f:
    r=csv.DictReader(f)
    for row in r:
        d=int(row["day_index"])
        b=int(float(row["births"])); dd=int(float(row["deaths"]))
        fo=int(float(row["filled_owner_jobs"]))
        if b: births.append((d,b))
        if dd: deaths.append((d,dd))
        if fo<50: dips.append((d,fo,int(float(row["unemployed_population"])), int(float(row["production_inputs_consumed"]))))
print("births", births)
print("deaths", deaths)
print("owner_dips", dips)
