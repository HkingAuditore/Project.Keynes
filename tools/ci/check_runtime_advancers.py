#!/usr/bin/env python3
"""Check host progress fields and keep the C++ advancer inventory reproducible.

Lexical guard, not proof of all simulation calls. Default never writes files.
Review the JSON registry for new advancers, then explicitly regenerate its header.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
HOST = "Project/project-keynes/scripts/game/world_runtime_host.gd"
REGISTRY = "tools/ci/runtime_advancers.json"
BASELINE = "tools/ci/runtime_advancers_baseline.json"
HEADER = "gdext/src/runtime_external_advancers.h"
THREADS = {"main": "MAIN", "executor": "EXECUTOR", "worker": "WORKER"}
# Remove comments and quoted strings, retaining newlines for anchored declarations.
NON_CODE = re.compile(r'"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|\#[^\n]*')


def inventory(source: str) -> tuple[set[str], set[str]]:
    code = NON_CODE.sub(lambda match: "\n" * match[0].count("\n"), source)
    declared = re.findall(r"^\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:static\s+)?var\s+(_runtime_\w+)\b", code, re.M)
    # *_days totals are counters, not date cursors (e.g. inline_pending_days).
    fields = {name for name in declared if "cursor" in name or "catchup" in name
              or (name.endswith(("_day", "_day_index")) and any(word in name for word in ("last", "pending", "target", "commit")))}
    methods = set(re.findall(r"^func\s+((?:_queue|_drain)_runtime_\w*_commits?)\s*\(", code, re.M))
    return fields, methods


def render_header(registry: dict) -> str:
    lines = ["#pragma once", "", "// Generated from tools/ci/runtime_advancers.json by check_runtime_advancers.py.",
             "// Inventory only: this table never schedules or moves execution.", "#include <array>", "", "namespace pk {",
             "enum class RuntimeAdvancerThread { MAIN, WORKER, EXECUTOR };",
             "// EXECUTOR is worker normally, or the existing inline caller.",
             "struct RuntimeExternalAdvancerDescriptor {",
             "    const char *id;", "    RuntimeAdvancerThread thread;",
             "    const char *reads;", "    const char *writes;", "    const char *trigger;",
             "    const char *source;", "    const char *entrypoint;", "    const char *host_fields;", "};", "",
             f"inline constexpr std::array<RuntimeExternalAdvancerDescriptor, {len(registry['advancers'])}> RUNTIME_EXTERNAL_ADVANCERS{{{{"]
    for row in registry["advancers"]:
        values = [json.dumps(row["id"]), "RuntimeAdvancerThread::" + THREADS[row["thread"]]]
        values += [json.dumps(row[key]) for key in ("reads", "writes", "trigger", "source", "entrypoint")]
        values += [json.dumps(";".join(row["host_fields"]))]
        lines.append("    {" + ", ".join(values) + "},")
    lines += ["}};", "} // namespace pk", ""]
    return "\n".join(lines)


def violations(root: Path, registry: dict, baseline: dict) -> list[str]:
    errors = []
    if registry.get("version") != 1 or baseline.get("version") != 1:
        return ["unsupported registry/baseline version"]
    fields, methods = inventory((root / HOST).read_text())
    registered_fields, registered_methods, ids = set(), set(), set()
    for row in registry["advancers"]:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", row["id"]) or row["id"] in ids:
            errors.append(f"invalid/duplicate advancer id: {row['id']}")
        ids.add(row["id"])
        if row["thread"] not in THREADS:
            errors.append(f"unknown thread: {row['id']}")
        for key in ("reads", "writes", "trigger", "source", "entrypoint"):
            if not row.get(key): errors.append(f"missing {key}: {row['id']}")
        source = root / row["source"]
        if not source.is_file() or row["entrypoint"] not in source.read_text():
            errors.append(f"missing entrypoint: {row['id']} {row['entrypoint']}")
        for key, current, registered in (("host_fields", fields, registered_fields),
                                         ("host_methods", methods, registered_methods)):
            for name in row[key]:
                if name in registered: errors.append(f"duplicate registration: {name}")
                if name not in current: errors.append(f"stale registration: {name}")
                registered.add(name)
    for key, current, registered in (("fields", fields, registered_fields),
                                     ("methods", methods, registered_methods)):
        debt = set(baseline["unregistered_" + key])
        for name in sorted(current - registered - debt):
            errors.append(f"unregistered {key}: {name}")
    if not errors:
        header = root / HEADER
        if not header.is_file() or header.read_text() != render_header(registry):
            errors.append("C++ inventory differs from registry; review and run --write-header")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--write-header", action="store_true", help="explicit reviewed generation only")
    args = parser.parse_args()
    registry = json.loads((args.root / REGISTRY).read_text())
    baseline = json.loads((args.root / BASELINE).read_text())
    if args.write_header:
        (args.root / HEADER).write_text(render_header(registry))
    errors = violations(args.root, registry, baseline)
    fields, methods = inventory((args.root / HOST).read_text())
    print(f"runtime advancers: {len(registry['advancers'])} entries, {len(fields)} fields, {len(methods)} catchup methods, {len(errors)} violations")
    for error in errors: print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
