extends "res://scripts/simulation/sus/sus_job.gd"
class_name WeatherRefreshJob

## WeatherRefreshJob — wraps the daily weather advance + feedback chain
## (MapGenerator.refresh_daily) under a StridePolicy. Single-slice per tick.
##
## Driven by: SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:  StridePolicy(stride). x1→1, x5→4, x20→8 mapped from speed by
##            main.gd._on_speed_changed.
##
## Why a Job instead of a direct call:
##   1. Centralizes stride configuration in SUS (single source of truth).
##   2. Allows future replacement with sliced strategies (e.g. spread the
##      transpiration / albedo passes across multiple ticks) without touching
##      the dispatcher.
##   3. Captures the "active fronts" output via job-local snapshot so the
##      renderer can poll it after SUS.tick() returns.
##
## Note on stride semantics: Legacy refresh_daily had its own internal stride
## counter (`_refresh_daily_call_index`) that returned `_last_active_fronts`
## on skip days. Now SUS.policy gates the call entirely; on gated days the
## Job is not invoked at all and the renderer keeps polling the cached
## fronts from the last unsuppressed run. Behavior equivalent.

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
# Extreme performance mode：weather 避免叠在任何已明显超 1ms 的 climate
# slice 后面。允许最多连续 defer 4 次，防止天气完全饿死。
const _DEFER_AFTER_CLIMATE_SLICE_MS: float = 1.0
const _MAX_CLIMATE_DEFER_STREAK: int = 4

# External references — wired up by MapGenerator at registration time.
var generator = null  # MapGenerator (untyped to avoid circular preload)
var map: MapData = null
var world: WorldData = null
# WorldClock-bound getters; nil-safe at call sites.
var season_index_getter: Callable = Callable()
var season_phase_getter: Callable = Callable()
var climate_anomaly_getter: Callable = Callable()

# Mirrored stride.
var stride: int = 1
# Cached output from the most recent successful run; renderer polls it.
var _last_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
var _last_published_front_signature: String = ""
var _last_published_front_slot_sigs: PackedStringArray = PackedStringArray()
var _last_fronts_diff_report: Dictionary = {}
# Set true on every tick where run_slice actually fired (i.e. policy gate
# passed). Used by main.gd to decide whether to refresh per-cell UI lines.
var ran_this_tick: bool = false
# Drift-fix（2026-05-10）：fronts 数据是否真的在本 tick 更新。
# 历史背景：原 2-tick split 下 ran_this_tick 在 stage_a/stage_b 都为真，但
# _last_fronts 只在 stage_b 翻新——所以引入这个标志区分"slice 跑了"与"fronts 真变了"，
# 以避免在 stage_a tick 让 weather_layer 收到一份未变的 fronts → blend reset → 云冻结。
# Field-slice fix（2026-05-11）：weather field solver 可以跨多 tick 跑。
# fronts_changed 只在 commit + stage_b 完成后置位。保留这个 API 以便：
#   1) main.gd 与 weather_layer 接口语义清晰（"fronts 是否真变了"独立可查）
#   2) 分片期间 renderer 继续使用上一轮完整 fronts，避免半更新。
var _fronts_changed_this_tick: bool = false

# Field solver 分三段：begin 初始化快照，run_slice 只算 N 个 cell，commit 才写回
# HexCell.weather_*、重建 summary fronts 并运行 stage_b。_round_active 表示当前有
# 未完成的天气场 round，should_run 会绕过 stride gate 继续推进下一片。
var _round_active: bool = false
var _round_stage: int = 0
var _round_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
var _climate_defer_streak: int = 0
var _merged_native_first_log_done: bool = false
var _weather_rt_diag_count: int = 0


func _publish_fronts_if_changed(fronts: Array[WeatherFront]) -> bool:
	var slot_sigs: PackedStringArray = _fronts_publish_slot_signatures(fronts)
	var signature: String = "n=%d|%s" % [fronts.size(), "|".join(slot_sigs)]
	var diff: Dictionary = _fronts_signature_diff(_last_published_front_slot_sigs, slot_sigs)
	var changed: bool = signature != _last_published_front_signature
	diff["changed"] = changed
	diff["signature"] = signature
	diff["fronts"] = fronts.size()
	_last_fronts = fronts
	_last_published_front_signature = signature
	_last_published_front_slot_sigs = slot_sigs
	_last_fronts_diff_report = diff
	return changed


func _front_signature(front: WeatherFront) -> String:
	if front == null:
		return "null"
	var axis_v: Vector2 = front.normalized_axis()
	var center_x_bucket: int = roundi(front.center.x / 8.0)
	var center_y_bucket: int = roundi(front.center.y / 8.0)
	var axis_bucket: int = roundi(axis_v.angle() / 0.0872665)
	var radius_bucket: int = roundi(front.radius / 8.0)
	var strength_bucket: int = roundi(clampf(front.intensity, 0.0, 1.0) * 100.0)
	var precip_bucket: int = roundi(clampf(front.precip_amount, 0.0, 1.0) * 100.0)
	var cloud_bucket: int = roundi(clampf(front.cloud_amount, 0.0, 1.0) * 100.0)
	return "%d:%d:%d:%d:%d:%d:%d:%d" % [
		int(front.type),
		center_x_bucket,
		center_y_bucket,
		axis_bucket,
		radius_bucket,
		strength_bucket,
		precip_bucket,
		cloud_bucket,
	]


func _fronts_publish_slot_signatures(fronts: Array[WeatherFront]) -> PackedStringArray:
	var parts: PackedStringArray = PackedStringArray()
	parts.resize(fronts.size())
	for front_index in range(fronts.size()):
		parts[front_index] = _front_signature(fronts[front_index])
	return parts


func _fronts_signature_diff(prev: PackedStringArray, next: PackedStringArray) -> Dictionary:
	var changed_slots: PackedInt32Array = PackedInt32Array()
	var unchanged: int = 0
	var changed: int = 0
	var added: int = 0
	var removed: int = 0
	var max_n: int = maxi(prev.size(), next.size())
	for i in range(max_n):
		var old_sig: String = prev[i] if i < prev.size() else ""
		var new_sig: String = next[i] if i < next.size() else ""
		if old_sig == new_sig:
			unchanged += 1
		else:
			changed_slots.append(i)
			if i >= prev.size():
				added += 1
			elif i >= next.size():
				removed += 1
			else:
				changed += 1
	return {
		"changed_slots": changed_slots,
		"changed_slots_count": changed_slots.size(),
		"unchanged_slots": unchanged,
		"changed_slots_existing": changed,
		"added_slots": added,
		"removed_slots": removed,
	}


func _weather_rt_log(ctx: SusTickContext, stage_name: String, detail: String = "") -> void:
	if _weather_rt_diag_count >= 32:
		return
	if not PKLog.enabled:
		return
	_weather_rt_diag_count += 1
	var suffix: String = ""
	if detail != "":
		suffix = " " + detail
	print("[weather_refresh][RT] #%d tick=%d stage=%s stride=%d round=%s rstage=%d fronts=%d changed=%s%s" % [
		_weather_rt_diag_count, ctx.tick_index, stage_name, stride,
		str(_round_active), _round_stage, _last_fronts.size(),
		str(_fronts_changed_this_tick), suffix,
	])


