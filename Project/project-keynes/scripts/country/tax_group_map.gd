extends RefCounted

## Common lookup surface for business-tax groupings and tax panel axes.

const BuildingGroups = preload("res://scripts/country/tax_building_groups.gd")

const SECTOR_IDS = BuildingGroups.SECTOR_IDS
const MODE_SECTOR = BuildingGroups.MODE_SECTOR
const MODE_SECTOR_OWNER = BuildingGroups.MODE_SECTOR_OWNER
const MODE_CHAIN = BuildingGroups.MODE_CHAIN
const MODE_STAPLE_CROP = BuildingGroups.MODE_STAPLE_CROP
const MODE_MATURITY_RANK = BuildingGroups.MODE_MATURITY_RANK
const MODE_OUTPUT_GOOD = BuildingGroups.MODE_OUTPUT_GOOD
const MODES = BuildingGroups.MODES
const STAPLE_GROUP_ID = BuildingGroups.STAPLE_GROUP_ID
const STAPLE_GROUP_LABEL = BuildingGroups.STAPLE_GROUP_LABEL
const STAPLE_CATEGORY = BuildingGroups.STAPLE_CATEGORY
const RANK_LABELS = BuildingGroups.RANK_LABELS
const RANK_GROUP_PREFIX = BuildingGroups.RANK_GROUP_PREFIX
const NO_OUTPUT_GROUP_ID = BuildingGroups.NO_OUTPUT_GROUP_ID
const NO_OUTPUT_GROUP_LABEL = BuildingGroups.NO_OUTPUT_GROUP_LABEL


static func build(catalog: Dictionary, mode: String = MODE_SECTOR_OWNER) -> Dictionary:
	return BuildingGroups.build(catalog, mode)


static func buildings_in_group(building_group_indices: PackedInt32Array,
		group: int) -> PackedInt32Array:
	return BuildingGroups.buildings_in_group(building_group_indices, group)


static func members_in_group(member_group_indices: PackedInt32Array,
		group: int) -> PackedInt32Array:
	return BuildingGroups.members_in_group(member_group_indices, group)


static func _output_columns_ok(catalog: Dictionary, count: int) -> bool:
	return BuildingGroups._output_columns_ok(catalog, count)


static func _first_output_good(building: int, catalog: Dictionary) -> String:
	return BuildingGroups._first_output_good(building, catalog)


# ---------------------------------------------------------------------------
# 面板分组轴：时代 / 产品线 / 产物 / 产业 / 生产档位 / 物资三层 / 职业阶层
#
# 与上面 build() 的分工：build() 是「建筑整组改税率」那四种老轴，语义与顺序一个
# 字节不动；这里是新面板用的轴，建筑 / 物资 / 职业三种主体共用一套出口。
# 所有值都从编译产物的现成列里读（economy_facade_display.gd 的
# construction_type_columns 只透传，不在这里造数据）。
# ---------------------------------------------------------------------------

const SUBJECT_BUILDING := "building"
const SUBJECT_GOOD := "good"
const SUBJECT_PROFESSION := "profession"

## 时代阶梯：与 data/technology/technology_network.json 的 eras[].sort_order
## 0..10 同序（country_facade.gd:8 的里程碑索引也按这个顺序）。只用于比较
## 「谁更晚」，不参与任何结算。
const ERA_ORDER := ["stone", "agrarian", "kingdom", "empire", "exploration",
	"enlightenment", "steam", "electrical", "atomic", "information", "intelligent"]
