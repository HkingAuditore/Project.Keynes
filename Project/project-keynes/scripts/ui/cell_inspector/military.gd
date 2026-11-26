extends RefCounted

const StateBuildings = preload("res://scripts/ui/cell_inspector/state_building_rows.gd")

const MaintenancePresentation = preload("res://scripts/ui/military_maintenance_presentation.gd")


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
	return {"military_cell": h._Military_delegate._military_cell_model(h, facade, snapshot,
		host._Overview_delegate._country_summary(host, cell_idx), cell_idx)}



func _military_cell_model(host, facade, snapshot: Dictionary, country: Dictionary,
		cell_idx: int) -> Dictionary:
	var h = host
	var catalog = host._military_catalog_cache(facade)
	var researched: PackedStringArray = host.player_technology_ids()
	# 科技快照读不到时不过滤（宁可见全目录也不误藏），与兵种名录同口径。
	var gate_known = host._technology_ids_resolved
	var can_build = host._Military_delegate._military_can_build(host, snapshot, country)
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
	var maintenance_by_index = host._Military_delegate._military_maintenance_rows(host, facade, cell_idx)
	var market_stock: Dictionary = h._Construction_delegate._construction_local_stock(h, h._Overview_delegate._market_snapshot(h, cell_idx)) if can_build else {}
	var buildings: Array = []
	for role_def in host.STATE_BUILDING_ROLES:
		buildings.append(host._Military_delegate._state_building_entry(host, role_def, snapshot,
			building_rows, researched, gate_known, can_build, facade, cell_idx,
			maintenance_by_index, market_stock))
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
			"training_speed": h._Military_delegate._military_training_speed(h, building_rows,
				int(snapshot.get("college_tier", -1))),
			"ratio": clampf(float(present) / float(posts), 0.0, 1.0) if posts > 0 else 0.0,
			"paused": bool(snapshot.get("paused", false)),
			"disrepair": bool(snapshot.get("disrepair", false)),
			"occupied": owner_slot >= 0 and controller_slot != owner_slot,
		},
		"troops": h._Military_delegate._military_troop_rows(h, snapshot),
		"training": h._Military_delegate._military_training_rows(h, snapshot, catalog.get("units", {})),
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
		maintenance_by_index: Dictionary = {}, market_stock: Dictionary = {}) -> Dictionary:
	return StateBuildings._state_building_entry(host, role_def, snapshot, catalog_rows, researched, gate_known, can_build, facade, cell_idx, maintenance_by_index, market_stock)


func _state_building_cost(host, facade, building_index: int,
		building_row: Dictionary, cash_available: int, cell_idx: int,
		treasury_cache: Dictionary = {}, market_cache: Dictionary = {},
		standing_row: Dictionary = {}, held_count: int = 0) -> Dictionary:
	return StateBuildings._state_building_cost(host, facade, building_index, building_row, cash_available, cell_idx, treasury_cache, market_cache, standing_row, held_count)


func _state_building_economy_quote(host, facade, building_index: int,
		building_row: Dictionary, country_handle: int, cell_idx: int,
		_cash_available: int, standing_row: Dictionary = {},
		held_count: int = 0) -> Dictionary:
	return StateBuildings._state_building_economy_quote(host, facade, building_index, building_row, country_handle, cell_idx, _cash_available, standing_row, held_count)


func _state_building_standing_cost(host, building_row: Dictionary,
		count: int = 1) -> Dictionary:
	return StateBuildings._state_building_standing_cost(host, building_row, count)


func _state_building_upkeep_after_text(host, build_row: Dictionary,
		standing_row: Dictionary, held_count: int) -> String:
	return StateBuildings._state_building_upkeep_after_text(host, build_row, standing_row, held_count)


func _state_building_upkeep_text(host, building_row: Dictionary,
		count: int = 1, existing: bool = true) -> String:
	return StateBuildings._state_building_upkeep_text(host, building_row, count, existing)


func _empty_state_building_cost(host) -> Dictionary:
	return StateBuildings._empty_state_building_cost(host)


func _state_building_materials_text(host, materials: Array) -> String:
	return StateBuildings._state_building_materials_text(host, materials)


func _state_building_cost_tooltip(host, display_name: String, effect: String,
		cost: Dictionary) -> String:
	return StateBuildings._state_building_cost_tooltip(host, display_name, effect, cost)


func _treasury_good_stock(host) -> Dictionary:
	return StateBuildings._treasury_good_stock(host)


func _country_cash(host) -> int:
	return StateBuildings._country_cash(host)


func _state_building_role_rows(host, catalog_rows: Array, role: int) -> Array:
	return StateBuildings._state_building_role_rows(host, catalog_rows, role)


func _state_building_at_tier(host, role_rows: Array, tier: int) -> Dictionary:
	return StateBuildings._state_building_at_tier(host, role_rows, tier)


func _state_building_pending(host, catalog_rows: Array, snapshot: Dictionary,
		role: int) -> Dictionary:
	return StateBuildings._state_building_pending(host, catalog_rows, snapshot, role)


func _state_building_unlocked(host, row: Dictionary, researched: PackedStringArray,
		gate_known: bool) -> bool:
	return StateBuildings._state_building_unlocked(host, row, researched, gate_known)


func _state_building_effect(host, role_id: String, row: Dictionary,
		disrepair: bool) -> String:
	return StateBuildings._state_building_effect(host, role_id, row, disrepair)


func _technology_display_name(host, tech_id: String) -> String:
	return StateBuildings._technology_display_name(host, tech_id)


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
