extends SceneTree

# Real-scheduler validation for native_daily_spread_across_ticks.
# Runs via the FULL SUS scheduler (sus_tick_daily) so retained jobs (ocean_currents,
# visual uploads, ...) run between native slices — unlike tmp_native_batch_bitequal_test
# which drives run_native_daily_slice_from_job in isolation.
#
#   godot --headless --script tests/tmp_native_spread_validate.gd --quit -- variant=onetick
#   godot --headless --script tests/tmp_native_spread_validate.gd --quit -- variant=spread
#
# onetick : native_daily_spread_across_ticks=false (whole round per tick) -> dumps fp + perf
# spread  : native_daily_spread_across_ticks=true  (one batch per tick)   -> loads onetick
#           dump, reports per-tick perf AND the end-state delta (expected small: retained
#           jobs run between native slices, which the user accepts as legacy-style).

const MAP_W: int = 56
const MAP_H: int = 44
const DAYS: int = 24
const SEED: int = 717171
const DUMP_PATH: String = "user://fp_spread_onetick.dat"

var _max_slices: int = 1
var _yield_override: PackedInt32Array = PackedInt32Array()
var _max_tick_jobs: Dictionary = {}

const FINGERPRINT_FLOAT_ARRAYS: Array[String] = [
	"temp_arr", "moisture_arr", "snow_cover_arr", "temp_anomaly_arr", "sea_ice_frac_arr",
	"weather_intensity_arr", "weather_cloud_arr", "weather_precip_arr",
	"ocean_thermal_anomaly_arr", "local_thermal_anomaly_arr",
	"temperature_transport_anomaly_arr",
	"wind_x_arr", "wind_y_arr", "ocean_current_x_arr", "ocean_current_y_arr",
]


func _init() -> void:
	var variant: String = "onetick"
	var max_slices: int = 1
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("variant="):
			variant = str(a).substr(8)
		elif str(a).begins_with("maxslices="):
			max_slices = int(str(a).substr(10))
		elif str(a).begins_with("yield="):
			var csv: String = str(a).substr(6)
			for tok in csv.split(",", false):
				if str(tok).strip_edges().is_valid_int():
					_yield_override.append(int(str(tok).strip_edges()))
	_max_slices = max_slices
	if not _yield_override.is_empty():
		print("  yield override = %s" % str(_yield_override))
	print("=== spread validate variant=%s maxslices=%d (%dx%d, %d days, seed=%d) ===" % [
		variant, _max_slices, MAP_W, MAP_H, DAYS, SEED])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt not found")
		quit(0)
		return

	var spread: bool = variant == "spread"
	var result: Dictionary = await _run(spread)
	var fp: Dictionary = result["fp"]

	if not spread:
		var f := FileAccess.open(DUMP_PATH, FileAccess.WRITE)
		f.store_var(fp, true)
		f.close()
		print("  onetick fingerprint dumped (%d arrays)" % fp.size())
	else:
		if not FileAccess.file_exists(DUMP_PATH):
			print("  [WARN] onetick dump missing; run variant=onetick first (perf still reported)")
		else:
			var f := FileAccess.open(DUMP_PATH, FileAccess.READ)
			var fp_one: Dictionary = f.get_var(true)
			f.close()
			_compare(fp_one, fp)
	quit(0)


