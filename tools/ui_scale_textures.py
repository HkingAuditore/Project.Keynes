#!/usr/bin/env python3
"""按系数降低 UI 贴图分辨率，并把九宫格边距一起缩放。

为什么需要配套脚本
------------------
九宫格边距（`texture_margin_*`）记的是**纹理像素**。图缩小了而边距不动，
边框就会变粗甚至超出纹理。本脚本把「图」和「依赖这张图的边距」当成一个整体
一起缩，缩完再用 `tools/ui_slice_guard.py` 校验。

安全边界
--------
**不碰被 `AtlasTexture.region` 锚定的贴图**——那类切图坐标由
`tools/art/build_paper_icon_atlases.py` 从图像测量生成，必须「缩图 → 重跑生成器」，
不能由本脚本处理（本脚本没有重算 region 的能力）。

用法
----
    python tools/ui_scale_textures.py --factor 0.75            # 预演，只报告
    python tools/ui_scale_textures.py --factor 0.75 --apply    # 实际执行
    python tools/ui_scale_textures.py --factor 0.75 --apply --limit 20
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui_slice_guard as guard  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
DEFAULT_PROJECT = REPO / "Project" / "project-keynes"
MARGIN_LINE_RE = re.compile(r'^(texture_margin_(?:left|top|right|bottom)\s*=\s*)([\d.]+)\s*$', re.M)


def atlas_anchored(project: Path) -> set[str]:
    """被 AtlasTexture.region 引用的贴图（相对 res:// 的路径）。"""
    sizes = guard.build_size_index(project)
    resolver = guard.Resolver(project, sizes)
    out: set[str] = set()
    for f in project.rglob("*"):
        if f.suffix not in (".tres", ".tscn"):
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
        if 'type="AtlasTexture"' not in text:
            continue
        ext = {m.group(3): m.group(2) for m in guard.EXT_RE.finditer(text)}
        for kind, body in guard.sections(text):
            if 'type="AtlasTexture"' not in kind:
                continue
            ref = guard.ATLAS_REF_RE.search(body)
            if not ref:
                continue
            rel = ext.get(ref.group(1))
            if not rel:
                continue
            resolved = rel
            if resolved not in sizes:
                # 顺着 .tres 包装解析到真正的 PNG 名字
                for cand in ext.values():
                    if cand.endswith(".png"):
                        resolved = cand
            out.add(resolved)
            out.add(rel)
        _ = resolver
    return out


def collect_targets(project: Path, scope: str, min_kb: int, anchored: set[str]):
    sizes = guard.build_size_index(project)
    targets = []
    for rel, (w, h) in sizes.items():
        if not rel.startswith(scope):
            continue
        if rel in anchored:
            continue
        # 年报撕口有固定取样行，透明像素的绿通道还存着纸外距离。
        if rel == "assets/ui/annual_chronicle/paper_tear_mask.png":
            continue
        # 作者源图不进包（source / bitmap_sources 目录），缩了只会破坏母版
        if "/source/" in rel or "bitmap_sources" in rel or "/source_" in rel:
            continue
        path = project / rel
        if not path.is_file():
            continue
        if path.stat().st_size < min_kb * 1024:
            continue
        targets.append((path.stat().st_size, rel, w, h))
    targets.sort(reverse=True)
    return targets


def _section_bounds(text: str):
    """返回所有 StyleBoxTexture 节的 (start, end)，end 跳过紧随的 [resource] 节。"""
    heads = list(re.finditer(r'^\[(?!!)([^\]]*)\]', text, re.M))
    out = []
    for i, m in enumerate(heads):
        kind = m.group(1)
        if 'type="StyleBoxTexture"' not in kind:
            continue
        body_start = m.end()
        body_end = len(text)
        for nxt in heads[i + 1:]:
            if nxt.group(1).startswith("resource"):
                continue
            body_end = nxt.start()
            break
        out.append((body_start, body_end))
    return out


def scale_margins(project: Path, scaled: set[str], factor: float) -> list[str]:
    """把引用 scaled 贴图的 StyleBoxTexture 边距乘以 factor。返回被改写的文件。"""
    changed = []
    files = [p for p in project.rglob("*") if p.suffix in (".tres", ".tscn")]
    for f in files:
        try:
            text = f.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "texture_margin_" not in text:
            continue
        ext = {m.group(3): m.group(2) for m in guard.EXT_RE.finditer(text)}
        spans = _section_bounds(text)
        if not spans:
            continue

        def repl(mm):
            return f"{mm.group(1)}{float(mm.group(2)) * factor:.1f}"

        new_text = text
        for body_start, body_end in reversed(spans):
            body = new_text[body_start:body_end]
            ref = guard.TEX_REF_RE.search(body)
            if not ref or ext.get(ref.group(1)) not in scaled:
                continue
            new_text = new_text[:body_start] + MARGIN_LINE_RE.sub(repl, body) + new_text[body_end:]
        if new_text != text:
            f.write_text(new_text, encoding="utf-8", newline="\n")
            changed.append(str(f.relative_to(project)))
    return changed


def main() -> int:
    ap = argparse.ArgumentParser(description="降低 UI 贴图分辨率并缩放九宫格边距")
    ap.add_argument("--project", default=str(DEFAULT_PROJECT))
    ap.add_argument("--factor", type=float, default=0.75)
    ap.add_argument("--scope", default="assets/ui/")
    ap.add_argument("--min-kb", type=int, default=64, help="小于该体积的图不动")
    ap.add_argument("--limit", type=int, default=0, help="最多处理多少张（0=不限）")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    project = Path(args.project)
    if not (0.3 <= args.factor < 1.0):
        print("factor 应在 [0.3, 1.0) 之间", file=sys.stderr)
        return 2

    anchored = atlas_anchored(project)
    targets = collect_targets(project, args.scope, args.min_kb, anchored)
    if args.limit:
        targets = targets[:args.limit]
    if not targets:
        print("没有符合条件的贴图")
        return 0

    before = sum(t[0] for t in targets)
    print(f"图集锚定（跳过）{len(anchored)} 张；待处理 {len(targets)} 张，源文件 {before/1048576:.1f} MiB")
    print(f"{'源 MiB':>8} {'尺寸':>12} -> {'新尺寸':>12}  路径")
    for size, rel, w, h in targets[:40]:
        nw, nh = max(2, round(w * args.factor)), max(2, round(h * args.factor))
        print(f"{size/1048576:8.2f} {w:5d}x{h:<6d} -> {nw:5d}x{nh:<6d}  {rel}")
    if len(targets) > 40:
        print(f"  … 其余 {len(targets)-40} 张略")

    if not args.apply:
        print("\n（预演，未改动任何文件；加 --apply 执行）")
        return 0

    scaled: set[str] = set()
    after = 0
    for size, rel, w, h in targets:
        path = project / rel
        im = Image.open(path).convert("RGBA")
        nw, nh = max(2, round(w * args.factor)), max(2, round(h * args.factor))
        im.resize((nw, nh), Image.LANCZOS).save(path, format="PNG", optimize=True)
        scaled.add(rel)
        after += path.stat().st_size
        print(f"  scaled {rel} {w}x{h} -> {nw}x{nh}")

    changed = scale_margins(project, scaled, args.factor)
    print(f"\n改写九宫格边距的文件 {len(changed)} 个：")
    for c in changed:
        print(f"  {c}")
    print(f"源文件体积 {before/1048576:.1f} -> {after/1048576:.1f} MiB")
    print("下一步：python tools/ui_slice_guard.py 校验，然后重新导入并出包")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
