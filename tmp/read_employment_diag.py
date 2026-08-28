"""Summarize the employment-hiring diagnostics emitted into the buildings CSV.

Usage:
    python tmp/read_employment_diag.py <..._buildings.csv>

Diagnostic rows carry group_index = -2 and employment_candidate = 1. Each row is
one (building group, role, source ethnicity) hiring candidate for the inspector
cell on that day, with the exact gate that rejected it.
"""

import csv
import sys
from collections import Counter, defaultdict

REASONS = {
    0: "NONE (hired)",
    1: "POOL_MISSING        unemployed signature has no cohort slot",
    2: "POOL_EMPTY          pool population <= 0",
    3: "SOURCE_SIGNATURE    pool signature out of range",
    4: "TARGET_SIGNATURE    no signature for profession+ethnicity",
    5: "TARGET_DISPOSABLE   owner target disposable income < 0",
    6: "SURVIVAL_FLOOR      employee wage below survival floor",
    7: "HURDLE              improvement < transition hurdle",
    8: "NO_ALLOCATION       eligible but received zero mobility quota",
    9: "KNOWLEDGE_CAP       knowledge-sector headcount cap",
    10: "SIGNATURE_SELF      target signature == unemployed signature",
    11: "PROFESSION_UNAVAILABLE",
    12: "ZERO_TAKE           quota allocated but take clamped to 0",
}

