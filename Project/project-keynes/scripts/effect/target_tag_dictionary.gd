class_name TargetTagDictionary
extends RefCounted

## 理念卡的**标签词典**（设计文档 §1 那张表的可执行版本）。
##
## 这里只**生成数据**，不参与判定：产物是一组 `{name, rows}`，
## rows 形如 `{metric, op, threshold_q16, clause}`，由 EffectCatalog 编进
## 原生目标标签表（`gdext/src/target_tag.h`）。判据在原生侧，本文件只负责
## 「把中文标签定义翻译成 metric + 比较 + 阈值」。
##
## 语义（与 TargetTagTable::matches 严格对应，勿凭直觉改动）：
##   - **同一 clause 内的行是 AND**
##   - **不同 clause 之间是 OR**
##   - 一个标签至少要有 1 行，否则整份目录校验失败
##
## 因此「粮作」= 五个单行 clause → OR（集合成员语义），而「富藏铁」=
## 同一 clause 两行 → AND。两者都不需要新增算子。

const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const Q16_ONE := 65536

# --- TargetTagOp 镜像 ---------------------------------------------------
# 顺序必须与 gdext/src/target_tag.h 的 TargetTagOp 逐项一致。
const OP_GTE := 0
const OP_LTE := 1
const OP_EQ := 2
const OP_NEQ := 3
const OP_BIT_SET := 4

# --- 标定表（唯一可调处）------------------------------------------------
#
# 设计文档 §1 要求 P0/P1/P2/T 按「开局后 50 年存档的自有地块分布」的分位数
# 标定：边地 = 人口 30 分位，聚落 = 70 分位，大邑 = 90 分位，繁市 = 贸易事件
# 75 分位。**仓内目前既没有 50 年存档，也没有长期经济模拟探针**，所以下面四
# 个值是临时值，用「地块人口量级约百人」的既有测试夹具（tests/map_activity_
# layer_test.gd 用 population = 108）作锚点推的，不是分位数算出来的。
#
# 标定完成后只需要改这四个常量，词典与卡面定义都不用动。运行时也能改
# `effect_catalog.target_tags` 里的阈值覆盖，不必重新编译原生库。
const CALIBRATION_IS_PROVISIONAL := true
const FRONTIER_POPULATION := 120      # 边地：人口 < P0（目标 30 分位）
const SETTLEMENT_POPULATION := 400    # 聚落：人口 ≥ P1（目标 70 分位）
const METROPOLIS_POPULATION := 1200   # 大邑：人口 ≥ P2（目标 90 分位）
const MARKET_TRADE_EVENTS := 24       # 繁市：贸易事件 ≥ T（目标 75 分位）

## 「粮作」的物资集合。用稳定 id 而不是分类，因为分类（`starchy_staple`）
## 没有进 EffectCatalog；若将来扩表，这里加一行即可。
## 缺任何一个都会让 build() 报 `target_tag_good_missing:<id>` 硬失败——
## 这是刻意的：悄悄少一个谷物会让粮作标签静默变窄。
const GRAIN_GOODS := [
	"wheat_grain",
	"rice_grain",
	"corn_grain",
	"potatoes",
	"grain",
]

## 支柱部门。metric 是**产出占比**（37–41），不是建筑数占比：建筑数占比
## 在产出系数变化时不移动，条件会永远闭不上环。
const SECTORS := [
	{"id": "agriculture", "metric": "cell.sector_output_share.agriculture_q16"},
	{"id": "extractive", "metric": "cell.sector_output_share.extractive_q16"},
	{"id": "manufacturing", "metric": "cell.sector_output_share.manufacturing_q16"},
	{"id": "energy", "metric": "cell.sector_output_share.energy_q16"},
	{"id": "knowledge", "metric": "cell.sector_output_share.knowledge_q16"},
]

## 复合标签的左因子：规模档。乘上每个支柱部门，得到
## 「边地的农业地块」「大邑的工业地块」这类两谓词条件。
const COMPOSITE_SCALES := ["cell.frontier", "cell.settlement", "cell.metropolis"]

