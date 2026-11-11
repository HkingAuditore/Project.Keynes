#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sync_bank_imports.py —— 补齐 `assets/audio/banks/Desktop/*.bank` 的 Godot 导入缓存。

为什么需要它
------------
`.bank` 的导入器 `godot.fmod.bank` 由 FmodGodot 这个纯 GDExtension 提供，没有
`plugin.cfg`。没有 EditorPlugin 就不会在扫描时**自动**给新文件生成 `.import`，
所以新拆出来的 `Music_<era>.bank` 即使扩展已注册也不会被导入（实测：连跑两遍
`godot --headless --import` 仍然只有旧的 4 个）。

好消息是这个导入器只做逐字节拷贝，规则完全可推：
    dest 文件名 = "<源文件名>-" + md5("res://<相对路径>") + ".bank"
    .md5 边车   = source_md5 / dest_md5 都是源文件 md5
（已用现有的 Master/UI/Music 三个 bank 反推验证过。）

于是这里按同一规则把缺失的 `.import`、`.godot/imported/*.bank`、`.md5` 一并生成，
让新版 bank 与旧版在 Godot 眼里没有任何区别。已有的 `.import` 一律不覆盖。

用法
----
    python tools\\audio\\sync_bank_imports.py            # 补齐缺失项
    python tools\\audio\\sync_bank_imports.py --check    # 只报告
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT = os.path.join(REPO, "Project", "project-keynes")
BANK_SRC = os.path.join(PROJECT, "assets", "audio", "banks", "Desktop")
IMPORTED = os.path.join(PROJECT, ".godot", "imported")
UID_NS = uuid.UUID("3f6a1d92-8c47-4e51-b2d9-7a0c5e4f1b83")

IMPORT_TMPL = """[remap]

importer="godot.fmod.bank"
type="FmodBank"
uid="uid://{uid}"
path="res://.godot/imported/{dest}"
{deps}
[params]


"""


def md5_hex(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def file_md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_uid(res_path: str) -> str:
    # Godot 的 uid:// 是 base32（字母表 0-9a-v）。这里只需要"唯一且稳定"，
    # 用 uuid5 取低 64 位转成同样字母表即可，格式合法、不会让引擎报错。
    raw = uuid.uuid5(UID_NS, res_path).int & 0xFFFFFFFFFFFFFFFF
    alphabet = "0123456789abcdefghijklmnopqrstuv"
    out = []
    while raw:
        raw, rem = divmod(raw, 32)
        out.append(alphabet[rem])
    return "".join(reversed(out)) or "0"


def sync(bank: str, *, check_only: bool) -> str:
    src = os.path.join(BANK_SRC, bank)
    if not os.path.exists(src):
        return "missing"
    res_path = "res://assets/audio/banks/Desktop/" + bank
    h = md5_hex(res_path)
    dest_name = f"{bank}-{h}.bank"
    dest = os.path.join(IMPORTED, dest_name)
    imp = src + ".import"
    sidecar = os.path.join(IMPORTED, f"{bank}-{h}.md5")

    if os.path.exists(imp) and os.path.exists(dest):
        return "ok"

    if check_only:
        return "needs-sync"

    source_md5 = file_md5(src)
    if not os.path.exists(imp):
        with open(imp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(IMPORT_TMPL.format(
                uid=make_uid(res_path),
                dest=dest_name,
                deps='\n[deps]\n\nsource_file="%s"\ndest_files=["res://.godot/imported/%s"]\n'
                     % (res_path, dest_name),
            ))
    os.makedirs(IMPORTED, exist_ok=True)
    if not os.path.exists(dest):
        with open(src, "rb") as fin, open(dest, "wb") as fout:
            for chunk in iter(lambda: fin.read(1 << 20), b""):
                fout.write(chunk)
    with open(sidecar, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f'source_md5="{source_md5}"\ndest_md5="{source_md5}"\n')
    return "written"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="补齐 bank 的 Godot 导入缓存")
    ap.add_argument("--check", action="store_true", help="只报告，不写盘")
    args = ap.parse_args(argv)

    if not os.path.isdir(BANK_SRC):
        print(f"找不到 bank 目录: {BANK_SRC}", file=sys.stderr)
        return 1

    banks = sorted(f for f in os.listdir(BANK_SRC) if f.endswith(".bank"))
    pending = 0
    for bank in banks:
        state = sync(bank, check_only=args.check)
        if state in ("needs-sync", "missing"):
            pending += 1
        print(f"[bankimport] {bank:<24} {state}")
    if args.check:
        print(f"[bankimport] {pending} 个待补齐")
        return 1 if pending else 0
    print(f"[bankimport] 完成（共 {len(banks)} 个 bank）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
