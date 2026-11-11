class_name MilitaryFacade
extends RefCounted

## Cold-path GDScript wrapper around the native military bindings on DCWorldExt.
##
## Every native entry point is guarded with `has_method` so the game keeps
## running against an older DLL: when the military API is absent the facade
## reports `configured == false`, the daily system never registers, and
## `MilitaryDailySystem.should_run()` stays false (zero cost, zero errors).
##
## Ownership: this file only forwards. Dense ids, catalog resolution and
## ration candidates live in MilitaryCatalogCompiler; simulation authority is
## native (never advance a military day from GDScript except through
## [run_daily], which is the documented non-whole-graph entry point).

const MilitaryCatalogCompilerScript = preload(
	"res://scripts/military/military_catalog_compiler.gd")

## DCSystem registration surface. Mirrors the other runtimes' DCSystem ids.
const SYSTEM_ID := &"military_daily"

const CATALOG_PATH := MilitaryCatalogCompilerScript.CATALOG_PATH

## Command `op` strings accepted by `submit_military_commands` (contract §2).
const SPEC_COMMON := {
	force_ops = [
		"force.set_target", "force.set_levy", "force.set_auto_discharge",
		"config.set", "config.set_quality_policy", "config.auto_retrain",
	],
	building_ops = ["barracks.pause", "train", "state.build", "state.demolish"],
	policy_ops = ["policy.set_wage", "policy.set_procurement", "policy.set_budget"],
	army_ops = [
		"army.create", "army.station", "army.transfer", "army.merge",
		"army.split", "army.set_template", "army.reinforce", "army.move",
		"army.area_control", "army.stop", "army.stance", "army.rename",
		"army.disband", "army.explore",
	],
	diplomacy_ops = ["war.declare", "peace.propose", "peace.respond"],
}

const PEACE_TERM_KINDS := [
	"white", "cede", "annex", "lump_sum", "installments", "goods", "return"]

# ---- 实物维护（docs/plans/military-physical-maintenance.md D7 / S4-6）----
## 维护对象的两类：建筑组（`object_id` = 目录 `state_buildings` 稠密下标）
## 与装备组（`object_id` = 兵种稠密下标）。
const MAINTENANCE_KIND_BUILDING := 0
const MAINTENANCE_KIND_EQUIPMENT := 1
const MAINTENANCE_KIND_NAMES := {0: "建筑", 1: "装备"}
## `shortage_reason`：0 无 / 1 缺货 / 2 预算不足 / 3 运输未到。
const MAINTENANCE_REASON_TEXT := ["—", "缺货", "预算不足", "运输未到"]
## `days_cover_x10 == -1`：该行没有需求，可用天数无意义。
const MAINTENANCE_NO_DEMAND := -1
## 排序用的「无需求」哨兵：比任何真实天数都大，保证短缺行排在最前。
const MAINTENANCE_NO_DEMAND_SORT := 0x7FFFFFFF
## 维护缓存的槽：无参原生方法一次回全表，所有国家共用这一份。
const MAINTENANCE_ALL_COUNTRIES := -1
## 原生字段名在 D7 契约与任务书里各写了一次（`daily_need` vs `daily_need_goods`
## 等），两条都认。这是本次 UI 侧唯一的字段名假设，已列进交付说明请原生侧核对。
const MAINTENANCE_FIELD_ALIASES := {
	"country_slot": ["country_slot"],
	"cell": ["cell"],
	"kind": ["kind"],
	"object_id": ["object_id"],
	"units": ["units"],
	"daily_need_goods": ["daily_need_goods", "daily_need"],
	"stock_goods": ["stock_goods", "stock"],
	"inbound_goods": ["inbound_goods", "inbound"],
	"ratio_bp": ["ratio_bp"],
	"days_cover_x10": ["days_cover_x10"],
	"disrepair": ["disrepair"],
	"shortage_reason": ["shortage_reason", "reason"],
}

var _world_ext: Object = null
var _configured := false
var _catalog: Dictionary = {}
var _catalog_hash := 0
## Economy's dense good id table, captured at configure time. The compiled
## military catalog indexes materials by that dense id (`material_goods`), so
## resolving a name needs this table; keeping it here means the view model never
## has to reach into the economy catalog for a military row (see
## docs/ui/military-cell-tab.md §2).
var _good_ids: PackedStringArray = PackedStringArray()
var _world_seed := 0
var _last_configure_result: Dictionary = {}
var _last_daily_report: Dictionary = {}
var _terrain_signature := 0
var _terrain_cells := 0
var _terrain_set_day := -1
var _ai_player_handles := PackedInt64Array()
var _missing_api_reason := ""
var _event_cursor := 0
var _restored_event_progress := PackedInt64Array()
## 维护快照的整形结果：一次原生读取服务同一刷新里的明细表与汇总，跨日/命令/
## 读档才失效（见 `invalidate_maintenance_cache`）。UI 每天最多读一次。
## 键是缓存槽（见 `_maintenance_view`），不是国家槽。
var _maintenance_cache: Dictionary = {}
## 原生方法声明的参数个数（-1 = 未探测）。D7 写作无参「一次轮询」，但带国家槽
## 的实现也认：多一个参数不影响语义，只影响调用形状。
var _maintenance_native_args := -1


