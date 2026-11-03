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
var _player_controller = null
var _cell_names: Dictionary = {}
var _country_names: Dictionary = {}
var _neighbor_cache: Dictionary = {}
var _event_rows: Array = []
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
	_player_controller = section.get("player_controller",
		_model.get("player_controller", null))
	_cell_names = _as_dict(_model.get("cell_names", null))
	_country_names = _as_dict(_model.get("country_names", null))
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
			return war_model(int(state.get("war", 0)),
				_as_dict(state.get("ceding", null)))
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
	return {
		"ok": true,
		"target_mode": int(_snapshot.get("target_mode", 0)),
		"target_value": int(_snapshot.get("target_value", 0)),
		"per_soldier_cost": int(_snapshot.get("per_soldier_cost", 0)),
		"shares": share_segments(shares),
		"share_total": _share_total(shares),
		"units": unit_share_rows(shares),
		"quality_policy": int(_snapshot.get("quality_policy", 0)),
		"auto_retrain": bool(_snapshot.get("auto_retrain", true)),
		"levy_enabled": bool(_snapshot.get("levy_enabled", true)),
		"auto_discharge": bool(_snapshot.get("auto_discharge", false)),
		"barracks": barracks_rows(barracks),
		"barracks_caption": "%d 座 · 兵额 %s" % [barracks.size(),
			_count(_snapshot.get("post_count", 0))],
		"training": training_rows(),
		"training_caption": "在训 %s 人" % _count(_snapshot.get("soldiers_training", 0)),
		"codex": codex_cards(),
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


func unit_share_rows(shares: Dictionary) -> Array:
	var rows: Array = []
	var total := _share_total(shares)
	for index in range(_unit_rows.size()):
		var unit_id := String(unit_row(index).get("id", ""))
		if unit_id.is_empty() or is_militia(index):
			continue
		var bp := int(shares.get(unit_id, 0))
		rows.append({
			"id": unit_id,
			"label": unit_name(index),
			"class": class_label(index),
			"icon": String(unit_icon(index)),
			"era": _era_label(int(unit_row(index).get("era", 0))),
			"bp": bp,
			"can_raise": total < 10000,
			"color": class_color(index),
		})
	return rows


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


func codex_cards() -> Array:
	var cards: Array = []
	for index in range(_unit_rows.size()):
		cards.append(unit_card(index))
	return cards


func unit_card(index: int) -> Dictionary:
	var unit := unit_row(index)
	var slots: Array = []
	var min_quality := 1
	for raw in _as_array(unit.get("equipment", null)):
		var slot := _as_dict(raw)
		var quality := clampi(int(slot.get("min_quality", 1)), 1, 5)
		min_quality = maxi(min_quality, quality)
		slots.append("%s ≥%s · %.0f/百人" % [_category_label(int(slot.get("category", -1))),
			QUALITY_NAMES[quality], float(slot.get("qty_per_100", 0)) / GOODS_SCALE])
	var unit_id := String(unit.get("id", ""))
	return {
		"id": unit_id,
		"name": unit_name(index),
		"class": String(UNIT_CLASSES[class_of(index)].id),
		"subtitle": "%s · %s" % [class_label(index), _era_label(int(unit.get("era", 0)))],
		"icon": String(unit_icon(index)),
		"militia": is_militia(index),
		"attack_text": "%.1f" % _raw_q16(unit.get("attack_q16", 0)),
		"defense_text": "%.1f" % _raw_q16(unit.get("defense_q16", 0)),
		"speed_text": "%.1f" % _raw_q16(unit.get("speed_q16", Q16)),
		"training_text": "%d 日" % int(unit.get("training_days", 0)),
		"min_quality": min_quality,
		"equipment": slots,
		"description": String(_as_dict(_catalog.get("descriptions", null)).get(unit_id, "")),
	}


# ── armies & logistics ───────────────────────────────────────────────────

func armies_model(selected: int) -> Dictionary:
	var rows: Array = []
	var selected_row: Dictionary = {}
	for raw in _armies:
		var row := army_row(_as_dict(raw))
		rows.append(row)
		if int(row.handle) == selected:
			selected_row = _as_dict(raw)
	if selected_row.is_empty() and not _armies.is_empty():
		selected_row = _as_dict(_armies[0])
	var spend := spend_breakdown()
	return {
		"ok": true,
		"rows": rows,
		"selected": int(selected_row.get("handle", 0)),
		"detail": army_detail(selected_row) if not selected_row.is_empty() else {},
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
func army_detail(army: Dictionary) -> Dictionary:
	var detail := army
	if _facade != null and _facade.has_method("army"):
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
				"tooltip": "%s 可支撑 %d 日（刻度为 7 日警戒线）" % [label, int(value)]})
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


func war_model(selected: int, ceding: Dictionary = {}) -> Dictionary:
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
		"detail": current,
		"declare": declare_candidates(),
		"ceded": ceded_cells(current, ceding),
		"log": war_log(),
		"fronts": front_rows(),
		"front_source": _front_queried,
		"log_source": event_log_available(),
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
	if _generator != null and _generator.has_method("get_data_core_world_ext") \
			and _generator.has_method("current_map"):
		regions = _scan_regions()
	_neighbor_cache[key] = regions
	return regions


## Neighbour scan over Country's territory map. Returns {} when the session
## does not expose a map (fixture/offline mount).
func _scan_regions() -> Dictionary:
	var regions := {}
	var ext = _generator.call("get_data_core_world_ext")
	if ext == null or not ext.has_method("get_country_cell_snapshot"):
		return regions
	var owners = ext.call("get_country_cell_snapshot")
	var map = _generator.call("current_map")
	if not (owners is PackedInt32Array) or map == null:
		return regions
	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	if neighbors.size() < owners.size() * 6:
		return regions
	var my_slot := int(_snapshot.get("country_slot", -1))
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
	var section := _as_dict(_model.get("military", null))
	var handles: Dictionary = _as_dict(section.get("country_handles", null))
	return int(handles.get(slot, 0))


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
	if _generator != null and _generator.has_method("get_data_core_world_ext"):
		var ext = _generator.call("get_data_core_world_ext")
		if ext != null and ext.has_method("get_country_cell_snapshot"):
			var owners = ext.call("get_country_cell_snapshot")
			if owners is PackedInt32Array:
				return owners
	var stand_in = _as_dict(_as_dict(_model.get("military", null)).get(
		"cell_owners", null))
	if stand_in.is_empty():
		return PackedInt32Array()
	var rows = stand_in.get("owners", PackedInt32Array())
	return rows if rows is PackedInt32Array else PackedInt32Array()


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
	var resolved := ""
	var facade = _country_facade()
	var handle := _handle_for_slot(slot)
	if facade != null and handle != 0 and facade.has_method("snapshot"):
		var snapshot = facade.call("snapshot", handle)
		if snapshot is Dictionary and bool((snapshot as Dictionary).get("ok", false)):
			resolved = String((snapshot as Dictionary).get("country_name", "")).strip_edges()
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
