extends SceneTree

# Climate per-domain ACTIVE soak probe.
#
# Purpose: reproduce the hard crash (0xC0000005 on a native_parallel_executor
# pool thread) and the `pending=nan` contamination that show up on the real
# client a few dozen ticks after `runtime_climate_authority_enabled` is turned
# on. The suspected mechanism is that SeasonRefreshSystem stays on the main
# thread and keeps writing `moisture` / `snow_cover` /
# `vegetation_growth_pressure`, while `apply_runtime_climate_writeback` flushes
# the worker's copy of the same three fields into MapData.
#
# The probe drives the write-back boundary every tick (the SceneTree does not
# pump _process under `-s`) and scans the parity fields for NaN/Inf after each
# tick, so a run that survives still reports the first contaminated tick.
#
#   godot --headless --path Project/project-keynes -s tests/climate_authority_soak_probe.gd
#
# Two drive modes, because the serial one does not reproduce:
#
#   PK_SOAK_DRIVE=serial (default)
#     tick -> drain write-back -> tick. Deterministic, and 300 ticks come back
#     clean, which is itself the finding: a torn read needs the two writers to
#     interleave, and this ordering never lets them.
#
#   PK_SOAK_DRIVE=frames
#     Let WorldClock run at speed and advance real SceneTree frames, so
#     `_on_clock_day_changed` (SUS tick, season refresh) and `_process`
#     (write-back) interleave the way they do on the client. A season round is
#     sliced across frames, so this is the ordering where the write-back can
#     land mid-round.
#
#     Does not currently advance under `--headless`: WorldClock holds on
#     `native_daily_day_barrier`, which never releases without the jobs the
#     client frame stream drives, so the day counter stays at 0. The mode bails
#     out and says so rather than burning the whole frame budget. Reproducing
#     the crash still needs the real client.
#
# Env overrides: PK_SOAK_DAYS, PK_SOAK_SEED, PK_SOAK_W, PK_SOAK_H,
# PK_SOAK_AUTHORITY, PK_SOAK_DRIVE, PK_SOAK_SPEED

const WORKER_SPEED: float = 50.0
const POLL_MSEC: int = 2
const WRITEBACK_WAIT_MSEC: int = 24

# Scanned every tick. These are the fields the write-back table and the season
# round both touch, plus the temperature/weather lanes that a torn moisture read
# would poison downstream.
const SCAN_FIELDS: Array[String] = [
	"moisture_arr",
	"snow_cover_arr",
	"vegetation_growth_pressure_arr",
	"soil_moisture_arr",
	"base_moisture_arr",
	"temp_arr",
	"plant_available_water_arr",
	"water_balance_30d_arr",
	"weather_precip_arr",
	"weather_vapor_arr",
	"sea_ice_frac_arr",
]


func _env_int(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name)
	return int(raw) if raw != "" and raw.is_valid_int() else fallback


func _init() -> void:
	var days := _env_int("PK_SOAK_DAYS", 300)
	var seed := _env_int("PK_SOAK_SEED", 20260907)
	var width := _env_int("PK_SOAK_W", 50)
	var height := _env_int("PK_SOAK_H", 48)
	var authority := _env_int("PK_SOAK_AUTHORITY", 1) != 0
	var drive := OS.get_environment("PK_SOAK_DRIVE")
	if drive == "":
		drive = "serial"
	print("[soak/start] days=%d seed=%d %dx%d authority=%s drive=%s" % [
		days, seed, width, height, str(authority), drive])
	var rc := await _run(authority, seed, width, height, days, drive)
	quit(rc)


