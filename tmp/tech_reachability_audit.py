"""Static discover/research reachability audit for technology_network.json.

Mirrors NativeCountryRuntime::refresh_discovery_for_technology and the compiled
research-condition AND tree (TechnologyCatalog._compile_research_conditions).
"""
import json
import sys
from collections import Counter, defaultdict

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json"
data = json.load(open(PATH, encoding="utf-8"))
nodes = data["nodes"]
by_id = {t["id"]: t for t in nodes}
era_order = {e["id"]: i for i, e in enumerate(data["eras"])}
milestone_of_era = {e["id"]: e["milestone_id"] for e in data["eras"]}
milestone_rows = {e["milestone_id"]: e for e in data["eras"]}

STARTERS = ["tech.gathering", "tech.hunting", "tech.early_trade",
            "tech.deadwood_collection"]
STARTER_VARIANTS = {
    "gold_warm": STARTERS + ["tech.gold_panning"],
    "silver_cold": STARTERS + ["tech.surface_silver_collection", "tech.hide_scraping"],
}
BOOT_REVEALED = {"tech.early_knowledge_institution"}


def atoms(cond):
    if not cond:
        return
    if "kind" in cond:
        yield cond
        return
    if int(cond.get("operator", -1)) == 0 and "atom" in cond:
        yield from atoms(cond["atom"])
        return
    for ch in cond.get("children", []):
        yield from atoms(ch)


def evaluate(cond, done, signals):
    if "kind" in cond:
        kind = int(cond["kind"])
        if kind == 0:
            return cond["id"] in done
        return cond["id"] in signals
    op = int(cond.get("operator", -1))
    if op == 0:
        return evaluate(cond["atom"], done, signals)
    vals = [evaluate(c, done, signals) for c in cond.get("children", [])]
    if op == 1:
        return all(vals)
    if op == 2:
        return any(vals)
    if op == 3:
        return sum(vals) >= int(cond.get("required_count", 0))
    if op == 5:
        return not vals[0]
    raise ValueError(op)


def research_ok(t, done, signals):
    tid = t["id"]
    for p in t.get("hard_prerequisite_ids", []):
        if p not in done:
            return False
    if tid in milestone_rows:
        row = milestone_rows[tid]
        have = sum(1 for c in row["milestone_candidate_ids"] if c in done)
        if have < int(row["candidate_required"]):
            return False
        entry = row.get("entry_milestone_id", "")
        if entry and entry not in done:
            return False
    routes = t.get("research_routes", [])
    if routes and not any(evaluate(r["condition"], done, signals) for r in routes):
        return False
    return True


def discovered(t, done, signals):
    tid = t["id"]
    if tid in done or tid in BOOT_REVEALED:
        return True
    reveal = t.get("reveal_condition") or {}
    if reveal:
        return evaluate(reveal, done, signals)
    if tid in milestone_rows:
        return any(c in done for c in milestone_rows[tid]["milestone_candidate_ids"])
    return any(p in done for p in t.get("hard_prerequisite_ids", []))


def closure(start, signals):
    done = set(start)
    changed = True
    while changed:
        changed = False
        for t in nodes:
            if t["id"] in done:
                continue
            if discovered(t, done, signals) and research_ok(t, done, signals):
                done.add(t["id"])
                changed = True
    return done


all_signals = set()
for t in nodes:
    for a in atoms(t.get("reveal_condition") or {}):
        if int(a["kind"]) != 0:
            all_signals.add(a["id"])
    for r in t.get("research_routes", []):
        for a in atoms(r["condition"]):
            if int(a["kind"]) != 0:
                all_signals.add(a["id"])


def explain(t, done, signals):
    reasons = []
    if not discovered(t, done, signals):
        reveal = t.get("reveal_condition") or {}
        if reveal:
            reasons.append("reveal_unmet")
        elif t["id"] in milestone_rows:
            reasons.append("milestone_no_candidate")
        elif not t.get("hard_prerequisite_ids"):
            reasons.append("NEVER_REVEALED(empty reveal + no hard prereq)")
        else:
            reasons.append("no_prereq_done")
    missing = [p for p in t.get("hard_prerequisite_ids", []) if p not in done]
    if missing:
        reasons.append("hard_missing=" + ",".join(missing))
    routes = t.get("research_routes", [])
    if routes and not any(evaluate(r["condition"], done, signals) for r in routes):
        reasons.append("no_route")
    if t["id"] in milestone_rows:
        row = milestone_rows[t["id"]]
        have = sum(1 for c in row["milestone_candidate_ids"] if c in done)
        if have < int(row["candidate_required"]):
            reasons.append("candidates %d/%d" % (have, int(row["candidate_required"])))
    return reasons


def report(label, start, signals):
    done = closure(start, signals)
    stuck = [t for t in nodes if t["id"] not in done]
    print("== %s: completed %d/%d, stuck %d" % (label, len(done), len(nodes), len(stuck)))
    roots = []
    for t in stuck:
        r = explain(t, done, signals)
        # a "root" blocker is stuck for a reason other than missing stuck prereqs
        if not any(x.startswith("hard_missing") for x in r) or any(
                x.startswith("NEVER") or x == "reveal_unmet" or x == "no_route" for x in r):
            roots.append((t, r))
    for t, r in sorted(roots, key=lambda x: era_order[x[0]["era_id"]]):
        print("   ROOT %-40s %-13s %s" % (t["id"], t["era_id"], "; ".join(r)))
    return done


if __name__ == "__main__":
    full = None
    for name, start in STARTER_VARIANTS.items():
        full = report("all-signals/" + name, start, all_signals)

    # Per-signal criticality with all other signals present.
    base = closure(STARTER_VARIANTS["gold_warm"], all_signals)
    crit = []
    for s in sorted(all_signals):
        lost = base - closure(STARTER_VARIANTS["gold_warm"], all_signals - {s})
        if lost:
            crit.append((len(lost), s, sorted(lost, key=lambda x: era_order[by_id[x]["era_id"]])))
    crit.sort(reverse=True)
    print("== single-signal hard dependencies (lost tech count when only that signal is absent)")
    for count, s, lost in crit:
        print("   %3d  %-45s %s" % (count, s, ", ".join(lost[:6]) + (" ..." if len(lost) > 6 else "")))

    # Category removal.
    for prefix in ["contact.", "breakthrough.", "development.", "weather."]:
        lost = base - closure(STARTER_VARIANTS["gold_warm"],
                              {s for s in all_signals if not s.startswith(prefix)})
        print("== without %s*: lose %d techs" % (prefix, len(lost)))
        eras = Counter(by_id[x]["era_id"] for x in lost)
        print("   by era:", dict(sorted(eras.items(), key=lambda kv: era_order[kv[0]])))
