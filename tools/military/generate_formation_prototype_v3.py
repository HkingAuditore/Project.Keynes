#!/usr/bin/env python3
"""Assemble the v3 military formation atlas from isolated action sheets.

The generated source art is arranged as four prototype/action sheets. Each
sheet contains exactly eight frames in a 4-column by 2-row grid. This tool only
performs alpha cleanup, fixed-scale cell extraction, transparent padding and
atlas packing. It does not draw or synthesize unit artwork.

Unlike v2, v3 treats frame isolation as a hard input contract:

- every source cell must leave a transparent perimeter;
- all eight cells use one shared, cell-centered crop;
- no frame is independently recentered or rescaled;
- each atlas frame receives an additional transparent safety gutter.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
PROTOTYPE_DIR = (
    ROOT
    / "Project/project-keynes/assets/military/formations/prototype"
)
DEFAULT_SOURCE_DIR = PROTOTYPE_DIR / "source/v3"
DEFAULT_OUTPUT = PROTOTYPE_DIR / "military_formation_prototype_v3.png"
DEFAULT_MANIFEST = PROTOTYPE_DIR / "source/source_manifest_v3.json"

PROTOTYPES = ("foot", "mounted", "artillery", "armored")
ACTIONS = ("idle", "move", "attack", "hit")
SOURCE_COLUMNS = 4
SOURCE_ROWS = 2
FRAMES_PER_ACTION = 8
FRAME = 128
FRAME_PADDING = 12
ALPHA_FLOOR = 8
MIN_CELL_EDGE_MARGIN_PX = 3


class SourceValidationError(ValueError):
    """Raised when a generated action sheet violates the frame contract."""


def _source_path(source_dir: Path, prototype: str, action: str) -> Path:
    return source_dir / f"{prototype}_{action}.png"


def _cell_box(
    width: int,
    height: int,
    column: int,
    row: int,
) -> tuple[int, int, int, int]:
    left = round(column * width / SOURCE_COLUMNS)
    right = round((column + 1) * width / SOURCE_COLUMNS)
    top = round(row * height / SOURCE_ROWS)
    bottom = round((row + 1) * height / SOURCE_ROWS)
    return left, top, right, bottom


def _alpha_clean(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    red, green, blue, alpha = rgba.split()
    alpha = alpha.point(lambda value: 0 if value <= ALPHA_FLOOR else value)
    return Image.merge("RGBA", (red, green, blue, alpha))


def _cell_metrics(
    sheet: Image.Image,
    prototype: str,
    action: str,
) -> tuple[list[Image.Image], list[dict], float, float]:
    cells: list[Image.Image] = []
    metrics: list[dict] = []
    max_half_x = 0.0
    max_half_y = 0.0
    for row in range(SOURCE_ROWS):
        for column in range(SOURCE_COLUMNS):
            box = _cell_box(sheet.width, sheet.height, column, row)
            cell = _alpha_clean(sheet.crop(box))
            used = cell.getbbox()
            if used is None:
                raise SourceValidationError(
                    f"{prototype}/{action} cell r{row}c{column} is empty"
                )
            edge_margin_x = max(
                MIN_CELL_EDGE_MARGIN_PX,
                round(cell.width * 0.025),
            )
            edge_margin_y = max(
                MIN_CELL_EDGE_MARGIN_PX,
                round(cell.height * 0.025),
            )
            if (
                used[0] < edge_margin_x
                or used[1] < edge_margin_y
                or used[2] > cell.width - edge_margin_x
                or used[3] > cell.height - edge_margin_y
            ):
                raise SourceValidationError(
                    f"{prototype}/{action} cell r{row}c{column} touches its "
                    f"frame boundary: used={used}, size={cell.size}"
                )
            center_x = cell.width * 0.5
            center_y = cell.height * 0.5
            max_half_x = max(
                max_half_x,
                abs(float(used[0]) - center_x),
                abs(float(used[2]) - center_x),
            )
            max_half_y = max(
                max_half_y,
                abs(float(used[1]) - center_y),
                abs(float(used[3]) - center_y),
            )
            cells.append(cell)
            metrics.append(
                {
                    "index": row * SOURCE_COLUMNS + column,
                    "source_cell": {
                        "column": column,
                        "row": row,
                        "box": list(box),
                        "width": cell.width,
                        "height": cell.height,
                    },
                    "alpha_bounds": list(used),
                    "edge_margin": {
                        "left": used[0],
                        "top": used[1],
                        "right": cell.width - used[2],
                        "bottom": cell.height - used[3],
                    },
                }
            )
    return cells, metrics, max_half_x, max_half_y


def _common_crop_side(cells: list[Image.Image], max_half_x: float,
                      max_half_y: float) -> int:
    smallest_cell_side = min(min(cell.width, cell.height) for cell in cells)
    padding = max(4.0, float(smallest_cell_side) * 0.035)
    half = max(max_half_x, max_half_y) + padding
    side = int(round(half * 2.0))
    if side >= smallest_cell_side:
        raise SourceValidationError(
            "shared crop does not fit inside the source cells: "
            f"crop={side}, smallest_cell={smallest_cell_side}"
        )
    return side


def _normalize_action(
    sheet: Image.Image,
    prototype: str,
    action: str,
) -> tuple[list[Image.Image], dict]:
    sheet = _alpha_clean(sheet)
    cells, cell_metrics, max_half_x, max_half_y = _cell_metrics(
        sheet,
        prototype,
        action,
    )
    crop_side = _common_crop_side(cells, max_half_x, max_half_y)
    inner = FRAME - FRAME_PADDING * 2
    frames: list[Image.Image] = []
    crop_metrics: list[dict] = []
    for cell, metrics in zip(cells, cell_metrics, strict=True):
        left = round(cell.width * 0.5 - crop_side * 0.5)
        top = round(cell.height * 0.5 - crop_side * 0.5)
        crop = cell.crop((left, top, left + crop_side, top + crop_side))
        crop = crop.resize((inner, inner), Image.Resampling.LANCZOS)
        frame = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
        frame.alpha_composite(crop, (FRAME_PADDING, FRAME_PADDING))
        frames.append(frame)
        crop_metrics.append(
            {
                "crop_box": [left, top, left + crop_side, top + crop_side],
                "atlas_padding_px": FRAME_PADDING,
            }
        )
    summary = {
        "prototype": prototype,
        "action": action,
        "source_columns": SOURCE_COLUMNS,
        "source_rows": SOURCE_ROWS,
        "frame_count": len(frames),
        "shared_crop_side_px": crop_side,
        "cells": cell_metrics,
        "crops": crop_metrics,
    }
    return frames, summary


def _frame_metrics(frame: Image.Image, prototype: str, action: str,
                   frame_index: int) -> dict:
    alpha = frame.getchannel("A").point(
        lambda value: 0 if value <= ALPHA_FLOOR else value
    )
    used = alpha.getbbox()
    if used is None:
        raise SourceValidationError(
            f"{prototype}/{action} frame {frame_index} is empty after packing"
        )
    if (
        used[0] < FRAME_PADDING
        or used[1] < FRAME_PADDING
        or used[2] > FRAME - FRAME_PADDING
        or used[3] > FRAME - FRAME_PADDING
    ):
        raise SourceValidationError(
            f"{prototype}/{action} frame {frame_index} lost its atlas gutter: "
            f"used={used}"
        )
    border = Image.new("L", (FRAME, FRAME), 0)
    border.paste(alpha.crop((0, 0, FRAME, 1)), (0, 0))
    border.paste(alpha.crop((0, FRAME - 1, FRAME, FRAME)), (0, FRAME - 1))
    border.paste(alpha.crop((0, 0, 1, FRAME)), (0, 0))
    border.paste(alpha.crop((FRAME - 1, 0, FRAME, FRAME)), (FRAME - 1, 0))
    if border.getextrema()[1] > ALPHA_FLOOR:
        raise SourceValidationError(
            f"{prototype}/{action} frame {frame_index} touches the atlas edge"
        )
    return {
        "index": frame_index,
        "alpha_bounds": list(used),
        "sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
    }


def build_atlas(source_dir: Path) -> tuple[Image.Image, list[dict], dict]:
    atlas = Image.new(
        "RGBA",
        (FRAME * FRAMES_PER_ACTION, FRAME * len(ACTIONS) * len(PROTOTYPES)),
        (0, 0, 0, 0),
    )
    action_reports: list[dict] = []
    source_info: dict[str, dict] = {}
    for prototype_row, prototype in enumerate(PROTOTYPES):
        for action_row, action in enumerate(ACTIONS):
            path = _source_path(source_dir, prototype, action)
            if not path.exists():
                raise FileNotFoundError(
                    f"missing generated v3 source sheet: {path}"
                )
            payload = path.read_bytes()
            with Image.open(path) as source:
                source = source.convert("RGBA")
                frames, report = _normalize_action(
                    source,
                    prototype,
                    action,
                )
                report["source"] = {
                    "path": path.relative_to(ROOT).as_posix(),
                    "width": source.width,
                    "height": source.height,
                    "mode": source.mode,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
                source_info[f"{prototype}/{action}"] = report["source"]
            atlas_row = prototype_row * len(ACTIONS) + action_row
            frame_reports: list[dict] = []
            for frame_index, frame in enumerate(frames):
                frame_reports.append(
                    _frame_metrics(frame, prototype, action, frame_index)
                )
                atlas.alpha_composite(
                    frame,
                    (frame_index * FRAME, atlas_row * FRAME),
                )
            distinct_frames = {
                frame_report["sha256"] for frame_report in frame_reports
            }
            if len(distinct_frames) < 7:
                raise SourceValidationError(
                    f"{prototype}/{action} has only {len(distinct_frames)} "
                    "distinct packed frames"
                )
            report["atlas_frames"] = frame_reports
            action_reports.append(report)
    return atlas, action_reports, source_info


def _manifest(
    output: Path,
    atlas: Image.Image,
    action_reports: list[dict],
    source_info: dict[str, dict],
) -> dict:
    return {
        "schema": 3,
        "pipeline": (
            "built-in image generation -> isolated 4x2 action sheets "
            "-> shared-anchor cell crop -> transparent-frame padding "
            "-> RGBA atlas packing"
        ),
        "art_source": "model-generated raster action sheets",
        "projection": "strict vertical orthographic overhead",
        "facing": "east",
        "source_contract": {
            "sheet_columns": SOURCE_COLUMNS,
            "sheet_rows": SOURCE_ROWS,
            "frames_per_sheet": FRAMES_PER_ACTION,
            "frame_order": "left-to-right, then top-to-bottom",
            "alpha_cleanup_threshold": ALPHA_FLOOR,
            "transparent_cell_perimeter_required": True,
            "per_frame_recentering": False,
            "shared_crop_per_action": True,
        },
        "actions": list(ACTIONS),
        "prototypes": list(PROTOTYPES),
        "output_frame": {
            "width": FRAME,
            "height": FRAME,
            "transparent_padding_px": FRAME_PADDING,
        },
        "atlas": {
            "path": output.relative_to(ROOT).as_posix(),
            "width": atlas.width,
            "height": atlas.height,
            "mode": atlas.mode,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        },
        "sources": source_info,
        "action_reports": action_reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()

    atlas, reports, source_info = build_atlas(args.source_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(args.output, format="PNG", optimize=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(
        json.dumps(
            _manifest(args.output, atlas, reports, source_info),
            ensure_ascii=True,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(f"wrote {args.output}")
    print(
        f"size={atlas.width}x{atlas.height} "
        f"mode={atlas.mode} sha256={digest}"
    )
    print(f"wrote {args.manifest}")
    for report in reports:
        print(
            "validated "
            f"{report['prototype']}/{report['action']}: "
            f"frames={report['frame_count']} "
            f"crop={report['shared_crop_side_px']}px"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
