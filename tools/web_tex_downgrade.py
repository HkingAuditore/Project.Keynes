#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web_tex_downgrade.py —— Web 导出专用的纹理降规格（构建期临时改，事后必恢复）。

问题
----
Web pck 里 `.ctex` 占 154.6 MB：**全部** 2D 纹理都是 `compress/mode=0`（无损 WebP），
一张 1254² 的手绘 UI 图单独就有 2.5 MB。gzip 对此无能为力（实测只有 0.45%），
所以只能降内容规格；桌面端必须一个字节都不变。

方案
----
Godot 4 的 `.import` 没有"按平台"的参数段（见报告 §2 的证据），所以走
**构建期重导入**：

    begin  : 备份 .import -> 按策略改 [params] -> `godot --headless --import`
    export : 原样跑原有导出（此时 .godot/imported/ 里是 web 规格的 ctex）
    end    : 还原 .import -> 再 `--import` 一次，把本机缓存恢复成桌面规格

`end` 必须在成功和失败两条路径上都被调用（Build-Web.cmd 的 `:fail` 里也要有）。
如果构建进程被 Ctrl-C 杀掉，`begin` 会在下次运行时发现残留状态并**先自动还原**
（self-healing）；也可以手动 `python tools\\web_tex_downgrade.py restore`。

安全阀
------
    PK_WEB_SKIP_TEXTURE_DOWNGRADE=1   begin/end 都是 no-op（exit 0）
    任何一步失败：立刻还原 .import 并 exit 1（绝不留下半改状态）
    还原后校验 sha256 与备份一致，并校验 ctex 体积回到 before 值

用法
----
    python tools\\web_tex_downgrade.py plan              # 只看策略命中，不动磁盘
    python tools\\web_tex_downgrade.py begin --godot <exe>
    python tools\\web_tex_downgrade.py end   --godot <exe>
    python tools\\web_tex_downgrade.py restore --godot <exe>
    python tools\\web_tex_downgrade.py status
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any

# --------------------------------------------------------------------------
# 策略
# --------------------------------------------------------------------------
# 依据：tools/pck_audit.py 的实测 Top 表（见 tmp/next/web_texture_downgrade_IMPL.md）。
#   实测：所有 2D 纹理 mode=0（无损 WebP），1254^2 手绘图 2.5 MB、1536^2 图 2.9 MB。
#   所以主要杠杆不是降分辨率，而是把无损换成 lossy WebP：
#   同一张图 q=0.68~0.72 大约剩 1/8~1/12 字节，1080p（预设已把 devicePixelRatio
#   固定成 1）下基本看不出来。
#
# 规则按 glob 匹配源资源 res:// 路径，**后面的规则覆盖前面的**。
#
# keys：
#   "compress/mode"          0=Lossless 1=Lossy 2=VRAM 3=VRAM-uncompressed 4=BasisU
#   "compress/lossy_quality" 仅 mode=1 生效（WebP 质量）
#   "process/size_limit"     0=原尺寸；>0 按最长边缩到该值
#   "mipmaps/generate"       数组/3D 用途要保留，UI 图本来是 false 就别开
RULES: list[tuple[str, dict[str, str], int]] = [
    # 基线：所有 2D 纹理 无损 -> lossy
    ("res://assets/**", {"compress/mode": "1", "compress/lossy_quality": "0.72"}, 0),

    # 大头：手绘 UI 纸面/面板（assets/ui 占 97.9 MB），观感容错最高
    ("res://assets/ui/**", {"compress/mode": "1", "compress/lossy_quality": "0.68"}, 0),

    # 图标集：屏幕显示尺寸小（1080p 下 32~64 px）
    ("res://assets/icons/**", {"compress/mode": "1", "compress/lossy_quality": "0.62"}, 0),

    # 地形材质：1024^2 平铺细节图，铺满整张地图，质量给高一些
    ("res://assets/textures/terrain_materials/**",
     {"compress/mode": "1", "compress/lossy_quality": "0.80"}, 0),

    # 2D 数组纹理（地面覆盖 / 树冠，按 sprite 采样）。法线一旦出块状伪影会毁掉受光，
    # 所以 q 给 0.82；mipmaps 必须保留（远处 minify 靠它）。
    # 注意：已经是 s3tc+etc2 双套的 albedo 数组会被 is_vram_variant() 挡掉，不改 mode。
    ("res://assets/textures/resource_art/**",
     {"compress/mode": "1", "compress/lossy_quality": "0.82"}, 0),

    # 法线：跟着 albedo 一起降分辨率，但质量档不能低于 0.90（强损会在受光上出
    # 带状脏影，得不偿失）。这两条必须排在 resource_art/** 之后才生效。
    ("res://assets/textures/resource_art/cover_normal.png",
     {"compress/mode": "1", "compress/lossy_quality": "0.90"}, 0),
    ("res://assets/textures/resource_art/crown_normal.png",
     {"compress/mode": "1", "compress/lossy_quality": "0.92"}, 0),

    # 天气层小图（雨滴/雪花，只有 alpha 信息）：动 mode 省不了几 KB 还可能糊边
    ("res://assets/textures/weather/**", {}, 0),
    ("res://textures/weather/**", {}, 0),

    # 贸易车辆等 vfx 精灵图集
    ("res://assets/vfx/**", {"compress/mode": "1", "compress/lossy_quality": "0.70"}, 0),
]

