extends RefCounted
class_name DCWeatherFrontAdvect

## Phase E.2 / dots-full-migration §Phase E.2：weather front 推进抽出。
##
## **当前状态（2026-05-14, dots-monolith-split 1.1 第 1 步）**：
##   - cyclone wake 扰动已从 [`weather_system.gd::_tick_cyclone_wake`] 搬到本类
##     的 `tick_cyclone_wake(map)`，weather_system 通过 owner 引用读写
##     `ocean_current_perturbation / _active_fronts / _hex_size / _cyclone_wake_days`
##     字段，业务逻辑 bit-equal 不变。
##   - 主 fronts 推进段（advance + decay + reap，含 F.6 C++ 快路径与 GDScript
##     fallback）尚未迁出，仍在 [`weather_system.tick_one_day`] 内联，下个子 PR
##     处理。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## 主入口（在 weather_system.tick_one_day 内联，无独立 _advance_fronts 函数；
## 搬迁时需提取为独立方法）：
##   - tick_one_day 中 "advance fronts" 段（约 line 305-425）：
##     for front in _active_fronts:
##         front.position += front.velocity * dt
##         front.intensity *= front.decay_rate
##         front.age += 1
##         if front.intensity < THRESHOLD or front 出界:
##             移除
##
## 配套 helper：
##   - cyclone wake 扰动 `tick_cyclone_wake(map)`  — ✅ 已搬入本类
##   - 边界/出界判定（搜 `_world_bounds`）
##   - WeatherFront 字段访问（pos / vel / intensity / age / decay_rate）
##
## ─── F.6 C++ 化前置条件 ──────────────────────────────────────────
##
## F.6 weather front advect → C++ 化时本类必须先完成抽出。C++ 端 pass 签名：
##   `run_weather_front_advect_pass(n_fronts: int, dt: float)`
## 读 / 写 FRONT_POS_X/Y/VEL_X/Y/AGE/INTENSITY 6 个 component（已注册到
## DCComponentIds，但目前是镜像；F.6 升为权威）。
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 接受 weather_system owner，从中拿 _active_fronts pool / _world_bounds /
##    _hex_size 等配置；
## 2. 读 cell.wind_vector / has_river 走 ViewAdapter 或 weather_refresh_job
##    的 data_core_views()；
## 3. F.6 之后 fronts 数据从 GDScript Array[WeatherFront] 升级为 World 的 FRONT_*
##    component pool（即真正 entity）。

var _weather_system

func _init(weather_system) -> void:
	_weather_system = weather_system

## 主入口：tick fronts（搬迁后填实现）。
## 当前为 stub；E.2 后由 weather_system.tick_one_day 切换为调用本方法。
func tick(_dt: float) -> void:
	pass

## 取活跃 fronts 列表（owner 仍持权威；F.6 后改读 World pool）。
func active_fronts() -> Array:
	if _weather_system == null:
		return []
	# Future: 提供与 weather_system._active_fronts 相同的语义
	return []

