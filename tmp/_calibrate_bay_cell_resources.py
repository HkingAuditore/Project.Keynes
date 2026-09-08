"""Bay-cell resource calibration for early-building target N=5000.

Units:
  map_reserve = authored * CELL_AREA_RESOURCE_SCALE (100)
  goods_amount = map_reserve * GOODS_SCALE (1000)
  ecology_capacity_goods = ecology_capacity * 100 * 1000

Formulas:
  ecology_capacity = round(4 * N * q / (r * 100000))
  agri/mineral floors use goods-comparable init_min:
    capacity buildings at full util: N ~= init_min * 100000 / q
    mineral 10y horizon: init_min = N * q * 3650 / 100000
"""
from __future__ import annotations

from pathlib import Path
import re
import shutil

ROOT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes")
AUTH = ROOT / "Project/project-keynes/data/resources"
CODE = ROOT / "tools/codegen/economy_content/resources"

N = 5000
SCALE = 100.0 * 1000.0  # CELL_AREA * GOODS


def eco_cap(q: float, r: float) -> int:
    return int(round(4 * N * q / (r * SCALE)))


def mineral_floor(q: float) -> int:
    return int(round(N * q * 3650 / SCALE))


FLOAT_ASSIGN = re.compile(
    r"^(\s*)([A-Za-z0-9_]+)(\s*=\s*)(-?\d+(?:\.\d+)?)(\s*)$", re.M
)
DICT_NUM = re.compile(r"(\d+\s*:\s*)(-?\d+(?:\.\d+)?)")

SCALE_KEYS = {
    "init_base",
    "init_temp",
    "init_moisture",
    "init_elevation",
    "init_river",
    "init_volcano",
    "init_ocean_current",
    "init_upwelling",
    "init_estuary",
    "init_climate_fit",
    "init_noise",
    "init_province",
    "init_belt",
    "init_target_reserve_density",
    "init_target_mean_reserve",
    "init_micro_min_reserve",
    "init_floor_reserve",
}


def _lit(value: float, force_float: bool = True) -> str:
    if abs(value - round(value)) < 1e-9:
        iv = int(round(value))
        return f"{iv}.0" if force_float else str(iv)
    return f"{value:.6g}"


def set_or_replace(text: str, key: str, value: float, force_float: bool = True) -> str:
    lit = _lit(float(value), force_float=force_float)
    pat = re.compile(rf"^(\s*{re.escape(key)}\s*=\s*)(-?\d+(?:\.\d+)?)(\s*)$", re.M)
    if pat.search(text):
        return pat.sub(rf"\g<1>{lit}\g<3>", text, count=1)
    insert = f"{key} = {lit}\n"
    if "ecology_capacity" in text:
        return text.replace("ecology_capacity", insert + "ecology_capacity", 1)
    if not text.endswith("\n"):
        text += "\n"
    return text + insert


def scale_init_fields(text: str, factor: float) -> str:
    if abs(factor - 1.0) < 1e-9:
        return text

    def repl_assign(m: re.Match[str]) -> str:
        indent, key, eq, num, sp = m.groups()
        if key not in SCALE_KEYS:
            return m.group(0)
        v = float(num) * factor
        lit = _lit(v, force_float=("." in num))
        return f"{indent}{key}{eq}{lit}{sp}"

    text = FLOAT_ASSIGN.sub(repl_assign, text)

    def scale_dict_block(name: str, s: str) -> str:
        pat = re.compile(rf"({name}\s*=\s*\{{)(.*?)(\}})", re.S)

        def blk(m: re.Match[str]) -> str:
            body = DICT_NUM.sub(
                lambda mm: mm.group(1)
                + _lit(float(mm.group(2)) * factor, force_float=("." in mm.group(2))),
                m.group(2),
            )
            return m.group(1) + body + m.group(3)

        return pat.sub(blk, s)

    text = scale_dict_block("init_landform_weights", text)
    text = scale_dict_block("init_vegetation_weights", text)
    return text


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def write(p: Path, t: str) -> None:
    p.write_text(t, encoding="utf-8", newline="\n")
    print("updated", p.relative_to(ROOT).as_posix())


