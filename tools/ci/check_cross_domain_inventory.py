#!/usr/bin/env python3
"""Keep the reviewed cross-domain dependency-pair inventory complete."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "tools/ci/cpp_deps_baseline.json"
INVENTORY = ROOT / "tools/ci/cross_domain_inventory.json"


def violations(root: Path = ROOT) -> list[str]:
    baseline = json.loads((root / "tools/ci/cpp_deps_baseline.json").read_text())
    inventory = json.loads((root / "tools/ci/cross_domain_inventory.json").read_text())
    actual = {key.split("|", 2)[1] for key in baseline.get("references", {}) if "|" in key}
    actual |= {key.split("|", 2)[1] for key in baseline.get("contract_references", {}) if "|" in key}
    listed = {row["pair"] for row in inventory.get("pairs", [])}
    errors = []
    for pair in sorted(actual - listed):
        errors.append(f"cross-domain pair missing from inventory: {pair}")
    for pair in sorted(listed - actual):
        errors.append(f"inventory pair has no dependency evidence: {pair}")
    for row in inventory.get("pairs", []):
        if row.get("status") not in {"已迁移", "明确不迁移", "待逐函数核查"}:
            errors.append(f"invalid inventory status: {row.get('pair')}")
    return errors


def main() -> int:
    errors = violations()
    for error in errors:
        print(error)
    print(f"cross-domain inventory: {len(json.loads(INVENTORY.read_text())['pairs'])} pairs, {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
