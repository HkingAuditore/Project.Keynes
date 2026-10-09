@tool
extends EditorScript

# Phase 3a Step 2.0 / Step 1 验收脚本：DCWorldExt::bind_map_data 的
# (a) BIND_TABLE 与 GDScript 端 DCWorld._bind_register_and_attach[_u8]
#     1:1 对齐 — bound_count 必须 == 注册数（零静默 skip），以及
# (b) C++→GDScript 单向快照契约（T1b 必过；T1/T2 "失败"是 GDExtension
#     ABI 的物理性结果，不是 bug，详见下方 verdict 段）。
#
# 不依赖真实 MapData：用一个 inline 子类，仅暴露 BIND_TABLE 关心的字段。
# 字段名必须与 scripts/data_core/world.gd line 598-637 中实际访问的
# MapData 属性名一致（这是 Step 2.0 修两个静默 bug 的根本依据）。
#
# ─── 边界契约（已在 docs/performance-charter.md §11 固化） ───────────
# GDExtension ABI 把每个 PackedArray 跨界都包成 Variant，refcount 必然
# ≥ 2，C++ 端任何 ptrw() 都 CoW-detach 成私有副本。因此真正的契约是：
#   方向 1 (C++ → GDScript)：必须用 "write-then-set" 推送（T1b 验证）
#   方向 2 (GDScript → C++)：禁止在 pass 内回写已 flush 的字段；
#                            重新 reseat 后必须 bind_map_data() 重绑
# 这是"单向快照"模型，不是"双向 alias"。所有性能账已确认收益不受影响
# （边界开销 < 0.04% / daily-tick），见 performance-charter.md §11。

class _MockMap:
	# ─── F32 fields (mirrors BIND_TABLE F32 entries) ──────────────────
	var temp_arr:                   PackedFloat32Array = PackedFloat32Array()
	var temp_baseline_arr:          PackedFloat32Array = PackedFloat32Array()
	var temp_30d_arr:               PackedFloat32Array = PackedFloat32Array()
	var temp_365d_arr:              PackedFloat32Array = PackedFloat32Array()
	var temp_anomaly_arr:           PackedFloat32Array = PackedFloat32Array()
	var moisture_arr:               PackedFloat32Array = PackedFloat32Array()
	var snow_cover_arr:             PackedFloat32Array = PackedFloat32Array()
	var sea_ice_frac_arr:           PackedFloat32Array = PackedFloat32Array()
	var weather_intensity_arr:      PackedFloat32Array = PackedFloat32Array()
	var weather_cloud_arr:          PackedFloat32Array = PackedFloat32Array()
	var weather_precip_arr:         PackedFloat32Array = PackedFloat32Array()
	var elevation_arr:              PackedFloat32Array = PackedFloat32Array()
	var base_moisture_arr:          PackedFloat32Array = PackedFloat32Array()
	var ocean_current_x_arr:        PackedFloat32Array = PackedFloat32Array()
	var ocean_current_y_arr:        PackedFloat32Array = PackedFloat32Array()
	var wind_x_arr:                 PackedFloat32Array = PackedFloat32Array()
	var wind_y_arr:                 PackedFloat32Array = PackedFloat32Array()
	var cell_pos_x_arr:             PackedFloat32Array = PackedFloat32Array()
	var cell_pos_y_arr:             PackedFloat32Array = PackedFloat32Array()
	var cell_lat_norm_arr:          PackedFloat32Array = PackedFloat32Array()
	var temp_baseline_year_arr:     PackedFloat32Array = PackedFloat32Array()
	var weather_vapor_arr:          PackedFloat32Array = PackedFloat32Array()
	var weather_convergence_arr:    PackedFloat32Array = PackedFloat32Array()
	var weather_instability_arr:    PackedFloat32Array = PackedFloat32Array()
	var air_mass_temp_anomaly_arr:  PackedFloat32Array = PackedFloat32Array()
	var temp_season_offset_arr:     PackedFloat32Array = PackedFloat32Array()
	# ─── U8 fields (mirrors BIND_TABLE U8 entries) ────────────────
	var terrain_arr:                PackedByteArray = PackedByteArray()
	var landform_arr:               PackedByteArray = PackedByteArray()
	var vegetation_arr:             PackedByteArray = PackedByteArray()
	var cover_arr:                  PackedByteArray = PackedByteArray()
	var weather_type_arr:           PackedByteArray = PackedByteArray()
	var is_water_arr:               PackedByteArray = PackedByteArray()
	var climate_dirty_mask:         PackedByteArray = PackedByteArray()
	var weather_dirty_mask:         PackedByteArray = PackedByteArray()
	var weather_field_init_arr:     PackedByteArray = PackedByteArray()
	var has_river_arr:              PackedByteArray = PackedByteArray()
	var ema_initialized_arr:        PackedByteArray = PackedByteArray()