# --- 预算（原生表的镜像）-------------------------------------------------
# 与 gdext/src/target_tag.h 的 TargetTagTable::MAX_TAGS / MAX_ROWS 同值。
# 抄这两个数是为了把失败挡在编译期：原生侧超限会整份目录校验失败，
# 也就是**所有**卡都拿不到标签，而不只是超限的那张。
const MAX_TAGS := 512
const MAX_ROWS := 8192

## 合成标签的 clause 乘积预算。`cell.frontier`(1) × `cell.grain`(5) 只有 5，
## 真正的三谓词组合落在 10–20 条 clause 量级；64 足够宽，又能挡住
## 「N 个多 clause 标签相乘」这种指数爆炸。
const MAX_INTERSECTION_CLAUSES := 64
const MAX_INTERSECTION_ROWS := 256
## 与 IdeologyEffectDefinition.MAX_SELECTOR_TAGS 同值；这里是第二道闸。
const MAX_INTERSECTION_TAGS := 4
## X5 unions are narrower than intersections (no clause product), but still
## bounded so one typo cannot append an unbounded synthetic row group.
const MAX_UNION_TAGS := 16


# --- 入口 ---------------------------------------------------------------

## `economy_catalog` 是 EconomyCatalog.compile_native_catalog() 的产物，
## 只需要其中的 `good_ids` / `resource_ids`（id 就是这两个数组的下标）。
## 返回 {"ok": bool, "reason": String, "tags": Array[Dictionary]}。
static func build(economy_catalog: Dictionary) -> Dictionary:
	if not bool(economy_catalog.get("ok", false)):
		return {"ok": false, "reason": "target_tag_economy_catalog_unavailable"}
	var good_ids: PackedStringArray = economy_catalog.get(
		"good_ids", PackedStringArray())
	var resource_ids: PackedStringArray = economy_catalog.get(
		"resource_ids", PackedStringArray())
	if good_ids.is_empty() or resource_ids.is_empty():
		return {"ok": false, "reason": "target_tag_economy_ids_missing"}
	var good_index := {}
	for i in range(good_ids.size()):
		good_index[String(good_ids[i])] = i
	var landform_enum: Dictionary = LandformTypeScript.LF
	# TerrainType.TERRAIN is an enum, which GDScript exposes as name -> value
	# exactly like a const Dictionary, so the same loop shape works.
	var terrain_enum: Dictionary = TerrainTypeScript.TERRAIN

	var tags: Array = []
	var by_name := {}

	# ── 规模档（人口 / 贸易事件）───────────────────────────────────────
	# 人口口径是 count_q16：整数人口 p 采样成 p * Q16_ONE。所以
	# 「人口 < P0」写成 `≤ P0*Q16 - 1`，与「p ≤ P0-1」严格等价；
	# 若写成 `≤ P0*Q16` 会把恰好等于 P0 的格算进边地。
	_append(tags, by_name, _atom("cell.frontier", [_row(
		"cell.population", OP_LTE, FRONTIER_POPULATION * Q16_ONE - 1)]))
	_append(tags, by_name, _atom("cell.settlement", [_row(
		"cell.population", OP_GTE, SETTLEMENT_POPULATION * Q16_ONE)]))
	_append(tags, by_name, _atom("cell.metropolis", [_row(
		"cell.population", OP_GTE, METROPOLIS_POPULATION * Q16_ONE)]))
	_append(tags, by_name, _atom("cell.market", [_row(
		"cell.trade_events", OP_GTE, MARKET_TRADE_EVENTS * Q16_ONE)]))

	# ── 产出结构 ─────────────────────────────────────────────────────
	_append(tags, by_name, _atom("cell.specialized", [_row(
		"cell.top_output_good_share_q16", OP_GTE, _pct(60))]))
	_append(tags, by_name, _atom("cell.specialized_high", [_row(
		"cell.top_output_good_share_q16", OP_GTE, _pct(80))]))
	var grain_rows: Array = []
	for i in range(GRAIN_GOODS.size()):
		var grain_id := String(GRAIN_GOODS[i])
		if not good_index.has(grain_id):
			return {"ok": false, "reason": "target_tag_good_missing:" + grain_id}
		grain_rows.append(_row("cell.dominant_output_good_id", OP_EQ,
			int(good_index[grain_id]) * Q16_ONE, i))
	_append(tags, by_name, _atom("cell.grain", grain_rows))
	for i in range(good_ids.size()):
		_append(tags, by_name, _atom("cell.produces." + String(good_ids[i]),
			[_row("cell.dominant_output_good_id", OP_EQ, i * Q16_ONE)]))
	for sector in SECTORS:
		var sector_id := String(sector["id"])
		_append(tags, by_name, _atom("cell.sector." + sector_id,
			[_row(String(sector["metric"]), OP_GTE, _pct(50))]))

	# ── 资源存量 ─────────────────────────────────────────────────────
	# 「富藏〔R〕」= 主导资源是 R **且** 存量占比 ≥50%，两行同 clause → AND。
	for i in range(resource_ids.size()):
		_append(tags, by_name, _atom("cell.rich." + String(resource_ids[i]), [
			_row("cell.dominant_resource_id", OP_EQ, i * Q16_ONE),
			_row("cell.dominant_resource_stock_share_q16", OP_GTE, _pct(50)),
		]))

	# ── 结构 / 状态 ──────────────────────────────────────────────────
	_append(tags, by_name, _atom("cell.diversified", [_row(
		"cell.distinct_sector_count", OP_GTE, 3 * Q16_ONE)]))
	_append(tags, by_name, _atom("cell.chained", [_row(
		"cell.complete_chain_count", OP_GTE, 1 * Q16_ONE)]))
	_append(tags, by_name, _atom("cell.unemployed", [_row(
		"cell.unemployment_q16", OP_GTE, _pct(10))]))
	_append(tags, by_name, _atom("cell.shortage", [_row(
		"cell.essentials_shortage_q16", OP_GTE, _pct(20))]))
	_append(tags, by_name, _atom("cell.abundant", [_row(
		"cell.resource_abundance_q16", OP_GTE, _pct(80))]))
	_append(tags, by_name, _atom("cell.depleted", [_row(
		"cell.resource_shortage_q16", OP_GTE, _pct(30))]))
	# rain_event 原生侧只会写 0 或 Q16_ONE（economy_runtime.cpp 里
	# RAIN_EVENT_THRESHOLD_Q16 判定后二值化），所以 ≥Q16_ONE 就是「当日有雨」。
	_append(tags, by_name, _atom("cell.rain", [_row(
		"cell.rain_event", OP_GTE, Q16_ONE)]))
	# ── 地貌 ─────────────────────────────────────────────────────────
	# 枚举直接来自 LandformType.LF，尾部追加的 PLATEAU / RIFT_VALLEY /
	# CANYON 自动带上，不需要在这里手工抄 id。注意 metric 10 是 **landform**
	# 轴，不含「河谷 / 泛滥平原」那些 terrain 轴的地貌（见 §27.6）。
	for lf_name in landform_enum:
		var lf_id := int(landform_enum[lf_name])
		_append(tags, by_name, _atom(
			"cell.landform." + String(lf_name).to_lower(),
			[_row("cell.landform", OP_EQ, lf_id * Q16_ONE)]))

	# ── 地形（metric 50，与地貌是两套 id 空间）────────────────────────
	# LandformType 是「这块地的形状」（平原/丘陵/三角洲/峡谷…），TerrainType
	# 是「这块地上长什么」（草地/森林/泛滥平原/寒漠…）。§1 的表把两者混在
	# 「地貌」一行里，导致「河谷」——floodplain，一个 **terrain** ——
	# 在只有 metric 10 时根本写不出来。
	#
	# 同样遍历枚举而不是手抄 31 个 id：TERRAIN 尾部还会追加（26+ 那批就是
	# terrain-overhaul 追加的），抄写必然漂移。
	for t_name in terrain_enum:
		var t_id := int(terrain_enum[t_name])
		_append(tags, by_name, _atom(
			"cell.terrain." + String(t_name).to_lower(),
			[_row("cell.terrain", OP_EQ, t_id * Q16_ONE)]))

	# ── 复合标签 ─────────────────────────────────────────────────────
	# DNF 的分配律：A AND B = OR_{i,j}(clauseA_i ∪ clauseB_j)。因为匹配语义
	# 是「clause 内 AND、跨 clause OR」，把两个标签的 clause 两两合并成一个
	# 更大的 clause，正好就是逻辑与。单 clause 的原子两两组合只花两行。
	for scale in COMPOSITE_SCALES:
		for sector in SECTORS:
			var sector_id := String(sector["id"])
			_append(tags, by_name, _conjunction(
				"%s.%s" % [scale, sector_id],
				by_name[scale], by_name["cell.sector." + sector_id]))
	for sector in SECTORS:
		var sector_id := String(sector["id"])
		_append(tags, by_name, _conjunction(
			"cell.market." + sector_id,
			by_name["cell.market"], by_name["cell.sector." + sector_id]))
	for lf_name in landform_enum:
		var lf_key := String(lf_name).to_lower()
		_append(tags, by_name, _conjunction(
			"cell.market." + lf_key,
			by_name["cell.market"], by_name["cell.landform." + lf_key]))
	# 「边地的粮作地块」：左 1 个 clause × 右 5 个 clause → 5 个 clause，
	# 每个 clause 是 {人口 < P0} AND {主产 = 某一种谷物}，正是要的语义。
	for scale in COMPOSITE_SCALES:
		_append(tags, by_name, _conjunction(
			"%s.grain" % scale, by_name[scale], by_name["cell.grain"]))

	# X12 geography flags. The metric is a raw bitmask, not a count, so each tag
	# tests its own bit instead of comparing the combined integer.
	# These MUST stay at the true end of the table: tag ids are 1-based array
	# indices, and inserting them earlier silently retargets every later card.
	_append(tags, by_name, _atom("cell.river", [_row(
		"cell.geo_flags", OP_BIT_SET, 1)]))
	_append(tags, by_name, _atom("cell.coastal", [_row(
		"cell.geo_flags", OP_BIT_SET, 2)]))
	_append(tags, by_name, _atom("cell.canal", [_row(
		"cell.geo_flags", OP_BIT_SET, 4)]))
	_append(tags, by_name, _atom("cell.border", [_row(
		"cell.geo_flags", OP_BIT_SET, 8)]))
	# X13a climate tags. Temperature uses the runtime normalization
	# `C = 50 * q - 17`: 5C -> 28836, 22C -> 51118, both rounded.
	_append(tags, by_name, _atom("cell.climate.cold", [_row(
		"cell.temperature_annual_q16", OP_LTE, 28836)]))
	_append(tags, by_name, _atom("cell.climate.hot", [_row(
		"cell.temperature_annual_q16", OP_GTE, 51118)]))
	_append(tags, by_name, _atom("cell.climate.dry_spell", [_row(
		"cell.dry_streak_days", OP_GTE, 20 * Q16_ONE)]))
	# X9a family tags. Metric 84 is count_q16; metric 85 is raw Q16.
	_append(tags, by_name, _atom("cell.clan", [_row(
		"cell.family_branch_count", OP_GTE, Q16_ONE)]))
	_append(tags, by_name, _atom("cell.eminent_clan", [_row(
		"cell.max_branch_prestige_q16", OP_GTE, 32768)]))

	# 重名会让同名标签在原生侧只保留先出现的偏移，卡面引用到哪个全凭顺序。
	# 用一个集合大小对账代替 assert —— assert 在 release 导出里是空的，
	# 而这份内容是编译期固化的，出错必须当场硬失败。
	if by_name.size() != tags.size():
		return {"ok": false, "reason": "target_tag_name_duplicate"}

	# Same reason as the duplicate check: the native table rejects an oversized
	# dictionary wholesale, which would cost every card its tag filter, so the
	# ceiling is enforced here where the message can say which one was hit.
	if tags.size() > MAX_TAGS:
		return {"ok": false, "reason": "target_tag_table_over_capacity:%d" % tags.size()}
	var total_rows := 0
	for tag in tags:
		total_rows += (tag["rows"] as Array).size()
	if total_rows > MAX_ROWS:
		return {"ok": false, "reason": "target_tag_row_over_capacity:%d" % total_rows}

	return {"ok": true, "reason": "", "tags": tags}


