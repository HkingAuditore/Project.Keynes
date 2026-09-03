#!/usr/bin/env python3
from pathlib import Path
import re

root = Path("Project/project-keynes/data/economy/buildings")


def show(bid: str) -> None:
    t = (root / f"{bid}.tres").read_text(encoding="utf-8")

    def arr(k: str) -> str:
        m = re.search(rf"^{k} = Packed\w+Array\((.*)\)\s*$", t, re.M)
        return m.group(1) if m else ""

    def num(k: str, default: int = 1) -> int:
        m = re.search(rf"^{k} = (-?\d+)\s*$", t, re.M)
        return int(m.group(1)) if m else default

    goods = re.findall(r'"([^"]+)"', arr("input_good_ids"))
    out_raw = arr("output_quantities_per_day")
    outs = [int(x) for x in out_raw.split(",") if x.strip()] if out_raw else []
    req_raw = arr("input_required_q16")
    req = [int(x) for x in req_raw.split(",") if x.strip()] if req_raw else []
    owner = num("owner_slots_per_building", 1)
    emp = [int(x) for x in re.findall(r"-?\d+", arr("employee_slots_per_building"))]
    labor = max(1, owner + sum(emp))
    opl = outs[0] / labor if outs else 0.0
    print(f"{bid}: goods={goods} req={req} out={outs[:3]} labor={labor} opl={opl:.1f}")


for bid in [
    "stone_age_hunting_camp",
    "method_stone_age_hunting_camp_r4",
    "small_game_trapline",
    "gathering_ground",
    "method_gathering_ground_r1",
    "deadwood_gathering_camp",
    "timber_collector",
    "freshwater_fishing_camp",
    "marine_fish_collector",
    "method_marine_fish_collector_r2",
    "rubble_stone_working",
    "stone_collector",
    "knapping_workshop",
    "tools_plant",
]:
    show(bid)
