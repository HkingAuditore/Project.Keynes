extends SceneTree

## NS 化四方向深化 — Phase 0/1/3 原生公式测试 + Phase 2 SL 消费公式测试。
## 覆盖(plan/NS化气候动力学四方向深化 验证矩阵):
##   - 六分扇形 barycentric / 轨迹表:均匀场 SL 恒等、线性场 SL 精确(权重和=1
##     无 overshoot)、指纹 stale → 旧 hopping 回退。
##   - 动量扩散:均匀场 Laplacian=0;一般场按 GDScript 复刻公式逐 cell 精确。
##   - 散度阻尼 L1:均匀场 div=0 不动;脉冲场按复刻公式逐 cell 精确。
## 运行: godot --headless --path Project/project-keynes -s tests/native_wind_traj_momentum_test.gd

const _SQRT3 := 1.7320508075688772
const _SQRT3_HALF := 0.8660254037844386
# 与 world_ext_physical.cpp NB_DIR_X/Y 同值(0=E,1=NE,2=NW,3=W,4=SW,5=SE)。
const _NB_DIR_X := [_SQRT3, _SQRT3_HALF, -_SQRT3_HALF, -_SQRT3, -_SQRT3_HALF, _SQRT3_HALF]
const _NB_DIR_Y := [0.0, -1.5, -1.5, 0.0, 1.5, 1.5]

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("SKIP: DCWorldExt 不可用(原生扩展未加载)")
		quit(0)
		return
	_test_momentum_uniform_identity()
	_test_diffuse_general_field_replica()
	_test_div_damp_replica()
	_test_sliced_equivalence()
	_test_wind_air_sl_linear_and_stale()
	print("=== native wind traj/momentum: %d checks, %d failures ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


# ─── 地图 / 旋钮构建 ────────────────────────────────────────────────────────

func _build_land_map(w: int, h: int) -> MapData:
	var map := MapData.new(w, h)
	for row in range(h):
		for col in range(w):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.index = row * w + col
			cell.terrain = int(TerrainType.TERRAIN.GRASSLAND)
			map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	var n := map.cell_count()
	var terr := PackedByteArray()
	terr.resize(n)
	terr.fill(int(TerrainType.TERRAIN.GRASSLAND))
	map.terrain_arr = terr
	var lf := PackedByteArray()
	lf.resize(n)
	lf.fill(int(LandformType.LF.PLAIN))
	map.landform_arr = lf
	return map


## 按 per-cell 通量 (fx, fy) 写 wind dir/speed 三元组(dir 单位化)。
func _set_wind_flux(map: MapData, fx: Array, fy: Array) -> void:
	var n := map.cell_count()
	var wx := PackedFloat32Array()
	var wy := PackedFloat32Array()
	var wsp := PackedFloat32Array()
	wx.resize(n)
	wy.resize(n)
	wsp.resize(n)
	for i in range(n):
		var len: float = sqrt(fx[i] * fx[i] + fy[i] * fy[i])
		if len > 0.0001:
			wx[i] = fx[i] / len
			wy[i] = fy[i] / len
			wsp[i] = len
	map.wind_x_arr = wx
	map.wind_y_arr = wy
	map.wind_speed_arr = wsp


func _wind_knobs(map: MapData, extra: Dictionary = {}) -> Dictionary:
	var n := map.cell_count()
	var slp := PackedFloat32Array()
	slp.resize(n)
	var water_ids := PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN),
		int(TerrainType.TERRAIN.COAST),
		int(TerrainType.TERRAIN.REEF),
		int(TerrainType.TERRAIN.KELP),
	])
	var k: Dictionary = {
		"n_cells": n,
		"hex_size": 1.0,
		"season_phase": 0.0,
		"terrain_aware": 0,
		"world_bounds_pos_y": 0.0,
		"world_bounds_size_y": 1.0,
		"neighbor_indices": map._neighbor_indices,
		"slp_arr": slp,
		"water_terrain_ids": water_ids,
		"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
		"land_lf_peak": int(LandformType.LF.PEAK),
		"land_lf_hill": int(LandformType.LF.HILL),
		# 隔离动量/散度:诊断合成与 synoptic 不参与终值(effective_rate=0)。
		"wind_response_rate": 0.0,
		"wind_synoptic_amp": 0.0,
		"wrap_period_x": 0.0,
		"wind_elapsed_days": 12.0,
	}
	for key in extra:
		k[key] = extra[key]
	return k


