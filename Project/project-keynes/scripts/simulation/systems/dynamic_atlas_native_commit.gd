extends RefCounted

## Publishes the native atlas pipeline's committed texture data.


static func _is_cpp_atlas_pipeline_enabled(owner: DynamicVisualAtlasUploadSystem) -> bool:
	return true


# plan/sim-2ms-simd-dirty-budget 任务 7（2026-05-21）：dynamic_visual_atlas dirty
# 编码 kill-switch。dots-flag-prune-pr1 round 2: use_gdext_dynamic_atlas_terminal_dirty
# flag 已删除——恒走 cpp 现行 dirty 路径（dirty_indices 比对 + value-diff + 1-跳
# 邻居膨胀），不再提供 A/B 对照与回归排障入口。本 helper 恒返 true。
static func _is_dynamic_atlas_terminal_dirty_enabled(owner: DynamicVisualAtlasUploadSystem) -> bool:
	return true


# 取 DCWorld 挂载的 _world_ext / _ext（与 _should_use_ext_encode 同模式，
# 走 .get() 反射避免对 DCWorld 内部命名强耦合）。
static func _get_world_ext(owner: DynamicVisualAtlasUploadSystem):
	if owner.world_ext != null:
		return owner.world_ext
	if owner.world_data == null:
		if owner.baker != null:
			return owner.baker.get("_world_ext")
		return null
	var ext = owner.world_data.get("_world_ext")
	if ext == null:
		ext = owner.world_data.get("_ext")
	if ext == null and owner.baker != null:
		ext = owner.baker.get("_world_ext")
	return ext


# 主入口：cpp_atlas_pipeline 薄壳。
# 1) 一次性原子读 dirty_indices；2) 首次调用前做 ecology 持久状态 burn-in；
# 3) 调 run_atlas_pipeline_step 拿 atlas_buffers + ms_breakdown；
# 4) 4 次 ImageTexture.update；5) 复用 _dvas_diag_* 采样窗口与 phase breakdown 输出。
static func _tick_cpp_pipeline(owner: DynamicVisualAtlasUploadSystem, t_start_us: int, ext: Object) -> Dictionary:
	return owner.DynamicVisualAtlasUploadHelpers.tick_cpp_pipeline(owner, t_start_us, ext)



static func _run_atlas_pipeline_step(owner: DynamicVisualAtlasUploadSystem, ext: Object, opts: Dictionary) -> Dictionary:
	return ext.call(&"run_atlas_pipeline_step", opts)



static func _begin_cpp_commit_queue(owner: DynamicVisualAtlasUploadSystem, atlas_buffers: Dictionary, W: int, H: int,
		stride_real: Dictionary, base_report: Dictionary) -> void:
	owner.DynamicVisualAtlasUploadHelpers.begin_cpp_commit_queue(owner, atlas_buffers, W, H, stride_real, base_report)



static func _current_cpp_atlas_buffer(owner: DynamicVisualAtlasUploadSystem, channel: String) -> PackedByteArray:
	match channel:
		"dyn":
			return owner.world_data.dynamic_cell_atlas_buffer
		"eco":
			return owner.world_data.ecology_visual_atlas_buffer
		"smo":
			return owner.world_data.dyn_atlas_smooth_buffer
		"ice":
			return owner.world_data.ice_state_buffer
		_:
			return PackedByteArray()



static func _maybe_enqueue_cpp_commit_task(owner: DynamicVisualAtlasUploadSystem, channel: String, buf: PackedByteArray,
		image_format: int, bytes_per_pixel: int, stride_count: int,
		need_init: bool, W: int, H: int, n_pix: int,
		force_commit: bool = false) -> void:
	var expected_size: int = n_pix * bytes_per_pixel
	if buf.size() != expected_size:
		return
	if stride_count <= 0 and not need_init:
		var current_buf: PackedByteArray = owner._current_cpp_atlas_buffer(channel)
		if current_buf.size() == expected_size and current_buf == buf:
			owner._cpp_commit_skip_count += 1
			return
		if not force_commit:
			return
	# force_commit 仍允许初始化或 buffer 真变化时上传；完全相同的全量图不再碰 GPU。
	if not force_commit and stride_count <= 0 and not need_init:
		return
	owner._cpp_commit_queue.append({
		"channel": channel,
		"buffer": buf,
		"format": image_format,
		"stride_count": stride_count,
		"need_init": need_init,
		"W": W,
		"H": H,
		"pixels": n_pix,
	})



static func _drain_cpp_commit_queue(owner: DynamicVisualAtlasUploadSystem, t_start_us: int) -> Dictionary:
	return owner.DynamicVisualAtlasUploadHelpers.drain_cpp_commit_queue(owner, t_start_us)



