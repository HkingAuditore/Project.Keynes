"""Render runtime icon crops and flag suspicious atlas slices for visual review."""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Project/project-keynes/assets/icons/paper"
OUT = ROOT / "artifacts/paper-icons/qa-crops"


def split_edges(profile: list[int], count: int) -> list[int]:
    """Mirror build_paper_icon_atlases.py so this audit measures runtime cells."""
    length = len(profile)
    edges = [0]
    for i in range(1, count):
        expected = i * length / count
        span = length / count * 0.24
        start = max(1, round(expected - span))
        stop = min(length - 1, round(expected + span))
        candidates = range(start, stop)
        edge = min(
            candidates,
            key=lambda j: sum(profile[max(0, j - 2) : j + 3])
            + abs(j - expected) * 0.015,
        )
        edges.append(edge)
    return edges + [length]


def checkerboard(width: int, height: int, cell: int = 16) -> Image.Image:
    image = Image.new("RGBA", (width, height), (225, 219, 207, 255))
    draw = ImageDraw.Draw(image)
    for y in range(0, height, cell):
        for x in range(0, width, cell):
            if (x // cell + y // cell) % 2:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(197, 191, 179, 255))
    return image


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in (
        Path("C:/Windows/Fonts/consola.ttf"),
        Path("C:/Windows/Fonts/segoeui.ttf"),
    ):
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def contact_sheet(sheet: dict, image: Image.Image) -> Image.Image:
    keys = sheet["semantics"]
    cols = 6 if len(keys) > 16 else 4
    rows = math.ceil(len(keys) / cols)
    tile_w, tile_h = 230, 235
    canvas = Image.new("RGB", (cols * tile_w, rows * tile_h), (239, 233, 220))
    draw = ImageDraw.Draw(canvas)
    label_font = font(14)
    for index, key in enumerate(keys):
        region = sheet["regions"][key]
        crop = image.crop(
            (region[0], region[1], region[0] + region[2], region[1] + region[3])
        )
        crop.thumbnail((196, 176), Image.Resampling.LANCZOS)
        x = (index % cols) * tile_w
        y = (index // cols) * tile_h
        board = checkerboard(208, 188)
        board.paste(
            crop,
            ((board.width - crop.width) // 2, (board.height - crop.height) // 2),
            crop,
        )
        canvas.paste(board.convert("RGB"), (x + 11, y + 9))
        name = key.split(".", 1)[-1]
        draw.text((x + 12, y + 203), f"{index + 1:02d} {name}", fill=(45, 35, 26), font=label_font)
    return canvas


def cell_suspicion(
    sheet: dict, image: Image.Image
) -> list[dict]:
    alpha = np.asarray(image.getchannel("A"))
    height, width = alpha.shape
    profile = np.count_nonzero(alpha > 160, axis=1).tolist()
    rows = sheet.get("actual_rows", sheet["rows"])
    row_edges = split_edges(profile, rows)
    findings = []
    for index, key in enumerate(sheet["semantics"]):
        col = index % sheet["columns"]
        row = index // sheet["columns"]
        y0, y1 = row_edges[row], row_edges[row + 1]
        row_profile = np.count_nonzero(alpha[y0:y1] > 160, axis=0).tolist()
        col_edges = split_edges(row_profile, sheet["columns"])
        x0, x1 = col_edges[col], col_edges[col + 1]
        mask = alpha[y0:y1, x0:x1] > 160
        labels, count = ndimage.label(mask, structure=np.ones((3, 3), dtype=bool))
        if count == 0:
            findings.append({"key": key, "reason": "empty cell", "severity": "error"})
            continue
        objects = ndimage.find_objects(labels)
        sizes = ndimage.sum(mask, labels, range(1, count + 1))
        ranked = sorted(range(count), key=lambda i: sizes[i], reverse=True)
        largest = ranked[0]
        lx0, ly0 = objects[largest][1].start, objects[largest][0].start
        lx1, ly1 = objects[largest][1].stop, objects[largest][0].stop
        region = sheet["regions"][key]
        relative = (region[0] - x0, region[1] - y0, region[0] + region[2] - x0, region[1] + region[3] - y0)
        obj_w, obj_h = lx1 - lx0, ly1 - ly0
        cell_w, cell_h = x1 - x0, y1 - y0
        reasons = []
        severity = "info"
        if obj_w < cell_w * 0.28 or obj_h < cell_h * 0.28:
            reasons.append("largest component is unusually small")
            severity = "warn"
        if obj_w > cell_w * 0.88 or obj_h > cell_h * 0.88:
            reasons.append("largest component nearly touches cell edge")
            severity = "warn"
        if lx0 <= 1 or ly0 <= 1 or lx1 >= cell_w - 1 or ly1 >= cell_h - 1:
            reasons.append("component touches nominal cell boundary")
            severity = "warn"
        for other in ranked[1:]:
            if sizes[other] < sizes[largest] * 0.12:
                break
            ox0, oy0 = objects[other][1].start, objects[other][0].start
            ox1, oy1 = objects[other][1].stop, objects[other][0].stop
            gap_x = max(0, max(lx0, ox0) - min(lx1, ox1))
            gap_y = max(0, max(ly0, oy0) - min(ly1, oy1))
            if max(gap_x, gap_y) >= max(12, int(min(cell_w, cell_h) * 0.06)):
                reasons.append(
                    f"detached component {int(sizes[other])}px ({sizes[other] / sizes[largest]:.0%})"
                )
                severity = "error" if sizes[other] >= sizes[largest] * 0.35 else "warn"
                break
        if reasons:
            findings.append(
                {
                    "key": key,
                    "severity": severity,
                    "reasons": reasons,
                    "region": region,
                    "cell": [x0, y0, x1 - x0, y1 - y0],
                    "largest_component": [x0 + lx0, y0 + ly0, obj_w, obj_h],
                    "components": int(count),
                    "relative_bounds": relative,
                }
            )
    return findings


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ASSETS / "manifest.json").read_text(encoding="utf-8"))
    all_findings = []
    for sheet in manifest["sheets"]:
        image = Image.open(ASSETS / f"{sheet['name']}.png").convert("RGBA")
        contact = contact_sheet(sheet, image)
        contact.save(OUT / f"{sheet['name']}_runtime-crops.png")
        findings = cell_suspicion(sheet, image)
        all_findings.extend(
            [{"sheet": sheet["name"], **finding} for finding in findings]
        )
    report = {
        "summary": {
            "sheets": len(manifest["sheets"]),
            "icons": sum(len(sheet["semantics"]) for sheet in manifest["sheets"]),
            "findings": len(all_findings),
            "errors": sum(item["severity"] == "error" for item in all_findings),
            "warnings": sum(item["severity"] == "warn" for item in all_findings),
        },
        "findings": all_findings,
    }
    (OUT / "suspicious-slices.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report["summary"], ensure_ascii=False))


if __name__ == "__main__":
    main()