func _run(authority: bool, seed: int, width: int, height: int, days: int,
		drive: String) -> int:
	var speed := float(_env_int("PK_SOAK_SPEED", 50))
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = speed if drive == "frames" else 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = width
	host.map_height = height
	host.initial_seed = seed
	# Formal multi-country start, not the synthetic economy. The synthetic path
	# fails to bootstrap on generated terrain (timber/stone come out at 0), and
	# a world whose economy never started leaves the contested fields flat, so
	# a clean run there says nothing about the double write.
	host.generate_test_economy_data = false
	host.test_economy_population_scale = _env_int("PK_SOAK_POP", 100)
	host.runtime_climate_authority_enabled = authority
	get_root().add_child(host)
	host.configure(null, null, clock)
	var session := _configure_formal_start(host, width, height, seed,
		_env_int("PK_SOAK_FOREIGN", 3))
	if not bool(session.get("ok", false)):
		print("[soak/FAIL] formal start failed: %s" % str(session))
		return 1
	await host.generate_world(seed)

	var map: MapData = host.get_current_map()
	var generator: MapGenerator = host.get_generator()
	if map == null or generator == null:
		print("[soak/FAIL] generate_failed")
		return 1

	var ext = generator.get_data_core_world_ext()
	if authority:
		if ext == null or not ext.has_method("set_runtime_clock"):
			print("[soak/FAIL] no_clock_api")
			return 1
		ext.set_runtime_clock(false, WORKER_SPEED)

	var first_bad_tick := -1
	var first_bad_field := ""
	var last_season_log := ""

	if drive == "frames":
		# The client ordering. WorldClock drives day_changed off _process, and
		# host._process drains the write-back in the same frame stream, so a
		# sliced season round and a write-back can land in either order.
		clock.pause(false)
		var frame := 0
		var frame_budget := days * 40 + 600
		# If the clock has not moved a single day by here, it is parked on a
		# barrier and more frames will not change that.
		const STALL_FRAMES := 400
		while int(clock.current_day) < days and frame < frame_budget:
			await process_frame
			frame += 1
			var day_now := int(clock.current_day)
			if frame >= STALL_FRAMES and day_now <= 0:
				print("[soak/FAIL] clock parked at day 0 after %d frames (barrier=%s);" % [
					frame, str(clock.get("_simulation_backpressure_sources"))])
				print("[soak/FAIL] frames mode cannot drive the clock headless - reproduce on the client")
				clock.pause(true)
				host.free()
				clock.free()
				await process_frame
				return 2
			if first_bad_tick < 0:
				var bad_f := _scan(map)
				if bad_f != "":
					first_bad_tick = day_now
					first_bad_field = bad_f
					print("[soak/nan] day=%d frame=%d field=%s" % [day_now, frame, bad_f])
			last_season_log = _season_path(generator, last_season_log)
			if frame % 200 == 0:
				var diag_f: Dictionary = host.climate_authority_diagnostics()
				print("[soak/frame] frame=%d day=%d writeback_days=%d last_day=%d season_path=%s" % [
					frame, day_now,
					int(diag_f.get("writeback_days", 0)),
					int(diag_f.get("writeback_last_day", -1)),
					last_season_log])
		clock.pause(true)
		print("[soak/frames] frames=%d final_day=%d" % [frame, int(clock.current_day)])
	else:
		for tick in range(1, days + 1):
			clock.current_day = float(tick)
			# 与客户端 _on_clock_day_changed 同序：先把 worker 上一天的结果落进
			# MapData，再跑本 tick 的 capture + season refresh。这个顺序就是被测
			# 对象，改客户端那侧时这里必须跟着改，否则 soak 测的是另一条路径。
			if authority:
				var deadline := Time.get_ticks_msec() + WRITEBACK_WAIT_MSEC
				while Time.get_ticks_msec() < deadline:
					host._consume_runtime_commit_if_ready()
					OS.delay_msec(POLL_MSEC)
				_accumulate_stages(generator)
			host.run_daily_tick(tick, clock.season_phase_for_day(tick))
			host.finish_daily_tick(0.0, {})
			if OS.get_environment("PK_SOAK_TRACE_DAYS") == "1":
				var r: Dictionary = generator.get_runtime_thread_report()
				var d: Dictionary = host.climate_authority_diagnostics()
				print("[soak/t%d] wb_last=%s wb_days=%s pod_ready=%s changed=%s " \
					% [tick, str(d.get("writeback_last_day", -1)),
						str(d.get("writeback_days", -1)),
						str(r.get("climate_pod_ready", "?")),
						str(r.get("climate_pod_changed_cells", "?"))]
					+ "worker_day=%s env_day=%s reason=%s" % [
						str(r.get("committed_day", "?")),
						str(r.get("environment_day", "?")),
						str(r.get("climate_pod_fallback_reason", ""))])
			last_season_log = _season_path(generator, last_season_log)
			if first_bad_tick < 0:
				var bad := _scan(map)
				if bad != "":
					first_bad_tick = tick
					first_bad_field = bad
					print("[soak/nan] tick=%d field=%s" % [tick, bad])
			if tick % 25 == 0:
				var diag: Dictionary = host.climate_authority_diagnostics()
				# _last_season_refresh_day 决定 capture 是否告诉 worker「今天该把
				# moisture / PAW 收回来」。它只在 finish_season_refresh 里被写，且
				# 依赖 _world_clock_ref —— 任何一环没接上，收回机制就静默失效。
				print("[soak/tick] %d writeback_days=%d last_day=%d season_path=%s suppressed=%s sr_day=%s" % [
					tick,
					int(diag.get("writeback_days", 0)),
					int(diag.get("writeback_last_day", -1)),
					last_season_log,
					str(_suppressed(generator)),
					str(generator.get("_last_season_refresh_day"))])
				# Without this the run proves nothing: if the contested fields
				# are flat zero (no population, no bootstrapped economy) then
				# both writers are writing the same nothing and a clean 300
				# ticks is not evidence about the double-write at all.
				print("[soak/live] %s" % _liveness(map))
				print("[soak/fields] applied=%d skipped=%s" % [
					int(diag.get("writeback_applied_fields", 0)),
					str(diag.get("writeback_skipped_fields", []))])
				print("[soak/stages] %s" % _stage_report(generator))

	var diag_final: Dictionary = host.climate_authority_diagnostics()
	print("[soak/fields] applied=%d skipped=%s" % [
		int(diag_final.get("writeback_applied_fields", 0)),
		str(diag_final.get("writeback_skipped_fields", []))])
	print("[soak/stage-days] %s" % _stage_totals())
	print("[soak/done] ticks=%d writeback_days=%d drops=%d first_bad_tick=%d field=%s season_path=%s" % [
		days,
		int(diag_final.get("writeback_days", 0)),
		int(diag_final.get("writeback_drop_count", 0)),
		first_bad_tick,
		first_bad_field,
		last_season_log])
	host.free()
	clock.free()
	await process_frame
	return 1 if first_bad_tick >= 0 else 0


