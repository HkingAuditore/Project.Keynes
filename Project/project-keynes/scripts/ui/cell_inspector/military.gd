extends RefCounted


const TEMPERATURE_HISTORY_CAPACITY = 32
const TEMPERATURE_HISTORY_CACHE_LIMIT = 64
const DETAIL_HISTORY_CAPACITY = 48
const DETAIL_HISTORY_LOOKBACK = 7
## 原生金额单位是 1/10000 货币；只有视图层才把它换算成金币读数。
const MONEY_SCALE = 10000.0

# 对象详情弹窗：行类型 → 页签 / 行列表键 / 中文类型名。
const OBJECT_DETAIL_TAB = {
	"cohort": "population",
	"building": "buildings",
	"good": "market",
	"resource": "geography",
	"family": "families",
}
const OBJECT_DETAIL_ROWS = {
	"cohort": "cohort_rows",
	"building": "building_rows",
	"good": "market_rows",
	"resource": "resource_rows",
	"family": "family_rows",
}
const OBJECT_TYPE_LABELS = {
	"cohort": "阶层",
	"building": "建筑",
	"good": "物资",
	"resource": "自然资源",
	"family": "家族",
}
# 对象类型 → 关联税种（税收契约：所得税按职业、营业税按建筑类型、
# 交易税与进出口关税按物资；自然资源没有适用税种）。
const OBJECT_TAX_KINDS = {
	"cohort": ["income"],
	"building": ["business"],
	"good": ["consumption", "import", "export"],
}
const TAX_KIND_IDS = {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const TAX_KIND_LABELS = {"income": "所得税", "consumption": "交易税",
	"business": "营业税", "import": "进口关税", "export": "出口关税"}
const TAX_DEFAULT_LABELS = {"income": "此地所得税", "consumption": "此地交易税",
	"business": "此地营业税", "import": "此地进口税", "export": "此地出口税"}
const TAX_KIND_ACCENTS = {"income": UITokens.ACCENT, "consumption": UITokens.GOOD,
	"business": UITokens.CLIMATE, "import": UITokens.WATER, "export": UITokens.WATER}
const TRADE_ORDER_PAGE_SIZE = 12
const TRADE_ORDER_PAGE_CACHE_LIMIT = 8
const TRADE_ORDER_MODEL_CACHE_LIMIT = 16
const TRADE_ORDER_NAME_CACHE_LIMIT = 256

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
## Same order as MilitaryUnitClass (military_core.h), used for unit icon keys.
const MILITARY_UNIT_CLASS_IDS: Array[String] = ["line", "mobile", "artillery"]
## 维护快照的 `kind`：0 = 建筑组，1 = 装备组（D7 契约）。地块档案只读建筑组。
## `object_id` 是目录 `state_buildings` 的稠密下标，与 `state_building_materials()`
## 用的是同一套下标。
const MAINTENANCE_KIND_BUILDING = 0
const MAINTENANCE_REASON_TEXT: Array[String] = ["—", "缺货", "预算不足", "运输未到"]
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
## one-tick memo for the (large) cell building snapshot: the buildings tab and
## the construction window share one read per cell per committed day.

func _military_facade(host):
	var h = host
	if h._generator == null or not h._generator.has_method("get_military_facade"):
		return null
	var facade = host._generator.get_military_facade()
	if facade == null or not facade.has_method("cell_snapshot"):
		return null
	return facade


## Inspector「军事」页签：本地驻军 / 部队 / 训练 / 三行官营建筑（兵营·城防·军校）。
##
## 全部数据来自一次 `get_military_cell_snapshot` + 编译目录：
##   post_count / present / pending_enlist / paused / disrepair → 驻军条
##   armies[]                                                   → 部队行（点行开军务档案）
##   training[]                                                 → 训练行（兵种/人数/进度/剩余日）
##   barracks_tiers / fort_tier / college_tier                  → 三行的现存档位与座数
##   construction_buildings / construction_done_days            → 「在建 · 剩 N 日」
##   state_buildings[] + 玩家已研究科技                          → 可建造的最高档与解锁闸门
##
## 这里不写任何解释性句子：没有部队/训练/建筑就整组隐藏，只有读不到快照时留一行错误态。

func _military_category(host, cell_idx: int) -> Dictionary:
	var h = host
	var facade = host._military_facade()
	if facade == null:
		return {}
	var snapshot: Dictionary = facade.cell_snapshot(cell_idx, host._player_country_handle())
	if not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "military_pending", "text": "军事数据暂不可用",
			"icon": "status.warning", "accent": UITokens.ARCHIVE_INK_MUTED}]}
	return {"military_cell": h._military_cell_model(facade, snapshot,
		host._country_summary(cell_idx), cell_idx)}