const _N: int = 16
const _IDX: int = 7
const _SENTINEL_FROM_CPP:    float = 12345.5
const _SENTINEL_FROM_GD:     float = -98765.25
const _SENTINEL_FLUSH:       float = 31415.5

# slot dtype 编码（与 C++ 端 SlotDType 一致）：F32=0, I32=1, U8=2
const _DT_F32: int = 0
const _DT_I32: int = 1
const _DT_U8:  int = 2

# 与 BIND_TABLE 1:1 对齐的注册清单 (Step 2.0)。
# 增删字段时同时改 _MockMap 与 C++ BIND_TABLE。
const _REGISTRATIONS: Array = [
	# F32 (21)
	[&"cell_temp",                  _DT_F32],
	[&"cell_temp_baseline",         _DT_F32],
	[&"cell_temp_30d",              _DT_F32],
	[&"cell_temp_365d",             _DT_F32],
	[&"cell_temp_anomaly",          _DT_F32],
	[&"cell_moisture",              _DT_F32],
	[&"cell_snow_cover",            _DT_F32],
	[&"cell_sea_ice_frac",          _DT_F32],
	[&"cell_weather_intensity",     _DT_F32],
	[&"cell_weather_cloud",         _DT_F32],
	[&"cell_weather_precip",        _DT_F32],
	[&"cell_elevation",             _DT_F32],
	[&"cell_base_moisture",         _DT_F32],
	[&"cell_ocean_current_x",       _DT_F32],
	[&"cell_ocean_current_y",       _DT_F32],
	[&"cell_wind_x",                _DT_F32],
	[&"cell_wind_y",                _DT_F32],
	[&"cell_pos_x",                 _DT_F32],
	[&"cell_pos_y",                 _DT_F32],
	[&"cell_lat_norm",              _DT_F32],
	[&"cell_temp_baseline_year",    _DT_F32],
	[&"cell_weather_vapor",         _DT_F32],
	[&"cell_weather_convergence",   _DT_F32],
	[&"cell_weather_instability",   _DT_F32],
	[&"cell_air_mass_temp_anomaly", _DT_F32],
	[&"cell_temp_season_offset",    _DT_F32],
	# U8 (11)
	[&"cell_terrain",               _DT_U8],
	[&"cell_landform",              _DT_U8],
	[&"cell_vegetation",            _DT_U8],
	[&"cell_cover",                 _DT_U8],
	[&"cell_weather_type",          _DT_U8],
	[&"cell_is_water",              _DT_U8],
	[&"cell_climate_dirty",         _DT_U8],
	[&"cell_weather_dirty",         _DT_U8],
	[&"cell_weather_field_init",    _DT_U8],
	[&"cell_has_river",             _DT_U8],
	[&"cell_ema_initialized",       _DT_U8],
]


