extends SceneTree
## 地图生成失败诊断测试（问题 3/3）。
##
## 覆盖三条路：
##   PK_MAPGEN_TEST=success  (默认) 40x28 固定 seed 完整生成 → map/world_data/细胞数正确，
##                          且 last_generation_error 保持为空（成功路径不回归）。
##   PK_MAPGEN_TEST=failure  配 PK_FORCE_MAPGEN_FAIL=1 → 生成返回空，但
##                          last_generation_error 必须带回 stage/reason/native_report，
##                          last_generation_error_text() 必须能渲染出可读细节。
##   PK_MAPGEN_TEST=selfcheck 跑 generation_preflight + native 冒烟（--mapgen-selfcheck 内核）。
##
## 跑法（Windows headless）：
##   Godot_v4.6.2-stable_win64_console.exe --headless --path <project> \
##       --script res://tests/world/mapgen_diagnostics_test.gd
## 失败模式：
##   $env:PK_FORCE_MAPGEN_FAIL="1"; $env:PK_MAPGEN_TEST="failure"; <同上>

const WIDTH := 40
const HEIGHT := 28
const FIXED_SEED := 20261101

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _make_cfg() -> MapConfig:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	var cfg := MapConfig.make(WIDTH, HEIGHT)
	cfg.seed = FIXED_SEED
	cfg.num_continents = 1
	cfg.sea_level = 0.45
	cfg.continent_size = 0.82
	cfg.climate_profile = profile
	return cfg


func _make_generator(profile: ClimateProfile) -> MapGenerator:
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	return generator


func _run() -> void:
	var mode := OS.get_environment("PK_MAPGEN_TEST")
	if mode.is_empty():
		mode = "success"
	print("[mapgen-test] mode=%s grid=%dx%d seed=%d PK_FORCE_MAPGEN_FAIL=%s" % [
		mode, WIDTH, HEIGHT, FIXED_SEED, OS.get_environment("PK_FORCE_MAPGEN_FAIL")])
	match mode:
		"success":
			await _run_success()
		"failure":
			await _run_failure()
		"selfcheck":
			_run_selfcheck()
		_:
			_failures.append("unknown PK_MAPGEN_TEST=%s" % mode)
	_finish(mode)


# ─── 成功路径：不回归 ─────────────────────────────────────────────────────
func _run_success() -> void:
	var cfg := _make_cfg()
	var profile := cfg.climate_profile as ClimateProfile
	var generator := _make_generator(profile)

	var preflight: Dictionary = generator.generation_preflight()
	_expect("preflight ok", bool(preflight.get("ok", false)), preflight)
	_expect("preflight extension_loaded", bool(preflight.get("extension_loaded", false)), preflight)
	_expect("preflight native_mode==2", int(preflight.get("native_mode", -1)) == 2, preflight)
	_expect("preflight no missing methods",
		(preflight.get("missing_methods", PackedStringArray()) as PackedStringArray).is_empty(), preflight)
	print("[mapgen-test][preflight] %s" % JSON.stringify(preflight, "", false))

	var t0 := Time.get_ticks_msec()
	var result: Dictionary = await generator.generate(cfg, 10.0)
	var elapsed := Time.get_ticks_msec() - t0

	_expect("generate returned non-empty", not result.is_empty(), {})
	_expect("result has map", result.get("map", null) is MapData, {})
	_expect("result has world_data", result.get("world_data", null) is WorldData, {})
	var map := result.get("map", null) as MapData
	if map != null:
		_expect("cell_count == WIDTH*HEIGHT (%d)" % (WIDTH * HEIGHT),
			map.cell_count() == WIDTH * HEIGHT, {"actual": map.cell_count()})
		_expect("seed echoed", int(result.get("seed", -1)) == FIXED_SEED, result.get("seed", null))
	# 成功时不得留下失败记录（否则 UI 会把正常生成当失败）。
	_expect("last_generation_error empty on success", generator.last_generation_error.is_empty(),
		generator.last_generation_error)
	print("[mapgen-test][success] cells=%d elapsed=%dms error_empty=%s" % [
		map.cell_count() if map != null else -1, elapsed,
		str(generator.last_generation_error.is_empty())])