# --- 构造件 -------------------------------------------------------------

static func _pct(percent: int) -> int:
	# 向下取整，让「份额恰好等于 N%」落进阈值内；份额本身也是向下取整量化，
	# 向上取整会把 59.99% 放进来。
	return percent * Q16_ONE / 100


static func _row(metric: String, op: int, threshold_q16: int,
		clause: int = 0) -> Dictionary:
	return {
		"metric": metric,
		"op": op,
		"threshold_q16": threshold_q16,
		"clause": clause,
	}


static func _atom(name: String, rows: Array) -> Dictionary:
	return {"name": name, "rows": rows}


static func _append(tags: Array, by_name: Dictionary, tag: Dictionary) -> void:
	# 重名只在这里记账，build() 末尾用 tags.size() 对账。
	var name := String(tag["name"])
	by_name[name] = tag["rows"]
	tags.append(tag)


static func _clause_groups(rows: Array) -> Array:
	var groups: Array = []
	var current := -1
	for row in rows:
		var clause := int(row["clause"])
		if clause != current:
			current = clause
			groups.append([])
		groups[groups.size() - 1].append(row)
	return groups


static func _conjunction(name: String, left: Array, right: Array) -> Dictionary:
	var left_groups := _clause_groups(left)
	var right_groups := _clause_groups(right)
	var rows: Array = []
	var clause := 0
	for left_group in left_groups:
		for right_group in right_groups:
			for row in left_group:
				rows.append(_row(String(row["metric"]), int(row["op"]),
					int(row["threshold_q16"]), clause))
			for row in right_group:
				rows.append(_row(String(row["metric"]), int(row["op"]),
					int(row["threshold_q16"]), clause))
			clause += 1
	return {"name": name, "rows": rows}


