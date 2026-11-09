extends RefCounted
class_name MilitaryViewModel

## Read-only presentation model for MilitaryWorkspace. Every number comes from the
## military facade snapshot (fixed-point ints) and is converted here; nothing is
## written back. Fields the native snapshot does not export are left out rather than
## shown as fabricated zeros.

const MONEY_SCALE := 10000.0
const Q16 := 65536.0
const BP := 10000.0
const GOODS_SCALE := 1000.0
const Q8 := 256.0

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

const CHAPTERS: Array[Dictionary] = [
	{"id": "overview", "label": "总览", "icon": &"summary.overview"},
	{"id": "forces", "label": "兵力", "icon": &"military.unit.line"},
	{"id": "armies", "label": "部队与后勤", "icon": &"military.banner"},
	{"id": "war", "label": "战争", "icon": &"military.war.front"},
]

## Same order as MilitaryUnitClass in military_core.h.
const UNIT_CLASSES: Array[Dictionary] = [
	{"id": "line", "label": "步兵", "color": Color(0.55, 0.42, 0.24)},
	{"id": "mobile", "label": "骑兵", "color": Color(0.36, 0.47, 0.36)},
	{"id": "artillery", "label": "炮兵", "color": Color(0.55, 0.24, 0.18)},
]

## Same order as MilitarySupplyClass.
const SUPPLY_CLASSES: Array[Dictionary] = [
	{"id": "ration", "label": "口粮", "icon": &"military.supply.ration"},
	{"id": "fodder", "label": "草料", "icon": &"military.supply.fodder"},
	{"id": "ammunition", "label": "弹药", "icon": &"military.good.ammunition"},
	{"id": "fuel", "label": "燃料", "icon": &"military.good.fuel"},
	{"id": "upkeep", "label": "维护", "icon": &"military.supply.equipment"},
	{"id": "equipment", "label": "装备", "icon": &"military.good.body_armor"},
]

const QUALITY_NAMES: Array[String] = ["", "Q1", "Q2", "Q3", "Q4", "Q5"]
## Combat multiplier per quality tier (design §4.2).
const QUALITY_MULT: Array[float] = [1.0, 1.0, 1.2, 1.45, 1.75, 2.1]
const STANCE_LABELS := {0: "固守", 1: "推进", 2: "强攻", 3: "撤退", 4: "海运"}
const MISSION_LABELS := {0: "待命", 1: "行军", 2: "军事控制"}
const BAND_LABELS: Array[String] = ["低", "中", "高"]
const SHARE_STEP_BP := 500
const SUPPLY_HORIZON_DAYS := 30.0
## Render-snapshot army flags (military-runtime.md §9).
const FLAG_LOW_SUPPLY := 1
const FLAG_NO_RATION := 2
const FLAG_UNPAID := 4
const FLAG_LOW_MORALE := 8
const FLAG_ENGAGED := 16
const FLAG_RETREATING := 32
## Army events (40–47) that make up the battle log.
const EVENT_WAR_DECLARED := 40
const EVENT_WAR_ENDED := 41
const EVENT_BATTLE_RESOLVED := 42
const EVENT_CELL_CONTROL_CHANGED := 43
const EVENT_ARMY_DESTROYED := 44
const EVENT_COUNTRY_ANNEXED := 45
const EVENT_CONVOY_INTERCEPTED := 46
const EVENT_LEVY_APPLIED := 47
const MAX_LOG_ROWS := 8
const MAX_FRONT_ROWS := 8
## 军务档案的对阵表：单侧最多读多少支部队的详情（攻防/士气/补给）。
const DOSSIER_SIDE_ARMY_CAP := 12
const MAX_CEDE_ROWS := 16

var _model: Dictionary = {}
var _facade = null
var _country_handle := 0
var _day := -1
var _available := false
var _reason := ""
var _snapshot: Dictionary = {}
var _armies: Array = []
var _catalog: Dictionary = {}
var _unit_rows: Array = []
var _category_rows: Array = []
var _unit_index_by_id := {}
## Optional live session readers (see configure). Null in fixtures.
var _generator = null
## 会话地图（`MapData`）。生产链路由 `CountryViewModel` 显式交过来：`MapGenerator`
## 没有公开的 map getter，fixture 那条 `current_map()` 只在截图 harness 里存在。
var _map_obj = null
var _player_controller = null
var _cell_names: Dictionary = {}
var _country_names: Dictionary = {}
var _neighbor_cache: Dictionary = {}
var _event_rows: Array = []
## 军务档案单次构建内的部队详情缓存（对阵表按句柄汇总攻防）。
var _dossier_army_cache: Dictionary = {}
## Country-level per-head daily wage in MONEY_SCALE units (0 = the economy has
## not published the soldier living cost yet, so the roster says "待结算").
var _daily_wage := 0
## Stable technology ids the country has already researched. Empty with
## `_gate_known == false` means "this mount cannot see the gate" (fixture,
## offline gallery) and the roster must not filter anything out.
var _researched: Dictionary = {}
var _gate_known := false
var _tech_names: Dictionary = {}
var _tech_names_ready := false
## True once the front-edge probe answered (an empty table then means "quiet",
## not "no data source").
var _front_queried := false


func configure(model: Dictionary) -> void:
	_model = model if model != null else {}
	var section: Dictionary = _as_dict(_model.get("military", null))
	_facade = section.get("facade", null)
	_country_handle = int(section.get("country_handle", _model.get("country_handle", 0)))
	_day = int(_model.get("current_day", -1))
	_available = bool(section.get("available", false))
	_reason = String(section.get("reason", ""))
	_snapshot = _as_dict(section.get("snapshot", null))
	_catalog = _as_dict(section.get("catalog", null))
	_armies = _as_array(section.get("armies", null))
	_generator = section.get("generator", _model.get("generator", null))
	_map_obj = section.get("map", _model.get("map", null))
	_player_controller = section.get("player_controller",
		_model.get("player_controller", null))
	_cell_names = _as_dict(_model.get("cell_names", null))
	_country_names = _as_dict(_model.get("country_names", null))
	_daily_wage = int(_snapshot.get("daily_wage", 0))
	_gate_known = bool(section.get("tech_gate_known", false))
	_researched.clear()
	var researched = section.get("researched_tech_ids", null)
	if researched is PackedStringArray and _gate_known:
		for stable_id in researched:
			_researched[String(stable_id)] = true
	_neighbor_cache.clear()
	_event_rows = []
	_index_catalog()


## Drop every cached world read; the next build re-queries names, neighbours and
## the event ring. Called when the committed day or the selection changes.
func invalidate_session() -> void:
	_neighbor_cache.clear()
	_event_rows = []
	_front_queried = false


## False when the model was assembled without a live generator/controller
## (screenshot fixture, unit tests). Production callers must check this.
func session_bound() -> bool:
	return _generator != null


## Live controller handed over after configure (the panel owns it and passes it
## on when the shell rebinds); world names and target lists read through it.
func set_player_controller(controller) -> void:
	if controller == _player_controller:
		return
	_player_controller = controller
	_neighbor_cache.clear()


func build(chapter_id: String, state: Dictionary = {}) -> Dictionary:
	if not _available:
		return {"ok": false, "reason": _reason if not _reason.is_empty() else "军事机构尚未建立"}
	match chapter_id:
		"overview":
			return overview_model()
		"forces":
			return forces_model()
		"armies":
			return armies_model(int(state.get("army", 0)))
		"war":
			return war_model(int(state.get("war", 0)))
	return {"ok": false, "reason": "未知章节"}


func available() -> bool:
	return _available


func reason() -> String:
	return _reason


func facade():
	return _facade


func country_handle() -> int:
	return _country_handle


func snapshot() -> Dictionary:
	return _snapshot


func armies() -> Array:
	return _armies


func catalog() -> Dictionary:
	return _catalog


# ── catalog ──────────────────────────────────────────────────────────────

func _index_catalog() -> void:
	_unit_rows = _as_array(_catalog.get("units", null))
	_category_rows = _as_array(_catalog.get("categories", null))
	_unit_index_by_id.clear()
	for row_value in _unit_rows:
		var row := _as_dict(row_value)
		_unit_index_by_id[String(row.get("id", ""))] = int(row.get("index", -1))


func unit_row(index: int) -> Dictionary:
	return _as_dict(_unit_rows[index]) if index >= 0 and index < _unit_rows.size() else {}


func unit_index(unit_id: String) -> int:
	return int(_unit_index_by_id.get(unit_id, -1))


func unit_name(index: int) -> String:
	var unit_id := String(unit_row(index).get("id", ""))
	if unit_id.is_empty():
		return "—"
	var name := String(_as_dict(_catalog.get("display_names", null)).get(unit_id, ""))
	return name if not name.is_empty() else unit_id


func class_of(index: int) -> int:
	return clampi(int(unit_row(index).get("class", 0)), 0, UNIT_CLASSES.size() - 1)


func class_label(index: int) -> String:
	return String(UNIT_CLASSES[class_of(index)].label)


func class_color(index: int) -> Color:
	return UNIT_CLASSES[class_of(index)].color


func is_militia(index: int) -> bool:
	return bool(unit_row(index).get("militia", false))


func unit_icon(index: int) -> StringName:
	if is_militia(index):
		return &"military.unit.militia"
	var has_bow := false
	for slot_value in _as_array(unit_row(index).get("equipment", null)):
		if _category_id(int(_as_dict(slot_value).get("category", -1))) in [
				"missile_arms", "bows"]:
			has_bow = true
	return IconCatalog.military_unit_semantic_for_id(
		String(unit_row(index).get("id", "")),
		String(UNIT_CLASSES[class_of(index)].id), has_bow)


func _category_id(index: int) -> String:
	if index < 0 or index >= _category_rows.size():
		return ""
	return String(_as_dict(_category_rows[index]).get("id", ""))


func _category_label(index: int) -> String:
	var category_id := _category_id(index)
	if category_id.is_empty():
		return "—"
	var name := String(_as_dict(_catalog.get("category_names", null)).get(category_id, ""))
	return name if not name.is_empty() else category_id


