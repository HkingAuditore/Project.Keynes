#!/usr/bin/env python3
"""Idempotent catalog patch: explicit required_q16 + soft complementary slots."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = (
    Path(__file__).resolve().parents[1]
    / "Project"
    / "project-keynes"
    / "data"
    / "economy"
    / "buildings"
)
SOFT = 32768
HARD = 65536
QTY_PER_LABOR = 100

MINT_IDS = {
    "placer_gold_working",
    "surface_silver_working",
    "shallow_silver_working",
    "primitive_gold_sluice",
}
TOOL_GOODS = {"tools", "chipped_stone_tools", "bronze_tools", "precision_tools"}
TOOL_MIN_QUALITY = {
    "chipped_stone_tools": 1,
    "bronze_tools": 2,
    "tools": 3,
    "precision_tools": 4,
}
FERT_GOODS = {"fertilizer"}
MACH_GOODS = {"agricultural_machinery", "industrial_machinery"}
T1_MIN_QUALITY_DROP_IDS = {
    "copper_ore_collector",
    "iron_ore_collector",
}
HUNTING_QTY_SCALE_IDS = {"method_stone_age_hunting_camp_r4"}
LATER_FARM_FAMILIES = {
    "field_crop_farming",
    "paddy_farming",
    "maize_farming",
    "tuber_farming",
    "highland_crop_farming",
    "specialty_commodity_crops",
}

RE_STR_ARR = re.compile(r"^(\w+) = PackedStringArray\((.*)\)\s*$", re.M)
RE_I32_ARR = re.compile(r"^(\w+) = PackedInt32Array\((.*)\)\s*$", re.M)
RE_I64_ARR = re.compile(r"^(\w+) = PackedInt64Array\((.*)\)\s*$", re.M)
RE_STR = re.compile(r'^(\w+) = "([^"]*)"\s*$', re.M)
RE_STRNAME = re.compile(r'^(\w+) = &"([^"]*)"\s*$', re.M)
RE_INT = re.compile(r"^(\w+) = (-?\d+)\s*$", re.M)


def parse_str_list(raw: str) -> list[str]:
    raw = raw.strip()
    if not raw:
        return []
    return [m.group(1) for m in re.finditer(r'"([^"]*)"', raw)]


def parse_int_list(raw: str) -> list[int]:
    raw = raw.strip()
    if not raw:
        return []
    return [int(x.strip()) for x in raw.split(",") if x.strip()]


def fmt_str(values: list[str]) -> str:
    if not values:
        return "PackedStringArray()"
    inner = ", ".join(f'"{v}"' for v in values)
    return f"PackedStringArray({inner})"


def fmt_i32(values: list[int]) -> str:
    if not values:
        return "PackedInt32Array()"
    return "PackedInt32Array(" + ", ".join(str(v) for v in values) + ")"


def fmt_i64(values: list[int]) -> str:
    if not values:
        return "PackedInt64Array()"
    return "PackedInt64Array(" + ", ".join(str(v) for v in values) + ")"


def set_line(text: str, key: str, formatted: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)} = .*$", re.M)
    replacement = f"{key} = {formatted}"
    if pattern.search(text):
        return pattern.sub(replacement, text, count=1)
    anchor = re.compile(r"^input_quantities_per_day = .*$", re.M)
    match = anchor.search(text)
    if match:
        return text[: match.end()] + "\n" + replacement + text[match.end() :]
    return text


def fields(text: str) -> dict:
    out: dict = {}
    for m in RE_STRNAME.finditer(text):
        out[m.group(1)] = m.group(2)
    for m in RE_STR.finditer(text):
        out[m.group(1)] = m.group(2)
    for m in RE_INT.finditer(text):
        out[m.group(1)] = int(m.group(2))
    for m in RE_STR_ARR.finditer(text):
        out[m.group(1)] = parse_str_list(m.group(2))
    for m in RE_I32_ARR.finditer(text):
        out[m.group(1)] = parse_int_list(m.group(2))
    for m in RE_I64_ARR.finditer(text):
        out[m.group(1)] = parse_int_list(m.group(2))
    return out


def labor_slots(f: dict) -> int:
    owner = int(f.get("owner_slots_per_building", 1))
    employees = f.get("employee_slots_per_building") or []
    return max(1, owner + sum(employees))


def is_tool_slot(good: str, category: str) -> bool:
    return category == "tools" or good in TOOL_GOODS


def is_fert_slot(good: str, category: str) -> bool:
    return category == "fertilizer" or good in FERT_GOODS


def is_mach_slot(good: str, category: str) -> bool:
    return category == "agricultural_machinery" or good in MACH_GOODS


def is_productivity(good: str, category: str) -> bool:
    return is_tool_slot(good, category) or is_fert_slot(good, category) or is_mach_slot(good, category)


def should_skip_new_tools(f: dict) -> bool:
    bid = f.get("id", "")
    if bid in MINT_IDS:
        return True
    if f.get("economic_sector_id") == "knowledge":
        return True
    if f.get("building_kind") == "service":
        return True
    if f.get("building_kind") != "collector":
        return True
    if str(f.get("upgrade_family_id", "") or "") == "household_cloth":
        return True
    if not (f.get("resource_ids") or []):
        return True
    return False


FARM_CAPACITY_RESOURCES = {
    "arable_land",
    "paddy_land",
    "plantation_land",
    "pasture",
}


def should_add_fertilizer(f: dict) -> bool:
    if f.get("building_kind") != "collector":
        return False
    if f.get("id") == "subsistence_farm":
        return False
    family = str(f.get("upgrade_family_id", "") or "")
    tier = int(f.get("upgrade_tier", 0) or 0)
    if family in {"hunting", "freshwater_fishing", "household_cloth"}:
        return False
    tags = f.get("semantic_tags") or []
    if "starter.construction" in tags:
        return False
    if family == "subsistence_food":
        return tier >= 3
    if family in LATER_FARM_FAMILIES:
        return True
    resources = f.get("resource_ids") or []
    return any(resource in FARM_CAPACITY_RESOURCES for resource in resources)


def scale_extract_resources(f: dict, resources: list[int]) -> list[int]:
    modes = list(f.get("resource_interaction_modes") or [])
    scaled = list(resources)
    for i, value in enumerate(scaled):
        mode = modes[i] if i < len(modes) else "extract"
        if mode != "capacity":
            scaled[i] = value * 2
    return scaled


def extend_offsets(old: list[int], old_n: int, new_n: int) -> list[int]:
    if new_n <= 0:
        return [0]
    if old_n <= 0 or len(old) != old_n + 1:
        return [0] * (new_n + 1)
    last = old[-1]
    return list(old) + [last] * (new_n - old_n)


def patch_file(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    f = fields(text)
    bid = f.get("id", path.stem)
    goods: list[str] = list(f.get("input_good_ids") or [])
    qty: list[int] = list(f.get("input_quantities_per_day") or [])
    required: list[int] = list(f.get("input_required_q16") or [])
    cats: list[str] = list(f.get("input_category_ids") or [])
    mins: list[int] = list(f.get("input_min_quality_levels") or [])
    outputs: list[int] = list(f.get("output_quantities_per_day") or [])
    resources: list[int] = list(f.get("resource_quantities_per_day") or [])
    offsets: list[int] = list(f.get("input_candidate_offsets") or [0])
    old_n = len(goods)
    n = old_n
    added_tools = False
    added_fert = False
    changed_goods = False
    changed_qty = False
    changed_required = False
    changed_cats = False
    changed_mins = False
    changed_offsets = False
    changed_outputs = False
    changed_resources = False

    if n and len(qty) != n:
        return f"skip qty mismatch {bid}"

    if n and not required:
        required = [HARD] * n
        changed_required = True
    if n and not cats:
        cats = [""] * n
    if n and not mins:
        mins = [0] * n
    if n:
        if len(cats) != n:
            cats = (cats + [""] * n)[:n]
            changed_cats = True
        if len(mins) != n:
            mins = (mins + [0] * n)[:n]
            changed_mins = True
        if len(required) != n:
            required = (required + [HARD] * n)[:n]
            changed_required = True

    for i, good in enumerate(goods):
        cat = cats[i] if i < len(cats) else ""
        if is_productivity(good, cat) and required[i] != SOFT:
            required[i] = SOFT
            changed_required = True
        if is_tool_slot(good, cat) and bid in T1_MIN_QUALITY_DROP_IDS:
            if mins[i] != 1:
                mins[i] = 1
                changed_mins = True
            if cats[i] != "tools":
                cats[i] = "tools"
                changed_cats = True
            if goods[i] != "tools":
                goods[i] = "tools"
                changed_goods = True
        if is_tool_slot(good, cat) and bid in HUNTING_QTY_SCALE_IDS:
            target = QTY_PER_LABOR * labor_slots(f)
            if qty[i] != target:
                qty[i] = target
                changed_qty = True
        if good in TOOL_MIN_QUALITY:
            if len(cats) != n:
                cats = (cats + [""] * n)[:n]
            if len(mins) != n:
                mins = (mins + [0] * n)[:n]
            if good != "tools":
                era_min = TOOL_MIN_QUALITY[good]
                if cats[i] != "tools":
                    cats[i] = "tools"
                    changed_cats = True
                if mins[i] < era_min:
                    mins[i] = era_min
                    changed_mins = True
                if goods[i] != "tools":
                    goods[i] = "tools"
                    changed_goods = True
            elif cats[i] != "tools":
                cats[i] = "tools"
                changed_cats = True
                if mins[i] <= 0:
                    mins[i] = TOOL_MIN_QUALITY["tools"]
                    changed_mins = True
        if bid in HUNTING_QTY_SCALE_IDS and i < len(mins) and mins[i] != 3:
            mins[i] = 3
            changed_mins = True

    if n == 0 and not should_skip_new_tools(f):
        labor = labor_slots(f)
        goods = ["tools"]
        qty = [QTY_PER_LABOR * labor]
        required = [SOFT]
        cats = ["tools"]
        mins = [1]
        n = 1
        added_tools = True
        changed_goods = changed_qty = changed_required = True
        changed_cats = changed_mins = changed_offsets = True
        outputs = [v * 2 for v in outputs]
        changed_outputs = True
        if resources:
            resources = scale_extract_resources(f, resources)
            changed_resources = True

    if should_add_fertilizer(f) and not any(
        is_fert_slot(g, cats[i] if i < len(cats) else "") for i, g in enumerate(goods)
    ):
        owner = int(f.get("owner_slots_per_building", 1))
        goods.append("fertilizer")
        qty.append(QTY_PER_LABOR * max(1, owner))
        required.append(SOFT)
        cats.append("fertilizer")
        mins.append(0)
        n = len(goods)
        added_fert = True
        changed_goods = changed_qty = changed_required = True
        changed_cats = changed_mins = changed_offsets = True

    if changed_offsets:
        offsets = extend_offsets(offsets, old_n, n)

    if changed_goods:
        text = set_line(text, "input_good_ids", fmt_str(goods))
    if changed_qty:
        text = set_line(text, "input_quantities_per_day", fmt_i64(qty))
    if changed_required:
        text = set_line(text, "input_required_q16", fmt_i32(required))
    if changed_cats:
        text = set_line(text, "input_category_ids", fmt_str(cats))
    if changed_mins:
        text = set_line(text, "input_min_quality_levels", fmt_i32(mins))
    if changed_offsets:
        text = set_line(text, "input_candidate_offsets", fmt_i32(offsets))
    if changed_outputs:
        text = set_line(text, "output_quantities_per_day", fmt_i64(outputs))
    if changed_resources and f.get("resource_quantities_per_day"):
        text = set_line(text, "resource_quantities_per_day", fmt_i64(resources))

    if not any(
        [
            changed_goods,
            changed_qty,
            changed_required,
            changed_cats,
            changed_mins,
            changed_offsets,
            changed_outputs,
            changed_resources,
        ]
    ):
        return f"{bid}: noop"

    path.write_text(text, encoding="utf-8", newline="\n")
    flags = []
    if added_tools:
        flags.append("add_tools")
    if added_fert:
        flags.append("add_fert")
    if bid in T1_MIN_QUALITY_DROP_IDS and changed_mins:
        flags.append("t1_quality")
    if bid in HUNTING_QTY_SCALE_IDS and changed_qty:
        flags.append("scale_qty")
    if changed_required and not flags:
        flags.append("fill_required")
    return f"{bid}: {','.join(flags) or 'update'}"


def main() -> None:
    if not ROOT.is_dir():
        raise SystemExit(f"missing building dir: {ROOT}")
    reports = [patch_file(path) for path in sorted(ROOT.glob("*.tres"))]
    added = [r for r in reports if "add_tools" in r]
    fert = [r for r in reports if "add_fert" in r]
    other = [r for r in reports if r.split(": ", 1)[-1] not in ("noop",) and r not in added and r not in fert]
    print(
        f"patched {len(reports)} buildings; added tools {len(added)}; "
        f"added fertilizer {len(fert)}; other {len(other)}"
    )
    for row in added + fert + other:
        if not row.endswith(": noop"):
            print(" ", row)


if __name__ == "__main__":
    main()
