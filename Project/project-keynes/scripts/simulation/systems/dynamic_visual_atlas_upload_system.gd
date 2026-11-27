extends DCSystem
class_name DynamicVisualAtlasUploadSystem

const AtlasNativeCommit = preload("res://scripts/simulation/systems/dynamic_atlas_native_commit.gd")

const AtlasStride = preload("res://scripts/simulation/systems/dynamic_atlas_stride.gd")

const AtlasTick = preload("res://scripts/simulation/systems/dynamic_atlas_tick.gd")

const DynamicVisualAtlasUploadHelpers = preload("res://scripts/simulation/systems/dynamic_visual_atlas_upload_helpers.gd")

## Updates low-frequency visual atlases used by the main map shader.
##
## Stride=1 default：每个仿真日跑一次（StridePolicy 控制），保持温度/雪/海冰视觉同步。
## Weather LUT 已并入 weather_refresh commit path，提交天气字段时同步生成并发布。
##
## v3：湿迹/龟裂短期痕迹视觉已删除；本系统只更新 dynamic/ecology/smooth/ice 四类视觉 atlas。
## 回退：`enable_time_slicing = false` 走 one-shot 路径。
##
## 2026-05-19 plan/dirty-push-atlas-encode 阶段 D：
##   入口 `_start_new_stride()` 调 `world.read_and_clear_dirty_mask()` 一次性
##   拿到本 stride 的 dirty cell 列表，缓存到 `_stride_dirty_cells`。dynamic_cell
##   / ice_state 两个 phase 走 dirty 子集（这两张 atlas 不依赖邻居 / 衰减状态）；
##   ecology / smooth 两个 phase 暂走 `map.all_cells()`，等阶段 E 引入
##   active_decay_set / 1 跳邻居膨胀后再切。
##
## 兼容性：
##   - dirty_push_enabled flag 关闭 → 全部 phase 走 all_cells（旧行为）
##   - world == null / mask 为空 → 同上
##   - DCWorld 未挂 use_data_core / use_hexcell_facade → mask 一直为空 → 自动 fallback
##
## 2026-05-20 plan/atlas-pipeline-cpp（全量 DOTS 化）：
##   新增 `cpp_atlas_pipeline_enabled` flag（默认 true）。开启时 tick 入口直接
##   调 `world_ext.run_atlas_pipeline_step(opts)`，C++ 端一次性完成 4 phase
##   （dirty 消费 + value-diff via prev_sigs + 1 跳膨胀 + 4 atlas encode），返回
##   `atlas_buffers` 字典（dyn/eco/smo/ice 四份 PackedByteArray），GD 端只做
##   `Image.create_from_data + ImageTexture.update`。flag=false 时回退到旧
##   4-phase 状态机 + map_baker chunk_begin/step/finalize 路径。
##
##   迁移覆盖：旧 `_step_phase_baker` / `_baker_callables` / 12 个 phase ms
##   累加器仍保留以服务 fallback 路径与旧 dashboard；新路径用 `_last_breakdown`
##   接收 C++ 返回的 `ms_breakdown` Dict，保持采样窗口与 print 格式不变。
##
##   ecology 持久状态 burn-in：首次以 cpp 路径成功跑通时调
##   `world_ext.migrate_eco_persistent_from_gd(state)`，把 baker 端
##   `_eco_active_decay_set / _eco_transition_age_arr` 一次性灌过去；之后
##   完全由 C++ 端 AtlasPipelineState 维护。

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const FeatureFlagsScript = preload("res://scripts/data_core/feature_flags.gd")
const BakerDirtyHelpersScript = preload("res://scripts/rendering/bakers/baker_dirty_helpers.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")


# ─── Phase 编号 ───────────────────────────────────────────────────────────────
const PHASE_IDLE: int = 0
const PHASE_DYNAMIC: int = 1
const PHASE_ECOLOGY: int = 2
const PHASE_SMOOTH: int = 3
# DEPRECATED(plan-A sea-ice-render-source-unify): kept for non-water shaders（hillshade_tod /
# weather_overlay 仍引用 ice_state_atlas 兼容通道），will be removed in plan-C 任务 10
# 之后（届时所有消费方迁移到 dyn_atlas_smooth.A 或退出 ice_state_atlas）。
const PHASE_ICE: int = 4
const PHASE_DONE: int = 5

# 单 tick 最多扫多少 cell（跨 phase 共享预算的"软上限"）。
# 2026-05-19 方案 B：从 500 → 4096，单 tick 直接扫完一个 phase 的全部 cells，
# 避免 4 phase × 多 tick 串行导致雪量响应延迟数十仿真日。
# 实际 dirty 少时 chunk_step 走 sig 比对快速 skip，远未达上限就 phase 结束。
const MAX_CELLS_PER_TICK: int = 4096
const TIME_CHECK_CELLS_PER_STEP: int = 128
# [perf 2026-05-20] 方案 A：CPP 路径从 512 → 4096。
# 原因：512 把 2400-cell 全图人为切成 5 段，每段都付一次 GD→C++ 反射调用 +
# _pack_csr_for_cells 打包 + Variant/Dict marshalling 税（5 段 × 4 phase = 20 次/stride）。
# 实测 max_tick_ms 18-22ms 主要来自这个调度开销，而非 C++ 真实算力（< 0.5ms）。
# 放大到 4096 后单 phase 单次 baker.call 吃完全图（4 次/stride），并且 CSR 在
# cache 友好的连续段上拼接更快。GD fallback 路径仍保留 128 上限以保护时间预算。
const CPP_TIME_CHECK_CELLS_PER_STEP: int = 4096

