extends RefCounted

## Binds the player narrative services and prepares or closes their runtime session.


static func _configure_narrative_runtime(owner: PlayerController) -> void:
	owner._narrative_component._configure_narrative_runtime(owner)
	if owner._runtime_host == null or not owner._runtime_host.has_method("register_session_module"):
		return
	var module := preload("res://scripts/game/runtime_session_module.gd").new()
	module.configure("narrative", ["restore"], ["world.narrative"], owner._prepare_narrative_session,
		owner._cancel_narrative_session, owner._narrative_service.release_world)
	owner._runtime_host.register_session_module(module)
	var consume: Callable = owner._narrative_service.executor_started.unbind(4)
	if not owner._runtime_host.world_ready.is_connected(consume):
		owner._runtime_host.world_ready.connect(consume)
	var settings := owner.get_node_or_null("/root/GameSettings")
	if settings != null and not settings.ai_narrative_changed.is_connected(owner._on_narrative_settings_changed):
		settings.ai_narrative_changed.connect(owner._on_narrative_settings_changed)
	if settings != null and not settings.event_pause_changed.is_connected(owner._on_event_pause_changed):
		settings.event_pause_changed.connect(owner._on_event_pause_changed)



static func _prepare_narrative_session(owner: PlayerController) -> Dictionary:
	var country: int = owner._runtime_host._resolve_player_country_handle()
	if country <= 0:
		return {"ok": true}
	var settings := owner.get_node_or_null("/root/GameSettings")
	var ai_enabled := settings != null and bool(settings.values().get("ai_narrative_enabled", false))
	var pause_mask := int(settings.values().get("event_pause_mask", 255)) if settings != null else 255
	return owner._narrative_service.bind_world(owner._runtime_host.generator(), owner._world_clock,
		country, owner._runtime_host.last_seed(), ai_enabled, pause_mask)



static func _cancel_narrative_session(owner: PlayerController) -> void:
	pass
