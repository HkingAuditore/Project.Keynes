extends "res://scripts/weather/weather_context.gd"
class_name DCWeatherFieldSolver

const FieldSliceKernel = preload("res://scripts/weather/field_slice_kernel.gd")
const FieldSliceCommit = preload("res://scripts/weather/field_slice_commit.gd")

const WeatherFieldPhysicsScript = preload("res://scripts/weather/field_solver_physics.gd")

## Phase E.1 / dots-full-migration §Phase E.1：weather field solver 抽出。
##
## **当前状态（dots-monolith-split §1.2 / PR-1..7 全部完成）**：
## 实际 hot-path 实现已全量搬入本类。`weather_system.gd` 端的同名函数
## （begin_weather_field_solve / run_weather_field_solve_slice /
## commit_weather_field_solve / _solve_weather_field）保留为薄转发入口，
## 服务于 map_generator.gd 等 SUS job 的外部契约稳定。
## 业务旋钮（`_field_advect_steps` / `_field_diffusion` / `_field_condensation_gain`
## 等约 12 个 `_field_*` 配置字段）仍保留在 weather_system 作为 owner
## 配置中心；本类通过 `_weather_system.<field>` 读取。
##
## ─── 已完成的搬迁清单 ─────────────────────────────────────────────────
##
## PR-1：邻居/风向 helper（已保留的索引路径）
##   - `_neighbor_aligned` / `_neighbor_aligned_idx`
##   - `_upstream_vapor_cached` / `_upstream_vapor_idx_from_first`
##   - `_neighbor_average_vapor_cached` / `_neighbor_average_vapor_idx`
##
## PR-2：物理项 helper（已保留的索引路径）
##   - `_orographic_lift_for_cell` / `_orographic_lift_from_upstream_idx`
##   - `_wind_convergence_for_cell` / `_wind_convergence_idx`
##
## PR-3：海洋异常 helper（2 个）
##   - `_avg_ocean_anomaly_at` / `_avg_ocean_anomaly_at_idx`
##
## PR-4：切片状态字段（22 个 `_field_slice_*`）
##   - active / map / world / season_idx / climate_anomaly / cursor /
##     refresh_convergence / cells / cell_pos / neighbor_indices /
##     fast_indexed / prev_vapor / prev_precip / next_vapor / next_cloud /
##     next_precip / next_instability / next_intensity / next_convergence /
##     next_type / solve_ms / last_ms
##
## PR-5：`commit()` 主体（149 行）
##   - 9 字段 batch SoA 写入（DCWorld.write_f32_indexed / write_u8_indexed）
##   - facade 开启时跳过 AoS 双写
##   - distribute / build_field_summary_fronts / cyclone_wake / breakdown
##
## PR-6：`begin_slice()`（63 行）+ `run_slice()`（181 行）
##   - DCWorldExt C++ 单 shot fast path
##   - GDScript fallback：vapor / cloud / precip / instability 三段式 hot loop
##   - `_solve_weather_field` 内 dead code 已清除
##
## ─── 拆分原则（保留作为后续维护参考）──────────────────────────────────
##
## 1. `DCWeatherFieldSolver.new(weather_system)` 接受 owner 引用，从中拿
##    约 12 个 `_field_*` 配置字段；
## 2. 读 cell.* schema-mirrored 字段统一走 SoA index（PackedArray）；
## 3. 写 weather component 走 cell.<field> = ... 的 SoA 镜像 + DCWorld
##    write_*_indexed 批量提交；
## 4. F.1 阶段（已上线）把 `run_slice` 整体调度切到
##    `DCWorldExt.run_weather_field_solve_pass` 的 C++ 实现，本类的 GDScript
##    实现作为 fallback 路径。
##
## ─── 隔离 fallback 声明（NS 化 Phase 2,2026-08-04）──────────────────
## 生产 profile 已退休 legacy weather 生产注册（native C++ 是唯一生产路径），
## 本 GDScript hot loop 定位为 **stale-DLL 隔离 fallback**：保留旧 hopping
## 平流语义（`_upstream_vapor_idx_from_first`，离散邻居逐跳），**不镜像**
## C++ 的风场轨迹表三点插值（`_phys_wind_traj` 成员缓存仅存在于 native 侧，
## GDScript 无法访问 → 无法 bit-equal，强行近似反而引入第二条漂移源）。
## 例外：静态纯函数 `hex_sextant_barycentric()` 与 C++ 保持 SAME_SOURCE
## 数学定义互链（不依赖成员缓存，可供任何 GDScript 侧 SL 计算复用）。