const ERA_LABELS := {
	"stone": "石器时代", "agrarian": "农耕时代", "kingdom": "王国时代",
	"empire": "帝国时代", "exploration": "探索时代", "enlightenment": "启蒙时代",
	"steam": "蒸汽时代", "electrical": "电气时代", "atomic": "原子时代",
	"information": "信息时代", "intelligent": "智能时代",
}
## 24 条产品线 + 4 条 backbone：technology_layout_lanes 里的原样取值。
const FAMILY_LABELS := {
	"branch.maize_horticulture": "玉米与园圃农业",
	"branch.wheat_rainfed": "小麦、谷物与雨养农业",
	"branch.rice_irrigation": "水稻、水田与灌溉农业",
	"branch.tuber_highland": "块茎、梯田与高地农业",
	"branch.pastoral_livestock": "草原、马匹与畜牧业",
	"branch.tropical_commodities": "热带作物与商品农业",
	"branch.forest_biomass": "森林、木材、造纸与生物质",
	"branch.maritime_logistics": "渔业、航海、港口与海运物流",
	"branch.textile_fibers": "纤维、纺织、服装与合成纤维",
	"branch.construction_materials": "黏土、石材、玻璃、建筑与公共工程",
	"branch.nonferrous_metals": "铜、锡、有色金属与特种合金",
	"branch.heavy_industry": "铁、煤、矿井、蒸汽与重工业",
	"branch.industrial_chemistry": "盐、硫、肥料、炸药与工业化学",
	"branch.petroleum_materials": "石油、内燃机、石化与合成材料",
	"branch.water_wind": "水力、风力、水务与流域工程",
	"branch.electric_intelligent_energy": "电力、核能、电网与智能能源",
	"branch.land_institutions": "土地产权、租佃与乡村制度",
	"branch.commerce_finance": "商业、金融、会计与公司组织",
	"branch.labor_management": "劳工、管理与生产组织",
	"branch.measurement_instruments": "测量、标准化与精密仪器",
	"branch.natural_history": "自然史、生物学与育种科学",
	"branch.public_health": "医学、卫生与公共健康",
	"branch.geoscience_gis": "制图、地学、遥感与空间分析",
	"branch.computation_control": "计算、控制、网络与机器智能",
	"backbone.food_storage": "食物、保存与公共储备",
	"backbone.tools_machinery": "工具、机械与自动控制",
	"backbone.knowledge_computation": "观察、科学与计算",
	"backbone.institutions_exchange": "制度、交换与组织",
}
const SECTOR_LABELS := {
	"agriculture": "农业", "extractive": "采掘", "manufacturing": "制造",
	"energy": "能源", "knowledge": "知识", "military": "军事",
	"commerce": "商业与贸易", "unemployed": "未就业",
}
const PROFESSION_CLASS_LABELS := {
	"farmer": "农民", "worker": "工人", "technology": "技术与学者",
	"military": "军事", "owner": "商业与业主", "unemployed": "未就业",
	"general": "其他",
}
## 商业与流通职业（如商人兼任矿场业主时，不能因矿场数量多而被归入采掘业）。
const COMMERCE_PROFESSION_IDS := {
	"merchant": true, "ship_officer": true, "transport_worker": true,
}
const OWNER_PROFESSION_IDS := {
	"merchant": true, "landlord": true, "industrialist": true,
	"guild_master": true, "manager": true, "ship_officer": true,
}
const LAYER_RAW := "raw"
const LAYER_INTERMEDIATE := "intermediate"
const LAYER_FINISHED := "finished"
const LAYER_LABELS := {
	"raw": "原材料", "intermediate": "中间品", "finished": "制成品",
}
const UNCLASSIFIED_ID := "unclassified"
const UNCLASSIFIED_LABEL := "未分类"
const NO_OUTPUT_GROUP := "no_output"

## 组名一律中文，而且名字出自数据作者：technology_network.json 的 eras[]、
## branch_families[]、backbones[] 每一项都带 display_name。这里先问
## TechnologyCatalog 的公开元数据（country_view_model.gd:136 用的是同一条路，
## 不是给税收界面新开一条加载路径），只在数据拿不到某个键时才退回上面的常量镜像。
## 镜像与数据是否逐字一致由探针核对——两侧都不自己编名字。
const TechnologyCatalogScript := preload(
	"res://scripts/economy/technology_catalog.gd")
static var _era_labels_cache: Dictionary = {}
static var _family_labels_cache: Dictionary = {}


