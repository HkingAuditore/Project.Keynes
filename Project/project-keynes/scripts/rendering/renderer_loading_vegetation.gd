extends RefCounted

## Stateless collaborator for ShrubLayer.

static func _setup_loading_vegetation_layer(host, layer: ShrubLayer) -> void:

	layer.set_world_ext(host._world_ext)
	if layer.has_method("set_defer_initial_rebuild"):
		layer.set_defer_initial_rebuild(host.detail_scatter_family_renderer_enabled)
	if layer.has_method("set_chunked_multimesh_enabled"):
		layer.set_chunked_multimesh_enabled(host.detail_scatter_chunked_multimesh_enabled, host.detail_scatter_chunk_size_cells)
	var layer_t0 = Time.get_ticks_usec()
	layer.setup(host._map, host._world, host._world.world_bounds, host.hex_size, host.visual_quality)
	print("[loading-renderer-step] %s %.1fms" % [layer.name,float(Time.get_ticks_usec()-layer_t0)/1000.0])
	if host._camera_view_initialized and layer.has_method("set_camera_view"):
		layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)

## 加载尾段（进度条 98% 之后）原先对每一层 `await setup_cooperative()`，单层 200–400ms
## （第一个草地层还要额外吃 shader 首次编译），14+ 层叠加就是那段看不见尽头的卡顿。
##
## 现在改成"加载期只做最便宜的初始化 + 进世界后分帧补齐"：
##   1) 每层只建资源：shader / 材质、MultiMesh、profile / 质量档 / 光照 / TOD 状态
##      （ShrubLayer.setup() 的 defer 分支，纯同步，不清散点）；
##   2) 把整张地图的 chunk 登记成"待补"，由 _reactivate_deferred_detail_chunks()
##      放行 prefetch 视口内的块；
##   3) 真正的散布构建交给已有的运行期预算路径逐帧完成：
##      _drain_detail_refresh_queue() → ShrubLayer.refresh_chunk_for_succession()
##      → 原生 encode_detail_scatter_delta + chunk MultiMesh 上传。
## 玩家进世界后先看到地形，植被在 1–3 秒内按"离相机最近优先"逐块长出来。

static func _rebuild_cooperative(host) -> void:

	if host._world_quad == null:
		return
	if host._map == null or host._world == null or host._map.cell_count() == 0:
		host._set_world_quad_mesh(null)
		host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.clear()
		)
		host._mark_detail_budget_total_dirty()
		return

	host._apply_world_quad_geometry()
	# 防御性：若 set_world_ext 尚未注入，尝试从已注入的 MapBaker 取 C++ ext。
	if host._world_ext == null and host._map_baker != null and "_world_ext" in host._map_baker:
		host.set_world_ext(host._map_baker._world_ext)
	var _t_veg2 = Time.get_ticks_usec()
	var deferred_layers = 0
	if host.PK_WEB_DEFER_VEG_LAYERS and OS.has_feature("web"):
		_defer_vegetation_layers_after_bind(host, )
	else:
		deferred_layers = await _setup_loading_vegetation_layers_for_deferred_fill(host, )
	WebTelemetry.emit("rebuild_phase", {"p": "veg_layers_coop", "dur": int(float(Time.get_ticks_usec()-_t_veg2)/1000.0)})
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.configure(host._detail_layers, host.detail_scatter_family_renderer_enabled)
		if host._camera_view_initialized:
			host._detail_family_layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)
	if host.detail_scatter_family_renderer_enabled and host._camera_view_initialized:
		host._queue_missing_prefetch_detail_chunks()
	if deferred_layers > 0:
		_seed_deferred_detail_chunks_for_deferred_fill(host, )
		host._reactivate_deferred_detail_chunks()
		# 恢复"非加载期"的 defer 策略：之后再调 setup() / 切画质时按老语义走，
		# 不会因为加载期的临时 defer 出现"清空了却没人补"。
		for layer in host._detail_layers:
			if layer != null and layer.has_method("set_defer_initial_rebuild"):
				layer.set_defer_initial_rebuild(host.detail_scatter_family_renderer_enabled)
	# 此刻各层实例数还是 0：这里只把预算统计切到"已知容量"口径并下发一次可见比例
	# （1.0 不裁剪）。运行期每补完一批 chunk，_drain_detail_refresh_queue() 都会
	# _mark_detail_budget_total_dirty() + _apply_detail_global_budget() 重新结算。
	var _t_budget2 = Time.get_ticks_usec()
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget(true)
	WebTelemetry.emit("rebuild_phase", {"p": "detail_budget_coop", "dur": int(float(Time.get_ticks_usec()-_t_budget2)/1000.0)})
	host._log_detail_scatter_rebuild_summary("renderer_rebuild")
	if deferred_layers > 0:
		_arm_deferred_detail_fill_watchdog(host, )
	if host._shader_mat == null:
		return
	host._apply_uniforms()


