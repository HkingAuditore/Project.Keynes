extends RefCounted

## Builds military spending and diplomacy views from committed country data.


static func build_military_model(owner: CountryViewModel, country_handle: int, model: Dictionary) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var facade = null
	if owner._generator != null and owner._generator.has_method("get_military_facade"):
		facade = owner._generator.get_military_facade()
	var section := {
		"available": false,
		"reason": "先在领地建立军事机构，才能查看军情。",
		"facade": facade,
		"country_handle": country_handle,
		# 视图模型按国家槽位反查邻国/句柄/名称都要经过会话世界（领土镜像 + Country
		# facade）。缺了它 `session_bound()` 恒为 false，战争页的邻国表就永远是空的。
		"generator": owner._generator,
		"map": owner._map,
		# 兵营行、训练行与割地表都要写地块名。名字的权威在 Economy 的具名聚落，
		# 这里一次装进段里：`MilitaryViewModel.cell_name()` 就不用自己再查原生，
		# 面板也不至于因为拿不到名字而写「未命名地块」。
		"cell_names": owner._cell_name_table(),
	}
	if facade == null:
		model["military"] = section
		return section
	if facade.has_method("is_configured") and not bool(facade.call("is_configured")):
		var missing := String(facade.call("missing_api_reason")) \
			if facade.has_method("missing_api_reason") else ""
		section["reason"] = "军事机构尚未就绪" if missing.is_empty() \
			else "军事机构尚未就绪（%s）" % missing
		model["military"] = section
		return section
	if facade.has_method("catalog") and owner._military_catalog_facade != facade:
		owner._military_catalog_facade = facade
		owner._military_catalog_cache = {}
	var catalog: Dictionary = owner._military_catalog_cache
	if catalog.is_empty() and facade.has_method("catalog"):
		catalog = facade.call("catalog")
		if catalog is Dictionary and bool(catalog.get("ok", false)):
			owner._military_catalog_cache = catalog
	var snapshot: Dictionary = {}
	if facade.has_method("country_snapshot"):
		snapshot = facade.call("country_snapshot", country_handle)
		if not snapshot is Dictionary:
			snapshot = {}
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		var raw_reason := String(snapshot.get("reason", "")) if snapshot is Dictionary else ""
		section["reason"] = "军事数据暂不可用" if raw_reason.is_empty() \
			else "军事数据暂不可用（%s）" % raw_reason
		model["military"] = section
		return section
	var armies: Array = []
	if facade.has_method("armies"):
		var fetched = facade.call("armies", country_handle)
		armies = fetched if fetched is Array else []
	var view: Dictionary = {}
	if facade.has_method("catalog_view"):
		var fetched_view = facade.call("catalog_view")
		view = fetched_view if fetched_view is Dictionary else {}
	# 目录显示名（military_catalog.json）与原生 dense 目录合并：原生给 dense id
	# 与数值，GDScript 目录给玩家读的名字。
	var merged_catalog := owner._merge_military_catalog(catalog, view)
	# 兵种解锁闸门：原生目录每行有 unlock_bit，国家快照有已研究科技稳定 id。
	# snapshot 不可用时 gate 标记为未知，面板据此不过滤（宁可见全目录也不误藏）。
	var researched := PackedStringArray()
	var gate_known := false
	var country_facade = model.get("country_facade", null)
	if country_facade != null and country_facade.has_method("snapshot"):
		var country_snapshot = country_facade.call("snapshot", country_handle)
		if country_snapshot is Dictionary and bool((country_snapshot as Dictionary).get("ok", false)):
			var ids = (country_snapshot as Dictionary).get("technology_ids", null)
			if ids is PackedStringArray:
				researched = ids
				gate_known = true
	section = {
		"available": true,
		"facade": facade,
		"country_handle": country_handle,
		"snapshot": snapshot,
		"armies": armies,
		"catalog": merged_catalog,
		"researched_tech_ids": researched,
		"tech_gate_known": gate_known,
		"generator": owner._generator,
		"map": owner._map,
		# 名字表必须跟着这条主路径一起交出去：兵营行、训练行与割地表都读它。
		"cell_names": owner._cell_name_table(),
		"query_ms": (Time.get_ticks_usec() - started_usec) / 1000.0,
	}
	# 财政页的军事只读实付板块。原生只给 30 日滑窗累计，这里统一折成日均，
	# 三个通道口径相同（否则玩家会把 30 日总额当成一天的花销）。
	section.merge(CountryViewModel.military_spending_model(snapshot,
		owner._military_maintenance_model(facade, country_handle)), true)
	model["military"] = section
	return section


