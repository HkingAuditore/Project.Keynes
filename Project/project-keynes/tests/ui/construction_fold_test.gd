extends SceneTree

## 建造界面主粮折叠的分区性测试。
##
## 折叠是纯呈现，无头模拟根本不走 UI，所以 CSV 逐位比对证明不了它：
## 这个测试直接构造 catalog 列与 entry，验证「全折叠只出档位卡」和
## 「全展开后 50 座主粮不重不漏」。故意不依赖 EconomyFacade，只读 .tres。

const StapleGroups = preload("res://scripts/ui/cell_inspector/construction_staple_groups.gd")
const Construction = preload("res://scripts/ui/cell_inspector/construction.gd")
const TaxGroupMap = preload("res://scripts/country/tax_group_map.gd")
const BUILDING_DIR := "res://data/economy/buildings"
const GOOD_DIR := "res://data/goods"

var failures := 0


func _init() -> void:
	var goods := _scan_goods()
	var columns := _build_columns(goods)
	var entries := _build_entries(columns)
	var expected := _staple_type_ids(columns, entries)
	var ranks_col: PackedInt32Array = columns["building_maturity_ranks"]
	print("  catalog buildings=%d goods=%d" % [
		(columns["building_type_ids"] as PackedStringArray).size(), goods.size()])
	print("  staple buildings=%d, entries=%d" % [expected.size(), entries.size()])

	# A) 全折叠：只有档位卡，主粮变体一个都不出现在本页。
	var collapsed: Array = Construction.fold_staple_entries(entries, columns)
	var collapsed_cards := 0
	var collapsed_variants := 0
	for raw in collapsed:
		var row: Dictionary = raw
		if _is_rank_card(row):
			collapsed_cards += 1
		elif expected.has(int(row.get("type_id", -1))):
			collapsed_variants += 1
	print("  collapsed: cards=%d variants=%d rows=%d" % [
		collapsed_cards, collapsed_variants, collapsed.size()])
	_expect("collapsed shows only rank cards",
		collapsed_cards == 7 and collapsed_variants == 0)

	# B) 全展开：所有主粮变体逐个出现。
	var expanded_ranks := {}
	var expanded_crops := {}
	for tid: int in expected:
		var rank := int(ranks_col[tid])
		expanded_ranks[rank] = true
		var crop := Construction.staple_crop_key(tid, columns)
		expanded_crops["%d|%s" % [rank, crop]] = true
	var folded: Array = Construction.fold_staple_entries(
		entries, columns, expanded_ranks, expanded_crops)

	# 1) 变体集合恰好等于主粮建筑，不重不漏。
	# 单变体的作物不额外输出变体行（点一下直接建），所以从结构里收集。
	var seen := {}
	for raw in folded:
		var row: Dictionary = raw
		if not _is_rank_card(row):
			continue
		for crop_entry in _crops_of(row):
			for variant in ((crop_entry as Dictionary)["variants"] as Array):
				var tid := int((variant as Dictionary).get("type_id", -1))
				seen[tid] = int(seen.get(tid, 0)) + 1
	var missing := PackedStringArray()
	var duplicated := PackedInt32Array()
	for tid: int in expected:
		if not seen.has(tid):
			missing.append(str(tid))
		elif int(seen[tid]) > 1:
			duplicated.append(tid)
	var extra := PackedInt32Array()
	for tid: int in seen.keys():
		if not expected.has(tid):
			extra.append(tid)
	_expect("every staple building appears exactly once (%d)" % expected.size(),
		missing.is_empty() and duplicated.is_empty() and extra.is_empty()
		and seen.size() == expected.size())
	if not missing.is_empty():
		print("    missing=%s" % str(missing))
	if not duplicated.is_empty():
		print("    duplicated=%s" % str(duplicated))
	if not extra.is_empty():
		print("    extra=%s" % str(extra))

	# 2) 非主粮 entry 原样透传：数量与 type_id 顺序都不变。
	var expected_passthrough := PackedInt32Array()
	for raw in entries:
		var entry: Dictionary = raw
		if not expected.has(int(entry.get("type_id", -1))):
			expected_passthrough.append(int(entry.get("type_id", -1)))
	var actual_passthrough := PackedInt32Array()
	for raw in folded:
		var row: Dictionary = raw
		if row.has("fold"):
			continue
		if expected.has(int(row.get("type_id", -1))):
			continue
		actual_passthrough.append(int(row.get("type_id", -1)))
	_expect("non-staple rows pass through unchanged",
		actual_passthrough == expected_passthrough)

	# 3) 一级卡 = 一档一张，最多 7 张。
	var rank_cards := 0
	var ranks := {}
	for raw in folded:
		var row: Dictionary = raw
		if not _is_rank_card(row):
			continue
		rank_cards += 1
		ranks[int(row["fold"]["rank"])] = true
	print("  expanded: rank cards=%d ranks=%s" % [rank_cards, str(ranks.keys())])
	_expect("rank cards at most 7 and one per rank",
		rank_cards <= 7 and rank_cards == ranks.size())

	# 4) 二级键唯一，且作物顺序固定为 CROP_ORDER 的前缀。
	var seen_keys := {}
	var crop_total := 0
	var order_ok := true
	for raw in folded:
		var row: Dictionary = raw
		if not _is_rank_card(row):
			continue
		var last_index := -1
		for crop_entry in _crops_of(row):
			crop_total += 1
			var crop := String((crop_entry as Dictionary)["crop"])
			var key := "%d|%s" % [int(row["fold"]["rank"]), crop]
			if seen_keys.has(key):
				_expect("crop option unique: %s" % key, false)
			seen_keys[key] = true
			var order_index := StapleGroups.CROP_ORDER.find(crop)
			if order_index >= 0:
				if order_index <= last_index:
					order_ok = false
				last_index = order_index
	print("  expanded: crop options=%d" % crop_total)
	_expect("crop options follow CROP_ORDER", order_ok)

	# 5) rank 3 只有麦/稻/玉米/薯，没有混合谷物。
	var rank3_crops := PackedStringArray()
	for raw in folded:
		var row: Dictionary = raw
		if not _is_rank_card(row) or int(row["fold"]["rank"]) != 3:
			continue
		for crop_entry in _crops_of(row):
			rank3_crops.append(String((crop_entry as Dictionary)["crop"]))
	_expect("rank 3 has no generic grain option", not rank3_crops.has("grain"))
	print("  rank3 crops=%s" % str(rank3_crops))

	# 6) 每张卡都指向一个真实变体，点一下能直接建。
	var head_ok := true
	for raw in folded:
		var row: Dictionary = raw
		var action: Dictionary = row.get("fold_action", {}) if row.has("fold_action") else {}
		var ids := PackedInt32Array()
		if _is_rank_card(row):
			for crop_entry in _crops_of(row):
				for variant in ((crop_entry as Dictionary)["variants"] as Array):
					ids.append(int((variant as Dictionary).get("type_id", -1)))
		elif String(action.get("kind", "")) == "toggle_crop":
			for variant in ((row["fold"] as Dictionary)["variants"] as Array):
				ids.append(int((variant as Dictionary).get("type_id", -1)))
		else:
			continue
		if not ids.has(int(row.get("type_id", -1))):
			head_ok = false
			break
	_expect("folded row head type_id is one of its variants", head_ok)

	# 7) 作物选项内部变体按可建/score/cash/type_id 排序。
	var variants_ok := true
	for raw in folded:
		var row: Dictionary = raw
		for crop_entry in _crops_of(row):
			var variants: Array = (crop_entry as Dictionary)["variants"]
			for index in range(1, variants.size()):
				if not Construction.staple_variant_before(
						variants[index - 1] as Dictionary, variants[index] as Dictionary):
					variants_ok = false
					break
			if not variants_ok:
				break
		if not variants_ok:
			break
	_expect("variants sorted by eligibility, score, cash, type_id", variants_ok)

	# 9) 税分组不能和折叠判定漂移：staple_crop 的主粮组必须恰好是这 50 座。
	#    两边各自实现了一次「首个产出货是否 starchy_staple」，这条就是防它们分叉。
	var grouped: Dictionary = TaxGroupMap.build(columns, TaxGroupMap.MODE_STAPLE_CROP)
	_expect("tax staple group builds", bool(grouped.get("ok", false)))
	if bool(grouped.get("ok", false)):
		var group_ids: PackedStringArray = grouped.get("group_ids", PackedStringArray())
		var staple_group := group_ids.find(TaxGroupMap.STAPLE_GROUP_ID)
		_expect("tax staple group exists", staple_group >= 0)
		if staple_group >= 0:
			var indices: PackedInt32Array = grouped.get("building_group_indices", PackedInt32Array())
			var members: PackedInt32Array = TaxGroupMap.buildings_in_group(indices, staple_group)
			var expected_set := {}
			for tid: int in expected:
				expected_set[tid] = true
			var same_set := members.size() == expected.size()
			for member in members:
				if not expected_set.has(int(member)):
					same_set = false
					break
			print("  tax staple group size=%d, fold staple=%d" % [
				members.size(), expected.size()])
			_expect("tax staple group matches fold staple set", same_set)

	print("construction fold: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(1 if failures > 0 else 0)


func _is_rank_card(row: Dictionary) -> bool:
	if not row.has("fold"):
		return false
	return String((row["fold"] as Dictionary).get("kind", "")) == "rank_card"


func _crops_of(row: Dictionary) -> Array:
	if not _is_rank_card(row):
		return []
	return (row["fold"] as Dictionary).get("crops", [])


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _scan_goods() -> Dictionary:
	var out := {}
	var dir := DirAccess.open(GOOD_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.ends_with(".tres"):
			var good = load("%s/%s" % [GOOD_DIR, name])
			if good != null:
				out[String(good.id)] = String(good.category_id)
		name = dir.get_next()
	dir.list_dir_end()
	return out


func _build_columns(goods: Dictionary) -> Dictionary:
	var good_ids := PackedStringArray(goods.keys())
	good_ids.sort()
	var good_index := {}
	for index in good_ids.size():
		good_index[good_ids[index]] = index
	var categories := PackedStringArray()
	for good_id in good_ids:
		categories.append(String(goods[good_id]))

	var rows: Array = []
	var dir := DirAccess.open(BUILDING_DIR)
	if dir == null:
		return {}
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var profile = load("%s/%s" % [BUILDING_DIR, file_name])
			if profile != null and String(profile.id) != "":
				rows.append(profile)
		file_name = dir.get_next()
	dir.list_dir_end()
	rows.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))

	var sector_ids := [
		"agriculture", "extractive", "manufacturing", "energy", "knowledge", "military"]
	var type_ids := PackedStringArray()
	var ranks := PackedInt32Array()
	var offsets := PackedInt32Array()
	var out_goods := PackedInt32Array()
	var sectors := PackedInt32Array()
	for profile in rows:
		type_ids.append(String(profile.id))
		ranks.append(int(profile.maturity_rank))
		offsets.append(out_goods.size())
		sectors.append(maxi(0, sector_ids.find(String(profile.economic_sector_id))))
		for good_id in profile.output_good_ids:
			out_goods.append(int(good_index.get(String(good_id), -1)))
	offsets.append(out_goods.size())
	# 税分组只要求业主列长度匹配，这里给占位值即可——staple_crop 不按业主分组。
	var owners := PackedInt32Array()
	owners.resize(type_ids.size())
	owners.fill(0)
	return {
		"building_type_ids": type_ids,
		"building_maturity_ranks": ranks,
		"building_output_offsets": offsets,
		"building_output_good_ids": out_goods,
		"good_ids": good_ids,
		"good_category_ids": categories,
		"building_economic_sectors": sectors,
		"building_owner_profession_ids": owners,
		"profession_ids": PackedStringArray(["placeholder"]),
	}


func _build_entries(columns: Dictionary) -> Array:
	var type_ids: PackedStringArray = columns["building_type_ids"]
	var ranks: PackedInt32Array = columns["building_maturity_ranks"]
	var entries: Array = []
	for type_id in type_ids.size():
		entries.append({
			"index": type_id,
			"type_id": type_id,
			"building_id": type_ids[type_id],
			"name": type_ids[type_id],
			"icon": &"economy.building",
			"eligible": type_id % 3 != 0,
			"reason_code": "" if type_id % 3 != 0 else "construction_treasury_cash_insufficient",
			"tech_locked": false,
			"cash_required": (type_ids.size() - type_id) * 1000,
			"market_used": 0,
			"score": (type_id * 37) % 1000,
			"days": 10,
			"maturity_rank": ranks[type_id],
		})
	return entries


func _staple_type_ids(columns: Dictionary, entries: Array) -> PackedInt32Array:
	var expected := PackedInt32Array()
	for raw in entries:
		var entry: Dictionary = raw
		var key := Construction.staple_crop_key(int(entry.get("type_id", -1)), columns)
		if key != "":
			expected.append(int(entry.get("type_id", -1)))
	return expected
