extends RefCounted

const RowPresentation = preload("res://scripts/ui/cell_inspector/construction_row_presentation.gd")

const MilitaryRows = preload("res://scripts/ui/cell_inspector/construction_military_rows.gd")

const StapleGroups = preload("res://scripts/ui/cell_inspector/construction_staple_groups.gd")
const ConstructionTooltip = preload("res://scripts/ui/cell_inspector/construction_tooltip.gd")

const Recipes = preload("res://scripts/ui/cell_inspector/construction_recipes.gd")


const ObjectDossiers = preload("res://scripts/ui/cell_inspector/object_dossiers.gd")

## 原生金额单位是 1/10000 货币；只有视图层才把它换算成金币读数。
const MONEY_SCALE = 10000.0


## 营造窗口一页的建筑条目数。一页 = 16 条同时报价：够填满视口，又让
## 「打开 / 切部门 / 翻页 / 每日刷新」的原生报价调用保持在毫秒级。
const CONSTRUCTION_PAGE_SIZE = 16
## Building kinds are compiled to dense ints; 3 == state-owned (barracks /
## fortification / war college). The dedicated military department lists them
## from MilitaryCatalog's `state_buildings` and quotes their economy type IDs.
const STATE_BUILDING_KIND = 3
## 军事部门不是经济目录里的部门：条目来自 MilitaryCatalog 的 `state_buildings`，
## 命令走军事运行时的 `state.build`，与经济侧的 `construction.build` 是两条通道
## （见 docs/ui/military-cell-tab.md §2.1）。这个 id 故意不并入 economy 的
## sector 表，避免被 `construction_candidates` 当成经济部门下标。
const CONSTRUCTION_MILITARY_SECTOR = "military"
## 军事页的三行官营建筑，顺序即行序；`role` 对齐 MilitaryStateRole (military_core.h)。
const STATE_BUILDING_ROLES: Array[Dictionary] = [
	{"id": "barracks", "label": "兵营", "role": 0},
	{"id": "fortification", "label": "城防", "role": 1},
	{"id": "war_college", "label": "军校", "role": 2},
]
const CONSTRUCTION_SECTOR_LABELS = {
	"agriculture": "农业",
	"extractive": "采掘",
	"manufacturing": "制造",
	"energy": "能源",
	"knowledge": "知识",
	"military": "军事",
}
const CONSTRUCTION_SECTOR_ICONS = {
	"agriculture": &"economy.building.farm",
	"extractive": &"economy.building.mine",
	"manufacturing": &"economy.building.factory",
	"energy": &"economy.building.power",
	"knowledge": &"economy.building.science",
	"military": &"military.building.barracks",
}
## 营造目录的排序档。三档都遵守「可建优先」，档位只决定可建项之间的次序。
const CONSTRUCTION_SORT_IDS = ["recommended", "cost", "newest"]
## 原生报价的拒绝码 → 玩家可读的短因由（行内标签用，长解释在 hover 里）。
const CONSTRUCTION_REASON_TEXT = {
	"construction_cell_not_owned": "非本国领土",
	"construction_technology_locked": "科技未解锁",
	"construction_obsolete": "已被高阶取代",
	"construction_conditions_failed": "地块不符",
	"construction_resource_unavailable": "自然资源不足",
	"construction_materials_insufficient": "建材不足",
	"construction_market_short": "市场缺货",
	"construction_treasury_cash_insufficient": "资金不足",
	"construction_market_unavailable": "市场不可结算",
	"construction_owner_signature_unavailable": "无合适业主",
	"construction_target_invalid": "目标无效",
}

