#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web_bank_downgrade.py —— Web 导出专用的 FMOD bank 降质（构建期临时换，事后必恢复）。

问题
----
`Music.bank` 单个 91.04 MiB，占 Web pck 的 27.7%（见 `tools/pck_audit.py`）。
根因不是"没压缩"，而是**发错平台**：工程里 Desktop 平台的编码设置是
Vorbis quality=70（`Metadata/EncodingSetting/{fa3463e9-...}.xml`），而
HTML5 平台一直是 quality=37（`{e8cf84fd-...}.xml`）。Web 包却一直在带
`banks/Desktop/` 那一套。

为什么不能靠 export_presets.cfg 的 exclude_filter 解决
------------------------------------------------------
排除规则本来就有（`assets/audio/banks/*`），但**只要 FmodGodot 被挂进
`.godot/extension_list.cfg`，它的 EditorExportPlugin 就会用 `add_file()`
把 bank 硬塞进包**，而 `add_file()` 绕过一切 filter。实测对照：
  * 11-01 构建（只有 dots_ext）→ pck 里 0 个 .bank，88.16 MiB
  * 11-02 构建（加了 FmodGodot）→ pck 里 91.38 MiB 的 bank，345.01 MiB
所以唯一的杠杆是**让源文件本身变小**，也就是换成 HTML5 平台那套。

为什么两份都要换
----------------
pck 目录表里 bank 的路径是 `assets/audio/banks/Desktop/Music.bank`（源路径），
而 `.godot/imported/Music.bank-<hash>.bank` 是导入缓存，两者当前逐字节相同
（FmodBank 导入器就是拷贝）。导出时读的是哪一份不该靠猜，所以两份一起换，
并把 `.godot/imported/*.md5` 的两个 md5 一起改写成新内容的 md5 —— 这样
Godot 的脏检查（比对 source_md5）认为没变化，**不会触发重导入**，
也就不需要 FmodGodot 在编辑器里注册，天然与 `.gdignore` 状态无关。

安全阀
------
    PK_WEB_SKIP_BANK_DOWNGRADE=1   begin/end 都是 no-op（exit 0）
    begin 前校验：HTML5 那套存在、RIFF/FEV 头合法、总体积确实更小
    备份失败或写后校验失败 → 立刻还原并 exit 1（绝不留下半改状态）
    end 还原后逐个校验 sha256 与备份一致
    构建进程被 Ctrl-C 杀掉 → 下次 begin 发现残留状态会**先自动还原**

用法
----
    python tools\\web_bank_downgrade.py plan
    python tools\\web_bank_downgrade.py begin
    python tools\\web_bank_downgrade.py end
    python tools\\web_bank_downgrade.py restore
    python tools\\web_bank_downgrade.py status
    python tools\\web_bank_downgrade.py verify --pck WebBuild\\ProjectKeynes.pck

前提：`Audio/ProjectKeynes/Build/HTML5/` 存在且不比 Desktop 那套旧 ——
由 `Build-FMOD-Banks.cmd`（默认同时编 Desktop + HTML5）保证。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from dataclasses import dataclass
from typing import Any

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(REPO, "Project", "project-keynes")
BANK_SRC = os.path.join(PROJECT, "assets", "audio", "banks", "Desktop")
HTML5_BUILD = os.path.join(REPO, "Audio", "ProjectKeynes", "Build", "HTML5")
IMPORTED = os.path.join(PROJECT, ".godot", "imported")
STATE_DIR = os.path.join(REPO, "tmp", "web_bank_downgrade")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
BACKUP_DIR = os.path.join(STATE_DIR, "backup")

# 核心 bank：每个 web 包都必须带，只是换成 HTML5 平台那份（体积差别很小）。
CORE_BANKS = ["Master.strings.bank", "Master.bank", "Music.bank", "UI.bank"]

# 时代 bank：每个 8~10 MB，而一局只会用到其中一个（见 tools/audio/split_music_banks.py）。
# Web 的 boot pck 里**一个都不能有** —— FmodGodot 的 add_file() 会绕过
# export_presets.cfg 的 exclude，所以只能把它们从工程里挪走，导出后再作为独立文件
# 发布到 WebBuild 根目录，由运行期按时代 fetch。
ERA_BANKS = ["Music_stone.bank", "Music_agrarian.bank", "Music_kingdom.bank",
             "Music_empire.bank"]