func _military_cell_model(host, facade, snapshot: Dictionary, country: Dictionary,
		cell_idx: int) -> Dictionary:
	var h = host
	var catalog = host._military_catalog_cache(facade)
	var researched: PackedStringArray = host.player_technology_ids()
	# 科技快照读不到时不过滤（宁可见全目录也不误藏），与兵种名录同口径。
	var gate_known = host._technology_ids_resolved
	var can_build = host._military_can_build(snapshot, country)
	var posts = maxi(0, int(snapshot.get("post_count", 0)))
	var present = maxi(0, int(snapshot.get("present", 0)))
	var pending = maxi(0, int(snapshot.get("pending_enlist", 0)))
	var owner_slot = int(snapshot.get("owner_slot", -1))
	var controller_slot = int(snapshot.get("controller_slot", -1))
	var army_units: Dictionary = {}
	var garrison_lots = snapshot.get("garrison_lots", [])
	if garrison_lots is Array:
		for raw in garrison_lots:
			if not raw is Dictionary:
				continue
			var lot: Dictionary = raw
			if int(lot.get("country_slot", -1)) != owner_slot:
				continue
			var unit = int(lot.get("unit", -1))
			var count = maxi(0, int(lot.get("count", 0)))
			if unit >= 0 and count > 0:
				army_units[unit] = int(army_units.get(unit, 0)) + count
	var army_heads = 0
	for count in army_units.values():
		army_heads += int(count)
	var building_rows: Array = catalog.get("buildings", [])
	# 本格的建筑维护行（D7）：有实物快照就按建筑类型各读各的满足率/可用天数/失修，
	# 没有（旧 DLL / 未接通）就退回国家级 `disrepair` 旗标，行为与旧版一致。
	var maintenance_by_index = host._military_maintenance_rows(facade, cell_idx)
	var buildings: Array = []
	for role_def in host.STATE_BUILDING_ROLES:
		buildings.append(host._state_building_entry(role_def, snapshot,
			building_rows, researched, gate_known, can_build, facade, cell_idx,
			maintenance_by_index))
	# 驻军条上的读数一律照实给（包括 0）：玩家要靠这些数字判断"这一格能养多少兵、
	# 还差多少、征召排了多少、训练快不快"，所以没有部队时也要显示 0 而不是整条消失。
	return {
		"cell": cell_idx,
		"garrison": {
			"present": present,
			"posts": posts,
			"open": maxi(0, posts - present - pending),
			"quota": maxi(0, int(snapshot.get("quota", 0))),
			"pending": pending,
			"barracks_count": h._military_barracks_count(snapshot),
			"training_speed": h._military_training_speed(building_rows,
				int(snapshot.get("college_tier", -1))),
			"ratio": clampf(float(present) / float(posts), 0.0, 1.0) if posts > 0 else 0.0,
			"paused": bool(snapshot.get("paused", false)),
			"disrepair": bool(snapshot.get("disrepair", false)),
			"occupied": owner_slot >= 0 and controller_slot != owner_slot,
		},
		"troops": h._military_troop_rows(snapshot),
		"training": h._military_training_rows(snapshot, catalog.get("units", {})),
		"army_create": {
			"enabled": can_build and army_heads > 0,
			"heads": army_heads,
			"units": army_units,
		},
		"buildings": buildings,
	}


## 本格建筑维护行（D7）：`maintenance_snapshot()` 按 (kind = 建筑, cell) 过滤，
## 键是目录稠密下标 —— 原生行的 `object_id` 与 `state_building_materials()` 用同一套
## 下标，所以这里可以直接按 `state_building_role_rows()` 的 `index` 取。
##
## 快照不可用（旧 DLL、未配置、门面是测试夹具）时返回空表，调用方据此回落到国家级的
## `disrepair` 旗标。只读一次：facade 侧按军事日缓存，不逐行查原生。

