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
# 实测 4 × 5.33 MB = 21.3 MB，而 Web 运行时按 TERRAIN_MATERIAL_SIZE_MOBILE(512) 读，
# 1024 那套在 web 上永远不会被 load（见 map_baker.gd:341 / 1215）。
# 处理方式：导出期把文件内容换成 256²（保留文件本身，避免导出器 missing），
# 导出后连字节一起还原。
RES_STUB_TARGETS = [
    "assets/textures/loading_prebaked_v1/material_1024_%d.res" % i for i in range(4)
]
RES_STUB_SCRIPT = "res://tools/web_tex_stub_loading_materials.gd"

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


def run_res_stub(godot: str, project: str, log_path: str) -> None:
    """跑 Godot 侧的重烘焙脚本（有 PK_WEB_DG_STUB=1 守卫，误跑不会动手）。"""
    env = dict(os.environ)
    env["PK_WEB_DG_STUB"] = "1"
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

    def save_manifest(totals: dict[str, int] | None = None) -> None:
        payload: dict[str, Any] = {
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
            "godot": godot,
            "project": project,
            "entries": entries,
            "res_entries": res_entries,
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
    """把 .import 还原成 begin 之前的样子。

    两条路：
      1) 当前内容 == begin 写下的那份（正常情况）：直接复制回备份字节，保证逐字节一致。
      2) 期间有人改过这个文件（多 agent/多构建并发）：**只把我们改过的那几个键还原**，
         别人的改动保留，并告警——绝不整文件覆盖掉别人的编辑。
    """
    exact = surgical = 0
    for e in entries:
        backup = e.get("backup", "")
        path = e["import_abspath"]
        if not backup or not os.path.exists(backup):
            continue
        cur = sha256_file(path)
        if e.get("import_sha_after") and cur == e["import_sha_after"]:
            shutil.copy2(backup, path)
            if sha256_file(path) != e.get("import_sha_before", sha256_file(path)):
                raise RuntimeError(f"还原后 sha256 不匹配: {path}")
            exact += 1
            continue
        # 并发修改：按 key 还原
        try:
            imp = ImportFile.load(e["res_path"], path)
            before_params = e.get("params_before", {})
            changes = {k: before_params[k] for k in e["params_changed"] if k in before_params}
            removals = tuple(k for k in e["params_changed"] if k not in before_params)
            with open(path, "wb") as fh:
                fh.write(imp.patched(changes, removals))
            surgical += 1
        except Exception as exc:  # noqa: BLE001 —— 还原失败必须让人看见
            raise RuntimeError(f"并发修改后按 key 还原失败({path}): {exc}") from exc
    if exact or surgical:
        msg = f"[tex] 已还原 {exact + surgical} 个 .import"
        if surgical:
            msg += (f"（其中 {surgical} 个在构建窗口内被别的改动动过，"
                    f"只还原了我们改的键，其余内容保留）")
        print(msg)


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

    # 1) 先还原文件（.res 直接复制回去；.import 直接复制 + sha 校验）
    _restore_files(entries)
    try:
        _restore_res_stubs(res_entries)
        if res_entries:
            print(f"[tex] 已还原 {len(res_entries)} 个 prebaked .res")
    except RuntimeError as exc:
        print(f"[tex] !! prebaked .res 还原失败：{exc}", file=sys.stderr)
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
