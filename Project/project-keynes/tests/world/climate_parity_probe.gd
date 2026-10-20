extends SceneTree

# Climate SHADOW parity probe (plan step S2).
#
# Runs the production (OFF) Climate day next to the worker's POD kernel and
# records, per day, whether the two agree and which fields do not. The output is
# the divergence matrix that decides the order the production passes get
# extracted into shared code.
#
# Three things this harness must do that the perf/probe templates do not:
#
#   1. Ensure the worker is in SHADOW with parity forcing. Production
#      generate_world now starts the worker; this harness only reconfigures
#      speed and forcing so a second start is not required.
#   2. Assert that a comparison actually happened. "not compared" and "compared
#      and equal" are both all-zero in the report; only the first is a bug in
#      the harness.
#   3. Enable parity forcing. A divergent day is otherwise retried forever
#      against an ever-newer trace front, so exactly one day is measurable.
#
# Day alignment: the generator captures the pre-tick state of day (tick - 1) and
# publishes the post-tick state as that same day's reference. A worker started at
# day 0 therefore plans day 1 first, which is captured by tick 2. The bootstrap
# frame from tick 1 is consumed and rejected once, by design.
#
# Usage:
#   godot --headless --path Project/project-keynes -s tests/climate_parity_probe.gd -- days=30 seed=20260906

const DEFAULT_DAYS := 30
const DEFAULT_SEED := 20260906
const DEFAULT_MAP_WIDTH := 60
const DEFAULT_MAP_HEIGHT := 40
# The worker advances on its own wall clock, so a "single step" here is really
# "unpause, poll until the consumed counter moves, pause again". At 400 days/s a
# day takes 2.5ms while the poll granularity is 2ms, which made the release
# window and one day almost exactly the same length: whether the worker got
# through one day or two inside a window came down to CPU jitter. Two runs of
# the same seed then disagreed on which days production ran a Climate round,
# which silently changes the whole divergence table. 50 days/s gives 20ms per
# day against the same 2ms poll, so the detection lag is ~10% of a day and a
# release window cannot span two.
const WORKER_SPEED_DAYS_PER_SECOND := 50.0
const MAX_BARRIER_PULSES_PER_DAY := 400
const WORKER_WAIT_TIMEOUT_MSEC := 5000
const WORKER_POLL_MSEC := 2


