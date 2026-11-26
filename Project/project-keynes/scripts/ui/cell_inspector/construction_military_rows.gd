extends RefCounted

## Projects published military building data into the construction list.

## 军事目录规模：只读缓存里的行数，不读国库/市场、不算成本。部门计数与
## 营造入口的「目录 N 项」用它，避免为了一个数字把 17 座建筑的成本全算一遍。
## 口径必须与民用部门一致：科技未解锁的条目不进目录（见
## docs/ui/building-workspace.md §5）。否则部门签写「17 项」、点进去却只有
## 开局那一档，和民用部门的行为也对不上。

static func _construction_military_count(host, ) -> int:
	var h = host
	var facade = host._military_facade()
	if facade == null:
		return 0
	var rows: Array = h._military_catalog_cache(facade).get("buildings", [])
	var researched = host.player_technology_ids()
	var gate_known = host._technology_ids_resolved
	var count = 0
	for raw in rows:
		if raw is Dictionary and host._Military_delegate._state_building_unlocked(host, raw, researched, gate_known):
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

static func _construction_military_rows(host, cell_idx: int, search: String) -> Array:
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
	var can_build = host._Military_delegate._military_can_build(host, snapshot, host._Overview_delegate._country_summary(host, cell_idx))
	var cash = host._country_cash() if can_build else -1
	# 库存与市场各读一次：17 座建筑共用，避免逐行重复拉国库与市场快照。
	var treasury_stock = host._Military_delegate._treasury_good_stock(host) if can_build else {}
	var market_stock = host._Construction_delegate._construction_local_stock(host, host._Overview_delegate._market_snapshot(host, cell_idx)) \
		if can_build else {}
	var occupied = host._Construction_delegate._construction_military_occupied(host, catalog_rows, snapshot)
	var query = search.strip_edges().to_lower()
	var rows: Array = []
	for index in range(catalog_rows.size()):
		var row: Dictionary = catalog_rows[index]
		# 与经济部门同口径：科技未解锁的条目在目录层直接剔除，不进列表
		# （民用部门由 building_technology_available 过滤，见 §5）。
		# 科技快照不可读时保留「宁可见不误藏」的既有兜底，命令层还会再拦一次。
		if not host._Military_delegate._state_building_unlocked(host, row, researched, gate_known):
			continue
		var name = String(row.get("name", row.get("id", ""))).strip_edges()
		if not query.is_empty() and name.to_lower().find(query) < 0 \
				and String(row.get("id", "")).to_lower().find(query) < 0:
			continue
		rows.append(host._Construction_delegate._construction_military_row(host, facade, index, row, snapshot,
			researched, gate_known, can_build, cash, cell_idx, occupied,
			treasury_stock, market_stock))
	return rows


## 这一格已建成的档位：兵营按档累加（`barracks_count[tier]` 是计数数组），
## 城防/军校在原生侧只保留最高档（military_core.cpp:3287 用 std::max 覆盖）。
## 因此「该档已建成」只能用来拦城防/军校：兵营同档再建是有效操作，兵额会叠加。

static func _construction_military_occupied(host, catalog_rows: Array, snapshot: Dictionary) -> Dictionary:
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

static func _construction_military_row(host, facade, index: int, row: Dictionary,
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
	var effect = host._Military_delegate._state_building_effect(host, role_id, row, disrepair)
	var cost = host._Military_delegate._empty_state_building_cost(host)
	if can_build:
		cost = host._Military_delegate._state_building_cost(host, facade, index, row, cash, cell_idx,
			treasury_stock, market_stock)
	var unlocked = host._Military_delegate._state_building_unlocked(host, row, researched, gate_known)
	var pending = host._Construction_delegate._state_building_pending_by_index(host, snapshot, index)
	# 可建判定与地块档案那一行同序：科技 -> 施工位 -> 该档已存在 -> 建材/现金。
	# 顺序决定玩家先看到「差科技」而不是「缺钱」，因为科技是更硬的闸门。
	# 兵营例外：原生 `barracks_count[tier]` 是计数数组，同档再建会叠加兵额。
	var reason = ""
	var eligible = false
	if not can_build:
		reason = host._Construction_delegate._construction_military_block_text(host, snapshot)
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
			tooltip_lines.append("受阻：%s" % reason)
	else:
		tooltip_lines.append("受阻：%s" % reason)
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
		"materials_text": materials_text,
		"days": int(cost.get("build_days", 0)),
		"cash_required": cash_required,
		"cash_text": h._money_text(cash_required) if cash_required > 0 else "",
		"market_used": 0,
		"material_status": host._Construction_delegate._construction_material_status_rows(host,
			cost.get("materials", []), market_stock),
		"cash_blocked": String(cost.get("reason_code", ""))
			== "construction_treasury_cash_insufficient",
		"tooltip": "\n".join(tooltip_lines),
	}


## 不可建的具体原因：驻军格已被外人占领与「不是自家地」对玩家是两件事，
## 而「读不到归属」又不该被说成「不是你的地」。三者分开写。

static func _construction_military_block_text(host, snapshot: Dictionary) -> String:
	var h = host
	var owner_slot = int(snapshot.get("owner_slot", -1))
	if owner_slot < 0:
		return "无主之地"
	if int(snapshot.get("controller_slot", -1)) != owner_slot:
		return "领土被占领"
	return "非本国领土"


## 该建筑是否正在这一格的施工位里（原生 3 个施工位），返回剩余天数，-1 = 不在建。

static func _state_building_pending_by_index(host, snapshot: Dictionary, index: int) -> int:
	var h = host
	var built = snapshot.get("construction_buildings", null)
	if not built is PackedInt32Array:
		return -1
	var done = snapshot.get("construction_done_days", null)
	var done_days: PackedInt32Array = done if done is PackedInt32Array \
		else PackedInt32Array()
	var today = host._Geography_delegate._current_sample_day(host)
	for slot in range((built as PackedInt32Array).size()):
		if int((built as PackedInt32Array)[slot]) != index:
			continue
		if slot < done_days.size() and int(done_days[slot]) >= 0:
			return maxi(0, int(done_days[slot]) - today)
		return 0
	return -1


## 军事部门的一页：排序（可建优先）+ 分页，字段与经济部门完全一致。

static func _construction_military_page(host, model: Dictionary, rows: Array,
		sort: String, requested_offset: int) -> Dictionary:
	var h = host
	var sorted_rows = rows.duplicate()
	sorted_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return CellInspectorViewModel._Construction._construction_military_before(a, b, sort))
	var total = sorted_rows.size()
	var safe_offset = requested_offset
	if safe_offset >= total:
		safe_offset = 0
	model["offset"] = safe_offset
	model["query"]["offset"] = safe_offset
	model["total"] = total
	model["page_label"] = h._Construction_delegate._construction_page_label(h, safe_offset,
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
