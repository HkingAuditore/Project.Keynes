extends DCSystem
class_name DynamicVisualAtlasUploadSystem

## Updates low-frequency visual atlases used by the main map shader.
##
## Stride=1 default：每个仿真日跑一次（StridePolicy 控制），保持温度/雪/海冰视觉同步。
## Weather LUT 已拆到 WeatherLutUploadSystem，跟随 weather_refresh 提交单独发布。
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
const PHASE_COUNT: int = 4  # 实际工作 phase 数（1..4）

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
const SOFT_BUDGET_MULTIPLIER: float = 2.0

# ─── plan/atlas-phase-slicing（2026-05-21）：CPP pipeline phase 切片预算 ───
# 默认 4 = 单 tick 一气呵成，dyn/eco/smooth/ice 同一轮产出并提交。
# 调低到 1 = 每 tick 推 1 phase，4 个 phase 拆到 4 个 tick（严格预算/诊断用）。
# 配合 C++ AtlasPipelineState 跨 call 持有 stride snapshot（dirty/cache/nb_arr/prep_*），
# 仅在 stride 起点传 dirty_indices；mid-stride tick 跳过 commit GPU。
const CPP_PIPELINE_PHASE_BUDGET: int = 4
# C++ smooth phase 内部再按 cell cursor 切片，避免 dirty/full sweep 时单次 2ms+。
const CPP_SMOOTH_CELLS_PER_CALL: int = 512
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
const CPP_COMMIT_TEXTURES_PER_TICK_DESKTOP: int = 4
const CPP_COMMIT_TEXTURES_PER_TICK_MOBILE: int = 1

static func _cpp_commit_textures_per_tick() -> int:
	return CPP_COMMIT_TEXTURES_PER_TICK_MOBILE if OS.has_feature("mobile") else CPP_COMMIT_TEXTURES_PER_TICK_DESKTOP

# 兼容：保留旧名，值=桌面默认。真正分流由 _cpp_commit_textures_per_tick()。
const CPP_COMMIT_TEXTURES_PER_TICK: int = CPP_COMMIT_TEXTURES_PER_TICK_DESKTOP
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
var _dvas_ice_skip_runs: int = 0
var _last_breakdown: Dictionary = {}

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
var _cpp_pipeline_warned_missing_method: bool = false  # 一次性 push_warning
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
	# Keep visual upload budgeted; starvation protection catches long stalls.
	starvation_threshold = 8
	baker = p_baker
	map = p_map
	world_data = p_world
	dirty_world = p_dirty_world
	world_ext = p_world_ext
	stride = max(1, p_stride)
	climate_profile = p_climate_profile
	# Fix #11 (2026-06-15): mobile C 桶错峰 stride=8 phase=2 → tick 6, 14, 22, 30
	# 完整分桶: A sea_ice (s8 p6), B weather+enum (s8 p4), C dyn_visual (s8 p2),
	# D ocean (s8 p0)。每 8 仿真日 atlas commit 一次。
	# 单 tick 1-3ms，不再被 ocean (D 桶 8ms) 或 climate (1-12ms) 撞 budget。
	if OS.has_feature("mobile"):
		_configure_lut_policy(8, 2)
	else:
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


func _lut_due_for_tick(tick_index: int) -> bool:
	return posmod(tick_index + _lut_phase, _lut_stride) == 0


func _latest_lut_due_tick_at_or_before(tick_index: int) -> int:
	return tick_index - posmod(tick_index + _lut_phase, _lut_stride)


func _ctx_tick_index(ctx) -> int:
	if ctx is Dictionary:
		return int(ctx.get("tick_index", 0))
	if ctx != null:
		return int(ctx.get("tick_index"))
	return 0


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
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}
	if not _cpp_commit_queue.is_empty():
		return _drain_cpp_commit_queue(t_start_us)

	# [cell-indirect single-path 2026-06-16] flag 开 → 主 shader 全量走 per-cell LUT，
	# 旧逐像素动态 atlas（dynamic/ecology/smooth/ice）已无任何 shader 消费者。这里每
	# stride 只全量重烘 enum/dyn/eco per-cell LUT（weather_lut 不在此发布），
	# 随后直接结束本 tick：彻底跳过下方 C++ run_atlas_pipeline_step 与 4-phase 逐像素
	# 上传，省每日 GPU 上传 + 4 张 derived RGBA8 显存。stride 节奏不变（StridePolicy
	# 控制 tick 频率）。weather_lut 由 WeatherLutUploadSystem 跟随天气提交发布。
	# flag 关时本分支零触达，旧 per-pixel 路径（_tick_cpp_pipeline / 4-phase / _tick_oneshot）
	# 行为完全不变，即 flag 充当 A/B fallback 开关（skill rule 11）。
	if FeatureFlagsScript.cell_indirection_active():
		_mark_lut_due_from_ctx(ctx)
		var pending_before: bool = _lut_refresh_pending
		var tick_index: int = _ctx_tick_index(ctx)
		var due_this_tick: bool = _lut_due_for_tick(tick_index)
		var due_tick: int = _lut_last_due_tick
		var catchup: bool = pending_before and not due_this_tick
		var lut_report: Dictionary = baker.refresh_cell_luts_daily(map, world_data)
		var _lut_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
		_lut_last_refresh_tick = tick_index
		_lut_refresh_pending = false
		_lut_pending_before_tick = pending_before
		_lut_catchup_tick = catchup
		var report: Dictionary = {
			"done": true,
			"work_done": map.cell_count() if map != null else 0,
			"elapsed_ms": _lut_ms,
			"progress_ratio": 1.0,
			"path": "cell_indirection_lut",
		}
		report["lut_path"] = str(lut_report.get("path", ""))
		report.merge(lut_report, true)
		report["path"] = "cell_indirection_lut"
		report["lut_refresh_ms"] = _lut_ms
		report["lut_refresh_pending_before"] = pending_before
		report["lut_refresh_pending_after"] = _lut_refresh_pending
		report["lut_last_refresh_tick"] = _lut_last_refresh_tick
		report["lut_last_due_tick"] = due_tick
		report["lut_stride"] = _lut_stride
		report["lut_phase"] = _lut_phase
		report["lut_catchup"] = catchup
		_last_breakdown = report.duplicate(true)
		_last_breakdown["_tick_idx"] = current_fast_tick_idx
		return report

	# 紧急回退：走旧 one-shot 路径。
	if not enable_time_slicing:
		return _tick_oneshot(t_start_us)

	# ── plan/atlas-pipeline-cpp：薄壳路径分流 ────────────────────────────
	# flag=true 且 ext 实现了 run_atlas_pipeline_step → 走全量 DOTS C++ 路径，
	# 一次性完成 4 atlas 计算并返回 atlas_buffers，GD 端只做 ImageTexture.update。
	# 任一前置条件不满足则自动 fallback 到旧 4-phase 状态机。
	if _is_cpp_atlas_pipeline_enabled():
		var ext = _get_world_ext()
		if ext != null and ext.has_method(&"run_atlas_pipeline_step"):
			return _tick_cpp_pipeline(t_start_us, ext)
		elif not _cpp_pipeline_warned_missing_method:
			_cpp_pipeline_warned_missing_method = true
			push_warning("[atlas-pipeline-cpp] flag=on 但 ext 缺少 run_atlas_pipeline_step；fallback 到旧 4-phase 路径")

	# Soft budget：单 tick 不应超过这个数值；用作 phase 推进的让出阈值。
	var soft_budget_us: int = maxi(50, int(slice_budget_ms * SOFT_BUDGET_MULTIPLIER * 1000.0))
	var deadline_us: int = t_start_us + soft_budget_us

	# Phase IDLE：进入新 stride。
	if _phase == PHASE_IDLE:
		_start_new_stride()

	_total_ticks_used += 1

	# 主推进循环：尽可能多 phase 在 budget 内完成。
	while _phase >= PHASE_DYNAMIC and _phase <= PHASE_ICE:
		var elapsed_us: int = Time.get_ticks_usec() - t_start_us
		if elapsed_us >= soft_budget_us:
			break
		# 计算本次 step 可扫的 cell 上限：MAX_CELLS_PER_TICK 跨 phase 共享。
		var remaining_budget: int = MAX_CELLS_PER_TICK - int(_aggregated_report.get("_cells_scanned_this_tick", 0))
		if remaining_budget <= 0:
			break
		var phase_done: bool = _advance_current_phase(remaining_budget, deadline_us)
		if phase_done:
			_phase += 1
			# Phase 切换：清掉 ctx / report，准备进入下一 phase。
			_phase_ctx = {}
			_phase_report = {}
			_phase_cells = []
			_phase_cursor = 0
		else:
			# 当前 phase 未完，break 让出，下 tick 续跑。
			break

	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	_dvas_diag_max_tick_ms = max(_dvas_diag_max_tick_ms, elapsed_ms)

	# 清掉本 tick 的 cells_scanned 计数，下 tick 重置。
	_aggregated_report["_cells_scanned_this_tick"] = 0

	# Stride 完成（_phase == PHASE_DONE）。
	if _phase >= PHASE_DONE:
		var final_report: Dictionary = _finalize_stride(elapsed_ms)
		_reset_state_machine()
		return final_report

	# 还有 phase 未完成 —— 返回部分进度，下 tick 续跑。
	var partial_report: Dictionary = _build_report(false, elapsed_ms)
	_last_breakdown = partial_report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return partial_report