## `economy_catalog` is `EconomyFacade.native_catalog()`; `technology_catalog`
## is `TechnologyCatalog.compile_native_catalog()`. Both are required because
## dense good / profession / technology ids come from those authorities.
## `military_catalog_data` overrides the JSON path (tests, authored overrides).
func configure(world_ext: Object, economy_catalog: Dictionary,
		technology_catalog: Dictionary, world_seed: int,
		military_catalog_data: Dictionary = {}) -> Dictionary:
	_world_ext = world_ext
	_configured = false
	_catalog = {}
	_catalog_hash = 0
	_maintenance_native_args = -1
	invalidate_maintenance_cache()
	_good_ids = economy_catalog.get("good_ids", PackedStringArray()) \
		if economy_catalog.get("good_ids", null) is PackedStringArray \
		else PackedStringArray()
	_world_seed = int(world_seed)
	_missing_api_reason = ""
	if _world_ext == null or not _world_ext.has_method("configure_military"):
		_missing_api_reason = "military_api_unavailable"
		_last_configure_result = _fail("military_api_unavailable")
		return _last_configure_result
	var compiled: Dictionary
	if military_catalog_data.is_empty():
		compiled = MilitaryCatalogCompilerScript.compile(
			economy_catalog, technology_catalog, CATALOG_PATH)
	else:
		compiled = MilitaryCatalogCompilerScript.compile_from_data(
			military_catalog_data, economy_catalog, technology_catalog)
	if not bool(compiled.get("ok", false)):
		_last_configure_result = compiled
		return _last_configure_result
	var native_catalog := compiled.duplicate(true)
	for meta_key in ["ok", "schema"]:
		native_catalog.erase(meta_key)
	var result: Dictionary = _world_ext.configure_military(native_catalog, _world_seed)
	if not bool(result.get("ok", false)):
		_last_configure_result = _fail(String(result.get("reason",
			"military_configure_failed")))
		return _last_configure_result
	_catalog = compiled
	_catalog_hash = int(compiled.get("catalog_hash", 0))
	_configured = true
	_event_cursor = 0
	_restored_event_progress.clear()
	_terrain_signature = 0
	_terrain_set_day = -1
	_last_configure_result = result.duplicate(false)
	_last_configure_result["catalog_hash"] = _catalog_hash
	_last_configure_result["unit_count"] = (compiled.get("units", []) as Array).size()
	_last_configure_result["unlock_count"] = int(
		(compiled.get("unlock_tech_ids", PackedInt32Array()) as PackedInt32Array).size())
	return _last_configure_result


func is_configured() -> bool:
	return _configured


func world_ext() -> Object:
	return _world_ext


func catalog() -> Dictionary:
	return _catalog


func catalog_hash() -> int:
	return _catalog_hash


func missing_api_reason() -> String:
	return _missing_api_reason


func configure_result() -> Dictionary:
	return _last_configure_result.duplicate(true)


## Terrain is static except for seasonal cover (snow / flood / glacier), so the
## caller passes a signature over the cover array: an unchanged signature is a
## no-op instead of a fresh 9-array Packed copy across the bridge.
func set_terrain(map, day: int = -1, force: bool = false,
		settlement_tiers: PackedByteArray = PackedByteArray()) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	if map == null:
		return _fail("military_terrain_map_unavailable")
	if not _world_ext.has_method("set_military_terrain"):
		return _fail("military_terrain_api_unavailable")
	var cover: PackedByteArray = map.cover_arr
	var signature := hash(cover)
	if not force and signature == _terrain_signature \
			and int(map.cell_count()) == _terrain_cells:
		return {"ok": true, "skipped": true, "reason": "terrain_unchanged"}
	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	if neighbors.size() != int(map.cell_count()) * 6:
		return _fail("military_terrain_neighbors_invalid")
	var tiers := settlement_tiers
	if tiers.size() != int(map.cell_count()):
		tiers = _settlement_tiers_from_map(map, int(map.cell_count()))
	# temporary: remove once MilitaryCore::set_terrain stops resetting
	# Native MilitaryCore::set_terrain calls reset_state(): every push wipes
	# armies, wars, policies, pending commands and the step cursor. Only the
	# configure-time push may do that; a seasonal cover refresh on a live world
	# must keep military state, so snapshot it through PKMI and restore it onto
	# the new terrain (same shape, so the transactional restore validates).
	var preserved := PackedByteArray()
	if terrain_ready() and _terrain_cells == int(map.cell_count()) \
			and _world_ext.has_method("encode_military_state") \
			and _world_ext.has_method("restore_military_state"):
		var encoded = _world_ext.encode_military_state()
		if encoded is PackedByteArray:
			preserved = encoded
	var result: Dictionary = _world_ext.set_military_terrain({
		"cell_count": int(map.cell_count()),
		"width": int(map.width),
		"height": int(map.height),
		"neighbors": neighbors,
		"landform": map.base_landform_arr,
		"vegetation": map.vegetation_arr,
		"cover": cover,
		"is_water": map.is_water_arr,
		"has_river": map.has_river_arr,
		"settlement_tier": tiers,
	})
	if bool(result.get("ok", false)):
		_terrain_signature = signature
		_terrain_cells = int(map.cell_count())
		_terrain_set_day = day
		invalidate_maintenance_cache()
		if not preserved.is_empty():
			# Native call on purpose: restore_state() rewinds the event cursor,
			# but the restored ring keeps its ids, so forwarding must continue.
			var restored: Dictionary = _world_ext.restore_military_state(preserved)
			result["state_preserved"] = bool(restored.get("ok", false))
			if not bool(restored.get("ok", false)):
				push_error("[military] terrain refresh lost military state: %s" % String(
					restored.get("reason", "restore_failed")))
	return result


