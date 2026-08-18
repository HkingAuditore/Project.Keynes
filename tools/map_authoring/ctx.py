"""Authoring context exposed to sandboxed generate(ctx) scripts."""

from __future__ import annotations

import math
from typing import Iterator

from .hexgeom import index_of


def _clamp(value: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return lo if value < lo else hi if value > hi else value


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * _clamp(t, 0.0, 1.0)


def _smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge0 == edge1:
        return 1.0 if x >= edge1 else 0.0
    t = _clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _hash01(ix: int, iy: int, iz: int, seed: int) -> float:
    n = (ix * 374761393 + iy * 668265263 + iz * 2146121005 + seed * 1013904223) & 0xFFFFFFFF
    n ^= n >> 13
    n = (n * 1274126177) & 0xFFFFFFFF
    return (n & 0xFFFFFF) / 16777215.0


def _value_noise(x: float, y: float, z: float, seed: int) -> float:
    x0 = math.floor(x)
    y0 = math.floor(y)
    z0 = math.floor(z)
    tx = x - x0
    ty = y - y0
    tz = z - z0
    tx = tx * tx * (3.0 - 2.0 * tx)
    ty = ty * ty * (3.0 - 2.0 * ty)
    tz = tz * tz * (3.0 - 2.0 * tz)
    ix0 = int(x0)
    iy0 = int(y0)
    iz0 = int(z0)
    c000 = _hash01(ix0, iy0, iz0, seed)
    c100 = _hash01(ix0 + 1, iy0, iz0, seed)
    c010 = _hash01(ix0, iy0 + 1, iz0, seed)
    c110 = _hash01(ix0 + 1, iy0 + 1, iz0, seed)
    c001 = _hash01(ix0, iy0, iz0 + 1, seed)
    c101 = _hash01(ix0 + 1, iy0, iz0 + 1, seed)
    c011 = _hash01(ix0, iy0 + 1, iz0 + 1, seed)
    c111 = _hash01(ix0 + 1, iy0 + 1, iz0 + 1, seed)
    c00 = _lerp(c000, c100, tx)
    c10 = _lerp(c010, c110, tx)
    c01 = _lerp(c001, c101, tx)
    c11 = _lerp(c011, c111, tx)
    c0 = _lerp(c00, c10, ty)
    c1 = _lerp(c01, c11, ty)
    return _lerp(c0, c1, tz) * 2.0 - 1.0


class AuthoringContext:
    """Whitelist API for AI-authored maps. Coordinates match C++ index_for_qr."""

    def __init__(self, width: int, height: int, seed: int, sea_level: float) -> None:
        self.width = int(width)
        self.height = int(height)
        self.seed = int(seed)
        self.sea_level = float(sea_level)

    def index(self, col: int, row: int) -> int:
        return index_of(int(col), int(row), self.width)

    def nx(self, col: int) -> float:
        return float(col) / float(self.width)

    def ny(self, row: int) -> float:
        denom = max(self.height - 1, 1)
        return float(row) / float(denom)

    def cells(self) -> Iterator[tuple[int, int, int]]:
        i = 0
        for row in range(self.height):
            for col in range(self.width):
                yield row, col, i
                i += 1

    def clamp(self, value: float, lo: float = 0.0, hi: float = 1.0) -> float:
        return _clamp(float(value), float(lo), float(hi))

    def lerp(self, a: float, b: float, t: float) -> float:
        return _lerp(float(a), float(b), float(t))

    def smoothstep(self, edge0: float, edge1: float, x: float) -> float:
        return _smoothstep(float(edge0), float(edge1), float(x))

    def cyl_dist(self, nx0: float, ny0: float, nx1: float, ny1: float) -> float:
        dx = abs(float(nx0) - float(nx1))
        dx = min(dx, 1.0 - dx)
        dy = float(ny0) - float(ny1)
        return math.sqrt(dx * dx + dy * dy)

    def _cyl_sample(self, col: float, row: float, seed: int, freq: float) -> float:
        ang = 2.0 * math.pi * (float(col) / float(self.width))
        ny = float(row) / float(max(self.height - 1, 1))
        f = max(float(freq), 0.01)
        return _value_noise(math.cos(ang) * f, math.sin(ang) * f, ny * f, seed)

    def fbm(self, col: float, row: float, seed: int = 0, freq: float = 2.0, octaves: int = 4) -> float:
        amp = 1.0
        total = 0.0
        norm = 0.0
        f = max(float(freq), 0.01)
        s = int(seed) + self.seed * 131
        for _ in range(max(1, int(octaves))):
            total += self._cyl_sample(col, row, s, f) * amp
            norm += amp
            f *= 2.0
            amp *= 0.5
            s += 17
        return total / max(norm, 1e-6)

    def ridged(self, col: float, row: float, seed: int = 0, freq: float = 2.0, octaves: int = 4) -> float:
        n = self.fbm(col, row, seed, freq, octaves)
        return 1.0 - abs(n)