# The three fields season refresh and the write-back table both own, plus
# soil_moisture as the season-only control.
const CONTESTED: Array[String] = [
	"moisture_arr",
	"snow_cover_arr",
	"vegetation_growth_pressure_arr",
	"soil_moisture_arr",
	# PAW 与 water_balance_30d 不是争用字段，是上游。transpiration 算的是
	# growth_pressure = clamp(PAW * heat)，而 PAW 由 moisture / water_balance_30d /
	# soil_moisture 派生 —— 如果这两条在 worker 侧不动，下游的植被压力与土壤水
	# 冻结就是必然的，跟争用无关。单点 cell trace 分不出「这个格子本来就是水域」
	# 和「全场冻结」，所以在这里看全场。
	"plant_available_water_arr",
	"water_balance_30d_arr",
	# 温度是所有季节性的源头：snow_cover 由它决定，moisture 的蒸发项由它驱动。
	# 「四条场在 worker 侧全部平坦」如果根因在上游，这一条会先露出来。
	"temp_arr",
	# insolation_dev 比 temp 更靠上游：它是 pass_a 直接从 season_phase + lat_norm 算的
	# 日照偏差，温度只是它的下游。客户端实测 ACTIVE 下这一条既冻结又只有对照 44% 的
	# 幅度（-0.370..0.134 恒定 vs 对照 -0.392..0.302 每 round 推进），而 temp 的症状
	# 完全是它的投影。看极值而不是 nz/mean：它是有符号量，全场 mean 接近 0。
	"insolation_dev_arr",
]


func _suppressed(generator: MapGenerator) -> bool:
	if not generator.has_method("sus_climate_breakdown"):
		return false
	var bd: Dictionary = generator.sus_climate_breakdown()
	return bool(bd.get("climate_authority_suppressed", false))