# 明确不动的路径。命中即跳过并给出理由。
KEEP: list[tuple[str, str]] = [
    ("res://assets/fonts/**", "字体：子集化由 Build-Web 另一条钩子负责，这里不碰"),
    ("res://assets/textures/loading_prebaked_v1/**",
     "预烘焙 .res 由 export_presets 的 exclude_filter 处理（见报告 §5）"),
    ("res://assets/textures/resource_art/source/**", "原图源，游戏不直接引用"),
    ("res://**.svg", "矢量图标：光栅化后是锐利线稿，lossy 反而出振铃，且单文件 < 2 KB"),
]

# 体积门槛：当前导入产物小于这个值的资源一律不动。
# 理由：这些要么是 1~64 px 的小图标（省不到 100 KB，但 lossy 会糊边），
# 要么是 alpha 遮罩小图；动它们的性价比为负。
MIN_BYTES = 128 * 1024

# ---- 预烘焙材质 .res（不进 .import 流程，靠重烘焙脚本临时缩小）------------
# [web-loading-material-shrink 2026-11-01] 只 stub **512** 那套，不再动 1024：
#   * Web 运行时由 MapBaker._terrain_material_size() 决定档位，现在 Web 固定 512
#     （1024 档在 Web 上被显式排除，见 export_presets.cfg 的 exclude_filter 与
#     map_baker.gd 的注释），所以 1024 那套不进 Web 包，也不该在构建期被改写——
#     否则同一份磁盘文件会连带影响桌面导出。
#   * 512 -> 256：每张 1.334 MB -> 0.334 MB（RGBA8 + mipmap 链 = 4/3*w*h*4），
#     4 张共 5.33 MB -> 1.33 MB，这是首屏关键路径（加载屏自己就要显示地面材质）。
#   * 层尺寸由 map_baker._build_terrain_material_tex 按**实际读到的图**决定，
#     所以文件名仍叫 material_512_*、内容是 256² 也是自洽的。
RES_STUB_TARGETS = [
    f"assets/textures/loading_prebaked_v1/material_512_{i}.res" for i in range(4)
]
RES_STUB_SIZES = "512"
RES_STUB_SCRIPT = "res://tools/web_tex_stub_loading_materials.gd"

# ---- 源图分辨率上限（web-only，仅"单张整图"）--------------------------------
# 只允许**单张整图**：图集（AtlasTexture）缩小后 .tres 里的 region 会整体错位。
# `assets/icons/paper/*.png` 是 1254^2 图集，region 实测约 197x178（已经小于 256），
# 所以那里的图集一律**不缩**，只降 lossy 质量（规则见 RULES 的 assets/icons/**）。
# `assets/icons/era/era_*.png` 是 1254^2 单张整图，`scripts/ui/components/era_indicator.gd`
# 直接 load()，显示面 UITokens.ERA_BADGE_SIZE = 220 px，缩到 256 完全够。
MAX_DIM_RULES: list[tuple[str, int]] = [
    # [2026-11-01 定案] era 徽章（1254² -> 256²）已由用户认可，作为**永久降采样**留在
    # 仓库里（源 PNG 就是 256² 了），不再进 web-only 的构建期缩放/还原流程。
    # 这里留空表 + 机制，将来要临时缩别的"整图"资源时再填。
]

# ---- 按倍率缩放（web-only，单张整图）---------------------------------------
# resource_art 的 5 张是"地表覆盖层 / 树冠 / 动物"，用户已授权 web 端降分辨率
# （它们是地形视觉本身，桌面保持原样）。倍率由环境变量控制，`=1` 即回退：
#   PK_WEB_RESOURCE_ART_SCALE=1    不缩
#   PK_WEB_RESOURCE_ART_SCALE=0.5  各边减半（默认）
# 注意：这些源图的层数是 vertical strip（512x8192 = 16 层），等比缩放不会破坏帧布局。
SCALE_RULES: list[tuple[str, str, float]] = [
    ("assets/textures/resource_art/cover_albedo.png", "PK_WEB_RESOURCE_ART_SCALE", 0.5),
    ("assets/textures/resource_art/cover_normal.png", "PK_WEB_RESOURCE_ART_SCALE", 0.5),
    ("assets/textures/resource_art/crown_atlas.png", "PK_WEB_RESOURCE_ART_SCALE", 0.5),
    ("assets/textures/resource_art/crown_normal.png", "PK_WEB_RESOURCE_ART_SCALE", 0.5),
    ("assets/textures/resource_art/fauna_atlas.png", "PK_WEB_RESOURCE_ART_SCALE", 0.5),
    # 法线跟着 albedo 同倍率缩放，但质量档见 RULES 里的 *_normal 规则（>=0.90）
]

# 平铺采样的贴图：缩小时必须用环绕卷积，否则左右/上下边不再连续（tiling seam 翻倍，
# 肉眼就是地图上的格线）。cover_* 是 16 层无缝地表覆盖层；crown/fauna 是精灵图集，
# 不按 tile 采样，用普通 resize。
TILED_PATTERNS: list[str] = [
    "assets/textures/resource_art/cover_*.png",
]

# 只处理这些 importer 的 .import（其余 font_data/script 一律不碰）
TARGET_IMPORTERS = {"texture", "2d_array_texture"}

STATE_DIRNAME = "web_tex_downgrade"