func _publish_weather_lut_inline(ctx: SusTickContext, report: Dictionary, source: String) -> void:
	if generator == null or not generator.has_method("publish_weather_lut_after_weather_commit"):
		report["weather_lut_reason"] = "missing_publish_facade"
		return
	var t_lut_us: int = Time.get_ticks_usec()
	var lut_report: Dictionary = generator.publish_weather_lut_after_weather_commit(map, world)
	var lut_ms: float = float(Time.get_ticks_usec() - t_lut_us) / 1000.0
	report["weather_lut_ms"] = lut_ms
	report["weather_lut_published"] = bool(lut_report.get("weather_lut_published", false))
	report["weather_lut_changed"] = bool(lut_report.get("weather_lut_changed", false))
	report["weather_lut_reason"] = str(lut_report.get("weather_lut_reason", lut_report.get("reason", "")))
	print("[weather-lut][inline] tick=%d source=%s published=%s changed=%s reason=%s ms=%.3f" % [
		ctx.tick_index if ctx != null else -1,
		source,
		str(report["weather_lut_published"]),
		str(report["weather_lut_changed"]),
		str(report["weather_lut_reason"]),
		lut_ms,
	])


# ─── DataCore: weather component 注册与缓存（Task 8） ───────────────────
# 由 SusScheduler.bind_world → SusJob.bind_world → _on_world_bound 链路触发。
# 注册以下：
#   cell-level component（CELL_WEATHER_INTENSITY/CLOUD/PRECIP/TYPE）—— 已由
#     bind_map_data 自动挂入，本类只缓存 comp_id；
#   front-level component（FRONT_POS_X/Y/VEL_X/Y/KIND/STRENGTH/RADIUS/AGE）——
#     由 World 独立分配；首版以 max_front_count=MAX_FRONTS 一次性预留。
#   archetype WEATHER_FRONT_ARCH 用于 query.with_archetype 过滤。
#
# 注意：本 step 1 仅完成"注册 + 缓存 + 镜像位预留"。step 2 才会让 sub-pass
# 真正通过 query 读写这些 component。在 step 1 期间，WeatherSystem 仍是
# AoS 实例数组的权威，World 中的 front-level component 处于"已注册但内容
# 暂未同步"的状态；ClimateProfile.use_data_core_weather=true 时才开启镜像。

# Cell-level comp_id 缓存
var _comp_cell_intensity: int = -1
var _comp_cell_cloud: int = -1
var _comp_cell_precip: int = -1
var _comp_cell_type: int = -1
# B-full Step-2：weather hot loop view_f32 化新增 6 个缓存
var _comp_cell_weather_vapor: int = -1
var _comp_cell_weather_convergence: int = -1
var _comp_cell_weather_instability: int = -1
var _comp_cell_weather_field_init: int = -1
var _comp_cell_air_mass_temp_anomaly: int = -1
var _comp_cell_has_river: int = -1
# B-full Step-2：weather hot loop 还要读 climate / 慢层 7 个 component；
# 在 _on_world_bound 一并缓存，避免 hot loop 每 tick 反复查 component_id。
var _comp_cell_temp: int = -1
var _comp_cell_moisture: int = -1
var _comp_cell_wind_x: int = -1
var _comp_cell_wind_y: int = -1
var _comp_cell_elevation: int = -1
var _comp_cell_terrain: int = -1
var _comp_cell_snow_cover: int = -1
# Front-level comp_id 缓存（独立于 cell 的 entity 池）
var _comp_front_pos_x: int = -1
var _comp_front_pos_y: int = -1
var _comp_front_vel_x: int = -1
var _comp_front_vel_y: int = -1
var _comp_front_kind: int = -1
var _comp_front_strength: int = -1
var _comp_front_radius: int = -1
var _comp_front_age: int = -1
# archetype id（front-level）
var _arch_weather_front: int = -1
# DataCore 路径状态
var _data_core_components_ready: bool = false
# Front entity 池在 World 全局 entity 空间内的起始 idx 与容量。
# I2.A 改造（2026-05-11）：从"约定式偏移 cell_n + 16"升级为"显式 pool 注册"。
# _pool_id_fronts 由 _on_world_bound 调 world.create_pool 时获得；
# _front_pool_base 在同一时刻缓存自 world.pool_range(_pool_id_fronts).x，
# 后续 hot path 调用方继续读这个字段，零侵入。
const MAX_FRONTS_DC: int = 16  # 与 WeatherSystem.MAX_FRONTS 保持一致
var _pool_id_fronts: int = -1
var _front_pool_base: int = -1
# DOTS-Total-CPP（任务 7）：mock 路径警告限频，避免每天 spam log。
var _sync_fronts_dict_warned: bool = false

# C-01 dirty short-circuit 缓存：上次 sync 的 fronts 数量 + instance_id 异或哈希
# + 内容指纹（pos/vel/intensity/age 加权和），用于跳过未变化的全量同步。
# 适用场景：weather 路径每天 commit 1 次但 fronts 多日才显著变化时，
# sync_fronts_to_world 直接 return，省掉 16×8 个 PackedArray 写。
var _last_sync_n: int = -1
var _last_sync_id_xor: int = 0
var _last_sync_content_hash: float = 0.0

# I2.A.5：ECB pool-aware sync 跟踪集。记录上一轮已在 World 里占据
# entity 槽位的 front（中立仓库于 WeatherSystem._active_fronts）。本轮不在
# active_fronts 中但在 _synced_fronts 中的 → ECB.destroy_in_pool；
# 本轮在 active_fronts 但 world_idx==-1 的 → ECB.create_in_pool 并回写 world_idx。
var _synced_fronts: Array[WeatherFront] = []
# I2.A.5：本次 sync 中 ECB flush 耗时（ms），供调试 / SUS 面板读取。
var _last_flush_ms: float = 0.0

