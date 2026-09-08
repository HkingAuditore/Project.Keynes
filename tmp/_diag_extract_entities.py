import json
from pathlib import Path

d = json.loads(
    Path("tmp/economy_record_20260901_164046_v25_cell1522_q15_r15_profile.json").read_text(
        encoding="utf-8"
    )
)

# dump full table integrity fields
for kind, t in d["tables"].items():
    print(f"\n==== {kind} ====")
    for k, v in t.items():
        if k == "columns":
            print("columns_count", len(v))
            continue
        print(f"{k}: {v}")

print("\n==== summary structure keys ===", list(d["summary"].keys()))
# series_index may have aggregates
si = d.get("series_index", {})
print("series_index keys sample", list(si.keys())[:20] if isinstance(si, dict) else type(si))

# print all cohort entities compact
print("\n==== cohorts ===")
for c in d["entities"]["cohorts"]:
    print(json.dumps({
        "sig": c.get("signature_id"),
        "prof": c.get("profession_id_stable") or c.get("profession_id"),
        "merchant": c.get("is_merchant"),
        "pop": [c["first"]["population"], c["last"]["population"], c.get("population_delta")],
        "funds_pc": [round(c["first"]["funds_per_capita"]/10000,2), round(c["last"]["funds_per_capita"]/10000,2)],
        "sat": [c["first"]["satisfaction_q16"], c["last"]["satisfaction_q16"], c.get("min_satisfaction_q16")],
        "cov": [c["first"]["livelihood_coverage_q16"], c["last"]["livelihood_coverage_q16"], c.get("min_livelihood_coverage_q16")],
        "worst_need": c.get("worst_need_last_stable"),
        "days": [c["first"]["day"], c["last"]["day"]],
    }, ensure_ascii=False))

print("\n==== building_types ===")
for b in d["entities"]["building_types"]:
    print(json.dumps(b, ensure_ascii=False)[:500])

print("\n==== building_row_classes ===")
print(json.dumps(d["entities"].get("building_row_classes"), ensure_ascii=False, indent=2))
print("\n==== investment_rejection_counts ===")
print(json.dumps(d["entities"].get("investment_rejection_counts"), ensure_ascii=False, indent=2)[:3000])

print("\n==== resources top deplete / critical ===")
ress = d["entities"]["resources"]
# each resource structure
print("resource keys", list(ress[0].keys()) if ress else None)
for r in sorted(ress, key=lambda x: (x.get("depletion_share") is not None, x.get("depletion_share") or -1), reverse=True)[:15]:
    print(json.dumps({k: r.get(k) for k in ["resource_id","resource_stable_id","first_reserve","last_reserve","min_reserve","depletion_share","last_projected_life","min_projected_life","sum_artificial_extraction_applied","sum_natural_negative_change"]}, ensure_ascii=False))

print("\n==== market_goods shortage-ish ===")
goods = d["entities"]["market_goods"]
print("good keys", list(goods[0].keys())[:40])
# sort by late shortage
def late_sh(g):
    late = g.get("late") or g.get("last") or {}
    return late.get("shortage_q16") or g.get("late_shortage_q16") or 0
for g in sorted(goods, key=late_sh, reverse=True)[:20]:
    print(json.dumps(g, ensure_ascii=False)[:450])

# correlations that involve deaths, shortage, population
print("\n==== top first_difference correlations involving key terms ===")
corr = d.get("correlations", {})
for section in ["top_first_difference", "top_lagged_first_difference", "top_level"]:
    items = corr.get(section) or []
    print(f"\n-- {section} --")
    for it in items[:12]:
        print(json.dumps(it, ensure_ascii=False)[:300])