## Equipment category icon. The papercut set registers every category as
## `military.good.<category_id>`, so no per-category table is needed here.
func _category_icon(index: int) -> StringName:
	var category_id := _category_id(index)
	if category_id.is_empty():
		return &"military.good.melee_arms"
	var key := StringName("military.good.%s" % category_id)
	return key if IconCatalog.has_icon(key) else &"military.good.melee_arms"


# ── unlock gate ──────────────────────────────────────────────────────────
#
# `unlock_bit` indexes the compiled catalog's `unlock_tech_ids`, `-1` meaning
# "always available" (military_core.h:123). The country's researched ids come
# from CountryFacade.snapshot()["technology_ids"], i.e. the same authority the
# native digest uses for its per-country unlock bitset — the roster never
# invents a second gate.

func gate_known() -> bool:
	return _gate_known


func unit_unlock_tech(index: int) -> String:
	var unit_id := String(unit_row(index).get("id", ""))
	return String(_as_dict(_catalog.get("unit_tech", null)).get(unit_id, ""))


## Readable technology name for the "未解锁" label. Falls back to the raw id so a
## renamed technology degrades to something clickable-looking, never to "".
func technology_name(tech_id: String) -> String:
	if tech_id.is_empty():
		return ""
	if not _tech_names_ready:
		_tech_names_ready = true
		for definition in TechnologyCatalogScript.public_definitions():
			var id := String((definition as Dictionary).get("id", ""))
			if not id.is_empty():
				_tech_names[id] = String((definition as Dictionary).get("display_name", ""))
	var name := String(_tech_names.get(tech_id, ""))
	return name if not name.is_empty() else tech_id


func unit_unlocked(index: int) -> bool:
	# A mount without a country snapshot (fixture, gallery, offline QA) cannot
	# resolve the gate, so it shows the whole catalog; production always knows.
	if not _gate_known:
		return true
	var tech_id := unit_unlock_tech(index)
	if tech_id.is_empty():
		return true
	return _researched.has(tech_id)


## Everything the roster needs for one unit, all read-only. Money values stay in
## display units (already divided by MONEY_SCALE); goods stay in the catalog's
## authored per-100 basis and are only ever printed in the tooltip.
func unit_facts(index: int) -> Dictionary:
	var unit := unit_row(index)
	var unit_id := String(unit.get("id", ""))
	var tech_id := unit_unlock_tech(index)
	var unlocked := unit_unlocked(index)
	return {
		"id": unit_id,
		"index": index,
		"name": unit_name(index),
		"class": String(UNIT_CLASSES[class_of(index)].id),
		"class_label": class_label(index),
		"era_index": int(unit.get("era", 0)),
		"era": _era_label(int(unit.get("era", 0))),
		"icon": String(unit_icon(index)),
		"militia": is_militia(index),
		"unlocked": unlocked,
		"unlock_tech": tech_id,
		"unlock_label": technology_name(tech_id),
		"attack": _raw_q16(unit.get("attack_q16", 0)),
		"defense": _raw_q16(unit.get("defense_q16", 0)),
		"speed": _raw_q16(unit.get("speed_q16", Q16)),
		"training_days": int(unit.get("training_days", 0)),
		"wage_per_100": float(_daily_wage) * 100.0 / MONEY_SCALE,
		"supply": _supply_chips(unit),
		"equipment": _equipment_chips(unit),
		"description": String(_as_dict(_catalog.get("descriptions", null)).get(unit_id, "")),
	}


## Supply classes this unit consumes while idle, one chip per non-zero class.
## `supply_idle_per_100` comes from the native catalog view, which already
## converted the authored float through `goods_from_units`: the int64 is in
## GOODS_SCALE per 100 heads per day, so only GOODS_SCALE divides it back.
func _supply_chips(unit: Dictionary) -> Array:
	var chips: Array = []
	var raw = unit.get("supply_idle_per_100", null)
	if not (raw is PackedInt64Array or raw is Array):
		return chips
	for index in range(mini(raw.size(), SUPPLY_CLASSES.size())):
		var value := float(raw[index]) / GOODS_SCALE
		if value <= 0.0001:
			continue
		chips.append({
			"id": String(SUPPLY_CLASSES[index].id),
			"label": String(SUPPLY_CLASSES[index].label),
			"icon": SUPPLY_CLASSES[index].icon,
			"value": value,
			"text": "%.2f" % value,
		})
	return chips


func _equipment_chips(unit: Dictionary) -> Array:
	var chips: Array = []
	for slot_value in _as_array(unit.get("equipment", null)):
		var slot := _as_dict(slot_value)
		if slot.is_empty():
			continue
		var category := int(slot.get("category", -1))
		var quality := clampi(int(slot.get("min_quality", 1)), 1, 5)
		chips.append({
			"id": _category_id(category),
			"label": _category_label(category),
			"icon": String(_category_icon(category)),
			"quality": quality,
			"quality_text": "Q%d" % quality,
			"per_100": float(slot.get("qty_per_100", 0)) / GOODS_SCALE,
		})
	return chips


# ── overview ─────────────────────────────────────────────────────────────

func overview_model() -> Dictionary:
	var soldiers := int(_snapshot.get("soldiers_total", 0))
	var militia := int(_snapshot.get("soldiers_militia", 0))
	var trained := int(_snapshot.get("soldiers_trained", 0))
	var training := int(_snapshot.get("soldiers_training", 0))
	var target := int(_snapshot.get("effective_target", 0))
	var deficit := maxi(0, target - soldiers - training)
	var spend := spend_breakdown()
	var pay_ratio := _ratio(_snapshot.get("pay_ratio_30_q16", 0))
	var readiness := army_readiness()
	var kpis := [
		{"id": "soldiers", "title": "兵力", "value": float(soldiers), "kind": "count",
			"icon": &"military.unit.line",
			"caption": ("目标 %s · 缺 %s" % [_count(target), _count(deficit)]) if deficit > 0
				else "目标 %s · 已达成" % _count(target),
			"tone": "warn" if deficit > 0 else ""},
		{"id": "spend", "title": "日军费", "value": float(spend.total), "kind": "money",
			"icon": &"military.army.pay", "caption": "军饷实付 %s" % _percent(pay_ratio),
			"tone": "risk" if pay_ratio < 0.5 else ("warn" if pay_ratio < 0.8 else "")},
		{"id": "morale", "title": "士气", "value": float(readiness.morale), "kind": "percent",
			"icon": &"military.army.morale", "caption": readiness.morale_caption,
			"tone": "risk" if float(readiness.morale) < 0.4 and int(readiness.count) > 0 else ""},
		{"id": "supply", "title": "补给满足", "value": float(readiness.supply), "kind": "percent",
			"icon": &"military.army.supply", "caption": readiness.supply_caption,
			"tone": "risk" if float(readiness.supply) < 0.5 and int(readiness.count) > 0 else ""},
	]
	if int(readiness.count) == 0:
		kpis[2]["kind"] = "text"
		kpis[2]["text"] = "—"
		kpis[3]["kind"] = "text"
		kpis[3]["text"] = "—"
	var garrisoned := int(_snapshot.get("soldiers_garrisoned", 0))
	var field := int(_snapshot.get("soldiers_in_armies", 0))
	return {
		"ok": true,
		"kpis": kpis,
		"composition": [
			{"label": "正规军", "text": _count(trained), "value": trained,
				"color": UITokens.DOSSIER_VERDIGRIS},
			{"label": "民兵", "text": _count(militia), "value": militia,
				"color": UITokens.DOSSIER_UMBER},
			{"label": "训练中", "text": _count(training), "value": training,
				"color": UITokens.DOSSIER_BRASS},
		],
		"composition_total": "%s 人" % _count(soldiers + training),
		"deployment": [
			{"label": "驻防", "text": _count(garrisoned), "value": garrisoned,
				"color": UITokens.DOSSIER_SLATE},
			{"label": "野战部队", "text": _count(field), "value": field,
				"color": UITokens.DOSSIER_OXBLOOD},
		],
		"deployment_total": "%d 支部队" % _armies.size(),
		"spend": spend.segments,
		"spend_total": _money_text(spend.total_raw),
		"wars": war_cards(),
		"insights": _overview_insights(soldiers, deficit, pay_ratio, readiness),
	}


func spend_breakdown() -> Dictionary:
	var payroll := int(_snapshot.get("spend_payroll_30", 0)) / 30
	var procurement := int(_snapshot.get("spend_procurement_30", 0)) / 30
	var upkeep := int(_snapshot.get("spend_upkeep_30", 0)) / 30
	var total := payroll + procurement + upkeep
	return {
		"total": float(total) / MONEY_SCALE,
		"total_raw": total,
		"segments": [
			{"label": "军饷", "text": _money_text(payroll), "value": payroll,
				"color": UITokens.DOSSIER_BRASS},
			{"label": "军需采购", "text": _money_text(procurement), "value": procurement,
				"color": UITokens.DOSSIER_VERDIGRIS},
			{"label": "维护", "text": _money_text(upkeep), "value": upkeep,
				"color": UITokens.DOSSIER_UMBER},
		],
	}


## Headcount-weighted morale and supply across field armies.
func army_readiness() -> Dictionary:
	var heads := 0.0
	var morale := 0.0
	var supply := 0.0
	var worst_supply := 2.0
	var worst_name := ""
	var low_morale := 0
	for raw in _armies:
		var army := _as_dict(raw)
		var count := float(maxi(0, int(army.get("headcount", 0))))
		var army_morale := _ratio(army.get("morale_q16", Q16))
		var army_supply := _ratio(army.get("supply_ratio_q16", Q16))
		heads += count
		morale += army_morale * count
		supply += army_supply * count
		if army_morale < 0.4:
			low_morale += 1
		if army_supply < worst_supply:
			worst_supply = army_supply
			worst_name = army_name(army)
	var weighted_morale := morale / heads if heads > 0.0 else 0.0
	var weighted_supply := supply / heads if heads > 0.0 else 0.0
	return {
		"count": _armies.size(),
		"morale": weighted_morale,
		"supply": weighted_supply,
		"low_morale": low_morale,
		"worst_supply": worst_supply if worst_supply <= 1.0 else 0.0,
		"morale_caption": ("%d 支部队士气低落" % low_morale) if low_morale > 0
			else "%d 支部队按兵力加权" % _armies.size() if _armies.size() > 0 else "尚无野战部队",
		"supply_caption": ("最低 %s %s" % [worst_name, _percent(worst_supply)])
			if not worst_name.is_empty() else "尚无野战部队",
	}


