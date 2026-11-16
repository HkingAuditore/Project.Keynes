extends SceneTree

const Context = preload("res://scripts/game/loading_catalog_context.gd")
const Gate = preload("res://scripts/geography/loading_frame_gate.gd")
const Economy = preload("res://scripts/economy/economy_catalog.gd")
const Modifier = preload("res://scripts/modifier/modifier_catalog.gd")
const Effects = preload("res://scripts/effect/effect_domain_catalog.gd")
const Facade = preload("res://scripts/economy/economy_facade.gd")
const Display = preload("res://scripts/economy/economy_facade_display.gd")
const Family = preload("res://scripts/family/family_effect_catalog.gd")
const Ideology = preload("res://scripts/ideology/ideology_catalog.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)

func _same(label: String, before: Dictionary, after: Dictionary) -> void:
	_expect(label + " valid", bool(before.get("ok", false)) and bool(after.get("ok", false)))
	_expect(label + " keys", before.keys() == after.keys())
	for key in before:
		_expect(label + "/" + String(key), before[key] == after.get(key))

func _run() -> void:
	LoadingCatalogCache.invalidate()
	# Cancel a real threaded source load. Collection must finish without keeping
	# the canceled world/gate alive or blocking the cancellation callback.
	var canceled_load := Context.new(Gate.new())
	process_frame.connect(canceled_load.frame_gate.cancel, CONNECT_ONE_SHOT)
	var canceled_source: Resource = await canceled_load.resource("res://data/ideologies/default_ideology_catalog.tres")
	_expect("threaded source cancellation returns no resource", canceled_source == null)
	var released_context: WeakRef = weakref(canceled_load)
	canceled_load = null
	# Let the cancel callback unwind; it legitimately owns the context until then.
	await process_frame
	_expect("pending resource does not retain canceled context", released_context.get_ref() == null)
	while Context.ResourceRequest.pending_count > 0:
		await process_frame
	_expect("canceled threaded source request collected", Context.ResourceRequest.pending_count == 0)
	# A threaded preload must still run load_default's catalog/profile hook.
	var hook_context := Context.new(Gate.new())
	var held: Resource = await hook_context.resource(Ideology.DEFAULT_PATH)
	var original_profile: Resource = held.profile
	var original_gate: bool = Ideology.support_gate_enabled
	Ideology.support_gate_enabled = false
	var hooked: Resource = await hook_context.default_resource(Ideology.DEFAULT_PATH, Ideology.load_default)
	_expect("threaded default preserves loader hook and cached identity", hooked == held and not bool(hooked.profile.support_gate_enabled))
	Ideology.support_gate_enabled = original_gate
	held.profile = original_profile
	hook_context.frame_gate.cancel()
	var canceled_hook: Resource = await hook_context.default_resource(Ideology.DEFAULT_PATH, Ideology.load_default)
	_expect("canceled default does not apply loader hook", canceled_hook == null and held.profile == original_profile)
	var context := Context.new(Gate.new())
	var economy_before: Dictionary = Economy.compile_native_catalog()
	var economy_after: Dictionary = await Economy.compile_native_catalog_cooperative(context)
	_same("economy", economy_before, economy_after)
	# A caller may erase keys or modify nested data without poisoning another user.
	economy_after.erase("ok")
	var again: Dictionary = await Economy.compile_native_catalog_cooperative(context)
	_same("economy_cache", economy_before, again)
	_expect("default economy built once", context.compile_counts.get("economy", 0) == 1)
	var modifier: Resource = Modifier.load_default()
	var modifier_before: Dictionary = modifier.compile_native_catalog()
	var modifier_after: Dictionary = await modifier.compile_native_catalog_cooperative(context)
	_same("modifier", modifier_before, modifier_after)
	_expect("modifier reuses economy", context.compile_counts.get("economy", 0) == 1)
	# External .tres children must be frozen too (duplicate(true) shares them).
	var external_modifier: Resource = modifier.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	var modifier_path := "user://loading_freeze_modifier_%d.tres" % Time.get_ticks_usec()
	_expect("external modifier fixture saved", ResourceSaver.save(external_modifier.definitions[0], modifier_path) == OK)
	external_modifier.definitions[0] = load(modifier_path)
	var changed_modifier: Resource = external_modifier.definitions[0]
	var modifier_expected: Dictionary = external_modifier.compile_native_catalog()
	var modifier_context := Context.new(Gate.new())
	modifier_context._slice_started = 0
	process_frame.connect(func(): changed_modifier.key = &"", CONNECT_ONE_SHOT)
	_same("modifier_external_frozen", modifier_expected,
		await external_modifier.compile_native_catalog_cooperative(modifier_context))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(modifier_path))

	var effect_before: Resource = Effects.build()
	var effect_after: Resource = await Effects.build_cooperative(context)
	_expect("effects available", effect_before != null and effect_after != null)
	if effect_before != null and effect_after != null:
		_same("effects", effect_before.compile_native_catalog(),
			await effect_after.compile_native_catalog_cooperative(context))
	if effect_before != null and effect_after != null:
		_expect("effect native extensions", effect_before.native_extensions == effect_after.native_extensions)
	var sync_display := Facade.new()
	var coop_display := Facade.new()
	Display.configure_displays(sync_display)
	await Display._configure_displays(context, coop_display)
	for field in ["_profession_display_names", "_ethnicity_display_names", "_building_display_names",
			"_need_display_names", "_good_display_names", "_family_trait_descriptions",
			"_family_trait_copy", "_family_trait_effect_keys", "_family_effect_displays",
			"_family_modifier_displays", "_family_trigger_displays"]:
		_expect("displays/" + field, sync_display.get(field) == coop_display.get(field)
			and sync_display.get(field).keys() == coop_display.get(field).keys())
	if effect_after != null and not effect_after.definitions.is_empty():
		var external_path := "user://loading_freeze_effect_%d.tres" % Time.get_ticks_usec()
		_expect("external effect fixture saved", ResourceSaver.save(effect_after.definitions[0], external_path) == OK)
		effect_after.definitions[0] = load(external_path)
		var expected_effect: Dictionary = effect_after.compile_native_catalog()
		var changing_definition: Resource = effect_after.definitions[0]
		_expect("effect fixture has external path", not changing_definition.resource_path.is_empty())
		var original_key: StringName = changing_definition.key
		var freezing_effect := Context.new(Gate.new())
		freezing_effect._slice_started = 0
		process_frame.connect(func(): changing_definition.key = &"test.changed_during_compile", CONNECT_ONE_SHOT)
		_same("effect_frozen", expected_effect,
			await effect_after.compile_native_catalog_cooperative(freezing_effect))
		changing_definition.key = original_key
		DirAccess.remove_absolute(ProjectSettings.globalize_path(external_path))
	var profile: Resource = load(Facade.DEFAULT_PROFILE_PATH).duplicate(true)
	var expected_profile: Dictionary = profile.to_native_profile()
	var profile_context := Context.new(Gate.new())
	profile_context._slice_started = 0
	var profile_facade := Facade.new()
	var profile_world := DCWorldExt.new()
	process_frame.connect(func():
		profile.money_scale += 1
		profile_context.frame_gate.cancel(), CONNECT_ONE_SHOT)
	var canceled_config: Dictionary = await profile_facade.configure_cooperative(
		profile_context, profile_world, 1, 20260723, profile, economy_before)
	_expect("profile frozen before display yields", profile_facade._profile.to_native_profile() == expected_profile)
	_expect("canceled configure does not install", canceled_config.get("reason") == "loading_canceled" and not profile_facade.is_configured())
	_expect("effect reuses default economy", context.compile_counts.get("economy", 0) == 1)
	# An explicit empty family catalog is a distinct input, never the default.
	var empty_family := Family.new()
	_same("family_override", Economy.compile_native_catalog(empty_family),
		await Economy.compile_native_catalog_cooperative(context, empty_family))
	_expect("override got separate compile", context.compile_counts.get("economy", 0) == 2)
	# Editing the same Resource identity must not retrieve its old success.
	empty_family.version = 0
	var edited: Dictionary = await Economy.compile_native_catalog_cooperative(context, empty_family)
	_expect("same resource edit invalidates", not bool(edited.get("ok", false)))
	empty_family.version = 1
	_same("restored_override", Economy.compile_native_catalog(empty_family),
		await Economy.compile_native_catalog_cooperative(context, empty_family))
	var freezing := Context.new(Gate.new())
	freezing._slice_started = 0
	var changing_family := Family.new()
	process_frame.connect(func(): changing_family.version = 0, CONNECT_ONE_SHOT)
	var frozen_result: Dictionary = await Economy.compile_native_catalog_cooperative(freezing, changing_family)
	_expect("in-flight input is frozen", bool(frozen_result.get("ok", false)) and changing_family.version == 0)
	_expect("actual loop work yielded frames", context.yielded_frames > 0)
	var stopped := Context.new(Gate.new())
	stopped.frame_gate.cancel()
	var canceled_result: Dictionary = await Economy.compile_native_catalog_cooperative(stopped)
	_expect("canceled compiler rejected", canceled_result.get("reason") == "loading_canceled")
	_expect("canceled result was not cached", stopped.compile_counts.is_empty())
	var interrupted := Context.new(Gate.new())
	Engine.set_meta(&"loading_step", "test / before canceled source compile")
	process_frame.connect(_cancel_at_resource.bind(interrupted))
	var interrupted_result: Dictionary = await Economy.compile_native_catalog_cooperative(interrupted)
	_expect("mid-compile cancellation rejected", interrupted_result.get("reason") == "loading_canceled")
	_expect("mid-compile cancellation never publishes", interrupted.compile_counts.is_empty())
	print("[loading-catalog-cooperative] checks=%d failures=%d report=%s" % [checks, failures, context.report()])
	quit(0 if failures == 0 else 1)

func _cancel_at_resource(context) -> void:
	if String(Engine.get_meta(&"loading_step", "")) == "catalog / catalog_resources":
		process_frame.disconnect(_cancel_at_resource.bind(context))
		context.frame_gate.cancel()
