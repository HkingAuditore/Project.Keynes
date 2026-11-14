extends RefCounted

## Runtime atlas helpers. DynamicVisualAtlasUploadSystem remains the sole state owner.

static func tick_cpp_pipeline(host, t_start_us: int, ext: Object) -> Dictionary:
	# ── plan/atlas-phase-slicing：mid-stride 守卫 ──
	# 上一 tick C++ 返回 done=false 表示 stride 没跑完（phase_budget < 4），
	# 本 tick 不应再读 dirty / burn-in，直接 call C++ 推下一个 phase。
	var is_mid_stride: bool = host._cpp_stride_in_progress

	# ── Step 1：原子读 dirty_indices（只在 stride 起点做，mid-stride 时复用 C++ 缓存）──
	var dirty_indices: PackedInt32Array = PackedInt32Array()
	var dirty_path_used: bool = false
	var dirty_reason: String = ""
	var dirty_source_tag: String = ""
	var dirty_mask_available: bool = false
	if not is_mid_stride and host._is_dirty_push_enabled():
		var dirty_source = host.dirty_world if host.dirty_world != null else host.world_data
		dirty_source_tag = "dirty_world" if host.dirty_world != null else "world_data"
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
	if not is_mid_stride and (not host._eco_burnin_done or host._pending_burnin) :
		host._burn_in_eco_state(ext)
		host._eco_burnin_done = true
		host._pending_burnin = false

	# ── Step 3：构造 opts → 调 run_atlas_pipeline_step ──
	var W: int = int(host.world_data.derived_size.x) if host.world_data != null else 0
	var H: int = int(host.world_data.derived_size.y) if host.world_data != null else 0
	# plan/sim-2ms-simd-dirty-budget 任务 7：dirty 编码 kill-switch（默认 true）。
	# false 时跳过传 dirty_indices 并加 force_full_encode=true，cpp 入口会覆盖
	# dirty_path_used=false 让 4 phase 全集编码（A/B 对照与回归排障）。
	var dvas_terminal_dirty_on: bool = host._is_dynamic_atlas_terminal_dirty_enabled()
	var opts: Dictionary = {
		"world": host.world_data,
		"map": host.map,
		"width": W,
		"height": H,
		"terrain_lake": int(host.TerrainTypeScript.TERRAIN.LAKE),
		"terrain_sea_ice": int(host.TerrainTypeScript.TERRAIN.SEA_ICE),
		"veg_none": int(host.VegetationTypeScript.VEG.NONE),
		"enable_diag": true,
		"phase_budget": host.CPP_PIPELINE_PHASE_BUDGET,
		"max_smooth_cells_per_call": host.CPP_SMOOTH_CELLS_PER_CALL,
	}
	# dirty_indices 仅在 stride 起点传一次（mid-stride 时 C++ 从 stride snapshot 复用）。
	# 任务 7 kill-switch：flag=false 时显式不传 dirty_indices 并设置 force_full_encode，
	# 让 cpp 端把 dirty_path_used 钉为 false（覆盖默认按 opts.has 决策）。
	if dirty_path_used and dvas_terminal_dirty_on:
		opts["dirty_indices"] = dirty_indices
	if not dvas_terminal_dirty_on:
		opts["force_full_encode"] = true
	var t_call_us: int = Time.get_ticks_usec()
	var res: Dictionary = host._run_atlas_pipeline_step(ext, opts)
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
		if not host._cpp_pipeline_warned_no_world:
			host._cpp_pipeline_warned_no_world = true
			host.push_warning("[atlas-pipeline-cpp] run_atlas_pipeline_step fallback=true reason=",
					String(res.get("reason", "")), "; 本 stride fallback 到旧 4-phase 路径")
		# 软回退：重置 mid-stride 状态，让下一 tick 重启。
		host._cpp_stride_in_progress = false
		# plan/atlas-phase-slicing 诊断（2026-05-21）：把 fallback reason 透传给 oneshot
		# 的 report，让 CSV 能直接看出来 cpp_pipeline 为什么没生效。
		host._pending_fallback_reason = String(res.get("reason", "unknown"))
		return host._tick_oneshot(t_start_us)

	# ── plan/atlas-phase-slicing：判定本 tick 是否完成整段 stride ──
	# done=false → mid-stride，不 commit GPU（atlas_buffers 为空 Dict），
	# 设置 _cpp_stride_in_progress=true 让下一 tick 继续推 phase。
	var stride_done: bool = bool(res.get("done", true))
	host._cpp_stride_in_progress = not stride_done

	# ── Step 4：收集待提交 atlas（仅在 stride_done 时有 atlas_buffers）──
	var atlas_buffers: Dictionary = res.get("atlas_buffers", {})
	var stride_real: Dictionary = res.get("stride_real", {})

	# ── Step 5：诊断与 report 组装 ──
	# mid-stride 时只更新 max_tick_ms（用于诊断单 tick 抖动），不累加 stride 计数；
	# stride_done 时才完整累加并触发窗口输出（保持窗口=stride 数语义）。
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	host._dvas_diag_max_tick_ms = max(host._dvas_diag_max_tick_ms, elapsed_ms)
	var ms_breakdown: Dictionary = res.get("ms_breakdown", {})
	if stride_done:
		host._dvas_diag_stride_count += 1
		host._dvas_diag_ticks_accum += 1
		# 累加 C++ 返回的 ms_breakdown（stride_done 时拿到完整 4 phase 累计）
		for key in host._dvas_diag_phase_ms_accum.keys():
			host._dvas_diag_phase_ms_accum[key] = float(host._dvas_diag_phase_ms_accum[key]) \
					+ float(ms_breakdown.get(key, 0.0))
		if host._dvas_diag_stride_count >= host._dvas_diag_avg_window:
			host._print_phase_breakdown_window("cpp_pipeline")
			host._dvas_diag_stride_count = 0
			host._dvas_diag_ticks_accum = 0
			host._dvas_diag_max_tick_ms = 0.0
			for k in host._dvas_diag_phase_ms_accum.keys():
				host._dvas_diag_phase_ms_accum[k] = 0.0
	else:
		# mid-stride：仅累 ticks_accum 计数，便于在窗口里看到"每 stride 用 N tick"。
		host._dvas_diag_ticks_accum += 1

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
			"current_phase": int(res.get("phase", host.PHASE_IDLE)),
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
		host._last_breakdown = mid_report.duplicate(true)
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		host._last_breakdown["_tick_idx"] = host.current_fast_tick_idx
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
		"current_phase": host.PHASE_DONE,
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
		"max_cells_per_tick": host.MAX_CELLS_PER_TICK,
		"time_check_cells_per_step": host.TIME_CHECK_CELLS_PER_STEP,
		"cpp_time_check_cells_per_step": host.CPP_TIME_CHECK_CELLS_PER_STEP,
		"slice_budget_ms": host.slice_budget_ms,
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
	host._begin_cpp_commit_queue(atlas_buffers, W, H, stride_real, report)
	if not host._cpp_commit_queue.is_empty():
		return host._drain_cpp_commit_queue(t_start_us)
	host._last_breakdown = report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	host._last_breakdown["_tick_idx"] = host.current_fast_tick_idx
	return report