func _building_category(host, snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	return ObjectDossiers._building_category(host, snapshot, cell_idx)


## 建筑页签里的「营造新建筑」纸笺。只统计目录规模，**不报价**：这张纸笺会随
## 建筑页签的每日 live patch 重建，报价必须留给真正打开窗口的那一次。

## Capability is published by Country and copied into cell_summary. UI treats
## the value as a read-only hint only; PlayerController and Economy apply the
## same gate again at their command boundaries.
static func country_allows_treasury_construction(summary: Dictionary) -> bool:
	var politics: Variant = summary.get("politics", {})
	if politics is Dictionary:
		if politics.has("can_treasury_construction"):
			return bool(politics.get("can_treasury_construction", false))
		if politics.has("capability_bits"):
			return (int(politics.get("capability_bits", 0)) & 1) != 0
	if summary.has("can_treasury_construction"):
		return bool(summary.get("can_treasury_construction", false))
	if summary.has("capability_bits"):
		return (int(summary.get("capability_bits", 0)) & 1) != 0
	return false


func build_construction_entry(host, cell_idx: int) -> Dictionary:
	var h = host
	var entry = {
		"available": false,
		"visible": true,
		"message": "只能在玩家领土内营造。",
		"title": "营造新建筑",
		"hint": "按部门浏览，国库物资优先",
		"count": 0,
	}
	if cell_idx < 0 or host._generator == null \
			or not h._generator.has_method("get_country_facade"):
		return entry
	var country = host._generator.get_country_facade()
	if country == null or not country.has_method("cell_summary"):
		return entry
	var player_handle = host._player_country_handle()
	var summary: Dictionary = country.cell_summary(cell_idx)
	if player_handle <= 0 or not bool(summary.get("owned", false)) \
			or int(summary.get("country_handle", 0)) != player_handle:
		return entry
	if not host._country_allows_treasury_construction(summary):
		entry["visible"] = false
		entry["message"] = "当前体制不开放国库建造。"
		entry["hint"] = ""
		return entry
	entry["available"] = true
	entry["message"] = ""
	var snapshot = host._Construction_delegate._construction_building_snapshot(host, cell_idx)
	if snapshot.is_empty():
		entry["hint"] = "营造目录暂不可读"
		return entry
	if host._snapshot_pending(snapshot):
		entry["hint"] = "正在读取营造目录…"
		return entry
	var count = host._Construction_delegate._construction_catalog_count(host, snapshot)
	# 军事部门也是这个窗口的一部分：只数民用会给玩家一个偏小的目录读数。
	var military_count = host._Construction_delegate._construction_military_count(host)
	entry["count"] = count + military_count
	entry["hint"] = "目录 %d 项 · 按部门浏览，国库物资优先" % (count + military_count) \
		if count + military_count > 0 else ""
	return entry


## 营造窗口模型。查询身份 = cell + sector + search + offset：同身份刷新由窗口
## 只写值，不重建行节点。

func build_construction_model(host, cell_idx: int, sector_id: String = "",
		search: String = "", sort_id: String = "recommended",
		offset: int = 0) -> Dictionary:
	var h = host
	var requested_offset = maxi(0, offset)
	var sort = String(sort_id)
	if not host.CONSTRUCTION_SORT_IDS.has(sort):
		sort = String(host.CONSTRUCTION_SORT_IDS[0])
	var model = {
		"available": false,
		"message": "营造目录暂不可用。",
		"data_pending": false,
		"cell": cell_idx,
		"sector": sector_id,
		"search": search,
		"sort": sort,
		"offset": requested_offset,
		"limit": h.CONSTRUCTION_PAGE_SIZE,
		"total": 0,
		"sector_total": 0,
		"items": [],
		"sectors": [],
		"sorts": h._Construction_delegate._construction_sort_entries(h, sort),
		"header": h._Construction_delegate._construction_header(h, cell_idx),
		"page_label": "",
		"query": {"sector": sector_id, "search": search, "sort": sort,
			"offset": requested_offset},
	}
	if cell_idx < 0 or host._map == null or host._generator == null \
			or not h._generator.has_method("get_country_facade") \
			or not h._generator.has_method("get_economy_facade"):
		return model
	var country = host._generator.get_country_facade()
	var economy = host._generator.get_economy_facade()
	if country == null or economy == null \
			or not economy.has_method("construction_type_columns"):
		return model
	var player_handle = host._player_country_handle()
	var target_summary: Dictionary = country.cell_summary(cell_idx)
	if player_handle <= 0 or not bool(target_summary.get("owned", false)) \
			or int(target_summary.get("country_handle", 0)) != player_handle:
		model["message"] = "只能在本国领土内营造。"
		return model
	if not host._country_allows_treasury_construction(target_summary):
		model["visible"] = false
		model["message"] = "当前体制不开放国库建造。"
		return model
	var snapshot = host._Construction_delegate._construction_building_snapshot(host, cell_idx)
	if snapshot.is_empty():
		model["message"] = "营造目录暂不可读，稍后再试。"
		return model
	if host._snapshot_pending(snapshot):
		model["data_pending"] = true
		model["message"] = "正在读取营造目录…"
		return model
	if not bool(snapshot.get("ok", false)):
		model["message"] = "营造目录暂不可读，稍后再试。"
		return model
	var technology: PackedByteArray = snapshot.get(
		"building_technology_available", PackedByteArray())
	var type_ids: PackedStringArray = snapshot.get(
		"building_type_ids", PackedStringArray())
	var columns: Dictionary = economy.construction_type_columns()
	var sectors: PackedInt32Array = columns.get(
		"building_economic_sectors", PackedInt32Array())
	var durations: PackedInt32Array = columns.get(
		"building_construction_days", PackedInt32Array())
	var sector_ids: PackedStringArray = economy.construction_sector_ids()
	if technology.size() != type_ids.size() or sectors.size() != type_ids.size() \
			or sector_ids.is_empty():
		model["message"] = "营造目录暂不可读，稍后再试。"
		return model
	# 民用目录 = 科技可用 + 非官营。官营建筑不进经济部门循环（经济目录没有
	# `state` 建筑类型），改由下面单独的军事部门列出，数据来自军事目录。
	var kinds: PackedInt32Array = snapshot.get("building_kinds", PackedInt32Array())
	var page_availability = technology.duplicate()
	var counts = {}
	for type_id in range(type_ids.size()):
		if int(page_availability[type_id]) == 0:
			continue
		if type_id < kinds.size() and int(kinds[type_id]) == host.STATE_BUILDING_KIND:
			page_availability[type_id] = 0
			continue
		var sector_name = host._Construction_delegate._construction_sector_name(host,
			sector_ids, int(sectors[type_id]))
		if sector_name.is_empty():
			page_availability[type_id] = 0
			continue
		counts[sector_name] = int(counts.get(sector_name, 0)) + 1
	# 军事部门：条目来自军事目录而非经济目录，所以只取规模做部门计数。
	# 真正切到这一页时才组行（组行要读国库/市场快照，不能白算）。
	var military_total = host._Construction_delegate._construction_military_count(host)
	if military_total > 0:
		counts[host.CONSTRUCTION_MILITARY_SECTOR] = military_total
	# 部门索引签按编译列顺序给出。`military` 已经作为第 6 个 sector 追加进
	# EconomyCatalog.BUILDING_SECTOR_IDS（列顺序是契约，只准追加），所以这里
	# 只做防御性去重：早期版本曾无条件再 append 一次，索引签上会出现两个
	# 一模一样的「军事」页签。
	var page_sector_ids = sector_ids.duplicate()
	if military_total > 0 and page_sector_ids.find(host.CONSTRUCTION_MILITARY_SECTOR) < 0:
		page_sector_ids.append(host.CONSTRUCTION_MILITARY_SECTOR)
	var resolved_sector = sector_id
	if resolved_sector == host.CONSTRUCTION_MILITARY_SECTOR:
		if military_total <= 0:
			resolved_sector = ""
	elif resolved_sector.is_empty() \
			or int(counts.get(resolved_sector, 0)) <= 0:
		resolved_sector = ""
	if resolved_sector.is_empty():
		for candidate in sector_ids:
			if int(counts.get(String(candidate), 0)) > 0:
				resolved_sector = String(candidate)
				break
	model["sectors"] = h._Construction_delegate._construction_sector_entries(h,
		page_sector_ids, counts, resolved_sector)
	if resolved_sector.is_empty():
		model["message"] = ""
		return model
	model["sector"] = resolved_sector
	model["query"]["sector"] = resolved_sector
	model["sector_total"] = int(counts.get(resolved_sector, 0))
	if resolved_sector == host.CONSTRUCTION_MILITARY_SECTOR:
		return host._Construction_delegate._construction_military_page(host, model,
			host._Construction_delegate._construction_military_rows(host, cell_idx, search), sort, requested_offset)
	var sector_index = sector_ids.find(resolved_sector)
	var candidates: PackedInt32Array = economy.construction_candidates(
		search, page_availability, sector_index)
	if candidates.is_empty():
		model["offset"] = 0
		model["query"]["offset"] = 0
		model["available"] = true
		model["message"] = ""
		return model
	# 整部门一次报价（实测 0.14–0.26 ms）：排序才能作用于整个部门，而不是只排当前页。
	var quotes: Dictionary = economy.construction_quotes(
		player_handle, cell_idx, candidates)
	if not bool(quotes.get("ok", false)):
		if bool(quotes.get("busy", false)) \
				or bool(quotes.get("read_view_pending", false)):
			model["data_pending"] = true
			model["message"] = "正在读取营造报价…"
		else:
			model["message"] = "营造报价暂不可用。"
		return model
	var market = host._Overview_delegate._market_snapshot(host, cell_idx)
	var entries = host._Construction_delegate._construction_entries(host, candidates, quotes, snapshot, market,
		durations, columns.get("building_maturity_ranks", PackedInt32Array()))
	# 科技门在目录层已经过滤过；这里再兜一层，绝不让「科技未解锁」进目录。
	var visible_entries: Array = []
	for raw in entries:
		var entry: Dictionary = raw
		if bool(entry.get("tech_locked", false)):
			continue
		visible_entries.append(entry)
	var total = visible_entries.size()
	visible_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return CellInspectorViewModel._Construction._construction_entry_before(a, b, sort))
	# 主粮建筑折叠成「rank 卡 → 作物选项 → 变体」。展开状态由视图模型提供
	# （_construction_fold_state 返回 {"ranks": {...}, "crops": {...}}），
	# 没有该方法时保持全折叠，只出 7 张档位卡。非主粮行不带 fold、原样排在后面。
	var expanded_ranks: Dictionary = {}
	var expanded_crops: Dictionary = {}
	if host.has_method("_construction_fold_state"):
		var fold_state: Dictionary = host._construction_fold_state()
		expanded_ranks = fold_state.get("ranks", {})
		expanded_crops = fold_state.get("crops", {})
	visible_entries = StapleGroups.fold_staple_entries(
		visible_entries, columns, expanded_ranks, expanded_crops)
	total = visible_entries.size()
	var safe_offset = requested_offset
	if safe_offset >= total:
		safe_offset = 0
	model["offset"] = safe_offset
	model["query"]["offset"] = safe_offset
	model["total"] = total
	model["page_label"] = h._Construction_delegate._construction_page_label(h, safe_offset,
		mini(host.CONSTRUCTION_PAGE_SIZE, total - safe_offset), total)
	var page_entries = visible_entries.slice(safe_offset,
		mini(total, safe_offset + host.CONSTRUCTION_PAGE_SIZE))
	model["items"] = h._construction_page_rows(page_entries, quotes, snapshot,
		economy, market, columns.get("building_maturity_display_names",
			PackedStringArray()))
	model["available"] = true
	model["message"] = ""
	return model



