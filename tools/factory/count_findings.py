"""Count Qodo findings by class from docs/factory/qodo-findings-2026-11-22.json (Day 5 evidence).

Each row is one finding on one of our PRs; the rows judged to be the gate-input class carry
`class: gate-input`. Prints totals; the numbers in AGENTS.md rule 6 come from this output.
"""

import json
import sys
from collections import Counter
from pathlib import Path

DATA = Path(__file__).resolve().parents[2] / "docs/factory/qodo-findings-2026-11-22.json"


def count(path: Path = DATA) -> dict:
    rows = json.loads(path.read_text())["findings"]
    classed = [r for r in rows if r.get("class") == "gate-input"]
    return {"total": len(rows), "gate_input": len(classed),
            "prs_total": len({r["pr"] for r in rows}), "prs_gate_input": len({r["pr"] for r in classed}),
            "by_level": dict(Counter(r["level"] for r in classed))}


if __name__ == "__main__":
    json.dump(count(), sys.stdout, indent=1)
    print()