# ─── solver 实现入口（hot loop 已全量实装，见上方 PR-1..7 清单）─────



## 在 weather_system 实例上注入本 solver。为 E.3 cleanup 时 weather_system 可
## 通过 `_field_solver = DCWeatherFieldSolver.new(self)` 实例化并 forward 调用。

func _init(weather_system) -> void:
	_weather_system = weather_system
	if _weather_system == null:
		push_warning("[DCWeatherFieldSolver] _init: null weather_system; field solver will no-op")


## 主入口：dots-monolith-split §1.2 / PR-6 搬迁。
## 三段式：begin_slice 初始化 → 循环 run_slice 跑完所有 cell → commit 写出 SoA & 构建 fronts。
## map_generator.gd 的 SUS job 直接调 weather_system.begin_weather_field_solve /
## run_weather_field_solve_slice / commit_weather_field_solve（已薄转发到本类）。
func solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> void:
	if _weather_system == null:
		return
	begin_slice(map, world, season_idx, climate_anomaly, _weather_system._season_phase)
	while true:
		var slice_result: Dictionary = run_slice(2147483647)
		if bool(slice_result.get("done", true)):
			break
	commit()

# ─── PR-6：切片状态机主体（搬迁自 weather_system.gd line 629-873）──────────
# weather_system 端 begin_weather_field_solve / run_weather_field_solve_slice
# 改为薄转发到本类的 begin_slice / run_slice。所有 _field_slice_* 字段（PR-4
# 搬来）作为 self 成员；owner 上的 _field_*/世界边界/gdext 状态等通过
# _weather_system.xxx 访问；helper（_neighbor_aligned_idx / _upstream_vapor_idx*
# / _orographic_lift* / _wind_convergence* / _avg_ocean_anomaly_at* /
# _neighbor_average_vapor*）已在 PR-1/2/3 搬入本类，自调用。