## 逐层"最便宜的初始化"，返回真正走了 defer 的层数（0 = 全量同步构建，老行为）。
## defer 的前提是分块 MultiMesh：chunk 是运行期补齐的最小单位。

static func _setup_loading_vegetation_layers_for_deferred_fill(host) -> int:

	var deferred_layers = 0
	var can_defer = host.detail_scatter_chunked_multimesh_enabled
	var window_start_usec = Time.get_ticks_usec()
	var layers_in_window = 0
	var layer_built = 0
	for layer in host._detail_layers:
		if layer == null:
			continue
		if can_defer:
			_setup_loading_vegetation_layer_deferred(host, layer)
			deferred_layers += 1
		else:
			await _setup_loading_vegetation_layer_cooperative(host, layer)
		# 逐层发进度：这一段（14+ 层）原先在进度条上完全静默，是"卡在 98%"的
		# 主要来源。defer 之后这一步只剩初始化（几毫秒/层），进度能匀速走完。
		layer_built += 1
		host.loading_layer_progress.emit(layer_built, host._detail_layers.size(), String(layer.name))
		layers_in_window += 1
		# 不再"每层一帧"（那是给加载期 UI 让帧的老做法）：改成每 N 层或累计超预算
		# 才让一帧，既保住进度条动画，也不再把让帧开销乘以层数。
		var elapsed_ms = float(Time.get_ticks_usec() - window_start_usec) / 1000.0
		if layers_in_window >= host.DETAIL_LOADING_LAYERS_PER_YIELD \
				or elapsed_ms >= host.DETAIL_LOADING_YIELD_BUDGET_MS:
			await host.get_tree().process_frame
			window_start_usec = Time.get_ticks_usec()
			layers_in_window = 0
	return deferred_layers


## 单层最便宜的初始化：world_ext / defer 标记 / 分块参数，然后只跑 setup() 的
## defer 分支（建 MultiMesh 资源 + 推 profile / 质量档 / 光照 / TOD uniform）。

static func _setup_loading_vegetation_layer_deferred(host, layer: ShrubLayer) -> void:

	layer.set_world_ext(host._world_ext)
	if layer.has_method("set_defer_initial_rebuild"):
		layer.set_defer_initial_rebuild(true)
	if layer.has_method("set_chunked_multimesh_enabled"):
		layer.set_chunked_multimesh_enabled(host.detail_scatter_chunked_multimesh_enabled, host.detail_scatter_chunk_size_cells)
	var layer_t0 = Time.get_ticks_usec()
	layer.setup(host._map, host._world, host._world.world_bounds, host.hex_size, host.visual_quality)
	print("[loading-renderer-step] %s %.1fms (deferred)" % [
		layer.name, float(Time.get_ticks_usec() - layer_t0) / 1000.0])
	if host._camera_view_initialized and layer.has_method("set_camera_view"):
		layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)


## 非分块（chunked=off）配置下的老路径：一次性协同构建整层。只有关掉分块
## MultiMesh 时才会走到，属于兼容分支。

static func _setup_loading_vegetation_layer_cooperative(host, layer: ShrubLayer) -> void:

	layer.set_world_ext(host._world_ext)
	if layer.has_method("set_defer_initial_rebuild"):
		layer.set_defer_initial_rebuild(host.detail_scatter_family_renderer_enabled)
	if layer.has_method("set_chunked_multimesh_enabled"):
		layer.set_chunked_multimesh_enabled(host.detail_scatter_chunked_multimesh_enabled, host.detail_scatter_chunk_size_cells)
	var layer_t0 = Time.get_ticks_usec()
	await layer.setup_cooperative(host._map, host._world, host._world.world_bounds, host.hex_size, host.visual_quality)
	print("[loading-renderer-step] %s %.1fms" % [layer.name,float(Time.get_ticks_usec()-layer_t0)/1000.0])
	if host._camera_view_initialized and layer.has_method("set_camera_view"):
		layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)


## 把整张地图的 chunk 登记为"待分帧补齐"。这里只登记、不入队：真正入队由
## _reactivate_deferred_detail_chunks() 按 prefetch 视口筛选，保证进世界第一屏
## 只补视野附近的块；视野外的块留在 _detail_deferred_chunks 里，等相机移动时
## set_camera_view() 再触发一次放行。
## Web 专用：进世界之后再补植被层 setup（含 deferred chunk 播种）。
## 实测这段 4.1 秒（9 层 x wasm），放在加载链里必然超时。

