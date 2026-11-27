extends RefCounted

## Runs each accepted slice of a climate day.


static func run_slice(owner: ClimateDailySystem, ctx: SusTickContext) -> Dictionary:
	if owner.generator == null or owner.map == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	# Fix #6 (2026-06-15): finalizer 拆 slice 跨帧。上一片（async 或 sync）设了
	# _finalize_pending，本片专门跑 _finalize_round() —— 把 5-8ms finalizer 从
	# 最后一个 pass slice 剥离出来，让 mobile p95 下降。
	# 必须在 async branch 之前，避免 next-tick 再进 _run_slice_async 又跑一遍 round。
	# 仅 mobile 启用（桌面端不会设 _finalize_pending，所以分支不会触发）。
	if owner._finalize_pending:
		var t_fin_us: int = Time.get_ticks_usec()
		owner._pass_cursor = owner._PASS_COUNT
		owner._finalize_round()
		owner._finalize_pending = false
		owner._round_active = false
		# async path 也要清 kick 标志，否则下个 round 入 _run_slice_async 跳过 kick
		# 直接 poll 返回 empty 等结果，永远循环。
		owner._async_round_kicked = false
		owner._async_round_poll_attempts = 0
		owner.ran_this_tick = true
		var fin_elapsed_ms: float = float(Time.get_ticks_usec() - t_fin_us) / 1000.0
		owner._last_slice_elapsed_ms = fin_elapsed_ms
		return {
			"done": true,
			"work_done": owner.map.cell_count() if owner.map != null else 0,
			"elapsed_ms": fin_elapsed_ms,
			"progress_ratio": 1.0,
			"stage_name": "round_finalize",
			"substage": "finalizer_split",
			"path": "data_core_finalizer",
			"processed_cells": 0,
			"cursor_start": -1,
			"cursor_end": -1,
			"budget_interrupted": false,
			"status": owner._PASS_RESULT_DONE,
			"pass_token": owner._active_pass_token,
			"kernel_ms": 0.0,
			"slice_wall_ms": fin_elapsed_ms,
			"finalizer_ms": float(owner._last_finalize_diag.get("finalize_total_ms", fin_elapsed_ms)),
		}

	# ─── Async climate round 分支（plan §async-stage-3） ──────────────
	# cp.use_climate_round_async=true + ext 支持 → worker thread 跑完整 round。
	# 主线程 run_slice 只 kick / poll，单帧 < 1.5ms。sync path 保留作 fallback。
	var cp_async_check = owner.generator._c() if owner.generator != null else null
	var async_enabled: bool = false
	if cp_async_check != null and "use_climate_round_async" in cp_async_check:
		async_enabled = bool(cp_async_check.use_climate_round_async)
	# Mobile 默认开启 climate async（Fix #2, 2026-06-15）：log_next.txt 显示
	# transp/finalizer 持续报到 SUS-cpp largest 19ms（实际 kernel 0.06ms，
	# 其余 8ms 在 finalize_finalizer_ms 拼 cell_ms/sort_ms）。worker thread 框架
	# 已在 plan §async-stage-1/3 落地（async_climate_round_kick/poll），
	# desktop 上 KEY_B bench 验过 bit-equal，所以 mobile 默认开。
	# 桌面端继续按 ClimateProfile.use_climate_round_async 显式 opt-in。
	if not async_enabled and OS.has_feature("mobile"):
		async_enabled = true
	# Stage 3 调试 print（一次性）：第一次进 run_slice 时 dump 实际 condition
	if not owner._async_branch_probe_logged:
		owner._async_branch_probe_logged = true
		var ext_ok: bool = owner.generator._data_core_world_ext != null
		var has_kick: bool = ext_ok and owner.generator._data_core_world_ext.has_method("async_climate_round_kick")
		var has_poll: bool = ext_ok and owner.generator._data_core_world_ext.has_method("async_climate_round_poll")
		var cp_path: String = "<null>" if cp_async_check == null else (cp_async_check.resource_path if cp_async_check.resource_path != "" else "<in-memory>")
		print("[climate/async PROBE] cp=%s async_enabled=%s ext=%s has_kick=%s has_poll=%s" % [
			cp_path, str(async_enabled), str(ext_ok), str(has_kick), str(has_poll),
		])
	if async_enabled and owner.generator._data_core_world_ext != null \
			and owner.generator._data_core_world_ext.has_method("async_climate_round_kick") \
			and owner.generator._data_core_world_ext.has_method("async_climate_round_poll"):
		return owner._run_slice_async(ctx)

	# ─── Sync sliced round（原行为，保留作 fallback）──────────────────
	# Round 启动：锁 phase + 清埋点累加器
	if not owner._round_active:
		var t_round_start_us: int = Time.get_ticks_usec()
		var t_round_part_us: int = t_round_start_us
		owner._last_round_start_diag = {
			"round_start_total_ms": 0.0,
			"round_start_phase_ms": 0.0,
			"round_start_terrain_sync_ms": 0.0,
			"round_start_terrain_sync_skipped": false,
			"capture_start_state_ms": 0.0,
			"round_start_state_ms": 0.0,
			"round_start_reset_transp_ms": 0.0,
			"round_start_mark_stale_ms": 0.0,
			"round_start_soa_begin_ms": 0.0,
			"round_start_dirty_ms": 0.0,
		}
		owner._pass_cursor = 0
		if owner.season_phase_getter.is_valid():
			owner._phase_locked = float(owner.season_phase_getter.call())
		else:
			owner._phase_locked = ctx.season_phase
		owner._last_round_start_diag["round_start_phase_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		owner._round_t_pass_a_ms = 0.0
		owner._round_t_pass_b_ms = 0.0
		owner._round_t_ocean_ms = 0.0
		owner._round_t_wind_ms = 0.0
		owner._round_t_sea_ice_ms = 0.0
		owner._round_t_transp_ms = 0.0
		owner._last_finalize_diag = {}
		owner._last_slice_pass_overhead_ms = 0.0
		owner._round_t_round_start_ms = Time.get_ticks_msec()
		owner._round_active = true
		t_round_part_us = Time.get_ticks_usec()
		var terrain_diag: Dictionary = owner._sync_runtime_terrain_views_for_reason("round_start")
		owner._last_round_start_diag["round_start_terrain_sync_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		owner._last_round_start_diag["round_start_terrain_sync_skipped"] = bool(terrain_diag.get("skipped", false))
		if not terrain_diag.is_empty():
			owner._last_round_start_diag["round_start_terrain_sync_diag"] = terrain_diag.duplicate(true)
		t_round_part_us = Time.get_ticks_usec()
		owner._begin_round_pass_state()
		owner._last_round_start_diag["round_start_state_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		t_round_part_us = Time.get_ticks_usec()
		owner._reset_transpiration_slice_state()
		owner._last_round_start_diag["round_start_reset_transp_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		# refresh-consolidation-2026-06：round 入口 mark stale，让 pass_a 入口的
		# _ensure_climate_daily_round_slots_fresh() 做一次真实 refresh；同 round 内
		# 后续 pass 的 ensure 调用全部跳过（除非跨 pass 边界由本 system 再次 mark stale）。
		t_round_part_us = Time.get_ticks_usec()
		if owner.generator != null and owner.generator.has_method("_mark_climate_daily_round_slots_stale"):
			owner.generator._mark_climate_daily_round_slots_stale()
		owner._last_round_start_diag["round_start_mark_stale_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		t_round_part_us = Time.get_ticks_usec()
		if owner.map != null and owner.map.has_soa() and owner.map.has_method("soa_begin_climate_transaction"):
			owner.map.soa_begin_climate_transaction()
		owner._last_round_start_diag["round_start_soa_begin_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		# A.2.1.A4 — Dirty Mask 启动时整 round 边界处理：
		#   1) season 跨整数 / 每 30 日 full sweep / 加载存档首日 → mark_all_climate_dirty
		#   2) 否则保留上一日 dirty 增量（Pass A 内层 epsilon 比对会继续覆写）
		# 这里只在 use_sparse_climate=true 时维护 mask；为 false 时 mask 保持全 0 不影响。
		t_round_part_us = Time.get_ticks_usec()
		var cp_round = owner.generator._c() if owner.generator != null else null
		if cp_round != null and bool(cp_round.use_sparse_climate) and owner.map != null and owner.map.has_soa():
			var phase_int: int = int(floor(owner._phase_locked))
			var season_changed: bool = (owner._last_phase_int_seen != -9999) and (phase_int != owner._last_phase_int_seen)
			var full_sweep_due: bool = owner._full_sweep_counter >= owner._FULL_SWEEP_PERIOD
			if season_changed or full_sweep_due:
				owner.map.mark_all_climate_dirty()
				owner._full_sweep_counter = 0
			else:
				# 增量模式：清空上一 round 残留的 dirty 标记，让 Pass A epsilon 比对从零开始
				owner.map.clear_climate_dirty()
			owner._last_phase_int_seen = phase_int
		owner._last_round_start_diag["round_start_dirty_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		owner._last_round_start_diag["round_start_total_ms"] = float(Time.get_ticks_usec() - t_round_start_us) / 1000.0

	# 守卫：daily_climate_interpolation 关闭 → 一次性短路收尾整 round
	# （行为等同旧 wrapper 的 "if not cp.daily_climate_interpolation: return"）
	var cp = owner.generator._c()
	if cp == null or owner.generator._last_cfg == null or not cp.daily_climate_interpolation:
		owner._finalize_round()
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	# 推进当前 cursor 指向的 sub-pass。按段 skip 不可执行的可选段，把 cursor 移到下一段。
	var t_slice_us0: int = Time.get_ticks_usec()
	var local_coupling: bool = bool(cp.enable_local_climate_coupling)
	var ocean_enabled: bool = bool(owner.generator._last_cfg.enable_ocean_heat_transport)
	# climate-loop-closure Phase 1.1：风温段开关（profile 缺字段时默认 true）。
	var wind_heat_enabled: bool = true
	if cp.get("enable_wind_heat_transport") != null:
		wind_heat_enabled = bool(cp.enable_wind_heat_transport)
	var slice_elapsed_ms: float = 0.0
	var ran_pass_id: int = -1
	owner._reset_last_pass_diag()

	while owner._pass_cursor < owner._PASS_COUNT:
		var pass_id: int = owner._pass_cursor
		# Skip 不需要执行的段（开关关闭的可选 pass），cursor +1 继续 while
		var should_skip: bool = false
		match pass_id:
			owner._PASS_B:
				should_skip = not local_coupling
			owner._PASS_OCEAN_WATER, owner._PASS_OCEAN_LAND:
				should_skip = not ocean_enabled
			owner._PASS_WIND_AIR, owner._PASS_WIND_SURFACE:
				should_skip = not wind_heat_enabled
			owner._PASS_SEA_ICE:
				should_skip = owner._standalone_sea_ice_enabled()
			owner._PASS_TRANSP:
				should_skip = not local_coupling
			_:
				should_skip = false
		if should_skip:
			owner._pass_cursor += 1
			continue
		# 本 round 对应一个日级气候调度点：能立即完成的 pass 在同一调度点连续推进，
		# 避免 SLP/wind/ocean/soil 读取半成品。只有 chunked pass 返回未完成时暂停。
		var pass_done: bool = owner._run_pass(pass_id)
		ran_pass_id = pass_id
		if pass_done:
			owner._pass_cursor += 1
		slice_elapsed_ms = (Time.get_ticks_usec() - t_slice_us0) / 1000.0
		if not pass_done:
			break
		break

	if ran_pass_id >= 0:
		var pass_reported_ms: float = float(owner._last_pass_diag.get(
			"diagnostic_wall_ms",
			owner._last_pass_diag.get("reported_elapsed_ms", owner._last_pass_diag.get("elapsed_ms", 0.0))
		))
		owner._last_slice_pass_overhead_ms = maxf(0.0, slice_elapsed_ms - pass_reported_ms)
	else:
		owner._last_slice_pass_overhead_ms = 0.0

	# 检查 round 是否结束：cursor ≥ _PASS_COUNT 表示所有段（含 skip）都过了
	var done: bool = owner._pass_cursor >= owner._PASS_COUNT
	# Fix #6 已回退 (2026-06-15 v3)：实测把 finalize 拆 slice 反而让 sus_ticks/120 从 61
	# 涨到 79，sus_frame_avg 从 28ms 涨到 36ms，FPS 从 66 跌到 29。原因：每个 SUS slice
	# 都有边界 schedule overhead，把 1 个 22ms slice 拆成 16ms+6ms 反而让 2 帧都承担
	# SUS 工作（之前只 1 帧）。finalize 5-8ms 是确定性 cost 不是随机 spike，无法通过
	# 拆 slice 优化。真正瓶颈在 GPU fragment shader（fronts=12 时 draw_calls 41 /
	# primitives 5400），不在 climate finalize。
	# 保留 _finalize_pending 状态字段，但不再触发（done 时直接调 _finalize_round）。
	if done:
		owner._finalize_round()
	else:
		owner._publish_partial_round(ran_pass_id, slice_elapsed_ms, float(owner._pass_cursor) / float(owner._PASS_COUNT))
	owner.ran_this_tick = ran_pass_id >= 0
	owner._last_slice_elapsed_ms = slice_elapsed_ms if owner.ran_this_tick else 0.0

	var progress: float = float(owner._pass_cursor) / float(owner._PASS_COUNT)
	var stage_name_out: String = ""
	if ran_pass_id >= 0 and ran_pass_id < owner._PASS_NAMES.size():
		stage_name_out = owner._PASS_NAMES[ran_pass_id]
	elif done:
		stage_name_out = "round_done"
	else:
		stage_name_out = "skip"
	# 走 climate_pass_b 时有 sparse/full 三态，附带在 substage 上，便于
	# fast tick WARN/largest 行直接看出本片走的稀疏程度。
	# substage 用本 tick 真正执行的 pass_id（_pass_cursor 在执行后已 +1，
	# 取它会偏向 "下一片要跑哪段" 而不是 "本片刚跑了哪段"）。
	var substage_out: String = "cursor_%d" % ran_pass_id if ran_pass_id >= 0 else "cursor_skip"
	# dots-flag-prune-pr1 (2026-05-22)：use_data_core_climate flag 已删除——路径现恒
	# 走 DataCore，仅根据 data_core_ready() 探测决定 path 标签是 cells_only 还是完整
	# DataCore。上游 cp_for_path 仅为保留 generator._c() lookup 路径，用于后续
	# climate_pass_b path 诊断。
	var path_out: String = "data_core" if owner.data_core_ready() else "data_core_cells_only"
	if ran_pass_id == owner._PASS_B and owner.generator != null and "_last_climate_pass_b_path" in owner.generator:
		substage_out = "pass_b_%s" % str(owner.generator._last_climate_pass_b_path)
	elif owner._last_pass_substage != "":
		substage_out = owner._last_pass_substage
	if owner._last_pass_stage != "":
		stage_name_out = owner._last_pass_stage
	if owner._last_pass_path != "":
		path_out = owner._last_pass_path
	var processed_cells_out: int = owner._last_pass_processed_cells
	# Fix #5 (2026-06-15): SUS-cpp largest 归因修复。当 round 结束时 (done=true)，
	# _finalize_round 已经跑完整套 finalizer (cell loop / sort / tta / thermal)。
	# 之前 SUS 看 largest=refresh_climate_daily/transp/native path=gdext 19ms，
	# 但实际 transp/native 0.06ms，剩 18ms 全在 finalizer。让 substage 和 path
	# 在 round 结束帧明确反映 finalizer 主导，不让 transp 背锅。
	# kernel_wall = native_ms（C++ pass 自身），slice_wall = slice_elapsed_ms（含
	# finalizer + sync）—— 把两者都暴露给上层方便区分。
	var native_kernel_ms_out: float = float(owner._last_pass_diag.get("native_ms", 0.0))
	if done:
		var finalize_ms: float = float(owner._last_finalize_diag.get("finalize_total_ms", 0.0))
		if finalize_ms >= maxf(2.0, native_kernel_ms_out * 4.0):
			# 当 finalizer 比 kernel 大 4x 以上且超过 2ms 时（典型 5-8ms），
			# 重新指认为 finalizer 主导，避免 SUS-cpp 把 transp 当瓶颈追错方向。
			substage_out = "finalizer"
			path_out = "data_core_finalizer"
			stage_name_out = "round_finalize"
	return {
		"done": done,
		"work_done": owner.map.cell_count() if done else 0,
		"elapsed_ms": slice_elapsed_ms,
		"progress_ratio": progress if not done else 1.0,
		"stage_name": stage_name_out,
		"substage": substage_out,
		"path": path_out,
		"processed_cells": processed_cells_out,
		"cursor_start": owner._last_pass_cursor_start,
		"cursor_end": owner._last_pass_cursor_end,
		"budget_interrupted": owner._last_pass_budget_interrupted,
		"status": owner._last_pass_status,
		"pass_token": owner._active_pass_token,
		# Fix #5 双口径暴露给 main.gd / scheduler diag：kernel_ms 是 C++ 算子
		# 单独耗时（path=gdext 真实成本），elapsed_ms 是整片墙钟（含 finalizer
		# / sync / write）。SUS-cpp 用 elapsed_ms 算 largest，但消费方拿 kernel_ms
		# 才能判断 C++ 优化是否还有空间。
		"kernel_ms": native_kernel_ms_out,
		"slice_wall_ms": slice_elapsed_ms,
		"finalizer_ms": float(owner._last_finalize_diag.get("finalize_total_ms", 0.0)) if done else 0.0,
	}
