#!/usr/bin/env python3
"""Module API boundary guard.

Each module that publishes a public API header has a contract file in
tools/ci/module_api/<module>.json:

  api_headers               public headers peers may include
  internal_header_patterns  globs for the module's internal headers
  owner_file_patterns       globs for files that belong to the module
  composition_roots         {file: reason} files that construct/own the runtime
                            and may include internal headers (shrink-only)
  legacy_includers          peers not yet migrated to the API (shrink-only)

Rules (all fail the check):
  * a non-owner file includes an internal header and is neither a composition
    root nor a legacy includer (new coupling);
  * a listed composition root / legacy includer no longer includes any internal
    header (stale entry: remove it so the ratchet tightens);
  * a composition root has no written reason;
  * an API header includes anything other than a <system> header, another
    module's *_api.h, or a registered shared contract header (the API must stay
    free of internals).

Shared contract headers (tools/ci/module_api_shared.json, {header: reason}) are
leaf value-type headers several modules exchange through APIs (masks, small
stats structs). Each must have a reason, exist, and itself include only
<system> headers or other shared contract headers.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = Path(__file__).with_name("module_api")
SHARED_FILE = Path(__file__).with_name("module_api_shared.json")
INCLUDE = re.compile(r'^\s*#\s*include\s*([<"])([^">]+)[">]', re.M)
NON_CODE = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/')


def includes(source: str) -> list[tuple[str, str]]:
    code = NON_CODE.sub(lambda m: "\n" * m.group().count("\n"), source)
    return [(m.group(1), m.group(2)) for m in INCLUDE.finditer(code)]


def matches(name: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(name, pattern) for pattern in patterns)


def source_files(root: Path) -> list[Path]:
    src = root / "gdext/src"
    return sorted(p for p in src.rglob("*") if p.suffix in {".cpp", ".h", ".inc"} and ".gen." not in p.name)


def check_shared(root: Path, shared: dict) -> list[str]:
    errors: list[str] = []
    src = root / "gdext/src"
    for header, reason in sorted(shared.items()):
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"shared contract header {header} lacks a reason")
        path = src / header
        if not path.is_file():
            errors.append(f"shared contract header {header} is missing")
            continue
        for kind, target in includes(path.read_text(encoding="utf-8")):
            if kind == "<" or target in shared:
                continue
            errors.append(f"shared contract header {header} includes non-shared header {target}")
    return errors


def check_contract(root: Path, contract: dict, shared: dict | None = None) -> list[str]:
    shared = shared or {}
    module = contract["module"]
    api = set(contract["api_headers"])
    internal = contract["internal_header_patterns"]
    owners = contract["owner_file_patterns"]
    roots = contract.get("composition_roots", {})
    legacy = set(contract.get("legacy_includers", []))
    errors: list[str] = []
    src = root / "gdext/src"
    seen: set[str] = set()
    for path in source_files(root):
        rel = path.relative_to(src).as_posix()
        incs = includes(path.read_text(encoding="utf-8"))
        if path.name in api:
            for kind, target in incs:
                if kind == "<" or target.endswith("_api.h") or target in shared:
                    continue
                errors.append(f"{module}: API header {rel} includes non-API header {target}")
            continue
        if matches(path.name, owners):
            continue
        hits = [t for k, t in incs if k == '"' and matches(Path(t).name, internal)]
        if not hits:
            continue
        seen.add(rel)
        if rel in roots or rel in legacy:
            continue
        errors.append(f"{module}: {rel} includes internal {', '.join(sorted(set(hits)))}; "
                      f"include {' / '.join(sorted(api))} instead")
    for rel in sorted((set(roots) | legacy) - seen):
        errors.append(f"{module}: stale entry {rel} no longer includes internals; remove it from the contract")
    for rel, reason in sorted(roots.items()):
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"{module}: composition root {rel} lacks a reason")
    for header in sorted(api):
        if not (src / header).is_file():
            errors.append(f"{module}: API header {header} is missing")
    return errors


def load_contracts(directory: Path) -> list[dict]:
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(directory.glob("*.json"))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--contracts", type=Path, default=CONTRACT_DIR)
    parser.add_argument("--shared", type=Path, default=SHARED_FILE)
    args = parser.parse_args()
    contracts = load_contracts(args.contracts)
    shared = json.loads(args.shared.read_text(encoding="utf-8")) if args.shared.is_file() else {}
    errors: list[str] = check_shared(args.root, shared)
    summary = []
    for contract in contracts:
        errors += check_contract(args.root, contract, shared)
        summary.append(f"{contract['module']}: {len(contract.get('legacy_includers', []))} legacy, "
                       f"{len(contract.get('composition_roots', {}))} roots")
    print(f"module API: {len(contracts)} modules ({'; '.join(summary)}), "
          f"{len(shared)} shared contract headers, {len(errors)} violations")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
