extends "res://scripts/simulation/sus/sus_job.gd"
class_name WeatherRefreshJob

const WeatherSlices = preload("res://scripts/simulation/sus/jobs/weather_refresh_slices.gd")

const FrontMirror = preload("res://scripts/simulation/sus/jobs/weather_front_mirror.gd")

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
const _SOAK_DUMP_SCRIPT_PATH := "res://scripts/tools/dots_soak_dump.gd"
var _soak_dump_script = null
# Extreme performance mode：weather 避免叠在任何已明显超 1ms 的 climate
# slice 后面。允许最多连续 defer 4 次，防止天气完全饿死。
const _DEFER_AFTER_CLIMATE_SLICE_MS: float = 1.0
const _MAX_CLIMATE_DEFER_STREAK: int = 4

# External references — wired up by MapGenerator at registration time.
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


func _get_soak_dump_instance():
	if _soak_dump_script == null:
		if not ResourceLoader.exists(_SOAK_DUMP_SCRIPT_PATH):
			return null
		_soak_dump_script = load(_SOAK_DUMP_SCRIPT_PATH) as GDScript
	if _soak_dump_script == null:
		return null
	return _soak_dump_script.instance


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
	var native_lut: PackedByteArray = report.get("weather_lut", PackedByteArray())
	var native_changed: bool = bool(report.get("weather_lut_changed", false))
	if native_lut.is_empty() and generator.get("_last_weather_breakdown") != null:
		var last_weather_breakdown: Dictionary = generator._last_weather_breakdown
		native_lut = last_weather_breakdown.get("weather_lut", PackedByteArray())
		native_changed = bool(last_weather_breakdown.get("weather_lut_changed", native_changed))
	var t_lut_us: int = Time.get_ticks_usec()
	var lut_report: Dictionary = generator.publish_weather_lut_after_weather_commit(map, world, native_lut, native_changed)
	var lut_ms: float = float(Time.get_ticks_usec() - t_lut_us) / 1000.0
	report["weather_lut_ms"] = lut_ms
	report["weather_lut_published"] = bool(lut_report.get("weather_lut_published", false))
	report["weather_lut_changed"] = bool(lut_report.get("weather_lut_changed", false))
	report["weather_lut_reason"] = str(lut_report.get("weather_lut_reason", lut_report.get("reason", "")))
	report["weather_lut_dirty_count"] = int(lut_report.get("weather_lut_dirty_count", 0))
	report["weather_lut_full_rebuild"] = bool(lut_report.get("weather_lut_full_rebuild", false))
	print("[weather-lut][inline] tick=%d source=%s published=%s changed=%s dirty=%d full=%s reason=%s ms=%.3f" % [
		ctx.tick_index if ctx != null else -1,
		source,
		str(report["weather_lut_published"]),
		str(report["weather_lut_changed"]),
		int(report["weather_lut_dirty_count"]),
		str(report["weather_lut_full_rebuild"]),
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
	FrontMirror.sync_fronts_to_world(self, active_fronts)


func _sync_fronts_object_path(active_fronts: Array, n: int) -> void:
	FrontMirror._sync_fronts_object_path(self, active_fronts, n)


func _sync_fronts_dict_path(active_fronts: Array, n: int) -> void:
	FrontMirror._sync_fronts_dict_path(self, active_fronts, n)


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
	# B8 唯一写者规则：Climate 在 worker 手上时，主线程 weather 链是一个必须被抑制的
	# 第二写者。它的 field state 在 ACTIVE 下不再被推进/填充，distribute 会把一份
	# 零天气写回 MapData —— 而且时序正好在 worker writeback 之后，于是 worker 当天
	# 算出的天气场被覆盖成零（实测：worker vapor0=0.11，MapData weather_vapor_arr
	# nz=0，pending 的 skipped_fields 里没有任何天气字段）。
	if generator.has_method("climate_authority_suppressed") \
			and bool(generator.climate_authority_suppressed()):
		ran_this_tick = false
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
	return WeatherSlices.run_slice(self, ctx)


# DCSoakDump（dots-storage-同源紧急修复 2026-05-14）：weather pipeline 末尾把
# 当前 SoA 全字段（含 weather_intensity / cloud / precip 等）追加到 dump，与
# climate phase 行成对，可在 SUMMARY 中按 phase_kind 列分桶 diff。
# is_active() 失败时本函数是 nop。
func _soak_dump_weather_phase(ctx: SusTickContext, fronts_count: int) -> void:
	var soak_dump = _get_soak_dump_instance()
	if soak_dump == null or not soak_dump.is_active():
		return
	if map == null:
		return
	var sim_day: int = 0
	if generator != null and generator.has_method("climate_diagnostic_call_count"):
		sim_day = int(generator.climate_diagnostic_call_count())
	var sphase: float = ctx.season_phase
	soak_dump.record_tick("weather", sim_day, sphase, map, {"fronts_count": fronts_count})


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


## Allow MapGenerator to retune the stride/phase on the fly.
func reconfigure(p_stride: int, p_phase: int = 0) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, posmod(p_phase, stride))


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
