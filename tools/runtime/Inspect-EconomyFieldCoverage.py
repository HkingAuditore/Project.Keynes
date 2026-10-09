"""Read-only inventory of economy columns, legacy hash dependencies and writers.

This is a grounding inventory, not a proof that a writer is registered. The
integration gate must resolve every candidate against the stable field catalog.
"""
import argparse
import json
import re
from pathlib import Path


def inspect(root: Path) -> dict:
    source = root / "gdext/src"
    headers = [
        "runtime_economy_population_store.h", "runtime_economy_state.h",
        "runtime_economy_building_store.h", "runtime_economy_live_tables.h",
        "runtime_economy_family_side_tables.h", "runtime_economy_family_store.h",
        "runtime_economy_trade_escrow_store.h",
    ]
    columns = []
    for name in headers:
        lines = (source / name).read_text(encoding="utf-8-sig").splitlines()
        owner = ""
        depth = 0
        for line_number, line in enumerate(lines, 1):
            declaration = re.search(r"^struct\s+(\w+)", line)
            if declaration and depth <= 1:
                owner = declaration.group(1)
            for match in re.finditer(r"(?:std::vector|EconomyTrackedColumn)<(.+?)>\s+(\w+)\s*[;={]", line):
                if owner:
                    columns.append({"owner": owner, "field": match.group(2),
                        "type": match.group(1), "file": f"gdext/src/{name}",
                        "line": line_number})
            depth += line.count("{") - line.count("}")
            # Namespace pk contributes one brace; reset owner at struct close.
            if line.strip() == "};":
                owner = ""

    runtime = (source / "economy_runtime.cpp").read_text(encoding="utf-8-sig")
    begin = runtime.index("int64_t NativeEconomyRuntime::state_hash_internal(")
    end = runtime.index("\nDictionary NativeEconomyRuntime::reset(", begin)
    authority_hash = runtime[begin:end]
    dependencies = sorted(set(re.findall(r"\b_[a-z][a-z0-9_]*\b", authority_hash)))
    store_dependencies = sorted(set(re.findall(r"(\w+_store\(\)\.\w+)", authority_hash)))
    writers = []
    expression = re.compile(
        r"(?:\w+_store\(\)|(?:_state|owned|restored)\.\w+)\.\w+"
        r"(?:\[[^;]+?\]\s*(?:[+\-*/|&^]?=(?!=)|\+\+|--)|"
        r"\.(?:assign|resize|clear|swap|push_back|erase|insert)\s*\()")
    for path in sorted(source.glob("*economy*.cpp")):
        for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            if expression.search(line):
                writers.append({"file": path.relative_to(root).as_posix(), "line": number,
                    "code": line.strip(), "registration": "requires_review"})
    return {"inventory_version": 1, "coverage_proven": False,
        "columns": columns, "legacy_hash_member_dependencies": dependencies,
        "legacy_hash_store_dependencies": store_dependencies, "writer_candidates": writers}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    print(json.dumps(inspect(args.root.resolve()), ensure_ascii=False, indent=2))
