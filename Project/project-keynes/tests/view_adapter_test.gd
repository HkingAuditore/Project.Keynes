# view_adapter_test.gd
# Phase A.2 — DCViewAdapter 双实现 bit-equal 验收。
#
# 构造一个 mini DCWorld + MapData（4 cells），随机化 schema 涉及的字段，
# 同时通过 DCViewAdapter.Cell 与 DCViewAdapter.World 读取每个字段，
# 比对返回值 bit-equal（F32 用 is_equal_approx，U8/bool/int 用 ==）。
#
# 命中点：覆盖 ~33 个 getter（schema 38 条里去掉 dirty mask 等不直接对外
# 暴露的字段），让两实现的 cross-impl 一致性有自动化保障，给 Phase B/C 的
# 后续接入做防回归。
#
# Headless execution:
#     godot --headless --script tests/view_adapter_test.gd --quit
#
# Exit codes:
#     0  = all checks passed
#     1  = at least one check failed (per-failure detail printed to stderr)

extends SceneTree

var _failures: int = 0
var _checks: int = 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== DCViewAdapter cross-impl bit-equal test ===")
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xDC_AD_BEEFCAFE  # deterministic
	var n: int = 4
	var map: MapData = _build_mini_map(n, rng)
	var world: DCWorld = DCWorld.new()
	world.bind_map_data(map)
	# Cell adapter reads from HexCell strong-typed fields; World adapter reads
	# from PackedArrays via DCWorld.view_*. Both should agree because
	# bind_map_data attaches the same underlying buffers.
	var cells: Array = map.iter_cells()
	var cell_adapter: DCViewAdapter = DCViewAdapter.Cell.new(cells)
	var world_adapter: DCViewAdapter = DCViewAdapter.World.new(world)

	for i in range(n):
		# F32 fields with strong-typed HexCell mirrors
		_expect_f("temp", i, cell_adapter.get_temp(i), world_adapter.get_temp(i))
		_expect_f("moisture", i, cell_adapter.get_moisture(i), world_adapter.get_moisture(i))
		_expect_f("snow_cover", i, cell_adapter.get_snow_cover(i), world_adapter.get_snow_cover(i))
		_expect_f("sea_ice_frac", i, cell_adapter.get_sea_ice_frac(i), world_adapter.get_sea_ice_frac(i))
		_expect_f("temp_baseline", i, cell_adapter.get_temp_baseline(i), world_adapter.get_temp_baseline(i))
		_expect_f("temp_30d", i, cell_adapter.get_temp_30d(i), world_adapter.get_temp_30d(i))
		_expect_f("temp_365d", i, cell_adapter.get_temp_365d(i), world_adapter.get_temp_365d(i))
		_expect_f("temp_anomaly", i, cell_adapter.get_temp_anomaly(i), world_adapter.get_temp_anomaly(i))
		_expect_f("temp_season_offset", i, cell_adapter.get_temp_season_offset(i), world_adapter.get_temp_season_offset(i))
		_expect_f("air_mass_temp_anomaly", i, cell_adapter.get_air_mass_temp_anomaly(i), world_adapter.get_air_mass_temp_anomaly(i))
		_expect_f("weather_intensity", i, cell_adapter.get_weather_intensity(i), world_adapter.get_weather_intensity(i))
		_expect_f("weather_cloud", i, cell_adapter.get_weather_cloud(i), world_adapter.get_weather_cloud(i))
		_expect_f("weather_precip", i, cell_adapter.get_weather_precip(i), world_adapter.get_weather_precip(i))
		_expect_f("weather_vapor", i, cell_adapter.get_weather_vapor(i), world_adapter.get_weather_vapor(i))
		_expect_f("weather_convergence", i, cell_adapter.get_weather_convergence(i), world_adapter.get_weather_convergence(i))
		_expect_f("weather_instability", i, cell_adapter.get_weather_instability(i), world_adapter.get_weather_instability(i))
		_expect_f("elevation", i, cell_adapter.get_elevation(i), world_adapter.get_elevation(i))
		_expect_f("base_moisture", i, cell_adapter.get_base_moisture(i), world_adapter.get_base_moisture(i))
		_expect_f("ocean_current_x", i, cell_adapter.get_ocean_current_x(i), world_adapter.get_ocean_current_x(i))
		_expect_f("ocean_current_y", i, cell_adapter.get_ocean_current_y(i), world_adapter.get_ocean_current_y(i))
		_expect_f("wind_x", i, cell_adapter.get_wind_x(i), world_adapter.get_wind_x(i))
		_expect_f("wind_y", i, cell_adapter.get_wind_y(i), world_adapter.get_wind_y(i))
		# U8 / int / bool fields
		_expect_i("terrain", i, cell_adapter.get_terrain(i), world_adapter.get_terrain(i))
		_expect_i("landform", i, cell_adapter.get_landform(i), world_adapter.get_landform(i))
		_expect_i("vegetation", i, cell_adapter.get_vegetation(i), world_adapter.get_vegetation(i))
		_expect_i("cover", i, cell_adapter.get_cover(i), world_adapter.get_cover(i))
		_expect_i("weather_type", i, cell_adapter.get_weather_type(i), world_adapter.get_weather_type(i))
		_expect_b("is_water", i, cell_adapter.get_is_water(i), world_adapter.get_is_water(i))
		_expect_b("has_river", i, cell_adapter.get_has_river(i), world_adapter.get_has_river(i))
		_expect_b("weather_field_init", i, cell_adapter.get_weather_field_init(i), world_adapter.get_weather_field_init(i))
		_expect_b("ema_initialized", i, cell_adapter.get_ema_initialized(i), world_adapter.get_ema_initialized(i))
		# Composite Vector2 helpers
		var v_oc_cell: Vector2 = cell_adapter.get_ocean_current(i)
		var v_oc_world: Vector2 = world_adapter.get_ocean_current(i)
		_expect_f("ocean_current.x", i, v_oc_cell.x, v_oc_world.x)
		_expect_f("ocean_current.y", i, v_oc_cell.y, v_oc_world.y)
		var v_wind_cell: Vector2 = cell_adapter.get_wind_vector(i)
		var v_wind_world: Vector2 = world_adapter.get_wind_vector(i)
		_expect_f("wind_vector.x", i, v_wind_cell.x, v_wind_world.x)
		_expect_f("wind_vector.y", i, v_wind_cell.y, v_wind_world.y)

	# Check cell-only-blind fields don't crash and return 0 (Cell adapter
	# doesn't have HexCell mirrors for pos_x/y/lat_norm/temp_baseline_year)
	var pos_x_cell: float = cell_adapter.get_pos_x(0)
	var pos_y_cell: float = cell_adapter.get_pos_y(0)
	var lat_cell: float = cell_adapter.get_lat_norm(0)
	var tby_cell: float = cell_adapter.get_temp_baseline_year(0)
	_expect_f("Cell.get_pos_x = 0 (HexCell has no mirror)", 0, 0.0, pos_x_cell)
	_expect_f("Cell.get_pos_y = 0 (HexCell has no mirror)", 0, 0.0, pos_y_cell)
	_expect_f("Cell.get_lat_norm = 0 (HexCell has no mirror)", 0, 0.0, lat_cell)
	_expect_f("Cell.get_temp_baseline_year = 0 (HexCell has no mirror)", 0, 0.0, tby_cell)

	# describe() smoke
	print("  cell adapter: ", cell_adapter.describe())
	print("  world adapter: ", world_adapter.describe())

	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