static func begin_cpp_commit_queue(host, atlas_buffers: Dictionary, W: int, H: int,
		stride_real: Dictionary, base_report: Dictionary) -> void:
	host._cpp_commit_queue.clear()
	host._cpp_commit_skip_count = 0
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
	host._maybe_enqueue_cpp_commit_task("dyn", atlas_buffers.get("dyn", PackedByteArray()),
			Image.FORMAT_RGBA8, 4, int(stride_real.get("dyn", 0)),
			host.world_data.dynamic_cell_atlas_tex == null
					or host.world_data.dynamic_cell_atlas_tex.get_size() != Vector2(float(W), float(H))
					or host.world_data.dynamic_cell_atlas_buffer.size() != n_pix * 4,
			W, H, n_pix, true)
	host._maybe_enqueue_cpp_commit_task("eco", atlas_buffers.get("eco", PackedByteArray()),
			Image.FORMAT_RGBA8, 4, int(stride_real.get("eco", 0)),
			host.world_data.ecology_visual_atlas_tex == null
					or host.world_data.ecology_visual_atlas_tex.get_size() != Vector2(float(W), float(H))
					or host.world_data.ecology_visual_atlas_buffer.size() != n_pix * 4,
			W, H, n_pix, true)
	host._maybe_enqueue_cpp_commit_task("smo", atlas_buffers.get("smo", PackedByteArray()),
			Image.FORMAT_RGBA8, 4, int(stride_real.get("smo", 0)),
			host.world_data.dyn_atlas_smooth_tex == null
					or host.world_data.dyn_atlas_smooth_tex.get_size() != Vector2(float(W), float(H))
					or host.world_data.dyn_atlas_smooth_buffer.size() != n_pix * 4,
			W, H, n_pix, true)
	host._maybe_enqueue_cpp_commit_task("ice", atlas_buffers.get("ice", PackedByteArray()),
			Image.FORMAT_R8, 1, int(stride_real.get("ice", 0)),
			host.world_data.ice_state_tex == null
					or host.world_data.ice_state_tex.get_size() != Vector2(float(W), float(H))
					or host.world_data.ice_state_buffer.size() != n_pix,
			W, H, n_pix, true)
	if host._cpp_commit_queue.is_empty():
		base_report["commit_skipped_unchanged"] = host._cpp_commit_skip_count
		return
	host._cpp_commit_context = base_report.duplicate(true)
	host._cpp_commit_context["path"] = "cpp_pipeline_commit_queue"
	host._cpp_commit_context["phase"] = "upload_commit"
	host._cpp_commit_context["commit_queue_total"] = host._cpp_commit_queue.size()
	host._cpp_commit_context["commit_queue_remaining"] = host._cpp_commit_queue.size()
	host._cpp_commit_context["commit_textures_done"] = 0
	host._cpp_commit_context["commit_pixels_written"] = 0
	host._cpp_commit_context["commit_ms"] = 0.0
	host._cpp_commit_context["commit_channel"] = ""
	host._cpp_commit_context["commit_skipped_unchanged"] = host._cpp_commit_skip_count
	host._cpp_commit_context["commit_ticks_used"] = 0