func should_run(ctx: SusTickContext) -> bool:
	# F11 调试热键（2026-06-14）：force_disable meta 临时禁用整个 DVA pipeline。
	# 用来对比关掉 atlas commit 后 FPS 改善多少，定位 GPU 瓶颈。
	if Engine.has_meta(&"force_disable_dva_upload") and bool(Engine.get_meta(&"force_disable_dva_upload")):
		return false
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
	_phase = PHASE_DYNAMIC
	_phase_cursor = 0
	_phase_cells = map.all_cells()
	_phase_ctx = {}
	_phase_report = {}
	_total_ticks_used = 0
	_aggregated_report = {
		"dynamic_dirty_cells": 0,
		"dynamic_ms": 0.0,
		"ecology_dirty_cells": 0,
		"ecology_ms": 0.0,
		"smooth_dirty_cells": 0,
		"smooth_ms": 0.0,
		"ice_dirty_cells": 0,
		"ice_ms": 0.0,
		"dynamic_prepare_ms": 0.0,
		"dynamic_step_ms": 0.0,
		"dynamic_finalize_ms": 0.0,
		"dynamic_cells_considered": 0,
		"dynamic_pixels_written": 0,
		"dynamic_cpp_calls": 0,
		"dynamic_gd_calls": 0,
		"dynamic_empty_calls": 0,
		"ecology_prepare_ms": 0.0,
		"ecology_step_ms": 0.0,
		"ecology_finalize_ms": 0.0,
		"ecology_cells_considered": 0,
		"ecology_pixels_written": 0,
		"ecology_cpp_calls": 0,
		"ecology_gd_calls": 0,
		"ecology_empty_calls": 0,
		"smooth_prepare_ms": 0.0,
		"smooth_step_ms": 0.0,
		"smooth_finalize_ms": 0.0,
		"smooth_cells_considered": 0,
		"smooth_pixels_written": 0,
		"smooth_cpp_calls": 0,
		"smooth_gd_calls": 0,
		"smooth_empty_calls": 0,
		"ice_prepare_ms": 0.0,
		"ice_step_ms": 0.0,
		"ice_finalize_ms": 0.0,
		"ice_cells_considered": 0,
		"ice_pixels_written": 0,
		"ice_cpp_calls": 0,
		"ice_gd_calls": 0,
		"ice_empty_calls": 0,
		"dirty_reason": "",
		"dirty_source": "",
		"dirty_mask_available": false,
		"dirty_noop": false,
		"_cells_scanned_this_tick": 0,
	}
	# plan/dirty-push-atlas-encode 阶段 D：原子读 + 清零 mask，反查 cell 列表。
	# 单线程 SUS 调度保证 read_and_clear 的原子性（priority 100-200 的 sim 已写完，
	# 250 的 atlas upload 是唯一消费者）。
	_stride_dirty_indices = PackedInt32Array()
	_stride_dirty_cells = []
	_stride_dirty_path_used = false
	_stride_dirty_noop = false
	_stride_dirty_reason = ""
	if not _is_dirty_push_enabled():
		_stride_dirty_reason = "flag_disabled"
		_aggregated_report["dirty_reason"] = _stride_dirty_reason
		return
	var dirty_source = dirty_world if dirty_world != null else world_data
	_aggregated_report["dirty_source"] = "dirty_world" if dirty_world != null else "world_data"
	if dirty_source == null or not dirty_source.has_method("read_and_clear_dirty_mask"):
		_stride_dirty_reason = "read_and_clear_missing"
		_aggregated_report["dirty_reason"] = _stride_dirty_reason
		return
	if dirty_source.has_method("dirty_mask_size") and int(dirty_source.dirty_mask_size()) <= 0:
		_stride_dirty_reason = "dirty_mask_size_zero"
		_aggregated_report["dirty_reason"] = _stride_dirty_reason
		return
	_aggregated_report["dirty_mask_available"] = true
	var dirty: PackedInt32Array = dirty_source.read_and_clear_dirty_mask()
	_stride_dirty_path_used = true
	# [DIAG mask_dirty=2400 排查 · 2026-05-20] 仅前 8 次 stride + 之后每 30 stride 打一次
	if _dvas_diag_stride_count < 8 or (_dvas_diag_stride_count % 30) == 0:
		var _src_tag: String = "dirty_world" if dirty_world != null else "world_data"
		var _mask_size_dump: int = -1
		if dirty_source.has_method("dirty_mask_size"):
			_mask_size_dump = int(dirty_source.dirty_mask_size())
		print("[DIAG atlas_upload] stride#%d source=%s mask_size=%d dirty_count=%d" % [
			_dvas_diag_stride_count, _src_tag, _mask_size_dump, dirty.size(),
		])
	if dirty.size() <= 0:
		_stride_dirty_noop = true
		_stride_dirty_reason = "no_dirty"
		_aggregated_report["dirty_reason"] = _stride_dirty_reason
		_aggregated_report["dirty_noop"] = true
		return
	_stride_dirty_indices = dirty
	_stride_dirty_reason = "dirty"
	_aggregated_report["dirty_reason"] = _stride_dirty_reason
	_aggregated_report["dirty_noop"] = false
	# 反查 HexCell：MapData.cell_by_index(idx) 是 O(1) 数组下标。
	_stride_dirty_cells.resize(dirty.size())
	var n: int = dirty.size()
	for i in range(n):
		var idx: int = dirty[i]
		var c: HexCell = map.cell_at(idx)
		_stride_dirty_cells[i] = c   # 允许 null（mask 越界容错；下游会过滤）


# plan/dirty-push-atlas-encode 阶段 D 私有 helper：
# dots-flag-prune-pr1 round 2: dirty_push_enabled flag 已删除——恒走 mask 路径。
# climate_profile 与 dirty mask 逻辑无关，dirty_source 是否实现 read_and_clear_dirty_mask
# 由下游调用点探测。本 helper 仅作为后兼容保留，恒返 true。
func _is_dirty_push_enabled() -> bool:
	return true


# plan/dirty-push-atlas-encode 阶段 F 私有 helper：
# 是否启用 C++ atlas encode pass。要求：
#   1. world_data 有 _world_ext 引用且非 null（DCWorld bind 后注入）
#   2. ext 实现了对应 encode_* 方法（向前兼容旧版本 GDExtension dll）
# 任一不满足都返回 false → 自动 fallback 到 GDScript mask 路径。
#
# dots-flag-prune-pr1 round 2: cpp_atlas_encode_enabled flag 已删除——恒走 ext +
# has_method 探测分支（ext 未提供对应 encode_* method 时透明回退）。
func _should_use_ext_encode(method_name: StringName) -> bool:
	if baker != null and baker.has_method("_cpp_atlas_encode_active"):
		return bool(baker.call("_cpp_atlas_encode_active", method_name))
	if world_data == null:
		return false
	# DCWorld 在 bind_world 时把 ext 引用挂到 _world_ext / _ext 等字段；
	# 走 .get() 反射拿，避免对 DCWorld 内部实现强耦合。
	var ext = world_data.get("_world_ext")
	if ext == null:
		ext = world_data.get("_ext")
	if ext == null:
		return false
	return ext.has_method(method_name)


func _chunk_size_limit_for_baker(baker_key: String) -> int:
	var method_name: StringName
	match baker_key:
		"dynamic_cell_atlas":
			method_name = &"encode_dynamic_cell_atlas"
		"ecology_visual_atlas":
			method_name = &"encode_ecology_visual_atlas"
		"dyn_atlas_smooth":
			method_name = &"encode_dyn_smooth_atlas"
		"ice_state_atlas":
			method_name = &"encode_ice_state_atlas"
		_:
			return TIME_CHECK_CELLS_PER_STEP
	if _should_use_ext_encode(method_name):
		return CPP_TIME_CHECK_CELLS_PER_STEP
	return TIME_CHECK_CELLS_PER_STEP


# 推进当前 phase；返回 true 表示当前 phase 已完成（finalize 已调用），可切下一 phase。
# remaining_budget 是本 tick 还能扫多少 cell。
func _advance_current_phase(remaining_budget: int, deadline_us: int) -> bool:
	match _phase:
		PHASE_DYNAMIC:
			return _step_phase_baker(remaining_budget, "dynamic_cell_atlas",
					"dynamic_dirty_cells", "dynamic_ms", "dynamic", deadline_us)
		PHASE_ECOLOGY:
			return _step_phase_baker(remaining_budget, "ecology_visual_atlas",
					"ecology_dirty_cells", "ecology_ms", "ecology", deadline_us)
		PHASE_SMOOTH:
			return _step_phase_baker(remaining_budget, "dyn_atlas_smooth",
					"smooth_dirty_cells", "smooth_ms", "smooth", deadline_us)
		PHASE_ICE:
			return _step_phase_baker(remaining_budget, "ice_state_atlas",
					"ice_dirty_cells", "ice_ms", "ice", deadline_us)
		_:
			return true


func _abort_smooth_prep(reason: String) -> void:
	if _smooth_prep_state.is_empty():
		return
	_smooth_prep_abort_count += 1
	_aggregated_report["smooth_prep_abort_reason"] = reason
	_aggregated_report["smooth_prep_abort_count"] = _smooth_prep_abort_count
	_smooth_prep_generation += 1
	_smooth_prep_state = {}