INT_FIELDS = (
    "employment_role employment_target_signature employment_profession_id "
    "employment_source_ethnicity employment_pool_slot employment_pool_signature "
    "employment_pool_population employment_vacancy employment_target_disposable "
    "employment_source_disposable employment_improvement_q16 employment_hurdle_q16 "
    "employment_weight_q16 employment_budget employment_allocation employment_take "
    "employment_eligible employment_rejection_reason employment_diagnostic_day "
    "employment_group employment_owner_target employment_filled_before_clamp "
    "employment_filled_after_profession_clamp employment_filled_after_family_clamp "
    "employment_family_owned employment_family_member_people "
    "employment_anonymous_people employment_owner_cohort_population "
    "employment_shed_surplus"
).split()


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            if row.get("employment_candidate") != "1":
                continue
            record = {"day": int(row["day_index"]), "type_id": int(row["type_id"]),
                      "group": int(row["group_index"])}
            for field in INT_FIELDS:
                value = row.get(field, "")
                record[field] = int(value) if value not in ("", None) else -1
            rows.append(record)
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    rows = load(sys.argv[1])
    if not rows:
        print("no employment diagnostic rows found.")
        print("the recorded cell must be the inspector-selected cell; select the")
        print("cell on the map before starting the recording.")
        return 1

    days = sorted({r["day"] for r in rows})
    stale = sum(1 for r in rows if r["employment_diagnostic_day"] != r["day"])
    print(f"rows={len(rows)}  days={len(days)} [{days[0]}..{days[-1]}]  "
          f"stale_rows={stale}")
    print()

    print("=== rejection reason totals ===")
    for reason, count in Counter(
            r["employment_rejection_reason"] for r in rows).most_common():
        share = 100.0 * count / len(rows)
        print(f"  {count:7d} ({share:5.1f}%)  {reason:>2}  "
              f"{REASONS.get(reason, 'unknown')}")
    print()

    hires = [r for r in rows if r["employment_take"] > 0]
    print(f"=== hires: {len(hires)} row(s), "
          f"{sum(r['employment_take'] for r in hires)} people ===")
    print()

    print("=== per (group, role) breakdown ===")
    groups = defaultdict(list)
    for r in rows:
        groups[(r["group"], r["type_id"], r["employment_role"])].append(r)
    for key in sorted(groups):
        group, type_id, role = key
        items = groups[key]
        last = items[-1]
        reasons = Counter(r["employment_rejection_reason"] for r in items)
        label = "owner" if role < 0 else f"employee r{role}"
        print(f"  group{group} type{type_id} {label}: {len(items)} rows")
        print(f"    reasons        {dict(reasons)}")
        print(f"    last row day={last['day']} "
              f"eligible={last['employment_eligible']} "
              f"vacancy={last['employment_vacancy']} "
              f"pool_slot={last['employment_pool_slot']} "
              f"pool_pop={last['employment_pool_population']}")
        print(f"    budget={last['employment_budget']} "
              f"weight={last['employment_weight_q16']} "
              f"alloc={last['employment_allocation']} "
              f"take={last['employment_take']}")
        print(f"    target_disp={last['employment_target_disposable']} "
              f"source_disp={last['employment_source_disposable']} "
              f"improvement={last['employment_improvement_q16']} "
              f"hurdle={last['employment_hurdle_q16']}")
    print()

    print("=== owner-slot clamp chain (who evicts the incumbents?) ===")
    if all(r["employment_owner_target"] < 0 for r in rows):
        print("  clamp-chain columns absent: this CSV predates them. Re-record")
        print("  with the current build to attribute the eviction.")
        print()
        return quota_accounting(rows, days)
    print("  A vacancy that reappears every day means the seat is being shed")
    print("  and refilled, not that it was never filled.")
    owners = defaultdict(list)
    for r in rows:
        if r["employment_role"] < 0:
            owners[(r["employment_group"], r["type_id"])].append(r)
    for key in sorted(owners):
        group, type_id = key
        items = owners[key]
        last = items[-1]
        before = last["employment_filled_before_clamp"]
        after_prof = last["employment_filled_after_profession_clamp"]
        after_fam = last["employment_filled_after_family_clamp"]
        if before > after_prof:
            culprit = "PROFESSION clamp (not enough profession population)"
        elif after_prof > after_fam:
            culprit = "FAMILY clamp (family-only slots, too few local members)"
        elif before == after_fam and last["employment_vacancy"] > 0:
            culprit = "none - seat genuinely never filled"
        else:
            culprit = "none"
        print(f"  group{group} type{type_id} owner  (last day {last['day']})")
        print(f"    owner_target={last['employment_owner_target']}  "
              f"filled: before={before} -> after_profession={after_prof} "
              f"-> after_family={after_fam}   vacancy={last['employment_vacancy']}")
        print(f"    family_owned={last['employment_family_owned']} "
              f"family_members={last['employment_family_member_people']} "
              f"anonymous={last['employment_anonymous_people']} "
              f"owner_cohort_pop={last['employment_owner_cohort_population']} "
              f"shed_surplus={last['employment_shed_surplus']}")
        print(f"    => {culprit}")
        churn = sum(1 for r in items
                    if r["employment_filled_before_clamp"] >
                    min(r["employment_filled_after_profession_clamp"],
                        r["employment_filled_after_family_clamp"]))
        print(f"    days where a clamp shed an incumbent: {churn} / {len(items)}")
    print()
    return quota_accounting(rows, days)


def quota_accounting(rows, days):
    print("=== per-day quota accounting (is the budget being wasted?) ===")
    per_day = defaultdict(list)
    for r in rows:
        per_day[r["day"]].append(r)
    wasted_days = 0
    for day in days:
        items = per_day[day]
        budget = max((r["employment_budget"] for r in items), default=0)
        allocated = sum(r["employment_allocation"] for r in items)
        taken = sum(r["employment_take"] for r in items)
        if allocated > 0 and taken == 0:
            wasted_days += 1
    print(f"  days where quota was allocated but nobody was hired: "
          f"{wasted_days} / {len(days)}")
    sample = days[: min(5, len(days))]
    for day in sample:
        items = per_day[day]
        budget = max((r["employment_budget"] for r in items), default=0)
        print(f"  day {day}: budget={budget} "
              f"eligible={sum(r['employment_eligible'] for r in items)}/{len(items)} "
              f"alloc={sum(r['employment_allocation'] for r in items)} "
              f"take={sum(r['employment_take'] for r in items)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