## 时代 id → 中文名。eras[] 是完整数据（11/11 带 display_name）。
static func era_label_map() -> Dictionary:
	if not _era_labels_cache.is_empty():
		return _era_labels_cache
	var out := {}
	for row_value in TechnologyCatalogScript.public_era_metadata():
		var row: Dictionary = row_value
		var id := String(row.get("id", ""))
		var name := String(row.get("display_name", ""))
		if not id.is_empty() and not name.is_empty():
			out[id] = name
	for era_id in ERA_LABELS.keys():
		if not out.has(String(era_id)):
			out[String(era_id)] = String(ERA_LABELS[era_id])
	_era_labels_cache = out
	return out


## 产品线 id → 中文名：24 条 branch.* + 4 条 backbone.* 全带 display_name。
static func family_label_map() -> Dictionary:
	if not _family_labels_cache.is_empty():
		return _family_labels_cache
	var out := {}
	for row_value in TechnologyCatalogScript.public_lane_metadata():
		var row: Dictionary = row_value
		var id := String(row.get("id", ""))
		var name := String(row.get("display_name", ""))
		if not id.is_empty() and not name.is_empty():
			out[id] = name
	for family_id in FAMILY_LABELS.keys():
		if not out.has(String(family_id)):
			out[String(family_id)] = String(FAMILY_LABELS[family_id])
	_family_labels_cache = out
	return out


## 生产档位：RANK_LABELS 的键是 int，组 id 是 "rank_N"，这里把两张表接上。
## 不接的话组名会退化成 "rank_4" 这种裸 id（探针实测 8/8 全裸）。
static func _rank_label_map() -> Dictionary:
	var out := {}
	for rank_value in RANK_LABELS.keys():
		out["%s%d" % [RANK_GROUP_PREFIX, int(rank_value)]] = String(
			RANK_LABELS[rank_value])
	return out


## 轴 id：与 build_axis 的 axis 参数同值。
const AXIS_ERA := "era"
const AXIS_OUTPUT_GOOD := "output_good"
const AXIS_BRANCH_FAMILY := "branch_family"
const AXIS_SECTOR := "sector"
const AXIS_MATURITY_RANK := "maturity_rank"
const AXIS_LAYER := "layer"
const AXIS_PROFESSION_CLASS := "profession_class"

## 面板轴的展示清单：总面板（economy_workspace.gd 的 _tax_group_axes_for_page）
## 与地方面板/对象详情（inspector_tax_groups.gd 的 tax_group_axes）都从这里取，
## 轴、顺序、文案只有这一份——两处各写一份正是这次要消灭的毛病。
const SUBJECT_AXES := {
	SUBJECT_BUILDING: [
		{"id": AXIS_ERA, "label": "按时代",
			"hint": "按解锁所需最晚的那条技术所在的时代分组"},
		{"id": AXIS_OUTPUT_GOOD, "label": "按产物",
			"hint": "产出同一件货的全国建筑；没有产出的单列一组"},
		{"id": AXIS_BRANCH_FAMILY, "label": "按产品线",
			"hint": "按技术所属的产品线（24 条 branch + 4 条 backbone）"},
		{"id": AXIS_SECTOR, "label": "按产业",
			"hint": "农业/采掘/制造/能源/知识/军事"},
		{"id": AXIS_MATURITY_RANK, "label": "按生产档位",
			"hint": "同一生产方式档位的全国建筑"},
	],
	SUBJECT_GOOD: [
		{"id": AXIS_LAYER, "label": "按产品性质",
			"hint": "原材料 / 中间品 / 制成品"},
		{"id": AXIS_ERA, "label": "按时代",
			"hint": "这种货最早能造出来的时代"},
		{"id": AXIS_BRANCH_FAMILY, "label": "按产品线",
			"hint": "按生产它的建筑所属产品线"},
		{"id": AXIS_SECTOR, "label": "按产业",
			"hint": "按生产它的建筑所属产业"},
	],
	SUBJECT_PROFESSION: [
		{"id": AXIS_PROFESSION_CLASS, "label": "按阶层",
			"hint": "农民 / 工人 / 技术 / 军事；缺字段的归未分类"},
		{"id": AXIS_SECTOR, "label": "按产业",
			"hint": "按雇主建筑的主导产业"},
	],
}


## 某一主体的轴清单（复制一份，调用方随便改都不会污染常量表）。
static func axes_for_subject(subject: String) -> Array:
	var axes: Array = SUBJECT_AXES.get(subject, [])
	return axes.duplicate(true)


