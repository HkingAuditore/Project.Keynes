extends DCSystem
class_name DynamicVisualAtlasUploadSystem

## Updates low-frequency visual atlases used by the main map shader.
##
## Stride=2 default：每 2 个仿真日跑一次（StridePolicy 控制）。
##
## v3：湿迹/龟裂短期痕迹视觉已删除；本系统只更新 dynamic/ecology/smooth/ice 四类视觉 atlas。
## 回退：`enable_time_slicing = false` 走 one-shot 路径。

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")


# ─── Phase 编号 ───────────────────────────────────────────────────────────────
const PHASE_IDLE: int = 0
const PHASE_DYNAMIC: int = 1
const PHASE_ECOLOGY: int = 2
const PHASE_SMOOTH: int = 3
const PHASE_ICE: int = 4
const PHASE_DONE: int = 5
const PHASE_COUNT: int = 4  # 实际工作 phase 数（1..4）

# 单 tick 最多扫多少 cell（跨 phase 共享预算的"软上限"）。
# 2026-05-19 方案 B：从 500 → 4096，单 tick 直接扫完一个 phase 的全部 cells，
# 避免 4 phase × 多 tick 串行导致雪量响应延迟数十仿真日。
# 实际 dirty 少时 chunk_step 走 sig 比对快速 skip，远未达上限就 phase 结束。
const MAX_CELLS_PER_TICK: int = 4096

# Soft budget = slice_budget_ms × 这个倍数，超出则 break 让出。
const SOFT_BUDGET_MULTIPLIER: float = 2.0

var baker: MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null
var stride: int = 2

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

# 诊断采样（沿用 _wf_diag_* 风格）。
var _dvas_diag_stride_count: int = 0
var _dvas_diag_ticks_accum: int = 0
var _dvas_diag_max_tick_ms: float = 0.0
var _dvas_diag_avg_window: int = 30


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData, p_stride: int = 2) -> void:
	id = &"dynamic_visual_atlas_upload"
	priority = 250
	# 2026-05-19 方案 B：默认 budget 从 0.45 → 1.5ms，配合 MAX_CELLS_PER_TICK=4096
	# 让一个 phase 在单 tick 内扫完。仍可被 climate_profile.sim_upload_slice_budget_ms 覆盖。
	slice_budget_ms = 1.5
	max_slices_per_tick = 1
	must_run = false
	starvation_threshold = 0
	baker = p_baker
	map = p_map
	world_data = p_world
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func tick(_ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}

	# 紧急回退：走旧 one-shot 路径。
	if not enable_time_slicing:
		return _tick_oneshot(t_start_us)

	# Soft budget：单 tick 不应超过这个数值；用作 phase 推进的让出阈值。
	var soft_budget_us: int = int(slice_budget_ms * SOFT_BUDGET_MULTIPLIER * 1000.0)

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
		var phase_done: bool = _advance_current_phase(remaining_budget)
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
	return {
		"done": false,
		"work_done": int(_aggregated_report.get("dynamic_dirty_cells", 0)) \
				+ int(_aggregated_report.get("ecology_dirty_cells", 0)) \
				+ int(_aggregated_report.get("smooth_dirty_cells", 0)),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(_phase) / float(PHASE_DONE),
		"phase": "upload_phase_%d" % _phase,
		"stage_name": "dynamic_visual_atlas_upload",
		"current_phase": _phase,
		"phase_cursor": _phase_cursor,
		"ticks_used": _total_ticks_used,
	}


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
		"_cells_scanned_this_tick": 0,
	}


# 推进当前 phase；返回 true 表示当前 phase 已完成（finalize 已调用），可切下一 phase。
# remaining_budget 是本 tick 还能扫多少 cell。
func _advance_current_phase(remaining_budget: int) -> bool:
	match _phase:
		PHASE_DYNAMIC:
			return _step_phase_baker(remaining_budget, "dynamic_cell_atlas",
					"dynamic_dirty_cells", "dynamic_ms")
		PHASE_ECOLOGY:
			return _step_phase_baker(remaining_budget, "ecology_visual_atlas",
					"ecology_dirty_cells", "ecology_ms")
		PHASE_SMOOTH:
			return _step_phase_baker(remaining_budget, "dyn_atlas_smooth",
					"smooth_dirty_cells", "smooth_ms")
		PHASE_ICE:
			return _step_phase_baker(remaining_budget, "ice_state_atlas",
					"ice_dirty_cells", "ice_ms")
		_:
			return true


