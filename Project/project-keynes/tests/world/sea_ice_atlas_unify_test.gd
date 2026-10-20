# sea_ice_atlas_unify_test.gd
# plan: sea-ice-render-source-unify 阶段 A 验收
#
# 验证海冰渲染数据源单源化的关键不变量：
#   1. _q01_byte_ice 量化：fraction=0 → 0；微量 (1e-3) → ≥1；fraction=1.0 → 255。
#   2. _dynamic_cell_signature A 字节双语义：
#        水格 (passable_sea=true)  → A == _q01_byte_ice(sea_ice_fraction)
#        陆格 (passable_sea=false) → A == _q01_byte(vegetation_vitality)
#   3. 极寒水格 (sea_ice_fraction=1.0) → A=255 → shader smoothstep(0.22,0.72) 得 w_ice≈1
#   4. 温暖水格 (sea_ice_fraction=0.0) → A=0   → shader smoothstep(0.22,0.72) 得 w_ice=0
#   5. R/G/B 通道（temp / moisture / snow_cover）不受改动影响（保护既有不变量）
#
# Headless execution:
#     godot --headless --script tests/sea_ice_atlas_unify_test.gd --quit

extends SceneTree

const MapBaker = preload("res://scripts/rendering/map_baker.gd")

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _expect(cond: bool, name: String) -> void:
	_checks += 1
	if cond:
		print("  [PASS] %s" % name)
	else:
		print("  [FAIL] %s" % name)
		_failures += 1


func _expect_eq_int(actual: int, expected: int, name: String) -> void:
	_checks += 1
	if actual == expected:
		print("  [PASS] %s (= %d)" % [name, actual])
	else:
		print("  [FAIL] %s (expected %d got %d)" % [name, expected, actual])
		_failures += 1


