extends RefCounted

## Builds officer and state building availability, cost, and upkeep rows.

const MaintenancePresentation = preload("res://scripts/ui/military_maintenance_presentation.gd")


static func _state_building_entry(host, role_def: Dictionary, snapshot: Dictionary,
		catalog_rows: Array, researched: PackedStringArray, gate_known: bool,
		can_build: bool, facade = null, cell_idx: int = -1,
		maintenance_by_index: Dictionary = {}, market_stock: Dictionary = {}) -> Dictionary:
	var h = host
	var role = int(role_def.get("role", -1))
	var role_id = String(role_def.get("id", ""))
	var label = String(role_def.get("label", ""))
	var role_rows = _state_building_role_rows(host, catalog_rows, role)
	var best: Dictionary = {}
	for i in range(role_rows.size() - 1, -1, -1):
		if host._Military_delegate._state_building_unlocked(host, role_rows[i].row, researched, gate_known):
			best = role_rows[i]
			break
	var count = 0
	var current_tier = -1
	var known_tiers = true
	if role_id == "barracks":
		var tiers = snapshot.get("barracks_tiers", null)
		if tiers is PackedInt32Array:
			var tier_counts: PackedInt32Array = tiers
			for tier_idx in range(tier_counts.size()):
				var tier_count = int(tier_counts[tier_idx])
				if tier_count <= 0:
					continue
				count += tier_count
				current_tier = maxi(current_tier, tier_idx)
		else:
			# 旧 DLL 没有分档座数：只知道有兵营，不能安全地定位拆除目标。
			known_tiers = false
			count = 1 if int(snapshot.get("post_count", 0)) > 0 else 0
	else:
		current_tier = int(snapshot.get("fort_tier" if role_id == "fortification"
			else "college_tier", -1))
		count = 1 if current_tier >= 0 else 0
	var current: Dictionary = _state_building_at_tier(host, role_rows, current_tier) \
		if current_tier >= 0 else {}
	var pending = host._Military_delegate._state_building_pending(host, catalog_rows, snapshot, role)
	var pending_index = int(pending.get("index", -1))
	var pending_days = int(pending.get("days", 0))
	var display_row: Dictionary = {}
	var target = -1
	var action = "unavailable"
	var action_label = ""
	# 主键语义恒定：只有 host.build / upgrade / rebuild 会占用它，拆除单独一条通道。# 主键语义恒定：只有 build / upgrade / rebuild 会占用它，拆除单独一条通道。
	# 这样「右下角那个键」永远代表在这格里增加建筑，不会某一刻变成会毁掉已有建筑的键。
	var primary_action = "none"
	var can_demolish = false
	if pending_index >= 0:
		display_row = catalog_rows[pending_index]
		target = pending_index
		action = "building"
	elif not can_build or not known_tiers:
		action = "unavailable"
		display_row = current.row if not current.is_empty() else best.row if not best.is_empty() else {}
	elif count <= 0:
		if best.is_empty():
			action = "locked"
			# 全锁着时也把最低一档的名字/效果摆出来：这一行不能只剩一个类目名。
			if not role_rows.is_empty():
				display_row = role_rows[0].row
		else:
			display_row = best.row
			target = int(best.index)
			action = "build"
			action_label = "建造"
			primary_action = "build"
	else:
		display_row = current.row if not current.is_empty() else {}
		can_demolish = not current.is_empty()
		if not best.is_empty() and int(best.row.get("tier", -1)) > current_tier:
			target = int(best.index)
			# 升级时整行必须描述**要建的那一档**：名称、效果、工期、建材要指向同一座
			# 建筑。若沿用现有档，玩家会看到「戍卫营」却报价「联合训练中心」的料。
			display_row = best.row
			action = "upgrade"
			action_label = "升级"
			primary_action = "upgrade"
		elif not current.is_empty() and role_id == "barracks":
			# 兵营可按档叠加（原生 barracks_count[tier] 是计数数组，兵额按
			# count x capacity 累加），所以到顶档后仍给「再建」，而不是把它换成拆除。
			# 城防与军校在原生侧是单值取最大档，叠加没有意义，因此不给这个入口。
			target = int(current.index)
			action = "rebuild"
			action_label = "再建"
			primary_action = "rebuild"
	# 失修按「这一行实际建成的那一档」判定（D7 / S3-2：同格不同建筑各自独立）。
	# 没有该档的维护行（未建成 / 旧 DLL / 快照为空）时才退回国家级旗标。
	var built_index = int(current.index) if not current.is_empty() else -1
	var maintenance: Dictionary = maintenance_by_index.get(built_index, {}) \
		if built_index >= 0 else {}
	var disrepair = bool(int(maintenance.get("disrepair", 0)) != 0) \
		if not maintenance.is_empty() else bool(snapshot.get("disrepair", false))
	var maintenance_text = MaintenancePresentation._state_building_maintenance_text(maintenance)
	var effect = ""
	if not display_row.is_empty():
		effect = host._Military_delegate._state_building_effect(host, role_id, display_row, disrepair)
	elif role_id == "barracks" and count > 0:
		effect = "兵额 +%s" % h._count_text(int(snapshot.get("post_count", 0)))
	var display_name = label
	if not display_row.is_empty():
		var row_name = String(display_row.get("name", "")).strip_edges()
		if not row_name.is_empty():
			display_name = row_name
	var icon: StringName = IconCatalog.military_building_semantic(
		String(display_row.get("id", "")), role_id,
		int(display_row.get("tier", current_tier)))
	# 成本只对「真正会新建一座」的行有意义：在建与锁定态没有可下单目标，
	# 传 -1 让成本函数返回空档，行内就不会显示一份不会兑现的报价。
	var cost = host._Military_delegate._empty_state_building_cost(host)
	if primary_action in ["build", "upgrade", "rebuild"] and target >= 0:
		cost = host._Military_delegate._state_building_cost(host, facade, target, display_row,
			host._country_cash(), cell_idx, {}, {},
			current.row if not current.is_empty() else display_row, count)
	# 缺料/缺钱时按需求把主键置为不可用，但成本信息本身继续留在行里。
	if bool(cost.get("blocked", false)):
		primary_action = "none"
	# 维护成本是「这座建筑天天在吃钱」，与能不能下单无关：只要这一行有具体对象
	# （可建造的档位、已建成的档位、在建目标），提示卡就必须写着它。
	var tooltip = ""
	if primary_action != "none" or bool(cost.get("blocked", false)):
		tooltip = _state_building_cost_tooltip(host, display_name, effect, cost)
	# 拆除是独立通道（`can_demolish`），不再占用 `action` 的取值。
	elif can_demolish:
		tooltip = _state_building_cost_tooltip(host, display_name, effect,
			_state_building_standing_cost(host, display_row, count))
	elif action == "building" and not display_row.is_empty():
		tooltip = _state_building_cost_tooltip(host, display_name, effect,
			_state_building_standing_cost(host, display_row, count))
	elif action == "locked":
		tooltip = MaintenancePresentation._state_building_lock_tooltip(host, role_rows, researched, gate_known)
	var reason: String = cost.get("reason_text", "")
	var status := "已建成" if count > 0 else "未建成"
	var status_tone := "neutral"
	var is_quoting: bool = target >= 0 and action in ["build", "upgrade", "rebuild"]
	if is_quoting:
		status = "受阻" if not reason.is_empty() else "可" + action_label
		status_tone = "risk" if not reason.is_empty() else "good"
	elif action == "building":
		status = "在建"
	elif action == "locked":
		status = "未解锁"
		status_tone = "risk"
		reason = tooltip
	elif not can_build:
		reason = h._Construction_delegate._construction_military_block_text(h, snapshot)

	var has_future: bool = is_quoting or action == "building"
	var current_daily := MaintenancePresentation._state_building_current_upkeep(h, role_id, role_rows, current, snapshot, count)
	var future_daily := -1
	if has_future:
		future_daily = MaintenancePresentation.building_upkeep(h, display_row)
		if role_id == "barracks":
			future_daily += current_daily
	var preview := MaintenancePresentation.building_hover_preview(h, role_id, display_row,
		disrepair and not has_future, current_daily, future_daily, maintenance)
	var hover := {
		"name": display_name, "icon": icon, "role_label": label,
		"tier": int(display_row.get("tier", -1)),
		"eligible": is_quoting and not bool(cost.get("blocked", false)),
		"status_text": status, "status_tone": status_tone, "reason_text": reason,
		"cash_required": int(cost.get("cash_required", 0)), "cash_text": String(cost.get("cash_text", "")),
		"cash_blocked": cost.get("reason_code") == "construction_treasury_cash_insufficient",
		"days": pending_days if action == "building" else int(cost.get("build_days", 0)),
		"days_label": "剩余工期" if action == "building" else "工期",
		"material_status": h._Construction_delegate._construction_material_status_rows(h, cost.get("materials", []), market_stock),
		"preview": preview,
	}
	var demolish_hover := {}
	if can_demolish:
		var built: Dictionary = current.row
		demolish_hover = {
			"name": String(built.get("name", label)),
			"icon": IconCatalog.military_building_semantic(String(built.get("id", "")), role_id, current_tier),
			"role_label": label, "tier": current_tier, "status_text": "拆除",
			"reason_text": "拆除后不退还建材",
		}
	# 实物维护不是「成本」而是「这座建筑现在被养得怎么样」：单独一行，附在提示卡尾部。
	# 没有维护行（未接通 / 未建成）时整行为空，提示卡与本改动前逐字一致。
	if not maintenance_text.is_empty():
		var maintenance_line = "实物维护：%s（5 日结算）" % maintenance_text
		tooltip = maintenance_line if tooltip.is_empty() \
			else "%s\n%s" % [tooltip, maintenance_line]
	return {
		"role": role_id,
		"label": label,
		"icon": String(icon),
		"name": display_name,
		"count": count,
		"effect": effect,
		# `action` 保留为纯展示态（building / locked / unavailable / rebuild / …），
		# 控件据此决定要不要画槽位；`primary_action` 与 `can_demolish` 才是可点性。
		"action": action,
		"primary_action": primary_action,
		"action_label": action_label,
		"can_demolish": can_demolish and can_build and known_tiers,
		"target": target,
		# 拆除目标必须指向**已建成的那一档**：主键在可升级时指向更高档，
		# 两者混用会把「升级」的 target 拿去拆掉现有建筑。
		"demolish_target": int(current.index) if can_demolish else -1,
		"pending_days": pending_days if pending_index >= 0 else -1,
		"materials_text": String(cost.get("materials_text", "")),
		# 全量建材明细：行内文本会截断成「等 N 项」，提示卡与测试都要看这一份。
		"materials_detail": cost.get("materials", []),
		"upkeep_text": String(cost.get("upkeep_text", "")),
		"cost_days_text": String(cost.get("days_text", "")),
		"cost_cash_text": String(cost.get("cash_text", "")),
		"cost_reason": String(cost.get("reason_text", "")),
		"tooltip": tooltip,
		"hover": hover,
		"demolish_hover": demolish_hover,
		# ---- 实物维护（D7 / S4-6）：这一类型自己的满足率 / 可用天数 / 失修 ----
		# `disrepair` 已按建筑类型判定（无维护行时等于国家级旗标），
		# `satisfaction_bp` / `cover_days_x10` 是原生整数口径：万分比与十分之一日。
		"disrepair": disrepair,
		"maintenance": maintenance,
		"satisfaction_bp": clampi(int(maintenance.get("ratio_bp", 0)), 0, 10000),
		"cover_days_x10": int(maintenance.get("days_cover_x10", -1)),
		"shortage_reason": int(maintenance.get("shortage_reason", 0)),
		"maintenance_text": maintenance_text,
	}








