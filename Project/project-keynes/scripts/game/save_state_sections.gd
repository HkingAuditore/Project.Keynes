extends RefCounted

const GameSaveCoordinator = preload("res://scripts/game/game_save_coordinator.gd")

## Builds and registers the save section providers and their context.


static func _collect_sections(owner: GameSaveCoordinator, saved_paused: bool, saved_speed: float,
		native_bundle: Dictionary, defer_provider_hashes: bool = false) -> Dictionary:
	var generator := owner._runtime_host.generator()
	var context := owner._provider_context(owner._runtime_host, generator, saved_paused, saved_speed)
	context["native_runtime_bundle"] = native_bundle.get("bytes", PackedByteArray())
	context["native_country_pkcn"] = native_bundle.get("country_pkcn", PackedByteArray())
	context["native_economy_ecp2"] = native_bundle.get("economy_ecp2", PackedByteArray())
	context["native_pkmi"] = native_bundle.get("pkmi", PackedByteArray())
	context["native_pknr"] = native_bundle.get("pknr", PackedByteArray())
	var sections := {}
	var provider_manifest: Array = []
	var provider_hash_payloads: Array = []
	var profile_save := OS.get_environment("PK_SAVE_PROFILE") == "1"
	var verify_provider_hashes := OS.get_environment("PK_SAVE_PROVIDER_HASH_VERIFY") == "1"
	for provider in owner._providers:
		var profile_start := Time.get_ticks_usec() if profile_save else 0
		var available: Dictionary = provider.can_save(context)
		if not bool(available.get("ok", false)):
			return available
		var written: Dictionary = provider.write_sections(context)
		if not bool(written.get("ok", false)):
			return written
		var provider_sections: Dictionary = written.get("sections", {})
		for section_id in provider_sections:
			if sections.has(section_id):
				return GameSaveCoordinator._result(false, "save_provider_duplicate_section",
					"多个 provider 写入了 section：%s" % section_id)
			sections[section_id] = provider_sections[section_id]
		context.current_provider_sections = provider_sections
		var profile_hash_start := Time.get_ticks_usec() if profile_save else 0
		var manifest: Dictionary = provider.manifest_entry(context, not defer_provider_hashes)
		if defer_provider_hashes:
			# 在安全边界冻结与原 state_hash 完全相同的 Variant 字节；
			# 后台只读私有字节，不能再访问 provider、Node 或活跃世界。
			var payload := {"manifest_index": provider_manifest.size(),
				"bytes": var_to_bytes(provider_sections)}
			if verify_provider_hashes:
				payload["expected_hash"] = provider.state_hash(context)
			provider_hash_payloads.append(payload)
		provider_manifest.append(manifest)
		if profile_save:
			print("[save-provider-cost] id=%s capture_ms=%.3f manifest_ms=%.3f" % [
				provider.provider_id(), float(profile_hash_start - profile_start) / 1000.0,
				float(Time.get_ticks_usec() - profile_hash_start) / 1000.0])
	provider_manifest.append({
		"provider_id": GameSaveCoordinator.TECHNOLOGY_INDUSTRY_PROVIDER_ID,
		"schema_version": GameSaveCoordinator.TECHNOLOGY_INDUSTRY_REVISION,
		"sections": PackedStringArray(),
		"content_hash": "",
	})
	for required in GameSaveCoordinator.REQUIRED_SECTIONS:
		if not sections.has(required):
			return GameSaveCoordinator._result(false, "save_provider_missing", "运行时缺少 provider：%s" % required)
	return {"ok": true, "code": "ok", "message": "", "sections": sections,
		"provider_manifest": provider_manifest, "provider_hash_payloads": provider_hash_payloads}



static func _economy_checkpoint_format(owner: GameSaveCoordinator) -> Dictionary:
	if not owner._economy_format.is_empty():
		return owner._economy_format
	owner._economy_format = {"schema_version": 53, "abi_version": 2, "hash_version": 1}
	if ClassDB.class_exists("DCWorldExt"):
		var probe: DCWorldExt = GameSaveCoordinator.NativeWorld.create()
		if probe != null:
			owner._economy_format = probe.get_economy_checkpoint_format()
	return owner._economy_format



static func _register_providers(owner: GameSaveCoordinator) -> void:
	var registered := owner._install_provider_entries(GameSaveCoordinator.WorldStateModules.builtins(
		int(owner._economy_checkpoint_format().schema_version), GameSaveCoordinator.PKMI_SCHEMA))
	if not bool(registered.ok):
		owner._provider_registration_error = registered
		push_error(String(registered.message))



static func _install_provider_entries(owner: GameSaveCoordinator, entries: Array) -> Dictionary:
	var resolved := GameSaveCoordinator.ModuleRegistry.resolve(entries)
	if not bool(resolved.ok):
		return resolved
	owner._provider_entries = entries.duplicate()
	owner._providers = resolved.modules
	owner._provider_registration_error.clear()
	return {"ok": true, "code": "ok"}


## Register a new persistent module at composition time, before binding a game.
## The module supplies its own callbacks; the coordinator needs no new branch.
static func register_state_module(owner: GameSaveCoordinator, provider, restore_after: PackedStringArray) -> Dictionary:
	if is_instance_valid(owner._runtime_host) or owner._busy or not owner._pending_load.is_empty():
		return GameSaveCoordinator._result(false, "module_registration_session_active", "请在进入游戏前登记模块。")
	var candidate := owner._provider_entries.duplicate()
	var entry := GameSaveCoordinator.ModuleRegistry.state_entry(provider, restore_after)
	if entry.is_empty():
		return GameSaveCoordinator._result(false, "module_descriptor_invalid", "模块缺少保存接口。")
	# Player presentation is installed after every business module, including
	# extensions unknown to the built-in composition.
	for index in candidate.size():
		if String(candidate[index].id) == "player_session":
			candidate[index] = candidate[index].duplicate(true)
			candidate[index].after.append(String(entry.id))
	candidate.append(entry)
	return owner._install_provider_entries(candidate)



static func _provider_context(owner: GameSaveCoordinator, host: WorldRuntimeHost, generator: MapGenerator,
		saved_paused: bool, saved_speed: float) -> Dictionary:
	return {
		"host": host,
		"generator": generator,
		"world": generator.get_data_core_world() if generator != null else null,
		"event_bus": generator.get_gameplay_event_bus() if generator != null else null,
		"saved_paused": saved_paused,
		"saved_speed": saved_speed,
		"clock": owner._world_clock,
		"session": GameFlow.session(),
		"set_session": GameFlow.set_session,
		"player": owner._player_controller,
		"viewport": owner.get_viewport(),
		"clock_restored": Callable(owner, "_clock_restored"),
		"set_pending_view": Callable(owner, "_set_pending_view"),
	}
