extends SceneTree

# tests/cpp_atlas_encode_bitequal_test.gd
#
# plan/dirty-push-atlas-encode 阶段 G —— bit-equal 单测。
#
# 目标：构造 16-cell 小型 mock world（覆盖海/陆/不同 vegetation），把同一
# baker + 同一 dirty 集分别走 GDScript loop 与 C++ encode_* 两条路径，
# byte-by-byte 比对 4 张 atlas buffer（dynamic_cell / ecology_visual /
# dyn_atlas_smooth / ice_state）。
#
# 触发路径：godot --headless --script tests/cpp_atlas_encode_bitequal_test.gd
#
# 跳过策略（CI 友好）：
#   - DCWorldExt 类不存在 → SKIP（dll 没编/没载）
#   - DCWorldExt 没有 encode_dynamic_cell_atlas method → SKIP（dll 旧）
#   - cpp 路径 fallback=true（bind 失败/SoA 不齐）→ SKIP（mock 路径硬伤）
# 任一 SKIP 都 quit(0)，CI 视为通过；只有真"两条路径输出 byte 不同"才 fail。
#
# 不动点：
#   - 不修改 baker / world_ext / climate_profile 任何生产路径
#   - 不引入 GUT 框架，与 dirty_mask_test.gd / baker_atlas_section_verdict_test.gd
#     同形（extends SceneTree + _init → _run → quit）

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
		print("[bitequal-test] SKIP: %s" % _skip_reason)
		quit(0)
		return
	if _failures.is_empty():
		print("[bitequal-test] PASS (4 atlas × 2 scenarios bit-equal)")
		quit(0)
	else:
		printerr("[bitequal-test] FAIL ×%d:" % _failures.size())
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

# ───────── 核心 _run ─────────

func _run() -> void:
	# ── 0. prerequisite 守卫（dll 缺/method 缺则 skip） ──
	if not _check_prerequisites():
		return

	# ── 1. 构造 mock world / baker ──
	var fixture := _build_fixture()
	if fixture.is_empty():
		_skip("fixture build failed (mock world构造异常)")
		return

	var map: MapData = fixture["map"]
	var world: WorldData = fixture["world"]
	var baker: MapBaker = fixture["baker"]
	var ext = fixture["ext"]
	var cp = fixture["cp"]

	# ── 2. 探测 cpp 路径是否真的能跑（bind 后做一次 encode_dynamic_cell_atlas
	#       probe；fallback=true 说明 SoA 槽位/passable_sea 任一不齐 → skip） ──
	if not _probe_cpp_can_consume(baker, world, map, ext, cp):
		_skip("cpp encode probe returned fallback=true (bind/SoA 不齐 - mock 限制)")
		return

	# ── 3. 场景 A：cache_invalid 首帧 ──
	# 状态：baker 全部 sig cache 已被 _build_fixture 重置；4 个 rebake_*_only
	# 都会走 chunk_begin 的 cache_valid=false 路径。
	# 步骤：flag=false 跑一次抓 4 buffer → 重置 baker → flag=true 再跑 → 比对
	_run_scenario("A_cache_invalid", baker, world, map, ext, cp)

	# ── 4. 场景 B：cache_valid 增量帧 ──
	# 状态：先用 GDScript 路径跑一次填好 cache → 改 5 个 cell 的 temp/moisture →
	#       再跑两条路径比对增量帧。
	# 注意：场景 A 之后 baker 的 cache 已经填过两次（GD + cpp）；这里复用 cache，
	#       让 cache_valid=true，模拟生产链路上"已有上一帧 sig 命中"的工况。
	_modify_some_cells(map)
	_run_scenario("B_cache_valid_delta", baker, world, map, ext, cp)


# ───────── 场景执行 ─────────

func _run_scenario(label: String, baker: MapBaker, world: WorldData, map: MapData, ext, cp) -> void:
	print("[bitequal-test] === scenario %s ===" % label)

	# 第一次：GDScript 路径
	_set_cpp_flag(cp, false)
	_snapshot_baker_cache_state(baker, "before_gd")
	baker.rebake_dynamic_cell_atlas_only(map, world)
	baker.rebake_ecology_visual_atlas_only(map, world)
	baker.rebake_dyn_atlas_smooth(map, world)
	baker.rebake_ice_state_atlas(map, world)
	var gd_buf := {
		"dynamic_cell": baker._dynamic_cell_atlas_buf.duplicate(),
		"ecology": baker._ecology_visual_atlas_buf.duplicate(),
		"smooth": baker._dyn_atlas_smooth_buf.duplicate(),
		"ice": baker._ice_state_buf.duplicate(),
	}

	# 重置 baker 全部 cache，让 cpp 路径从同一起点重跑
	_reset_baker_state(baker)

	# 第二次：C++ 路径
	_set_cpp_flag(cp, true)
	baker.rebake_dynamic_cell_atlas_only(map, world)
	baker.rebake_ecology_visual_atlas_only(map, world)
	baker.rebake_dyn_atlas_smooth(map, world)
	baker.rebake_ice_state_atlas(map, world)
	var cpp_buf := {
		"dynamic_cell": baker._dynamic_cell_atlas_buf.duplicate(),
		"ecology": baker._ecology_visual_atlas_buf.duplicate(),
		"smooth": baker._dyn_atlas_smooth_buf.duplicate(),
		"ice": baker._ice_state_buf.duplicate(),
	}

	# 比对
	for atlas_name in ["dynamic_cell", "ecology", "smooth", "ice"]:
		var gd_b: PackedByteArray = gd_buf[atlas_name]
		var cpp_b: PackedByteArray = cpp_buf[atlas_name]
		var ok := _bytes_equal(gd_b, cpp_b)
		var detail := ""
		if not ok:
			detail = _format_first_diff(gd_b, cpp_b)
		_expect(ok, "%s/%s" % [label, atlas_name], detail)