## 一座官营建筑的建材与工期成本，供行内成本总览与 hover 提示卡使用。
##
## 建材与替代品由经济侧报价规划，这里只排版并展示权威的可建判定。
##
## 返回的 `materials` 每项带 `required` / `treasury` / `market`（都是 GOODS_SCALE），
## 让提示卡能像营造那样写「国库 X / 市购 Y」；`market` 是市购量，不是缺货量。
##
## `building_row` 是**要建的那一档**（升级时是更高一档，不是现有档），工期取它；
## `standing_row` 是**现有已建成的那一档**，维护成本取它——升级前后维护是两个数，
## 混用会让玩家看到「旧档的钱」却建的是新档。
## 报价与可建判定的统一入口（任务 7）：两个入口（地块军事页 `host._state_building_entry`## 报价与可建判定的统一入口（任务 7）：两个入口（地块军事页 `_state_building_entry`
## 与营造窗口军事部门 `host._construction_military_row`）都必须看见同一份「国库出多少钱、## 与营造窗口军事部门 `_construction_military_row`）都必须看见同一份「国库出多少钱、
## 差多少料、卡在哪」，否则一边报可建一边报缺料是对着同一座建筑打脸。因此造价和
## 卡点一律以经济侧 `treasury_construction_quotes` 为唯一数据源——它就是
## `COMMAND_TREASURY_SPONSORED_BUILD` 真正会扣的钱（缺口 × 市场价，不是建材量折现）。
##
## 返回字段与旧 `host._state_building_cost` 完全一致（`materials`/`materials_text`/## 返回字段与旧 `_state_building_cost` 完全一致（`materials`/`materials_text`/
## `build_days`/`days_text`/`cash_required`/`cash_text`/`reason_text`/`blocked`/
## `upkeep_text`/`upkeep_after_text`），额外带 `reason_code`（经济侧原样拒绝码）供
## 调用方按统一顺序组卡点文案。