# Soft budget = slice_budget_ms × 这个倍数，超出则 break 让出。

# ─── plan/atlas-phase-slicing（2026-05-21）：CPP pipeline phase 切片预算 ───
# 默认 4 = 单 tick 一气呵成，dyn/eco/smooth/ice 同一轮产出并提交。
# 调低到 1 = 每 tick 推 1 phase，4 个 phase 拆到 4 个 tick（严格预算/诊断用）。
# 配合 C++ AtlasPipelineState 跨 call 持有 stride snapshot（dirty/cache/nb_arr/prep_*），
# 仅在 stride 起点传 dirty_indices；mid-stride tick 跳过 commit GPU。
const CPP_PIPELINE_PHASE_BUDGET: int = 4
# C++ smooth phase 内部再按 cell cursor 切片，避免 dirty/full sweep 时单次 2ms+。
const CPP_SMOOTH_CELLS_PER_CALL: int = 512
const LUT_DENSE_DIRTY_MIN_CELLS: int = 64
const LUT_DENSE_DIRTY_RATIO: float = 0.25
# C++ 计算完成后，GPU texture commit 仍必须走主线程。一次 stride 可能同时
# 产出 dyn/eco/smo/ice 多张 atlas；这里把它们排成队列。
# 修复（2026-05-26）：原值=1 会导致 4 张 atlas 跨 4 个 tick 才上传完成，
# 叠加 stride 本身的 4-phase 推进 + 频繁的 frame_budget_exhausted，
# 实测一次完整渲染更新需要 100+ 帧。提到 4 后 stride_done 那帧立即把 4 张
# 全部 drain 上传；单张 ImageTexture.update ~0.3-0.5ms，4 张 ≤ 2ms，仍在
# upload budget(1.5ms 软阈值) 边界范围内，超出由 SUS 自然在下一帧回归。
#
# 修复（2026-06-13，android 性能）：实测 Adreno 830 上 4 张 1024×606 atlas
# 单 tick drain spike 12-55ms，吃掉两帧 vsync。改成移动端 1 张/tick，4 张分到
# 4 tick；配合 stride=2，整体视觉延迟从 1-2 day → ~4 day，肉眼可接受。配合
# HM_MAX_DIM_MOBILE=512 后单张 atlas 0.6MB（vs 桌面 2.4MB），单 tick commit
# 实测 < 5ms，回到单帧预算内。

const SOFT_BUDGET_MULTIPLIER: float = 2.0

const CPP_COMMIT_TEXTURES_PER_TICK_DESKTOP: int = 4
const CPP_COMMIT_TEXTURES_PER_TICK_MOBILE: int = 1

static func _cpp_commit_textures_per_tick() -> int:
	return CPP_COMMIT_TEXTURES_PER_TICK_MOBILE if OS.has_feature("mobile") else CPP_COMMIT_TEXTURES_PER_TICK_DESKTOP

# 兼容：保留旧名，值=桌面默认。真正分流由 _cpp_commit_textures_per_tick()。
# fallback GDScript smooth dirty/prep 子阶段预算：把 merge / one-hop dilation
# 拆出 baker prepare，避免极端 dirty/full sweep 在单 tick 内完成全部预处理。
const SMOOTH_PREP_CELLS_PER_TICK: int = 512

var baker: MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null
var dirty_world = null
var world_ext = null

# [perf 2026-05-20] 方案 C：Callable 缓存。
# 原因：_step_phase_baker 在 hot loop 内每帧 20+ 次 `baker.call("xxx_chunk_step", ...)`,
# 字符串路径每次走 ObjectDB method-name lookup（dict hash + StringName intern）。
# 改用 baker_key → {begin/step/finalize: Callable} 的预解析表，命中直接 .call(...) 省 lookup 税。
# init 阶段 baker 不会变，Callable 永久有效；baker == null 时表为空，fallback 走旧 baker.call 路径。
var _baker_callables: Dictionary = {}   # baker_key (String) -> {"begin": Callable, "step": Callable, "finalize": Callable}
var stride: int = 2
# plan/dirty-push-atlas-encode 阶段 D：dirty mask 消费方需要拿到 ClimateProfile
# 才能在 hot path 内调 DCFeatureFlags.is_on(&"dirty_push_enabled", cp)。
# 构造时可不传（默认 null），此时 flag 视为 false → 走 all_cells 老路径（向后兼容）。
var climate_profile = null

