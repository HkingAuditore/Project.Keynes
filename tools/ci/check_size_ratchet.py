#!/usr/bin/env python3
"""Reject growth above review thresholds, without grandfathering new files.

Physical lines, including comments/blanks, are intentional. Baselines are
reviewed files, never updated by the default regression command.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Explicit ownership, not a loose filename heuristic. New orchestrators must
# be registered here; ordinary leaf files use the language threshold.
ORCHESTRATORS = {
    "Project/project-keynes/scripts/main.gd",
    "Project/project-keynes/scripts/game/world_runtime_host.gd",
    "Project/project-keynes/scripts/game/game_save_coordinator.gd",
    "Project/project-keynes/scripts/geography/map_generator.gd",
    "Project/project-keynes/scripts/rendering/map_baker.gd",
    "gdext/src/native_simulation_host.cpp",
    "gdext/src/native_simulation_host.h",
}
EXCLUDED_PARTS = {"tests", "addons", ".godot", ".git", "generated", "build", "Build"}


def measure(root: Path) -> dict[str, dict[str, int]]:
    result = {}
    candidates = list((root / "Project/project-keynes").rglob("*.gd"))
    candidates += list((root / "gdext/src").rglob("*.cpp"))
    candidates += list((root / "gdext/src").rglob("*.h"))
    for path in sorted(candidates):
        relative = path.relative_to(root)
        if (EXCLUDED_PARTS.intersection(relative.parts) or ".gen." in path.name
                or ".generated." in path.name or path.stem.endswith("_generated")):
            continue
        name = relative.as_posix()
        limit = 600 if name in ORCHESTRATORS else (800 if path.suffix == ".gd" else 2000)
        lines = len(path.read_text(encoding="utf-8").splitlines())
        result[name] = {"lines": lines, "limit": limit}
    return result


def violations(current: dict, baseline: dict) -> list[str]:
    errors = []
    for name, entry in current.items():
        allowed = max(entry["limit"], baseline.get(name, {}).get("lines", 0))
        if entry["lines"] > allowed:
            errors.append(f"{name}: {entry['lines']} lines > {allowed} (threshold {entry['limit']})")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=Path(__file__).with_name("size_baseline.json"))
    parser.add_argument("--write-baseline", action="store_true", help="explicit reviewed snapshot only")
    args = parser.parse_args()
    current = measure(args.root)
    if args.write_baseline:
        args.baseline.write_text(json.dumps({"version": 1, "files": {
            name: entry for name, entry in current.items() if entry["lines"] > entry["limit"]
        }}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return 0
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    errors = violations(current, baseline["files"])
    print(f"size ratchet: {len(current)} files, {len(errors)} violations")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