func _init() -> void:
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var args := _arguments()
	var days := int(args.get("days", DEFAULT_DAYS))
	var seed := int(args.get("seed", DEFAULT_SEED))
	var map_width := int(args.get("width", DEFAULT_MAP_WIDTH))
	var map_height := int(args.get("height", DEFAULT_MAP_HEIGHT))
	var label := str(args.get("label", "parity30"))
	# Artifacts belong to the repository, not to the Godot project directory, and
	# res:// cannot address a parent directory. Resolve the repository root from
	# the project path instead of hardcoding a drive.
	var repo_root := ProjectSettings.globalize_path("res://").get_base_dir() \
		.get_base_dir().get_base_dir()
	var out_dir := str(args.get("out", "%s/artifacts/runtime/s2-divergence" % repo_root))
	if days <= 0:
		push_error("[parity-probe] days must be positive")
		return 2
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[parity-probe] DCWorldExt unavailable; rebuild and restart Godot")
		return 3
	if not DirAccess.dir_exists_absolute(out_dir):
		DirAccess.make_dir_recursive_absolute(out_dir)

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = map_width
	host.map_height = map_height
	host.initial_seed = seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 0
	host.runtime_parity_forcing = true
	# SHADOW overlay comparison needs the main thread still computing Climate.
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	host.configure(null, null, clock)

	await host.generate_world(seed)
	var map: MapData = host.get_current_map()
	var generator: MapGenerator = host.get_generator()
	if map == null or generator == null:
		push_error("[parity-probe] world generation failed")
		return 4
	var ext = generator.get_data_core_world_ext()
	if ext == null or not ext.has_method("start_runtime_worker"):
		push_error("[parity-probe] runtime worker API unavailable")
		return 4
	if not ext.has_method("get_runtime_climate_parity_divergence"):
		push_error("[parity-probe] parity divergence API missing; rebuild the extension")
		return 4

	var contract: Dictionary = ext.runtime_climate_parity_contract_test()
	if not bool(contract.get("ok", false)):
		push_error("[parity-probe] parity contract self-test failed: %s" % String(
			contract.get("error", contract.get("code", "unknown"))))
		return 5

	# Production generate_world already started SHADOW. Forcing was armed on
	# the host before generate so the first compared day is measurable.
	# Reconfigure the worker clock to the probe's single-day release cadence.
	if ext.has_method("set_runtime_climate_parity_forcing"):
		ext.set_runtime_climate_parity_forcing(true)
	if ext.has_method("set_runtime_clock"):
		var clocked: Dictionary = ext.set_runtime_clock(true, WORKER_SPEED_DAYS_PER_SECOND)
		if not bool(clocked.get("ok", false)):
			push_error("[parity-probe] worker clock reconfigure failed: %s" % String(
				clocked.get("code", "unknown")))
			return 6
	else:
		push_error("[parity-probe] set_runtime_clock missing; rebuild the extension")
		return 6

	var field_table: Array = ext.get_runtime_climate_parity_fields()
	var rows: Array[Dictionary] = []
	var previous_divergence: Array = ext.get_runtime_climate_parity_divergence()
	var fatal := ""
	var last_report: Dictionary = {}
	# The Climate round can be sliced over several ticks, so a tick does not map
	# one-to-one onto a released reference. Keep ticking until the requested
	# number of days has actually been compared, and take the day from the
	# worker's own report rather than from the tick counter.
	var tick := 0
	var tick_budget := days * 4 + 16
	# Non-zero means at least one release window covered more than one worker
	# day, so this run's day alignment differs from a clean run's and the
	# divergence table must not be compared against one.
	var overshot_ticks := 0
	# Ticks where production advanced but the worker produced no comparison. Each
	# one shifts production ahead of the worker by a day, which is the other way
	# the alignment drifts between runs. Split by cause: a frame that never got
	# released is a barrier/pacing problem, while a released-but-not-compared
	# frame is a day-mismatch rejection. They need different fixes, so counting
	# them together tells us nothing.
	var uncompared_ticks := 0
	var no_frame_ticks := 0
	var rejected_frame_ticks := 0
	var reject_reasons := {}
	while rows.size() < days and tick < tick_budget:
		tick += 1
		var phase := clock.season_phase_for_day(tick)
		clock.current_day = float(tick)
		host.run_daily_tick(tick, phase)
		host.finish_daily_tick(0.0, {})
		if not bool(_drain_hard_barrier(clock, tick).get("ok", false)):
			fatal = "hard_barrier_stuck_at_tick_%d" % tick
			break
		var consumed_before := int(_report(ext).get("climate_trace_consumed", 0))
		var settled: Dictionary = _advance_worker_one_frame(ext, consumed_before)
		last_report = settled["report"]
		overshot_ticks += int(settled.get("overshot", 0))
		if not bool(settled.get("ok", false)):
			# No frame was released this tick. That is normal while a sliced
			# round is still running, so keep ticking rather than failing.
			uncompared_ticks += 1
			no_frame_ticks += 1
			continue
		if not bool(last_report.get("climate_pod_parity_compared", false)):
			# The bootstrap frame carries day 0 while the worker asks for day 1,
			# so exactly one rejected frame is expected. Anything beyond that is
			# a barrier problem and shows up as an unmet day budget below.
			uncompared_ticks += 1
			rejected_frame_ticks += 1
			var why := String(last_report.get("climate_pod_fallback_reason", ""))
			if why.is_empty():
				why = "unknown"
			reject_reasons[why] = int(reject_reasons.get(why, 0)) + 1
			continue
		var divergence: Array = ext.get_runtime_climate_parity_divergence()
		rows.append(_row(int(last_report.get("climate_parity_day", -1)),
			last_report, previous_divergence, divergence))
		previous_divergence = divergence
	if fatal.is_empty() and rows.size() < days:
		fatal = "only_%d_of_%d_days_compared_in_%d_ticks_last_reason_%s" % [
			rows.size(), days, tick,
			String(last_report.get("climate_pod_fallback_reason", "unknown"))]

	var final_divergence: Array = ext.get_runtime_climate_parity_divergence()
	var forcing: Dictionary = ext.set_runtime_climate_parity_forcing(false)
	ext.request_runtime_stop()
	OS.delay_msec(100)

	var summary := _summarize(label, seed, map_width, map_height, days, map,
		rows, field_table, final_divergence, forcing, fatal,
		overshot_ticks, uncompared_ticks, no_frame_ticks,
		rejected_frame_ticks, reject_reasons, tick)
	var json_path := "%s/parity-%dd-%s.json" % [out_dir, days, label]
	var csv_path := "%s/parity-%dd-%s.csv" % [out_dir, days, label]
	var matrix_path := "%s/divergence-matrix-%s.csv" % [out_dir, label]
	var cadence_path := "%s/stage-cadence-%s.csv" % [out_dir, label]
	_write_text(json_path, JSON.stringify(summary, "\t"))
	_write_text(csv_path, _daily_csv(rows))
	_write_text(matrix_path, _matrix_csv(final_divergence))
	_write_text(cadence_path, _stage_cadence_csv(summary.get("stage_cadence", [])))
	_print_matrix(summary, final_divergence)

	host.free()
	clock.free()
	await process_frame
	if not fatal.is_empty():
		push_error("[parity-probe] fatal: %s" % fatal)
		return 7
	return 0


