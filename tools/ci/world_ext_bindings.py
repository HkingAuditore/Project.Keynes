#!/usr/bin/env python3
"""Inventory of the script-facing DCWorldExt bindings.

Parses ``ClassDB::bind_method`` calls in the module bind files, finds the file that
defines each bound member function, and assigns it a module through
``world_ext_binding_modules.json`` (definition file -> module).

Default mode checks the table: every defining file must belong to exactly one
module, no module may list a missing file, and every name in ``test_only`` /
``keep_unreferenced`` must still be a binding. ``--json`` prints the inventory;
``--refs`` adds where each binding is referenced from (scripts, tests, the
perf-validation mirror, tools) by name. Name matching over-counts methods that
share a name with something else; it is a review aid, not a proof of use.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = "tools/ci/world_ext_binding_modules.json"
SRC = "gdext/src"
BIND = re.compile(r"ClassDB::bind_method\s*\(\s*D_METHOD\s*\(")
REF = re.compile(r"""\.(\w+)\s*\(|&?["'](\w+)["']""")
REF_ROOTS = {
    "script": ["Project/project-keynes"],
    "test": ["Project/project-keynes/tests"],
    "mirror": ["Project/perf-validation"],
    "tools": ["tools"],
}
REF_SUFFIXES = {".gd", ".tscn", ".tres", ".py", ".cfg"}


def _balanced(text: str, start: int) -> int:
    """Index just past the parenthesis that closes the one opened before ``start``."""
    depth, i, quote = 1, start, None
    while depth:
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        i += 1
    return i


def strip_comments(text: str) -> str:
    # Preserve quoted names/defaults (including URLs containing //).
    return re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda m: m[0] if m[0][0] in "\"'" else " ", text)


def parse_bindings(root: Path, bind_file: str) -> list[dict]:
    text = strip_comments((root / bind_file).read_text(encoding="utf-8"))
    result = []
    for match in BIND.finditer(text):
        end = _balanced(text, match.end())
        d_method = text[match.end():end - 1]
        strings = re.findall(r'"([^"]*)"', d_method)
        rest_end = _balanced(text, end)
        rest = text[end:rest_end - 1]
        member = re.search(r"&DCWorldExt::(\w+)", rest)
        result.append({
            "name": strings[0],
            "args": strings[1:],
            "defaults": len(re.findall(r"\bDEFVAL\s*\(", rest)),
            "member": member.group(1) if member else None,
            "bind_file": bind_file,
        })
    return result


def definition_files(root: Path, members: set[str]) -> dict[str, str]:
    where: dict[str, str] = {}
    for path in sorted((root / SRC).glob("world_ext*.cpp")):
        if path.name.startswith("world_ext_bind_"):
            continue
        text = path.read_text(encoding="utf-8")
        for m in re.finditer(r"^[^\n&;]*?\bDCWorldExt::(\w+)\s*\(", text, re.MULTILINE):
            if m.group(1) in members:
                where.setdefault(m.group(1), path.name)
    header = (root / SRC / "world_ext.h").read_text(encoding="utf-8")
    for name in members - where.keys():
        if re.search(rf"\b{name}\s*\([^;{{]*\)\s*(?:const\s*)?(?:noexcept\s*)?\{{", header):
            where[name] = "world_ext.h"
    return where


def load_table(root: Path) -> dict:
    return json.loads((root / TABLE).read_text(encoding="utf-8"))


def inventory(root: Path) -> tuple[list[dict], list[str]]:
    table = load_table(root)
    file_module: dict[str, str] = {}
    problems: list[str] = []
    for module, files in table["modules"].items():
        for name in files:
            if name in file_module:
                problems.append(f"{name} is listed under both {file_module[name]} and {module}")
            file_module[name] = module
            if not (root / SRC / name).is_file():
                problems.append(f"module {module} lists missing file {SRC}/{name}")
    bindings = []
    # Include unexpected bind files too, so misplaced/duplicate bindings cannot
    # disappear from the inventory just because the table does not name them.
    for path in sorted((root / SRC).glob("world_ext_bind_*.cpp")):
        bindings.extend(parse_bindings(root, path.relative_to(root).as_posix()))
    for module in table["modules"]:
        expected = table["bind_file_pattern"].format(module=module)
        if not (root / expected).is_file():
            problems.append(f"module {module} is missing binding file {expected}")
    where = definition_files(root, {b["member"] for b in bindings if b["member"]})
    seen: Counter[str] = Counter(b["name"] for b in bindings)
    for name, count in seen.items():
        if count > 1:
            problems.append(f"binding {name} is bound {count} times")
    for b in bindings:
        b["file"] = where.get(b["member"])
        b["module"] = file_module.get(b["file"]) if b["file"] else None
        if b["member"] is None:
            problems.append(f"binding {b['name']} has no &DCWorldExt:: member")
        elif b["file"] is None:
            problems.append(f"binding {b['name']}: definition of {b['member']} not found")
        elif b["module"] is None:
            problems.append(f"binding {b['name']}: {b['file']} is not assigned to a module in {TABLE}")
    names = set(seen)
    for key in ("test_only", "keep_unreferenced"):
        for name in table.get(key, []):
            if name not in names:
                problems.append(f"{TABLE}: {key} names {name}, which is not a binding")
    test_only = set(table.get("test_only", []))
    for b in bindings:
        b["test_only"] = b["name"] in test_only
    return bindings, problems


def references(root: Path, names: set[str]) -> dict[str, Counter]:
    refs: dict[str, Counter] = {name: Counter() for name in names}
    test_root = root / REF_ROOTS["test"][0]
    for kind, dirs in REF_ROOTS.items():
        if kind == "test":
            continue
        for rel in dirs:
            for path in (root / rel).rglob("*"):
                if path.suffix not in REF_SUFFIXES or not path.is_file() or "/.godot/" in str(path):
                    continue
                bucket = "test" if kind == "script" and test_root in path.parents else kind
                for m in REF.finditer(path.read_text(encoding="utf-8", errors="replace")):
                    token = m.group(1) or m.group(2)
                    if token in refs:
                        refs[token][bucket] += 1
    return refs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json", action="store_true", help="print the inventory as JSON")
    parser.add_argument("--refs", action="store_true", help="include reference counts by caller kind")
    parser.add_argument("--audit", action="store_true",
                        help="also require test_only / keep_unreferenced to match the current references")
    args = parser.parse_args()
    bindings, problems = inventory(args.root)
    if args.audit:
        table = load_table(args.root)
        refs = references(args.root, {b["name"] for b in bindings})
        keep = set(table.get("keep_unreferenced", {}))
        test_only = set(table.get("test_only", []))
        for b in bindings:
            kinds = set(refs[b["name"]]) & {"script", "test"}
            if not kinds and b["name"] not in keep:
                problems.append(f"{b['name']}: no script or test reference; delete it or add it to keep_unreferenced")
            if kinds and b["name"] in keep:
                problems.append(f"{b['name']}: listed in keep_unreferenced but now referenced")
            if (kinds == {"test"}) != (b["name"] in test_only):
                problems.append(f"{b['name']}: test_only marking does not match references ({sorted(kinds)})")
    if args.refs:
        refs = references(args.root, {b["name"] for b in bindings})
        for b in bindings:
            b["refs"] = dict(sorted(refs[b["name"]].items()))
    if args.json:
        print(json.dumps(sorted(bindings, key=lambda b: (b["module"] or "", b["name"])), ensure_ascii=False, indent=1))
    for line in problems:
        print(line, file=sys.stderr)
    counts = Counter(b["module"] for b in bindings)
    summary = ", ".join(f"{m} {c}" for m, c in counts.most_common())
    print(f"world_ext bindings: {len(bindings)} ({summary}); {len(problems)} problems", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