static func _state_building_cost(host, facade, building_index: int,
		building_row: Dictionary, cash_available: int, cell_idx: int,
		treasury_cache: Dictionary = {}, market_cache: Dictionary = {},
		standing_row: Dictionary = {}, held_count: int = 0) -> Dictionary:
	var h = host
	return host._Military_delegate._state_building_economy_quote(host, facade, building_index, building_row,
		host._player_country_handle(), cell_idx, cash_available, standing_row, held_count)


## 上面那个外壳只是为了不惊动两处旧调用与契约测试；真正的统一逻辑在这里。
## `economy_id` 由军事门面把 dense 索引翻成经济目录类型索引，再喂给经济侧报价。

static func _state_building_economy_quote(host, facade, building_index: int,
		building_row: Dictionary, country_handle: int, cell_idx: int,
		_cash_available: int, standing_row: Dictionary = {},
		held_count: int = 0) -> Dictionary:
	var h = host
	if building_index < 0 or building_row.is_empty():
		return host._Military_delegate._empty_state_building_cost(host)
	# 报价以经济目录的类型索引为钥匙：军事索引先翻成经济稠密类型，再交给经济侧报价。
	var economy_id = -1
	if facade != null and facade.has_method("state_building_economy_id"):
		economy_id = int(facade.state_building_economy_id(building_index))
	var quote: Dictionary = {}
	var reason_code = ""
	var economy = host._economy_facade()
	if economy_id >= 0 and economy != null \
			and economy.has_method("construction_quotes"):
		var where = PackedInt32Array([economy_id])
		var result: Dictionary = economy.construction_quotes(
			country_handle, cell_idx, where)
		var items: Array = result.get("items", []) if bool(result.get("ok", false)) \
			else []
		if not items.is_empty():
			var item: Dictionary = items[0] as Dictionary
			quote = item
			reason_code = String(item.get("reason_code", ""))
	elif economy == null or economy_id < 0 \
			or not economy.has_method("construction_quotes"):
		# economy == null（受限 headless / 旧夹具）或桥接失效：退回本地安全空档。
		# blocked 置真，让行显示「暂不可营造」，绝不编造一条「差 X 料」的假报价。
		var locked = host._Military_delegate._empty_state_building_cost(host)
		locked["reason_text"] = "暂不可营造"
		locked["blocked"] = true
		return locked
	# 未传现有档（营造目录是在报「还没建的这一档」）时，维护就按目标档算。
	var has_standing = not standing_row.is_empty()
	var upkeep_row = standing_row if has_standing else building_row
	var effective_held = held_count if has_standing else 0
	var days = maxi(0, int(building_row.get("build_days", 0)))
	var materials: Array = quote.get("materials", []) if not quote.is_empty() else []
	var cash_required = int(quote.get("cash_required", 0)) if not quote.is_empty() \
		else 0
	# eligible 已包含替代建材、市场可结算与国库现金检查。市购量可以大于零，
	# 另一份现金快照也可能已过时，UI 不据此重新否决报价。失败或空报价保持禁用。
	var eligible = bool(quote.get("eligible", false))
	var reason = ""
	if not eligible:
		# 用与经济部门同一套文案；这里只是把码变成短因由，长解释交给行内 tooltip。
		reason = String(h.CONSTRUCTION_REASON_TEXT.get(reason_code, "暂不可营造"))
	return {
		"materials": materials,
		"materials_text": _state_building_materials_text(h, materials),
		"build_days": days,
		"days_text": "%d 日" % days if days > 0 else "",
		"cash_required": cash_required,
		"cash_text": h._money_text(cash_required) if cash_required > 0 else "",
		"reason_text": reason,
		"reason_code": reason_code,
		"blocked": not eligible,
		"upkeep_text": _state_building_upkeep_text(h, upkeep_row, effective_held),
		"upkeep_after_text": _state_building_upkeep_after_text(h, building_row,
			upkeep_row, effective_held),
	}