func _military_maintenance_rows(host, facade, cell_idx: int) -> Dictionary:
	var h = host
	var out = {}
	if facade == null or not facade.has_method("maintenance_snapshot"):
		return out
	var rows = facade.maintenance_snapshot()
	if not rows is Array:
		return out
	for raw in rows:
		if not raw is Dictionary:
			continue
		var row: Dictionary = raw
		if int(row.get("kind", -1)) != h.MAINTENANCE_KIND_BUILDING:
			continue
		if int(row.get("cell", -1)) != cell_idx:
			continue
		var index = int(row.get("object_id", -1))
		if index >= 0 and not out.has(index):
			out[index] = row
	return out


## 本格兵营座数：逐档座数求和（旧 DLL 没有分档表时退回兵额>0 ? 1 : 0 由调用方处理）。

func _military_barracks_count(host, snapshot: Dictionary) -> int:
	var h = host
	var tiers = snapshot.get("barracks_tiers", null)
	if not tiers is PackedInt32Array:
		return 0
	var total = 0
	for value in (tiers as PackedInt32Array):
		total += maxi(0, int(value))
	return total


## 本格训练速度倍数：军校档位的 `training_speed`（原生在同档取最大值，1.0 为基数）。
## 没有军校就是 1.0 —— 这个"1.0"本身也是要告诉玩家的状态。

func _military_training_speed(host, catalog_rows: Array, college_tier: int) -> float:
	var h = host
	if college_tier < 0:
		return 1.0
	var speed = 1.0
	var college_role = int(h.STATE_BUILDING_ROLES[2].get("role", 2))
	for row in catalog_rows:
		var entry: Dictionary = row
		if int(entry.get("role", -1)) != college_role:
			continue
		if int(entry.get("tier", -1)) != college_tier:
			continue
		speed = maxf(speed, float(entry.get("training_speed", 1.0)))
	return speed


## 玩家能否在这一格下令营造：本国领土、未被占领、玩家国家句柄已解析。

func _military_can_build(host, snapshot: Dictionary, country: Dictionary) -> bool:
	var h = host
	var owner_slot = int(snapshot.get("owner_slot", -1))
	if owner_slot < 0 or int(snapshot.get("controller_slot", -1)) != owner_slot:
		return false
	var handle = host._player_country_handle()
	if handle <= 0 or not bool(country.get("owned", false)):
		return false
	return int(country.get("country_handle", 0)) == handle


## 同格部队：番号走 MilitaryViewModel 的同一套回落（handle 低位 + 1），
## 归属只标「外」（不是本格所属国的军队），国名留给点开的军务档案。

func _military_troop_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var armies = snapshot.get("armies", null)
	if not armies is Array:
		return rows
	for raw in armies:
		if not raw is Dictionary:
			continue
		var army: Dictionary = raw
		var handle = int(army.get("handle", 0))
		if handle == 0:
			continue
		rows.append({
			"handle": handle,
			"name": "第 %d 军" % ((handle & 0xFFFFFFFF) + 1),
			"heads": maxi(0, int(army.get("headcount", 0))),
			"foreign": bool(army.get("foreign", false)),
		})
	rows.sort_custom(func(a, b) -> bool: return int(a.heads) > int(b.heads))
	return rows


## 本地训练队列：兵种名取自编译目录，`days_total` 已含军校加速，
## 所以剩余天数与进度直接读快照，不再另算速率。

