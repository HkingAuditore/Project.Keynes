#!/usr/bin/env python3
"""Check the single descriptor for native daily save sections.

This is deliberately a contract check: it verifies ownership, version guards,
and the declared restore DAG. It does not pretend to prove C++ alias analysis.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = Path("tools/ci/cpp_save_section_contracts.json")

def violations(root: Path) -> list[str]:
    data = json.loads((root / REGISTRY).read_text())
    rows = data.get("sections", [])
    errors: list[str] = []
    domains = [row.get("domain") for row in rows]
    if len(rows) != 12 or len(set(domains)) != len(domains):
        errors.append("descriptor must contain 12 unique domains")
    tags = [row.get("tag") for row in rows]
    if any(not isinstance(row.get("version"), int) or row["version"] <= 0 for row in rows):
        errors.append("every section needs a positive integer version")
    if len(set(tags)) != len(set((row.get("tag"), row.get("owner")) for row in rows)):
        errors.append("same tag is used by incompatible owners")
    known = {row.get("owner") for row in rows}
    for row in rows:
        source = root / row["source"]
        if not source.exists():
            errors.append(f"missing save owner source {row['source']}")
            continue
        text = source.read_text()
        for token in row.get("tokens", []):
            if token not in text:
                errors.append(f"{row['domain']} missing version/reject evidence: {token}")
        for dep in row.get("restore_after", []):
            if dep not in domains and dep not in known:
                errors.append(f"{row['domain']} dependency is not registered: {dep}")
    order = data.get("restore_order", [])
    positions = {name: i for i, name in enumerate(order)}
    for row in rows:
        if row["domain"] not in positions and row["domain"] not in {"family", "technology", "climate"}:
            errors.append(f"{row['domain']} missing restore order position")
        for dep in row.get("restore_after", []):
            if dep in positions and row["domain"] in positions and positions[dep] > positions[row["domain"]]:
                errors.append(f"restore order violation: {row['domain']} before {dep}")
    if len(order) != len(set(order)):
        errors.append("restore order contains duplicates")
    return errors

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(); errors = violations(args.root)
    for error in errors: print(error)
    print(f"C++ save section contracts: 12 domains, {len(errors)} violations")
    return 1 if errors else 0

if __name__ == "__main__": raise SystemExit(main())
