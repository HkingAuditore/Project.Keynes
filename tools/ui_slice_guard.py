#!/usr/bin/env python3
"""UI 切片守卫：像素锚点（图集区域 / 九宫格边距）是否还在合法范围内。

为什么需要它
------------
UI 贴图里有一批「像素锚点」——它们记的是源图第几个像素：

  * `AtlasTexture.region`（`.tres` / `.tscn`），例如 `Rect2(47, 105, 207, 214)`
  * `StyleBoxTexture.texture_margin_{left,top,right,bottom}`（九宫格边距，单位是纹理像素）

一旦某张贴图被降了分辨率，这些坐标不会跟着走：切图会取到错位的区域，
九宫格边框会变粗甚至超出纹理。本脚本在构建前把这类错误挡下来。

检查项
------
  error   region 超出纹理边界 / 宽高非正
  error   九宫格左右（或上下）边距之和超过纹理对应边
  warn    同一张图集上两个切图区域重叠（可能是刻意的，人工判断）

用法
----
    python tools/ui_slice_guard.py
    python tools/ui_slice_guard.py --project Project/project-keynes --verbose
"""

from __future__ import annotations

import argparse
import re
import struct
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_PROJECT = REPO / "Project" / "project-keynes"

EXT_RE = re.compile(r'\[ext_resource type="(\w+)"[^\]]*?path="res://([^"]+)"[^\]]*?id="([^"]+)"')
RECT_RE = re.compile(r'region\s*=\s*Rect2\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)')
TEX_REF_RE = re.compile(r'texture\s*=\s*ExtResource\("([^"]+)"\)')
ATLAS_REF_RE = re.compile(r'atlas\s*=\s*ExtResource\("([^"]+)"\)')
MARGIN_RE = re.compile(r'texture_margin_(left|top|right|bottom)\s*=\s*([\d.]+)')


def sections(text: str):
    """把 .tres/.tscn 切成 (节头, 正文)。

    `[gd_resource type="AtlasTexture"]` 的属性写在紧随其后的 `[resource]` 节里，
    而 `[sub_resource ...]` 的属性直接跟在节头后面。所以先把每个节头到下一个节头
    之间的文本切出来，再把 `[resource]` 的正文归并给最近的 `gd_resource`。
    """
    headers = [(m.start(), m.group(0)) for m in re.finditer(r'^\[(?!!)([^\]]*)\]', text, re.M)]
    raw: list[list[str]] = []
    for idx, (pos, header) in enumerate(headers):
        end = headers[idx + 1][0] if idx + 1 < len(headers) else len(text)
        raw.append([header[1:header.find("]")], text[pos + len(header):end]])

    out: list[list[str]] = []
    for kind, body in raw:
        if kind == "resource":
            for entry in reversed(out):
                if entry[0].startswith("gd_resource"):
                    entry[1] += "\n" + body
                    break
            else:
                out.append([kind, body])
            continue
        out.append([kind, body])
    return [(kind, body) for kind, body in out]


def png_size(path: Path) -> tuple[int, int] | None:
    """只读 PNG 头，避免为了一张图去解码整张 RGBA。"""
    try:
        with path.open("rb") as fh:
            head = fh.read(33)
    except OSError:
        return None
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return int(width), int(height)


def build_size_index(project: Path) -> dict[str, tuple[int, int]]:
    """res:// 相对路径 -> (w, h)，数据来自每个 .png.import 指向的源文件。"""
    sizes: dict[str, tuple[int, int]] = {}
    for imp in project.rglob("*.png.import"):
        m = re.search(r'^source_file="res://(.+)"', imp.read_text(encoding="utf-8"), re.M)
        if not m:
            continue
        rel = m.group(1)
        size = png_size(project / rel)
        if size:
            sizes[rel] = size
    return sizes


class Resolver:
    """把 StyleBoxTexture 里指向 .tres 的引用一路解析到真正的 PNG。

    很多九宫格样式不是直接引用 PNG，而是 `texture = ExtResource(...)` 指向一个
    AtlasTexture / 包装过的 .tres。不追下去就会把"包了一层"误报成"纹理缺失"。
    """

    def __init__(self, project: Path, sizes: dict[str, tuple[int, int]]):
        self.project = project
        self.sizes = sizes
        self._text: dict[str, str] = {}
        self._cache: dict[str, tuple[int, int] | None] = {}

    def _read(self, rel: str) -> str:
        if rel not in self._text:
            try:
                self._text[rel] = (self.project / rel).read_text(encoding="utf-8", errors="ignore")
            except OSError:
                self._text[rel] = ""
        return self._text[rel]

    def size(self, rel: str, depth: int = 0) -> tuple[int, int] | None:
        if rel in self.sizes:
            return self.sizes[rel]
        if depth > 3:
            return None
        if rel in self._cache:
            return self._cache[rel]
        text = self._read(rel)
        ext = {m.group(3): m.group(2) for m in EXT_RE.finditer(text)}
        found = None
        for pattern in (ATLAS_REF_RE, TEX_REF_RE):
            m = pattern.search(text)
            if m and m.group(1) in ext:
                found = self.size(ext[m.group(1)], depth + 1)
                if found:
                    break
        if found is None:
            # 兜底：文件里任意一个 PNG 引用
            for target in ext.values():
                if target.endswith(".png"):
                    found = self.sizes.get(target)
                    if found:
                        break
        self._cache[rel] = found
        return found


