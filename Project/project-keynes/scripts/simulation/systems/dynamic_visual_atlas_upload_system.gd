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
const TIME_CHECK_CELLS_PER_STEP: int = 128
const CPP_TIME_CHECK_CELLS_PER_STEP: int = 512

# Soft budget = slice_budget_ms × 这个倍数，超出则 break 让出。
const SOFT_BUDGET_MULTIPLIER: float = 2.0

var baker: MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null
var dirty_world = null
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

# 诊断采样（沿用 _wf_diag_* 风格）。
var _dvas_diag_stride_count: int = 0
var _dvas_diag_ticks_accum: int = 0
var _dvas_diag_max_tick_ms: float = 0.0
var _dvas_diag_avg_window: int = 30
var _last_breakdown: Dictionary = {}


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData,
		p_stride: int = 2, p_climate_profile = null, p_dirty_world = null) -> void:
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
	dirty_world = p_dirty_world
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
	return partial_report


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
	if baker != null and baker.has_method("_cpp_atlas_encode_active"):
		return bool(baker.call("_cpp_atlas_encode_active", method_name))
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


# Phase 1..4：通用 baker chunk 推进。
# baker_key 决定调用哪组 chunk_begin/step/finalize；
# agg_dirty_key / agg_ms_key 是 aggregated_report 里的累计字段名。
func _step_phase_baker(remaining_budget: int, baker_key: String,
		agg_dirty_key: String, agg_ms_key: String, phase_key: String,
		deadline_us: int) -> bool:
	var total_us: int = Time.get_ticks_usec()
	if _phase_ctx.is_empty():
		var prepare_us: int = Time.get_ticks_usec()
		var begin_method: String = "%s_chunk_begin" % baker_key
		if not baker.has_method(begin_method):
			return true
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
					_phase_cells = BakerDirtyHelpersScript.dilate_dirty_one_hop(
							map, baker._eco_active_decay_set.keys())
					source = "decay_one_hop"
			else:
				var smooth_seed: Array = BakerDirtyHelpersScript.merge_with_eco_decay(
						_stride_dirty_cells, baker._eco_active_decay_set)
				_phase_cells = BakerDirtyHelpersScript.dilate_dirty_one_hop(map, smooth_seed)
				source = "dirty_decay_one_hop"
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
	if _dvas_diag_stride_count >= _dvas_diag_avg_window:
		var avg_ticks: float = float(_dvas_diag_ticks_accum) / float(_dvas_diag_stride_count)
		print_rich("[color=#888]dynamic_visual_atlas_upload diag: avg_ticks_per_stride=%.2f, max_tick_ms=%.2f (over %d strides)[/color]"
				% [avg_ticks, _dvas_diag_max_tick_ms, _dvas_diag_stride_count])
		_dvas_diag_stride_count = 0
		_dvas_diag_ticks_accum = 0
		_dvas_diag_max_tick_ms = 0.0

	var report: Dictionary = _build_report(true, elapsed_ms)
	_last_breakdown = report.duplicate(true)
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
	}
	_last_breakdown = report.duplicate(true)
	return report


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


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
	]:
		var key: String = phase_key + "_" + suffix
		if _aggregated_report.has(key):
			out[key] = _aggregated_report[key]
