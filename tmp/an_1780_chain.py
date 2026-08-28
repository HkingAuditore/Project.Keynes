import csv
from collections import defaultdict, Counter

BASE = "tmp/economy_record_20260829_013229_v25_cell1780_q26_r29_"


def load(name):
    with open(BASE + name + ".csv", newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def i(row, key, default=0):
    v = row.get(key, "")
    return int(v) if v not in ("", None) else default


diag = [r for r in load("buildings") if r.get("employment_candidate") == "1"]
owners = defaultdict(list)
for r in diag:
    if i(r, "employment_role", -1) < 0:
        owners[(i(r, "employment_group"), i(r, "type_id"))].append(r)

print("=" * 96)
print("Per-day clamp chain, owner vacancies")
print("=" * 96)
for key in sorted(owners):
    rows = sorted(owners[key], key=lambda r: i(r, "day_index"))
    pat = Counter()
    for r in rows:
        pat[(i(r, "employment_filled_before_clamp"),
             i(r, "employment_filled_after_profession_clamp"),
             i(r, "employment_filled_after_family_clamp"),
             i(r, "employment_owner_cohort_population"),
             i(r, "employment_family_owned"),
             i(r, "employment_family_member_people"),
             i(r, "employment_anonymous_people"),
             i(r, "employment_shed_surplus"))] += 1
    print(f"\n-- group{key[0]} type{key[1]} owner "
          f"(target={i(rows[-1],'employment_owner_target')}) --")
    print("   (before, afterProf, afterFam, cohortPop, famOwned, famMembers,"
          " anon, shed) : days")
    for k, n in pat.most_common(8):
        print(f"   {k} : {n}")

print()
print("=" * 96)
print("Building group state over time (recorder view)")
print("=" * 96)
b = [r for r in load("buildings")
     if i(r, "group_index", -99) >= 0 and r.get("is_construction") == "0"]
groups = defaultdict(list)
for r in b:
    groups[(i(r, "group_index"), i(r, "type_id"))].append(r)
for key in sorted(groups):
    rows = sorted(groups[key], key=lambda r: i(r, "day_index"))
    fo = Counter(i(r, "filled_owner") for r in rows)
    print(f"  group{key[0]} type{key[1]}: count={i(rows[-1],'count')} "
          f"owner_required={i(rows[-1],'owner_required')} "
          f"filled_owner distribution={dict(fo)}")

print()
print("=" * 96)
print("Cohorts in the cell: does the owner cohort ever grow?")
print("=" * 96)
co = load("cohorts")
by_sig = defaultdict(list)
for r in co:
    by_sig[i(r, "signature_id")].append(r)
for sig in sorted(by_sig):
    rows = sorted(by_sig[sig], key=lambda r: i(r, "day_index"))
    pops = Counter(i(r, "population") for r in rows)
    print(f"  sig{sig} prof={i(rows[0],'profession_id')}: "
          f"pop distribution={dict(pops)}  "
          f"owner_emp={sorted({i(r,'owner_employed') for r in rows})}  "
          f"unemp={sorted({i(r,'unemployed') for r in rows})}")
    print(f"     funds {i(rows[0],'funds'):,} -> {i(rows[-1],'funds'):,}")

print()
print("=" * 96)
print("Day-by-day sample: hire vs next-day filled_owner (group2 type103)")
print("=" * 96)
g2 = {i(r, "day_index"): r for r in owners[(2, 103)]}
g2b = {i(r, "day_index"): r for r in groups[(2, 103)]}
days = sorted(set(g2) & set(g2b))
print("  day | before afterP afterF | take | recorder filled_owner | cohortPop anon")
for d in days[:14] + days[-6:]:
    a, bb = g2[d], g2b[d]
    print(f"{d:5d} | {i(a,'employment_filled_before_clamp'):6d} "
          f"{i(a,'employment_filled_after_profession_clamp'):6d} "
          f"{i(a,'employment_filled_after_family_clamp'):6d} | "
          f"{i(a,'employment_take'):4d} | {i(bb,'filled_owner'):21d} | "
          f"{i(a,'employment_owner_cohort_population'):9d} "
          f"{i(a,'employment_anonymous_people'):4d}")