## 统一出口：`axis` ＋ `subject` 决定用哪一列。
## 返回 {ok, subject, axis, group_ids, group_labels, member_group_indices,
##       group_counts, group_count}；member_group_indices 是每个成员的组号。
static func build_axis(catalog: Dictionary, axis: String,
		subject: String = SUBJECT_BUILDING) -> Dictionary:
	match subject:
		SUBJECT_BUILDING:
			return _building_axis(catalog, axis)
		SUBJECT_GOOD:
			return _good_axis(catalog, axis)
		SUBJECT_PROFESSION:
			return _profession_axis(catalog, axis)
	return {"ok": false, "reason": "unknown_tax_axis_subject: %s" % subject}


## 把「每个成员的组键」压成组表。空键统一落「未分类」，不丢成员。
static func _group_from_keys(subject: String, axis: String,
		member_ids: PackedStringArray, member_keys: PackedStringArray,
		label_map: Dictionary) -> Dictionary:
	var group_ids := PackedStringArray()
	var group_labels := PackedStringArray()
	var by_key := {}
	var indices := PackedInt32Array()
	indices.resize(member_ids.size())
	var counts := PackedInt32Array()
	for i in range(member_ids.size()):
		var key := String(member_keys[i]) if i < member_keys.size() else ""
		if key.is_empty():
			key = UNCLASSIFIED_ID
		var group := int(by_key.get(key, -1))
		if group < 0:
			group = group_ids.size()
			by_key[key] = group
			group_ids.append(key)
			var label := String(label_map.get(key, ""))
			if label.is_empty():
				label = UNCLASSIFIED_LABEL if key == UNCLASSIFIED_ID else key
			group_labels.append(label)
			counts.append(0)
		indices[i] = group
		counts[group] = counts[group] + 1
	if group_ids.is_empty():
		return {"ok": false, "reason": "tax_axis_empty_catalog"}
	return {"ok": true, "subject": subject, "axis": axis,
		"group_ids": group_ids, "group_labels": group_labels,
		"member_group_indices": indices, "group_counts": counts,
		"group_count": group_ids.size()}


## 技术节点表：tech_id → {era, family}。技术目录已由 economy 编译产物合并进来，
## 这里只做一次索引，不重新加载 technology_network.json。
static func _tech_table(catalog: Dictionary) -> Dictionary:
	var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
	var eras: PackedStringArray = catalog.get("technology_era_ids", PackedStringArray())
	var lanes: PackedStringArray = catalog.get(
		"technology_layout_lanes", PackedStringArray())
	var table := {}
	for i in range(ids.size()):
		table[String(ids[i])] = {
			"era": String(eras[i]) if i < eras.size() else "",
			"family": String(lanes[i]) if i < lanes.size() else "",
		}
	return table


## 一座建筑的 technology_tags 切片（CSR：offsets 长度 = 建筑数 + 1）。
static func _building_tech_tags(catalog: Dictionary, building: int) -> PackedStringArray:
	var offsets: PackedInt32Array = catalog.get(
		"building_technology_tag_offsets", PackedInt32Array())
	var tags: PackedStringArray = catalog.get(
		"building_technology_tags", PackedStringArray())
	var out := PackedStringArray()
	if building < 0 or building + 1 >= offsets.size():
		return out
	var begin := maxi(int(offsets[building]), 0)
	var end := mini(int(offsets[building + 1]), tags.size())
	for i in range(begin, end):
		out.append(String(tags[i]))
	return out


static func _era_rank(era_id: String) -> int:
	return ERA_ORDER.find(era_id)


## 建筑的时代 = 它所有技术里「最晚」的那一档。
## 依据：建筑要等最晚的那条前置技术才解锁。拿产物作者在
## application_intersections 里标注的 293 座对照，这条规则命中 291 座（99%）；
## 取「最早」只命中 34 座（12%）。
static func _building_era(catalog: Dictionary, building: int,
		table: Dictionary) -> String:
	var best := -1
	for tag in _building_tech_tags(catalog, building):
		var entry: Dictionary = table.get(String(tag), {})
		var rank := _era_rank(String(entry.get("era", "")))
		if rank > best:
			best = rank
	return ERA_ORDER[best] if best >= 0 else ""


