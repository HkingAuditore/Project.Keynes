extends RefCounted

# Tax grouping for the business tax UI (T1 of the tax rework).
#
# Today the player sets one business tax rate per building: 449 rows. This module
# maps every building to a *tax group* so the panel can present far fewer rows
# while the underlying per-building rate vector and the native settlement tables
# stay exactly as they are. Nothing here changes storage, keys or settlement.
#
# Group identity is derived only from catalog columns that already exist:
#   building_type_ids             - dense building order (one entry per building)
#   building_economic_sectors     - dense index into BUILDING_SECTOR_IDS (6 entries,
#                                   `military` included; see economy_catalog.gd:51-57)
#   building_owner_profession_ids - owner profession per building
#   building_industry_chain_ids   - production chain id per building
#
# Do not index `building_economic_sectors` into `modifier_sector_ids`: that list
# is the five *civil* sectors (economy_catalog.gd:511-512) and `military` must
# never be read through it (BUILDING_CIVIL_SECTOR_COUNT documents that rule).

const SECTOR_IDS := [
	"agriculture", "extractive", "manufacturing", "energy", "knowledge",
	"military",
]

const MODE_SECTOR := "sector"
const MODE_SECTOR_OWNER := "sector_owner"
const MODE_CHAIN := "chain"
## 主粮农场单独成一组，其余建筑按部门兜底。判定与建造界面的折叠同源：
## 首个产出货的类别是 starchy_staple 就算主粮建筑。这样「一个滑条管全部农场」
## 才成立——sector 模式会把香料/药材/棉花/渔猎一起收进来（农业 104 座里只有
## 50 座是主粮），sector_owner 又会把它们按业主拆成四组（地主 29、自给农 14、
## 采集者 4、家户农 3），两边的档位还是错开的。
const MODE_STAPLE_CROP := "staple_crop"
## 档位轴：`maturity_rank` 是「生产方式档位」，不是时代。军械 17 座全部
## rank 0，落到「未入档」组而不是被丢掉——面板上少一组比少 17 座更危险。
const MODE_MATURITY_RANK := "maturity_rank"
## 产物轴：按首个产出货分组，与建造界面的折叠键同源（fold key = 首个产出货）。
## 多产出建筑（通用农场 grain|vegetables）归到它的第一件货。
const MODE_OUTPUT_GOOD := "output_good"

const MODES := [MODE_SECTOR, MODE_SECTOR_OWNER, MODE_CHAIN, MODE_STAPLE_CROP,
	MODE_MATURITY_RANK, MODE_OUTPUT_GOOD]

const STAPLE_GROUP_ID := "staple_crop_farm"
const STAPLE_GROUP_LABEL := "主粮农场"
const STAPLE_CATEGORY := "starchy_staple"

## 档位规范名：一条轴只该有一个名字。数据里 rank 4 同时出现「组织化生产/
## 规模化生产/组织化规模/专业生产」四种写法，rank 3 是 21:20 的两名平手——
## 所以这里写死规范名，不取建筑自带名，界面才不会冒出第 8 种叫法。
const RANK_LABELS := {
	0: "(未入档)",
	1: "自然获取",
	2: "家户试作",
	3: "专业工艺",
	4: "组织化生产",
	5: "机械化",
	6: "精准/数字化",
	7: "自动化",
}
const RANK_GROUP_PREFIX := "rank_"
const NO_OUTPUT_GROUP_ID := "no_output"
const NO_OUTPUT_GROUP_LABEL := "无产出"