func _start_smooth_prep(source: String, seed_cells: Array, decay_set: Dictionary = {}) -> void:
	var n: int = map.cell_count() if map != null else 0
	_smooth_prep_generation += 1
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(maxi(0, n))
	var seed_seen: PackedByteArray = PackedByteArray()
	seed_seen.resize(maxi(0, n))
	_smooth_prep_state = {
		"generation": _smooth_prep_generation,
		"stage": "merge_seed",
		"source": source,
		"input_cells": seed_cells if seed_cells != null else [],
		"input_cursor": 0,
		"decay_keys": decay_set.keys() if decay_set != null and not decay_set.is_empty() else [],
		"decay_cursor": 0,
		"seed_cells": [],
		"dilate_cursor": 0,
		"collect_cursor": 0,
		"seen": seen,
		"seed_seen": seed_seen,
		"candidates": PackedInt32Array(),
		"candidate_sorted": false,
		"out": [],
		"n": n,
		"prepared": false,
	}


func _smooth_prep_push_candidate(idx: int) -> void:
	var n: int = int(_smooth_prep_state.get("n", 0))
	if idx < 0 or idx >= n:
		return
	var seen: PackedByteArray = _smooth_prep_state.get("seen", PackedByteArray())
	if seen.size() < n or seen[idx] != 0:
		return
	seen[idx] = 1
	_smooth_prep_state["seen"] = seen
	var candidates: PackedInt32Array = _smooth_prep_state.get("candidates", PackedInt32Array())
	candidates.append(idx)
	_smooth_prep_state["candidates"] = candidates


func _advance_smooth_prep(remaining_budget: int, deadline_us: int) -> bool:
	if _smooth_prep_state.is_empty():
		return true
	if int(_smooth_prep_state.get("generation", -1)) != _smooth_prep_generation:
		_abort_smooth_prep("stale_generation")
		return false
	var t_prep_us: int = Time.get_ticks_usec()
	var budget: int = maxi(1, mini(SMOOTH_PREP_CELLS_PER_TICK, remaining_budget))
	var seed_cells: Array = _smooth_prep_state.get("seed_cells", [])
	var n: int = int(_smooth_prep_state.get("n", 0))
	var nb_indices: PackedInt32Array = map.neighbor_indices_packed() if map != null and map.has_method("neighbor_indices_packed") else PackedInt32Array()
	var fast_indexed: bool = nb_indices.size() >= n * 6
	var worked: int = 0
	while worked < budget:
		if worked > 0 and Time.get_ticks_usec() >= deadline_us:
			break
		var stage: String = str(_smooth_prep_state.get("stage", "merge_seed"))
		if stage == "merge_seed":
			var input_cells: Array = _smooth_prep_state.get("input_cells", [])
			var decay_keys: Array = _smooth_prep_state.get("decay_keys", [])
			var input_cursor: int = int(_smooth_prep_state.get("input_cursor", 0))
			var decay_cursor: int = int(_smooth_prep_state.get("decay_cursor", 0))
			var merged_seed: Array = _smooth_prep_state.get("seed_cells", [])
			var c = null
			if input_cursor < input_cells.size():
				c = input_cells[input_cursor]
				_smooth_prep_state["input_cursor"] = input_cursor + 1
			elif decay_cursor < decay_keys.size():
				c = decay_keys[decay_cursor]
				_smooth_prep_state["decay_cursor"] = decay_cursor + 1
			else:
				_smooth_prep_state["seed_cells"] = merged_seed
				_smooth_prep_state["stage"] = "dilate_mark"
				seed_cells = merged_seed
				continue
			if c != null:
				var idx_seed: int = int(c.index)
				var seed_seen: PackedByteArray = _smooth_prep_state.get("seed_seen", PackedByteArray())
				if idx_seed >= 0 and idx_seed < n and seed_seen[idx_seed] == 0:
					seed_seen[idx_seed] = 1
					_smooth_prep_state["seed_seen"] = seed_seen
					merged_seed.append(c)
					_smooth_prep_state["seed_cells"] = merged_seed
			worked += 1
		elif stage == "dilate_mark":
			var dilate_cursor: int = int(_smooth_prep_state.get("dilate_cursor", 0))
			if dilate_cursor >= seed_cells.size():
				_smooth_prep_state["stage"] = "collect_sorted"
				continue
			var c2 = seed_cells[dilate_cursor]
			if c2 != null:
				var idx2: int = int(c2.index)
				if idx2 >= 0 and idx2 < n:
					_smooth_prep_push_candidate(idx2)
					if fast_indexed:
						var base: int = idx2 * 6
						for d in range(6):
							_smooth_prep_push_candidate(nb_indices[base + d])
					elif map.has_method("get_neighbors"):
						for nb_cell in map.get_neighbors(c2):
							if nb_cell != null:
								_smooth_prep_push_candidate(int(nb_cell.index))
			_smooth_prep_state["dilate_cursor"] = dilate_cursor + 1
			worked += 1
		elif stage == "collect_sorted":
			var candidates: PackedInt32Array = _smooth_prep_state.get("candidates", PackedInt32Array())
			if not bool(_smooth_prep_state.get("candidate_sorted", false)):
				candidates.sort()
				_smooth_prep_state["candidates"] = candidates
				_smooth_prep_state["candidate_sorted"] = true
			var collect_cursor: int = int(_smooth_prep_state.get("collect_cursor", 0))
			if collect_cursor >= candidates.size():
				_smooth_prep_state["stage"] = "done"
				_smooth_prep_state["prepared"] = true
				break
			var collect_end: int = mini(candidates.size(), collect_cursor + (budget - worked))
			var out: Array = _smooth_prep_state.get("out", [])
			for i in range(collect_cursor, collect_end):
				out.append(map.cell_at(candidates[i]))
			_smooth_prep_state["out"] = out
			_smooth_prep_state["collect_cursor"] = collect_end
			worked += collect_end - collect_cursor
		else:
			break
	_aggregated_report["smooth_prepare_ms"] = float(_aggregated_report.get("smooth_prepare_ms", 0.0)) \
			+ float(Time.get_ticks_usec() - t_prep_us) / 1000.0
	_aggregated_report["smooth_prep_stage"] = str(_smooth_prep_state.get("stage", ""))
	_aggregated_report["smooth_prep_input_cursor"] = int(_smooth_prep_state.get("input_cursor", 0))
	_aggregated_report["smooth_prep_decay_cursor"] = int(_smooth_prep_state.get("decay_cursor", 0))
	_aggregated_report["smooth_prep_seed_count"] = int((_smooth_prep_state.get("seed_cells", []) as Array).size())
	_aggregated_report["smooth_prep_dilate_cursor"] = int(_smooth_prep_state.get("dilate_cursor", 0))
	_aggregated_report["smooth_prep_collect_cursor"] = int(_smooth_prep_state.get("collect_cursor", 0))
	_aggregated_report["smooth_prep_candidates"] = int((_smooth_prep_state.get("candidates", PackedInt32Array()) as PackedInt32Array).size())
	_aggregated_report["_cells_scanned_this_tick"] = int(_aggregated_report.get("_cells_scanned_this_tick", 0)) + worked
	return bool(_smooth_prep_state.get("prepared", false))


func _validate_smooth_prep_equivalence_if_small() -> void:
	if _smooth_prep_state.is_empty() or map == null:
		return
	var input_cells: Array = _smooth_prep_state.get("input_cells", [])
	var decay_keys: Array = _smooth_prep_state.get("decay_keys", [])
	var total_input: int = input_cells.size() + decay_keys.size()
	if total_input > 256:
		return
	_smooth_prep_equiv_checks += 1
	var seed_expected: Array = BakerDirtyHelpersScript.merge_with_eco_decay(input_cells, {})
	if not decay_keys.is_empty():
		var decay_set: Dictionary = {}
		for c in decay_keys:
			if c != null:
				decay_set[c] = true
		seed_expected = BakerDirtyHelpersScript.merge_with_eco_decay(seed_expected, decay_set)
	var expected: Array = BakerDirtyHelpersScript.dilate_dirty_one_hop(map, seed_expected)
	var actual: Array = _smooth_prep_state.get("out", [])
	var equal: bool = expected.size() == actual.size()
	if equal:
		for i in range(expected.size()):
			var e = expected[i]
			var a = actual[i]
			var ei: int = int(e.index) if e != null else -1
			var ai: int = int(a.index) if a != null else -1
			if ei != ai:
				equal = false
				break
	if not equal:
		_smooth_prep_equiv_failures += 1
		push_warning("[dyn_atlas_smooth/prep] sliced dirty expansion mismatch expected=%d actual=%d" % [expected.size(), actual.size()])
	_aggregated_report["smooth_prep_equiv_checks"] = _smooth_prep_equiv_checks
	_aggregated_report["smooth_prep_equiv_failures"] = _smooth_prep_equiv_failures


