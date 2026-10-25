extends SceneTree

## L6-15 acceptance: the card face reads the effect-instance report.
##
## Why this exists
## ---------------
## `get_ideology_effect_instance_report()` has been bound to GDScript since the
## reconciliation path landed and had exactly zero callers. A card could be
## equipped, its tooltip read, and nothing on screen told the player whether it
## was projecting anything at all.
##
## Three things are pinned here, all of them pure functions:
##
##  1. `IdeologyEffectReport.summarize()` collapses the parallel columns into
##     per-card totals, and a column shorter than `count` is read as absent
##     rather than dropping every row.
##  2. `present_ideology_card()` renders a badge only when the caller actually
##     has a report. "0 处" and "we did not look" must not look the same — the
##     collection grid passes an empty row on purpose.
##  3. `main_thread_owned` never reaches the card face. The native column is an
##     ownership bit, so under worker authority a fully live card reports 0; a
##     badge built from it would say 「0 处已生效」 about a working card.
##
## The native report shape itself is exercised by `ideology_effect_instance_test`;
## this file only assumes the column names.

const IdeologyEffectReportScript = preload("res://scripts/ideology/ideology_effect_report.gd")
const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("ideology effect report: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_shape_rejection()
	_test_per_card_totals()
	_test_native_int64_columns()
	_test_short_columns_are_absent()
	_test_card_row()
	_test_card_badge()
	_test_ownership_bit_is_not_rendered()
	_test_cell_targets()


## 1. A rejected report must not be mined for rows.
func _test_shape_rejection() -> void:
	var summary: Dictionary = IdeologyEffectReportScript.summarize(
		{"ok": false, "reason": "ideology_country_unknown"})
	_expect("a rejected report stays rejected", not bool(summary.get("ok", true)))
	_expect("a rejected report carries the native reason",
		String(summary.get("reason", "")) == "ideology_country_unknown",
		String(summary.get("reason", "")))
	_expect("a rejected report has no card rows",
		(summary.get("by_idea", {}) as Dictionary).is_empty())


## 2. One row is one instance. Totals per card, distinct targets, distinct levels.
func _test_per_card_totals() -> void:
	var summary: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 5,
		"idea_ids": PackedInt32Array([3, 3, 3, 7, 7]),
		"idea_levels": PackedInt32Array([1, 1, 0, 2, 2]),
		"target_handles": PackedInt64Array([10, 10, 11, 20, 21]),
		"present": PackedByteArray([1, 0, 1, 0, 0]),
	})
	_expect("every row is counted", int(summary.get("total", 0)) == 5,
		str(summary.get("total", 0)))
	var by_idea: Dictionary = summary.get("by_idea", {})
	_expect("both cards produced a row", by_idea.size() == 2, str(by_idea.keys()))
	var card_three: Dictionary = by_idea.get(3, {})
	_expect("instances are counted per card", int(card_three.get("instances", 0)) == 3,
		str(card_three))
	_expect("distinct targets, not rows", int(
		(card_three.get("targets", PackedInt64Array()) as PackedInt64Array).size()) == 2,
		str(card_three.get("targets", PackedInt64Array())))
	_expect("targets keep first-seen order",
		card_three.get("targets", PackedInt64Array()) == PackedInt64Array([10, 11]),
		str(card_three.get("targets", PackedInt64Array())))
	_expect("levels are distinct and ascending",
		card_three.get("levels", PackedInt32Array()) == PackedInt32Array([0, 1]),
		str(card_three.get("levels", PackedInt32Array())))
	_expect("the ownership bit is summed, not OR-ed",
		int(card_three.get("main_thread_owned", -1)) == 2, str(card_three))
	var card_seven: Dictionary = by_idea.get(7, {})
	_expect("a second card keeps its own targets", int(
		(card_seven.get("targets", PackedInt64Array()) as PackedInt64Array).size()) == 2,
		str(card_seven.get("targets", PackedInt64Array())))


## Native idea columns are 64-bit, while cell domains remain 32-bit.
func _test_native_int64_columns() -> void:
	var country_handle: int = 4294967297
	var summary: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 3,
		"idea_ids": PackedInt64Array([3, 3, 7]),
		"idea_levels": PackedInt64Array([2, 0, 1]),
		"target_handles": PackedInt64Array([country_handle, 12, 13]),
		"target_domains": PackedInt32Array([3, 2, 5]),
		"present": PackedByteArray([0, 1, 0]),
	})
	_expect("native int64 columns count every instance",
		int(summary.get("total", 0)) == 3, str(summary))
	var row: Dictionary = IdeologyEffectReportScript.card_row(summary, 3)
	_expect("native int64 IDs group instances by card",
		int(row.get("instances", 0)) == 2, str(row))
	_expect("native int64 levels produce sorted UI levels",
		row.get("levels") == PackedInt32Array([0, 2]), str(row))
	var raw_row: Dictionary = (summary.get("by_idea", {}) as Dictionary).get(3, {})
	_expect("native target handles retain all 64 bits",
		raw_row.get("targets") == PackedInt64Array([country_handle, 12]), str(raw_row))
	_expect("native report excludes country handles from cells",
		row.get("cells") == PackedInt32Array([12]), str(row))
	_expect("native int64 IDs keep separate cards",
		int(IdeologyEffectReportScript.card_row(summary, 7).get("instances", 0)) == 1)