## 地块名表（cell -> 具名聚落名），供军事面板写兵营行、训练行与割地表。
##
## 名字的权威在 Economy：`named_settlement_snapshot()` 给「哪些格有名字、叫什么」，
## `settlement_delta(since)` 给增量。这里按 revision 缓存：名字没变时每次刷新只是一次
## 空读；首次或 revision 跳变（含 `full_snapshot`）才重扫一遍。读失败（worker 忙、
## 旧 DLL）时保留上一份，面板退回地区名而不是整列变空。
##
## 只收 `name_active != 0` 且名字非空的格：未命名的聚落行在原生里也带一串占位名，
## 写进面板会比没有名字更糟。
static func _cell_name_table(owner: CountryViewModel) -> Dictionary:
	if owner._generator == null or not owner._generator.has_method("get_economy_facade"):
		return owner._cell_names
	var economy = owner._generator.get_economy_facade()
	if economy == null or not economy.has_method("settlement_delta"):
		return owner._cell_names
	var delta = economy.call("settlement_delta", owner._cell_names_revision)
	if not (delta is Dictionary) or not bool((delta as Dictionary).get("ok", false)):
		return owner._cell_names
	var rows: Dictionary = delta
	var revision := int(rows.get("revision", owner._cell_names_revision))
	if revision == owner._cell_names_revision:
		return owner._cell_names
	if bool(rows.get("full_snapshot", false)):
		owner._cell_names.clear()
	var cells = rows.get("cell_indices", PackedInt32Array())
	var names = rows.get("settlement_names", PackedStringArray())
	var active = rows.get("name_active", PackedByteArray())
	if cells is PackedInt32Array and names is PackedStringArray:
		var count := mini((cells as PackedInt32Array).size(), (names as PackedStringArray).size())
		for index in range(count):
			var cell := int((cells as PackedInt32Array)[index])
			if cell < 0:
				continue
			var named := not (active is PackedByteArray) or index >= (active as PackedByteArray).size() \
				or int((active as PackedByteArray)[index]) != 0
			var label := String((names as PackedStringArray)[index]).strip_edges()
			if named and not label.is_empty():
				owner._cell_names[cell] = label
			else:
				owner._cell_names.erase(cell)
	owner._cell_names_revision = revision
	return owner._cell_names