# One report row per compared day. The per-field deltas come from the cumulative
# counters, so a day's own divergence is the difference against the prior read.
func _row(day: int, report: Dictionary, before: Array, after: Array) -> Dictionary:
	# 两个口径并存：out_of_band_* 是判绿依据（非分片 stage 的 band 为 0，退化成逐位
	# 相等），diverged_* 保留逐位差异，用来看容差到底吃掉了多少。只报 out-of-band 会
	# 让「分片 stage 有 1e-4 抖动」和「这个 pass 根本没跑」在报告上长得一样。
	var diverged_fields: Array[String] = []
	var diverged_cells := 0
	var bitwise_fields: Array[String] = []
	var bitwise_cells := 0
	for i in range(after.size()):
		var now: Dictionary = after[i]
		if not bool(now.get("comparable", false)):
			continue
		var was_days := 0
		var was_cells := 0
		var was_band_days := 0
		var was_band_cells := 0
		if i < before.size():
			var prior: Dictionary = before[i]
			was_days = int(prior.get("diverged_days", 0))
			was_cells = int(prior.get("diverged_cells", 0))
			was_band_days = int(prior.get("out_of_band_days", 0))
			was_band_cells = int(prior.get("out_of_band_cells", 0))
		if int(now.get("out_of_band_days", 0)) > was_band_days:
			diverged_fields.append(String(now.get("name", "")))
			diverged_cells += int(now.get("out_of_band_cells", 0)) - was_band_cells
		if int(now.get("diverged_days", 0)) > was_days:
			bitwise_fields.append(String(now.get("name", "")))
			bitwise_cells += int(now.get("diverged_cells", 0)) - was_cells
	return {
		"day": day,
		"parity_compared": bool(report.get("climate_pod_parity_compared", false)),
		"parity_matched": bool(report.get("climate_pod_parity_matched", false)),
		"worker_parity_hash": int(report.get("climate_pod_state_hash", 0)),
		"reference_hash": int(report.get("climate_pod_reference_hash", 0)),
		"first_field": String(report.get("climate_parity_field", "")),
		"first_stage": int(report.get("climate_parity_stage", 0)),
		"first_cell": int(report.get("climate_parity_cell", 0)),
		"first_reference": String(report.get("climate_parity_reference_bits", "")),
		"first_worker": String(report.get("climate_parity_worker_bits", "")),
		"reason": String(report.get("climate_pod_parity_reason", "")),
		"changed_cells": int(report.get("climate_pod_changed_cells", 0)),
		"diverged_fields": diverged_fields,
		"diverged_cells": diverged_cells,
		"bitwise_diverged_fields": bitwise_fields,
		"bitwise_diverged_cells": bitwise_cells,
		# 生产 / worker 各跑过哪些 stage（1 << RuntimeClimateStage）。差集是 stage 9..13
		# 字段分叉的唯一可信归因：没有它，"worker 缺实现"和"这一天生产本来也没跑"在矩阵
		# 上完全一样，而后者在 30 日窗口里其实占大多数。
		"production_stage_mask": int(report.get("climate_production_stage_mask", 0)),
		"worker_stage_mask": int(report.get("climate_worker_stage_mask", 0)),
		# Per-stage worker cost, straight off RuntimeThreadReport. Without it the
		# only cost signal is a single climate_pod_plan_ms, which cannot answer
		# "which stage got slower" — the question ACTIVE Climate will actually
		# be asked.
		"stage_ms": report.get("climate_stage_ms", PackedFloat64Array()),
		"stage_work": report.get("climate_stage_work", PackedInt64Array()),
		"stage_total_ms": float(report.get("climate_stage_total_ms", 0.0)),
	}