func _construction_header(host, cell_idx: int) -> Dictionary:
	var h = host
	var header = {
		"kicker": "营造目录",
		"title": "新建建筑",
		"subtitle": "国库物资优先，缺口向本地市场购入",
	}
	if cell_idx < 0 or host._map == null or not host._map.has_indices():
		return header
	var cell = host._map.cell_at(cell_idx)
	if cell == null:
		return header
	header["subtitle"] = "%s · %s · 国库出资，缺料市购" % [
		LandformType.name_cn(host._landform(cell, cell_idx)),
		TerrainType.terrain_name_cn(host._Geography_delegate._terrain(host, cell, cell_idx))]
	return header



func _construction_catalog_count(host, snapshot: Dictionary) -> int:
	var h = host
	var technology: PackedByteArray = snapshot.get(
		"building_technology_available", PackedByteArray())
	var kinds: PackedInt32Array = snapshot.get("building_kinds", PackedInt32Array())
	var count = 0
	for type_id in range(technology.size()):
		if int(technology[type_id]) == 0:
			continue
		if type_id < kinds.size() and int(kinds[type_id]) == host.STATE_BUILDING_KIND:
			continue
		count += 1
	return count


func _construction_military_count(host, ) -> int:
	return MilitaryRows._construction_military_count(host)