## Build a grouping over the whole catalog.
##
## Returns:
##   ok                       - false with `reason` on malformed input
##   mode                     - the mode that was built
##   group_ids                - stable group ids, first-appearance order
##   group_labels             - human label per group (same order)
##   building_group_indices   - group index per building (same order as building_type_ids)
##   group_building_counts    - number of buildings per group
##   group_count              - group_ids.size()
##
## Ordering is first-appearance in catalog order, never sorted: a saved game and
## a fresh compile must produce the same index for the same group.
static func build(catalog: Dictionary, mode: String = MODE_SECTOR_OWNER) -> Dictionary:
	if not MODES.has(mode):
		return {"ok": false, "reason": "unknown_tax_group_mode: %s" % mode}
	var building_ids: PackedStringArray = catalog.get("building_type_ids", PackedStringArray())
	var sectors: PackedInt32Array = catalog.get("building_economic_sectors", PackedInt32Array())
	# Despite the `_ids` suffix this column stores profession *indices*; the
	# compiled column is built from `var owner_professions := PackedInt32Array()`
	# (economy_building_catalog_compile_steps.gd:185, published at :723). Accept
	# either shape so a future string column needs no second module.
	var owners := _profession_column(catalog.get("building_owner_profession_ids", null),
		catalog.get("profession_ids", PackedStringArray()))
	var chains: PackedStringArray = catalog.get("building_industry_chain_ids", PackedStringArray())
	var ranks: PackedInt32Array = catalog.get("building_maturity_ranks", PackedInt32Array())
	var count := building_ids.size()
	if count == 0:
		return {"ok": false, "reason": "tax_group_empty_catalog"}
	if sectors.size() != count:
		return {"ok": false, "reason": "tax_group_sector_column_mismatch"}
	var needs_owner := mode == MODE_SECTOR_OWNER
	if needs_owner and owners.size() != count:
		return {"ok": false, "reason": "tax_group_owner_column_mismatch"}
	if mode == MODE_CHAIN and chains.size() != count:
		return {"ok": false, "reason": "tax_group_chain_column_mismatch"}
	if mode == MODE_MATURITY_RANK and ranks.size() != count:
		return {"ok": false, "reason": "tax_group_maturity_column_mismatch"}
	if mode == MODE_OUTPUT_GOOD and not _output_columns_ok(catalog, count):
		return {"ok": false, "reason": "tax_group_output_column_mismatch"}
	var good_display_names: Dictionary = catalog.get("good_display_names", {})

	var group_ids := PackedStringArray()
	var group_labels := PackedStringArray()
	var group_index := {}
	var building_group_indices := PackedInt32Array()
	building_group_indices.resize(count)
	var counts := PackedInt32Array()
	var unassigned := 0

	for building in range(count):
		var sector_index := int(sectors[building])
		if sector_index < 0 or sector_index >= SECTOR_IDS.size():
			return {"ok": false, "reason": "tax_group_sector_index_out_of_range: %d" % sector_index,
				"building": String(building_ids[building])}
		var sector: String = SECTOR_IDS[sector_index]
		var owner := String(owners[building]) if owners.size() == count else ""
		var chain := String(chains[building]) if chains.size() == count else ""
		var group_id := ""
		var label := ""
		match mode:
			MODE_SECTOR:
				group_id = sector
				label = sector
			MODE_SECTOR_OWNER:
				var owner_label := owner if not owner.is_empty() else "(no_owner)"
				group_id = "%s|%s" % [sector, owner_label]
				label = "%s · %s" % [sector, owner_label]
			MODE_STAPLE_CROP:
				if _is_staple_building(building, catalog):
					group_id = STAPLE_GROUP_ID
					label = STAPLE_GROUP_LABEL
				else:
					group_id = sector
					label = sector
			MODE_MATURITY_RANK:
				var rank_value := int(ranks[building])
				group_id = "%s%d" % [RANK_GROUP_PREFIX, rank_value]
				label = String(RANK_LABELS.get(rank_value, "档位 %d" % rank_value))
			MODE_OUTPUT_GOOD:
				var good := _first_output_good(building, catalog)
				if good.is_empty():
					group_id = NO_OUTPUT_GROUP_ID
					label = NO_OUTPUT_GROUP_LABEL
				else:
					group_id = good
					label = String(good_display_names.get(good, good))
			_:
				group_id = chain
				label = chain
		if group_id.is_empty():
			# Total mapping on purpose: a building with no owner profession or no
			# chain must still land somewhere a panel can show, instead of
			# aborting the whole catalog compile.
			group_id = "unassigned"
			label = "unassigned"
			unassigned += 1
		var index := int(group_index.get(group_id, -1))
		if index < 0:
			index = group_ids.size()
			group_index[group_id] = index
			group_ids.append(group_id)
			group_labels.append(label)
			counts.append(0)
		building_group_indices[building] = index
		counts[index] += 1

	# 档位有天然顺序：按 rank 升序重排组，面板才从「自然获取」读到「自动化」。
	# 其余模式保持首次出现顺序（存档与重编译必须给出同一个组索引）。
	if mode == MODE_MATURITY_RANK:
		var ordered := _order_groups_by_rank(
			group_ids, group_labels, building_group_indices, counts)
		group_ids = ordered["group_ids"]
		group_labels = ordered["group_labels"]
		building_group_indices = ordered["building_group_indices"]
		counts = ordered["group_building_counts"]

	return {
		"ok": true,
		"mode": mode,
		"group_ids": group_ids,
		"group_labels": group_labels,
		"building_group_indices": building_group_indices,
		"group_building_counts": counts,
		"group_count": group_ids.size(),
		"building_count": count,
		"unassigned_buildings": unassigned,
	}