func _summarize(label: String, seed: int, width: int, height: int, days: int,
		map: MapData, rows: Array[Dictionary], field_table: Array,
		divergence: Array, forcing: Dictionary, fatal: String,
		overshot_ticks: int, uncompared_ticks: int, no_frame_ticks: int,
		rejected_frame_ticks: int, reject_reasons: Dictionary,
		ticks_spent: int) -> Dictionary:
	var matched_days := 0
	var first_mismatch_day := -1
	for row in rows:
		if bool(row.get("parity_matched", false)):
			matched_days += 1
		elif first_mismatch_day < 0:
			first_mismatch_day = int(row.get("day", -1))
	var comparable := 0
	var excluded: Array[Dictionary] = []
	for entry in field_table:
		var field: Dictionary = entry
		if String(field.get("comparability", "")) == "comparable":
			comparable += 1
		else:
			excluded.append({
				"name": String(field.get("name", "")),
				"comparability": String(field.get("comparability", "")),
				"note": String(field.get("note", "")),
			})
	var stages := {}
	for entry in divergence:
		var field: Dictionary = entry
		if not bool(field.get("comparable", false)):
			continue
		var stage := String(field.get("stage_name", "UNKNOWN"))
		var bucket: Dictionary = stages.get(stage, {
			"fields": 0,
			"diverged_fields": 0,
			"bitwise_diverged_fields": 0,
			"first_diverged_day": -1,
		})
		bucket["fields"] = int(bucket["fields"]) + 1
		if int(field.get("out_of_band_days", 0)) > 0:
			bucket["diverged_fields"] = int(bucket["diverged_fields"]) + 1
			var first := int(field.get("first_out_of_band_day", -1))
			var known := int(bucket["first_diverged_day"])
			if first >= 0 and (known < 0 or first < known):
				bucket["first_diverged_day"] = first
		if int(field.get("diverged_days", 0)) > 0:
			bucket["bitwise_diverged_fields"] = int(
				bucket.get("bitwise_diverged_fields", 0)) + 1
		stages[stage] = bucket
	return {
		"label": label,
		"seed": seed,
		"map_width": width,
		"map_height": height,
		"cell_count": int(map.cell_count()),
		"requested_days": days,
		"compared_days": rows.size(),
		"matched_days": matched_days,
		"first_mismatch_day": first_mismatch_day,
		"parity_fields_total": field_table.size(),
		"parity_fields_comparable": comparable,
		"parity_fields_excluded": excluded,
		"forced_days": int(forcing.get("forced_days", 0)),
		# Day-alignment health. Both must be small and stable for two runs'
		# divergence tables to be comparable at all — see the
		# WORKER_SPEED_DAYS_PER_SECOND comment.
		"overshot_ticks": overshot_ticks,
		"uncompared_ticks": uncompared_ticks,
		"no_frame_ticks": no_frame_ticks,
		"rejected_frame_ticks": rejected_frame_ticks,
		"reject_reasons": reject_reasons,
		"ticks_spent": ticks_spent,
		"alignment_clean": overshot_ticks == 0,
		"fatal": fatal,
		"stages": stages,
		"stage_cadence": _stage_cadence(rows),
		"fields": divergence,
		"days": rows,
	}