# 紧急回退开关：false 时走原 one-shot 路径，phase 字段不使用。
var enable_time_slicing: bool = true

# ─── 状态机字段 ───────────────────────────────────────────────────────────────
var _phase: int = PHASE_IDLE
var _phase_cursor: int = 0
var _phase_cells: Array = []          # 当前 phase 入口快照的 cell 序列
var _phase_ctx: Dictionary = {}        # 当前 baker chunk 的 ctx
var _phase_report: Dictionary = {}     # 当前 baker chunk 的局部 report
var _aggregated_report: Dictionary = {}  # 跨 phase 累计；stride 结束 tick 一次性回报
var _total_ticks_used: int = 0         # 本 stride 跨了多少 tick（含起始 tick）

# plan/dirty-push-atlas-encode 阶段 D：本 stride 由 sim 推送积累的 dirty cells
# 列表。在 _start_new_stride() 入口调 world_data.read_and_clear_dirty_mask() 拿到。
# - PackedInt32Array：cell.index 列表（原子读+清零 保证下 stride 不漏不重）
# - 空数组：mask flag 关闭 / DCWorld 未 bind / 上 stride 完后无新 dirty → fallback all_cells
var _stride_dirty_indices: PackedInt32Array = PackedInt32Array()
var _stride_dirty_cells: Array = []           # 反查后的 HexCell 列表（dynamic/ice phase 用）
var _stride_dirty_path_used: bool = false     # 诊断：本 stride 是否走了 mask 路径（影响 report）
var _stride_dirty_noop: bool = false
var _stride_dirty_reason: String = ""

# dyn_atlas_smooth fallback dirty/prep 状态机。
# 阶段：merge_seed → dilate_mark → collect_sorted，完成后 _phase_cells 才交给 baker chunk_step。
var _smooth_prep_state: Dictionary = {}
var _smooth_prep_generation: int = 0
var _smooth_prep_abort_count: int = 0
var _smooth_prep_equiv_checks: int = 0
var _smooth_prep_equiv_failures: int = 0

# 诊断采样（沿用 _wf_diag_* 风格）。
var _dvas_diag_stride_count: int = 0
var _dvas_diag_ticks_accum: int = 0
var _dvas_diag_max_tick_ms: float = 0.0
var _dvas_diag_avg_window: int = 30
# [DIAG 2026-05-23 四轮] 海冰看似不动排障：跟踪 ice 通道实际 commit / skip 次数。
var _dvas_ice_commit_runs: int = 0
var _last_breakdown: Dictionary = {}
var _lut_dense_fallback_count: int = 0

# Perf instrumentation freshness（方案 ④ Step 1）：generator 在每个 fast tick 顶部
# 通过 set_current_fast_tick_idx 把当前 _fast_tick_count 同步进来。所有
# `_last_breakdown = report.duplicate(...)` 的写入点会立刻把它打到字典内的
# `_tick_idx` 字段；perf_recorder 比对 row.tick_idx ≠ dict._tick_idx 时跳过整组
# 字段，避免 305 行重复值假象。
var current_fast_tick_idx: int = 0

# [diag 2026-05-20 phase-breakdown] 窗口内累加每 phase 的 prepare/step/finalize ms 总和，
# 用于回答"max_tick_ms 那 ~20ms 到底花在哪个 phase 哪个阶段"。
# stride 完成时把 _aggregated_report 的 *_ms 字段累计进来，print 时除以 stride_count 得均值。
var _dvas_diag_phase_ms_accum: Dictionary = {
	"dynamic_prepare_ms": 0.0, "dynamic_step_ms": 0.0, "dynamic_finalize_ms": 0.0,
	"ecology_prepare_ms": 0.0, "ecology_step_ms": 0.0, "ecology_finalize_ms": 0.0,
	"smooth_prepare_ms": 0.0, "smooth_step_ms": 0.0, "smooth_finalize_ms": 0.0,
	"ice_prepare_ms": 0.0, "ice_step_ms": 0.0, "ice_finalize_ms": 0.0,
}

# ─── plan/atlas-pipeline-cpp 薄壳路径状态 ────────────────────────────────
# _eco_burnin_done：首次成功调用 run_atlas_pipeline_step 之前，
# 是否已经把 GD 端 ecology 持久状态（map_baker._eco_active_decay_set /
# _eco_transition_age_arr）一次性迁移到 C++ AtlasPipelineState。
# 之后由 C++ 端独立维护，无需再读 GD 端 baker 状态。
# 地图重生成（discard_all_buffers / bake_world）时由 invalidate_atlas_csr_cache
# 旁路触发再次 burn-in（_eco_burnin_done 由 baker 通知或本系统在
# `_pending_burnin = true` 时触发）。
var _eco_burnin_done: bool = false
var _pending_burnin: bool = false
var _cpp_pipeline_warned_no_world: bool = false  # 一次性 push_warning
# plan/atlas-phase-slicing 诊断（2026-05-21）：cpp_pipeline 返回 fallback=true 时
# 暂存 reason，在 _tick_oneshot 写进 report，让 perf CSV 直接看出原因。
var _pending_fallback_reason: String = ""

