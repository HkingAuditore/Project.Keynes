"""Replace persistence decoder's direct mutable lane references with writes."""
import re
from pathlib import Path

source = Path(__file__).resolve().parents[2] / "gdext/src"
target = re.compile(r"read_le\(bytes,\s*cursor,\s*(population_store\(\)\.\w+)\s*\[([^\]]+)\]\)")
for path in sorted(source.glob("*.cpp")):
    text = path.read_text(encoding="utf-8-sig")
    updated, count = target.subn(lambda m: f"read_column_le(bytes, cursor, {m[1]}, {m[2]})", text)
    if count:
        path.write_bytes(updated.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
        print(path.name, count)
