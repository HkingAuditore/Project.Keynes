"""Cross-check the shipped family catalog against the design table copy."""
from __future__ import annotations

import json
import re
from pathlib import Path

Q16 = 65536
ROOT = Path(".")
MD = ROOT / "Project/project-keynes/data/economy/family_official_buffs.md"
JSON = ROOT / "Project/project-keynes/data/economy/family_official_buffs.json"
TRES = ROOT / "Project/project-keynes/data/modifiers/default_modifier_catalog.tres"

DEF_OF = {
    "birth_plenty": "family.city.birth_boost",
    "birth_decline": "family.city.birth_cut",
    "production_boost": "family.city.production_boost_high",
    "hedonism": "family.city.hedonism",
    "afforestation": "family.city.timber_regen_boost",
    "corn_expert": "family.city.good.corn_grain.output",
    "hardship": "family.city.austere_consumption",
    "rain_farming": "family.city.agriculture_output_boost",
    "heat_stress": "family.city.birth_boost",
    "valley_farm": "family.city.agriculture_output_boost",
    "tide_living": "family.city.good.fish.output",
    "mountain_vein": "family.city.extractive_output_boost",
    "drought_stores": "family.city.staple_consumption_cut",
    "industry_cluster": "family.city.manufacturing_output_boost_high",
    "thrift_output": "family.city.manufacturing_output_boost_high",
    "market_boom": "family.city.trade_output_boost",
    "ancestral_precept": "family.city.production_boost_high",
    "knowledge_spread": "family.city.knowledge_output_boost",
    "shared_water": "family.city.agriculture_output_boost",
    "branch_network": "family.city.trade_output_boost",
    "overfish": "family.city.extractive_output_boost",
    "many_trades": "family.city.production_boost_high",
    "city_chain": "family.city.chain_output_boost",
    "trade_nation": "family.country.trade_capacity",
    "many_resources": "family.city.chain_output_boost",
    "century_shop": "family.city.owned_building_output",
}
ABS_OF = {
    "rain_prayer": "pct",
    "cold_resist": "pct",
    "expansionism": "count",
    "work_relief": "pct",
    "city_founder": "count",
    "one_industry_city": "pct",
    "branching_households": "pct",
    "market_bully": "pct",
    "retain_lineage": "pct",
    "specialized_industry": "pct",
    "versatile_crafts": "pct",
    "complete_chain": "pct",
    "local_monopoly": "pct",
    "remote_kin": "pct",
    "family_learning": "pct",
    "new_nobility": "count",
    "wealthy_few_heirs": "pct",
}
SKIP = {"trade_zealot", "lucky_pair", "split_dowry", "break_with_past", "absorb_all"}


def cells(line: str) -> list[str]:
    s = line.strip()
    if not s.startswith("|"):
        return []
    parts = [p.strip() for p in s.strip("|").split("|")]
    if not parts or all(set(p) <= {"-", ":"} for p in parts):
        return []
    return parts


def load_defs() -> dict[str, list[tuple[str, int, float]]]:
    text = TRES.read_text(encoding="utf-8")
    blocks = re.split(r"\n(?=\[sub_resource type=)", text)
    terms: dict[str, tuple[str, int, float]] = {}
    raw: dict[str, list[str]] = {}
    for block in blocks:
        m = re.match(r'\[sub_resource type="Resource" id="([^"]+)"\]', block)
        if not m:
            continue
        bid = m.group(1)
        stat = re.search(r'stat_key = &"([^"]+)"', block)
        if stat:
            op = re.search(r"\noperation = (\d+)", block)
            val = re.search(r"\nvalue = ([0-9.]+)", block)
            terms[bid] = (stat.group(1), int(op.group(1)) if op else 0,
                          float(val.group(1)) if val else 0.0)
        key = re.search(r'\nkey = &"([^"]+)"', block)
        if key:
            listing = re.search(r"terms = Array\[Resource\]\(\[(.*?)\]\)", block, re.S)
            raw[key.group(1)] = re.findall(r'SubResource\("([^"]+)"\)',
                                           listing.group(1)) if listing else []
    return {k: [terms[i] for i in v if i in terms] for k, v in raw.items()}