func _overview_insights(soldiers: int, deficit: int, pay_ratio: float,
		readiness: Dictionary) -> Array:
	var insights: Array = []
	if soldiers <= 0:
		insights.append(_insight("no_soldiers", "尚无兵员：先在领土上建兵营，再设定目标兵力。",
			"military.building.barracks", UITokens.DOSSIER_OXBLOOD))
	elif deficit > 0:
		insights.append(_insight("deficit",
			"距目标还缺 %s 人，兵营会在每次经济结算后继续征召。" % _count(deficit),
			"military.plan.target", UITokens.DOSSIER_BRASS))
	if pay_ratio > 0.0 and pay_ratio < 0.8:
		insights.append(_insight("low_pay", "近 30 日军饷只实付 %s，士气会持续下滑。" % _percent(pay_ratio),
			"military.army.pay", UITokens.DOSSIER_OXBLOOD))
	if int(readiness.count) > 0 and float(readiness.worst_supply) < 0.5:
		insights.append(_insight("supply", "%s。补给不足的部队会掉组织度。" % String(readiness.supply_caption),
			"military.army.supply", UITokens.DOSSIER_OXBLOOD))
	var waiting := 0
	for raw in _as_array(_snapshot.get("training", null)):
		if not bool(_as_dict(raw).get("equipment_ready", false)):
			waiting += 1
	if waiting > 0:
		insights.append(_insight("equipment", "%d 笔训练订单在等装备到货。" % waiting,
			"military.plan.training", UITokens.DOSSIER_BRASS))
	if _as_array(_snapshot.get("wars", null)).is_empty() and insights.size() < 2:
		insights.append(_insight("peace", "当前没有战争，军费全部用于常备与后勤。",
			"military.war.truce", UITokens.DOSSIER_INK_MUTED))
	return insights.slice(0, 4)


static func _insight(id: String, text: String, icon: String, accent: Color) -> Dictionary:
	return {"id": id, "text": text, "icon": icon, "accent": accent}


# ── forces ───────────────────────────────────────────────────────────────

func forces_model() -> Dictionary:
	var shares := shares_by_unit()
	var barracks := _as_array(_snapshot.get("barracks", null))
	var rows := unit_share_rows(shares)
	return {
		"ok": true,
		"target_mode": int(_snapshot.get("target_mode", 0)),
		"target_value": int(_snapshot.get("target_value", 0)),
		"per_soldier_cost": int(_snapshot.get("per_soldier_cost", 0)),
		"daily_wage": float(_daily_wage) / MONEY_SCALE,
		"shares": share_segments(shares),
		"share_total": _share_total(shares),
		"units": rows,
		"unlocked_count": unlocked_unit_count(),
		"quality_policy": int(_snapshot.get("quality_policy", 0)),
		"auto_retrain": bool(_snapshot.get("auto_retrain", true)),
		"levy_enabled": bool(_snapshot.get("levy_enabled", true)),
		"auto_discharge": bool(_snapshot.get("auto_discharge", false)),
		"barracks": barracks_rows(barracks),
		"barracks_caption": "%d 座 · 兵额 %s" % [barracks.size(),
			_count(_snapshot.get("post_count", 0))],
		"training": training_rows(),
		"training_caption": "在训 %s 人" % _count(_snapshot.get("soldiers_training", 0)),
	}


## config_share_bp is a dense array indexed by unit; keyed by stable id here.
func shares_by_unit() -> Dictionary:
	var raw = _snapshot.get("config_share_bp", PackedInt32Array())
	var shares := {}
	if not (raw is PackedInt32Array or raw is Array):
		return shares
	for index in range(raw.size()):
		var unit_id := String(unit_row(index).get("id", ""))
		if int(raw[index]) > 0 and not unit_id.is_empty():
			shares[unit_id] = int(raw[index])
	return shares


func share_segments(shares: Dictionary) -> Array:
	var segments: Array = []
	var assigned := 0
	for index in range(_unit_rows.size()):
		var unit_id := String(unit_row(index).get("id", ""))
		var bp := int(shares.get(unit_id, 0))
		if bp <= 0:
			continue
		assigned += bp
		segments.append({"id": unit_id, "label": unit_name(index), "text": _bp(bp),
			"value": bp, "color": _shade(class_color(index), segments.size())})
	var remainder := maxi(0, 10000 - assigned)
	segments.append({"id": "militia", "label": "民兵", "text": _bp(remainder),
		"value": remainder, "color": Color(0.62, 0.55, 0.44)})
	return segments


## Neighbouring segments of one class get alternating lightness so they stay distinct.
static func _shade(color: Color, ordinal: int) -> Color:
	return color.lightened(0.18) if ordinal % 2 == 1 else color


func _share_total(shares: Dictionary) -> int:
	var total := 0
	for unit_id in shares:
		total += maxi(0, int(shares[unit_id]))
	return total


## Roster rows. Only units the country can actually field are offered: a locked
## unit is shown solely when it already holds a share, so a lost gate can always
## be lowered instead of becoming an invisible, un-cancellable allocation.
## The militia closes the list: it is a real unit type and owns every unassigned
## point, so the player reads the remainder as a row instead of a caption.
func unit_share_rows(shares: Dictionary) -> Array:
	var rows: Array = []
	var total := _share_total(shares)
	for index in range(_unit_rows.size()):
		if is_militia(index):
			continue
		var unit_id := String(unit_row(index).get("id", ""))
		if unit_id.is_empty():
			continue
		var bp := int(shares.get(unit_id, 0))
		var facts := unit_facts(index)
		var locked := not bool(facts.unlocked)
		if locked and bp <= 0:
			continue
		facts["label"] = facts.name
		facts["bp"] = bp
		facts["locked"] = locked
		facts["can_raise"] = total < 10000 and not locked
		facts["color"] = class_color(index)
		rows.append(facts)
	rows.sort_custom(func(a, b):
		if int(a.era_index) != int(b.era_index):
			return int(a.era_index) < int(b.era_index)
		if not is_equal_approx(float(a.attack), float(b.attack)):
			return float(a.attack) > float(b.attack)
		return String(a.id) < String(b.id))
	var militia := _militia_row(total)
	if not militia.is_empty():
		rows.append(militia)
	_normalize_stats(rows)
	return rows


## 民兵行：占满剩余份额，永远排最后，不能加份额（它本来就是剩下的部分）。
func _militia_row(total: int) -> Dictionary:
	var index := militia_index()
	if index < 0:
		return {}
	var row := unit_facts(index)
	row["label"] = row.name
	row["bp"] = maxi(0, 10000 - total)
	row["locked"] = false
	row["can_raise"] = false
	row["color"] = class_color(index)
	row["is_militia_row"] = true
	return row


func militia_index() -> int:
	var declared := int(_catalog.get("militia_unit", -1))
	if declared >= 0 and declared < _unit_rows.size() and is_militia(declared):
		return declared
	for index in range(_unit_rows.size()):
		if is_militia(index):
			return index
	return -1


## Stat bars compare units against each other, so each ratio is scaled by the best
## value in the visible set. The printed number stays the raw catalog value.
static func _normalize_stats(rows: Array) -> void:
	var best := {"attack": 0.0, "defense": 0.0, "speed": 0.0}
	for row in rows:
		for field in best:
			best[field] = maxf(float(best[field]), float(row[field]))
	for row in rows:
		for field in best:
			var peak := float(best[field])
			var ratio := 0.0
			if peak > 0.0001:
				ratio = clampf(float(row[field]) / peak, 0.0, 1.0)
			row["%s_ratio" % field] = ratio


func locked_unit_count() -> int:
	var count := 0
	for index in range(_unit_rows.size()):
		if not is_militia(index) and not unit_unlocked(index):
			count += 1
	return count


func unlocked_unit_count() -> int:
	var count := 0
	for index in range(_unit_rows.size()):
		if not is_militia(index) and unit_unlocked(index):
			count += 1
	return count


func barracks_rows(barracks: Array) -> Array:
	var rows: Array = []
	for raw in barracks:
		var entry := _as_dict(raw)
		var cell := int(entry.get("cell", -1))
		var posts := int(entry.get("post_count", 0))
		var present := int(entry.get("present", 0))
		var paused := bool(entry.get("paused", false))
		var disrepair := bool(entry.get("disrepair", false))
		rows.append({
			"cell": cell,
			"name": cell_name(cell),
			"posts": posts,
			"present": present,
			"fill": clampf(float(present) / float(posts), 0.0, 1.0) if posts > 0 else 0.0,
			"open": maxi(0, int(entry.get("open", 0))),
			"quota": int(entry.get("quota", 0)),
			"pending": int(entry.get("pending_enlist", 0)),
			"paused": paused,
			"disrepair": disrepair,
			"status": "失修" if disrepair else ("暂停" if paused else "招募中"),
			"icon": String(IconCatalog.military_building_semantic(
				"", "barracks", _barracks_tier(posts))),
		})
	rows.sort_custom(func(a, b): return int(a.posts) > int(b.posts))
	return rows


static func _barracks_tier(posts: int) -> int:
	if posts <= 4:
		return 0
	if posts <= 10:
		return 1
	if posts <= 25:
		return 2
	if posts <= 50:
		return 3
	if posts <= 100:
		return 4
	if posts <= 200:
		return 5
	if posts <= 400:
		return 6
	return 7


func training_rows() -> Array:
	var rows: Array = []
	for raw in _as_array(_snapshot.get("training", null)):
		var order := _as_dict(raw)
		var done := int(order.get("days_done", 0))
		var total := maxi(1, int(order.get("days_total", 1)))
		var from_unit := int(order.get("from_unit", -1))
		var to_unit := int(order.get("to_unit", -1))
		var quality := clampi(int(round(float(order.get("quality_q8", 256)) / Q8)), 1, 5)
		rows.append({
			"id": int(order.get("id", 0)),
			"cell": int(order.get("cell", -1)),
			"cell_text": cell_name(int(order.get("cell", -1))),
			"from_label": "民兵" if from_unit < 0 or is_militia(from_unit) else unit_name(from_unit),
			"to_label": unit_name(to_unit),
			"icon": String(unit_icon(to_unit)),
			"count": int(order.get("count", 0)),
			"quality_text": QUALITY_NAMES[quality],
			"ready": bool(order.get("equipment_ready", false)),
			"progress": clampf(float(done) / float(total), 0.0, 1.0),
			"progress_text": "%d/%d 日" % [done, total],
		})
	rows.sort_custom(func(a, b): return float(a.progress) > float(b.progress))
	return rows


