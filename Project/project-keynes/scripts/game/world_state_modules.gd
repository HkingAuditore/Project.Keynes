extends RefCounted

## Composition only. State and encoding stay with the registered providers.
const Registry = preload("res://scripts/game/runtime_module_registry.gd")
const Bindings = preload("res://scripts/game/world_state_bindings.gd")
const RuntimeStateProviderScript = preload("res://scripts/game/runtime_state_provider.gd")
const OPTIONAL_ARCHIVES := ["pkcm", "pkgp", "pktr", "pkef", "pkid", "pkai", "pkmi", "pkar", "pknr"]
const READABLE_SCHEMAS := {
	"environment": [3], "pkfg": [1, 2, 3, 4],
	"journal": [1, 2, 3, 4], "pkid": [1, 2],
}
const RESTORE_AFTER := {
    "dynamic_world": [],
    "environment": ["dynamic_world"],
    "pkcm": ["environment"],
    "world_clock": ["dynamic_world"],
    "simulation_runtime": ["environment", "pkcm", "world_clock"],
    "pkmi": ["pkcn"],
    "pkef": ["pkmi"],
    "pkgp": ["ecp2"],
    "pkfg": ["pkcn", "ecp2", "pkgp"],
    "pkai": ["pkcn", "ecp2"],
    "journal": ["ecp2", "pkgp", "pkfg"],
    "pktr": ["journal"],
    "pkid": ["pktr", "pkef", "ecp2", "pkgp"],
    "pkar": ["pkid"],
    "pknr": ["pkar"],
    "player_session": ["dynamic_world", "environment", "world_clock", "simulation_runtime", "pkcm", "pkcn", "pkmi", "pkef", "ecp2", "pkgp", "pkfg", "pkai", "journal", "pktr", "pkid", "pkar", "pknr"],
}


const GeographyState = preload("res://scripts/game/save_modules/geography_state.gd")

const ClockState = preload("res://scripts/game/save_modules/clock_state.gd")

const SimulationState = preload("res://scripts/game/save_modules/simulation_state.gd")

const CountryState = preload("res://scripts/game/save_modules/country_state.gd")

const EconomyState = preload("res://scripts/game/save_modules/economy_state.gd")

const RulesState = preload("res://scripts/game/save_modules/rules_state.gd")

const VisionState = preload("res://scripts/game/save_modules/vision_state.gd")

const HistoryState = preload("res://scripts/game/save_modules/history_state.gd")

const PlayerState = preload("res://scripts/game/save_modules/player_state.gd")

