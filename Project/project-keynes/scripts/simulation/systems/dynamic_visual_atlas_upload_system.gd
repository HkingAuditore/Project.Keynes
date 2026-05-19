extends DCSystem
class_name DynamicVisualAtlasUploadSystem

## Updates low-frequency visual atlases used by the main map shader.
##
## Stride=2 default：每 2 个仿真日跑一次（StridePolicy 控制）。
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

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const FeatureFlagsScript = preload("res://scripts/data_core/feature_flags.gd")
const BakerDirtyHelpersScript = preload("res://scripts/rendering/bakers/baker_dirty_helpers.gd")


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

# 诊断采样（沿用 _wf_diag_* 风格）。
var _dvas_diag_stride_count: int = 0
var _dvas_diag_ticks_accum: int = 0
var _dvas_diag_max_tick_ms: float = 0.0
var _dvas_diag_avg_window: int = 30


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData, p_stride: int = 2, p_climate_profile = null) -> void:
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
	climate_profile = p_climate_profile
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
	# plan/dirty-push-atlas-encode 阶段 D：原子读 + 清零 mask，反查 cell 列表。
	# 单线程 SUS 调度保证 read_and_clear 的原子性（priority 100-200 的 sim 已写完，
	# 250 的 atlas upload 是唯一消费者）。
	_stride_dirty_indices = PackedInt32Array()
	_stride_dirty_cells = []
	_stride_dirty_path_used = false
	if not _is_dirty_push_enabled():
		return
	if world_data == null or not world_data.has_method("read_and_clear_dirty_mask"):
		return
	var dirty: PackedInt32Array = world_data.read_and_clear_dirty_mask()
	if dirty.size() <= 0:
		# mask 为空：可能是 use_data_core 关闭 / facade 关闭 / 本 stride 真无变化。
		# 记 path_used=true 仍然有意义（stride 结束 report 区分"flag 关"vs"无 dirty"）。
		_stride_dirty_path_used = true
		return
	_stride_dirty_indices = dirty
	_stride_dirty_path_used = true
	# 反查 HexCell：MapData.cell_by_index(idx) 是 O(1) 数组下标。
	_stride_dirty_cells.resize(dirty.size())
	var n: int = dirty.size()
	for i in range(n):
		var idx: int = dirty[i]
		var c: HexCell = map.cell_at(idx)
		_stride_dirty_cells[i] = c   # 允许 null（mask 越界容错；下游会过滤）


# plan/dirty-push-atlas-encode 阶段 D 私有 helper：
# 是否启用 dirty mask 路径。在 climate_profile == null 时返回 false 走 fallback。
# 复用 DCFeatureFlags.is_on 保证未来 hot-reload 钩子统一接入。
func _is_dirty_push_enabled() -> bool:
	if climate_profile == null:
		return false
	return FeatureFlagsScript.is_on(&"dirty_push_enabled", climate_profile)


# plan/dirty-push-atlas-encode 阶段 F 私有 helper：
# 是否启用 C++ atlas encode pass。要求三件事同时满足：
#   1. cpp_atlas_encode_enabled flag = true
#   2. world_data 有 _world_ext 引用且非 null（DCWorld bind 后注入）
#   3. ext 实现了对应 encode_* 方法（向前兼容旧版本 GDExtension dll）
# 任一不满足都返回 false → 自动 fallback 到 GDScript mask 路径（阶段 D+E）。
#
# 当前 C++ 端 encode_* pass 暂未落地（plan 阶段 F 计划项），
# 此 helper 始终返回 false。等 gdext/src/world_ext.cpp 实现 4 个 method 后
# flip flag 即可启用，无需改 GDScript 一行。
func _should_use_ext_encode(method_name: StringName) -> bool:
	if climate_profile == null:
		return false
	if not FeatureFlagsScript.is_on(&"cpp_atlas_encode_enabled", climate_profile):
		return false
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
		# Cell 数据源（plan/dirty-push-atlas-encode 阶段 D + E）：
		# - ice_state：dirty 路径下取 (dirty_cells ∩ water_lists.keys())；
		#   否则走 baker.ice_state_atlas_default_cell_source（water_lists.keys() 全集）；
		# - dynamic_cell：dirty 路径下直接取 _stride_dirty_cells；否则 all_cells；
		# - ecology_visual：dirty 路径下取 dirty_cells ∪ baker._eco_active_decay_set
		#   （让 transition_age 还在衰减的 cells 重新喂进 chunk_step）；
		# - dyn_atlas_smooth：dirty 路径下取 dilate_dirty_one_hop(dirty_cells)
		#   （box blur 中心 + 邻居均值，dirty cell 变化会让其 6 邻居作为"中心"
		#   时也需要重算，所以必须 1 跳膨胀）。
		if baker_key == "ice_state_atlas":
			if _stride_dirty_path_used and baker.has_method("ice_state_atlas_default_cell_source"):
				# 取 dirty cells ∩ water cells 的交集。water_cell_pixel_lists 的 keys() 是水域 cell 全集。
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
				else:
					# water_lists 还没建好 / dirty 为空 → 走 baker 默认源（兼容首帧 cold 场景）
					_phase_cells = baker.ice_state_atlas_default_cell_source(map, world_data, _phase_ctx)
			elif baker.has_method("ice_state_atlas_default_cell_source"):
				_phase_cells = baker.ice_state_atlas_default_cell_source(map, world_data, _phase_ctx)
			else:
				_phase_cells = map.all_cells()
		elif baker_key == "dynamic_cell_atlas" and _stride_dirty_path_used:
			# dirty 路径：直接喂 dirty cells 子集
			_phase_cells = _stride_dirty_cells
		elif baker_key == "ecology_visual_atlas" and _stride_dirty_path_used:
			# ecology phase：dirty ∪ active_decay_set。cache_invalid（首帧 / 地图重生）
			# 时强制走 all_cells，让 chunk_step 完成 byte 初始化。
			var ctx_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
			if not ctx_cache_valid:
				_phase_cells = map.all_cells()
			else:
				_phase_cells = BakerDirtyHelpersScript.merge_with_eco_decay(
					_stride_dirty_cells, baker._eco_active_decay_set)
		elif baker_key == "dyn_atlas_smooth" and _stride_dirty_path_used:
			# smooth phase：1 跳邻居膨胀。cache_invalid 同 ecology 强制走 all_cells。
			var ctx_cache_valid: bool = bool(_phase_ctx.get("cache_valid", false))
			if not ctx_cache_valid:
				_phase_cells = map.all_cells()
			else:
				_phase_cells = BakerDirtyHelpersScript.dilate_dirty_one_hop(map, _stride_dirty_cells)
		else:
			# ecology / smooth / fallback（flag off / mask 不可用）：维持 all_cells
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
		# plan/dirty-push-atlas-encode 阶段 D 诊断：
		# mask_path = true 表示本 stride dynamic/ice phase 走了 dirty 子集；
		# mask_dirty_count 是 _start_new_stride 时一次性读到的 cell 数量。
		"mask_path": _stride_dirty_path_used,
		"mask_dirty_count": _stride_dirty_indices.size(),
	}


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
