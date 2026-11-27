extends RefCounted

## Publishes the climate loading progress and prepares the season geometry.


static func cancel_loading_work(context) -> void:
	context._generator._loading_epoch += 1
	if context._generator._data_core_world_ext != null:
		context._generator._data_core_world_ext.cancel_all_loading_tasks()
	if context._generator._baker != null:
		context._generator._baker.cancel_loading_work()
	context._generator._loading_frames.cancel()

static func _loading_profile_step(context, label: String) -> void:
	var now := Time.get_ticks_usec()
	if context._generator._loading_step_usec > 0 and now-context._generator._loading_step_usec > 30000:
		var step_ms := float(now-context._generator._loading_step_usec)/1000.0
		print("[loading-substep] %s %.1fms" % [context._generator._loading_step_name, step_ms])
		# Web 构建：把每一步耗时推给本地事件通道（tmp/web_events.jsonl）。
		WebTelemetry.emit("gen_step", {"label": context._generator._loading_step_name, "dur": step_ms})
	context._generator._loading_step_usec = now
	context._generator._loading_step_name = label
	Engine.set_meta("loading_step",label)
	# 顺手把"simulation(0.96) 之后"的每一步变成真实进度（见下方 _emit_loading_tail_progress）。
	context._generator._emit_loading_tail_progress(label)

# ─── 生成收尾段的诚实进度：simulation(0.96) 之后的引导链 ────────────────────
# 背景：generate() 只在 8 个点发 bake_progress，而 `_setup_sus` 整条引导链
# （native bind → 资源勘测 → 生态播种 → 玩法/经济 bootstrap → 拓扑构建）一步都不发，
# 于是进度条会在 92% 处长时间钉住。这里复用"每一步都会被调用"的
# `_loading_profile_step()` 当推进点，用一个单调几何游标把这段推进到
# LOADING_TAIL_CEIL：
#   游标_{n+1} = 游标_n + (CEIL - 游标_n) * GAIN
# 因此严格单调、绝不回退、也永远到不了 1.0（1.0 只属于 generate() 末尾的
# bake_progress("done", 1.0)，100% 只属于 WorldLoadingOverlay.hide_completed()）。

static func _loading_tail_stage_for(context, label: String) -> String:
	var lowered := label.to_lower()
	for rule in context._generator.LOADING_TAIL_STAGE_RULES:
		if lowered.contains(String(rule[0])):
			return String(rule[1])
	return context._generator.LOADING_TAIL_STAGE_DEFAULT

# 发出一次尾部进度。只有满足两个条件才发：
#   1) bake_world 已经返回、_last_world 被换成新实例（否则烘焙段 44%~88% 会被压掉）；
#   2) _setup_sus 已经把新世界写进 _sus_world（也就是确实进入了收尾引导链）。
# 两个条件都用实例身份判断，regenerate 时旧世界不会被误认成新世界。

static func _emit_loading_tail_progress(context, label: String) -> void:
	if context._generator._loading_epoch != context._generator._loading_tail_epoch:
		context._generator._loading_tail_epoch = context._generator._loading_epoch
		context._generator._loading_tail_progress = context._generator.LOADING_TAIL_START
		context._generator._loading_tail_world_id = context._generator._last_world.get_instance_id() if context._generator._last_world != null else 0
		context._generator._loading_tail_active = false
	if not context._generator._loading_tail_active:
		if context._generator._last_world == null:
			return
		if context._generator._last_world.get_instance_id() == context._generator._loading_tail_world_id:
			return
		if context._generator._sus_world != context._generator._last_world:
			return
		context._generator._loading_tail_active = true
	var step = (context._generator.LOADING_TAIL_CEIL - context._generator._loading_tail_progress) * context._generator.LOADING_TAIL_GAIN
	if step <= 0.0:
		return
	context._generator._loading_tail_progress = minf(context._generator.LOADING_TAIL_CEIL, context._generator._loading_tail_progress + step)
	context._generator.bake_progress.emit(context._generator._loading_tail_stage_for(label), context._generator._loading_tail_progress)

static func _generation_slice_due(context) -> bool:
	var now := Time.get_ticks_usec()
	if now-context._generator._generation_slice_start_usec < UITokens.LOADING_MAIN_SLICE_USEC:
		return false
	context._generator._generation_slice_start_usec = now
	return true

static func _prepare_season_geometry_cooperative(context, map: MapData, n: int) -> void:
	var rows := PackedInt32Array()
	var jitter := PackedFloat32Array()
	rows.resize(n)
	jitter.resize(n)
	var tree := Engine.get_main_loop() as SceneTree
	var start := Time.get_ticks_usec()
	for i in n:
		var cell := map.cell_at(i)
		if cell != null:
			rows[i] = context._generator._cube_to_row(cell,context._generator._last_cfg)
			jitter[i] = context._generator._height_warp.get_noise_2d(float(cell.q)*8.0,float(cell.r)*8.0)*.04 if context._generator._height_warp != null else 0.0
		if tree != null and Time.get_ticks_usec()-start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await context._generator._yield_generation_frame()
			if context._generator._loading_frames.canceled:
				return
			start = Time.get_ticks_usec()
	context._generator._season_knob_row_idx_cache = rows
	context._generator._season_knob_jitter_cache = jitter
	context._generator._season_knob_cache_map_id = map.get_instance_id()
	context._generator._season_knob_cache_cfg_id = context._generator._last_cfg.get_instance_id()
	context._generator._season_knob_cache_warp_id = context._generator._height_warp.get_instance_id() if context._generator._height_warp != null else 0
	context._generator._season_knob_cache_n = n