# ── armies & logistics ───────────────────────────────────────────────────

## 列表只给「哪支部队、多少人、还能不能打」；编成与补给天数在军务档案里。
func armies_model(selected: int) -> Dictionary:
	var rows: Array = []
	var selected_handle := 0
	for raw in _armies:
		var row := army_row(_as_dict(raw))
		rows.append(row)
		if int(row.handle) == selected:
			selected_handle = int(row.handle)
	if selected_handle == 0 and not rows.is_empty():
		selected_handle = int((rows[0] as Dictionary).get("handle", 0))
	var spend := spend_breakdown()
	return {
		"ok": true,
		"rows": rows,
		"selected": selected_handle,
		"convoys": convoy_rows(_as_array(_snapshot.get("convoys", null))),
		"spend": spend.segments,
		"spend_total": _money_text(spend.total_raw),
		"procurement_text": "军需采购占财政 %s" % _bp(int(_snapshot.get("procurement_share_bp", 2000))),
	}


func army_row(army: Dictionary) -> Dictionary:
	var morale := _ratio(army.get("morale_q16", Q16))
	var supply := _ratio(army.get("supply_ratio_q16", Q16))
	var warnings := army_warnings(army)
	return {
		"handle": int(army.get("handle", 0)),
		"name": army_name(army),
		"cell": int(army.get("cell", -1)),
		"cell_text": cell_name(int(army.get("cell", -1))),
		"headcount": int(army.get("headcount", 0)),
		"attack": _raw_q16(army.get("attack_q16", 0)),
		"defense": _raw_q16(army.get("defense_q16", 0)),
		"morale": morale,
		"supply": supply,
		"mission": _mission_text(army),
		"warning": ", ".join(warnings.map(func(w): return String(w.label))),
		"critical": warnings.any(func(w): return String(w.tone) == "risk"),
	}


## Flag thresholds mirror get_military_render_snapshot (military-runtime.md §9).
func army_warnings(army: Dictionary) -> Array:
	var warnings: Array = []
	if int(army.get("engagement", -1)) >= 0:
		warnings.append({"label": "交战中", "tone": "risk"})
	if _ratio(army.get("ration_ratio_q16", Q16)) < 0.25:
		warnings.append({"label": "缺粮", "tone": "risk"})
	elif _ratio(army.get("supply_ratio_q16", Q16)) < 0.5:
		warnings.append({"label": "补给低", "tone": "warn"})
	if _ratio(army.get("pay_ratio_q16", Q16)) < 0.6:
		warnings.append({"label": "欠饷", "tone": "risk"})
	if _ratio(army.get("morale_q16", Q16)) < 0.4:
		warnings.append({"label": "士气低", "tone": "warn"})
	return warnings


## `detail` is a get_military_army() dictionary (composition, supply_days, convoys);
## the list row is used as-is when the facade cannot provide it.
## `prefetched` lets the dossier page skip a second facade.army() round trip.
func army_detail(army: Dictionary, prefetched: Dictionary = {}) -> Dictionary:
	var detail := prefetched if not prefetched.is_empty() else army
	if prefetched.is_empty() and _facade != null and _facade.has_method("army"):
		var fetched = _facade.call("army", int(army.get("handle", 0)))
		if fetched is Dictionary and bool(fetched.get("ok", false)):
			detail = fetched
	var lots: Array = []
	var heads := maxf(1.0, float(detail.get("headcount", 0)))
	for raw in _as_array(detail.get("composition", null)):
		var lot := _as_dict(raw)
		var unit := int(lot.get("unit", -1))
		var quality := clampi(int(round(float(lot.get("quality_q8", 256)) / Q8)), 1, 5)
		lots.append({"id": unit * 10 + quality, "label": "%s %s" % [unit_name(unit), QUALITY_NAMES[quality]],
			"icon": String(unit_icon(unit)), "value": float(lot.get("count", 0)) / heads,
			"text": _count(lot.get("count", 0)), "color": class_color(unit)})
	var supply: Array = []
	var days = detail.get("supply_days", null)
	if days is PackedInt64Array or days is Array:
		for index in range(mini(days.size(), SUPPLY_CLASSES.size())):
			var value := float(days[index])
			var label := String(SUPPLY_CLASSES[index].label)
			if index == 3 and value <= 0.0:
				continue
			supply.append({"id": index, "label": label, "icon": SUPPLY_CLASSES[index].icon,
				"value": clampf(value / SUPPLY_HORIZON_DAYS, 0.0, 1.0),
				"text": "%d 日" % int(value), "marker": 7.0 / SUPPLY_HORIZON_DAYS,
				"color": UITokens.DOSSIER_OXBLOOD if value < 3.0 else (UITokens.DOSSIER_BRASS
					if value < 7.0 else UITokens.DOSSIER_VERDIGRIS),
				"tooltip": "%s 可支撑 %d 日" % [label, int(value)]})
	return {
		"handle": int(army.get("handle", 0)),
		"name": army_name(army),
		"meta": "%s · %s · %s" % [cell_name(int(detail.get("cell", -1))),
			String(STANCE_LABELS.get(int(detail.get("stance", 0)), "固守")), _mission_text(detail)],
		"cell": int(detail.get("cell", -1)),
		"lots": lots,
		"supply": supply,
		"warnings": army_warnings(detail),
	}


func _mission_text(army: Dictionary) -> String:
	var label := String(MISSION_LABELS.get(int(army.get("mission", 0)), "待命"))
	var target := int(army.get("target_cell", -1))
	return "%s → %s" % [label, cell_name(target)] if target >= 0 else label


## ── 军务档案（右栏页面，见 docs/ui/military-dossier.md）─────────────────
## 部队档案：KPI 4 格 + 编成 + 补给 + 战备环 + 徽记 + 同格名录。
## `same_cell` 是渲染快照里同格的部队行（{handle, owner_slot, headcount}）。
func army_dossier(handle: int, same_cell: Array = []) -> Dictionary:
	if handle == 0:
		return {"ok": false, "reason": "military_army_unknown"}
	var detail: Dictionary = {}
	if _facade != null and _facade.has_method("army"):
		var fetched = _facade.call("army", handle)
		if fetched is Dictionary and bool((fetched as Dictionary).get("ok", false)):
			detail = fetched
	if detail.is_empty():
		return {"ok": false, "reason": "military_army_unknown"}
	var info := army_detail(detail, detail)
	var owner_slot := int(detail.get("owner_slot", -1))
	var player_slot := int(_snapshot.get("country_slot", -1))
	var heads := maxi(0, int(detail.get("headcount", 0)))
	var morale := _ratio(detail.get("morale_q16", Q16))
	var pay := _ratio(detail.get("pay_ratio_q16", Q16))
	var supply := _ratio(detail.get("supply_ratio_q16", Q16))
	var ration := _ratio(detail.get("ration_ratio_q16", Q16))
	var attack := _raw_q16(detail.get("attack_q16", 0))
	var defense := _raw_q16(detail.get("defense_q16", 0))
	var speed := _raw_q16(detail.get("speed_q16", Q16))
	# 编成条按「兵种 + 品阶」分段（最多 6 段，其余归入"其他"）：
	# 一条比例带 + 一份图例就够读出编成，不再另开一张重复的名录表。
	var lots: Array = []
	for raw in _as_array(detail.get("composition", null)):
		var lot := _as_dict(raw)
		var unit := int(lot.get("unit", -1))
		var quality := clampi(int(round(float(lot.get("quality_q8", 256)) / Q8)), 1, 5)
		var count := maxi(0, int(lot.get("count", 0)))
		if count <= 0:
			continue
		lots.append({
			"label": "%s %s" % [unit_name(unit), String(QUALITY_NAMES[quality])],
			"count": count,
			"color": class_color(unit),
		})
	lots.sort_custom(func(a, b) -> bool: return int(a.count) > int(b.count))
	var segments: Array = []
	var divisor := maxf(1.0, float(heads))
	var rest := 0
	for i in lots.size():
		var lot: Dictionary = lots[i]
		if i >= 5:
			rest += int(lot.count)
			continue
		segments.append({
			"label": String(lot.label),
			"text": _count(lot.count),
			"value": float(lot.count) / divisor,
			"color": lot.color,
		})
	if rest > 0:
		segments.append({
			"label": "其他",
			"text": _count(rest),
			"value": float(rest) / divisor,
			"color": UITokens.DOSSIER_UMBER,
		})
	var badges: Array = []
	for warning in info.get("warnings", []):
		var entry := _as_dict(warning)
		badges.append({
			"text": String(entry.get("label", "")),
			"accent": UITokens.DOSSIER_OXBLOOD if String(entry.get("tone", "")) == "risk" \
				else UITokens.DOSSIER_BRASS,
		})
	var same_rows: Array = []
	for raw in same_cell:
		var other := _as_dict(raw)
		var other_handle := int(other.get("handle", 0))
		if other_handle == 0 or other_handle == handle:
			continue
		same_rows.append({
			"id": other_handle,
			"cells": {
				"name": {"text": army_name(other), "icon": "military.banner",
					"sub": cell_name(int(other.get("cell", -1)))},
				"heads": {"text": _count(other.get("headcount", 0)),
					"sort": float(other.get("headcount", 0))},
				"owner": {"text": country_name(int(other.get("owner_slot", -1)))},
			},
		})
	var own := owner_slot >= 0 and owner_slot == player_slot
	var actions := [
		{"id": "locate", "label": "定位", "enabled": true},
		{"id": "move", "label": "移动", "enabled": own},
		{"id": "area", "label": "军事控制", "enabled": own},
		{"id": "stop", "label": "停止任务", "enabled": own and int(detail.get("mission", 0)) != 0},
	]
	var remaining := 0
	var path = detail.get("path", null)
	if path is PackedInt32Array or path is Array:
		remaining = path.size()
	var note := ""
	if remaining > 0:
		note = "%s · 剩 %d 格" % [
			String(MISSION_LABELS.get(int(detail.get("mission", 0)), "行军")), remaining]
	var dominant_unit := -1
	if not _as_array(detail.get("composition", null)).is_empty():
		dominant_unit = int(_as_dict(_as_array(detail.get("composition", null))[0]).get("unit", -1))
	return {
		"ok": true, "kind": "army", "identity": "army:%d" % handle,
		"kicker": "部队档案", "title": String(info.get("name", "部队")),
		"subtitle": "%s · %s · %s" % [
			cell_name(int(detail.get("cell", -1))), country_name(owner_slot),
			String(STANCE_LABELS.get(int(detail.get("stance", 0)), "固守"))],
		"icon": unit_icon(dominant_unit) if dominant_unit >= 0 else &"military.banner",
		"accent": CountryBorderLayer.country_color(owner_slot, player_slot,
			UITokens.DOSSIER_OXBLOOD),
		"kpis": [
			{"id": "heads", "title": "兵力", "value": float(heads), "kind": "count",
				"icon": &"military.unit.line", "caption": "%d 类兵种" % segments.size()},
			{"id": "morale", "title": "士气", "value": morale, "kind": "percent",
				"icon": &"military.army.morale", "caption": "",
				"tone": "risk" if morale < 0.4 else ("warn" if morale < 0.6 else "")},
			{"id": "supply", "title": "补给", "value": supply, "kind": "percent",
				"icon": &"military.army.supply", "caption": "口粮 %s" % _percent(ration),
				"tone": "risk" if supply < 0.5 else ("warn" if supply < 0.8 else "")},
			{"id": "pay", "title": "军饷", "value": pay, "kind": "percent",
				"icon": &"military.army.pay", "caption": "",
				"tone": "risk" if pay < 0.6 else ("warn" if pay < 0.85 else "")},
		],
		"focus_cell": int(detail.get("cell", -1)),
		"selected": handle,
		"army": {
			"own": own,
			"stance": int(detail.get("stance", 0)),
			"mission_text": _mission_text(detail),
			# 攻 / 防 / 速 是平级战力数据：同一行、同一字号、同一墨色。
			"peer_stats": [
				{"label": "攻击", "text": "%.1f" % attack, "color": UITokens.DOSSIER_INK},
				{"label": "防御", "text": "%.1f" % defense, "color": UITokens.DOSSIER_INK},
				{"label": "速度", "text": "%.1f" % speed, "color": UITokens.DOSSIER_INK},
			],
			"composition": {"title": "", "total": "%s 人" % _count(heads),
				"segments": segments},
			"supply_rows": info.get("supply", []),
			"badges": badges,
			"note": note,
			"actions": actions,
			"same_cell_rows": same_rows,
		},
	}


