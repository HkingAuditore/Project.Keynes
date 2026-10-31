#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pck_audit.py - 直接解析 Godot 4 的 .pck，输出"谁占了体积"。

为什么不用 Godot 自身遍历 res://：
  * 导出后 pck 里的路径和工程目录不是一一对应的（纹理是 `.godot/imported/*.ctex`，
    文本资源在导出时被转成 `.godot/exported/<n>/export-<hash>-<name>.<ext>`），
    遍历工程目录量出来的是**源文件**大小，不是包里的字节数，会误导取舍。
  * 引擎没有暴露"枚举 pck 目录表"的 API。

所以这里直接按 Godot 的 PCK 目录格式解析二进制：

    u32 magic          'GDPC'
    u32 pack_version   3（4.6）
    u32 ver_major/minor/patch
    u32 pack_flags     1 = 目录加密, 2 = 偏移相对 file_base（PACK_REL_FILEBASE）
    u64 file_base      文件数据区起点
    u64 dir_offset     目录表偏移（末尾，4.4+ 为了 delta patch 挪到了尾部）
    ... reserved ...
    --- @dir_offset ---
    u32 file_count
    重复 file_count 次：
        u32 path_len + path(utf8, 尾部 \\0 补齐到 4 字节)   ← 不带 res:// 前缀
        u64 offset + u64 size
        16B md5
        u32 flags

用法：
    python tools/pck_audit.py                        # 默认审 WebBuild/ProjectKeynes.pck
    python tools/pck_audit.py --top 40 --detail
    python tools/pck_audit.py --json tmp/pck_before.json
    python tools/pck_audit.py --compare tmp/pck_before.json   # 导出后对比 Top 表

输出：
    * 总体：文件数 / 总字节 / 各扩展名聚合
    * Top N：pck 内路径 → 折算到的**源资源**路径 + 体积 + 类型 + 落地目录
    * --detail：附上该源资源 `.import` 里的关键参数（compress/mode、lossy_quality…）