func terrain_ready() -> bool:
	return _terrain_set_day >= 0 or _terrain_signature != 0


## Lowest-cost settlement tier per cell (0 with no settlement). The native
## digest only needs a coarse 0..4 band; the named settlement row already
## carries it when Economy is up, otherwise occupancy is inferred from
## MapData's own settlement counters.
static func _settlement_tiers_from_map(map, cell_count: int) -> PackedByteArray:
	var tiers := PackedByteArray()
	tiers.resize(cell_count)
	var counts: PackedInt32Array = PackedInt32Array()
	if "settlement_count_arr" in map:
		counts = map.settlement_count_arr
	for cell in range(mini(cell_count, counts.size())):
		var count := int(counts[cell])
		if count <= 0:
			continue
		tiers[cell] = 1 if count == 1 else (2 if count <= 3 else
			(3 if count <= 8 else 4))
	return tiers


func should_run(day: int) -> bool:
	if not _configured:
		return false
	if not _world_ext.has_method("military_should_run"):
		return false
	return bool(_world_ext.military_should_run(int(day)))


## Non-whole-graph entry point (DCSystem). `day` is the committed day index the
## daily system is advancing; the native side captures its own digest from the
## committed Country/Economy state and emits D+1 intents.
func run_daily(day: int) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	if not _world_ext.has_method("run_military_daily"):
		return _fail("military_daily_api_unavailable")
	var result: Dictionary = _world_ext.run_military_daily({"day_index": int(day)})
	_last_daily_report = result if result is Dictionary else {}
	invalidate_maintenance_cache()
	return _last_daily_report


## Legacy alias kept for older callers. The worker NEVER steps Military: in
## whole-graph ACTIVE, WorldRuntimeHost replays each committed day on the main
## thread through [run_daily] (native `run_military_daily`). This forwards to
## `run_military_catch_up`, which is the same main-thread step guarded by the
## one-step-per-day check (`military_day_already_stepped` when already run).
func catch_up(day: int) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	if _world_ext.has_method("run_military_catch_up"):
		var caught: Dictionary = _world_ext.run_military_catch_up({"day_index": int(day)})
		invalidate_maintenance_cache()
		return caught
	return run_daily(day)