# --------------------------------------------------------------------------
# .import 读写
# --------------------------------------------------------------------------
SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")


@dataclass
class ImportFile:
    res_path: str
    abspath: str
    importer: str = ""
    params: dict[str, str] = field(default_factory=dict)
    dests: list[str] = field(default_factory=list)
    raw: bytes = b""

    @classmethod
    def load(cls, res_path: str, abspath: str) -> "ImportFile":
        with open(abspath, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8", "surrogateescape")
        importer = ""
        params: dict[str, str] = {}
        dests: list[str] = []
        section = ""
        for line in text.splitlines():
            s = line.strip()
            m = SECTION_RE.match(s)
            if m:
                section = m.group(1)
                continue
            if section == "remap" and s.startswith("importer="):
                importer = s.split("=", 1)[1].strip().strip('"')
            elif section == "remap" and s.startswith("path") and "=" in s:
                v = s.split("=", 1)[1].strip().strip('"')
                if v.startswith("res://"):
                    dests.append(v)
            elif section == "deps" and s.startswith("dest_files="):
                body = s.split("=", 1)[1].strip().strip("[]")
                for part in body.split(","):
                    part = part.strip().strip('"')
                    if part.startswith("res://"):
                        dests.append(part)
            elif section == "params" and "=" in s:
                k, v = s.split("=", 1)
                params[k.strip()] = v.strip().strip('"')
        seen: set[str] = set()
        dests = [d for d in dests if not (d in seen or seen.add(d))]
        return cls(res_path, abspath, importer, params, dests, raw)

    def patched(self, changes: dict[str, str], removals: tuple[str, ...] = ()) -> bytes:
        """只改 [params] 里指定的键，其余字节原样保留（行尾/顺序/其它键都不动）。

        removals 里的键会被整行删掉（还原一个"原本不存在"的键时用）。
        """
        if not changes and not removals:
            return self.raw
        text = self.raw.decode("utf-8", "surrogateescape")
        nl = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(nl)
        out: list[str] = []
        section = ""
        params_at = -1
        set_keys: set[str] = set()
        for line in lines:
            s = line.strip()
            m = SECTION_RE.match(s)
            if m:
                section = m.group(1)
                if section == "params":
                    params_at = len(out)
                out.append(line)
                continue
            if section == "params" and "=" in s:
                key = s.split("=", 1)[0].strip()
                if key in removals:
                    continue
                if key in changes:
                    out.append(f"{key}={changes[key]}")
                    set_keys.add(key)
                    continue
            out.append(line)
        missing = [k for k in changes if k not in set_keys]
        if missing:
            if params_at < 0:
                raise RuntimeError(f"{self.res_path}: .import 里没有 [params] 段")
            insert_at = len(out)
            for i in range(params_at + 1, len(out)):
                if SECTION_RE.match(out[i].strip()):
                    insert_at = i
                    break
            for off, key in enumerate(missing):
                out.insert(insert_at + off, f"{key}={changes[key]}")
        return nl.join(out).encode("utf-8", "surrogateescape")


# --------------------------------------------------------------------------
# 策略求值
# --------------------------------------------------------------------------
def is_vram_variant(imp: ImportFile) -> bool:
    """`.import` 已经有 path.s3tc / path.etc2 -> 该资源带 VRAM 变体。

    这种资源不能改 compress/mode：改完 [remap] 里的 path.s3tc / path.etc2 会指向
    不再生成的产物，运行时 "Can't open file"。收益也不值得——这类图已经是
    0.5 B/px 的块压缩，唯一能降的是分辨率。
    """
    for d in imp.dests:
        name = os.path.basename(d).lower()
        if ".s3tc." in name or ".etc2." in name or ".astc." in name or ".bptc." in name:
            return True
    return False


def policy_for(res_path: str, params: dict[str, str], importer: str,
               imp: ImportFile | None = None, current_bytes: int = -1) -> tuple[dict[str, str], str]:
    """返回 (要改的参数, 说明)。说明里写清命中/跳过原因，供 plan 与报告引用。"""
    for pat, reason in KEEP:
        if fnmatch.fnmatch(res_path, pat):
            return {}, reason
    if importer not in TARGET_IMPORTERS:
        return {}, f"importer={importer or '?'} 不在目标列表"

    resolved: dict[str, str] = {}
    rule_name = ""
    min_bytes = 0
    for pat, kv, floor in RULES:
        if fnmatch.fnmatch(res_path, pat):
            if kv:
                resolved.update(kv)
                rule_name = pat
                min_bytes = max(min_bytes, floor)
            else:
                return {}, f"规则 {pat} 明确不动"

    if not resolved:
        return {}, "无规则命中"

    if 0 <= current_bytes < max(MIN_BYTES, min_bytes):
        return {}, f"当前产物只有 {current_bytes // 1024} KB，低于门槛，性价比为负"

    if imp is not None and is_vram_variant(imp):
        resolved = {k: v for k, v in resolved.items() if k == "process/size_limit"}
        if not resolved:
            return {}, ("已是 s3tc+etc2 双套 VRAM，不改 mode"
                        "（会断 [remap] 的 path.s3tc/path.etc2）")

    changed = {k: v for k, v in resolved.items() if params.get(k, "") != v}
    if not changed:
        return {}, "已是目标规格"
    return changed, f"规则 {rule_name}"


# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------
def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dest_size(project: str, res_dest: str) -> int:
    p = os.path.join(project, res_dest.replace("res://", "").replace("/", os.sep))
    try:
        return os.path.getsize(p)
    except OSError:
        return -1


def human(n: int) -> str:
    if n < 0:
        return "?"
    x = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if abs(x) < 1024.0 or unit == "GB":
            return f"{n} B" if unit == "B" else f"{x:.2f} {unit}"
        x /= 1024.0
    return f"{x:.2f} GB"


def find_godot(repo: str, explicit: str) -> str:
    if explicit and os.path.isfile(explicit):
        return explicit
    env = os.environ.get("GODOT_BIN", "")
    if env and os.path.isfile(env):
        return env
    # 与 Build-Web.cmd 一致：<repo>\..\..\Godot_v4.6.2-stable_win64.exe\<exe>
    base = repo
    for _ in range(3):
        for cand in (
            os.path.join(base, "Godot_v4.6.2-stable_win64.exe",
                         "Godot_v4.6.2-stable_win64.exe"),
            os.path.join(base, "Godot_v4.6.2-stable_win64.exe"),
        ):
            if os.path.isfile(cand):
                return cand
        base = os.path.dirname(base)
    raise SystemExit("找不到 Godot 可执行文件，请用 --godot 指定（或设 GODOT_BIN）")


def collect_imports(project: str) -> list[ImportFile]:
    out: list[ImportFile] = []
    skip_dirs = {".git", ".godot", "__pycache__", "tmp", "test_output", "docs", "android"}
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        rel = os.path.relpath(root, project).replace("\\", "/")
        for fn in files:
            if not fn.endswith(".import"):
                continue
            abspath = os.path.join(root, fn)
            res = "res://" + (f"{rel}/{fn[:-7]}" if rel != "." else fn[:-7])
            try:
                out.append(ImportFile.load(res, abspath))
            except OSError as exc:
                print(f"[warn] 读不了 {abspath}: {exc}", file=sys.stderr)
    out.sort(key=lambda i: i.res_path)
    return out


def run_import(godot: str, project: str, log_path: str) -> None:
    cmd = [godot, "--headless", "--path", project, "--import"]
    t0 = time.time()
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "wb") as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    dt = time.time() - t0
    if proc.returncode != 0:
        tail = ""
        try:
            with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
                tail = "".join(fh.readlines()[-25:])
        except OSError:
            pass
        raise RuntimeError(f"godot --import 失败 (exit={proc.returncode}, {dt:.1f}s)\n{tail}")
    print(f"[import] ok  {dt:.1f}s  (log: {log_path})")


