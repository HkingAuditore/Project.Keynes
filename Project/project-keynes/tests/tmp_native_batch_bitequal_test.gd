extends SceneTree

# Bit-equal A/B for the native_daily slice node-batching optimization.
# Runs in TWO separate processes to avoid shared C++/weather global-state contamination:
#   godot --headless --path <proj> --script tests/tmp_native_batch_bitequal_test.gd -- variant=baseline
#   godot --headless --path <proj> --script tests/tmp_native_batch_bitequal_test.gd -- variant=batched
#
# variant=baseline : force legacy one-node-per-call (yield set = ALL nodes) and dump a
#                    fingerprint of every major SoA array to user://fp_baseline.dat
# variant=batched  : default yield set {1,2,4,6,7}; loads the baseline dump and compares.
# They MUST be bit-equal (batching only removes redundant GDScript<->C++ round-trips).

const MAP_W: int = 56
const MAP_H: int = 44
const DAYS: int = 40
const SEED: int = 717171
const DUMP_PATH: String = "user://fp_baseline.dat"

const YIELD_ALL: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

const FINGERPRINT_FLOAT_ARRAYS: Array[String] = [
	"temp_arr", "temp_arr_prev", "moisture_arr", "snow_cover_arr",
	"temp_anomaly_arr", "sea_ice_frac_arr",
	"weather_intensity_arr", "weather_cloud_arr", "weather_precip_arr",
	"weather_classification_temp_arr", "weather_classification_moisture_arr",
	"weather_vapor_arr", "weather_convergence_arr",
	"air_mass_temp_anomaly_arr",
	"river_discharge_arr", "river_storage_arr", "groundwater_storage_arr",
	"surface_runoff_arr",
	"ocean_thermal_anomaly_arr", "local_thermal_anomaly_arr",
	"vegetation_vitality_arr", "soil_moisture_arr",
	"temperature_transport_anomaly_arr",
	"vegetation_heat_stress_arr", "vegetation_drought_stress_arr",
	"vegetation_cold_stress_arr",
	"ocean_current_x_arr", "ocean_current_y_arr",
	"wind_x_arr", "wind_y_arr", "slp_arr", "wind_speed_arr",
	"ocean_psi_arr",
]

const FINGERPRINT_BYTE_ARRAYS: Array[String] = [
	"terrain_arr", "landform_arr", "vegetation_arr",
	"weather_field_init_arr", "has_river_arr",
]


var _finalizer_native: bool = true

func _init() -> void:
	var variant: String = "baseline"
	var yield_csv: String = ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("variant="):
			variant = str(a).substr(8)
		elif str(a).begins_with("yield="):
			yield_csv = str(a).substr(6)
		elif str(a).begins_with("finalizer="):
			_finalizer_native = str(a).substr(10).strip_edges() == "native"
	print("  finalizer path = %s" % ("native(C++)" if _finalizer_native else "gdscript"))
	print("=== node-batching BIT-EQUAL A/B variant=%s (%dx%d, %d days, seed=%d) ===" % [
		variant, MAP_W, MAP_H, DAYS, SEED])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt class not found")
		quit(0)
		return

	if variant == "baseline":
		var fp: Dictionary = _run_variant(PackedInt32Array(YIELD_ALL), "baseline(one-node)")
		if fp.is_empty():
			print("  [FAIL] baseline produced no fingerprint")
		else:
			var f := FileAccess.open(DUMP_PATH, FileAccess.WRITE)
			f.store_var(fp, true)
			f.close()
			print("  baseline fingerprint dumped to %s (%d arrays)" % [DUMP_PATH, fp.size()])
	else:
		var override := PackedInt32Array()
		if not yield_csv.is_empty():
			for tok in yield_csv.split(",", false):
				override.append(int(tok))
		print("  batched yield override = %s (empty=default {1,2,4,6,7})" % str(override))
		var fp_batched: Dictionary = _run_variant(override, "batched(yield=%s)" % yield_csv)
		if not FileAccess.file_exists(DUMP_PATH):
			print("  [FAIL] baseline dump missing; run variant=baseline first")
			quit(0)
			return
		var f := FileAccess.open(DUMP_PATH, FileAccess.READ)
		var fp_baseline: Dictionary = f.get_var(true)
		f.close()
		_compare(fp_baseline, fp_batched)
	quit(0)