func _construction_military_rows(host, cell_idx: int, search: String) -> Array:
	return MilitaryRows._construction_military_rows(host, cell_idx, search)


func _construction_military_occupied(host, catalog_rows: Array, snapshot: Dictionary) -> Dictionary:
	return MilitaryRows._construction_military_occupied(host, catalog_rows, snapshot)


func _construction_military_row(host, facade, index: int, row: Dictionary,
		snapshot: Dictionary, researched: PackedStringArray, gate_known: bool,
		can_build: bool, cash: int, cell_idx: int, occupied: Dictionary,
		treasury_stock: Dictionary, market_stock: Dictionary) -> Dictionary:
	return MilitaryRows._construction_military_row(host, facade, index, row, snapshot, researched, gate_known, can_build, cash, cell_idx, occupied, treasury_stock, market_stock)


func _construction_military_block_text(host, snapshot: Dictionary) -> String:
	return MilitaryRows._construction_military_block_text(host, snapshot)


func _state_building_pending_by_index(host, snapshot: Dictionary, index: int) -> int:
	return MilitaryRows._state_building_pending_by_index(host, snapshot, index)


func _construction_military_page(host, model: Dictionary, rows: Array,
		sort: String, requested_offset: int) -> Dictionary:
	return MilitaryRows._construction_military_page(host, model, rows, sort, requested_offset)


