"""Rasterize author hints into elevation/moisture/lake-seed fields.

Aligns lake geometry with post_base defaults:
hydro_lake_min_depth=0.018, hydro_lake_min_cells=8, hydro_lake_min_volume=0.22
"""

from __future__ import annotations

import math
from typing import Any

from .errors import AuthoringError
from .hexgeom import neighbors, index_of, col_row_of

HYDRO_LAKE_MIN_DEPTH = 0.018
HYDRO_LAKE_MIN_CELLS = 8
HYDRO_LAKE_MIN_VOLUME = 0.22
LAND_RATIO_MIN = 0.18
LAND_RATIO_MAX = 0.72
WRAP_SEAM_MAX_DELTA = 0.18
WRAP_SEAM_FAIL_ROWS = 3


def _as_float_list(values: Any, n: int, field: str) -> list[float]:
    if not isinstance(values, (list, tuple)):
        raise AuthoringError("size_mismatch", "%s must be a list of length %d" % (field, n))
    if len(values) != n:
        raise AuthoringError("size_mismatch", "%s length %d != %d" % (field, len(values), n))
    out: list[float] = []
    for i, v in enumerate(values):
        try:
            fv = float(v)
        except (TypeError, ValueError) as exc:
            raise AuthoringError("nan_elevation", "%s[%d] is not a number" % (field, i)) from exc
        if not math.isfinite(fv):
            raise AuthoringError("nan_elevation", "%s[%d] is not finite" % (field, i))
        out.append(fv)
    return out


def _clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else 1.0 if v > 1.0 else v