static func builtins(economy_schema: int, military_schema: int) -> Array:
	var adapters := {
		"geography": GeographyState.new(),
		"clock": ClockState.new(),
		"simulation": SimulationState.new(),
		"country": CountryState.new(),
		"economy": EconomyState.new(),
		"rules": RulesState.new(),
		"vision": VisionState.new(),
		"history": HistoryState.new(),
		"player": PlayerState.new(),
	}
	var providers := [
		_make_provider(adapters["geography"], &"dynamic_world", 1,
			PackedStringArray(["new_game_config", "dynamic_world"]),
			"_can_world_provider", "_write_world_provider", "_restore_world_provider"),
		_make_provider(adapters["geography"], &"environment", 3, PackedStringArray(["environment"]),
			"_can_environment_provider", "_write_environment_provider",
			"_restore_environment_provider"),
		_make_provider(adapters["rules"], &"pkcm", 3, PackedStringArray(["pkcm"]),
			"_can_modifier_provider", "_write_climate_modifier_provider",
			"_restore_climate_modifier_provider"),
		_make_provider(adapters["clock"], &"world_clock", 1, PackedStringArray(["world_clock"]),
			"_can_clock_provider", "_write_clock_provider", "_restore_clock_provider"),
		_make_provider(adapters["simulation"], &"simulation_runtime", 2, PackedStringArray(["simulation_runtime"]),
			"_can_simulation_runtime_provider", "_write_simulation_runtime_provider",
			"_restore_simulation_runtime_provider"),
		_owned_provider(adapters["country"], CountryState.archive_contract()),
		# Military restores right after Country (its digest reads territory) and
		# before Effect/Economy (design §22: PKMI between PKCN and PKEF/ECP2).
		_make_provider(adapters["country"], &"pkmi", military_schema, PackedStringArray(["pkmi"]),
			"_can_military_provider", "_write_military_provider",
			"_restore_military_provider"),
		# Effect restores before Economy so ECP2 can cross-check every
		# SETTLING expedition transaction against authoritative PKEF state.
		_make_provider(adapters["rules"], &"pkef", 11, PackedStringArray(["pkef"]),
			"_can_effect_provider", "_write_effect_provider",
			"_restore_effect_provider"),
		# Negotiate with the loaded DLL: an old editor must never stamp a new
		# manifest on bytes produced by its still-loaded ABI2 extension.
		_owned_provider(adapters["economy"], EconomyState.archive_contract(economy_schema)),
		_make_provider(adapters["rules"], &"pkgp", 3, PackedStringArray(["pkgp"]),
			"_can_modifier_provider", "_write_gameplay_modifier_provider",
			"_restore_gameplay_modifier_provider"),
		# 视野排在 PKCN 之后：恢复时要先有领土才能重解算可见性。
		_make_provider(adapters["vision"], &"pkfg", 4, PackedStringArray(["pkfg"]),
			"_can_vision_provider", "_write_vision_provider", "_restore_vision_provider"),
		# Country AI memory, player exclusion and Economy-pending colonization
		# intents. Restores after PKCN/ECP2 so handles and the Economy inbox exist.
		_make_provider(adapters["country"], &"pkai", 1, PackedStringArray(["pkai"]),
			"_can_country_ai_provider", "_write_country_ai_provider",
			"_restore_country_ai_provider"),
		# v4 also persists custom gameplay commits (including canal geography)
		# with event_id=-1 idempotency evidence. The manifest
		# must match the payload schema, or list_slots() rejects newly written saves.
		_make_provider(adapters["history"], &"journal", 4, PackedStringArray(["journal"]),
			"_can_journal_provider", "_write_journal_provider", "_restore_journal_provider"),
		_make_provider(adapters["rules"], &"pktr", 6, PackedStringArray(["pktr"]),
			"_can_trigger_provider", "_write_trigger_provider",
			"_restore_trigger_provider"),
		# PKID also certifies the plan 11.5 execution contract in the manifest.
		# THREE version spaces live here and are never interchangeable:
		#   * this provider-section `schema` = 2 (the pkid manifest entry's own);
		#   * the PKID payload schema = 14 (inside the section bytes, native);
		#   * `execution_contract_hash` -- neither of the above, a hash of the
		#     rule versions plus the ideology / Effect / Modifier catalogs this
		#     runtime was configured with.
		# The contract can stay equal across a payload schema bump and change
		# without one (a catalog edit), so bumping the payload schema does NOT
		# certify a different contract, and PK_SAVE_MIGRATE cannot make one safe:
		# migration is a schema operation, the contract is not a schema version.
		# Never compare the three.
		_make_provider(adapters["rules"], &"pkid", 2, PackedStringArray(["pkid"]),
			"_can_ideology_provider", "_write_ideology_provider",
			"_restore_ideology_provider", &"_ideology_manifest_identity"),
		_make_provider(adapters["history"], &"pkar", 1, PackedStringArray(["pkar"]),
			"_can_annual_provider", "_write_annual_provider", "_restore_annual_provider"),
		_make_provider(adapters["history"], &"pknr", 1, PackedStringArray(["pknr"]),
			"_can_narrative_provider", "_write_narrative_provider", "_restore_narrative_provider"),
		_make_provider(adapters["player"], &"player_session", 1,
			PackedStringArray(["player_context", "player_view", "preview"]),
			"_can_player_provider", "_write_player_provider", "_restore_player_provider"),
	]

	var entries: Array = []
	for provider in providers:
		var id := String(provider.provider_id())
		var schemas := PackedInt32Array(READABLE_SCHEMAS.get(id, [provider.schema_version()]))
		if id == "pkcn": schemas = CountryState.archive_contract().readable_versions
		elif id == "ecp2": schemas = EconomyState.archive_contract(economy_schema).readable_versions
		if id == "ecp2" and OS.get_environment("PK_SAVE_MIGRATE") == "1" and 53 not in schemas:
			schemas.append(53)
		provider.configure_compatibility(schemas, id in OPTIONAL_ARCHIVES)
		provider.configure_context_binding(Bindings.for_module.bind(id))
		if id == "simulation_runtime":
			provider.configure_restore_reads(PackedStringArray(["ecp2"]))
		elif id in ["pkmi", "pkai"]:
			provider.configure_restore_reads(PackedStringArray(["player_context"]))
		var dependencies: PackedStringArray
		if id == "pkcn": dependencies = CountryState.archive_contract().restore_after
		elif id == "ecp2": dependencies = EconomyState.archive_contract(economy_schema).restore_after
		else: dependencies = PackedStringArray(RESTORE_AFTER[id])
		entries.append(Registry.state_entry(provider, dependencies))
	return entries


static func _make_provider(owner: Object, provider_id: StringName, schema: int, section_ids: PackedStringArray,
		can_method: StringName, write_method: StringName,
		restore_method: StringName, identity_method: StringName = &""):
	var provider = RuntimeStateProviderScript.new().configure(provider_id, schema, section_ids,
		Callable(owner, can_method), Callable(owner, write_method),
		Callable(owner, restore_method), Callable(owner, "_hash_provider_sections"))
	provider.retain_adapter(owner)
	provider.configure_codecs(owner.section_codecs(provider_id, section_ids))
	owner.configure_provider(provider)
	if identity_method != &"":
		provider.configure_manifest_identity(Callable(owner, identity_method))
	return provider

static func _owned_provider(owner: Object, contract: Dictionary):
	var provider = _make_provider(owner, contract.id, contract.version, contract.sections,
		contract.can, contract.write, contract.restore)
	return provider