# Phase 1..4：通用 baker chunk 推进。
# baker_key 决定调用哪组 chunk_begin/step/finalize；
# agg_dirty_key / agg_ms_key 是 aggregated_report 里的累计字段名。
func _step_phase_baker(remaining_budget: int, baker_key: String,
		agg_dirty_key: String, agg_ms_key: String, phase_key: String,
		deadline_us: int) -> bool:
	var total_us: int = Time.get_ticks_usec()
	# [perf 2026-05-20] 方案 C：Callable 表命中直接调，未命中（理论上不会发生）走老路径。
	var _cb: Dictionary = _baker_callables.get(baker_key, {})
	var _cb_step: Callable = _cb.get("step", Callable())
	var _cb_finalize: Callable = _cb.get("finalize", Callable())
	if _phase_ctx.is_empty():
		var prepare_us: int = Time.get_ticks_usec()
		var begin_method: String = "%s_chunk_begin" % baker_key
		if not baker.has_method(begin_method):
			return true
		var _cb_begin: Callable = _cb.get("begin", Callable())
		if _cb_begin.is_valid():
			_phase_ctx = _cb_begin.call(map, world_data)
		else:
			_phase_ctx = baker.call(begin_method, map, world_data)
		if not bool(_phase_ctx.get("prepared", false)):
			_phase_ctx = {}
			return true
		var source: String = "all_cells"
		if baker_key == "ice_state_atlas":
			if _stride_dirty_path_used and _stride_dirty_noop:
				var ice_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
				if ice_cache_valid:
					_phase_cells = []
					source = "no_dirty"
				elif baker.has_method("ice_state_atlas_default_cell_source"):
					_phase_cells = baker.ice_state_atlas_default_cell_source(map, world_data, _phase_ctx)
					source = "all_cells_cache_invalid"
				else:
					_phase_cells = map.all_cells()
					source = "all_cells_cache_invalid"
			elif _stride_dirty_path_used and baker.has_method("ice_state_atlas_default_cell_source"):
				var water_lists: Dictionary = world_data.water_cell_pixel_lists if world_data != null else {}
				if water_lists != null and not water_lists.is_empty() and not _stride_dirty_cells.is_empty():
					var intersection: Array = []
					intersection.resize(_stride_dirty_cells.size())
					var w: int = 0
					for c in _stride_dirty_cells:
						if c != null and water_lists.has(c):
							intersection[w] = c
							w += 1
					intersection.resize(w)
					_phase_cells = intersection
					source = "dirty_water_intersection"
				else:
					var ice_dirty_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
					if ice_dirty_cache_valid:
						_phase_cells = []
						source = "dirty_no_water_intersection"
					else:
						_phase_cells = baker.ice_state_atlas_default_cell_source(map, world_data, _phase_ctx)
						source = "all_cells_cache_invalid"
			elif baker.has_method("ice_state_atlas_default_cell_source"):
				_phase_cells = baker.ice_state_atlas_default_cell_source(map, world_data, _phase_ctx)
				source = "ice_default_source"
			else:
				_phase_cells = map.all_cells()
		elif baker_key == "dynamic_cell_atlas" and _stride_dirty_path_used:
			if _stride_dirty_noop:
				var dynamic_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
				if dynamic_cache_valid:
					_phase_cells = []
					source = "no_dirty"
				else:
					_phase_cells = map.all_cells()
					source = "all_cells_cache_invalid"
			else:
				_phase_cells = _stride_dirty_cells
				source = "dirty_mask"
		elif baker_key == "ecology_visual_atlas" and _stride_dirty_path_used:
			var eco_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
			if not eco_cache_valid:
				_phase_cells = map.all_cells()
				source = "all_cells_cache_invalid"
			elif _stride_dirty_noop:
				if baker._eco_active_decay_set.is_empty():
					_phase_cells = []
					source = "no_dirty"
				else:
					_phase_cells = baker._eco_active_decay_set.keys()
					source = "decay_only"
			else:
				_phase_cells = BakerDirtyHelpersScript.merge_with_eco_decay(
					_stride_dirty_cells, baker._eco_active_decay_set)
				source = "dirty_plus_decay"
		elif baker_key == "dyn_atlas_smooth" and _stride_dirty_path_used:
			var smooth_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
			if not smooth_cache_valid:
				_phase_cells = map.all_cells()
				source = "all_cells_cache_invalid"
			elif _stride_dirty_noop:
				if baker._eco_active_decay_set.is_empty():
					_phase_cells = []
					source = "no_dirty"
				else:
					source = "decay_one_hop_sliced"
					if _smooth_prep_state.is_empty():
						_start_smooth_prep(source, baker._eco_active_decay_set.keys())
					if not _advance_smooth_prep(remaining_budget, deadline_us):
						_aggregated_report[phase_key + "_source"] = source
						return false
					_validate_smooth_prep_equivalence_if_small()
					_phase_cells = _smooth_prep_state.get("out", [])
					_smooth_prep_state = {}
			else:
				source = "dirty_decay_one_hop_sliced"
				if _smooth_prep_state.is_empty():
					_start_smooth_prep(source, _stride_dirty_cells, baker._eco_active_decay_set)
				if not _advance_smooth_prep(remaining_budget, deadline_us):
					_aggregated_report[phase_key + "_source"] = source
					return false
				_validate_smooth_prep_equivalence_if_small()
				_phase_cells = _smooth_prep_state.get("out", [])
				_smooth_prep_state = {}
		else:
			_phase_cells = map.all_cells()
		_phase_cursor = 0
		_phase_report = {
			"prepared": true,
			"dirty": false,
			"dirty_cells": 0,
			"pixels_written": 0,
			"elapsed_ms": 0.0,
			"path": "",
			"fallback_reason": "",
			"cpp_calls": 0,
			"gd_calls": 0,
			"empty_calls": 0,
		}
		_aggregated_report[phase_key + "_prepare_ms"] = \
				float(Time.get_ticks_usec() - prepare_us) / 1000.0
		_aggregated_report[phase_key + "_source"] = source
		_aggregated_report[phase_key + "_total_cells"] = _phase_cells.size()

	var total_cells: int = _phase_cells.size()
	var cells_scanned: int = 0
	while _phase_cursor < total_cells and cells_scanned < remaining_budget:
		if cells_scanned > 0 and Time.get_ticks_usec() >= deadline_us:
			break
		var chunk_size_limit: int = _chunk_size_limit_for_baker(baker_key)
		var chunk_budget: int = mini(chunk_size_limit, remaining_budget - cells_scanned)
		var end_cursor: int = mini(total_cells, _phase_cursor + chunk_budget)
		var slice_size: int = end_cursor - _phase_cursor
		if slice_size <= 0:
			break
		var step_us: int = Time.get_ticks_usec()
		# [perf 2026-05-20] 方案 C：Callable 直调；hot path 单次省 ~50-100μs。
		if _cb_step.is_valid():
			_cb_step.call(map, world_data, _phase_ctx, _phase_cells,
					_phase_report, _phase_cursor, end_cursor)
		else:
			var step_method: String = "%s_chunk_step" % baker_key
			baker.call(step_method, map, world_data, _phase_ctx, _phase_cells,
					_phase_report, _phase_cursor, end_cursor)
		_phase_cursor = end_cursor
		_aggregated_report["_cells_scanned_this_tick"] = \
				int(_aggregated_report.get("_cells_scanned_this_tick", 0)) + slice_size
		_aggregated_report[phase_key + "_cells_considered"] = \
				int(_aggregated_report.get(phase_key + "_cells_considered", 0)) + slice_size
		_aggregated_report[phase_key + "_step_ms"] = \
				float(_aggregated_report.get(phase_key + "_step_ms", 0.0)) \
				+ float(Time.get_ticks_usec() - step_us) / 1000.0
		cells_scanned += slice_size

	var phase_complete: bool = _phase_cursor >= total_cells
	if phase_complete:
		var finalize_us: int = Time.get_ticks_usec()
		# [perf 2026-05-20] 方案 C：Callable 直调。
		if _cb_finalize.is_valid():
			_cb_finalize.call(world_data, _phase_ctx, _phase_report)
		else:
			var finalize_method: String = "%s_chunk_finalize" % baker_key
			baker.call(finalize_method, world_data, _phase_ctx, _phase_report)
		_aggregated_report[phase_key + "_finalize_ms"] = \
				float(_aggregated_report.get(phase_key + "_finalize_ms", 0.0)) \
				+ float(Time.get_ticks_usec() - finalize_us) / 1000.0

	_phase_report.elapsed_ms = float(_phase_report.get("elapsed_ms", 0.0)) \
			+ float(Time.get_ticks_usec() - total_us) / 1000.0
	_aggregated_report[agg_dirty_key] = int(_phase_report.get("dirty_cells", 0))
	_aggregated_report[agg_ms_key] = float(_phase_report.get("elapsed_ms", 0.0))
	_aggregated_report[phase_key + "_pixels_written"] = int(_phase_report.get("pixels_written", 0))
	_aggregated_report[phase_key + "_path"] = str(_phase_report.get("path", ""))
	_aggregated_report[phase_key + "_fallback_reason"] = str(_phase_report.get("fallback_reason", ""))
	_aggregated_report[phase_key + "_cpp_calls"] = int(_phase_report.get("cpp_calls", 0))
	_aggregated_report[phase_key + "_gd_calls"] = int(_phase_report.get("gd_calls", 0))
	_aggregated_report[phase_key + "_empty_calls"] = int(_phase_report.get("empty_calls", 0))

	return phase_complete