static func _defer_vegetation_layers_after_bind(host) -> void:

	if host._web_veg_defer_started:
		return
	host._web_veg_defer_started = true
	var tree = host.get_tree()
	if tree == null:
		return
	var timer = tree.create_timer(2.5, true, false, true)
	await timer.timeout
	if not host.is_inside_tree():
		return
	var started = Time.get_ticks_usec()
	var deferred_layers: int = await _setup_loading_vegetation_layers_for_deferred_fill(host, )
	if deferred_layers > 0:
		_seed_deferred_detail_chunks_for_deferred_fill(host, )
		host._reactivate_deferred_detail_chunks()
		for layer in host._detail_layers:
			if layer != null and layer.has_method("set_defer_initial_rebuild"):
				layer.set_defer_initial_rebuild(host.detail_scatter_family_renderer_enabled)
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget(true)
	WebTelemetry.emit("veg_deferred_done", {
		"layers": deferred_layers,
		"dur": int(float(Time.get_ticks_usec() - started) / 1000.0),
	})



static func _seed_deferred_detail_chunks_for_deferred_fill(host) -> void:

	# PROBE：web 上整段跳过 deferred 植被填充（图层照常创建），
	# 用来判定那次 ~24s 长帧是否来自填充 / MultiMesh 上传。
	if host.PK_WEB_SKIP_DEFERRED_VEG_SEED and OS.has_feature("web"):
		print("[probe] web: skip deferred vegetation seed")
		return
	var probe = _detail_chunk_probe_layer(host, )
	if probe == null or host._map == null:
		return
	# Web：只登记"玩家脚下一小块"的 chunk，其余等相机移动时按 prefetch 视口补。
	# 实测单位成本：每 chunk × 每层 ≈ 1 s（wasm 下的原生 scatter）。
	# 若按整张世界登记 → 12 chunk × 9 层 ≈ 50 s；按整幅相机视野登记 → 仍要 30 s+。
	# 这里取世界 12% 见方的一块（约 1 个 chunk），把入场成本压到 ~9 s 以内，
	# 之后的植被随视野流式补齐。
	var seed_rect: Rect2 = host._world.world_bounds if host._world != null else Rect2()
	if OS.has_feature("web"):
		var base: Rect2 = host._world.world_bounds if host._world != null else Rect2()
		var patch = base.size * 0.12
		var center = host._camera_world_center if host._camera_view_initialized else base.position + base.size * 0.5
		seed_rect = Rect2(center - patch * 0.5, patch)
	var plan: Array = probe.detail_chunk_plan_for_view(seed_rect)
	if plan.is_empty():
		return
	var family_mask = host._detail_all_family_mask()
	var profile_mask = (1 << host._detail_layers.size()) - 1
	var seeded = 0
	for chunk in plan:
		var chunk_id = int(chunk.get("chunk_id", -1))
		if chunk_id < 0:
			continue
		host._detail_deferred_chunks[chunk_id] = family_mask
		host._detail_deferred_profile_masks[chunk_id] = profile_mask
		seeded += 1
	print("[detail_scatter/DEFER_SEED] chunks=%d layers=%d" % [seeded, host._detail_layers.size()])



static func _detail_chunk_probe_layer(host):

	for layer in host._detail_layers:
		if layer != null and is_instance_valid(layer) \
				and layer.has_method("detail_chunk_plan_for_view") \
				and layer.has_method("detail_chunk_is_in_prefetch") \
				and layer.has_method("detail_chunk_cells"):
			return layer
	return null



static func _arm_deferred_detail_fill_watchdog(host) -> void:

	host._deferred_fill_watchdog_msec = Time.get_ticks_msec()
	host._deferred_fill_rescued = false


## 兜底：defer 之后若刷新管线已经空闲、却在救援窗口内一株都没建出来（原生
## encode_detail_scatter_delta 缺失 / chunk 计划失败等），退回一次性全量构建。

static func _poll_deferred_detail_fill_watchdog(host) -> void:

	if host._deferred_fill_rescued or host._deferred_fill_watchdog_msec <= 0:
		return
	if Time.get_ticks_msec() - host._deferred_fill_watchdog_msec \
			< int(host.DEFERRED_DETAIL_FILL_RESCUE_SECONDS * 1000.0):
		return
	if not host._detail_refresh_queue.is_empty() or host._detail_plan_phase != host.DETAIL_PLAN_IDLE \
			or not host._detail_refresh_batches.is_empty():
		# 还在排队：只是慢，不是坏了，继续等。
		return
	host._deferred_fill_watchdog_msec = 0
	host._deferred_fill_rescued = true
	if host._map == null or host._world == null or host._detail_layers.is_empty():
		return
	var built = 0
	for layer in host._detail_layers:
		if layer != null and layer.has_method("instance_count"):
			built += int(layer.instance_count())
	if built > 0:
		return
	push_warning("[detail_scatter] 分帧补齐在救援窗口内没有任何植被实例，回退全量构建")
	print("[detail_scatter/DEFER_RESCUE] fallback=full_rebuild layers=%d" % host._detail_layers.size())
	for layer in host._detail_layers:
		if layer == null or not is_instance_valid(layer):
			continue
		if layer.has_method("set_defer_initial_rebuild"):
			layer.set_defer_initial_rebuild(false)
		layer.setup(host._map, host._world, host._world.world_bounds, host.hex_size, host.visual_quality)
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget(true)

