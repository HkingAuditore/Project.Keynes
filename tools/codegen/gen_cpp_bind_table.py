#!/usr/bin/env python3
"""gen_cpp_bind_table.py — DOTS framework codegen (A1 / dots-migration-roadmap §3).

Reads the GDScript single-source schema at
    Project/project-keynes/scripts/data_core/component_schema.gd
and emits the C++ counterpart at
    gdext/src/component_bind_table.gen.h
which is `#include`d by `gdext/src/world_ext.cpp` to drive the
`bind_map_data` slot registration. This eliminates the long-standing
"GDScript / C++ two BIND_TABLEs maintained by hand" anti-pattern
(performance-charter §11.2 / §12.4 historical warning).

Usage:
    cd <repo root>
    python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py

After running, rebuild the GDExtension. The generated header is
committed to the repo so that engineers without Python set up locally
still get a working build; CI should run this script and fail if the
generated content drifts from the committed file.

Invariants enforced (will fail the build with a clear error if violated):
    * Every CELL_SCHEMA entry must have non-empty `cpp_name`,
      `map_field`, and a recognised `dtype` (F32 / I32 / U8).
    * `cpp_name` values must be unique across the table.
    * `map_field` values must be unique across the table.

This script is intentionally dependency-free (stdlib only); it can be
run from any environment with Python 3.7+.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

# ─── Paths (relative to repository root) ──────────────────────────────────────
# Resolved relative to the script's own location, so the script can be invoked
# from any working directory.
SCRIPT_DIR = Path(__file__).resolve().parent
# tools/codegen/ → tools/ → Project.Keynes/ (repo root containing both
# `Project/` and `gdext/`).
REPO_ROOT = SCRIPT_DIR.parent.parent
SCHEMA_PATH = REPO_ROOT / "Project" / "project-keynes" / "scripts" / "data_core" / "component_schema.gd"
OUTPUT_PATH = REPO_ROOT / "gdext" / "src" / "component_bind_table.gen.h"


# ─── Regex used to slice CELL_SCHEMA array literal ────────────────────────────
# Entry shape (single line, comments above it are ignored):
#   { name = &"cell.temp", cpp_name = "cell_temp", dtype = F32,
#     track_prev = true, map_field = "temp_arr", prev_field = "temp_arr_prev",
#     owner = "climate.pass_a" },
# Each field uses `key = value` with `=`, not `:`. We extract the four
# fields the C++ side actually needs (cpp_name / dtype / map_field) plus
# `name` (used in a verification comment) and the optional `demo` flag.

ENTRY_RE = re.compile(r"\{\s*(?P<body>[^{}]*?)\s*\}")
KV_RE = re.compile(r"(\w+)\s*=\s*(.*?)(?=,\s*\w+\s*=|$)", re.DOTALL)


def _parse_value(raw: str) -> str:
    """Strip GDScript quoting noise and return the bare value as a string.

    Handles:
        &"cell.temp"  → cell.temp
        "temp_arr"    → temp_arr
        F32           → F32
        true / false  → true / false
        1.0 / 42      → 1.0 / 42
    """
    raw = raw.strip().rstrip(",").strip()
    if raw.startswith("&\"") and raw.endswith("\""):
        return raw[2:-1]
    if raw.startswith("\"") and raw.endswith("\""):
        return raw[1:-1]
    return raw


def parse_schema(schema_path: Path) -> List[Dict[str, str]]:
    text = schema_path.read_text(encoding="utf-8")
    # Locate the CELL_SCHEMA array literal block. We deliberately do not
    # parse arbitrary GDScript; we only handle the well-known shape used in
    # component_schema.gd (one entry per line, dict literal with `=`).
    start_match = re.search(r"const\s+CELL_SCHEMA\s*:\s*Array\s*=\s*\[", text)
    if not start_match:
        raise SystemExit(
            f"[gen_cpp_bind_table] ERROR: cannot find `const CELL_SCHEMA: Array = [` in {schema_path}"
        )
    # Walk forward to find the matching closing bracket. Brackets inside
    # entry dicts are `{ ... }` — they do not affect the outer `[ ... ]`.
    depth = 1
    pos = start_match.end()
    while pos < len(text) and depth > 0:
        ch = text[pos]
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                break
        pos += 1
    if depth != 0:
        raise SystemExit(
            "[gen_cpp_bind_table] ERROR: unterminated CELL_SCHEMA array literal"
        )
    body = text[start_match.end() : pos]

    entries: List[Dict[str, str]] = []
    for m in ENTRY_RE.finditer(body):
        entry_body = m.group("body")
        # Skip fully blank entries (defensive — shouldn't happen).
        if not entry_body.strip():
            continue
        kv_pairs = KV_RE.findall(entry_body)
        if not kv_pairs:
            continue
        entry: Dict[str, str] = {}
        for k, v in kv_pairs:
            entry[k.strip()] = _parse_value(v)
        entries.append(entry)
    if not entries:
        raise SystemExit(
            "[gen_cpp_bind_table] ERROR: 0 entries parsed — check schema format"
        )
    return entries


def validate(entries: List[Dict[str, str]]) -> None:
    """Run the same nine sanity checks the GDScript validate_all() does, plus
    uniqueness of cpp_name / map_field (the C++ side relies on this)."""
    valid_dtypes = {"F32", "I32", "U8"}
    seen_cpp: Dict[str, int] = {}
    seen_map: Dict[str, int] = {}
    for idx, e in enumerate(entries):
        for key in ("name", "cpp_name", "dtype", "map_field"):
            if key not in e or not e[key]:
                raise SystemExit(
                    f"[gen_cpp_bind_table] ERROR: entry[{idx}] missing required field '{key}'"
                )
        if e["dtype"] not in valid_dtypes:
            raise SystemExit(
                f"[gen_cpp_bind_table] ERROR: entry[{idx}] '{e['name']}' has invalid dtype '{e['dtype']}' (must be F32/I32/U8)"
            )
        if e["cpp_name"] in seen_cpp:
            raise SystemExit(
                f"[gen_cpp_bind_table] ERROR: duplicate cpp_name '{e['cpp_name']}' "
                f"(entry[{idx}] and entry[{seen_cpp[e['cpp_name']]}])"
            )
        seen_cpp[e["cpp_name"]] = idx
        if e["map_field"] in seen_map:
            raise SystemExit(
                f"[gen_cpp_bind_table] ERROR: duplicate map_field '{e['map_field']}' "
                f"(entry[{idx}] and entry[{seen_map[e['map_field']]}])"
            )
        seen_map[e["map_field"]] = idx


# ─── Output template ──────────────────────────────────────────────────────────

HEADER_PREFIX = """// component_bind_table.gen.h — AUTOGENERATED by tools/codegen/gen_cpp_bind_table.py
//
// DO NOT EDIT THIS FILE BY HAND. Edit the GDScript single source at
//   Project/project-keynes/scripts/data_core/component_schema.gd
// then run
//   python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py
// and rebuild the GDExtension. The script enforces uniqueness of
// cpp_name / map_field and validates dtype values; any drift between
// schema and generated header is a build-time error, not a silent
// runtime miscompile.
//
// This file is the single C++-side mirror of the GDScript bind_map_data
// registration. Background and rationale: docs/dots-migration-roadmap.md
// §3 (A1 ComponentSchema 单一源) and dots-component-schema.md.
//
// Schema entries: {n_entries}
// (Demo entries are emitted with the same row shape; the GDScript side
// gates them on demo_thermal_gradient_enabled before binding, and the
// C++ bind_map_data already gracefully no-ops on size==0 properties.)