## 「已建成 / 在建」用的成本档：没有可下单目标，所以建材与现金留空，
## 但维护成本必须照写——玩家判断该不该留着这座建筑，靠的就是这个数字。
## `count` 是这一格里该角色的实有座数（兵营可按档叠加），维护要按座数合计，
## 否则两座兵营只报一座的钱，玩家会低估 upkeep。

static func _state_building_standing_cost(host, building_row: Dictionary,
		count: int = 1) -> Dictionary:
	var h = host
	return {
		"materials": [],
		"materials_text": "",
		"build_days": 0,
		"days_text": "",
		"cash_required": 0,
		"cash_text": "",
		"reason_text": "",
		"blocked": false,
		"upkeep_text": _state_building_upkeep_text(h, building_row, count),
		"upkeep_after_text": "",
	}


## 建成后这座（或这几座）每天要吃多少。三种情形各不相同，不能一句话糊住：
##   - 同档再建：现有 N 座 + 新建 1 座 = N+1 座。
##   - 升级到新档：原生按档位取最大档只算一份，所以是目标档单座的维护。
##   - 首次建造（现有 0 座）：就是目标档单座。

static func _state_building_upkeep_after_text(host, build_row: Dictionary,
		standing_row: Dictionary, held_count: int) -> String:
	var h = host
	var per_day = maxf(0.0, float(build_row.get("upkeep", 0.0)))
	if per_day <= 0.0:
		return ""
	var one = host._money_text(int(round(per_day * host.MONEY_SCALE)))
	var same_tier = int(build_row.get("tier", -1)) \
		== int(standing_row.get("tier", -2)) and held_count > 0
	if same_tier:
		var total = host._money_text(int(round(per_day * host.MONEY_SCALE)) * (held_count + 1))
		return "建成后 %d 座，共 %s/日" % [held_count + 1, total]
	if held_count > 0:
		# 升级：旧档被新档替换，维护按新档单份算，不是两份相加。
		return "升级后 %s/日" % one
	return "建成后 %s/日" % one


