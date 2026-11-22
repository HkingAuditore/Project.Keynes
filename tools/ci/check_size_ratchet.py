#!/usr/bin/env python3
"""Check source line counts against review thresholds.

New files must stay within their threshold. Files in the baseline must stay
at or below their recorded count.
Physical lines include comments and blanks. --write-baseline only lowers or
drops existing entries and saves any tightening before reporting growth and new
oversized files as errors.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GROWTH_ALLOWANCE = 0
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
    candidates += list((root / "gdext/src").rglob("*.inc"))  # included bodies count like the .cpp they extend
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
        allowed = entry["limit"]
        if name in baseline:
            allowed = baseline[name]["lines"] + GROWTH_ALLOWANCE
        if entry["lines"] > allowed:
            errors.append(f"{name}: {entry['lines']} lines > {allowed} (threshold {entry['limit']})")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=Path(__file__).with_name("size_baseline.json"))
    parser.add_argument("--write-baseline", action="store_true",
                        help="save reductions and removals, then report growth and new oversized files as errors")
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))["files"]
    current = measure(args.root)

    warnings = 0
    for name, entry in current.items():
        if name not in baseline or entry["lines"] <= baseline[name]["lines"]:
            continue
        message = (
            f"{name} grew {baseline[name]['lines']} -> {entry['lines']} lines (threshold {entry['limit']}); "
            "split it before adding more, see docs/architecture/development-guide.md"
        )
        growth_is_error = args.write_baseline or entry["lines"] > baseline[name]["lines"] + GROWTH_ALLOWANCE
        if not growth_is_error:
            print(f"warning: {message}")
            warnings += 1
        if os.environ.get("GITHUB_ACTIONS") == "true":
            level = "error" if growth_is_error else "warning"
            print(f"::{level} file={name}::{message}")

    baseline_summary = ""
    if args.write_baseline:
        candidate = {}
        lowered = 0
        for name, previous in baseline.items():
            entry = current.get(name)
            if entry is None or entry["lines"] <= entry["limit"]:
                continue
            if entry["lines"] < previous["lines"]:
                candidate[name] = entry
                lowered += 1
            else:
                candidate[name] = previous
        if candidate != baseline:
            args.baseline.write_text(json.dumps({"version": 1, "files": candidate},
                                                indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        dropped = len(baseline) - len(candidate)
        baseline_summary = f", baseline entries lowered={lowered}, dropped={dropped}"

        errors = []
        for name, entry in current.items():
            if name not in baseline and entry["lines"] > entry["limit"]:
                errors.append(
                    f"{name}: {entry['lines']} lines > {entry['limit']} (threshold); "
                    "split the file or register it in ORCHESTRATORS only if it is an orchestrator"
                )
            elif name in baseline and entry["lines"] > baseline[name]["lines"]:
                errors.append(
                    f"{name}: {entry['lines']} lines > {baseline[name]['lines']} (baseline); "
                    "cannot raise the baseline"
                )
    else:
        errors = violations(current, baseline)
    print(
        f"size ratchet: {len(current)} files, {len(errors)} violations, "
        f"{warnings} growth warnings{baseline_summary}"
    )
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
