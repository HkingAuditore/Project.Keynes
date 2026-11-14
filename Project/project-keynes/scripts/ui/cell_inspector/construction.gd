extends RefCounted


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
	var snapshot = host._construction_building_snapshot(cell_idx)
	if snapshot.is_empty():
		entry["hint"] = "营造目录暂不可读"
		return entry
	if host._snapshot_pending(snapshot):
		entry["hint"] = "正在读取营造目录…"
		return entry
	var count = host._construction_catalog_count(snapshot)
	# 军事部门也是这个窗口的一部分：只数民用会给玩家一个偏小的目录读数。
	var military_count = host._construction_military_count()
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
		"sorts": h._construction_sort_entries(sort),
		"header": h._construction_header(cell_idx),
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
	var snapshot = host._construction_building_snapshot(cell_idx)
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
		var sector_name = host._construction_sector_name(
			sector_ids, int(sectors[type_id]))
		if sector_name.is_empty():
			page_availability[type_id] = 0
			continue
		counts[sector_name] = int(counts.get(sector_name, 0)) + 1
	# 军事部门：条目来自军事目录而非经济目录，所以只取规模做部门计数。
	# 真正切到这一页时才组行（组行要读国库/市场快照，不能白算）。
	var military_total = host._construction_military_count()
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
	model["sectors"] = h._construction_sector_entries(
		page_sector_ids, counts, resolved_sector)
	if resolved_sector.is_empty():
		model["message"] = ""
		return model
	model["sector"] = resolved_sector
	model["query"]["sector"] = resolved_sector
	model["sector_total"] = int(counts.get(resolved_sector, 0))
	if resolved_sector == host.CONSTRUCTION_MILITARY_SECTOR:
		return host._construction_military_page(model,
			host._construction_military_rows(cell_idx, search), sort, requested_offset)
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
	var market = host._market_snapshot(cell_idx)
	var entries = host._construction_entries(candidates, quotes, snapshot, market,
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
		return host._construction_entry_before(a, b, sort))
	var safe_offset = requested_offset
	if safe_offset >= total:
		safe_offset = 0
	model["offset"] = safe_offset
	model["query"]["offset"] = safe_offset
	model["total"] = total
	model["page_label"] = h._construction_page_label(safe_offset,
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
		TerrainType.terrain_name_cn(host._terrain(cell, cell_idx))]
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


## 军事目录规模：只读缓存里的行数，不读国库/市场、不算成本。部门计数与
## 营造入口的「目录 N 项」用它，避免为了一个数字把 17 座建筑的成本全算一遍。
## 口径必须与民用部门一致：科技未解锁的条目不进目录（见
## docs/ui/building-workspace.md §5）。否则部门签写「17 项」、点进去却只有
## 开局那一档，和民用部门的行为也对不上。

func _construction_military_count(host, ) -> int:
	var h = host
	var facade = host._military_facade()
	if facade == null:
		return 0
	var rows: Array = h._military_catalog_cache(facade).get("buildings", [])
	var researched = host.player_technology_ids()
	var gate_known = host._technology_ids_resolved
	var count = 0
	for raw in rows:
		if raw is Dictionary and host._state_building_unlocked(raw, researched, gate_known):
			count += 1
	return count


## 营造窗口的军事部门：一次性把军事目录的 `state_buildings`（17 座）组成本窗口
## 的行。数据源与地块档案「军事」页同源（MilitaryCatalog），命令也走同一条
## `state.build`：这里不发明新的结算通道，只把「能建什么」摊开成一个可浏览的目录。
##
## 与经济部门一样的判定链：官方建筑与普通建筑都用 `construction_quotes` 报价，
## 卡点顺序同为「科技 → 施工位 → 该档已建成 → 建材/现金」。官营建筑的造价来自
## 库里经济目录的同类型定义（`COMMAND_TREASURY_SPONSORED_BUILD` 会真正扣的那
## 笔钱），不再用 v1 的建材折现估计（见 docs/ui/military-cell-tab.md §2.1）。

func _construction_military_rows(host, cell_idx: int, search: String) -> Array:
	var h = host
	var facade = host._military_facade()
	if facade == null:
		return []
	var country = host._generator.get_country_facade() if host._generator != null \
		and h._generator.has_method("get_country_facade") else null
	var snapshot: Dictionary = facade.cell_snapshot(cell_idx,
		host._player_country_handle())
	if not bool(snapshot.get("ok", false)):
		return []
	var catalog = host._military_catalog_cache(facade)
	var catalog_rows: Array = catalog.get("buildings", [])
	if catalog_rows.is_empty():
		return []
	var researched = host.player_technology_ids()
	var gate_known = host._technology_ids_resolved
	var can_build = host._military_can_build(snapshot, host._country_summary(cell_idx))
	var cash = host._country_cash() if can_build else -1
	# 库存与市场各读一次：17 座建筑共用，避免逐行重复拉国库与市场快照。
	var treasury_stock = host._treasury_good_stock() if can_build else {}
	var market_stock = host._construction_local_stock(host._market_snapshot(cell_idx)) \
		if can_build else {}
	var occupied = host._construction_military_occupied(catalog_rows, snapshot)
	var query = search.strip_edges().to_lower()
	var rows: Array = []
	for index in range(catalog_rows.size()):
		var row: Dictionary = catalog_rows[index]
		# 与经济部门同口径：科技未解锁的条目在目录层直接剔除，不进列表
		# （民用部门由 building_technology_available 过滤，见 §5）。
		# 科技快照不可读时保留「宁可见不误藏」的既有兜底，命令层还会再拦一次。
		if not host._state_building_unlocked(row, researched, gate_known):
			continue
		var name = String(row.get("name", row.get("id", ""))).strip_edges()
		if not query.is_empty() and name.to_lower().find(query) < 0 \
				and String(row.get("id", "")).to_lower().find(query) < 0:
			continue
		rows.append(host._construction_military_row(facade, index, row, snapshot,
			researched, gate_known, can_build, cash, cell_idx, occupied,
			treasury_stock, market_stock))
	return rows


