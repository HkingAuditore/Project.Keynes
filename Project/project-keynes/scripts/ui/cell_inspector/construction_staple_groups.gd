extends RefCounted




static func _construction_entry_before(a: Dictionary, b: Dictionary,
		sort: String) -> bool:
	var a_eligible = bool(a.get("eligible", false))
	var b_eligible = bool(b.get("eligible", false))
	if a_eligible != b_eligible:
		return a_eligible
	var a_score = int(a.get("score", 0))
	var b_score = int(b.get("score", 0))
	var a_cash = int(a.get("cash_required", 0))
	var b_cash = int(b.get("cash_required", 0))
	if sort == "cost":
		if a_cash != b_cash:
			return a_cash < b_cash
		if a_score != b_score:
			return a_score > b_score
	elif sort == "newest":
		var a_rank = int(a.get("maturity_rank", 0))
		var b_rank = int(b.get("maturity_rank", 0))
		if a_rank != b_rank:
			return a_rank > b_rank
		if a_score != b_score:
			return a_score > b_score
	elif a_score != b_score:
		return a_score > b_score
	elif a_cash != b_cash:
		return a_cash < b_cash
	var a_name = String(a.get("name", ""))
	var b_name = String(b.get("name", ""))
	if a_name != b_name:
		return a_name < b_name
	return int(a.get("type_id", 0)) < int(b.get("type_id", 0))


## ── 主粮建筑折叠（一级 rank 卡 / 二级作物 / 三级变体）──────────────────
## 折叠键 = 首个产出货，主粮判定 = 该货的类别为 starchy_staple。只折叠这类
## 建筑，其它 entry 原样透传。纯数据变换：卡行也指向一个真实 type_id，所以
## 「点一下直接建」依旧落到原有命令参数上，折叠只改分组与分页。
const STAPLE_CATEGORY := "starchy_staple"
const CROP_ORDER := ["grain", "wheat_grain", "rice_grain", "corn_grain", "potatoes"]


## 该 building 的主粮作物键；不是主粮建筑返回空串。
static func staple_crop_key(type_id: int, columns: Dictionary) -> String:
	var offsets: PackedInt32Array = columns.get("building_output_offsets", PackedInt32Array())
	var out_goods: PackedInt32Array = columns.get("building_output_good_ids", PackedInt32Array())
	var good_ids: PackedStringArray = columns.get("good_ids", PackedStringArray())
	var categories: PackedStringArray = columns.get("good_category_ids", PackedStringArray())
	if type_id < 0 or type_id + 1 >= offsets.size():
		return ""
	var begin := int(offsets[type_id])
	var end := int(offsets[type_id + 1])
	if begin < 0 or end <= begin or begin >= out_goods.size():
		return ""
	var good_index := int(out_goods[begin])
	if good_index < 0 or good_index >= good_ids.size() or good_index >= categories.size():
		return ""
	if String(categories[good_index]) != STAPLE_CATEGORY:
		return ""
	return String(good_ids[good_index])


## 该 building 是否产出两件以上货品（通用农场的「粮+菜」）。
static func staple_outputs_multiple(type_id: int, columns: Dictionary) -> bool:
	var offsets: PackedInt32Array = columns.get("building_output_offsets", PackedInt32Array())
	if type_id < 0 or type_id + 1 >= offsets.size():
		return false
	return int(offsets[type_id + 1]) - int(offsets[type_id]) > 1


## 变体排序：可建在前 → score 降序 → cash_required 升序 → type_id 升序。
## 不用 progression_step：高地精准块茎的 step=1 会被顶到第一，而它是同档最弱的一支。
static func staple_variant_before(a: Dictionary, b: Dictionary) -> bool:
	var a_eligible := bool(a.get("eligible", false))
	var b_eligible := bool(b.get("eligible", false))
	if a_eligible != b_eligible:
		return a_eligible
	var a_score := int(a.get("score", 0))
	var b_score := int(b.get("score", 0))
	if a_score != b_score:
		return a_score > b_score
	var a_cash := int(a.get("cash_required", 0))
	var b_cash := int(b.get("cash_required", 0))
	if a_cash != b_cash:
		return a_cash < b_cash
	return int(a.get("type_id", 0)) < int(b.get("type_id", 0))


