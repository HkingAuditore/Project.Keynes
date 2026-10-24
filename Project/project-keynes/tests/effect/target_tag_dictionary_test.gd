extends SceneTree

## L1-4c acceptance: the tag *dictionary* (design doc §1 / §27).
##
## Why this exists
## ---------------
## `target_tag_catalog_test.gd` pins the catalog <-> native *contract*: a table
## arrives in the layout the evaluator reads, and malformed shapes are rejected.
## It says nothing about *which* tags exist, because until now none did.
##
## This file pins the dictionary itself, in two layers:
##
##  1. A synthetic economy fixture, so shape assertions are exact and cheap.
##     Clause counts, op codes and thresholds are checked structurally, not by
##     re-reading the same constants the dictionary used.
##  2. The production catalog end to end: `EffectDomainCatalog.build()` must
##     produce a non-empty table that the native side actually accepts. That is
##     the only check that catches a metric key typo — `compile_native_catalog`
##     rejects `target_tag_metric_not_declared`, and the native `configure()`
##     rejects the whole table if a metric id is out of range.
##
## Evaluation (does a tag actually select the right cells) lives in
## `economy_runtime_effect_selector_tests.cpp`, which has a grid.

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const TargetTagDictionaryScript = preload(
	"res://scripts/effect/target_tag_dictionary.gd")

const Q16_ONE := 65536

## Op codes, mirrored from `TargetTagOp` in gdext/src/target_tag.h.
const TAG_GTE := 0
const TAG_LTE := 1
const TAG_EQ := 2
const TAG_NEQ := 3
const TAG_BIT_SET := 4