## 这一格已建成的档位：兵营按档累加（`barracks_count[tier]` 是计数数组），
## 城防/军校在原生侧只保留最高档（military_core.cpp:3287 用 std::max 覆盖）。
## 因此「该档已建成」只能用来拦城防/军校：兵营同档再建是有效操作，兵额会叠加。

func _construction_military_occupied(host, catalog_rows: Array, snapshot: Dictionary) -> Dictionary:
	var h = host
	var occupied = {"barracks": {}, "fortification": {}, "war_college": {}}
	var tiers = snapshot.get("barracks_tiers", null)
	if tiers is PackedInt32Array:
		for tier_idx in range((tiers as PackedInt32Array).size()):
			if int((tiers as PackedInt32Array)[tier_idx]) > 0:
				(occupied["barracks"] as Dictionary)[tier_idx] = true
	for role_name in ["fortification", "war_college"]:
		var tier = int(snapshot.get("fort_tier" if role_name == "fortification"
			else "college_tier", -1))
		if tier >= 0:
			(occupied[role_name] as Dictionary)[tier] = true
	return occupied


## 军事部门的一行：与经济部门同字段（`building_id` / `eligible` / `reason_text` /
## `materials_text` / `cash_required` / `tooltip`），好让同一个行控件画两种条目。
## 额外带 `military_index`（原生 `state.build` 的 `building` 参数）与 `role_id`。

func _construction_military_row(host, facade, index: int, row: Dictionary,
		snapshot: Dictionary, researched: PackedStringArray, gate_known: bool,
		can_build: bool, cash: int, cell_idx: int, occupied: Dictionary,
		treasury_stock: Dictionary, market_stock: Dictionary) -> Dictionary:
	var h = host
	var role = int(row.get("role", -1))
	var role_id = String((host.STATE_BUILDING_ROLES[clampi(role, 0,
		h.STATE_BUILDING_ROLES.size() - 1)] as Dictionary).get("id", ""))
	var role_label = String((host.STATE_BUILDING_ROLES[clampi(role, 0,
		h.STATE_BUILDING_ROLES.size() - 1)] as Dictionary).get("label", ""))
	var building_id = String(row.get("id", ""))
	var tier = int(row.get("tier", -1))
	var name = String(row.get("name", building_id)).strip_edges()
	if name.is_empty():
		name = role_label
	var disrepair = bool(snapshot.get("disrepair", false))
	var effect = host._state_building_effect(role_id, row, disrepair)
	var cost = host._empty_state_building_cost()
	if can_build:
		cost = host._state_building_cost(facade, index, row, cash, cell_idx,
			treasury_stock, market_stock)
	var unlocked = host._state_building_unlocked(row, researched, gate_known)
	var pending = host._state_building_pending_by_index(snapshot, index)
	# 可建判定与地块档案那一行同序：科技 -> 施工位 -> 该档已存在 -> 建材/现金。
	# 顺序决定玩家先看到「差科技」而不是「缺钱」，因为科技是更硬的闸门。
	# 兵营例外：原生 `barracks_count[tier]` 是计数数组，同档再建会叠加兵额。
	var reason = ""
	var eligible = false
	if not can_build:
		reason = host._construction_military_block_text(snapshot)
	elif not unlocked:
		reason = "科技未解锁"
	elif pending >= 0:
		reason = "在建 · 剩 %d 日" % pending
	elif role_id != "barracks" \
			and bool((occupied.get(role_id, {}) as Dictionary).get(tier, false)):
		reason = "该档已建成"
	elif bool(cost.get("blocked", false)):
		reason = String(cost.get("reason_text", "暂不可营造"))
	else:
		eligible = true
	var cash_required = int(cost.get("cash_required", 0))
	var tooltip_lines = PackedStringArray()
	tooltip_lines.append(name)
	tooltip_lines.append("类别：%s · %d 档" % [role_label, tier])
	if not effect.is_empty():
		tooltip_lines.append("效果：%s" % effect)
	var materials_text = String(cost.get("materials_text", ""))
	if can_build:
		for raw in (cost.get("materials", []) as Array):
			var material: Dictionary = raw
			var line = "建材：%s %s（国库 %s" % [
				String(material.get("name", "建材")),
				h._goods_scaled(int(material.get("required", 0))),
				h._goods_scaled(int(material.get("treasury", 0)))]
			var market = int(material.get("market", 0))
			if market > 0:
				line += " / 市购 %s" % h._goods_scaled(market)
			tooltip_lines.append(line + "）")
		var days_text = String(cost.get("days_text", ""))
		if not days_text.is_empty():
			tooltip_lines.append("工期：%s" % days_text)
		var cash_text = String(cost.get("cash_text", ""))
		if not cash_text.is_empty():
			tooltip_lines.append("现金：%s（一次性）" % cash_text)
		if not reason.is_empty():
			tooltip_lines.append("卡点：%s" % reason)
	else:
		tooltip_lines.append("卡点：%s" % reason)
	return {
		"building_id": building_id,
		"military_index": index,
		"role_id": role_id,
		"role_label": role_label,
		"tier": tier,
		"name": name,
		"icon": String(IconCatalog.military_building_semantic(building_id, role_id, tier)),
		"eligible": eligible,
		"blocked": not eligible,
		"reason_code": String(cost.get("reason_code", "")),
		"reason_text": "" if eligible else reason,
		"materials_text": materials_text if can_build else "",
		"cash_required": cash_required,
		"cash_text": h._money_text(cash_required) if cash_required > 0 else "",
		"market_used": 0,
		"tooltip": "\n".join(tooltip_lines),
	}