func _valid_nb(map: MapData, i: int) -> Array:
	var out: Array = []
	var nb := map._neighbor_indices
	var n := map.cell_count()
	for d in range(6):
		var ni := int(nb[i * 6 + d])
		if ni >= 0 and ni < n:
			out.append(ni)
	return out


# ─── Test 1: 动量(advect+diffuse)对均匀场恒等 ───────────────────────────────

func _test_momentum_uniform_identity() -> void:
	var map := _build_land_map(9, 5)
	var n := map.cell_count()
	var fx: Array = []
	var fy: Array = []
	for i in range(n):
		fx.append(0.8)
		fy.append(0.0)
	_set_wind_flux(map, fx, fy)
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)

	# Pass A:仅建轨迹表。
	var k1 := _wind_knobs(map, {"wind_traj_table_enabled": true})
	var e1: float = ext.run_wind_field_pass(k1)
	_expect("uniform: pass A 成功", e1 >= 0.0)
	_expect("uniform: 轨迹表 gen=1", int(k1.get("wind_traj_gen", -1)) == 1)

	# Pass B:动量全开。均匀场 → SL 采样=自身、Laplacian=0 → 零增量。
	var k2 := _wind_knobs(map, {
		"wind_traj_table_enabled": true,
		"wind_momentum_advect_w": 0.3,
		"wind_momentum_diffuse_w_daily": 0.08,
	})
	var e2: float = ext.run_wind_field_pass(k2)
	_expect("uniform: pass B 成功", e2 >= 0.0)
	_expect("uniform: 动量增量 p95 ≈ 0",
		abs(float(k2.get("momentum_advect_diffuse_delta_p95", 1.0))) < 1e-5)
	_expect("uniform: 动量开启强制重建轨迹表 gen=2",
		int(k2.get("wind_traj_gen", -1)) == 2)
	_expect("uniform: advect_w 生效键", abs(float(k2.get("momentum_advect_w_eff", -1.0)) - 0.3) < 1e-6)
	var ok_slots := true
	for i in range(n):
		if abs(map.wind_x_arr[i] - 1.0) > 1e-5 or abs(map.wind_y_arr[i]) > 1e-5 \
				or abs(map.wind_speed_arr[i] - 0.8) > 1e-5:
			ok_slots = false
			break
	_expect("uniform: 风场逐位不变", ok_slots)

# ─── Test 2: 动量扩散对一般场逐 cell 精确(GDScript 复刻公式) ────────────────

func _test_diffuse_general_field_replica() -> void:
	var map := _build_land_map(9, 5)
	var n := map.cell_count()
	var px := map.cell_pos_x_arr
	var py := map.cell_pos_y_arr
	var fx: Array = []
	var fy: Array = []
	for i in range(n):
		fx.append(0.3 * px[i] + 0.2 * py[i] + 0.5)
		fy.append(0.1 * px[i] - 0.4 * py[i] + 0.6)
	_set_wind_flux(map, fx, fy)
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)

	# 只开扩散(daily=0.5 → 1-(0.5)^12 ≈ 1),advect=0 隔离 SL。
	var k := _wind_knobs(map, {"wind_momentum_diffuse_w_daily": 0.5})
	var e: float = ext.run_wind_field_pass(k)
	_expect("diffuse: pass 成功", e >= 0.0)

	var grid_s: float = sqrt(float(n) / 15000.0)
	var w: float = (1.0 - pow(1.0 - 0.5, 12.0)) * grid_s * grid_s
	if w > 0.5:
		w = 0.5
	_expect("diffuse: 生效权重键与复刻一致",
		abs(float(k.get("momentum_diffuse_w_eff", -1.0)) - w) < 1e-9)
	_expect("diffuse: 增量 p95 > 0(扩散确实作用)",
		float(k.get("momentum_advect_diffuse_delta_p95", 0.0)) > 1e-6)

	var max_err := 0.0
	var ok_dir := true
	for i in range(n):
		var nb := _valid_nb(map, i)
		var sum_x := 0.0
		var sum_y := 0.0
		for ni in nb:
			sum_x += fx[ni]
			sum_y += fy[ni]
		var tx: float = fx[i] + w * (sum_x / float(nb.size()) - fx[i])
		var ty: float = fy[i] + w * (sum_y / float(nb.size()) - fy[i])
		var tl: float = sqrt(tx * tx + ty * ty)
		var edx: float = tx / tl
		var edy: float = ty / tl
		max_err = max(max_err, abs(map.wind_x_arr[i] - edx))
		max_err = max(max_err, abs(map.wind_y_arr[i] - edy))
		# rate=0 → speed 保持旧值(通量模长),扩散只改方向。
		if abs(map.wind_speed_arr[i] - sqrt(fx[i] * fx[i] + fy[i] * fy[i])) > 2e-4:
			ok_dir = false
	_expect("diffuse: 逐 cell 方向与 Laplacian 复刻一致(max_err=%.6f)" % max_err, max_err < 2e-4)
	_expect("diffuse: rate=0 时 speed 不被诊断改写", ok_dir)