def md_rows() -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    rows = {}
    result_cells = {}
    for line in MD.read_text(encoding="utf-8").splitlines():
        c = cells(line)
        if len(c) >= 10 and re.fullmatch(r"E\d{3}", c[0]):
            rows[c[1]] = [s.strip() for s in c[9].replace("<br>", "\n").split("\n")
                          if s.strip()]
            result_cells[c[1]] = c[4:9]
    return rows, result_cells


def fmt(v: float) -> str:
    return f"{v:g}"


def main() -> int:
    defs = load_defs()
    buffs = json.loads(JSON.read_text(encoding="utf-8-sig"))
    rows, result_cells = md_rows()
    problems = 0
    checked = 0
    for e in buffs["effects"]:
        key = e["key"]
        name = e["display_name"]
        stmts = rows.get(name)
        if stmts is None or len(stmts) != 5:
            print("MISSING COPY", key, name)
            problems += 1
            continue
        mags = e["magnitude_by_prestige_q16"]
        # Compact result cells must keep the same number order as the full copy,
        # otherwise a tier can advertise a threshold that the statement disproves.
        cell_numbers = [[m.group(0) for m in re.finditer(r"\d+(?:\.\d+)?", cell)]
                        for cell in result_cells.get(name, [])]
        for tier, numbers in enumerate(cell_numbers):
            statement_numbers = [m.group(0) for m in
                                 re.finditer(r"\d+(?:\.\d+)?", stmts[tier])]
            cursor = 0
            for number in numbers:
                while cursor < len(statement_numbers) and statement_numbers[cursor] != number:
                    cursor += 1
                if cursor >= len(statement_numbers):
                    print("CELL/COPY DIVERGENCE", key, "tier", tier + 1, numbers,
                          "|", stmts[tier][:120])
                    problems += 1
                    break
                cursor += 1
        if len(mags) != 6 or max(mags) > 4 * Q16:
            print("MAG OVERFLOW", key, list(mags))
            problems += 1
        if key == "patronage_house":
            terms = defs.get("family.country.patronage_satisfaction", [])
            for t in range(5):
                m = mags[t + 1] / Q16
                expected = [fmt(round(value * m / 100.0, 2)) for _, _, value in terms]
                if sum(1 for x in expected if x in stmts[t]) < len(expected):
                    print("COPY MISMATCH", key, "tier", t + 1, expected, "|",
                          stmts[t][:120])
                    problems += 1
                checked += 1
        elif key in DEF_OF:
            terms = defs.get(DEF_OF[key], [])
            if not terms:
                print("NO TERM", key)
                problems += 1
                continue
            for t in range(5):
                m = mags[t + 1] / Q16
                expected = []
                for _, op, value in terms:
                    if op == 2:
                        expected.append(fmt(round(abs(value - 1.0) * m * 100, 2)))
                    elif op == 3:
                        expected.append(fmt(round(abs(1.0 - value) * m * 100, 2)))
                    else:
                        expected.append(fmt(round(value * m / 100.0, 2)))
                expected = list(dict.fromkeys(expected))
                if sum(1 for x in expected
                       if x + "%" in stmts[t] or ("降低" + x + "%") in stmts[t]) < len(expected):
                    print("COPY MISMATCH", key, "tier", t + 1, expected, "|",
                          stmts[t][:140])
                    problems += 1
                checked += 1
        elif key in ABS_OF:
            kind = ABS_OF[key]
            for t in range(5):
                m = mags[t + 1] / Q16
                want = fmt(round(m * 100, 2)) + "%" if kind == "pct" else fmt(mags[t + 1])
                if want not in stmts[t]:
                    print("ABS MISMATCH", key, "tier", t + 1, want, "|", stmts[t][:140])
                    problems += 1
                checked += 1
        elif key not in SKIP:
            print("NO CHECK RULE", key, name)
    print(f"checked {checked} tier rows, problems {problems}")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
