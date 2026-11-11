#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""split_music_banks.py —— 把四个时代的 Suite 事件各自拆到独立 FMOD bank。

为什么
------
`Music.bank` 里 98.5% 的 PCM 来自四个 `event:/Music/<Era>/Suite` 事件，而**一局只会
用到其中一个**。四个 Suite 引用的音频互不重叠，所以按事件拆 bank 就能让 web 首包
只带当前时代那一份（实测 49.7 MB -> 每个时代 10.7~13.6 MB）。

改动范围（全部在 `Audio/ProjectKeynes/Metadata/`，都在 git 里，可 `--revert`）
------
1. 新增 4 个 `Bank` 对象：Music_stone / Music_agrarian / Music_kingdom / Music_empire
2. 把对应 Suite 事件的 `<relationship name="banks">` 从 Music 改指向新 bank

**不动资产**：FMOD 的 EncodableAsset 没有 banks 关系时跟随引用它的事件，所以音频
会随事件一起搬过去。四个 Suite 的音频集互不相交（已核），不会出现同一份音频被编进
两个 bank 的重复。

用法
----
    python tools\\audio\\split_music_banks.py            # 应用
    python tools\\audio\\split_music_banks.py --check    # 只报告当前状态
    python tools\\audio\\split_music_banks.py --revert   # 还原成单一 Music bank

改完必须重编 bank（`Build-FMOD-Banks.cmd`）。运行期还要配合按时代加载，见
`scripts/audio/game_audio_service.gd` 的 `_ensure_era_bank()`；否则 Desktop 的
Music.bank 不含 Suite，音乐会是哑的。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT = os.path.join(REPO, "Audio", "ProjectKeynes")
BANK_DIR = os.path.join(PROJECT, "Metadata", "Bank")
EVENT_DIR = os.path.join(PROJECT, "Metadata", "Event")

MUSIC_BANK = "{02c1157d-95db-4fc0-9efe-1dd45d126f1b}"
MASTER_BANK_FOLDER = "{07fb52a7-88b7-4b50-aff5-5f9728462f36}"

# 事件 GUID 与时代的对应，来自 Metadata/EventFolder 的 名字（event:/Music/<Era>/Suite）。
ERA_EVENTS = {
    "Music_stone": "{0a184c90-4391-4f7d-b008-cdb1ed1ac032}",
    "Music_agrarian": "{4f4aeb92-64d0-4fa8-a2f2-46a838fb2b3d}",
    "Music_kingdom": "{0109a0e7-ef53-4ca6-826a-d0676768b2c4}",
    "Music_empire": "{8f020a26-d9a4-4cfd-9304-71ed8c4825da}",
}

# 固定 GUID：重跑必须落在同一个文件名上，否则每跑一次就多一个 bank。
BANK_NS = uuid.UUID("6f1b2c8e-3d4a-4f5b-9c7d-1e2f3a4b5c6d")

BANK_XML = """<?xml version="1.0" encoding="UTF-8"?>
<objects serializationModel="Studio.02.03.00">
\t<object class="Bank" id="{gid}">
\t\t<property name="name">
\t\t\t<value>{name}</value>
\t\t</property>
\t\t<relationship name="folder">
\t\t\t<destination>{folder}</destination>
\t\t</relationship>
\t</object>
</objects>
"""

BANKS_RE = re.compile(
    r'(<relationship name="banks">\s*<destination>)(\{[0-9a-fA-F-]+\})(</destination>)'
)


def bank_gid(name: str) -> str:
    return "{" + str(uuid.uuid5(BANK_NS, name)) + "}"


def event_path(ev: str) -> str:
    return os.path.join(EVENT_DIR, ev + ".xml")


def current_bank(ev: str) -> str | None:
    with open(event_path(ev), "r", encoding="utf-8") as fh:
        m = BANKS_RE.search(fh.read())
    return m.group(2) if m else None


def set_bank(ev: str, gid: str) -> bool:
    """把事件的 banks 关系指向 gid。返回是否真的改了。"""
    p = event_path(ev)
    with open(p, "r", encoding="utf-8") as fh:
        text = fh.read()
    new, n = BANKS_RE.subn(lambda m: m.group(1) + gid + m.group(3), text)
    if n != 1:
        raise RuntimeError(f"{os.path.basename(p)}: banks 关系匹配到 {n} 处，预期 1 处")
    if new == text:
        return False
    with open(p, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(new)
    return True


def status() -> int:
    print(f"{'bank':<16}{'GUID':<40}{'状态'}")
    ok = True
    for name, ev in ERA_EVENTS.items():
        gid = bank_gid(name)
        xml = os.path.join(BANK_DIR, gid + ".xml")
        exists = os.path.exists(xml)
        cur = current_bank(ev)
        if exists and cur == gid:
            state = "已拆分"
        elif cur == MUSIC_BANK:
            state = "未拆分（挂在 Music 上）"
            ok = False
        else:
            state = f"异常：事件指向 {cur}，bank 文件{'存在' if exists else '缺失'}"
            ok = False
        print(f"{name:<16}{gid:<40}{state}")
    return 0 if ok else 1


def apply() -> int:
    changed = 0
    for name, ev in ERA_EVENTS.items():
        gid = bank_gid(name)
        xml = os.path.join(BANK_DIR, gid + ".xml")
        if not os.path.exists(xml):
            with open(xml, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(BANK_XML.format(gid=gid, name=name, folder=MASTER_BANK_FOLDER))
            print(f"[split] 新建 bank {name}  {gid}")
            changed += 1
        if set_bank(ev, gid):
            print(f"[split] {name}: Suite 事件已改挂")
            changed += 1
    if changed == 0:
        print("[split] 已是拆分状态，无改动")
    else:
        print(f"[split] 完成（{changed} 处改动）。下一步：Build-FMOD-Banks.cmd")
    return 0


def revert() -> int:
    changed = 0
    for name, ev in ERA_EVENTS.items():
        if set_bank(ev, MUSIC_BANK):
            print(f"[split] {name}: Suite 事件已挂回 Music")
            changed += 1
        xml = os.path.join(BANK_DIR, bank_gid(name) + ".xml")
        if os.path.exists(xml):
            os.unlink(xml)
            print(f"[split] 删除 bank 文件 {os.path.basename(xml)}")
            changed += 1
    if changed == 0:
        print("[split] 已是单一 Music bank 状态，无改动")
    else:
        print(f"[split] 已还原（{changed} 处改动）。下一步：Build-FMOD-Banks.cmd")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="把四个时代的 Suite 拆到独立 FMOD bank")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="只报告当前状态")
    g.add_argument("--revert", action="store_true", help="还原成单一 Music bank")
    args = ap.parse_args(argv)

    if not os.path.isdir(PROJECT):
        print(f"找不到 FMOD 工程: {PROJECT}", file=sys.stderr)
        return 1
    if args.check:
        return status()
    if args.revert:
        return revert()
    return apply()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