# plan/atlas-phase-slicing：mid-stride 跟踪。true = 上一 tick C++ 返回 done=false，
# 本 tick 应跳过 dirty 重读 + burn-in，直接 call 让 C++ 推下一个 phase。
# done=true 时翻回 false，下一 tick 重新启动一个 stride。
var _cpp_stride_in_progress: bool = false
var _cpp_commit_queue: Array = []
var _cpp_commit_context: Dictionary = {}
var _cpp_commit_skip_count: int = 0

var _lut_refresh_pending: bool = false
var _lut_last_refresh_tick: int = -1
var _lut_last_due_tick: int = -1
var _lut_last_environment_generation: int = -1
var _lut_stride: int = 1
var _lut_phase: int = 0
var _lut_pending_before_tick: bool = false
var _lut_catchup_tick: bool = false


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData,
		p_stride: int = 1, p_climate_profile = null, p_dirty_world = null,
		p_world_ext = null) -> void:
	id = &"dynamic_visual_atlas_upload"
	priority = 250
	use_job_should_run = true
	# 2026-05-19 方案 B：默认 budget 从 0.45 → 1.5ms，配合 MAX_CELLS_PER_TICK=4096
	# 让一个 phase 在单 tick 内扫完。仍可被 climate_profile.sim_upload_slice_budget_ms 覆盖。
	slice_budget_ms = 1.5
	max_slices_per_tick = 1
	# Fix #8B 已回退 (2026-06-15 v2)：must_run=true 是"绕过预算"而非"合理调度"，
	# 跟玩家"用预算时间卡执行会发生逻辑漂移"的设计批评一致。改回 false 让
	# frame_budget gate 生效，并配合 Fix #9 用 phase 错峰：让 dynamic_visual_atlas
	# 跟 sea_ice_daily / weather_refresh 等同落在 climate 不跑的 phase=1 tick，
	# 这样 SUS budget 2-4ms 在两 tick 之间均摊，单 tick 不再撞车。
	must_run = false
	# Keep visual upload budgeted (no must_run, per the drift principle above), but the
	# active path is the cheap cell-indirection per-cell LUT rebake — the SOLE dynamic
	# visual path (temp/moisture/snow/vegetation/sea-ice all ride dyn_lut). On large maps
	# the must_run climate round eats the whole 2ms frame budget every tick, so this job is
	# perpetually frame_budget_exhausted and only the starvation net keeps it alive. A high
	# threshold (old 8) makes all dynamic visuals lag ~8 days on heavy maps (looks frozen,
	# most visibly sea ice). 2 bounds the lag to ~3 ticks at negligible cost. NOTE: the
	# effective value is re-applied by DcSystemScheduler._apply_budget_profile_to_job.
	starvation_threshold = 2
	baker = p_baker
	map = p_map
	world_data = p_world
	dirty_world = p_dirty_world
	world_ext = p_world_ext
	stride = max(1, p_stride)
	climate_profile = p_climate_profile
	_configure_lut_policy(stride, 0)
	_rebuild_baker_callables()


# [perf 2026-05-20] 方案 C：预解析所有 baker_key 的 begin/step/finalize Callable。
# 仅在 init/baker 切换时跑一次。Callable 是 Variant 内 inline，调用时无字符串 lookup。
func _rebuild_baker_callables() -> void:
	_baker_callables.clear()
	if baker == null:
		return
	const _KEYS: Array[String] = ["dynamic_cell_atlas", "ecology_visual_atlas",
			"dyn_atlas_smooth", "ice_state_atlas"]
	for k in _KEYS:
		var begin_name: String = k + "_chunk_begin"
		var step_name: String = k + "_chunk_step"
		var finalize_name: String = k + "_chunk_finalize"
		if not baker.has_method(begin_name) or not baker.has_method(step_name) \
				or not baker.has_method(finalize_name):
			continue
		_baker_callables[k] = {
			"begin": Callable(baker, begin_name),
			"step": Callable(baker, step_name),
			"finalize": Callable(baker, finalize_name),
		}


func _configure_lut_policy(p_stride: int, p_phase: int) -> void:
	stride = max(1, p_stride)
	_lut_stride = stride
	_lut_phase = p_phase
	policy = SusPolicyScript.StridePolicy.new(_lut_stride, _lut_phase)


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_COVER,
		DCComponentIds.CELL_VEGETATION_VITALITY,
	]


func declare_writes() -> Array[StringName]:
	return []