func _military_training_rows(host, snapshot: Dictionary, units: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var orders = snapshot.get("training", null)
	if not orders is Array:
		return rows
	var owner_slot = int(snapshot.get("owner_slot", -1))
	for raw in orders:
		if not raw is Dictionary:
			continue
		var order: Dictionary = raw
		var from_row: Dictionary = units.get(int(order.get("from_unit", -1)), {})
		var to_row: Dictionary = units.get(int(order.get("to_unit", -1)), {})
		var days_total = maxi(1, int(order.get("days_total", 1)))
		var days_done = clampi(int(order.get("days_done", 0)), 0, days_total)
		rows.append({
			"id": int(order.get("id", 0)),
			"from": String(from_row.get("name", "—")),
			"to": String(to_row.get("name", "—")),
			"icon": String(IconCatalog.military_unit_semantic_for_id(
				String(to_row.get("id", "")), String(to_row.get("class_id", "line")))),
			"count": maxi(0, int(order.get("count", 0))),
			"progress": float(days_done) / float(days_total),
			"remaining_days": days_total - days_done,
			"foreign": int(order.get("country_slot", -1)) != owner_slot,
		})
	return rows


## 一类官营建筑的一行：现存档位/座数 + 效果 + 一个动作（建造 / 升级 / 拆除）。
## 动作由这里判定，控件只负责画和发请求，避免同一套规则散在渲染层。

func _state_building_entry(host, role_def: Dictionary, snapshot: Dictionary,
		catalog_rows: Array, researched: PackedStringArray, gate_known: bool,
		can_build: bool, facade = null, cell_idx: int = -1,
		maintenance_by_index: Dictionary = {}) -> Dictionary:
	var h = host
	var role = int(role_def.get("role", -1))
	var role_id = String(role_def.get("id", ""))
	var label = String(role_def.get("label", ""))
	var role_rows = host._state_building_role_rows(catalog_rows, role)
	var best: Dictionary = {}
	for i in range(role_rows.size() - 1, -1, -1):
		if host._state_building_unlocked(role_rows[i].row, researched, gate_known):
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
	var current: Dictionary = host._state_building_at_tier(role_rows, current_tier) \
		if current_tier >= 0 else {}
	var pending = host._state_building_pending(catalog_rows, snapshot, role)
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
	var maintenance_text = host._state_building_maintenance_text(maintenance)
	var effect = ""
	if not display_row.is_empty():
		effect = host._state_building_effect(role_id, display_row, disrepair)
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
	var cost = host._empty_state_building_cost()
	if primary_action in ["build", "upgrade", "rebuild"] and target >= 0:
		cost = host._state_building_cost(facade, target, display_row,
			host._country_cash(), cell_idx, {}, {},
			current.row if not current.is_empty() else display_row, count)
	# 缺料/缺钱时按需求把主键置为不可用，但成本信息本身继续留在行里。
	if bool(cost.get("blocked", false)):
		primary_action = "none"
	# 维护成本是「这座建筑天天在吃钱」，与能不能下单无关：只要这一行有具体对象
	# （可建造的档位、已建成的档位、在建目标），提示卡就必须写着它。
	var tooltip = ""
	if primary_action != "none" or bool(cost.get("blocked", false)):
		tooltip = host._state_building_cost_tooltip(display_name, effect, cost)
	# 拆除是独立通道（`can_demolish`），不再占用 `action` 的取值。
	elif can_demolish:
		tooltip = host._state_building_cost_tooltip(display_name, effect,
			host._state_building_standing_cost(display_row, count))
	elif action == "building" and not display_row.is_empty():
		tooltip = host._state_building_cost_tooltip(display_name, effect,
			host._state_building_standing_cost(display_row, count))
	elif action == "locked":
		tooltip = host._state_building_lock_tooltip(role_rows, researched, gate_known)
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

func _state_building_cost(host, facade, building_index: int,
		building_row: Dictionary, cash_available: int, cell_idx: int,
		treasury_cache: Dictionary = {}, market_cache: Dictionary = {},
		standing_row: Dictionary = {}, held_count: int = 0) -> Dictionary:
	var h = host
	return host._state_building_economy_quote(facade, building_index, building_row,
		host._player_country_handle(), cell_idx, cash_available, standing_row, held_count)


## 上面那个外壳只是为了不惊动两处旧调用与契约测试；真正的统一逻辑在这里。
## `economy_id` 由军事门面把 dense 索引翻成经济目录类型索引，再喂给经济侧报价。

func _state_building_economy_quote(host, facade, building_index: int,
		building_row: Dictionary, country_handle: int, cell_idx: int,
		_cash_available: int, standing_row: Dictionary = {},
		held_count: int = 0) -> Dictionary:
	var h = host
	if building_index < 0 or building_row.is_empty():
		return host._empty_state_building_cost()
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
		var locked = host._empty_state_building_cost()
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
		"materials_text": h._state_building_materials_text(materials),
		"build_days": days,
		"days_text": "%d 日" % days if days > 0 else "",
		"cash_required": cash_required,
		"cash_text": h._money_text(cash_required) if cash_required > 0 else "",
		"reason_text": reason,
		"reason_code": reason_code,
		"blocked": not eligible,
		"upkeep_text": h._state_building_upkeep_text(upkeep_row, effective_held),
		"upkeep_after_text": h._state_building_upkeep_after_text(building_row,
			upkeep_row, effective_held),
	}


