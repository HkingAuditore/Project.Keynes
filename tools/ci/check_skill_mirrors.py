#!/usr/bin/env python3
"""Ratchet for the per-agent copies of the project skills.

The same skill is checked in under several agent homes (``.agents/skills``,
``.claude/skills``, ``.codex/skills`` ...). ``.agents/skills`` is the canonical
copy: edit a skill there, then run ``--sync <skill>`` to copy it to every home
that already carries that skill. A home may omit a skill entirely.

Existing drift is frozen in ``skill_mirrors_baseline.json`` as the number of
distinct versions per file. The check fails when

- a file drifts that is not in the baseline (new drift),
- a baselined file has more distinct versions than recorded (drift got worse),
- a baselined entry is stale or can be tightened (run ``--write-baseline``;
  the tool refuses to write a baseline that is looser than the current one).

Line endings are normalised before comparing, so a CRLF checkout is not drift.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "tools/ci/skill_mirrors_baseline.json"
CANONICAL = ".agents"
HOME_PATTERN = re.compile(r"^(\.[^/]+)/skills/([^/]+)/(.+)$")


def tracked_skill_files(root: Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8").split("\0") if HOME_PATTERN.match(p)]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def collect(root: Path) -> dict[str, dict[str, dict[str, str]]]:
    """skill -> home -> {relative file: digest}; files deleted from the worktree are skipped."""
    table: dict[str, dict[str, dict[str, str]]] = {}
    for rel in tracked_skill_files(root):
        home, skill, name = HOME_PATTERN.match(rel).groups()
        path = root / rel
        if path.is_file():
            table.setdefault(skill, {}).setdefault(home, {})[name] = digest(path)
    return table


def drift(table: dict[str, dict[str, dict[str, str]]]) -> dict[str, int]:
    """'<skill>/<file>' -> number of distinct versions; a file absent from a home that has the skill counts as one."""
    result: dict[str, int] = {}
    for skill, homes in table.items():
        if len(homes) < 2:
            continue
        for name in sorted({n for files in homes.values() for n in files}):
            versions = {files.get(name, "<missing>") for files in homes.values()}
            if len(versions) > 1:
                result[f"{skill}/{name}"] = len(versions)
    return result


def violations(current: dict[str, int], baseline: dict[str, int]) -> list[str]:
    found = []
    for key, count in sorted(current.items()):
        if key not in baseline:
            found.append(f"new drift: {key} has {count} versions; edit {CANONICAL}/skills and run --sync")
        elif count > baseline[key]:
            found.append(f"drift got worse: {key} has {count} versions, baseline {baseline[key]}")
    for key, count in sorted(baseline.items()):
        if current.get(key, 1) < count:
            found.append(f"stale baseline: {key} is down to {current.get(key, 1)} versions; run --write-baseline")
    return found


def sync(root: Path, table: dict[str, dict[str, dict[str, str]]], skill: str) -> int:
    homes = table.get(skill, {})
    if CANONICAL not in homes:
        print(f"{skill}: no canonical copy under {CANONICAL}/skills", file=sys.stderr)
        return 1
    source = root / CANONICAL / "skills" / skill
    for home in sorted(h for h in homes if h != CANONICAL):
        target = root / home / "skills" / skill
        shutil.rmtree(target)
        shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__"))
        print(f"synced {skill} -> {home}/skills")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--write-baseline", action="store_true", help="tighten the baseline to the current drift")
    parser.add_argument("--sync", metavar="SKILL", action="append", default=[],
                        help="overwrite every other home's copy of SKILL with the canonical one")
    args = parser.parse_args()
    table = collect(args.root)
    for skill in args.sync:
        if sync(args.root, table, skill):
            return 1
    if args.sync:
        table = collect(args.root)
    current = drift(table)
    path = args.root / BASELINE
    baseline = json.loads(path.read_text(encoding="utf-8"))["files"] if path.is_file() else None
    if args.write_baseline:
        if baseline is not None:
            looser = [v for v in violations(current, baseline) if not v.startswith("stale")]
            if looser:
                print("\n".join(looser), file=sys.stderr)
                print("refusing to loosen the baseline", file=sys.stderr)
                return 1
        path.write_text(json.dumps({"version": 1, "canonical": f"{CANONICAL}/skills", "files": dict(sorted(current.items()))},
                                   ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {BASELINE}: {len(current)} drifting files")
        return 0
    found = violations(current, baseline or {})
    for line in found:
        print(line, file=sys.stderr)
    print(f"skill mirrors: {len(table)} skills, {len(current)} drifting files, {len(found)} violations")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
