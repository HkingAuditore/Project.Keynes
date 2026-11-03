#!/usr/bin/env python3
"""把 FmodGodot 追加进 `.godot/extension_list.cfg`（web 导出前），导出后再还原。

为什么必须在导出**之前**、由外部脚本改：`extension_list.cfg` 是 Godot 的
forced-export 文件，导出插件无论 `add_file`（会得到两条同名条目）还是 `skip()`
都顶不掉；在 `_export_begin` 里改磁盘也太晚（文件列表已经收集）。所以流程是：

    python tools/patch_web_extension_list.py add
    <godot --export-release Web ...>
    python tools/patch_web_extension_list.py restore

web 上必须在引擎启动时自动加载：运行期 `GDExtensionManager.load_extension()`
是同步等待异步 fetch，会死锁主线程。
"""

from __future__ import annotations

import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
LIST = REPO / "Project" / "project-keynes" / ".godot" / "extension_list.cfg"
BACKUP = LIST.with_suffix(".cfg.pk_backup")
DESCRIPTOR = "res://addons/FmodGodot/FmodGodot.gdextension"


def main(argv: list[str]) -> int:
    action = argv[1] if len(argv) > 1 else ""
    if action == "add":
        text = LIST.read_text(encoding="utf-8") if LIST.exists() else ""
        BACKUP.write_text(text, encoding="utf-8")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if DESCRIPTOR not in lines:
            lines.append(DESCRIPTOR)
        LIST.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("[extlist] patched:", lines)
        return 0
    if action == "restore":
        if BACKUP.exists():
            LIST.write_text(BACKUP.read_text(encoding="utf-8"), encoding="utf-8")
            BACKUP.unlink()
            print("[extlist] restored")
        else:
            print("[extlist] nothing to restore")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