## 由 SUS 在 bind_world 时调用。完成 component / archetype 注册（幂等）。
## 不做行为切换 —— 仅准备 comp_id；实际是否走 DataCore 路径由
## use_data_core_weather 开关在 run_slice 内决定。
func _on_world_bound() -> void:
	if _world == null:
		return
	# Cell-level component：已由 DCWorld.bind_map_data() 注册并挂入 MapData。
	# 这里仅查 comp_id；若 World 尚未 bind_map_data（即 use_data_core=false），
	# comp_id 会是 -1，后续 sub-pass 会自动跳过 DataCore 路径。
	_comp_cell_intensity = _world.component_id(DCComponentIds.CELL_WEATHER_INTENSITY)
	_comp_cell_cloud = _world.component_id(DCComponentIds.CELL_WEATHER_CLOUD)
	_comp_cell_precip = _world.component_id(DCComponentIds.CELL_WEATHER_PRECIP)
	_comp_cell_type = _world.component_id(DCComponentIds.CELL_WEATHER_TYPE)
	# B-full Step-2：6 个新 component（weather 自身）
	_comp_cell_weather_vapor = _world.component_id(DCComponentIds.CELL_WEATHER_VAPOR)
	_comp_cell_weather_convergence = _world.component_id(DCComponentIds.CELL_WEATHER_CONVERGENCE)
	_comp_cell_weather_instability = _world.component_id(DCComponentIds.CELL_WEATHER_INSTABILITY)
	_comp_cell_weather_field_init = _world.component_id(DCComponentIds.CELL_WEATHER_FIELD_INIT)
	_comp_cell_air_mass_temp_anomaly = _world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
	_comp_cell_has_river = _world.component_id(DCComponentIds.CELL_HAS_RIVER)
	# B-full Step-2：weather hot loop 同时读的 climate + 慢层 7 个
	_comp_cell_temp = _world.component_id(DCComponentIds.CELL_TEMP)
	_comp_cell_moisture = _world.component_id(DCComponentIds.CELL_MOISTURE)
	_comp_cell_wind_x = _world.component_id(DCComponentIds.CELL_WIND_X)
	_comp_cell_wind_y = _world.component_id(DCComponentIds.CELL_WIND_Y)
	_comp_cell_elevation = _world.component_id(DCComponentIds.CELL_ELEVATION)
	_comp_cell_terrain = _world.component_id(DCComponentIds.CELL_TERRAIN)
	_comp_cell_snow_cover = _world.component_id(DCComponentIds.CELL_SNOW_COVER)
	# Front-level component：World 独立分配（不依赖 MapData）。track_prev=true
	# 用于 advect 跨 tick 切片时下游读 prev。
	_comp_front_pos_x = _world.register_component(DCComponentIds.FRONT_POS_X, DCComponentIds.F32, 1, true)
	_comp_front_pos_y = _world.register_component(DCComponentIds.FRONT_POS_Y, DCComponentIds.F32, 1, true)
	_comp_front_vel_x = _world.register_component(DCComponentIds.FRONT_VEL_X, DCComponentIds.F32, 1, false)
	_comp_front_vel_y = _world.register_component(DCComponentIds.FRONT_VEL_Y, DCComponentIds.F32, 1, false)
	_comp_front_kind = _world.register_component(DCComponentIds.FRONT_KIND, DCComponentIds.U8, 1, false)
	_comp_front_strength = _world.register_component(DCComponentIds.FRONT_STRENGTH, DCComponentIds.F32, 1, false)
	_comp_front_radius = _world.register_component(DCComponentIds.FRONT_RADIUS, DCComponentIds.F32, 1, false)
	_comp_front_age = _world.register_component(DCComponentIds.FRONT_AGE, DCComponentIds.I32, 1, false)
	# archetype（首版仅为分组标记）
	_arch_weather_front = _world.create_archetype(DCComponentIds.ARCH_WEATHER_FRONT,
		[_comp_front_pos_x, _comp_front_pos_y, _comp_front_vel_x, _comp_front_vel_y,
		 _comp_front_kind, _comp_front_strength, _comp_front_radius, _comp_front_age])
	# Front entity 池：通过 World 显式 Pool API（I2.A）注册。
	# 仅在已 bind_map_data（cells pool 已建好，entity_count = cell_count）的情
	# 况下创建。否则保持 entity_count=0，run_slice 时回退 legacy 路径。
	if _world.is_bound() and _pool_id_fronts < 0:
		_pool_id_fronts = _world.create_pool(DCComponentIds.POOL_WEATHER_FRONTS, MAX_FRONTS_DC)
		var rng: Vector2i = _world.pool_range(_pool_id_fronts)
		_front_pool_base = rng.x
		# I2.A.5：create_pool 内部已将段内所有 entity 的 archetype 预置为
		# ARCH_NONE，这里不再需要手动循环。
	_data_core_components_ready = true


## 是否所有 DataCore 组件都已 ready（cell + front + archetype 全有效）。
## main.gd / generator 可调此函数判断是否真正在 DataCore 路径上跑。
func data_core_ready() -> bool:
	return _data_core_components_ready and _world != null and _world.is_bound() \
		and _comp_cell_intensity >= 0 and _comp_front_pos_x >= 0


## B-full Step-2：6 个新 weather component 是否全部 ready。
## 给 weather_system 的 _is_dc_field_enabled() 做更严格的 gate；
## 任一未挂入则 fallback 到 AoS（避免 view_f32 返回空）。
func data_core_field_ready() -> bool:
	return data_core_ready() \
		and _comp_cell_weather_vapor >= 0 \
		and _comp_cell_weather_convergence >= 0 \
		and _comp_cell_weather_instability >= 0 \
		and _comp_cell_weather_field_init >= 0 \
		and _comp_cell_air_mass_temp_anomaly >= 0 \
		and _comp_cell_has_river >= 0 \
		and _comp_cell_temp >= 0 \
		and _comp_cell_moisture >= 0 \
		and _comp_cell_wind_x >= 0 \
		and _comp_cell_wind_y >= 0 \
		and _comp_cell_elevation >= 0 \
		and _comp_cell_terrain >= 0 \
		and _comp_cell_snow_cover >= 0


## B-full Step-2：把 weather hot loop 需要的所有 view 一次性打包返回。
## weather_system 在 begin / run_slice / commit 入口取一次即可，避免反复查
## comp_id 与重复 view_* 调用。返回字典字段：
##   vapor / convergence / instability ：Packed F32（hot loop 写）
##   field_init                        ：Packed U8（0/1，hot loop 写）
##   intensity / cloud / precip        ：Packed F32（hot loop 写）
##   wtype                             ：Packed U8（hot loop 写）
##   temp / moisture / snow_cover      ：Packed F32（climate pass 写、本路径只读）
##   wind_x / wind_y / elevation       ：Packed F32（地图生成 / climate pass 写、本路径只读）
##   terrain                           ：Packed U8（地图生成期写、本路径只读）
##   air_anomaly                       ：Packed F32（climate pass 写、本路径只读）
##   has_river                         ：Packed U8（地图生成期写、本路径只读）
## 调用方应在 data_core_field_ready() == true 时使用；否则返回空 Dictionary。
func data_core_views() -> Dictionary:
	if not data_core_field_ready():
		return {}
	return {
		# weather hot loop 自己写 / 自己读
		"vapor": _world.view_f32(_comp_cell_weather_vapor),
		"convergence": _world.view_f32(_comp_cell_weather_convergence),
		"instability": _world.view_f32(_comp_cell_weather_instability),
		"field_init": _world.view_u8(_comp_cell_weather_field_init),
		"intensity": _world.view_f32(_comp_cell_intensity),
		"cloud": _world.view_f32(_comp_cell_cloud),
		"precip": _world.view_f32(_comp_cell_precip),
		"wtype": _world.view_u8(_comp_cell_type),
		# climate pass 写、weather hot loop 只读
		"temp": _world.view_f32(_comp_cell_temp),
		"moisture": _world.view_f32(_comp_cell_moisture),
		"snow_cover": _world.view_f32(_comp_cell_snow_cover),
		"air_anomaly": _world.view_f32(_comp_cell_air_mass_temp_anomaly),
		# 地图生成 / climate pass 写、weather hot loop 只读
		"wind_x": _world.view_f32(_comp_cell_wind_x),
		"wind_y": _world.view_f32(_comp_cell_wind_y),
		"elevation": _world.view_f32(_comp_cell_elevation),
		"terrain": _world.view_u8(_comp_cell_terrain),
		"has_river": _world.view_u8(_comp_cell_has_river),
	}


## Front 池起始 idx（World 全局 entity 空间内）。step 2 的 query.with_range
## 用得到。
func front_pool_base() -> int:
	return _front_pool_base