static func drain_cpp_commit_queue(host, t_start_us: int) -> Dictionary:
	var report: Dictionary = host._cpp_commit_context.duplicate(true)
	# 移动端每 tick 只 commit 1 张 atlas，桌面 4 张。see CPP_COMMIT_TEXTURES_PER_TICK_*.
	var textures_this_tick: int = mini(host._cpp_commit_textures_per_tick(), host._cpp_commit_queue.size())
	var tick_commit_ms: float = 0.0
	var tick_pixels: int = 0
	var last_channel: String = ""
	for _i in range(textures_this_tick):
		var task: Dictionary = host._cpp_commit_queue.pop_front()
		var t_commit_us: int = Time.get_ticks_usec()
		tick_pixels += host._commit_cpp_atlas_task_to_gpu(task)
		tick_commit_ms += float(Time.get_ticks_usec() - t_commit_us) / 1000.0
		last_channel = str(task.get("channel", ""))
	var committed: int = int(report.get("commit_textures_done", 0)) + textures_this_tick
	var total: int = int(report.get("commit_queue_total", committed))
	var pixels_done: int = int(report.get("commit_pixels_written", 0)) + tick_pixels
	var commit_ticks: int = int(report.get("commit_ticks_used", 0)) + 1
	var done: bool = host._cpp_commit_queue.is_empty()
	report["done"] = done
	report["progress_ratio"] = 1.0 if total <= 0 else float(committed) / float(total)
	report["elapsed_ms"] = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	report["path"] = "cpp_pipeline_commit_queue"
	report["phase"] = "upload_commit"
	report["commit_channel"] = last_channel
	report["commit_ms"] = tick_commit_ms
	report["commit_queue_total"] = total
	report["commit_queue_remaining"] = host._cpp_commit_queue.size()
	report["commit_textures_done"] = committed
	report["commit_pixels_written"] = pixels_done
	report["commit_skipped_unchanged"] = int(report.get("commit_skipped_unchanged", 0))
	report["pixels_written"] = pixels_done
	report["commit_ticks_used"] = commit_ticks
	report["ticks_used"] = int(report.get("ticks_used", 1)) + commit_ticks - 1
	report["total_ticks_used"] = int(report.get("total_ticks_used", 1)) + commit_ticks - 1
	host._dvas_diag_max_tick_ms = max(host._dvas_diag_max_tick_ms, float(report["elapsed_ms"]))
	if done:
		host._cpp_commit_context = {}
	else:
		host._cpp_commit_context = report.duplicate(true)
		host._cpp_commit_context.erase("_tick_idx")
	host._last_breakdown = report.duplicate(true)
	host._last_breakdown["_tick_idx"] = host.current_fast_tick_idx
	if textures_this_tick > 0:
		host.mark_atlas_upload_success()
	return report