static func _construction_military_before(a: Dictionary, b: Dictionary,
		sort: String) -> bool:
	return MilitaryRows._construction_military_before(a, b, sort)


## 建筑快照只有「按已提交日」的语义：同格同日复用一份，避免建筑页签与
## 营造窗口各拉一次完整快照。

func _construction_building_snapshot(host, cell_idx: int) -> Dictionary:
	var h = host
	var key = "%d|%d" % [cell_idx, h._Geography_delegate._current_sample_day(h)]
	if String(h._building_snapshot_memo.get("key", "")) == key:
		return h._building_snapshot_memo.get("snapshot", {})
	var snapshot = host._Overview_delegate._building_snapshot(host, cell_idx)
	if snapshot.is_empty() or host._snapshot_pending(snapshot) \
			or not bool(snapshot.get("ok", false)):
		return snapshot
	h._building_snapshot_memo = {"key": key, "snapshot": snapshot}
	return snapshot



func _construction_sector_name(host, sector_ids: PackedStringArray, sector_index: int) -> String:
	var h = host
	if sector_index < 0 or sector_index >= sector_ids.size():
		return ""
	return String(sector_ids[sector_index])



func _construction_sort_entries(host, selected: String) -> Array:
	var h = host
	return [
		{
			"id": "recommended", "label": "推荐", "selected": selected == "recommended",
			"tooltip": "可建优先，再按估算毛利/日从高到低（本地市价，未计工资与税）",
		},
		{
			"id": "cost", "label": "造价", "selected": selected == "cost",
			"tooltip": "可建优先，再按现金支出从低到高",
		},
		{
			"id": "newest", "label": "最新", "selected": selected == "newest",
			"tooltip": "可建优先，再按生产成熟度从新到旧（自然获取 → 自动化）",
		},
	]



func _construction_sector_entries(host, sector_ids: PackedStringArray,
		counts: Dictionary, selected: String) -> Array:
	var h = host
	var entries = []
	for raw in sector_ids:
		var sector_name = String(raw)
		var count = int(counts.get(sector_name, 0))
		if count <= 0:
			continue
		var label = String(host.CONSTRUCTION_SECTOR_LABELS.get(sector_name, sector_name))
		entries.append({
			"id": sector_name,
			"label": label,
			"count": count,
			"icon": h.CONSTRUCTION_SECTOR_ICONS.get(sector_name, &"economy.building"),
			"question": "%s · %d 项可营造" % [label, count],
			"selected": sector_name == selected,
		})
	return entries



func _construction_page_label(host, offset: int, count: int, total: int) -> String:
	var h = host
	if total <= 0 or count <= 0:
		return ""
	return "%d–%d / %d" % [offset + 1, mini(total, offset + count), total]



