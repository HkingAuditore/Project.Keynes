#!/usr/bin/env python3
"""Convert a fixed-camera unit animation clip into an 8-frame 4x2 source sheet.

This is the video-first path for military formation art:

    canonical model-generated master
      -> fixed-camera image-to-video action clip
      -> stable 8-frame window
      -> one shared crop and one shared scale
      -> transparent 1792x896 source sheet
      -> generate_formation_prototype_v4.py atlas build

The tool never draws unit artwork. Pillow is used only for chroma-key
transparency cleanup, deterministic cropping, resizing, padding and packing.
Frame content must come from a model-generated clip or prepared RGBA frames.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
PROTOTYPE_DIR = ROOT / "Project/project-keynes/assets/military/formations/prototype"
DEFAULT_VIDEO_DIR = PROTOTYPE_DIR / "source/v4/video"
DEFAULT_SOURCE_DIR = PROTOTYPE_DIR / "source/v4/video_selected"

PROTOTYPES = ("foot", "mounted", "artillery", "armored")
ACTIONS = ("idle", "move", "attack", "hit")
LOOP_ACTIONS = {"idle", "move"}

FRAME_COUNT = 8
SOURCE_COLUMNS = 4
SOURCE_ROWS = 2
SOURCE_CELL_SIZE = 448
SOURCE_SHEET_SIZE = (SOURCE_CELL_SIZE * SOURCE_COLUMNS, SOURCE_CELL_SIZE * SOURCE_ROWS)
DEFAULT_SHEET_PADDING = 62

ALPHA_FLOOR = 8
CORE_ALPHA = 192
CROP_ALPHA = 16
DEFAULT_KEY_TOLERANCE = 26.0
DEFAULT_KEY_SOFTNESS = 18.0

MIN_MOTION_BY_ACTION = {
    "idle": 0.010,
    "move": 0.035,
    "attack": 0.035,
    "hit": 0.035,
}
MAX_MOTION_BY_ACTION = {
    "idle": 0.085,
    "move": 0.420,
    "attack": 0.520,
    "hit": 0.520,
}


class PipelineError(RuntimeError):
    """Raised when input or output violates the video-to-sheet contract."""


@dataclass
class DecodedFrame:
    index: int
    seconds: float
    image: Image.Image


@dataclass
class WindowChoice:
    indices: list[int]
    score: float
    report: dict[str, Any]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return str(path.resolve())


def _resolve_ffmpeg(explicit: str) -> str:
    candidates = [
        explicit.strip(),
        os.environ.get("FFMPEG_BIN", "").strip(),
        r"E:\ffmpeg-2026-01-05-git-2892815c45-full_build\bin\ffmpeg.exe",
        shutil.which("ffmpeg") or "",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))
    raise PipelineError(
        "ffmpeg was not found; pass --ffmpeg or set FFMPEG_BIN"
    )


def _resolve_ffprobe(ffmpeg: str, explicit: str) -> str:
    candidates = [
        explicit.strip(),
        os.environ.get("FFPROBE_BIN", "").strip(),
        str(Path(ffmpeg).with_name("ffprobe.exe")),
        str(Path(ffmpeg).with_name("ffprobe")),
        shutil.which("ffprobe") or "",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))
    raise PipelineError(
        "ffprobe was not found; pass --ffprobe or set FFPROBE_BIN"
    )


def _parse_rate(value: str) -> float:
    if not value:
        return 0.0
    if "/" in value:
        numerator, denominator = value.split("/", 1)
        denominator_value = float(denominator)
        return float(numerator) / denominator_value if denominator_value else 0.0
    return float(value)


def _probe_video(path: Path, ffprobe: str) -> dict[str, Any]:
    command = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration",
        "-of",
        "json",
        str(path),
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise PipelineError(f"ffprobe failed: {result.stderr.strip()}")
    try:
        streams = json.loads(result.stdout).get("streams", [])
    except json.JSONDecodeError as exc:
        raise PipelineError("ffprobe returned invalid JSON") from exc
    if not streams:
        raise PipelineError("video has no readable video stream")
    stream = streams[0]
    rate = _parse_rate(
        str(stream.get("avg_frame_rate") or stream.get("r_frame_rate") or "")
    )
    return {
        "width": int(stream.get("width", 0)),
        "height": int(stream.get("height", 0)),
        "fps": rate,
        "duration_seconds": float(stream.get("duration", 0.0) or 0.0),
        "reported_frame_count": (
            int(stream["nb_frames"])
            if str(stream.get("nb_frames", "")).isdigit()
            else None
        ),
    }


def _extract_video_frames(
    video: Path,
    ffmpeg: str,
    frame_dir: Path,
    decode_fps: float,
) -> list[Path]:
    frame_dir.mkdir(parents=True, exist_ok=True)
    output_pattern = frame_dir / "frame_%06d.png"
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(video),
        "-vf",
        f"fps={decode_fps:g}",
        "-fps_mode",
        "vfr",
        "-start_number",
        "0",
        str(output_pattern),
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise PipelineError(f"ffmpeg frame extraction failed: {result.stderr.strip()}")
    paths = sorted(frame_dir.glob("frame_*.png"))
    if not paths:
        raise PipelineError("ffmpeg produced no frames")
    return paths


def _frame_paths_from_directory(source_dir: Path) -> list[Path]:
    patterns = ("*.png", "*.webp", "*.tif", "*.tiff")
    paths: list[Path] = []
    for pattern in patterns:
        paths.extend(source_dir.glob(pattern))
    paths = sorted(path for path in paths if path.is_file())
    if not paths:
        raise PipelineError(f"no frame images found in {source_dir}")
    return paths


def _parse_hex_color(value: str) -> tuple[int, int, int]:
    text = value.strip().lstrip("#")
    if len(text) != 6:
        raise PipelineError("--key-color must be a six-digit hex color such as 00ff00")
    try:
        return tuple(int(text[index : index + 2], 16) for index in (0, 2, 4))
    except ValueError as exc:
        raise PipelineError("--key-color contains non-hex digits") from exc


def _key_background(
    image: Image.Image,
    key_color: tuple[int, int, int] | None,
    tolerance: float,
    softness: float,
) -> Image.Image:
    rgba = image.convert("RGBA")
    if key_color is None:
        alpha = rgba.getchannel("A")
        if alpha.getextrema()[0] == 255:
            raise PipelineError(
                "opaque input requires --key-color; refusing to create an opaque sheet"
            )
        return rgba

    pixels = np.asarray(rgba, dtype=np.float32)
    key = np.asarray(key_color, dtype=np.float32)
    rgb = pixels[:, :, :3]
    distance = np.linalg.norm(rgb - key, axis=2)
    keep = np.clip((distance - tolerance) / max(softness, 0.001), 0.0, 1.0)
    source_alpha = pixels[:, :, 3] / 255.0
    combined_alpha = source_alpha * keep

    # Remove key-colored light that was mixed into antialiased boundary pixels.
    decontaminated = (
        rgb - key.reshape(1, 1, 3) * (1.0 - keep[:, :, None])
    ) / np.maximum(keep[:, :, None], 0.001)
    decontaminated = np.clip(decontaminated, 0.0, 255.0)

    # A compressed clip often leaves a one-pixel key-color spike on edges.
    # Primary chroma keys can be desaturated without touching opaque interior
    # colors, because the key channel never legitimately exceeds both others.
    for channel in range(3):
        others = [index for index in range(3) if index != channel]
        if key[channel] > max(key[others]) + 64.0:
            ceiling = np.maximum(
                decontaminated[:, :, others[0]],
                decontaminated[:, :, others[1]],
            )
            spill_zone = combined_alpha < 0.98
            decontaminated[:, :, channel] = np.where(
                spill_zone,
                np.minimum(decontaminated[:, :, channel], ceiling),
                decontaminated[:, :, channel],
            )

    decontaminated[combined_alpha <= 0.001] = 0.0

    output = np.empty_like(pixels, dtype=np.uint8)
    output[:, :, :3] = np.rint(decontaminated).astype(np.uint8)
    output[:, :, 3] = np.rint(combined_alpha * 255.0).astype(np.uint8)
    output[:, :, 3][output[:, :, 3] <= ALPHA_FLOOR] = 0
    cleaned = Image.fromarray(output, mode="RGBA")
    return cleaned


def _load_frames(
    paths: list[Path],
    decode_fps: float,
    key_color: tuple[int, int, int] | None,
    tolerance: float,
    softness: float,
) -> list[DecodedFrame]:
    frames: list[DecodedFrame] = []
    for index, path in enumerate(paths):
        with Image.open(path) as image:
            cleaned = _key_background(
                image.convert("RGBA"),
                key_color,
                tolerance,
                softness,
            )
        frames.append(
            DecodedFrame(
                index=index,
                seconds=float(index) / decode_fps,
                image=cleaned,
            )
        )
    return frames


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


def _core_mask(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("RGBA"))[:, :, 3] >= CORE_ALPHA


def _silhouette_delta(first: Image.Image, second: Image.Image) -> float:
    first_mask = _core_mask(first)
    second_mask = _core_mask(second)
    union = int(np.logical_or(first_mask, second_mask).sum())
    if union <= 0:
        return 0.0
    return float(np.logical_xor(first_mask, second_mask).sum()) / float(union)


def _feature_from_mask(mask: np.ndarray) -> dict[str, float]:
    bounds = _bbox_from_mask(mask)
    if bounds is None:
        return {
            "center_x": 0.0,
            "center_y": 0.0,
            "width": 0.0,
            "height": 0.0,
            "area_ratio": 0.0,
        }
    left, top, right, bottom = bounds
    image_area = max(1, int(mask.shape[1] * mask.shape[0]))
    return {
        "center_x": (left + right) * 0.5,
        "center_y": (top + bottom) * 0.5,
        "width": float(right - left),
        "height": float(bottom - top),
        "area_ratio": float((right - left) * (bottom - top)) / image_area,
    }


def _frame_feature(image: Image.Image) -> dict[str, float]:
    alpha = np.asarray(image.convert("RGBA"))[:, :, 3]
    return _feature_from_mask(alpha >= CROP_ALPHA)


def _scoring_mask(image: Image.Image, max_side: int = 128) -> np.ndarray:
    scale = min(1.0, float(max_side) / float(max(image.width, image.height)))
    if scale < 1.0:
        size = (
            max(1, int(round(image.width * scale))),
            max(1, int(round(image.height * scale))),
        )
        image = image.resize(size, Image.Resampling.BILINEAR)
    alpha = np.asarray(image.convert("RGBA"))[:, :, 3]
    return alpha >= CROP_ALPHA


def _mask_delta(first: np.ndarray, second: np.ndarray) -> float:
    union = int(np.logical_or(first, second).sum())
    if union <= 0:
        return 0.0
    return float(np.logical_xor(first, second).sum()) / float(union)


def _choose_window(
    frames: list[DecodedFrame],
    action: str,
    decode_fps: float,
    sample_fps: float,
    explicit_start: int | None,
) -> WindowChoice:
    stride = max(1, int(round(decode_fps / max(sample_fps, 0.1))))
    span = stride * (FRAME_COUNT - 1)
    if explicit_start is not None:
        start = explicit_start
        indices = [start + index * stride for index in range(FRAME_COUNT)]
        if start < 0 or indices[-1] >= len(frames):
            raise PipelineError(
                f"manual window {start}..{indices[-1]} exceeds "
                f"{len(frames) - 1} decoded frames"
            )
        selected = [frames[index] for index in indices]
        return WindowChoice(
            indices=indices,
            score=0.0,
            report={
                "mode": "manual",
                "start_index": start,
                "stride": stride,
                "why": "operator selected the action window",
                "features": [_frame_feature(frame.image) for frame in selected],
            },
        )

    if len(frames) < span + 1:
        raise PipelineError(
            f"clip has {len(frames)} decoded frames, but an 8-frame "
            f"{sample_fps:g} fps window needs {span + 1}; lower --decode-fps"
        )
    desired_min = MIN_MOTION_BY_ACTION[action]
    desired_max = MAX_MOTION_BY_ACTION[action]
    scoring_masks = [_scoring_mask(frame.image) for frame in frames]
    scoring_features = [
        _feature_from_mask(mask) for mask in scoring_masks
    ]
    best: tuple[float, int, list[int], list[dict[str, float]], list[float]] | None = None
    for start in range(0, len(frames) - span):
        indices = [start + index * stride for index in range(FRAME_COUNT)]
        features = [scoring_features[index] for index in indices]
        if any(feature["width"] <= 0.0 for feature in features):
            continue
        centers_x = np.asarray([feature["center_x"] for feature in features])
        centers_y = np.asarray([feature["center_y"] for feature in features])
        widths = np.asarray([feature["width"] for feature in features])
        heights = np.asarray([feature["height"] for feature in features])
        areas = np.asarray([feature["area_ratio"] for feature in features])
        frame_area = max(
            1,
            int(scoring_masks[0].shape[0] * scoring_masks[0].shape[1]),
        )
        center_scale = math.sqrt(frame_area)
        stability_score = (
            float(np.std(centers_x)) / center_scale * 8.0
            + float(np.std(centers_y)) / center_scale * 8.0
            + float(np.std(widths)) / center_scale * 3.0
            + float(np.std(heights)) / center_scale * 3.0
            + float(np.std(areas)) * 2.0
        )
        deltas = [
            _mask_delta(
                scoring_masks[indices[index]],
                scoring_masks[indices[index + 1]],
            )
            for index in range(FRAME_COUNT - 1)
        ]
        motion_mean = float(np.mean(deltas))
        motion_penalty = 0.0
        if motion_mean < desired_min:
            motion_penalty += (desired_min - motion_mean) * 40.0
        if motion_mean > desired_max:
            motion_penalty += (motion_mean - desired_max) * 8.0
        closure = _mask_delta(
            scoring_masks[indices[0]],
            scoring_masks[indices[-1]],
        )
        closure_penalty = 0.0
        if action in LOOP_ACTIONS:
            if closure < 0.005:
                closure_penalty += (0.005 - closure) * 20.0
            if closure > 0.20:
                closure_penalty += (closure - 0.20) * 20.0
        score = stability_score + motion_penalty + closure_penalty
        if best is None or score < best[0]:
            best = (score, start, indices, features, deltas)
    if best is None:
        raise PipelineError("no window with visible foreground was found")
    score, start, indices, features, deltas = best
    return WindowChoice(
        indices=indices,
        score=score,
        report={
            "mode": "auto",
            "start_index": start,
            "stride": stride,
            "why": (
                "lowest combined registration drift and motion-band penalty"
            ),
            "score": score,
            "adjacent_core_delta": deltas,
            "closure_delta": _mask_delta(
                scoring_masks[indices[0]],
                scoring_masks[indices[-1]],
            ),
            "features": features,
        },
    )


def _shared_crop_and_scale(
    frames: list[Image.Image],
    cell_size: int,
    padding: int,
) -> tuple[list[Image.Image], dict[str, Any]]:
    union: np.ndarray | None = None
    for frame in frames:
        mask = np.asarray(frame.convert("RGBA"))[:, :, 3] >= CROP_ALPHA
        union = mask if union is None else np.logical_or(union, mask)
    if union is None:
        raise PipelineError("selected frames are empty")
    bounds = _bbox_from_mask(union)
    if bounds is None:
        raise PipelineError("selected frames contain no thresholded foreground")
    left, top, right, bottom = bounds
    crop_padding = max(4, int(round(max(right - left, bottom - top) * 0.02)))
    left = max(0, left - crop_padding)
    top = max(0, top - crop_padding)
    right = min(frames[0].width, right + crop_padding)
    bottom = min(frames[0].height, bottom + crop_padding)
    crop = (left, top, right, bottom)
    crop_width = right - left
    crop_height = bottom - top
    inner_size = max(1, cell_size - padding * 2)
    scale = min(inner_size / crop_width, inner_size / crop_height)
    scaled_size = (
        max(1, int(round(crop_width * scale))),
        max(1, int(round(crop_height * scale))),
    )
    destination = (
        (cell_size - scaled_size[0]) // 2,
        (cell_size - scaled_size[1]) // 2,
    )
    cells: list[Image.Image] = []
    for frame in frames:
        cropped = frame.crop(crop)
        resized = cropped.resize(scaled_size, Image.Resampling.LANCZOS)
        cell = Image.new("RGBA", (cell_size, cell_size), (0, 0, 0, 0))
        cell.alpha_composite(resized, destination)
        cells.append(cell)
    return cells, {
        "mode": "union_bbox_of_all_selected_frames",
        "crop_px": [left, top, right, bottom],
        "crop_size": [crop_width, crop_height],
        "padding_px": padding,
        "scale": scale,
        "scaled_size": list(scaled_size),
        "destination_xy": list(destination),
        "shared_by_all_eight_frames": True,
        "per_frame_recentering": False,
        "per_frame_rescaling": False,
    }


def _compose_sheet(cells: list[Image.Image]) -> Image.Image:
    if len(cells) != FRAME_COUNT:
        raise PipelineError(f"expected {FRAME_COUNT} cells, got {len(cells)}")
    sheet = Image.new("RGBA", SOURCE_SHEET_SIZE, (0, 0, 0, 0))
    for index, cell in enumerate(cells):
        row, column = divmod(index, SOURCE_COLUMNS)
        sheet.alpha_composite(
            cell,
            (column * SOURCE_CELL_SIZE, row * SOURCE_CELL_SIZE),
        )
    return sheet


def _upper_lower_centroids(image: Image.Image) -> tuple[tuple[float, float], tuple[float, float]]:
    pixels = np.asarray(image.convert("RGBA"))
    alpha = pixels[:, :, 3]
    mask = alpha >= CORE_ALPHA
    row_sums = mask.sum(axis=1)
    low = int(image.height * 0.35)
    high = int(image.height * 0.65)
    empty_rows = [row for row in range(low, high) if row_sums[row] == 0]
    split = empty_rows[len(empty_rows) // 2] if empty_rows else image.height // 2
    result: list[tuple[float, float]] = []
    for start, end in ((0, split), (split, image.height)):
        local_mask = mask[start:end]
        ys, xs = np.nonzero(local_mask)
        if xs.size == 0:
            raise PipelineError("paired-registration check found an empty half")
        weights = alpha[start:end][local_mask].astype(np.float64)
        result.append(
            (
                float(np.average(xs, weights=weights)),
                float(np.average(ys + start, weights=weights)),
            )
        )
    return result[0], result[1]


def _pair_registration_report(cells: list[Image.Image]) -> dict[str, Any]:
    relative: list[tuple[float, float]] = []
    for cell in cells:
        upper, lower = _upper_lower_centroids(cell)
        relative.append((lower[0] - upper[0], lower[1] - upper[1]))
    values = np.asarray(relative, dtype=np.float64)
    ranges = np.ptp(values, axis=0)
    step_lengths = np.linalg.norm(np.diff(values, axis=0), axis=1)
    max_relative_range = SOURCE_CELL_SIZE * 0.008
    passed = bool(
        float(ranges[0]) <= max_relative_range
        and float(ranges[1]) <= max_relative_range
    )
    return {
        "status": "pass" if passed else "fail",
        "relative_offset_xy": [[float(x), float(y)] for x, y in relative],
        "relative_x_range_px": float(ranges[0]),
        "relative_y_range_px": float(ranges[1]),
        "max_adjacent_step_px": float(step_lengths.max(initial=0.0)),
        "allowed_relative_range_px": max_relative_range,
    }


def _motion_report(cells: list[Image.Image]) -> dict[str, Any]:
    adjacent = [
        _silhouette_delta(cells[index], cells[index + 1])
        for index in range(FRAME_COUNT - 1)
    ]
    key_pairs = ((0, 3), (0, 4), (2, 5), (3, 6), (4, 7))
    keyframes = [_silhouette_delta(cells[first], cells[second]) for first, second in key_pairs]
    return {
        "adjacent_delta": adjacent,
        "adjacent_mean": float(np.mean(adjacent)),
        "adjacent_min": float(np.min(adjacent)),
        "keyframe_delta": keyframes,
        "keyframe_mean": float(np.mean(keyframes)),
        "keyframe_min": float(np.min(keyframes)),
    }


def _selected_frames(
    frames: list[DecodedFrame],
    indices: list[int],
) -> list[Image.Image]:
    return [frames[index].image for index in indices]


def _validate_cells(
    cells: list[Image.Image],
    prototype: str,
    action: str,
) -> dict[str, Any]:
    reports: list[str] = []
    failures: list[str] = []
    motion = _motion_report(cells)
    desired_min = MIN_MOTION_BY_ACTION[action]
    if motion["adjacent_mean"] < desired_min:
        failures.append(
            f"adjacent mean {motion['adjacent_mean']:.4f} < {desired_min:.4f}"
        )
    if action == "idle" and motion["adjacent_mean"] > MAX_MOTION_BY_ACTION[action]:
        failures.append(
            f"idle adjacent mean {motion['adjacent_mean']:.4f} exceeds "
            f"{MAX_MOTION_BY_ACTION[action]:.4f}"
        )
    for index, cell in enumerate(cells):
        bounds = _bbox_from_mask(
            np.asarray(cell.convert("RGBA"))[:, :, 3] >= CROP_ALPHA
        )
        if bounds is None:
            failures.append(f"frame {index} has no foreground")
            continue
        left, top, right, bottom = bounds
        if min(left, top, SOURCE_CELL_SIZE - right, SOURCE_CELL_SIZE - bottom) < 10:
            failures.append(f"frame {index} has less than 10 px transparent margin")
    pair_lock = None
    if prototype == "artillery" and action == "idle":
        pair_lock = _pair_registration_report(cells)
        if pair_lock["status"] != "pass":
            failures.append(
                "artillery idle pair registration drift "
                f"x={pair_lock['relative_x_range_px']:.2f}px "
                f"y={pair_lock['relative_y_range_px']:.2f}px"
            )
    if failures:
        reports.extend(failures)
    return {
        "status": "fail" if failures else "pass",
        "failures": failures,
        "motion": motion,
        "pair_registration": pair_lock,
    }


def _build_report(
    args: argparse.Namespace,
    input_path: Path,
    ffmpeg: str,
    ffprobe: str,
    decode_fps: float,
    probe: dict[str, Any],
    decoded_count: int,
    window: WindowChoice,
    frames: list[DecodedFrame],
    shared: dict[str, Any],
    qc: dict[str, Any],
    sheet_path: Path,
) -> dict[str, Any]:
    selected = [frames[index] for index in window.indices]
    return {
        "schema": 1,
        "pipeline": (
            "fixed-camera model video/frame sequence -> stable window -> "
            "one shared crop/scale -> 4x2 source sheet -> v4 atlas builder"
        ),
        "prototype": args.prototype,
        "action": args.action,
        "input": {
            "path": str(input_path.resolve()),
            "kind": args.kind,
            "sha256": _sha256(input_path) if input_path.is_file() else None,
            "decode_fps": decode_fps,
            "decoded_frame_count": decoded_count,
            "probe": probe,
        },
        "tools": {
            "ffmpeg": ffmpeg,
            "ffprobe": ffprobe,
        },
        "background": {
            "key_color": args.key_color,
            "tolerance": args.key_tolerance,
            "softness": args.key_softness,
            "alpha_floor": ALPHA_FLOOR,
        },
        "window": {
            **window.report,
            "indices": window.indices,
            "seconds": [selected_frame.seconds for selected_frame in selected],
        },
        "registration": shared,
        "qc": qc,
        "output": {
            "path": _display_path(sheet_path),
            "width": SOURCE_SHEET_SIZE[0],
            "height": SOURCE_SHEET_SIZE[1],
            "mode": "RGBA",
            "columns": SOURCE_COLUMNS,
            "rows": SOURCE_ROWS,
            "frame_count": FRAME_COUNT,
            "cell_size": SOURCE_CELL_SIZE,
            "sha256": _sha256(sheet_path),
        },
    }


def _discover_kind(path: Path) -> str:
    if path.is_dir():
        return "frames_dir"
    if path.is_file():
        return "video"
    raise PipelineError(f"input does not exist: {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prototype", choices=PROTOTYPES, required=True)
    parser.add_argument("--action", choices=ACTIONS, required=True)
    parser.add_argument(
        "--input",
        type=Path,
        required=True,
        help="Video file or directory of prepared RGBA frame images.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output source sheet; defaults to source/v4/video_selected.",
    )
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--ffmpeg", default="")
    parser.add_argument("--ffprobe", default="")
    parser.add_argument("--decode-fps", type=float, default=24.0)
    parser.add_argument("--sample-fps", type=float, default=8.0)
    parser.add_argument(
        "--start-frame",
        type=int,
        default=None,
        help="Manual decoded-frame start. Omit to auto-select a stable window.",
    )
    parser.add_argument("--key-color", default="")
    parser.add_argument(
        "--key-tolerance",
        type=float,
        default=DEFAULT_KEY_TOLERANCE,
    )
    parser.add_argument(
        "--key-softness",
        type=float,
        default=DEFAULT_KEY_SOFTNESS,
    )
    parser.add_argument(
        "--sheet-padding",
        type=int,
        default=DEFAULT_SHEET_PADDING,
    )
    parser.add_argument(
        "--allow-qc-failures",
        action="store_true",
        help="Write the sheet/report even when motion or pair-lock QC fails.",
    )
    args = parser.parse_args()

    if args.decode_fps <= 0 or args.sample_fps <= 0:
        raise PipelineError("--decode-fps and --sample-fps must be positive")
    if args.sheet_padding < 0 or args.sheet_padding * 2 >= SOURCE_CELL_SIZE:
        raise PipelineError("--sheet-padding leaves no usable cell area")

    input_path = args.input.resolve()
    kind = _discover_kind(input_path)
    args.kind = kind
    output = (
        args.output.resolve()
        if args.output is not None
        else (
            DEFAULT_SOURCE_DIR
            / f"{args.prototype}_{args.action}.png"
        ).resolve()
    )
    report_path = (
        args.report.resolve()
        if args.report is not None
        else output.with_suffix(".video_report.json")
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    key_color = _parse_hex_color(args.key_color) if args.key_color else None
    ffmpeg = ""
    ffprobe = ""
    probe: dict[str, Any] = {}
    with tempfile.TemporaryDirectory(prefix="pk_formation_video_") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        if kind == "video":
            ffmpeg = _resolve_ffmpeg(args.ffmpeg)
            ffprobe = _resolve_ffprobe(ffmpeg, args.ffprobe)
            probe = _probe_video(input_path, ffprobe)
            source_paths = _extract_video_frames(
                input_path,
                ffmpeg,
                temp_dir / "decoded",
                args.decode_fps,
            )
        else:
            source_paths = _frame_paths_from_directory(input_path)
            source_fps = args.decode_fps
            probe = {
                "fps": source_fps,
                "reported_frame_count": len(source_paths),
            }

        decoded = _load_frames(
            source_paths,
            args.decode_fps,
            key_color,
            args.key_tolerance,
            args.key_softness,
        )
        window = _choose_window(
            decoded,
            args.action,
            args.decode_fps,
            args.sample_fps,
            args.start_frame,
        )
        selected_images = _selected_frames(decoded, window.indices)
        cells, shared = _shared_crop_and_scale(
            selected_images,
            SOURCE_CELL_SIZE,
            args.sheet_padding,
        )
        qc = _validate_cells(cells, args.prototype, args.action)
        sheet = _compose_sheet(cells)
        sheet.save(output, format="PNG", optimize=True)

    report = _build_report(
        args,
        input_path,
        ffmpeg,
        ffprobe,
        args.decode_fps,
        probe,
        len(decoded),
        window,
        decoded,
        shared,
        qc,
        output,
    )
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "output": _display_path(output),
                "report": _display_path(report_path),
                "window": window.indices,
                "qc": qc["status"],
                "motion_mean": qc["motion"]["adjacent_mean"],
                "pair_lock": (
                    qc["pair_registration"]["status"]
                    if qc["pair_registration"]
                    else None
                ),
            },
            ensure_ascii=False,
        )
    )
    if qc["status"] != "pass" and not args.allow_qc_failures:
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PipelineError as exc:
        print(f"formation_video_pipeline: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
