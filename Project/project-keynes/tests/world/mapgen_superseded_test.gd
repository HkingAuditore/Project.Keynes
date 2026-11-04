extends SceneTree
## 生成被取代（superseded）路径测试。
##
## 背景：`_generation_superseded()` 返回 `{}`，而 world_runtime_host 拿到空字典后
## 会走失败上报。玩家点"重试/重新生成"时如果旧的那次生成被新的一次顶掉，
## 就绝不能闪一个"世界准备失败"面板去盖住新一轮的进度条。
##
## 本测试分两段：
##   A. 真实 generate() 被取代：在 bake_progress("continents") 回调里把
##      _loading_epoch 顶掉（等价于"新的 generate() 已经开始"），断言：
##        - generate() 返回 {}
##        - last_generation_error.superseded == true
##        - reason == generation_superseded
##   B. host 层闸门：把带 superseded 标记的 generator 塞进 WorldRuntimeHost，
##      调 _report_world_generation_failure()，断言 world_generation_failed **不发**；
##      再用一个真失败做正对照，断言**会发**且摘要含阶段/原因。
##
## 跑法：
##   Godot_v4.6.2-stable_win64_console.exe --headless --path <project> \
##       --script res://tests/world/mapgen_superseded_test.gd

const WIDTH := 24
const HEIGHT := 18

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _case_superseded_generation()
	_case_host_suppresses_superseded()
	_case_host_reports_real_failure()
	if _failures.is_empty():
		print("[mapgen-superseded-test] PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error("[mapgen-superseded-test] FAIL: %s" % failure)
		print("[mapgen-superseded-test] FAIL count=%d" % _failures.size())
		quit(1)


func _make_cfg() -> MapConfig:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	var cfg := MapConfig.make(WIDTH, HEIGHT)
	cfg.seed = 424242
	cfg.num_continents = 1
	cfg.sea_level = 0.45
	cfg.continent_size = 0.82
	cfg.climate_profile = profile
	return cfg


# ─── A. 真实 generate() 被取代 ────────────────────────────────────────────
func _case_superseded_generation() -> void:
	var cfg := _make_cfg()
	var generator := MapGenerator.new()
	generator.climate_profile = cfg.climate_profile as ClimateProfile
	var bumped := [false]
	generator.bake_progress.connect(func(stage: String, _fraction: float) -> void:
		# "continents" 阶段意味着 native 生成已经成功返回，正好模拟"玩家又点了一次生成"。
		if not bumped[0] and stage == "continents":
			bumped[0] = true
			generator.set("_loading_epoch", int(generator.get("_loading_epoch")) + 1)
	)
	var result: Dictionary = await generator.generate(cfg, 10.0)
	_expect("supersede hook fired", bumped[0], {})
	_expect("generate returned empty on supersede", result.is_empty(), result.keys())
	var err: Dictionary = generator.last_generation_error
	_expect("superseded flag set", bool(err.get("superseded", false)), err.get("superseded", null))
	_expect("reason == generation_superseded",
		String(err.get("reason", "")) == "generation_superseded", err.get("reason", ""))
	_expect("stage recorded", not String(err.get("stage", "")).is_empty(), err.get("stage", ""))
	print("[mapgen-superseded-test] A ok: stage=%s reason=%s" % [
		String(err.get("stage", "")), String(err.get("reason", ""))])


# ─── B1. host 层：superseded 不弹面板 ────────────────────────────────────
func _case_host_suppresses_superseded() -> void:
	var generator := MapGenerator.new()
	generator._generation_superseded("native_base")
	var host := WorldRuntimeHost.new()
	host.set("_generator", generator)
	var fired := [0]
	host.world_generation_failed.connect(func(_reason: String) -> void: fired[0] += 1)
	host._report_world_generation_failure()
	_expect("superseded does NOT emit world_generation_failed", fired[0] == 0, fired[0])
	_expect("superseded leaves host error empty",
		(host.last_world_generation_error as Dictionary).is_empty(),
		host.last_world_generation_error)
	host.free()
	print("[mapgen-superseded-test] B1 ok: emitted=%d (expected 0)" % fired[0])


# ─── B2. 正对照：真失败必须发 ────────────────────────────────────────────
func _case_host_reports_real_failure() -> void:
	var generator := MapGenerator.new()
	generator.last_generation_error = {
		"stage": "native_base",
		"reason": "boom_for_test",
		"summary": "C++ 地图生成失败（boom_for_test）。",
		"hint": "重建原生库后重试。",
		"preflight": {},
		"env": {},
		"native_report": {},
		"superseded": false,
	}
	var host := WorldRuntimeHost.new()
	host.set("_generator", generator)
	var captured: Array = []
	host.world_generation_failed.connect(func(reason: String) -> void: captured.append(reason))
	host._report_world_generation_failure()
	_expect("real failure DOES emit world_generation_failed", captured.size() == 1, captured.size())
	if captured.size() == 1:
		var line := String(captured[0])
		_expect("emitted summary carries stage", line.contains("native_base"), line)
		_expect("emitted summary carries reason", line.contains("boom_for_test"), line)
		_expect("emitted summary carries hint", line.contains("重建原生库"), line)
	# 供 overlay 使用的详情文本必须能渲染出来。
	var detail: String = host.last_world_generation_error_text()
	_expect("host detail text non-empty", not detail.is_empty(), detail)
	_expect("host detail text has stage", detail.contains("native_base"), detail.substr(0, 120))
	host.free()
	print("[mapgen-superseded-test] B2 ok: emitted=%d" % captured.size())


func _expect(label: String, condition: bool, extra) -> void:
	if not condition:
		_failures.append("%s | got=%s" % [label, str(extra)])
