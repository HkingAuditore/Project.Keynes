extends RefCounted
class_name MilitaryViewModel

const ConflictProjection = preload("res://scripts/ui/military_conflict_projection.gd")

const ArmyProjection = preload("res://scripts/ui/military_army_projection.gd")

const ForceProjection = preload("res://scripts/ui/military_force_projection.gd")

const MilitaryCellNames = preload("res://scripts/ui/military_cell_names.gd")
const MilitaryDossiers = preload("res://scripts/ui/military_dossier_projection.gd")
const MilitaryLogisticsProjection = preload("res://scripts/ui/military_logistics_projection.gd")


## Read-only presentation model for MilitaryWorkspace. Every number comes from the
## military facade snapshot (fixed-point ints) and is converted here; nothing is
## written back. Fields the native snapshot does not export are left out rather than
## shown as fabricated zeros.

const MONEY_SCALE := 10000.0
const Q16 = MilitaryLogisticsProjection.Q16
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
const MISSION_LABELS := {0: "待命", 1: "行军", 2: "军事控制", 3: "探路"}
const EXPLORATION_PHASE_ACTIVE := 0
const EXPLORATION_PHASE_RETURNING := 1
const EXPLORATION_PHASE_PAUSED_BATTLE := 2
const EXPLORATION_PHASE_COMPLETE := 3
const EXPLORATION_PHASE_FAILED_NO_RETURN := 4
const EXPLORATION_RESULT_NONE := 0
const EXPLORATION_RESULT_ALL_SEEN := 1
const EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE := 2
const EXPLORATION_RESULT_FAILED_NO_RETURN := 3
const EXPLORATION_RESULT_CANCELLED := 4
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
	# 地块名由装配层（CountryViewModel）从 Economy 的具名聚落装进军事段；顶层的
	# `cell_names` 仍认，是为了夹具与旧调用面不必改。
	_cell_names = _as_dict(section.get("cell_names", _model.get("cell_names", null)))
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
	return name if not name.is_empty() else "需要前置科技"


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
	return ForceProjection.overview_model(self)


func spend_breakdown() -> Dictionary:
	return ForceProjection.spend_breakdown(self)


func army_readiness() -> Dictionary:
	return ForceProjection.army_readiness(self)


func _overview_insights(soldiers: int, deficit: int, pay_ratio: float,
		readiness: Dictionary) -> Array:
	return ForceProjection._overview_insights(self, soldiers, deficit, pay_ratio, readiness)


static func _insight(id: String, text: String, icon: String, accent: Color) -> Dictionary:
	return ForceProjection._insight(id, text, icon, accent)


func forces_model() -> Dictionary:
	return ForceProjection.forces_model(self)


func shares_by_unit() -> Dictionary:
	return ForceProjection.shares_by_unit(self)


func share_segments(shares: Dictionary) -> Array:
	return ForceProjection.share_segments(self, shares)


static func _shade(color: Color, ordinal: int) -> Color:
	return ForceProjection._shade(color, ordinal)


func _share_total(shares: Dictionary) -> int:
	return ForceProjection._share_total(self, shares)


func unit_share_rows(shares: Dictionary) -> Array:
	return ForceProjection.unit_share_rows(self, shares)


func _militia_row(total: int) -> Dictionary:
	return ForceProjection._militia_row(self, total)


func militia_index() -> int:
	return ForceProjection.militia_index(self)


static func _normalize_stats(rows: Array) -> void:
	ForceProjection._normalize_stats(rows)


func locked_unit_count() -> int:
	return ForceProjection.locked_unit_count(self)


func unlocked_unit_count() -> int:
	return ForceProjection.unlocked_unit_count(self)


func barracks_rows(barracks: Array) -> Array:
	return ForceProjection.barracks_rows(self, barracks)


static func _barracks_tier(posts: int) -> int:
	return ForceProjection._barracks_tier(posts)


func training_rows() -> Array:
	return ForceProjection.training_rows(self)


# ── armies & logistics ───────────────────────────────────────────────────

## 列表只给「哪支部队、多少人、还能不能打」；编成与补给天数在军务档案里。
func armies_model(selected: int) -> Dictionary:
	return ArmyProjection.armies_model(self, selected)


func _procurement_share_text() -> String:
	return ArmyProjection._procurement_share_text(self)


func army_row(army: Dictionary) -> Dictionary:
	return ArmyProjection.army_row(self, army)


func army_warnings(army: Dictionary) -> Array:
	return ArmyProjection.army_warnings(self, army)


func army_detail(army: Dictionary, prefetched: Dictionary = {}) -> Dictionary:
	return ArmyProjection.army_detail(self, army, prefetched)


func _mission_text(army: Dictionary) -> String:
	return ArmyProjection._mission_text(self, army)


func _exploration_state(army: Dictionary) -> Dictionary:
	return ArmyProjection._exploration_state(self, army)


func _exploration_status_text(army: Dictionary) -> String:
	return ArmyProjection._exploration_status_text(self, army)


func _exploration_has_live_order(army: Dictionary) -> bool:
	return ArmyProjection._exploration_has_live_order(self, army)