## 不可建的具体原因：驻军格已被外人占领与「不是自家地」对玩家是两件事，
## 而「读不到归属」又不该被说成「不是你的地」。三者分开写。

func _construction_military_block_text(host, snapshot: Dictionary) -> String:
	var h = host
	var owner_slot = int(snapshot.get("owner_slot", -1))
	if owner_slot < 0:
		return "无主之地"
	if int(snapshot.get("controller_slot", -1)) != owner_slot:
		return "领土被占领"
	return "非本国领土"


## 该建筑是否正在这一格的施工位里（原生 3 个施工位），返回剩余天数，-1 = 不在建。

func _state_building_pending_by_index(host, snapshot: Dictionary, index: int) -> int:
	var h = host
	var built = snapshot.get("construction_buildings", null)
	if not built is PackedInt32Array:
		return -1
	var done = snapshot.get("construction_done_days", null)
	var done_days: PackedInt32Array = done if done is PackedInt32Array \
		else PackedInt32Array()
	var today = host._current_sample_day()
	for slot in range((built as PackedInt32Array).size()):
		if int((built as PackedInt32Array)[slot]) != index:
			continue
		if slot < done_days.size() and int(done_days[slot]) >= 0:
			return maxi(0, int(done_days[slot]) - today)
		return 0
	return -1


## 军事部门的一页：排序（可建优先）+ 分页，字段与经济部门完全一致。

func _construction_military_page(host, model: Dictionary, rows: Array,
		sort: String, requested_offset: int) -> Dictionary:
	var h = host
	var sorted_rows = rows.duplicate()
	sorted_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return host._construction_military_before(a, b, sort))
	var total = sorted_rows.size()
	var safe_offset = requested_offset
	if safe_offset >= total:
		safe_offset = 0
	model["offset"] = safe_offset
	model["query"]["offset"] = safe_offset
	model["total"] = total
	model["page_label"] = h._construction_page_label(safe_offset,
		mini(host.CONSTRUCTION_PAGE_SIZE, total - safe_offset), total)
	model["items"] = sorted_rows.slice(safe_offset,
		mini(total, safe_offset + host.CONSTRUCTION_PAGE_SIZE))
	model["available"] = true
	model["message"] = ""
	return model


## 军事部门的排序：与经济部门同口径（可建优先），档位是这里的第二主键——
## 官营建筑是逐档升级的一条线，低档在前才读得通。

static func _construction_military_before(a: Dictionary, b: Dictionary,
		sort: String) -> bool:
	var a_eligible = bool(a.get("eligible", false))
	var b_eligible = bool(b.get("eligible", false))
	if a_eligible != b_eligible:
		return a_eligible
	if sort == "cost":
		var a_cash = int(a.get("cash_required", 0))
		var b_cash = int(b.get("cash_required", 0))
		if a_cash != b_cash:
			return a_cash < b_cash
	elif sort == "newest":
		var a_tier = int(a.get("tier", 0))
		var b_tier = int(b.get("tier", 0))
		if a_tier != b_tier:
			return a_tier > b_tier
	var a_role = String(a.get("role_id", ""))
	var b_role = String(b.get("role_id", ""))
	if a_role != b_role:
		return a_role < b_role
	var a_order = int(a.get("tier", 0))
	var b_order = int(b.get("tier", 0))
	if a_order != b_order:
		return a_order < b_order
	return String(a.get("name", "")) < String(b.get("name", ""))


## 建筑快照只有「按已提交日」的语义：同格同日复用一份，避免建筑页签与
## 营造窗口各拉一次完整快照。

func _construction_building_snapshot(host, cell_idx: int) -> Dictionary:
	var h = host
	var key = "%d|%d" % [cell_idx, h._current_sample_day()]
	if String(h._building_snapshot_memo.get("key", "")) == key:
		return h._building_snapshot_memo.get("snapshot", {})
	var snapshot = host._building_snapshot(cell_idx)
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
	var prices = host._construction_price_by_good(market)
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
			"score": h._construction_daily_score(type_id, snapshot, prices),
			"days": int(durations[type_id]) \
				if type_id >= 0 and type_id < durations.size() else 0,
			"maturity_rank": int(maturity_ranks[type_id]) \
				if type_id >= 0 and type_id < maturity_ranks.size() else 0,
		})
	return entries


## 三档排序共用的比较器：**可建永远在前**，再按该档的主键，最后按名称稳定排序。
## recommended = 估算毛利/日（本地市价，未计工资与税）高→低；
## cost = 现金支出 低→高；newest = 生产成熟度档位 高→低。

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


## 每座每日「产出市值 − 投入市值」（本地市价、单位对齐 GOODS_SCALE）。
## 只是排序启发式，不写回任何模拟状态。