## 「已建成 / 在建」用的成本档：没有可下单目标，所以建材与现金留空，
## 但维护成本必须照写——玩家判断该不该留着这座建筑，靠的就是这个数字。
## `count` 是这一格里该角色的实有座数（兵营可按档叠加），维护要按座数合计，
## 否则两座兵营只报一座的钱，玩家会低估 upkeep。

func _state_building_standing_cost(host, building_row: Dictionary,
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
		"upkeep_text": h._state_building_upkeep_text(building_row, count),
		"upkeep_after_text": "",
	}


## 建成后这座（或这几座）每天要吃多少。三种情形各不相同，不能一句话糊住：
##   - 同档再建：现有 N 座 + 新建 1 座 = N+1 座。
##   - 升级到新档：原生按档位取最大档只算一份，所以是目标档单座的维护。
##   - 首次建造（现有 0 座）：就是目标档单座。

func _state_building_upkeep_after_text(host, build_row: Dictionary,
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

func _state_building_upkeep_text(host, building_row: Dictionary,
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



func _empty_state_building_cost(host, ) -> Dictionary:
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
## 注意：只有**行内**接受这个截断。hover 提示卡在 `host._state_building_cost_tooltip()` 里## 注意：只有**行内**接受这个截断。hover 提示卡在 `_state_building_cost_tooltip()` 里
## 自己逐项遍历 `materials`，不复用这份文本——两处各取所需，不要合并。

func _state_building_materials_text(host, materials: Array) -> String:
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

func _state_building_cost_tooltip(host, display_name: String, effect: String,
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
		lines.append("卡点：%s" % reason)
	return "\n".join(lines)


## 国库逐物资现货（GOODS_SCALE）。读不到时返回空表：成本会显示成全部市购，
## 比编造一个「国库充足」的假象安全。

func _treasury_good_stock(host, ) -> Dictionary:
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

func _country_cash(host, ) -> int:
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

func _state_building_role_rows(host, catalog_rows: Array, role: int) -> Array:
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

func _state_building_at_tier(host, role_rows: Array, tier: int) -> Dictionary:
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

func _state_building_pending(host, catalog_rows: Array, snapshot: Dictionary,
		role: int) -> Dictionary:
	var h = host
	var built = snapshot.get("construction_buildings", null)
	if not built is PackedInt32Array:
		return {}
	var done = snapshot.get("construction_done_days", null)
	var done_days: PackedInt32Array = done if done is PackedInt32Array \
		else PackedInt32Array()
	var best: Dictionary = {}
	var today = host._current_sample_day()
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



func _state_building_unlocked(host, row: Dictionary, researched: PackedStringArray,
		gate_known: bool) -> bool:
	var h = host
	if not gate_known:
		return true
	var tech = String(row.get("unlock_tech_id", ""))
	return tech.is_empty() or researched.has(tech)


## 一行建筑的实物维护读数：「满足 73% · 可用 3.5 日 · 失修 · 缺货」。
## 没有维护行（旧 DLL / 未建成 / 快照为空）时返回空串，控件据此保持旧版布局，
## 而不是画一段「满足 0%」把「读不到」说成「没维护」。

static func _state_building_maintenance_text(row: Dictionary) -> String:
	if row.is_empty():
		return ""
	var parts = PackedStringArray()
	parts.append("满足 %d%%" % (clampi(int(row.get("ratio_bp", 0)), 0, 10000) / 100))
	var days = int(row.get("days_cover_x10", -1))
	if days >= 0:
		parts.append("可用 %s" % _maintenance_days_text(days))
	if int(row.get("disrepair", 0)) != 0:
		parts.append("失修")
	var reason = int(row.get("shortage_reason", 0))
	if reason > 0 and reason < MAINTENANCE_REASON_TEXT.size():
		parts.append(MAINTENANCE_REASON_TEXT[reason])
	return " · ".join(parts)


## 可用天数（十分之一日，-1 = 无需求）→ 「3.5 日」。整数运算，不经过浮点。

static func _maintenance_days_text(days_cover_x10: int) -> String:
	if days_cover_x10 < 0:
		return "—"
	if days_cover_x10 % 10 == 0:
		return "%d 日" % (days_cover_x10 / 10)
	return "%d.%d 日" % [days_cover_x10 / 10, days_cover_x10 % 10]


## 一行建筑的效果：兵营=兵额贡献，城防=守备加成（失修折半，与原生一致），
## 军校=训练天数倍数。单位只写百分比/倍数，不写货币记号。
## `disrepair` 由调用方按「建筑类型」判定（D7：同格不同建筑各判各的），
## 不再是一个国家的单一旗标。

func _state_building_effect(host, role_id: String, row: Dictionary,
		disrepair: bool) -> String:
	var h = host
	match role_id:
		"barracks":
			return "兵额 +%s" % h._count_text(int(row.get("capacity", 0)))
		"fortification":
			var bonus = float(row.get("fort_bonus", 0.0))
			if disrepair:
				bonus *= 0.5
			return "守备 +%d%%" % int(round(bonus * 100.0))
		_:
			var speed = float(row.get("training_speed", 1.0))
			return "训练 ×%s" % h._one_decimal(speed)


## 未解锁时 tooltip 指向"差哪项科技"：取最低一档尚未解锁的行。

func _state_building_lock_tooltip(host, role_rows: Array, researched: PackedStringArray,
		gate_known: bool) -> String:
	var h = host
	for entry in role_rows:
		var tech = String(entry.row.get("unlock_tech_id", ""))
		if tech.is_empty() or (gate_known and researched.has(tech)):
			continue
		var tech_name = host._technology_display_name(tech)
		return "需 %s" % tech_name if not tech_name.is_empty() else ""
	return ""



func _technology_display_name(host, tech_id: String) -> String:
	var h = host
	if tech_id.is_empty():
		return ""
	if host._technology_names.is_empty():
		var catalog = host._ensure_technology_catalog()
		var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
		var names: PackedStringArray = catalog.get(
			"technology_display_names", PackedStringArray())
		for index in range(mini(ids.size(), names.size())):
			host._technology_names[String(ids[index])] = String(names[index])
	return String(h._technology_names.get(tech_id, ""))


## 军事目录在整局里不变，只按 facade 身份缓存一次：每格重建军事页时
## 不再过滤/重排一遍官营建筑，也不再重建兵种名表。

func _military_catalog_cache(host, facade) -> Dictionary:
	var h = host
	if host._military_catalog_facade == facade and not host._military_catalog_rows.is_empty():
		return {"buildings": h._military_catalog_rows, "units": h._military_unit_names}
	var catalog: Dictionary = facade.catalog() if facade.has_method("catalog") else {}
	var buildings: Array = []
	for raw in catalog.get("state_buildings", []):
		if raw is Dictionary:
			buildings.append(raw)
	var units = {}
	var unit_rows: Array = catalog.get("units", []) if catalog.get(
		"units", null) is Array else []
	for index in range(unit_rows.size()):
		var row = unit_rows[index]
		if not row is Dictionary:
			continue
		var unit: Dictionary = row
		var class_index = clampi(int(unit.get("class", 0)), 0,
			host.MILITARY_UNIT_CLASS_IDS.size() - 1)
		units[index] = {
			"id": String(unit.get("id", "")),
			"name": String(unit.get("name", unit.get("id", ""))).strip_edges(),
			"class_id": h.MILITARY_UNIT_CLASS_IDS[class_index],
		}
	host._military_catalog_facade = facade
	host._military_catalog_rows = buildings
	host._military_unit_names = units
	return {"buildings": buildings, "units": units}



static func _one_decimal(value: float) -> String:
	var text = "%.1f" % value
	return text.trim_suffix(".0")



static func _count_text(value: int) -> String:
	return UITokens.format_compact_number_cn(float(value), 1)