## Systemic Ocean Currents：台风尾迹扰动一日推进。
##
## 行为完全等价于原 [`weather_system._tick_cyclone_wake(map)`]：
##   1) 衰减并淘汰已过期的扰动条目（days_left -= 1，<=0 移除；vec 按比例缩放）。
##   2) 对当前所有 STORM 类 front 中心位于水面 cell 时，注入新的切向扰动向量。
##
## 读 / 写：
##   - owner.ocean_current_perturbation（Dictionary，注入 / 衰减 / 淘汰）
##   - owner._active_fronts（Array[WeatherFront]，只读）
##   - owner._hex_size、owner._cyclone_wake_days（只读配置）
##   - map.get_cell_by_cube(cube)（不修改 cell）
##
## 副作用：仅修改 owner.ocean_current_perturbation。
func tick_cyclone_wake(map) -> void:
	if _weather_system == null or map == null:
		return
	var ocean_current_perturbation: Dictionary = _weather_system.ocean_current_perturbation
	var active_fronts_ref: Array = _weather_system._active_fronts
	var hex_size: float = float(_weather_system._hex_size)
	var cyclone_wake_days: int = int(_weather_system._cyclone_wake_days)

	# 1) 衰减 / 移除
	var to_remove: Array = []
	for key in ocean_current_perturbation.keys():
		var d: Dictionary = ocean_current_perturbation[key]
		var days_left: int = int(d.get("days_left", 0)) - 1
		if days_left <= 0:
			to_remove.append(key)
			continue
		var init_days: int = int(d.get("init_days", cyclone_wake_days))
		var scale: float = float(days_left) / float(maxi(init_days, 1))
		var vec0: Vector2 = d.get("vec_init", d.get("vec", Vector2.ZERO))
		d["days_left"] = days_left
		d["vec"] = vec0 * scale
		ocean_current_perturbation[key] = d
	for key in to_remove:
		ocean_current_perturbation.erase(key)

	# 2) 注入新的扰动（基于当前活跃 front）
	for front in active_fronts_ref:
		if front.type != WeatherType.WT.STORM:
			continue
		if front.intensity < 0.8:
			continue
		# 找 front 中心所在 cell
		var center: Vector2 = front.center
		var cube := HexUtils.world_to_cube(center, hex_size)
		var cell = map.get_cell_by_cube(cube)
		if cell == null:
			continue
		# 仅海面 cell 注入
		if not _is_water_terrain(int(cell.terrain)):
			continue
		# 扰动向量：风向顺时针旋 90° 得切向，按 intensity 缩放到 [-0.6, 0.6] 范围
		var wind: Vector2 = front.velocity
		if wind.length_squared() < 1e-4:
			wind = Vector2(1.0, 0.0)
		var tangent := Vector2(-wind.y, wind.x).normalized()
		var perturb: Vector2 = tangent * float(front.intensity) * 0.6
		var key2: int = cell.q * 10000 + cell.r
		ocean_current_perturbation[key2] = {
			"vec": perturb,
			"vec_init": perturb,
			"days_left": cyclone_wake_days,
			"init_days": cyclone_wake_days,
		}

