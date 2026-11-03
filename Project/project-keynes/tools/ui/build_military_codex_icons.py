"""Build the dedicated Project.Keynes military codex icon atlas.

The four source sheets are original hand-drawn military vignettes generated for
this project. They borrow only the material language of the supplied ToyEmpires
reference: waxy colored-pencil grain, wobbling graphite contours, muted earthy
colors, and a rough off-white scissor-cut paper border.

Inputs : assets/military/codex/source/*.png
Outputs: assets/military/codex/military_codex_atlas_v1.png
         assets/military/codex/regions.json
         assets/military/codex/<key>.tres
         assets/military/codex/README.md

Usage:
    python tools/ui/build_military_codex_icons.py
    python tools/ui/build_military_codex_icons.py --check
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets" / "military" / "codex" / "source"
OUT = ROOT / "assets" / "military" / "codex"
ATLAS_NAME = "military_codex_atlas_v1"

CELL = 256
CONTENT = 232
ATLAS_COLS = 8
ALPHA_CUTOFF = 24
COMPONENT_MIN_AREA = 20
CROP_PAD = 5
MAX_MARKER_EROSION = 48


UNITS = [
    "unit.militia",
    "unit.tribal",
    "unit.spearmen",
    "unit.legionary",
    "unit.archer",
    "unit.cavalry",
    "unit.chariot",
    "unit.musketeer",
    "unit.line_infantry",
    "unit.rifleman",
    "unit.machine_gunner",
    "unit.field_artillery",
    "unit.siege_train",
    "unit.early_tank",
    "unit.tank",
    "unit.drone",
]

GOODS = [
    "good.melee_arms",
    "good.missile_arms",
    "good.firearms",
    "good.ordnance",
    "good.body_armor",
    "good.mounts",
    "good.armored_vehicles",
    "good.drones",
    "good.ammunition",
    "good.propellant",
    "good.fuel",
    "good.electronics",
    "supply.ration",
    "supply.fodder",
    "supply.equipment",
    "ledger.convoy",
]

BUILDINGS = [
    "building.tribal_lodge",
    "building.palisade_barracks",
    "building.legion_fort",
    "building.modern_base",
    "building.rampart",
    "building.stone_wall",
    "building.star_fort",
    "building.bunker",
    "building.academy",
    "building.simulation_center",
    "building.depot",
    "building.training_ground",
]

STATUS = [
    "army.morale",
    "army.organization",
    "army.pay",
    "army.supply",
    "army.attack",
    "army.defense",
    "war.front",
    "war.battle",
    "war.score",
    "war.peace",
    "war.truce",
    "ledger.secure_convoy",
]

SHEETS = [
    {
        "id": "units",
        "source": "units_sheet_v1.png",
        "columns": 4,
        "rows": 4,
        "keys": UNITS,
        "audience": "兵种",
    },
    {
        "id": "goods",
        "source": "goods_sheet_v1.png",
        "columns": 4,
        "rows": 4,
        "keys": GOODS,
        "audience": "军需物资与装备",
    },
    {
        "id": "buildings",
        "source": "buildings_sheet_v1.png",
        "columns": 4,
        "rows": 3,
        "keys": BUILDINGS,
        "audience": "军事建筑",
    },
    {
        "id": "status",
        "source": "status_sheet_v1.png",
        "columns": 4,
        "rows": 3,
        "keys": STATUS,
        "audience": "军队状态与战争外交",
    },
]


def _semantic(key: str) -> str:
    return f"military.{key}"


def _expected_centers(width: int, height: int,
        columns: int, rows: int) -> list[tuple[float, float]]:
    return [
        (width * (column + 0.5) / columns, height * (row + 0.5) / rows)
        for row in range(rows)
        for column in range(columns)
    ]


def _nearest_expected_cell(x: float, y: float,
        centers: list[tuple[float, float]]) -> int:
    return min(
        range(len(centers)),
        key=lambda index: (centers[index][0] - x) ** 2
        + (centers[index][1] - y) ** 2,
    )


def _marker_labels_for_cells(mask: np.ndarray, columns: int, rows: int
        ) -> tuple[np.ndarray, list[list[int]], int]:
    """Find one thick core per illustrated cell.

    The generated sheets arrange icons on a loose grid; their weapons, smoke,
    roofs and flags regularly cross equal-cell boundaries. Progressive erosion
    separates touching paper outlines while retaining a reliable marker for
    every intended cell.
    """
    height, width = mask.shape
    centers = _expected_centers(width, height, columns, rows)
    structure = np.ones((3, 3), dtype=bool)
    for erosion in range(0, MAX_MARKER_EROSION + 1):
        core = mask if erosion == 0 else ndimage.binary_erosion(
            mask, structure=structure, iterations=erosion)
        labels, count = ndimage.label(core, structure=structure.astype(np.uint8))
        if count == 0:
            continue
        sizes = np.bincount(labels.ravel())
        centers_of_mass = ndimage.center_of_mass(
            core, labels, range(1, count + 1))
        by_cell: list[list[int]] = [[] for _ in centers]
        for label, (center_y, center_x) in enumerate(centers_of_mass, start=1):
            if int(sizes[label]) < COMPONENT_MIN_AREA:
                continue
            cell = _nearest_expected_cell(
                float(center_x), float(center_y), centers)
            by_cell[cell].append(label)
        if all(by_cell):
            return labels, by_cell, erosion
    raise SystemExit("could not resolve a content marker for every source cell")


def _assign_cell_pixels(mask: np.ndarray, columns: int, rows: int
        ) -> tuple[np.ndarray, int]:
    """Partition the full sheet without clipping artwork at grid boundaries."""
    height, width = mask.shape
    centers = _expected_centers(width, height, columns, rows)
    marker_labels, by_cell, erosion = _marker_labels_for_cells(
        mask, columns, rows)
    marker_to_cell: dict[int, int] = {}
    for cell, labels in enumerate(by_cell):
        for label in labels:
            marker_to_cell[label] = cell

    component_labels, count = ndimage.label(
        mask, structure=np.ones((3, 3), dtype=np.uint8))
    sizes = np.bincount(component_labels.ravel())
    component_slices = ndimage.find_objects(component_labels)
    owner = np.zeros(mask.shape, dtype=np.int32)
    neighbors = (
        (-1, -1), (-1, 0), (-1, 1),
        (0, -1), (0, 1),
        (1, -1), (1, 0), (1, 1),
    )

    for component_id in range(1, count + 1):
        if int(sizes[component_id]) < COMPONENT_MIN_AREA:
            continue
        component_slice = component_slices[component_id - 1]
        if component_slice is None:
            continue
        local_component = component_labels[component_slice] == component_id
        local_markers = marker_labels[component_slice]
        marker_ids = np.unique(
            local_markers[local_component & (local_markers > 0)])
        cells = sorted({
            marker_to_cell[int(marker)]
            for marker in marker_ids
            if int(marker) in marker_to_cell
        })
        local_owner = np.zeros(local_component.shape, dtype=np.int32)

        if not cells:
            center_y, center_x = ndimage.center_of_mass(local_component)
            cell = _nearest_expected_cell(
                float(center_x) + component_slice[1].start,
                float(center_y) + component_slice[0].start,
                centers,
            )
            local_owner[local_component] = cell + 1
        elif len(cells) == 1:
            local_owner[local_component] = cells[0] + 1
        else:
            # A loose paper border can join adjacent icons. Geodesic growth
            # from their eroded cores cuts only the narrow bridge, keeping
            # protruding barrels, limbs and roofs attached to the right icon.
            queue: deque[tuple[int, int]] = deque()
            seed_y, seed_x = np.nonzero(
                local_component & (local_markers > 0))
            for y, x in zip(seed_y, seed_x):
                marker = int(local_markers[y, x])
                cell = marker_to_cell.get(marker)
                if cell is None or local_owner[y, x] != 0:
                    continue
                local_owner[y, x] = cell + 1
                queue.append((int(y), int(x)))
            while queue:
                y, x = queue.popleft()
                cell_id = int(local_owner[y, x])
                for delta_y, delta_x in neighbors:
                    next_y = y + delta_y
                    next_x = x + delta_x
                    if next_y < 0 or next_x < 0:
                        continue
                    if next_y >= local_component.shape[0] \
                            or next_x >= local_component.shape[1]:
                        continue
                    if not local_component[next_y, next_x] \
                            or local_owner[next_y, next_x] != 0:
                        continue
                    local_owner[next_y, next_x] = cell_id
                    queue.append((next_y, next_x))
            for y, x in zip(*np.nonzero(local_component)):
                if local_owner[y, x] != 0:
                    continue
                global_y = int(y) + component_slice[0].start
                global_x = int(x) + component_slice[1].start
                local_owner[y, x] = _nearest_expected_cell(
                    global_x, global_y, centers) + 1

        owner[component_slice][local_component] = local_owner[local_component]

    return owner, erosion


def _crop_assigned_cell(pixels: np.ndarray, owner: np.ndarray,
        cell_index: int) -> Image.Image:
    assigned = owner == cell_index + 1
    ys, xs = np.nonzero(assigned)
    if xs.size == 0:
        raise SystemExit(f"source cell {cell_index} has no assigned artwork")
    left = max(0, int(xs.min()) - CROP_PAD)
    top = max(0, int(ys.min()) - CROP_PAD)
    right = min(pixels.shape[1], int(xs.max()) + 1 + CROP_PAD)
    bottom = min(pixels.shape[0], int(ys.max()) + 1 + CROP_PAD)
    crop = pixels[top:bottom, left:right].copy()
    keep = assigned[top:bottom, left:right]
    crop[~keep] = 0
    return Image.fromarray(crop, "RGBA")


def _extract_cell_stickers(sheet: Image.Image, columns: int,
        rows: int) -> list[Image.Image]:
    pixels = np.array(sheet.convert("RGBA"))
    mask = pixels[:, :, 3] > ALPHA_CUTOFF
    owner, _erosion = _assign_cell_pixels(mask, columns, rows)
    return [
        _normalise_sticker(_crop_assigned_cell(pixels, owner, index))
        for index in range(columns * rows)
    ]


def _normalise_sticker(sticker: Image.Image) -> Image.Image:
    scale = min(CONTENT / sticker.width, CONTENT / sticker.height)
    size = (
        max(1, int(round(sticker.width * scale))),
        max(1, int(round(sticker.height * scale))),
    )
    art = sticker.resize(size, Image.Resampling.LANCZOS)
    cell = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    cell.alpha_composite(art, ((CELL - size[0]) // 2, (CELL - size[1]) // 2))
    return cell


def build() -> dict[str, list[int]]:
    OUT.mkdir(parents=True, exist_ok=True)
    extracted: list[tuple[str, Image.Image]] = []
    for spec in SHEETS:
        keys: list[str] = spec["keys"]
        if len(keys) != int(spec["columns"]) * int(spec["rows"]):
            raise SystemExit(f"{spec['id']}: key count does not fill its grid")
        path = SOURCE / str(spec["source"])
        if not path.exists():
            raise SystemExit(f"missing source sheet: {path}")
        sheet = Image.open(path).convert("RGBA")
        artworks = _extract_cell_stickers(
            sheet, int(spec["columns"]), int(spec["rows"]))
        extracted.extend(
            (_semantic(key), artwork) for key, artwork in zip(keys, artworks))

    entries = [(key, art) for key, art in extracted]
    rows = (len(entries) + ATLAS_COLS - 1) // ATLAS_COLS
    atlas = Image.new("RGBA", (ATLAS_COLS * CELL, rows * CELL), (0, 0, 0, 0))
    regions: dict[str, list[int]] = {}
    for index, (key, art) in enumerate(entries):
        x = (index % ATLAS_COLS) * CELL
        y = (index // ATLAS_COLS) * CELL
        atlas.alpha_composite(art, (x, y))
        regions[key] = [x, y, CELL, CELL]

    atlas.save(OUT / f"{ATLAS_NAME}.png")
    (OUT / "regions.json").write_text(
        json.dumps(regions, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    _write_tres(regions)
    _write_import()
    _write_readme(regions)
    _write_source_manifest()

    for preview_index, spec in enumerate(SHEETS):
        keys = [_semantic(key) for key in spec["keys"]]
        cols = int(spec["columns"])
        rows_in_sheet = int(spec["rows"])
        preview = Image.new("RGBA", (cols * CELL, rows_in_sheet * CELL),
            (31, 28, 24, 255))
        offset = sum(len(item["keys"]) for item in SHEETS[:preview_index])
        for index, key in enumerate(keys):
            art = extracted[offset + index][1]
            preview.alpha_composite(art, ((index % cols) * CELL,
                (index // cols) * CELL))
        preview.save(OUT / f"preview_{spec['id']}.png")
    return regions


def _write_tres(regions: dict[str, list[int]]) -> None:
    for key, (x, y, width, height) in sorted(regions.items()):
        safe = key.replace(".", "_")
        path = OUT / f"{safe}.tres"
        path.write_text(
            "[gd_resource type=\"AtlasTexture\" load_steps=2 format=3]\n\n"
            "[ext_resource type=\"Texture2D\" "
            f"path=\"res://assets/military/codex/{ATLAS_NAME}.png\" id=\"1\"]\n\n"
            "[resource]\n"
            "atlas = ExtResource(\"1\")\n"
            f"region = Rect2({x}, {y}, {width}, {height})\n"
            "filter_clip = true\n",
            encoding="utf-8")


def _write_import() -> None:
    template = ROOT / "assets" / "icons" / "paper" / "ui_states_01.png.import"
    if template.exists():
        lines = template.read_text(encoding="utf-8").splitlines()
        rebuilt: list[str] = []
        for line in lines:
            if line.startswith(("uid=", "path=\"res://.godot/imported/", "dest_files=")):
                continue
            rebuilt.append(line)
        text = "\n".join(rebuilt) + "\n"
        text = text.replace(
            "source_file=\"res://assets/icons/paper/ui_states_01.png\"",
            f"source_file=\"res://assets/military/codex/{ATLAS_NAME}.png\"")
        if "source_file=" not in text:
            text = text.replace(
                "[deps]\n",
                f"[deps]\n\nsource_file=\"res://assets/military/codex/{ATLAS_NAME}.png\"\n")
    else:
        text = (
            "[remap]\n\n"
            "importer=\"texture\"\n"
            "type=\"CompressedTexture2D\"\n\n"
            "[deps]\n\n"
            f"source_file=\"res://assets/military/codex/{ATLAS_NAME}.png\"\n"
        )
    (OUT / f"{ATLAS_NAME}.png.import").write_text(text, encoding="utf-8")


def _write_readme(regions: dict[str, list[int]]) -> None:
    lines = [
        "# Military codex sticker atlas v1",
        "",
        "Original AI-generated hand-drawn military vignettes created for",
        "Project.Keynes on 2026-11-02. The supplied ToyEmpires unit images were",
        "used only as a style reference for waxy colored-pencil grain, wobbling",
        "graphite contours, muted earthy colors and rough white scissor-cut paper",
        "borders. No reference character, costume, pose or composition was copied.",
        "",
        f"`{ATLAS_NAME}.png` is a lossless RGBA atlas with {ATLAS_COLS} columns",
        f"of {CELL}px cells. Each cell keeps a transparent gutter and a normalised",
        f"{CONTENT}px artwork envelope so table icons and dossier headers share",
        "the same optical weight.",
        "",
        "The source sheets use a loose illustrated grid. The builder segments",
        "each sheet from eroded icon cores and assigns complete connected",
        "artwork back to its cell, so protruding weapons, smoke, roofs and",
        "flags are not clipped by equal-grid slicing.",
        "",
        "Source sheets live in `source/`; rebuild with:",
        "",
        "```powershell",
        "python tools/ui/build_military_codex_icons.py",
        "```",
        "",
        "| semantic | cell (x, y, w, h) |",
        "| --- | --- |",
    ]
    for key in sorted(regions):
        x, y, width, height = regions[key]
        lines.append(f"| `{key}` | {x}, {y}, {width}, {height} |")
    (OUT / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_source_manifest() -> None:
    manifest = {
        "generated_on": "2026-11-02",
        "style_reference": [
            "E:/下载/TE/ToyEmpires-main/Assets/Resources/Sprites/Units/示例/"
            "001_2001_0.png",
            "E:/下载/TE/ToyEmpires-main/Assets/Resources/Sprites/Units/示例/"
            "000_5002_0.png",
        ],
        "source_sheets": {
            str(spec["source"]): {
                "audience": spec["audience"],
                "columns": spec["columns"],
                "rows": spec["rows"],
                "semantics": [_semantic(key) for key in spec["keys"]],
            }
            for spec in SHEETS
        },
    }
    (SOURCE / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")


def check() -> int:
    atlas_path = OUT / f"{ATLAS_NAME}.png"
    regions_path = OUT / "regions.json"
    if not atlas_path.exists() or not regions_path.exists():
        print("missing military codex atlas or regions.json")
        return 1
    atlas = Image.open(atlas_path).convert("RGBA")
    regions = json.loads(regions_path.read_text(encoding="utf-8"))
    expected = sum(len(spec["keys"]) for spec in SHEETS)
    if len(regions) != expected:
        print(f"region count {len(regions)} != {expected}")
        return 1
    for key, (x, y, width, height) in regions.items():
        if width != CELL or height != CELL:
            print(f"{key}: unexpected cell size")
            return 1
        if x < 0 or y < 0 or x + width > atlas.width or y + height > atlas.height:
            print(f"{key}: region outside atlas")
            return 1
        pixels = atlas.crop((x, y, x + width, y + height))
        if pixels.getchannel("A").getextrema()[1] == 0:
            print(f"{key}: empty alpha cell")
            return 1
        art_box = pixels.getbbox()
        if art_box is None:
            print(f"{key}: empty artwork bounds")
            return 1
        if art_box[0] < 8 or art_box[1] < 8 \
                or art_box[2] > width - 8 or art_box[3] > height - 8:
            print(f"{key}: artwork enters the cell safety margin")
            return 1
    print(f"ok {atlas_path.name} {atlas.width}x{atlas.height} "
          f"regions={len(regions)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        return check()
    regions = build()
    print(f"wrote {len(regions)} military codex stickers to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