# 逐 stage 统计"生产跑了几天 / worker 跑了几天 / 生产跑了但 worker 没跑几天"。
#
# 最后一列才是 S3 的剩余工作量：一个 stage 在窗口内生产从未跑过时，它在分叉矩阵上
# 的字段分叉不可能由这个 stage 的缺失解释，也不可能靠提取这个 stage 修掉。
func _stage_cadence(rows: Array[Dictionary]) -> Array:
	var names := PackedStringArray([
		"PASS_A", "PASS_B", "OCEAN_WATER", "OCEAN_LAND", "WIND_AIR",
		"WIND_SURFACE", "SEA_ICE", "TRANSPIRATION", "ALBEDO",
		"VEGETATION_DYNAMICS", "CLIMATE_FEEDBACK", "WEATHER",
		"RUNTIME_HYDROLOGY", "STAGE_B_AFTER_HYDROLOGY",
	])
	var out: Array = []
	for stage in range(names.size()):
		var bit := 1 << stage
		var production_days := 0
		var worker_days := 0
		var missing_days := 0
		var total_ms := 0.0
		var peak_ms := 0.0
		var total_work := 0
		for row in rows:
			var production := (int(row.get("production_stage_mask", 0)) & bit) != 0
			var worker := (int(row.get("worker_stage_mask", 0)) & bit) != 0
			if production:
				production_days += 1
			if worker:
				worker_days += 1
			if production and not worker:
				missing_days += 1
			var stage_ms: PackedFloat64Array = row.get("stage_ms", PackedFloat64Array())
			if stage < stage_ms.size():
				total_ms += stage_ms[stage]
				peak_ms = maxf(peak_ms, stage_ms[stage])
			var stage_work: PackedInt64Array = row.get("stage_work", PackedInt64Array())
			if stage < stage_work.size():
				total_work += stage_work[stage]
		out.append({
			"stage": stage,
			"stage_name": names[stage],
			"production_days": production_days,
			"worker_days": worker_days,
			"missing_days": missing_days,
			"total_ms": total_ms,
			"peak_ms": peak_ms,
			# Averaged over the days the worker actually ran the stage, not over
			# the window: dividing by 30 when a stage runs 3 times reports a cost
			# ten times lower than the one the frame budget sees.
			"mean_ms": (total_ms / float(worker_days)) if worker_days > 0 else 0.0,
			"total_work": total_work,
		})
	return out


func _stage_cadence_csv(cadence: Array) -> String:
	var lines: Array[String] = [
		"stage,stage_name,production_days,worker_days,missing_days," +
		"total_ms,mean_ms,peak_ms,total_work",
	]
	for entry in cadence:
		var stage: Dictionary = entry
		lines.append("%d,%s,%d,%d,%d,%s,%s,%s,%d" % [
			int(stage.get("stage", -1)),
			String(stage.get("stage_name", "")),
			int(stage.get("production_days", 0)),
			int(stage.get("worker_days", 0)),
			int(stage.get("missing_days", 0)),
			String.num(float(stage.get("total_ms", 0.0)), 6),
			String.num(float(stage.get("mean_ms", 0.0)), 6),
			String.num(float(stage.get("peak_ms", 0.0)), 6),
			int(stage.get("total_work", 0)),
		])
	return "\n".join(lines) + "\n"