## 建筑的产品线 = 技术标签里出现最多的那条 lane（平票取先出现）。
static func _building_family(catalog: Dictionary, building: int,
		table: Dictionary) -> String:
	var counts := {}
	var order := PackedStringArray()
	for tag in _building_tech_tags(catalog, building):
		var entry: Dictionary = table.get(String(tag), {})
		var family := String(entry.get("family", ""))
		if family.is_empty():
			continue
		if not counts.has(family):
			counts[family] = 0
			order.append(family)
		counts[family] = int(counts[family]) + 1
	var best := ""
	var best_count := 0
	for family in order:
		var count := int(counts[family])
		if count > best_count:
			best = family
			best_count = count
	return best


static func _building_axis(catalog: Dictionary, axis: String) -> Dictionary:
	var ids: PackedStringArray = catalog.get("building_type_ids", PackedStringArray())
	if ids.is_empty():
		return {"ok": false, "reason": "tax_axis_empty_catalog"}
	var count := ids.size()
	var keys := PackedStringArray()
	keys.resize(count)
	var labels: Dictionary = {}
	var table := {}
	if axis == "era" or axis == "branch_family":
		table = _tech_table(catalog)
		labels = era_label_map() if axis == "era" else family_label_map()
		if table.is_empty():
			return {"ok": false, "reason": "tax_axis_technology_columns_missing"}
	elif axis == "sector":
		labels = SECTOR_LABELS
	elif axis == "output_good":
		labels = (catalog.get("good_display_names", {}) as Dictionary).duplicate()
		# 没有产出的建筑不能落进「未分类」——它不是分类缺失，是确实不产出，
		# 得给它自己的中文组名（老轴 MODE_OUTPUT_GOOD 就叫「无产出」）。
		labels[NO_OUTPUT_GROUP] = NO_OUTPUT_GROUP_LABEL
	elif axis == "maturity_rank":
		labels = _rank_label_map()
	else:
		return {"ok": false, "reason": "unknown_tax_axis: %s" % axis}
	var sectors: PackedInt32Array = catalog.get(
		"building_economic_sectors", PackedInt32Array())
	var ranks: PackedInt32Array = catalog.get(
		"building_maturity_ranks", PackedInt32Array())
	if axis == "sector" and sectors.size() != count:
		return {"ok": false, "reason": "tax_axis_sector_column_mismatch"}
	if axis == "maturity_rank" and ranks.size() != count:
		return {"ok": false, "reason": "tax_axis_maturity_column_mismatch"}
	if axis == "output_good" and not _output_columns_ok(catalog, count):
		return {"ok": false, "reason": "tax_axis_output_column_mismatch"}
	for building in range(count):
		match axis:
			"era":
				keys[building] = _building_era(catalog, building, table)
			"branch_family":
				keys[building] = _building_family(catalog, building, table)
			"sector":
				var sector_index := int(sectors[building])
				keys[building] = SECTOR_IDS[sector_index] \
					if sector_index >= 0 and sector_index < SECTOR_IDS.size() else ""
			"output_good":
				var first_good := _first_output_good(building, catalog)
				keys[building] = first_good if not first_good.is_empty() \
					else NO_OUTPUT_GROUP
			"maturity_rank":
				keys[building] = "rank_%d" % int(ranks[building])
	return _group_from_keys(SUBJECT_BUILDING, axis, ids, keys, labels)


## 物资 → 生产者建筑（good_index → PackedInt32Array）。
static func _good_producer_map(catalog: Dictionary) -> Dictionary:
	var offsets: PackedInt32Array = catalog.get(
		"building_output_offsets", PackedInt32Array())
	var goods: PackedInt32Array = catalog.get(
		"building_output_good_ids", PackedInt32Array())
	var out := {}
	for building in range(maxi(offsets.size() - 1, 0)):
		var begin := maxi(int(offsets[building]), 0)
		var end := mini(int(offsets[building + 1]), goods.size())
		for i in range(begin, end):
			var good := int(goods[i])
			var list: PackedInt32Array = out.get(good, PackedInt32Array())
			list.append(building)
			out[good] = list
	return out