static func commit_cpp_atlas_task_to_gpu(host, task: Dictionary) -> int:
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
	# Compatibility(GLES3) 下单通道纹理会被引擎换成 4×4 默认白纹理（见
	# DCAtlasEncoders._single_channel_format），ice 通道必须一起加宽。
	if img.get_format() == Image.FORMAT_R8:
		var want_ice: int = DCAtlasEncoders.single_channel_format()
		if want_ice != Image.FORMAT_R8:
			img.convert(want_ice)
	var _img_create_ms: float = float(Time.get_ticks_usec() - _commit_t0_us) / 1000.0
	var _create_from_image_path: bool = false
	var _commit_t1_us: int = Time.get_ticks_usec()
	match channel:
		"dyn":
			host.world_data.dynamic_cell_atlas_buffer = buf
			if host.world_data.dynamic_cell_atlas_tex != null \
					and host.world_data.dynamic_cell_atlas_tex.get_size() == Vector2(float(W), float(H)):
				host.world_data.dynamic_cell_atlas_tex.update(img)
			else:
				host.world_data.dynamic_cell_atlas_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
		"eco":
			host.world_data.ecology_visual_atlas_buffer = buf
			if host.world_data.ecology_visual_atlas_tex != null \
					and host.world_data.ecology_visual_atlas_tex.get_size() == Vector2(float(W), float(H)):
				host.world_data.ecology_visual_atlas_tex.update(img)
			else:
				host.world_data.ecology_visual_atlas_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
		"smo":
			host.world_data.dyn_atlas_smooth_buffer = buf
			if host.world_data.dyn_atlas_smooth_tex != null \
					and host.world_data.dyn_atlas_smooth_tex.get_size() == Vector2(float(W), float(H)):
				host.world_data.dyn_atlas_smooth_tex.update(img)
			else:
				host.world_data.dyn_atlas_smooth_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
		"ice":
			host.world_data.ice_state_buffer = buf
			if host.world_data.ice_state_tex != null \
					and host.world_data.ice_state_tex.get_size() == Vector2(float(W), float(H)):
				host.world_data.ice_state_tex.update(img)
			else:
				host.world_data.ice_state_tex = ImageTexture.create_from_image(img)
				_create_from_image_path = true
			host._dvas_ice_commit_runs = int(host._dvas_ice_commit_runs) + 1
			if host._dvas_ice_commit_runs <= 3 or (host._dvas_ice_commit_runs % 60) == 0:
				host._log_ice_commit_sample(buf, bool(task.get("need_init", false)),
						int(task.get("stride_count", 0)))
		_:
			return 0
	var _tex_phase_ms: float = float(Time.get_ticks_usec() - _commit_t1_us) / 1000.0
	var _total_commit_ms: float = float(Time.get_ticks_usec() - _commit_t0_us) / 1000.0
	# Fix #3：高耗时直接打 warn，spike 时定位 root cause。25ms 阈值挑得偏严，
	# 但 mobile commit 期望 ≤ 5ms，>25ms 就是真实问题。
	if _total_commit_ms > 25.0:
		host.push_warning("[atlas/commit-spike] ch=%s total=%.1fms img_create=%.1fms tex_%s=%.1fms W=%d H=%d buf=%dB path=%s" % [
			channel, _total_commit_ms, _img_create_ms,
			"create" if _create_from_image_path else "update",
			_tex_phase_ms, W, H, buf.size(),
			"ImageTexture.create_from_image" if _create_from_image_path else "ImageTexture.update",
		])
	return pixels