func _liveness(map: MapData) -> String:
	var parts: PackedStringArray = []
	for name in CONTESTED:
		var raw: Variant = map.get(name)
		if typeof(raw) != TYPE_PACKED_FLOAT32_ARRAY:
			parts.append("%s=absent" % name)
			continue
		var arr: PackedFloat32Array = raw
		var nonzero := 0
		var total := 0.0
		var lo := INF
		var hi := -INF
		for i in range(arr.size()):
			if arr[i] != 0.0:
				nonzero += 1
			total += arr[i]
			lo = minf(lo, arr[i])
			hi = maxf(hi, arr[i])
		var mean := total / float(max(arr.size(), 1))
		# 温度看极值而不是 nz/mean：全场 mean 随季节几乎不变（南北半球互相抵消），
		# 季节振幅体现在两端 —— 冬季高纬那一端要压下去。nz 对温度也没有意义。
		if name == "temp_arr" or name == "insolation_dev_arr":
			parts.append("%s mean=%.3f min=%.3f max=%.3f" % [
				name.trim_suffix("_arr"), mean, lo, hi])
		else:
			parts.append("%s nz=%d/%d mean=%.5f" % [
				name.trim_suffix("_arr"), nonzero, arr.size(), mean])
	return " | ".join(parts)


# RuntimeClimateStage order, so a missing stage can be named rather than read
# out of a hex mask.
const STAGE_NAMES: Array[String] = [
	"pass_a", "pass_b", "ocean_water", "ocean_land", "wind_air", "wind_surface",
	"sea_ice", "transpiration", "albedo", "vegetation", "feedback", "weather",
	"hydrology",
]


# Days each stage was seen to run, accumulated per tick. A single sample cannot
# answer "did every stage run": the stage mask only describes the last day the
# kernel computed, and the sparse stages (albedo/feedback every 10 weather
# rounds, i.e. ~80 days) are almost never that day.
var _stage_days: Array[int] = []


func _accumulate_stages(generator: MapGenerator) -> void:
	if _stage_days.is_empty():
		_stage_days.resize(STAGE_NAMES.size())
		_stage_days.fill(0)
	if not generator.has_method("get_runtime_thread_report"):
		return
	var report: Dictionary = generator.get_runtime_thread_report()
	var work: Array = report.get("climate_stage_work", [])
	for i in range(mini(STAGE_NAMES.size(), work.size())):
		if int(work[i]) > 0:
			_stage_days[i] += 1


func _stage_totals() -> String:
	var parts: PackedStringArray = []
	for i in range(STAGE_NAMES.size()):
		var n := int(_stage_days[i]) if i < _stage_days.size() else 0
		parts.append("%s=%d" % [STAGE_NAMES[i], n])
	return " ".join(parts)


func _stage_report(generator: MapGenerator) -> String:
	if not generator.has_method("get_runtime_thread_report"):
		return "no_report"
	var report: Dictionary = generator.get_runtime_thread_report()
	if OS.get_environment("PK_SOAK_DUMP_REPORT") == "1":
		var keys: Array = []
		for k in report.keys():
			if String(k).contains("climate") or String(k).contains("mode") \
					or String(k).contains("authorit"):
				keys.append("%s=%s" % [k, str(report[k])])
		keys.sort()
		print("[soak/report] %s" % ", ".join(keys))
	var mask := int(report.get("climate_worker_stage_mask", 0))
	var ran: PackedStringArray = []
	var missing: PackedStringArray = []
	for i in range(STAGE_NAMES.size()):
		if (mask & (1 << i)) != 0:
			ran.append(STAGE_NAMES[i])
		else:
			missing.append(STAGE_NAMES[i])
	return "mask=0x%x ran=[%s] MISSING=[%s]" % [
		mask, ", ".join(ran), ", ".join(missing)]


func _configure_formal_start(host: WorldRuntimeHost, width: int, height: int,
		seed: int, foreign_count: int) -> Dictionary:
	var config := NewGameConfig.create_default()
	config.country.name = "Climate Soak"
	config.country.foreign_count = foreign_count
	config.base.map_width = width
	config.base.map_height = height
	config.base.initial_seed = seed
	var validation := config.validate()
	if not bool(validation.get("ok", false)):
		return validation
	return host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})


func _season_path(generator: MapGenerator, current: String) -> String:
	var sr: Variant = generator.get("_last_season_refresh_breakdown")
	if typeof(sr) != TYPE_DICTIONARY:
		return current
	var sr_path := String((sr as Dictionary).get("b_plus_path", ""))
	return sr_path if sr_path != "" else current


func _scan(map: MapData) -> String:
	for name in SCAN_FIELDS:
		var raw: Variant = map.get(name)
		if typeof(raw) != TYPE_PACKED_FLOAT32_ARRAY:
			continue
		var arr: PackedFloat32Array = raw
		for i in range(arr.size()):
			if not is_finite(arr[i]):
				return "%s[%d]=%f" % [name, i, arr[i]]
	return ""
