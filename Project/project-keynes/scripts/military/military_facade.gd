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
		"army.disband",
	],
	diplomacy_ops = ["war.declare", "peace.propose", "peace.respond"],
}

const PEACE_TERM_KINDS := [
	"white", "cede", "annex", "lump_sum", "installments", "goods", "return"]

var _world_ext: DCWorldExt = null
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


## `economy_catalog` is `EconomyFacade.native_catalog()`; `technology_catalog`
## is `TechnologyCatalog.compile_native_catalog()`. Both are required because
## dense good / profession / technology ids come from those authorities.
## `military_catalog_data` overrides the JSON path (tests, authored overrides).
func configure(world_ext: DCWorldExt, economy_catalog: Dictionary,
		technology_catalog: Dictionary, world_seed: int,
		military_catalog_data: Dictionary = {}) -> Dictionary:
	_world_ext = world_ext
	_configured = false
	_catalog = {}
	_catalog_hash = 0
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
		return _world_ext.run_military_catch_up({"day_index": int(day)})
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
