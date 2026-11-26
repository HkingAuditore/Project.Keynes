class_name MilitaryFacade
extends RefCounted

const MaintenanceRows = preload("res://scripts/military/military_maintenance_rows.gd")

## Cold-path GDScript wrapper around the native military bindings on DCWorldExt.
##
## NativeWorld.create() verifies all methods in the binding manifest before use.
## Without a native world the facade remains unconfigured and its daily system
## stays idle.
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

const MAINTENANCE_KIND_BUILDING = MaintenanceRows.MAINTENANCE_KIND_BUILDING
const MAINTENANCE_KIND_EQUIPMENT = MaintenanceRows.MAINTENANCE_KIND_EQUIPMENT
const MAINTENANCE_KIND_NAMES = MaintenanceRows.MAINTENANCE_KIND_NAMES
const MAINTENANCE_REASON_TEXT = MaintenanceRows.MAINTENANCE_REASON_TEXT
const MAINTENANCE_NO_DEMAND = MaintenanceRows.MAINTENANCE_NO_DEMAND
const MAINTENANCE_NO_DEMAND_SORT = MaintenanceRows.MAINTENANCE_NO_DEMAND_SORT
const MAINTENANCE_ALL_COUNTRIES = MaintenanceRows.MAINTENANCE_ALL_COUNTRIES
const MAINTENANCE_FIELD_ALIASES = MaintenanceRows.MAINTENANCE_FIELD_ALIASES