## N 个标签的**逻辑与**，返回可直接 append 进 tags 的新标签。
##
## `build()` 里那批复合标签是「预先焊死的两两组合」；这个函数是给卡面用的
## 运行期入口——卡上写 `target_selector_tags = ["cell.settlement",
## "cell.sector.agriculture", "cell.grain"]`，编译时在这里折成一条合成标签，
## 运行时仍然只读一个 `param[1]` id，原生侧一行都不用改。
##
## 名字排序后再折，是为了让**书写顺序不影响结果**：两张卡用不同顺序列同样的
## 标签，必须命中同一条合成标签，否则词典里会堆出一串语义相同、id 不同的条目，
## 而参数表还会因为顺序不同给出不同的 clause 编号。
##
## 返回 {"ok", "reason", "name", "rows"}。名字不存在、clause 乘积或行数超预算
## 都返回 ok=false —— 这些都是编译期就该硬失败的错，不是运行期能兜住的。
static func intersection(names: PackedStringArray, tags: Array) -> Dictionary:
	if names.size() < 2:
		return {"ok": false, "reason": "target_tag_intersection_needs_two"}
	var rows_by_name := {}
	for tag in tags:
		rows_by_name[String(tag["name"])] = tag["rows"]
	var ordered := PackedStringArray(names)
	ordered.sort()
	if int(ordered.size()) > MAX_INTERSECTION_TAGS:
		return {"ok": false, "reason": "target_tag_intersection_tag_count"}
	var rows: Array = []
	var composite := ""
	var previous := ""
	for index in ordered.size():
		var name := String(ordered[index])
		if name == previous:
			# `A AND A` is `A`; the card-level rulebook already rejects repeats,
			# and this second gate exists because `intersection()` is also
			# reachable from tooling that never builds a card.
			return {"ok": false, "reason": "target_tag_intersection_duplicate"}
		previous = name
		if not rows_by_name.has(name):
			return {"ok": false, "reason": "target_tag_intersection_unknown:%s" % name}
		if index == 0:
			rows = (rows_by_name[name] as Array).duplicate()
			composite = name
			continue
		var merged := _conjunction(composite + "&" + name, rows, rows_by_name[name])
		rows = merged["rows"]
		composite = String(merged["name"])
		var clauses := _clause_groups(rows).size()
		if clauses > MAX_INTERSECTION_CLAUSES:
			return {"ok": false, "reason": "target_tag_intersection_clause_budget:%d" % clauses}
		if rows.size() > MAX_INTERSECTION_ROWS:
			return {"ok": false, "reason": "target_tag_intersection_row_budget:%d" % rows.size()}
	return {"ok": true, "reason": "", "name": composite, "rows": rows}


