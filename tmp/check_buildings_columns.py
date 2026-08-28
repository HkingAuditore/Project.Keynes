"""Verify the buildings CSV header and writer stay column-aligned.

Counts the employment_* names appended to BUILDING_V25_SUFFIX and the matching
field() calls in the buildings write block, and confirms the pre-change CSV was
already self-consistent.
"""

import csv
import re
import sys
from pathlib import Path

SRC = Path("gdext/src/economy_csv_recorder.cpp")
OLD_CSV = Path("tmp/economy_record_20260828_231131_v25_cell1788_q34_r29_buildings.csv")


def main():
    text = SRC.read_text(encoding="utf-8")

    suffix = text.split("constexpr const char *BUILDING_V25_SUFFIX =", 1)[1]
    suffix = suffix.split(";", 1)[0]
    header_names = re.findall(r'",([a-z0-9_]+)(?:\\n)?"', suffix)
    header_employment = [n for n in header_names if n.startswith("employment_")]

    block = text.split(
        "if (_config.enabled[BUILDINGS]) for (const BuildingRow &row : batch.buildings)", 1)[1]
    block = block.split("if (!flush(BUILDINGS))", 1)[0]
    written = re.findall(r"field\(chunk, row\.(employment_[a-z0-9_]+)", block)

    print(f"header employment columns : {len(header_employment)}")
    print(f"writer employment fields  : {len(written)}")
    ok = header_employment == written
    print(f"order matches             : {ok}")
    if not ok:
        print("  header:", header_employment)
        print("  writer:", written)

    if OLD_CSV.exists():
        with open(OLD_CSV, newline="", encoding="utf-8-sig") as handle:
            reader = csv.reader(handle)
            head = next(reader)
            widths = {len(head)}
            for i, row in enumerate(reader):
                widths.add(len(row))
                if i > 20000:
                    break
        print(f"baseline CSV header cols  : {len(head)}")
        print(f"baseline CSV row widths   : {sorted(widths)}")
        if len(widths) != 1:
            print("  baseline was already ragged; investigate before trusting counts")
            ok = False
        else:
            print(f"expected new column count : {len(head) + len(header_employment)}")

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