func _run(spread: bool) -> Dictionary:
	var profile: ClimateProfile = _make_profile(spread)
	var cfg: MapConfig = MapConfig.make(MAP_W, MAP_H)
	cfg.seed = SEED
	cfg.num_continents = 3
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.native_daily_slice_yield_nodes_override = _yield_override
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	if map == null:
		print("  FAIL: generation null")
		return {"fp": {}}

	var per_tick: Array[float] = []
	var ticks_per_round: Array[int] = []
	var max_wall: float = -1.0
	var max_wall_slice_ms: float = 0.0
	var max_wall_bd: Dictionary = {}
	# Capture the breakdown on a steady-state round-COMPLETE tick (where the finalizer runs)
	# so we can split apply_ms into finalizer sub-timers vs the rest.
	var done_bd: Dictionary = {}
	var done_seen: int = 0
	# Per-stage slice attribution: stage_name -> [count, sum_slice_ms, max_slice_ms,
	#                                             sum_apply_ms, sum_bundle_ms].
	var stage_stats: Dictionary = {}
	var job_totals: Dictionary = {}   # jid -> [sum_ms, ran_count]
	var sum_overhead_ms: float = 0.0  # Σ max(0, wall - Σ job_elapsed) = scheduler+wrapper+Time noise
	for day in range(1, DAYS + 1):
		var phase: float = float(day % 365) / 365.0
		var guard: int = 0
		var ticks_this: int = 0
		while guard < 48:
			var t0: int = Time.get_ticks_usec()
			generator.sus_tick_daily(null, day, phase)
			var wall: float = float(Time.get_ticks_usec() - t0) / 1000.0
			per_tick.append(wall)
			ticks_this += 1
			guard += 1
			# Per-job accumulation across ALL ticks (authoritative "where time goes").
			var jobs_now: Dictionary = generator.sus_report_last_tick()
			var tick_job_sum: float = 0.0
			for jid in jobs_now.keys():
				var je = jobs_now[jid]
				if je is Dictionary:
					var em: float = float(je.get("elapsed_ms", 0.0))
					tick_job_sum += em
					if not job_totals.has(jid):
						job_totals[jid] = [0.0, 0]
					var jr: Array = job_totals[jid]
					jr[0] = float(jr[0]) + em
					if em > 0.0001:
						jr[1] = int(jr[1]) + 1
			sum_overhead_ms += maxf(0.0, wall - tick_job_sum)
			var res: Dictionary = generator.native_daily_last_result()
			var bd: Dictionary = res.get("breakdown", {})
			# Per-stage attribution of native cost components for this tick.
			var st: String = str(bd.get("stage_name", "?"))
			var slice_ms: float = float(bd.get("native_ms", bd.get("slice_ms", 0.0)))
			var apply_ms: float = float(bd.get("round_apply_ms", 0.0))
			var bundle_ms: float = float(bd.get("round_bundle_ms", 0.0))
			if not stage_stats.has(st):
				stage_stats[st] = [0, 0.0, 0.0, 0.0, 0.0]
			var row: Array = stage_stats[st]
			row[0] = int(row[0]) + 1
			row[1] = float(row[1]) + slice_ms
			row[2] = maxf(float(row[2]), slice_ms)
			row[3] = float(row[3]) + apply_ms
			row[4] = float(row[4]) + bundle_ms
			# Attribute the worst tick: native-slice cost vs the rest (retained jobs).
			if wall > max_wall:
				max_wall = wall
				max_wall_slice_ms = slice_ms + apply_ms + bundle_ms
				max_wall_bd = bd.duplicate()
				_max_tick_jobs = jobs_now
			if bool(res.get("done", true)):
				# Skip the first couple of rounds (cold-start cache builds) for a steady-state sample.
				done_seen += 1
				if done_seen >= 4:
					done_bd = bd.duplicate()
				break
		ticks_per_round.append(ticks_this)
	if not done_bd.is_empty():
		print("  round-COMPLETE tick apply breakdown (steady-state, accumulated per round):")
		print("    round_apply_ms=%.3f round_bundle_ms=%.3f round_native_call_ms=%.3f slices=%d" % [
			float(done_bd.get("round_apply_ms", 0.0)), float(done_bd.get("round_bundle_ms", 0.0)),
			float(done_bd.get("round_native_call_ms", 0.0)), int(done_bd.get("round_slice_count", 0))])
		print("    finalizer_total_ms=%.3f  (of which: temp=%.3f tta=%.3f thermal=%.3f write_dense=%.3f sort=%.3f sea_ice=%.3f precip=%.3f)" % [
			float(done_bd.get("finalizer_total_ms", 0.0)), float(done_bd.get("finalizer_temp_ms", 0.0)),
			float(done_bd.get("finalizer_tta_ms", 0.0)), float(done_bd.get("finalizer_thermal_ms", 0.0)),
			float(done_bd.get("finalizer_write_dense_ms", 0.0)), float(done_bd.get("finalizer_sort_ms", 0.0)),
			float(done_bd.get("finalizer_sea_ice_ms", 0.0)), float(done_bd.get("finalizer_precip_ms", 0.0))])
		print("    finalizer_cells_seen=%d temp_cell_mirror=%s tta_cell_mirror=%s tta_mirror_count=%d apply_residual(non-finalizer)=%.3f" % [
			int(done_bd.get("finalizer_cells_seen", 0)), str(done_bd.get("finalizer_temperature_cell_mirror", "?")),
			str(done_bd.get("finalizer_tta_cell_mirror", "?")), int(done_bd.get("finalizer_tta_cell_mirror_count", 0)),
			maxf(0.0, float(done_bd.get("round_apply_ms", 0.0)) - float(done_bd.get("finalizer_total_ms", 0.0)))])
	print("  worst tick: wall=%.2fms native_slice(+apply+bundle)=%.2fms → retained/other=%.2fms" % [
		max_wall, max_wall_slice_ms, max_wall - max_wall_slice_ms])
	# Per-job attribution on the worst tick (sorted by elapsed_ms).
	var job_rows: Array = []
	for jid in _max_tick_jobs.keys():
		var entry = _max_tick_jobs[jid]
		if entry is Dictionary:
			job_rows.append([str(jid), float(entry.get("elapsed_ms", 0.0)), str(entry.get("skipped_reason", ""))])
	job_rows.sort_custom(func(a, b): return a[1] > b[1])
	for row in job_rows:
		if row[1] > 0.05 or row[2] == "":
			print("    job %-30s elapsed=%.2fms skipped=%s" % [row[0], row[1], row[2]])
	# Worst-tick native breakdown component dump (which native phase dominated).
	if not max_wall_bd.is_empty():
		print("  worst-tick native breakdown:")
		for k in ["stage_name", "slice_ms", "native_ms", "native_call_ms", "round_native_call_ms",
				"round_bundle_ms", "round_apply_ms", "finalizer_total_ms", "finalizer_write_dense_ms",
				"native_context_ms", "round_slice_count", "climate_ms", "ocean_ms", "wind_ms",
				"sea_ice_ms", "weather_ms", "hydrology_ms"]:
			if max_wall_bd.has(k):
				print("      %-26s %s" % [k, str(max_wall_bd[k])])
	# Per-stage slice attribution (which graph node is the per-tick floor).
	print("  per-stage slice attribution (stage: n, avg_slice, max_slice, avg_apply, avg_bundle):")
	var srows: Array = []
	for st in stage_stats.keys():
		var r: Array = stage_stats[st]
		var cnt: int = int(r[0])
		srows.append([str(st), cnt, float(r[1]) / float(maxi(1, cnt)), float(r[2]),
			float(r[3]) / float(maxi(1, cnt)), float(r[4]) / float(maxi(1, cnt))])
	srows.sort_custom(func(a, b): return a[3] > b[3])
	for r in srows:
		print("    %-26s n=%-3d avg=%.3f max=%.3f apply=%.3f bundle=%.3f" % [
			r[0], r[1], r[2], r[3], r[4], r[5]])

	per_tick.sort()
	var n: int = per_tick.size()
	var sum_w: float = 0.0
	for v in per_tick:
		sum_w += v
	var sum_tr: int = 0
	for t in ticks_per_round:
		sum_tr += t
	print("  per-tick wall: mean=%.2fms p95=%.2fms max=%.2fms min=%.2fms (n=%d)" % [
		sum_w / float(maxi(1, n)),
		per_tick[clampi(int(floor(0.95 * float(n))), 0, n - 1)],
		per_tick[n - 1], per_tick[0], n])
	print("  ticks/round: avg=%.2f (total ticks=%d over %d days)" % [
		float(sum_tr) / float(maxi(1, DAYS)), sum_tr, DAYS])

	# --- Distribution: percentiles + histogram ---
	print("  distribution: p50=%.2f p75=%.2f p90=%.2f p95=%.2f p99=%.2f max=%.2f" % [
		per_tick[clampi(int(floor(0.50 * float(n))), 0, n - 1)],
		per_tick[clampi(int(floor(0.75 * float(n))), 0, n - 1)],
		per_tick[clampi(int(floor(0.90 * float(n))), 0, n - 1)],
		per_tick[clampi(int(floor(0.95 * float(n))), 0, n - 1)],
		per_tick[clampi(int(floor(0.99 * float(n))), 0, n - 1)],
		per_tick[n - 1]])
	var buckets: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0])
	for v in per_tick:
		buckets[clampi(int(floor(v)), 0, 5)] += 1
	var blabels: PackedStringArray = PackedStringArray(["[0,1)", "[1,2)", "[2,3)", "[3,4)", "[4,5)", "[5+) "])
	print("  histogram (ms bucket: count / share):")
	for i in range(6):
		var c: int = buckets[i]
		var share: float = 100.0 * float(c) / float(maxi(1, n))
		print("    %s %4d  %5.1f%%  %s" % [blabels[i], c, share, "#".repeat(int(round(share / 2.0)))])

	# --- Where the time goes: per-job total across ALL ticks ---
	print("  where time goes (job: total_ms, %% of all-tick wall, ran, avg/run):")
	var jrows: Array = []
	for jid in job_totals.keys():
		var jr2: Array = job_totals[jid]
		jrows.append([str(jid), float(jr2[0]), int(jr2[1])])
	jrows.sort_custom(func(a, b): return a[1] > b[1])
	var total_wall: float = maxf(0.001, sum_w)
	for r in jrows:
		print("    %-30s %7.2fms  %5.1f%%  ran=%-4d avg=%.3f" % [
			r[0], r[1], 100.0 * float(r[1]) / total_wall, r[2], float(r[1]) / float(maxi(1, int(r[2])))])
	print("    %-30s %7.2fms  %5.1f%%  (scheduler loop + GDScript wrapper + Time noise)" % [
		"<unattributed/overhead>", sum_overhead_ms, 100.0 * sum_overhead_ms / total_wall])
	print("    %-30s %7.2fms  (sum of all sim-tick wall over %d ticks)" % ["<TOTAL>", sum_w, n])

	# Stability + fingerprint.
	var fp: Dictionary = {}
	var temp: PackedFloat32Array = map.temp_arr
	var tmin: float = INF
	var tmax: float = -INF
	var nan_count: int = 0
	for v in temp:
		if is_nan(v) or is_inf(v):
			nan_count += 1
		else:
			tmin = minf(tmin, v)
			tmax = maxf(tmax, v)
	print("  stability: temp range [%.4f, %.4f] nan/inf=%d cells=%d" % [tmin, tmax, nan_count, temp.size()])
	for key in FINGERPRINT_FLOAT_ARRAYS:
		var arr = map.get(key)
		fp[key] = (arr as PackedFloat32Array).duplicate() if arr != null else PackedFloat32Array()
	return {"fp": fp}