# [large-map sea-ice visual freeze fix 2026-06-29]
# The cell-indirection per-cell LUT rebake is the SOLE dynamic-visual path (temp / moisture
# / snow / vegetation-vitality / sea-ice all ride dyn_lut) and is cheap (~0.57ms @ 6400
# cells). reconfigure() is fed the STAGGER bucket stride (default 8), which made the LUT
# only "due" every 8 ticks regardless of map size — so every dynamic visual refreshed once
# per ~8 game-days. On fast small/medium maps 8 days elapse in a blink (looks live); on slow
# large maps 8 days take seconds, so sea ice looked visually frozen even though the numbers
# moved. The stagger only ever existed to spread the now-retired EXPENSIVE per-pixel atlas
# upload; the cheap LUT must instead track the sim at its base stride (knob default 1 = every
# tick). Keep the staggered _lut_stride/_lut_phase for the dead per-pixel fallback only.
func _lut_cadence_stride() -> int:
	if not FeatureFlagsScript.cell_indirection_active():
		return _lut_stride
	if climate_profile != null and climate_profile.get("dynamic_visual_atlas_upload_stride") != null:
		return clampi(int(climate_profile.dynamic_visual_atlas_upload_stride), 1, 8)
	return 1


func _lut_cadence_phase() -> int:
	# Cheap LUT does not need a stagger phase offset; refresh in step with the sim day.
	return 0 if FeatureFlagsScript.cell_indirection_active() else _lut_phase


func _lut_due_for_tick(tick_index: int) -> bool:
	return posmod(tick_index + _lut_cadence_phase(), _lut_cadence_stride()) == 0


func _latest_lut_due_tick_at_or_before(tick_index: int) -> int:
	return tick_index - posmod(tick_index + _lut_cadence_phase(), _lut_cadence_stride())


func _ctx_tick_index(ctx) -> int:
	if ctx is Dictionary:
		return int(ctx.get("tick_index", 0))
	if ctx != null:
		return int(ctx.get("tick_index"))
	return 0


func _ctx_day_index(ctx) -> int:
	if ctx is Dictionary:
		return int(ctx.get("day_index", -1))
	if ctx != null:
		return int(ctx.get("day_index"))
	return -1


func _lut_dirty_source():
	return dirty_world if dirty_world != null else world_data


func _lut_peek_dirty_count() -> int:
	var source = _lut_dirty_source()
	if source == null or not source.has_method("peek_dirty_count"):
		return -1
	if "dirty_mask_enabled" in source and not bool(source.dirty_mask_enabled):
		return -1
	if source.has_method("dirty_mask_size") and int(source.dirty_mask_size()) <= 0:
		return -1
	return int(source.peek_dirty_count())


func _lut_dense_dirty_threshold(source) -> int:
	if source == null or not source.has_method("dirty_mask_size"):
		return 0
	var cell_count := int(source.dirty_mask_size())
	if cell_count <= 0:
		return 0
	return mini(cell_count, maxi(
		LUT_DENSE_DIRTY_MIN_CELLS,
		int(ceil(float(cell_count) * LUT_DENSE_DIRTY_RATIO))))


func _lut_textures_ready() -> bool:
	return world_data != null \
			and world_data.enum_lut_tex != null \
			and world_data.dyn_lut_tex != null \
			and world_data.eco_lut_tex != null


func _lut_active_decay_pending() -> bool:
	if baker == null:
		return false
	if baker.has_method("cell_lut_active_transition_pending") \
			and bool(baker.cell_lut_active_transition_pending()):
		return true
	return "_eco_active_decay_set" in baker and not baker._eco_active_decay_set.is_empty()


func _native_visual_commit_pending() -> bool:
	var ext = _get_world_ext()
	if ext == null:
		return false
	if true \
			and bool(ext.call(&"is_native_daily_visual_commit_pending")):
		return true
	# ACTIVE climate worker 仍在提交日事务时，SoA slot 可能处于写入中。
	# LUT 编码读取的是 slot 的裸数组；50x 下这个窗口更容易与渲染帧重叠，
	# 造成 dyn_lut 的整批内容在新旧快照之间跳变。等本日事务完全提交后，
	# 下一 tick 的 catch-up 会用同一份稳定 slot 编码。
	var tr: Dictionary = ext.call(&"get_runtime_thread_report")
	if bool(tr.get("climate_worker_authoritative", false)) \
			and int(tr.get("worker_day_inflight", 0)) != 0:
		return true
	return false


func _runtime_environment_generation() -> int:
	var ext = _get_world_ext()
	if ext == null:
		return -1
	var tr: Dictionary = ext.call(&"get_runtime_thread_report")
	return int(tr.get("simulation_environment_generation",
		tr.get("environment_generation", -1)))


func _build_lut_commit_deferred_report(t_start_us: int, tick_index: int,
		pending_before: bool, due_this_tick: bool, due_tick: int) -> Dictionary:
	_lut_refresh_pending = true
	_lut_pending_before_tick = pending_before
	_lut_catchup_tick = false
	var report: Dictionary = {
		"done": true,
		"work_done": 0,
		"processed_cells": 0,
		"elapsed_ms": float(Time.get_ticks_usec() - t_start_us) / 1000.0,
		"progress_ratio": 1.0,
		"path": "cell_indirection_lut_commit_deferred",
		"lut_path": "deferred_native_daily_commit",
		"lut_refresh_ms": 0.0,
		"lut_refresh_due": due_this_tick,
		"lut_refresh_pending_before": pending_before,
		"lut_refresh_pending_after": true,
		"lut_last_refresh_tick": _lut_last_refresh_tick,
		"lut_last_due_tick": due_tick,
		"lut_stride": _lut_stride,
		"lut_phase": _lut_phase,
		"lut_catchup": false,
		"lut_skip_no_dirty": false,
		"native_visual_commit_pending": true,
		"dirty_reason": "native_daily_commit_pending",
		"dirty_noop": true,
	}
	_last_breakdown = report.duplicate(true)
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return report