## 财政（国库）章的军事支出段。
##
## 国库页只画三条通道的实付与信封读数（军饷 / 建筑维护 / 装备与给养采购），需要的
## 输入就是 `military_spending_model` 的两项：国家槽快照 + 实物维护明细。整份军事
## 模型（部队、目录、科技闸门、逐格快照）属于军事章；把它装进经济章等于每次刷新
## 国库页都多读三份原生数据，只为一段根本读不到的字段付钱。
##
## 关键点：经济章的模型以前**完全没有** `military` 这个键，于是财政页拿到空字典，
## 军事板块永远显示「暂不可用 / 军事账目尚未就绪」（2026-11-20 玩家截图里的红框）。
## 这里产出的键集合与 `military_spending_model` 完全一致，所以财政页不必区分
## 「经济章的军事段」与「军事章的军事段」。
static func build_military_spending_model(owner: CountryViewModel, country_handle: int, model: Dictionary) -> Dictionary:
	var facade = null
	if owner._generator != null and owner._generator.has_method("get_military_facade"):
		facade = owner._generator.get_military_facade()
	var section := {
		"available": false,
		"reason": "军事机构尚未接通，军费账目暂不可读。",
		"facade": facade,
		"country_handle": country_handle,
	}
	if facade != null and facade.has_method("country_snapshot"):
		var fetched = facade.call("country_snapshot", country_handle)
		var snapshot: Dictionary = fetched if fetched is Dictionary else {}
		if bool(snapshot.get("ok", false)):
			var spending := CountryViewModel.military_spending_model(snapshot,
				owner._military_maintenance_model(facade, country_handle))
			section["available"] = bool(spending.get("available", false))
			section["reason"] = ""
			section.merge(spending, true)
			if not bool(section.get("available", false)):
				# 快照正常但没有国家政策槽：原生还没为这个国家开军事账。
				section["reason"] = "军务政策尚未建立，军费账目暂不可读。"
		elif not String(snapshot.get("reason", "")).is_empty():
			section["reason"] = "军事数据暂不可用（%s）" % String(
				snapshot.get("reason", ""))
	model["military"] = section
	return section


## 维护实物化（docs/plans/military-physical-maintenance.md D7 / S4-6）的模型入口。
##
## 两次门面调用（`maintenance_summary()` + `maintenance_snapshot()`）共享 facade 的
## 整形缓存，同一刷新里原生只读一次。旧 DLL 没有这个方法 → `supported = false`，
## 面板写「实物维护未接通」，不再拿现金口径冒充维护。
static func _military_maintenance_model(owner: CountryViewModel, facade, country_handle: int) -> Dictionary:
	if facade == null or not facade.has_method("maintenance_supported"):
		return {"supported": false}
	if not bool(facade.call("maintenance_supported")):
		return {"supported": false}
	var summary = facade.call("maintenance_summary", country_handle)
	var rows = facade.call("maintenance_snapshot", country_handle)
	return {
		"supported": true,
		"summary": summary if summary is Dictionary else {},
		"rows": rows if rows is Array else [],
	}