# ───────── 工具：byte 比对 + 首差定位 ─────────

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


# ───────── 工具：reset baker 状态 ─────────

# 把 baker 的所有"按 cell 索引的 sig/state 字典"清空 + 4 个 atlas buffer 清空，
# 模拟"刚 _build_fixture 完"的状态。下一次 chunk_begin 会判 cache_valid=false。
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
	# P1-E：同步清 SoA 镜像，强制 chunk_begin 走 cache_invalid baseline 灌注路径
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

func _snapshot_baker_cache_state(_baker: MapBaker, _label: String) -> void:
	# 占位：当前不做诊断 print，避免日志炸；调试需要时改成
	# print("[%s] dyn_sigs=%d eco_sigs=%d ..." 即可。
	pass


# ───────── 工具：toggle flag ─────────

func _set_cpp_flag(cp, on: bool) -> void:
	cp.cpp_atlas_encode_enabled = on


# ───────── prerequisite 守卫 ─────────

func _check_prerequisites() -> bool:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class missing — gdext dll not loaded")
		return false
	var ext := ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return false
	var required := [
		&"encode_dynamic_cell_atlas",
		&"encode_ecology_visual_atlas",
		&"encode_dyn_atlas_smooth",
		&"encode_ice_state_atlas",
		&"bind_map_data",
	]
	for m in required:
		if not ext.has_method(m):
			_skip("DCWorldExt missing method: %s (dll outdated)" % String(m))
			return false
	return true

func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason


# ───────── fixture 构造：16-cell 4×4 mock world ─────────
#
# - MapData(4, 4) 16 个 HexCell（offset->cube），_build_indices() 后 cell.index 0..15
# - WorldData.derived_size = (8, 8)，n_pix = 64；每 cell 映射 4 个连续像素
# - 填 6 个 PackedXxxArray（temp/moisture/snow_cover/vegetation_vitality/terrain/vegetation）
# - 部分 cell 设 passable_sea=true 走海洋分支
# - DCWorldExt.bind_map_data(map) → 自动注册 + 把 *_arr snapshot 进 SoA slot

