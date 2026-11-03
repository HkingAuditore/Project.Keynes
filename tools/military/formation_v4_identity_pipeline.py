#!/usr/bin/env python3
"""Build canonical model-art references for v4.1 frame-consistent animation.

The image generator is unreliable when asked to invent an entire action sheet
from text alone. This helper takes one already model-generated canonical cell
per prototype, applies only deterministic raster cleanup/rotation/scaling, and
creates an eight-cell identity board plus a fixed prompt set for every action.

It never draws unit artwork. Every visible unit pixel still comes from the
image-generation model.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

from formation_v4_prompts import (
    ACTIONS,
    BEATS,
    IDENTITY,
    PROTOTYPES,
    SPECIAL_RULES,
    SUBJECT_DETAIL,
)


ROOT = Path(__file__).resolve().parents[2]
PROTOTYPE_DIR = ROOT / "Project/project-keynes/assets/military/formations/prototype"
DEFAULT_SOURCE_DIR = PROTOTYPE_DIR / "source/v4/candidates"
DEFAULT_OUTPUT_DIR = PROTOTYPE_DIR / "source/v4/identity"
DEFAULT_MASTER_OVERRIDE_DIR = DEFAULT_OUTPUT_DIR / "masters/candidates"

SOURCE_COLUMNS = 4
SOURCE_ROWS = 2
MASTER_SIZE = 512
MASTER_PADDING = 56
BOARD_SIZE = (1792, 896)
BOARD_COLUMNS = 4
BOARD_ROWS = 2
BOARD_CELL_PADDING = 62
ALPHA_FLOOR = 8

# The canonical idle cell is model-generated. These fixed raster rotations are
# required because the generator rendered these two prototypes north/south.
MASTER_ROTATION_DEGREES = {
    "foot": 0,
    "mounted": 0,
    "artillery": -90,
    "armored": 90,
}

# The original text-generated artillery master placed its crew directly in
# front of the muzzles. This curated image-to-image replacement keeps the same
# cannon identity but removes all human figures. It is already east-facing, so
# the legacy raster rotation must not be applied again.
MASTER_OVERRIDES = {
    "artillery": "artillery_master_clean_00.png",
}


SHARED_CONTRACT = """
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.
""".strip()


ACTION_DIRECTION = {
    "idle": (
        "Preserve the east-facing canonical formation while changing weight, "
        "shield angles, horse stance, wheel tremor, turret scan or antenna sway. "
        "Frame 8 is a half-breath pose near frame 1, not an identical copy."
    ),
    "move": (
        "All members travel east but remain inside their cell anchor. Show a "
        "large contact-compression-extension-contact cycle using legs, bodies, "
        "hulls, tracks, wheels and formation spacing. Do not translate the whole "
        "unit across the cell. Frame 8 closes the gait cycle near frame 1."
    ),
    "attack": (
        "The formation coils west, strikes or fires east, reaches a strong action "
        "peak, recoils, and returns to a neutral east-facing guard. No unit may "
        "spin away from east. Keep all effects inside the cell. Frame 8 is "
        "near-neutral."
    ),
    "hit": (
        "The formation takes one impact from the east: compress, buckle west, "
        "stagger with at most an 8-degree local yaw, then reform east-facing. "
        "Do not flip or mirror the unit. Keep detached gear connected or inside "
        "the central safe area. Frame 8 is near-neutral."
    ),
}


def _alpha_clean(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    red, green, blue, alpha = rgba.split()
    alpha = alpha.point(lambda value: 0 if value <= ALPHA_FLOOR else value)
    return Image.merge("RGBA", (red, green, blue, alpha))


def _crop_foreground(image: Image.Image) -> Image.Image:
    alpha = image.getchannel("A")
    bounds = alpha.getbbox()
    if bounds is None:
        raise ValueError("canonical source cell is empty")
    return image.crop(bounds)


def _fit_centered(
    image: Image.Image,
    size: tuple[int, int],
    padding: int,
) -> Image.Image:
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    inner_w = max(1, size[0] - padding * 2)
    inner_h = max(1, size[1] - padding * 2)
    fitted = image.copy()
    fitted.thumbnail((inner_w, inner_h), Image.Resampling.LANCZOS)
    x = (size[0] - fitted.width) // 2
    y = (size[1] - fitted.height) // 2
    canvas.alpha_composite(fitted, (x, y))
    return canvas


def _first_source_cell(sheet: Image.Image) -> Image.Image:
    cell_width = sheet.width // SOURCE_COLUMNS
    cell_height = sheet.height // SOURCE_ROWS
    return sheet.crop((0, 0, cell_width, cell_height))


def _build_master(
    source_dir: Path,
    prototype: str,
    master_override_dir: Path | None,
) -> Image.Image:
    override_name = MASTER_OVERRIDES.get(prototype, "")
    override = (
        master_override_dir / override_name
        if master_override_dir is not None and override_name
        else None
    )
    if override is not None and override.is_file():
        with Image.open(override) as image:
            cell = _alpha_clean(image.convert("RGBA"))
        rotation = 0
    else:
        source = source_dir / f"{prototype}_idle_sunburst_00.png"
        if not source.is_file():
            raise FileNotFoundError(f"missing canonical idle source: {source}")
        with Image.open(source) as image:
            cell = _alpha_clean(_first_source_cell(image.convert("RGBA")))
        rotation = MASTER_ROTATION_DEGREES[prototype]
    cell = cell.rotate(
        rotation,
        expand=True,
        resample=Image.Resampling.BICUBIC,
    )
    cell = _crop_foreground(_alpha_clean(cell))
    return _fit_centered(cell, (MASTER_SIZE, MASTER_SIZE), MASTER_PADDING)


def _build_identity_board(master: Image.Image) -> Image.Image:
    board = Image.new("RGBA", BOARD_SIZE, (0, 0, 0, 0))
    cell_width = BOARD_SIZE[0] // BOARD_COLUMNS
    cell_height = BOARD_SIZE[1] // BOARD_ROWS
    unit = _fit_centered(
        _crop_foreground(master),
        (cell_width, cell_height),
        BOARD_CELL_PADDING,
    )
    for row in range(BOARD_ROWS):
        for column in range(BOARD_COLUMNS):
            board.alpha_composite(
                unit,
                (column * cell_width, row * cell_height),
            )
    return board


def build_action_prompt(prototype: str, action: str) -> str:
    if prototype not in PROTOTYPES or action not in ACTIONS:
        raise ValueError(f"unsupported prompt key: {prototype}/{action}")
    prompt = (
        SHARED_CONTRACT
        + "\n\nSubject: "
        + IDENTITY[prototype]
        + "."
        + (" " + SUBJECT_DETAIL[prototype] if SUBJECT_DETAIL[prototype] else "")
        + "\n\nFacing contract: "
        + ACTION_DIRECTION[action]
        + "\n\n"
        + f"{action.upper()} beat sequence: "
        + BEATS[(prototype, action)]
    )
    special_rule = SPECIAL_RULES.get((prototype, action), "")
    if special_rule:
        prompt += "\n\n" + special_rule
    return prompt


def write_prompts(output_dir: Path) -> list[Path]:
    prompt_dir = output_dir / "prompts"
    prompt_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    sections = [
        "# Military formation v4.1 identity-board prompts",
        "",
        "Reference A for every prompt is the matching canonical eight-cell",
        "identity board generated from one model-created unit master.",
        "",
    ]
    for prototype in PROTOTYPES:
        for action in ACTIONS:
            prompt = build_action_prompt(prototype, action)
            path = prompt_dir / f"{prototype}_{action}.txt"
            path.write_text(prompt + "\n", encoding="utf-8")
            written.append(path)
            sections.extend(
                [
                    f"## {prototype} / {action}",
                    "",
                    "```text",
                    prompt,
                    "```",
                    "",
                ]
            )
    index = output_dir / "prompts_v4_1.md"
    index.write_text("\n".join(sections), encoding="utf-8")
    written.append(index)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--master-override-dir",
        type=Path,
        default=DEFAULT_MASTER_OVERRIDE_DIR,
    )
    args = parser.parse_args()

    master_dir = args.output_dir / "masters"
    board_dir = args.output_dir / "boards"
    master_dir.mkdir(parents=True, exist_ok=True)
    board_dir.mkdir(parents=True, exist_ok=True)
    for prototype in PROTOTYPES:
        master = _build_master(
            args.source_dir,
            prototype,
            args.master_override_dir,
        )
        master_path = master_dir / f"{prototype}_master.png"
        board_path = board_dir / f"{prototype}_identity_board.png"
        master.save(master_path, format="PNG", optimize=True)
        _build_identity_board(master).save(
            board_path,
            format="PNG",
            optimize=True,
        )
        print(f"wrote {master_path}")
        print(f"wrote {board_path}")
    for path in write_prompts(args.output_dir):
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