# Stride 完成 tick 的最终 report 组装。
func _finalize_stride(elapsed_ms: float) -> Dictionary:
	_dvas_diag_stride_count += 1
	_dvas_diag_ticks_accum += _total_ticks_used
	# [diag 2026-05-20 phase-breakdown] 累加本 stride 的 phase ms 切片到窗口累加器。
	for key in _dvas_diag_phase_ms_accum.keys():
		_dvas_diag_phase_ms_accum[key] = float(_dvas_diag_phase_ms_accum[key]) \
				+ float(_aggregated_report.get(key, 0.0))
	if _dvas_diag_stride_count >= _dvas_diag_avg_window:
		var avg_ticks: float = float(_dvas_diag_ticks_accum) / float(_dvas_diag_stride_count)
		var n: float = float(_dvas_diag_stride_count)
		# 顶层数字（保持原有格式以免破坏旧 dashboard / grep）
		print_rich("[color=#888]dynamic_visual_atlas_upload diag: avg_ticks_per_stride=%.2f, max_tick_ms=%.2f (over %d strides)[/color]"
				% [avg_ticks, _dvas_diag_max_tick_ms, _dvas_diag_stride_count])
		# Phase 分解：每行一个 phase，prep/step/fin 三个分量（窗口均值, ms/stride）
		var dyn_p: float = float(_dvas_diag_phase_ms_accum["dynamic_prepare_ms"]) / n
		var dyn_s: float = float(_dvas_diag_phase_ms_accum["dynamic_step_ms"]) / n
		var dyn_f: float = float(_dvas_diag_phase_ms_accum["dynamic_finalize_ms"]) / n
		var eco_p: float = float(_dvas_diag_phase_ms_accum["ecology_prepare_ms"]) / n
		var eco_s: float = float(_dvas_diag_phase_ms_accum["ecology_step_ms"]) / n
		var eco_f: float = float(_dvas_diag_phase_ms_accum["ecology_finalize_ms"]) / n
		var smo_p: float = float(_dvas_diag_phase_ms_accum["smooth_prepare_ms"]) / n
		var smo_s: float = float(_dvas_diag_phase_ms_accum["smooth_step_ms"]) / n
		var smo_f: float = float(_dvas_diag_phase_ms_accum["smooth_finalize_ms"]) / n
		var ice_p: float = float(_dvas_diag_phase_ms_accum["ice_prepare_ms"]) / n
		var ice_s: float = float(_dvas_diag_phase_ms_accum["ice_step_ms"]) / n
		var ice_f: float = float(_dvas_diag_phase_ms_accum["ice_finalize_ms"]) / n
		var total: float = dyn_p + dyn_s + dyn_f + eco_p + eco_s + eco_f \
				+ smo_p + smo_s + smo_f + ice_p + ice_s + ice_f
		print_rich("[color=#888]  phase breakdown (avg ms/stride, prep+step+fin):"
				+ " dyn=%.2f+%.2f+%.2f eco=%.2f+%.2f+%.2f smo=%.2f+%.2f+%.2f ice=%.2f+%.2f+%.2f sum=%.2f[/color]"
				% [dyn_p, dyn_s, dyn_f, eco_p, eco_s, eco_f, smo_p, smo_s, smo_f, ice_p, ice_s, ice_f, total])
		_dvas_diag_stride_count = 0
		_dvas_diag_ticks_accum = 0
		_dvas_diag_max_tick_ms = 0.0
		for key2 in _dvas_diag_phase_ms_accum.keys():
			_dvas_diag_phase_ms_accum[key2] = 0.0

	var report: Dictionary = _build_report(true, elapsed_ms)
	_last_breakdown = report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return report


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


func _clear_cpp_commit_queue() -> void:
	_cpp_commit_queue.clear()
	_cpp_commit_context = {}


# ─── plan/atlas-pipeline-cpp 薄壳路径 ─────────────────────────────────────

# 是否启用 cpp_atlas_pipeline 全量 DOTS 路径。要求：
#   1. climate_profile 不为空（默认 ResourceLoader 注入）
# dots-flag-prune-pr1 round 2: cpp_atlas_pipeline_enabled flag 已删除——恒走 ext +
# has_method(run_atlas_pipeline_step) 探测分支（ext 缺失时透明 fallback 到旧 4-phase 状态机）。
# 本 helper 作为后兼容保留，恒返 true。
func _is_cpp_atlas_pipeline_enabled() -> bool:
	return true


# plan/sim-2ms-simd-dirty-budget 任务 7（2026-05-21）：dynamic_visual_atlas dirty
# 编码 kill-switch。dots-flag-prune-pr1 round 2: use_gdext_dynamic_atlas_terminal_dirty
# flag 已删除——恒走 cpp 现行 dirty 路径（dirty_indices 比对 + value-diff + 1-跳
# 邻居膨胀），不再提供 A/B 对照与回归排障入口。本 helper 恒返 true。
func _is_dynamic_atlas_terminal_dirty_enabled() -> bool:
	return true


# 取 DCWorld 挂载的 _world_ext / _ext（与 _should_use_ext_encode 同模式，
# 走 .get() 反射避免对 DCWorld 内部命名强耦合）。
func _get_world_ext():
	if world_ext != null:
		return world_ext
	if world_data == null:
		if baker != null:
			return baker.get("_world_ext")
		return null
	var ext = world_data.get("_world_ext")
	if ext == null:
		ext = world_data.get("_ext")
	if ext == null and baker != null:
		ext = baker.get("_world_ext")
	return ext


