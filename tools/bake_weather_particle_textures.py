#!/usr/bin/env python3
"""Bake weather particle textures to PNG.

Reproduces the pixel algorithm from
`weather_layer.gd::_build_rain_drop_texture` and `::_build_snow_flake_texture`
so the runtime code generators can be retired. Uses only the Python stdlib
(zlib + struct), no Pillow dependency.

Run once:
    python tools/bake_weather_particle_textures.py

Output:
    Project/project-keynes/textures/weather/rain_drop.png   (4x16 RGBA8)
    Project/project-keynes/textures/weather/snow_flake.png  (8x8  RGBA8)
"""

from __future__ import annotations

import math
import os
import struct
import zlib
from pathlib import Path


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    """Write an 8-bit RGBA PNG. `pixels` must be width*height*4 bytes."""
    assert len(pixels) == width * height * 4

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    sig = b"\x89PNG\r\n\x1a\n"
    # IHDR: bit depth 8, color type 6 (RGBA), no interlace
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)

    # Build raw stream with filter byte (0 = None) at each scanline.
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * stride : (y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)

    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def bake_rain_drop() -> tuple[int, int, bytes]:
    """Mirror of weather_layer.gd::_build_rain_drop_texture.

    4x16 vertical gradient: transparent top -> opaque bottom, with a soft
    horizontal falloff so the drop reads as a thin pill rather than a square.
    """
    w, h = 4, 16
    out = bytearray()
    for y in range(h):
        ay = y / (h - 1)
        a_y = pow(ay, 1.4)
        for x in range(w):
            ax = abs(float(x) - (w - 1) * 0.5) / ((w - 1) * 0.5)
            a_x = 1.0 - ax * ax
            a = max(0.0, min(1.0, a_y * a_x))
            ai = int(a * 255.0 + 0.5)
            out.extend((255, 255, 255, ai))
    return w, h, bytes(out)


def bake_snow_flake() -> tuple[int, int, bytes]:
    """Mirror of weather_layer.gd::_build_snow_flake_texture.

    8x8 radial white disc with soft alpha falloff (pow 1.5).
    """
    size = 8
    center = (size - 1) * 0.5
    inv_r = 1.0 / (size * 0.5)
    out = bytearray()
    for y in range(size):
        for x in range(size):
            dx = float(x) - center
            dy = float(y) - center
            d = math.sqrt(dx * dx + dy * dy) * inv_r
            a = max(0.0, min(1.0, 1.0 - d))
            a = pow(a, 1.5)
            ai = int(a * 255.0 + 0.5)
            out.extend((255, 255, 255, ai))
    return size, size, bytes(out)


def main() -> None:
    here = Path(__file__).resolve().parent
    project_root = here.parent
    out_dir = project_root / "Project" / "project-keynes" / "textures" / "weather"
    out_dir.mkdir(parents=True, exist_ok=True)

    rw, rh, rpx = bake_rain_drop()
    write_png(out_dir / "rain_drop.png", rw, rh, rpx)
    print(f"wrote {out_dir / 'rain_drop.png'} ({rw}x{rh})")

    sw, sh, spx = bake_snow_flake()
    write_png(out_dir / "snow_flake.png", sw, sh, spx)
    print(f"wrote {out_dir / 'snow_flake.png'} ({sw}x{sh})")


if __name__ == "__main__":
    main()
