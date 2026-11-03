"""Audit military papercut cells for clipped artwork and detached fragments."""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[2]
ATLAS = ROOT / "assets/military/papercut/military_atlas_v1.png"
REGIONS = ROOT / "assets/military/papercut/regions.json"
OUT = ROOT.parents[1] / "artifacts/military-papercut-qa"
SOURCE_MANIFEST = ROOT / "assets/military/papercut/source-manifest.json"


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in (Path("C:/Windows/Fonts/consola.ttf"), Path("C:/Windows/Fonts/segoeui.ttf")):
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _checkerboard(size: int, step: int = 16) -> Image.Image:
    image = Image.new("RGB", (size, size), (226, 220, 208))
    draw = ImageDraw.Draw(image)
    for y in range(0, size, step):
        for x in range(0, size, step):
            if (x // step + y // step) % 2:
                draw.rectangle((x, y, x + step - 1, y + step - 1), fill=(197, 191, 179))
    return image


def _source_findings() -> list[dict]:
    manifest = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    findings = []
    for sheet in manifest["sheets"]:
        image = Image.open(ROOT / "assets/military/papercut" / sheet["file"]).convert("RGBA")
        for semantic, (x, y, w, h) in sorted(sheet["cells"].items()):
            alpha = np.asarray(image.crop((x, y, x + w, y + h)).getchannel("A")) > 16
            labels, count = ndimage.label(alpha, structure=np.ones((3, 3), dtype=bool))
            if count == 0:
                findings.append({"key": semantic, "reason": "empty source cell"})
                continue
            sizes = ndimage.sum(alpha, labels, range(1, count + 1))
            largest_index = int(np.argmax(sizes)) + 1
            ys, xs = np.nonzero(labels == largest_index)
            if xs.min() <= 1 or ys.min() <= 1 or xs.max() >= w - 2 or ys.max() >= h - 2:
                findings.append(
                    {
                        "key": semantic,
                        "reason": "largest source component touches detected cell edge",
                        "bounds": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())],
                        "cell": [x, y, w, h],
                    }
                )
    return findings


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    atlas = Image.open(ATLAS).convert("RGBA")
    regions = json.loads(REGIONS.read_text(encoding="utf-8"))
    keys = sorted(regions)
    cols, tile = 5, 300
    rows = math.ceil(len(keys) / cols)
    sheet = Image.new("RGB", (cols * tile, rows * tile), (240, 234, 221))
    draw = ImageDraw.Draw(sheet)
    label_font = _font(13)
    findings = []
    for index, key in enumerate(keys):
        x, y, w, h = regions[key]
        crop = atlas.crop((x, y, x + w, y + h))
        alpha = np.asarray(crop.getchannel("A")) > 16
        edge_pixels = int(
            alpha[0, :].sum()
            + alpha[-1, :].sum()
            + alpha[:, 0].sum()
            + alpha[:, -1].sum()
        )
        labels, count = ndimage.label(alpha, structure=np.ones((3, 3), dtype=bool))
        sizes = ndimage.sum(alpha, labels, range(1, count + 1)) if count else np.array([])
        significant = int((sizes > 120).sum()) if count else 0
        board = _checkerboard(270)
        icon = crop.resize((256, 256), Image.Resampling.LANCZOS)
        board.paste(icon, (7, 7), icon)
        bx, by = (index % cols) * tile, (index // cols) * tile
        sheet.paste(board, (bx + 15, by + 8))
        color = (46, 36, 27)
        if edge_pixels:
            color = (170, 38, 32)
            findings.append(
                {
                    "key": key,
                    "edge_pixels": edge_pixels,
                    "components": int(count),
                    "significant_components": significant,
                }
            )
        draw.text((bx + 17, by + 276), f"{index + 1:02d} {key}", fill=color, font=label_font)
    sheet.save(OUT / "military_runtime-crops.png")
    source_findings = _source_findings()
    report = {
        "icons": len(keys),
        "runtime_edge_findings": len(findings),
        "source_boundary_warnings": len(source_findings),
        "runtime_findings": findings,
        "source_warnings": source_findings,
    }
    (OUT / "military-audit.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