## 战线档案：双方在同一组指标上并排对比 + 交战段名录。
## 扇区由 MilitaryMapLayers.front_sector() 聚合；每侧的攻击/防御/士气/补给由
## 扇区内**可见**部队的 facade.army() 汇总（攻防求和，士气/补给按兵力加权）。
func front_dossier(sector: Dictionary) -> Dictionary:
	if not bool(sector.get("ok", false)):
		return {}
	var player_slot := int(sector.get("player_slot", -1))
	var edge_key := int(sector.get("edge_key", -1))
	var side_rows: Array = _as_array(sector.get("sides", null))
	var owners = sector.get("owners", PackedInt32Array())
	# 两个交战方：扇区内地块的归属。一侧此刻没有部队时也要能写出国名。
	var belligerents: Array = []
	if owners is PackedInt32Array:
		for slot in owners:
			if int(slot) >= 0 and not belligerents.has(int(slot)):
				belligerents.append(int(slot))
	belligerents.sort()
	var own_slot := -1
	var enemy_slot := -1
	if belligerents.has(player_slot):
		own_slot = player_slot
		for slot in belligerents:
			if int(slot) != player_slot:
				enemy_slot = int(slot)
				break
	elif not belligerents.is_empty():
		own_slot = int(belligerents[0])
		if belligerents.size() > 1:
			enemy_slot = int(belligerents[1])
	_dossier_army_cache.clear()
	var own := _side_totals(side_rows, own_slot)
	var enemy := _side_totals(side_rows, enemy_slot)
	var advance := float(sector.get("advance", -1.0))
	var active_count := int(sector.get("active_count", 0))
	var edge_count := int(sector.get("edge_count", 0))
	var focused := int(sector.get("focus_cell", -1))
	var versus_rows := [
		_versus_row("兵力", float(own.heads), float(enemy.heads),
			_count(own.heads), _count(enemy.heads)),
		_versus_row("攻击", float(own.attack), float(enemy.attack),
			"%.1f" % float(own.attack), "%.1f" % float(enemy.attack)),
		_versus_row("防御", float(own.defense), float(enemy.defense),
			"%.1f" % float(own.defense), "%.1f" % float(enemy.defense)),
		_versus_row("士气", float(own.morale), float(enemy.morale),
			_percent(own.morale), _percent(enemy.morale)),
		_versus_row("补给", float(own.supply), float(enemy.supply),
			_percent(own.supply), _percent(enemy.supply)),
	]
	var footnote_parts := PackedStringArray()
	if advance >= 0.0:
		footnote_parts.append("推进 %s" % _percent(advance))
	footnote_parts.append("交战 %d 段" % active_count)
	footnote_parts.append("接触 %d 边" % edge_count)
	var army_rows: Array = []
	_append_side_army_rows(army_rows, side_rows, own_slot)
	_append_side_army_rows(army_rows, side_rows, enemy_slot)
	army_rows.sort_custom(func(a, b) -> bool:
		return float(a.cells.heads.sort) > float(b.cells.heads.sort))
	var engagements: Array = _as_array(sector.get("engagements", null))
	var rows: Array = []
	for raw in engagements:
		var engagement := _as_dict(raw)
		var progress := clampf(float(engagement.get("progress", 0.0)), 0.0, 1.0)
		var attacker := int(engagement.get("attacker", -1))
		rows.append({
			"id": int(_pair_key_for(
				int(engagement.get("cell_a", -1)), int(engagement.get("cell_b", -1)))),
			"tooltip": "%s ↔ %s" % [
				cell_name(int(engagement.get("cell_a", -1))),
				cell_name(int(engagement.get("cell_b", -1)))],
			"cells": {
				"zone": {"text": zone_name(int(engagement.get("cell_a", -1)))},
				"progress": {"text": _percent(progress), "value": progress,
					"bar_color": UITokens.DOSSIER_VERDIGRIS \
						if attacker == player_slot else UITokens.DOSSIER_OXBLOOD},
				"attacker": {"text": country_name(attacker)},
			},
		})
	rows.sort_custom(func(a, b) -> bool:
		return float(a.cells.progress.value) > float(b.cells.progress.value))
	var left_name := "—" if own_slot < 0 else country_name(own_slot)
	var right_name := "—" if enemy_slot < 0 else country_name(enemy_slot)
	return {
		"ok": true, "kind": "front", "identity": "front:%d" % edge_key,
		"kicker": "战线档案",
		"title": zone_name(focused) if focused >= 0 else "战线",
		"subtitle": "%s ↔ %s" % [left_name, right_name],
		"icon": &"military.war.front",
		"accent": CountryBorderLayer.country_color(
			own_slot if own_slot >= 0 else player_slot, player_slot,
			UITokens.DOSSIER_BRASS),
		"focus_cell": focused,
		"selected": edge_key,
		"front": {
			"versus": {
				"rows": versus_rows,
				"own_color": CountryBorderLayer.country_color(own_slot, player_slot,
					UITokens.DOSSIER_VERDIGRIS),
				"enemy_color": CountryBorderLayer.country_color(enemy_slot, player_slot,
					UITokens.DOSSIER_OXBLOOD),
				"own_label": "我方" if own_slot == player_slot else left_name,
				"enemy_label": "敌方" if enemy_slot != player_slot else right_name,
			},
			"footnote": " · ".join(footnote_parts),
			"army_rows": army_rows.slice(0, 8),
			"army_visible": not army_rows.is_empty(),
			"engagement_rows": rows.slice(0, 8),
			"engagement_visible": not rows.is_empty(),
		},
	}


## 一侧的汇总：兵力来自渲染快照（受迷雾门控），攻防/士气/补给来自每支部队的
## facade.army()。单侧最多读 12 支部队，其余只计入兵力，避免一次刷新打爆原生调用。
func _side_totals(sides: Array, slot: int) -> Dictionary:
	var out := {"heads": 0, "attack": 0.0, "defense": 0.0, "morale": 0.0, "supply": 0.0}
	if slot < 0:
		return out
	var weight := 0.0
	for raw in sides:
		var side := _as_dict(raw)
		if int(side.get("slot", -1)) != slot:
			continue
		out["heads"] = int(out["heads"]) + int(side.get("heads", 0))
		var handles = side.get("handles", null)
		if not (handles is Array or handles is PackedInt64Array):
			continue
		var limit := mini(handles.size(), DOSSIER_SIDE_ARMY_CAP)
		for i in limit:
			var detail := _dossier_army(int(handles[i]))
			if detail.is_empty():
				continue
			out["attack"] = float(out["attack"]) + _raw_q16(detail.get("attack_q16", 0))
			out["defense"] = float(out["defense"]) + _raw_q16(detail.get("defense_q16", 0))
			var heads := float(maxi(1, int(detail.get("headcount", 0))))
			out["morale"] = float(out["morale"]) \
				+ _ratio(detail.get("morale_q16", Q16)) * heads
			out["supply"] = float(out["supply"]) \
				+ _ratio(detail.get("supply_ratio_q16", Q16)) * heads
			weight += heads
	if weight > 0.0:
		out["morale"] = float(out["morale"]) / weight
		out["supply"] = float(out["supply"]) / weight
	return out


func _dossier_army(handle: int) -> Dictionary:
	if _dossier_army_cache.has(handle):
		return _dossier_army_cache[handle]
	var detail: Dictionary = {}
	if _facade != null and _facade.has_method("army"):
		var fetched = _facade.call("army", handle)
		if fetched is Dictionary and bool((fetched as Dictionary).get("ok", false)):
			detail = fetched
	if _dossier_army_cache.size() < 64:
		_dossier_army_cache[handle] = detail
	return detail