# 主入口：cpp_atlas_pipeline 薄壳。
# 1) 一次性原子读 dirty_indices；2) 首次调用前做 ecology 持久状态 burn-in；
# 3) 调 run_atlas_pipeline_step 拿 atlas_buffers + ms_breakdown；
# 4) 4 次 ImageTexture.update；5) 复用 _dvas_diag_* 采样窗口与 phase breakdown 输出。
func _tick_cpp_pipeline(t_start_us: int, ext: Object) -> Dictionary:
	# ── plan/atlas-phase-slicing：mid-stride 守卫 ──
	# 上一 tick C++ 返回 done=false 表示 stride 没跑完（phase_budget < 4），
	# 本 tick 不应再读 dirty / burn-in，直接 call C++ 推下一个 phase。
	var is_mid_stride: bool = _cpp_stride_in_progress

	# ── Step 1：原子读 dirty_indices（只在 stride 起点做，mid-stride 时复用 C++ 缓存）──
	var dirty_indices: PackedInt32Array = PackedInt32Array()
	var dirty_path_used: bool = false
	var dirty_reason: String = ""
	var dirty_source_tag: String = ""
	var dirty_mask_available: bool = false
	if not is_mid_stride and _is_dirty_push_enabled():
		var dirty_source = dirty_world if dirty_world != null else world_data
		dirty_source_tag = "dirty_world" if dirty_world != null else "world_data"
		if dirty_source != null and dirty_source.has_method("read_and_clear_dirty_mask"):
			var has_mask: bool = true
			if dirty_source.has_method("dirty_mask_size") \
					and int(dirty_source.dirty_mask_size()) <= 0:
				has_mask = false
				dirty_reason = "dirty_mask_size_zero"
			if has_mask:
				dirty_mask_available = true
				dirty_indices = dirty_source.read_and_clear_dirty_mask()
				dirty_path_used = true
				dirty_reason = "dirty" if dirty_indices.size() > 0 else "no_dirty"
		else:
			dirty_reason = "read_and_clear_missing"
	elif is_mid_stride:
		dirty_reason = "mid_stride_reuse"
	else:
		dirty_reason = "flag_disabled"

	# ── Step 2：burn-in ecology 持久状态（首次 / 地图重生时；mid-stride 不做）──
	if not is_mid_stride and (not _eco_burnin_done or _pending_burnin) \
			and ext.has_method(&"migrate_eco_persistent_from_gd"):
		_burn_in_eco_state(ext)
		_eco_burnin_done = true
		_pending_burnin = false

	# ── Step 3：构造 opts → 调 run_atlas_pipeline_step ──
	var W: int = int(world_data.derived_size.x) if world_data != null else 0
	var H: int = int(world_data.derived_size.y) if world_data != null else 0
	# plan/sim-2ms-simd-dirty-budget 任务 7：dirty 编码 kill-switch（默认 true）。
	# false 时跳过传 dirty_indices 并加 force_full_encode=true，cpp 入口会覆盖
	# dirty_path_used=false 让 4 phase 全集编码（A/B 对照与回归排障）。
	var dvas_terminal_dirty_on: bool = _is_dynamic_atlas_terminal_dirty_enabled()
	var opts: Dictionary = {
		"world": world_data,
		"map": map,
		"width": W,
		"height": H,
		"terrain_lake": int(TerrainTypeScript.TERRAIN.LAKE),
		"terrain_sea_ice": int(TerrainTypeScript.TERRAIN.SEA_ICE),
		"veg_none": int(VegetationTypeScript.VEG.NONE),
		"enable_diag": true,
		"phase_budget": CPP_PIPELINE_PHASE_BUDGET,
		"max_smooth_cells_per_call": CPP_SMOOTH_CELLS_PER_CALL,
	}
	# dirty_indices 仅在 stride 起点传一次（mid-stride 时 C++ 从 stride snapshot 复用）。
	# 任务 7 kill-switch：flag=false 时显式不传 dirty_indices 并设置 force_full_encode，
	# 让 cpp 端把 dirty_path_used 钉为 false（覆盖默认按 opts.has 决策）。
	if dirty_path_used and dvas_terminal_dirty_on:
		opts["dirty_indices"] = dirty_indices
	if not dvas_terminal_dirty_on:
		opts["force_full_encode"] = true
	var t_call_us: int = Time.get_ticks_usec()
	var res: Dictionary = ext.call(&"run_atlas_pipeline_step", opts)
	var call_ms: float = float(Time.get_ticks_usec() - t_call_us) / 1000.0
	# [TEMP DIAG sea-ice cpp-res]
	if not Engine.has_meta("_diag_cpp_res_dumped"):
		Engine.set_meta("_diag_cpp_res_dumped", 0)
	var _crd: int = int(Engine.get_meta("_diag_cpp_res_dumped"))
	if _crd < 6:
		var _ab: Dictionary = res.get("atlas_buffers", {})
		var _sr: Dictionary = res.get("stride_real", {})
		var _smo_buf: PackedByteArray = _ab.get("smo", PackedByteArray())
		var _dyn_buf: PackedByteArray = _ab.get("dyn", PackedByteArray())
		print("[CPP-RES] fallback=", res.get("fallback", "?"),
			" done=", res.get("done", "?"),
			" reason=", res.get("reason", ""),
			" ab.keys=", _ab.keys(),
			" smo.sz=", _smo_buf.size(), " dyn.sz=", _dyn_buf.size(),
			" stride_real=", _sr,
			" call_ms=", call_ms)
		Engine.set_meta("_diag_cpp_res_dumped", _crd + 1)

	if bool(res.get("fallback", true)):
		# C++ 端在前置校验失败时会返回 fallback=true。退化为旧路径以保安全。
		if not _cpp_pipeline_warned_missing_method:
			_cpp_pipeline_warned_missing_method = true
			push_warning("[atlas-pipeline-cpp] run_atlas_pipeline_step fallback=true reason=",
					String(res.get("reason", "")), "; 本 stride fallback 到旧 4-phase 路径")
		# 软回退：重置 mid-stride 状态，让下一 tick 重启。
		_cpp_stride_in_progress = false
		# plan/atlas-phase-slicing 诊断（2026-05-21）：把 fallback reason 透传给 oneshot
		# 的 report，让 CSV 能直接看出来 cpp_pipeline 为什么没生效。
		_pending_fallback_reason = String(res.get("reason", "unknown"))
		return _tick_oneshot(t_start_us)

	# ── plan/atlas-phase-slicing：判定本 tick 是否完成整段 stride ──
	# done=false → mid-stride，不 commit GPU（atlas_buffers 为空 Dict），
	# 设置 _cpp_stride_in_progress=true 让下一 tick 继续推 phase。
	var stride_done: bool = bool(res.get("done", true))
	_cpp_stride_in_progress = not stride_done

	# ── Step 4：收集待提交 atlas（仅在 stride_done 时有 atlas_buffers）──
	var atlas_buffers: Dictionary = res.get("atlas_buffers", {})
	var stride_real: Dictionary = res.get("stride_real", {})

	# ── Step 5：诊断与 report 组装 ──
	# mid-stride 时只更新 max_tick_ms（用于诊断单 tick 抖动），不累加 stride 计数；
	# stride_done 时才完整累加并触发窗口输出（保持窗口=stride 数语义）。
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	_dvas_diag_max_tick_ms = max(_dvas_diag_max_tick_ms, elapsed_ms)
	var ms_breakdown: Dictionary = res.get("ms_breakdown", {})
	if stride_done:
		_dvas_diag_stride_count += 1
		_dvas_diag_ticks_accum += 1
		# 累加 C++ 返回的 ms_breakdown（stride_done 时拿到完整 4 phase 累计）
		for key in _dvas_diag_phase_ms_accum.keys():
			_dvas_diag_phase_ms_accum[key] = float(_dvas_diag_phase_ms_accum[key]) \
					+ float(ms_breakdown.get(key, 0.0))
		if _dvas_diag_stride_count >= _dvas_diag_avg_window:
			_print_phase_breakdown_window("cpp_pipeline")
			_dvas_diag_stride_count = 0
			_dvas_diag_ticks_accum = 0
			_dvas_diag_max_tick_ms = 0.0
			for k in _dvas_diag_phase_ms_accum.keys():
				_dvas_diag_phase_ms_accum[k] = 0.0
	else:
		# mid-stride：仅累 ticks_accum 计数，便于在窗口里看到"每 stride 用 N tick"。
		_dvas_diag_ticks_accum += 1

	# mid-stride 时返回最小 report，告诉调度器"本 tick 没完成 stride，下 tick 继续"。
	if not stride_done:
		var mid_report: Dictionary = {
			"done": false,
			"work_done": 0,
			"elapsed_ms": elapsed_ms,
			"progress_ratio": 0.0,
			"phase": "upload",
			"stage_name": "dynamic_visual_atlas_upload",
			"path": "cpp_pipeline_mid_stride",
			"call_ms": call_ms,
			"current_phase": int(res.get("phase", PHASE_IDLE)),
			"phase_cursor": int(res.get("cursor", 0)),
			"ticks_used": 1,
			"mid_stride": true,
			"phases_done_this_call": int(res.get("phases_done_this_call", 0)),
			# plan/atlas-phase-slicing 诊断（2026-05-21）：mid-stride 也写 _last_breakdown，
			# 否则 perf_recorder 在 mid-stride tick 拿到的是上一次 stride_done 的旧 dict，
			# CSV 看起来"每次都 done=true 4 phase 全跑"是假象。
			"phase_budget_effective": int(res.get("phase_budget_effective", -1)),
			"opts_has_phase_budget": bool(res.get("opts_has_phase_budget", false)),
			"opts_phase_budget_raw": int(res.get("opts_phase_budget_raw", -999)),
			"pixels_written": 0,
			"mask_path": dirty_path_used,
			"mask_dirty_count": dirty_indices.size(),
			"dirty_reason": dirty_reason,
			"dirty_source": dirty_source_tag,
			"dirty_mask_available": dirty_mask_available,
		}
		_last_breakdown = mid_report.duplicate(true)
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		_last_breakdown["_tick_idx"] = current_fast_tick_idx
		return mid_report

	var report: Dictionary = {
		"done": true,
		"work_done": int(stride_real.get("dyn", 0)) + int(stride_real.get("eco", 0)) \
				+ int(stride_real.get("smo", 0)) + int(stride_real.get("ice", 0)),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"phase": "upload",
		"stage_name": "dynamic_visual_atlas_upload",
		"path": "cpp_pipeline",
		"call_ms": call_ms,
		"total_ms": float(res.get("total_ms", 0.0)),
		"current_phase": PHASE_DONE,
		"phase_cursor": 0,
		"ticks_used": 1,
		"dynamic_dirty_cells": int(stride_real.get("dyn", 0)),
		"ecology_dirty_cells": int(stride_real.get("eco", 0)),
		"smooth_dirty_cells": int(stride_real.get("smo", 0)),
		"ice_dirty_cells": int(stride_real.get("ice", 0)),
		"pixels_written": 0,
		"commit_queue_total": 0,
		"commit_queue_remaining": 0,
		"commit_textures_done": 0,
		"commit_pixels_written": 0,
		"commit_ms": 0.0,
		"commit_channel": "",
		"commit_skipped_unchanged": 0,
		"total_ticks_used": 1,
		"mask_path": dirty_path_used,
		"mask_dirty_count": dirty_indices.size(),
		"dirty_reason": dirty_reason,
		"dirty_source": dirty_source_tag,
		"dirty_mask_available": dirty_mask_available,
		"max_cells_per_tick": MAX_CELLS_PER_TICK,
		"time_check_cells_per_step": TIME_CHECK_CELLS_PER_STEP,
		"cpp_time_check_cells_per_step": CPP_TIME_CHECK_CELLS_PER_STEP,
		"slice_budget_ms": slice_budget_ms,
		"dynamic_prepare_ms": float(ms_breakdown.get("dynamic_prepare_ms", 0.0)),
		"dynamic_step_ms": float(ms_breakdown.get("dynamic_step_ms", 0.0)),
		"dynamic_finalize_ms": float(ms_breakdown.get("dynamic_finalize_ms", 0.0)),
		"dynamic_cpp_calls": 1,
		"dynamic_gd_calls": 0,
		"dynamic_empty_calls": 0,
		"dynamic_source": "cpp_pipeline",
		"dynamic_path": "cpp_pipeline",
		"dynamic_fallback_reason": "",
		"ecology_prepare_ms": float(ms_breakdown.get("ecology_prepare_ms", 0.0)),
		"ecology_step_ms": float(ms_breakdown.get("ecology_step_ms", 0.0)),
		"ecology_finalize_ms": float(ms_breakdown.get("ecology_finalize_ms", 0.0)),
		"ecology_cpp_calls": 1,
		"ecology_gd_calls": 0,
		"ecology_empty_calls": 0,
		"ecology_source": "cpp_pipeline",
		"ecology_path": "cpp_pipeline",
		"ecology_fallback_reason": "",
		"smooth_prepare_ms": float(ms_breakdown.get("smooth_prepare_ms", 0.0)),
		"smooth_step_ms": float(ms_breakdown.get("smooth_step_ms", 0.0)),
		"smooth_finalize_ms": float(ms_breakdown.get("smooth_finalize_ms", 0.0)),
		"smooth_cpp_calls": 1,
		"smooth_gd_calls": 0,
		"smooth_empty_calls": 0,
		"smooth_source": "cpp_pipeline",
		"smooth_path": "cpp_pipeline",
		"smooth_fallback_reason": "",
		"ice_prepare_ms": float(ms_breakdown.get("ice_prepare_ms", 0.0)),
		"ice_step_ms": float(ms_breakdown.get("ice_step_ms", 0.0)),
		"ice_finalize_ms": float(ms_breakdown.get("ice_finalize_ms", 0.0)),
		"ice_cpp_calls": 1,
		"ice_gd_calls": 0,
		"ice_empty_calls": 0,
		"ice_source": "cpp_pipeline",
		"ice_path": "cpp_pipeline",
		"ice_fallback_reason": "",
		# plan/atlas-phase-slicing 诊断（2026-05-21）：把 C++ 实际看到的 phase_budget
		# 透传到 CSV，方便确认 opts marshalling 是否正确。预期：opts_has=true、raw=1、effective=1。
		"phase_budget_effective": int(res.get("phase_budget_effective", -1)),
		"opts_has_phase_budget": bool(res.get("opts_has_phase_budget", false)),
		"opts_phase_budget_raw": int(res.get("opts_phase_budget_raw", -999)),
	}
	_begin_cpp_commit_queue(atlas_buffers, W, H, stride_real, report)
	if not _cpp_commit_queue.is_empty():
		return _drain_cpp_commit_queue(t_start_us)
	_last_breakdown = report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return report


