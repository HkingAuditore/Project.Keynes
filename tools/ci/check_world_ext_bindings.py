#!/usr/bin/env python3
"""Keep DCWorldExt script bindings in their definition file's module."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import world_ext_bindings as inventory


def violations(root: Path) -> list[str]:
    table = inventory.load_table(root)
    bindings, problems = inventory.inventory(root)
    entry = table["bind_entry"]
    expected = {table["bind_file_pattern"].format(module=m) for m in table["modules"]}
    actual = {p.relative_to(root).as_posix()
              for p in (root / inventory.SRC).glob("world_ext_bind_*.cpp")}
    for path in sorted(expected - actual):
        problems.append(f"missing module binding file: {path}")
    for path in sorted(actual - expected - {entry}):
        problems.append(f"unexpected module binding file: {path}")
    for binding in bindings:
        if binding["module"] is None:
            continue  # The inventory already explains the missing definition/module.
        target = table["bind_file_pattern"].format(module=binding["module"])
        if binding["bind_file"] != target:
            problems.append(f"binding {binding['name']} in {binding['bind_file']} belongs to "
                            f"module {binding['module']} ({binding['file']}); expected {target}")
    if not (root / entry).is_file():
        problems.append(f"missing binding entry file: {entry}")
        return problems
    text = inventory.strip_comments((root / entry).read_text(encoding="utf-8"))
    if re.search(r"\bClassDB::bind_method\s*\(", text):
        problems.append(f"{entry}: bind_method must only appear in module binding files")
    body = re.search(r"\bDCWorldExt::_bind_methods\s*\(\s*\)\s*\{([\s\S]*?)\}", text)
    if body is None:
        problems.append(f"{entry}: DCWorldExt::_bind_methods() definition not found")
    for module in table["modules"]:
        count = len(re.findall(rf"\b_bind_{re.escape(module)}_methods\s*\(\s*\)\s*;",
                               body[1] if body else ""))
        if count != 1:
            problems.append(f"{entry}: _bind_{module}_methods() called {count} times; expected once")
    manifest_path = root / inventory.MANIFEST
    if not manifest_path.is_file():
        if (root / "Project/project-keynes").is_dir():
            problems.append(f"missing native binding manifest: {inventory.MANIFEST}; run "
                            "world_ext_bindings.py --write-manifest")
    else:
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest_names = manifest.get("methods") if isinstance(manifest, dict) else None
            static_names = sorted({binding["name"] for binding in bindings})
            if not isinstance(manifest_names, list) or sorted(manifest_names) != static_names:
                problems.append(f"native binding manifest methods differ from static inventory; run "
                                "world_ext_bindings.py --write-manifest")
            elif int(manifest.get("count", -1)) != len(static_names):
                problems.append(f"native binding manifest count differs from methods; run "
                                "world_ext_bindings.py --write-manifest")
            if manifest.get("class") != "DCWorldExt":
                problems.append(f"native binding manifest class must be DCWorldExt; run "
                                "world_ext_bindings.py --write-manifest")
        except (OSError, ValueError, TypeError, AttributeError):
            problems.append(f"invalid native binding manifest: {inventory.MANIFEST}; run "
                            "world_ext_bindings.py --write-manifest")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=inventory.ROOT)
    args = parser.parse_args()
    problems = violations(args.root)
    for problem in problems:
        print(problem, file=sys.stderr)
    modules = inventory.load_table(args.root)["modules"]
    print(f"world_ext binding guard: {len(modules)} modules; {len(problems)} problems")
    return int(bool(problems))


if __name__ == "__main__":
    sys.exit(main())
