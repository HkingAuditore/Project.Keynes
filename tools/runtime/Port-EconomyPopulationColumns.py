"""One-time mechanical population-column port; compile validates aliases.

Stable IDs are explicit numeric literals in the generated constructor. Once
ported, this tool refuses to generate a second catalog or renumber fields.
"""
import re
from pathlib import Path
from Port_Economy_helpers import port_indexed_writes

root = Path(__file__).resolve().parents[2]
source = root / "gdext/src"
header_path = source / "runtime_economy_population_store.h"
header = header_path.read_text(encoding="utf-8-sig")
if "EconomyTrackedColumn" in header:
    raise SystemExit("population columns already ported; preserve stable field IDs")
columns = re.findall(r"std::vector<(\w+)>\s+(\w+);", header)
header = header.replace("#include <vector>", '#include <vector>\n#include "economy_tracked_column.h"')
header = header.replace("struct RuntimeEconomyPopulationStore {", "struct RuntimeEconomyPopulationStore {\n    ChangeRegistry changes;")
for ctype, name in columns:
    header = header.replace(f"std::vector<{ctype}> {name};", f"EconomyTrackedColumn<{ctype}> {name};")
declarations = """
    RuntimeEconomyPopulationStore();
    RuntimeEconomyPopulationStore(const RuntimeEconomyPopulationStore &other);
    RuntimeEconomyPopulationStore(RuntimeEconomyPopulationStore &&other);
    RuntimeEconomyPopulationStore &operator=(const RuntimeEconomyPopulationStore &other);
    RuntimeEconomyPopulationStore &operator=(RuntimeEconomyPopulationStore &&other);
"""
header = header.replace("    void clear(int32_t cells);", declarations + "\n    void clear(int32_t cells);")
header_path.write_bytes(header.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
encodings = {"uint8_t": ("U8", 1), "uint16_t": ("U16", 2), "uint32_t": ("U32", 4),
    "uint64_t": ("U64", 8), "int32_t": ("I32", 4), "int64_t": ("I64", 8)}
initializers = []
for field_id, (ctype, name) in enumerate(columns, 1):
    encoding, width = encodings[ctype]
    initializers.append(f'      {name}(changes, {{{{1, {field_id}}}, "population.{name}", EconomyFieldEncoding::{encoding}, {width}}})')
constructors = "RuntimeEconomyPopulationStore::RuntimeEconomyPopulationStore()\n    : " + ",\n".join(initializers).lstrip() + " {}\n\n"
for argument in ["const RuntimeEconomyPopulationStore &", "RuntimeEconomyPopulationStore &&"]:
    move = "&&" in argument
    constructors += f"RuntimeEconomyPopulationStore::RuntimeEconomyPopulationStore({argument}other)\n    : RuntimeEconomyPopulationStore() {{ *this = " + ("std::move(other)" if move else "other") + "; }\n"
    constructors += f"RuntimeEconomyPopulationStore &RuntimeEconomyPopulationStore::operator=({argument}other) {{\n    if (this == &other) return *this;\n"
    for _, name in columns:
        constructors += (f"    {name}.move_from(other.{name});\n" if move else f"    {name}.assign(other.{name}.values());\n")
    constructors += "    active_count = other.active_count; high_water_slots = other.high_water_slots; scan_steps = other.scan_steps;\n"
    if move:
        constructors += "    other.active_count = other.high_water_slots = other.scan_steps = 0;\n"
    constructors += "    return *this;\n}\n\n"
cpp = source / "runtime_economy_population_store.cpp"
text = cpp.read_text(encoding="utf-8-sig")
text = text.replace("namespace pk {", "namespace pk {\n" + constructors, 1)
cpp.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
names = "|".join(name for _, name in columns)
target = re.compile(rf"(?:population_store\(\)|(?:[\w.()]+\.)?population)\.(?:{names})\[")
local_target = re.compile(rf"(?:(?:store\.)?(?:{names}))\[")
for path in sorted(source.glob("*.cpp")):
    text = path.read_text(encoding="utf-8-sig")
    chosen = local_target if path.name == "runtime_economy_population_store.cpp" else target
    changes = port_indexed_writes(text, chosen)
    if not changes:
        continue
    for start, end, replacement in reversed(changes):
        text = text[:start] + replacement + text[end:]
    path.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
    print(path.name, len(changes))
print("population_columns", len(columns))