func _begin_cpp_commit_queue(atlas_buffers: Dictionary, W: int, H: int,
		stride_real: Dictionary, base_report: Dictionary) -> void:
	_cpp_commit_queue.clear()
	_cpp_commit_skip_count = 0
	if atlas_buffers.is_empty() or W <= 0 or H <= 0:
		return
	# [TEMP DIAG sea-ice begin-commit]
	if not Engine.has_meta("_diag_begin_commit_dumped"):
		Engine.set_meta("_diag_begin_commit_dumped", 0)
	var _bcd: int = int(Engine.get_meta("_diag_begin_commit_dumped"))
	if _bcd < 6:
		var _bd: PackedByteArray = atlas_buffers.get("dyn", PackedByteArray())
		var _bs: PackedByteArray = atlas_buffers.get("smo", PackedByteArray())
		var _be: PackedByteArray = atlas_buffers.get("eco", PackedByteArray())
		var _bi: PackedByteArray = atlas_buffers.get("ice", PackedByteArray())
		print("[BEGIN-COMMIT] W=", W, " H=", H,
			" dyn.sz=", _bd.size(), " smo.sz=", _bs.size(),
			" eco.sz=", _be.size(), " ice.sz=", _bi.size(),
			" stride_real=", stride_real)
		Engine.set_meta("_diag_begin_commit_dumped", _bcd + 1)
	var n_pix: int = W * H
	# 方案A 修复（2026-05-26）：当 stride_done=true 进入此函数时，atlas_buffers 已是
	# 完整全量图（C++ pipeline 跨 4 phase 累计写完后才会一次性返回）。但 stride_real
	# 只反映当前最后一个 phase 的单次写入计数，因此 dyn/smo/eco 的 stride_real 常为 0。
	# 必须用 force_commit=true 绕过单 phase stride 守卫，把 4 张图一次性入队。
	_maybe_enqueue_cpp_commit_task("dyn", atlas_buffers.get("dyn", PackedByteArray()),
			Image.FORMAT_RGBA8, 4, int(stride_real.get("dyn", 0)),
			world_data.dynamic_cell_atlas_tex == null
					or world_data.dynamic_cell_atlas_tex.get_size() != Vector2(float(W), float(H))
					or world_data.dynamic_cell_atlas_buffer.size() != n_pix * 4,
			W, H, n_pix, true)
	_maybe_enqueue_cpp_commit_task("eco", atlas_buffers.get("eco", PackedByteArray()),
			Image.FORMAT_RGBA8, 4, int(stride_real.get("eco", 0)),
			world_data.ecology_visual_atlas_tex == null
					or world_data.ecology_visual_atlas_tex.get_size() != Vector2(float(W), float(H))
					or world_data.ecology_visual_atlas_buffer.size() != n_pix * 4,
			W, H, n_pix, true)
	_maybe_enqueue_cpp_commit_task("smo", atlas_buffers.get("smo", PackedByteArray()),
			Image.FORMAT_RGBA8, 4, int(stride_real.get("smo", 0)),
			world_data.dyn_atlas_smooth_tex == null
					or world_data.dyn_atlas_smooth_tex.get_size() != Vector2(float(W), float(H))
					or world_data.dyn_atlas_smooth_buffer.size() != n_pix * 4,
			W, H, n_pix, true)
	_maybe_enqueue_cpp_commit_task("ice", atlas_buffers.get("ice", PackedByteArray()),
			Image.FORMAT_R8, 1, int(stride_real.get("ice", 0)),
			world_data.ice_state_tex == null
					or world_data.ice_state_tex.get_size() != Vector2(float(W), float(H))
					or world_data.ice_state_buffer.size() != n_pix,
			W, H, n_pix, true)
	if _cpp_commit_queue.is_empty():
		base_report["commit_skipped_unchanged"] = _cpp_commit_skip_count
		return
	_cpp_commit_context = base_report.duplicate(true)
	_cpp_commit_context["path"] = "cpp_pipeline_commit_queue"
	_cpp_commit_context["phase"] = "upload_commit"
	_cpp_commit_context["commit_queue_total"] = _cpp_commit_queue.size()
	_cpp_commit_context["commit_queue_remaining"] = _cpp_commit_queue.size()
	_cpp_commit_context["commit_textures_done"] = 0
	_cpp_commit_context["commit_pixels_written"] = 0
	_cpp_commit_context["commit_ms"] = 0.0
	_cpp_commit_context["commit_channel"] = ""
	_cpp_commit_context["commit_skipped_unchanged"] = _cpp_commit_skip_count
	_cpp_commit_context["commit_ticks_used"] = 0


func _current_cpp_atlas_buffer(channel: String) -> PackedByteArray:
	match channel:
		"dyn":
			return world_data.dynamic_cell_atlas_buffer
		"eco":
			return world_data.ecology_visual_atlas_buffer
		"smo":
			return world_data.dyn_atlas_smooth_buffer
		"ice":
			return world_data.ice_state_buffer
		_:
			return PackedByteArray()


func _maybe_enqueue_cpp_commit_task(channel: String, buf: PackedByteArray,
		image_format: int, bytes_per_pixel: int, stride_count: int,
		need_init: bool, W: int, H: int, n_pix: int,
		force_commit: bool = false) -> void:
	var expected_size: int = n_pix * bytes_per_pixel
	if buf.size() != expected_size:
		return
	if stride_count <= 0 and not need_init:
		var current_buf: PackedByteArray = _current_cpp_atlas_buffer(channel)
		if current_buf.size() == expected_size and current_buf == buf:
			_cpp_commit_skip_count += 1
			return
		if not force_commit:
			return
	# force_commit 仍允许初始化或 buffer 真变化时上传；完全相同的全量图不再碰 GPU。
	if not force_commit and stride_count <= 0 and not need_init:
		return
	_cpp_commit_queue.append({
		"channel": channel,
		"buffer": buf,
		"format": image_format,
		"stride_count": stride_count,
		"need_init": need_init,
		"W": W,
		"H": H,
		"pixels": n_pix,
	})


func _drain_cpp_commit_queue(t_start_us: int) -> Dictionary:
	var report: Dictionary = _cpp_commit_context.duplicate(true)
	# 移动端每 tick 只 commit 1 张 atlas，桌面 4 张。see CPP_COMMIT_TEXTURES_PER_TICK_*.
	var textures_this_tick: int = mini(_cpp_commit_textures_per_tick(), _cpp_commit_queue.size())
	var tick_commit_ms: float = 0.0
	var tick_pixels: int = 0
	var last_channel: String = ""
	for _i in range(textures_this_tick):
		var task: Dictionary = _cpp_commit_queue.pop_front()
		var t_commit_us: int = Time.get_ticks_usec()
		tick_pixels += _commit_cpp_atlas_task_to_gpu(task)
		tick_commit_ms += float(Time.get_ticks_usec() - t_commit_us) / 1000.0
		last_channel = str(task.get("channel", ""))
	var committed: int = int(report.get("commit_textures_done", 0)) + textures_this_tick
	var total: int = int(report.get("commit_queue_total", committed))
	var pixels_done: int = int(report.get("commit_pixels_written", 0)) + tick_pixels
	var commit_ticks: int = int(report.get("commit_ticks_used", 0)) + 1
	var done: bool = _cpp_commit_queue.is_empty()
	report["done"] = done
	report["progress_ratio"] = 1.0 if total <= 0 else float(committed) / float(total)
	report["elapsed_ms"] = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	report["path"] = "cpp_pipeline_commit_queue"
	report["phase"] = "upload_commit"
	report["commit_channel"] = last_channel
	report["commit_ms"] = tick_commit_ms
	report["commit_queue_total"] = total
	report["commit_queue_remaining"] = _cpp_commit_queue.size()
	report["commit_textures_done"] = committed
	report["commit_pixels_written"] = pixels_done
	report["commit_skipped_unchanged"] = int(report.get("commit_skipped_unchanged", 0))
	report["pixels_written"] = pixels_done
	report["commit_ticks_used"] = commit_ticks
	report["ticks_used"] = int(report.get("ticks_used", 1)) + commit_ticks - 1
	report["total_ticks_used"] = int(report.get("total_ticks_used", 1)) + commit_ticks - 1
	_dvas_diag_max_tick_ms = max(_dvas_diag_max_tick_ms, float(report["elapsed_ms"]))
	if done:
		_cpp_commit_context = {}
	else:
		_cpp_commit_context = report.duplicate(true)
		_cpp_commit_context.erase("_tick_idx")
	_last_breakdown = report.duplicate(true)
	_last_breakdown["_tick_idx"] = current_fast_tick_idx
	return report