# ─── Test 3: 散度阻尼 L1 逐 cell 精确 + 均匀场不动 ──────────────────────────

func _test_div_damp_replica() -> void:
	# 3a:均匀场 → div≡0 → 完全不动。
	var map_u := _build_land_map(9, 5)
	var n := map_u.cell_count()
	var fx0: Array = []
	var fy0: Array = []
	for i in range(n):
		fx0.append(0.5)
		fy0.append(0.0)
	_set_wind_flux(map_u, fx0, fy0)
	var ext_u := DCWorldExt.new()
	ext_u.bind_map_data(map_u)
	var ku := _wind_knobs(map_u, {"wind_div_damp_alpha": 1.0})
	ext_u.run_wind_field_pass(ku)
	var ok_u := true
	for i in range(n):
		if abs(map_u.wind_x_arr[i] - 1.0) > 1e-6 or abs(map_u.wind_y_arr[i]) > 1e-6 \
				or abs(map_u.wind_speed_arr[i] - 0.5) > 1e-6:
			ok_u = false
			break
	_expect("div_damp: 均匀场完全不变", ok_u)
	_expect("div_damp: α 超 0.3 硬上限被 clamp(α_eff=min(1.0,0.3)·s²)",
		abs(float(ku.get("div_damp_alpha_eff", -1.0)) - 0.3 * float(n) / 15000.0) < 1e-12)

	# 3b:中心脉冲场 → 按复刻公式逐 cell 精确。
	var map := _build_land_map(9, 5)
	var px := map.cell_pos_x_arr
	var py := map.cell_pos_y_arr
	# 中心 cell (col=4,row=2) → index = 2*9+4 = 22。
	var center := 22
	var fx: Array = []
	var fy: Array = []
	for i in range(n):
		fx.append(2.0 if i == center else 0.5)
		fy.append(0.0)
	_set_wind_flux(map, fx, fy)
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)
	var k := _wind_knobs(map, {"wind_div_damp_alpha": 1.0})
	ext.run_wind_field_pass(k)

	var a_eff: float = min(1.0, 0.3) * float(n) / 15000.0
	# 复刻:div_i = (1/3)Σ_d (F_nb - F_i)·NB_DIR_d;g_i = (1/3)Σ_d (div_nb - div_i)·NB_DIR_d;
	# F_new = F + α_eff·g(+号为 div 能量梯度下降方向:∂½∫div²/∂t = -α∫|∇div|² ≤ 0;
	# 2026-08-04 A/B 实测 - 号为反扩散放大散度,已翻转)。
	var div: Array = []
	div.resize(n)
	for i in range(n):
		var dv := 0.0
		for d in range(6):
			var ni := int(map._neighbor_indices[i * 6 + d])
			if ni < 0 or ni >= n:
				continue
			dv += (fx[ni] - fx[i]) * _NB_DIR_X[d] + (fy[ni] - fy[i]) * _NB_DIR_Y[d]
		div[i] = dv / 3.0
	var max_err := 0.0
	for i in range(n):
		var gx := 0.0
		var gy := 0.0
		var cnt := 0
		for d in range(6):
			var ni := int(map._neighbor_indices[i * 6 + d])
			if ni < 0 or ni >= n:
				continue
			gx += (div[ni] - div[i]) * _NB_DIR_X[d]
			gy += (div[ni] - div[i]) * _NB_DIR_Y[d]
			cnt += 1
		if cnt == 0:
			continue
		gx /= 3.0
		gy /= 3.0
		var nfx: float = fx[i] + a_eff * gx
		var nfy: float = fy[i] + a_eff * gy
		var nl2: float = nfx * nfx + nfy * nfy
		if nl2 <= 1e-8:
			continue
		var nl: float = sqrt(nl2)
		max_err = max(max_err, abs(map.wind_x_arr[i] - nfx / nl))
		max_err = max(max_err, abs(map.wind_y_arr[i] - nfy / nl))
		max_err = max(max_err, abs(map.wind_speed_arr[i] - nl))
	_expect("div_damp: 脉冲场逐 cell 与复刻一致(max_err=%.6f)" % max_err, max_err < 2e-3)

	# 3c:物理性质断言(防符号回归):一步 L1 后全场散度能量 Σdiv² 必须下降。
	# 先算作用前 Σdiv²(上面已逐 cell 算得 div),再对 pass 后的新风场重算。
	var e_before := 0.0
	for i in range(n):
		e_before += div[i] * div[i]
	var e_after := 0.0
	for i in range(n):
		var fx_i: float = map.wind_x_arr[i] * map.wind_speed_arr[i]
		var fy_i: float = map.wind_y_arr[i] * map.wind_speed_arr[i]
		var dv2 := 0.0
		for d in range(6):
			var ni := int(map._neighbor_indices[i * 6 + d])
			if ni < 0 or ni >= n:
				continue
			var dfx2: float = map.wind_x_arr[ni] * map.wind_speed_arr[ni] - fx_i
			var dfy2: float = map.wind_y_arr[ni] * map.wind_speed_arr[ni] - fy_i
			dv2 += dfx2 * _NB_DIR_X[d] + dfy2 * _NB_DIR_Y[d]
		var d2: float = dv2 / 3.0
		e_after += d2 * d2
	_expect("div_damp: 脉冲场 Σdiv² 严格下降(%.6f → %.6f)" % [e_before, e_after],
		e_after < e_before - 1e-12)

