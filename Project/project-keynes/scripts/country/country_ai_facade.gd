class_name CountryAiFacade
extends RefCounted

## Cold-path wrapper around the native foreign-country AI.  Configuration and
## save/restore run at safe boundaries on the main thread; everything else is
## read-only diagnostics.  The AI itself plans inside the Country authority day
## (worker or synchronous slice) and only emits player-equivalent commands.

const CountryAiCatalogScript = preload("res://scripts/country/country_ai_catalog.gd")

var _world_ext: Object = null
var _configured := false
var _last_decision_id := 0
var _configure_result: Dictionary = {}


## `excluded_handles` are the player country handles.  The native runtime stays
## unarmed (never plans) until they are set here or restored from `pkai`.
func configure(world_ext: Object, seed: int, map = null,
		excluded_handles: PackedInt64Array = PackedInt64Array(),
		catalog_resource = null) -> Dictionary:
	_world_ext = world_ext
	_configured = false
	_last_decision_id = 0
	if _world_ext == null or not _world_ext.has_method("configure_country_ai"):
		_configure_result = {"ok": false, "reason": "country_ai_api_unavailable"}
		return _configure_result
	var resource = catalog_resource
	if resource == null:
		resource = CountryAiCatalogScript.load_default()
	if resource == null:
		_configure_result = {"ok": false, "reason": "country_ai_catalog_unavailable"}
		return _configure_result
	var compiled: Dictionary = resource.compile_native_catalog(seed)
	if not bool(compiled.get("ok", false)):
		_configure_result = compiled
		return _configure_result
	var result: Dictionary = _world_ext.configure_country_ai(compiled.get("catalog", {}))
	if not bool(result.get("ok", false)):
		_configure_result = {"ok": false, "reason": String(result.get("code", "country_ai_configure_failed"))}
		return _configure_result
	if map != null and map.has_method("neighbor_indices_packed"):
		_world_ext.set_country_ai_topology(map.neighbor_indices_packed(), PackedInt32Array())
	if not excluded_handles.is_empty():
		_world_ext.set_country_ai_excluded_handles(excluded_handles)
	_configured = true
	_configure_result = result
	return result


func is_configured() -> bool:
	return _configured


func world_ext() -> Object:
	return _world_ext


func set_player_handles(handles: PackedInt64Array) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country_ai_not_configured"}
	return _world_ext.set_country_ai_excluded_handles(handles)


func set_mode(mode: String) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country_ai_not_configured"}
	return _world_ext.set_country_ai_mode(mode)


func report() -> Dictionary:
	if not _configured:
		return {"ok": false, "configured": false}
	return _world_ext.get_country_ai_report()


func country_snapshot(handle: int) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country_ai_not_configured"}
	return _world_ext.get_country_ai_country_snapshot(handle)


## Decisions newer than `after_id`, optionally filtered to one country.
func decision_log(handle: int = 0, after_id: int = 0, limit: int = 128) -> Array:
	if not _configured:
		return []
	var polled: Dictionary = _world_ext.poll_country_ai_decisions(after_id, limit)
	var rows: Array = polled.get("decisions", [])
	if handle == 0:
		return rows
	return rows.filter(func(row: Dictionary) -> bool: return int(row.get("handle", 0)) == handle)


## Incremental cursor for debug panels: returns only decisions not seen yet.
func poll_new_decisions(limit: int = 256) -> Array:
	if not _configured:
		return []
	var polled: Dictionary = _world_ext.poll_country_ai_decisions(_last_decision_id, limit)
	_last_decision_id = int(polled.get("last_id", _last_decision_id))
	return polled.get("decisions", [])


func drain_record_rows(limit: int = 4096) -> Array:
	if not _configured:
		return []
	return (_world_ext.drain_country_ai_record_rows(limit) as Dictionary).get("rows", [])


func encode_state() -> PackedByteArray:
	if not _configured:
		return PackedByteArray()
	return _world_ext.encode_country_ai_state()


func restore_state(bytes: PackedByteArray) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country_ai_not_configured"}
	var result: Dictionary = _world_ext.restore_country_ai_state(bytes)
	_last_decision_id = 0
	if not bool(result.get("ok", false)):
		return {"ok": false, "reason": String(result.get("code", "pkai_restore_failed"))}
	return result