static func _versus_row(label: String, own_value: float, enemy_value: float,
		own_text: String, enemy_text: String) -> Dictionary:
	return {"label": label, "own_value": own_value, "enemy_value": enemy_value,
		"own_text": own_text, "enemy_text": enemy_text}


## 「在场部队」名录：把一侧的可见部队逐支列出（番号 / 兵力 / 攻击 / 归属）。
## 详情来自 front_dossier 已经读过的缓存，不会为名录再多打一次原生调用。
func _append_side_army_rows(out: Array, sides: Array, slot: int) -> void:
	if slot < 0:
		return
	for raw in sides:
		var side := _as_dict(raw)
		if int(side.get("slot", -1)) != slot:
			continue
		var handles = side.get("handles", null)
		if not (handles is Array or handles is PackedInt64Array):
			continue
		for i in mini(handles.size(), DOSSIER_SIDE_ARMY_CAP):
			var detail := _dossier_army(int(handles[i]))
			if detail.is_empty():
				continue
			out.append({
				"id": int(handles[i]),
				"cells": {
					"name": {"text": army_name(detail)},
					"heads": {"text": _count(detail.get("headcount", 0)),
						"sort": float(detail.get("headcount", 0))},
					"attack": {"text": "%.1f" % _raw_q16(detail.get("attack_q16", 0))},
					"owner": {"text": country_name(slot)},
				},
			})


static func _pair_key_for(cell_a: int, cell_b: int) -> int:
	return mini(cell_a, cell_b) * 131072 + maxi(cell_a, cell_b)


func _condition_color(value: float) -> Color:
	if value < 0.4:
		return UITokens.DOSSIER_OXBLOOD
	if value < 0.7:
		return UITokens.DOSSIER_BRASS
	return UITokens.DOSSIER_VERDIGRIS


func convoy_rows(convoys: Array) -> Array:
	var rows: Array = []
	for raw in convoys:
		var convoy := _as_dict(raw)
		var risk := _ratio(convoy.get("risk_q16", 0))
		rows.append({
			"id": int(convoy.get("id", 0)),
			"cell": int(convoy.get("current_cell", -1)),
			"route": "%s → %s" % [cell_name(int(convoy.get("current_cell", -1))),
				cell_name(int(convoy.get("dest_cell", -1)))],
			"goods": _good_label(int(convoy.get("good", -1))),
			"risk": risk,
			"eta": maxi(0, int(convoy.get("eta_day", 0)) - _day),
		})
	rows.sort_custom(func(a, b): return float(a.risk) > float(b.risk))
	return rows


func _good_label(dense_id: int) -> String:
	var ordered = _model.get("good_ids", PackedStringArray())
	if not (ordered is PackedStringArray) or dense_id < 0 or dense_id >= ordered.size():
		return "物资 #%d" % dense_id
	var stable_id := String(ordered[dense_id])
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	return String(profile.display_name) if profile != null else stable_id


# ── war ──────────────────────────────────────────────────────────────────

func war_cards() -> Array:
	var cards: Array = []
	for raw in _as_array(_snapshot.get("wars", null)):
		cards.append(war_card(_as_dict(raw)))
	return cards


## 战争章节只放索引：在打谁、打了多久、战争分怎么来的、周边有哪些邻国可以开战。
## 条款草稿与占领格勾选在议和面板自己的模型里（MilitaryPeaceViewModel），
## 会战记录在军务档案里，所以这里不再预取 ceded / log。
func war_model(selected: int) -> Dictionary:
	var wars := war_cards()
	var current: Dictionary = {}
	for war in wars:
		if int(war.id) == selected:
			current = war
	if current.is_empty() and not wars.is_empty():
		current = wars[0]
	return {
		"ok": true,
		"wars": wars,
		"selected": int(current.get("id", 0)),
		"declare": declare_candidates(),
		"fronts": front_rows(),
		"front_source": _front_queried,
	}


func war_card(war: Dictionary) -> Dictionary:
	var my_slot := int(_snapshot.get("country_slot", -1))
	# A card without the country slot (older fixture shapes) is the player's own
	# war as the attacker; anything else is compared against the slot only, so a
	# missing slot never silently flips which side is "us".
	var attacker := int(war.get("attacker_slot", -1)) == my_slot
	if my_slot < 0 and not war.has("attacker_slot"):
		attacker = bool(war.get("attacker", true))
	var enemy_slot := int(war.get("defender_slot" if attacker else "attacker_slot",
		war.get("enemy_slot", -1)))
	var score := float(war.get("score_q16", 0)) / Q16 * 100.0
	var parts: Array = []
	var raw_parts := _as_dict(war.get("score_parts", null))
	if not raw_parts.is_empty():
		for spec in [["battle", "会战", &"military.war.battle"],
				["occupation", "占领", &"military.plan.target"],
				["annihilation", "歼灭", &"military.army.attack"],
				["attrition", "损耗", &"military.army.defense"]]:
			var value := float(raw_parts.get(String(spec[0]), 0.0))
			parts.append({"id": String(spec[0]), "label": String(spec[1]), "icon": spec[2],
				"value": clampf(value / 40.0, -1.0, 1.0), "text": "%+.0f" % value})
	var days := maxi(0, _day - int(war.get("start_day", _day)))
	var our_losses := int(war.get("attacker_losses" if attacker else "defender_losses", 0))
	var enemy_losses := int(war.get("defender_losses" if attacker else "attacker_losses", 0))
	var our_slot := int(war.get("attacker_slot" if attacker else "defender_slot", -1))
	var engagement := engagement_between(our_slot, int(enemy_slot))
	return {
		"id": int(war.get("war_id", 0)),
		"enemy_name": country_name(enemy_slot),
		"role": "进攻方" if attacker else "防守方",
		"days": days,
		"score": score,
		"score_text": "%+.0f" % score,
		"score_parts": parts,
		"our_losses": our_losses,
		"enemy_losses": enemy_losses,
		"losses_text": "我方伤亡 %s · 敌方伤亡 %s" % [_count(our_losses), _count(enemy_losses)],
		"fully_occupied": bool(war.get("fully_occupied", false)),
		"engagement": engagement,
		"battle": not engagement.is_empty() and bool(engagement.get("battle", false)),
	}


## ── fronts & battles (military_core engagements / front_edges) ───────────

## Live engagements as rows. `zone_a`/`zone_b` come from the probe in the
## controller (the native table is not exported), region names from Country.
func engagement_rows() -> Array:
	var rows: Array = []
	for raw in _as_array(_snapshot.get("engagements", null)):
		var row := _as_dict(raw)
		var progress := _ratio(row.get("progress_q16", Q16 / 2))
		var days := maxi(0, _day - int(row.get("start_day", _day)))
		var attacker := int(row.get("attacker_slot", -1))
		var label := String(row.get("battle_label", ""))
		rows.append({
			"cell_a": int(row.get("cell_a", -1)),
			"cell_b": int(row.get("cell_b", -1)),
			"attacker_slot": attacker,
			"defender_slot": int(row.get("defender_slot", -1)),
			"progress": progress,
			"progress_text": "%d%%" % int(round(progress * 100.0)),
			"days": days,
			"days_text": "已接战 %d 日" % days if days > 0 else "今日接战",
			"battle": bool(row.get("battle", false)),
			"label": label if not label.is_empty() else "%s ↔ %s" % [
				String(row.get("zone_a", cell_name(int(row.get("cell_a", -1))))),
				String(row.get("zone_b", cell_name(int(row.get("cell_b", -1)))))],
			"attacker_name": country_name(attacker),
			"zone_a": String(row.get("zone_a", cell_name(int(row.get("cell_a", -1))))),
			"zone_b": String(row.get("zone_b", cell_name(int(row.get("cell_b", -1))))),
		})
	return rows


func engagement_between(slot_a: int, slot_b: int) -> Dictionary:
	for row in engagement_rows():
		var attacker := int(row.attacker_slot)
		var defender := int(row.defender_slot)
		if (attacker == slot_a and defender == slot_b) \
				or (attacker == slot_b and defender == slot_a):
			return row
	return {}


## Front-edge keys (cell * 6 + direction) collapsed into per-cell counts: the UI
## cannot draw a ribbon, but it can say which sectors are contested.
func front_rows() -> Array:
	# The render snapshot carries the per-edge progress byte but not the keys
	# (they only feed MilitaryFrontLayer), so the controller hands both over.
	var keys = _snapshot.get("front_edge_keys", PackedInt32Array())
	if not (keys is PackedInt32Array) and _player_controller != null \
			and _player_controller.has_method("military_front_probe"):
		var probe = _player_controller.call("military_front_probe")
		if probe is Dictionary:
			keys = (probe as Dictionary).get("keys", PackedInt32Array())
			_snapshot["front_edge_progress"] = (probe as Dictionary).get(
				"progress", PackedByteArray())
	if not (keys is PackedInt32Array):
		return []
	_front_queried = true
	var counts := {}
	var progress = _snapshot.get("front_edge_progress", PackedByteArray())
	for i in range(keys.size()):
		var cell := int(keys[i]) / 6
		var entry: Dictionary = counts.get(cell, {"count": 0, "progress": -1})
		entry["count"] = int(entry["count"]) + 1
		if progress is PackedByteArray and i < progress.size() and int(progress[i]) != 255:
			entry["progress"] = int(progress[i])
		counts[cell] = entry
	var rows: Array = []
	for cell in counts.keys():
		var entry: Dictionary = counts[cell]
		var zone := zone_name(int(cell))
		var zone_row: Dictionary = {}
		for row in rows:
			if String(row.zone) == zone:
				zone_row = row
				break
		if zone_row.is_empty():
			zone_row = {"zone": zone, "cell": int(cell), "edges": [], "count": 0,
				"progress": -1}
			rows.append(zone_row)
		(zone_row.edges as Array).append(int(cell))
	var out: Array = []
	for row in rows:
		var best := -1
		for cell in row.edges:
			best = maxi(best, int((counts[cell] as Dictionary).get("progress", -1)))
		out.append({
			"id": String(row.zone),
			"zone": String(row.zone),
			"cell": int(row.cell),
			"edges": (row.edges as Array).size(),
			"progress": maxf(0.0, float(best) / 254.0),
			"progress_text": "交战中" if best >= 0 else "—",
			"text": "交战中" if best >= 0 else "对峙",
		})
	out.sort_custom(func(a, b): return int(a.edges) > int(b.edges))
	return out.slice(0, MAX_FRONT_ROWS)