# ─── Test 3c: 切片执行 ≡ 全量执行(分区不变性/bit-equal A/B) ─────────────────
# 动量快照成员化(首切片重建、后续复用)+ 散度阻尼/轨迹表仅末切片 → 任意切片
# 序列与单次全量逐位一致。新并行段(动量/散度/轨迹构建)全部为 per-cell 只读邻
# 居写自身,线程划分数无关;切片 A/B 是该不变性可用的最强实证形式。

func _test_sliced_equivalence() -> void:
	var gates := {
		"wind_momentum_advect_w": 0.3,
		"wind_momentum_diffuse_w_daily": 0.08,
		"wind_div_damp_alpha": 0.2,
		"wind_traj_table_enabled": true,
	}
	# 全量
	var map_a := _build_land_map(9, 5)
	var n := map_a.cell_count()
	var px := map_a.cell_pos_x_arr
	var py := map_a.cell_pos_y_arr
	var fx: Array = []
	var fy: Array = []
	for i in range(n):
		fx.append(0.3 * px[i] + 0.2 * py[i] + 0.5)
		fy.append(0.1 * px[i] - 0.4 * py[i] + 0.6)
	_set_wind_flux(map_a, fx, fy)
	var ext_a := DCWorldExt.new()
	ext_a.bind_map_data(map_a)
	ext_a.run_wind_field_pass(_wind_knobs(map_a, gates))
	# 两切片
	var map_b := _build_land_map(9, 5)
	_set_wind_flux(map_b, fx, fy)
	var ext_b := DCWorldExt.new()
	ext_b.bind_map_data(map_b)
	var half: int = n / 2
	var k1 := _wind_knobs(map_b, gates)
	k1["start_idx"] = 0
	k1["end_idx"] = half
	ext_b.run_wind_field_pass(k1)
	var k2 := _wind_knobs(map_b, gates)
	k2["start_idx"] = half
	k2["end_idx"] = n
	ext_b.run_wind_field_pass(k2)
	_expect("slice: 切片后轨迹表照常构建", int(k2.get("wind_traj_gen", -1)) == 1)
	var ok := true
	for i in range(n):
		if map_a.wind_x_arr[i] != map_b.wind_x_arr[i] \
				or map_a.wind_y_arr[i] != map_b.wind_y_arr[i] \
				or map_a.wind_speed_arr[i] != map_b.wind_speed_arr[i]:
			ok = false
			printerr("    slice mismatch at %d: a=(%.9g,%.9g,%.9g) b=(%.9g,%.9g,%.9g)" % [
				i, map_a.wind_x_arr[i], map_a.wind_y_arr[i], map_a.wind_speed_arr[i],
				map_b.wind_x_arr[i], map_b.wind_y_arr[i], map_b.wind_speed_arr[i]])
			break
	_expect("slice: 两切片 ≡ 全量 逐位一致(bit-equal)", ok)


