"""Port building SoA columns to explicit stable tracked-column bindings."""
import re
from pathlib import Path
from Port_Economy_helpers import port_indexed_writes

source = Path(__file__).resolve().parents[2] / "gdext/src"
path = source / "runtime_economy_building_store.h"
header = path.read_text(encoding="utf-8-sig")
if "EconomyTrackedColumn" in header:
    raise SystemExit("building fields already ported; stable IDs must not be regenerated")
columns = re.findall(r"std::vector<(\w+)>\s+(\w+);", header)
header = header.replace("#include <vector>", '#include <vector>\n#include "economy_tracked_column.h"')
header = header.replace("struct RuntimeEconomyBuildingStore {", "struct RuntimeEconomyBuildingStore {\n    ChangeRegistry changes;")
for ctype, name in columns:
    header = header.replace(f"std::vector<{ctype}> {name};", f"EconomyTrackedColumn<{ctype}> {name};")
header = header.replace("    void clear() noexcept;", """
    RuntimeEconomyBuildingStore();
    RuntimeEconomyBuildingStore(const RuntimeEconomyBuildingStore &other);
    RuntimeEconomyBuildingStore(RuntimeEconomyBuildingStore &&other);
    RuntimeEconomyBuildingStore &operator=(const RuntimeEconomyBuildingStore &other);
    RuntimeEconomyBuildingStore &operator=(RuntimeEconomyBuildingStore &&other);
    void clear() noexcept;""")
path.write_bytes(header.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
types = {"uint8_t": ("U8", 1), "uint16_t": ("U16", 2), "uint32_t": ("U32", 4),
    "uint64_t": ("U64", 8), "int32_t": ("I32", 4), "int64_t": ("I64", 8)}
rows = []
for index, (ctype, name) in enumerate(columns, 1):
    encoding, width = types[ctype]
    rows.append(f'      {name}(changes, {{{{4, {index}}}, "building.{name}", EconomyFieldEncoding::{encoding}, {width}}})')
code = "RuntimeEconomyBuildingStore::RuntimeEconomyBuildingStore()\n    : " + ",\n".join(rows).lstrip() + " {}\n"
for argument in ["const RuntimeEconomyBuildingStore &", "RuntimeEconomyBuildingStore &&"]:
    move = "&&" in argument
    code += f"RuntimeEconomyBuildingStore::RuntimeEconomyBuildingStore({argument}other)\n    : RuntimeEconomyBuildingStore() {{ *this = " + ("std::move(other)" if move else "other") + "; }\n"
    code += f"RuntimeEconomyBuildingStore &RuntimeEconomyBuildingStore::operator=({argument}other) {{\n    if (this == &other) return *this;\n"
    for _, name in columns:
        code += (f"    {name}.move_from(other.{name});\n" if move else f"    {name}.assign(other.{name}.values());\n")
    code += "    return *this;\n}\n"
path = source / "runtime_economy_building_store.cpp"
text = path.read_text(encoding="utf-8-sig").replace("namespace pk {", "namespace pk {\n" + code, 1)
text = text.replace("const std::vector<T> &column", "const EconomyTrackedColumn<T> &column")
for ctype in types:
    text = text.replace(f"std::vector<{ctype}> &dst", f"EconomyTrackedColumn<{ctype}> &dst")
path.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
names = "|".join(name for _, name in columns)
target = re.compile(rf"(?:buildings_store\(\)|(?:[\w.()]+\.)?(?:store|buildings|building\.store))\.(?:{names})\[")
local = re.compile(rf"(?<![\w.])(?:{names})\[")
for path in sorted(source.glob("*.cpp")):
    text = path.read_text(encoding="utf-8-sig")
    if path.name == "runtime_economy_state.cpp":
        # Validation-only generic store aliases are intentionally excluded.
        continue
    chosen = local if path.name == "runtime_economy_building_store.cpp" else target
    changes = port_indexed_writes(text, chosen)
    if not changes:
        continue
    for start, end, replacement in reversed(changes):
        text = text[:start] + replacement + text[end:]
    path.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
    print(path.name, len(changes))
print("building_columns", len(columns))
