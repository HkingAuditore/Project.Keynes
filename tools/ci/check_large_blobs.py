#!/usr/bin/env python3
"""Reject a commit that stages one file above the size budget.

Git stores every byte forever, so a single ``git add`` of a build product is a
permanent cost for everyone who clones. This gate reads the *index* (what a
commit would actually contain), not the working tree, and fails when any staged
file is larger than ``--max-mb`` (default 5) unless
``tools/ci/large_blobs_allowlist.json`` names it.

Size source: the staged blob itself. ``git diff --cached --numstat`` reports
``-`` instead of a byte count for binary files, so the authoritative size comes
from ``git cat-file -s :<path>`` on the index entry; numstat is only used to
label the row as binary in the report.

This project does not use Git LFS. ``.gitattributes`` carries no ``filter=lfs``
lines and none will be added: large artifacts belong in a GitHub Release asset
or on the network share, never in the repository.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = Path(__file__).with_name("large_blobs_allowlist.json")
DEFAULT_MAX_MB = 5.0

# Index entries a commit would add or change. Deletions cannot grow the repo.
DIFF_FILTER = "ACMR"


def human(size_bytes: float) -> str:
    if size_bytes >= 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.2f} MB"
    if size_bytes >= 1024:
        return f"{size_bytes / 1024:.1f} KB"
    return f"{int(size_bytes)} B"


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=str(root), capture_output=True, check=False)
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed ({result.returncode}): {message}")
    return result.stdout


def binary_staged_paths(root: Path) -> set[str]:
    """Paths numstat marked as ``-``/``-`` (binary). Diagnostic label only."""
    # Without -z: a rename renders as a brace expression, so those rows simply
    # stay unlabelled. Sizes never come from here.
    output = git(root, "diff", "--cached", "--numstat").decode("utf-8", "replace")
    marked = set()
    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0] == "-" and parts[1] == "-":
            marked.add(parts[2])
    return marked


def staged_entries(root: Path) -> list[tuple[str, int, bool]]:
    raw = git(root, "diff", "--cached", "--name-only", "--diff-filter", DIFF_FILTER, "-z")
    paths = [item for item in raw.decode("utf-8", "replace").split("\0") if item]
    if not paths:
        return []
    binaries = binary_staged_paths(root)
    entries = []
    for path in paths:
        size = int(git(root, "cat-file", "-s", f":{path}").decode("ascii", "replace").strip())
        entries.append((path, size, path in binaries))
    return entries


def load_allowlist(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    try:
        # utf-8-sig: Windows editors and PowerShell's -Encoding UTF8 prepend a
        # BOM, which is not a decode error. Everything else stays strict.
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{path}: invalid JSON ({error})") from error
    allow = data.get("allow", [])
    if not isinstance(allow, list):
        raise RuntimeError(f"{path}: 'allow' must be a list")
    for row in allow:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str) or not row["path"]:
            raise RuntimeError(f"{path}: every entry needs a non-empty string 'path'")
        if not isinstance(row.get("why"), str) or not row["why"].strip():
            raise RuntimeError(f"{path}: entry {row['path']} needs a written 'why'")
        if row.get("max_mb") is not None and float(row["max_mb"]) <= 0:
            raise RuntimeError(f"{path}: entry {row['path']} has a non-positive max_mb")
    return allow


def allowed_limit(path: str, allow: list[dict], default_mb: float) -> float | None:
    """Largest allowlisted budget for this path, or None when not allowlisted."""
    limit = None
    for row in allow:
        if fnmatch.fnmatchcase(path, row["path"]):
            candidate = float(row.get("max_mb", default_mb))
            limit = candidate if limit is None else max(limit, candidate)
    return limit


def check(entries, allow, default_mb: float):
    """Split entries into (violations, allowlisted, within-budget)."""
    default_budget = default_mb * 1024 * 1024
    violations, allowlisted, within = [], [], []
    for path, size, binary in entries:
        limit_mb = allowed_limit(path, allow, default_mb)
        if limit_mb is None:
            if size <= default_budget:
                within.append((path, size, binary))
            else:
                violations.append((path, size, binary, default_mb))
            continue
        budget = limit_mb * 1024 * 1024
        if size <= budget:
            allowlisted.append((path, size, binary, limit_mb))
        else:
            # Matched the allowlist but blew through its own budget: still a fail.
            violations.append((path, size, binary, limit_mb))
    return violations, allowlisted, within


def report(violations, allowlisted, within, default_mb: float) -> None:
    default_budget = default_mb * 1024 * 1024
    for path, size, binary, budget_mb in violations:
        over = size - budget_mb * 1024 * 1024
        percent = over / (budget_mb * 1024 * 1024) * 100
        print(f"FAIL staged file over budget: {path}")
        print(f"  size      : {human(size)}{'  (binary)' if binary else ''}")
        print(f"  budget    : {human(budget_mb * 1024 * 1024)} (--max-mb {budget_mb:g})")
        print(f"  over by   : +{human(over)} ({percent:.1f}% over)")
        print("  alternatives:")
        print("    - attach it to a GitHub Release asset (2 GB per-file limit) and link it")
        print("    - keep it on the network share / NAS and reference the path")
        print("    - do not commit binaries into this repository")
        print("  this project does not use Git LFS: .gitattributes stays free of filter=lfs")
    for path, size, binary, budget_mb in allowlisted:
        # Only worth a line when the default budget would have rejected it.
        if size > default_budget:
            print(f"ALLOW {path}  {human(size)} (allowlisted budget {budget_mb:g} MB)")
    print(f"large blobs: {len(violations) + len(allowlisted) + len(within)} staged file(s) checked, "
          f"{len(violations)} over {default_mb:g} MB, {len(allowlisted)} allowlisted")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--staged", action="store_true",
                        help="check the index (default when --path is absent)")
    parser.add_argument("--path", action="append", default=[], metavar="FILE",
                        help="measure one file on disk instead of the index; repeatable")
    parser.add_argument("--max-mb", type=float, default=DEFAULT_MAX_MB,
                        help=f"per-file budget in MB (default {DEFAULT_MAX_MB:g})")
    parser.add_argument("--allowlist", type=Path, default=ALLOWLIST,
                        help="allowlist JSON (default tools/ci/large_blobs_allowlist.json)")
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    args = parser.parse_args()

    if args.max_mb <= 0:
        parser.error("--max-mb must be positive")

    root = args.root.resolve()
    try:
        allow = load_allowlist(args.allowlist)
        if args.path:
            entries = []
            for item in args.path:
                path = Path(item)
                if not path.is_file():
                    print(f"error: not a file: {item}", file=sys.stderr)
                    return 1
                try:
                    # Report the repository-relative path so allowlist patterns
                    # behave the same in both modes.
                    relative = path.resolve().relative_to(root).as_posix()
                except ValueError:
                    relative = path.resolve().as_posix()
                entries.append((relative, path.stat().st_size, False))
        else:
            entries = staged_entries(root)
    except (RuntimeError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    violations, allowlisted, within = check(entries, allow, args.max_mb)
    report(violations, allowlisted, within, args.max_mb)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