ALL_BANKS = CORE_BANKS + ERA_BANKS

MODE_SWAP = "swap"      # 换成 HTML5 平台那份
MODE_REMOVE = "remove"  # 整个从工程里挪走，导出后单独发布

SKIP_ENV = "PK_WEB_SKIP_BANK_DOWNGRADE"

# 允许总账至少省这么多才算成功，防止误把更大的文件换进来。
MIN_SAVING_BYTES = 4 * 1024 * 1024


# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------
def mb(n: float) -> str:
    return f"{n / 1048576:.2f} MB"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def md5_file(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_bank_header(path: str) -> None:
    """FMOD bank 是 RIFF 容器，`FEV ` 在偏移 8。

    只校验这一点，是因为它足以挡住"空文件 / Git LFS 指针 / 拷错成 .fsb"
    这类事故，又不会因为 FMOD 小版本升级而误报。
    """
    size = os.path.getsize(path)
    if size < 64:
        raise ValueError(f"{path} 只有 {size} B，不像一个 bank")
    with open(path, "rb") as fh:
        head = fh.read(16)
    if head[0:4] != b"RIFF":
        raise ValueError(f"{path} 头 4 字节是 {head[0:4]!r}，不是 RIFF")
    if head[8:12] != b"FEV ":
        raise ValueError(f"{path} 偏移 8 是 {head[8:12]!r}，不是 'FEV '")


def imported_path(bank: str) -> str | None:
    """从 `.import` 的 dest_files 里取导入缓存路径；没有就返回 None。"""
    imp = os.path.join(BANK_SRC, bank + ".import")
    if not os.path.exists(imp):
        return None
    with open(imp, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("dest_files="):
                inner = line[len("dest_files="):].strip()
                if not inner.startswith("["):
                    return None
                rel = inner.strip("[]").split(",")[0].strip().strip('"')
                if not rel.startswith("res://"):
                    return None
                return os.path.join(PROJECT, rel[len("res://"):].replace("/", os.sep))
    return None


def md5_sidecar(dest: str | None) -> str | None:
    if not dest:
        return None
    cand = os.path.splitext(dest)[0] + ".md5"
    return cand if os.path.exists(cand) else None


def md5_text(source_md5: str, dest_md5: str) -> str:
    return f'source_md5="{source_md5}"\ndest_md5="{dest_md5}"\n'


def skipped() -> bool:
    return os.environ.get(SKIP_ENV, "").strip().lower() in {"1", "true", "yes", "on"}


# --------------------------------------------------------------------------
# 状态
# --------------------------------------------------------------------------
@dataclass
class Record:
    bank: str
    src: str
    src_sha: str
    src_size: int
    mode: str = MODE_SWAP
    dest: str | None = None
    dest_sha: str = ""
    dest_size: int = 0
    sidecar: str | None = None
    sidecar_text: str = ""
    new_sha: str = ""
    new_md5: str = ""
    new_size: int = 0


def load_state() -> dict[str, Any] | None:
    if not os.path.exists(STATE_FILE):
        return None
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"状态文件损坏: {STATE_FILE}: {exc}") from exc


def save_state(records: list[Record]) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    payload = {
        "schema": 1,
        "project": PROJECT,
        "bank_src": BANK_SRC,
        "html5_build": HTML5_BUILD,
        "records": [
            {
                "bank": r.bank,
                "src": r.src,
                "src_sha": r.src_sha,
                "src_size": r.src_size,
                "mode": r.mode,
                "dest": r.dest,
                "dest_sha": r.dest_sha,
                "dest_size": r.dest_size,
                "sidecar": r.sidecar,
                "sidecar_text": r.sidecar_text,
                "new_sha": r.new_sha,
                "new_md5": r.new_md5,
                "new_size": r.new_size,
            }
            for r in records
        ],
    }
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, STATE_FILE)