## 切片初始化：分配 prev/next buffer、读 SoA 进 prev_vapor/precip。
func begin_slice(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true, for_worker_knobs_only: bool = false, defer_thermal_equator: bool = false) -> void:
	_weather_system._clear_weather_field_slice_state()
	if map == null or world == null:
		return
	if count_day:
		_weather_system._day_counter += 1
	_weather_system._current_map_for_tick = map
	_weather_system._season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5
	_weather_system._field_solve_tick += 1
	_field_slice_active = true
	_field_slice_map = map
	_field_slice_world = world
	_field_slice_season_idx = season_idx
	_field_slice_climate_anomaly = climate_anomaly
	_field_slice_cursor = 0
	_field_slice_solve_ms = 0.0
	_field_slice_last_ms = 0.0
	_field_slice_results_in_soa = false
	_field_slice_native_convergence_boost = false
	_field_slice_temp_anom = PackedFloat32Array()
	_field_slice_native_knobs.clear()
	_field_slice_refresh_convergence = ((_weather_system._field_solve_tick - 1) % _weather_system._field_convergence_refresh_stride) == 0
	_field_slice_cells = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = _field_slice_cells.size()
	# Stage6c: 对流抑制记忆数组——仅在尺寸变化(换地图)时重置，否则跨 tick 持久(承载充放电记忆)。
	if _convective_inhib.size() != n_cells:
		_convective_inhib = PackedFloat32Array()
		_convective_inhib.resize(n_cells)
	_field_slice_temp_read = map.temp_arr_prev if map.temp_arr_prev.size() == n_cells else map.temp_arr
	_field_slice_moisture_read = map.moisture_arr_prev if map.moisture_arr_prev.size() == n_cells else map.moisture_arr
	if not for_worker_knobs_only:
		if map.weather_classification_temp_arr.size() == n_cells:
			map.weather_classification_temp_arr = _field_slice_temp_read.duplicate()
		if map.weather_classification_moisture_arr.size() == n_cells:
			map.weather_classification_moisture_arr = _field_slice_moisture_read.duplicate()
	_field_slice_snow_cover_read = map.snow_cover_arr_prev if map.snow_cover_arr_prev.size() == n_cells else map.snow_cover_arr
	_field_slice_neighbor_indices = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	_field_slice_fast_indexed = _field_slice_neighbor_indices.size() >= n_cells * 6
	var map_id: int = map.get_instance_id()
	var has_soa_pos_for_scale: bool = map.cell_pos_x_arr.size() >= n_cells and map.cell_pos_y_arr.size() >= n_cells
	_field_slice_cell_pos_scale = 1.0 if has_soa_pos_for_scale else _weather_system._hex_size
	_field_slice_wrap_width_x = float(map.width) * sqrt(3.0) * _field_slice_cell_pos_scale if map.width > 0 else 0.0
	var can_reuse_cell_pos: bool = _cached_cell_pos_n == n_cells \
		and _cached_cell_pos_map_id == map_id \
		and absf(_cached_cell_pos_hex_size - _field_slice_cell_pos_scale) < 0.0001 \
		and _cached_cell_pos.size() == n_cells
	if not can_reuse_cell_pos:
		_cached_cell_pos = PackedVector2Array()
		_cached_cell_pos.resize(n_cells)
		var pos_x_arr: PackedFloat32Array = map.cell_pos_x_arr
		var pos_y_arr: PackedFloat32Array = map.cell_pos_y_arr
		for i in range(n_cells):
			if has_soa_pos_for_scale:
				_cached_cell_pos[i] = Vector2(pos_x_arr[i], pos_y_arr[i])
			else:
				var cell: HexCell = _field_slice_cells[i]
				_cached_cell_pos[i] = HexUtils.cube_to_world(cell.q, cell.r, _weather_system._hex_size)
		_cached_cell_pos_n = n_cells
		_cached_cell_pos_map_id = map_id
		_cached_cell_pos_hex_size = _field_slice_cell_pos_scale
	_field_slice_cell_pos = _cached_cell_pos
	_weather_system._tick_cell_pos.clear()
	_weather_system._tick_cell_neighbors.clear()

	if not for_worker_knobs_only:
		_field_slice_prev_vapor = PackedFloat32Array()
		_field_slice_prev_precip = PackedFloat32Array()
		_field_slice_next_vapor = PackedFloat32Array()
		_field_slice_next_cloud = PackedFloat32Array()
		_field_slice_next_cloud_water = PackedFloat32Array()
		_field_slice_next_precip = PackedFloat32Array()
		_field_slice_next_instability = PackedFloat32Array()
		_field_slice_next_intensity = PackedFloat32Array()
		_field_slice_next_convergence = PackedFloat32Array()
		_field_slice_next_type = PackedInt32Array()
		_field_slice_prev_vapor.resize(n_cells)
		_field_slice_prev_precip.resize(n_cells)
		_field_slice_next_vapor.resize(n_cells)
		_field_slice_next_cloud.resize(n_cells)
		_field_slice_next_cloud_water.resize(n_cells)
		_field_slice_next_precip.resize(n_cells)
		_field_slice_next_instability.resize(n_cells)
		_field_slice_next_intensity.resize(n_cells)
		_field_slice_next_convergence.resize(n_cells)
		_field_slice_next_type.resize(n_cells)
		var soa_vapor_in: PackedFloat32Array = map.weather_vapor_arr
		var soa_precip_in: PackedFloat32Array = map.weather_precip_arr
		var soa_field_init: PackedByteArray = map.weather_field_init_arr
		var soa_moisture: PackedFloat32Array = _field_slice_moisture_read if _field_slice_moisture_read.size() == n_cells else map.moisture_arr
		for i in range(n_cells):
			if soa_field_init[i] > 0:
				_field_slice_prev_vapor[i] = soa_vapor_in[i]
				_field_slice_prev_precip[i] = soa_precip_in[i]
			else:
				_field_slice_prev_vapor[i] = soa_moisture[i] * 0.15
				_field_slice_prev_precip[i] = 0.0
	var tta_soa: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if tta_soa.size() == n_cells:
		_field_slice_temp_anom = tta_soa
	elif not for_worker_knobs_only:
		_field_slice_temp_anom = PackedFloat32Array()
		_field_slice_temp_anom.resize(n_cells)
		for ti in range(n_cells):
			var tc: HexCell = _field_slice_cells[ti]
			_field_slice_temp_anom[ti] = float(tc.temperature_transport_anomaly)
	# ─── climate-realism Stage1 (2026-06-23): 计算「热赤道」纬度 (norm) ──────
	# 用基准气温找最暖纬带并细化位置，供 Hadley/Ferrel、ITCZ、副热带和风暴轴随季移动。
	# 24 个纬带按格子顺序累加，使用邻带温度做抛物线插值。
	var lat_te_norm: float = 0.5
	var te_bpos_y: float = _weather_system._world_bounds.position.y
	var te_bsize_y: float = _weather_system._world_bounds.size.y
	if not defer_thermal_equator and te_bsize_y > 0.001 \
			and _field_slice_temp_read.size() == n_cells and _field_slice_cell_pos.size() == n_cells:
		const TE_NB := 24
		var te_sum: PackedFloat32Array = PackedFloat32Array(); te_sum.resize(TE_NB)
		var te_cnt: PackedInt32Array = PackedInt32Array(); te_cnt.resize(TE_NB)
		for ci in range(n_cells):
			var nyv: float = clampf((_field_slice_cell_pos[ci].y - te_bpos_y) / te_bsize_y, 0.0, 0.999999)
			var bkt: int = int(nyv * TE_NB)
			te_sum[bkt] += _field_slice_temp_read[ci]
			te_cnt[bkt] += 1
		var best_m: float = -1.0
		var best_b: int = TE_NB / 2
		for bk in range(TE_NB):
			if te_cnt[bk] > 0:
				var m: float = te_sum[bk] / float(te_cnt[bk])
				if m > best_m:
					best_m = m
					best_b = bk
		var bf: float = float(best_b)
		if best_b > 0 and best_b < TE_NB - 1 and te_cnt[best_b - 1] > 0 and te_cnt[best_b + 1] > 0:
			var ml: float = te_sum[best_b - 1] / float(te_cnt[best_b - 1])
			var mr: float = te_sum[best_b + 1] / float(te_cnt[best_b + 1])
			var denom: float = ml - 2.0 * best_m + mr
			if absf(denom) > 1.0e-6:
				bf += clampf(0.5 * (ml - mr) / denom, -0.5, 0.5)
		lat_te_norm = clampf((bf + 0.5) / float(TE_NB), 0.0, 1.0)
	_field_slice_lat_te_norm = lat_te_norm
	if _weather_system._use_gdext_weather_field and _field_slice_fast_indexed \
			and _weather_system._data_core_world_ext != null:
		_field_slice_native_knobs = _weather_system._build_weather_field_knobs(map, world, n_cells, 0, n_cells)