func _build_lut_skip_report(t_start_us: int, tick_index: int, pending_before: bool,
		due_this_tick: bool, due_tick: int, dirty_count: int) -> Dictionary:
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	_lut_last_refresh_tick = tick_index
	_lut_refresh_pending = false
	_lut_pending_before_tick = pending_before
	_lut_catchup_tick = false
	var report: Dictionary = {
		"done": true,
		"work_done": 0,
		"processed_cells": 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"path": "cell_indirection_lut_skip",
		"lut_path": "skip_no_dirty",
		"lut_refresh_ms": 0.0,
		"lut_skip_no_dirty": true,
		"lut_refresh_due": due_this_tick,
		"lut_refresh_pending_before": pending_before,
		"lut_refresh_pending_after": _lut_refresh_pending,
		"lut_last_refresh_tick": _lut_last_refresh_tick,
		"lut_last_due_tick": due_tick,
		"lut_stride": _lut_stride,
		"lut_phase": _lut_phase,
		"lut_catchup": false,
		"mask_dirty_count": dirty_count,
		"dirty_reason": "no_dirty",
		"dirty_noop": true,
	}
	_last_breakdown = report.duplicate(true)
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return report


func _mark_lut_due_from_ctx(ctx) -> void:
	if not FeatureFlagsScript.cell_indirection_active():
		return
	var tick_index: int = _ctx_tick_index(ctx)
	var latest_due_tick: int = _latest_lut_due_tick_at_or_before(tick_index)
	if latest_due_tick < 0:
		return
	if _lut_last_refresh_tick < latest_due_tick:
		_lut_refresh_pending = true
		_lut_last_due_tick = max(_lut_last_due_tick, latest_due_tick)


func tick(ctx) -> Dictionary:
	return AtlasTick.tick(self, ctx)


func should_run(ctx: SusTickContext) -> bool:
	# F11 调试热键（2026-06-14）：force_disable meta 临时禁用整个 DVA pipeline。
	# 用来对比关掉 atlas commit 后 FPS 改善多少，定位 GPU 瓶颈。
	if Engine.has_meta(&"force_disable_dva_upload") and bool(Engine.get_meta(&"force_disable_dva_upload")):
		return false
	if should_skip_fast_forward_visual(ctx):
		return false
	if take_fast_forward_atlas_catchup():
		_lut_refresh_pending = true
	if not _cpp_commit_queue.is_empty() or _cpp_stride_in_progress:
		return true
	if FeatureFlagsScript.cell_indirection_active():
		_mark_lut_due_from_ctx(ctx)
		return _lut_refresh_pending
	if policy == null:
		return true
	return policy.should_run(self, ctx)


# ─── 状态机内部 helpers ───────────────────────────────────────────────────────

func _start_new_stride() -> void:
	AtlasStride._start_new_stride(self)


func _is_dirty_push_enabled() -> bool:
	return AtlasStride._is_dirty_push_enabled(self)


func _should_use_ext_encode(method_name: StringName) -> bool:
	return AtlasStride._should_use_ext_encode(self, method_name)


func _chunk_size_limit_for_baker(baker_key: String) -> int:
	return AtlasStride._chunk_size_limit_for_baker(self, baker_key)


func _advance_current_phase(remaining_budget: int, deadline_us: int) -> bool:
	return AtlasStride._advance_current_phase(self, remaining_budget, deadline_us)


func _abort_smooth_prep(reason: String) -> void:
	AtlasStride._abort_smooth_prep(self, reason)


func _start_smooth_prep(source: String, seed_cells: Array, decay_set: Dictionary = {}) -> void:
	AtlasStride._start_smooth_prep(self, source, seed_cells, decay_set)


func _smooth_prep_push_candidate(idx: int) -> void:
	AtlasStride._smooth_prep_push_candidate(self, idx)


func _advance_smooth_prep(remaining_budget: int, deadline_us: int) -> bool:
	return AtlasStride._advance_smooth_prep(self, remaining_budget, deadline_us)


func _validate_smooth_prep_equivalence_if_small() -> void:
	AtlasStride._validate_smooth_prep_equivalence_if_small(self)


func _step_phase_baker(remaining_budget: int, baker_key: String,
		agg_dirty_key: String, agg_ms_key: String, phase_key: String,
		deadline_us: int) -> bool:
	return AtlasStride._step_phase_baker(self, remaining_budget, baker_key, agg_dirty_key, agg_ms_key, phase_key, deadline_us)


func _finalize_stride(elapsed_ms: float) -> Dictionary:
	return AtlasStride._finalize_stride(self, elapsed_ms)