## 把主粮 entry 折成三级：rank 卡 → 作物选项 → 变体。
## 展开状态由调用方传入：expanded_ranks 里的档展开出作物行，expanded_crops
## （键 "rank|crop"）里的选项展开出变体行。这样展开只重算本页 rows，列表控件
## 不必维护层级。rank 卡最多 7 张、作物顺序固定为 CROP_ORDER、变体保留原 type_id。
## 非主粮 entry 原样透传，排在最后。
static func fold_staple_entries(entries: Array, columns: Dictionary,
		expanded_ranks: Dictionary = {}, expanded_crops: Dictionary = {}) -> Array:
	var groups: Dictionary = {}
	var order: Array = []
	var passthrough: Array = []
	for raw in entries:
		var entry: Dictionary = raw
		var type_id := int(entry.get("type_id", -1))
		var crop := staple_crop_key(type_id, columns)
		if crop.is_empty():
			passthrough.append(entry)
			continue
		var rank := int(entry.get("maturity_rank", 0))
		var key := "%d|%s" % [rank, crop]
		if not groups.has(key):
			groups[key] = {
				"rank": rank,
				"crop": crop,
				"two_goods": staple_outputs_multiple(type_id, columns),
				"variants": [],
			}
			order.append(key)
		(groups[key]["variants"] as Array).append(entry)
	for key in order:
		var variants: Array = (groups[key] as Dictionary)["variants"]
		variants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return staple_variant_before(a, b))

	var ranks: Dictionary = {}
	for key in order:
		ranks[int((groups[key] as Dictionary)["rank"])] = true
	var sorted_ranks: Array = ranks.keys()
	sorted_ranks.sort()

	var rows: Array = []
	for rank in sorted_ranks:
		var rank_int := int(rank)
		var crops: Array = []
		for crop in CROP_ORDER:
			var ordered_key := "%d|%s" % [rank_int, crop]
			if groups.has(ordered_key):
				crops.append(groups[ordered_key])
		for key in order:
			var extra_group: Dictionary = groups[key]
			if int(extra_group["rank"]) != rank_int:
				continue
			if CROP_ORDER.has(String(extra_group["crop"])):
				continue
			crops.append(extra_group)
		var head: Dictionary = {}
		for crop_entry in crops:
			for variant in ((crop_entry as Dictionary)["variants"] as Array):
				var candidate: Dictionary = variant
				if head.is_empty() or staple_variant_before(candidate, head):
					head = candidate
		var rank_open := expanded_ranks.has(rank_int)
		rows.append(_fold_head_row(head, {
			"kind": "rank_card",
			"rank": rank_int,
			"crops": crops,
			"expanded": rank_open,
		}, {
			"kind": "toggle_rank",
			"rank": rank_int,
			"expanded": rank_open,
			"crop_count": crops.size(),
		}))
		if not rank_open:
			continue
		for crop_entry in crops:
			var group: Dictionary = crop_entry
			var crop_key := "%d|%s" % [rank_int, String(group["crop"])]
			var crop_open := expanded_crops.has(crop_key)
			var variants: Array = group["variants"]
			var crop_head: Dictionary = variants[0] if not variants.is_empty() else {}
			rows.append(_fold_head_row(crop_head, {
				"kind": "crop_option",
				"rank": rank_int,
				"crop": String(group["crop"]),
				"two_goods": bool(group["two_goods"]),
				"variant_count": variants.size(),
				"expanded": crop_open,
				"variants": variants,
			}, {
				"kind": "toggle_crop",
				"rank": rank_int,
				"crop": String(group["crop"]),
				"expanded": crop_open,
				"variant_count": variants.size(),
				"single_variant": variants.size() <= 1,
			}))
			if not crop_open or variants.size() <= 1:
				continue
			for variant in variants:
				rows.append(variant)
	for row in passthrough:
		rows.append(row)
	return rows


## 折叠出来的卡行：字段与普通 entry 同形，另带 fold（层级数据）与
## fold_action（点击行为）。type_id 取自该层首选变体，所以点一下能直接建。
static func _fold_head_row(head: Dictionary, fold: Dictionary,
		action: Dictionary) -> Dictionary:
	# 折叠卡与它的变体可能共用同一个 building_id（卡面取首选变体），
	# 所以列表索引必须用独立的 row_key，否则卡与变体会互相覆盖。
	var kind := String(fold.get("kind", ""))
	var row_key := ""
	if kind == "rank_card":
		row_key = "##rank_%d" % int(fold.get("rank", 0))
	elif kind == "crop_option":
		row_key = "##crop_%d_%s" % [int(fold.get("rank", 0)), String(fold.get("crop", ""))]
	return {
		"row_key": row_key,
		"index": int(head.get("index", -1)),
		"type_id": int(head.get("type_id", -1)),
		"building_id": String(head.get("building_id", "")),
		"name": String(head.get("name", "")),
		"icon": head.get("icon", &"economy.building"),
		"eligible": bool(head.get("eligible", false)),
		"reason_code": String(head.get("reason_code", "")),
		"tech_locked": bool(head.get("tech_locked", false)),
		"cash_required": int(head.get("cash_required", 0)),
		"market_used": int(head.get("market_used", 0)),
		"score": int(head.get("score", 0)),
		"days": int(head.get("days", 0)),
		"maturity_rank": int(fold.get("rank", 0)),
		"fold": fold,
		"fold_action": action,
	}


## 每座每日「产出市值 − 投入市值」（本地市价、单位对齐 GOODS_SCALE）。
## 只是排序启发式，不写回任何模拟状态。