static func _order_groups_by_rank(group_ids: PackedStringArray, group_labels: PackedStringArray,
		building_group_indices: PackedInt32Array, counts: PackedInt32Array) -> Dictionary:
	var order: Array = []
	for index in range(group_ids.size()):
		order.append(index)
	order.sort_custom(func(a: int, b: int) -> bool:
		return _rank_of_group(String(group_ids[a])) < _rank_of_group(String(group_ids[b])))
	var remap := {}
	var new_ids := PackedStringArray()
	var new_labels := PackedStringArray()
	var new_counts := PackedInt32Array()
	for new_index in range(order.size()):
		var old_index: int = order[new_index]
		remap[old_index] = new_index
		new_ids.append(group_ids[old_index])
		new_labels.append(group_labels[old_index])
		new_counts.append(counts[old_index])
	var new_indices := PackedInt32Array()
	new_indices.resize(building_group_indices.size())
	for building in range(building_group_indices.size()):
		new_indices[building] = int(remap.get(int(building_group_indices[building]), -1))
	return {
		"group_ids": new_ids,
		"group_labels": new_labels,
		"building_group_indices": new_indices,
		"group_building_counts": new_counts,
	}


static func _rank_of_group(group_id: String) -> int:
	if not group_id.begins_with(RANK_GROUP_PREFIX):
		return 999
	return int(group_id.substr(RANK_GROUP_PREFIX.length()))


## 主粮判定：与建造界面的折叠同源——首个产出货的类别是 starchy_staple。
## catalog 若没带类别列，退回五个主粮货 id，判定结果完全一致。
static func _is_staple_building(building: int, catalog: Dictionary) -> bool:
	var good_index := _first_output_good_index(building, catalog)
	if good_index < 0:
		return false
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var categories: PackedStringArray = catalog.get(
		"good_category_ids", PackedStringArray())
	if good_index >= good_ids.size():
		return false
	if good_index < categories.size() and not String(categories[good_index]).is_empty():
		return String(categories[good_index]) == STAPLE_CATEGORY
	return String(good_ids[good_index]) in [
		"grain", "wheat_grain", "rice_grain", "corn_grain", "potatoes"]


## 产出列是否够用：offsets 是每座建筑的 CSR 前缀和，长度必须是建筑数 + 1。
static func _output_columns_ok(catalog: Dictionary, count: int) -> bool:
	var offsets: PackedInt32Array = catalog.get("building_output_offsets", PackedInt32Array())
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	return offsets.size() == count + 1 and not good_ids.is_empty()


## 首个产出货的 good id；没有产出（军械、服务）返回空串。
static func _first_output_good(building: int, catalog: Dictionary) -> String:
	var good_index := _first_output_good_index(building, catalog)
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	if good_index < 0 or good_index >= good_ids.size():
		return ""
	return String(good_ids[good_index])


static func _first_output_good_index(building: int, catalog: Dictionary) -> int:
	var offsets: PackedInt32Array = catalog.get("building_output_offsets", PackedInt32Array())
	var out_goods: PackedInt32Array = catalog.get("building_output_good_ids", PackedInt32Array())
	if building < 0 or building + 1 >= offsets.size():
		return -1
	var begin := int(offsets[building])
	var end := int(offsets[building + 1])
	if begin < 0 or end <= begin or begin >= out_goods.size():
		return -1
	return int(out_goods[begin])


## Normalise the owner-profession column to one profession id per building.
## Accepts a string column or the index column the shipping catalog publishes.
static func _profession_column(raw: Variant, profession_ids: PackedStringArray) -> PackedStringArray:
	if raw is PackedStringArray:
		return raw
	var out := PackedStringArray()
	if raw is PackedInt32Array:
		var indices: PackedInt32Array = raw
		out.resize(indices.size())
		for i in range(indices.size()):
			var index := int(indices[i])
			out[i] = String(profession_ids[index]) \
				if index >= 0 and index < profession_ids.size() else ""
	return out


## Building indices that belong to one group, in catalog order.
static func buildings_in_group(building_group_indices: PackedInt32Array,
		group: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for building in range(building_group_indices.size()):
		if int(building_group_indices[building]) == group:
			out.append(building)
	return out


## 任意主体的成员索引（建筑 / 物资 / 职业都是「索引数组 + 组号」同一形状）。
static func members_in_group(member_group_indices: PackedInt32Array,
		group: int) -> PackedInt32Array:
	return buildings_in_group(member_group_indices, group)