## Front 池容量。
func front_pool_capacity() -> int:
	return MAX_FRONTS_DC


## archetype id。
func weather_front_archetype() -> int:
	return _arch_weather_front


# ─── DataCore: front 镜像同步（step 1 末尾保留接口；step 2 实际写入） ────
# 当 use_data_core_weather=true 时，每个 sub-pass commit 后调用此方法把
# WeatherSystem._active_fronts 同步到 World 中的 front-level component。
# step 1：方法已就位但默认不开启；调用方需确认 data_core_ready() 才调用。
# C-01 优化（2026-05-11）：
#   1) dirty short-circuit：fronts 大小+id 异或+内容指纹三者全等时直接 return；
#   2) 类型分发：在入口判一次首元素是否 WeatherFront，快路径走零反射成员访问；
#   3) archetype assign 仅在 free 段尾巴做差分；
# 目标：常态调用 ≤0.05ms（dirty 短路）/ ≤0.15ms（全量），从原 ~0.4ms 降下。
func sync_fronts_to_world(active_fronts: Array) -> void:
	if not data_core_ready():
		return
	if _front_pool_base < 0:
		return
	var n: int = mini(active_fronts.size(), MAX_FRONTS_DC)

	# C-01.1：dirty 指纹计算（轻量，不进入 PackedArray 写）。
	# 指纹 = n + 前 n 个 front 的 instance_id 异或 + 内容加权和。
	# is_first_object_typed 同时决定后续走哪条 path。
	var id_xor: int = 0
	var content_hash: float = 0.0
	var is_first_object_typed: bool = n > 0 and active_fronts[0] is WeatherFront
	if is_first_object_typed:
		for i in range(n):
			var f: WeatherFront = active_fronts[i]
			if f == null:
				continue
			id_xor ^= f.get_instance_id()
			content_hash += f.center.x + f.velocity.x * 7.31 + f.intensity * 19.7 + float(f.age_days)
	else:
		for i in range(n):
			var f_any = active_fronts[i]
			if f_any == null:
				continue
			if f_any is Object:
				id_xor ^= f_any.get_instance_id()
	if n == _last_sync_n and id_xor == _last_sync_id_xor \
			and absf(content_hash - _last_sync_content_hash) < 1e-4:
		return  # 指纹完全一致 → 跳过本次全量同步
	_last_sync_n = n
	_last_sync_id_xor = id_xor
	_last_sync_content_hash = content_hash

	# C-01.2：类型分发，走特化的快/慢路径
	if is_first_object_typed:
		_sync_fronts_object_path(active_fronts, n)
	else:
		_sync_fronts_dict_path(active_fronts, n)


## C-01.2 强类型快路径：active_fronts 元素全为 WeatherFront 实例（≥99% 情形）。
## 循环内零反射，全部走直接成员访问 + PackedArray index 写入。
##
## I2.A.5：ECB pool-aware。不再用 base + i 顺序占段，而是每个 front 持有
## 自己的 world_idx（由 ECB 从 pool free-list 分配）。上轮在 _synced_fronts
## 但本轮不在的 → destroy_in_pool；本轮新出现且 world_idx==-1 的 → create_in_pool。
## flush 在函数尾调一次，把所有 archetype 变更 + free-list 互访一批处理完。
##
## I3.A.2：写入路径全部改走 _world.write_*（DCWorld / DCWorldExt 双兼容）。
## DCWorldExt 下 view_* 是只读快照（拷贝），原本 `view_*(c)[i] = v` 会静默
## 失效；统一为 write_* 后双路径行为一致。
func _sync_fronts_object_path(active_fronts: Array, n: int) -> void:
	var arch_id: int = _arch_weather_front
	var ecb: DCCommandBuffer = _world.command_buffer()

	# 1) 差分：计算本轮 active 集合（用 instance_id 进 Dictionary，O(n)）
	var active_set: Dictionary = {}
	for i in range(n):
		var f: WeatherFront = active_fronts[i]
		if f != null:
			active_set[f.get_instance_id()] = f

	# 2) destroy：上轮 _synced_fronts 中本轮不在的 → 走 ECB 归还 idx
	for old_f in _synced_fronts:
		if old_f == null:
			continue
		if active_set.has(old_f.get_instance_id()):
			continue
		if old_f.world_idx >= 0:
			ecb.destroy_in_pool(_pool_id_fronts, old_f.world_idx)
			old_f.world_idx = -1

	# 3) create + 写入：本轮所有 front，未分配 idx 的先走 ECB 拿 idx
	for i in range(n):
		var f2: WeatherFront = active_fronts[i]
		if f2 == null:
			continue
		if f2.world_idx < 0:
			var new_idx: int = ecb.create_in_pool(_pool_id_fronts, arch_id)
			if new_idx < 0:
				# free-list 耗尽（front 池满）——跳过该 front 的写入。
				# weather_system 本来有 MAX_FRONTS 守卫，进到这里代表与之不同步。
				continue
			f2.world_idx = new_idx
		var slot_idx: int = f2.world_idx
		_world.write_f32(_comp_front_pos_x, slot_idx, f2.center.x)
		_world.write_f32(_comp_front_pos_y, slot_idx, f2.center.y)
		_world.write_f32(_comp_front_vel_x, slot_idx, f2.velocity.x)
		_world.write_f32(_comp_front_vel_y, slot_idx, f2.velocity.y)
		_world.write_u8(_comp_front_kind, slot_idx, f2.type & 0xFF)
		_world.write_f32(_comp_front_strength, slot_idx, f2.intensity)
		_world.write_f32(_comp_front_radius, slot_idx, f2.radius)
		_world.write_i32(_comp_front_age, slot_idx, f2.age_days)

	# 4) flush ECB（archetype 批处理 + free-list 同步）。计时供调试。
	var t_us0: int = Time.get_ticks_usec()
	_world.flush_command_buffer()
	_last_flush_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 5) 更新跟踪集（浅拷贝 Array 即可，仅记录引用）
	_synced_fronts.clear()
	_synced_fronts.append_array(active_fronts.slice(0, n))