## ── battle log (native event ring 40–47) ─────────────────────────────────

func war_log() -> Array:
	if _event_rows.is_empty():
		_event_rows = _read_events()
	var rows: Array = []
	for raw in _event_rows:
		var event := _as_dict(raw)
		var event_type := int(event.type)
		var is_battle := event_type in [EVENT_BATTLE_RESOLVED, EVENT_ARMY_DESTROYED,
			EVENT_CELL_CONTROL_CHANGED, EVENT_CONVOY_INTERCEPTED]
		if not is_battle:
			continue
		var scored := _battle_log_label(int(event.get("cell", -1)), int(event.get("war_id", -1)))
		if not scored.is_empty():
			event["scored"] = scored
		rows.append(_event_row(event))
	rows.reverse()
	return rows.slice(0, MAX_LOG_ROWS)


## True when the native military event ring (types 40-47) can be read at all. The
## workspace says "战报需要军事运行时的事件流" only when this is false.
func event_log_available() -> bool:
	if _facade != null and _facade.has_method("poll_events"):
		return true
	return _player_controller != null \
		and _player_controller.has_method("military_events_probe")


## True when the core's scored battle log (MilitaryBattleLogRow, saved in PKMI) is
## readable. The bridge exports no accessor yet, so this reports false and the
## event ring carries the log.
func scored_log_available() -> bool:
	if _player_controller == null or not _player_controller.has_method("battle_log_probe"):
		return false
	var probe = _player_controller.call("battle_log_probe")
	return probe is Dictionary and bool((probe as Dictionary).get("available", false))


func _read_events() -> Array:
	var batch = null
	if _facade != null and _facade.has_method("poll_events"):
		batch = _facade.call("poll_events", 0, 512)
	elif _player_controller != null and _player_controller.has_method("military_events_probe"):
		# Production path: CountryViewModel does not hand the façade down, so the
		# controller forwards the military event ring (same native ring).
		batch = _player_controller.call("military_events_probe", 512)
	return batch if batch is Array else []


## MilitaryBattleLogRow (last 64 battles, core-owned, saved in PKMI) is not
## exported by the bridge. The probe reports "cell|war|day" of the newest row so
## the newest matching event can be marked as scored until it is. The second
## element is the row count, so an empty log counts as a resolved probe.
func _battle_log_label(cell: int, war_id: int) -> String:
	if _player_controller == null or not _player_controller.has_method("battle_log_probe"):
		return ""
	var probe = _player_controller.call("battle_log_probe")
	if not (probe is Dictionary) or not bool((probe as Dictionary).get("available", false)):
		return ""
	var newest := String((probe as Dictionary).get("newest", ""))
	var count := int((probe as Dictionary).get("count", 0))
	if count > 0 and newest == "%d|%d" % [cell, war_id]:
		return "已计分"
	return ""


func _event_row(event: Dictionary) -> Dictionary:
	var event_type := int(event.type)
	var cell := int(event.cell)
	var team := ""
	var text := ""
	match event_type:
		EVENT_WAR_DECLARED:
			text = "%s 向 %s 宣战" % [country_name(int(event.i0)), country_name(int(event.i1))]
		EVENT_WAR_ENDED:
			text = "战争结束：%s" % ("吞并" if int(event.i0) == 2 else "和约")
			if int(event.i1) > 0:
				text += "，割地 %d 格" % int(event.i1)
		EVENT_BATTLE_RESOLVED:
			var winner := int(event.i0)
			var loser := int(event.i1)
			team = "我方" if winner == int(_snapshot.get("country_slot", -1)) else "敌方"
			text = "%s 于 %s 击退 %s，损失 %s 人" % [country_name(winner), zone_name(cell),
				country_name(loser), _count(event.value)]
		EVENT_CELL_CONTROL_CHANGED:
			text = "%s 被 %s 占领" % [zone_name(cell), country_name(int(event.i0))]
		EVENT_ARMY_DESTROYED:
			text = "%s 的部队在 %s 被歼灭（%s 人）" % [country_name(int(event.i1)),
				zone_name(cell), _count(event.value)]
		EVENT_CONVOY_INTERCEPTED:
			text = "%s 的车队在 %s 被截（货值 %s）" % [country_name(int(event.i1)),
				zone_name(cell), _money_text(event.value)]
		_:
			text = String(event.get("text", ""))
	return {
		"id": int(event.get("id", 0)),
		"day": int(event.get("day", 0)),
		"type": event_type,
		"text": text,
		"detail": String(event.get("scored", "")),
		"team": team,
		"kind": {"42": "会战", "43": "占领", "44": "歼灭", "46": "截击"}.get(str(event_type), "战事"),
		"cell": cell,
	}


## ── declare war (neighbouring countries from the live territory map) ─────

func declare_candidates() -> Array:
	var rows: Array = []
	var regions := _region_map()
	var my_slot := int(_snapshot.get("country_slot", -1))
	for slot in regions.keys():
		if int(slot) == my_slot:
			continue
		var region: Dictionary = regions[slot]
		var handle := _handle_for_slot(int(slot))
		var status := _war_status(int(slot))
		var reason := String(status.reason)
		# A country without a Country handle cannot be addressed by war.declare;
		# saying so beats sending a command that the runtime rejects.
		if handle == 0 and reason.is_empty():
			reason = "缺少国家句柄"
		rows.append({
			"id": handle if handle != 0 else -1 - int(slot),
			"slot": int(slot),
			"handle": handle,
			"name": country_name(int(slot)),
			"cells": int(region.cells),
			"capital": _capital_name(handle),
			"war": bool(status.war),
			"truce_until": int(status.truce_until),
			"can_declare": reason.is_empty(),
			"reason": reason,
		})
	rows.sort_custom(func(a, b):
		if bool(a.can_declare) != bool(b.can_declare):
			return bool(a.can_declare)
		return int(a.cells) > int(b.cells))
	return rows


## slot -> {cells}: how many cells of each foreign country touch the player's
## territory. 1 = one hex ring, 2 = inside the widest command radius.
func _region_map() -> Dictionary:
	var key := "%d" % int(_country_handle)
	if _neighbor_cache.has(key):
		return _neighbor_cache[key]
	var regions := {}
	if _map() != null:
		regions = _scan_regions()
	_neighbor_cache[key] = regions
	return regions


## 会话地图：模型显式给的优先，其次 fixture 的 `current_map()`。
func _map():
	if _map_obj != null:
		return _map_obj
	return CountryMapQuery.map_of(_generator)


## Neighbour scan over the territory mirror. Returns {} when the session does not
## expose a map (fixture/offline mount). The owner array comes from
## `CountryMapQuery`, i.e. `MapData.country_slot_arr` first — the same mirror the
## borders and the fog are solved from.
func _scan_regions() -> Dictionary:
	var regions := {}
	var owners := CountryMapQuery.owner_map(_generator, _model, _map())
	var neighbors := CountryMapQuery.neighbors_of(_generator, _map())
	if owners.is_empty() or neighbors.size() < owners.size() * 6:
		return regions
	var my_slot := _player_slot()
	var frontier: Array = []
	for cell in range(owners.size()):
		if int(owners[cell]) == my_slot:
			frontier.append(cell)
	var seen := PackedByteArray()
	seen.resize(owners.size())
	# Ring 1 is real adjacency; ring 2 exists only so the radius picker can show
	# targets it would reach. `adjoining` keeps the two apart.
	for ring in range(1, 3):
		var next: Array = []
		for cell in frontier:
			for offset_value in _neighbor_offsets(neighbors, int(cell)):
				var neighbor := int(cell) + int(offset_value)
				if neighbor < 0 or neighbor >= owners.size() or int(seen[neighbor]) != 0:
					continue
				seen[neighbor] = 1
				next.append(neighbor)
				var slot := int(owners[neighbor])
				if slot < 0 or slot == my_slot:
					continue
				var entry: Dictionary = regions.get(slot, {"cells": 0, "adjoining": false})
				entry.cells = int(entry.cells) + 1
				entry.adjoining = bool(entry.adjoining) or ring == 1
				regions[slot] = entry
		frontier = next
	return regions


## The six neighbour indices of a cell (seam wrapped). MapData owns the layout;
## military_front_layer uses the same packed array (cell * 6 + direction).
func _neighbor_offsets(neighbors: PackedInt32Array, cell: int) -> Array:
	var offsets: Array = []
	var base := cell * 6
	if neighbors.size() < base + 6:
		return offsets
	for direction in range(6):
		var neighbor := int(neighbors[base + direction])
		if neighbor >= 0:
			offsets.append(neighbor - cell)
	return offsets


## A war with this country blocks a declaration until the truce expires.
func _war_status(slot: int) -> Dictionary:
	for war in _as_array(_snapshot.get("wars", null)):
		var row := _as_dict(war)
		if int(row.get("attacker_slot", -1)) == slot \
				or int(row.get("defender_slot", -1)) == slot:
			return {"war": true, "truce_until": -1, "reason": "正在交战"}
	if _player_controller != null and _player_controller.has_method("military_truce_until"):
		var until := int(_player_controller.call("military_truce_until", slot))
		if until > _day:
			return {"war": false, "truce_until": until,
				"reason": "停战至第 %d 日" % until}
	return {"war": false, "truce_until": -1, "reason": ""}


func _handle_for_slot(slot: int) -> int:
	var key := "handle_%d" % slot
	if _neighbor_cache.has(key):
		return int(_neighbor_cache[key])
	var section := _as_dict(_model.get("military", null))
	var handles: Dictionary = _as_dict(section.get("country_handles", null))
	var handle := CountryMapQuery.handle_for_slot(_owner_map(), slot,
		_country_facade(), handles, _slot_first_cells())
	_neighbor_cache[key] = handle
	return handle