def main() -> None:
    # A. extract ecology
    p = AUTH / "wild_game.tres"
    t = read(p)
    old_cap = 1200.0
    new_cap = float(eco_cap(163, 0.01))
    t = set_or_replace(t, "ecology_capacity", new_cap)
    t = set_or_replace(t, "ecology_growth_rate", 0.01)
    t = set_or_replace(t, "ecology_immigration", round(0.01 * new_cap / old_cap, 4))
    t = re.sub(
        r"# 旧值 0\.001495.*\n(# .*\n)?",
        "# Bay-cell early-building target N=5000 (goods units).\n"
        "# ecology_capacity = 4*N*q/(r*CELL_AREA*GOODS_SCALE); MSY camps ~= N.\n",
        t,
    )
    t = scale_init_fields(t, new_cap / old_cap)
    write(p, t)

    p = AUTH / "freshwater_fish.tres"
    t = read(p)
    t = set_or_replace(t, "ecology_growth_rate", 0.012)
    write(p, t)

    p = AUTH / "marine_fish.tres"
    t = read(p)
    t = set_or_replace(t, "ecology_growth_rate", 0.01)
    write(p, t)

    p = AUTH / "timber.tres"
    t = read(p)
    t = set_or_replace(t, "ecology_growth_rate", 0.01)
    write(p, t)

    # B. agriculture
    p = AUTH / "fertile_soil.tres"
    t = read(p)
    t = set_or_replace(t, "gen_self", 8.0)
    write(p, t)

    agri = {
        "pasture": dict(
            gen_self=2.5,
            decay_self=0.002,
            decay_stress=0.4,
            runtime_climate_fit_weight=0.55,
            gen_moisture=0.35,
        ),
        "arable_land": dict(
            gen_self=2.0,
            decay_self=0.002,
            decay_stress=0.45,
            runtime_climate_fit_weight=0.6,
            gen_moisture=0.4,
        ),
        "paddy_land": dict(
            gen_self=2.0,
            decay_self=0.002,
            decay_stress=0.4,
            runtime_climate_fit_weight=0.6,
            gen_moisture=0.5,
        ),
        "plantation_land": dict(
            gen_self=2.2,
            decay_self=0.002,
            decay_stress=0.45,
            runtime_climate_fit_weight=0.6,
            gen_moisture=0.45,
        ),
    }
    for rid, knobs in agri.items():
        p = AUTH / f"{rid}.tres"
        t = read(p)
        for k, v in knobs.items():
            t = set_or_replace(t, k, float(v))
        if "runtime_temperature_signal" not in t:
            t = t.replace(
                "temp_lo",
                'runtime_temperature_signal = "mean_30d"\n'
                'runtime_moisture_signal = "plant_available_water"\n'
                "temp_lo",
                1,
            )
        write(p, t)

    # C. minerals
    minerals = {
        "gold_ore": 50,
        "silver_ore": 200,
        "iron_ore": 2254,
        "copper_ore": 1435,
        "tin_ore": 13586,
        "lead_ore": 12061,
        "zinc_ore": 12061,
        "coal": 18038,
        "oil": 13287,
        "natural_gas": 10950,
        "stone": 858,
        "flint": 441,
        "silica_sand": 13650,
        "limestone": 5739,
        "clay": 12776,
        "salt": 3106,
        "saltpeter": 5197,
        "sulfur": 5197,
        "phosphate_rock": 12061,
        "bauxite": 13287,
        "manganese_ore": 13684,
        "rare_earth": 10944,
    }
    gen_boost = {"clay": 4.0, "salt": 4.0, "saltpeter": 4.0}

    for rid, q in minerals.items():
        p = AUTH / f"{rid}.tres"
        t = read(p)
        m = re.search(r"init_min_reserve\s*=\s*(-?\d+(?:\.\d+)?)", t)
        old = float(m.group(1)) if m else 0.0
        target = float(mineral_floor(q))
        new = max(old, target)
        factor = new / old if old > 0 else 1.0
        t = set_or_replace(t, "init_min_reserve", new)
        if factor > 1.0 + 1e-9:
            t = scale_init_fields(t, factor)
        if rid in gen_boost:
            gm = re.search(r"gen_self\s*=\s*(-?\d+(?:\.\d+)?)", t)
            if gm:
                t = set_or_replace(t, "gen_self", float(gm.group(1)) * gen_boost[rid])
        write(p, t)

    synced = 0
    for src in AUTH.glob("*.tres"):
        dst = CODE / src.name
        if dst.exists():
            shutil.copy2(src, dst)
            synced += 1
            print("synced codegen", src.name)
    print(f"DONE synced={synced} wild_cap={eco_cap(163, 0.01)}")


if __name__ == "__main__":
    main()