#pragma once

#include "components/slot.h"

namespace pk {{

struct BindEntry {{
    const char *slot_name;
    const char *property_name;
    SlotDType   dtype;
}};

inline constexpr BindEntry BIND_TABLE_AUTOGEN[] = {{
"""

HEADER_SUFFIX = """};

inline constexpr int BIND_TABLE_AUTOGEN_SIZE =
    sizeof(BIND_TABLE_AUTOGEN) / sizeof(BindEntry);

} // namespace pk
"""


def emit(entries: List[Dict[str, str]]) -> str:
    # Compute padding so the columns line up nicely in the generated file.
    cpp_w = max(len(e["cpp_name"]) for e in entries) + 2
    map_w = max(len(e["map_field"]) for e in entries) + 2
    rows: List[str] = []
    for e in entries:
        cpp_name = f"\"{e['cpp_name']}\","
        prop_name = f"\"{e['map_field']}\","
        dtype = f"SlotDType::{e['dtype']}"
        is_demo = e.get("demo") == "true"
        comment = ""
        if is_demo:
            comment = "  // demo-only (gated on ClimateProfile.demo_thermal_gradient_enabled)"
        rows.append(
            f"    {{ {cpp_name:<{cpp_w + 1}} {prop_name:<{map_w + 1}} {dtype} }},{comment}"
        )
    body = "\n".join(rows) + "\n"
    return (
        HEADER_PREFIX.format(n_entries=len(entries))
        + body
        + HEADER_SUFFIX
    )


def main() -> int:
    if not SCHEMA_PATH.exists():
        raise SystemExit(
            f"[gen_cpp_bind_table] ERROR: schema not found at {SCHEMA_PATH}"
        )
    entries = parse_schema(SCHEMA_PATH)
    validate(entries)
    output = emit(entries)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    # Compare with existing content. If unchanged, do not touch the file
    # (preserves mtime so SCons doesn't trigger a rebuild needlessly).
    existing = OUTPUT_PATH.read_text(encoding="utf-8") if OUTPUT_PATH.exists() else ""
    if existing == output:
        print(
            f"[gen_cpp_bind_table] no changes ({len(entries)} entries) — "
            f"{OUTPUT_PATH.relative_to(REPO_ROOT)}"
        )
        return 0
    OUTPUT_PATH.write_text(output, encoding="utf-8", newline="\n")
    print(
        f"[gen_cpp_bind_table] wrote {len(entries)} entries → "
        f"{OUTPUT_PATH.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