func _compare(fp_one: Dictionary, fp_spread: Dictionary) -> void:
	print("")
	print("=== end-state delta: spread vs onetick (after %d days) ===" % DAYS)
	var worst: float = 0.0
	for key in FINGERPRINT_FLOAT_ARRAYS:
		var a: PackedFloat32Array = fp_one.get(key, PackedFloat32Array())
		var b: PackedFloat32Array = fp_spread.get(key, PackedFloat32Array())
		var max_abs: float = 0.0
		var sum_abs: float = 0.0
		if a.size() == b.size() and a.size() > 0:
			for i in range(a.size()):
				var d: float = absf(a[i] - b[i])
				max_abs = maxf(max_abs, d)
				sum_abs += d
			worst = maxf(worst, max_abs)
			print("  %-34s max_abs=%.6f mean_abs=%.6f" % [key, max_abs, sum_abs / float(a.size())])
		else:
			print("  %-34s SIZE MISMATCH a=%d b=%d" % [key, a.size(), b.size()])
			worst = INF
	print("")
	if worst == 0.0:
		print("  RESULT: BIT-EQUAL (no retained-job interference)")
	elif worst < 0.05:
		print("  RESULT: CLOSE (worst max_abs=%.6f < 0.05; legacy-style inter-job timing, acceptable)" % worst)
	else:
		print("  RESULT: DIVERGENT (worst max_abs=%.6f >= 0.05; review)" % worst)
	print("=== done ===")


func _make_profile(spread: bool) -> ClimateProfile:
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
	profile.native_daily_spread_across_ticks = spread
	profile.native_daily_max_slices_per_tick = _max_slices
	return profile