## N 个标签的**逻辑或**。与 `intersection()` 相反，这是把各标签的 clause
## 组直接串接并重新编号，因此结果正好是「命中任意一个成员」。
##
## X5 的重写会用它生成 `cell.landform.delta|cell.terrain.floodplain` 这类
## 合成标签；返回值仍是一个普通标签，原生侧只看到追加后的 id。
static func union(names: PackedStringArray, tags: Array) -> Dictionary:
	if names.is_empty():
		return {"ok": false, "reason": "target_tag_union_empty"}
	if names.size() == 1:
		var only_name := String(names[0]).strip_edges()
		for tag in tags:
			if String(tag["name"]) == only_name:
				return {"ok": true, "reason": "", "name": only_name,
					"rows": (tag["rows"] as Array).duplicate()}
		return {"ok": false, "reason": "target_tag_union_unknown:%s" % only_name}
	var rows_by_name := {}
	for tag in tags:
		rows_by_name[String(tag["name"])] = tag["rows"]
	var ordered := PackedStringArray(names)
	ordered.sort()
	if int(ordered.size()) > MAX_UNION_TAGS:
		return {"ok": false, "reason": "target_tag_union_tag_count"}
	var rows: Array = []
	var composite := ""
	var previous := ""
	var clause := 0
	for name in ordered:
		if String(name) == previous:
			return {"ok": false, "reason": "target_tag_union_duplicate"}
		previous = String(name)
		if not rows_by_name.has(name):
			return {"ok": false, "reason": "target_tag_union_unknown:%s" % name}
		composite = String(name) if composite.is_empty() \
			else composite + "|" + String(name)
		for group in _clause_groups(rows_by_name[name]):
			for row in group:
				rows.append(_row(String(row["metric"]), int(row["op"]),
					int(row["threshold_q16"]), clause))
			clause += 1
	if rows.size() > MAX_INTERSECTION_ROWS:
		return {"ok": false, "reason": "target_tag_union_row_budget:%d" % rows.size()}
	return {"ok": true, "reason": "", "name": composite, "rows": rows}


## 标签 id = **1-based 的数组下标**（0 表示"不筛"）。卡面的
## `target_selector_param[1]` 直接写这个数，所以**顺序是契约**：
## 新标签只能追加，不能插在中间——插一个就会让它后面所有卡的 param[1]
## 整体错位，而且不报错、不崩溃，只是安静地作用到别的地块上。
## 与 metric id 同一套规矩（`FamilyEffectMetricId` 的注释也写着 MUST be appended）。
## 返回 0 表示没有这个标签名。
static func tag_index(tags: Array, name: String) -> int:
	for i in range(tags.size()):
		if String(tags[i]["name"]) == name:
			return i + 1
	return 0


## 名字 -> 1-based id 的预摊表，供编译期一次构建、多次查。
## 和 `tag_index()` 必须是同一套约定——测试会逐条对账两者一致。
static func tag_id_map(tags: Array) -> Dictionary:
	var out := {}
	for i in range(tags.size()):
		out[String(tags[i]["name"])] = i + 1
	return out