func _commit_cpp_atlas_task_to_gpu(task: Dictionary) -> int:
	var channel: String = str(task.get("channel", ""))
	var buf: PackedByteArray = task.get("buffer", PackedByteArray())
	var W: int = int(task.get("W", 0))
	var H: int = int(task.get("H", 0))
	var pixels: int = int(task.get("pixels", 0))
	if W <= 0 or H <= 0 or pixels <= 0:
		return 0
	# [TEMP DIAG sea-ice cpp-commit]
	if not Engine.has_meta("_diag_cpp_commit_dumped"):
		Engine.set_meta("_diag_cpp_commit_dumped", 0)
	var _ndump: int = int(Engine.get_meta("_diag_cpp_commit_dumped"))
	if _ndump < 12:
		var _samp_pxs: Array = [8584, 4586, 4843, 5091, 719]
		var _samp: String = ""
		for _px in _samp_pxs:
			var _i: int = int(_px)
			var _stride: int = 4 if channel != "ice" else 1
			var _byte_off: int = _i * _stride + (3 if _stride == 4 else 0)
			if _byte_off >= 0 and _byte_off < buf.size():
				_samp += " px%d.A=%d" % [_i, int(buf[_byte_off])]
		print("[CPP-COMMIT] ch=", channel, " buf.size=", buf.size(),
			" expected=", pixels * (1 if channel == "ice" else 4),
			" W=", W, " H=", H, _samp)
		Engine.set_meta("_diag_cpp_commit_dumped", _ndump + 1)
	var image_format: int = int(task.get("format", Image.FORMAT_RGBA8))
	# Fix #3 (2026-06-15)：包 profile 到 GPU upload。frame=2587/3520 max=549.95ms /
	# 521.18ms spike 与 ice atlas commit 时间对齐；嫌疑是
	# ImageTexture.create_from_image() 首次为通道分配 VRAM 时的同步 stall
	# （Adreno 830 GPU 内存 mapping）。打点确认 root cause 后再决定是否
	# defer 到 RenderingServer 队列。
	var _commit_t0_us: int = Time.get_ticks_usec()
	var img := Image.create_from_data(
			W, H, false,
			Image.FORMAT_R8 if image_format == int(Image.FORMAT_R8) else Image.FORMAT_RGBA8,
			buf)
	var _img_create_ms: float = float(Time.get_ticks_usec() - _commit_t0_us) / 1000.0
	var _create_from_image_path: bool = false
	var _commit_t1_us: int = Time.get_ticks_usec()
	match channel:
		"dyn":
			world_data.dynamic_cell_atlas_buffer = buf
			if world_data.dynamic_cell_atlas_tex != null \
					and world_data.dynamic_cell_atlas_tex.get_size() == Vector2(float(W), float(H)):
				world_data.dynamic_cell_atlas_tex.update(img)
			else:
				world_data.dynamic_cell_atlas_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
		"eco":
			world_data.ecology_visual_atlas_buffer = buf
			if world_data.ecology_visual_atlas_tex != null \
					and world_data.ecology_visual_atlas_tex.get_size() == Vector2(float(W), float(H)):
				world_data.ecology_visual_atlas_tex.update(img)
			else:
				world_data.ecology_visual_atlas_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
		"smo":
			world_data.dyn_atlas_smooth_buffer = buf
			if world_data.dyn_atlas_smooth_tex != null \
					and world_data.dyn_atlas_smooth_tex.get_size() == Vector2(float(W), float(H)):
				world_data.dyn_atlas_smooth_tex.update(img)
			else:
				world_data.dyn_atlas_smooth_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
		"ice":
			world_data.ice_state_buffer = buf
			if world_data.ice_state_tex != null \
					and world_data.ice_state_tex.get_size() == Vector2(float(W), float(H)):
				world_data.ice_state_tex.update(img)
			else:
				world_data.ice_state_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
			_dvas_ice_commit_runs = int(_dvas_ice_commit_runs) + 1
			if _dvas_ice_commit_runs <= 3 or (_dvas_ice_commit_runs % 60) == 0:
				_log_ice_commit_sample(buf, bool(task.get("need_init", false)),
						int(task.get("stride_count", 0)))
		_:
			return 0
	var _tex_phase_ms: float = float(Time.get_ticks_usec() - _commit_t1_us) / 1000.0
	var _total_commit_ms: float = float(Time.get_ticks_usec() - _commit_t0_us) / 1000.0
	# Fix #3：高耗时直接打 warn，spike 时定位 root cause。25ms 阈值挑得偏严，
	# 但 mobile commit 期望 ≤ 5ms，>25ms 就是真实问题。
	if _total_commit_ms > 25.0:
		push_warning("[atlas/commit-spike] ch=%s total=%.1fms img_create=%.1fms tex_%s=%.1fms W=%d H=%d buf=%dB path=%s" % [
			channel, _total_commit_ms, _img_create_ms,
			"create" if _create_from_image_path else "update",
			_tex_phase_ms, W, H, buf.size(),
			"ImageTexture.create_from_image" if _create_from_image_path else "ImageTexture.update",
		])
	return pixels


func _log_ice_commit_sample(buf_ice: PackedByteArray, need_init: bool,
		stride_count: int) -> void:
	var ice_nonzero: int = 0
	var ice_max: int = 0
	var ice_n: int = buf_ice.size()
	for bi in range(ice_n):
		var bv: int = int(buf_ice[bi])
		if bv > 0:
			ice_nonzero += 1
			if bv > ice_max:
				ice_max = bv
	print("[ice_atlas/COMMIT] run#%d need_init=%s stride=%d buf_n=%d nonzero=%d max=%d tex_rid=%s" % [
		_dvas_ice_commit_runs, str(need_init), stride_count,
		ice_n, ice_nonzero, ice_max,
		str(world_data.ice_state_tex.get_rid()) if world_data.ice_state_tex != null else "<null>",
	])


# burn-in：把 baker 端 ecology 持久状态一次性灌到 C++ AtlasPipelineState。
# 调用时机：本系统首次调 _tick_cpp_pipeline，或 _pending_burnin=true（外部
# 通知地图重生）。失败不抛错，只记日志，让 C++ 用 SoA cur 自启 baseline。
func _burn_in_eco_state(ext: Object) -> void:
	var state: Dictionary = {}
	# transition_age：直接拿 baker 端 SoA byte 数组（PackedByteArray）
	var tr_arr = baker.get("_eco_transition_age_arr")
	if tr_arr is PackedByteArray and tr_arr.size() > 0:
		state["transition_age"] = tr_arr
	# active_decay：从 _eco_active_decay_set 提 cell.index 列表
	var decay_set = baker.get("_eco_active_decay_set")
	if decay_set is Dictionary and not decay_set.is_empty():
		var idxs: PackedInt32Array = PackedInt32Array()
		idxs.resize(decay_set.size())
		var w: int = 0
		for cell in decay_set.keys():
			if cell != null and cell.index >= 0:
				idxs[w] = cell.index
				w += 1
		idxs.resize(w)
		state["active_decay"] = idxs
	ext.call(&"migrate_eco_persistent_from_gd", state)
	print("[atlas-pipeline-cpp] eco burn-in: transition_age=%d active_decay=%d" % [
		int(state.get("transition_age", PackedByteArray()).size()),
		int(state.get("active_decay", PackedInt32Array()).size()),
	])


# 复用 _finalize_stride 的 phase breakdown 打印格式（cpp_pipeline 路径同款 grep）。
func _print_phase_breakdown_window(path_tag: String) -> void:
	var n: float = float(_dvas_diag_stride_count)
	if n <= 0.0:
		return
	var avg_ticks: float = float(_dvas_diag_ticks_accum) / n
	print_rich("[color=#888]dynamic_visual_atlas_upload diag(%s): avg_ticks_per_stride=%.2f, max_tick_ms=%.2f (over %d strides)[/color]"
			% [path_tag, avg_ticks, _dvas_diag_max_tick_ms, _dvas_diag_stride_count])
	var dyn_p: float = float(_dvas_diag_phase_ms_accum["dynamic_prepare_ms"]) / n
	var dyn_s: float = float(_dvas_diag_phase_ms_accum["dynamic_step_ms"]) / n
	var dyn_f: float = float(_dvas_diag_phase_ms_accum["dynamic_finalize_ms"]) / n
	var eco_p: float = float(_dvas_diag_phase_ms_accum["ecology_prepare_ms"]) / n
	var eco_s: float = float(_dvas_diag_phase_ms_accum["ecology_step_ms"]) / n
	var eco_f: float = float(_dvas_diag_phase_ms_accum["ecology_finalize_ms"]) / n
	var smo_p: float = float(_dvas_diag_phase_ms_accum["smooth_prepare_ms"]) / n
	var smo_s: float = float(_dvas_diag_phase_ms_accum["smooth_step_ms"]) / n
	var smo_f: float = float(_dvas_diag_phase_ms_accum["smooth_finalize_ms"]) / n
	var ice_p: float = float(_dvas_diag_phase_ms_accum["ice_prepare_ms"]) / n
	var ice_s: float = float(_dvas_diag_phase_ms_accum["ice_step_ms"]) / n
	var ice_f: float = float(_dvas_diag_phase_ms_accum["ice_finalize_ms"]) / n
	var total: float = dyn_p + dyn_s + dyn_f + eco_p + eco_s + eco_f \
			+ smo_p + smo_s + smo_f + ice_p + ice_s + ice_f
	print_rich("[color=#888]  phase breakdown (avg ms/stride, prep+step+fin):"
			+ " dyn=%.2f+%.2f+%.2f eco=%.2f+%.2f+%.2f smo=%.2f+%.2f+%.2f ice=%.2f+%.2f+%.2f sum=%.2f[/color]"
			% [dyn_p, dyn_s, dyn_f, eco_p, eco_s, eco_f, smo_p, smo_s, smo_f, ice_p, ice_s, ice_f, total])


# 外部通知接口：地图重生成或 invalidate_atlas_csr_cache 时调，
# 让下一次 _tick_cpp_pipeline 重新做 ecology burn-in。
func notify_eco_burnin_pending() -> void:
	_pending_burnin = true
	_abort_smooth_prep("eco_burnin_pending")


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


func reconfigure(p_stride: int) -> void:
	_abort_smooth_prep("reconfigure")
	_reset_state_machine()
	_clear_cpp_commit_queue()
	_cpp_stride_in_progress = false
	stride = max(1, p_stride)
	# Fix #11: mobile C 桶 s8 p2 与 _init 一致
	if OS.has_feature("mobile"):
		_configure_lut_policy(8, 2)
	else:
		_configure_lut_policy(stride, 0)
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