## Render selection (army handle, 0 = none). The native render snapshot returns
## the selected army's area cells and remaining path cells.
func set_render_selection(army_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("set_military_render_selection"):
		return _fail("military_render_selection_api_unavailable")
	return _world_ext.set_military_render_selection(int(army_handle))


func last_daily_report() -> Dictionary:
	return _last_daily_report.duplicate(false)


func report() -> Dictionary:
	if not _configured:
		return {"ok": false, "configured": false, "reason": _missing_api_reason}
	if not _world_ext.has_method("get_military_report"):
		return {"ok": false, "configured": true, "reason": "military_report_api_unavailable"}
	var result: Dictionary = _world_ext.get_military_report()
	result["configured"] = true
	result["catalog_hash"] = _catalog_hash
	result["terrain_set_day"] = _terrain_set_day
	return result


# ------------------------------------------------------------- commands

## Submit a raw native command batch. Each item follows contract §2. The facade
## normalizes `units` dictionaries into the (unit,count) int pairs the command
## POD carries and rejects unknown ops before crossing the bridge, so a UI typo
## becomes a rejected index instead of a silent native no-op.
func submit(batch: Array) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	if not _world_ext.has_method("submit_military_commands"):
		return _fail("military_command_api_unavailable")
	var accepted := 0
	var rejected: Array = []
	var encoded: Array = []
	for index in range(batch.size()):
		var command_value = batch[index]
		if not command_value is Dictionary:
			rejected.append({"index": index, "reason": "military_command_not_object"})
			continue
		var command: Dictionary = command_value
		var op := String(command.get("op", ""))
		if op.is_empty():
			rejected.append({"index": index, "reason": "military_command_op_missing"})
			continue
		var normalized := command.duplicate(false)
		if op == "config.set" and command.get("shares") is Dictionary:
			# 玩家传稳定兵种 id 的局部修改；原生命令是 dense id 的整表替换。
			var snapshot := country_snapshot(int(command.get("country", 0)))
			if not bool(snapshot.get("ok", false)):
				rejected.append({"index": index, "reason": "military_country_snapshot_unavailable"})
				continue
			var rows: Array = _catalog.get("units", [])
			var previous = snapshot.get("config_share_bp", PackedInt32Array())
			var changes: Dictionary = command["shares"]
			var remaining := changes.duplicate()
			var config_pairs := PackedInt32Array()
			for unit_index in range(rows.size()):
				var unit_id := String(rows[unit_index].get("id", ""))
				var bp := int(previous[unit_index]) if unit_index < previous.size() else 0
				if changes.has(unit_id):
					bp = int(changes[unit_id])
					remaining.erase(unit_id)
				config_pairs.append(unit_index)
				config_pairs.append(bp)
			if not remaining.is_empty():
				rejected.append({"index": index, "reason": "command_bad_unit"})
				continue
			normalized["int_pairs"] = config_pairs
		var units_value = command.get("units", null)
		if units_value is Dictionary and not normalized.has("int_pairs"):
			var pairs := PackedInt32Array()
			for unit_key in (units_value as Dictionary).keys():
				pairs.append(int(unit_key))
				pairs.append(int((units_value as Dictionary)[unit_key]))
			normalized["int_pairs"] = pairs
		encoded.append(normalized)
		accepted += 1
	var result: Dictionary = _world_ext.submit_military_commands(encoded)
	invalidate_maintenance_cache()
	if rejected.size() > 0:
		var native_rejected: Array = result.get("rejected", [])
		result["rejected"] = native_rejected + rejected
		result["rejected_local"] = rejected.size()
	return result


## 军事预算信封（任务 6 / 需求 5.1）。三项通道份额各传 -1 表示「本次不改」，
## 让 UI 只推变化的那一项；原生按未传入项沿用当前值校验三项之和 <= 100%。
## `total_bp <= 0` 表示关闭预算控制，回落到旧的「按现金与需求直接结算」。
func set_budget(country: int, total_bp: int, wage_bp: int = -1,
		upkeep_bp: int = -1, procurement_bp: int = -1) -> Dictionary:
	var pairs := PackedInt32Array([int(wage_bp), int(upkeep_bp),
		int(procurement_bp)])
	return submit([{"op": "policy.set_budget", "country": country,
		"value": int(total_bp), "int_pairs": pairs}])


func set_target(country: int, mode: int, value: int) -> Dictionary:
	return submit([{"op": "force.set_target", "country": country,
		"count": int(mode), "value": int(value)}])


func set_levy_enabled(country: int, enabled: bool) -> Dictionary:
	return submit([{"op": "force.set_levy", "country": country,
		"count": 1 if enabled else 0}])


## `shares` maps dense unit id -> basis points; the native config must sum to at
## most 10000. This dense-id entry point replaces the whole configuration.
func set_unit_config(country: int, shares: Dictionary) -> Dictionary:
	var pairs := PackedInt32Array()
	var keys := shares.keys()
	keys.sort()
	for unit_key in keys:
		pairs.append(int(unit_key))
		pairs.append(int(shares[unit_key]))
	return submit([{"op": "config.set", "country": country, "int_pairs": pairs}])


func build_state_building(country: int, cell: int, building: int) -> Dictionary:
	return submit([{"op": "state.build", "country": country,
		"cell": int(cell), "unit_to": int(building)}])


func demolish_state_building(country: int, cell: int, building: int) -> Dictionary:
	return submit([{"op": "state.demolish", "country": country,
		"cell": int(cell), "unit_to": int(building)}])


func create_army(country: int, cell: int, units: Dictionary) -> Dictionary:
	return submit([{"op": "army.create", "country": country,
		"cell": int(cell), "units": units}])


func move_army(army: int, cell: int) -> Dictionary:
	return submit([{"op": "army.move", "army": army, "cell": int(cell)}])


func area_control(army: int, cell: int, radius: int,
		cells: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var command := {"op": "army.area_control", "army": army,
		"cell": int(cell), "radius": int(radius)}
	if not cells.is_empty():
		command["cells"] = cells
	return submit([command])


func explore_army(army: int, cell: int, cells: PackedInt32Array,
		radius: int) -> Dictionary:
	return submit([{"op": "army.explore", "army": army, "cell": int(cell),
		"cells": cells, "radius": int(radius)}])


func set_military_exploration_observer(observer_slot: int) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"set_military_exploration_observer"):
		return _fail("military_exploration_observer_unavailable")
	return _world_ext.set_military_exploration_observer(int(observer_slot))


func set_military_exploration_view(observer_slot: int, explored: PackedByteArray,
		day: int, revision: int) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"set_military_exploration_view"):
		return _fail("military_exploration_view_unavailable")
	return _world_ext.set_military_exploration_view(
		int(observer_slot), explored, int(day), int(revision))


func get_military_vision_trail(observer_slot: int) -> PackedInt32Array:
	if not _configured or not _world_ext.has_method("get_military_vision_trail"):
		return PackedInt32Array()
	var trail = _world_ext.get_military_vision_trail(int(observer_slot))
	return trail if trail is PackedInt32Array else PackedInt32Array()


