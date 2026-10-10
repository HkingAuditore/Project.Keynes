import collections
import csv
import sys
from pathlib import Path

root = Path(sys.argv[1])
step = int(sys.argv[2]) if len(sys.argv) > 2 else 50


def load(name):
    with open(root / name, encoding="utf-8") as f:
        return list(csv.DictReader(f))


fam = load("families.csv")
hold = load("holdings.csv")
events = load("events.csv")
by = collections.defaultdict(list)
for r in fam:
    by[r["family_handle"]].append(r)
days = sorted({int(r["day"]) for r in fam})
print(f"days {days[0]}..{days[-1]} samples={len(days)} families_seen={len(by)}")
print("events:", collections.Counter(e["event"] for e in events))
for e in events:
    if e["event"] == "dissolved":
        print("  dissolved", e)

print("\n== per-family trajectory (pop / cash(万) / buildings / snapshot-asset / branch-asset / professions)")
for h, rs in by.items():
    print(f"family ..{h[-4:]} home={rs[-1]['home_cell']} founded={rs[0]['founded_day']} flags={rs[0]['flags']}")
    last = None
    for r in rs:
        d = int(r["day"])
        if last is not None and d - last < step and r is not rs[-1]:
            continue
        last = d
        print(f"   d{d:5d} pop={int(r['population']):4d} cash={int(r['cash_claim'])/1e4:10.1f} "
              f"bld={int(r['owned_buildings']):3d} snapA={int(r['snapshot_asset_value'])/1e4:8.1f} "
              f"branchA={int(r['branch_building_asset'])/1e4:9.1f} decl={r['decline_reviews']} {r['professions']}")

print("\n== holdings: owned units vs family-filled owner posts (last sample per family)")
last_day = days[-1]
tot_owned = tot_slots_family = tot_slots_cap = 0
for r in hold:
    if int(r["day"]) != last_day:
        continue
    owned = int(r["owned_count"] or 0)
    group = int(r["group_count"] or 0) or 1
    cap = int(r["owner_capacity"] or 0)
    family_cap = cap * owned // group
    tot_owned += owned
    tot_slots_family += int(r["family_filled_owner"] or 0)
    tot_slots_cap += family_cap
    print(f"  ..{r['family_handle'][-4:]} cell={r['cell']} {r['building_type']:<28} owner_prof={r['owner_profession'] or '(no cohort)':<10} "
          f"owned={owned}/{group} family_owner_posts={r['family_filled_owner']}/{family_cap} "
          f"group_owner_filled={r['group_filled_owner']}/{cap} state={r['operating_state']} "
          f"rev={r['last_revenue']} cost={r['last_operating_cost']} "
          f"cohort_pop={r['owner_cohort_population']} family_people_in_cell={r['family_people_in_cell']}")
print(f"  TOTAL owned units={tot_owned} family-owned owner posts filled by family={tot_slots_family}/{tot_slots_cap}")