func _construction_daily_score(host, type_id: int, snapshot: Dictionary,
		prices: Dictionary) -> int:
	var h = host
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	return h._construction_flow_value(snapshot, type_id, "output", good_ids, prices) \
		- h._construction_flow_value(snapshot, type_id, "input", good_ids, prices)



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
	var h = host
	var rows = []
	var items: Array = quotes.get("items", [])
	var local_stock = host._construction_local_stock(market)
	var unlocked_goods = host._unlocked_good_ids(market)
	for raw in entries:
		var entry: Dictionary = raw
		var index = int(entry.get("index", -1))
		var item: Dictionary = items[index] \
			if index >= 0 and index < items.size() else {}
		var materials: Array = item.get("materials", [])
		var type_id = int(entry.get("type_id", -1))
		var building_id = String(entry.get("building_id", ""))
		var eligible = bool(entry.get("eligible", false))
		var reason_text = host._construction_reason_text(
			String(entry.get("reason_code", "")), materials, local_stock)
		var maturity = String(maturity_names[type_id]) \
			if type_id >= 0 and type_id < maturity_names.size() else ""
		var placement: Dictionary = economy.building_placement_spec(
			StringName(building_id)) if economy.has_method("building_placement_spec") else {}
		var job_spec: Dictionary = economy.building_job_spec(
			StringName(building_id)) if economy.has_method("building_job_spec") else {}
		var cash = int(entry.get("cash_required", 0))
		rows.append({
			"building_id": building_id,
			"type_id": type_id,
			"name": String(entry.get("name", building_id)),
			"icon": entry.get("icon", &"economy.building"),
			"eligible": eligible,
			"blocked": not eligible,
			"reason_code": String(entry.get("reason_code", "")),
			"reason_text": "" if eligible else reason_text,
			"materials_text": h._construction_materials_text(materials),
			"cash_required": cash,
			"cash_text": h._money_text(cash),
			"days": int(entry.get("days", 0)),
			"score": int(entry.get("score", 0)),
			"maturity": maturity,
			"market_used": int(entry.get("market_used", 0)),
			"tooltip": h._construction_tooltip(entry, item, materials, local_stock,
				placement, job_spec, unlocked_goods, int(entry.get("days", 0)),
				maturity, reason_text),
		})
	return rows



func _construction_materials_text(host, materials: Array) -> String:
	var h = host
	var parts = PackedStringArray()
	for raw in materials:
		if parts.size() >= 3:
			break
		var material: Dictionary = raw
		parts.append("%s %s" % [String(material.get("name", "建材")),
			h._goods_scaled(int(material.get("required", 0)))])
	var text = " · ".join(parts)
	if materials.size() > parts.size():
		text += " 等 %d 项" % materials.size()
	return text



func _construction_reason_text(host, code: String, materials: Array,
		local_stock: Dictionary) -> String:
	var h = host
	if code.is_empty() or code == "ok":
		return ""
	if code == "construction_materials_insufficient":
		# 同一个拒绝码覆盖两种缺料：国库+市场总量不够，或市场现货不够缺口。
		for raw in materials:
			var material: Dictionary = raw
			var shortfall = int(material.get("market", 0))
			if shortfall <= 0:
				continue
			var good_id = String(material.get("good_id", ""))
			if int(local_stock.get(good_id, 0)) < shortfall:
				return String(host.CONSTRUCTION_REASON_TEXT.get(
					"construction_market_short", "市场缺货"))
	return String(h.CONSTRUCTION_REASON_TEXT.get(code, "暂不可营造"))


## hover 详情：先答「它提供什么岗位、吃什么、产什么」，再答成本与卡点。
## 每段独立成行、段名在前；没有数据的段整行不出。

func _construction_tooltip(host, entry: Dictionary, item: Dictionary, materials: Array,
		local_stock: Dictionary, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary, days: int, maturity: String,
		reason_text: String) -> String:
	var h = host
	var lines = PackedStringArray()
	var job_text = host._construction_job_text(job_spec)
	if not job_text.is_empty():
		lines.append("岗位：%s" % job_text)
	var inputs = host._construction_recipe_side(
		host._construction_input_recipe_rows(placement, unlocked_goods))
	if not inputs.is_empty():
		lines.append("投入：%s" % inputs)
	var outputs = host._construction_recipe_side(
		h._construction_recipe_rows(placement, "output_good_ids",
			"output_quantities", "产出"))
	if not outputs.is_empty():
		lines.append("产出：%s" % outputs)
	for raw in materials:
		var material: Dictionary = raw
		var required = int(material.get("required", 0))
		var treasury = int(material.get("treasury", 0))
		var market = int(material.get("market", 0))
		var line = "建材：%s %s（国库 %s" % [
			String(material.get("name", "建材")),
			host._goods_scaled(required), host._goods_scaled(treasury)]
		if market > 0:
			line += " / 市购 %s" % h._goods_scaled(market)
		var unit_price = int(material.get("unit_price", 0))
		if unit_price > 0:
			line += " · 单价 %s" % h._money_text(unit_price)
		lines.append(line + "）")
	if not materials.is_empty():
		lines.append("现金：%s" % h._money_text(int(entry.get("cash_required", 0))))
	for raw in materials:
		var material: Dictionary = raw
		var shortfall = int(material.get("market", 0))
		if shortfall <= 0:
			continue
		var good_id = String(material.get("good_id", ""))
		lines.append("现货：%s 现有 %s / 缺口 %s" % [
			String(material.get("name", "建材")),
			host._goods_scaled(int(local_stock.get(good_id, 0))),
			host._goods_scaled(shortfall)])
	var facts = PackedStringArray()
	if not maturity.is_empty():
		facts.append(maturity)
	if days > 0:
		facts.append("工期 %d 日" % days)
	var score = int(entry.get("score", 0))
	if score != 0:
		facts.append("估算毛利 %s/日" % h._money_text(score))
	if not facts.is_empty():
		lines.append("概况：%s" % " · ".join(facts))
	if not reason_text.is_empty():
		lines.append("不满足：%s" % reason_text)
	return "\n".join(lines)



