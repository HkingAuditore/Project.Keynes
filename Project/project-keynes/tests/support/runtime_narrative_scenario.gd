extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const StoryPacket = preload("res://scripts/narrative/narrative_catalog_packet.gd")

var story_host: WorldRuntimeHost
var story_clock: WorldClock
var story_controller: PlayerController
var story_economy: EconomyFacade
var story_service: NarrativeEventService
var story_ext: DCWorldExt
var story_player: int
var story_cell: int
var story_day := 0


func _start_story(archive: Dictionary, event_ids: Array = [], config: NewGameConfig = null) -> bool:
	story_clock = WorldClock.new()
	story_clock.auto_start = false
	root.add_child(story_clock)
	story_clock.set_process(false)
	story_host = _create_host()
	story_host.runtime_economy_auto_pod_active = true
	root.add_child(story_host)
	story_host.configure(null, null, story_clock)
	story_host.set_climate_authority_override("force_on")
	story_controller = PlayerController.new()
	root.add_child(story_controller)
	story_controller.configure(null, null, story_host, story_clock, null)
	story_service = story_controller.narrative_service()
	if not event_ids.is_empty():
		var authored := story_service.catalog()
		story_service._catalog = NarrativeEventCatalog.new()
		for event_id in event_ids:
			story_service._catalog.register_event(authored.get_event(StringName(event_id)))
	archive = archive.duplicate(true)
	if not archive.has("event_pause_mask"):
		archive["event_pause_mask"] = 255
	story_controller.restore_narrative_state(archive)
	if config == null:
		config = _background_config()
	var configured := story_host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	if not bool(configured.get("ok", false)):
		_expect("formal story session configures", false)
		return false
	await story_host.generate_world()
	var ready := story_host.is_runtime_ready_for_ticks()
	_expect("formal story session starts", ready)
	if not ready:
		return false
	story_economy = story_host.get_generator().get_economy_facade()
	story_ext = story_economy.world_ext()
	story_cell = int(story_host.get_generator().gameplay_start_report().get("cell", -1))
	story_player = int(story_ext.get_country_cell_summary(story_cell).get("country_handle", 0))
	_expect("the starter has a committed country handle", story_player > 0)
	story_clock.set_speed(100.0)
	story_day = 0
	# Keep the published story reads, with no foreground modal or AI transport.
	story_host.simulation_committed.disconnect(story_controller._on_simulation_committed)
	story_service.offer_ready.disconnect(story_controller.narrative_flow()._on_service_offer_ready)
	story_service.ai_generation_requested.disconnect(story_controller._on_narrative_ai_generation_requested)
	return true


func _close_story() -> void:
	_expect("formal story session closes", bool((await story_host.close_world()).get("ok", false)))
	story_controller.free()
	story_host.free()
	story_clock.free()
	story_service = null
	story_economy = null
	story_ext = null


func _advance_story(day: int) -> bool:
	while story_day < day:
		var next_day := story_day + 1
		_publish_day(story_host, story_clock, next_day)
		if not await _wait_golden_read_boundary(story_host, story_economy, next_day):
			_expect("story commits day %d" % next_day, false)
			return false
		story_day = next_day
		story_service.consume_committed()
		var report := story_host.annual_report_status()
		var report_id := int(report.get("ready_report_id", 0))
		if report_id > 0 and story_day >= report_id * story_clock.days_per_year():
			story_host.mark_annual_report_presented(report_id)
	return true


func _choose_story(option: int) -> Dictionary:
	var offer := story_service.active_offer()
	var result := story_controller.request_command(&"narrative.choose", {
		"offer_id": int(offer.get("offer_id", 0)),
		"offer_generation": int(offer.get("offer_generation", 0)),
		"option_index": option,
	})
	_expect("choice is dated for day %d, %s" % [story_day + 1, result.get("code", "")],
		bool(result.get("ok", false)) and bool(result.get("pending", false))
		and int(result.get("effective_day", -1)) == story_day + 1)
	return result


func _story_records() -> Array[Dictionary]:
	return story_service.get_chronicle()


func _authored_weight(def: NarrativeEventDefinition, context: Dictionary) -> int:
	var era := int(context.get("era_index", 0))
	if era < def.min_era_index or era > def.max_era_index:
		return 0
	var technology: PackedStringArray = context.get("technology_ids", PackedStringArray())
	for key in def.required_technologies:
		if not technology.has(key):
			return 0
	for key in def.blocked_technologies:
		if technology.has(key):
			return 0
	var completed: PackedStringArray = context.get("completed_events", PackedStringArray())
	for key in def.required_events_completed:
		if not completed.has(key):
			return 0
	var flags: Dictionary = context.get("story_flags", {})
	for key in def.required_story_flags:
		if not flags.has(key):
			return 0
	for key in def.blocked_story_flags:
		if flags.has(key):
			return 0
	for condition in def.conditions:
		if not condition.evaluate(context):
			return 0
	var weight := def.base_weight
	var factor := 65536
	for rule in def.weight_rules:
		if rule.matches(context):
			weight += rule.add_weight
			factor = (factor * maxi(0, rule.multiplier_q16)) >> 16
	return clampi((maxi(0, weight) * factor) >> 16, 0, 1000000)


func _story_fixture_event(event_id: String, effects: Array, conditions: Array = []) -> Dictionary:
	return StoryPacket.encode_event(NarrativeEventDefinition.from_dict({
		"event_id": event_id, "title": "本地{family_name}", "body_text": "本地议事",
		"trigger_channel": NarrativeEventDefinition.TriggerChannel.SCHEDULED_ONLY,
		"conditions": conditions,
		"options": [{"text": "施行", "outcomes": [{"effects": effects}]}],
	}))