## 槽位 → 该国领土首格。句柄只能按「拿一个格去问 Country」解析，所以这张表必须
## 一次扫完并缓存：每个槽位重扫一遍归属镜像在十万格地图上是平方级开销。
func _slot_first_cells() -> Dictionary:
	if _neighbor_cache.has("__slot_cells__"):
		return _neighbor_cache["__slot_cells__"]
	var cells := CountryMapQuery.first_cell_by_slot(_owner_map())
	_neighbor_cache["__slot_cells__"] = cells
	return cells


## 玩家自己在这个会话里的槽位。军事快照最权威；军事机构未接通时退回句柄低 32 位
## 的编码（`make_handle = generation << 32 | slot`），这里只用于排除本国。
func _player_slot() -> int:
	var slot := int(_snapshot.get("country_slot", -1))
	if slot >= 0:
		return slot
	return CountryMapQuery.slot_of_handle(_country_handle)


func _capital_name(handle: int) -> String:
	if handle == 0:
		return ""
	var facade = _country_facade()
	if facade == null or not facade.has_method("snapshot"):
		return ""
	var snapshot = facade.call("snapshot", handle)
	if not (snapshot is Dictionary) or not bool((snapshot as Dictionary).get("ok", false)):
		return ""
	return cell_name(int((snapshot as Dictionary).get("cell", -1)))


## ── occupied cells for the peace draft (design §12.3) ───────────────────

## Cells of the war's enemy that we currently control. Native
## `get_military_control_snapshot()` carries no owner column, so the owner comes
## from Country's territory map (same seam as declare_candidates).
func ceded_cells(war: Dictionary, checked: Dictionary = {}) -> Dictionary:
	if war.is_empty():
		return {"rows": [], "cells": [], "total": 0, "checked": 0}
	var my_slot := int(_snapshot.get("country_slot", -1))
	var attacker := int(war.get("attacker_slot", -1)) == my_slot
	var enemy_slot := int(war.get("defender_slot" if attacker else "attacker_slot", -1))
	var control := _as_dict(_snapshot.get("control", null))
	# 原生国家快照不带 control 段（它只在自己的 country_snapshot 里），生产环境要
	# 问一次军事 facade：否则议和窗口的割地候选永远是空的。
	if control.is_empty() and _facade != null and _facade.has_method("control_snapshot"):
		control = _as_dict(_facade.call("control_snapshot"))
	var cells = control.get("cells", PackedInt32Array())
	var slots = control.get("controller_slots", PackedInt32Array())
	if not (cells is PackedInt32Array) or not (slots is PackedInt32Array) \
			or cells.size() != slots.size():
		return {"rows": [], "cells": [], "total": 0, "checked": 0}
	var owners = _owner_map()
	var rows: Array = []
	var selected: Array = []
	for i in range(cells.size()):
		if int(slots[i]) != my_slot:
			continue
		var cell := int(cells[i])
		# No owner column in the control snapshot: keep the cell when Country
		# cannot say whose it is either, rather than silently dropping the term.
		if enemy_slot >= 0 and cell < owners.size() and int(owners[cell]) != enemy_slot:
			continue
		var is_checked := bool(checked.get(cell, true))
		if is_checked:
			selected.append(cell)
		var owner := _owner_label(cell, owners)
		rows.append({
			"id": cell,
			"cell": cell,
			"label": cession_label(cell, owners),
			"note": ("原属%s" % owner) if not owner.is_empty() else "",
			"tooltip": "%s · 我方占领\n勾选后写进和议条款" % zone_name(cell),
		})
	return {"rows": rows, "cells": selected, "total": rows.size(), "checked": selected.size()}


func _owner_map() -> PackedInt32Array:
	if _neighbor_cache.has("__owners__"):
		return _neighbor_cache["__owners__"]
	var owners := CountryMapQuery.owner_map(_generator, _model, _map())
	_neighbor_cache["__owners__"] = owners
	return owners


## One occupied cell of the peace draft. The region name alone repeats for every
## cell of a region, so the cell's own name is what tells them apart; the index
## only shows up when neither the generator nor Country can name it.
func cession_label(cell: int, owners: PackedInt32Array) -> String:
	var zone := zone_name(cell)
	var name := cell_name(cell)
	if name.begins_with("地块 #"):
		return zone
	if zone.ends_with(name):
		return zone
	return "%s · %s" % [zone, name]


func _owner_label(cell: int, owners: PackedInt32Array) -> String:
	if owners.is_empty() or cell < 0 or cell >= owners.size() or int(owners[cell]) < 0:
		return ""
	return country_name(int(owners[cell]))


## Preview of a peace draft. The native evaluator is authoritative; the local
## estimate is only used when the facade is absent (tests, old saves).
func evaluate_peace(war_id: int, war_score: float, terms: Array) -> Dictionary:
	if terms.is_empty():
		return {"ok": true, "price": 0.0, "band": -1}
	if _facade != null and _facade.has_method("evaluate_peace"):
		var result = _facade.call("evaluate_peace", war_id, _country_handle, terms)
		if result is Dictionary and result.has("price"):
			var band := ["low", "mid", "high"].find(String(result.get("band", "low")))
			return {"ok": bool(result.get("ok", false)), "price": float(result.price),
				"band": maxi(band, 0), "reason": String(result.get("reason", ""))}
	var price := 0.0
	for term_value in terms:
		var term := _as_dict(term_value)
		match String(term.get("kind", "")):
			"annex":
				price += 100.0
			"lump_sum":
				price += float(term.get("amount", 0.0)) / 2000.0
			"installments":
				price += float(term.get("amount", 0.0)) * float(term.get("n", 0)) / 2600.0
			"ceding":
				price += float(term.get("n", 0)) * 2.0
	var available := maxf(0.0, war_score)
	var band := 0
	if available > 0.0:
		band = 2 if price <= available * 0.6 else (1 if price <= available else 0)
	return {"ok": true, "price": price, "band": band}


# ── naming ───────────────────────────────────────────────────────────────

## Region name of a cell. Territory names are authored by the world generator
## (MapGenerator.region_name_for_cell); the owner name comes from Country. A bare
## index is the last resort, so a missing name in production stays visible.
func zone_name(cell: int) -> String:
	if cell < 0:
		return "—"
	var region := ""
	if _generator != null and _generator.has_method("region_name_for_cell"):
		region = String(_generator.call("region_name_for_cell", cell)).strip_edges()
	if region.is_empty():
		# Fixture/offline stand-in for the generator's region names.
		region = String(_as_dict(_as_dict(_model.get("military", null)).get(
			"region_names", null)).get(cell, ""))
	var owner := cell_owner_name(cell)
	# A region with no authored name is said out loud ("青川国境内"): falling
	# through to the fixture's cell table here is exactly how a production
	# "地块 #1467" would look like a real name.
	if not region.is_empty():
		return "%s·%s" % [region, owner] if not owner.is_empty() else region
	return "%s境内" % owner if not owner.is_empty() else cell_name(cell)


func cell_name(cell: int) -> String:
	if cell < 0:
		return "—"
	var name := String(_cell_names.get(cell, ""))
	return name if not name.is_empty() else "地块 #%d" % cell


func army_name(army: Dictionary) -> String:
	var handle := int(army.get("handle", 0))
	var name := String(_as_dict(_model.get("army_names", null)).get(handle, ""))
	return name if not name.is_empty() else "第 %d 军" % ((handle & 0xFFFFFFFF) + 1)


## Country display name by slot. The shell's model normally carries
## `country_names`; without it the name still comes from the real Country runtime
## (same slot -> handle encoding as NativeCountryRuntime::make_handle, read back
## through facade.snapshot()), never from a hand-made table.
func country_name(slot: int) -> String:
	if slot < 0:
		return "敌国"
	var name := String(_country_names.get(slot, ""))
	if not name.is_empty():
		return name
	name = _facade_country_name(slot)
	return name if not name.is_empty() else "第 %d 国" % (slot + 1)


## Display name straight from Country, cached per slot for this model build so a
## table with forty neighbours costs forty snapshot calls, once.
func _facade_country_name(slot: int) -> String:
	var key := "name_%d" % slot
	if _neighbor_cache.has(key):
		return String(_neighbor_cache[key])
	var resolved := CountryMapQuery.country_name(_country_facade(), _handle_for_slot(slot))
	_neighbor_cache[key] = resolved
	return resolved


## Country facade for name/capital lookups. The controller forwards it in game;
## the generator is the fallback for callers that mount the panel on their own.
func _country_facade():
	if _player_controller != null and _player_controller.has_method("get_country_facade"):
		var facade = _player_controller.call("get_country_facade")
		if facade != null:
			return facade
	if _generator != null and _generator.has_method("get_country_facade"):
		return _generator.call("get_country_facade")
	return null


## Owner name of one cell, straight from Country's territory map. This is the
## same source the rest of the country UI names cells with; the workspace shell
## does not hand the military view model a name table.
func cell_owner_name(cell: int) -> String:
	var owners := _owner_map()
	if owners.is_empty() or cell < 0 or cell >= owners.size() or int(owners[cell]) < 0:
		return ""
	return country_name(int(owners[cell]))


static func _era_label(era: int) -> String:
	var eras := ["石器", "农耕", "王国", "帝国", "探索", "启蒙", "蒸汽", "电气", "原子", "信息", "智能"]
	return String(eras[clampi(era, 0, eras.size() - 1)])


# ── formatting ───────────────────────────────────────────────────────────

static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}


static func _as_array(value) -> Array:
	return value if value is Array else []


static func money(raw) -> float:
	return float(raw) / MONEY_SCALE


static func _money_text(raw) -> String:
	return UITokens.format_compact_number_cn(float(raw) / MONEY_SCALE, 2)


static func _count(raw) -> String:
	return UITokens.format_compact_number_cn(float(raw), 1)


static func _ratio(raw) -> float:
	return clampf(float(raw) / Q16, 0.0, 1.0)


static func _raw_q16(raw) -> float:
	return float(raw) / Q16


static func _percent(value: float) -> String:
	return "%d%%" % int(round(clampf(value, 0.0, 1.0) * 100.0))


static func _bp(raw) -> String:
	return "%.0f%%" % (float(raw) / BP * 100.0)
