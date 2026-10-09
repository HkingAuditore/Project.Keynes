"""Read-only inventory of economy columns, legacy hash dependencies and writers.

This is a grounding inventory, not a proof that a writer is registered. The
integration gate must resolve every candidate against the stable field catalog.
"""
import argparse
import json
import re
from pathlib import Path

CONTAINERS = (
    "std::vector", "EconomyTrackedColumn", "EconomyOwnedColumn",
    "EconomyTrackedScalar", "EconomyTrackedRecords",
    "EconomyKeyedVariableRecords", "EconomyOwnedRecordValue", "EconomyTrackedJournal",
)
DECLARATION = re.compile(
    r"(" + "|".join(re.escape(name) for name in CONTAINERS) +
    r")<(.+)>\s+(\w+)\s*[;={]"
)


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
            for match in DECLARATION.finditer(line):
                if owner:
                    columns.append({"owner": owner, "field": match.group(3),
                        "type": match.group(2), "container": match.group(1),
                        "write_guarded": match.group(1) != "std::vector",
                        "file": f"gdext/src/{name}", "line": line_number})
            depth += line.count("{") - line.count("}")
            # Namespace pk contributes one brace; reset owner at struct close.
            if line.strip() == "};":
                owner = ""

    # Native owns additional configuration, command, journal and side-table
    # fields. Record these separately from store columns: a tracked declaration
    # alone does not establish persistence, authority or consumer ownership.
    native_columns = []
    native_header = source / "economy_runtime.h"
    primitive = re.compile(r"(bool|(?:u?int(?:8|16|32|64)_t)|float|double|std::string)\s+(_\w+)\s*(?:[;={])")
    for number, line in enumerate(native_header.read_text(encoding="utf-8-sig").splitlines(), 1):
        match = DECLARATION.match(line.strip())
        if match and match.group(3).startswith("_"):
            native_columns.append({"owner": "NativeEconomyRuntime", "field": match.group(3),
                "type": match.group(2), "container": match.group(1),
                "write_guarded": match.group(1) != "std::vector",
                "file": "gdext/src/economy_runtime.h", "line": number,
                "authority_classification": "requires_review"})
        elif line.startswith("    ") and not line.startswith("        "):
            match = primitive.match(line.strip())
            if match:
                native_columns.append({"owner": "NativeEconomyRuntime", "field": match.group(2),
                    "type": match.group(1), "container": "scalar", "write_guarded": False,
                    "file": "gdext/src/economy_runtime.h", "line": number,
                    "authority_classification": "requires_review"})

    # A save reference is a review candidate, not proof: expressions can refer
    # to a derived projection or diagnostic counter inside the same section.
    persistence_references = {}
    for path in sorted(source.glob("economy_runtime_persistence*.cpp")):
        for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            line = line.split("//", 1)[0]
            for field in set(re.findall(r"\b_[a-z][a-z0-9_]*\b", line)):
                persistence_references.setdefault(field, []).append({
                    "file": path.relative_to(root).as_posix(), "line": number})
    for column in native_columns:
        column["persistence_references"] = persistence_references.get(column["field"], [])

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
    guarded_writer = re.compile(r"\.\s*(?:write_scalar|write_values|write_range|write_record|edit_row|borrow_row|move_from|fill_range)\s*\(")
    for path in sorted(source.glob("*economy*.cpp")):
        for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            if expression.search(line) or guarded_writer.search(line):
                writers.append({"file": path.relative_to(root).as_posix(), "line": number,
                    "code": line.strip(), "registration": "requires_review"})
    bindings = {}
    descriptor_pattern = re.compile(r'\{\{\s*(\d+)\s*,\s*(\d+)\s*\},\s*"([^"]+)"\s*,\s*EconomyFieldEncoding::(\w+)\s*,\s*(\d+)')
    for path in sorted(source.glob("*economy*.*")):
        if path.suffix not in {".h", ".cpp"}:
            continue
        content = path.read_text(encoding="utf-8-sig")
        for match in descriptor_pattern.finditer(content):
            domain, column, label, encoding, width = match.groups()
            key = f"{domain}:{column}"
            item = {"domain": int(domain), "column": int(column), "name": label,
                "encoding": encoding, "width": int(width)}
            if key in bindings and any(bindings[key][name] != item[name] for name in item):
                raise ValueError(f"field binding conflict: {key}")
            if key not in bindings:
                bindings[key] = dict(item, sources=[], binding_sites=[],
                    authority_classification="requires_review", consumers="requires_review")
            bindings[key]["sources"].append(path.relative_to(root).as_posix())
            bindings[key]["binding_sites"].append({"file": path.relative_to(root).as_posix(),
                "line": content.count("\n", 0, match.start()) + 1})
    return {"inventory_version": 3, "coverage_proven": False,
        "registered_bindings": [bindings[key] for key in sorted(bindings, key=lambda key: tuple(map(int, key.split(':'))))],
        "columns": columns, "native_columns": native_columns,
        "unguarded_native_persistence_candidates": [column for column in native_columns
            if not column["write_guarded"] and column["persistence_references"]],
        "legacy_hash_member_dependencies": dependencies,
        "legacy_hash_store_dependencies": store_dependencies, "writer_candidates": writers}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    print(json.dumps(inspect(args.root.resolve()), ensure_ascii=False, indent=2))