# ─── 失败路径：信息必须完整 ───────────────────────────────────────────────
func _run_failure() -> void:
	if OS.get_environment("PK_FORCE_MAPGEN_FAIL") != "1":
		_failures.append("failure mode requires PK_FORCE_MAPGEN_FAIL=1")
		return
	var cfg := _make_cfg()
	var generator := _make_generator(cfg.climate_profile as ClimateProfile)
	var result: Dictionary = await generator.generate(cfg, 10.0)

	_expect("generate returned empty dict", result.is_empty(), result.keys())
	var err: Dictionary = generator.last_generation_error
	_expect("last_generation_error populated", not err.is_empty(), {})
	_expect("error.stage is native_base", String(err.get("stage", "")) == "native_base", err.get("stage", ""))
	_expect("error.reason carried through",
		String(err.get("reason", "")) == "forced_by_env_PK_FORCE_MAPGEN_FAIL", err.get("reason", ""))
	_expect("error.summary non-empty", not String(err.get("summary", "")).is_empty(), {})
	_expect("error.hint non-empty", not String(err.get("hint", "")).is_empty(), {})
	_expect("error.map_size", String(err.get("map_size", "")) == "%dx%d" % [WIDTH, HEIGHT],
		err.get("map_size", ""))
	_expect("error.seed", int(err.get("seed", -1)) == FIXED_SEED, err.get("seed", null))
	var native_report: Dictionary = err.get("native_report", {})
	_expect("native_report.rc == -7", int(native_report.get("rc", 0)) == -7, native_report)
	_expect("native_report.fallback_reason",
		String(native_report.get("fallback_reason", "")) == "forced_by_env_PK_FORCE_MAPGEN_FAIL",
		native_report)
	var pf: Dictionary = err.get("preflight", {})
	_expect("error.preflight present", pf.has("extension_loaded"), pf)
	var env: Dictionary = err.get("env", {})
	_expect("error.env.has os/arch", env.has("os") and env.has("arch"), env)
	# 纯文本渲染必须同时含 stage 与 reason，否则"复制详情"没意义。
	var text: String = generator.last_generation_error_text()
	_expect("detail text contains stage", text.contains("native_base"), text.substr(0, 200))
	_expect("detail text contains reason",
		text.contains("forced_by_env_PK_FORCE_MAPGEN_FAIL"), text.substr(0, 200))
	_expect("detail text contains native_report section",
		text.contains("native_generation_base_report"), text.substr(0, 200))
	var dir := OS.get_environment("PK_MAPGEN_TEST_OUT_DIR")
	if not dir.is_empty():
		_write_dump(dir, text)
	print("[mapgen-test][failure] stage=%s reason=%s" % [
		String(err.get("stage", "")), String(err.get("reason", ""))])
	print("[mapgen-test][failure] --- detail text begin ---")
	print(text)
	print("[mapgen-test][failure] --- detail text end ---")


func _write_dump(dir: String, text: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("mapgen_failure_detail.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[mapgen-test] cannot write %s" % path)
		return
	f.store_string(text)
	f.close()
	print("[mapgen-test] detail dumped to %s" % path)


# ─── 自检路径（--mapgen-selfcheck 的内核） ────────────────────────────────
func _run_selfcheck() -> void:
	var generator := MapGenerator.new()
	var report: Dictionary = generator.run_mapgen_selfcheck(true)
	_expect("selfcheck ok", bool(report.get("ok", false)), report)
	_expect("selfcheck preflight ok", bool(report.get("ok", false)), report)
	var smoke: Dictionary = report.get("native_smoke", {})
	_expect("native smoke ok", bool(smoke.get("ok", false)), smoke)
	_expect("native smoke cell count",
		int(smoke.get("n_cells", -1)) == int(smoke.get("expected_cells", -2)), smoke)


func _finish(mode: String) -> void:
	if _failures.is_empty():
		print("[mapgen-diagnostics] PASS mode=%s" % mode)
		quit(0)
	else:
		for failure in _failures:
			push_error("[mapgen-diagnostics] FAIL: %s" % failure)
		print("[mapgen-diagnostics] FAIL mode=%s count=%d" % [mode, _failures.size()])
		quit(1)


func _expect(label: String, condition: bool, extra) -> void:
	if not condition:
		_failures.append("%s | got=%s" % [label, JSON.stringify(_safe(extra), "", false)])


func _safe(value) -> Variant:
	# 断言失败信息里绝不能塞 n_cells 级 PackedArray：折叠成大数组占位 + 截断字符串。
	if value is Dictionary:
		var out := {}
		for key in value.keys():
			out[String(key)] = _safe(value[key])
		return out
	if value is Array:
		return "<Array len=%d>" % value.size()
	if value is PackedInt32Array or value is PackedInt64Array \
			or value is PackedFloat32Array or value is PackedFloat64Array \
			or value is PackedByteArray or value is PackedStringArray:
		return "<%s len=%d>" % [type_string(typeof(value)), value.size()]
	if value is String:
		return value if value.length() <= 400 else value.substr(0, 400) + "…"
	if value is Dictionary or value is float or value is int or value is bool or value == null:
		return value
	return str(value)