def _backup_res_stubs(project: str, backup_root: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for rel in RES_STUB_TARGETS:
        path = os.path.join(project, rel.replace("/", os.sep))
        if not os.path.isfile(path):
            print(f"[tex] warn: 找不到 {rel}，跳过", file=sys.stderr)
            continue
        dst = os.path.join(backup_root, "res__" + rel.replace("/", "__"))
        shutil.copy2(path, dst)
        sha = sha256_file(path)
        if sha256_file(dst) != sha:
            raise RuntimeError(f"备份校验失败: {path}")
        out.append({"path": path, "rel": rel, "backup": dst,
                    "sha_before": sha, "size_before": os.path.getsize(path)})
    return out


def _restore_res_stubs(entries: list[dict[str, Any]]) -> None:
    for e in entries:
        if os.path.exists(e["backup"]):
            shutil.copy2(e["backup"], e["path"])
            if sha256_file(e["path"]) != e["sha_before"]:
                raise RuntimeError(f"还原后 sha256 不匹配: {e['path']}")


def _collect_resize_targets(project: str) -> list[dict[str, Any]]:
    """MAX_DIM_RULES / SCALE_RULES 命中的源图（相对工程根的路径 + 目标尺寸策略）。"""
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    wanted: list[tuple[str, int | None, float | None]] = []
    for pattern, max_dim in MAX_DIM_RULES:
        wanted.append((pattern, max_dim, None))
    for pattern, env_name, default_scale in SCALE_RULES:
        try:
            scale = float(os.environ.get(env_name, "") or default_scale)
        except ValueError:
            print(f"[tex] !! {env_name} 不是数字，按 {default_scale} 处理", file=sys.stderr)
            scale = default_scale
        if scale <= 0.0 or scale >= 1.0:
            print(f"[tex] {env_name}={scale:g} -> 跳过 {pattern}")
            continue
        wanted.append((pattern, None, scale))

    for root, _dirs, files in os.walk(project):
        for name in files:
            abspath = os.path.join(root, name)
            rel = os.path.relpath(abspath, project).replace("\\", "/")
            if rel in seen:
                continue
            if os.path.splitext(rel)[1].lower() not in (".png", ".webp", ".jpg", ".jpeg"):
                continue
            for pattern, max_dim, scale in wanted:
                if fnmatch.fnmatch(rel, pattern):
                    seen.add(rel)
                    out.append({"res_path": "res://" + rel, "rel": rel, "abspath": abspath,
                                "max_dim": max_dim, "scale": scale})
                    break
    return sorted(out, key=lambda e: e["res_path"])


def _resize_source(img, target: tuple[int, int], tiled: bool):
    """缩小源图。平铺贴图用 BOX（area average），其余用 LANCZOS。

    为什么平铺的不能用 LANCZOS：`cover_albedo` 是 16 层无缝地表覆盖层，按 tile 采样。
    实测同一层 512² -> 256² 时：
        原图 seam 9.38 | LANCZOS 18.92 | BICUBIC 17.27 | BILINEAR 15.30 | BOX 14.93
    （seam = 左右边列的平均差，0 表示完美拼接）。LANCZOS 的负瓣会在边缘 ringing，
    seam 翻倍到肉眼可能看到格线；BOX 是 2x2 区域平均，seam 最接近原图且不会有振铃。
    精灵图集（crown/fauna）不按 tile 采样，LANCZOS 的锐度更划算。
    """
    from PIL import Image  # noqa: PLC0415 - 只有构建机需要

    return img.resize(target, Image.BOX if tiled else Image.LANCZOS)


def _backup_and_resize_sources(project: str, backup_root: str) -> list[dict[str, Any]]:
    """把命中上限的源图临时缩到 max_dim（备份 + sha 校验），供 begin 阶段的重导入使用。

    桌面 import 状态由 cmd_end 还原（`_restore_resized_sources` + 重导入），
    所以这里不需要、也不允许改任何 .import 之外的东西。
    """
    targets = _collect_resize_targets(project)
    if not targets:
        return []
    try:
        from PIL import Image  # noqa: PLC0415 - 构建机才需要 Pillow
    except ImportError:
        print("[tex] !! Pillow 未安装，跳过源图缩放（pip install pillow）；"
              "或设 PK_WEB_SKIP_SOURCE_RESIZE=1 消除本提示", file=sys.stderr)
        return []
    if os.environ.get("PK_WEB_SKIP_SOURCE_RESIZE") == "1":
        print("[tex] PK_WEB_SKIP_SOURCE_RESIZE=1 -> 跳过源图缩放")
        return []

    entries: list[dict[str, Any]] = []
    total_before = total_after = 0
    for t in targets:
        src = t["abspath"]
        dst = os.path.join(backup_root, "src__" + t["rel"].replace("/", "__"))
        shutil.copy2(src, dst)
        sha = sha256_file(src)
        if sha256_file(dst) != sha:
            raise RuntimeError(f"源图备份校验失败: {src}")
        entry = {"res_path": t["res_path"], "abspath": src, "backup": dst,
                 "sha_before": sha, "size_before": os.path.getsize(src),
                 "max_dim": t.get("max_dim"), "scale": t.get("scale"), "resized": False}
        with Image.open(src) as img:
            before = img.size
            entry["dims_before"] = list(before)
            if t.get("scale"):
                factor = float(t["scale"])
                target = (max(1, int(round(before[0] * factor))),
                          max(1, int(round(before[1] * factor))))
            else:
                longest = max(before)
                if longest <= int(t["max_dim"]):
                    print(f"[tex] 源图已够小，跳过: {t['rel']} {before}")
                    entries.append(entry)
                    continue
                factor = float(t["max_dim"]) / float(longest)
                target = (max(1, int(round(before[0] * factor))),
                          max(1, int(round(before[1] * factor))))
            work = img.convert("RGBA") if img.mode not in ("RGBA", "RGB") else img.copy()
        tiled = any(fnmatch.fnmatch(t["rel"], pat) for pat in TILED_PATTERNS)
        work = _resize_source(work, target, tiled)
        work.save(src, format="PNG", optimize=True)
        entry.update({"resized": True, "dims_after": list(target),
                      "size_after": os.path.getsize(src)})
        total_before += entry["size_before"]
        total_after += entry["size_after"]
        print(f"[tex] 源图缩小 {t['rel']} {before} -> {target} "
              f"({human(entry['size_before'])} -> {human(entry['size_after'])})")
        entries.append(entry)
    if any(e["resized"] for e in entries):
        print(f"[tex] 源图缩放完成：{sum(1 for e in entries if e['resized'])} 张，"
              f"{human(total_before)} -> {human(total_after)}（pck 体积由重导入后的 ctex 决定）")
    return entries


def _restore_resized_sources(entries: list[dict[str, Any]]) -> None:
    for e in entries:
        if not e.get("resized"):
            continue
        shutil.copy2(e["backup"], e["abspath"])
        if sha256_file(e["abspath"]) != e["sha_before"]:
            raise RuntimeError(f"源图还原后 sha256 不匹配: {e['abspath']}")


def run_res_stub(godot: str, project: str, log_path: str) -> None:
    """跑 Godot 侧的重烘焙脚本（有 PK_WEB_DG_STUB=1 守卫，误跑不会动手）。"""
    env = dict(os.environ)
    env["PK_WEB_DG_STUB"] = "1"
    env["PK_WEB_DG_STUB_SIZES"] = RES_STUB_SIZES
    env.setdefault("PK_WEB_DG_STUB_SIZE", "256")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    t0 = time.time()
    with open(log_path, "wb") as log:
        proc = subprocess.run([godot, "--headless", "--path", project,
                               "--script", RES_STUB_SCRIPT],
                              stdout=log, stderr=subprocess.STDOUT, env=env)
    dt = time.time() - t0
    if proc.returncode != 0:
        tail = ""
        try:
            with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
                tail = "".join(fh.readlines()[-25:])
        except OSError:
            pass
        raise RuntimeError(f"重烘焙 .res 失败 (exit={proc.returncode}, {dt:.1f}s)\n{tail}")
    print(f"[res] 重烘焙 ok  {dt:.1f}s  (log: {log_path})")


# --------------------------------------------------------------------------
# 子命令
# --------------------------------------------------------------------------
def cmd_plan(args: Any, state: str) -> int:
    project = args.project
    rows = []
    skipped: list[tuple[str, str]] = []
    for imp in collect_imports(project):
        cur = sum(max(0, dest_size(project, d)) for d in imp.dests)
        changes, why = policy_for(imp.res_path, imp.params, imp.importer, imp, cur)
        if not changes:
            if imp.importer in TARGET_IMPORTERS:
                skipped.append((imp.res_path, why))
            continue
        before = cur
        rows.append((imp, changes, why, before))
    if not rows:
        print("没有任何 .import 命中降规格策略。")
        return 0
    print(f"# 计划：{len(rows)} 个资源（当前已导入体积合计 "
          f"{human(sum(r[3] for r in rows))}）\n")
    print("| 源资源 | 改前 | 改后 | 当前体积 | 依据 |")
    print("| --- | --- | --- | ---: | --- |")
    for imp, changes, why, before in sorted(rows, key=lambda r: -r[3]):
        def fmt(d: dict[str, str]) -> str:
            return (f"mode={d.get('compress/mode', '-')} "
                    f"q={d.get('compress/lossy_quality', '-')}")
        print(f"| `{imp.res_path}` | {fmt(imp.params)} | {fmt({**imp.params, **changes})} | "
              f"{human(before)} | {why} |")
    print(f"\n合计 {len(rows)} 项，当前 {human(sum(r[3] for r in rows))}。")
    res_now = sum(max(0, dest_size(project, r)) for r in RES_STUB_TARGETS)
    if res_now > 0:
        print(f"\n另有 prebaked .res {len(RES_STUB_TARGETS)} 个：当前 {human(res_now)}"
              f"，导出期重烘焙到 256²（约 1.3 MB）后还原。")
    if skipped and args.verbose:
        print(f"\n## 跳过的纹理（{len(skipped)} 项）\n")
        by_reason: dict[str, int] = {}
        for _p, why in skipped:
            by_reason[why] = by_reason.get(why, 0) + 1
        for why, cnt in sorted(by_reason.items(), key=lambda kv: -kv[1]):
            print(f"- {cnt:4d} 项：{why}")
    return 0


def cmd_begin(args: Any, state: str) -> int:
    if os.environ.get("PK_WEB_SKIP_TEXTURE_DOWNGRADE") == "1":
        print("[tex] PK_WEB_SKIP_TEXTURE_DOWNGRADE=1 -> 跳过降规格")
        return 0

    project = args.project
    godot = find_godot(args.repo, args.godot)
    manifest_path = os.path.join(state, "manifest.json")

    # 残留状态自愈：上次构建被 Ctrl-C 打断时，先把上次的备份还回去
    if os.path.exists(manifest_path):
        print("[tex] 发现上次未完成的降规格状态 -> 先自动还原")
        rc = cmd_end(args, state)
        if rc != 0:
            print("[tex] !! 自动还原失败，拒绝继续", file=sys.stderr)
            return 1

    entries: list[dict[str, Any]] = []
    to_write: list[tuple[str, bytes]] = []

    for imp in collect_imports(project):
        if args.only and not any(fnmatch.fnmatch(imp.res_path, g) for g in args.only):
            continue
        before = {d: dest_size(project, d) for d in imp.dests}
        cur = sum(max(0, v) for v in before.values())
        changes, why = policy_for(imp.res_path, imp.params, imp.importer, imp, cur)
        if not changes:
            continue
        entries.append({
            "res_path": imp.res_path,
            "import_abspath": imp.abspath,
            "importer": imp.importer,
            "params_before": imp.params,
            "params_changed": changes,
            "dests": imp.dests,
            "dest_sizes_before": before,
            "why": why,
        })
        to_write.append((imp.abspath, imp.patched(changes)))

    if not entries:
        print("[tex] 没有资源命中策略，跳过")
        return 0

    # 1) 备份（先备份再落盘：之后任何一步失败都能还原）
    backup_root = os.path.join(state, "backup")
    os.makedirs(backup_root, exist_ok=True)
    for i, e in enumerate(entries):
        src = e["import_abspath"]
        rel = os.path.relpath(src, project).replace("\\", "/").replace("/", "__")
        dst = os.path.join(backup_root, f"{i:04d}__{rel}")
        shutil.copy2(src, dst)
        e["backup"] = dst
        e["import_sha_before"] = sha256_file(src)
        if sha256_file(dst) != e["import_sha_before"]:
            raise RuntimeError(f"备份校验失败: {src}")

    res_entries = _backup_res_stubs(project, backup_root)
    resized_sources = _backup_and_resize_sources(project, backup_root)

    def save_manifest(totals: dict[str, int] | None = None) -> None:
        payload: dict[str, Any] = {
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
            "godot": godot,
            "project": project,
            "entries": entries,
            "res_entries": res_entries,
            "resized_sources": resized_sources,
            "import_log": os.path.join(state, "import_begin.log"),
        }
        if totals:
            payload["totals"] = totals
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)

    save_manifest()
    print(f"[tex] 已备份 {len(entries)} 个 .import + {len(res_entries)} 个 .res -> {backup_root}")

    try:
        for path, data in to_write:
            with open(path, "wb") as fh:
                fh.write(data)
        # 记下"我们写下的内容"的 sha：end 用它判断期间有没有别人改过这个文件
        for e in entries:
            e["import_sha_after"] = sha256_file(e["import_abspath"])
        save_manifest()
        print(f"[tex] 已改写 {len(to_write)} 个 .import（web 规格）")
        if args.no_import:
            print("[tex] --no-import：跳过重导入")
            return 0
        if res_entries:
            run_res_stub(godot, project, os.path.join(state, "res_stub.log"))
        run_import(godot, project, os.path.join(state, "import_begin.log"))

        total_before = total_after = 0
        bad: list[str] = []
        for e in entries:
            after = {d: dest_size(project, d) for d in e["dests"]}
            e["dest_sizes_after"] = after
            b = sum(max(0, v) for v in e["dest_sizes_before"].values())
            a = sum(max(0, v) for v in after.values())
            total_before += b
            total_after += a
            if a <= 0:
                bad.append(f"{e['res_path']}: 重导入后没有产物（{after}）")
            elif a > b:
                bad.append(f"{e['res_path']}: 体积反而变大 {human(b)} -> {human(a)}")
        res_before = res_after = 0
        for r in res_entries:
            r["size_after"] = os.path.getsize(r["path"])
            res_before += r["size_before"]
            res_after += r["size_after"]
            if r["size_after"] >= r["size_before"]:
                bad.append(f"{r['rel']}: 重烘焙后没有变小 "
                           f"{human(r['size_before'])} -> {human(r['size_after'])}")
        if bad:
            raise RuntimeError("降规格结果异常：\n  " + "\n  ".join(bad[:10]))

        save_manifest({"before": total_before, "after": total_after,
                       "res_before": res_before, "res_after": res_after})
        print(f"[tex] texture 降规格：{human(total_before)} -> {human(total_after)}"
              f"（省 {human(total_before - total_after)}，"
              f"{(total_before - total_after) / max(1, total_before) * 100:.1f}%）")
        if res_entries:
            print(f"[tex] prebaked .res：{human(res_before)} -> {human(res_after)}"
                  f"（省 {human(res_before - res_after)}）")
        top = sorted(entries,
                     key=lambda e: -(sum(max(0, v) for v in e["dest_sizes_before"].values()) -
                                     sum(max(0, v) for v in e["dest_sizes_after"].values())))[:15]
        print(f"\n{'源资源':64s} {'之前':>10s} {'之后':>10s} {'省':>10s}")
        for e in top:
            b = sum(max(0, v) for v in e["dest_sizes_before"].values())
            a = sum(max(0, v) for v in e["dest_sizes_after"].values())
            print(f"{e['res_path'].replace('res://', '')[:64]:64s} "
                  f"{human(b):>10s} {human(a):>10s} {human(b - a):>10s}")
        return 0
    except BaseException:
        # 任何失败：立刻还原，绝不把半改状态留给导出
        print("[tex] !! 降规格失败，立刻还原", file=sys.stderr)
        _restore_files(entries)
        _restore_res_stubs(res_entries)
        _drop_manifest(manifest_path)
        raise