## 军事支出视图（财政页只读板块用）。输入 `get_military_country_snapshot` 的
## 原始快照，输出三个通道的日均实付与招募集训的等待装备计数。
##
## `maintenance` 是维护实物化的模型（见 `_military_maintenance_model`）：`supported`、
## `summary`（聚合整数）与 `rows`（逐对象明细）。缺省 `{}` 表示「旧 DLL，没有实物维护」，
## 此时只多一个 `maintenance_is_physical = true` 的语义标记，其余维护键全 0/空。
##
## 招募本身不拨预算：这一点由 `recruitment_funded = false` 明确表达，
## 面板据此把招募行标成「不拨款」，而不是显示 0。
static func military_spending_model(snapshot: Dictionary,
		maintenance: Dictionary = {}) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"available": false}
	if not bool(snapshot.get("has_policy", false)):
		return {"available": false}
	# 30 日滑窗累计 ÷ 30。整除而非四舍五入：上报的是"至少花了这么多"。
	var payroll_30 := maxi(0, int(snapshot.get("spend_payroll_30", 0)))
	var upkeep_30 := maxi(0, int(snapshot.get("spend_upkeep_30", 0)))
	var procurement_30 := maxi(0, int(snapshot.get("spend_procurement_30", 0)))
	# 训练队列里还没拿到装备的兵：这就是"已排队但还在等"的装备需求。
	var waiting_equipment := 0
	var training_rows: Array = snapshot.get("training", [])
	if training_rows is Array:
		for row_value in training_rows:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			if bool(row.get("equipment_ready", false)):
				continue
			waiting_equipment += maxi(0, int(row.get("count", 0)))
	# ---- 维护实物化：满足率/失修/短缺由原生按 (国家, 地块, 类型) 判定 ----
	var maintenance_supported := bool(maintenance.get("supported", false))
	var summary: Dictionary = maintenance.get("summary", {}) \
		if maintenance.get("summary", null) is Dictionary else {}
	var maintenance_rows := CountryViewModel.maintenance_detail_rows(maintenance.get("rows", []))
	return {
		"available": true,
		"wage_paid_last_period": payroll_30 / 30,
		"maintenance_paid_last_period": upkeep_30 / 30,
		"procurement_paid_last_period": procurement_30 / 30,
		"wage_paid_window": payroll_30,
		"maintenance_paid_window": upkeep_30,
		"procurement_paid_window": procurement_30,
		"window_days": 30,
		"procurement_share_bp": clampi(
			int(snapshot.get("procurement_share_bp", 0)), 0, 10000),
		"waiting_equipment": waiting_equipment,
		"soldiers_training": maxi(0, int(snapshot.get("soldiers_training", 0))),
		# 招募与训练本身不领取军事预算：预算只覆盖军饷、维护与采购。
		"recruitment_funded": false,
		# ---- 预算信封（任务 6/7/8 的原生字段，任务 9 的可编辑 UI 直接消费）----
		# `envelope_enabled == false` 是「没有信封」：三个日额是 -1 而不是 0，
		# 表示"不设上限、跟随现金"，与"份额为 0 暂停该通道"是相反的语义。
		"envelope_enabled": bool(snapshot.get("budget_enabled", false)),
		"budget_share_bp": clampi(int(snapshot.get("budget_share_bp", 0)), 0, 10000),
		"budget_wage_bp": clampi(int(snapshot.get("budget_wage_bp", 6000)), 0, 10000),
		"budget_upkeep_bp": clampi(int(snapshot.get("budget_upkeep_bp", 2000)), 0, 10000),
		"budget_procurement_bp": clampi(
			int(snapshot.get("procurement_share_bp", 2000)), 0, 10000),
		"envelope_daily": int(snapshot.get("budget_envelope_daily", 0)),
		"wage_budget_daily": int(snapshot.get("budget_wage_daily", -1)),
		"upkeep_budget_daily": int(snapshot.get("budget_upkeep_daily", -1)),
		"procurement_budget_daily": int(snapshot.get("budget_procurement_daily", -1)),
		# ---- 上一轮结算结果（任务 7/8）----
		# 军饷与维护是高优先级：超支是允许的，用 `*_overspend` 画铁锈红。
		# 采购是低优先级：绝不超支，被配额截断的部分在 `procurement_deferred_units`
		# 里，面板用「待购」而不是「超支」标示。
		"wage_demand": maxi(0, int(snapshot.get("budget_wage_demand", 0))),
		"wage_arrears": maxi(0, int(snapshot.get("budget_wage_arrears", 0))),
		"wage_overspend": maxi(0, int(snapshot.get("budget_wage_overspend", 0))),
		"upkeep_demand": maxi(0, int(snapshot.get("budget_upkeep_demand", 0))),
		"upkeep_arrears": maxi(0, int(snapshot.get("budget_upkeep_arrears", 0))),
		"upkeep_overspend": maxi(0, int(snapshot.get("budget_upkeep_overspend", 0))),
		"procurement_used": maxi(0, int(snapshot.get("budget_procurement_used", 0))),
		"procurement_deferred_units": maxi(0,
			int(snapshot.get("budget_procurement_deferred_units", 0))),
		# ---- 维护实物化（D7 / S4-6）----
		# 「维护」通道从此描述**实物维修采购**：国库付给商人换维修材料，材料到货后
		# 才计入满足率。`maintenance_paid_last_period` 仍是「实际结算的维护花费」
		# （30 日窗口 ÷ 30），来源不变；下面这组键描述的是这笔钱买到的实物结果。
		"maintenance_is_physical": true,
		"maintenance_supported": maintenance_supported,
		"maintenance_ratio_bp": clampi(
			int(summary.get("weighted_ratio_bp", 0)), 0, 10000),
		"maintenance_disrepair_rows": maxi(0, int(summary.get("disrepair_rows", 0))),
		"maintenance_shortage_rows": maxi(0, int(summary.get("shortage_rows", 0))),
		"maintenance_object_rows": maxi(0, int(summary.get("rows", 0))),
		"maintenance_need_goods": maxi(0, int(summary.get("need_goods", 0))),
		"maintenance_stock_goods": maxi(0, int(summary.get("stock_goods", 0))),
		"maintenance_inbound_goods": maxi(0, int(summary.get("inbound_goods", 0))),
		# 逐对象明细（已按短缺优先排序）。面板只画前 N 条，但整表留在这里，
		# 「为什么是 0 座失修」这类追问不用再去查原生。
		"maintenance_rows": maintenance_rows,
		# 一行摘要的变更签名：维护读数天天变，财政页的节流比较需要它。
		"maintenance_signature": CountryViewModel.maintenance_signature(maintenance_rows, summary),
	}


