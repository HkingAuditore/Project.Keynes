class_name NarrativeEventService
extends RefCounted

## Reads the executor's committed story frame. Choice effects still use the
## existing adapters and the context included in the native choice receipt.
signal offer_ready(offer: Dictionary)
signal chronicle_updated()
signal ai_generation_requested(request_spec: Dictionary)

const CatalogPacket = preload("res://scripts/narrative/narrative_catalog_packet.gd")
const Effects = preload("res://scripts/narrative/narrative_effect_adapter.gd")

var _bus = null
var _generator = null
var _country: int = 0
var _view: Dictionary = {}
var _last_popup_day: int = -999
var _consumed_day: int = -1
var _last_ai_request: int = 0
var _ai_enabled := false
var _saved: Dictionary = {}
var _catalog: NarrativeEventCatalog


func bind_world(generator, clock: WorldClock, country: int, seed: int,
		enable_ai: bool) -> Dictionary:
	_generator = generator
	_country = country
	_bus = generator.get_gameplay_event_bus()
	_ai_enabled = enable_ai
	var packet := CatalogPacket.build(catalog(), generator, clock, country, seed, enable_ai)
	if _bus == null or not _bus.configure_story(packet, _saved):
		return {"ok": false, "code": "narrative_executor_configure_failed"}
	_saved = {}
	_refresh_view()
	return {"ok": true}


func release_world() -> Dictionary:
	_bus = null
	_generator = null
	_country = 0
	_view = {}
	_saved = {}
	_last_popup_day = -999
	_consumed_day = -1
	_last_ai_request = 0
	return {"ok": true}


func catalog() -> NarrativeEventCatalog:
	if _catalog == null:
		_catalog = NarrativeEventCatalog.build_default_catalog()
	return _catalog


func consume_committed() -> void:
	_refresh_view()
	var day := int(_view.get("day", -1))
	if day > _consumed_day:
		_consumed_day = day
		_forward_independence(_view.get("independence", []))


func active_offer() -> Dictionary:
	return (_view.get("active_offer", {}) as Dictionary).duplicate(true)


func has_active_offer() -> bool:
	return not (_view.get("active_offer", {}) as Dictionary).is_empty()


func ready_queue() -> Array:
	return (_view.get("ready_queue", []) as Array).duplicate(true)


func ready_queue_size() -> int:
	return (_view.get("ready_queue", []) as Array).size()


func unrest_fact_cursor() -> int:
	return int(_view.get("unrest_fact_cursor", -1))


func choose_option(args: Dictionary, sequence: int, sequence_alloc: Callable) -> Dictionary:
	var command := args.duplicate()
	command["country"] = _country
	command["sequence"] = sequence
	var receipt := _request(&"choose", command)
	if not bool(receipt.get("ok", false)):
		return receipt
	var outcome: Dictionary = receipt.outcome
	var ctx: Dictionary = receipt.context
	var effects := Effects.apply_effects(outcome.get("effects", []), ctx, self, _generator,
		_country, int(ctx.get("cell_idx", -1)), int(receipt.legacy_resolution_day), sequence_alloc)
	var concession: Dictionary = receipt.get("concession", {})
	if not concession.is_empty():
		_generator.get_economy_facade().transfer_country_cash_to_cohort(
			_country, int(concession.cohort), int(concession.amount),
			int(concession.day), int(concession.sequence))
	var resolved := _request(&"complete", {"offer_id": receipt.offer_id,
		"applied_summaries": Array(effects.applied_summaries)})
	if bool(resolved.get("ok", false)):
		resolved["outcome"] = outcome
		resolved["outcome_index"] = receipt.outcome_index
		resolved["applied_summaries"] = effects.applied_summaries
		_refresh_view()
		chronicle_updated.emit()
	return resolved


func allocate_modifier_source_id() -> int:
	return int(_request(&"source_id", {}).get("id", 0))


func set_ai_enabled(enabled: bool) -> void:
	if _bus == null or enabled == _ai_enabled:
		return
	if bool(_request(&"ai_enabled", {"enabled": enabled}).get("ok", false)):
		_ai_enabled = enabled


func accept_ai_generation(result: Dictionary, arrival_day: int) -> void:
	var payload := result.duplicate()
	var definition = result.get("definition", null)
	payload["definition"] = CatalogPacket.encode_event(definition) if definition != null else {}
	payload["arrival_day"] = arrival_day
	_request(&"ai_result", payload)
	_refresh_view()


func get_chronicle(offset: int = 0, limit: int = 64, filter_cell: int = -1) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for row: Dictionary in _view.get("chronicle", []):
		if filter_cell < 0 or int(row.get("cell_idx", -1)) == filter_cell:
			filtered.append(row.duplicate(true))
	var first := clampi(offset, 0, filtered.size())
	return filtered.slice(first, mini(first + maxi(1, limit), filtered.size()))


func chronicle_total_count(filter_cell: int = -1) -> int:
	return get_chronicle(0, 256, filter_cell).size()


func export_state() -> Dictionary:
	return _bus.capture_story() if _bus != null else _saved.duplicate(true)


func restore_state(state: Dictionary) -> Dictionary:
	_saved = state.duplicate(true)
	return {"ok": true}


func _request(kind: StringName, args: Dictionary) -> Dictionary:
	if _bus == null:
		return {"ok": false, "code": "narrative_runtime_unavailable"}
	return _bus.submit_story_request(kind, args)


func _refresh_view() -> void:
	if _bus == null:
		return
	var previous := int(_view.get("active_offer", {}).get("offer_id", 0))
	_view = _bus.story_view()
	_last_popup_day = int(_view.get("last_popup_day", -999))
	var offer := active_offer()
	if not offer.is_empty() and int(offer.offer_id) != previous:
		offer_ready.emit(offer)
	var request: Dictionary = _view.get("ai_request", {})
	var sequence := int(request.get("ai_request_seq", 0))
	if sequence > _last_ai_request:
		_last_ai_request = sequence
		ai_generation_requested.emit(request)


func _forward_independence(requests: Array) -> void:
	for item: Dictionary in requests:
		if item.has("new_owner"):
			var military = _generator.get_military_facade()
			if military != null:
				military.declare_war_forced(int(item.old_owner), int(item.new_owner))
				military.transfer_cell_garrison(int(item.old_owner), int(item.cell), int(item.new_owner))
		else:
			_generator.get_country_facade().create_country(StringName(item.stable_id),
				String(item.display_name), int(item.cell), int(item.day), int(item.sequence))