func _daily_csv(rows: Array[Dictionary]) -> String:
	var lines: Array[String] = [
		"day,parity_compared,parity_matched,diverged_field_count,diverged_cells," +
		"first_field,first_stage,first_cell,first_reference,first_worker,reason," +
		"production_stage_mask,worker_stage_mask",
	]
	for row in rows:
		var fields: Array = row.get("diverged_fields", [])
		lines.append("%d,%s,%s,%d,%d,%s,%d,%d,%s,%s,%s,0x%X,0x%X" % [
			int(row.get("day", -1)),
			str(bool(row.get("parity_compared", false))).to_lower(),
			str(bool(row.get("parity_matched", false))).to_lower(),
			fields.size(),
			int(row.get("diverged_cells", 0)),
			String(row.get("first_field", "")),
			int(row.get("first_stage", 0)),
			int(row.get("first_cell", 0)),
			String(row.get("first_reference", "")),
			String(row.get("first_worker", "")),
			String(row.get("reason", "")),
			int(row.get("production_stage_mask", 0)),
			int(row.get("worker_stage_mask", 0)),
		])
	return "\n".join(lines) + "\n"


func _matrix_csv(divergence: Array) -> String:
	var lines: Array[String] = [
		"stage,stage_name,field,map_data_array,comparable,tolerance_band," +
		"compared_days,out_of_band_days,out_of_band_cells,first_out_of_band_day," +
		"max_out_of_band_delta,diverged_days,diverged_cells,first_diverged_day," +
		"first_cell,max_abs_delta,first_reference,first_worker,note",
	]
	for entry in divergence:
		var field: Dictionary = entry
		lines.append("%d,%s,%s,%s,%s,%s,%d,%d,%d,%d,%s,%d,%d,%d,%d,%s,%s,%s,%s" % [
			int(field.get("stage", -1)),
			String(field.get("stage_name", "")),
			String(field.get("name", "")),
			String(field.get("map_data_array", "")),
			str(bool(field.get("comparable", false))).to_lower(),
			String.num(float(field.get("tolerance_band", 0.0)), 9),
			int(field.get("compared_days", 0)),
			int(field.get("out_of_band_days", 0)),
			int(field.get("out_of_band_cells", 0)),
			int(field.get("first_out_of_band_day", -1)),
			String.num(float(field.get("max_out_of_band_delta", 0.0)), 9),
			int(field.get("diverged_days", 0)),
			int(field.get("diverged_cells", 0)),
			int(field.get("first_diverged_day", -1)),
			int(field.get("first_cell", 0)),
			String.num(float(field.get("max_abs_delta", 0.0)), 9),
			String(field.get("first_reference", "")),
			String(field.get("first_worker", "")),
			String(field.get("note", "")),
		])
	return "\n".join(lines) + "\n"


