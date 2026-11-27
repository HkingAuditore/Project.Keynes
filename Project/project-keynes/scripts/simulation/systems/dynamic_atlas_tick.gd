extends RefCounted

## Processes scheduled atlas uploads and reports the result of each tick.


static func tick(owner: DynamicVisualAtlasUploadSystem, ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if owner.baker == null or owner.map == null or owner.world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}
	if not owner._cpp_commit_queue.is_empty():
		return owner._drain_cpp_commit_queue(t_start_us)

	# [cell-indirect single-path 2026-06-16] flag 开 → 主 shader 全量走 per-cell LUT，
	# 旧逐像素动态 atlas（dynamic/ecology/smooth/ice）已无任何 shader 消费者。这里每
	# stride 只全量重烘 enum/dyn/eco per-cell LUT（weather_lut 不在此发布），
	# 随后直接结束本 tick：彻底跳过下方 C++ run_atlas_pipeline_step 与 4-phase 逐像素
	# 上传，省每日 GPU 上传 + 4 张 derived RGBA8 显存。stride 节奏不变（StridePolicy
	# 控制 tick 频率）。weather_lut 由 weather_refresh commit path 同步生成并发布。
	# flag 关时本分支零触达，旧 per-pixel 路径（_tick_cpp_pipeline / 4-phase / _tick_oneshot）
	# 行为完全不变，即 flag 充当 A/B fallback 开关（skill rule 11）。
	if owner.FeatureFlagsScript.cell_indirection_active():
		owner._mark_lut_due_from_ctx(ctx)
		var pending_before: bool = owner._lut_refresh_pending
		var tick_index: int = owner._ctx_tick_index(ctx)
		var due_this_tick: bool = owner._lut_due_for_tick(tick_index)
		var due_tick: int = owner._lut_last_due_tick
		if owner._native_visual_commit_pending():
			return owner._build_lut_commit_deferred_report(t_start_us, tick_index,
					pending_before, due_this_tick, due_tick)
		var catchup: bool = pending_before and not due_this_tick
		var dirty_count: int = owner._lut_peek_dirty_count()
		var environment_generation := owner._runtime_environment_generation()
		if environment_generation >= 0 and environment_generation <= owner._lut_last_environment_generation \
				and not catchup and dirty_count == 0 and not owner._lut_active_decay_pending() \
				and owner._lut_textures_ready():
			return owner._build_lut_skip_report(t_start_us, tick_index, pending_before,
					due_this_tick, due_tick, dirty_count)
		if dirty_count == 0 and not catchup and owner._lut_textures_ready() and not owner._lut_active_decay_pending():
			return owner._build_lut_skip_report(t_start_us, tick_index, pending_before,
					due_this_tick, due_tick, dirty_count)
		if owner.baker.has_method("set_river_atlas_probe_context"):
			owner.baker.set_river_atlas_probe_context({
				"tick_idx": tick_index,
				"sim_day": owner._ctx_day_index(ctx),
				"catchup": catchup,
				"due_this_tick": due_this_tick,
				"dirty_count": dirty_count,
			})
		var dirty_indices := PackedInt32Array()
		var dirty_source_available := false
		var dense_dirty_fallback := false
		var dense_dirty_threshold := 0
		var dirty_source = owner._lut_dirty_source()
		if dirty_count >= 0 and dirty_source != null \
				and dirty_source.has_method("read_and_clear_dirty_mask"):
			dirty_source_available = true
			dense_dirty_threshold = owner._lut_dense_dirty_threshold(dirty_source)
			if dense_dirty_threshold > 0 and dirty_count >= dense_dirty_threshold \
					and dirty_source.has_method("clear_dirty_mask"):
				dirty_source.clear_dirty_mask()
				dense_dirty_fallback = true
				owner._lut_dense_fallback_count += 1
			else:
				dirty_indices = dirty_source.read_and_clear_dirty_mask()
				dirty_count = dirty_indices.size()
		var lut_report: Dictionary = owner.baker.refresh_cell_luts_daily(
			owner.map, owner.world_data, dirty_indices,
			not dirty_source_available or dense_dirty_fallback)
		if environment_generation >= 0:
			owner._lut_last_environment_generation = environment_generation
		owner._lut_last_refresh_tick = tick_index
		owner._lut_refresh_pending = false
		owner._lut_pending_before_tick = pending_before
		owner._lut_catchup_tick = catchup
		var report: Dictionary = {
			"done": true,
			"work_done": int(lut_report.get("processed_cells",
				lut_report.get("dirty_cells", owner.map.cell_count() if owner.map != null else 0))),
			"elapsed_ms": 0.0,
			"progress_ratio": 1.0,
			"path": "cell_indirection_lut",
		}
		report["lut_path"] = str(lut_report.get("path", ""))
		report.merge(lut_report, true)
		report["path"] = "cell_indirection_lut"
		report["lut_refresh_pending_before"] = pending_before
		report["lut_refresh_pending_after"] = owner._lut_refresh_pending
		report["lut_last_refresh_tick"] = owner._lut_last_refresh_tick
		report["lut_last_due_tick"] = due_tick
		report["lut_stride"] = owner._lut_stride
		report["lut_phase"] = owner._lut_phase
		report["lut_catchup"] = catchup
		report["lut_skip_no_dirty"] = false
		report["lut_refresh_due"] = due_this_tick
		report["mask_dirty_count"] = dirty_count
		report["lut_dense_dirty_fallback"] = dense_dirty_fallback
		report["lut_dense_dirty_threshold"] = dense_dirty_threshold
		report["lut_dense_fallback_count"] = owner._lut_dense_fallback_count
		var lut_wall_ms := float(Time.get_ticks_usec() - t_start_us) / 1000.0
		report["elapsed_ms"] = lut_wall_ms
		report["lut_refresh_ms"] = lut_wall_ms
		owner._last_breakdown = report.duplicate(false)
		owner._last_breakdown["_tick_idx"] = owner.current_fast_tick_idx
		owner.mark_atlas_upload_success()
		return report

	# 紧急回退：走旧 one-shot 路径。
	if not owner.enable_time_slicing:
		return owner._tick_oneshot(t_start_us)

	# ── plan/atlas-pipeline-cpp：薄壳路径分流 ────────────────────────────
	# 原生世界可用时走全量 DOTS C++ 路径，
	# 一次性完成 4 atlas 计算并返回 atlas_buffers，GD 端只做 ImageTexture.update。
	# 未绑定原生世界时沿用 4-phase 状态机。
	if owner._is_cpp_atlas_pipeline_enabled():
		var ext = owner._get_world_ext()
		if ext != null:
			return owner._tick_cpp_pipeline(t_start_us, ext)
		elif not owner._cpp_pipeline_warned_no_world:
			owner._cpp_pipeline_warned_no_world = true
			push_warning("[atlas-pipeline-cpp] 未绑定原生世界；fallback 到旧 4-phase 路径")

	# Soft budget：单 tick 不应超过这个数值；用作 phase 推进的让出阈值。
	var soft_budget_us: int = maxi(50, int(owner.slice_budget_ms * owner.SOFT_BUDGET_MULTIPLIER * 1000.0))
	var deadline_us: int = t_start_us + soft_budget_us

	# Phase IDLE：进入新 stride。
	if owner._phase == owner.PHASE_IDLE:
		owner._start_new_stride()

	owner._total_ticks_used += 1

	# 主推进循环：尽可能多 phase 在 budget 内完成。
	while owner._phase >= owner.PHASE_DYNAMIC and owner._phase <= owner.PHASE_ICE:
		var elapsed_us: int = Time.get_ticks_usec() - t_start_us
		if elapsed_us >= soft_budget_us:
			break
		# 计算本次 step 可扫的 cell 上限：MAX_CELLS_PER_TICK 跨 phase 共享。
		var remaining_budget: int = owner.MAX_CELLS_PER_TICK - int(owner._aggregated_report.get("_cells_scanned_this_tick", 0))
		if remaining_budget <= 0:
			break
		var phase_done: bool = owner._advance_current_phase(remaining_budget, deadline_us)
		if phase_done:
			owner._phase += 1
			# Phase 切换：清掉 ctx / report，准备进入下一 phase。
			owner._phase_ctx = {}
			owner._phase_report = {}
			owner._phase_cells = []
			owner._phase_cursor = 0
		else:
			# 当前 phase 未完，break 让出，下 tick 续跑。
			break

	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	owner._dvas_diag_max_tick_ms = max(owner._dvas_diag_max_tick_ms, elapsed_ms)

	# 清掉本 tick 的 cells_scanned 计数，下 tick 重置。
	owner._aggregated_report["_cells_scanned_this_tick"] = 0

	# Stride 完成（_phase == PHASE_DONE）。
	if owner._phase >= owner.PHASE_DONE:
		var final_report: Dictionary = owner._finalize_stride(elapsed_ms)
		owner._reset_state_machine()
		return final_report

	# 还有 phase 未完成 —— 返回部分进度，下 tick 续跑。
	var partial_report: Dictionary = owner._build_report(false, elapsed_ms)
	owner._last_breakdown = partial_report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	owner._last_breakdown["_tick_idx"] = owner.current_fast_tick_idx
	return partial_report