func army_dossier(handle: int, same_cell: Array = []) -> Dictionary:
	return ArmyProjection.army_dossier(self, handle, same_cell)


func front_dossier(sector: Dictionary) -> Dictionary:
	return ArmyProjection.front_dossier(self, sector)


func _side_totals(sides: Array, slot: int) -> Dictionary:
	return ArmyProjection._side_totals(self, sides, slot)


func _dossier_army(handle: int) -> Dictionary:
	return ArmyProjection._dossier_army(self, handle)


static func _versus_row(label: String, own_value: float, enemy_value: float,
		own_text: String, enemy_text: String) -> Dictionary:
	return ArmyProjection._versus_row(label, own_value, enemy_value, own_text, enemy_text)


func _append_side_army_rows(out: Array, sides: Array, slot: int) -> void:
	ArmyProjection._append_side_army_rows(self, out, sides, slot)


static func _pair_key_for(cell_a: int, cell_b: int) -> int:
	return ArmyProjection._pair_key_for(cell_a, cell_b)


func convoy_rows(convoys: Array) -> Array:
	return ArmyProjection.convoy_rows(self, convoys)


func _good_label(dense_id: int) -> String:
	return ArmyProjection._good_label(self, dense_id)


# ── war ──────────────────────────────────────────────────────────────────

func war_cards() -> Array:
	return ConflictProjection.war_cards(self)


func war_model(selected: int) -> Dictionary:
	return ConflictProjection.war_model(self, selected)


func war_card(war: Dictionary) -> Dictionary:
	return ConflictProjection.war_card(self, war)


func engagement_rows() -> Array:
	return ConflictProjection.engagement_rows(self)


func engagement_between(slot_a: int, slot_b: int) -> Dictionary:
	return ConflictProjection.engagement_between(self, slot_a, slot_b)


func front_rows() -> Array:
	return ConflictProjection.front_rows(self)


func war_log() -> Array:
	return ConflictProjection.war_log(self)


func _read_events() -> Array:
	return ConflictProjection._read_events(self)


func _battle_log_label(cell: int, war_id: int) -> String:
	return ConflictProjection._battle_log_label(self, cell, war_id)


func _event_row(event: Dictionary) -> Dictionary:
	return ConflictProjection._event_row(self, event)


func declare_candidates() -> Array:
	return ConflictProjection.declare_candidates(self)


func _region_map() -> Dictionary:
	return ConflictProjection._region_map(self)


func _map():
	return ConflictProjection._map(self)


func _scan_regions() -> Dictionary:
	return ConflictProjection._scan_regions(self)


func _neighbor_offsets(neighbors: PackedInt32Array, cell: int) -> Array:
	return ConflictProjection._neighbor_offsets(self, neighbors, cell)


func _war_status(slot: int) -> Dictionary:
	return ConflictProjection._war_status(self, slot)


func _handle_for_slot(slot: int) -> int:
	return ConflictProjection._handle_for_slot(self, slot)


func _slot_first_cells() -> Dictionary:
	return ConflictProjection._slot_first_cells(self)


func _player_slot() -> int:
	return ConflictProjection._player_slot(self)


func _capital_name(handle: int) -> String:
	return ConflictProjection._capital_name(self, handle)


func ceded_cells(war: Dictionary, checked: Dictionary = {}) -> Dictionary:
	return ConflictProjection.ceded_cells(self, war, checked)


func _owner_map() -> PackedInt32Array:
	return ConflictProjection._owner_map(self)


func cession_label(cell: int, owners: PackedInt32Array) -> String:
	return ConflictProjection.cession_label(self, cell, owners)


func _owner_label(cell: int, owners: PackedInt32Array) -> String:
	return ConflictProjection._owner_label(self, cell, owners)


func evaluate_peace(war_id: int, war_score: float, terms: Array) -> Dictionary:
	return ConflictProjection.evaluate_peace(self, war_id, war_score, terms)


# ── naming ───────────────────────────────────────────────────────────────

func zone_name(cell: int) -> String:
	return MilitaryCellNames.zone_name(self, cell)


func settlement_name(cell: int) -> String:
	return MilitaryCellNames.settlement_name(self, cell)


func cell_name_count() -> int:
	return MilitaryCellNames.cell_name_count(self)


func cell_name(cell: int) -> String:
	return MilitaryCellNames.cell_name(self, cell)


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
	return name if not name.is_empty() else "未命名国家"


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
	return MilitaryLogisticsProjection._as_dict(value)


static func _as_array(value) -> Array:
	return value if value is Array else []


static func money(raw) -> float:
	return float(raw) / MONEY_SCALE


static func _money_text(raw) -> String:
	return UITokens.format_compact_number_cn(float(raw) / MONEY_SCALE, 2)


static func _count(raw) -> String:
	return UITokens.format_compact_number_cn(float(raw), 1)


static func _ratio(raw) -> float:
	return MilitaryLogisticsProjection._ratio(raw)


static func _raw_q16(raw) -> float:
	return float(raw) / Q16


static func _percent(value: float) -> String:
	return "%d%%" % int(round(clampf(value, 0.0, 1.0) * 100.0))


static func _bp(raw) -> String:
	return "%.0f%%" % (float(raw) / BP * 100.0)
