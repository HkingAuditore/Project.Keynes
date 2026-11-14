# -*- coding: utf-8 -*-
"""v5 内容：把 `canned_fish` 与 `processed_food` 接进家庭消费。

这两个物资目前有生产者、零消费者（`orphan_goods` 审计里唯一被判孤儿的非军工物资）。
做法：把 `.tres` 解析成"需求 → 变体 → 组件"模型，改完**从零重建两套 offset 数组**，
并保留每个字段原本的数组类型。位置数组一错位，整个消费计划会静默错乱，
所以宁可整段重写，也不对原文做插入。
"""
from __future__ import annotations

import argparse
import os
import re
import sys

PLANS = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
         r"\data\economy\consumption_plans")

NEED_LEVEL = ["need_ids", "priorities", "base_qty_per_person", "wealth_elasticity_q16",
              "wealth_min_q16", "wealth_max_q16", "price_quantity_elasticity_q16",
              "price_quantity_floor_q16", "quantity_env_curve_ids"]
VARIANT_LEVEL = ["variant_ids", "variant_preference_q16", "variant_price_elasticity_q16",
                 "variant_class_wealth_elasticity_delta_q16",
                 "variant_class_savings_threshold_factor_q16",
                 "variant_preference_env_curve_ids"]
VARIANT_EXTRA = ["98304", "98304", "0", "0", '""']

# 注意：每个需求最多 8 个变体（economy_catalog 的硬规则），
# staple_food 已经是 8 个，所以 processed_food 只能作为既有变体的额外部件加入。
INSERTIONS = [
    ("protein", "protein_canned_fish", "canned_fish", "620"),
    ("protein", "protein_frozen_food", "frozen_food", "700"),
    ("healthcare", "healthcare_antibiotics", "antibiotics", "260"),
]
EXTRA_COMPONENTS = [
    ("staple_food_0", "processed_food", "300"),
]
# 需求级插入：把物资挂到该需求的第一个变体上（不新增变体，绕开 8 个变体的上限）
NEED_COMPONENTS = [
    ("luxury", "silver", "90"),
]

PATTERN = re.compile(r"^([a-z_0-9]+) = ([A-Za-z0-9]+Array)\(([^)]*)\)$", re.M)


def parse(text):
    arrays, kinds = {}, {}
    for match in PATTERN.finditer(text):
        name, kind, body = match.group(1), match.group(2), match.group(3)
        arrays[name] = [value.strip() for value in body.split(",") if value.strip()]
        kinds[name] = kind
    return arrays, kinds


def emit(text, arrays, kinds):
    for name, items in arrays.items():
        replacement = "%s = %s(%s)" % (name, kinds.get(name, "PackedStringArray"),
                                       ", ".join(items))
        text = re.sub(r"^%s = [A-Za-z0-9]+Array\([^)]*\)$" % re.escape(name),
                      replacement, text, count=1, flags=re.M)
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    dry = arguments.dry_run
    touched = 0
    for name in sorted(os.listdir(PLANS)):
        if not name.endswith(".tres"):
            continue
        path = os.path.join(PLANS, name)
        text = open(path, encoding="utf-8").read()
        arrays, kinds = parse(text)
        if "need_ids" not in arrays:
            continue
        needs = [value.strip('"') for value in arrays["need_ids"]]
        variant_ids = [value.strip('"') for value in arrays["variant_ids"]]
        component_goods = [value.strip('"') for value in arrays["component_good_ids"]]
        component_qty = list(arrays["component_qty_per_need"])
        need_offsets = [int(value) for value in arrays["need_variant_offsets"]]
        component_offsets = [int(value) for value in arrays["variant_component_offsets"]]

        model = []
        for need_index in range(len(needs)):
            bucket = []
            for variant_index in range(need_offsets[need_index], need_offsets[need_index + 1]):
                start = component_offsets[variant_index]
                end = component_offsets[variant_index + 1]
                pairs = [(component_goods[index], component_qty[index])
                         for index in range(start, end)]
                extras = [arrays[field][variant_index] for field in VARIANT_LEVEL[1:]]
                bucket.append((variant_ids[variant_index], pairs, extras))
            model.append(bucket)

        added = 0
        for need_id, new_variant, good_id, quantity in INSERTIONS:
            if need_id not in needs:
                continue
            need_index = needs.index(need_id)
            if any(variant[0] == new_variant for variant in model[need_index]):
                continue
            model[need_index].append((new_variant, [(good_id, quantity)], list(VARIANT_EXTRA)))
            added += 1
        for target_variant, good_id, quantity in EXTRA_COMPONENTS:
            attached = False
            for need_index in range(len(model)):
                for position, (variant_id, pairs, extras) in enumerate(model[need_index]):
                    if variant_id != target_variant:
                        continue
                    if any(pair[0] == good_id for pair in pairs):
                        attached = True
                        break
                    model[need_index][position] = (variant_id,
                                                   pairs + [(good_id, quantity)], extras)
                    added += 1
                    attached = True
                    break
                if attached:
                    break
        for need_id, good_id, quantity in NEED_COMPONENTS:
            if need_id not in needs:
                continue
            need_index = needs.index(need_id)
            if not model[need_index]:
                continue
            variant_id, pairs, extras = model[need_index][0]
            if any(pair[0] == good_id for pair in pairs):
                continue
            model[need_index][0] = (variant_id, pairs + [(good_id, quantity)], extras)
            added += 1
        if added == 0:
            continue

        new_variant_ids, new_components, new_qty = [], [], []
        columns = {field: [] for field in VARIANT_LEVEL[1:]}
        new_need_offsets, new_component_offsets = [0], [0]
        for need_index in range(len(needs)):
            for variant_id, pairs, extras in model[need_index]:
                new_variant_ids.append('"%s"' % variant_id)
                for position, field in enumerate(VARIANT_LEVEL[1:]):
                    columns[field].append(extras[position])
                for good_id, quantity in pairs:
                    new_components.append('"%s"' % good_id)
                    new_qty.append(quantity)
                new_component_offsets.append(len(new_components))
            new_need_offsets.append(len(new_variant_ids))

        arrays["variant_ids"] = new_variant_ids
        for field in VARIANT_LEVEL[1:]:
            arrays[field] = columns[field]
        arrays["component_good_ids"] = new_components
        arrays["component_qty_per_need"] = new_qty
        arrays["need_variant_offsets"] = [str(value) for value in new_need_offsets]
        arrays["variant_component_offsets"] = [str(value) for value in new_component_offsets]

        touched += 1
        print("%-34s +%d 变体（%d → %d 变体 / %d → %d 组件）" % (
            name, added, len(variant_ids), len(new_variant_ids),
            len(component_goods), len(new_components)))
        if not dry:
            with open(path + ".v5tmp", "w", encoding="utf-8", newline="\n") as handle:
                handle.write(emit(text, arrays, kinds))
            os.replace(path + ".v5tmp", path)
    print("--- %d 个计划 / %s ---" % (touched, "dry-run" if dry else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