## C-01.2 慢路径：兼容 Dictionary / 历史 alias 字段名（debug / mock 数据）。
## 仅在首元素不是 WeatherFront 实例时才进入；保留原有反射兼容性，不优化。
##
## I2.A.5：mock 路径不走 ECB pool-aware（Dict 没有 world_idx 字段），继续使用
## base+i 顺序占段与直接 assign_archetype。生产路径若误入此分支会被 push_warning 提醒。
func _sync_fronts_dict_path(active_fronts: Array, n: int) -> void:
	# DOTS-Total-CPP（任务 7）：mock 路径警告限频（生产路径误入 → 仅第一次提醒）
	if not _sync_fronts_dict_warned:
		push_warning("[weather_refresh_job] _sync_fronts_dict_path: mock data path; ECB pool-aware path is bypassed. n=%d (subsequent warnings suppressed)" % n)
		_sync_fronts_dict_warned = true
	for i in range(n):
		var f = active_fronts[i]
		if f == null:
			continue
		var slot_idx: int = _front_pool_base + i
		var is_dict: bool = f is Dictionary
		var c_val: Vector2 = Vector2.ZERO
		if is_dict:
			if f.has("center"):
				c_val = f["center"]
			elif f.has("position"):
				c_val = f["position"]
		else:
			if "center" in f:
				c_val = f.center
			elif "position" in f:
				c_val = f.position
		_world.write_f32(_comp_front_pos_x, slot_idx, c_val.x)
		_world.write_f32(_comp_front_pos_y, slot_idx, c_val.y)
		var v_val: Vector2 = Vector2.ZERO
		if is_dict:
			if f.has("velocity"):
				v_val = f["velocity"]
			elif f.has("vel"):
				v_val = f["vel"]
		else:
			if "velocity" in f:
				v_val = f.velocity
			elif "vel" in f:
				v_val = f.vel
		_world.write_f32(_comp_front_vel_x, slot_idx, v_val.x)
		_world.write_f32(_comp_front_vel_y, slot_idx, v_val.y)
		var k_int: int = 0
		if is_dict:
			if f.has("type"):
				k_int = int(f["type"]) & 0xFF
			elif f.has("weather_type"):
				k_int = int(f["weather_type"]) & 0xFF
		else:
			if "type" in f:
				k_int = int(f.type) & 0xFF
			elif "weather_type" in f:
				k_int = int(f.weather_type) & 0xFF
		_world.write_u8(_comp_front_kind, slot_idx, k_int)
		var s_val: float = 0.0
		if is_dict:
			if f.has("intensity"):
				s_val = float(f["intensity"])
			elif f.has("strength"):
				s_val = float(f["strength"])
		else:
			if "intensity" in f:
				s_val = float(f.intensity)
			elif "strength" in f:
				s_val = float(f.strength)
		_world.write_f32(_comp_front_strength, slot_idx, s_val)
		var r_val: float = 0.0
		if is_dict:
			if f.has("radius"):
				r_val = float(f["radius"])
		else:
			if "radius" in f:
				r_val = float(f.radius)
		_world.write_f32(_comp_front_radius, slot_idx, r_val)
		var age_val: int = 0
		if is_dict:
			if f.has("age_days"):
				age_val = int(f["age_days"])
			elif f.has("age"):
				age_val = int(f["age"])
		else:
			if "age_days" in f:
				age_val = int(f.age_days)
			elif "age" in f:
				age_val = int(f.age)
		_world.write_i32(_comp_front_age, slot_idx, age_val)
		_world.assign_archetype(slot_idx, _arch_weather_front)
	var arch_none: int = _world.archetype_none()
	for j in range(n, MAX_FRONTS_DC):
		_world.assign_archetype(_front_pool_base + j, arch_none)


func _init(p_generator, p_map: MapData, p_world: WorldData,
		p_season_index_getter: Callable,
		p_season_phase_getter: Callable,
		p_climate_anomaly_getter: Callable,
		p_stride: int) -> void:
	id = &"weather_refresh"
	priority = 150  # after refresh_climate_daily (100), before ocean_currents (200)
	# Field solver now runs in cell slices; commit slice may add summary/stage_b.
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	# Daily-sim perf bugfix：weather 推进必须每日发生（受 stride 节流），否则
	# 全图天气前沿冻结、降水/温度异常驱动失效。绕过 frame_budget 守卫，避免
	# 因 climate Job 超预算而被 frame_budget_exhausted 全数跳过。
	must_run = false
	generator = p_generator
	map = p_map
	world = p_world
	season_index_getter = p_season_index_getter
	season_phase_getter = p_season_phase_getter
	climate_anomaly_getter = p_climate_anomaly_getter
	stride = max(1, p_stride)
	# Fix #11 (2026-06-15): mobile B 桶错峰 stride=8 phase=4 → tick 4, 12, 20, 28
	# 配套 Fix #11 完整分桶：A sea_ice (s8 p6), B weather+enum (s8 p4),
	# C dyn_visual (s8 p2), D ocean (s8 p0)，climate s2 p1 落奇 tick。
	if OS.has_feature("mobile"):
		stride = 8
		policy = SusPolicyScript.StridePolicy.new(8, 4)
	else:
		policy = SusPolicyScript.StridePolicy.new(stride, 0)
	# Drift-fix（2026-05-10）：原 depends_on=[refresh_climate_daily] 是导致云"几十天才动一次"
	# 的真凶。RefreshClimateDailyJob 是 6-sub-pass 切片（每 tick 一个 sub-pass，整 round 6 游戏日），
	# round 期间 in_flight=true → SUS 把 weather 标 dep_pending 并 skip，所以 weather 实际上每
	# 6+ 游戏日才能跑一次。诊断日志里看到 snap_interval=6-16s 完全对应这个 cadence。
	#
	# 取消硬依赖：weather 读的是 cell.temperature/moisture 等慢层 baseline，即使读到上一日的
	# 值（climate round 还在中间 sub-pass，未来字段尚未写入），1 天差异在天气/降水驱动里
	# 完全不可察——慢层本身的日变化就远小于 weather 自己的 stochastic 项。
	# 副作用：weather 现在每 game day 都跑（stride=1 下），云能流畅平移，与玩家时间感知对齐。
	depends_on = []


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null or world == null:
		return false
	var base_should_run: bool = true if _round_active else super.should_run(ctx)
	if not base_should_run:
		return false
	if _should_defer_after_climate_slice():
		return false
	_climate_defer_streak = 0
	return true


func _should_defer_after_climate_slice() -> bool:
	if generator == null:
		return false
	if not generator.has_method("did_refresh_climate_run_this_tick") \
			or not generator.has_method("last_refresh_climate_slice_ms"):
		return false
	if not bool(generator.did_refresh_climate_run_this_tick()):
		return false
	var climate_ms: float = float(generator.last_refresh_climate_slice_ms())
	if climate_ms < _DEFER_AFTER_CLIMATE_SLICE_MS:
		return false
	if _climate_defer_streak >= _MAX_CLIMATE_DEFER_STREAK:
		return false
	_climate_defer_streak += 1
	return true


## Merged-native gate 结果缓存（一次性 has_method 探测后固定）。
##
## 关键修复（基于 2026-05-18 实测日志）：
## 旧实现每个 SUS slice 都对 DCWorldExt 调 4 次 get_method_list()，每次返回
## 整个类的方法表（数百项）并遍历比对字符串——这是 weather_refresh 日志中
## `unattributed=2.5~2.6ms` 的核心来源。
## 同时旧实现检查的 4 个子方法名 (run_weather_field_solve_pass /
## run_weather_distribute_pass / run_weather_summary_fronts_pass /
## run_stage_b_pass) **未通过 ClassDB::bind_method 注册**（只是 C++ 内部
## helper），所以 gate 实际上永远返回 false，反复付出诊断成本却拿不到收益。
##
## 唯一已 bind 的一体化入口是 DCWorldExt::run_weather_refresh_daily_pass。
## 但现 GDScript 端没有构造其 17+ 项 knobs PackedArray 的 facade，所以现在
## 仍保持 false，直到 generator 暴露 refresh_weather_daily() facade。
## 这里用懒探测 + 永久缓存，把 gate 开销从每 tick 数毫秒降到一次 has_method。
var _merged_native_gate_probed: bool = false
var _merged_native_gate_active: bool = false


func _refresh_merged_native_gate() -> void:
	_merged_native_gate_probed = true
	# Keep the one-shot native transaction opt-in only. The staged field path is
	# the visible weather authority; a method probe for run_weather_refresh_daily_pass
	# is not enough because the combined facade can bypass field commit diagnostics.
	_merged_native_gate_active = false
	if generator == null or not generator.has_method("weather_native_daily_available"):
		return
	_merged_native_gate_active = bool(generator.weather_native_daily_available())