## 3. A column that is shorter than `idea_ids` (older native build, or a payload
##    a test mutated) must not throw away the rows that do exist.
func _test_short_columns_are_absent() -> void:
	var summary: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 3,
		"idea_ids": PackedInt32Array([1, 1, 1]),
		"idea_levels": PackedInt32Array([0]),
		"target_handles": PackedInt64Array(),
		"present": PackedByteArray([1]),
	})
	_expect("short columns do not drop rows", int(summary.get("total", 0)) == 3,
		str(summary.get("total", 0)))
	var row: Dictionary = (summary.get("by_idea", {}) as Dictionary).get(1, {})
	_expect("a short target column leaves targets empty",
		(row.get("targets", PackedInt64Array()) as PackedInt64Array).is_empty(),
		str(row.get("targets", PackedInt64Array())))
	_expect("the levels that are present still land",
		row.get("levels", PackedInt32Array()) == PackedInt32Array([0]),
		str(row.get("levels", PackedInt32Array())))
	_expect("a missing ownership column defaults to zero",
		int(row.get("main_thread_owned", -1)) == 1, str(row))


## 4. `card_row` is the only shape the view model sees.
func _test_card_row() -> void:
	var summary: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 2,
		"idea_ids": PackedInt32Array([4, 4]),
		"idea_levels": PackedInt32Array([0, 1]),
		"target_handles": PackedInt64Array([5, 6]),
		"present": PackedByteArray([1, 1]),
	})
	var row: Dictionary = IdeologyEffectReportScript.card_row(summary, 4)
	_expect("card_row reports the instance count", int(row.get("instances", 0)) == 2,
		str(row))
	_expect("card_row reports distinct targets",
		int(row.get("target_count", 0)) == 2, str(row))
	_expect("card_row of an unknown card is empty",
		IdeologyEffectReportScript.card_row(summary, 99).is_empty())
	# An empty row is what "we did not look" looks like; it must not become
	# {"instances": 0} by accident, because the view model would draw a badge.
	var empty_summary: Dictionary = IdeologyEffectReportScript.summarize(
		{"ok": false, "reason": "x"})
	_expect("a rejected summary gives every card an empty row",
		IdeologyEffectReportScript.card_row(empty_summary, 4).is_empty())


## 5. The badge exists only when asked for.
func _test_card_badge() -> void:
	var metadata := {
		"display_name": "测试理念",
		"level_effect_lines": [["产出 +10%"]],
		"level_labels": ["初"],
	}
	var plain: Dictionary = CountryViewModelScript.present_ideology_card(metadata, 0)
	_expect("a card without a report shows no effect badge",
		_badge_texts(plain).filter(func(text: String) -> bool:
			return text.begins_with("效果 ")).is_empty(), str(_badge_texts(plain)))

	var with_effect: Dictionary = CountryViewModelScript.present_ideology_card(
		metadata, 0, {"instances": 12, "target_count": 9})
	var badges := _badge_texts(with_effect)
	_expect("a card with a report shows its instance count",
		badges.has("效果 12 处"), str(badges))
	_expect("the tooltip carries the target count",
		String(with_effect.get("tooltip", "")).contains("覆盖 9 个目标"),
		String(with_effect.get("tooltip", "")))
	# Wording is load-bearing: one instance is one resolved target, which is a
	# cell for a cell-domain program and a country handle otherwise.
	_expect("the badge does not claim cells it cannot know about",
		not badges.has("命中 12 块地"), str(badges))

	var zero: Dictionary = CountryViewModelScript.present_ideology_card(
		metadata, 0, {"instances": 0, "target_count": 0})
	_expect("an explicit zero renders no badge, same as no report",
		_badge_texts(zero).filter(func(text: String) -> bool:
			return text.begins_with("效果 ")).is_empty(), str(_badge_texts(zero)))


