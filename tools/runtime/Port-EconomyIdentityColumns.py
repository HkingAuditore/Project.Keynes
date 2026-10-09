"""One-time conversion of authoritative identity SoA; IDs are never regenerated."""
import re
from pathlib import Path
from Port_Economy_helpers import port_indexed_writes

source = Path(__file__).resolve().parents[2] / "gdext/src"
specs = [
    ("runtime_economy_live_tables.h", "EconomyFamilyStore", 5, "family", "families_store", "runtime_economy_live_tables.cpp"),
    ("runtime_economy_family_side_tables.h", "EconomyNotablePersonStore", 6, "person", "persons_store", "economy_runtime_storage.cpp"),
    ("runtime_economy_family_side_tables.h", "EconomyFamilyCellInfluenceStore", 7, "influence", "family_cell_influence_store", "economy_runtime_catalog.cpp"),
    ("runtime_economy_family_side_tables.h", "EconomyFamilyExpeditionStore", 8, "expedition", "family_expeditions_store", "economy_runtime_colonization.cpp"),
]
types = {"uint8_t": ("U8", 1), "uint16_t": ("U16", 2), "uint32_t": ("U32", 4), "uint64_t": ("U64", 8), "int32_t": ("I32", 4), "int64_t": ("I64", 8)}

def save(path, text):
    path.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))

for header_name, store, domain, label, accessor, cpp_name in specs:
    path = source / header_name
    header = path.read_text(encoding="utf-8-sig")
    start = header.index(f"struct {store} {{")
    end = header.index("\n};", start) + 3
    body = header[start:end]
    if "EconomyTrackedColumn" in body:
        raise SystemExit(f"{store} already converted; do not renumber")
    columns = re.findall(r"std::vector<(\w+)>\s+(\w+);", body)
    body = body.replace(f"struct {store} {{", f"struct {store} {{\n    ChangeRegistry changes;")
    for ctype, name in columns:
        body = body.replace(f"std::vector<{ctype}> {name};", f"EconomyTrackedColumn<{ctype}> {name};")
    declarations = f"\n    {store}();\n    {store}(const {store} &other);\n    {store}({store} &&other);\n    {store} &operator=(const {store} &other);\n    {store} &operator=({store} &&other);\n"
    body = body.replace("    void clear();", declarations + "    void clear();")
    header = header[:start] + body + header[end:]
    if '#include "economy_tracked_column.h"' not in header:
        header = header.replace("#include <vector>", '#include <vector>\n#include "economy_tracked_column.h"')
    save(path, header)
    rows = []
    for index, (ctype, name) in enumerate(columns, 1):
        encoding, width = types[ctype]
        rows.append(f'      {name}(changes, {{{{{domain}, {index}}}, "{label}.{name}", EconomyFieldEncoding::{encoding}, {width}}})')
    code = f"{store}::{store}()\n    : " + ",\n".join(rows).lstrip() + " {}\n"
    for move in (False, True):
        arg = f"{store} &&" if move else f"const {store} &"
        code += f"{store}::{store}({arg}other)\n    : {store}() {{ *this = " + ("std::move(other)" if move else "other") + "; }\n"
        code += f"{store} &{store}::operator=({arg}other) {{\n    if (this == &other) return *this;\n"
        for _, name in columns:
            code += f"    {name}.move_from(other.{name});\n" if move else f"    {name}.assign(other.{name}.values());\n"
        if "int64_t active_count" in body:
            code += "    active_count = other.active_count;\n"
            if move:
                code += "    other.active_count = 0;\n"
        code += "    return *this;\n}\n"
    path = source / cpp_name
    cpp = path.read_text(encoding="utf-8-sig").replace("namespace pk {", "namespace pk {\n" + code, 1)
    # Only methods of this store may use unqualified column names.
    methods = list(re.finditer(rf"\b(?:void|int32_t|uint64_t|bool) {store}::\w+\(", cpp))
    local = re.compile(r"(?<![\w.])(?:" + "|".join(name for _, name in columns) + r")\[")
    for match in reversed(methods):
        first = cpp.index("{", match.end())
        cursor, depth = first + 1, 1
        while depth:
            depth += (cpp[cursor] == "{") - (cpp[cursor] == "}")
            cursor += 1
        method = cpp[first:cursor]
        for a, b, replacement in reversed(port_indexed_writes(method, local)):
            method = method[:a] + replacement + method[b:]
        cpp = cpp[:first] + method + cpp[cursor:]
    save(path, cpp)
    target = re.compile(rf"{accessor}\(\)\.(?:" + "|".join(name for _, name in columns) + r")\[")
    for path in sorted(source.glob("*.cpp")):
        cpp = path.read_text(encoding="utf-8-sig")
        changes = port_indexed_writes(cpp, target)
        if not changes:
            continue
        for a, b, replacement in reversed(changes):
            # Native methods may run in a private worker task.
            replacement = replacement[:-2] + ", market_mutation_sink());"
            cpp = cpp[:a] + replacement + cpp[b:]
        save(path, cpp)
    print(store, domain, len(columns))
