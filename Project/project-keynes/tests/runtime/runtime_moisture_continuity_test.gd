extends SceneTree

# Headless regression guard for tick-to-tick moisture continuity:
# 1. No periodic cliff across season_refresh boundaries (day 31 / day 61).
# 2. No 2-tick alternating sign-flip flickering (|dm| > 0.02) in steady state.

const DAYS := 65
const SEED := 20260718
const MAP_W := 48
const MAP_H := 32

var _checks := 0
var _failures := 0


func _init() -> void:
	var code := await _run()
	quit(code)


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s%s" % [label, (": " + detail) if not detail.is_empty() else ""])


func _wait_commit(host: WorldRuntimeHost, target_day: int) -> bool:
	for _i in range(500):
		var st: Dictionary = host._runtime_control_state()
		host._consume_runtime_commit_if_ready(st)
		host._apply_climate_writeback_if_authoritative(st)
		if host._runtime_climate_writeback_last_day >= target_day:
			return true
		OS.delay_msec(2)
	return false


func _run() -> int:
	print("=== runtime moisture continuity ===")
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt unavailable")
		return 2

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 50.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.set_speed(50.0)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = MAP_W
	host.map_height = MAP_H
	host.initial_seed = SEED
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 0
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	await host.generate_world(SEED)

	var map: MapData = host.get_current_map()
	_expect("world generated", map != null and map.cell_count() > 0)
	if map == null:
		host.free()
		clock.free()
		await process_frame
		return 1

	var n: int = map.cell_count()
	var prev_m: PackedFloat32Array = map.moisture_arr.duplicate()
	var prev_d: PackedFloat32Array = PackedFloat32Array()
	prev_d.resize(n)

	var max_jump_after_warmup := 0.0
	var max_jump_day := -1
	var season_boundary_max_jump := 0.0
	var steady_big_flips := 0
	var steady_big_flip_cells := 0
	var cell_had_big_flip := PackedByteArray()
	cell_had_big_flip.resize(n)
	var all_committed := true

	host._forward_runtime_clock(false, 50.0)
	for day in range(1, DAYS + 1):
		clock.current_day = float(day)
		host._admit_runtime_calendar(day + 1)
		if not _wait_commit(host, day):
			all_committed = false
			break
		var cur_m: PackedFloat32Array = map.moisture_arr
		var day_max := 0.0
		for i in range(n):
			var d: float = cur_m[i] - prev_m[i]
			var ad: float = absf(d)
			if ad > day_max:
				day_max = ad
			if day >= 15 and d * prev_d[i] < -1e-7 and ad > 0.02 and absf(prev_d[i]) > 0.02:
				steady_big_flips += 1
				if cell_had_big_flip[i] == 0:
					cell_had_big_flip[i] = 1
					steady_big_flip_cells += 1
			prev_d[i] = d
			prev_m[i] = cur_m[i]
		if day >= 5 and day_max > max_jump_after_warmup:
			max_jump_after_warmup = day_max
			max_jump_day = day
		if day == 31 or day == 61:
			if day_max > season_boundary_max_jump:
				season_boundary_max_jump = day_max

	_expect("all %d days committed" % DAYS, all_committed)
	_expect("no moisture cliff on season_refresh boundaries (day 31/61)",
		season_boundary_max_jump < 0.05,
		"max_jump=%.4f" % season_boundary_max_jump)
	_expect("single-tick moisture delta bounded after warm-up",
		max_jump_after_warmup < 0.05,
		"max_jump=%.4f on day %d" % [max_jump_after_warmup, max_jump_day])
	_expect("zero large alternating moisture flips (|dm|>0.02) in steady state",
		steady_big_flips == 0,
		"flips=%d cells=%d" % [steady_big_flips, steady_big_flip_cells])

	host.free()
	clock.free()
	await process_frame
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])
	return 0 if _failures == 0 else 1