func _reset_state_machine() -> void:
	_phase = PHASE_IDLE
	_phase_cursor = 0
	_phase_cells = []
	_phase_ctx = {}
	_phase_report = {}
	_aggregated_report = {}
	_total_ticks_used = 0
	# plan/dirty-push-atlas-encode 阶段 D：清掉 stride 级 dirty 缓存，
	# 防止下 stride 误用旧 cells（read_and_clear 已让 mask 归零，但反查
	# 出来的 _stride_dirty_cells 仍持着 HexCell 引用）。
	_stride_dirty_indices = PackedInt32Array()
	_stride_dirty_cells = []
	_stride_dirty_path_used = false
	_stride_dirty_noop = false
	_stride_dirty_reason = ""
	_smooth_prep_state = {}
	_lut_last_environment_generation = -1


func _clear_cpp_commit_queue() -> void:
	_cpp_commit_queue.clear()
	_cpp_commit_context = {}


# ─── plan/atlas-pipeline-cpp 薄壳路径 ─────────────────────────────────────

# cpp_atlas_pipeline_enabled 已移除；原生管线在 world_ext 非空时使用。
# 此查询入口保留给既有调用者。
func _is_cpp_atlas_pipeline_enabled() -> bool:
	return AtlasNativeCommit._is_cpp_atlas_pipeline_enabled(self)


func _is_dynamic_atlas_terminal_dirty_enabled() -> bool:
	return AtlasNativeCommit._is_dynamic_atlas_terminal_dirty_enabled(self)


func _get_world_ext():
	return AtlasNativeCommit._get_world_ext(self)


func _tick_cpp_pipeline(t_start_us: int, ext: Object) -> Dictionary:
	return AtlasNativeCommit._tick_cpp_pipeline(self, t_start_us, ext)


func _run_atlas_pipeline_step(ext: Object, opts: Dictionary) -> Dictionary:
	return AtlasNativeCommit._run_atlas_pipeline_step(self, ext, opts)


func _begin_cpp_commit_queue(atlas_buffers: Dictionary, W: int, H: int,
		stride_real: Dictionary, base_report: Dictionary) -> void:
	AtlasNativeCommit._begin_cpp_commit_queue(self, atlas_buffers, W, H, stride_real, base_report)


func _current_cpp_atlas_buffer(channel: String) -> PackedByteArray:
	return AtlasNativeCommit._current_cpp_atlas_buffer(self, channel)


func _maybe_enqueue_cpp_commit_task(channel: String, buf: PackedByteArray,
		image_format: int, bytes_per_pixel: int, stride_count: int,
		need_init: bool, W: int, H: int, n_pix: int,
		force_commit: bool = false) -> void:
	AtlasNativeCommit._maybe_enqueue_cpp_commit_task(self, channel, buf, image_format, bytes_per_pixel, stride_count, need_init, W, H, n_pix, force_commit)


func _drain_cpp_commit_queue(t_start_us: int) -> Dictionary:
	return AtlasNativeCommit._drain_cpp_commit_queue(self, t_start_us)


func _commit_cpp_atlas_task_to_gpu(task: Dictionary) -> int:
	return AtlasNativeCommit._commit_cpp_atlas_task_to_gpu(self, task)


func _log_ice_commit_sample(buf_ice: PackedByteArray, need_init: bool,
		stride_count: int) -> void:
	AtlasNativeCommit._log_ice_commit_sample(self, buf_ice, need_init, stride_count)


func _burn_in_eco_state(ext: Object) -> void:
	AtlasNativeCommit._burn_in_eco_state(self, ext)


func _print_phase_breakdown_window(path_tag: String) -> void:
	AtlasNativeCommit._print_phase_breakdown_window(self, path_tag)


func notify_eco_burnin_pending() -> void:
	AtlasNativeCommit.notify_eco_burnin_pending(self)


