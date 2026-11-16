#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 UI 问题清单切成互不重叠的并行工单。

多个 agent 同时改一个仓库时，按「问题簇」分工必然互相覆盖文件。
本脚本用 union-find 把共享同一文件的条目绑成连通分量，同分量不拆分，
再负载均衡到 N 个桶，保证任意两工单的独占文件集合交集为空。

用法：
    PYTHONPATH= python build_workorders.py \
        --csv <清单.csv> --root <工程根> --out <输出目录> \
        [--buckets 8] [--backup <备份目录>] [--skip B-001,B-002]

CSV 至少需含列：建议ID, 问题一句话, 类别, 文件:行号, 原文证据, 修法, 确信度, 来源报告
输出：workorders/WO-01.md ... ，workorder_manifest.md，以及备份目录中的原文件副本。
"""
import argparse
import csv
import os
import re
import shutil
from collections import defaultdict

PATH_RE = re.compile(
    r"((?:scripts|scenes|data|assets|tests)/[A-Za-z0-9_./-]+\.(?:gd|tscn|json|tres|cpp|h))")


def paths_of(row):
    """只认「文件:行号」里的路径。修法里提到的参考文件不能进独占清单。"""
    found = []
    for m in PATH_RE.finditer(str(row.get("文件:行号", ""))):
        if m.group(1) not in found:
            found.append(m.group(1))
    return found


class DSU:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b):
        a, b = self.find(a), self.find(b)
        if a != b:
            self.p[b] = a


def main():
    ap = argparse.ArgumentParser(description="多 agent 并行修复的无冲突工单生成器")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--root", required=True, help="工程根（含 project.godot）")
    ap.add_argument("--out", required=True, help="工单输出目录")
    ap.add_argument("--buckets", type=int, default=8)
    ap.add_argument("--backup", default="", help="改动前备份目录；留空则不备份")
    ap.add_argument("--skip", default="", help="逗号分隔的不施工条目 ID")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    out = os.path.abspath(args.out)
    wo_dir = os.path.join(out, "workorders")
    os.makedirs(wo_dir, exist_ok=True)
    if args.backup:
        os.makedirs(args.backup, exist_ok=True)

    with open(args.csv, "r", encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))
    skip_ids = {s.strip() for s in args.skip.split(",") if s.strip()}
    active = [r for r in rows if r.get("建议ID") not in skip_ids]
    skipped = [(r["建议ID"], r.get("问题一句话", "")) for r in rows
               if r.get("建议ID") in skip_ids]

    dsu = DSU(len(active))
    owner = {}
    for i, r in enumerate(active):
        for p in paths_of(r):
            if p in owner:
                dsu.union(owner[p], i)
            else:
                owner[p] = i
    groups = defaultdict(list)
    for i, r in enumerate(active):
        groups[dsu.find(i)].append(r)
    comps = sorted(groups.values(), key=lambda g: -len(g))

    buckets = [[] for _ in range(args.buckets)]
    loads = [0] * args.buckets
    for comp in comps:
        k = loads.index(min(loads))
        buckets[k].extend(comp)
        loads[k] += len(comp)

    all_files = sorted({p for b in buckets for r in b for p in paths_of(r)})
    if args.backup:
        for p in all_files:
            src = os.path.join(root, p.replace("/", os.sep))
            if not os.path.isfile(src):
                continue
            dst = os.path.join(args.backup, p.replace("/", os.sep))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)

    manifest = []
    for k, b in enumerate(buckets, 1):
        if not b:
            continue
        files = sorted({p for r in b for p in paths_of(r)})
        wo = os.path.join(wo_dir, "WO-%02d.md" % k)
        with open(wo, "w", encoding="utf-8") as fh:
            fh.write("# 并行修复工单 WO-%02d\n\nROOT = `%s`\n\n" % (k, root))
            fh.write("## 独占文件（只允许改这些，共 %d 个）\n\n" % len(files))
            for p in files:
                fh.write("- `%s`\n" % p)
            fh.write("\n> 严禁打开/修改独占清单以外的任何游戏文件。"
                     "改前先核对工单里的原文证据在当前文件里是否仍然存在；"
                     "若文件已被其他会话改过、原文对不上，跳过该条并在摘要里记录。\n\n")
            fh.write("## 待修条目（%d 条）\n\n" % len(b))
            for r in b:
                fh.write("### %s | %s | 确信度 %s\n\n" % (
                    r.get("建议ID", "?"), r.get("类别", ""), r.get("确信度", "")))
                for label, key in (("问题", "问题一句话"), ("位置", "文件:行号"),
                                   ("原文", "原文证据"), ("修法", "修法"),
                                   ("来源", "来源报告")):
                    fh.write("- %s：%s\n" % (label, r.get(key, "")))
                fh.write("\n")
            fh.write("## 纪律\n\n"
                     "1. 只改上面的独占文件；每条改动必须能追溯到某个条目 ID。\n"
                     "2. 删除文案时连同承载它的空容器 / section title 一起删，"
                     "不要只把文字清空后留一个空 Label。\n"
                     "3. 不改变数据结构、字段名、信号、存档格式；"
                     "不碰 C++/GDExtension；不改 tests/ 里的断言。\n"
                     "4. 拿不准或原文对不上的条目跳过并记录。\n"
                     "5. 改完逐文件静态自检（括号、缩进、数组字面量用 `[]`"
                     "而非元组括号、静态函数只能调静态函数）。\n"
                     "6. **不要运行 Godot、不要跑测试、不要写 `.godot/`**"
                     "（多进程会互抢，统一由主会话验证）。\n"
                     "7. 摘要写到 `workorders/WO-%02d_result.md`。\n" % k)
        manifest.append((k, len(b), len(files), wo))

    # 冲突证明
    seen, overlap = set(), set()
    for k, n, f, wo in manifest:
        fs = set()
        for line in open(wo, encoding="utf-8"):
            m = re.match(r"- `((?:scripts|scenes|data|assets|tests)/[^`]+)`", line)
            if m:
                fs.add(m.group(1))
        for p in fs:
            if p in seen:
                overlap.add(p)
            seen.add(p)
    with open(os.path.join(out, "workorder_manifest.md"), "w", encoding="utf-8") as fh:
        fh.write("# 并行工单分配表\n\n")
        fh.write("连通分量 %d，桶 %d，活动条目 %d，跳过 %d，涉及文件 %d。\n\n" %
                 (len(comps), len(manifest), len(active), len(skipped), len(all_files)))
        fh.write("| 工单 | 条目数 | 独占文件数 | 路径 |\n|---|---:|---:|---|\n")
        for k, n, f, wo in manifest:
            fh.write("| WO-%02d | %d | %d | `%s` |\n" % (k, n, f, wo))
        if skipped:
            fh.write("\n## 明确跳过\n\n")
            for rid, why in skipped:
                fh.write("- `%s`：%s\n" % (rid, why))
        fh.write("\n## 冲突证明\n\n"
                 "共享文件的条目经 union-find 合并为同一连通分量且不拆分，"
                 "因此任意两工单的独占文件集合交集应为空。\n\n"
                 "**实测交集：%s**\n" % (sorted(overlap) or "空（无冲突）"))

    print("comps=%d active=%d skipped=%d files=%d" %
          (len(comps), len(active), len(skipped), len(all_files)))
    for k, n, f, wo in manifest:
        print("  WO-%02d items=%-3d files=%-3d" % (k, n, f))
    print("cross-workorder overlap:", sorted(overlap) or "none")
    if overlap:
        raise SystemExit("ERROR: 工单存在文件交集，禁止并行施工")


if __name__ == "__main__":
    main()