## 切片单步：在 [start_i, end_i) 范围内跑 vapor/cloud/precip 三段式 hot loop。
## 优先走 DCWorldExt C++ range fast path；失败时回退到 GDScript range loop。
func run_slice(cell_budget: int) -> Dictionary:
	return FieldSliceKernel.run_slice(self, cell_budget)


func _ensure_weather_commit_arrays(map: MapData, n_cells: int) -> void:
	FieldSliceCommit._ensure_weather_commit_arrays(self, map, n_cells)

func _weather_commit_visible(map: MapData, n_cells: int, transition_enabled: bool) -> Dictionary:
	return FieldSliceCommit._weather_commit_visible(self, map, n_cells, transition_enabled)

func commit() -> Array[WeatherFront]:
	return FieldSliceCommit.commit(self)


func _upstream_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	# 现在：完全不含自己，仅看上游链，权重从近到远递减，让 vapor 真正随风迁移。
	if _weather_system == null:
		return 0.0
	# 修（v3）：平流只看上游链，避免把 cell 自身重复加权后场面难以移动。
	# 权重从近到远递减，让 vapor 真正随风迁移。
	var current: HexCell = cell
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_weather_system._field_advect_steps):
		var upstream: HexCell = _neighbor_aligned(current, map, -wind_dir)
		if upstream == null:
			break
		sum_v += _weather_system._prev_vapor_cached(upstream, map, prev_vapor) * w_decay
		weight += w_decay
		w_decay *= 0.75
		current = upstream
	if weight < 0.001:
		# 边缘格子无上游：fallback 到自身（避免 0 vapor）
		return _weather_system._prev_vapor_cached(cell, map, prev_vapor)
	return sum_v / weight

func _neighbor_average_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	if _weather_system == null or cell == null:
		return 0.0
	var sum_v: float = _weather_system._prev_vapor_cached(cell, map, prev_vapor)
	var n: int = 1
	for nb: HexCell in _weather_system._cell_neighbors(cell, map):
		if nb == null:
			continue
		sum_v += _weather_system._prev_vapor_cached(nb, map, prev_vapor)
		n += 1
	return sum_v / float(maxi(n, 1))