"""

from __future__ import annotations

import argparse
import json
import mmap
import os
import struct
import sys
from dataclasses import dataclass, field, asdict
from typing import Any

# --------------------------------------------------------------------------
# 类型归类：用 pck 内路径的扩展名，而不是源文件扩展名（fontdata 的源是 ttf，
# 但真正进包的是 .fontdata）。
# --------------------------------------------------------------------------
EXT_KIND = {
    ".ctex": "texture(2D)",
    ".ctexarray": "texture(array)",
    ".fontdata": "font",
    ".res": "resource(binary)",
    ".scn": "scene",
    ".tscn": "scene",
    ".gd": "script",
    ".gdc": "script(compiled)",
    ".gdshader": "shader",
    ".gdshaderinc": "shader",
    ".glsl": "shader",
    ".json": "data",
    ".txt": "data",
    ".csv": "data",
    ".import": "import-meta",
    ".remap": "import-meta",
    ".md5": "import-meta",
    ".ogg": "audio",
    ".wav": "audio",
    ".mp3": "audio",
    ".ttf": "font-src",
    ".otf": "font-src",
    ".woff2": "font-src",
    ".png": "image-src",
    ".svg": "image-src",
    ".webp": "image-src",
    ".uid": "meta",
}


def kind_of(path: str) -> str:
    """pck 内路径 → 归类。"""
    low = path.lower()
    for ext in (".ctexarray", ".gdshaderinc", ".fontdata", ".gdshader", ".import",
                ".remap", ".woff2", ".ctex", ".gdc", ".json", ".res", ".scn",
                ".tscn", ".ttf", ".otf", ".png", ".svg", ".webp", ".csv", ".txt",
                ".ogg", ".wav", ".mp3", ".gd", ".uid", ".md5"):
        if low.endswith(ext):
            return EXT_KIND[ext]
    _, ext = os.path.splitext(low)
    return EXT_KIND.get(ext, ext or "(none)")


# --------------------------------------------------------------------------
# PCK 解析
# --------------------------------------------------------------------------
class PckError(RuntimeError):
    pass


@dataclass
class Entry:
    path: str            # pck 内路径（不带 res://）
    offset: int          # 已折算成绝对偏移
    size: int
    flags: int


class Pck:
    HEADER_MAGIC = b"GDPC"

    def __init__(self, path: str) -> None:
        self.path = path
        self.file_size = os.path.getsize(path)
        self._fp = open(path, "rb")
        self._mm = mmap.mmap(self._fp.fileno(), 0, access=mmap.ACCESS_READ)
        self.pack_version = 0
        self.version = (0, 0, 0)
        self.pack_flags = 0
        self.file_base = 0
        self.dir_offset = 0
        self.entries: list[Entry] = []
        self._parse()

    # -- 低层 ---------------------------------------------------------------
    def _u32(self, off: int) -> int:
        return struct.unpack_from("<I", self._mm, off)[0]

    def _u64(self, off: int) -> int:
        return struct.unpack_from("<Q", self._mm, off)[0]

    def _parse_dir(self, dir_off: int) -> list[Entry] | None:
        """在 dir_off 处尝试解析目录表；必须正好吃到文件末尾才算成功。"""
        mm = self._mm
        n = self.file_size
        if dir_off + 4 > n:
            return None
        count = self._u32(dir_off)
        if count <= 0 or count > 2_000_000:
            return None
        pos = dir_off + 4
        out: list[Entry] = []
        rel = bool(self.pack_flags & 2)  # PACK_REL_FILEBASE
        for _ in range(count):
            if pos + 4 > n:
                return None
            plen = self._u32(pos)
            pos += 4
            if plen <= 0 or plen > 4096 or pos + plen > n:
                return None
            raw = mm[pos:pos + plen]
            pos += (plen + 3) & ~3
            if pos + 8 + 8 + 16 + 4 > n:
                return None
            off = self._u64(pos)
            size = self._u64(pos + 8)
            pos += 16 + 16
            flags = self._u32(pos)
            pos += 4
            name = raw.split(b"\x00", 1)[0].decode("utf-8", "replace")
            if not name:
                return None
            out.append(Entry(name, off + self.file_base if rel else off, size, flags))
        if pos != n:
            return None  # 目录表没有正好结束在 EOF → 解析错位
        return out

    def _parse(self) -> None:
        mm, n = self._mm, self.file_size
        if n < 108 or mm[0:4] != self.HEADER_MAGIC:
            raise PckError(f"{self.path}: 不是 Godot pck（magic = {bytes(mm[0:4])!r}）")
        self.pack_version, maj, mi, pa, self.pack_flags = struct.unpack_from("<5I", mm, 4)
        self.version = (maj, mi, pa)
        self.file_base = self._u64(24)

        # 4.4+：目录在文件末尾，偏移写在 header 的 u64@32。老格式则紧跟 header。
        candidates: list[int] = []
        if n >= 40:
            candidates.append(self._u64(32))
        candidates += [108, 100, self.file_base]
        # 兜底：在尾部 8MB 内扫一遍候选（防止 header 布局再次变化）
        lo = max(0, n - 8 * 1024 * 1024)
        candidates += [p for p in range(lo, n - 8, 4)]

        seen: set[int] = set()
        for cand in candidates:
            if cand in seen or cand < 0 or cand >= n:
                continue
            seen.add(cand)
            got = self._parse_dir(cand)
            if got:
                self.dir_offset = cand
                self.entries = got
                return
        raise PckError(f"{self.path}: 目录表解析失败（header 布局未知）")

    # -- 高层 ---------------------------------------------------------------
    def total_bytes(self) -> int:
        return sum(e.size for e in self.entries)

    def close(self) -> None:
        try:
            self._mm.close()
            self._fp.close()
        except Exception:
            pass


# --------------------------------------------------------------------------
# 把 pck 内路径折回源资源（.import → source_file）
# --------------------------------------------------------------------------
class SourceIndex:
    """扫工程目录的所有 *.import，建立 dest → source 的反查表。"""

    def __init__(self, project_dir: str) -> None:
        self.project_dir = project_dir
        self.dest_to_source: dict[str, str] = {}
        # 导出转换产物 `.godot/exported/<n>/export-<hash>-<name>.<ext>` 的 basename → 源
        self.basename_to_source: dict[str, str] = {}
        self.import_params: dict[str, dict[str, str]] = {}
        self._scan()

    def _scan(self) -> None:
        if not os.path.isdir(self.project_dir):
            return
        for root, dirs, files in os.walk(self.project_dir):
            # 跳过 .git / .godot / 构建产物，但 .godot 下的 *.import 不需要（没有）
            dirs[:] = [d for d in dirs if d not in (".git", ".godot", "__pycache__")]
            for fn in files:
                if not fn.endswith(".import"):
                    continue
                full = os.path.join(root, fn)
                rel_dir = os.path.relpath(root, self.project_dir).replace("\\", "/")
                source_res = "res://" + (rel_dir + "/" + fn[:-len(".import")] if rel_dir != "." else fn[:-len(".import")])
                try:
                    with open(full, "r", encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                dests: list[str] = []
                params: dict[str, str] = {}
                section = ""
                for line in text.splitlines():
                    s = line.strip()
                    if s.startswith("[") and s.endswith("]"):
                        section = s[1:-1]
                        continue
                    if section == "remap" and (s.startswith("path") and "=" in s):
                        val = s.split("=", 1)[1].strip().strip('"')
                        if val.startswith("res://"):
                            dests.append(val)
                    elif section == "deps" and s.startswith("dest_files="):
                        body = s.split("=", 1)[1].strip()
                        body = body.strip("[]")
                        for part in body.split(","):
                            part = part.strip().strip('"')
                            if part.startswith("res://"):
                                dests.append(part)
                    elif section == "params" and "=" in s:
                        k, v = s.split("=", 1)
                        params[k.strip()] = v.strip().strip('"')
                self.import_params[source_res] = params
                for d in dests:
                    self.dest_to_source.setdefault(d, source_res)
                base = fn[:-len(".import")]
                self.basename_to_source.setdefault(base, source_res)

    def resolve(self, pck_path: str) -> tuple[str, str]:
        """返回 (源资源 res:// 路径, 说明)。源路径找不到时返回原路径。"""
        res = "res://" + pck_path
        if res in self.dest_to_source:
            return self.dest_to_source[res], "import"
        norm = pck_path.replace("\\", "/")
        # .godot/exported/<n>/export-<hash>-<name>.<ext>
        if norm.startswith(".godot/exported/"):
            parts = norm.split("/")
            tail = parts[-1]
            if tail.startswith("export-"):
                rest = tail[len("export-"):]
                # export-<32 hex>-<name>
                if len(rest) > 33 and rest[32] == "-":
                    rest = rest[33:]
            stem, _ext = os.path.splitext(rest)
            if stem in self.basename_to_source:
                return self.basename_to_source[stem], "exported-copy"
            return res, "exported-copy?"
        if norm.endswith(".import") or norm.endswith(".remap") or norm.endswith(".md5"):
            # 导出时附带的 import 元数据，依附于同名源
            stem = norm.rsplit(".", 1)[0]
            base = stem.rsplit("/", 1)[-1]
            if base in self.basename_to_source:
                return self.basename_to_source[base], "import-meta"
            return res, "import-meta?"
        # 其它（scripts/shaders/data）路径本身就在工程里
        if os.path.exists(os.path.join(self.project_dir, norm.replace("/", os.sep))):
            return res, "direct"
        return res, "direct?"


# --------------------------------------------------------------------------
# 报表
# --------------------------------------------------------------------------
def image_dims(path: str) -> str:
    """只读 PNG/WebP 文件头拿像素尺寸，不解码（534 张图也能秒出）。"""
    try:
        with open(path, "rb") as fh:
            head = fh.read(32)
            if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
                w, h = struct.unpack(">II", head[16:24])
                return f"{w}x{h}"
            if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
                kind = head[12:16]
                if kind == b"VP8 ":
                    w = int.from_bytes(head[26:28], "little") & 0x3FFF
                    h = int.from_bytes(head[28:30], "little") & 0x3FFF
                    return f"{w}x{h}"
                if kind == b"VP8L":
                    b = int.from_bytes(head[21:25], "little")
                    return f"{(b & 0x3FFF) + 1}x{((b >> 14) & 0x3FFF) + 1}"
                if kind == b"VP8X":
                    w = int.from_bytes(head[24:27], "little") + 1
                    h = int.from_bytes(head[27:30], "little") + 1
                    return f"{w}x{h}"
    except OSError:
        pass
    return ""


@dataclass
class Row:
    pck_path: str
    source: str
    kind: str
    size: int
    how: str
    params: dict[str, str] = field(default_factory=dict)
    dims: str = ""

    def mb(self) -> float:
        return self.size / (1024 * 1024)


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024.0 or unit == "GB":
            return f"{n:.2f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024.0
    return f"{n:.2f} GB"


def build_rows(pck: Pck, index: SourceIndex, max_params: int = 0) -> list[Row]:
    rows: list[Row] = []
    dim_cache: dict[str, str] = {}
    for e in pck.entries:
        src, how = index.resolve(e.path)
        params = index.import_params.get(src, {}) if max_params else {}
        dims = ""
        if how in ("import", "exported-copy"):
            if src not in dim_cache:
                rel = src.replace("res://", "").replace("/", os.sep)
                dim_cache[src] = image_dims(os.path.join(index.project_dir, rel))
            dims = dim_cache[src]
        rows.append(Row(e.path, src, kind_of(e.path), e.size, how, params, dims))
    return rows


KEY_PARAMS = (
    "compress/mode", "compress/lossy_quality", "compress/high_quality",
    "mipmaps/generate", "process/size_limit", "compress/channel_pack",
    "slices/vertical", "slices/horizontal",
)


def print_report(pck: Pck, rows: list[Row], top: int, detail: bool, out=sys.stdout) -> None:
    total = pck.total_bytes()
    print(f"# PCK 体积审计\n", file=out)
    print(f"- 包: `{pck.path}`", file=out)
    print(f"- 磁盘大小: {pck.file_size:,} B ({human(pck.file_size)})", file=out)
    print(f"- 目录表: {len(rows)} 个条目，条目字节合计 {total:,} B ({human(total)})", file=out)
    print(f"- 格式: pck v{pck.pack_version} / Godot {'.'.join(map(str, pck.version))}"
          f" / flags={pck.pack_flags} / file_base={pck.file_base} / dir@{pck.dir_offset}", file=out)
    print(file=out)

    # 按类型聚合
    agg: dict[str, tuple[int, int]] = {}
    for r in rows:
        c, s = agg.get(r.kind, (0, 0))
        agg[r.kind] = (c + 1, s + r.size)
    print("## 按类型", file=out)
    print("| 类型 | 文件数 | 体积 | 占比 |", file=out)
    print("| --- | ---: | ---: | ---: |", file=out)
    for kind, (c, s) in sorted(agg.items(), key=lambda kv: -kv[1][1]):
        print(f"| {kind} | {c} | {human(s)} | {100.0 * s / max(1, total):.1f}% |", file=out)
    print(file=out)

    # Top N
    ranked = sorted(rows, key=lambda r: -r.size)[:top]
    cum = 0
    print(f"## Top {top} 资源", file=out)
    hdr = "| # | 体积 | 累计% | 类型 | 源图尺寸 | 源资源 | pck 内路径 |"
    if detail:
        hdr += " 关键导入参数 |"
    print(hdr, file=out)
    print("| ---: | ---: | ---: | --- | --- | --- | --- |" + (" --- |" if detail else ""), file=out)
    for i, r in enumerate(ranked, 1):
        cum += r.size
        line = (f"| {i} | {r.mb():.2f} MB | {100.0 * cum / max(1, total):.1f}% | {r.kind} | "
                f"{r.dims or '-'} | `{r.source}` | `{r.pck_path}` |")
        if detail:
            p = r.params
            bits = []
            for k in KEY_PARAMS:
                if k in p:
                    short = k.split("/")[-1]
                    bits.append(f"{short}={p[k]}")
            line += " " + (", ".join(bits) if bits else "-") + " |"
        print(line, file=out)
    print(file=out)

    # 落地目录聚合（按源路径前两层）
    print("## 按源目录（Top 15）", file=out)
    print("| 目录 | 文件数 | 体积 |", file=out)
    print("| --- | ---: | ---: |", file=out)
    dagg: dict[str, list[int]] = {}
    for r in rows:
        p = r.source.replace("res://", "")
        parts = p.split("/")
        key = "/".join(parts[:2]) if len(parts) > 2 else (parts[0] if parts else "?")
        slot = dagg.setdefault(key, [0, 0])
        slot[0] += 1
        slot[1] += r.size
    for key, (c, s) in sorted(dagg.items(), key=lambda kv: -kv[1][1])[:15]:
        print(f"| `{key}` | {c} | {human(s)} |", file=out)


def main(argv: list[str]) -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description="Godot 4 pck 体积审计（Top 资源表）")
    ap.add_argument("--pck", default=os.path.join(repo_root, "WebBuild", "ProjectKeynes.pck"))
    ap.add_argument("--project", default=os.path.join(repo_root, "Project", "project-keynes"))
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--detail", action="store_true", help="Top 表附 .import 关键参数")
    ap.add_argument("--json", default="", help="把完整清单写成 JSON（供 --compare 用）")
    ap.add_argument("--out", default="", help="把报告写成 UTF-8 文件（默认 stdout）")
    ap.add_argument("--compare", default="", help="与之前的 JSON 对比，输出体积差 Top")
    args = ap.parse_args(argv)

    if not os.path.exists(args.pck):
        print(f"找不到 pck: {args.pck}", file=sys.stderr)
        return 2

    pck = Pck(args.pck)
    index = SourceIndex(args.project)
    rows = build_rows(pck, index, max_params=1 if args.detail else 0)

    sink = sys.stdout
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        sink = open(args.out, "w", encoding="utf-8")

    if args.compare:
        with open(args.compare, "r", encoding="utf-8") as fh:
            before = json.load(fh)
        print_compare(before, pck, rows, out=sink)
    else:
        print_report(pck, rows, args.top, args.detail, out=sink)

    if sink is not sys.stdout:
        sink.close()
        print(f"[done] 报告 → {args.out}", file=sys.stderr)

    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        payload: dict[str, Any] = {
            "pck": args.pck,
            "file_size": pck.file_size,
            "entries": len(rows),
            "total": pck.total_bytes(),
            "version": list(pck.version),
            "rows": [
                {"pck_path": r.pck_path, "source": r.source, "kind": r.kind,
                 "size": r.size, "how": r.how, "dims": r.dims}
                for r in sorted(rows, key=lambda r: -r.size)
            ],
        }
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)
        print(f"\n[done] JSON → {args.json}", file=sys.stderr)

    pck.close()
    return 0


