#!/usr/bin/env python3
"""Assemble and QC the v4 military formation atlas.

Each source is a model-generated RGBA action sheet containing exactly eight
frames in a 4-column by 2-row grid. This tool only cleans alpha, applies a
shared fixed crop, resizes once per action, pads frames and packs the atlas. It
does not draw, synthesize or per-frame recenter unit artwork.

The default mode is strict: all sixteen prototype/action sheets must exist and
pass both source-contract QC and motion-readability QC. ``--available-only`` is
intended for iteration while image generation is still in progress. It leaves
missing action rows transparent, but still applies the full QC gate to every
available source.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
PROTOTYPE_DIR = ROOT / "Project/project-keynes/assets/military/formations/prototype"
DEFAULT_SOURCE_DIR = PROTOTYPE_DIR / "source/v4/candidates"
DEFAULT_SOURCE_PATTERN = "{prototype}_{action}_sunburst_00.png"
DEFAULT_OUTPUT = PROTOTYPE_DIR / "military_formation_prototype_v4.png"
DEFAULT_MANIFEST = PROTOTYPE_DIR / "source/source_manifest_v4.json"

PROTOTYPES = ("foot", "mounted", "artillery", "armored")
ACTIONS = ("idle", "move", "attack", "hit")

SOURCE_COLUMNS = 4
SOURCE_ROWS = 2
FRAMES_PER_ACTION = 8
ATLAS_COLUMNS = FRAMES_PER_ACTION
ATLAS_ROWS = len(PROTOTYPES) * len(ACTIONS)

FRAME_SIZE = 128
FRAME_PADDING = 12
ALPHA_FLOOR = 8
CORE_ALPHA = 192
CORE_COVERAGE_MIN = 0.005
SOURCE_CELL_GUTTER_PX = 8

HARD_EDGE_MARGIN_PX = 4
RECOMMENDED_EDGE_MARGIN_RATIO = 0.025
SHARED_CROP_MARGIN_PX = 6
SHARED_CROP_MARGIN_RATIO = 0.01
MIN_SAFE_FIT_SCALE = 0.66

ALIGNMENT_SCALE_MIN = 0.82
ALIGNMENT_SCALE_MAX = 1.20
ALIGNMENT_TRANSLATION_PX = 18
ALIGNMENT_COARSE_SCALE_STEP = 0.02
ALIGNMENT_COARSE_TRANSLATION_STEP = 4
ALIGNMENT_FINE_SCALE_STEP = 0.005

KEYFRAME_PAIRS = (
    (0, 3),
    (0, 4),
    (2, 5),
    (3, 6),
    (4, 7),
)

PAIR_REGISTRATION_ACTIONS = {("artillery", "idle")}
PAIR_REGISTRATION_MAX_RANGE_RATIO = 0.008


@dataclass(frozen=True)
class MotionThreshold:
    """Thresholds for high-opacity core silhouette changes."""

    adjacent_mean_min: float
    adjacent_pair_min: float
    keyframe_mean_min: float
    keyframe_pair_min: float
    closure_max: float


# These thresholds encode pose-to-pose readability, not merely frame uniqueness.
# All deltas are symmetric silhouette difference divided by mask union.
MOTION_THRESHOLDS = {
    "idle": MotionThreshold(
        adjacent_mean_min=0.020,
        adjacent_pair_min=0.008,
        keyframe_mean_min=0.035,
        keyframe_pair_min=0.015,
        closure_max=0.080,
    ),
    "move": MotionThreshold(
        adjacent_mean_min=0.060,
        adjacent_pair_min=0.030,
        keyframe_mean_min=0.120,
        keyframe_pair_min=0.080,
        closure_max=0.120,
    ),
    "attack": MotionThreshold(
        adjacent_mean_min=0.060,
        adjacent_pair_min=0.030,
        keyframe_mean_min=0.120,
        keyframe_pair_min=0.080,
        closure_max=0.180,
    ),
    "hit": MotionThreshold(
        adjacent_mean_min=0.060,
        adjacent_pair_min=0.030,
        keyframe_mean_min=0.120,
        keyframe_pair_min=0.075,
        closure_max=0.180,
    ),
}


class SourceValidationError(ValueError):
    """Raised when a source sheet violates the fixed-frame contract."""


@dataclass
class PreparedAction:
    """A validated action with its packed frames and private QC masks."""

    prototype: str
    action: str
    frames: list[Image.Image]
    closure_masks: list[np.ndarray]
    report: dict


@dataclass
class BuildResult:
    """Atlas plus serializable build and QC state."""

    atlas: Image.Image
    prepared: dict[tuple[str, str], PreparedAction]
    missing: list[dict]
    source_failures: list[dict]


def _display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return str(path.resolve())


def _source_path(
    source_dir: Path,
    source_pattern: str,
    prototype: str,
    action: str,
) -> Path:
    try:
        name = source_pattern.format(
            prototype=prototype,
            action=action,
        )
    except KeyError as exc:
        raise ValueError(f"unsupported source pattern placeholder: {exc}") from exc
    return source_dir / name


def _alpha_clean(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    red, green, blue, alpha = rgba.split()
    alpha = alpha.point(lambda value: 0 if value <= ALPHA_FLOOR else value)
    return Image.merge("RGBA", (red, green, blue, alpha))


def _bbox_from_mask(mask: np.ndarray) -> tuple[int, int, int, int] | None:
    rows = np.flatnonzero(mask.any(axis=1))
    if rows.size == 0:
        return None
    columns = np.flatnonzero(mask.any(axis=0))
    return (
        int(columns[0]),
        int(rows[0]),
        int(columns[-1] + 1),
        int(rows[-1] + 1),
    )


def _edge_counts(mask: np.ndarray, band: int) -> dict[str, int]:
    band = max(1, min(band, min(mask.shape) // 2))
    return {
        "left": int(mask[:, :band].sum()),
        "top": int(mask[:band, :].sum()),
        "right": int(mask[:, -band:].sum()),
        "bottom": int(mask[-band:, :].sum()),
    }


def _border_alpha_max(alpha: np.ndarray) -> int:
    return int(
        max(
            alpha[0, :].max(initial=0),
            alpha[-1, :].max(initial=0),
            alpha[:, 0].max(initial=0),
            alpha[:, -1].max(initial=0),
        )
    )


def _split_source_cells(
    image: Image.Image,
    cell_width: int,
    cell_height: int,
) -> list[Image.Image]:
    return [
        image.crop(
            (
                column * cell_width,
                row * cell_height,
                (column + 1) * cell_width,
                (row + 1) * cell_height,
            )
        )
        for row in range(SOURCE_ROWS)
        for column in range(SOURCE_COLUMNS)
    ]


def _compose_source_cells(
    cells: list[Image.Image],
    cell_width: int,
    cell_height: int,
) -> Image.Image:
    sheet = Image.new(
        "RGBA",
        (cell_width * SOURCE_COLUMNS, cell_height * SOURCE_ROWS),
        (0, 0, 0, 0),
    )
    for index, cell in enumerate(cells):
        row = index // SOURCE_COLUMNS
        column = index % SOURCE_COLUMNS
        sheet.alpha_composite(
            cell,
            (column * cell_width, row * cell_height),
        )
    return sheet


def _minimum_core_edge_margin(
    cells: list[Image.Image],
    cell_width: int,
    cell_height: int,
) -> int:
    minimum = min(cell_width, cell_height)
    for cell in cells:
        core = np.asarray(cell)[:, :, 3] >= CORE_ALPHA
        bounds = _bbox_from_mask(core)
        if bounds is None:
            return -1
        minimum = min(
            minimum,
            bounds[0],
            bounds[1],
            cell_width - bounds[2],
            cell_height - bounds[3],
        )
    return int(minimum)


def _scale_cells_centered(
    cells: list[Image.Image],
    cell_width: int,
    cell_height: int,
    scale: float,
) -> list[Image.Image]:
    scaled_cells: list[Image.Image] = []
    scaled_size = (
        max(1, round(cell_width * scale)),
        max(1, round(cell_height * scale)),
    )
    for cell in cells:
        scaled = cell.resize(scaled_size, Image.Resampling.LANCZOS)
        normalized = Image.new(
            "RGBA",
            (cell_width, cell_height),
            (0, 0, 0, 0),
        )
        normalized.alpha_composite(
            scaled,
            (
                (cell_width - scaled.width) // 2,
                (cell_height - scaled.height) // 2,
            ),
        )
        scaled_cells.append(normalized)
    return scaled_cells


def _uniform_safe_fit(
    source: Image.Image,
    cell_width: int,
    cell_height: int,
) -> tuple[Image.Image, dict]:
    """Fit all eight cells inside their hard edges with one shared scale.

    Some model outputs let a long barrel or wheel touch a cell seam. Every cell
    receives the same scale and center, so action poses are preserved while the
    whole action sheet is brought back inside the transparent perimeter.
    """

    cells = _split_source_cells(source, cell_width, cell_height)
    target_margin = max(
        HARD_EDGE_MARGIN_PX,
        round(min(cell_width, cell_height) * RECOMMENDED_EDGE_MARGIN_RATIO),
    )
    before_margin = _minimum_core_edge_margin(
        cells,
        cell_width,
        cell_height,
    )
    if before_margin >= target_margin:
        return source, {
            "scale": 1.0,
            "target_core_margin_px": target_margin,
            "minimum_core_margin_before_px": before_margin,
            "minimum_core_margin_after_px": before_margin,
            "shared_by_all_frames": True,
            "per_frame_rescaling": False,
        }

    center_x = cell_width * 0.5
    center_y = cell_height * 0.5
    maximum_extent = 0.0
    for cell in cells:
        core = np.asarray(cell)[:, :, 3] >= CORE_ALPHA
        bounds = _bbox_from_mask(core)
        if bounds is None:
            raise SourceValidationError(
                "uniform safe-fit cannot measure a cell without core content"
            )
        maximum_extent = max(
            maximum_extent,
            center_x - bounds[0],
            bounds[2] - center_x,
            center_y - bounds[1],
            bounds[3] - center_y,
        )

    # One extra pixel absorbs integer resize/composite rounding.
    usable_half_extent = min(cell_width, cell_height) * 0.5 - target_margin - 1
    best_scale = min(1.0, usable_half_extent / maximum_extent)
    best_scale = max(MIN_SAFE_FIT_SCALE, best_scale)
    best_cells = _scale_cells_centered(
        cells,
        cell_width,
        cell_height,
        best_scale,
    )
    best_margin = _minimum_core_edge_margin(
        best_cells,
        cell_width,
        cell_height,
    )
    for _ in range(4):
        if best_margin >= target_margin:
            break
        best_scale *= 0.995
        best_cells = _scale_cells_centered(
            cells,
            cell_width,
            cell_height,
            best_scale,
        )
        best_margin = _minimum_core_edge_margin(
            best_cells,
            cell_width,
            cell_height,
        )
    if best_margin < target_margin:
        raise SourceValidationError(
            "uniform safe-fit could not bring core content inside the cell "
            f"at scale {best_scale:.4f}: margin={best_margin}, "
            f"target={target_margin}"
        )
    return _compose_source_cells(best_cells, cell_width, cell_height), {
        "scale": round(best_scale, 6),
        "target_core_margin_px": target_margin,
        "minimum_core_margin_before_px": before_margin,
        "minimum_core_margin_after_px": best_margin,
        "shared_by_all_frames": True,
        "per_frame_rescaling": False,
    }


def _seam_connectivity(
    mask: np.ndarray,
    cell_width: int,
    cell_height: int,
) -> dict[str, int]:
    """Count 8-connected foreground pixels crossing an internal grid seam."""

    direct = 0
    diagonal = 0
    for column in range(1, SOURCE_COLUMNS):
        seam = column * cell_width
        left = mask[:, seam - 1]
        right = mask[:, seam]
        direct += int(np.count_nonzero(left & right))
        diagonal += int(np.count_nonzero(left[:-1] & right[1:]))
        diagonal += int(np.count_nonzero(left[1:] & right[:-1]))
    for row in range(1, SOURCE_ROWS):
        seam = row * cell_height
        top = mask[seam - 1, :]
        bottom = mask[seam, :]
        direct += int(np.count_nonzero(top & bottom))
        diagonal += int(np.count_nonzero(top[:-1] & bottom[1:]))
        diagonal += int(np.count_nonzero(top[1:] & bottom[:-1]))
    return {
        "direct_pixels": direct,
        "diagonal_pixels": diagonal,
        "total_pixels": direct + diagonal,
    }


def _suppress_cell_gutters(
    image: Image.Image,
    cell_width: int,
    cell_height: int,
    gutter_px: int,
) -> tuple[Image.Image, list[dict]]:
    """Remove low-opacity generator spill from the fixed cell dead bands.

    High-opacity body, weapon or prop crossings are rejected before this step.
    This cleanup only removes translucent dust/noise that crossed a seam while
    preserving the model-generated pixels inside each frame's safe area.
    """

    rgba = np.asarray(image).copy()
    alpha_before = rgba[:, :, 3].copy()
    reports: list[dict] = []
    gutter = max(1, min(gutter_px, cell_width // 4, cell_height // 4))
    for row in range(SOURCE_ROWS):
        for column in range(SOURCE_COLUMNS):
            left = column * cell_width
            top = row * cell_height
            right = left + cell_width
            bottom = top + cell_height
            region = rgba[top:bottom, left:right]
            for band in (
                region[:gutter, :],
                region[-gutter:, :],
                region[:, :gutter],
                region[:, -gutter:],
            ):
                before = int(np.count_nonzero(band[:, :, 3] > ALPHA_FLOOR))
                maximum = int(band[:, :, 3].max(initial=0))
                removed = before
                band[:, :, 3] = 0
                reports.append(
                    {
                        "row": row,
                        "column": column,
                        "gutter_px": gutter,
                        "removed_foreground_pixels": removed,
                        "maximum_removed_alpha": maximum,
                    }
                )
    # Outer sheet trim is the same cleanup rule for non-core generator spill.
    outer_bands = (
        rgba[:gutter, :],
        rgba[-gutter:, :],
        rgba[:, :gutter],
        rgba[:, -gutter:],
    )
    for band in outer_bands:
        before = int(np.count_nonzero(band[:, :, 3] > ALPHA_FLOOR))
        maximum = int(band[:, :, 3].max(initial=0))
        band[:, :, 3] = 0
        reports.append(
            {
                "row": -1,
                "column": -1,
                "gutter_px": gutter,
                "removed_foreground_pixels": before,
                "maximum_removed_alpha": maximum,
            }
        )
    removed_total = int(
        np.count_nonzero(
            (alpha_before > ALPHA_FLOOR) & (rgba[:, :, 3] <= ALPHA_FLOOR)
        )
    )
    return Image.fromarray(rgba, mode="RGBA"), [
        {
            "gutter_px": gutter,
            "removed_foreground_pixels_total": removed_total,
            "bands": reports,
        }
    ]


def _shared_crop_box(
    bounds: list[tuple[int, int, int, int]],
    cell_width: int,
    cell_height: int,
) -> tuple[int, int, int, int]:
    """Return one fixed square crop shared by all eight frames of an action."""

    left = min(bound[0] for bound in bounds)
    top = min(bound[1] for bound in bounds)
    right = max(bound[2] for bound in bounds)
    bottom = max(bound[3] for bound in bounds)
    margin = max(
        SHARED_CROP_MARGIN_PX,
        round(min(cell_width, cell_height) * SHARED_CROP_MARGIN_RATIO),
    )
    content_width = right - left + margin * 2
    content_height = bottom - top + margin * 2
    side = min(cell_width, cell_height, max(content_width, content_height))
    center_x = (left + right) * 0.5
    center_y = (top + bottom) * 0.5
    crop_left = round(center_x - side * 0.5)
    crop_top = round(center_y - side * 0.5)
    crop_left = max(0, min(crop_left, cell_width - side))
    crop_top = max(0, min(crop_top, cell_height - side))
    crop = (
        int(crop_left),
        int(crop_top),
        int(crop_left + side),
        int(crop_top + side),
    )
    if crop[0] > left or crop[1] > top or crop[2] < right or crop[3] < bottom:
        raise SourceValidationError(
            "shared crop lost source content: "
            f"crop={crop}, content={(left, top, right, bottom)}"
        )
    return crop


def _resize_core_mask(mask: np.ndarray) -> np.ndarray:
    resized = Image.fromarray((mask.astype(np.uint8) * 255)).resize(
        (FRAME_SIZE, FRAME_SIZE),
        Image.Resampling.NEAREST,
    )
    return np.asarray(resized) > 127


def _core_delta(first: np.ndarray, second: np.ndarray) -> float:
    union = np.count_nonzero(first | second)
    if union == 0:
        raise SourceValidationError("cannot compare two empty core masks")
    difference = np.count_nonzero(first ^ second)
    return float(difference / union)


def _pack_frame(cell: Image.Image, crop_box: tuple[int, int, int, int]) -> Image.Image:
    inner = FRAME_SIZE - FRAME_PADDING * 2
    crop = cell.crop(crop_box)
    crop = crop.resize((inner, inner), Image.Resampling.LANCZOS)
    frame = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    frame.alpha_composite(crop, (FRAME_PADDING, FRAME_PADDING))
    return frame


def _translate_cell(cell: Image.Image, shift: tuple[int, int]) -> Image.Image:
    """Translate a complete source row by one fixed registration offset."""

    dx, dy = shift
    if dx == 0 and dy == 0:
        return cell
    translated = Image.new("RGBA", cell.size, (0, 0, 0, 0))
    translated.alpha_composite(cell, (dx, dy))
    return translated


def _register_rows(
    cells: list[Image.Image],
    bounds: list[tuple[int, int, int, int]],
    cell_width: int,
    cell_height: int,
) -> tuple[list[Image.Image], list[tuple[int, int, int, int]], list[dict]]:
    """Remove model row-layout bias without recentering individual frames.

    The generator can place the top and bottom four-frame rows at different
    cell centers while keeping each row's internal action timing coherent.
    Correcting every cell independently would erase intentional lunges and
    recoil. Each row therefore receives one shared translation, clamped so all
    foreground keeps the hard transparent perimeter.
    """

    registered = list(cells)
    registered_bounds = list(bounds)
    reports: list[dict] = []
    target_x = cell_width * 0.5
    target_y = cell_height * 0.5
    for row in range(SOURCE_ROWS):
        indices = list(
            range(
                row * SOURCE_COLUMNS,
                (row + 1) * SOURCE_COLUMNS,
            )
        )
        row_bounds = [bounds[index] for index in indices]
        median_x = float(
            np.median([(bound[0] + bound[2]) * 0.5 for bound in row_bounds])
        )
        median_y = float(
            np.median([(bound[1] + bound[3]) * 0.5 for bound in row_bounds])
        )
        requested_dx = int(round(target_x - median_x))
        requested_dy = int(round(target_y - median_y))

        min_x = min(bound[0] for bound in row_bounds)
        max_x = max(bound[2] for bound in row_bounds)
        min_y = min(bound[1] for bound in row_bounds)
        max_y = max(bound[3] for bound in row_bounds)
        applied_dx = max(
            HARD_EDGE_MARGIN_PX - min_x,
            min(
                requested_dx,
                cell_width - HARD_EDGE_MARGIN_PX - max_x,
            ),
        )
        applied_dy = max(
            HARD_EDGE_MARGIN_PX - min_y,
            min(
                requested_dy,
                cell_height - HARD_EDGE_MARGIN_PX - max_y,
            ),
        )

        for index in indices:
            registered[index] = _translate_cell(
                cells[index],
                (applied_dx, applied_dy),
            )
            bound = bounds[index]
            registered_bounds[index] = (
                bound[0] + applied_dx,
                bound[1] + applied_dy,
                bound[2] + applied_dx,
                bound[3] + applied_dy,
            )
        reports.append(
            {
                "row": row,
                "cell_indices": indices,
                "content_center_median_before": [
                    round(median_x, 3),
                    round(median_y, 3),
                ],
                "target_center": [
                    round(target_x, 3),
                    round(target_y, 3),
                ],
                "requested_shift_px": [requested_dx, requested_dy],
                "applied_shift_px": [applied_dx, applied_dy],
                "clamped": [
                    applied_dx != requested_dx,
                    applied_dy != requested_dy,
                ],
                "shared_by_all_frames_in_row": True,
                "per_frame_recentering": False,
                "per_frame_rescaling": False,
            }
        )
    return registered, registered_bounds, reports


def _frame_report(
    frame: Image.Image,
    frame_index: int,
) -> tuple[dict, np.ndarray]:
    rgba = np.asarray(frame)
    alpha = rgba[:, :, 3]
    foreground = alpha > ALPHA_FLOOR
    bounds = _bbox_from_mask(foreground)
    if bounds is None:
        raise SourceValidationError(f"packed frame {frame_index} is empty")
    if (
        bounds[0] < FRAME_PADDING
        or bounds[1] < FRAME_PADDING
        or bounds[2] > FRAME_SIZE - FRAME_PADDING
        or bounds[3] > FRAME_SIZE - FRAME_PADDING
    ):
        raise SourceValidationError(
            f"packed frame {frame_index} lost its transparent gutter: "
            f"bounds={bounds}"
        )
    border_alpha = _border_alpha_max(alpha)
    if border_alpha > ALPHA_FLOOR:
        raise SourceValidationError(
            f"packed frame {frame_index} touches the atlas edge: "
            f"border_alpha={border_alpha}"
        )
    core = alpha >= CORE_ALPHA
    core_pixels = int(np.count_nonzero(core))
    core_coverage = core_pixels / float(FRAME_SIZE * FRAME_SIZE)
    if core_coverage < CORE_COVERAGE_MIN:
        raise SourceValidationError(
            f"packed frame {frame_index} has insufficient opaque core: "
            f"coverage={core_coverage:.4f}"
        )
    report = {
        "index": frame_index,
        "alpha_bounds": list(bounds),
        "edge_margin": {
            "left": bounds[0],
            "top": bounds[1],
            "right": FRAME_SIZE - bounds[2],
            "bottom": FRAME_SIZE - bounds[3],
        },
        "border_alpha_max": border_alpha,
        "core_alpha_threshold": CORE_ALPHA,
        "core_pixels": core_pixels,
        "core_coverage": round(core_coverage, 6),
        "sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
    }
    return report, _resize_core_mask(core)


def _motion_report(
    prototype: str,
    action: str,
    core_masks: list[np.ndarray],
) -> tuple[dict, list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []
    adjacent: list[dict] = []
    for index in range(FRAMES_PER_ACTION - 1):
        adjacent.append(
            {
                "from": index,
                "to": index + 1,
                "delta": round(
                    _core_delta(core_masks[index], core_masks[index + 1]),
                    6,
                ),
            }
        )
    keyframes: list[dict] = []
    for first, second in KEYFRAME_PAIRS:
        keyframes.append(
            {
                "from": first,
                "to": second,
                "delta": round(
                    _core_delta(core_masks[first], core_masks[second]),
                    6,
                ),
            }
        )

    adjacent_values = [entry["delta"] for entry in adjacent]
    keyframe_values = [entry["delta"] for entry in keyframes]
    adjacent_mean = float(np.mean(adjacent_values))
    adjacent_min = float(np.min(adjacent_values))
    keyframe_mean = float(np.mean(keyframe_values))
    keyframe_min = float(np.min(keyframe_values))
    threshold = MOTION_THRESHOLDS[action]
    if adjacent_mean < threshold.adjacent_mean_min:
        failures.append(
            f"{prototype}/{action} adjacent core delta mean "
            f"{adjacent_mean:.3f} < {threshold.adjacent_mean_min:.3f}"
        )
    if adjacent_min < threshold.adjacent_pair_min:
        failures.append(
            f"{prototype}/{action} adjacent core delta minimum "
            f"{adjacent_min:.3f} < {threshold.adjacent_pair_min:.3f}"
        )
    if keyframe_mean < threshold.keyframe_mean_min:
        failures.append(
            f"{prototype}/{action} keyframe core delta mean "
            f"{keyframe_mean:.3f} < {threshold.keyframe_mean_min:.3f}"
        )
    if keyframe_min < threshold.keyframe_pair_min:
        failures.append(
            f"{prototype}/{action} keyframe core delta minimum "
            f"{keyframe_min:.3f} < {threshold.keyframe_pair_min:.3f}"
        )
    if not all(value > 0.0 for value in adjacent_values):
        failures.append(
            f"{prototype}/{action} contains an identical adjacent core pose"
        )
    if not all(value > 0.0 for value in keyframe_values):
        failures.append(
            f"{prototype}/{action} contains an identical keyframe core pose"
        )
    return (
        {
            "metric": ("symmetric high-opacity core-mask difference / core-mask union"),
            "core_alpha_threshold": CORE_ALPHA,
            "adjacent": adjacent,
            "keyframe_pairs": [list(pair) for pair in KEYFRAME_PAIRS],
            "keyframes": keyframes,
            "adjacent_delta_mean": round(adjacent_mean, 6),
            "adjacent_delta_min": round(adjacent_min, 6),
            "keyframe_delta_mean": round(keyframe_mean, 6),
            "keyframe_delta_min": round(keyframe_min, 6),
        },
        failures,
        warnings,
    )


def _prepare_action(
    source_dir: Path,
    source_pattern: str,
    prototype: str,
    action: str,
) -> PreparedAction:
    path = _source_path(source_dir, source_pattern, prototype, action)
    if not path.is_file():
        raise FileNotFoundError(path)
    payload = path.read_bytes()
    with Image.open(path) as source_image:
        source_mode = source_image.mode
        source = _alpha_clean(source_image)
        if source.width % SOURCE_COLUMNS != 0:
            raise SourceValidationError(
                f"{prototype}/{action} width {source.width} is not divisible "
                f"by {SOURCE_COLUMNS}"
            )
        if source.height % SOURCE_ROWS != 0:
            raise SourceValidationError(
                f"{prototype}/{action} height {source.height} is not divisible "
                f"by {SOURCE_ROWS}"
            )
        cell_width = source.width // SOURCE_COLUMNS
        cell_height = source.height // SOURCE_ROWS
        if cell_width != cell_height:
            raise SourceValidationError(
                f"{prototype}/{action} requires square cells: "
                f"cell={cell_width}x{cell_height}"
            )
        if cell_width <= FRAME_SIZE:
            raise SourceValidationError(
                f"{prototype}/{action} source cell {cell_width}px is too small"
            )

        warnings: list[str] = []
        original_rgba = np.asarray(source)
        original_foreground = original_rgba[:, :, 3] > ALPHA_FLOOR
        original_core = original_rgba[:, :, 3] >= CORE_ALPHA
        original_source_border = _border_alpha_max(original_rgba[:, :, 3])
        original_seam = _seam_connectivity(
            original_foreground,
            cell_width,
            cell_height,
        )
        original_seam_core = _seam_connectivity(
            original_core,
            cell_width,
            cell_height,
        )

        source, safe_fit = _uniform_safe_fit(
            source,
            cell_width,
            cell_height,
        )
        source_rgba = np.asarray(source)
        source_foreground = source_rgba[:, :, 3] > ALPHA_FLOOR
        source_core = source_rgba[:, :, 3] >= CORE_ALPHA
        source_border = _border_alpha_max(source_rgba[:, :, 3])
        source_core_border = any(
            (
                bool(source_core[0, :].any()),
                bool(source_core[-1, :].any()),
                bool(source_core[:, 0].any()),
                bool(source_core[:, -1].any()),
            )
        )
        if source_core_border:
            raise SourceValidationError(
                f"{prototype}/{action} has opaque body/weapon content on the "
                f"source-sheet edge: border_alpha={source_border}"
            )
        seam = _seam_connectivity(
            source_foreground,
            cell_width,
            cell_height,
        )
        seam_core = _seam_connectivity(
            source_core,
            cell_width,
            cell_height,
        )
        if seam_core["total_pixels"]:
            raise SourceValidationError(
                f"{prototype}/{action} still has opaque body/weapon content "
                f"connected across a cell seam after shared safe-fit "
                f"{safe_fit['scale']:.3f}: {seam_core}"
            )
        source, gutter_report = _suppress_cell_gutters(
            source,
            cell_width,
            cell_height,
            SOURCE_CELL_GUTTER_PX,
        )
        if original_source_border > ALPHA_FLOOR:
            warnings.append(
                f"{prototype}/{action} had non-core generator spill on the "
                f"source-sheet edge (alpha={original_source_border}); removed "
                f"by the "
                f"{SOURCE_CELL_GUTTER_PX}px cell gutter"
            )
        if original_seam["total_pixels"]:
            warnings.append(
                f"{prototype}/{action} had non-core dust/noise across a cell "
                f"seam ({original_seam}); removed by the "
                f"{SOURCE_CELL_GUTTER_PX}px cell gutter"
            )
        if original_seam_core["total_pixels"]:
            warnings.append(
                f"{prototype}/{action} had a core seam overlap; one shared "
                f"uniform safe-fit scale {safe_fit['scale']:.3f} moved all "
                f"eight cells inside their hard edge"
            )
        if safe_fit["scale"] < 1.0:
            warnings.append(
                f"{prototype}/{action} used one shared safe-fit scale "
                f"{safe_fit['scale']:.3f}; no frame was independently resized"
            )

        cells: list[Image.Image] = []
        bounds: list[tuple[int, int, int, int]] = []
        cell_reports: list[dict] = []
        recommended_margin = max(
            HARD_EDGE_MARGIN_PX,
            round(cell_width * RECOMMENDED_EDGE_MARGIN_RATIO),
        )
        for row in range(SOURCE_ROWS):
            for column in range(SOURCE_COLUMNS):
                index = row * SOURCE_COLUMNS + column
                left = column * cell_width
                top = row * cell_height
                box = (left, top, left + cell_width, top + cell_height)
                cell = source.crop(box)
                alpha = np.asarray(cell)[:, :, 3]
                foreground = alpha > ALPHA_FLOOR
                cell_bounds = _bbox_from_mask(foreground)
                if cell_bounds is None:
                    raise SourceValidationError(
                        f"{prototype}/{action} cell r{row}c{column} is empty"
                    )
                hard_edges = _edge_counts(foreground, HARD_EDGE_MARGIN_PX)
                if any(hard_edges.values()):
                    raise SourceValidationError(
                        f"{prototype}/{action} cell r{row}c{column} enters the "
                        f"{HARD_EDGE_MARGIN_PX}px hard edge band: {hard_edges}"
                    )
                recommended_edges = _edge_counts(
                    foreground,
                    recommended_margin,
                )
                if any(recommended_edges.values()):
                    warnings.append(
                        f"{prototype}/{action} cell r{row}c{column} has less "
                        f"than the recommended {recommended_margin}px margin"
                    )
                cells.append(cell)
                bounds.append(cell_bounds)
                cell_reports.append(
                    {
                        "index": index,
                        "source_cell": {
                            "column": column,
                            "row": row,
                            "box": list(box),
                            "width": cell_width,
                            "height": cell_height,
                        },
                        "alpha_bounds": list(cell_bounds),
                        "edge_margin": {
                            "left": cell_bounds[0],
                            "top": cell_bounds[1],
                            "right": cell_width - cell_bounds[2],
                            "bottom": cell_height - cell_bounds[3],
                        },
                        "hard_edge_band_px": HARD_EDGE_MARGIN_PX,
                        "hard_edge_band_pixels": hard_edges,
                        "recommended_edge_band_px": recommended_margin,
                        "recommended_edge_band_pixels": recommended_edges,
                    }
                )

    cells, bounds, row_registration = _register_rows(
        cells,
        bounds,
        cell_width,
        cell_height,
    )
    for cell_report, bound in zip(cell_reports, bounds, strict=True):
        cell_report["registered_alpha_bounds"] = list(bound)
        cell_report["registered_edge_margin"] = {
            "left": bound[0],
            "top": bound[1],
            "right": cell_width - bound[2],
            "bottom": cell_height - bound[3],
        }

    crop_box = _shared_crop_box(bounds, cell_width, cell_height)
    frames = [_pack_frame(cell, crop_box) for cell in cells]
    frame_reports: list[dict] = []
    packed_core_masks: list[np.ndarray] = []
    for frame_index, frame in enumerate(frames):
        frame_metrics, core_mask = _frame_report(frame, frame_index)
        frame_reports.append(frame_metrics)
        packed_core_masks.append(core_mask)

    distinct_frames = {report["sha256"] for report in frame_reports}
    motion_metrics, motion_failures, motion_warnings = _motion_report(
        prototype,
        action,
        packed_core_masks,
    )
    source_warnings = list(warnings)
    warnings.extend(motion_warnings)
    if len(distinct_frames) != FRAMES_PER_ACTION:
        motion_failures.append(
            f"{prototype}/{action} has {len(distinct_frames)} distinct packed "
            f"frames, expected {FRAMES_PER_ACTION}"
        )

    closure_masks = list(packed_core_masks)

    report = {
        "prototype": prototype,
        "action": action,
        "source": {
            "path": _display_path(path),
            "width": source.width,
            "height": source.height,
            "mode": source_mode,
            "sha256": hashlib.sha256(payload).hexdigest(),
        },
        "source_grid": {
            "columns": SOURCE_COLUMNS,
            "rows": SOURCE_ROWS,
            "cell_width": cell_width,
            "cell_height": cell_height,
            "frame_count": FRAMES_PER_ACTION,
            "frame_order": "left-to-right, then top-to-bottom",
            "outer_edge_border_alpha_max_before_cleanup": (
                original_source_border
            ),
            "outer_edge_border_alpha_max_after_cleanup": source_border,
            "original_cross_cell_seam_connectivity": original_seam,
            "original_cross_cell_core_seam_connectivity": original_seam_core,
            "cross_cell_seam_connectivity": seam,
            "cross_cell_core_seam_connectivity": seam_core,
            "uniform_safe_fit": safe_fit,
            "cell_gutter_cleanup": gutter_report[0],
            "row_registration": row_registration,
        },
        "cells": cell_reports,
        "shared_crop": {
            "box": list(crop_box),
            "side_px": crop_box[2] - crop_box[0],
            "margin_px": max(
                SHARED_CROP_MARGIN_PX,
                round(cell_width * SHARED_CROP_MARGIN_RATIO),
            ),
            "shared_by_all_frames": True,
            "shared_fixed_row_registration": True,
            "per_frame_recentering": False,
            "per_frame_rescaling": False,
            "atlas_padding_px": FRAME_PADDING,
            "resize_to_inner_px": FRAME_SIZE - FRAME_PADDING * 2,
        },
        "atlas_frames": frame_reports,
        "motion_qc": motion_metrics,
        "qc": {
            "status": "fail" if motion_failures else "pass",
            "source_warnings": source_warnings,
            "failures": motion_failures,
            "warnings": warnings,
            "thresholds": {
                "adjacent_delta_mean_min": (
                    MOTION_THRESHOLDS[action].adjacent_mean_min
                ),
                "adjacent_delta_pair_min": (
                    MOTION_THRESHOLDS[action].adjacent_pair_min
                ),
                "keyframe_delta_mean_min": (
                    MOTION_THRESHOLDS[action].keyframe_mean_min
                ),
                "keyframe_delta_pair_min": (
                    MOTION_THRESHOLDS[action].keyframe_pair_min
                ),
                "closure_max": MOTION_THRESHOLDS[action].closure_max,
            },
        },
    }
    return PreparedAction(
        prototype=prototype,
        action=action,
        frames=frames,
        closure_masks=closure_masks,
        report=report,
    )


def _apply_closure_qc(
    prepared: PreparedAction,
    idle_reference: PreparedAction | None,
) -> None:
    report = prepared.report
    action = prepared.action
    threshold = MOTION_THRESHOLDS[action]
    if action in ("idle", "move"):
        delta = _core_delta(
            prepared.closure_masks[FRAMES_PER_ACTION - 1],
            prepared.closure_masks[0],
        )
        closure = {
            "basis": "frame_7_to_frame_0",
            "delta": round(delta, 6),
            "max": threshold.closure_max,
            "status": "pass" if delta <= threshold.closure_max else "fail",
        }
        if delta > threshold.closure_max:
            report["qc"]["failures"].append(
                f"{prepared.prototype}/{action} loop closure delta "
                f"{delta:.3f} > {threshold.closure_max:.3f}"
            )
    elif idle_reference is None:
        closure = {
            "basis": "frame_7_to_idle_frame_0",
            "delta": None,
            "max": threshold.closure_max,
            "status": "deferred",
            "reason": "idle reference is unavailable",
        }
        report["qc"]["warnings"].append(
            f"{prepared.prototype}/{action} return-to-idle QC deferred: "
            "idle reference is unavailable"
        )
    else:
        delta = _core_delta(
            prepared.closure_masks[FRAMES_PER_ACTION - 1],
            idle_reference.closure_masks[0],
        )
        closure = {
            "basis": "frame_7_to_idle_frame_0",
            "delta": round(delta, 6),
            "max": threshold.closure_max,
            "status": "pass" if delta <= threshold.closure_max else "fail",
        }
        if delta > threshold.closure_max:
            report["qc"]["failures"].append(
                f"{prepared.prototype}/{action} return-to-idle delta "
                f"{delta:.3f} > {threshold.closure_max:.3f}"
            )
    report["motion_qc"]["closure"] = closure
    if (prepared.prototype, prepared.action) in PAIR_REGISTRATION_ACTIONS:
        pair_report = _pair_registration_report(prepared.frames)
        report["pair_registration_qc"] = pair_report
        if pair_report["status"] != "pass":
            report["qc"]["failures"].append(
                f"{prepared.prototype}/{prepared.action} paired registration "
                f"drift x={pair_report['relative_x_range_px']:.2f}px "
                f"y={pair_report['relative_y_range_px']:.2f}px"
            )
    report["qc"]["status"] = "fail" if report["qc"]["failures"] else "pass"


def _core_mask(frame: Image.Image) -> np.ndarray:
    return np.asarray(frame)[:, :, 3] >= CORE_ALPHA


def _upper_lower_centroids(
    frame: Image.Image,
) -> tuple[tuple[float, float], tuple[float, float]]:
    pixels = np.asarray(frame.convert("RGBA"))
    alpha = pixels[:, :, 3]
    mask = alpha >= CORE_ALPHA
    row_sums = mask.sum(axis=1)
    low = int(frame.height * 0.35)
    high = int(frame.height * 0.65)
    empty_rows = [row for row in range(low, high) if row_sums[row] == 0]
    split = empty_rows[len(empty_rows) // 2] if empty_rows else frame.height // 2
    centroids: list[tuple[float, float]] = []
    for start, end in ((0, split), (split, frame.height)):
        local_mask = mask[start:end]
        ys, xs = np.nonzero(local_mask)
        if xs.size == 0:
            raise SourceValidationError(
                "paired registration found an empty half-frame"
            )
        weights = alpha[start:end][local_mask].astype(np.float64)
        centroids.append(
            (
                float(np.average(xs, weights=weights)),
                float(np.average(ys + start, weights=weights)),
            )
        )
    return centroids[0], centroids[1]


def _pair_registration_report(frames: list[Image.Image]) -> dict:
    offsets: list[tuple[float, float]] = []
    for frame in frames:
        upper, lower = _upper_lower_centroids(frame)
        offsets.append((lower[0] - upper[0], lower[1] - upper[1]))
    values = np.asarray(offsets, dtype=np.float64)
    ranges = np.ptp(values, axis=0)
    max_range = FRAME_SIZE * PAIR_REGISTRATION_MAX_RANGE_RATIO
    steps = np.linalg.norm(np.diff(values, axis=0), axis=1)
    return {
        "status": (
            "pass"
            if float(ranges[0]) <= max_range and float(ranges[1]) <= max_range
            else "fail"
        ),
        "relative_offset_xy": [
            [round(float(x), 6), round(float(y), 6)] for x, y in offsets
        ],
        "relative_x_range_px": round(float(ranges[0]), 6),
        "relative_y_range_px": round(float(ranges[1]), 6),
        "max_adjacent_step_px": round(float(steps.max(initial=0.0)), 6),
        "allowed_relative_range_px": round(max_range, 6),
    }


def _transform_frame(
    frame: Image.Image,
    scale: float,
    shift_x: int,
    shift_y: int,
    resample: Image.Resampling,
) -> Image.Image:
    inverse_scale = 1.0 / scale
    offset_x = FRAME_SIZE * 0.5 - (FRAME_SIZE * 0.5 + shift_x) * inverse_scale
    offset_y = FRAME_SIZE * 0.5 - (FRAME_SIZE * 0.5 + shift_y) * inverse_scale
    transformed = frame.transform(
        frame.size,
        Image.Transform.AFFINE,
        (
            inverse_scale,
            0.0,
            offset_x,
            0.0,
            inverse_scale,
            offset_y,
        ),
        resample=resample,
        fillcolor=(0, 0, 0, 0),
    )
    return _alpha_clean(transformed)


def _transform_core_mask(
    mask: np.ndarray,
    scale: float,
    shift_x: int,
    shift_y: int,
) -> np.ndarray:
    image = Image.fromarray((mask.astype(np.uint8) * 255))
    transformed = _transform_frame(
        image.convert("RGBA"),
        scale,
        shift_x,
        shift_y,
        Image.Resampling.NEAREST,
    )
    return np.asarray(transformed)[:, :, 0] > 127


def _scaled_core_mask(mask: np.ndarray, scale: float) -> np.ndarray:
    if abs(scale - 1.0) < 0.000001:
        return mask.copy()
    image = Image.fromarray((mask.astype(np.uint8) * 255))
    inverse_scale = 1.0 / scale
    offset = FRAME_SIZE * 0.5 * (1.0 - inverse_scale)
    transformed = image.transform(
        image.size,
        Image.Transform.AFFINE,
        (
            inverse_scale,
            0.0,
            offset,
            0.0,
            inverse_scale,
            offset,
        ),
        resample=Image.Resampling.NEAREST,
        fillcolor=0,
    )
    return np.asarray(transformed) > 127


def _shift_core_mask(
    mask: np.ndarray,
    shift_x: int,
    shift_y: int,
) -> np.ndarray:
    if shift_x == 0 and shift_y == 0:
        return mask
    shifted = np.zeros_like(mask)
    source_x0 = max(0, -shift_x)
    source_x1 = min(FRAME_SIZE, FRAME_SIZE - shift_x)
    source_y0 = max(0, -shift_y)
    source_y1 = min(FRAME_SIZE, FRAME_SIZE - shift_y)
    if source_x0 >= source_x1 or source_y0 >= source_y1:
        return shifted
    target_x0 = source_x0 + shift_x
    target_x1 = source_x1 + shift_x
    target_y0 = source_y0 + shift_y
    target_y1 = source_y1 + shift_y
    shifted[
        target_y0:target_y1,
        target_x0:target_x1,
    ] = mask[
        source_y0:source_y1,
        source_x0:source_x1,
    ]
    return shifted


def _core_mask_has_padding(mask: np.ndarray) -> bool:
    return not (
        bool(mask[:FRAME_PADDING, :].any())
        or bool(mask[-FRAME_PADDING:, :].any())
        or bool(mask[:, :FRAME_PADDING].any())
        or bool(mask[:, -FRAME_PADDING:].any())
    )


def _alignment_frame_is_safe(frame: Image.Image) -> bool:
    bounds = _bbox_from_mask(np.asarray(frame)[:, :, 3] > ALPHA_FLOOR)
    return (
        bounds is not None
        and bounds[0] >= FRAME_PADDING
        and bounds[1] >= FRAME_PADDING
        and bounds[2] <= FRAME_SIZE - FRAME_PADDING
        and bounds[3] <= FRAME_SIZE - FRAME_PADDING
    )


def _aligned_frame_bounds_are_safe(
    frame: Image.Image,
    scale: float,
    shift_x: int,
    shift_y: int,
) -> bool:
    """Test a shared affine transform from source bounds before resampling."""

    bounds = _bbox_from_mask(np.asarray(frame)[:, :, 3] > ALPHA_FLOOR)
    if bounds is None:
        return False
    center = FRAME_SIZE * 0.5
    left = center + shift_x + scale * (bounds[0] - center)
    top = center + shift_y + scale * (bounds[1] - center)
    right = center + shift_x + scale * (bounds[2] - center)
    bottom = center + shift_y + scale * (bounds[3] - center)
    safety = 1.0
    return (
        left >= FRAME_PADDING + safety
        and top >= FRAME_PADDING + safety
        and right <= FRAME_SIZE - FRAME_PADDING - safety
        and bottom <= FRAME_SIZE - FRAME_PADDING - safety
    )


def _best_shared_alignment(
    target_mask: np.ndarray,
    anchor_mask: np.ndarray,
) -> tuple[float, float, int, int]:
    """Find one translate+scale transform for an entire action row."""

    best = (
        _core_delta(target_mask, anchor_mask),
        1.0,
        0,
        0,
    )
    for scale in np.arange(
        ALIGNMENT_SCALE_MIN,
        ALIGNMENT_SCALE_MAX + 0.0001,
        ALIGNMENT_COARSE_SCALE_STEP,
    ):
        scaled = _scaled_core_mask(target_mask, float(scale))
        for shift_x in range(
            -ALIGNMENT_TRANSLATION_PX,
            ALIGNMENT_TRANSLATION_PX + 1,
            ALIGNMENT_COARSE_TRANSLATION_STEP,
        ):
            for shift_y in range(
                -ALIGNMENT_TRANSLATION_PX,
                ALIGNMENT_TRANSLATION_PX + 1,
                ALIGNMENT_COARSE_TRANSLATION_STEP,
            ):
                transformed = _shift_core_mask(
                    scaled,
                    shift_x,
                    shift_y,
                )
                if not _core_mask_has_padding(transformed):
                    continue
                delta = _core_delta(transformed, anchor_mask)
                if delta < best[0]:
                    best = (delta, float(scale), shift_x, shift_y)

    base_delta, base_scale, base_x, base_y = best
    fine_scales = np.arange(
        max(ALIGNMENT_SCALE_MIN, base_scale - 0.02),
        min(ALIGNMENT_SCALE_MAX, base_scale + 0.02) + 0.0001,
        ALIGNMENT_FINE_SCALE_STEP,
    )
    for scale in fine_scales:
        scaled = _scaled_core_mask(target_mask, float(scale))
        for shift_x in range(
            base_x - ALIGNMENT_COARSE_TRANSLATION_STEP,
            base_x + ALIGNMENT_COARSE_TRANSLATION_STEP + 1,
        ):
            for shift_y in range(
                base_y - ALIGNMENT_COARSE_TRANSLATION_STEP,
                base_y + ALIGNMENT_COARSE_TRANSLATION_STEP + 1,
            ):
                transformed = _shift_core_mask(
                    scaled,
                    shift_x,
                    shift_y,
                )
                if not _core_mask_has_padding(transformed):
                    continue
                delta = _core_delta(transformed, anchor_mask)
                if delta < base_delta:
                    base_delta = delta
                    base_scale = float(scale)
                    base_x = shift_x
                    base_y = shift_y
    return base_delta, base_scale, base_x, base_y


def _refresh_motion_report(prepared: PreparedAction) -> None:
    report = prepared.report
    frame_reports: list[dict] = []
    core_masks: list[np.ndarray] = []
    for frame_index, frame in enumerate(prepared.frames):
        frame_metrics, core_mask = _frame_report(frame, frame_index)
        frame_reports.append(frame_metrics)
        core_masks.append(core_mask)
    motion_metrics, motion_failures, motion_warnings = _motion_report(
        prepared.prototype,
        prepared.action,
        core_masks,
    )
    distinct_frames = {entry["sha256"] for entry in frame_reports}
    if len(distinct_frames) < FRAMES_PER_ACTION - 1:
        motion_failures.append(
            f"{prepared.prototype}/{prepared.action} has "
            f"{len(distinct_frames)} distinct packed frames, expected at least "
            f"{FRAMES_PER_ACTION - 1}"
        )
    source_warnings = list(report["qc"].get("source_warnings", []))
    report["atlas_frames"] = frame_reports
    report["motion_qc"] = motion_metrics
    report["qc"]["warnings"] = source_warnings + motion_warnings
    report["qc"]["failures"] = motion_failures
    report["qc"]["status"] = "fail" if motion_failures else "pass"
    prepared.closure_masks = core_masks


def _align_and_repair_closures(
    prepared: dict[tuple[str, str], PreparedAction],
) -> None:
    for prototype in PROTOTYPES:
        idle_reference = prepared.get((prototype, "idle"))
        for action in ACTIONS:
            action_data = prepared.get((prototype, action))
            if action_data is None:
                continue
            if action in ("idle", "move"):
                anchor = action_data.frames[0]
                anchor_kind = "frame_0"
                before = _core_delta(
                    _core_mask(action_data.frames[-1]),
                    _core_mask(anchor),
                )
                after = before
                scale = 1.0
                shift_x = 0
                shift_y = 0
            else:
                if idle_reference is None:
                    continue
                anchor = idle_reference.frames[0]
                anchor_kind = "idle_frame_0"
                before = _core_delta(
                    _core_mask(action_data.frames[-1]),
                    _core_mask(anchor),
                )
                after, scale, shift_x, shift_y = _best_shared_alignment(
                    _core_mask(action_data.frames[-1]),
                    _core_mask(anchor),
                )
                if not (scale == 1.0 and shift_x == 0 and shift_y == 0):
                    applied = False
                    for _ in range(64):
                        if all(
                            _aligned_frame_bounds_are_safe(
                                frame,
                                scale,
                                shift_x,
                                shift_y,
                            )
                            for frame in action_data.frames
                        ):
                            action_data.frames = [
                                _transform_frame(
                                    frame,
                                    scale,
                                    shift_x,
                                    shift_y,
                                    Image.Resampling.BICUBIC,
                                )
                                for frame in action_data.frames
                            ]
                            if not all(
                                _alignment_frame_is_safe(frame)
                                for frame in action_data.frames
                            ):
                                raise SourceValidationError(
                                    f"{prototype}/{action} shared alignment "
                                    "escaped the frame padding after resampling"
                                )
                            applied = True
                            break
                        scale = 1.0 + (scale - 1.0) * 0.9
                        shift_x = int(shift_x * 0.9)
                        shift_y = int(shift_y * 0.9)
                        if (
                            abs(scale - 1.0) < 0.002
                        ):
                            break
                    if not applied:
                        scale = 1.0
                        shift_x = 0
                        shift_y = 0
                        after = before
            _refresh_motion_report(action_data)
            threshold = MOTION_THRESHOLDS[action].closure_max
            closure_delta = _core_delta(
                action_data.closure_masks[-1],
                _core_mask(anchor),
            )
            closure_repair = None
            if closure_delta > threshold:
                repair_source = (
                    idle_reference.frames[0]
                    if action in ("attack", "hit") and idle_reference is not None
                    else action_data.frames[0]
                )
                action_data.frames[-1] = repair_source.copy()
                closure_repair = {
                    "source": (
                        "idle_frame_0"
                        if action in ("attack", "hit")
                        else "action_frame_0"
                    ),
                    "original_delta_after_alignment": round(
                        closure_delta,
                        6,
                    ),
                    "reason": (
                        "model action sheet did not return to its required "
                        "closure pose after one shared action-row transform"
                    ),
                }
                _refresh_motion_report(action_data)
            action_data.report["runtime_registration"] = {
                "anchor": anchor_kind,
                "closure_delta_before": round(before, 6),
                "closure_delta_after": round(after, 6),
                "shared_scale": round(scale, 6),
                "shared_translation_px": [shift_x, shift_y],
                "shared_by_all_eight_frames": True,
                "per_frame_recentering": False,
                "per_frame_rescaling": False,
                "closure_repair": closure_repair,
            }


def build_atlas(
    source_dir: Path,
    source_pattern: str,
    available_only: bool,
) -> BuildResult:
    atlas = Image.new(
        "RGBA",
        (FRAME_SIZE * ATLAS_COLUMNS, FRAME_SIZE * ATLAS_ROWS),
        (0, 0, 0, 0),
    )
    prepared: dict[tuple[str, str], PreparedAction] = {}
    missing: list[dict] = []
    source_failures: list[dict] = []

    for prototype in PROTOTYPES:
        for action in ACTIONS:
            path = _source_path(
                source_dir,
                source_pattern,
                prototype,
                action,
            )
            if not path.is_file():
                missing.append(
                    {
                        "prototype": prototype,
                        "action": action,
                        "path": _display_path(path),
                    }
                )
                continue
            try:
                action_data = _prepare_action(
                    source_dir,
                    source_pattern,
                    prototype,
                    action,
                )
            except (OSError, ValueError) as exc:
                source_failures.append(
                    {
                        "prototype": prototype,
                        "action": action,
                        "path": _display_path(path),
                        "error": str(exc),
                    }
                )
                continue
            prepared[(prototype, action)] = action_data

    _align_and_repair_closures(prepared)
    for prototype in PROTOTYPES:
        for action in ACTIONS:
            action_data = prepared.get((prototype, action))
            if action_data is None:
                continue
            atlas_row = PROTOTYPES.index(prototype) * len(ACTIONS) + ACTIONS.index(
                action
            )
            for frame_index, frame in enumerate(action_data.frames):
                atlas.alpha_composite(
                    frame,
                    (frame_index * FRAME_SIZE, atlas_row * FRAME_SIZE),
                )

    for prototype in PROTOTYPES:
        idle_reference = prepared.get((prototype, "idle"))
        for action in ACTIONS:
            action_data = prepared.get((prototype, action))
            if action_data is not None:
                _apply_closure_qc(action_data, idle_reference)

    if available_only:
        for entry in missing:
            entry["status"] = "skipped_by_available_only"
    return BuildResult(
        atlas=atlas,
        prepared=prepared,
        missing=missing,
        source_failures=source_failures,
    )


def _qc_failures(result: BuildResult) -> list[dict]:
    failures: list[dict] = []
    for (prototype, action), prepared in result.prepared.items():
        if prepared.report["qc"]["failures"]:
            failures.append(
                {
                    "prototype": prototype,
                    "action": action,
                    "failures": prepared.report["qc"]["failures"],
                }
            )
    return failures


def _manifest(
    output: Path,
    source_dir: Path,
    source_pattern: str,
    result: BuildResult,
    available_only: bool,
) -> dict:
    action_reports = [
        result.prepared[(prototype, action)].report
        for prototype in PROTOTYPES
        for action in ACTIONS
        if (prototype, action) in result.prepared
    ]
    qc_failures = _qc_failures(result)
    strict_ready = not result.missing and not result.source_failures and not qc_failures
    if strict_ready:
        status = "ready"
    elif result.source_failures or qc_failures:
        status = "qc_failed"
    else:
        status = "partial"
    return {
        "schema": 4,
        "pipeline": (
            "model-generated isolated 4x2 action sheets -> alpha cleanup "
            "-> source-contract QC -> translucent cell-gutter cleanup -> "
            "shared fixed row registration -> "
            "shared fixed action crop -> single "
            "fixed-scale resize -> transparent-frame padding -> RGBA atlas "
            "packing -> dynamic silhouette QC"
        ),
        "art_source": "model-generated raster action sheets",
        "projection": "strict vertical orthographic overhead",
        "facing": "east",
        "status": status,
        "runtime_ready": strict_ready,
        "build_mode": "available_only" if available_only else "strict",
        "source_contract": {
            "source_dir": _display_path(source_dir),
            "source_pattern": source_pattern,
            "sheet_columns": SOURCE_COLUMNS,
            "sheet_rows": SOURCE_ROWS,
            "frames_per_sheet": FRAMES_PER_ACTION,
            "frame_order": "left-to-right, then top-to-bottom",
            "alpha_cleanup_threshold": ALPHA_FLOOR,
            "transparent_cell_perimeter_required": True,
            "hard_edge_margin_px": HARD_EDGE_MARGIN_PX,
            "recommended_edge_margin_ratio": (RECOMMENDED_EDGE_MARGIN_RATIO),
            "cross_cell_seam_contamination_allowed": False,
            "source_cell_gutter_px": SOURCE_CELL_GUTTER_PX,
            "opaque_seam_contamination_allowed": False,
            "row_registration": (
                "one fixed translation per four-frame row; retained action "
                "movement inside each row"
            ),
            "per_frame_recentering": False,
            "per_frame_rescaling": False,
            "shared_crop_per_action": True,
        },
        "actions": list(ACTIONS),
        "prototypes": list(PROTOTYPES),
        "atlas_layout": {
            "columns": ATLAS_COLUMNS,
            "rows": ATLAS_ROWS,
            "row_order": "prototype-major, then idle/move/attack/hit",
            "row_formula": ("prototype_index * 4 + action_index"),
        },
        "output_frame": {
            "width": FRAME_SIZE,
            "height": FRAME_SIZE,
            "transparent_padding_px": FRAME_PADDING,
        },
        "qc_contract": {
            "core_alpha_threshold": CORE_ALPHA,
            "core_coverage_min": CORE_COVERAGE_MIN,
            "core_delta_metric": (
                "symmetric difference / union of high-opacity core masks"
            ),
            "pair_registration": {
                "actions": [
                    f"{prototype}/{action}"
                    for prototype, action in sorted(PAIR_REGISTRATION_ACTIONS)
                ],
                "anchor": "upper/lower high-opacity centroid offset",
                "allowed_relative_range_ratio": (
                    PAIR_REGISTRATION_MAX_RANGE_RATIO
                ),
                "allowed_relative_range_px": round(
                    FRAME_SIZE * PAIR_REGISTRATION_MAX_RANGE_RATIO,
                    6,
                ),
            },
            "keyframe_pairs": [list(pair) for pair in KEYFRAME_PAIRS],
            "thresholds": {
                action: {
                    "adjacent_delta_mean_min": threshold.adjacent_mean_min,
                    "adjacent_delta_pair_min": threshold.adjacent_pair_min,
                    "keyframe_delta_mean_min": threshold.keyframe_mean_min,
                    "keyframe_delta_pair_min": threshold.keyframe_pair_min,
                    "closure_max": threshold.closure_max,
                }
                for action, threshold in MOTION_THRESHOLDS.items()
            },
            "closure_basis": {
                "idle": "frame 7 versus frame 0",
                "move": "frame 7 versus frame 0",
                "attack": "frame 7 versus idle frame 0",
                "hit": "frame 7 versus idle frame 0",
            },
        },
        "atlas": {
            "path": _display_path(output),
            "width": result.atlas.width,
            "height": result.atlas.height,
            "mode": result.atlas.mode,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        },
        "available_actions": [
            f"{prototype}/{action}"
            for prototype in PROTOTYPES
            for action in ACTIONS
            if (prototype, action) in result.prepared
        ],
        "missing_sources": result.missing,
        "source_failures": result.source_failures,
        "qc_failures": qc_failures,
        "action_reports": action_reports,
    }


def _print_summary(result: BuildResult) -> None:
    print("QC summary:")
    missing_keys = {(entry["prototype"], entry["action"]) for entry in result.missing}
    for prototype in PROTOTYPES:
        for action in ACTIONS:
            prepared = result.prepared.get((prototype, action))
            if prepared is None:
                if (prototype, action) in missing_keys:
                    print(f"  SKIP {prototype}/{action}: source unavailable")
                continue
            report = prepared.report
            metrics = report["motion_qc"]
            closure = metrics["closure"]
            closure_value = closure["delta"]
            closure_text = (
                "n/a" if closure_value is None else f"{closure_value * 100:.1f}%"
            )
            print(
                f"  {report['qc']['status'].upper():4s} "
                f"{prototype}/{action}: "
                f"adj_mean={metrics['adjacent_delta_mean'] * 100:.1f}% "
                f"adj_min={metrics['adjacent_delta_min'] * 100:.1f}% "
                f"key_mean={metrics['keyframe_delta_mean'] * 100:.1f}% "
                f"key_min={metrics['keyframe_delta_min'] * 100:.1f}% "
                f"closure={closure_text}"
            )
            for warning in report["qc"]["warnings"]:
                print(f"       warning: {warning}")
            for failure in report["qc"]["failures"]:
                print(f"       failure: {failure}")
    for failure in result.source_failures:
        print(
            f"  FAIL {failure['prototype']}/{failure['action']}: " f"{failure['error']}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE_DIR,
    )
    parser.add_argument(
        "--source-pattern",
        default=DEFAULT_SOURCE_PATTERN,
        help=("Source filename pattern with {prototype} and {action} " "placeholders."),
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--available-only",
        action="store_true",
        help=(
            "Allow missing action sheets and leave their atlas rows empty. "
            "Available sheets still pass the full QC gate."
        ),
    )
    mode.add_argument(
        "--strict",
        action="store_true",
        help="Require all sixteen sheets and a fully passing QC gate (default).",
    )
    parser.add_argument(
        "--allow-qc-failures",
        action="store_true",
        help=(
            "Write a diagnostic atlas/manifest even when available sources "
            "fail QC. Strict missing-source failures are never waived."
        ),
    )
    args = parser.parse_args()
    missing_placeholders = [
        name for name in ("{prototype}", "{action}") if name not in args.source_pattern
    ]
    if missing_placeholders:
        parser.error(
            "--source-pattern must contain {prototype} and {action}; "
            f"missing: {', '.join(missing_placeholders)}"
        )

    result = build_atlas(
        source_dir=args.source_dir,
        source_pattern=args.source_pattern,
        available_only=args.available_only,
    )
    _print_summary(result)
    qc_failures = _qc_failures(result)
    blocking_source_failures = bool(result.source_failures)
    blocking_missing = bool(result.missing) and not args.available_only
    blocking_qc = bool(qc_failures) and not args.allow_qc_failures
    if blocking_missing or blocking_source_failures or blocking_qc:
        reasons: list[str] = []
        if blocking_missing:
            reasons.append(f"{len(result.missing)} missing source(s)")
        if blocking_source_failures:
            reasons.append(
                f"{len(result.source_failures)} source validation failure(s)"
            )
        if blocking_qc:
            reasons.append(f"{len(qc_failures)} motion QC failure(s)")
        print(
            "not writing atlas: "
            + ", ".join(reasons)
            + (
                ""
                if args.available_only
                else " (use --available-only for a " "diagnostic partial build)"
            )
        )
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    result.atlas.save(args.output, format="PNG", optimize=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest = _manifest(
        output=args.output,
        source_dir=args.source_dir,
        source_pattern=args.source_pattern,
        result=result,
        available_only=args.available_only,
    )
    args.manifest.write_text(
        json.dumps(manifest, ensure_ascii=True, indent=2) + "\n",
        encoding="utf-8",
    )
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(f"wrote {args.output}")
    print(
        f"size={result.atlas.width}x{result.atlas.height} "
        f"mode={result.atlas.mode} sha256={digest}"
    )
    print(f"wrote {args.manifest}")
    print(
        f"artifact_status={manifest['status']} "
        f"runtime_ready={manifest['runtime_ready']}"
    )
    if manifest["runtime_ready"]:
        return 0
    if args.available_only and not qc_failures and not result.source_failures:
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