func _wrapped_delta(a: Vector2, b: Vector2, wrap_width_x: float) -> Vector2:
	var dx: float = b.x - a.x
	if wrap_width_x > 0.001:
		var half: float = wrap_width_x * 0.5
		if dx > half:
			dx -= wrap_width_x
		elif dx < -half:
			dx += wrap_width_x
	return Vector2(dx, b.y - a.y)

func _world_wrap_width_x(map: MapData) -> float:
	if map == null or map.width <= 0 or _weather_system == null:
		return 0.0
	return float(map.width) * sqrt(3.0) * _weather_system._hex_size

func _neighbor_aligned_idx(idx: int, dir: Vector2, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> int:
	if idx < 0 or idx >= cell_pos.size() or dir.length_squared() <= 0.0001:
		return -1
	if _weather_system == null:
		return -1
	var self_wp: Vector2 = cell_pos[idx]
	var best_idx: int = -1
	var best_dot: float = maxf(_field_slice_cell_pos_scale, 0.001) * 0.31176915 # sqrt(3) * 0.18
	var ndir: Vector2 = dir.normalized()
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var to_nb: Vector2 = _wrapped_delta(self_wp, cell_pos[nb_idx], _field_slice_wrap_width_x)
		var dot: float = to_nb.dot(ndir)
		if dot > best_dot:
			best_dot = dot
			best_idx = nb_idx
	return best_idx

func _upstream_vapor_idx_from_first(idx: int, first_upstream_idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	if _weather_system == null:
		return prev_vapor[idx] if idx >= 0 and idx < prev_vapor.size() else 0.0
	if first_upstream_idx < 0 or _weather_system._field_advect_steps <= 0:
		return prev_vapor[idx]
	var current_idx: int = first_upstream_idx
	var sum_v: float = prev_vapor[current_idx]
	var weight: float = 1.0
	var w_decay: float = 0.75
	for step in range(1, _weather_system._field_advect_steps):
		var upstream_idx: int = _neighbor_aligned_idx(current_idx, -wind_dir, cell_pos, neighbor_indices)
		if upstream_idx < 0:
			break
		sum_v += prev_vapor[upstream_idx] * w_decay
		weight += w_decay
		w_decay *= 0.75
		current_idx = upstream_idx
	return sum_v / weight

func _neighbor_average_vapor_idx(idx: int, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array) -> float:
	var sum_v: float = prev_vapor[idx]
	var n: int = 1
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		sum_v += prev_vapor[nb_idx]
		n += 1
	return sum_v / float(n)

## ─── NS 化 Phase 0:六分扇形 barycentric(半拉格朗日终点插值)─────────────
## SAME_SOURCE 数学定义:C++ 镜像 gdext/src/world_ext_internal.h::
## pk_hex_sextant_barycentric()。给定回溯终点 target 与宿主 cell cur,在 cur 与
## 其 1-ring 邻居组成的 6 个扇形三角形 (cur, nb_s, nb_{s+1}) 中寻找包含
## target 的三角形,返回 {i0=cur, i1, i2, w0, w1, w2}。权重 clamp 到 [0,1]
## 且和恒为 1(单调、无 overshoot);邻居缺失的扇形跳过,全部缺失退化为
## (cur,cur,cur,1,0,0)。x 方向按 wrap_period_x 最小映像折叠(≤0.001 不环绕)。
## 静态纯函数:供 physical_circulation_solver.gd(风场镜像动量自平流)与未来
## GDScript 侧 SL 消费复用。
static func hex_sextant_barycentric(cur: int, target: Vector2,
		cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array,
		wrap_period_x: float) -> Dictionary:
	var out: Dictionary = {"i0": cur, "i1": cur, "i2": cur, "w0": 1.0, "w1": 0.0, "w2": 0.0}
	var n_cells: int = cell_pos.size()
	if cur < 0 or cur >= n_cells:
		return out
	var c: Vector2 = cell_pos[cur]
	var dx: float = target.x - c.x
	var dy: float = target.y - c.y
	if wrap_period_x > 0.001:
		var half: float = wrap_period_x * 0.5
		if dx > half:
			dx -= wrap_period_x
		elif dx < -half:
			dx += wrap_period_x
	var base: int = cur * 6
	var best_score: float = -2.0
	var best_a: int = -1
	var best_b: int = -1
	var best_u1: float = 0.0
	var best_u2: float = 0.0
	for s in range(6):
		var a: int = neighbor_indices[base + s]
		var b: int = neighbor_indices[base + ((s + 1) % 6)]
		if a < 0 or a >= n_cells or b < 0 or b >= n_cells:
			continue
		var eax: float = cell_pos[a].x - c.x
		var eay: float = cell_pos[a].y - c.y
		var ebx: float = cell_pos[b].x - c.x
		var eby: float = cell_pos[b].y - c.y
		if wrap_period_x > 0.001:
			var half: float = wrap_period_x * 0.5
			if eax > half:
				eax -= wrap_period_x
			elif eax < -half:
				eax += wrap_period_x
			if ebx > half:
				ebx -= wrap_period_x
			elif ebx < -half:
				ebx += wrap_period_x
		var det: float = eax * eby - eay * ebx
		if det > -1e-7 and det < 1e-7:
			continue
		var inv_det: float = 1.0 / det
		var u1: float = (dx * eby - dy * ebx) * inv_det
		var u2: float = (eax * dy - eay * dx) * inv_det
		if u1 < -1e-4 or u2 < -1e-4:
			continue
		var score: float = 1.0 - u1 - u2
		if score > best_score:
			best_score = score
			best_a = a
			best_b = b
			best_u1 = u1
			best_u2 = u2
			if score >= 0.0:
				break
	if best_a < 0:
		return out
	var c1: float = clampf(best_u1, 0.0, 1.0)
	var c2: float = clampf(best_u2, 0.0, 1.0)
	var c0: float = 1.0 - c1 - c2
	if c0 < 0.0:
		var inv_sum: float = 1.0 / (c1 + c2)
		c1 *= inv_sum
		c2 *= inv_sum
		c0 = 0.0
	out["i1"] = best_a
	out["i2"] = best_b
	out["w0"] = c0
	out["w1"] = c1
	out["w2"] = c2
	return out

func _neighbor_aligned(cell: HexCell, map: MapData, dir: Vector2) -> HexCell:
	if cell == null or dir.length_squared() <= 0.0001:
		return null
	if _weather_system == null:
		return null
	var neighbors: Array = _weather_system._cell_neighbors(cell, map)
	if neighbors.is_empty():
		return null
	var self_wp: Vector2 = _weather_system._cell_world_pos(cell)
	var best: HexCell = null
	var best_dot: float = 0.18
	var ndir: Vector2 = dir.normalized()
	for nb: HexCell in neighbors:
		if nb == null:
			continue
		var nb_wp: Vector2 = _weather_system._cell_world_pos(nb)
		var to_nb: Vector2 = _wrapped_delta(self_wp, nb_wp, _world_wrap_width_x(map))
		if to_nb.length_squared() <= 0.0001:
			continue
		var d: float = to_nb.normalized().dot(ndir)
		if d > best_dot:
			best_dot = d
			best = nb
	return best
# endregion PR-1


# region PR-2 — orographic lift / wind convergence helpers (dots-monolith-split §1.2 / PR-2)
#
# 5 个物理项 helper 已从 weather_system.gd 整体搬迁到 field_solver。weather_system
# 端原同名 `_xxx` 私有方法保留为薄转发；hot loop 内 6 处调用点（line 840/843、
# 1278/1281、1429/1432）保持不变，最终都落到下面的实现。
#
# 依赖（通过 _weather_system 访问）：
#   - _weather_system._cell_neighbors(cell,map): Array   1 环邻居（HexCell）
#   - _weather_system._cell_world_pos(cell)    : Vector2 世界坐标
# 跨 helper 内部调用走 self._neighbor_aligned* 等（同类内的 PR-1 实现）。

func _orographic_lift_for_cell(cell: HexCell, map: MapData, wind_dir: Vector2) -> float:
	return WeatherFieldPhysicsScript.orographic_lift_for_cell(self, cell, map, wind_dir)

func _orographic_lift_from_upstream_idx(idx: int, upstream_idx: int, cells: Array) -> float:
	return WeatherFieldPhysicsScript.orographic_lift_from_upstream_idx(self, idx, upstream_idx, cells)

func _wind_convergence_for_cell(cell: HexCell, map: MapData) -> float:
	return WeatherFieldPhysicsScript.wind_convergence_for_cell(self, cell, map)

func _wind_convergence_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> float:
	return WeatherFieldPhysicsScript.wind_convergence_idx(self, idx, cells, cell_pos, neighbor_indices)

# endregion PR-2


# region PR-3 — ocean anomaly helpers (dots-monolith-split §1.2 / PR-3)
#
# 2 个海洋温度偏移 helper 已从 weather_system.gd 整体搬迁到 field_solver。
# weather_system 端原同名 `_xxx` 私有方法保留为薄转发；hot loop 内 4 处 `_idx`
# 调用点（line 807/1249/1382/1666）与 2 处 cell 版本调用点（line 2760/2773）保持
# 不变，最终都落到下面的实现。
#
# 依赖（通过 _weather_system 访问）：
#   - _weather_system._is_water_terrain(t)     : bool
#   - _weather_system._cell_neighbors(cell,map): Array

func _avg_ocean_anomaly_at_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array) -> float:
	return WeatherFieldPhysicsScript.avg_ocean_anomaly_at_idx(self, idx, cells, neighbor_indices)

func _avg_ocean_anomaly_at(cell: HexCell, map: MapData) -> float:
	return WeatherFieldPhysicsScript.avg_ocean_anomaly_at(self, cell, map)

# endregion PR-3


# region PR-4 — slice state machine fields (dots-monolith-split §1.2 / PR-4)
#
# 22 个 _field_slice_* 切片状态字段已从 weather_system.gd 整体搬迁到 field_solver。
# weather_system 端原 22 个 `var _field_slice_xxx` 字段定义全部删除；所有 184 处
# 访问点（begin_weather_field_solve / run_weather_field_solve_slice /
# commit_weather_field_solve / _clear_weather_field_slice_state 内部读写）改为
# `_field_solver._field_slice_xxx` 形式访问。
#
# 这些字段在 PR-5 / PR-6 把 commit / solve 主体搬过来后会自然变为 self.* 内部访问。
# 当前阶段它们仍被 weather_system 内的 begin / commit / solve 体读写，因此
# 命名保持 `_field_slice_xxx` 不加额外前缀。

var _field_slice_active: bool = false
var _field_slice_map: MapData = null
var _field_slice_world: WorldData = null
var _field_slice_season_idx: int = 0
var _field_slice_climate_anomaly: float = 0.0
var _field_slice_cursor: int = 0
# climate-realism Stage1: 「热赤道」纬度(norm)，begin_slice 按 zonal-max 温度逐 tick 算，omega 项消费。
var _field_slice_lat_te_norm: float = 0.5
var _field_slice_refresh_convergence: bool = false
var _field_slice_cells: Array = []
var _field_slice_cell_pos: PackedVector2Array = PackedVector2Array()
var _field_slice_neighbor_indices: PackedInt32Array = PackedInt32Array()
var _field_slice_fast_indexed: bool = false
var _field_slice_temp_read: PackedFloat32Array = PackedFloat32Array()
var _field_slice_moisture_read: PackedFloat32Array = PackedFloat32Array()
var _field_slice_snow_cover_read: PackedFloat32Array = PackedFloat32Array()
var _field_slice_prev_vapor: PackedFloat32Array = PackedFloat32Array()
var _field_slice_prev_precip: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_vapor: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_cloud: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_cloud_water: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_precip: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_instability: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_intensity: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_convergence: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_type: PackedInt32Array = PackedInt32Array()
var _field_slice_solve_ms: float = 0.0
var _field_slice_last_ms: float = 0.0
var _field_slice_results_in_soa: bool = false
var _field_slice_native_convergence_boost: bool = false
var _field_slice_temp_anom: PackedFloat32Array = PackedFloat32Array()
var _field_slice_native_knobs: Dictionary = {}
var _field_slice_wrap_width_x: float = 0.0
var _field_slice_cell_pos_scale: float = 1.0
var _cached_cell_pos: PackedVector2Array = PackedVector2Array()
var _cached_cell_pos_map_id: int = 0
var _cached_cell_pos_n: int = 0
var _cached_cell_pos_hex_size: float = -1.0
# Stage6c: 对流抑制记忆(per-cell)，跨 slice/tick 持久(不在 begin_slice 重置)。本地状态，非 SoA 组件、不入 CSV。
# 经 knobs "convective_inhib" 以 in/out 传给 C++(ptrw 原地更新，调用后读回)。GDScript fallback 直接读写本数组。
var _convective_inhib: PackedFloat32Array = PackedFloat32Array()
# endregion PR-4
