#!/usr/bin/env python3
"""Keep native environment reads and fault-injection names in the reviewed registry."""
from __future__ import annotations
import argparse
from collections import Counter
import json
from pathlib import Path
import re
from check_cpp_deps import NON_CODE

ROOT = Path(__file__).resolve().parents[2]
HEADER = "gdext/src/runtime_switch_registry.h"
IMPLEMENTATION = "gdext/src/runtime_switch_registry.cpp"


def mask(source: str) -> str:
    return NON_CODE.sub(lambda m: "".join("\n" if c == "\n" else " " for c in m[0]), source)


def inspect(root: Path, baseline: dict) -> tuple[list[str], dict]:
    header = (root / HEADER).read_text()
    registry = (root / IMPLEMENTATION).read_text()
    enum = re.search(r"enum class RuntimeSwitch\s*\{([\s\S]*?)\};", header)
    names = re.findall(r"\bPK_\w+\b", enum[1]) if enum else []
    entries = re.findall(r'\{"(PK_[^"\n]+)",\s*"[^"\n]+",\s*"[^"\n]+",\s*(?:true|false)\}', registry)
    faults = re.findall(r'\{"([^"\n]+)", "disabled until armed", "[^"\n]+", true\}', registry)
    errors = []
    if not names or names != entries or len(set(names)) != len(names):
        errors.append("switch enum and descriptor order differ, duplicate or missing metadata")
    if len(set(faults)) != len(faults):
        errors.append("duplicate fault names")
    host = root / "gdext/src/native_simulation_host.cpp"
    host_source = host.read_text() if host.exists() else ""
    tags_fn = re.search(r'const char \*runtime_domain_fault_tag\([^{}]*\)[^{]*\{[\s\S]*?\n}', host_source)
    tags = re.findall(r'return "([\w_]+)";', tags_fn[0]) if tags_fn else []
    for tag in tags:
        for side in ("before", "after"):
            if f"{tag}.plan.{side}" not in faults:
                errors.append(f"unregistered domain fault: {tag}.plan.{side}")
    raw: Counter[str] = Counter()
    dynamic: Counter[str] = Counter()
    reads = 0
    points = 0
    for path in sorted((root / "gdext/src").rglob("*")):
        if path.suffix not in {".cpp", ".h"}:
            continue
        rel = path.relative_to(root).as_posix()
        source = path.read_text()
        code = mask(source)
        if rel != IMPLEMENTATION:
            raw[rel] += len(re.findall(r"\bgetenv\b", code))
        if rel not in {HEADER, IMPLEMENTATION}:
            for call in re.finditer(r"\bruntime_switch_value\s*\(([^)]*)\)", code):
                reads += 1
                match = re.fullmatch(r"\s*(?:pk::)?RuntimeSwitch::(PK_\w+)\s*", call[1])
                if not match or match[1] not in names:
                    errors.append(f"{rel}: unregistered or indirect environment read: {call[1]}")
        for call in re.finditer(r'\btry_fault_injection\s*\(([^)]*)\)', source):
            if not code[call.start():call.start()+19].strip():
                continue
            arg = call[1].strip()
            if arg == "const char *point":
                continue  # Existing private declaration/definition, not a call.
            points += 1
            if re.fullmatch(r'"[^"\n]+"', arg):
                if arg[1:-1] not in faults:
                    errors.append(f"{rel}: unregistered fault: {arg}")
                continue
            # The only dynamic generator is the existing domain plan boundary.
            side = {"before_point": "before", "after_point": "after"}.get(arg)
            pattern = (r'std::snprintf\(' + re.escape(arg) + r', sizeof\(' + re.escape(arg)
                       + r'\), "%s\.plan\.' + str(side)
                       + r'",\s*runtime_domain_fault_tag\((?:stage\.domain|previous_domain)\)\);')
            if (rel == "gdext/src/native_simulation_host.cpp" and side and tags
                    and re.search(pattern, source)):
                continue
            dynamic[f"{rel}|{arg}"] += 1
    for label, counts in (("raw_getenv", raw), ("dynamic_faults", dynamic)):
        for key, count in counts.items():
            allowance = baseline.get(label, {}).get(key, {})
            allowed = allowance.get("count", 0)
            if count > allowed or (allowed and not allowance.get("reason")):
                errors.append(f"{label}: {key}: {count} > {allowed} or missing reason")
    return errors, {"switches": len(names), "reads": reads, "fault_names": len(faults),
                    "fault_calls": points, "raw_reads": sum(raw.values()),
                    "unregistered_dynamic": sum(dynamic.values())}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=Path(__file__).with_name("runtime_switches_baseline.json"))
    args = parser.parse_args()
    errors, counts = inspect(args.root, json.loads(args.baseline.read_text()))
    print("Runtime switches: " + json.dumps(counts) + f"; {len(errors)} violations")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