## fronts 推进 + 回收（dots-monolith-split §1.1 第 2 步）。
##
## 行为完全等价于原 [`weather_system.tick_one_day`] 中 line 305-446 的
## "1) 推进所有 front" + "2) 回收 dead 与出图 front" 内联段：
##   - emergent_coupling 时按 front 中心 cell 预算 decay_mul / precip_bonus
##   - F.6 C++ 快路径（`use_gdext_weather_front` flag + ext.has_method 通过时）
##     批量 advect；rc<0 时透明 fallback
##   - GDScript 主循环：advance_one_day(wind_fn) + 迎风坡 precip 加成
##   - reap：剔除 is_alive() == false 或飘出地图 + bounding_radius() 边界的 front
##
## 入参：
##   - map: MapData    用于 emergent_coupling / cube → cell 反查
##   - wind_fn: Callable  weather_system 一次性构造的风采样闭包
##
## 读 / 写 owner（_weather_system）字段：
##   - 读 + 写：_active_fronts、_gdext_front_runs/_fallbacks/_total_ms/
##              _first_attempt_logged/_signature_checked/_signature_ok
##   - 读：_emergent_coupling、_hex_size、_world_bounds、_data_core_world_ext、
##         _cp_for_front_flag
##   - 调用 owner 方法：_front_decay_modifier、_front_orographic_precip_bonus
##
## 返回 advance 段的 ms 耗时（与原内联段 `var advance_ms` 语义一致）。
func tick_advance_fronts(map, wind_fn: Callable) -> float:
	if _weather_system == null:
		return 0.0
	var ws = _weather_system
	var t_us0: int = Time.get_ticks_usec()

	# 1) 推进所有 front
	# Emergent Climate Coupling：推进前先按 front 当前中心 cell 的 local 状态
	# 临时缩放本日衰减。类型与本地温湿带匹配 → ×0.7（长寿命）；
	# 不匹配 → ×1.5（更快耗尽）。缩放只影响本次 advance_one_day 的 decay 消耗。
	# 不持久化到 front.decay_per_day 自身，避免跨日连锁放大。
	#
	# ─── Phase F.6：DCWorldExt fronts advect C++ 快路径 ─────────────────
	# 触发条件：cp.use_gdext_weather_front == true + ext != null + has_method
	#         + active_fronts 不空。任一不满足走 GDScript fallback。
	#
	# 设计：emergent_coupling 的 decay_mul / precip_bonus 仍由 GDScript 预算
	# （需要 map 查询）；C++ 端只接 batch advect 主循环（旋转 / center += vel /
	# decay / age++ / refresh_visual_lifecycle）。wind_fn 采样在 GDScript 端
	# 一次性 pre-compute 成 PackedVector2Array 传 C++。
	var f6_did_fast_path: bool = false
	var f6_active_fronts_size: int = ws._active_fronts.size()
	var f6_flag_on: bool = false
	if ws._cp_for_front_flag != null and "use_gdext_weather_front" in ws._cp_for_front_flag:
		f6_flag_on = bool(ws._cp_for_front_flag.use_gdext_weather_front)
	if f6_active_fronts_size > 0 and f6_flag_on \
			and ws._data_core_world_ext != null \
			and ws._data_core_world_ext.has_method("run_weather_front_advect_pass"):
		# 一次性诊断
		if not ws._gdext_front_first_attempt_logged:
			ws._gdext_front_first_attempt_logged = true
			print("[front/F.6] first attempt: n_active_fronts=%d flag=%s ext_ok=%s" % [
				f6_active_fronts_size, str(f6_flag_on), str(ws._data_core_world_ext != null),
			])
		if not ws._gdext_front_signature_checked:
			ws._gdext_front_signature_checked = true
			var ml: Array = ws._data_core_world_ext.get_method_list()
			for m: Dictionary in ml:
				if String(m.get("name", "")) == "run_weather_front_advect_pass":
					var args: Array = m.get("args", [])
					ws._gdext_front_signature_ok = (args.size() == 1)
					if not ws._gdext_front_signature_ok:
						push_warning("[gdext sig] run_weather_front_advect_pass has %d args (expected 1); .dll STALE — REBUILD gdext" % args.size())
					break
			print("[front/F.6] sig probe = %s（仅作诊断，不阻止下方调用）" % str(ws._gdext_front_signature_ok))

		# Phase 1: GDScript 预算 decay_mul / precip_bonus / wind_per_front
		var saved_decays: PackedFloat32Array = PackedFloat32Array()
		saved_decays.resize(f6_active_fronts_size)
		var precip_bonuses: PackedFloat32Array = PackedFloat32Array()
		precip_bonuses.resize(f6_active_fronts_size)
		var wind_per_front: PackedVector2Array = PackedVector2Array()
		wind_per_front.resize(f6_active_fronts_size)
		for i_f6 in range(f6_active_fronts_size):
			var f_f6: WeatherFront = ws._active_fronts[i_f6]
			saved_decays[i_f6] = f_f6.decay_per_day
			var decay_mul_f6: float = 1.0
			var precip_bonus_f6: float = 0.0
			if ws._emergent_coupling and map != null:
				var cube_f6 := HexUtils.world_to_cube(f_f6.center, float(ws._hex_size))
				var at_cell_f6: HexCell = map.get_cell_by_cube(cube_f6)
				if at_cell_f6 != null:
					decay_mul_f6 = ws._front_decay_modifier(f_f6, at_cell_f6)
					precip_bonus_f6 = ws._front_orographic_precip_bonus(f_f6, at_cell_f6, map)
			# 临时改 decay_per_day（C++ 端会读这个值）
			f_f6.decay_per_day = saved_decays[i_f6] * decay_mul_f6
			precip_bonuses[i_f6] = precip_bonus_f6
			# Wind sample（callable 是合法的；这里在 fast-path 之外的 callable 也 OK）
			if wind_fn.is_valid():
				wind_per_front[i_f6] = wind_fn.call(f_f6.center) as Vector2
			else:
				wind_per_front[i_f6] = Vector2.ZERO

		# Phase 2: pack + invoke C++
		var batch: Dictionary = WeatherFront.pack_into_dict(ws._active_fronts)
		batch["wind_per_front"] = wind_per_front
		batch["max_axis_turn_rad"] = 0.383972  # 与 weather_front.gd::_MAX_AXIS_TURN_RADIANS 一致
		var rc_f6: float = float(ws._data_core_world_ext.run_weather_front_advect_pass(batch))

		if ws._gdext_front_runs + ws._gdext_front_fallbacks < 3:
			print("[front/F.6] DEBUG call#%d: rc=%.4f n_active=%d emergent=%s" % [
				ws._gdext_front_runs + ws._gdext_front_fallbacks + 1,
				rc_f6, f6_active_fronts_size, str(ws._emergent_coupling),
			])

		if rc_f6 >= 0.0:
			# Phase 3: apply batch back to OOP fronts + 恢复 decay + 应用 precip_bonus
			WeatherFront.apply_dict_to_fronts(batch, ws._active_fronts)
			for i_f6r in range(f6_active_fronts_size):
				var f_f6r: WeatherFront = ws._active_fronts[i_f6r]
				f_f6r.decay_per_day = saved_decays[i_f6r]  # 恢复（不持久化 emergent decay_mul）
				var pb: float = precip_bonuses[i_f6r]
				if pb > 0.0:
					f_f6r.precip_amount = clampf(f_f6r.precip_amount + pb, 0.0, 1.0)

			ws._gdext_front_runs += 1
			ws._gdext_front_total_ms += rc_f6
			if ws._gdext_front_runs == 1:
				print("[front/F.6] gdext path ACTIVE — first run elapsed=%.3fms (legacy GDScript baseline ≈ 3.0ms; charter §7 target < 0.5ms)" % rc_f6)
			f6_did_fast_path = true
		else:
			# rc<0：恢复 decay（不能保留 emergent 缩放进 fallback，否则 GDScript 路径再次乘）
			for i_f6e in range(f6_active_fronts_size):
				(ws._active_fronts[i_f6e] as WeatherFront).decay_per_day = saved_decays[i_f6e]
			ws._gdext_front_fallbacks += 1
			# fall through 到 GDScript advect 循环（重新走 emergent 评估）

	if not f6_did_fast_path:
		for front in ws._active_fronts:
			var decay_mul: float = 1.0
			var precip_bonus: float = 0.0
			if ws._emergent_coupling and map != null:
				var cube := HexUtils.world_to_cube(front.center, float(ws._hex_size))
				var at_cell: HexCell = map.get_cell_by_cube(cube)
				if at_cell != null:
					decay_mul = ws._front_decay_modifier(front, at_cell)
					precip_bonus = ws._front_orographic_precip_bonus(front, at_cell, map)
			var saved_decay: float = front.decay_per_day
			front.decay_per_day = saved_decay * decay_mul
			front.advance_one_day(wind_fn)
			front.decay_per_day = saved_decay
			# 推进后如果地形给出迎风坡加成：把本日 precip_amount 拉高（视觉 + 后续分发用）
			if precip_bonus > 0.0:
				front.precip_amount = clampf(front.precip_amount + precip_bonus, 0.0, 1.0)

	# 2) 回收 dead 与出图 front
	var alive: Array[WeatherFront] = []
	for front in ws._active_fronts:
		if not front.is_alive():
			continue
		# 飘出地图边界 + 1 倍 radius 也算出图
		if not ws._world_bounds.grow(front.bounding_radius()).has_point(front.center):
			continue
		alive.append(front)
	ws._active_fronts = alive
	return (Time.get_ticks_usec() - t_us0) / 1000.0

static func _is_water_terrain(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE \
			or t == TerrainType.TERRAIN.LAKE

func describe() -> String:
	return "DCWeatherFrontAdvect(owner=%s)" % ("ws" if _weather_system != null else "(null)")
