# weather_convergence_metric_test.gd
#
# 计划 docs/plans/weather-precipitation-frequency-plan.md W1-1 / G1：
# `convergence` 必须是「有符号净辐合」，而不是「邻居风朝向本格的一致度」。
#
# 现行实现（weather_system.gd::_wind_convergence_for_cell →
# field_solver_physics.gd::wind_convergence_for_cell）是半波整流均值：
#   conv = mean_d max(0, cos(self→nb, wind_nb))
# 六角格 6 个等间隔方向上，这个式子的期望恒在 0.29–0.33，与风场是否有辐合无关
# （完整推导见计划 §2 F7–F9）。所以「均匀风场」在本测试里必须读 0：
# 均匀流是零辐散，任何叫 convergence 的量都应给出 0。
#
# 本测试在 W1 阶段是**明知会红**的：它就是根因复现证据。
# W2 把语义改为 inflow/outflow 之后同一组断言必须转绿，不需要放宽。
#
# Headless:
#     godot --headless --path Project/project-keynes \
#       --script res://tests/world/weather_convergence_metric_test.gd

extends SceneTree

const HEX_SIZE := 22.0
const EPS := 0.02

var _failures: int = 0
var _checks: int = 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== weather convergence metric test ===")
	_test_uniform_wind_is_zero()
	_test_convergence_center_is_positive()
	_test_divergence_center_is_zero()
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])

# ── 1. 均匀风场 = 零辐散 → convergence 必须为 0 ────────────────────────────────
# 现状读数约 0.333（GDScript 镜像没有 speed 权重；C++ 侧还会乘
# clamp(speed/1.2, 0.20, 1.25)，同场景读数更高）。
func _test_uniform_wind_is_zero() -> void:
	var directions := [
		Vector2.RIGHT,
		Vector2(0.5, 0.866),        # 与六角格方向错开 30°，验证与风向无关
		Vector2(0.0, 1.0),
	]
	var worst := 0.0
	var worst_dir := Vector2.ZERO
	for dir: Vector2 in directions:
		var map := _uniform_map(dir)
		var ws := _weather_system()
		var center := map.get_cell(1, 1)
		var value := ws._wind_convergence_for_cell(center, map)
		if value > worst:
			worst = value
			worst_dir = dir
		print("  uniform wind %s -> convergence %.4f" % [str(dir), value])
	_expect(worst < EPS,
		"uniform (zero-divergence) wind must read ~0, got max %.4f at dir %s — half-wave rectified mean with a geometric offset (see plan F7–F9)" % [worst, str(worst_dir)])

# ── 2. 辐合中心 → 明显为正 ────────────────────────────────────────────────────
func _test_convergence_center_is_positive() -> void:
	var map := _directed_map(true)
	var ws := _weather_system()
	var center := map.get_cell(1, 1)
	var value := ws._wind_convergence_for_cell(center, map)
	print("  convergent center -> convergence %.4f" % value)
	_expect(value > 0.30,
		"convergent center must read clearly positive (>0.30), got %.4f" % value)

# ── 3. 辐散中心 → 0（散度不能被算成正辐合）────────────────────────────────────
func _test_divergence_center_is_zero() -> void:
	var map := _directed_map(false)
	var ws := _weather_system()
	var center := map.get_cell(1, 1)
	var value := ws._wind_convergence_for_cell(center, map)
	print("  divergent center -> convergence %.4f" % value)
	_expect(value < EPS,
		"divergent center must not be counted as convergence (<0.02), got %.4f" % value)

# ── 构图 ────────────────────────────────────────────────────────────────────
# 3x3 平行四边形（q,r ∈ [0,2]），中心取 (1,1)：它的 6 个邻居全部落在图内。
func _uniform_map(dir: Vector2) -> MapData:
	var map := MapData.new(3, 3)
	for q in range(3):
		for r in range(3):
			map.set_cell(_cell(q, r, dir))
	map.rebuild_soa_from_cells()
	return map

# inward=true：每个邻居的风都吹向中心（辐合）；
# inward=false：每个邻居的风都背向中心（辐散）。
func _directed_map(inward: bool) -> MapData:
	var center_pos := HexUtils.cube_to_world(1, 1, HEX_SIZE)
	var map := MapData.new(3, 3)
	for q in range(3):
		for r in range(3):
			var dir := Vector2.ZERO
			if not (q == 1 and r == 1):
				var nb_pos := HexUtils.cube_to_world(q, r, HEX_SIZE)
				dir = (center_pos - nb_pos).normalized()
				if not inward:
					dir = -dir
			map.set_cell(_cell(q, r, dir))
	map.rebuild_soa_from_cells()
	return map

func _weather_system() -> WeatherSystem:
	var ws := WeatherSystem.new()
	ws.init(20261120, Rect2(Vector2(-100.0, -100.0), Vector2(240.0, 200.0)), HEX_SIZE)
	ws.configure_weather_field(true, 2, 0.08, 0.55, 0.35, 0.35, 0.25, 0.40, 16, 4, 0.08, 0.85,
		0.16, 0.22, 0.12, 0.02, 0.18, 2, 0.025, 0.24, 0.22, 0.08, 0.35, 0.28, 0.35, 0.35, 0.20, 0.30)
	ws.configure_terrain_wind(true)
	return ws

func _cell(q: int, r: int, wind: Vector2) -> HexCell:
	var c := HexCell.new()
	c.q = q
	c.r = r
	c.s = -q - r
	c.terrain = TerrainType.TERRAIN.OCEAN
	c.landform = LandformType.LF.OCEAN
	c.elevation = 0.05
	c.temperature = 0.70
	c.moisture = 0.60
	c.base_moisture = 0.60
	c.wind_vector = wind
	c.wind_speed = 1.20
	c.temperature_transport_anomaly = 0.0
	c.current_state = {}
	return c

func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("[FAIL] " + msg)
		print("[FAIL] " + msg)