def _restore_files(entries: list[dict[str, Any]]) -> None:
    """把 .import **整文件**还原成 begin 之前的样子，并用整文件 sha256 校验。

    2026-11-01 事故（必须记住）：早期版本在"构建窗口内有人改过同一个文件"时会退化成
    "只把我们改过的键还原、别人的改动保留"。那不是安全策略，而是**制造混合态**：
    当时 77 个 .import 被并行工具改成了 web 变体，end 只回滚了我们那几个键，于是
    paper 图集留下 `vram_texture: true` + `path.bptc/astc` —— 下一次构建每个 UI 图集
    都会多带一份 s3tc/astc 变体（+5~10 MB），桌面导入设置也被悄悄改掉。

    整文件还原才是唯一正确解：begin 前备份的是原件，end 把原件字节写回，
    "桌面/编辑器字节级不变"就自动成立，不需要读懂别人改了什么。校验用备份的整文件
    sha256；不一致就抛错中止 —— 宁可不还原，也不要带着脏状态继续导出。
    """
    restored = 0
    for e in entries:
        backup = e.get("backup", "")
        path = e["import_abspath"]
        expected = e.get("import_sha_before", "")
        if not backup or not os.path.exists(backup):
            raise RuntimeError(f"缺少 .import 备份，拒绝继续（状态未知）: {path}")
        if not expected or sha256_file(backup) != expected:
            raise RuntimeError(f"备份文件自身不完整/已损坏，拒绝写回: {backup}")
        shutil.copy2(backup, path)
        got = sha256_file(path)
        if got != expected:
            raise RuntimeError(
                "整文件还原后 sha256 不匹配，已中止（导入缓存可能处于混合态）:\n"
                f"  file     = {path}\n  expected = {expected}\n  got      = {got}\n"
                "  处理：python tools\\web_tex_downgrade.py restore，"
                "或对该文件 git checkout -- 恢复 HEAD 版本")
        restored += 1
    if restored:
        print(f"[tex] 已整文件还原 {restored} 个 .import（每个都用 sha256 校验过）")