## 官营建筑的维护成本。目录的 `upkeep` 是「每日货币单位」（原生
## `money_from_units` 乘 host.MONEY_SCALE 存进 `upkeep_per_day`），所以这里只做单位## `money_from_units` 乘 MONEY_SCALE 存进 `upkeep_per_day`），所以这里只做单位
## 换算与文案，不乘 5。
##
## 原生 `run_wages_and_upkeep` 每 5 日扣一次 `upkeep_per_day * 5`，折成日均仍是
## `upkeep_per_day`；提示卡写「每日」是因为玩家的决策周期是天，结算节奏属于引擎
## 细节（写「每 5 日」会被读成另一项成本）。
##
## 兵营在原生侧按 `barracks_count[tier] * upkeep_per_day` 逐档累加，所以多座时
## 必须把合计一起写出来：只报单价会让玩家拿一座的钱去做多座的决策。

static func _state_building_upkeep_text(host, building_row: Dictionary,
		count: int = 1, existing: bool = true) -> String:
	var h = host
	var per_day = maxf(0.0, float(building_row.get("upkeep", 0.0)))
	if per_day <= 0.0:
		return ""
	var one = host._money_text(int(round(per_day * host.MONEY_SCALE)))
	var held = maxi(1, count)
	if held <= 1:
		return "%s/日" % one
	var total = host._money_text(int(round(per_day * host.MONEY_SCALE)) * held)
	# 「现有」只在描述当前状态时用；说建成后的数字时不能拿「现有」去修饰未落成的那座。
	if existing:
		return "%s/日（现有 %d 座，共 %s/日）" % [one, held, total]
	return "%s × %d 座 = %s/日" % [one, held, total]



static func _empty_state_building_cost(host) -> Dictionary:
	var h = host
	return {
		"materials": [],
		"materials_text": "",
		"build_days": 0,
		"days_text": "",
		"cash_required": 0,
		"cash_text": "",
		"reason_text": "",
		"blocked": false,
		"upkeep_text": "",
		"upkeep_after_text": "",
	}


