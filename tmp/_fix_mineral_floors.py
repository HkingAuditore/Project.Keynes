"""Re-apply mineral floors without scaling suit coefficients (float32-safe)."""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes")
AUTH = ROOT / "Project/project-keynes/data/resources"
CODE = ROOT / "tools/codegen/economy_content/resources"

N = 5000
SCALE = 100000.0


def mineral_floor(q: float) -> int:
    return int(round(N * q * 3650 / SCALE))


def set_or_replace(text: str, key: str, value: float) -> str:
    lit = f"{int(round(value))}.0" if abs(value - round(value)) < 1e-9 else f"{value:.6g}"
    pat = re.compile(rf"^(\s*{re.escape(key)}\s*=\s*)(-?\d+(?:\.\d+)?)(\s*)$", re.M)
    if pat.search(text):
        return pat.sub(rf"\g<1>{lit}\g<3>", text, count=1)
    if not text.endswith("\n"):
        text += "\n"
    return text + f"{key} = {lit}\n"


def bump_related_floors(text: str, factor: float) -> str:
    """Scale deposit-target floors that exist, not suit scores."""
    keys = (
        "init_target_reserve_density",
        "init_target_mean_reserve",
        "init_micro_min_reserve",
        "init_floor_reserve",
    )
    for key in keys:
        m = re.search(rf"^(\s*{key}\s*=\s*)(-?\d+(?:\.\d+)?)(\s*)$", text, re.M)
        if not m:
            continue
        new_v = float(m.group(2)) * factor
        text = set_or_replace(text, key, new_v)
    return text


MINERALS = {
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
GEN_BOOST = {"clay": 4.0, "salt": 4.0, "saltpeter": 4.0}

# Restore minerals from HEAD then patch floors only.
rel_paths = [f"Project/project-keynes/data/resources/{rid}.tres" for rid in MINERALS]
# also restore codegen mineral mirrors
for rid in MINERALS:
    cg = CODE / f"{rid}.tres"
    if cg.exists():
        rel_paths.append(f"tools/codegen/economy_content/resources/{rid}.tres")

subprocess.run(
    ["git", "checkout", "HEAD", "--", *rel_paths],
    cwd=ROOT,
    check=True,
)

for rid, q in MINERALS.items():
    p = AUTH / f"{rid}.tres"
    text = p.read_text(encoding="utf-8")
    m = re.search(r"init_min_reserve\s*=\s*(-?\d+(?:\.\d+)?)", text)
    old = float(m.group(1)) if m else 0.0
    target = float(mineral_floor(q))
    new = max(old, target)
    factor = new / old if old > 0 else 1.0
    text = set_or_replace(text, "init_min_reserve", new)
    if factor > 1.0 + 1e-9:
        text = bump_related_floors(text, factor)
    if rid in GEN_BOOST:
        gm = re.search(r"gen_self\s*=\s*(-?\d+(?:\.\d+)?)", text)
        if gm:
            text = set_or_replace(text, "gen_self", float(gm.group(1)) * GEN_BOOST[rid])
    p.write_text(text, encoding="utf-8", newline="\n")
    print(f"{rid}: init_min {old} -> {new} (x{factor:.3g})")
    dst = CODE / f"{rid}.tres"
    if dst.exists():
        shutil.copy2(p, dst)
        print("  synced codegen")

print("DONE mineral floor re-apply")