func _print_matrix(summary: Dictionary, divergence: Array) -> void:
	print("[parity-probe] label=%s seed=%d map=%dx%d cells=%d compared_days=%d matched_days=%d forced_days=%d" % [
		String(summary.get("label", "")), int(summary.get("seed", 0)),
		int(summary.get("map_width", 0)), int(summary.get("map_height", 0)),
		int(summary.get("cell_count", 0)), int(summary.get("compared_days", 0)),
		int(summary.get("matched_days", 0)), int(summary.get("forced_days", 0))])
	print(("[parity-probe] alignment: ticks=%d overshot=%d uncompared=%d"
			+ " (no_frame=%d rejected=%d) clean=%s reasons=%s") % [
		int(summary.get("ticks_spent", 0)),
		int(summary.get("overshot_ticks", 0)),
		int(summary.get("uncompared_ticks", 0)),
		int(summary.get("no_frame_ticks", 0)),
		int(summary.get("rejected_frame_ticks", 0)),
		str(bool(summary.get("alignment_clean", false))),
		JSON.stringify(summary.get("reject_reasons", {}))])
	print("[parity-probe] stage cadence (production_days / worker_days / missing = prod ran, worker did not)")
	for entry in summary.get("stage_cadence", []):
		var stage: Dictionary = entry
		print("  %-2d %-24s production=%-3d worker=%-3d missing=%-3d mean=%.4fms peak=%.4fms work=%d" % [
			int(stage.get("stage", -1)),
			String(stage.get("stage_name", "")),
			int(stage.get("production_days", 0)),
			int(stage.get("worker_days", 0)),
			int(stage.get("missing_days", 0)),
			float(stage.get("mean_ms", 0.0)),
			float(stage.get("peak_ms", 0.0)),
			int(stage.get("total_work", 0))])
	print("[parity-probe] stage x field divergence (day of first divergence, -1 = never)")
	for entry in divergence:
		var field: Dictionary = entry
		if not bool(field.get("comparable", false)):
			print("  %-24s %-30s SKIPPED (%s)" % [
				String(field.get("stage_name", "")),
				String(field.get("name", "")),
				String(field.get("note", ""))])
			continue
		var band := float(field.get("tolerance_band", 0.0))
		var band_text := "exact" if band <= 0.0 else String.num(band, 4)
		print("  %-22s %-27s band=%-7s oob day=%-4d %d/%d cells=%d max=%s | bits %d/%d cells=%d max=%s" % [
			String(field.get("stage_name", "")),
			String(field.get("name", "")),
			band_text,
			int(field.get("first_out_of_band_day", -1)),
			int(field.get("out_of_band_days", 0)),
			int(field.get("compared_days", 0)),
			int(field.get("out_of_band_cells", 0)),
			String.num(float(field.get("max_out_of_band_delta", 0.0)), 6),
			int(field.get("diverged_days", 0)),
			int(field.get("compared_days", 0)),
			int(field.get("diverged_cells", 0)),
			String.num(float(field.get("max_abs_delta", 0.0)), 6)])


# Lets the worker take exactly the one trace frame the last tick released, then
# parks it again. Polling the consumed counter is what makes the run repeatable:
# the worker otherwise advances on wall-clock time.
func _advance_worker_one_frame(ext, consumed_before: int) -> Dictionary:
	ext.set_runtime_clock(false, WORKER_SPEED_DAYS_PER_SECOND)
	var deadline := Time.get_ticks_msec() + WORKER_WAIT_TIMEOUT_MSEC
	var report: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		report = _report(ext)
		var consumed := int(report.get("climate_trace_consumed", 0))
		if consumed > consumed_before:
			ext.set_runtime_clock(true, WORKER_SPEED_DAYS_PER_SECOND)
			# The consumed counter moves before the parity slots are published,
			# so let the same day finish before reading the report.
			OS.delay_msec(WORKER_POLL_MSEC)
			# More than one day inside a single release window means the step is
			# no longer a step, and every downstream number becomes incomparable
			# between runs. Surface it instead of averaging over it.
			return {
				"ok": true,
				"overshot": consumed - consumed_before - 1,
				"report": _report(ext),
			}
		OS.delay_msec(WORKER_POLL_MSEC)
	ext.set_runtime_clock(true, WORKER_SPEED_DAYS_PER_SECOND)
	return {"ok": false, "overshot": 0, "report": report}


func _report(ext) -> Dictionary:
	return ext.get_runtime_thread_report()


func _drain_hard_barrier(clock: WorldClock, day: int) -> Dictionary:
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < MAX_BARRIER_PULSES_PER_DAY:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	return {"ok": not _has_hard_barrier(clock), "pulses": pulses}


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[parity-probe] cannot write %s" % path)
		return
	file.store_string(text)
	file.close()


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out
