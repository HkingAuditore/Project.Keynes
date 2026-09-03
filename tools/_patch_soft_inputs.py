#!/usr/bin/env python3
"""Idempotent catalog patch: soft tool slots + optional yield rebalance."""
from __future__ import annotations

import argparse
import math
import re
import shutil
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent  # Project.Keynes
ROOT = (
    REPO_ROOT
    / "Project"
    / "project-keynes"
    / "data"
    / "economy"
    / "buildings"
)
CURATED_ROOT = TOOLS_DIR / "codegen" / "economy_content" / "buildings"

SOFT = 32768
HARD = 65536
QTY_PER_LABOR = 100
Q16_ONE = 65536
PROGRESSION_FLOOR = 1.34
STARTER_BARE_FLOOR = 0.9

MINT_IDS = {
    "placer_gold_working",
    "surface_silver_working",
    "shallow_silver_working",
    "primitive_gold_sluice",
}
MERCHANT_POST_IDS = {
    "merchant_post",
    "early_merchant_post",
}
TOOL_GOODS = {
    "tools",
    "chipped_stone_tools",
    "copper_tools",
    "bronze_tools",
    "precision_tools",
}
TOOL_MIN_QUALITY = {
    "chipped_stone_tools": 1,
    "copper_tools": 1,
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
FARM_CAPACITY_RESOURCES = {
    "arable_land",
    "paddy_land",
    "plantation_land",
    "pasture",
}
# Authored predecessor/upgrade links miss several early->later yield ladders.
EXTRA_EDGES = [
    ("stone_age_hunting_camp", "method_stone_age_hunting_camp_r4"),
    ("stone_age_hunting_camp", "small_game_trapline"),
    ("gathering_ground", "method_gathering_ground_r1"),
    ("gathering_ground", "subsistence_farm"),
    ("deadwood_gathering_camp", "method_timber_collector_r2"),
    ("deadwood_gathering_camp", "timber_collector"),
    ("freshwater_fishing_camp", "marine_fish_collector"),
    ("freshwater_fishing_camp", "method_marine_fish_collector_r2"),
    ("rubble_stone_working", "stone_collector"),
]
# Entry buildings whose bare yield should stay close to the pre-soft recipe.
STARTER_IDS = {
    "stone_age_hunting_camp",
    "gathering_ground",
    "deadwood_gathering_camp",
    "freshwater_fishing_camp",
    "rubble_stone_working",
    "subsistence_farm",
    "bast_fiber_camp",
    "surface_coal_gathering",
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
    return max(1, owner + sum(int(x) for x in employees))


def is_tool_slot(good: str, category: str) -> bool:
    return category == "tools" or good in TOOL_GOODS


def is_fert_slot(good: str, category: str) -> bool:
    return category == "fertilizer" or good in FERT_GOODS


def is_mach_slot(good: str, category: str) -> bool:
    return category == "agricultural_machinery" or good in MACH_GOODS


def is_productivity(good: str, category: str) -> bool:
    return is_tool_slot(good, category) or is_fert_slot(good, category) or is_mach_slot(
        good, category
    )


def has_tool_slot(f: dict) -> bool:
    goods = f.get("input_good_ids") or []
    cats = f.get("input_category_ids") or []
    for i, good in enumerate(goods):
        cat = cats[i] if i < len(cats) else ""
        if is_tool_slot(good, cat):
            return True
    return False


def is_tool_producer(f: dict) -> bool:
    return any(good in TOOL_GOODS for good in (f.get("output_good_ids") or []))


def tool_min_quality_for(f: dict) -> int:
    rank = int(f.get("maturity_rank", 0) or 0)
    if rank <= 2:
        return 1
    if rank <= 4:
        return 2
    return 3


def should_skip_new_tools(f: dict) -> bool:
    bid = f.get("id", "")
    if bid in MINT_IDS or bid in MERCHANT_POST_IDS:
        return True
    if f.get("economic_sector_id") == "knowledge":
        return True
    if f.get("building_kind") == "service":
        return True
    if str(f.get("upgrade_family_id", "") or "") == "household_cloth":
        return True
    if is_tool_producer(f):
        return True
    outputs = f.get("output_good_ids") or []
    if not outputs:
        return True
    return False


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


def scale_extract_resources(f: dict, resources: list[int], factor: float) -> list[int]:
    modes = list(f.get("resource_interaction_modes") or [])
    scaled: list[int] = []
    for i, value in enumerate(resources):
        mode = modes[i] if i < len(modes) else "extract"
        if mode == "capacity":
            scaled.append(int(value))
        else:
            scaled.append(max(1, int(math.ceil(value * factor))))
    return scaled


def extend_offsets(old: list[int], old_n: int, new_n: int) -> list[int]:
    if new_n <= 0:
        return [0]
    if old_n <= 0 or len(old) != old_n + 1:
        return [0] * (new_n + 1)
    last = old[-1]
    return list(old) + [last] * (new_n - old_n)


def soft_floor_q16(f: dict) -> int:
    """Bare-handed capacity floor implied by tool soft slots (min over tool slots)."""
    goods = f.get("input_good_ids") or []
    cats = f.get("input_category_ids") or []
    required = f.get("input_required_q16") or []
    floor = Q16_ONE
    found = False
    for i, good in enumerate(goods):
        cat = cats[i] if i < len(cats) else ""
        if not is_tool_slot(good, cat):
            continue
        req = required[i] if i < len(required) else HARD
        req = max(0, min(Q16_ONE, int(req)))
        found = True
        floor = min(floor, Q16_ONE - req)
    return floor if found else Q16_ONE


def main_output(f: dict) -> int:
    outputs = f.get("output_quantities_per_day") or []
    return int(outputs[0]) if outputs else 0


def full_opl(f: dict) -> float:
    labor = labor_slots(f)
    return main_output(f) / float(labor)


def bare_main_output(f: dict) -> float:
    return main_output(f) * soft_floor_q16(f) / float(Q16_ONE)


def write_building(path: Path, text: str, f: dict, *,
                   goods, qty, required, cats, mins, offsets,
                   outputs, resources,
                   changed: dict[str, bool]) -> None:
    if changed.get("goods"):
        text = set_line(text, "input_good_ids", fmt_str(goods))
    if changed.get("qty"):
        text = set_line(text, "input_quantities_per_day", fmt_i64(qty))
    if changed.get("required"):
        text = set_line(text, "input_required_q16", fmt_i32(required))
    if changed.get("cats"):
        text = set_line(text, "input_category_ids", fmt_str(cats))
    if changed.get("mins"):
        text = set_line(text, "input_min_quality_levels", fmt_i32(mins))
    if changed.get("offsets"):
        text = set_line(text, "input_candidate_offsets", fmt_i32(offsets))
    if changed.get("outputs"):
        text = set_line(text, "output_quantities_per_day", fmt_i64(outputs))
    if changed.get("resources") and (f.get("resource_quantities_per_day") is not None):
        text = set_line(text, "resource_quantities_per_day", fmt_i64(resources))
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_file(path: Path, *, tools_only: bool) -> str:
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
    appended_tools = False
    added_fert = False
    changed = {
        "goods": False,
        "qty": False,
        "required": False,
        "cats": False,
        "mins": False,
        "offsets": False,
        "outputs": False,
        "resources": False,
    }

    if n and len(qty) != n:
        return f"skip qty mismatch {bid}"

    if n and not required:
        required = [HARD] * n
        changed["required"] = True
    if n and not cats:
        cats = [""] * n
    if n and not mins:
        mins = [0] * n
    if n:
        if len(cats) != n:
            cats = (cats + [""] * n)[:n]
            changed["cats"] = True
        if len(mins) != n:
            mins = (mins + [0] * n)[:n]
            changed["mins"] = True
        if len(required) != n:
            required = (required + [HARD] * n)[:n]
            changed["required"] = True

    for i, good in enumerate(goods):
        cat = cats[i] if i < len(cats) else ""
        if is_productivity(good, cat) and required[i] != SOFT:
            required[i] = SOFT
            changed["required"] = True
        if is_tool_slot(good, cat) and bid in T1_MIN_QUALITY_DROP_IDS:
            if mins[i] != 1:
                mins[i] = 1
                changed["mins"] = True
            if cats[i] != "tools":
                cats[i] = "tools"
                changed["cats"] = True
            if goods[i] != "tools":
                goods[i] = "tools"
                changed["goods"] = True
        if is_tool_slot(good, cat) and bid in HUNTING_QTY_SCALE_IDS:
            target = QTY_PER_LABOR * labor_slots(f)
            if qty[i] != target:
                qty[i] = target
                changed["qty"] = True
        if is_tool_slot(good, cat) and bid in {"timber_collector", "stone_collector"}:
            target = QTY_PER_LABOR * labor_slots(f)
            if qty[i] != target:
                qty[i] = target
                changed["qty"] = True
            if goods[i] != "tools":
                goods[i] = "tools"
                changed["goods"] = True
            if cats[i] != "tools":
                cats[i] = "tools"
                changed["cats"] = True
            if mins[i] != 1:
                mins[i] = 1
                changed["mins"] = True
        if good in TOOL_MIN_QUALITY:
            if len(cats) != n:
                cats = (cats + [""] * n)[:n]
            if len(mins) != n:
                mins = (mins + [0] * n)[:n]
            if good != "tools":
                era_min = TOOL_MIN_QUALITY[good]
                if cats[i] != "tools":
                    cats[i] = "tools"
                    changed["cats"] = True
                if mins[i] < era_min:
                    mins[i] = era_min
                    changed["mins"] = True
                if goods[i] != "tools":
                    goods[i] = "tools"
                    changed["goods"] = True
            elif cats[i] != "tools":
                cats[i] = "tools"
                changed["cats"] = True
                if mins[i] <= 0:
                    mins[i] = TOOL_MIN_QUALITY["tools"]
                    changed["mins"] = True
        if bid in HUNTING_QTY_SCALE_IDS and i < len(mins) and mins[i] != 3:
            mins[i] = 3
            changed["mins"] = True

    if n == 0 and not should_skip_new_tools(f):
        labor = labor_slots(f)
        goods = ["tools"]
        qty = [QTY_PER_LABOR * labor]
        required = [SOFT]
        cats = ["tools"]
        mins = [tool_min_quality_for(f)]
        n = 1
        added_tools = True
        changed["goods"] = changed["qty"] = changed["required"] = True
        changed["cats"] = changed["mins"] = changed["offsets"] = True
        modes = list(f.get("resource_interaction_modes") or [])
        has_capacity = any(mode == "capacity" for mode in modes)
        # Capacity (or mixed capacity) lots keep authored full-tool land
        # productivity; soft tools then make bare-handed yield half of today.
        # Pure extract collectors still double so bare hands match the pre-soft
        # recipe.
        if outputs and not has_capacity:
            outputs = [v * 2 for v in outputs]
            changed["outputs"] = True
            if resources:
                resources = scale_extract_resources(f, resources, 2.0)
                changed["resources"] = True
        elif outputs and has_capacity:
            pass
    elif n > 0 and not has_tool_slot({"input_good_ids": goods, "input_category_ids": cats}) \
            and not should_skip_new_tools(f):
        labor = labor_slots(f)
        goods.append("tools")
        qty.append(QTY_PER_LABOR * labor)
        required.append(SOFT)
        cats.append("tools")
        mins.append(tool_min_quality_for(f))
        n = len(goods)
        appended_tools = True
        changed["goods"] = changed["qty"] = changed["required"] = True
        changed["cats"] = changed["mins"] = changed["offsets"] = True

    if (not tools_only) and should_add_fertilizer(f) and not any(
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
        changed["goods"] = changed["qty"] = changed["required"] = True
        changed["cats"] = changed["mins"] = changed["offsets"] = True

    if changed["offsets"]:
        offsets = extend_offsets(offsets, old_n, n)

    if not any(changed.values()):
        return f"{bid}: noop"

    write_building(
        path,
        text,
        f,
        goods=goods,
        qty=qty,
        required=required,
        cats=cats,
        mins=mins,
        offsets=offsets,
        outputs=outputs,
        resources=resources,
        changed=changed,
    )
    flags = []
    if added_tools:
        flags.append("add_tools")
    if appended_tools:
        flags.append("append_tools")
    if added_fert:
        flags.append("add_fert")
    if bid in T1_MIN_QUALITY_DROP_IDS and changed["mins"]:
        flags.append("t1_quality")
    if bid in HUNTING_QTY_SCALE_IDS and changed["qty"]:
        flags.append("scale_qty")
    if changed["required"] and not flags:
        flags.append("fill_required")
    if changed["outputs"] and "add_tools" not in flags:
        flags.append("scale_out")
    return f"{bid}: {','.join(flags) or 'update'}"


def load_all() -> dict[str, dict]:
    buildings: dict[str, dict] = {}
    for path in sorted(ROOT.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        f = fields(text)
        f["_path"] = path
        f["_text"] = text
        f["id"] = f.get("id", path.stem)
        buildings[f["id"]] = f
    return buildings


def scale_building_yield(f: dict, factor: float) -> None:
    outputs = [max(1, int(math.ceil(v * factor))) for v in (f.get("output_quantities_per_day") or [])]
    f["output_quantities_per_day"] = outputs
    resources = list(f.get("resource_quantities_per_day") or [])
    if resources:
        f["resource_quantities_per_day"] = scale_extract_resources(f, resources, factor)


def persist_yield(f: dict) -> None:
    path: Path = f["_path"]
    text = path.read_text(encoding="utf-8")
    text = set_line(text, "output_quantities_per_day", fmt_i64(f.get("output_quantities_per_day") or []))
    if f.get("resource_quantities_per_day") is not None:
        text = set_line(
            text,
            "resource_quantities_per_day",
            fmt_i64(f.get("resource_quantities_per_day") or []),
        )
    path.write_text(text, encoding="utf-8", newline="\n")
    f["_text"] = text


def same_primary_good(a: dict, b: dict) -> bool:
    e_goods = a.get("output_good_ids") or []
    l_goods = b.get("output_good_ids") or []
    return bool(e_goods and l_goods and e_goods[0] == l_goods[0])


def progression_edges(buildings: dict[str, dict]) -> list[tuple[str, str]]:
    """Only the explicit soft-tool inversion edges."""
    edges: set[tuple[str, str]] = set()
    for earlier_id, later_id in EXTRA_EDGES:
        if earlier_id not in buildings or later_id not in buildings:
            continue
        earlier = buildings[earlier_id]
        later = buildings[later_id]
        if not same_primary_good(earlier, later):
            continue
        edges.add((earlier_id, later_id))
    return sorted(edges)


def rebalance_yields(buildings: dict[str, dict], *, bare_targets: dict[str, int]) -> list[str]:
    """Raise later yields on EXTRA_EDGES after empty->soft doubling."""
    reports: list[str] = []
    edges = progression_edges(buildings)

    for _pass in range(4):
        changed = False
        for earlier_id, later_id in edges:
            earlier = buildings[earlier_id]
            later = buildings[later_id]
            if main_output(earlier) <= 0 or main_output(later) <= 0:
                continue
            need = full_opl(earlier) * PROGRESSION_FLOOR
            have = full_opl(later)
            if have + 1e-9 >= need:
                continue
            factor = min(need / max(have, 1e-9), 4.0)
            scale_building_yield(later, factor)
            persist_yield(later)
            reports.append(
                f"raise {later_id} x{factor:.3f} vs {earlier_id} "
                f"(opl {have:.1f}->{full_opl(later):.1f}, need {need:.1f})"
            )
            changed = True
        if not changed:
            break

    for bid, target in bare_targets.items():
        if bid not in STARTER_IDS or bid not in buildings or target <= 0:
            continue
        f = buildings[bid]
        bare = bare_main_output(f)
        floor = target * STARTER_BARE_FLOOR
        if bare + 1e-9 >= floor:
            continue
        factor = min(floor / max(bare, 1e-9), 2.0)
        scale_building_yield(f, factor)
        persist_yield(f)
        reports.append(
            f"raise_starter_bare {bid} x{factor:.3f} bare {bare:.1f}->{bare_main_output(f):.1f} "
            f"(target>={floor:.1f})"
        )

    for _pass in range(3):
        changed = False
        for earlier_id, later_id in edges:
            earlier = buildings[earlier_id]
            later = buildings[later_id]
            if main_output(earlier) <= 0 or main_output(later) <= 0:
                continue
            need = full_opl(earlier) * PROGRESSION_FLOOR
            have = full_opl(later)
            if have + 1e-9 >= need:
                continue
            factor = min(need / max(have, 1e-9), 4.0)
            scale_building_yield(later, factor)
            persist_yield(later)
            reports.append(
                f"raise {later_id} x{factor:.3f} vs {earlier_id} "
                f"(opl {have:.1f}->{full_opl(later):.1f}, need {need:.1f})"
            )
            changed = True
        if not changed:
            break
    return reports


def sync_curated(changed_ids: set[str]) -> list[str]:
    if not CURATED_ROOT.is_dir():
        return []
    synced = []
    for bid in sorted(changed_ids):
        src = ROOT / f"{bid}.tres"
        dst = CURATED_ROOT / f"{bid}.tres"
        if src.is_file() and dst.is_file():
            shutil.copy2(src, dst)
            synced.append(bid)
    return synced


def capture_bare_targets(buildings: dict[str, dict]) -> dict[str, int]:
    """Pre-soft bare targets: for empty-input buildings, old main output."""
    targets: dict[str, int] = {}
    for bid, f in buildings.items():
        goods = f.get("input_good_ids") or []
        if goods:
            continue
        if should_skip_new_tools(f):
            continue
        out = main_output(f)
        if out > 0:
            targets[bid] = out
    return targets


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--tools-only",
        action="store_true",
        default=True,
        help="Do not add fertilizer soft slots (default true).",
    )
    parser.add_argument(
        "--with-fertilizer",
        action="store_true",
        help="Also add fertilizer soft slots where authored rules match.",
    )
    parser.add_argument(
        "--skip-rebalance",
        action="store_true",
        help="Only add soft tool slots; do not retune yields.",
    )
    parser.add_argument(
        "--skip-curated-sync",
        action="store_true",
        help="Do not copy changed live profiles into codegen curated mirrors.",
    )
    args = parser.parse_args()
    tools_only = not args.with_fertilizer

    if not ROOT.is_dir():
        raise SystemExit(f"missing building dir: {ROOT}")

    before = load_all()
    bare_targets = capture_bare_targets(before)

    reports = [patch_file(path, tools_only=tools_only) for path in sorted(ROOT.glob("*.tres"))]
    added = [r for r in reports if "add_tools" in r or "append_tools" in r]
    fert = [r for r in reports if "add_fert" in r]
    other = [
        r
        for r in reports
        if r.split(": ", 1)[-1] not in ("noop",) and r not in added and r not in fert
    ]
    print(
        f"patched {len(reports)} buildings; added/append tools {len(added)}; "
        f"added fertilizer {len(fert)}; other {len(other)}"
    )
    for row in added + fert + other:
        if not row.endswith(": noop"):
            print(" ", row)

    changed_ids = {
        r.split(":", 1)[0]
        for r in reports
        if not r.endswith(": noop") and not r.startswith("skip ")
    }

    if not args.skip_rebalance:
        after = load_all()
        bal_reports = rebalance_yields(after, bare_targets=bare_targets)
        print(f"rebalance adjustments: {len(bal_reports)}")
        for row in bal_reports:
            print(" ", row)
            bid = row.split(" ", 2)[1]
            # raise X / lower X / raise_starter_bare X
            if bid:
                changed_ids.add(bid)

    if not args.skip_curated_sync:
        synced = sync_curated(changed_ids)
        print(f"synced curated: {len(synced)}")
        for bid in synced:
            print(" ", bid)


if __name__ == "__main__":
    main()
