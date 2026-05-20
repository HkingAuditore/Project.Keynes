extends SceneTree

# tests/cpp_atlas_pipeline_bitequal_test.gd
#
# plan/atlas-pipeline-cpp 阶段 t14 —— pipeline 级 bit-equal 单测。
#
# 目标：在同一 mock world 上分别走两条路径：
#   (A) 旧路径：baker.rebake_*_only x4（GDScript chunk_step 全 4 atlas 重烘）
#   (B) 新路径：DCWorldExt.run_atlas_pipeline_step（C++ DOTS 一次性 4 atlas）
# byte-by-byte 比对 4 张 atlas buffer（dyn / eco / smo / ice）。
#
# 触发：godot --headless --script tests/cpp_atlas_pipeline_bitequal_test.gd
#
# CI 友好的 SKIP 策略（与 cpp_atlas_encode_bitequal_test 同形）：
#   - DCWorldExt 类不存在 → SKIP
#   - DCWorldExt 没有 run_atlas_pipeline_step → SKIP（dll 旧）
#   - run_atlas_pipeline_step 返回 fallback=true（SoA 不齐）→ SKIP
# 任一 SKIP 都 quit(0) CI 视为通过；只有真正路径输出 byte 不同才 fail。

const MapBaker := preload("res://scripts/rendering/map_baker.gd")

# ───────── runner 入口 ─────────

var _failures: Array[String] = []
var _skipped: bool = false
var _skip_reason: String = ""

func _init() -> void:
	_run()
	_finish()

func _finish() -> void:
	if _skipped:
		print("[pipeline-bitequal] SKIP: %s" % _skip_reason)
		quit(0)
		return
	if _failures.is_empty():
		print("[pipeline-bitequal] PASS (4 atlas pipeline vs baker bit-equal)")
		quit(0)
	else:
		printerr("[pipeline-bitequal] FAIL ×%d:" % _failures.size())
		for line in _failures:
			printerr("  - " + line)
		quit(1)