func clear_military_vision_trail(observer_slot: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("clear_military_vision_trail"):
		return _fail("military_exploration_trail_unavailable")
	return _world_ext.clear_military_vision_trail(int(observer_slot))


func has_military_exploration_work() -> bool:
	if not _configured or not _world_ext.has_method(
			"has_military_exploration_work"):
		return false
	return bool(_world_ext.has_military_exploration_work())


func declare_war(country: int, target_country: int) -> Dictionary:
	return submit([{"op": "war.declare", "country": country,
		"other": target_country}])


func propose_peace(country: int, war: int, terms: Array) -> Dictionary:
	return submit([{"op": "peace.propose", "country": country,
		"other": war, "terms": terms}])


func respond_peace(country: int, war: int, accept: bool) -> Dictionary:
	return submit([{"op": "peace.respond", "country": country, "other": war,
		"count": 1 if accept else 0}])


# ------------------------------------------------------------- queries

func country_snapshot(country: int) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_military_country_snapshot"):
		return _fail("military_country_snapshot_unavailable")
	return _world_ext.get_military_country_snapshot(int(country))


func armies(country: int) -> Array:
	if not _configured or not _world_ext.has_method("get_military_armies"):
		return []
	var result = _world_ext.get_military_armies(int(country))
	return result if result is Array else []


func army(army_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_military_army"):
		return _fail("military_army_api_unavailable")
	return _world_ext.get_military_army(int(army_handle))


func cell_snapshot(cell: int, observer: int = 0) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_military_cell_snapshot"):
		return _fail("military_cell_snapshot_unavailable")
	return _world_ext.get_military_cell_snapshot(int(cell), int(observer))


func render_snapshot(after_revision: int = 0) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_military_render_snapshot"):
		return {"ok": false, "available": false,
			"reason": "military_render_api_unavailable"}
	return _world_ext.get_military_render_snapshot(int(after_revision))


func control_snapshot() -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_military_control_snapshot"):
		return {"ok": false, "available": false,
			"reason": "military_control_api_unavailable"}
	return _world_ext.get_military_control_snapshot()


func preview_path(army_handle: int, cell: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("preview_military_path"):
		return _fail("military_path_api_unavailable")
	return _world_ext.preview_military_path(int(army_handle), int(cell))


func evaluate_peace(war: int, proposer: int, terms: Array) -> Dictionary:
	if not _configured or not _world_ext.has_method("evaluate_military_peace"):
		return _fail("military_peace_api_unavailable")
	return _world_ext.evaluate_military_peace(int(war), int(proposer), terms)


func catalog_view() -> Dictionary:
	if not _configured or not _world_ext.has_method("get_military_catalog_view"):
		return _fail("military_catalog_view_api_unavailable")
	return _world_ext.get_military_catalog_view()


## 官营建筑一座的建材需求：`[{good_id, name, qty}]`，qty 是 GOODS_SCALE（1000 = 1 单位）。
##
## 目录在编译期就把 `materials` 折成了 dense 的 `material_goods` / `material_qty`
## 两条平行数组（见 military_catalog_compiler.gd），这里只负责把 dense id 还原成
## 稳定 id 与名字。返回空数组表示该建筑不需要建材（不返回 null：调用方要能区分
## 「没有建材」与「读不到目录」）。
func state_building_materials(building_index: int) -> Array:
	var rows: Array = _catalog.get("state_buildings", [])
	if building_index < 0 or building_index >= rows.size():
		return []
	var row: Dictionary = rows[building_index]
	var ids: PackedInt32Array = row.get("material_goods", PackedInt32Array())
	var quantities: PackedInt64Array = row.get("material_qty", PackedInt64Array())
	var out: Array = []
	for index in range(ids.size()):
		var dense := int(ids[index])
		var good_id := String(_good_ids[dense]) \
			if dense >= 0 and dense < _good_ids.size() else ""
		out.append({
			"good_id": good_id,
			"qty": int(quantities[index]) if index < quantities.size() else 0,
		})
	return out


## 该军事建筑对应的经济目录 `building_type_ids` 稠密索引。编译期按稳定 id 解析，
## 解析失败或落到的类型不是 `state` 时整份军事目录直接编译失败（见
## `_compile_state_buildings` 的 `military_state_building_without_economy_profile` /
## `military_state_building_economy_kind_invalid`），因此成功编译的目录里这个值恒 >= 0；
## 只有越界的 `building_index` 参数会返回 -1。
func state_building_economy_id(building_index: int) -> int:
	var rows: Array = _catalog.get("state_buildings", [])
	if building_index < 0 or building_index >= rows.size():
		return -1
	return int((rows[building_index] as Dictionary).get("economy_building_id", -1))


## 军事目录 `state_buildings` 的「稠密下标 → 稳定 id」表。维护快照的
## `object_id`（kind 0）就是这条表的下标，`state_building_materials()` 用的是
## 同一套下标。只读缓存好的编译目录，不碰原生。
func state_building_ids() -> PackedStringArray:
	return _catalog_ids("state_buildings")


## 兵种稠密下标 → 稳定 id（维护快照 kind 1 的 `object_id` 走这条表）。
func unit_ids() -> PackedStringArray:
	return _catalog_ids("units")


func _catalog_ids(key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var table = _catalog.get(key, null)
	if table is Array:
		for raw in (table as Array):
			out.append(String((raw as Dictionary).get("id", "")) if raw is Dictionary else "")
	return out


# ------------------------------------------------------------- maintenance

## 原生是否提供维护快照。旧 DLL 没有 `get_military_maintenance_snapshot()`：
## 面板据此写「实物维护未接通」，而不是把空表读成「没有维护对象」。
func maintenance_supported() -> bool:
	return _world_ext != null \
		and _world_ext.has_method("get_military_maintenance_snapshot")


## 丢弃整形缓存。军事日推进、命令、读档、地形重置后必须调用，否则面板会读到
## 上一日的库存/满足率。UI 不必手动调：这些入口都在本类里。
func invalidate_maintenance_cache() -> void:
	_maintenance_cache.clear()


## 逐对象的维护明细（稳定 id + 名字 + 原始整数），已按短缺优先排序。
## `country_slot < 0` = 全部国家。原生缺席时返回空数组，永不返回 null。
func maintenance_snapshot(country_slot := -1) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var view := _maintenance_view(int(country_slot))
	var rows: Array = view.get("rows", [])
	for row_value in rows:
		if row_value is Dictionary:
			out.append(row_value)
	return out


## 面板聚合读数：`rows` / `need_goods` / `stock_goods` / `inbound_goods` /
## `weighted_ratio_bp` / `disrepair_rows` / `shortage_rows`，全部整数。
func maintenance_summary(country_slot := -1) -> Dictionary:
	var view := _maintenance_view(int(country_slot))
	var summary: Dictionary = view.get("summary", {})
	return summary.duplicate(false)


## 一次原生读取 + 一次整形，然后按国家过滤并汇总。整形结果缓存在
## `_maintenance_cache` 上（无参原生方法只读全表一次），所以「明细 + 汇总」
## 在同一刷新里只跨桥一次。
func _maintenance_view(country_slot: int) -> Dictionary:
	var rows: Array = []
	for row_value in _shaped_maintenance(country_slot):
		var row: Dictionary = row_value
		if country_slot >= 0 and int(row.get("country_slot", -1)) != country_slot:
			continue
		rows.append(row)
	return {"rows": rows, "summary": _summarize_maintenance(rows)}


## 缓存槽：无参原生方法一次回全表，所有国家共用一份（`MAINTENANCE_ALL_COUNTRIES`）；
## 带国家槽的实现各存各的。
func _shaped_maintenance(country_slot: int) -> Array:
	var native_args := _maintenance_native_arg_count()
	var cache_key := MAINTENANCE_ALL_COUNTRIES if native_args <= 0 else country_slot
	if _maintenance_cache.has(cache_key):
		return _maintenance_cache[cache_key] as Array
	if not _configured or not maintenance_supported():
		return []
	var raw = _world_ext.get_military_maintenance_snapshot() if native_args <= 0 \
		else _world_ext.get_military_maintenance_snapshot(int(country_slot))
	var shaped: Array = shape_maintenance(raw, _catalog).get("rows", [])
	_maintenance_cache[cache_key] = shaped
	return shaped


## 原生签名的参数个数，只在第一次读快照时探测一次。契约写的是无参
## `get_military_maintenance_snapshot()`；如果实现加了国家槽参数，这里也能对上，
## 不让 UI 因为「多了一个可选参数」整块失联。
func _maintenance_native_arg_count() -> int:
	if _maintenance_native_args >= 0:
		return _maintenance_native_args
	_maintenance_native_args = 0
	if _world_ext == null:
		return _maintenance_native_args
	for method in _world_ext.get_method_list():
		if String(method.get("name", "")) != "get_military_maintenance_snapshot":
			continue
		var arg_list = method.get("args", [])
		_maintenance_native_args = (arg_list as Array).size() if arg_list is Array else 0
		break
	return _maintenance_native_args


## 纯函数：把维护快照整形为 `{rows: [...], summary: {...}}`，不碰原生、不留状态，
## 所以测试可以直接喂合成字典（tests/military/military_maintenance_view_model_test.gd）。
##
## `rows` 接受两种形状：
##   1. 原生发布的平行字典：`{country_slot: PackedInt32Array, ...}`（或带 `rows` 数组）；
##   2. 已解码的行数组：`[{country_slot: 1, kind: 0, object_id: 3, ...}, ...]`。
##
## `catalog` 是编译后的军事目录（`state_buildings` / `units`）。`object_id` 是稠密
## 下标，这里解析成稳定 id + 显示名；越界时 id 留空、名字写「建筑 · #n」。
##
## 排序：可用天数升序（短缺在前），再按稳定 id、国家、地块（后两项只为确定性，
## 同一 id 可能出现在多个地块）。`days_cover_x10 == -1`（无需求）不是短缺，排最后。
static func shape_maintenance(rows, catalog: Dictionary) -> Dictionary:
	var shaped: Array = []
	for raw in _decode_maintenance_rows(rows):
		shaped.append(_shape_maintenance_row(raw, catalog))
	shaped.sort_custom(func(a, b) -> bool:
		var days_a := _maintenance_sort_days(int(a.get("days_cover_x10",
			MAINTENANCE_NO_DEMAND)))
		var days_b := _maintenance_sort_days(int(b.get("days_cover_x10",
			MAINTENANCE_NO_DEMAND)))
		if days_a != days_b:
			return days_a < days_b
		var id_a := String(a.get("id", ""))
		var id_b := String(b.get("id", ""))
		if id_a != id_b:
			return id_a < id_b
		if int(a.get("country_slot", -1)) != int(b.get("country_slot", -1)):
			return int(a.get("country_slot", -1)) < int(b.get("country_slot", -1))
		return int(a.get("cell", -1)) < int(b.get("cell", -1)))
	return {"rows": shaped, "summary": _summarize_maintenance(shaped)}


## `shortage_reason` → 展示文案（0 — / 1 缺货 / 2 预算不足 / 3 运输未到）。
static func maintenance_reason_text(reason: int) -> String:
	if reason < 0 or reason >= MAINTENANCE_REASON_TEXT.size():
		return String(MAINTENANCE_REASON_TEXT[0])
	return String(MAINTENANCE_REASON_TEXT[reason])


## 需求加权满足率：`Σ(need × ratio) / Σneed`，整数除法；没有需求时为 0。
static func _summarize_maintenance(rows: Array) -> Dictionary:
	var need := 0
	var stock := 0
	var inbound := 0
	var weighted := 0
	var disrepair_rows := 0
	var shortage_rows := 0
	for raw in rows:
		var row: Dictionary = raw
		var row_need := maxi(0, int(row.get("daily_need_goods", 0)))
		need += row_need
		stock += maxi(0, int(row.get("stock_goods", 0)))
		inbound += maxi(0, int(row.get("inbound_goods", 0)))
		weighted += row_need * clampi(int(row.get("ratio_bp", 0)), 0, 10000)
		if int(row.get("disrepair", 0)) != 0:
			disrepair_rows += 1
		if int(row.get("shortage_reason", 0)) != 0:
			shortage_rows += 1
	return {
		"rows": rows.size(),
		"need_goods": need,
		"stock_goods": stock,
		"inbound_goods": inbound,
		"weighted_ratio_bp": clampi(weighted / need, 0, 10000) if need > 0 else 0,
		"disrepair_rows": disrepair_rows,
		"shortage_rows": shortage_rows,
	}


static func _maintenance_sort_days(days_cover_x10: int) -> int:
	return MAINTENANCE_NO_DEMAND_SORT if days_cover_x10 < 0 else days_cover_x10


static func _decode_maintenance_rows(rows) -> Array:
	if rows is Array:
		var decoded: Array = []
		for raw in (rows as Array):
			if raw is Dictionary:
				decoded.append(raw)
		return decoded
	if not rows is Dictionary:
		return []
	var raw_rows = (rows as Dictionary).get("rows", null)
	if raw_rows is Array:
		return _decode_maintenance_rows(raw_rows)
	if (rows as Dictionary).is_empty():
		return []
	return _decode_parallel_maintenance(rows as Dictionary)


## 平行数组 → 行字典。取各数组长度的最大值：缺一条数组不该把整张表截断。
static func _decode_parallel_maintenance(raw: Dictionary) -> Array:
	var columns := {}
	var count := 0
	for field in MAINTENANCE_FIELD_ALIASES:
		var values = _first_present(raw, MAINTENANCE_FIELD_ALIASES[field])
		columns[field] = values
		if values is Array:
			count = maxi(count, (values as Array).size())
		elif values is PackedInt32Array:
			count = maxi(count, (values as PackedInt32Array).size())
		elif values is PackedInt64Array:
			count = maxi(count, (values as PackedInt64Array).size())
		elif values is PackedByteArray:
			count = maxi(count, (values as PackedByteArray).size())
	var out: Array = []
	for index in range(count):
		var row := {}
		for field in columns:
			var values = columns[field]
			row[field] = int(values[index]) \
				if values != null and index < values.size() else 0
		out.append(row)
	return out


static func _first_present(raw: Dictionary, keys: Array):
	for key in keys:
		if raw.has(key):
			return raw[key]
	return null


static func _shape_maintenance_row(raw: Dictionary, catalog: Dictionary) -> Dictionary:
	var kind := int(raw.get("kind", MAINTENANCE_KIND_BUILDING))
	var object_id := int(raw.get("object_id", -1))
	var kind_name := String(MAINTENANCE_KIND_NAMES.get(kind, ""))
	var identity := _maintenance_identity(catalog, kind, object_id)
	var name := String(identity.get("name", ""))
	if name.is_empty():
		name = "%s · #%d" % [kind_name if not kind_name.is_empty() else "对象", object_id]
	var reason := int(raw.get("shortage_reason", 0))
	return {
		"country_slot": int(raw.get("country_slot", -1)),
		"cell": int(raw.get("cell", -1)),
		"kind": kind,
		"kind_name": kind_name,
		"object_id": object_id,
		"id": String(identity.get("id", "")),
		"name": name,
		"units": maxi(0, int(raw.get("units", 0))),
		"daily_need_goods": maxi(0, int(raw.get("daily_need_goods", 0))),
		"stock_goods": maxi(0, int(raw.get("stock_goods", 0))),
		"inbound_goods": maxi(0, int(raw.get("inbound_goods", 0))),
		"ratio_bp": clampi(int(raw.get("ratio_bp", 0)), 0, 10000),
		"days_cover_x10": int(raw.get("days_cover_x10", MAINTENANCE_NO_DEMAND)),
		"disrepair": 1 if int(raw.get("disrepair", 0)) != 0 else 0,
		"shortage_reason": reason,
		"reason_text": maintenance_reason_text(reason),
	}


## 稠密下标 → `{id, name}`。`units` 在编译目录里是数组；地块档案那边缓存的是
## 「下标 → 行」字典，两种都认，免得同一份解析写两遍。
static func _maintenance_identity(catalog: Dictionary, kind: int,
		object_id: int) -> Dictionary:
	var key := "state_buildings" if kind == MAINTENANCE_KIND_BUILDING else "units"
	var table = catalog.get(key, null)
	var row = null
	if table is Array:
		if object_id >= 0 and object_id < (table as Array).size():
			row = (table as Array)[object_id]
	elif table is Dictionary:
		row = (table as Dictionary).get(object_id, null)
	if not row is Dictionary:
		return {"id": "", "name": ""}
	var id := String((row as Dictionary).get("id", "")).strip_edges()
	var name := String((row as Dictionary).get("name", "")).strip_edges()
	return {"id": id, "name": name if not name.is_empty() else id}


## Drain the native event ring into GameplayEventBus-compatible batches.
## `cursor` is advanced in place by the caller (MilitaryDailySystem owns it).
func poll_events(after_id: int, limit: int = 256) -> Array:
	if not _configured or not _world_ext.has_method("poll_military_events"):
		return []
	var result = _world_ext.poll_military_events(int(after_id), int(limit))
	return result if result is Array else []


# ------------------------------------------------------------- persistence

func encode_state() -> PackedByteArray:
	if not _configured or not _world_ext.has_method("encode_military_state"):
		return PackedByteArray()
	var result = _world_ext.encode_military_state()
	return result if result is PackedByteArray else PackedByteArray()


func restore_state(bytes: PackedByteArray) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	if not _world_ext.has_method("restore_military_state"):
		return _fail("military_restore_api_unavailable")
	if bytes.is_empty():
		return _fail("pkmi_empty")
	var result: Dictionary = _world_ext.restore_military_state(bytes)
	if bool(result.get("ok", false)):
		# The restored state carries its own event ids; restart the cursor so a
		# reload does not replay the previous session's ring.
		_event_cursor = 0
	invalidate_maintenance_cache()
	return result


func state_hash() -> int:
	if not _configured or not _world_ext.has_method("get_military_report"):
		return 0
	return int((_world_ext.get_military_report() as Dictionary).get(
		"state_hash", 0))


# ------------------------------------------------------------- AI arming

## AI countries are every non-player country. Called after bootstrap and again
## when the player set is restored from a save.
func arm_ai(player_handles: PackedInt64Array) -> Dictionary:
	_ai_player_handles = player_handles.duplicate()
	if not _configured:
		return _fail("military_not_configured")
	return _apply_ai_arming()


func _apply_ai_arming() -> Dictionary:
	if not _configured or _world_ext == null:
		return _fail("military_not_configured")
	if _world_ext.has_method("set_military_ai_player_handles"):
		return _world_ext.set_military_ai_player_handles(_ai_player_handles)
	# Older bridge: one set_ai_country(slot, ai) call per country slot. Country
	# slots are dense, so iterating them is a cold-path cost only.
	if not _world_ext.has_method("set_military_ai_country"):
		return {"ok": true, "path": "unsupported", "reason":
			"military_ai_api_unavailable"}
	var applied := 0
	var player_slots := {}
	if _world_ext.has_method("get_country_cell_summary") and not _ai_player_handles.is_empty():
		# Handle -> slot is only resolvable through the country authority; the
		# native side owns that mapping, so let it decide when available.
		pass
	for slot in range(32):
		var result: Dictionary = _world_ext.set_military_ai_country(slot,
			0 if player_slots.has(slot) else 1)
		if bool(result.get("ok", false)):
			applied += 1
	return {"ok": true, "path": "per_slot", "applied": applied}


func ai_player_handles() -> PackedInt64Array:
	return _ai_player_handles


## Annual-report war section (design §19.2). Null when the native report has no
## war counters yet, so the caller can omit the section instead of showing 0.
func annual_war_section(year: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_military_report"):
		return {}
	if _world_ext.has_method("get_military_annual_section"):
		return _world_ext.get_military_annual_section(int(year))
	return {}


func player_tension(handle: int) -> float:
	if not _configured or not _world_ext.has_method("get_military_report"):
		return 0.0
	if _world_ext.has_method("get_military_tension"):
		return clampf(float(_world_ext.get_military_tension(int(handle))), 0.0, 1.0)
	return 0.0


func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


# The save provider restores before DCSystem registration. Hold only forwarding
# metadata here, then hand it to the session-owned job once at construction.
func restore_pending_event_progress(values: PackedInt64Array) -> bool:
	if values.size() != 3 or values[0] < 0 or values[1] < -1 or values[2] < 0: return false
	_restored_event_progress = values.duplicate()
	return true

func capture_pending_event_progress() -> PackedInt64Array:
	return PackedInt64Array([0, -1, 0]) if _restored_event_progress.is_empty() else _restored_event_progress.duplicate()

func take_restored_event_progress() -> PackedInt64Array:
	var values := _restored_event_progress.duplicate()
	_restored_event_progress.clear()
	return values