func _run() -> void:
	print("=== sea_ice_atlas_unify test (plan: sea-ice-render-source-unify/A) ===")
	_test_q01_byte_ice_quantization()
	_test_signature_water_a_is_sea_ice()
	_test_signature_land_a_is_vitality()
	_test_extreme_cold_water_full_ice()
	_test_warm_water_no_ice()
	_test_rgb_channels_unaffected()
	_test_shader_smoothstep_thresholds()
	print("=== sea_ice_atlas_unify summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 1. _q01_byte_ice 量化 ─────────────────────────────────────────────
func _test_q01_byte_ice_quantization() -> void:
	_expect_eq_int(MapBaker._q01_byte_ice(0.0), 0, "ice=0.0 → byte=0")
	_expect(MapBaker._q01_byte_ice(0.001) >= 1, "ice=0.001 → byte ≥ 1（低浓度数据不丢失）")
	_expect_eq_int(MapBaker._q01_byte_ice(1.0), 255, "ice=1.0 → byte=255")
	_expect_eq_int(MapBaker._q01_byte_ice(0.5), 128, "ice=0.5 → byte=128 (ceil)")
	# 负值与超界 clamp
	_expect_eq_int(MapBaker._q01_byte_ice(-0.1), 0, "ice=-0.1 → byte=0 (clamp)")
	_expect_eq_int(MapBaker._q01_byte_ice(2.0), 255, "ice=2.0 → byte=255 (clamp)")


# ─── 2. 水格 A 字节 = q01_byte_ice(sea_ice_fraction) ──────────────────
func _test_signature_water_a_is_sea_ice() -> void:
	var cell := _make_fake_cell(true, 0.95, 0.5, 0.0, 0.0, 0.7)  # water, frac=0.7
	# 直接调静态 _dynamic_cell_signature 是 instance method，需要实例
	var baker := MapBaker.new()
	var sig: int = baker._dynamic_cell_signature(cell)
	var a_byte: int = (sig >> 24) & 0xFF
	var expected: int = MapBaker._q01_byte_ice(0.7)
	_expect_eq_int(a_byte, expected, "water cell A byte == q01_byte_ice(sea_ice_fraction=0.7)")


# ─── 3. 陆格 A 字节 = q01_byte(vegetation_vitality) ─────────────────────
func _test_signature_land_a_is_vitality() -> void:
	var cell := _make_fake_cell(false, 0.6, 0.5, 0.0, 0.85, 0.0)  # land, vit=0.85
	var baker := MapBaker.new()
	var sig: int = baker._dynamic_cell_signature(cell)
	var a_byte: int = (sig >> 24) & 0xFF
	var expected: int = MapBaker._q01_byte(0.85)
	_expect_eq_int(a_byte, expected, "land cell A byte == q01_byte(vegetation_vitality=0.85)")


# ─── 4. 极寒水格 (sea_ice_fraction=1.0) → A=255 ───────────────────────
func _test_extreme_cold_water_full_ice() -> void:
	var cell := _make_fake_cell(true, 0.05, 0.5, 0.0, 0.0, 1.0)
	var baker := MapBaker.new()
	var sig: int = baker._dynamic_cell_signature(cell)
	var a_byte: int = (sig >> 24) & 0xFF
	_expect_eq_int(a_byte, 255, "extreme cold water (frac=1.0) → A=255")


# ─── 5. 温暖水格 (sea_ice_fraction=0.0) → A=0 ──────────────────────────
func _test_warm_water_no_ice() -> void:
	var cell := _make_fake_cell(true, 0.85, 0.5, 0.0, 0.0, 0.0)
	var baker := MapBaker.new()
	var sig: int = baker._dynamic_cell_signature(cell)
	var a_byte: int = (sig >> 24) & 0xFF
	_expect_eq_int(a_byte, 0, "warm water (frac=0.0) → A=0")


# ─── 6. R/G/B 通道不受改动影响 ─────────────────────────────────────────
func _test_rgb_channels_unaffected() -> void:
	var cell_w := _make_fake_cell(true, 0.4, 0.6, 0.2, 0.0, 0.5)
	var cell_l := _make_fake_cell(false, 0.4, 0.6, 0.2, 0.7, 0.0)
	var baker := MapBaker.new()
	var sig_w: int = baker._dynamic_cell_signature(cell_w)
	var sig_l: int = baker._dynamic_cell_signature(cell_l)
	var r_w: int = sig_w & 0xFF
	var g_w: int = (sig_w >> 8) & 0xFF
	var b_w: int = (sig_w >> 16) & 0xFF
	_expect_eq_int(r_w, MapBaker._q01_byte(0.4), "water R == q01(temp=0.4)")
	_expect_eq_int(g_w, MapBaker._q01_byte(0.6), "water G == q01(moist=0.6)")
	_expect_eq_int(b_w, MapBaker._q01_byte(0.2), "water B == q01(snow=0.2)")
	# 同样温/湿/雪的水格与陆格 RGB 应完全相同（只是 A 不同）
	_expect_eq_int(sig_w & 0x00FFFFFF, sig_l & 0x00FFFFFF,
		"water/land RGB identical when temp/moist/snow match")


# ─── 7. shader smoothstep 阈值契约 ───────────────────────────────────
# water_pipeline.gdshaderinc 用 smoothstep(0.22, 0.72, frac) 计算 w_ice。
# 验证 byte/255 ↦ w_ice 的关键拐点：
#   byte=0   → 0/255=0     → w_ice=0
#   byte=56  → ~0.219      → w_ice=0（恰在下限以下）
#   byte=128 → 0.502       → w_ice≈0.60（过渡带中段）
#   byte=255 → 1.0         → w_ice=1
func _test_shader_smoothstep_thresholds() -> void:
	_expect(_smoothstep(0.22, 0.72, 0.0) == 0.0, "frac=0 → w_ice=0")
	_expect(_smoothstep(0.22, 0.72, 0.219) == 0.0, "frac=0.219 → w_ice=0 (just below 0.22)")
	_expect(_smoothstep(0.22, 0.72, 1.0) == 1.0, "frac=1.0 → w_ice=1")
	var mid_w: float = _smoothstep(0.22, 0.72, 128.0 / 255.0)
	_expect(mid_w > 0.55 and mid_w < 0.65, "frac≈0.502 stays in a smooth transition band")


# ─── helpers ──────────────────────────────────────────────────────────
func _make_fake_cell(passable_sea: bool, temp: float, moisture: float,
		snow: float, vit: float, sea_ice: float) -> HexCell:
	var cell := HexCell.new()
	cell.passable_land = not passable_sea
	cell.passable_sea = passable_sea
	cell.terrain = TerrainType.TERRAIN.OCEAN if passable_sea else TerrainType.TERRAIN.PLAIN
	cell.temperature = temp
	cell.moisture = moisture
	cell.snow_cover = snow
	cell.vegetation_vitality = vit
	cell.sea_ice_fraction = sea_ice
	return cell


# GDScript smoothstep 镜像（与 GLSL smoothstep 同义；用于本测试 shader 契约校验）。
func _smoothstep(e0: float, e1: float, x: float) -> float:
	if e1 <= e0:
		return 0.0 if x < e0 else 1.0
	var t: float = clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