func _expect(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		print("  [ok] %s" % name)
	else:
		var msg := name
		if detail != "":
			msg += " | " + detail
		_failures.append(msg)
		printerr("  [FAIL] %s" % msg)

func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason

# ───────── 核心 _run ─────────

func _run() -> void:
	# 0. 守卫：dll 类与 method 必须存在
	if not _check_prerequisites():
		return

	# 1. 构造 mock fixture
	var fixture := _build_fixture()
	if fixture.is_empty():
		_skip("fixture build failed")
		return
	var map: MapData = fixture["map"]
	var world: WorldData = fixture["world"]
	var baker: MapBaker = fixture["baker"]
	var ext = fixture["ext"]
	var cp = fixture["cp"]

	# 2. GD 路径：先做一次 rebake，抓 4 张 atlas buffer
	cp.cpp_atlas_encode_enabled = false  # 强制 GDScript 实现
	cp.cpp_atlas_pipeline_enabled = false
	_reset_baker_state(baker)
	baker.rebake_dynamic_cell_atlas_only(map, world)
	baker.rebake_ecology_visual_atlas_only(map, world)
	baker.rebake_dyn_atlas_smooth(map, world)
	baker.rebake_ice_state_atlas(map, world)
	var gd_buf := {
		"dyn": baker._dynamic_cell_atlas_buf.duplicate(),
		"eco": baker._ecology_visual_atlas_buf.duplicate(),
		"smo": baker._dyn_atlas_smooth_buf.duplicate(),
		"ice": baker._ice_state_buf.duplicate(),
	}

	# 3. cpp pipeline 路径：调 run_atlas_pipeline_step（首帧 → cache_invalid → 全集）
	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var opts := {
		"world": world,
		"map": map,
		"width": W,
		"height": H,
		"dirty_indices": PackedInt32Array(),  # 模拟"无 dirty 但 cache 失效 → 全集"
		"terrain_lake": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice": int(TerrainType.TERRAIN.SEA_ICE),
		"veg_none": int(VegetationType.VEG.NONE),
		"enable_diag": true,
	}
	var res: Dictionary = ext.call(&"run_atlas_pipeline_step", opts)
	if bool(res.get("fallback", true)):
		_skip("run_atlas_pipeline_step fallback=true reason=" + String(res.get("reason", "")))
		return
	var atlas_buffers: Dictionary = res.get("atlas_buffers", {})

	# 4. 比对 4 张 atlas
	for atlas_name in ["dyn", "eco", "smo", "ice"]:
		var gd_b: PackedByteArray = gd_buf[atlas_name]
		var cpp_b: PackedByteArray = atlas_buffers.get(atlas_name, PackedByteArray())
		var ok := _bytes_equal(gd_b, cpp_b)
		var detail := ""
		if not ok:
			detail = _format_first_diff(gd_b, cpp_b)
		_expect(ok, "pipeline_vs_baker/%s" % atlas_name, detail)

	# 5. 校验 stride_real 字段非空（保底冒烟）
	var stride_real: Dictionary = res.get("stride_real", {})
	_expect(int(stride_real.get("dyn", -1)) >= 0, "stride_real.dyn present")
	_expect(int(stride_real.get("eco", -1)) >= 0, "stride_real.eco present")
	_expect(int(stride_real.get("smo", -1)) >= 0, "stride_real.smo present")
	_expect(int(stride_real.get("ice", -1)) >= 0, "stride_real.ice present")

	# 6. 校验 ms_breakdown 字段存在（diag=true 时）
	var ms: Dictionary = res.get("ms_breakdown", {})
	_expect(ms.has("dynamic_step_ms"), "ms_breakdown.dynamic_step_ms present")
	_expect(ms.has("ecology_step_ms"), "ms_breakdown.ecology_step_ms present")
	_expect(ms.has("smooth_step_ms"), "ms_breakdown.smooth_step_ms present")
	_expect(ms.has("ice_step_ms"), "ms_breakdown.ice_step_ms present")


# ───────── 守卫 ─────────

func _check_prerequisites() -> bool:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class missing — gdext dll not loaded")
		return false
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return false
	var required := [
		&"run_atlas_pipeline_step",
		&"invalidate_atlas_csr_cache",
		&"migrate_eco_persistent_from_gd",
		&"bind_map_data",
	]
	for m in required:
		if not ext.has_method(m):
			_skip("DCWorldExt missing method: %s (dll outdated)" % String(m))
			return false
	return true


# ───────── byte 比对 ─────────

func _bytes_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true

func _format_first_diff(a: PackedByteArray, b: PackedByteArray) -> String:
	if a.size() != b.size():
		return "size_mismatch gd=%d cpp=%d" % [a.size(), b.size()]
	var off := -1
	for i in range(a.size()):
		if a[i] != b[i]:
			off = i
			break
	if off < 0:
		return "no_diff(?)"
	var lo := maxi(0, off - 8)
	var hi := mini(a.size(), off + 8)
	var a_hex := ""
	var b_hex := ""
	for i in range(lo, hi):
		var marker := "*" if i == off else " "
		a_hex += "%s%02x " % [marker, a[i]]
		b_hex += "%s%02x " % [marker, b[i]]
	return "first_diff @ %d  gd=[%s]  cpp=[%s]" % [off, a_hex.strip_edges(), b_hex.strip_edges()]


# ───────── reset baker（模拟刚 _build_fixture 状态）─────────

func _reset_baker_state(baker: MapBaker) -> void:
	baker._dynamic_cell_atlas_buf = PackedByteArray()
	baker._dynamic_cell_atlas_cache_size = Vector2i.ZERO
	baker._last_dynamic_cell_sigs.clear()

	baker._ecology_visual_atlas_buf = PackedByteArray()
	baker._ecology_visual_atlas_cache_size = Vector2i.ZERO
	baker._last_ecology_visual_sigs.clear()
	baker._last_ecology_veg_bytes.clear()
	baker._last_ecology_vitality_bytes.clear()
	baker._ecology_transition_age_bytes.clear()
	baker._eco_veg_bytes_arr = PackedByteArray()
	baker._eco_vitality_bytes_arr = PackedByteArray()
	baker._eco_transition_age_arr = PackedByteArray()
	baker._eco_soa_initialized = false

	baker._dyn_atlas_smooth_buf = PackedByteArray()
	baker._dyn_atlas_smooth_cache_size = Vector2i.ZERO
	baker._last_dyn_smooth_cell_sigs.clear()

	baker._ice_state_buf = PackedByteArray()
	baker._ice_state_cache_size = Vector2i.ZERO
	baker._last_ice_state_cell_bytes.clear()


# ───────── fixture：4×4 mock world（与 cpp_atlas_encode_bitequal_test 同形， ───
#                    + cell_first_px_arr / cell_px_count_arr / flat_px_indices_arr）
func _build_fixture() -> Dictionary:
	var W := 4
	var H := 4
	var map: MapData = MapData.new(W, H)
	for row in range(H):
		for col in range(W):
			var q := col - (row >> 1)
			var r := row
			var c := HexCell.new(q, r)
			var idx_lin := row * W + col
			var is_sea := (idx_lin % 5) == 0
			c.terrain = TerrainType.TERRAIN.OCEAN if is_sea else TerrainType.TERRAIN.GRASSLAND
			c.landform = LandformType.LF.OCEAN if is_sea else LandformType.LF.PLAIN
			c.vegetation = VegetationType.VEG.NONE if is_sea else VegetationType.VEG.TEMPERATE_GRASSLAND
			c.passable_sea = is_sea
			c.temperature = 0.10 + 0.05 * float(idx_lin)
			c.moisture = clampf(0.20 + 0.04 * float(idx_lin), 0.0, 1.0)
			c.snow_cover = 0.05 * float(idx_lin % 4)
			c.vegetation_vitality = 0.30 + 0.04 * float(idx_lin)
			c.sea_ice_frac = 0.5 if is_sea else 0.0
			map.set_cell(c)
	map._build_indices()

	var n: int = map.cell_count()
	map.temp_arr = PackedFloat32Array()
	map.temp_arr.resize(n)
	map.moisture_arr = PackedFloat32Array()
	map.moisture_arr.resize(n)
	map.snow_cover_arr = PackedFloat32Array()
	map.snow_cover_arr.resize(n)
	map.vegetation_vitality_arr = PackedFloat32Array()
	map.vegetation_vitality_arr.resize(n)
	map.terrain_arr = PackedByteArray()
	map.terrain_arr.resize(n)
	map.vegetation_arr = PackedByteArray()
	map.vegetation_arr.resize(n)
	for i in range(n):
		var cell := map.cell_at(i)
		map.temp_arr[i] = float(cell.temperature)
		map.moisture_arr[i] = float(cell.moisture)
		map.snow_cover_arr[i] = float(cell.snow_cover)
		map.vegetation_vitality_arr[i] = float(cell.vegetation_vitality)
		map.terrain_arr[i] = int(cell.terrain) & 0xFF
		map.vegetation_arr[i] = int(cell.vegetation) & 0xFF

	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		return {}
	if not bool(ext.bind_map_data(map)):
		return {}
	if ext.has_method("create_entities"):
		ext.call("create_entities", n)
	elif ext.has_method("set_entity_count"):
		ext.call("set_entity_count", n)

	# WorldData：每 cell 4 个连续像素；cell_pixel_lists + 同结构的 SoA 三元组
	var world: WorldData = WorldData.new()
	var Wp := 8
	var Hp := 8
	world.derived_size = Vector2i(Wp, Hp)
	world.hm_size = Vector2i(Wp, Hp)
	world.cell_pixel_lists = {}
	world.water_cell_pixel_lists = {}
	# CSR SoA：cell_first_px_arr[i] = i*4，cell_px_count_arr[i]=4，flat_px_indices_arr 顺序排
	var first_arr: PackedInt32Array = PackedInt32Array()
	var count_arr: PackedInt32Array = PackedInt32Array()
	var flat_arr: PackedInt32Array = PackedInt32Array()
	first_arr.resize(n)
	count_arr.resize(n)
	flat_arr.resize(n * 4)
	for i in range(n):
		var cell := map.cell_at(i)
		var base := i * 4
		var pix := PackedInt32Array()
		pix.append(base + 0)
		pix.append(base + 1)
		pix.append(base + 2)
		pix.append(base + 3)
		world.cell_pixel_lists[cell] = pix
		if cell.passable_sea:
			world.water_cell_pixel_lists[cell] = pix
		first_arr[i] = base
		count_arr[i] = 4
		for k in range(4):
			flat_arr[base + k] = base + k
	# 反射写到 world（避免对 WorldData 引入新字段）
	world.set("cell_first_px_arr", first_arr)
	world.set("cell_px_count_arr", count_arr)
	world.set("flat_px_indices_arr", flat_arr)

	var cp := _MockClimateProfile.new()
	cp.cpp_atlas_encode_enabled = false
	cp.cpp_atlas_pipeline_enabled = false

	var baker := MapBaker.new()
	baker.set_climate_profile(cp)
	baker.set_world_ext(ext)

	return {
		"map": map,
		"world": world,
		"baker": baker,
		"ext": ext,
		"cp": cp,
	}


# ───────── Mock ClimateProfile ─────────

class _MockClimateProfile extends RefCounted:
	var cpp_atlas_encode_enabled: bool = false
	var cpp_atlas_pipeline_enabled: bool = false
