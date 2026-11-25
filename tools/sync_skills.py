#!/usr/bin/env python3
"""Point each AI tool's skills directory at this repository's ``skills/``.

The repository keeps exactly one copy of every skill, in ``<repo>/skills/``.
The tools do not know about that directory: each one reads its own
``<tool>/skills``.  This script makes those paths resolve to the single source
instead of storing a second copy in git.

Commands
    link     create the directory link for every tool
    unlink   remove only those links; the source is never touched
    check    report what each tool can actually see (exit 1 when something is missing)
    copy     fall back to real copies where links are unavailable

Scope
    --scope project   ``<repo>/.<tool>/skills``   (default: what the tools read
                      when they run inside this repository)
    --scope user      ``~/.<tool>/skills``        (what they read anywhere)

Nothing here runs git: the generated paths are gitignored, and this script must
stay usable on a machine that has the repository but no working git.
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

# tool directory name -> human label.  ``.agents`` is last on purpose: it is the
# one directory that used to hold the only real copy, so it is the least likely
# to surprise anyone when it turns into a link.
TOOLS = [
    ("claude", ".claude", "Claude Code"),
    ("codex", ".codex", "Codex"),
    ("cursor", ".cursor", "Cursor"),
    ("codebuddy", ".codebuddy", "CodeBuddy"),
    ("workbuddy", ".workbuddy", "WorkBuddy"),
    ("dsh", ".dsh", "DeepSeek Harness"),
    ("agents", ".agents", "generic agents"),
]

FILE_ATTRIBUTE_REPARSE_POINT = 0x400


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def repo_root() -> Path:
    """The repository root: this file lives in ``<repo>/tools/``."""
    return Path(__file__).resolve().parent.parent


def source_dir() -> Path:
    return repo_root() / "skills"


def expected_skills() -> list[str]:
    """Skill names that exist in the single source, sorted."""
    src = source_dir()
    if not src.is_dir():
        return []
    return sorted(
        p.name for p in src.iterdir() if p.is_dir() and (p / "SKILL.md").is_file()
    )


def is_link(path: Path) -> bool:
    """True for symlinks and, on Windows, for junctions too.

    Python reports junctions as ordinary directories before 3.8 and as
    non-links on some builds even later, so the reparse-point attribute is
    checked directly.
    """
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISLNK(st.st_mode):
        return True
    return bool(getattr(st, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT)


def link_target(path: Path) -> Path | None:
    """Where a link points, resolved as far as the OS lets us."""
    try:
        raw = os.readlink(path)
    except OSError:
        return None
    # A Windows junction reads back as \\?\<...> and some APIs use \??\.
    # Both carry a device prefix that Path.resolve() will not match against a
    # plain path, so strip it first: without this, every "does the link already
    # point at skills/?" test fails and link/unlink both refuse to act.
    for prefix in ("\\\\?\\", "\\??\\"):
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
            break
    # junctions come back as \\?\<...> ; ntpath handles that fine.
    return Path(raw).resolve()


def points_at_repo(path: Path) -> bool:
    tgt = link_target(path)
    if tgt is None:
        return False
    try:
        return tgt == source_dir().resolve()
    except OSError:
        return False


def tool_path(scope: str, dotname: str) -> Path:
    if scope == "user":
        return Path.home() / dotname / "skills"
    return repo_root() / dotname / "skills"


def visible_skills(path: Path) -> set[str]:
    """Skill names a tool would find at ``path``."""
    if not path.is_dir():
        return set()
    try:
        return {p.name for p in path.iterdir() if p.is_dir() and (p / "SKILL.md").is_file()}
    except OSError:
        return set()


def make_dir_link(link: Path, target: Path) -> tuple[bool, str]:
    """Create one directory link.  Returns (ok, message)."""
    link.parent.mkdir(parents=True, exist_ok=True)

    if os.name == "nt":
        # A junction needs no administrator rights and no Developer Mode, which
        # a plain symlink does.  mklink is a cmd builtin, so it runs via cmd /c.
        proc = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link), str(target)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if proc.returncode == 0:
            return True, "junction"
        first_error = (proc.stdout or "").strip()
        try:
            os.symlink(target, link, target_is_directory=True)
            return True, "symlink"
        except OSError as exc:
            return False, f"junction failed ({first_error}); symlink failed ({exc})"

    try:
        os.symlink(target, link, target_is_directory=True)
        return True, "symlink"
    except OSError as exc:
        return False, f"symlink failed ({exc})"


def remove_link(link: Path) -> None:
    """Remove a link without ever descending into what it points at."""
    if os.name == "nt" and is_link(link) and not stat.S_ISLNK(os.lstat(link).st_mode):
        os.rmdir(link)  # junction: rmdir drops the reparse point only
    else:
        os.unlink(link)


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(repo_root()))
    except ValueError:
        return str(path)


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_link(args: argparse.Namespace) -> int:
    src = source_dir()
    if not src.is_dir():
        print(f"error: no skills directory at {src}", file=sys.stderr)
        return 2
    names = expected_skills()
    if not names:
        print(f"error: {src} contains no <name>/SKILL.md", file=sys.stderr)
        return 2

    problems: list[str] = []
    made = skipped = 0
    for _, dotname, label in TOOLS:
        link = tool_path(args.scope, dotname)
        if is_link(link):
            if points_at_repo(link):
                print(f"  skip   {rel(link)}  (already -> skills/)")
                skipped += 1
            else:
                problems.append(
                    f"{rel(link)} is a link to {link_target(link)}, not to skills/"
                )
            continue
        if link.exists():
            # A real directory here would shadow the source: refuse rather than
            # delete somebody's files, and say exactly what to do about it.
            inside = len(visible_skills(link))
            problems.append(
                f"{rel(link)} already exists as a real directory ({inside} skills). "
                f"Move it aside or run `{Path(__file__).name} copy --force`."
            )
            continue
        ok, how = make_dir_link(link, src)
        if ok:
            print(f"  link   {rel(link)}  ({how})")
            made += 1
        else:
            problems.append(f"{rel(link)}: {how}")

    print(f"\n{len(names)} skills in {rel(src)}; {made} link(s) created, {skipped} already correct.")
    if problems:
        print("\nnot done:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    return 0


def cmd_unlink(args: argparse.Namespace) -> int:
    removed = kept = 0
    for _, dotname, label in TOOLS:
        link = tool_path(args.scope, dotname)
        if not is_link(link):
            if link.exists():
                print(f"  keep   {rel(link)}  (real directory, not ours)")
                kept += 1
            continue
        if points_at_repo(link):
            remove_link(link)
            print(f"  unlink {rel(link)}")
            removed += 1
        else:
            print(f"  keep   {rel(link)}  (points elsewhere: {link_target(link)})")
            kept += 1
    print(f"\n{removed} link(s) removed, {kept} left alone. {rel(source_dir())} untouched.")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    names = set(expected_skills())
    if not names:
        print(f"error: {source_dir()} contains no <name>/SKILL.md", file=sys.stderr)
        return 2
    total = len(names)
    bad = 0
    print(f"source: {rel(source_dir())}  ({total} skills)\n")
    for _, dotname, label in TOOLS:
        path = tool_path(args.scope, dotname)
        seen = visible_skills(path)
        missing = sorted(names - seen)
        extra = sorted(seen - names)
        state = f"{len(seen)}/{total}"
        if not missing and not extra:
            print(f"  ok     {label:<20} {rel(path):<32} {state}")
            continue
        bad += 1
        print(f"  FAIL   {label:<20} {rel(path):<32} {state}")
        if missing:
            print(f"         missing: {', '.join(missing)}")
        if extra:
            print(f"         not in source: {', '.join(extra)}")
    if bad:
        print(
            f"\n{bad} tool path(s) cannot see every skill. Run: "
            f"python tools/{Path(__file__).name} link"
            + (f" --scope {args.scope}" if args.scope != "project" else ""),
            file=sys.stderr,
        )
        return 1
    print("\nall tool paths see the full set.")
    return 0


def cmd_copy(args: argparse.Namespace) -> int:
    src = source_dir()
    names = expected_skills()
    if not names:
        print(f"error: {src} contains no <name>/SKILL.md", file=sys.stderr)
        return 2
    print(
        "warning: copies drift. Re-run after every `git pull`, and treat\n"
        "         skills/ as the only file anyone should edit.\n",
        file=sys.stderr,
    )
    wrote = 0
    for _, dotname, label in TOOLS:
        dest_root = tool_path(args.scope, dotname)
        if is_link(dest_root):
            print(f"  skip   {rel(dest_root)}  (is a link; run unlink first)")
            continue
        for name in names:
            dest = dest_root / name
            if dest.exists() and not args.force:
                continue
            dest_root.mkdir(parents=True, exist_ok=True)
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(src / name, dest)
            wrote += 1
        print(f"  copy   {rel(dest_root)}")
    print(f"\n{wrote} directory(ies) written under scope={args.scope}.")
    return 0


# --------------------------------------------------------------------------- #
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="sync_skills.py",
        description="Make every AI tool read this repository's skills/ directory.",
    )
    ap.add_argument("--scope", choices=["project", "user"], default="project",
                    help="project = <repo>/.<tool>/skills (default), user = ~/.<tool>/skills")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("link", help="create the directory links").set_defaults(func=cmd_link)
    sub.add_parser("unlink", help="remove only the links").set_defaults(func=cmd_unlink)
    sub.add_parser("check", help="verify every tool sees every skill").set_defaults(func=cmd_check)
    p_copy = sub.add_parser("copy", help="fall back to real copies (they drift)")
    p_copy.add_argument("--force", action="store_true",
                        help="replace existing directories in the tool paths")
    p_copy.set_defaults(func=cmd_copy)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