func _construction_job_text(host, job_spec: Dictionary) -> String:
	var h = host
	if not bool(job_spec.get("ok", false)):
		return ""
	var parts = PackedStringArray()
	var owner_slots = int(job_spec.get("owner_slots", 0))
	if owner_slots > 0:
		parts.append("业主 %s ×%d" % [h._construction_profession_name(
			String(job_spec.get("owner_profession", ""))), owner_slots])
	var professions: PackedStringArray = job_spec.get(
		"employee_professions", PackedStringArray())
	var slots: PackedInt64Array = job_spec.get("employee_slots", PackedInt64Array())
	for index in range(professions.size()):
		var role_slots = int(slots[index]) if index < slots.size() else 0
		if role_slots <= 0:
			continue
		parts.append("雇员 %s ×%d" % [h._construction_profession_name(
			String(professions[index])), role_slots])
	return " · ".join(parts)



func _construction_recipe_side(host, rows: Array) -> String:
	var h = host
	if rows.is_empty():
		return ""
	var parts = PackedStringArray()
	for raw in rows:
		var row: Dictionary = raw
		parts.append("%s %s" % [String(row.get("name", "")),
			String(row.get("quantity", ""))])
	return "、".join(parts)



func _goods_scaled(host, value: int) -> String:
	var h = host
	return UITokens.format_compact_number_cn(float(value) / 1000.0, 3)



func _construction_recipe_rows(host, placement: Dictionary, ids_key: String,
		quantities_key: String, label: String) -> Array:
	var h = host
	var rows: Array = []
	var ids: PackedStringArray = placement.get(ids_key, PackedStringArray())
	var quantities: PackedInt64Array = placement.get(quantities_key, PackedInt64Array())
	for index in range(ids.size()):
		var good_id = String(ids[index])
		rows.append({"name": h._good_display_name(good_id),
			"quantity": "%s/日" % h._goods_scaled(quantities[index]) \
				if index < quantities.size() else "—",
			"label": label})
	return rows