func _run_variant(yield_override: PackedInt32Array, label: String) -> Dictionary:
	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(MAP_W, MAP_H)
	cfg.seed = SEED
	cfg.num_continents = 3
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.native_daily_slice_yield_nodes_override = yield_override
	generator.native_daily_finalizer_native_enabled = _finalizer_native

	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	var world: WorldData = generated.get("world_data", null) as WorldData
	if map == null or world == null:
		print("  [%s] FAIL: generation returned null" % label)
		return {}

	# Drive native daily directly to completion once per day. This forces round N to
	# start on day N with the same locked season_phase in BOTH variants, so the only
	# difference is HOW MANY slice calls a round takes (baseline ~10 vs batched ~6).
	# If the batching transform is correct, the per-round outputs are identical.
	var completed: int = 0
	var total_slices: int = 0
	var sum_temp_clamped: int = 0
	var sum_tta_clamped: int = 0
	var sum_thermal_init: int = 0
	var last_path: String = "?"
	for day in range(1, DAYS + 1):
		var ctx := SusTickContext.make(day, day, float(day % 365) / 365.0, 1.0, &"ab_probe")
		var guard: int = 0
		var round_done: bool = false
		while guard < 64:
			var res: Dictionary = generator.run_native_daily_slice_from_job(ctx, map, world)
			guard += 1
			total_slices += 1
			if int(res.get("rc", -1)) != 0:
				print("  [%s] day %d rc!=0 fail_stage=%s" % [label, day, str(res.get("fail_stage", ""))])
				round_done = true
				break
			if bool(res.get("done", false)):
				var bd: Dictionary = res.get("breakdown", {})
				sum_temp_clamped += int(bd.get("temp_delta_clamped_count", 0))
				sum_tta_clamped += int(bd.get("finalizer_tta_clamped_count", 0))
				sum_thermal_init += int(bd.get("finalizer_thermal_init_count", 0))
				last_path = str(bd.get("finalizer_path", "?"))
				round_done = true
				break
		if round_done:
			completed += 1
		else:
			print("  [%s] day %d round did NOT complete within 64 slices" % [label, day])
	print("  [%s] finalizer=%s Σtemp_clamped=%d Σtta_clamped=%d Σthermal_init=%d" % [
		label, last_path, sum_temp_clamped, sum_tta_clamped, sum_thermal_init])
	print("  [%s] ran %d days, completed_rounds=%d, total_slices=%d (avg %.2f/round), soa=%d" % [
		label, DAYS, completed, total_slices, float(total_slices) / float(maxi(1, completed)), map.soa_size()])

	var fp: Dictionary = {}
	for key in FINGERPRINT_FLOAT_ARRAYS:
		var v = map.get(key)
		fp[key] = (v as PackedFloat32Array).duplicate() if v != null else PackedFloat32Array()
	for key in FINGERPRINT_BYTE_ARRAYS:
		var v = map.get(key)
		fp[key] = (v as PackedByteArray).duplicate() if v != null else PackedByteArray()
	return fp


func _compare(fp_baseline: Dictionary, fp_batched: Dictionary) -> void:
	print("")
	print("=== comparison (baseline vs batched) ===")
	var all_equal: bool = true
	var mismatches: int = 0
	for key in FINGERPRINT_FLOAT_ARRAYS:
		var a: PackedFloat32Array = fp_baseline.get(key, PackedFloat32Array())
		var b: PackedFloat32Array = fp_batched.get(key, PackedFloat32Array())
		var r: Dictionary = _cmp_float(a, b)
		if not bool(r["equal"]):
			all_equal = false
			mismatches += 1
			print("  [DIFF] %-38s sizeA=%d sizeB=%d max_abs=%.9f first_idx=%d" % [
				key, a.size(), b.size(), float(r["max_abs"]), int(r["first_idx"])])
	for key in FINGERPRINT_BYTE_ARRAYS:
		var a: PackedByteArray = fp_baseline.get(key, PackedByteArray())
		var b: PackedByteArray = fp_batched.get(key, PackedByteArray())
		if a != b:
			all_equal = false
			mismatches += 1
			print("  [DIFF] %-38s (byte) sizeA=%d sizeB=%d" % [key, a.size(), b.size()])

	print("")
	if all_equal:
		print("  RESULT: BIT-EQUAL OK (all %d float + %d byte arrays identical)" % [
			FINGERPRINT_FLOAT_ARRAYS.size(), FINGERPRINT_BYTE_ARRAYS.size()])
	else:
		print("  RESULT: MISMATCH (%d arrays differ)" % mismatches)
	print("=== done ===")


func _cmp_float(a: PackedFloat32Array, b: PackedFloat32Array) -> Dictionary:
	if a.size() != b.size():
		return {"equal": false, "max_abs": INF, "first_idx": -1}
	var max_abs: float = 0.0
	var first_idx: int = -1
	for i in range(a.size()):
		var d: float = absf(a[i] - b[i])
		if d > max_abs:
			max_abs = d
		if d != 0.0 and first_idx < 0:
			first_idx = i
	return {"equal": first_idx < 0, "max_abs": max_abs, "first_idx": first_idx}


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = false
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.weather_field_enabled = true
	profile.dynamic_visual_atlas_upload_stride = 8
	profile.enum_atlas_upload_stride = 8
	return profile