# ─── Helpers ────────────────────────────────────────────────────────────

func _build_mini_map(n: int, rng: RandomNumberGenerator) -> MapData:
	# Build a tiny linear strip of n HexCells (q = 0..n-1, r = 0). Just enough
	# for bind_map_data to satisfy length-consistency checks.
	var map: MapData = MapData.new(n, 1)
	for i in range(n):
		var c: HexCell = HexCell.new(i, 0)
		# Randomize all fields the schema mirrors. Values are arbitrary but
		# deterministic via the seeded rng.
		c.temperature              = rng.randf_range(0.0, 1.0)
		c.moisture                 = rng.randf_range(0.0, 1.0)
		c.snow_cover               = rng.randf_range(0.0, 1.0)
		c.sea_ice_fraction         = rng.randf_range(0.0, 1.0)
		c.temp_baseline            = rng.randf_range(0.0, 1.0)
		c.temp_30d_mean            = rng.randf_range(0.0, 1.0)
		c.temp_365d_mean           = rng.randf_range(0.0, 1.0)
		c.temp_dev_from_annual     = rng.randf_range(-0.3, 0.3)
		c.temp_season_offset       = rng.randf_range(-0.2, 0.2)
		c.air_mass_temp_anomaly    = rng.randf_range(-0.2, 0.2)
		c.weather_intensity        = rng.randf_range(0.0, 1.0)
		c.weather_cloud            = rng.randf_range(0.0, 1.0)
		c.weather_precip           = rng.randf_range(0.0, 1.0)
		c.weather_vapor            = rng.randf_range(0.0, 1.0)
		c.weather_convergence      = rng.randf_range(-0.5, 0.5)
		c.weather_instability      = rng.randf_range(0.0, 1.0)
		c.elevation                = rng.randf_range(0.0, 1.0)
		c.base_moisture            = rng.randf_range(0.0, 1.0)
		c.ocean_current            = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		c.wind_vector              = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		c.terrain                  = TerrainType.TERRAIN.PLAIN
		c.landform                 = LandformType.LF.PLAIN
		c.vegetation               = VegetationType.VEG.NONE
		c.cover                    = CoverType.CV.NONE
		c.weather_type             = WeatherType.WT.CLEAR
		c.passable_land            = (i % 2 == 0)
		c.has_river                = (i == 1)
		c.weather_field_initialized = (i >= 2)
		c._ema_initialized         = (i == 0 or i == 3)
		map.set_cell(c)
	# bind_map_data prerequisites: indices + SoA built first.
	map._build_indices()
	map.rebuild_soa_from_cells()
	return map


# Bit-equal float compare (use approx with tight tolerance because some
# fields go through Vector2 marshalling). Also accept exact equality which
# is the dominant case (HexCell strong-typed float -> SoA float -> view).
func _expect_f(label: String, idx: int, a: float, b: float) -> void:
	_checks += 1
	if a == b:
		return
	if is_equal_approx(a, b):
		return
	push_error("[view_adapter_test] FAIL %s [idx=%d] cell=%.9g world=%.9g (Δ=%.9g)" %
		[label, idx, a, b, abs(a - b)])
	_failures += 1


func _expect_i(label: String, idx: int, a: int, b: int) -> void:
	_checks += 1
	if a == b:
		return
	push_error("[view_adapter_test] FAIL %s [idx=%d] cell=%d world=%d" %
		[label, idx, a, b])
	_failures += 1


func _expect_b(label: String, idx: int, a: bool, b: bool) -> void:
	_checks += 1
	if a == b:
		return
	push_error("[view_adapter_test] FAIL %s [idx=%d] cell=%s world=%s" %
		[label, idx, str(a), str(b)])
	_failures += 1