var _world_ext: Object = null # configure() still requires DCWorldExt.
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
var _missing_api_reason := ""
var _event_cursor := 0
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
func configure(world_ext: DCWorldExt, economy_catalog: Dictionary,
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
	if _world_ext == null:
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
	return bool(_world_ext.military_should_run(int(day)))


## Non-whole-graph entry point (DCSystem). `day` is the committed day index the
## daily system is advancing; the native side captures its own digest from the
## committed Country/Economy state and emits D+1 intents.
func run_daily(day: int) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	var result: Dictionary = _world_ext.run_military_daily({"day_index": day})
	_last_daily_report = result if result is Dictionary else {}
	invalidate_maintenance_cache()
	return _last_daily_report


func catch_up(day: int) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
	var caught: Dictionary = _world_ext.run_military_catch_up({"day_index": int(day)})
	invalidate_maintenance_cache()
	return caught


## Render selection (army handle, 0 = none). The native render snapshot returns
## the selected army's area cells and remaining path cells.
func set_render_selection(army_handle: int) -> Dictionary:
	if not _configured:
		return _fail("military_render_selection_api_unavailable")
	return _world_ext.set_military_render_selection(int(army_handle))


func last_daily_report() -> Dictionary:
	if _configured:
		var current: Dictionary = _world_ext.get_military_daily_result()
		if not current.is_empty():
			return current
	return _last_daily_report.duplicate(false)


func report() -> Dictionary:
	if not _configured:
		return {"ok": false, "configured": false, "reason": _missing_api_reason}
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


func declare_war(country: int, target_country: int) -> Dictionary:
	return submit([{"op": "war.declare", "country": country,
		"other": target_country}])


func declare_war_forced(country: int, target_country: int) -> Dictionary:
	return submit([{"op": "war.declare_forced", "country": country,
		"other": target_country}])


func transfer_cell_garrison(country: int, cell: int,
		new_owner: int) -> Dictionary:
	return submit([{"op": "garrison.transfer_cell", "country": country,
		"cell": cell, "other": new_owner}])


func propose_peace(country: int, war: int, terms: Array) -> Dictionary:
	return submit([{"op": "peace.propose", "country": country,
		"other": war, "terms": terms}])


func respond_peace(country: int, war: int, accept: bool) -> Dictionary:
	return submit([{"op": "peace.respond", "country": country, "other": war,
		"count": 1 if accept else 0}])


# ------------------------------------------------------------- queries

func country_snapshot(country: int) -> Dictionary:
	if not _configured:
		return _fail("military_country_snapshot_unavailable")
	return _world_ext.get_military_country_snapshot(int(country))


func armies(country: int) -> Array:
	if not _configured:
		return []
	var result = _world_ext.get_military_armies(int(country))
	return result if result is Array else []


func army(army_handle: int) -> Dictionary:
	if not _configured:
		return _fail("military_army_api_unavailable")
	return _world_ext.get_military_army(int(army_handle))


func cell_snapshot(cell: int, observer: int = 0) -> Dictionary:
	if not _configured:
		return _fail("military_cell_snapshot_unavailable")
	return _world_ext.get_military_cell_snapshot(int(cell), int(observer))


func render_snapshot(after_revision: int = 0) -> Dictionary:
	if not _configured:
		return {"ok": false, "available": false,
			"reason": "military_render_api_unavailable"}
	return _world_ext.get_military_render_snapshot(int(after_revision))


func control_snapshot() -> Dictionary:
	if not _configured:
		return {"ok": false, "available": false,
			"reason": "military_control_api_unavailable"}
	return _world_ext.get_military_control_snapshot()


func preview_path(army_handle: int, cell: int) -> Dictionary:
	if not _configured:
		return _fail("military_path_api_unavailable")
	return _world_ext.preview_military_path(int(army_handle), int(cell))


func evaluate_peace(war: int, proposer: int, terms: Array) -> Dictionary:
	if not _configured:
		return _fail("military_peace_api_unavailable")
	return _world_ext.evaluate_military_peace(int(war), int(proposer), terms)


func catalog_view() -> Dictionary:
	if not _configured:
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
	var raw = _world_ext.call("get_military_maintenance_snapshot") if native_args <= 0 \
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


static func shape_maintenance(rows, catalog: Dictionary) -> Dictionary:
	return MaintenanceRows.shape_maintenance(rows, catalog)


static func maintenance_reason_text(reason: int) -> String:
	return MaintenanceRows.maintenance_reason_text(reason)


static func _summarize_maintenance(rows: Array) -> Dictionary:
	return MaintenanceRows._summarize_maintenance(rows)


## Drain the native event ring into GameplayEventBus-compatible batches.
## `cursor` is advanced in place by the caller (MilitaryDailySystem owns it).
func poll_events(after_id: int, limit: int = 256) -> Array:
	if not _configured:
		return []
	var result = _world_ext.poll_military_events(int(after_id), int(limit))
	return result if result is Array else []


# ------------------------------------------------------------- persistence

func encode_state() -> PackedByteArray:
	if not _configured:
		return PackedByteArray()
	var result = _world_ext.encode_military_state()
	return result if result is PackedByteArray else PackedByteArray()


func restore_state(bytes: PackedByteArray) -> Dictionary:
	if not _configured:
		return _fail("military_not_configured")
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
	if not _configured:
		return 0
	return int((_world_ext.get_military_report() as Dictionary).get(
		"state_hash", 0))


# ------------------------------------------------------------- AI arming

## Arm the foreign countries during a new game's bootstrap.
func arm_ai(player_handles: PackedInt64Array) -> Dictionary:
	if not _configured or _world_ext == null:
		return _fail("military_not_configured")
	return _world_ext.set_military_ai_player_handles(player_handles)


## Annual-report war section (design §19.2). Null when the native report has no
## war counters yet, so the caller can omit the section instead of showing 0.
func annual_war_section(year: int) -> Dictionary:
	if not _configured:
		return {}
	if _world_ext.has_method("get_military_annual_section"):
		return _world_ext.get_military_annual_section(int(year))
	return {}


func player_tension(handle: int) -> float:
	if not _configured:
		return 0.0
	if _world_ext.has_method("get_military_tension"):
		return clampf(float(_world_ext.get_military_tension(int(handle))), 0.0, 1.0)
	return 0.0


func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


# MDJ1 belongs to the same native boundary as the battle and event records.
func restore_pending_event_progress(values: PackedInt64Array) -> bool:
	return _world_ext.restore_military_event_progress(values)

func capture_pending_event_progress() -> PackedInt64Array:
	return _world_ext.capture_military_event_progress()