func _construction_local_stock(host, market: Dictionary) -> Dictionary:
	var h = host
	var stock_by_good = {}
	var ids: PackedStringArray = market.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = market.get("stock", PackedInt64Array())
	for index in range(mini(ids.size(), stock.size())):
		stock_by_good[String(ids[index])] = int(stock[index])
	return stock_by_good


## 排序用的轻量条目：只带排序键与行内要用的字段，材料/配方等重数据留给当前页。

func _construction_entries(host, candidates: PackedInt32Array, quotes: Dictionary,
		snapshot: Dictionary, market: Dictionary, durations: PackedInt32Array,
		maturity_ranks: PackedInt32Array) -> Array:
	var h = host
	var entries = []
	var items: Array = quotes.get("items", [])
	var prices = host._Construction_delegate._construction_price_by_good(host, market)
	for index in range(mini(candidates.size(), items.size())):
		var item: Dictionary = items[index]
		var type_id = int(candidates[index])
		var building_id = String(item.get("building_id", ""))
		var reason_code = String(item.get("reason_code", ""))
		entries.append({
			"index": index,
			"type_id": type_id,
			"building_id": building_id,
			"name": String(item.get("name", building_id)),
			"icon": h._building_icon(building_id, snapshot, type_id),
			"eligible": bool(item.get("eligible", false)),
			"reason_code": reason_code,
			"tech_locked": reason_code == "construction_technology_locked",
			"cash_required": int(item.get("cash_required", 0)),
			"market_used": int(item.get("market_goods_used", 0)),
			"score": h._Construction_delegate._construction_daily_score(h, type_id, snapshot, prices),
			"days": int(durations[type_id]) \
				if type_id >= 0 and type_id < durations.size() else 0,
			"maturity_rank": int(maturity_ranks[type_id]) \
				if type_id >= 0 and type_id < maturity_ranks.size() else 0,
		})
	return entries


## 三档排序共用的比较器：**可建永远在前**，再按该档的主键，最后按名称稳定排序。
## recommended = 估算毛利/日（本地市价，未计工资与税）高→低；
## cost = 现金支出 低→高；newest = 生产成熟度档位 高→低。

func _construction_daily_score(host, type_id: int, snapshot: Dictionary,
		prices: Dictionary) -> int:
	var h = host
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	return h._Construction_delegate._construction_flow_value(h, snapshot, type_id, "output", good_ids, prices) \
		- h._Construction_delegate._construction_flow_value(h, snapshot, type_id, "input", good_ids, prices)