func _run() -> void:
	print("=== DCWorldExt bind_map_data alias verification (Phase 3a Step 2.0 / Step 1) ===")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt NOT registered — extension didn't load.")
		return

	# ---- 准备 mock map (所有 35 字段 resize 到 _N) ----
	var mock: _MockMap = _MockMap.new()
	mock.temp_arr.resize(_N)
	for i in range(_N):
		mock.temp_arr[i] = float(i)  # 初始值 0..N-1
	# 其它 F32 字段也 resize 一下，确保 bind 时不会 size=0 推 warning
	for fname in [
		&"temp_baseline_arr", &"temp_30d_arr", &"temp_365d_arr", &"temp_anomaly_arr",
		&"moisture_arr", &"snow_cover_arr", &"sea_ice_frac_arr",
		&"weather_intensity_arr", &"weather_cloud_arr", &"weather_precip_arr",
		&"elevation_arr", &"base_moisture_arr",
		&"ocean_current_x_arr", &"ocean_current_y_arr",
		&"wind_x_arr", &"wind_y_arr",
		&"cell_pos_x_arr", &"cell_pos_y_arr", &"cell_lat_norm_arr",
		&"temp_baseline_year_arr",
		&"weather_vapor_arr", &"weather_convergence_arr", &"weather_instability_arr",
		&"air_mass_temp_anomaly_arr", &"temp_season_offset_arr",
	]:
		var arr: PackedFloat32Array = mock.get(fname)
		arr.resize(_N)
		mock.set(fname, arr)
	for fname2 in [
		&"terrain_arr", &"landform_arr", &"vegetation_arr", &"cover_arr",
		&"weather_type_arr", &"is_water_arr",
		&"climate_dirty_mask", &"weather_dirty_mask",
		&"weather_field_init_arr", &"has_river_arr", &"ema_initialized_arr",
	]:
		var arr2: PackedByteArray = mock.get(fname2)
		arr2.resize(_N)
		mock.set(fname2, arr2)

	var w: Object = ClassDB.instantiate("DCWorldExt")
	if w == null:
		push_error("DCWorldExt instantiation failed.")
		return

	# ---- BIND_TABLE 要求 register_component 先于 bind_map_data ----
	var c_temp: int = -1
	for entry in _REGISTRATIONS:
		var sn: StringName = entry[0]
		var dt: int = entry[1]
		var cid: int = w.register_component(sn, dt, 1, false)
		if sn == &"cell_temp":
			c_temp = cid

	var expected_count: int = _REGISTRATIONS.size()

	# ---- bind ----
	var ok: bool = w.bind_map_data(mock)
	if not ok:
		push_error("bind_map_data returned false.")
		return
	if not w.is_bound():
		push_error("is_bound() returned false after bind.")
		return

	# ─── T0: BIND_TABLE 1:1 对齐硬断言（Step 2.0 新增） ────────────────
	# bind_map_data 内部 print 了 "N components bound"。我们这里通过
	# debug_bound_count() 方法直接拿 count（C++ 端需要导出该 getter；
	# 若未导出，回退到 view 探针：每个 slot view 出来 size>0 就算 bound）。
	# 当前 C++ 没有 debug_bound_count() 导出，因此用回退方案：
	var bound_via_view: int = 0
	var unbound_names: Array = []
	for entry2 in _REGISTRATIONS:
		var sn2: StringName = entry2[0]
		var dt2: int = entry2[1]
		var cid2: int = w.component_id(sn2)
		if cid2 < 0:
			unbound_names.append(String(sn2) + "(no cid)")
			continue
		var sz: int = 0
		match dt2:
			_DT_F32:
				sz = (w.view_f32(cid2) as PackedFloat32Array).size()
			_DT_U8:
				sz = (w.view_u8(cid2) as PackedByteArray).size()
			_DT_I32:
				sz = (w.view_i32(cid2) as PackedInt32Array).size()
		if sz == _N:
			bound_via_view += 1
		else:
			unbound_names.append(String(sn2) + "(size=" + str(sz) + ")")

	var t0_pass: bool = (bound_via_view == expected_count)
	print("  T0 (BIND_TABLE 1:1 align): expected=%d  bound=%d  -> %s"
		% [expected_count, bound_via_view, "PASS" if t0_pass else "FAIL"])
	if not t0_pass:
		printerr("    Components that DIDN'T bind correctly: %s" % str(unbound_names))
		printerr("    -> BIND_TABLE in world_ext.cpp drift from world.gd. Fix before continuing.")

	# ─── T1: C++ → GDScript (no flush) — EXPECTED FAIL ────────────────
	# 这一项断在 ABI 物理层：bind_map_data 内部的 ptrw() 已经把 C++ 端
	# slot.arr_f32 detach 成私有 buffer，不再与 GDScript 端共享内存。
	# 所以 _debug_poke_f32 写到的是 C++ 私有副本，GDScript 端看不到。
	# 这是"单向快照"契约的物理表现，不是 bug。修复路径是 T1b。
	var ret_cpp: float = w._debug_poke_f32(c_temp, _IDX, _SENTINEL_FROM_CPP)
	var seen_gd_after_cpp_write: float = mock.temp_arr[_IDX]
	var t1_naive_synced: bool = is_equal_approx(seen_gd_after_cpp_write, _SENTINEL_FROM_CPP)
	print("  T1 (C++ → GDScript, no flush): cpp_returned=%s  gd_sees=%s  -> %s (EXPECTED: not synced; this is the snapshot contract)"
		% [str(ret_cpp), str(seen_gd_after_cpp_write),
		   "unexpectedly SYNCED" if t1_naive_synced else "not synced"])

	# ─── T1b: C++ → GDScript with explicit set() flush ────────────────
	var ret_cpp_flush: float = w._debug_poke_f32_with_flush(c_temp, _IDX, _SENTINEL_FLUSH)
	var seen_gd_after_flush: float = mock.temp_arr[_IDX]
	var t1b_pass: bool = is_equal_approx(seen_gd_after_flush, _SENTINEL_FLUSH)
	print("  T1b (C++ → GDScript, with flush): cpp_returned=%s  gd_sees=%s  expect=%s  -> %s"
		% [str(ret_cpp_flush), str(seen_gd_after_flush), str(_SENTINEL_FLUSH),
		   "PASS" if t1b_pass else "FAIL"])

	# ─── T2: GDScript → C++ (after rebind) — EXPECTED "not synced" ─────
	# 重要发现：T1b 中 map_data->set("temp_arr", arr) 不是原地修改，而是把
	# GDScript 端 mock.temp_arr 替换成新引用（reseat）。即使紧跟着重新
	# bind_map_data()，C++ 端在 bind 内 ptrw() 又 detach 一次，两侧仍指向
	# 不同 buffer。GDScript 端事后 mock.temp_arr[_IDX]=v 写入的也是 GDScript
	# 自己那份，C++ view_f32 看不到。
	# 这是 GDExtension ABI 的物理结果（每次跨界 Variant 包装 → refcount≥2
	# → ptrw 必 CoW），不是实现 bug。
	# 工程纪律（已写入 performance-charter.md §11）：
	#   1) GDScript 端的输入应该在 pass 之间通过 write_f32 / write_f32_indexed
	#      显式回写 C++ buffer，绝不依赖"in-place 写 mock.temp_arr"
	#   2) C++ 端在 pass 末尾用 set() flush 把结果推回 GDScript（这就是 T1b
	#      验证的契约）
	var rebound: bool = w.bind_map_data(mock)
	if not rebound:
		push_error("rebind for T2 failed.")
		return
	mock.temp_arr[_IDX] = _SENTINEL_FROM_GD
	var snapshot: PackedFloat32Array = w.view_f32(c_temp)
	var seen_cpp_view: float = snapshot[_IDX]
	var t2_naive_synced: bool = is_equal_approx(seen_cpp_view, _SENTINEL_FROM_GD)
	print("  T2 (GDScript → C++ in-place, after rebind): gd_wrote=%s  cpp_view_f32_sees=%s  -> %s (EXPECTED: not synced; use write_f32 helpers instead)"
		% [str(_SENTINEL_FROM_GD), str(seen_cpp_view),
		   "unexpectedly SYNCED" if t2_naive_synced else "not synced"])

	# ─── T3: GDScript reseat 后 alias 必断（记录用，不算失败）──────────
	mock.temp_arr.resize(_N + 1)
	var ret_cpp_after_reseat: float = w._debug_poke_f32(c_temp, _IDX, 4242.0)
	var gd_sees_after_reseat: float = mock.temp_arr[_IDX]
	var t3_alias_alive: bool = is_equal_approx(gd_sees_after_reseat, 4242.0)
	print("  T3 (after GDScript resize): cpp_returned=%s  gd_sees=%s  -> alias %s (expected: BROKEN)"
		% [str(ret_cpp_after_reseat), str(gd_sees_after_reseat),
		   "ALIVE (unexpected!)" if t3_alias_alive else "BROKEN (as expected)"])
	if t3_alias_alive:
		push_warning("T3: alias survived a GDScript-side resize?? double-check Phase 3a contract.")

	# ─── 总结 ────────────────────────────────────────────────────────
	# 真正的 alias 契约（performance-charter.md §11 固化）：
	#   - T0 必须 PASS：BIND_TABLE 1:1 对齐 world.gd（零静默 skip）
	#   - T1b 必须 PASS：write-then-set 是唯一可行的 C++ → GDScript 通路
	#   - T1 / T2 "not synced" 是 EXPECTED 行为（GDExtension ABI 单向快照）
	#   - T3 的 alias-broken-after-resize 也是 EXPECTED（reseat 必须重 bind）
	var step20_pass: bool = t0_pass
	var contract_pass: bool = t1b_pass
	# 如果 T1 / T2 居然 "synced" 了，说明 Godot 改了 ABI，需要立刻审计
	# 现有所有 hot-loop 假设（很可能可以删 set()-flush 简化代码）。
	var abi_surprise: bool = t1_naive_synced or t2_naive_synced

	print("=== Verdict ===")
	if step20_pass:
		print("  ✅ Step 2.0 PASS — BIND_TABLE 1:1 aligned with world.gd (no silent skips).")
	else:
		printerr("  ❌ Step 2.0 FAIL — BIND_TABLE drifts from world.gd; investigate above list.")

	if contract_pass:
		print("  ✅ Snapshot contract holds (the only contract this layer guarantees):")
		print("     - C++ → GDScript: write-then-set() per pass works (T1b PASS).")
		print("     - GDScript → C++: handled by write_f32/_indexed helpers (NOT alias).")
		print("     ℹ T1 / T2 \"not synced\" outcomes above are EXPECTED — they encode")
		print("       the GDExtension ABI: every cross-boundary PackedArray traverses")
		print("       a Variant; refcount ≥ 2 forces ptrw() to CoW-detach. There is no")
		print("       two-way zero-copy alias possible at this layer.")
		print("     ⚠ Engineering rules (see docs/performance-charter.md §11):")
		print("       1) C++ hot loop writes its own buffer freely, then calls")
		print("          map_data->set(prop, arr) ONCE at end of pass to flush.")
		print("       2) GDScript MUST NOT mutate already-flushed fields in-place")
		print("          inside a pass — those writes are invisible to C++.")
		print("          Use world.write_f32 / write_f32_indexed at pass boundaries.")
		print("       3) Any GDScript-side reseat (resize / whole-assign) of a bound")
		print("          field MUST be followed by world.bind_map_data(map).")
	else:
		printerr("  ❌ Snapshot contract BROKEN — T1b failed.")
		printerr("     write-then-set didn't sync GDScript side. This means the only")
		printerr("     viable cross-boundary write path no longer works. Investigate")
		printerr("     before proceeding to Step 2.1.")

	if abi_surprise:
		push_warning("GDExtension ABI surprise: T1 or T2 unexpectedly synced — Godot may have")
		push_warning("changed CoW semantics. Re-audit performance-charter.md §11 assumptions.")

	if step20_pass and contract_pass:
		print("")
		print("  >>> GREEN — proceed to Step 2.1 (HexCell weak-field sink).")