## 逐对象明细的展示投影。原生行保留 `*_goods` / `*_bp` / `*_x10` 后缀（毫单位、
## 万分比、十分之一日），这里改成面板读得懂的短键，并附上整数换算好的文本。
## 口径不变：`need` / `stock` / `inbound` 仍是 GOODS_SCALE，`ratio` 仍是万分比，
## `days_cover` 仍是「十分之一日」（-1 = 无需求）。
static func maintenance_detail_rows(rows) -> Array:
	return CountryViewModel.MaintenancePresentation.maintenance_detail_rows(rows)


## GOODS_SCALE（1000）毫单位 → 一位小数的纯整数文本。「—」表示没有量，
## 不是 0：维护行里 0 和「没有需求」是两件事。
static func goods_text(milli: int) -> String:
	return CountryViewModel.MaintenancePresentation.goods_text(milli)


## 可用天数（十分之一日，-1 = 无需求）→ 「3.5 日」。整数运算，不用浮点。
static func cover_days_text(days_cover_x10: int) -> String:
	return CountryViewModel.MaintenancePresentation.cover_days_text(days_cover_x10)


## 明细 + 汇总的变更签名。只取整数与短串，不给每帧比较造大字符串。
static func maintenance_signature(rows: Array, summary: Dictionary) -> int:
	return CountryViewModel.MaintenancePresentation.maintenance_signature(rows, summary)


## 外交章的模型。它自己不算任何东西：名单、档案与战事都由 DiplomacyViewModel 从
## 「已提交的国家壳 + 领土镜像 + 军事快照」里算。这里只把这条通路上要用的几个
## 句柄交出去，并保证军事段已经装好（战事与割地候选复用同一份快照）。
static func build_diplomacy_model(owner: CountryViewModel, country_handle: int, model: Dictionary, facade) -> Dictionary:
	var military: Dictionary = model.get("military", {})
	var section := {
		"available": true,
		"reason": "",
		"generator": owner._generator,
		"map": owner._map,
		"country_facade": facade,
		"military_facade": military.get("facade", null),
		"country_handle": country_handle,
		"day": int(model.get("current_day", -1)),
		"military_available": bool(military.get("available", false)),
		"military_reason": String(military.get("reason", "")),
	}
	model["diplomacy"] = section
	return section


## 「外交一起不可用」的兜底段：国家壳都没就绪时也要给外交面板一个可读原因。
static func _unavailable_diplomacy_section(owner: CountryViewModel, reason: String) -> Dictionary:
	return {
		"available": false,
		"reason": "外交档案暂不可用（%s）" % reason if not reason.is_empty()
			else "外交档案暂不可用",
		"country_facade": null,
		"military_facade": null,
		"country_handle": 0,
		"military_available": false,
		"military_reason": "",
	}