## 行内成本总览：最多三项建材，超出以「等 N 项」收尾。
## 与营造目录的 `host._construction_materials_text` 保持同一套排版。## 与营造目录的 `_construction_materials_text` 保持同一套排版。
## 注意：只有**行内**接受这个截断。hover 提示卡在 `_state_building_cost_tooltip(host)` 里## 注意：只有**行内**接受这个截断。hover 提示卡在 `_state_building_cost_tooltip()` 里
## 自己逐项遍历 `materials`，不复用这份文本——两处各取所需，不要合并。

static func _state_building_materials_text(host, materials: Array) -> String:
	var h = host
	if materials.is_empty():
		return "无需建材"
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


## 提示卡正文：先写这一座给什么，再写吃多少、维护多少、卡在哪。
## 段序与营造提示卡一致，但建材必须**逐项列全**：行内只放得下三项，
## 提示卡是玩家核对「到底要哪几种料」的唯一落点，不能复用行内的截断文本。

static func _state_building_cost_tooltip(host, display_name: String, effect: String,
		cost: Dictionary) -> String:
	var h = host
	var lines = PackedStringArray()
	if not display_name.is_empty():
		lines.append(display_name)
	if not effect.is_empty():
		lines.append("效果：%s" % effect)
	var materials: Array = cost.get("materials", [])
	if materials.is_empty():
		lines.append("建材：无需建材")
	# 每一种建材都单独一行：公布「国库多少、市购多少、还缺多少」，缺料时才看得懂
	# 是缺哪一种。逐项列全是这段代码存在的理由，不要为了行数改成汇总。
	var total = 0
	var shortage = 0
	for raw in materials:
		var material: Dictionary = raw
		var required = int(material.get("required", 0))
		var treasury = int(material.get("treasury", 0))
		var market = int(material.get("market", 0))
		var missing = maxi(0, required - treasury - market)
		total += required
		shortage += missing
		var line = "建材：%s %s（国库 %s" % [
			String(material.get("name", "建材")),
			host._goods_scaled(required),
			host._goods_scaled(treasury)]
		if market > 0:
			line += " / 市购 %s" % h._goods_scaled(market)
		if missing > 0:
			line += " / 缺 %s" % h._goods_scaled(missing)
		lines.append(line + "）")
	if materials.size() > 1:
		var summary = "建材合计：%s" % h._goods_scaled(total)
		if shortage > 0:
			summary += "，缺 %s" % h._goods_scaled(shortage)
		lines.append(summary)
	var cash_text = String(cost.get("cash_text", ""))
	if not cash_text.is_empty():
		lines.append("现金：%s（一次性）" % cash_text)
	var upkeep_text = String(cost.get("upkeep_text", ""))
	if not upkeep_text.is_empty():
		lines.append("维护：%s" % upkeep_text)
	var after_text = String(cost.get("upkeep_after_text", ""))
	if not after_text.is_empty() and after_text != upkeep_text:
		lines.append("建成后维护：%s" % after_text)
	var days_text = String(cost.get("days_text", ""))
	if not days_text.is_empty():
		lines.append("工期：%s" % days_text)
	var reason = String(cost.get("reason_text", ""))
	if not reason.is_empty():
		lines.append("受阻：%s" % reason)
	return "\n".join(lines)


## 国库逐物资现货（GOODS_SCALE）。读不到时返回空表：成本会显示成全部市购，
## 比编造一个「国库充足」的假象安全。

static func _treasury_good_stock(host) -> Dictionary:
	var h = host
	var out = {}
	if h._generator == null or not h._generator.has_method("get_country_facade"):
		return out
	var facade = host._generator.get_country_facade()
	if facade == null or not facade.has_method("treasury_snapshot"):
		return out
	var handle = host._player_country_handle()
	if handle <= 0:
		return out
	var treasury: Dictionary = facade.treasury_snapshot(handle)
	var ids: PackedStringArray = treasury.get("good_ids", PackedStringArray())
	var quantities: PackedInt64Array = treasury.get(
		"quantities", PackedInt64Array())
	for index in range(mini(ids.size(), quantities.size())):
		out[String(ids[index])] = int(quantities[index])
	return out