func _construction_flow_value(host, snapshot: Dictionary, type_id: int, kind: String,
		good_ids: PackedStringArray, prices: Dictionary) -> int:
	var h = host
	var offsets: PackedInt32Array = snapshot.get(
		"building_%s_offsets" % kind, PackedInt32Array())
	var good_indices: PackedInt32Array = snapshot.get(
		"building_%s_good_ids" % kind, PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get(
		"building_%s_quantities" % kind, PackedInt64Array())
	if type_id < 0 or type_id + 1 >= offsets.size():
		return 0
	var total = 0
	for cursor in range(int(offsets[type_id]), int(offsets[type_id + 1])):
		if cursor >= good_indices.size() or cursor >= quantities.size():
			break
		var good_idx = int(good_indices[cursor])
		if good_idx < 0 or good_idx >= good_ids.size():
			continue
		var price = int(prices.get(String(good_ids[good_idx]), 0))
		if price <= 0:
			continue
		total += int(quantities[cursor]) * price / 1000
	return total



func _construction_price_by_good(host, market: Dictionary) -> Dictionary:
	var h = host
	var prices = {}
	var ids: PackedStringArray = market.get("good_ids", PackedStringArray())
	var values: PackedInt32Array = market.get("price", PackedInt32Array())
	for index in range(mini(ids.size(), values.size())):
		prices[String(ids[index])] = int(values[index])
	return prices



func _construction_page_rows(host, entries: Array, quotes: Dictionary,
		snapshot: Dictionary, economy, market: Dictionary,
		maturity_names: PackedStringArray) -> Array:
	return RowPresentation._construction_page_rows(host, entries, quotes, snapshot, economy, market, maturity_names)


func _construction_materials_text(host, materials: Array) -> String:
	return RowPresentation._construction_materials_text(host, materials)


func _construction_material_status_rows(host, materials: Array,
		local_stock: Dictionary) -> Array:
	return RowPresentation._construction_material_status_rows(host, materials, local_stock)


func _construction_reason_text(host, code: String, materials: Array,
		local_stock: Dictionary) -> String:
	return RowPresentation._construction_reason_text(host, code, materials, local_stock)


func _construction_tooltip(host, entry: Dictionary, item: Dictionary, materials: Array,
		local_stock: Dictionary, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary, days: int, maturity: String,
		reason_text: String) -> String:
	return RowPresentation._construction_tooltip(host, entry, item, materials, local_stock, placement, job_spec, unlocked_goods, days, maturity, reason_text)


func _construction_job_text(host, job_spec: Dictionary) -> String:
	return RowPresentation._construction_job_text(host, job_spec)


func _construction_preview_rows(host, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary) -> Dictionary:
	return RowPresentation._construction_preview_rows(host, placement, job_spec, unlocked_goods)


func _construction_recipe_side(host, rows: Array) -> String:
	return Recipes._construction_recipe_side(host, rows)



func _goods_scaled(host, value: int) -> String:
	return Recipes._goods_scaled(host, value)



func _construction_recipe_rows(host, placement: Dictionary, ids_key: String,
		quantities_key: String, label: String) -> Array:
	return Recipes._construction_recipe_rows(host, placement, ids_key, quantities_key, label)



func _construction_input_recipe_rows(host, placement: Dictionary,
		unlocked_goods: Dictionary) -> Array:
	return Recipes._construction_input_recipe_rows(host, placement, unlocked_goods)



func _construction_input_candidate_label(host, placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> String:
	return Recipes._construction_input_candidate_label(host, placement, input_idx, unlocked_goods)



func _unlocked_good_ids(host, snapshot: Dictionary) -> Dictionary:
	return Recipes._unlocked_good_ids(host, snapshot)



func _construction_profession_name(host, profession_id: String) -> String:
	return Recipes._construction_profession_name(host, profession_id)



func _append_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int, kind: String,
		actual_total: int, building_count: int, period_days: int, group_idx: int = -1) -> void:
	return Recipes._append_recipe_rows(host, rows, snapshot, type_idx, kind, actual_total, building_count, period_days, group_idx)



func _selected_input_short_label(host, snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	return Recipes._selected_input_short_label(host, snapshot, input_idx, local_input_idx, group_idx, fallback_id)



func _input_candidate_label(host, snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	return Recipes._input_candidate_label(host, snapshot, input_idx, local_input_idx, group_idx, fallback_id)



func _append_resource_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	return Recipes._append_resource_recipe_rows(host, rows, snapshot, type_idx, actual_total, building_count, period_days)



func _append_resource_generation_rows(host, rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	return Recipes._append_resource_generation_rows(host, rows, snapshot, type_idx, actual_total, building_count, period_days)



func _building_resource_depleted(host, snapshot: Dictionary, type_idx: int) -> bool:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_resource_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_production_resource_ids", PackedInt32Array())
	var access_modes: PackedInt32Array = snapshot.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var effective: PackedInt64Array = snapshot.get("building_resource_effective_reserve", PackedInt64Array())
	var accessible: PackedInt64Array = snapshot.get(
		"building_resource_accessible_effective_reserve", PackedInt64Array())
	if type_idx < 0 or type_idx + 1 >= offsets.size() or offsets[type_idx] == offsets[type_idx + 1]:
		return false
	for cursor in range(offsets[type_idx], offsets[type_idx + 1]):
		var resource_idx = int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var values = accessible if cursor < access_modes.size() and int(access_modes[cursor]) == 1 else effective
		if resource_idx >= 0 and resource_idx < values.size() and int(values[resource_idx]) > 0:
			return false
	return true



func _resource_effective_text(host, snapshot: Dictionary, resource_idx: int, access_mode: int = 0) -> String:
	var h = host
	var reserves: PackedInt64Array = snapshot.get(
		"building_resource_accessible_current_reserve" if access_mode == 1 else \
		"building_resource_current_reserve", PackedInt64Array())
	var effective: PackedInt64Array = snapshot.get(
		"building_resource_accessible_effective_reserve" if access_mode == 1 else \
		"building_resource_effective_reserve", PackedInt64Array())
	var pending: PackedInt64Array = snapshot.get(
		"building_resource_accessible_pending_change" if access_mode == 1 else \
		"building_resource_pending_change", PackedInt64Array())
	var reserve = int(reserves[resource_idx]) if resource_idx >= 0 and resource_idx < reserves.size() else 0
	var available = int(effective[resource_idx]) if resource_idx >= 0 and resource_idx < effective.size() else 0
	var queued = int(pending[resource_idx]) if resource_idx >= 0 and resource_idx < pending.size() else 0
	return "%.3f（储量 %.3f，待处理 %+.3f）" % [
		float(available) / 1000.0, float(reserve) / 1000.0, float(queued) / 1000.0]



func _append_construction_rows(host, rows: Array, snapshot: Dictionary, type_ids: PackedStringArray, type_names: PackedStringArray) -> void:
	RowPresentation._append_construction_rows(host, rows, snapshot, type_ids, type_names)


func _building_icon(host, type_id: String, snapshot: Dictionary = {}, type_idx: int = -1) -> StringName:
	return RowPresentation._building_icon(host, type_id, snapshot, type_idx)


func _owner_profession_name(host, snapshot: Dictionary, signature_idx: int) -> String:
	return RowPresentation._owner_profession_name(host, snapshot, signature_idx)


func _profession_name(host, snapshot: Dictionary, profession_idx: int) -> String:
	return RowPresentation._profession_name(host, snapshot, profession_idx)


func _format_input_candidate_label(host, good_id: String, efficiency_q16: int) -> String:
	return RowPresentation._format_input_candidate_label(host, good_id, efficiency_q16)


func _good_display_name(host, stable_id: String) -> String:
	return RowPresentation._good_display_name(host, stable_id)


func _resource_display_name(host, stable_id: String) -> String:
	return RowPresentation._resource_display_name(host, stable_id)


func _fill_percent(host, filled: int, required: int) -> float:
	return RowPresentation._fill_percent(host, filled, required)


func _actual_daily_rate(host, actual_total: int, building_count: int, period_days: int) -> String:
	return RowPresentation._actual_daily_rate(host, actual_total, building_count, period_days)


func _sum_i64(host, values: PackedInt64Array) -> int:
	return RowPresentation._sum_i64(host, values)


func _money_text(host, subunits: int) -> String:
	return RowPresentation._money_text(host, subunits)


func _goods_unit_text(host, subunits: int) -> String:
	return RowPresentation._goods_unit_text(host, subunits)


func _packed_i64_at(host, values: PackedInt64Array, index: int) -> int:
	return RowPresentation._packed_i64_at(host, values, index)


func _market_trade_enabled(host, enabled: PackedByteArray, index: int) -> bool:
	return RowPresentation._market_trade_enabled(host, enabled, index)


func _trade_arrival_days(host, next_arrival_day: int, sample_day: int) -> int:
	return RowPresentation._trade_arrival_days(host, next_arrival_day, sample_day)


func _market_trade_insight_text(host, in_transit_kinds: int, arrival_days: int) -> String:
	return RowPresentation._market_trade_insight_text(host, in_transit_kinds, arrival_days)


func _cashflow_source_name(host, source_id: String, income: bool) -> String:
	return RowPresentation._cashflow_source_name(host, source_id, income)


func _has_cashflow_row(host, rows: Array, source_id: String) -> bool:
	return RowPresentation._has_cashflow_row(host, rows, source_id)


static func _construction_entry_before(a: Dictionary, b: Dictionary,
		sort: String) -> bool:
	return StapleGroups._construction_entry_before(a, b, sort)

static func staple_crop_key(type_id: int, columns: Dictionary) -> String:
	return StapleGroups.staple_crop_key(type_id, columns)

static func staple_variant_before(a: Dictionary, b: Dictionary) -> bool:
	return StapleGroups.staple_variant_before(a, b)

static func fold_staple_entries(entries: Array, columns: Dictionary,
		expanded_ranks: Dictionary = {}, expanded_crops: Dictionary = {}) -> Array:
	return StapleGroups.fold_staple_entries(entries, columns, expanded_ranks, expanded_crops)