## Caps from `TargetTagTable` in gdext/src/target_tag.h.
const MAX_TAGS := 512
const MAX_ROWS := 8192

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("target tag dictionary: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_shape_against_synthetic_economy()
	_test_composite_is_a_clause_product()
	_test_intersection_folds_three_tags()
	_test_union_concatenates_clauses()
	_test_limits_hold_for_the_shipped_dictionary()
	_test_authoring_errors()
	_test_production_catalog_round_trips()


## 1. Every atom in the shipped dictionary has the shape the design doc states.
func _test_shape_against_synthetic_economy() -> void:
	var built: Dictionary = TargetTagDictionaryScript.build(_economy_fixture())
	_expect("dictionary builds from a synthetic economy",
		bool(built.get("ok", false)), str(built.get("reason", "")))
	var tags: Array = built.get("tags", [])
	var by_name := _index(tags)
	_expect("dictionary emits tags", not tags.is_empty(), str(tags.size()))

	# 边地：人口 < P0，写成 `<= P0*Q16 - 1`。人口是 count_q16，所以
	# `<= P0*Q16` 会把恰好等于 P0 的格错算成边地。
	var frontier: Array = by_name.get("cell.frontier", [])
	_expect("frontier has one row", frontier.size() == 1, str(frontier))
	if frontier.size() == 1:
		var row: Dictionary = frontier[0]
		var p0 := int(TargetTagDictionaryScript.FRONTIER_POPULATION)
		_expect("frontier reads population", String(row["metric"]) == "cell.population",
			String(row["metric"]))
		_expect("frontier is an upper bound", int(row["op"]) == TAG_LTE,
			str(row["op"]))
		_expect("frontier threshold is strictly below P0",
			int(row["threshold_q16"]) == p0 * Q16_ONE - 1,
			str(row["threshold_q16"]))

	# 聚落 / 大邑 / 繁市：三个下界，阈值都必须正好落在标定值上。
	_expect_lower_bound(by_name, "cell.settlement", "cell.population",
		int(TargetTagDictionaryScript.SETTLEMENT_POPULATION) * Q16_ONE)
	_expect_lower_bound(by_name, "cell.metropolis", "cell.population",
		int(TargetTagDictionaryScript.METROPOLIS_POPULATION) * Q16_ONE)
	_expect_lower_bound(by_name, "cell.market", "cell.trade_events",
		int(TargetTagDictionaryScript.MARKET_TRADE_EVENTS) * Q16_ONE)

	# 粮作 = 五种谷物各占一个 clause -> OR（集合成员语义）。
	# 这里断言的是"每个 clause 恰好一行、行数等于谷物数"，把 OR 写成 AND
	# 会变成"主产同时是小麦和稻米"，恒假。
	var grain: Array = by_name.get("cell.grain", [])
	_expect("grain has one row per grain good",
		grain.size() == TargetTagDictionaryScript.GRAIN_GOODS.size(),
		str(grain.size()))
	var grain_clauses := {}
	for row in grain:
		grain_clauses[int(row["clause"])] = true
	_expect("each grain good is its own clause (OR)",
		grain_clauses.size() == grain.size(), str(grain_clauses.size()))

	# 富藏 = 主导资源是 R **且** 份额 ≥50% -> 同一 clause 两行（AND）。
	var rich: Array = by_name.get("cell.rich.iron_ore", [])
	_expect("rich tag has two rows", rich.size() == 2, str(rich))
	_expect("rich rows share one clause (AND)",
		rich.size() == 2 and int(rich[0]["clause"]) == int(rich[1]["clause"]),
		str(rich))
	var rich_metrics := {}
	for row in rich:
		rich_metrics[String(row["metric"])] = true
	_expect("rich reads both the id and the share",
		rich_metrics.has("cell.dominant_resource_id")
			and rich_metrics.has("cell.dominant_resource_stock_share_q16"),
		str(rich_metrics))

	# 主产 / 地貌 每类都要有；缺一个就等于该卡永远选不到目标。
	_expect("every good gets a produces tag",
		by_name.has("cell.produces.wheat_grain")
			and by_name.has("cell.produces.iron_ore"),
		str(by_name.keys().size()))
	_expect("every landform gets a tag",
		by_name.has("cell.landform.coast")
			and by_name.has("cell.landform.hill")
			and by_name.has("cell.landform.peak"),
		str(by_name.keys().size()))
	_expect("every sector gets a tag",
		by_name.has("cell.sector.agriculture")
			and by_name.has("cell.sector.knowledge"),
		str(by_name.keys().size()))

	# 降雨：原生只会写 0 或 Q16_ONE，所以 ≥Q16_ONE 才是"当日有雨"。
	_expect_lower_bound(by_name, "cell.rain", "cell.rain_event", Q16_ONE)
	# X12 地理标签共享 metric 75 的位掩码；每格必须测自己的位，不能把整个
	# bitmask 当计数比较。
	for row in [
			["cell.river", 1], ["cell.coastal", 2],
			["cell.canal", 4], ["cell.border", 8]]:
		var geo: Array = by_name.get(String(row[0]), [])
		_expect("%s has one bit-test row" % String(row[0]), geo.size() == 1,
			str(geo))
		_expect("%s tests metric 75 bit %d" % [String(row[0]), int(row[1])],
			geo.size() == 1 and String(geo[0]["metric"]) == "cell.geo_flags"
				and int(geo[0]["op"]) == TAG_BIT_SET
				and int(geo[0]["threshold_q16"]) == int(row[1]), str(geo))

	# 全局不变式：op 合法、clause 非降、metric 非空。
	var bad_op := ""
	var bad_order := ""
	var bad_metric := ""
	for tag in tags:
		var previous := -1
		for row in tag["rows"]:
			var op := int(row["op"])
			if op < TAG_GTE or op > TAG_BIT_SET:
				bad_op = "%s:%d" % [String(tag["name"]), op]
			if String(row["metric"]).is_empty():
				bad_metric = String(tag["name"])
			var clause := int(row["clause"])
			if clause < previous:
				bad_order = "%s:%d" % [String(tag["name"]), clause]
			previous = clause
	_expect("every op is in range", bad_op.is_empty(), bad_op)
	_expect("every metric key is non-empty", bad_metric.is_empty(), bad_metric)
	_expect("clauses are non-decreasing per tag", bad_order.is_empty(), bad_order)


## 2. 复合标签靠 DNF 分配律展开：A AND B = OR_{i,j}(clauseA_i ∪ clauseB_j)。
##    单 clause 的原子两两组合必须得到一个 clause 里放两行——那才是逻辑与。
func _test_composite_is_a_clause_product() -> void:
	var built: Dictionary = TargetTagDictionaryScript.build(_economy_fixture())
	var by_name := _index(built.get("tags", []))

	var combined: Array = by_name.get("cell.frontier.agriculture", [])
	_expect("frontier x agriculture exists", not combined.is_empty(), str(by_name.size()))
	_expect("single-clause conjunction is one clause of two rows",
		combined.size() == 2 and int(combined[0]["clause"]) == 0
			and int(combined[1]["clause"]) == 0,
		str(combined))
	var metrics := {}
	for row in combined:
		metrics[String(row["metric"])] = true
	_expect("conjunction carries both predicates",
		metrics.has("cell.population")
			and metrics.has("cell.sector_output_share.agriculture_q16"),
		str(metrics))

	# 5 clause × 1 clause -> 5 clauses of 2 rows。总行数必须是 10，不是 6：
	# 若实现成"两个 clause 列表首尾相接"，就退回成 OR 了。
	var grain_frontier: Array = by_name.get("cell.frontier.grain", [])
	_expect("frontier x grain is a 5 x 1 clause product",
		grain_frontier.size() == TargetTagDictionaryScript.GRAIN_GOODS.size() * 2,
		str(grain_frontier.size()))
	var clauses := {}
	for row in grain_frontier:
		clauses[int(row["clause"])] = true
	_expect("frontier x grain keeps one clause per grain good",
		clauses.size() == TargetTagDictionaryScript.GRAIN_GOODS.size(),
		str(clauses.size()))

	_expect("market x coast exists",
		by_name.has("cell.market.coast"), str(by_name.size()))

	# Terrain axis (metric 50). Landform and terrain are two id spaces; before
	# `cell.terrain` existed「河谷」— a FLOODPLAIN terrain — had no name at all,
	# because only the landform axis was readable. 29 is TerrainType.FLOODPLAIN
	# and the .tres agrees (`data/terrain/floodplain.tres: terrain_type = 29`).
	# Rows carry the metric KEY here; the id is resolved at compile time.
	var floodplain: Array = by_name.get("cell.terrain.floodplain", [])
	_expect("terrain floodplain tag exists", not floodplain.is_empty(),
		str(by_name.size()))
	_expect("terrain floodplain reads the terrain axis",
		not floodplain.is_empty()
			and String(floodplain[0]["metric"]) == "cell.terrain",
		str(floodplain))
	_expect("terrain floodplain compares id 29 for equality",
		not floodplain.is_empty() and int(floodplain[0]["op"]) == 2
			and int(floodplain[0]["threshold_q16"]) == 29 * 65536,
		str(floodplain))
	# The two axes must not alias: a landform tag and a terrain tag share names
	# (`coast` exists on both) but not metric keys, or every「海岸」card would
	# silently be matching whichever axis happened to win.
	var landform_coast: Array = by_name.get("cell.landform.coast", [])
	_expect("landform coast and terrain coast are different axes",
		not landform_coast.is_empty()
			and String(landform_coast[0]["metric"]) == "cell.landform",
		str(landform_coast))
	_expect("terrain coast is its own tag",
		by_name.has("cell.terrain.coast"), str(by_name.size()))


## 2b. 三个以上标签的 AND。`build()` 里那批复合标签是预先焊死的**两两**组合，
##     所以卡面过去只能引用「菜单上有的」那些。`intersection()` 把任意 N 个
##     标签折成一条合成标签，卡面才第一次能写「边地 AND 粮作 AND 农业」。
func _test_intersection_folds_three_tags() -> void:
	var built: Dictionary = TargetTagDictionaryScript.build(_economy_fixture())
	var tags: Array = built.get("tags", [])
	var names := PackedStringArray([
		"cell.frontier", "cell.sector.agriculture", "cell.grain"])
	var merged: Dictionary = TargetTagDictionaryScript.intersection(names, tags)
	_expect("three tags intersect", bool(merged.get("ok", false)),
		str(merged.get("reason", "")))
	var rows: Array = merged.get("rows", [])
	# 1 clause × 1 row (frontier) ⊗ 5 clauses × 1 row (grain)
	#   ⊗ 1 clause × 1 row (agriculture) = 5 clauses × 3 rows.
	_expect("a three-tag AND is the clause product, not a concatenation",
		rows.size() == TargetTagDictionaryScript.GRAIN_GOODS.size() * 3,
		str(rows.size()))
	var clauses := {}
	var triple_clauses := {}
	for row in rows:
		var clause := int(row["clause"])
		clauses[clause] = true
		if not triple_clauses.has(clause):
			triple_clauses[clause] = {}
		# One metric per predicate: two rows of the same metric inside a clause
		# would mean a predicate was duplicated by the fold.
		triple_clauses[clause][String(row["metric"])] = true
	_expect("one clause per grain good survives the fold",
		clauses.size() == TargetTagDictionaryScript.GRAIN_GOODS.size(),
		str(clauses.size()))
	var every_clause_has_three := true
	for clause in triple_clauses:
		if (triple_clauses[clause] as Dictionary).size() != 3:
			every_clause_has_three = false
	_expect("every clause carries all three predicates", every_clause_has_three,
		str(triple_clauses))

	# 书写顺序不影响结果：两张卡用不同顺序列同样的标签，必须落到同一条合成
	# 标签上，否则词典里会堆出一串语义相同、id 不同的条目。
	var reordered := PackedStringArray([
		"cell.grain", "cell.frontier", "cell.sector.agriculture"])
	var again: Dictionary = TargetTagDictionaryScript.intersection(reordered, tags)
	_expect("tag order does not change the synthetic name",
		String(again.get("name", "")) == String(merged.get("name", "")),
		"%s vs %s" % [String(again.get("name", "")), String(merged.get("name", ""))])
	_expect("tag order does not change the clause layout",
		_row_signature(again.get("rows", [])) == _row_signature(rows),
		_row_signature(again.get("rows", [])))

	# 失败面：少名、重名、未知名、预算超支，都要 ok=false 并说明原因。
	_expect("one name is not an intersection",
		String(TargetTagDictionaryScript.intersection(
			PackedStringArray(["cell.frontier"]), tags).get("reason", ""))
			== "target_tag_intersection_needs_two")
	_expect("a repeated name is rejected",
		String(TargetTagDictionaryScript.intersection(PackedStringArray(
			["cell.frontier", "cell.frontier"]), tags).get("reason", ""))
			== "target_tag_intersection_duplicate")
	var unknown_reason := String(TargetTagDictionaryScript.intersection(
		PackedStringArray(["cell.frontier", "cell.nowhere"]), tags).get("reason", ""))
	_expect("an unknown name names itself",
		unknown_reason == "target_tag_intersection_unknown:cell.nowhere",
		unknown_reason)

	# 预算：两个 10-clause 的标签相乘是 100 条 clause，超过 64 就该在编译期
	# 硬失败，而不是编进原生表之后让整份目录校验失败。
	var wide: Array = []
	for side in 2:
		var wide_rows: Array = []
		for clause in 10:
			wide_rows.append(TargetTagDictionaryScript._row(
				"cell.population", TAG_GTE, side * Q16_ONE, clause))
		wide.append(TargetTagDictionaryScript._atom("wide.%d" % side, wide_rows))
	var over: Dictionary = TargetTagDictionaryScript.intersection(
		PackedStringArray(["wide.0", "wide.1"]), wide)
	_expect("a clause product past the budget is rejected",
		not bool(over.get("ok", true)), str(over))
	_expect("the budget rejection names the count",
		String(over.get("reason", "")).begins_with(
			"target_tag_intersection_clause_budget:"),
		str(over.get("reason", "")))


## 2c. X5 tag widening: `A OR B` appends B's clauses to A's, renumbered from 0.
##     This is deliberately the opposite operation from `intersection()`: A's
##     two-row AND clause stays one clause, and B's one-row clause becomes the
##     second clause. Concatenating rows without renumbering would make B part
##     of A's AND and silently narrow the card.
func _test_union_concatenates_clauses() -> void:
	var tag_a := TargetTagDictionaryScript._atom("x5.union.a", [
		TargetTagDictionaryScript._row("cell.population", TAG_GTE,
			400 * Q16_ONE, 0),
		TargetTagDictionaryScript._row("cell.trade_events", TAG_GTE,
			24 * Q16_ONE, 0),
	])
	var tag_b := TargetTagDictionaryScript._atom("x5.union.b", [
		TargetTagDictionaryScript._row("cell.landform", TAG_EQ,
			2 * Q16_ONE, 0),
	])
	var merged: Dictionary = TargetTagDictionaryScript.union(
		PackedStringArray(["x5.union.b", "x5.union.a"]),
		[tag_a, tag_b])
	_expect("two tags union", bool(merged.get("ok", false)),
		str(merged.get("reason", "")))
	var rows: Array = merged.get("rows", [])
	_expect("union keeps all source rows", rows.size() == 3, str(rows.size()))
	var clauses: Array[int] = []
	for row in rows:
		clauses.append(int(row["clause"]))
	_expect("union renumbers A clause then B clause",
		clauses == [0, 0, 1], str(clauses))
	_expect("union keeps A's AND pair", rows.size() == 3
		and int(rows[0]["clause"]) == 0 and int(rows[1]["clause"]) == 0,
		str(rows))
	_expect("union canonicalizes member order",
		String(merged.get("name", "")) == "x5.union.a|x5.union.b",
		String(merged.get("name", "")))
	var reordered: Dictionary = TargetTagDictionaryScript.union(
		PackedStringArray(["x5.union.a", "x5.union.b"]), [tag_b, tag_a])
	_expect("union name and rows are order-independent",
		String(reordered.get("name", "")) == String(merged.get("name", ""))
			and _row_signature(reordered.get("rows", [])) == _row_signature(rows),
		_row_signature(reordered.get("rows", [])))
	_expect("union rejects a repeated member",
		String(TargetTagDictionaryScript.union(PackedStringArray(
			["x5.union.a", "x5.union.a"]), [tag_a]).get("reason", ""))
			== "target_tag_union_duplicate")
	_expect("union rejects an unknown member",
		String(TargetTagDictionaryScript.union(PackedStringArray(
			["x5.union.a", "cell.nowhere"]), [tag_a]).get("reason", ""))
			== "target_tag_union_unknown:cell.nowhere")


## 3. The shipped dictionary must stay inside the native table's fixed limits.
##    Exceeding either one rejects the *whole* catalog, not the offending tag:
##    EFFECT bit stays clear and the twelve-domain authority graph never lands.
##    `MAX_TAGS` / `MAX_ROWS` here are the native constants' mirrors — copying
##    one of them wrong installs the gate at the wrong height, and the failure
##    mode is "the entire catalog is refused", not "this tag is refused".
func _test_limits_hold_for_the_shipped_dictionary() -> void:
	var built: Dictionary = TargetTagDictionaryScript.build(_economy_fixture())
	var tags: Array = built.get("tags", [])
	var rows := 0
	for tag in tags:
		rows += (tag["rows"] as Array).size()
	_expect("tag count is within MAX_TAGS", tags.size() <= MAX_TAGS,
		"%d > %d" % [tags.size(), MAX_TAGS])
	_expect("row count is within MAX_ROWS", rows <= MAX_ROWS,
		"%d > %d" % [rows, MAX_ROWS])
	_expect("names are unique", _index(tags).size() == tags.size(),
		"%d vs %d" % [_index(tags).size(), tags.size()])
	print("  [INFO] shipped dictionary: %d tags, %d rows" % [tags.size(), rows])


## 4. Authoring mistakes have to fail loudly, with the offending id attached.
func _test_authoring_errors() -> void:
	var missing_grain := _economy_fixture()
	var shrunk: PackedStringArray = PackedStringArray(["wheat_grain", "iron_ore"])
	missing_grain["good_ids"] = shrunk
	var built: Dictionary = TargetTagDictionaryScript.build(missing_grain)
	_expect("a missing grain good is rejected",
		not bool(built.get("ok", true)), str(built.get("reason", "")))
	_expect("the rejection names the missing good",
		String(built.get("reason", "")) == "target_tag_good_missing:rice_grain",
		str(built.get("reason", "")))

	var no_ids := _economy_fixture()
	no_ids["good_ids"] = PackedStringArray()
	_expect("an empty good table is rejected",
		String(TargetTagDictionaryScript.build(no_ids).get("reason", ""))
			== "target_tag_economy_ids_missing")

	var unavailable := {"ok": false}
	_expect("an unusable economy catalog is rejected",
		String(TargetTagDictionaryScript.build(unavailable).get("reason", ""))
			== "target_tag_economy_catalog_unavailable")


## 5. The production catalog is the only place a metric key typo can surface:
##    `compile_native_catalog` checks the key, and native `configure()` checks
##    the row layout. Both must accept the dictionary the game actually ships.
func _test_production_catalog_round_trips() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var catalog: Resource = EffectDomainCatalogScript.build()
	_expect("production catalog builds", catalog != null)
	if catalog == null:
		return
	var tags: Array = catalog.get("target_tags")
	_expect("production catalog carries the tag dictionary", not tags.is_empty(),
		str(tags.size()))
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("production catalog compiles", bool(compiled.get("ok", false)),
		str(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		return
	var names: PackedStringArray = compiled.get("target_tags", PackedStringArray())
	var production_rows: int = (compiled.get(
		"tag_metric_ids", PackedInt32Array()) as PackedInt32Array).size()
	print("  [INFO] production dictionary: %d tags, %d rows" % [
		names.size(), production_rows])
	_expect("compiled table keeps every tag", names.size() == tags.size(),
		"%d vs %d" % [names.size(), tags.size()])

	# 标签 id 是 1-based 下标，卡面的 `target_selector_param[1]` 直接写它。
	# 所以前七个 id 是**契约**：卡面会硬编码 1..7，重排必须变成红色而不是
	# 静默换目标。整体自洽检查顺带当重复名检测器——重名时 tag_index 返回
	# 第一次出现的下标，与当前位置对不上。
	var anchors := [
		"cell.frontier", "cell.settlement", "cell.metropolis", "cell.market",
		"cell.specialized", "cell.specialized_high", "cell.grain",
	]
	for i in range(anchors.size()):
		var expected := i + 1
		var actual := int(TargetTagDictionaryScript.tag_index(tags, anchors[i]))
		_expect("tag id %d is %s" % [expected, anchors[i]], actual == expected,
			"got %d" % actual)
	var drift := ""
	for i in range(tags.size()):
		if int(TargetTagDictionaryScript.tag_index(tags, String(tags[i]["name"]))) != i + 1:
			drift = String(tags[i]["name"])
			break
	_expect("tag ids are the emitted order and names are unique", drift.is_empty(),
		drift)
	_expect("an unknown tag name resolves to 0",
		int(TargetTagDictionaryScript.tag_index(tags, "cell.no_such_tag")) == 0)
	var offsets: PackedInt32Array = compiled.get(
		"tag_offsets", PackedInt32Array())
	_expect("compiled offsets close on the row count",
		offsets.size() == names.size() + 1
			and offsets[offsets.size() - 1] == (compiled.get(
				"tag_metric_ids", PackedInt32Array()) as PackedInt32Array).size(),
		str(offsets.size()))

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var accepted: Dictionary = ext.configure_effects(compiled)
	_expect("native accepts the production tag table",
		bool(accepted.get("ok", false)), str(accepted))


# --- helpers ------------------------------------------------------------

## Smallest economy catalog that still exercises every branch: good ids are the
## real ones (so 粮作 resolves) plus a non-grain good, and two resources.
func _economy_fixture() -> Dictionary:
	return {
		"ok": true,
		"good_ids": PackedStringArray([
			"wheat_grain", "rice_grain", "corn_grain", "potatoes", "grain",
			"iron_ore",
		]),
		"resource_ids": PackedStringArray(["iron_ore", "coal"]),
	}


func _index(tags: Array) -> Dictionary:
	var out := {}
	for tag in tags:
		out[String(tag["name"])] = tag["rows"]
	return out


## Order-sensitive fingerprint of a row list. Used to prove that reordering the
## input names produces byte-identical rows, not merely the same name: the
## clause numbers are what the runtime groups on, so "same clauses, different
## indices" would still be a different table.
func _row_signature(rows: Array) -> String:
	var parts: PackedStringArray = []
	for row in rows:
		parts.append("%d:%s:%d:%d" % [int(row["clause"]), String(row["metric"]),
			int(row["op"]), int(row["threshold_q16"])])
	return "|".join(parts)


func _expect_lower_bound(by_name: Dictionary, tag: String, metric: String,
		threshold_q16: int) -> void:
	var rows: Array = by_name.get(tag, [])
	_expect("%s has one row" % tag, rows.size() == 1, str(rows))
	if rows.size() != 1:
		return
	var row: Dictionary = rows[0]
	_expect("%s reads %s" % [tag, metric], String(row["metric"]) == metric,
		String(row["metric"]))
	_expect("%s is a lower bound" % tag, int(row["op"]) == TAG_GTE,
		str(row["op"]))
	_expect("%s threshold matches calibration" % tag,
		int(row["threshold_q16"]) == threshold_q16, str(row["threshold_q16"]))


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
