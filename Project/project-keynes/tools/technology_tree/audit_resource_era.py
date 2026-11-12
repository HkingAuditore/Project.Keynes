# -*- coding: utf-8 -*-
"""资源"发现科技"时代是否合理的审计。

判据：
  * 资源档案 `discovery_technology_tags` -> 最早可发现的科技 -> 时代
  * 哪些建筑把它当自然资源用（`resource_ids`） -> 这些建筑所属科技的最早时代
  * 若"发现时代"比"首次使用时代"早 2 代以上 → **过早**（文不对题、且没有意义）
  * 若"发现时代"晚于"首次使用时代" → **过晚**（真正会卡住生产）
"""
import os
import re
import io
import sys
import collections

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
PROJ = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
RES_DIR = os.path.join(PROJ, "data", "resources")
BUILD_DIR = os.path.join(PROJ, "data", "economy", "buildings")
NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")


def parse(path):
    body = open(path, encoding="utf-8", errors="replace").read()
    return {m.group(1): m.group(2).strip()
            for m in re.finditer(r"^([a-z_0-9]+)\s*=\s*(.+)$", body, re.M)}


def arr(value):
    return re.findall(r'"([^"]*)"', value or "")


def main():
    net = json.load(open(NETWORK, encoding="utf-8")) if False else None
    import json as _json
    net = _json.load(open(NETWORK, encoding="utf-8"))
    era_ids = [era["id"] for era in net["eras"]]
    era_of = {node["id"]: era_ids.index(node["era_id"]) for node in net["nodes"]}
    name_of = {node["id"]: node.get("display_name", "") for node in net["nodes"]}

    # 建筑：资源 -> 使用它的建筑的最早科技时代
    use_era = collections.defaultdict(lambda: 99)
    use_building = {}
    for name in os.listdir(BUILD_DIR):
        if not name.endswith(".tres"):
            continue
        data = parse(os.path.join(BUILD_DIR, name))
        techs = [t for t in arr(data.get("technology_tags", "")) if t.startswith("tech.")]
        tech = techs[0] if techs else ""
        era = era_of.get(tech, 99)
        for resource in arr(data.get("resource_ids", "")):
            if era < use_era[resource]:
                use_era[resource] = era
                use_building[resource] = "%s(%s)" % (name[:-5], tech)

    rows = []
    for name in sorted(os.listdir(RES_DIR)):
        if not name.endswith(".tres"):
            continue
        data = parse(os.path.join(RES_DIR, name))
        resource = (arr(data.get("id", ""))[0]).replace("&", "")
        tags = arr(data.get("discovery_technology_tags", ""))
        eras = [era_of[t] for t in tags if t in era_of]
        discover = min(eras) if eras else 99
        rows.append((resource, discover, use_era.get(resource, 99), tags,
                     use_building.get(resource, "-")))

    print("%-22s %-14s %-14s %s" % ("资源", "发现时代", "首次使用", "差距"))
    print("-" * 86)
    early, late = [], []
    for resource, discover, use, tags, building in sorted(rows, key=lambda r: (r[1], r[0])):
        d_era = era_ids[discover] if discover < len(era_ids) else "?"
        u_era = era_ids[use] if use < len(era_ids) else "-"
        gap = (use - discover) if use < 99 and discover < 99 else None
        flag = ""
        if gap is not None and gap >= 2:
            flag = "过早 %d 代" % gap
            early.append((resource, d_era, u_era, gap, tags, building))
        elif gap is not None and gap < 0:
            flag = "过晚 %d 代" % gap
            late.append((resource, d_era, u_era, -gap, tags, building))
        print("%-22s %-14s %-14s %-10s %s" % (resource, d_era, u_era, flag, ",".join(tags)))

    print()
    print("== 过早（发现比使用早 >= 2 代）：%d 个" % len(early))
    for resource, d_era, u_era, gap, tags, building in early:
        print("   %-20s 发现=%-12s 使用=%-12s 差 %d 代  使用者=%s" % (
            resource, d_era, u_era, gap, building))
    print()
    print("== 过晚（发现晚于使用）：%d 个" % len(late))
    for resource, d_era, u_era, gap, tags, building in late:
        print("   %-20s 发现=%-12s 使用=%-12s 差 %d 代  使用者=%s" % (
            resource, d_era, u_era, gap, building))
    return 0


if __name__ == "__main__":
    sys.exit(main())