def print_compare(before: dict[str, Any], pck: Pck, rows: list[Row], out=sys.stdout) -> None:
    old_total = int(before.get("total", 0))
    new_total = pck.total_bytes()
    old_rows = {r["source"] + "|" + r["pck_path"]: int(r["size"]) for r in before.get("rows", [])}
    new_rows = {r.source + "|" + r.pck_path: r.size for r in rows}

    print("# PCK 前后对比\n", file=out)
    print(f"- 之前: {human(old_total)}（{before.get('entries', '?')} 条）", file=out)
    print(f"- 现在: {human(new_total)}（{len(rows)} 条）", file=out)
    delta = new_total - old_total
    print(f"- 变化: {delta / 1024 / 1024:+.2f} MB"
          f"（{100.0 * delta / max(1, old_total):+.1f}%）\n", file=out)

    changes: list[tuple[str, int, int]] = []
    for key in set(old_rows) | set(new_rows):
        a, b = old_rows.get(key, 0), new_rows.get(key, 0)
        if a != b:
            changes.append((key, a, b))
    removed = [c for c in changes if c[2] == 0]
    added = [c for c in changes if c[1] == 0]
    shrunk = sorted([c for c in changes if c[1] and c[2] and c[2] < c[1]], key=lambda c: -(c[1] - c[2]))
    grown = sorted([c for c in changes if c[1] and c[2] and c[2] > c[1]], key=lambda c: -(c[2] - c[1]))

    def dump(title: str, data: list[tuple[str, int, int]], limit: int = 40) -> None:
        if not data:
            return
        print(f"## {title}（{len(data)} 项）\n", file=out)
        print("| 资源 | 之前 | 现在 | 变化 |", file=out)
        print("| --- | ---: | ---: | ---: |", file=out)
        for key, a, b in data[:limit]:
            src = key.split("|", 1)[0]
            print(f"| `{src}` | {a / 1048576:.2f} MB | {b / 1048576:.2f} MB | "
                  f"{(b - a) / 1048576:+.2f} MB |", file=out)
        if len(data) > limit:
            print(f"| … 其余 {len(data) - limit} 项 | | | |", file=out)
        print(file=out)

    dump("体积减少最多", shrunk)
    dump("体积增加", grown)
    dump("完全消失（被挤出包）", removed)
    dump("新出现", added)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