static func _commit_cpp_atlas_task_to_gpu(owner: DynamicVisualAtlasUploadSystem, task: Dictionary) -> int:
	return owner.DynamicVisualAtlasUploadHelpers.commit_cpp_atlas_task_to_gpu(owner, task)



static func _log_ice_commit_sample(owner: DynamicVisualAtlasUploadSystem, buf_ice: PackedByteArray, need_init: bool,
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
		owner._dvas_ice_commit_runs, str(need_init), stride_count,
		ice_n, ice_nonzero, ice_max,
		str(owner.world_data.ice_state_tex.get_rid()) if owner.world_data.ice_state_tex != null else "<null>",
	])


# burn-in：把 baker 端 ecology 持久状态一次性灌到 C++ AtlasPipelineState。
# 调用时机：本系统首次调 _tick_cpp_pipeline，或 _pending_burnin=true（外部
# 通知地图重生）。失败不抛错，只记日志，让 C++ 用 SoA cur 自启 baseline。
static func _burn_in_eco_state(owner: DynamicVisualAtlasUploadSystem, ext: Object) -> void:
	var state: Dictionary = {}
	# transition_age：直接拿 baker 端 SoA byte 数组（PackedByteArray）
	var tr_arr = owner.baker.get("_eco_transition_age_arr")
	if tr_arr is PackedByteArray and tr_arr.size() > 0:
		state["transition_age"] = tr_arr
	# active_decay：从 _eco_active_decay_set 提 cell.index 列表
	var decay_set = owner.baker.get("_eco_active_decay_set")
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
static func _print_phase_breakdown_window(owner: DynamicVisualAtlasUploadSystem, path_tag: String) -> void:
	var n: float = float(owner._dvas_diag_stride_count)
	if n <= 0.0:
		return
	var avg_ticks: float = float(owner._dvas_diag_ticks_accum) / n
	print_rich("[color=#888]dynamic_visual_atlas_upload diag(%s): avg_ticks_per_stride=%.2f, max_tick_ms=%.2f (over %d strides)[/color]"
			% [path_tag, avg_ticks, owner._dvas_diag_max_tick_ms, owner._dvas_diag_stride_count])
	var dyn_p: float = float(owner._dvas_diag_phase_ms_accum["dynamic_prepare_ms"]) / n
	var dyn_s: float = float(owner._dvas_diag_phase_ms_accum["dynamic_step_ms"]) / n
	var dyn_f: float = float(owner._dvas_diag_phase_ms_accum["dynamic_finalize_ms"]) / n
	var eco_p: float = float(owner._dvas_diag_phase_ms_accum["ecology_prepare_ms"]) / n
	var eco_s: float = float(owner._dvas_diag_phase_ms_accum["ecology_step_ms"]) / n
	var eco_f: float = float(owner._dvas_diag_phase_ms_accum["ecology_finalize_ms"]) / n
	var smo_p: float = float(owner._dvas_diag_phase_ms_accum["smooth_prepare_ms"]) / n
	var smo_s: float = float(owner._dvas_diag_phase_ms_accum["smooth_step_ms"]) / n
	var smo_f: float = float(owner._dvas_diag_phase_ms_accum["smooth_finalize_ms"]) / n
	var ice_p: float = float(owner._dvas_diag_phase_ms_accum["ice_prepare_ms"]) / n
	var ice_s: float = float(owner._dvas_diag_phase_ms_accum["ice_step_ms"]) / n
	var ice_f: float = float(owner._dvas_diag_phase_ms_accum["ice_finalize_ms"]) / n
	var total: float = dyn_p + dyn_s + dyn_f + eco_p + eco_s + eco_f \
			+ smo_p + smo_s + smo_f + ice_p + ice_s + ice_f
	print_rich("[color=#888]  phase breakdown (avg ms/stride, prep+step+fin):"
			+ " dyn=%.2f+%.2f+%.2f eco=%.2f+%.2f+%.2f smo=%.2f+%.2f+%.2f ice=%.2f+%.2f+%.2f sum=%.2f[/color]"
			% [dyn_p, dyn_s, dyn_f, eco_p, eco_s, eco_f, smo_p, smo_s, smo_f, ice_p, ice_s, ice_f, total])


# 外部通知接口：地图重生成或 invalidate_atlas_csr_cache 时调，
# 让下一次 _tick_cpp_pipeline 重新做 ecology burn-in。
static func notify_eco_burnin_pending(owner: DynamicVisualAtlasUploadSystem) -> void:
	owner._pending_burnin = true
	owner._abort_smooth_prep("eco_burnin_pending")
