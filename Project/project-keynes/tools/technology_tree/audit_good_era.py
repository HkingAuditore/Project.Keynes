# -*- coding: utf-8 -*-
"""物资"科技标签"时代是否合理的审计（与资源审计同源的一类问题）。

判据：
  * 物资档案 `technology_tags` 里最早的 tech -> 时代（玩家看到的是"这些科技会解锁它"）
  * 真正能生产它的建筑（output_good_ids 含它）所属科技的最早时代
  * 差 >= 2 代 -> 标签"过早"：科技面板会宣称某个很早就解锁了它，但谁也造不出来
  * 差 < 0 -> 标签"过晚"：能造却没人宣称解锁
"""
import os
import re
import io
import sys
import json
import collections

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
PROJ = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
GOOD_DIR = os.path.join(PROJ, "data", "goods")
BUILD_DIR = os.path.join(PROJ, "data", "economy", "buildings")
NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")


def parse(path):
    body = open(path, encoding="utf-8", errors="replace").read()
    return {m.group(1): m.group(2).strip()
            for m in re.finditer(r"^([a-z_0-9]+)\s*=\s*(.+)$", body, re.M)}


def arr(value):
    return re.findall(r'"([^"]*)"', value or "")


def main():
    net = json.load(open(NETWORK, encoding="utf-8"))
    era_ids = [era["id"] for era in net["eras"]]
    era_of = {node["id"]: era_ids.index(node["era_id"]) for node in net["nodes"]}
    name_of = {node["id"]: node.get("display_name", "") for node in net["nodes"]}

    producer_era = {}
    for name in os.listdir(BUILD_DIR):
        if not name.endswith(".tres"):
            continue
        data = parse(os.path.join(BUILD_DIR, name))
        techs = [t for t in arr(data.get("technology_tags", "")) if t.startswith("tech.")]
        tech = techs[0] if techs else ""
        era = era_of.get(tech, 99)
        for good in arr(data.get("output_good_ids", "")):
            if era < producer_era.get(good, 99):
                producer_era[good] = era

    rows = []
    for name in sorted(os.listdir(GOOD_DIR)):
        if not name.endswith(".tres"):
            continue
        data = parse(os.path.join(GOOD_DIR, name))
        good = (arr(data.get("id", ""))[0]).replace("&", "")
        tags = [t for t in arr(data.get("technology_tags", "")) if era_of.get(t, 99) < 99]
        if not tags:
            continue
        tagged = min(era_of[t] for t in tags)
        produced = producer_era.get(good, 99)
        rows.append((good, tagged, produced, tags))

    early = [(good, tagged, produced, tags) for good, tagged, produced, tags in rows
             if produced < 99 and produced - tagged >= 2]
    late = [(good, tagged, produced, tags) for good, tagged, produced, tags in rows
            if produced < 99 and produced < tagged]
    early.sort(key=lambda r: -(r[2] - r[1]))

    print("物资 %d 个，其中：标签过早 %d 个 / 标签过晚 %d 个" % (len(rows), len(early), len(late)))
    print()
    print("== 标签过早（科技说它解锁，但最早能造它的建筑在 >=2 代之后）==")
    for good, tagged, produced, tags in early[:25]:
        earliest_tag = min(tags, key=lambda t: era_of[t])
        print("  %-24s 标签=%-12s(%s)  生产=%-12s  差 %d 代" % (
            good, era_ids[tagged], earliest_tag, era_ids[produced], produced - tagged))
    print()
    print("== 标签过晚（能造，但没有任何科技宣称解锁）==")
    for good, tagged, produced, tags in late[:20]:
        print("  %-24s 标签=%-12s  生产=%-12s" % (good, era_ids[tagged], era_ids[produced]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