def _drop_manifest(manifest_path: str) -> None:
    try:
        if os.path.exists(manifest_path):
            os.remove(manifest_path)
    except OSError:
        pass


def cmd_end(args: Any, state: str) -> int:
    manifest_path = os.path.join(state, "manifest.json")
    if os.environ.get("PK_WEB_SKIP_TEXTURE_DOWNGRADE") == "1":
        print("[tex] PK_WEB_SKIP_TEXTURE_DOWNGRADE=1 -> 无需还原")
        return 0
    if not os.path.exists(manifest_path):
        print("[tex] 没有待还原的降规格状态（无需操作）")
        return 0

    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    entries = manifest["entries"]
    res_entries = manifest.get("res_entries", [])
    project = manifest.get("project", args.project)
    godot = manifest.get("godot") or find_godot(args.repo, args.godot)

    # 1) 先还原文件（.import 整文件写回 + 整文件 sha 校验；.res 直接复制回去）
    #    还原失败必须大声中止：带着混合态的 .import 去导出，等于把脏状态写进包体。
    try:
        _restore_files(entries)
        _restore_res_stubs(res_entries)
        if res_entries:
            print(f"[tex] 已还原 {len(res_entries)} 个 prebaked .res")
        resized_sources = manifest.get("resized_sources", [])
        _restore_resized_sources(resized_sources)
        if any(e.get("resized") for e in resized_sources):
            print(f"[tex] 已还原 {sum(1 for e in resized_sources if e.get('resized'))} 张被缩小的源图")
    except RuntimeError as exc:
        print(f"[tex] !! prebaked .res / 源图还原失败：{exc}", file=sys.stderr)
        return 1

    # 2) 把本机导入缓存也恢复成桌面规格
    if args.no_import:
        print("[tex] --no-import：跳过还原后的重导入（本机缓存仍是 web 规格！）")
    else:
        try:
            run_import(godot, project, os.path.join(state, "import_end.log"))
        except RuntimeError as exc:
            print(f"[tex] !! 还原后重导入失败：{exc}", file=sys.stderr)
            print("[tex]    .import 已还原，但 .godot/imported 仍是 web 规格；"
                  "请手动跑一次 `godot --headless --path <project> --import`",
                  file=sys.stderr)
            return 1

    # 3) 校验 ctex 体积回到 before
    drift: list[str] = []
    for e in entries:
        now = {d: dest_size(project, d) for d in e["dests"]}
        before = e.get("dest_sizes_before", {})
        for d, b in before.items():
            if b <= 0:
                continue
            a = now.get(d, -1)
            if a != b:
                drift.append(f"{e['res_path']} [{os.path.basename(d)}] {human(b)} -> {human(a)}")
    if drift:
        print(f"[tex] !! 还原后仍有 {len(drift)} 个产物体积与原始不一致（缓存可能没重建）：",
              file=sys.stderr)
        for line in drift[:10]:
            print("    " + line, file=sys.stderr)
        print("[tex]    再跑一次 `--import` 或用编辑器打开工程即可修复。", file=sys.stderr)
        return 1

    shutil.rmtree(state, ignore_errors=True)
    if args.no_import:
        print(f"[tex] 已还原 .import/.res（{len(entries)} 项）；--no-import 所以没重建缓存")
    else:
        print(f"[tex] 已还原 .import 并重建桌面缓存（{len(entries)} 项，产物体积全部回到原值）")
    return 0