def scan(project: Path, verbose: bool) -> int:
    sizes = build_size_index(project)
    resolver = Resolver(project, sizes)
    errors: list[str] = []
    warnings: list[str] = []
    atlas_regions: dict[str, list[tuple[str, tuple[float, float, float, float]]]] = defaultdict(list)

    files = [p for p in project.rglob("*") if p.suffix in (".tres", ".tscn")]
    checked_atlas = checked_style = 0

    for f in files:
        try:
            text = f.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "AtlasTexture" not in text and "StyleBoxTexture" not in text:
            continue
        rel_file = str(f.relative_to(project))
        ext = {m.group(3): m.group(2) for m in EXT_RE.finditer(text)}

        for kind, body in sections(text):
            if 'type="AtlasTexture"' not in kind:
                continue
            atlas_ref = ATLAS_REF_RE.search(body)
            region = RECT_RE.search(body)
            if not atlas_ref or not region:
                continue
            atlas_rel = ext.get(atlas_ref.group(1))
            if not atlas_rel:
                continue
            checked_atlas += 1
            x, y, w, h = (float(v) for v in region.groups())
            size = resolver.size(atlas_rel)
            if size is None:
                errors.append(f"{rel_file}: 图集缺失或不是 PNG -> {atlas_rel}")
                continue
            aw, ah = size
            if w <= 0 or h <= 0:
                errors.append(f"{rel_file}: region 宽高非正 ({w}x{h}) -> {atlas_rel}")
            if x < 0 or y < 0 or x + w > aw + 0.5 or y + h > ah + 0.5:
                errors.append(
                    f"{rel_file}: region 超出图集 {atlas_rel} 边界 {aw}x{ah}"
                    f"（region={x:.0f},{y:.0f},{w:.0f}x{h:.0f}）")
            atlas_regions[atlas_rel].append((rel_file, (x, y, w, h)))

        for kind, body in sections(text):
            if 'type="StyleBoxTexture"' not in kind:
                continue
            tex_ref = TEX_REF_RE.search(body)
            if not tex_ref:
                continue
            tex_rel = ext.get(tex_ref.group(1))
            if not tex_rel:
                continue
            margins = {m.group(1): float(m.group(2)) for m in MARGIN_RE.finditer(body)}
            if not margins:
                continue
            checked_style += 1
            size = resolver.size(tex_rel)
            if size is None:
                errors.append(f"{rel_file}: 九宫格纹理缺失 -> {tex_rel}")
                continue
            tw, th = size
            horizontal = margins.get("left", 0.0) + margins.get("right", 0.0)
            vertical = margins.get("top", 0.0) + margins.get("bottom", 0.0)
            if horizontal > tw + 0.5:
                errors.append(
                    f"{rel_file}: 九宫格左右边距 {horizontal:.0f} > 纹理宽 {tw} -> {tex_rel}")
            if vertical > th + 0.5:
                errors.append(
                    f"{rel_file}: 九宫格上下边距 {vertical:.0f} > 纹理高 {th} -> {tex_rel}")

    # 同一图集内切图重叠：只警告
    for atlas_rel, entries in atlas_regions.items():
        for i in range(len(entries)):
            for j in range(i + 1, len(entries)):
                fa, (ax, ay, aw, ah) = entries[i]
                fb, (bx, by, bw, bh) = entries[j]
                if fa == fb:
                    continue
                if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                    warnings.append(f"{atlas_rel}: 切图重叠 {fa} <-> {fb}")

    print(f"检查 {len(files)} 个资源文件；AtlasTexture {checked_atlas} 个、"
          f"九宫格 {checked_style} 个；涉及图集 {len(atlas_regions)} 张")
    if verbose:
        for atlas_rel, entries in sorted(atlas_regions.items()):
            size = sizes.get(atlas_rel, ("?", "?"))
            print(f"  {atlas_rel} {size[0]}x{size[1]}: {len(entries)} 个切图")

    for w in warnings:
        print(f"[warn] {w}")
    for e in errors:
        print(f"[error] {e}")
    if errors:
        print(f"\n[slice-guard] FAIL — {len(errors)} 个错误")
        return 1
    print("\n[slice-guard] OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="校验 UI 切片像素锚点是否越界")
    ap.add_argument("--project", default=str(DEFAULT_PROJECT))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    project = Path(args.project)
    if not project.is_dir():
        print(f"找不到工程目录: {project}", file=sys.stderr)
        return 2
    return scan(project, args.verbose)


if __name__ == "__main__":
    raise SystemExit(main())
