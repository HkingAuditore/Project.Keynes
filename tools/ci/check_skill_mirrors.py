#!/usr/bin/env python3
"""Verify that tracked skills live under the repository's `skills/` directory."""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = re.compile(r"skills/[^/]+/SKILL\.md$")
TOOL_MIRROR = re.compile(r"^\.[^/]+/skills(?:/|$)")


def check(root: Path) -> tuple[int, list[str]]:
    # Use the index so a tracked mirror is reported even if sparse checkout omitted it.
    result = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True)
    tracked = result.stdout.decode("utf-8").split("\0")
    manifests = [path for path in tracked if MANIFEST.fullmatch(path)]
    problems = [f"tracked tool mirror: {path}; edit the source in skills/"
                for path in tracked if TOOL_MIRROR.match(path)]
    if not manifests:
        problems.append("no tracked skills/<name>/SKILL.md files")
    problems.extend(f"skill source missing from checkout: {path}"
                    for path in manifests if not (root / path).is_file())
    return len(manifests), problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    count, problems = check(parser.parse_args().root)
    for problem in problems:
        print(problem, file=sys.stderr)
    print(f"skill sources: {count} tracked manifests, {len(problems)} violations")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