def cmd_status(args: Any, state: str) -> int:
    manifest_path = os.path.join(state, "manifest.json")
    if not os.path.exists(manifest_path):
        print("当前没有降规格状态（干净）。")
        return 0
    with open(manifest_path, "r", encoding="utf-8") as fh:
        m = json.load(fh)
    tot = m.get("totals") or {}
    print(f"发现未完成状态：{m.get('created')}，{len(m['entries'])} 个 .import 处于 web 规格")
    if tot:
        print(f"  实测：{human(tot.get('before', 0))} -> {human(tot.get('after', 0))}")
    print("  本机 .import 现在**不是**桌面规格，请运行："
          "python tools\\web_tex_downgrade.py restore")
    return 0


# --------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description="Web 导出专用纹理降规格（构建期临时改 + 事后恢复）")
    ap.add_argument("action", choices=["plan", "begin", "end", "restore", "status"])
    ap.add_argument("--repo", default=repo)
    ap.add_argument("--project", default=os.path.join(repo, "Project", "project-keynes"))
    ap.add_argument("--godot", default="", help="Godot 可执行文件；缺省用 GODOT_BIN 或同级目录")
    ap.add_argument("--state", default="", help=f"状态目录（默认 tmp/{STATE_DIRNAME}）")
    ap.add_argument("--only", action="append", default=[],
                    help="只处理匹配的 res:// glob（可多次给；实验用）")
    ap.add_argument("--no-import", action="store_true", help="不跑 godot --import（调试用）")
    ap.add_argument("--verbose", action="store_true", help="plan 时列出跳过原因统计")
    args = ap.parse_args(argv)
    state = args.state or os.path.join(repo, "tmp", STATE_DIRNAME)

    try:
        if args.action == "plan":
            return cmd_plan(args, state)
        if args.action == "begin":
            return cmd_begin(args, state)
        if args.action in ("end", "restore"):
            return cmd_end(args, state)
        return cmd_status(args, state)
    except RuntimeError as exc:
        print(f"[tex] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