func _should_use_merged_native_weather(can_slice_field: bool) -> bool:
	if _round_active or not can_slice_field:
		return false
	if not _merged_native_gate_probed:
		_refresh_merged_native_gate()
	return _merged_native_gate_active


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world == null:
		ran_this_tick = false
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }

	# Prelude 计时：getter 调用、is_data_core_on 探测、can_slice_field has_method ×4。
	# 历史日志（2026-05-18）显示 unattributed=2.5~2.6ms，将该段独立 instrument
	# 以便后续诊断真凶（getter call 还是 has_method 链）。
	var t_prelude_us: int = Time.get_ticks_usec()
	var season_idx: int = 0
	if season_index_getter.is_valid():
		season_idx = int(season_index_getter.call())
	var season_phase: float = ctx.season_phase
	if season_phase_getter.is_valid():
		season_phase = float(season_phase_getter.call())
	var anomaly: float = 0.0
	if climate_anomaly_getter.is_valid():
		anomaly = float(climate_anomaly_getter.call())

	# C-02.3: 本次 run_slice 中是否启用 DataCore 镜像，仅查一次。
	# 避免两个 commit site 重复查 ClimateProfile 与 data_core_ready。
	var is_data_core_on: bool = _is_data_core_weather_enabled() and data_core_ready()

	var can_slice_field: bool = generator.has_method("weather_uses_field_solver") \
		and bool(generator.weather_uses_field_solver()) \
		and generator.has_method("begin_weather_refresh_stage_a") \
		and generator.has_method("run_weather_refresh_stage_a_slice") \
		and generator.has_method("commit_weather_refresh_stage_a")
	var prelude_ms: float = (Time.get_ticks_usec() - t_prelude_us) / 1000.0
	var timing: Dictionary = {
		"begin_stage_a_ms": 0.0,
		"run_stage_a_slice_ms": 0.0,
		"stage_a_direct_ms": 0.0,
		"commit_stage_a_ms": 0.0,
		"hydrology_discharge_ms": 0.0,
		"stage_b_outer_ms": 0.0,
		"sync_fronts_ms": 0.0,
		"soak_dump_ms": 0.0,
		"prelude_ms": prelude_ms,
	}
	var use_merged_native_weather: bool = _should_use_merged_native_weather(can_slice_field)
	_weather_rt_log(ctx, "entry", "can_slice=%s merged=%s dc=%s prelude=%.3f phase=%.3f" % [
		str(can_slice_field), str(use_merged_native_weather), str(is_data_core_on),
		prelude_ms, season_phase,
	])
	if use_merged_native_weather and not _merged_native_first_log_done:
		_merged_native_first_log_done = true
		print("[weather/native-daily] merged transaction ACTIVE — field/distribute/summary/stage_b run in one SUS slice; legacy sliced path remains fallback")

	# plan/weather-refresh-cpp-all PR-2：合并 facade 快路径。
	#
	# 当 _merged_native_gate_active=true 时，单 SUS slice 调 generator.refresh_weather_daily()
	# 把 5 段 cpp pass 一次跑完。返回的 fronts 与老链 stage_a + stage_b 完全语义一致；
	# 任何前置失败（flag off / ext null / cpp rc!=0）会在 generator.refresh_weather_daily
	# 内部透明 fallback 到 stage_a + stage_b 老链，所以本 job 这里只需关心"成功提交"
	# 后的状态同步：_last_fronts / _round_fronts / DataCore sync / soak dump / SUS timing publish。
	if use_merged_native_weather:
		var t_merged_us: int = Time.get_ticks_usec()
		var merged_fronts: Array[WeatherFront] = generator.refresh_weather_daily(
			map, world, season_idx, anomaly, season_phase
		)
		# 用 stage_a_direct_ms 字段记录合并 path 的总耗时（"direct" 模式 = 单 slice
		# 完成全部，与 fallback 走 stage_a/stage_b 共用同一字段语义；perf overlay
		# 通过 _last_weather_breakdown.path == "gdext_combined" 区分两者）。
		timing["stage_a_direct_ms"] = (Time.get_ticks_usec() - t_merged_us) / 1000.0
		# Stage13b: ψ 推进已内联进 C++ solve pass(每轮 start_idx==0 全场一次)，不再走 GDScript 挂钩。
		_round_fronts = merged_fronts
		_round_active = false
		_round_stage = 0
		ran_this_tick = true
		_fronts_changed_this_tick = _publish_fronts_if_changed(merged_fronts)

		if is_data_core_on and _fronts_changed_this_tick:
			var t_merged_sync_us: int = Time.get_ticks_usec()
			sync_fronts_to_world(merged_fronts)
			timing["sync_fronts_ms"] = (Time.get_ticks_usec() - t_merged_sync_us) / 1000.0
		var t_merged_soak_us: int = Time.get_ticks_usec()
		_soak_dump_weather_phase(ctx, merged_fronts.size())
		timing["soak_dump_ms"] = (Time.get_ticks_usec() - t_merged_soak_us) / 1000.0

		var merged_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		_publish_job_timing(timing, merged_elapsed_ms, "weather_merged")
		var merged_report: Dictionary = {
			"done": true,
			"work_done": merged_fronts.size(),
			"elapsed_ms": merged_elapsed_ms,
			"progress_ratio": 1.0,
			"stage_name": "weather_merged",
			"substage": "fronts_%d" % merged_fronts.size(),
			"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
		}
		merged_report.merge(_last_fronts_diff_report, true)
		_publish_weather_lut_inline(ctx, merged_report, "merged")
		_weather_rt_log(ctx, "merged_done", "elapsed=%.3f changed_slots=%d" % [
			merged_elapsed_ms, int(_last_fronts_diff_report.get("changed_slots_count", 0)),
		])
		return merged_report

	if can_slice_field and not use_merged_native_weather:
		var cell_budget: int = 500
		if generator.has_method("weather_field_slice_cells"):
			cell_budget = int(generator.weather_field_slice_cells())
		var round_cell_count: int = map.cell_count() if map != null and map.has_method("cell_count") else 0
		var same_slice_full_round: bool = round_cell_count > 0 \
				and round_cell_count <= 6400 \
				and cell_budget >= round_cell_count
		if not _round_active:
			var t_begin_us: int = Time.get_ticks_usec()
			generator.begin_weather_refresh_stage_a(map, world, season_idx, anomaly, season_phase)
			timing["begin_stage_a_ms"] = (Time.get_ticks_usec() - t_begin_us) / 1000.0
			_round_active = true
			_round_stage = 1
			_round_fronts = _last_fronts
			var begin_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
			_publish_job_timing(timing, begin_elapsed_ms, "weather_begin")
			_weather_rt_log(ctx, "begin", "elapsed=%.3f dc=%s" % [
				begin_elapsed_ms, str(is_data_core_on),
			])
			if not same_slice_full_round:
				return {
					"done": false,
					"work_done": 0,
					"elapsed_ms": begin_elapsed_ms,
					"progress_ratio": 0.10,
					"stage_name": "weather_begin",
					"substage": "init_round",
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
				}
		var slice_result: Dictionary = {}
		if _round_stage <= 1:
			var t_run_us: int = Time.get_ticks_usec()
			slice_result = generator.run_weather_refresh_stage_a_slice(cell_budget)
			timing["run_stage_a_slice_ms"] = (Time.get_ticks_usec() - t_run_us) / 1000.0
			var slice_done: bool = bool(slice_result.get("done", true))
			var solve_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
			_publish_job_timing(timing, solve_elapsed_ms, "weather_solve")
			if not slice_done:
				_weather_rt_log(ctx, "solve", "elapsed=%.3f work=%d cursor=%d..%d progress=%.3f" % [
					solve_elapsed_ms,
					int(slice_result.get("work_done", 0)),
					int(slice_result.get("cursor_start", -1)),
					int(slice_result.get("cursor_end", -1)),
					float(slice_result.get("progress_ratio", 0.0)),
				])
				return {
					"done": false,
					"work_done": int(slice_result.get("work_done", 0)),
					"elapsed_ms": solve_elapsed_ms,
					"progress_ratio": maxf(0.10, float(slice_result.get("progress_ratio", 0.0))),
					"stage_name": "weather_solve",
					"substage": "cells_%d" % int(slice_result.get("work_done", 0)),
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
					"processed_cells": int(slice_result.get("processed_cells", slice_result.get("work_done", 0))),
					"cursor_start": int(slice_result.get("cursor_start", -1)),
					"cursor_end": int(slice_result.get("cursor_end", -1)),
				}
			_round_stage = 2
			_weather_rt_log(ctx, "solve_done", "elapsed=%.3f work=%d cursor=%d..%d" % [
				solve_elapsed_ms,
				int(slice_result.get("work_done", 0)),
				int(slice_result.get("cursor_start", -1)),
				int(slice_result.get("cursor_end", -1)),
			])
			if not same_slice_full_round:
				return {
					"done": false,
					"work_done": int(slice_result.get("work_done", 0)),
					"elapsed_ms": solve_elapsed_ms,
					"progress_ratio": 0.70,
					"stage_name": "weather_solve",
					"substage": "cells_done",
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
					"processed_cells": int(slice_result.get("processed_cells", slice_result.get("work_done", 0))),
					"cursor_start": int(slice_result.get("cursor_start", -1)),
					"cursor_end": int(slice_result.get("cursor_end", -1)),
				}
		if _round_stage == 2:
			var t_commit_us: int = Time.get_ticks_usec()
			var committed_fronts: Array[WeatherFront] = generator.commit_weather_refresh_stage_a(map, world)
			timing["commit_stage_a_ms"] = (Time.get_ticks_usec() - t_commit_us) / 1000.0
			var summary_lut_report: Dictionary = {}
			_publish_weather_lut_inline(ctx, summary_lut_report, "summary")
			_round_fronts = committed_fronts
			# Stage13b: ψ 推进已内联进 C++ solve pass(每轮 start_idx==0 全场一次)，不再走 GDScript 挂钩。
			_round_stage = 3
			var commit_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
			_publish_job_timing(timing, commit_elapsed_ms, "weather_summary")
			_weather_rt_log(ctx, "summary", "elapsed=%.3f fronts=%d" % [
				commit_elapsed_ms, committed_fronts.size(),
			])
			if not same_slice_full_round:
				return {
					"done": false,
					"work_done": committed_fronts.size(),
					"elapsed_ms": commit_elapsed_ms,
					"progress_ratio": 0.85,
					"stage_name": "weather_summary",
					"substage": "fronts_%d" % committed_fronts.size(),
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
				}
		if _round_stage == 3:
			var hydrology_enabled: bool = generator.has_method("runtime_hydrology_enabled") \
					and bool(generator.runtime_hydrology_enabled())
			if hydrology_enabled:
				var t_hydro_us: int = Time.get_ticks_usec()
				var hydro_report: Dictionary = generator.run_hydrology_discharge_pass_native(map, world)
				timing["hydrology_discharge_ms"] = (Time.get_ticks_usec() - t_hydro_us) / 1000.0
				_round_stage = 4
				var hydro_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
				_publish_job_timing(timing, hydro_elapsed_ms, "hydrology_discharge")
				hydro_report["done"] = false
				hydro_report["elapsed_ms"] = hydro_elapsed_ms
				hydro_report["progress_ratio"] = 0.92
				hydro_report["stage_name"] = "hydrology_discharge"
				hydro_report["substage"] = "route_full"
				_weather_rt_log(ctx, "hydrology", "elapsed=%.3f q95=%.4f qmax=%.4f budget=%.5f" % [
					hydro_elapsed_ms,
					float(hydro_report.get("river_discharge_p95", 0.0)),
					float(hydro_report.get("river_discharge_max", 0.0)),
					float(hydro_report.get("water_budget_error", 0.0)),
				])
				if not same_slice_full_round:
					return hydro_report
			_round_stage = 4
		var t_stage_b_us: int = Time.get_ticks_usec()
		generator.refresh_daily_stage_b(map, world)
		timing["stage_b_outer_ms"] = (Time.get_ticks_usec() - t_stage_b_us) / 1000.0
		var sliced_fronts: Array[WeatherFront] = _round_fronts
		_round_active = false
		_round_stage = 0
		ran_this_tick = true
		_fronts_changed_this_tick = _publish_fronts_if_changed(sliced_fronts)
		# DataCore step 2：正路径 commit 完成，镜像 front 到 World（开关 ON 才生效）。
		# C-02.3：复用 run_slice 入口缓存的 is_data_core_on。
		if is_data_core_on and _fronts_changed_this_tick:
			var t_sync_us: int = Time.get_ticks_usec()
			sync_fronts_to_world(sliced_fronts)
			timing["sync_fronts_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
		var t_soak_us: int = Time.get_ticks_usec()
		_soak_dump_weather_phase(ctx, sliced_fronts.size())
		timing["soak_dump_ms"] = (Time.get_ticks_usec() - t_soak_us) / 1000.0
		var sliced_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		_publish_job_timing(timing, sliced_elapsed_ms, "weather_commit")
		var sliced_report: Dictionary = {
			"done": true,
			"work_done": sliced_fronts.size(),
			"elapsed_ms": sliced_elapsed_ms,
			"progress_ratio": 1.0,
			"stage_name": "weather_commit",
			"substage": "fronts_%d" % sliced_fronts.size(),
			"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
		}
		sliced_report.merge(_last_fronts_diff_report, true)
		_weather_rt_log(ctx, "commit", "elapsed=%.3f changed_slots=%d" % [
			sliced_elapsed_ms, int(_last_fronts_diff_report.get("changed_slots_count", 0)),
		])
		return sliced_report

	var t_direct_a_us: int = Time.get_ticks_usec()
	var fronts: Array[WeatherFront] = generator.refresh_daily_stage_a(map, world, season_idx, anomaly, season_phase)
	timing["stage_a_direct_ms"] = (Time.get_ticks_usec() - t_direct_a_us) / 1000.0
	if generator.has_method("runtime_hydrology_enabled") and bool(generator.runtime_hydrology_enabled()):
		var t_direct_hydro_us: int = Time.get_ticks_usec()
		generator.run_hydrology_discharge_pass_native(map, world)
		timing["hydrology_discharge_ms"] = (Time.get_ticks_usec() - t_direct_hydro_us) / 1000.0
	var t_direct_b_us: int = Time.get_ticks_usec()
	generator.refresh_daily_stage_b(map, world)
	timing["stage_b_outer_ms"] = (Time.get_ticks_usec() - t_direct_b_us) / 1000.0

	_round_fronts = fronts
	# 合并模式不再有"半成品 round"——_round_active 始终为 false。
	_round_active = false
	_round_stage = 0
	ran_this_tick = true
	_fronts_changed_this_tick = _publish_fronts_if_changed(fronts)
	# DataCore step 2：同步镜像。C-02.3：复用 run_slice 入口缓存的 is_data_core_on。
	if is_data_core_on and _fronts_changed_this_tick:
		var t_direct_sync_us: int = Time.get_ticks_usec()
		sync_fronts_to_world(fronts)
		timing["sync_fronts_ms"] = (Time.get_ticks_usec() - t_direct_sync_us) / 1000.0
	var t_direct_soak_us: int = Time.get_ticks_usec()
	_soak_dump_weather_phase(ctx, fronts.size())
	timing["soak_dump_ms"] = (Time.get_ticks_usec() - t_direct_soak_us) / 1000.0
	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	_publish_job_timing(timing, elapsed_ms, "weather_direct")
	var direct_report: Dictionary = {
		"done": true,
		"work_done": fronts.size(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"stage_name": "weather_direct",
		"substage": "fronts_%d" % fronts.size(),
		"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
	}
	direct_report.merge(_last_fronts_diff_report, true)
	_publish_weather_lut_inline(ctx, direct_report, "direct")
	_weather_rt_log(ctx, "direct", "elapsed=%.3f changed_slots=%d" % [
		elapsed_ms, int(_last_fronts_diff_report.get("changed_slots_count", 0)),
	])
	return direct_report


# DCSoakDump（dots-storage-同源紧急修复 2026-05-14）：weather pipeline 末尾把
# 当前 SoA 全字段（含 weather_intensity / cloud / precip 等）追加到 dump，与
# climate phase 行成对，可在 SUMMARY 中按 phase_kind 列分桶 diff。
# is_active() 失败时本函数是 nop。
func _soak_dump_weather_phase(ctx: SusTickContext, fronts_count: int) -> void:
	if DCSoakDump.instance == null or not DCSoakDump.instance.is_active():
		return
	if map == null:
		return
	var sim_day: int = 0
	if generator != null and "_daily_climate_call_count" in generator:
		sim_day = int(generator._daily_climate_call_count)
	var sphase: float = ctx.season_phase
	DCSoakDump.instance.record_tick("weather", sim_day, sphase, map, {"fronts_count": fronts_count})


## Read-only accessor for main.gd; cheap, no SUS state mutation.
func last_fronts() -> Array[WeatherFront]:
	return _last_fronts


func last_fronts_diff_report() -> Dictionary:
	return _last_fronts_diff_report.duplicate(true)


## DataCore step 2：构建一个用于遍历 active front entity 的 query。
## 消费者（未来 visualization / debug / external system）可以调 for_each_index(callback)
## 在 World 中拿到 front-level component view 进行数据访问。
##
## 示例：
##   var q := job.query_active_fronts()
##   var pos_x := world.view_f32(job._comp_front_pos_x)
##   q.for_each_index(func(i): print(pos_x[i]))
func query_active_fronts() -> DCQuery:
	if not data_core_ready():
		return null
	var q: DCQuery = _world.query()
	q.with(_comp_front_pos_x).with(_comp_front_pos_y).with(_comp_front_kind) \
		.with_archetype(_arch_weather_front)
	# I2.A：用 in_pool 取代手算 with_range。
	if _pool_id_fronts >= 0:
		q.in_pool(_pool_id_fronts)
	else:
		q.with_range(_front_pool_base, _front_pool_base + MAX_FRONTS_DC)
	return q.build()


## 内部：use_data_core_weather flag 已删（dots-flag-prune-pr1, 2026-05-22）。
## DataCore weather mirror 现恒走单路径——本 helper 改为返回常量 true，
## 仅在 generator 未就绪时返 false 作为 probe。最终 is_data_core_on 仍由
## data_core_ready() gate（comp_id 缓存就绪后才算真激活）。
func _is_data_core_weather_enabled() -> bool:
	if generator == null:
		return false
	return true


func _publish_job_timing(timing: Dictionary, total_ms: float, stage_name: String = "") -> void:
	timing["job_total_ms"] = total_ms
	if stage_name != "":
		timing["stage_name"] = stage_name
	var accounted_ms: float = 0.0
	for k in [
		"prelude_ms",
		"begin_stage_a_ms",
		"run_stage_a_slice_ms",
		"stage_a_direct_ms",
		"commit_stage_a_ms",
		"hydrology_discharge_ms",
		"stage_b_outer_ms",
		"sync_fronts_ms",
		"soak_dump_ms",
	]:
		accounted_ms += float(timing.get(k, 0.0))
	timing["job_unattributed_ms"] = maxf(0.0, total_ms - accounted_ms)
	if generator != null and generator.has_method("merge_weather_job_breakdown"):
		generator.merge_weather_job_breakdown(timing)


## Was run_slice invoked on the most recent SUS.tick()? Used by main.gd to
## skip per-cell UI line refresh on stride-gated days (matches legacy
## `was_skipped_day` UX).
func did_run_last_tick() -> bool:
	return ran_this_tick


## Drift-fix（2026-05-10）：本 tick 是否真的翻转了 _last_fronts？
## main.gd 用它 gate set_weather_fronts，避免冗余推送触发 weather_layer 的
## blend reset → 云冻结。Frequency-fix 后 stage_a/stage_b 合并，与 ran_this_tick 同步置位。
func did_change_fronts_last_tick() -> bool:
	return _fronts_changed_this_tick


## Called by SUS.tick() at the *start* of each tick wouldn't work (we'd lose
## the prior tick's value). Instead main.gd resets this via reset_run_flag()
## before sus_tick_daily — see MapGenerator.sus_tick_daily for details.
func reset_run_flag() -> void:
	ran_this_tick = false
	# Drift-fix：fronts_changed 也每 tick 入场前清零；run_slice 跑完会重新置位。
	_fronts_changed_this_tick = false


## Allow MapGenerator to retune the stride on the fly (speed_changed callback).
func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


## Map regenerate / SUS-wide reset：清状态字段。
## Frequency-fix 后已无 round 半成品概念，但保留接口与字段一致性。
func reset_progress() -> void:
	super.reset_progress()
	_round_active = false
	_round_stage = 0
	_round_fronts = [] as Array[WeatherFront]
	_last_fronts = [] as Array[WeatherFront]
	_last_published_front_signature = ""
	_last_published_front_slot_sigs = PackedStringArray()
	_last_fronts_diff_report = {}
	_fronts_changed_this_tick = false
	_climate_defer_streak = 0
	_merged_native_first_log_done = false
	_weather_rt_diag_count = 0
	# 强制下一次 run_slice 重新探测 merged-native gate（generator/ext 可能在
	# scene reload 期间被替换或新 facade 被注入；缓存失效后下一 slice 自检即可）。
	_merged_native_gate_probed = false
	_merged_native_gate_active = false