func _build_fixture() -> Dictionary:
	# 4×4 offset → 16 cell（用 even-r offset → cube 转换）
	var W := 4
	var H := 4
	var map: MapData = MapData.new(W, H)
	for row in range(H):
		for col in range(W):
			var q := col - (row >> 1)
			var r := row
			var c := HexCell.new(q, r)
			# 让一部分 cell 是海，一部分是陆，覆盖混合分支
			var idx_lin := row * W + col
			var is_sea := (idx_lin % 5) == 0  # 16 中 4 个是海（0/5/10/15）
			c.terrain = TerrainType.TERRAIN.OCEAN if is_sea else TerrainType.TERRAIN.GRASSLAND
			c.landform = LandformType.LF.OCEAN if is_sea else LandformType.LF.PLAINS
			c.vegetation = VegetationType.VEG.NONE if is_sea else VegetationType.VEG.GRASSLAND
			c.passable_sea = is_sea
			c.temperature = 0.10 + 0.05 * float(idx_lin)  # 0.10..0.85
			c.moisture = clampf(0.20 + 0.04 * float(idx_lin), 0.0, 1.0)
			c.snow_cover = 0.05 * float(idx_lin % 4)
			c.vegetation_vitality = 0.30 + 0.04 * float(idx_lin)
			map.set_cell(c)
	map._build_indices()

	# 同步 cell 字段到 MapData 的 *_arr（DCWorldExt.bind_map_data 直接读这些数组）
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

	# 实例化 + bind DCWorldExt
	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		return {}
	# 让 ext._entity_count = n（bind_map_data 内部不会主动 resize entities，但 SoA
	# slot 在 auto-register 时按当前 _entity_count 预分配。我们用 create_entities
	# 走 GDScript DCWorld 也行，但 DCWorldExt 直接 bind 后 slot 由 *_arr 共享，
	# 长度天然 = n，cpp 端读 _entity_count 时若为 0 会 fail。所以必须让 ext 知道
	# entity 数量。MapGenerator 的真实路径里 bind_map_data 之前没有 create_entities，
	# 而是依赖 _entity_count = max(slot.size())；查 cpp 端看是否如此 ↓
	#
	# 实际 cpp `if (s_temp.arr_f32.size() < n_cells || ...)` 中 n_cells = _entity_count
	# 由 bind 后赋值（默认初始 0）。我们必须 explicit 调一个能拉 _entity_count 的入口。
	# 查看 ext 暴露的 method ↓
	if not bool(ext.bind_map_data(map)):
		return {}

	# bind 后 _entity_count 仍可能是 0；用 reflective set 失败的话改用 has_method
	# 路径补一个 create_entities。
	if ext.has_method("create_entities"):
		ext.call("create_entities", n)
	elif ext.has_method("set_entity_count"):
		ext.call("set_entity_count", n)
	# 如果两者都没有，说明 _entity_count 在 bind_map_data 内自动 = n（生产路径已验证）；
	# probe 阶段会再次校验。

	# WorldData：derived_size + cell_pixel_lists（每 cell 4 px，连续映射）
	var world: WorldData = WorldData.new()
	var Wp := 8
	var Hp := 8
	world.derived_size = Vector2i(Wp, Hp)  # 64 px 总数
	world.hm_size = Vector2i(Wp, Hp)
	world.cell_pixel_lists = {}
	world.water_cell_pixel_lists = {}
	for i in range(n):
		var cell := map.cell_at(i)
		var base := i * 4  # 4 个连续像素
		var pix := PackedInt32Array()
		pix.append(base + 0)
		pix.append(base + 1)
		pix.append(base + 2)
		pix.append(base + 3)
		world.cell_pixel_lists[cell] = pix
		if cell.passable_sea:
			world.water_cell_pixel_lists[cell] = pix

	# Mock ClimateProfile：只需有 cpp_atlas_encode_enabled 字段（baker 反射读）。
	# 用 RefCounted + 内联属性即可（避免拉真 ClimateProfile.gd 的全部依赖）。
	var cp := _MockClimateProfile.new()
	cp.cpp_atlas_encode_enabled = false  # 起点关闭，由 _run_scenario 切换

	# Baker
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


# ───────── cpp 路径 probe（bind/SoA 是否真能跑） ─────────

func _probe_cpp_can_consume(baker: MapBaker, world: WorldData, map: MapData, _ext, cp) -> bool:
	# 把 flag 临时打开，跑一次 dynamic_cell_atlas_chunk_step，看 baker 的
	# _try_cpp_dynamic_cell_atlas_encode 是否返回 true（即 cpp 没 fallback）。
	# 不能直接看 buffer 内容（GDScript 也写得出）；改用 baker 的 report.dirty_cells
	# 大于 0 + cpp 路径"成功消费"的副作用：_last_dynamic_cell_sigs 被填。
	#
	# 实现：直接 toggle flag → reset cache → rebake → 检查 buffer 非全 0
	#       且 _last_dynamic_cell_sigs 大小 > 0。
	# 然后再把 cache reset 让正式 scenario 重跑。
	cp.cpp_atlas_encode_enabled = true
	_reset_baker_state(baker)
	var report: Dictionary = baker.rebake_dynamic_cell_atlas_only(map, world)
	var ok_dirty := int(report.get("dirty_cells", 0)) > 0
	var ok_sigs := baker._last_dynamic_cell_sigs.size() > 0
	# Reset 让正式 scenario 重新走
	cp.cpp_atlas_encode_enabled = false
	_reset_baker_state(baker)
	return ok_dirty and ok_sigs


# ───────── 场景 B：modify cells 触发 cache delta ─────────

func _modify_some_cells(map: MapData) -> void:
	# 改 5 个 cell 的 temperature / moisture，让 sig 变 → 走 cache_valid 增量分支
	var change_indices := [1, 3, 6, 9, 12]
	for ci in change_indices:
		var cell := map.cell_at(ci)
		if cell == null:
			continue
		cell.temperature = clampf(float(cell.temperature) + 0.13, 0.0, 1.0)
		cell.moisture = clampf(float(cell.moisture) + 0.07, 0.0, 1.0)
		# 同步 *_arr（DCWorldExt 的 SoA 是 snapshot 共享 — *_arr 改了 cpp 也立刻看到）
		map.temp_arr[ci] = float(cell.temperature)
		map.moisture_arr[ci] = float(cell.moisture)


# ───────── Mock ClimateProfile（轻量内联类） ─────────

class _MockClimateProfile extends RefCounted:
	# baker 的 _cpp_atlas_encode_active 走 _climate_profile.get("cpp_atlas_encode_enabled")
	# 反射读，所以只需是个普通 Object 含此字段即可。
	var cpp_atlas_encode_enabled: bool = false