# ─── Test 4: wind_air 轨迹表 SL(线性场精确)+ 指纹 stale 回退 ────────────────

func _test_wind_air_sl_linear_and_stale() -> void:
	var map := _build_land_map(15, 5)
	var n := map.cell_count()
	var px := map.cell_pos_x_arr
	# 线性温度场 T = px(barycentric 对线性场精确 → SL 结果解析可断)。
	var temp := PackedFloat32Array()
	temp.resize(n)
	for i in range(n):
		temp[i] = px[i]
	map.temp_arr = temp
	var fx: Array = []
	var fy: Array = []
	for i in range(n):
		fx.append(1.0)
		fy.append(0.0)
	_set_wind_flux(map, fx, fy)
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)

	# 生产契约:NB 表东西环绕(map_data._build_indices posmod)⟹ 必须传 wrap_period_x,
	# 否则最右列的环绕邻居在回溯 walk 里呈现为"远端西侧"假方向。wrap 开启后
	# 回溯点跨接缝由最小映像折叠正确处理。
	var period: float = 15.0 * _SQRT3
	var kw := _wind_knobs(map, {
		"wind_traj_table_enabled": true,
		"wind_traj_pos_scale": 4.0,
		"wind_traj_dt_days": 10.0,
		"wrap_period_x": period,
	})
	ext.run_wind_field_pass(kw)
	_expect("sl: 轨迹表 gen=1", int(kw.get("wind_traj_gen", -1)) == 1)

	var grid_s: float = sqrt(float(n) / 15000.0)
	var dist: float = 1.0 * (4.0 * grid_s * 10.0)  # |flux|·pos_scale·s·dt
	var speed_mix: float = 1.0 / 1.2

	var ka: Dictionary = {
		"n_cells": n,
		"advect_steps": 3,
		"heat_mix": 1.0,
		"neighbor_indices": map._neighbor_indices,
		"baseline_arr": temp.duplicate(),
		"temp_before_arr": temp.duplicate(),
		"wrap_period_x": period,
	}
	var ea: float = ext.run_wind_air_mass_pass(ka)
	_expect("sl: wind_air 成功", ea >= 0.0)
	_expect("sl: 轨迹表被消费(wind_traj_used)", bool(ka.get("wind_traj_used", false)))

	var max_px := -INF
	for i in range(n):
		max_px = max(max_px, px[i])
	var interior := 0
	var ok_exact := true
	var ok_bounds := true
	for i in range(n):
		var a: float = map.air_mass_temp_anomaly_arr[i]
		var t_up: float = px[i] + a / speed_mix
		# 单调性/无 overshoot:T_up 是顶点温度凸组合 → 恒在场值域内。
		if t_up < -1e-3 or t_up > max_px + 1e-3:
			ok_bounds = false
		if px[i] - dist >= 0.0:
			# 不跨接缝:线性场 barycentric 精确 → T_up = px_i - dist。
			interior += 1
			if abs(a + dist * speed_mix) > 2e-3:
				ok_exact = false
		else:
			# 跨接缝:回溯点绕到东侧高值区 → A 为正且仍被顶点值夹住。
			if a < -2e-3:
				ok_bounds = false
	_expect("sl: 内陆 cell 线性场 SL 精确(interior=%d)" % interior, interior >= 60 and ok_exact)
	_expect("sl: 全图 T_up 被顶点值夹住(权重和=1 无 overshoot)", ok_bounds)

	# stale:带外改写风槽(模拟 GDScript fallback 写风)→ 指纹失配 → 旧 hopping。
	var wx_half := PackedFloat32Array()
	wx_half.resize(n)
	wx_half.fill(0.5)
	map.wind_x_arr = wx_half
	ext.refresh_slots_from_map_keys(PackedStringArray(["cell_wind_x"]))
	var ka2: Dictionary = ka.duplicate()
	ka2["temp_before_arr"] = temp.duplicate()
	ext.run_wind_air_mass_pass(ka2)
	_expect("stale: 指纹失配落旧路径(wind_traj_used=false)",
		not bool(ka2.get("wind_traj_used", true)))
	_expect("stale: stale 计数上报", int(ka2.get("wind_traj_stale_count", 0)) >= 1)

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