## 军务档案（右栏部队/战线页）的模型上下文：只装 MilitaryViewModel 需要的那几项，
## 不走地块档案那条查询链。打开档案与每日刷新各调用一次，O(armies)，不进热循环。
static func military_dossier_context(owner: CountryViewModel, country_handle: int) -> Dictionary:
	var model := {"good_ids": CountryViewModel._good_stable_ids()}
	owner.build_military_model(country_handle, model)
	return {
		"military": model.get("military", {}),
		"country_handle": country_handle,
		"good_ids": model.get("good_ids", PackedStringArray()),
		"generator": owner._generator,
		"map": owner._map,
	}


## 目录合并：dense 数值取原生（真值），显示名/描述/所需科技取编译目录。
## 原生行的 `id` 是稳定 id（String），所以合并是「按 id 对齐」而不是按位置。
static func _merge_military_catalog(owner: CountryViewModel, native_catalog: Dictionary, view: Dictionary) -> Dictionary:
	var display_names := {}
	var descriptions := {}
	var category_names := {}
	var unit_tech := {}
	# 编译目录（MilitaryCatalogCompiler.compile 的产物）已经带上作者写的中文名，
	# 所以这里按 id 对齐即可；原先读的是 `equipment_categories`，而编译器输出的是
	# `categories`，键名不一致正是类别名一直回退成英文 id 的原因。
	var authored: Array = native_catalog.get("units", []) if native_catalog.get(
		"units", null) is Array else []
	for raw in authored:
		if not raw is Dictionary:
			continue
		var row: Dictionary = raw
		var unit_id := String(row.get("id", ""))
		if unit_id.is_empty():
			continue
		var display_name := String(row.get("name", "")).strip_edges()
		display_names[unit_id] = display_name if not display_name.is_empty() else unit_id
		descriptions[unit_id] = String(row.get("description", ""))
		unit_tech[unit_id] = String(row.get("tech", ""))
	var authored_categories: Array = native_catalog.get("categories", []) \
		if native_catalog.get("categories", null) is Array else []
	for raw in authored_categories:
		if not raw is Dictionary:
			continue
		var row: Dictionary = raw
		var category_id := String(row.get("id", ""))
		var display_name := String(row.get("name", "")).strip_edges()
		category_names[category_id] = display_name if not display_name.is_empty() \
			else category_id
	# 原生目录没有的项（旧存档、目录 hash 不一致）用原生 id 兜底显示。
	for raw in view.get("units", []) if view.get("units", null) is Array else []:
		if raw is Dictionary:
			var unit_id := String((raw as Dictionary).get("id", ""))
			if not unit_id.is_empty() and not display_names.has(unit_id):
				display_names[unit_id] = unit_id
	for raw in view.get("categories", []) if view.get("categories", null) is Array else []:
		if raw is Dictionary:
			var category_id := String((raw as Dictionary).get("id", ""))
			if not category_id.is_empty() and not category_names.has(category_id):
				category_names[category_id] = category_id
	var merged := view.duplicate(true)
	merged["display_names"] = display_names
	merged["descriptions"] = descriptions
	merged["category_names"] = category_names
	merged["unit_tech"] = unit_tech
	merged["units"] = view.get("units", [])
	merged["categories"] = view.get("categories", [])
	merged["state_buildings"] = view.get("state_buildings", [])
	if not bool(merged.get("ok", false)):
		merged["ok"] = true
	return merged


## dense good id → 稳定 id。GoodProfileRegistry 的 good_ids 就是 EconomyCatalog 的
## dense 顺序，军事目录里的装备类别用的是同一套 dense id。
static func _good_stable_ids() -> PackedStringArray:
	var columns: Dictionary = CountryViewModel.GoodProfileRegistryScript.compile_native_columns()
	var ids = columns.get("good_ids", PackedStringArray())
	return ids if ids is PackedStringArray else PackedStringArray()
