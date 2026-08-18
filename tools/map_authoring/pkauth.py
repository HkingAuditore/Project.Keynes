"""PKAUTH v1: magic + JSON header + little-endian elevation/moisture/lake-seed arrays."""

from __future__ import annotations

import json
import struct
from pathlib import Path
from typing import Any

from .errors import AuthoringError

MAGIC = b"PKAU"
FORMAT_VERSION = 1


def write_pkauth(path: str | Path, compiled: dict) -> Path:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    width = int(compiled["width"])
    height = int(compiled["height"])
    n = width * height
    elevation = compiled["elevation"]
    moisture = compiled["moisture"]
    seeds = compiled.get("is_lake_seed") or [0] * n
    if len(elevation) != n or len(moisture) != n or len(seeds) != n:
        raise AuthoringError("size_mismatch", "pkauth array length != width*height")
    header = {
        "magic": "PKAU",
        "format_version": FORMAT_VERSION,
        "width": width,
        "height": height,
        "n_cells": n,
        "sea_level": float(compiled["sea_level"]),
        "seed": int(compiled["seed"]),
        "arrays": ["elevation", "moisture", "is_lake_seed"],
    }
    header_b = json.dumps(header, separators=(",", ":")).encode("utf-8")
    with out.open("wb") as fh:
        fh.write(MAGIC)
        fh.write(struct.pack("<I", FORMAT_VERSION))
        fh.write(struct.pack("<I", len(header_b)))
        fh.write(header_b)
        fh.write(struct.pack("<%df" % n, *[float(v) for v in elevation]))
        fh.write(struct.pack("<%df" % n, *[float(v) for v in moisture]))
        fh.write(struct.pack("<%dB" % n, *[1 if int(v) else 0 for v in seeds]))
    return out


def read_pkauth(path: str | Path) -> dict[str, Any]:
    data = Path(path).read_bytes()
    if len(data) < 12 or data[:4] != MAGIC:
        raise AuthoringError("pkauth_header_invalid", "PKAUTH magic missing")
    version, header_len = struct.unpack_from("<II", data, 4)
    if version != FORMAT_VERSION or header_len <= 0:
        raise AuthoringError("pkauth_header_invalid", "PKAUTH version/header invalid")
    start = 12
    end = start + header_len
    if end > len(data):
        raise AuthoringError("pkauth_truncated", "PKAUTH header truncated")
    header = json.loads(data[start:end].decode("utf-8"))
    width = int(header["width"])
    height = int(header["height"])
    n = width * height
    if int(header.get("n_cells", n)) != n:
        raise AuthoringError("size_mismatch", "PKAUTH n_cells != width*height")
    body = data[end:]
    need = n * 4 + n * 4 + n
    if len(body) < need:
        raise AuthoringError("pkauth_truncated", "PKAUTH payload truncated")
    elev = list(struct.unpack_from("<%df" % n, body, 0))
    moist = list(struct.unpack_from("<%df" % n, body, n * 4))
    seeds = list(struct.unpack_from("<%dB" % n, body, n * 8))
    return {
        "width": width,
        "height": height,
        "n_cells": n,
        "sea_level": float(header["sea_level"]),
        "seed": int(header["seed"]),
        "elevation": elev,
        "moisture": moist,
        "is_lake_seed": seeds,
        "header": header,
    }