## 6. The ownership bit must not be rendered as "live".
func _test_ownership_bit_is_not_rendered() -> void:
	var summary: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 3,
		"idea_ids": PackedInt32Array([2, 2, 2]),
		"idea_levels": PackedInt32Array([0, 0, 0]),
		"target_handles": PackedInt64Array([1, 2, 3]),
		# Worker authority: the main thread owns none of these, yet the card is
		# projecting three instances.
		"present": PackedByteArray([0, 0, 0]),
	})
	var row: Dictionary = IdeologyEffectReportScript.card_row(summary, 2)
	var view: Dictionary = CountryViewModelScript.present_ideology_card(
		{"level_effect_lines": [["x"]], "level_labels": ["初"]}, 0, row)
	_expect("a worker-owned card still reports its instances",
		_badge_texts(view).has("效果 3 处"), str(_badge_texts(view)))
	_expect("the ownership bit never reaches the card face",
		not String(view.get("tooltip", "")).contains("已生效"),
		String(view.get("tooltip", "")))
	_expect("the ownership bit never becomes a badge",
		_badge_texts(view).filter(func(text: String) -> bool:
			return text.contains("生效")).is_empty(), str(_badge_texts(view)))


## 7. `cells` is derived from the domain column, and only a labelled cell-domain
##    row may contribute. This is the column the map overlay will paint, so a
##    wrong answer here lights an unrelated hex rather than showing a wrong
##    number.
func _test_cell_targets() -> void:
	var summary: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 6,
		"idea_ids": PackedInt32Array([3, 3, 3, 3, 3, 8]),
		"idea_levels": PackedInt32Array([0, 0, 0, 0, 0, 0]),
		# Domain 2 (settlement cell) and 5 (building/resource in a cell) both
		# carry a cell index; domain 3 carries a country handle. 77 appears
		# twice: one row per instance, one cell for the map.
		"target_handles": PackedInt64Array([11, 12, 11, 77, 13, 40]),
		"target_domains": PackedInt32Array([2, 2, 2, 3, 5, 2]),
		"present": PackedByteArray([1, 1, 1, 1, 1, 0]),
	})
	var card_three: Dictionary = IdeologyEffectReportScript.card_row(summary, 3)
	_expect("distinct targets still counts every domain",
		int(card_three.get("target_count", 0)) == 4, str(card_three))
	_expect("cells keep only cell-domain rows, deduplicated",
		card_three.get("cells", PackedInt32Array()) == PackedInt32Array([11, 12, 13]),
		str(card_three.get("cells", PackedInt32Array())))
	# The country handle must never survive into `cells`: 77 > any map size on a
	# normal map, but the guard is the domain, not the magnitude.
	_expect("a country-domain target is not a cell",
		not (card_three.get("cells", PackedInt32Array()) as PackedInt32Array).has(77),
		str(card_three.get("cells", PackedInt32Array())))
	_expect("domain 5 counts as a cell too",
		(card_three.get("cells", PackedInt32Array()) as PackedInt32Array).has(13),
		str(card_three.get("cells", PackedInt32Array())))

	# An unlabelled row (-1) means "the native side could not resolve a domain".
	# It must not be read as domain zero, which would be a cell.
	var unlabelled: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 2,
		"idea_ids": PackedInt32Array([4, 4]),
		"idea_levels": PackedInt32Array([0, 0]),
		"target_handles": PackedInt64Array([5, 6]),
		"target_domains": PackedInt32Array([-1, 3]),
		"present": PackedByteArray([1, 1]),
	})
	var card_four: Dictionary = IdeologyEffectReportScript.card_row(unlabelled, 4)
	_expect("an unlabelled target paints nothing",
		(card_four.get("cells", PackedInt32Array()) as PackedInt32Array).is_empty(),
		str(card_four.get("cells", PackedInt32Array())))
	_expect("unlabelled rows are still counted as instances",
		int(card_four.get("instances", 0)) == 2, str(card_four))

	# An older native build has no domain column at all. Everything still
	# summarises; nothing is paintable.
	var legacy: Dictionary = IdeologyEffectReportScript.summarize({
		"ok": true,
		"count": 1,
		"idea_ids": PackedInt32Array([5]),
		"idea_levels": PackedInt32Array([0]),
		"target_handles": PackedInt64Array([9]),
		"present": PackedByteArray([1]),
	})
	var card_five: Dictionary = IdeologyEffectReportScript.card_row(legacy, 5)
	_expect("a missing domain column leaves cells empty",
		(card_five.get("cells", PackedInt32Array()) as PackedInt32Array).is_empty(),
		str(card_five.get("cells", PackedInt32Array())))
	_expect("a missing domain column keeps the target count",
		int(card_five.get("target_count", 0)) == 1, str(card_five))


func _badge_texts(view: Dictionary) -> Array:
	var out := []
	for badge in view.get("badges", []):
		out.append(String((badge as Dictionary).get("text", "")))
	return out


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		if detail.is_empty():
			push_error("[FAIL] %s" % label)
		else:
			push_error("[FAIL] %s (%s)" % [label, detail])
