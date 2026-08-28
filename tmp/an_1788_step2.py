import csv, collections

BASE = "tmp/economy_record_20260828_231131_v25_cell1788_q34_r29_"

def load(name):
    with open(BASE + name + ".csv", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def f(x):
    try:
        return float(x)
    except Exception:
        return 0.0

# ---------------- buildings ----------------
b = load("buildings")
days = sorted({int(r["day_index"]) for r in b})
first_day, last_day = days[0], days[-1]

print("buildings rows=%d  rows/day=%.2f" % (len(b), len(b) / len(days)))
key = lambda r: (r["is_construction"], r["group_index"], r["type_id"], r["owner_signature_id"])
groups = collections.OrderedDict()
for r in b:
    groups.setdefault(key(r), []).append(r)
print("distinct building rows-classes = %d" % len(groups))

print("\n%-6s %-8s %-8s %-6s %-6s %-6s %-6s %-6s %-6s %-8s %-10s %-12s %s" % (
    "grp", "type", "ownsig", "cnt", "ocap", "oreq", "ofill", "oopen", "ereq", "efill", "state", "cap_q16", "margin_q16"))
for k, rows in groups.items():
    r0, rl = rows[0], rows[-1]
    print("%-6s %-8s %-8s %-6s %-6s %-6s %-6s %-6s %-6s %-8s %-10s %-12s %s" % (
        k[1], k[2], k[3], rl["count"], rl["owner_capacity"], rl["owner_required"],
        rl["filled_owner"], rl["owner_openings"], rl["employee_required"], rl["employee_filled"],
        rl["operating_state"], rl["capacity_q16"], rl["realized_profit_margin_q16"]))

print("\n-- employee demand over whole run --")
tot_ereq = collections.Counter()
for r in b:
    tot_ereq[(r["group_index"], r["type_id"])] += f(r["employee_required"])
print("  any group with employee_required>0 ever:",
      [k for k, v in tot_ereq.items() if v > 0] or "NONE")
print("  max owner_openings ever:", max(f(r["owner_openings"]) for r in b))
print("  distinct operating_state:", collections.Counter(r["operating_state"] for r in b))
print("  distinct wage_suspended:", collections.Counter(r["wage_suspended"] for r in b))
print("  distinct investment_candidate:", collections.Counter(r["investment_candidate"] for r in b))
print("  distinct investment_rejection_reason:", collections.Counter(r["investment_rejection_reason"] for r in b))

# which building columns actually change
cols = list(b[0].keys())
per_group_moving = collections.Counter()
for k, rows in groups.items():
    for c in cols:
        if c in ("epoch_row_id", "epoch_id", "day_index"):
            continue
        if len({r[c] for r in rows}) > 1:
            per_group_moving[c] += 1
print("\n-- building columns that vary within at least one group (col: #groups) --")
for c, n in per_group_moving.most_common():
    print("   %-46s %d" % (c, n))
