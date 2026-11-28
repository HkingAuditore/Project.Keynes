"""Bake periodic height, UV derivatives and filaments for the valley fog shader."""

import math
from pathlib import Path
import struct
import zlib


SIZE = 128
SLOPE_RANGE = 16.0  # WX_VALLEY_FOG_NOISE_SLOPE_RANGE in valley_fog.gdshaderinc
HEIGHT_WAVES = (
    (2, 1, 0.105, 0.4),
    (1, -3, 0.085, 1.7),
    (4, 2, 0.063, 3.8),
    (3, -5, 0.050, 0.7),
    (7, 3, 0.033, 5.2),
    (2, 6, 0.027, 2.1),
)
FILAMENT_WAVES = (
    (3, 11, 0.125, 4.2),
    (7, -13, 0.120, 0.6),
    (4, 17, 0.082, 5.1),
    (9, -14, 0.061, 1.3),
    (5, 19, 0.045, 3.8),
)


def sample(u, v):
    height = filament = 0.5
    slope_u = slope_v = 0.0
    for kx, ky, amplitude, phase in HEIGHT_WAVES:
        angle = math.tau * (kx * u + ky * v) + phase
        height += amplitude * math.sin(angle)
        derivative = math.tau * amplitude * math.cos(angle)
        slope_u += derivative * kx
        slope_v += derivative * ky
    for kx, ky, amplitude, phase in FILAMENT_WAVES:
        filament += amplitude * math.sin(math.tau * (kx * u + ky * v) + phase)
    return height, 0.5 + slope_u / (2 * SLOPE_RANGE), 0.5 + slope_v / (2 * SLOPE_RANGE), filament


def png_chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload)))


def main():
    image = bytearray()
    for y in range(SIZE):
        image.append(0)  # PNG scanline filter: None.
        for x in range(SIZE):
            channels = sample((x + 0.5) / SIZE, (y + 0.5) / SIZE)
            image.extend(round(255 * max(0.0, min(1.0, channel))) for channel in channels)

    target = (Path(__file__).resolve().parents[2] / "Project/project-keynes"
              / "assets/textures/weather/valley_fog_noise.png")
    target.parent.mkdir(exist_ok=True)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    target.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                       + png_chunk(b"IDAT", zlib.compress(image, 9)) + png_chunk(b"IEND", b""))


if __name__ == "__main__":
    main()