def _default_moisture(elevation: list[float], width: int, height: int, sea_level: float) -> list[float]:
    n = width * height
    moisture = [0.0] * n
    for i in range(n):
        col, row = col_row_of(i, width)
        lat = 1.0 - abs((row / max(height - 1, 1)) * 2.0 - 1.0)
        if elevation[i] < sea_level:
            moisture[i] = 0.92
            continue
        dist_sea = 8
        q = min(8, width // 2)
        for d in range(1, q + 1):
            west = elevation[index_of((col - d) % width, row, width)]
            east = elevation[index_of((col + d) % width, row, width)]
            if west < sea_level or east < sea_level:
                dist_sea = d
                break
            if row - d >= 0 and elevation[index_of(col, row - d, width)] < sea_level:
                dist_sea = d
                break
            if row + d < height and elevation[index_of(col, row + d, width)] < sea_level:
                dist_sea = d
                break
        coast = 1.0 - (dist_sea / 8.0)
        moisture[i] = _clamp01(0.28 + 0.42 * coast + 0.18 * lat)
    return moisture


def _path_has_ocean_outlet(
    cells: list[tuple[int, int]],
    elevation: list[float],
    width: int,
    height: int,
    sea_level: float,
) -> bool:
    if not cells:
        return False
    last = cells[-1]
    if last[1] < 0 or last[1] >= height:
        return False
    last_i = index_of(last[0] % width, last[1], width)
    if elevation[last_i] < sea_level:
        return True
    for ni in neighbors(last_i, width, height):
        if elevation[ni] < sea_level:
            return True
    return False


def _carve_rivers(
    elevation: list[float],
    hints: dict,
    width: int,
    height: int,
    sea_level: float,
) -> None:
    rivers = hints.get("carve_rivers") or []
    if not isinstance(rivers, list):
        raise AuthoringError("size_mismatch", "hints.carve_rivers must be a list")
    for river in rivers:
        if not isinstance(river, dict):
            continue
        raw_cells = river.get("cells") or []
        depth = float(river.get("depth", 0.04))
        river_width = max(1, int(river.get("width", 1)))
        cells: list[tuple[int, int]] = []
        for pair in raw_cells:
            if not isinstance(pair, (list, tuple)) or len(pair) < 2:
                continue
            col = int(pair[0]) % width
            row = int(pair[1])
            if 0 <= row < height:
                cells.append((col, row))
        if not cells:
            continue
        for col, row in cells:
            i = index_of(col, row, width)
            fall = max(0.0, elevation[i] - (sea_level + 0.012))
            elevation[i] = max(sea_level + 0.008, elevation[i] - min(depth, fall))
            if river_width <= 1:
                continue
            for ni in neighbors(i, width, height):
                if elevation[ni] < sea_level:
                    continue
                fall_n = max(0.0, elevation[ni] - (sea_level + 0.012))
                elevation[ni] = max(sea_level + 0.008, elevation[ni] - min(depth * 0.45, fall_n))
        if not _path_has_ocean_outlet(cells, elevation, width, height, sea_level):
            raise AuthoringError("river_no_outlet", "carve_rivers path has no ocean outlet")


def _carve_lakes(
    elevation: list[float],
    hints: dict,
    width: int,
    height: int,
    sea_level: float,
) -> list[int]:
    lakes = hints.get("lake_basins") or []
    if not isinstance(lakes, list):
        raise AuthoringError("size_mismatch", "hints.lake_basins must be a list")
    n = width * height
    seeds = [0] * n
    for basin in lakes:
        if not isinstance(basin, dict):
            continue
        raw_cells = basin.get("cells") or []
        depth = max(float(basin.get("depth", 0.08)), HYDRO_LAKE_MIN_DEPTH)
        cells: list[int] = []
        for pair in raw_cells:
            if not isinstance(pair, (list, tuple)) or len(pair) < 2:
                continue
            col = int(pair[0]) % width
            row = int(pair[1])
            if 0 <= row < height:
                cells.append(index_of(col, row, width))
        unique = sorted(set(cells))
        if len(unique) < HYDRO_LAKE_MIN_CELLS:
            raise AuthoringError(
                "lake_too_small",
                "lake_basins needs at least %d cells (got %d)" % (HYDRO_LAKE_MIN_CELLS, len(unique)),
            )
        rim = sea_level + 0.04
        for i in unique:
            if elevation[i] < sea_level:
                continue
            elevation[i] = max(sea_level + 0.004, min(elevation[i], rim) - depth)
            seeds[i] = 1
        volume = 0.0
        for i in unique:
            volume += max(0.0, (rim - elevation[i]))
        if volume < HYDRO_LAKE_MIN_VOLUME:
            extra = (HYDRO_LAKE_MIN_VOLUME - volume) / max(len(unique), 1)
            for i in unique:
                elevation[i] = max(sea_level + 0.004, elevation[i] - extra)
    return seeds


def _mix_paint(base: list[float], paint: Any, mix: float, n: int, field: str) -> list[float]:
    if paint is None:
        return base
    values = _as_float_list(paint, n, field)
    t = _clamp01(float(mix))
    return [_clamp01(base[i] * (1.0 - t) + values[i] * t) for i in range(n)]


def _highland_paint(elevation: list[float], hints: dict, width: int, height: int, sea_level: float) -> None:
    paint = hints.get("highland_paint")
    if not paint:
        return
    if not isinstance(paint, dict):
        raise AuthoringError("size_mismatch", "hints.highland_paint must be an object")
    n = width * height
    values = _as_float_list(paint.get("values"), n, "highland_paint.values")
    mix = _clamp01(float(paint.get("mix", 0.4)))
    peak = 0.93
    for i in range(n):
        if elevation[i] < sea_level:
            continue
        target = sea_level + _clamp01(values[i]) * (peak - sea_level)
        elevation[i] = _clamp01(elevation[i] * (1.0 - mix) + target * mix)


def _validate_fields(elevation: list[float], width: int, height: int, sea_level: float) -> None:
    n = width * height
    land = 0
    cliff_rows = 0
    for row in range(height):
        a = elevation[index_of(0, row, width)]
        b = elevation[index_of(width - 1, row, width)]
        if abs(a - b) > WRAP_SEAM_MAX_DELTA:
            cliff_rows += 1
        for col in range(width):
            if elevation[index_of(col, row, width)] >= sea_level:
                land += 1
    if cliff_rows >= WRAP_SEAM_FAIL_ROWS:
        raise AuthoringError("wrap_seam_cliff", "east-west seam cliff on %d rows" % cliff_rows)
    ratio = land / float(max(n, 1))
    if ratio < LAND_RATIO_MIN or ratio > LAND_RATIO_MAX:
        raise AuthoringError(
            "land_ratio_out_of_range",
            "land ratio %.3f outside [%.2f, %.2f]" % (ratio, LAND_RATIO_MIN, LAND_RATIO_MAX),
        )


def compile_hints(author: dict, width: int, height: int, seed: int, sea_level: float) -> dict:
    n = width * height
    elevation = _as_float_list(author.get("elevation"), n, "elevation")
    for i in range(n):
        elevation[i] = _clamp01(elevation[i])
    author_sea = author.get("sea_level", sea_level)
    try:
        sea_level = float(author_sea)
    except (TypeError, ValueError) as exc:
        raise AuthoringError("nan_elevation", "sea_level is not a number") from exc
    hints = author.get("hints") or {}
    if not isinstance(hints, dict):
        raise AuthoringError("size_mismatch", "hints must be an object")
    _highland_paint(elevation, hints, width, height, sea_level)
    lake_seeds = _carve_lakes(elevation, hints, width, height, sea_level)
    _carve_rivers(elevation, hints, width, height, sea_level)
    moisture = _default_moisture(elevation, width, height, sea_level)
    mpaint = hints.get("moisture_paint")
    if mpaint:
        if not isinstance(mpaint, dict):
            raise AuthoringError("size_mismatch", "hints.moisture_paint must be an object")
        moisture = _mix_paint(
            moisture,
            mpaint.get("values"),
            float(mpaint.get("mix", 0.5)),
            n,
            "moisture_paint.values",
        )
    _validate_fields(elevation, width, height, sea_level)
    return {
        "width": width,
        "height": height,
        "seed": seed,
        "sea_level": sea_level,
        "elevation": elevation,
        "moisture": moisture,
        "is_lake_seed": lake_seeds,
    }