## 被至少一座建筑当投入的货（good_index → true）。
static func _good_consumer_set(catalog: Dictionary) -> Dictionary:
	var offsets: PackedInt32Array = catalog.get(
		"building_input_offsets", PackedInt32Array())
	var goods: PackedInt32Array = catalog.get(
		"building_input_good_ids", PackedInt32Array())
	var out := {}
	for building in range(maxi(offsets.size() - 1, 0)):
		var begin := maxi(int(offsets[building]), 0)
		var end := mini(int(offsets[building + 1]), goods.size())
		for i in range(begin, end):
			out[int(goods[i])] = true
	return out


## 物资三层：主导产出产业是采掘/农业且被当投入 → 原材料；被当投入 → 中间品；
## 不被任何建筑当投入 → 制成品。依据：采掘建筑也有 tools 投入，所以「无投入」
## 不能当原材料判据；171 种货全部有生产建筑，这三种桶覆盖 171/171。
static func _good_layer(catalog: Dictionary, good: int,
		producers: Dictionary, consumers: Dictionary,
		sectors: PackedInt32Array) -> String:
	var list: PackedInt32Array = producers.get(good, PackedInt32Array())
	var counts := {}
	var order := PackedInt32Array()
	for building in list:
		var sector := int(sectors[building]) if building < sectors.size() else -1
		if not counts.has(sector):
			counts[sector] = 0
			order.append(sector)
		counts[sector] = int(counts[sector]) + 1
	var top := -1
	var top_count := 0
	for sector in order:
		var count := int(counts[sector])
		if count > top_count:
			top = sector
			top_count = count
	var top_id := String(SECTOR_IDS[top]) if top >= 0 and top < SECTOR_IDS.size() else ""
	if not bool(consumers.get(good, false)):
		return LAYER_FINISHED
	if top_id == "extractive" or top_id == "agriculture":
		return LAYER_RAW
	return LAYER_INTERMEDIATE


static func _good_axis(catalog: Dictionary, axis: String) -> Dictionary:
	var ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	if ids.is_empty():
		return {"ok": false, "reason": "tax_axis_empty_catalog"}
	var sectors: PackedInt32Array = catalog.get(
		"building_economic_sectors", PackedInt32Array())
	var producers := _good_producer_map(catalog)
	var table := {}
	var labels: Dictionary = {}
	if axis == "era" or axis == "branch_family":
		table = _tech_table(catalog)
		labels = era_label_map() if axis == "era" else family_label_map()
	elif axis == "layer":
		labels = LAYER_LABELS
	elif axis == "sector":
		labels = SECTOR_LABELS
	else:
		return {"ok": false, "reason": "unknown_tax_good_axis: %s" % axis}
	var consumers := _good_consumer_set(catalog) if axis == "layer" else {}
	var keys := PackedStringArray()
	keys.resize(ids.size())
	for good in range(ids.size()):
		var list: PackedInt32Array = producers.get(good, PackedInt32Array())
		match axis:
			"layer":
				keys[good] = _good_layer(catalog, good, producers, consumers, sectors)
			"era":
				# 物资「最早能造出来」的那一档：只要有任意一座生产建筑先出现，
				# 这种货就存在了，所以取最早，而不是最晚。
				var best := -1
				for building in list:
					var rank := _era_rank(_building_era(catalog, building, table))
					if rank >= 0 and (best < 0 or rank < best):
						best = rank
				keys[good] = ERA_ORDER[best] if best >= 0 else ""
			"branch_family":
				keys[good] = _majority_from_buildings(catalog, list, table, "family")
			"sector":
				keys[good] = _majority_sector(list, sectors)
	return _group_from_keys(SUBJECT_GOOD, axis, ids, keys, labels)