# --------------------------------------------------------------------------
# 还原（begin 的自愈、end、restore 共用）
# --------------------------------------------------------------------------
def restore_from_state(state: dict[str, Any], *, quiet: bool = False) -> int:
    problems: list[str] = []
    restored = 0
    for rec in state.get("records", []):
        bank = rec["bank"]
        # 1) 源 bank
        backup = os.path.join(BACKUP_DIR, bank + ".orig")
        if not os.path.exists(backup):
            problems.append(f"{bank}: 缺备份 {backup}")
            continue
        if sha256_file(backup) != rec["src_sha"]:
            problems.append(f"{bank}: 备份 sha256 与开始时不一致，拒绝还原")
            continue
        shutil.copy2(backup, rec["src"])
        if sha256_file(rec["src"]) != rec["src_sha"]:
            problems.append(f"{bank}: 还原后源文件 sha256 不匹配")
            continue

        # 2) 导入缓存
        dest = rec.get("dest")
        if dest:
            dbackup = os.path.join(BACKUP_DIR, bank + ".dest")
            if rec.get("dest_sha"):
                if not os.path.exists(dbackup):
                    problems.append(f"{bank}: 缺导入缓存备份 {dbackup}")
                    continue
                shutil.copy2(dbackup, dest)
                if sha256_file(dest) != rec["dest_sha"]:
                    problems.append(f"{bank}: 还原后导入缓存 sha256 不匹配")
                    continue

        # 3) md5 边车
        sidecar = rec.get("sidecar")
        if sidecar:
            if os.path.exists(sidecar):
                os.unlink(sidecar)
            if rec.get("sidecar_text"):
                with open(sidecar, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(rec["sidecar_text"])
        restored += 1

    if problems:
        print("[bank] 还原失败：", file=sys.stderr)
        for p in problems:
            print(f"[bank]   - {p}", file=sys.stderr)
        print(
            "[bank] 本机 bank 可能处于混合态。检查清单：\n"
            f"[bank]   {BANK_SRC}\n"
            f"[bank]   {IMPORTED}\n"
            "[bank] 全部是 Desktop 那套 91 MB 的原始 bank 才算干净；"
            "否则用 git checkout 恢复源，并重跑 Build-FMOD-Banks.cmd。",
            file=sys.stderr,
        )
        return 1

    if os.path.exists(STATE_FILE):
        os.unlink(STATE_FILE)
    if not quiet:
        print(f"[bank] 已还原 {restored} 个 bank（每个都校验过 sha256）")
    return 0


# --------------------------------------------------------------------------
# plan
# --------------------------------------------------------------------------
def collect_plan() -> tuple[list[Record], list[str]]:
    records: list[Record] = []
    problems: list[str] = []
    for bank in ALL_BANKS:
        mode = MODE_SWAP if bank in CORE_BANKS else MODE_REMOVE
        src = os.path.join(BANK_SRC, bank)
        new = os.path.join(HTML5_BUILD, bank)
        if not os.path.exists(src):
            problems.append(f"{bank}: 源文件不存在 {src}")
            continue
        if not os.path.exists(new):
            problems.append(
                f"{bank}: 没有 HTML5 版本 {new} —— 先跑 Build-FMOD-Banks.cmd"
            )
            continue
        try:
            check_bank_header(src)
            check_bank_header(new)
        except ValueError as exc:
            problems.append(str(exc))
            continue

        rec = Record(
            bank=bank,
            src=src,
            src_sha=sha256_file(src),
            src_size=os.path.getsize(src),
            mode=mode,
            new_sha=sha256_file(new),
            new_md5=md5_file(new),
            new_size=os.path.getsize(new),
        )
        rec.dest = imported_path(bank)
        if rec.dest and os.path.exists(rec.dest):
            rec.dest_sha = sha256_file(rec.dest)
            rec.dest_size = os.path.getsize(rec.dest)
        else:
            rec.dest = None
        sc = md5_sidecar(rec.dest)
        if sc:
            rec.sidecar = sc
            with open(sc, "r", encoding="utf-8") as fh:
                rec.sidecar_text = fh.read()
        records.append(rec)
    return records, problems


def cmd_plan(_args: Any) -> int:
    records, problems = collect_plan()
    if problems:
        for p in problems:
            print(f"[bank] 错误: {p}", file=sys.stderr)
        return 1

    print("# Web bank 计划")
    print()
    print("| bank | 处理 | Desktop | HTML5 | 对 pck 的影响 |")
    print("| --- | --- | ---: | ---: | ---: |")
    before = after = 0
    for r in records:
        before += r.src_size
        if r.mode == MODE_REMOVE:
            # 整个挪出工程：pck 里省掉全部体积，导出后单独发布，不进 boot 包。
            after += 0
            delta = -r.src_size
            act = "移出 pck + 单独发布"
        else:
            after += r.new_size
            delta = r.new_size - r.src_size
            act = "换成 HTML5 版"
        print(
            f"| {r.bank} | {act} | {mb(r.src_size)} | {mb(r.new_size)} | "
            f"{delta / 1048576:+.2f} MB |"
        )
    print(f"| **合计** | | **{mb(before)}** | **{mb(after)}** | "
          f"**{(after - before) / 1048576:+.2f} MB** |")
    print()
    print(f"源目录:   {BANK_SRC}")
    print(f"HTML5 源: {HTML5_BUILD}")
    return 0


# --------------------------------------------------------------------------
# begin
# --------------------------------------------------------------------------
def cmd_begin(_args: Any) -> int:
    if skipped():
        print(f"[bank] 跳过（{SKIP_ENV}=1）：pck 会带 Desktop q70 的 bank")
        return 0

    existing = load_state()
    if existing:
        print("[bank] 发现上次未收尾的状态，先自动还原（self-heal）...")
        rc = restore_from_state(existing)
        if rc != 0:
            print("[bank] 自愈失败，中止。", file=sys.stderr)
            return 1

    records, problems = collect_plan()
    if problems:
        for p in problems:
            print(f"[bank] 错误: {p}", file=sys.stderr)
        return 1

    before = sum(r.src_size for r in records)
    after = sum(r.new_size for r in records if r.mode == MODE_SWAP)
    if before - after < MIN_SAVING_BYTES:
        print(
            f"[bank] 错误: 只省 {mb(before - after)}，低于门槛 {mb(MIN_SAVING_BYTES)}。\n"
            f"[bank] 大概率是 HTML5 那套没重新编，或 Music_*.bank 还没拆出来。\n"
            "[bank] 先跑 python tools\\audio\\split_music_banks.py + Build-FMOD-Banks.cmd。",
            file=sys.stderr,
        )
        return 1

    os.makedirs(BACKUP_DIR, exist_ok=True)
    try:
        for r in records:
            shutil.copy2(r.src, os.path.join(BACKUP_DIR, r.bank + ".orig"))
            if r.dest and r.dest_sha:
                shutil.copy2(r.dest, os.path.join(BACKUP_DIR, r.bank + ".dest"))
        save_state(records)
    except OSError as exc:
        print(f"[bank] 备份失败: {exc}", file=sys.stderr)
        if os.path.exists(STATE_FILE):
            restore_from_state(load_state() or {})
        return 1

    # swap  : 源 + 导入缓存换成 HTML5 那份，md5 边车跟着改写（Godot 脏检查比
    #         source_md5，改对就不会触发重导入）。
    # remove: 源、导入缓存、md5 边车一起删掉 —— 只要文件还在 res:// 下，
    #         FmodGodot 的 add_file() 就会把它塞进 pck，exclude 拦不住。
    try:
        for r in records:
            if r.mode == MODE_REMOVE:
                for path in (r.src, r.dest, r.sidecar):
                    if path and os.path.exists(path):
                        os.unlink(path)
                continue
            new = os.path.join(HTML5_BUILD, r.bank)
            shutil.copy2(new, r.src)
            if r.dest:
                shutil.copy2(new, r.dest)
            if r.sidecar:
                with open(r.sidecar, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(md5_text(r.new_md5, r.new_md5))
    except OSError as exc:
        print(f"[bank] 写入失败: {exc} —— 立即还原", file=sys.stderr)
        restore_from_state(load_state() or {})
        return 1

    # 写后校验：swap 的必须是 HTML5 那份 sha256，remove 的必须真的不在了。
    bad: list[str] = []
    for r in records:
        if r.mode == MODE_REMOVE:
            if os.path.exists(r.src):
                bad.append(f"{r.bank}: 移出后源文件仍存在")
            if r.dest and os.path.exists(r.dest):
                bad.append(f"{r.bank}: 移出后导入缓存仍存在")
            continue
        if sha256_file(r.src) != r.new_sha:
            bad.append(f"{r.bank}: 源文件写后 sha256 不符")
        if r.dest and sha256_file(r.dest) != r.new_sha:
            bad.append(f"{r.bank}: 导入缓存写后 sha256 不符")
    if bad:
        for b in bad:
            print(f"[bank] 校验失败: {b}", file=sys.stderr)
        restore_from_state(load_state() or {})
        return 1

    print(
        f"[bank] web 包的 bank 已就位：pck 侧 {mb(before)} -> {mb(after)} "
        f"（省 {mb(before - after)}）"
    )
    for r in records:
        if r.mode == MODE_REMOVE:
            print(f"[bank]   {r.bank:<22} {mb(r.src_size):>9} -> 移出工程（单独发布）")
        else:
            print(f"[bank]   {r.bank:<22} {mb(r.src_size):>9} -> {mb(r.new_size):>9}")
    return 0


# --------------------------------------------------------------------------
# end / restore / status / verify
# --------------------------------------------------------------------------
def cmd_end(_args: Any) -> int:
    if skipped():
        print(f"[bank] 跳过（{SKIP_ENV}=1）")
        return 0
    state = load_state()
    if not state:
        print("[bank] 没有待还原的状态（可能没 begin 过，或已还原）")
        return 0
    return restore_from_state(state)


def cmd_restore(_args: Any) -> int:
    state = load_state()
    if not state:
        print("[bank] 没有待还原的状态")
        return 0
    return restore_from_state(state)


def cmd_status(_args: Any) -> int:
    state = load_state()
    if not state:
        print("[bank] 空闲：本机 bank 应为 Desktop 版本")
    else:
        print("[bank] 处于导出中间态（导出中，或上次没收尾）:")
        for rec in state.get("records", []):
            if rec.get("mode") == MODE_REMOVE:
                print(f"[bank]   {rec['bank']:<22} 已移出工程（原 {mb(rec['src_size'])}）")
            else:
                print(
                    f"[bank]   {rec['bank']:<22} 现在应为 "
                    f"{mb(rec['new_size'])}（原 {mb(rec['src_size'])}）"
                )
    print()
    for bank in ALL_BANKS:
        src = os.path.join(BANK_SRC, bank)
        if not os.path.exists(src):
            print(f"  {bank:<22} {'不在工程里':>12}")
            continue
        size = os.path.getsize(src)
        tag = "HTML5" if state and any(
            r["bank"] == bank and size == r["new_size"] for r in state["records"]
        ) else "Desktop"
        print(f"  {bank:<22} {mb(size):>10}  ({tag})")
    return 0


def cmd_verify(args: Any) -> int:
    pck_path = args.pck
    if not os.path.isabs(pck_path):
        pck_path = os.path.join(REPO, pck_path)
    if not os.path.exists(pck_path):
        print(f"[bank] verify: 找不到 {pck_path}", file=sys.stderr)
        return 1

    sys.path.insert(0, os.path.join(REPO, "tools"))
    try:
        from pck_audit import Pck  # type: ignore
    except Exception as exc:  # pragma: no cover - 只在结构变化时触发
        print(f"[bank] verify: 导入 pck_audit 失败: {exc}", file=sys.stderr)
        return 1

    pck = Pck(pck_path)
    banks = [e for e in pck.entries if e.path.endswith(".bank")]
    total = sum(e.size for e in banks)

    # 1) era bank 一个都不许在包里 —— 它们几十 MB，混进来就是拆包失败。
    leaked = [e for e in banks if any(name in e.path for name in ERA_BANKS)]
    if leaked:
        print("[bank] 失败：pck 里出现了 era bank（它们应该作为独立文件发布）：",
              file=sys.stderr)
        for e in leaked:
            print(f"[bank]   {mb(e.size):>10}  {e.path}", file=sys.stderr)
        print("[bank] 多半是导出时 Music_*.bank 还在 assets/audio/banks/ 下，"
              "FmodGodot 的 add_file() 把它塞进去了。", file=sys.stderr)
        return 1

    if args.limit_mb is not None:
        limit = int(args.limit_mb * 1048576)
        limit_src = f"--limit-mb {args.limit_mb}"
    else:
        # 上限由核心 bank 的 HTML5 体积推出来，不写死数字：曲库以后变大也不会误报，
        # 但仍然能抓到"核心 bank 整包换回 q70"这种事故。
        try:
            expected = sum(
                os.path.getsize(os.path.join(HTML5_BUILD, b))
                for b in CORE_BANKS
                if os.path.exists(os.path.join(HTML5_BUILD, b))
            )
        except OSError as exc:
            print(f"[bank] verify: 读 HTML5 bank 失败: {exc}", file=sys.stderr)
            return 1
        limit = expected + 2 * 1048576
        limit_src = f"核心 bank 的 HTML5 合计 {mb(expected)} + 2 MB 容差"

    print(f"[bank] pck: {pck_path}")
    for e in banks:
        print(f"[bank]   {mb(e.size):>10}  {e.path}")
    print(f"[bank] 合计 {mb(total)}（上限 {mb(limit)}，依据 {limit_src}）")
    if total > limit:
        print(
            "[bank] 失败：pck 里的 bank 超过上限，说明降级没生效"
            "（多半是导出时源 bank 被重新导入成 Desktop 版了）。",
            file=sys.stderr,
        )
        return 1
    print("[bank] ok")
    return 0


def cmd_publish(args: Any) -> int:
    """把 HTML5 那套 era bank 拷到导出目录，作为运行期 fetch 的目标。"""
    out = args.out
    if not os.path.isabs(out):
        out = os.path.join(REPO, out)
    if not os.path.isdir(out):
        print(f"[bank] publish: 导出目录不存在 {out}", file=sys.stderr)
        return 1
    total = 0
    for bank in ERA_BANKS:
        src = os.path.join(HTML5_BUILD, bank)
        if not os.path.exists(src):
            print(f"[bank] publish: 缺 {src} —— 先跑 Build-FMOD-Banks.cmd", file=sys.stderr)
            return 1
        check_bank_header(src)
        dst = os.path.join(out, bank)
        shutil.copy2(src, dst)
        size = os.path.getsize(dst)
        total += size
        print(f"[bank]   {mb(size):>9}  {bank}")
    print(f"[bank] 已发布 {len(ERA_BANKS)} 个 era bank 到 {out}（合计 {mb(total)}）")
    print("[bank] 它们由 GameAudio 按时代 fetch，不在 boot pck 里。")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Web 导出专用的 FMOD bank 降质")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan", help="只看体积对比，不动磁盘").set_defaults(func=cmd_plan)
    sub.add_parser("begin", help="备份并切到 HTML5 bank").set_defaults(func=cmd_begin)
    sub.add_parser("end", help="还原（成功和失败路径都要调）").set_defaults(func=cmd_end)
    sub.add_parser("restore", help="同 end，但忽略“没开始”的情况").set_defaults(func=cmd_restore)
    sub.add_parser("status", help="看当前处于哪一档").set_defaults(func=cmd_status)
    vp = sub.add_parser("verify", help="检查导出后的 pck 里 bank 是否真的变小了")
    vp.add_argument("--pck", default=os.path.join("WebBuild", "ProjectKeynes.pck"))
    vp.add_argument("--limit-mb", type=float, default=None,
                    help="pck 内 .bank 总量上限（MiB）；默认由核心 bank 的 HTML5 体积 +2 MB 推出")
    vp.set_defaults(func=cmd_verify)

    pp = sub.add_parser("publish", help="把 era bank 拷到导出目录（不进 pck）")
    pp.add_argument("--out", default=os.path.join("WebBuild"), help="导出目录")
    pp.set_defaults(func=cmd_publish)

    args = ap.parse_args(argv)
    try:
        return int(args.func(args) or 0)
    except RuntimeError as exc:
        print(f"[bank] 错误: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