## 国库现金（host.MONEY_SCALE 子单位）。读不到时返回 -1：调用方据此跳过资金卡点判断，## 国库现金（MONEY_SCALE 子单位）。读不到时返回 -1：调用方据此跳过资金卡点判断，
## 而不是把「未知」当成「没钱」把按钮锁死。

static func _country_cash(host) -> int:
	var h = host
	if h._generator == null or not h._generator.has_method("get_country_facade"):
		return -1
	var facade = host._generator.get_country_facade()
	if facade == null or not facade.has_method("treasury_snapshot"):
		return -1
	var handle = host._player_country_handle()
	if handle <= 0:
		return -1
	var treasury: Dictionary = facade.treasury_snapshot(handle)
	if not treasury.has("cash"):
		return -1
	return int(treasury.get("cash", 0))


## 一类角色的目录行，按 (档位, 容量) 升序：末尾即"最高档、同档里容量最大"。

static func _state_building_role_rows(host, catalog_rows: Array, role: int) -> Array:
	var h = host
	var out: Array = []
	for index in range(catalog_rows.size()):
		var row: Dictionary = catalog_rows[index]
		if int(row.get("role", -1)) != role:
			continue
		out.append({"row": row, "index": index})
	out.sort_custom(func(a, b) -> bool:
		var tier_a = int(a.row.get("tier", 0))
		var tier_b = int(b.row.get("tier", 0))
		if tier_a != tier_b:
			return tier_a < tier_b
		return int(a.row.get("capacity", 0)) < int(b.row.get("capacity", 0)))
	return out


## 目录档位是 0..7（编译器把 tier 8 也压到 7），同一档可能有两行：
## 取容量较大的一行显示；拆除只看 role+tier，任一行的下标都等价。

static func _state_building_at_tier(host, role_rows: Array, tier: int) -> Dictionary:
	var h = host
	var found: Dictionary = {}
	for entry in role_rows:
		if int(entry.row.get("tier", -1)) != tier:
			continue
		if found.is_empty() or int(entry.row.get("capacity", 0)) \
				> int(found.row.get("capacity", 0)):
			found = entry
	return found


## 该角色是否有在建工程（3 个施工位里最先完工的一个）。

static func _state_building_pending(host, catalog_rows: Array, snapshot: Dictionary,
		role: int) -> Dictionary:
	var h = host
	var built = snapshot.get("construction_buildings", null)
	if not built is PackedInt32Array:
		return {}
	var done = snapshot.get("construction_done_days", null)
	var done_days: PackedInt32Array = done if done is PackedInt32Array \
		else PackedInt32Array()
	var best: Dictionary = {}
	var today = host._Geography_delegate._current_sample_day(host)
	for slot in range((built as PackedInt32Array).size()):
		var index = int(built[slot])
		if index < 0 or index >= catalog_rows.size():
			continue
		var row: Dictionary = catalog_rows[index]
		if int(row.get("role", -1)) != role:
			continue
		var days = 0
		if slot < done_days.size() and int(done_days[slot]) >= 0:
			days = maxi(0, int(done_days[slot]) - today)
		if best.is_empty() or days < int(best.get("days", 0)):
			best = {"index": index, "days": days}
	return best



static func _state_building_unlocked(host, row: Dictionary, researched: PackedStringArray,
		gate_known: bool) -> bool:
	if not gate_known:
		return true
	var tech = String(row.get("unlock_tech_id", ""))
	return tech.is_empty() or researched.has(tech)


static func _state_building_effect(host, role_id: String, row: Dictionary,
		disrepair: bool) -> String:
	return MaintenancePresentation._state_building_effect(host, role_id, row, disrepair)


## 未解锁时 tooltip 指向"差哪项科技"：取最低一档尚未解锁的行。



static func _technology_display_name(host, tech_id: String) -> String:
	var h = host
	if tech_id.is_empty():
		return ""
	if host._technology_names.is_empty():
		var catalog = host._Overview_delegate._ensure_technology_catalog(host)
		var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
		var names: PackedStringArray = catalog.get(
			"technology_display_names", PackedStringArray())
		for index in range(mini(ids.size(), names.size())):
			host._technology_names[String(ids[index])] = String(names[index])
	return String(h._technology_names.get(tech_id, ""))


## 军事目录在整局里不变，只按 facade 身份缓存一次：每格重建军事页时
## 不再过滤/重排一遍官营建筑，也不再重建兵种名表。