func _construction_input_recipe_rows(host, placement: Dictionary,
		unlocked_goods: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var quantities: PackedInt64Array = placement.get("input_quantities", PackedInt64Array())
	for index in range(ids.size()):
		rows.append({
			"name": h._construction_input_candidate_label(placement, index, unlocked_goods),
			"quantity": "%s/日" % h._goods_scaled(quantities[index]) \
				if index < quantities.size() else "—",
			"label": "原材料",
		})
	return rows



func _construction_input_candidate_label(host, placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> String:
	var h = host
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var fallback_id = String(ids[input_idx]) if input_idx >= 0 and input_idx < ids.size() else ""
	var offsets: PackedInt32Array = placement.get(
		"input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = placement.get(
		"input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = placement.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return host._format_input_candidate_label(fallback_id, 65536)
	var entries: Array[Dictionary] = []
	for candidate_idx in range(int(offsets[input_idx]), int(offsets[input_idx + 1])):
		if candidate_idx < 0 or candidate_idx >= candidates.size():
			continue
		entries.append({
			"id": String(candidates[candidate_idx]),
			"efficiency": int(efficiencies[candidate_idx]) \
				if candidate_idx < efficiencies.size() else 65536,
		})
	var enforce = not unlocked_goods.is_empty()
	var visible: Array[Dictionary] = []
	for entry in entries:
		if not enforce or bool(unlocked_goods.get(String(entry.id), false)):
			visible.append(entry)
	if visible.is_empty():
		visible = entries
	if visible.is_empty():
		return host._format_input_candidate_label(fallback_id, 65536)
	visible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left_efficiency = int(a.efficiency)
		var right_efficiency = int(b.efficiency)
		if left_efficiency != right_efficiency:
			return left_efficiency < right_efficiency
		return String(a.id) < String(b.id))
	var labels = PackedStringArray()
	for entry in visible:
		if labels.size() >= 3:
			break
		labels.append(host._format_input_candidate_label(
			String(entry.id), int(entry.efficiency)))
	var text = " / ".join(labels)
	if visible.size() > labels.size():
		text += " 等 %d 种" % visible.size()
	return text



func _unlocked_good_ids(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var available: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var unlocked = {}
	if ids.is_empty() or available.size() != ids.size():
		return unlocked
	for index in range(ids.size()):
		if available[index] != 0:
			unlocked[String(ids[index])] = true
	return unlocked



func _construction_profession_name(host, profession_id: String) -> String:
	var h = host
	if h._generator != null and h._generator.has_method("get_economy_facade"):
		var facade = host._generator.get_economy_facade()
		if facade != null and facade.has_method("profession_display_name"):
			return String(facade.profession_display_name(StringName(profession_id)))
	return profession_id



func _append_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int, kind: String,
		actual_total: int, building_count: int, period_days: int, group_idx: int = -1) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_%s_offsets" % kind, PackedInt32Array())
	var good_indices: PackedInt32Array = snapshot.get("building_%s_good_ids" % kind, PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_%s_quantities" % kind, PackedInt64Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size():
		return
	var begin = int(offsets[type_idx])
	var end = int(offsets[type_idx + 1])
	var recipe_total = 0
	for cursor in range(begin, end):
		recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	var divisor = maxi(1, building_count) * maxi(1, period_days)
	for cursor in range(begin, end):
		var good_idx = int(good_indices[cursor]) if cursor < good_indices.size() else -1
		var stable_id = String(good_ids[good_idx]) if good_idx >= 0 and good_idx < good_ids.size() else "unknown"
		var quantity = int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual = int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var good_label = host._input_candidate_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else h._good_display_name(stable_id)
		var short_good = host._selected_input_short_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else h._good_display_name(stable_id)
		rows.append({
			"id": "%s_%d" % [kind, cursor],
			"name": "%s · %s" % ["原材料" if kind == "input" else "产出", good_label],
			"short_name": "%s · %s" % ["投入" if kind == "input" else "产出", short_good],
			"candidates_detail": good_label if kind == "input" else "",
			"daily_per_building_float": float(actual) / 1000.0 / float(divisor),
			"value": h._actual_daily_rate(actual, building_count, period_days),
			"icon": "resource",
			"accent": UITokens.RESOURCE,
		})



func _selected_input_short_label(host, snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	var h = host
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var selected_offsets: PackedInt32Array = snapshot.get(
		"group_input_selected_offsets", PackedInt32Array())
	var selected_goods: PackedInt32Array = snapshot.get(
		"group_input_selected_good_ids", PackedInt32Array())
	if group_idx >= 0 and group_idx + 1 < selected_offsets.size():
		var selected_idx = int(selected_offsets[group_idx]) + local_input_idx
		if selected_idx >= int(selected_offsets[group_idx]) \
				and selected_idx < int(selected_offsets[group_idx + 1]) \
				and selected_idx < selected_goods.size():
			var selected_good = int(selected_goods[selected_idx])
			if selected_good >= 0 and selected_good < good_ids.size():
				return host._good_display_name(String(good_ids[selected_good]))
	var offsets: PackedInt32Array = snapshot.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidates: PackedInt32Array = snapshot.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	if input_idx >= 0 and input_idx + 1 < offsets.size():
		var first_idx = int(offsets[input_idx])
		var count_cand = int(offsets[input_idx + 1]) - first_idx
		if count_cand > 0 and first_idx >= 0 and first_idx < candidates.size():
			var good_idx = int(candidates[first_idx])
			if good_idx >= 0 and good_idx < good_ids.size():
				var base_name = host._good_display_name(String(good_ids[good_idx]))
				return "%s等" % base_name if count_cand > 1 else base_name
	return host._good_display_name(fallback_id)



func _input_candidate_label(host, snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	var h = host
	var offsets: PackedInt32Array = snapshot.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidates: PackedInt32Array = snapshot.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var efficiencies: PackedInt32Array = snapshot.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return host._good_display_name(fallback_id)
	var labels = PackedStringArray()
	for candidate_idx in range(offsets[input_idx], offsets[input_idx + 1]):
		var good_idx = int(candidates[candidate_idx]) if candidate_idx < candidates.size() else -1
		if good_idx < 0 or good_idx >= good_ids.size():
			continue
		var efficiency = int(efficiencies[candidate_idx]) if candidate_idx < efficiencies.size() else 65536
		labels.append(host._format_input_candidate_label(String(good_ids[good_idx]), efficiency))
	var candidate_label = " / ".join(labels) \
		if not labels.is_empty() else host._good_display_name(fallback_id)
	var selected_offsets: PackedInt32Array = snapshot.get(
		"group_input_selected_offsets", PackedInt32Array())
	var selected_goods: PackedInt32Array = snapshot.get(
		"group_input_selected_good_ids", PackedInt32Array())
	if group_idx >= 0 and group_idx + 1 < selected_offsets.size():
		var selected_idx = int(selected_offsets[group_idx]) + local_input_idx
		if selected_idx >= int(selected_offsets[group_idx]) \
				and selected_idx < int(selected_offsets[group_idx + 1]) \
				and selected_idx < selected_goods.size():
			var selected_good = int(selected_goods[selected_idx])
			if selected_good >= 0 and selected_good < good_ids.size():
				candidate_label += "（当前：%s）" % h._good_display_name(String(good_ids[selected_good]))
	return candidate_label



func _append_resource_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_resource_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_production_resource_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = snapshot.get("building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = snapshot.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var resource_ids: PackedStringArray = snapshot.get("building_resource_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size(): return
	var begin = int(offsets[type_idx])
	var end = int(offsets[type_idx + 1])
	var recipe_total = 0
	for cursor in range(begin, end): recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var resource_idx = int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var stable_id = String(resource_ids[resource_idx]) if resource_idx >= 0 and resource_idx < resource_ids.size() else "unknown"
		var quantity = int(quantities[cursor]) if cursor < quantities.size() else 0
		var mode = int(modes[cursor]) if cursor < modes.size() else 0
		var access_mode = int(access_modes[cursor]) if cursor < access_modes.size() else 0
		var actual = int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var access_label = "邻域 · " if access_mode == 1 else ""
		var row_name = "自然资源 · %s%s" % [access_label, h._resource_display_name(stable_id)]
		var availability = "不足" if h._building_resource_depleted(snapshot, type_idx) else "充足"
		var row_value = "每栋 %.3f · %s" % [float(quantity) / 1000.0, availability] if mode == 1 \
			else "%s · %s" % [h._actual_daily_rate(actual, building_count, period_days), availability]
		rows.append({"id": "natural_input_%d" % cursor,
			"name": row_name,
			"value": row_value,
			"icon": "eco", "accent": UITokens.ECO})



func _append_resource_generation_rows(host, rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_resource_generation_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_resource_generation_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_resource_generation_quantities", PackedInt64Array())
	var resource_ids: PackedStringArray = snapshot.get("building_resource_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size(): return
	var begin = int(offsets[type_idx])
	var end = int(offsets[type_idx + 1])
	var recipe_total = 0
	for cursor in range(begin, end): recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var resource_idx = int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var stable_id = String(resource_ids[resource_idx]) if resource_idx >= 0 and resource_idx < resource_ids.size() else "unknown"
		var quantity = int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual = int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		rows.append({"id": "natural_generation_%d" % cursor,
			"name": "培育 · %s" % h._resource_display_name(stable_id),
			"value": "%s · 待资源周期生效" % h._actual_daily_rate(actual, building_count, period_days),
			"icon": "growth", "accent": UITokens.GOOD})



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
	var h = host
	var types: PackedInt32Array = snapshot.get("construction_type_ids", PackedInt32Array())
	var owners: PackedInt32Array = snapshot.get("construction_owner_signature_ids", PackedInt32Array())
	var counts: PackedInt64Array = snapshot.get("construction_counts", PackedInt64Array())
	var ready_days: PackedInt64Array = snapshot.get("construction_ready_days", PackedInt64Array())
	for i in range(types.size()):
		var type_idx = int(types[i])
		var building_id = String(type_ids[type_idx]) \
			if type_idx >= 0 and type_idx < type_ids.size() else ""
		rows.append({"id": "construction_%d_%d" % [type_idx, i], "name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (building_id if not building_id.is_empty() else "建筑"), "building_type_id": building_id, "count": "%d" % (int(counts[i]) if i < counts.size() else 0), "owner": "业主 · %s" % h._owner_profession_name(snapshot, int(owners[i]) if i < owners.size() else -1), "status": "建造中 · 第 %d 日完工" % (int(ready_days[i]) if i < ready_days.size() else 0), "profit": "—", "profit_label": "未投产", "accent": UITokens.WARN, "icon": h._building_icon(building_id, snapshot, type_idx), "job_rows": [], "production_rows": [], "finance": {}, "visible": true})



func _building_icon(host, type_id: String, snapshot: Dictionary = {}, type_idx: int = -1) -> StringName:
	var h = host
	if type_id.is_empty():
		return &"economy.building"
	var output_offsets: PackedInt32Array = snapshot.get(
		"building_output_offsets", PackedInt32Array())
	var output_good_indices: PackedInt32Array = snapshot.get(
		"building_output_good_ids", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var kinds: PackedInt32Array = snapshot.get("building_kinds", PackedInt32Array())
	if type_idx >= 0 and type_idx + 1 < output_offsets.size():
		var output_pos = int(output_offsets[type_idx])
		if output_pos < int(output_offsets[type_idx + 1]) \
				and output_pos >= 0 and output_pos < output_good_indices.size():
			var good_idx = int(output_good_indices[output_pos])
			if good_idx >= 0 and good_idx < good_ids.size():
				var kind = int(kinds[type_idx]) if type_idx < kinds.size() else 1
				return IconCatalog.building_semantic(type_id, good_ids[good_idx], kind)
	if type_id.contains("hearth"):
		return &"economy.building.hearth"
	if type_id.contains("gathering"):
		return &"economy.building.gathering"
	if type_id.contains("merchant") or type_id.contains("market") \
			or type_id.contains("trade"):
		return &"economy.building.market"
	if type_id.contains("fish"):
		return &"economy.building.fishing"
	if type_id.contains("hunting"):
		return &"economy.building.hunting"
	if type_id.contains("kitchen") or type_id.contains("food") \
			or type_id.contains("slaughterhouse"):
		return &"economy.building.food"
	if type_id.contains("farm") or type_id.contains("estate") \
			or type_id.contains("pasture") or type_id.contains("rice") \
			or type_id.contains("potato") or type_id.contains("wheat") \
			or type_id.contains("cotton") or type_id.contains("flax") \
			or type_id.contains("rubber_tree") or type_id.contains("spice") \
			or type_id.contains("herbs"):
		return &"economy.building.farm"
	if type_id.contains("timber") or type_id.contains("lumber"):
		return &"economy.building.forestry"
	if type_id.contains("mine") or type_id.contains("ore_") \
			or type_id.contains("quarry") or type_id.contains("stone_collector") \
			or type_id.contains("coal") or type_id.contains("oil_collector") \
			or type_id.contains("natural_gas") or type_id.contains("bauxite") \
			or type_id.contains("limestone") or type_id.contains("silica") \
			or type_id.contains("phosphate") or type_id.contains("salt") \
			or type_id.contains("sulfur") or type_id.contains("rare_earth") \
			or type_id.contains("flint"):
		return &"economy.building.mine"
	if type_id.contains("power"):
		return &"economy.building.power"
	if type_id.contains("shipyard"):
		return &"economy.building.shipyard"
	if type_id.contains("rail"):
		return &"economy.building.transport"
	if type_id.contains("scientific") or type_id.contains("medicine") \
			or type_id.contains("pharmaceutical"):
		return &"economy.building.science"
	if type_id.contains("workshop") or type_id.contains("kiln") \
			or type_id.contains("smith") or type_id.contains("tailor") \
			or type_id.contains("tannery") or type_id.contains("scriptorium"):
		return &"economy.building.workshop"
	if type_id.contains("plant") or type_id.contains("works") \
			or type_id.contains("mill") or type_id.contains("factory"):
		return &"economy.building.factory"
	if type_id.contains("school") or type_id.contains("hospital") \
			or type_id.contains("office"):
		return &"economy.building.service"
	return &"economy.building"



func _owner_profession_name(host, snapshot: Dictionary, signature_idx: int) -> String:
	var h = host
	var signature_professions: PackedInt32Array = snapshot.get("signature_profession_ids", PackedInt32Array())
	return host._profession_name(snapshot, int(signature_professions[signature_idx]) if signature_idx >= 0 and signature_idx < signature_professions.size() else -1)



func _profession_name(host, snapshot: Dictionary, profession_idx: int) -> String:
	var h = host
	var names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	if profession_idx >= 0 and profession_idx < names.size(): return String(names[profession_idx])
	return String(ids[profession_idx]) if profession_idx >= 0 and profession_idx < ids.size() else "未知阶层"



func _format_input_candidate_label(host, good_id: String, efficiency_q16: int) -> String:
	var h = host
	var label = host._good_display_name(good_id)
	if efficiency_q16 != 65536:
		label += " %.0f%%" % (float(efficiency_q16) * 100.0 / 65536.0)
	return label



func _good_display_name(host, stable_id: String) -> String:
	var h = host
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	return String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id



func _resource_display_name(host, stable_id: String) -> String:
	var h = host
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) == stable_id:
			return String(profile.display_name) if String(profile.display_name) != "" else stable_id
	return stable_id



func _fill_percent(host, filled: int, required: int) -> float:
	var h = host
	return float(filled) * 100.0 / float(required) if required > 0 else 100.0



func _actual_daily_rate(host, actual_total: int, building_count: int, period_days: int) -> String:
	var h = host
	var divisor = maxi(1, building_count) * maxi(1, period_days)
	return "%s 单位/栋/日" % UITokens.format_compact_number_cn(float(actual_total) / 1000.0 / float(divisor), 3)



func _sum_i64(host, values: PackedInt64Array) -> int:
	var h = host
	var total = 0
	for value in values:
		total += int(value)
	return total



func _money_text(host, subunits: int) -> String:
	var h = host
	if subunits != 0 and absi(subunits) < 100:
		return "%.4f" % (float(subunits) / h.MONEY_SCALE)
	return UITokens.format_compact_number_cn(float(subunits) / host.MONEY_SCALE, 2)



func _goods_unit_text(host, subunits: int) -> String:
	var h = host
	return "%s 单位" % UITokens.format_compact_number_cn(float(maxi(0, subunits)) / 1000.0, 2)



func _packed_i64_at(host, values: PackedInt64Array, index: int) -> int:
	var h = host
	return int(values[index]) if index >= 0 and index < values.size() else 0



func _market_trade_enabled(host, enabled: PackedByteArray, index: int) -> bool:
	var h = host
	if enabled.is_empty() or index < 0 or index >= enabled.size():
		return true
	return enabled[index] != 0



func _trade_arrival_days(host, next_arrival_day: int, sample_day: int) -> int:
	var h = host
	if next_arrival_day < 0:
		return -1
	return maxi(0, next_arrival_day - sample_day)



func _market_trade_insight_text(host, in_transit_kinds: int, arrival_days: int) -> String:
	var h = host
	if arrival_days < 0:
		return "%d 种物资在途。" % in_transit_kinds
	if arrival_days == 0:
		return "%d 种物资在途，下一批今日到货。" % in_transit_kinds
	return "%d 种物资在途，下一批还有 %d 日到货。" % [in_transit_kinds, arrival_days]



func _cashflow_source_name(host, source_id: String, income: bool) -> String:
	var h = host
	match source_id:
		"wages": return "工资"
		"owner_operations": return "业主经营"
		"merchant_household_sales": return "居民销售"
		"merchant_business_sales": return "产业供货"
		"transfer": return "转移支付"
		"household_consumption": return "生活消费"
		"production_inputs": return "生产原料"
		"owner_wages": return "雇员工资"
		"construction": return "建设"
		"merchant_procurement": return "商品收购"
		"producer_support_issuance": return "托底收购"
		"income_tax": return "所得税"
		"consumption_tax": return "交易税"
		"business_tax": return "营业税"
		"income_subsidy": return "收入补贴"
		"consumption_subsidy": return "消费补贴"
		"business_subsidy": return "经营补贴"
		"fiscal_escrow": return "财政托管"
		_: return "其他收入" if income else "其他支出"



func _has_cashflow_row(host, rows: Array, source_id: String) -> bool:
	var h = host
	for row_value in rows:
		if row_value is Dictionary and String((row_value as Dictionary).get("id", "")) == \
			("income_" + source_id if String((row_value as Dictionary).get("id", "")).begins_with("income_") else "expense_" + source_id):
			return true
	return false