# ─── 紧急回退：one-shot 路径 ───────────────────────────────────────────────
func _tick_oneshot(t_start_us: int) -> Dictionary:
	_abort_smooth_prep("oneshot_fallback")
	var dynamic_report: Dictionary = {}
	if baker.has_method("rebake_dynamic_cell_atlas_only"):
		dynamic_report = baker.rebake_dynamic_cell_atlas_only(map, world_data)
	var ecology_report: Dictionary = {}
	if baker.has_method("rebake_ecology_visual_atlas_only"):
		ecology_report = baker.rebake_ecology_visual_atlas_only(map, world_data)
	var smooth_report: Dictionary = {}
	if baker.has_method("rebake_dyn_atlas_smooth"):
		smooth_report = baker.rebake_dyn_atlas_smooth(map, world_data)
	var ice_report: Dictionary = {}
	if baker.has_method("rebake_ice_state_atlas"):
		ice_report = baker.rebake_ice_state_atlas(map, world_data)
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	var report := {
		"done": true,
		"work_done": map.cell_count(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"phase": "upload",
		"stage_name": "dynamic_visual_atlas_upload",
		"dynamic_dirty_cells": int(dynamic_report.get("dirty_cells", 0)),
		"dynamic_ms": float(dynamic_report.get("elapsed_ms", 0.0)),
		"ecology_dirty_cells": int(ecology_report.get("dirty_cells", 0)),
		"ecology_ms": float(ecology_report.get("elapsed_ms", 0.0)),
		"smooth_dirty_cells": int(smooth_report.get("dirty_cells", 0)),
		"smooth_ms": float(smooth_report.get("elapsed_ms", 0.0)),
		"ice_dirty_cells": int(ice_report.get("dirty_cells", 0)),
		"ice_ms": float(ice_report.get("elapsed_ms", 0.0)),
		"total_ticks_used": 1,
		# plan/atlas-phase-slicing 诊断（2026-05-21）：标记本次走 oneshot 的原因，
		# 让 perf CSV 直接能看出是\"cpp_pipeline 没生效→fallback\"还是\"enable_time_slicing=false\"。
		"path": "oneshot",
		"fallback_reason": _pending_fallback_reason if _pending_fallback_reason != "" else "no_cpp_pipeline_or_time_slicing_off",
	}
	# 消费一次，下次默认空（如果连续 fallback，每次都会被重置成最新原因）。
	_pending_fallback_reason = ""
	_last_breakdown = report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return report


func reconfigure(p_stride: int, p_phase: int = 0) -> void:
	_abort_smooth_prep("reconfigure")
	_reset_state_machine()
	_clear_cpp_commit_queue()
	_cpp_stride_in_progress = false
	stride = max(1, p_stride)
	_configure_lut_policy(stride, posmod(p_phase, stride))
	_lut_refresh_pending = true
	_lut_last_due_tick = -1


func reset_progress() -> void:
	super.reset_progress()
	_abort_smooth_prep("reset_progress")
	_reset_state_machine()
	_clear_cpp_commit_queue()
	_cpp_stride_in_progress = false
	_lut_refresh_pending = false
	_lut_last_refresh_tick = -1
	_lut_last_due_tick = -1
	_lut_pending_before_tick = false
	_lut_catchup_tick = false


func last_breakdown() -> Dictionary:
	return _last_breakdown.duplicate(true)


func _build_report(done: bool, elapsed_ms: float) -> Dictionary:
	var work_done: int = int(_aggregated_report.get("dynamic_dirty_cells", 0)) \
			+ int(_aggregated_report.get("ecology_dirty_cells", 0)) \
			+ int(_aggregated_report.get("smooth_dirty_cells", 0)) \
			+ int(_aggregated_report.get("ice_dirty_cells", 0))
	var report_work_done: int = work_done
	if report_work_done <= 0 and not _stride_dirty_path_used:
		report_work_done = map.cell_count()
	var progress_ratio: float = 1.0
	var phase_name: String = "upload"
	if not done:
		progress_ratio = clampf(float(_phase) / float(PHASE_DONE), 0.0, 1.0)
		phase_name = "upload_phase_%d" % _phase
	var out := {
		"done": done,
		"work_done": report_work_done,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress_ratio,
		"phase": phase_name,
		"stage_name": "dynamic_visual_atlas_upload",
		"current_phase": _phase,
		"phase_cursor": _phase_cursor,
		"ticks_used": _total_ticks_used,
		"total_ticks_used": _total_ticks_used,
		"mask_path": _stride_dirty_path_used,
		"mask_dirty_count": _stride_dirty_indices.size(),
		"dirty_reason": _stride_dirty_reason,
		"dirty_noop": _stride_dirty_noop,
		"dirty_mask_available": bool(_aggregated_report.get("dirty_mask_available", false)),
		"dirty_source": str(_aggregated_report.get("dirty_source", "")),
		"max_cells_per_tick": MAX_CELLS_PER_TICK,
		"time_check_cells_per_step": TIME_CHECK_CELLS_PER_STEP,
		"cpp_time_check_cells_per_step": CPP_TIME_CHECK_CELLS_PER_STEP,
		"slice_budget_ms": slice_budget_ms,
	}
	for phase_key in ["dynamic", "ecology", "smooth", "ice"]:
		_copy_phase_metrics(out, phase_key)
	return out


func _copy_phase_metrics(out: Dictionary, phase_key: String) -> void:
	for suffix in [
		"dirty_cells", "ms", "prepare_ms", "step_ms", "finalize_ms",
		"cells_considered", "total_cells", "pixels_written",
		"cpp_calls", "gd_calls", "empty_calls",
		"source", "path", "fallback_reason",
		"prep_stage", "prep_input_cursor", "prep_decay_cursor", "prep_seed_count",
		"prep_seed_cursor", "prep_dilate_cursor", "prep_collect_cursor", "prep_candidates",
		"prep_equiv_checks", "prep_equiv_failures", "prep_abort_reason", "prep_abort_count",
	]:
		var key: String = phase_key + "_" + suffix
		if _aggregated_report.has(key):
			out[key] = _aggregated_report[key]
