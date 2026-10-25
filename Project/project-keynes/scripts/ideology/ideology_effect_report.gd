class_name IdeologyEffectReport
extends RefCounted

## Turns `get_ideology_effect_instance_report()` into per-card totals.
##
## Why this exists
## ---------------
## The native reconciliation path has been emitting one row per (card, level,
## program, target) instance since it landed, and `get_ideology_effect_instance_
## report()` has been bound to GDScript the whole time — but nothing ever called
## it. So a player could equip a card, watch the tooltip, and never learn whether
## the thing was actually projecting anything onto the map.
##
## This is the missing reader, deliberately kept as a pure function: the view
## model gets a small dictionary and the native dictionary shape stays in exactly
## one place.
##
## One row is one *instance*, not one cell. A cell-domain selector expands to one
## instance per resolved cell, so `instances` is the cell count for those cards;
## a country-domain program resolves to a single country handle, so the same
## number reads as "1 target". The UI therefore says 「效果 N 处」 rather than
## 「命中 N 块地」 — the honest word for both.
##
## `main_thread_owned` is NOT "is it working". The native column is the ownership
## bit ("did the main thread own this instance, or was it handed to the worker"),
## so under worker authority a fully live card reports 0. It is kept for
## diagnostics and tests only; the card face must never render it as 「已生效」.
##
## `cells` is the answer to a different question: *where* the card acts. It is
## empty for a country-domain card and for a ref the native side could not label,
## and the two are intentionally the same shape — both mean "do not paint
## anything". Painting a country handle as a cell index would light an unrelated
## hex somewhere else on the map.

## `RuntimeDomainId` values whose `target_handle` is a **cell index**. Every
## other domain addresses something else (3 = country handle), so the numeric
## column is only usable as a cell after this check.
const CELL_TARGET_DOMAINS := [2, 5]


## Collapse the report's parallel columns into `by_idea`.
##
## Returns:
##   ok        bool   — mirrors the native `ok`
##   reason    String — native reason when not ok
##   total     int    — instance rows summed over every card
##   by_idea   Dictionary — idea_id -> {instances, main_thread_owned, targets,
##                          cells, levels}
##
## `targets` is the distinct target handles in first-seen order; `cells` the
## distinct *cell indices* among them (domain 2/5 only); `levels` the distinct
## levels, ascending. Columns shorter than `count` (an older native build, or a
## payload mutated by a test) are read as absent rather than truncating the whole
## summary.
static func summarize(report: Dictionary) -> Dictionary:
	if not bool(report.get("ok", false)):
		return {
			"ok": false,
			"reason": String(report.get("reason", "")),
			"total": 0,
			"by_idea": {},
		}
	# 原生列为 64 位；保留数组类型，也兼容旧的 32 位报告。
	var idea_ids: Variant = report.get("idea_ids", PackedInt64Array())
	var levels: Variant = report.get("idea_levels", PackedInt64Array())
	var targets: PackedInt64Array = report.get("target_handles", PackedInt64Array())
	var domains: PackedInt32Array = report.get("target_domains", PackedInt32Array())
	var owned: PackedByteArray = report.get("present", PackedByteArray())
	var by_idea := {}
	var total := 0
	for index in range(idea_ids.size()):
		var idea_id := int(idea_ids[index])
		var row: Dictionary = by_idea.get(idea_id, {
			"instances": 0,
			"main_thread_owned": 0,
			"targets": PackedInt64Array(),
			"cells": PackedInt32Array(),
			"levels": PackedInt32Array(),
		})
		row["instances"] = int(row["instances"]) + 1
		if index < owned.size() and int(owned[index]) != 0:
			row["main_thread_owned"] = int(row["main_thread_owned"]) + 1
		if index < targets.size():
			var seen: PackedInt64Array = row["targets"]
			var target := int(targets[index])
			# `has` on a PackedInt64Array is O(n), and n is capped at
			# SELECTOR_MAX_CELLS (32) per program row by the reconciler, so the
			# quadratic worst case is 32^2 per card. Not worth a side table.
			if not seen.has(target):
				var grown := PackedInt64Array(seen)
				grown.append(target)
				row["targets"] = grown
			# A cell is only a cell when the native side said so. An unlabelled
			# ref (domain -1) falls through both guards and paints nothing.
			if index < domains.size() and CELL_TARGET_DOMAINS.has(int(domains[index])) \
					and target >= 0:
				var cell_seen: PackedInt32Array = row["cells"]
				if not cell_seen.has(target):
					var cell_grown := PackedInt32Array(cell_seen)
					cell_grown.append(target)
					row["cells"] = cell_grown
		if index < levels.size():
			var level_seen: PackedInt32Array = row["levels"]
			var level := int(levels[index])
			if not level_seen.has(level):
				var level_grown := PackedInt32Array(level_seen)
				level_grown.append(level)
				level_grown.sort()
				row["levels"] = level_grown
		by_idea[idea_id] = row
		total += 1
	return {"ok": true, "reason": "", "total": total, "by_idea": by_idea}


## What the card face needs, for one card. An unknown card yields an empty row,
## which the view model renders as "no badge" rather than "0 处".
static func card_row(summary: Dictionary, idea_id: int) -> Dictionary:
	var by_idea: Dictionary = summary.get("by_idea", {})
	var row: Dictionary = by_idea.get(int(idea_id), {})
	if row.is_empty():
		return {}
	return {
		"instances": int(row.get("instances", 0)),
		"target_count": (row.get("targets", PackedInt64Array()) as PackedInt64Array).size(),
		"cells": row.get("cells", PackedInt32Array()),
		"levels": row.get("levels", PackedInt32Array()),
	}
