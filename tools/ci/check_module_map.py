#!/usr/bin/env python3
"""Check that every repository path named in docs/architecture/module-map.md exists.

A backticked token counts as a path when it starts with a top-level directory of
this repository. Tokens with ``*`` must match at least one file; tokens with a
``<placeholder>`` are skipped.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = "docs/architecture/module-map.md"
PREFIXES = ("gdext/", "Project/", "tools/", "docs/", ".github/", ".agents/")


def violations(root: Path = ROOT) -> list[str]:
    text = (root / MAP).read_text(encoding="utf-8")
    found = []
    for token in sorted(set(re.findall(r"`([^`\s]+)`", text))):
        if not token.startswith(PREFIXES) or "<" in token:
            continue
        exists = any(root.glob(token)) if "*" in token else (root / token).exists()
        if not exists:
            found.append(f"{MAP}: `{token}` does not exist")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    found = violations(parser.parse_args().root)
    for line in found:
        print(line, file=sys.stderr)
    print(f"module map: {len(found)} violations")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
