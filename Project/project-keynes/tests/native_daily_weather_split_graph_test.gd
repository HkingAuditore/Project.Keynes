extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_weather_split_graph_test.gd --quit
#
# Verifies the native daily slice hot path can split the weather transaction into
# graph-visible subnodes when ClimateProfile.native_daily_split_weather_node_enabled is true.

const MAX_SLICES := 64

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	await _run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily weather split graph ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(10, 8)
	cfg.seed = 737373
	cfg.num_continents = 1
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	var world: WorldData = generated.get("world_data", null) as WorldData
	_expect("map generation returned map", map != null)
	_expect("map generation returned world_data", world != null)
	if _failures > 0:
		_finish()
		return

	var final_res: Dictionary = {}
	var visible_moisture_before: PackedFloat32Array = map.moisture_arr.duplicate()
	var ext = generator.get_data_core_world_ext()
	var moisture_sid: int = int(ext.component_id("cell_moisture")) if ext != null else -1
	var slot_moisture_before: PackedFloat32Array = ext.snapshot_f32(moisture_sid) \
		if ext != null and moisture_sid >= 0 else PackedFloat32Array()
	var slot_changed_before_commit: bool = false
	var interleaved_bulk_refresh_preserved_slot: bool = true
	var nonfinal_slices: int = 0
	var intermediate_moisture_stable: bool = true
	for i in range(MAX_SLICES):
		var ctx := SusTickContext.make(1000 + i, 1, 0.125, 1.0, &"native_weather_split")
		final_res = generator.run_native_daily_slice_from_job(ctx, map, world)
		if int(final_res.get("rc", -1)) != 0:
			break
		if bool(final_res.get("done", false)):
			break
		nonfinal_slices += 1
		var slice_moisture_stable: bool = _arrays_equal(map.moisture_arr, visible_moisture_before)
		if not slice_moisture_stable:
			print("  [DIAG] intermediate moisture changed after slice %d stage=%s substage=%s breakdown=%s" % [
				i, str(final_res.get("stage_name", "")), str(final_res.get("substage", "")),
				str(final_res.get("breakdown", {}))])
		intermediate_moisture_stable = intermediate_moisture_stable and slice_moisture_stable
		if ext != null and moisture_sid >= 0:
			var slot_now: PackedFloat32Array = ext.snapshot_f32(moisture_sid)
			slot_changed_before_commit = slot_changed_before_commit \
				or not _arrays_equal(slot_now, slot_moisture_before)
			# Mirror production interleaving while visible moisture is still frozen.
			ext.refresh_slots_from_map()
			ext.refresh_slots_from_map_keys(PackedStringArray(["cell_moisture"]))
			var slot_after_refresh: PackedFloat32Array = ext.snapshot_f32(moisture_sid)
			interleaved_bulk_refresh_preserved_slot = \
				interleaved_bulk_refresh_preserved_slot and _arrays_equal(slot_now, slot_after_refresh)

	var breakdown: Dictionary = final_res.get("breakdown", {})
	var slot_moisture_after: PackedFloat32Array = ext.snapshot_f32(moisture_sid) \
		if ext != null and moisture_sid >= 0 else PackedFloat32Array()
	_expect("native split round succeeds", int(final_res.get("rc", -1)) == 0)
	_expect("native split round completes", bool(final_res.get("done", false)))
	_expect("spread mode produced non-final slices", nonfinal_slices > 0)
	_expect("non-final slices do not expose intermediate moisture",
		intermediate_moisture_stable)
	_expect("native moisture slot evolves before visible commit", slot_changed_before_commit)
	_expect("interleaved bulk and keyed refresh preserve in-flight native moisture",
		interleaved_bulk_refresh_preserved_slot)
	_expect("final visible moisture matches native slot",
		_arrays_equal(map.moisture_arr, slot_moisture_after))
	_expect("completed round changes visible moisture",
		not _arrays_equal(map.moisture_arr, visible_moisture_before))
	_expect("monolithic weather node was skipped", bool(breakdown.get("weather_split_skipped_monolithic", false)))
	_expect("weather field subnode reported", breakdown.has("weather_field_ms"))
	_expect("weather commit subnode reported", breakdown.has("weather_commit_ms"))
	_expect("weather distribute subnode reported", breakdown.has("weather_distribute_ms"))
	_expect("weather summary subnode reported", breakdown.has("weather_summary_ms"))
	_expect("weather cyclone subnode reported", breakdown.has("weather_cyclone_ms"))
	_expect("weather aggregate reported", float(breakdown.get("weather_ms", -1.0)) >= 0.0)
	_expect("moisture publishes once at native round completion",
		bool(breakdown.get("moisture_committed", false)) and
		float(breakdown.get("moisture_commit_flush_ms", -1.0)) >= 0.0)
	_expect("front snapshot remains array", final_res.get("fronts", []) is Array)
	_finish()


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_spread_across_ticks = true
	profile.native_daily_max_slices_per_tick = 1
	profile.native_daily_split_weather_node_enabled = true
	profile.native_daily_legacy_daily_production_retired = true
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.native_season_refresh_active_owner_enabled = true
	profile.native_shadow_diff_enabled = false
	profile.weather_field_enabled = true
	profile.runtime_hydrology_enabled = true
	profile.sim_stagger_enabled = false
	profile.weather_refresh_stride = 1
	profile.dynamic_visual_atlas_upload_stride = 8
	profile.enum_atlas_upload_stride = 8
	return profile


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _arrays_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] ", label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
