class_name IdeologyLocalSupport
extends RefCounted

## Cell-level support math, kept dependency-free so it can be unit-tested without
## a world. The facade feeds it Economy's bounded per-cell class headcount and the
## card's per-class stances; this file only does the weighted average.
##
##     local_support(cell) = Σ_c headcount_c(cell) × stance_c / Σ_c headcount_c(cell)
##
## It is deliberately the same aggregation as the national score. The gate stays
## national: a card cannot be pushed through by pleasing one district.

const Q16 := 65536


## `population` is row-major (cell x class). Returns one row per cell.
static func rows(stances: PackedInt32Array, population: PackedInt64Array,
		class_count: int, cell_count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cell in cell_count:
		var total := 0
		var weighted := 0
		for cls in class_count:
			var index := cell * class_count + cls
			if index >= population.size():
				break
			var people := maxi(0, int(population[index]))
			total += people
			if cls < stances.size():
				weighted += people * int(stances[cls])
		out.append({
			"support_q16": 0 if total <= 0 else int(weighted / total),
			"population": total,
		})
	return out


## Average and lowest support across the hit cells, for the one-line panel summary.
static func summarize(rows_in: Array) -> Dictionary:
	if rows_in.is_empty():
		return {"ok": false}
	var total := 0
	var lowest := 1 << 30
	var highest := -(1 << 30)
	for row in rows_in:
		var value := int((row as Dictionary).get("support_q16", 0))
		total += value
		lowest = mini(lowest, value)
		highest = maxi(highest, value)
	var count := rows_in.size()
	return {"ok": true, "cells": count, "average_q16": int(total / count),
		"lowest_q16": lowest, "highest_q16": highest}