# Phase 1..4：通用 baker chunk 推进。
# baker_key 决定调用哪组 chunk_begin/step/finalize；
# agg_dirty_key / agg_ms_key 是 aggregated_report 里的累计字段名。
func _step_phase_baker(remaining_budget: int, baker_key: String,
		agg_dirty_key: String, agg_ms_key: String) -> bool:
	var t_us: int = Time.get_ticks_usec()
	# 首次进入这个 phase：调用 chunk_begin + 准备 cell 序列。
	if _phase_ctx.is_empty():
		var begin_method: String = "%s_chunk_begin" % baker_key
		if not baker.has_method(begin_method):
			# baker 不支持该 phase（例如热回退老 baker） —— 跳过。
			return true
		_phase_ctx = baker.call(begin_method, map, world_data)
		if not bool(_phase_ctx.get("prepared", false)):
			# baker 自报未就绪（map/world 空、derived_size=0 等）—— 跳过。
			_phase_ctx = {}
			return true
		# Cell 数据源：ice_state 走 water_cell_pixel_lists，其它走 all_cells。
		if baker_key == "ice_state_atlas" \
				and baker.has_method("ice_state_atlas_default_cell_source"):
			_phase_cells = baker.ice_state_atlas_default_cell_source(map, world_data, _phase_ctx)
		else:
			_phase_cells = map.all_cells()
		_phase_cursor = 0
		_phase_report = {
			"prepared": true,
			"dirty": false,
			"dirty_cells": 0,
			"pixels_written": 0,
			"elapsed_ms": 0.0,
		}

	# 切一段 cell 子集出来，调用 chunk_step。
	var total_cells: int = _phase_cells.size()
	var end_cursor: int = min(total_cells, _phase_cursor + remaining_budget)
	var slice_size: int = end_cursor - _phase_cursor
	if slice_size > 0:
		var subset: Array = _phase_cells.slice(_phase_cursor, end_cursor)
		var step_method: String = "%s_chunk_step" % baker_key
		baker.call(step_method, map, world_data, _phase_ctx, subset, _phase_report)
		_phase_cursor = end_cursor
		_aggregated_report["_cells_scanned_this_tick"] = int(_aggregated_report.get("_cells_scanned_this_tick", 0)) + slice_size

	var phase_complete: bool = _phase_cursor >= total_cells
	if phase_complete:
		# 触发 GPU upload（仅这里允许；中间 tick 绝不上传）。
		var finalize_method: String = "%s_chunk_finalize" % baker_key
		baker.call(finalize_method, world_data, _phase_ctx, _phase_report)

	# 累加到 aggregated_report。
	_phase_report.elapsed_ms = float(_phase_report.get("elapsed_ms", 0.0)) \
			+ float(Time.get_ticks_usec() - t_us) / 1000.0
	_aggregated_report[agg_dirty_key] = int(_phase_report.get("dirty_cells", 0))
	_aggregated_report[agg_ms_key] = float(_phase_report.get("elapsed_ms", 0.0))

	return phase_complete


# Stride 完成 tick 的最终 report 组装。
func _finalize_stride(elapsed_ms: float) -> Dictionary:
	_dvas_diag_stride_count += 1
	_dvas_diag_ticks_accum += _total_ticks_used
	if _dvas_diag_stride_count >= _dvas_diag_avg_window:
		var avg_ticks: float = float(_dvas_diag_ticks_accum) / float(_dvas_diag_stride_count)
		print_rich("[color=#888]dynamic_visual_atlas_upload diag: avg_ticks_per_stride=%.2f, max_tick_ms=%.2f (over %d strides)[/color]"
				% [avg_ticks, _dvas_diag_max_tick_ms, _dvas_diag_stride_count])
		_dvas_diag_stride_count = 0
		_dvas_diag_ticks_accum = 0
		_dvas_diag_max_tick_ms = 0.0

	return {
		"done": true,
		"work_done": map.cell_count(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"phase": "upload",
		"stage_name": "dynamic_visual_atlas_upload",
		"dynamic_dirty_cells": int(_aggregated_report.get("dynamic_dirty_cells", 0)),
		"dynamic_ms": float(_aggregated_report.get("dynamic_ms", 0.0)),
		"ecology_dirty_cells": int(_aggregated_report.get("ecology_dirty_cells", 0)),
		"ecology_ms": float(_aggregated_report.get("ecology_ms", 0.0)),
		"smooth_dirty_cells": int(_aggregated_report.get("smooth_dirty_cells", 0)),
		"smooth_ms": float(_aggregated_report.get("smooth_ms", 0.0)),
		"ice_dirty_cells": int(_aggregated_report.get("ice_dirty_cells", 0)),
		"ice_ms": float(_aggregated_report.get("ice_ms", 0.0)),
		"total_ticks_used": _total_ticks_used,
	}


func _reset_state_machine() -> void:
	_phase = PHASE_IDLE
	_phase_cursor = 0
	_phase_cells = []
	_phase_ctx = {}
	_phase_report = {}
	_aggregated_report = {}
	_total_ticks_used = 0


# ─── 紧急回退：one-shot 路径 ───────────────────────────────────────────────
func _tick_oneshot(t_start_us: int) -> Dictionary:
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
	return {
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
	}


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)