## 物资 / 职业共用：从一组建筑里取出现最多的 lane 或产业。
static func _majority_from_buildings(catalog: Dictionary,
		buildings: PackedInt32Array, table: Dictionary, field: String) -> String:
	var counts := {}
	var order := PackedStringArray()
	for building in buildings:
		var value := ""
		if field == "family":
			value = _building_family(catalog, building, table)
		if value.is_empty():
			continue
		if not counts.has(value):
			counts[value] = 0
			order.append(value)
		counts[value] = int(counts[value]) + 1
	var best := ""
	var best_count := 0
	for value in order:
		var count := int(counts[value])
		if count > best_count:
			best = value
			best_count = count
	return best


static func _majority_sector(buildings: PackedInt32Array,
		sectors: PackedInt32Array) -> String:
	var counts := {}
	var order := PackedInt32Array()
	for building in buildings:
		if building < 0 or building >= sectors.size():
			continue
		var sector := int(sectors[building])
		if not counts.has(sector):
			counts[sector] = 0
			order.append(sector)
		counts[sector] = int(counts[sector]) + 1
	var best := -1
	var best_count := 0
	for sector in order:
		var count := int(counts[sector])
		if count > best_count:
			best = sector
			best_count = count
	return String(SECTOR_IDS[best]) if best >= 0 and best < SECTOR_IDS.size() else ""


## 职业的产业：谁雇它。业主 + 雇员职业列里的职业，取雇主建筑的主导产业。
static func _profession_employers(catalog: Dictionary) -> Dictionary:
	var owners: PackedInt32Array = catalog.get(
		"building_owner_profession_ids", PackedInt32Array())
	var emp_offsets: PackedInt32Array = catalog.get(
		"building_employee_offsets", PackedInt32Array())
	var emp_ids: PackedInt32Array = catalog.get(
		"building_employee_profession_ids", PackedInt32Array())
	var count := maxi(owners.size(), maxi(emp_offsets.size() - 1, 0))
	var out := {}
	for building in range(count):
		if building < owners.size():
			var owner := int(owners[building])
			if owner >= 0:
				var owned: PackedInt32Array = out.get(owner, PackedInt32Array())
				owned.append(building)
				out[owner] = owned
		if building + 1 < emp_offsets.size():
			var begin := maxi(int(emp_offsets[building]), 0)
			var end := mini(int(emp_offsets[building + 1]), emp_ids.size())
			for i in range(begin, end):
				var employee := int(emp_ids[i])
				if employee < 0:
					continue
				var held: PackedInt32Array = out.get(employee, PackedInt32Array())
				held.append(building)
				out[employee] = held
	return out


static func _profession_axis(catalog: Dictionary, axis: String) -> Dictionary:
	var ids: PackedStringArray = catalog.get("profession_ids", PackedStringArray())
	if ids.is_empty():
		return {"ok": false, "reason": "tax_axis_profession_column_missing"}
	var keys := PackedStringArray()
	keys.resize(ids.size())
	match axis:
		"profession_class":
			var classes: PackedStringArray = catalog.get(
				"profession_class_ids", PackedStringArray())
			if classes.size() != ids.size():
				return {"ok": false, "reason": "tax_axis_profession_class_mismatch"}
			for i in range(ids.size()):
				var pid := String(ids[i])
				var cls := String(classes[i])
				if pid == "unemployed":
					keys[i] = "unemployed"
				elif (cls.is_empty() or cls == "general") and OWNER_PROFESSION_IDS.has(pid):
					keys[i] = "owner"
				else:
					keys[i] = cls
			return _group_from_keys(SUBJECT_PROFESSION, axis, ids, keys,
				PROFESSION_CLASS_LABELS)
		"sector":
			var sectors: PackedInt32Array = catalog.get(
				"building_economic_sectors", PackedInt32Array())
			var employers := _profession_employers(catalog)
			for i in range(ids.size()):
				var pid := String(ids[i])
				if pid == "unemployed":
					keys[i] = "unemployed"
				elif COMMERCE_PROFESSION_IDS.has(pid):
					keys[i] = "commerce"
				else:
					keys[i] = _majority_sector(
						employers.get(i, PackedInt32Array()), sectors)
			return _group_from_keys(SUBJECT_PROFESSION, axis, ids, keys,
				SECTOR_LABELS)
	return {"ok": false, "reason": "unknown_tax_profession_axis: %s" % axis}
