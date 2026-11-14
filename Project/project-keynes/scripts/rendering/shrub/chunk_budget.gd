extends RefCounted

## Stateless collaborator for ShrubLayer.

static func _effective_visible_instance_fraction(host) -> float:

	if host._instance_count <= 0:
		return 0.0
	return float(_lod_visible_count(host, host._instance_count, host._far_instance_count)) / float(host._instance_count)



static func active_instance_count(host) -> int:

	if not host._camera_view_initialized:
		return clampi(int(round(float(host._instance_count) * host._zoom_visible_fraction)), 0, host._instance_count)
	if host._chunked_multimesh_enabled and not host._chunk_nodes.is_empty():
		if host._active_instance_count_valid:
			return host._active_instance_count_cache
		var total = 0
		for raw_chunk_id in host._chunk_nodes.keys():
			var chunk_id = int(raw_chunk_id)
			if not host.detail_chunk_is_render_visible(chunk_id):
				continue
			var count = int(host._chunk_instance_counts.get(chunk_id, 0))
			total += clampi(int(round(float(count) * host._zoom_visible_fraction)), 0, count)
		host._active_instance_count_cache = total
		host._active_instance_count_valid = true
		host._active_instance_count_scans += 1
		return host._active_instance_count_cache
	if host._multimesh == null:
		return 0
	return clampi(int(round(float(host._instance_count) * host._zoom_visible_fraction)), 0, host._instance_count)



static func _lod_visible_count(host, total: int, far_count: int) -> int:

	if total <= 0:
		return 0
	if not host._family_batch_suppressed:
		var near_budget_count = clampi(int(floor(float(total) * host._shadow_fraction)), 0, total)
		var budgeted_far_count = mini(clampi(far_count, 0, total), near_budget_count)
		return clampi(
			int(round(lerpf(float(budgeted_far_count), float(near_budget_count), host._lod_zoom_t))),
			0,
			total
		)
	var lod_count = clampi(int(round(float(total) * host._zoom_visible_fraction)), 0, total)
	if host._zoom_visible_fraction > 0.0 and total > 0:
		lod_count = maxi(1, lod_count)
	var budget_count = clampi(int(floor(float(total) * host._shadow_fraction)), 0, total)
	return mini(lod_count, budget_count)



static func apply_visible_instance_fraction(host, fraction: float) -> void:

	host._shadow_fraction = clampf(fraction, 0.0, 1.0)
	# [viewport-budget 2026-11-03] 均匀 fraction 会覆盖加权分配的每 chunk 计数，
	# 算完必须让视口优先分配在下一拍重算，否则两者互相踩。
	invalidate_viewport_budget_cache(host, )
	if host._chunked_multimesh_enabled and not host._chunk_nodes.is_empty():
		var any_visible = false
		var show_shadow = host._shadow_should_render()
		for chunk_id in host._chunk_nodes.keys():
			var node: MultiMeshInstance2D = host._chunk_nodes[chunk_id]
			if node == null or not is_instance_valid(node) or node.multimesh == null:
				continue
			var count = int(host._chunk_instance_counts.get(chunk_id, 0))
			var far_count = int(host._chunk_far_instance_counts.get(chunk_id, count))
			var next_visible = _lod_visible_count(host, count, far_count)
			node.multimesh.visible_instance_count = next_visible
			node.visible = not host._family_batch_suppressed \
				and host.detail_chunk_is_render_visible(int(chunk_id)) \
				and host._profile().enabled and not host._camera_lod_hidden and next_visible > 0
			host._sync_chunk_wrap_nodes(int(chunk_id))
			any_visible = any_visible or node.visible
			# 逐帧 LOD 内联同步对应 shadow chunk 的可见数（仅 visible_instance_count，无 buffer 操作）
			var snode: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
			if snode != null and is_instance_valid(snode) and snode.multimesh != null:
				snode.multimesh.visible_instance_count = clampi(next_visible, 0, snode.multimesh.instance_count)
				snode.visible = show_shadow and node.visible and next_visible > 0
				host._sync_shadow_chunk_wrap_nodes(int(chunk_id))
		host.visible = not host._family_batch_suppressed and host._profile().enabled \
			and not host._camera_lod_hidden and any_visible
		if host._shadow_mmi != null:
			host._shadow_mmi.visible = false
		return
	if host._multimesh == null:
		host.visible = false
		host._sync_single_shadow()
		return
	var next_visible = _lod_visible_count(host, host._instance_count, host._far_instance_count)
	host._multimesh.visible_instance_count = next_visible
	host.visible = not host._family_batch_suppressed and host._profile().enabled \
		and not host._camera_lod_hidden and next_visible > 0
	host._sync_single_wrap_nodes()
	host._sync_single_shadow()


# ─── 视口优先的细节预算分配 [viewport-budget 2026-11-03] ──────────────────────
# 背景：细节层原先把 hex_renderer 的全局 fraction 均匀摊到每个 chunk
# （apply_visible_instance_fraction）。玩家放大到某片区域时，那片区域也被同一比例
# 砍掉，近景反而比远景更荒。这里把「全局预算」改写成「视口优先」：视口内、离视口
# 中心近、以及高缩放的 chunk 尽量保住自己的 LOD 天花板，裁剪压力按「离视口中心
# 多远」分摊到视口边缘与外圈。
#
# 硬约束：Σ 可见 ≤ budget，其中
#   budget = min(floor(global_fraction × active_instance_count()), Σ LOD 天花板)
# 前一项正是 hex_renderer._apply_detail_global_budget 扫描 total 时用的口径
# （active_instance_count 只累计 render-host.visible chunk 的 count×zoom_fraction），
# 所以本函数给出的是「同样总预算内的重分配」，不可能突破全局预算。
#
# 与 _lod_visible_count 的组合顺序（叠加，不取代）：
#   1) 先算 LOD 天花板 L_c = _lod_visible_count(count, far_count)：zoom / 远景密度
#      倍数 / far_count 决定「这个 chunk 最多能显示多少」。实例顺序是「远景均衡前缀 +
#      近景尾部」，visible_instance_count 截的是前缀，所以可见集永远是合法前缀。
#   2) 再算视口权重 w_c，把 L_c 按 w_c 与预算压成 target_c（target_c ≤ L_c）。
#      因为永不越过天花板，zoom 拉近时细节按 LOD 自然恢复，也不会出现「远景没铺满
#      却先冒近景尾部」的破序。
#   3) global_fraction 只当预算压缩强度，不再逐 chunk 直接相乘。
# 注意 (1) 里屏蔽了 _shadow_fraction：否则「均匀 fraction」与「视口权重」会叠加成
# 两次抽稀（旧路径每 chunk 先砍一刀，视口优先再砍一刀）。


static func set_viewport_budget_log_enabled(host, enabled: bool) -> void:

	host._vp_budget_log_enabled = enabled


# chunk 计数被任何路径改写（重建 chunk / 演替 / 驱逐 / 均匀 fraction）后调一次，
# 下一次 apply 就会重算。只翻标志，O(1)。

static func invalidate_viewport_budget_cache(host) -> void:

	host._vp_budget_cache_valid = false


# 给 hex_renderer.detail_scatter_budget_report() 合并用的诊断（含缓存命中/耗时计数）。

static func viewport_budget_report(host) -> Dictionary:

	var out = host._vp_budget_cache_diag.duplicate(true)
	out["valid"] = host._vp_budget_cache_valid
	out["applies"] = host._vp_budget_applies
	out["skips"] = host._vp_budget_skips
	out["last_ms"] = host._vp_budget_last_ms
	return out


# 视口优先预算分配（新增 API，不改变 apply_visible_instance_fraction 的行为）。
# view_rect：相机当前可见世界矩形；pixel_world_size：一物理像素覆盖的世界单位数
# （hex_renderer.pixel_world_size()，= 1/canvas_scale），用于判断「近景/总览」。
# 返回诊断 Dictionary（同一对象被缓存复用，调用方只读）：kept / budget / chunks /
# near_fraction_min / near_fraction_max / near_fraction_mean / far_fraction_mean /
# rebalanced，外加 lod_total / kept_ratio / theta / boost / edge_falloff /
# coverage_ratio / coverage_reserve / weight_min / weight_max / skipped_chunks / ms。
# 只改 visible_instance_count（以及 node/shadow node 的 host.visible），不重建 MultiMesh、
# 不逐实例 set_transform。

static func apply_visible_instance_fraction_weighted(host, 
		global_fraction: float,
		view_rect: Rect2,
		zoom: float,
		pixel_world_size: float,
		log_enabled: bool = false) -> Dictionary:

	var t0_us = Time.get_ticks_usec()
	var fraction = clampf(global_fraction, 0.0, 1.0)
	var zoom_value = maxf(host._camera_zoom, 0.01) if not is_finite(zoom) else clampf(zoom, 0.01, 16.0)
	var px_world = pixel_world_size
	if not is_finite(px_world) or px_world <= 0.0:
		px_world = 1.0 / maxf(zoom_value, 0.0001)
	var rect = view_rect
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		rect = host._camera_view_rect
	var use_view = rect.size.x > 0.0 and rect.size.y > 0.0
	# 缓存：同样的 (view_rect, zoom, global_fraction) 不重复算，也不重复写
	# visible_instance_count（避免每帧抖动）。
	if host._vp_budget_cache_valid and _vp_budget_signature_matches(host, rect, zoom_value, fraction):
		host._vp_budget_skips += 1
		return host._vp_budget_cache_diag
	# 退化：单 MultiMesh（非分块）只能给一个前缀长度，退回原均匀行为。
	# 小图 / mobile LOW（单层 ≤5000）常见，此时行为必须与旧路径一致。
	if not host._chunked_multimesh_enabled or host._chunk_nodes.is_empty():
		apply_visible_instance_fraction(host, fraction)
		var degraded_kept = 0
		if host._multimesh != null:
			degraded_kept = int(host._multimesh.visible_instance_count)
		var degraded = {
			"kept": degraded_kept,
			"budget": degraded_kept,
			"chunks": 0,
			"near_fraction_min": fraction,
			"near_fraction_max": fraction,
			"near_fraction_mean": fraction,
			"far_fraction_mean": fraction,
			"rebalanced": false,
			"degraded": "single_multimesh",
			"global_fraction": fraction,
			"zoom": zoom_value,
			"lod_total": host._instance_count,
			"ms": 0.0,
		}
		host._vp_budget_last_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		_store_viewport_budget_cache(host, rect, zoom_value, fraction, degraded)
		return degraded
	# 加权分配接管预算后，_shadow_fraction 必须回到 1.0：它只在 _lod_visible_count
	# 里当「均匀抽稀」用，留着旧值会让 chunk 重建路径再砍一刀。
	host._shadow_fraction = 1.0
	var falloff = _vp_budget_edge_falloff(host, zoom_value, px_world)
	var view_radius = maxf(rect.size.length() * 0.5, 0.0001)
	var boost = host.VP_BUDGET_BOOST_MAX
	if fraction > 0.000001:
		boost = clampf(1.0 / fraction, 1.0, host.VP_BUDGET_BOOST_MAX)
	var ids = PackedInt32Array()
	var lods = PackedInt32Array()
	var weights = PackedFloat32Array()
	var ts = PackedFloat32Array()
	var wants = PackedInt32Array()
	var off_view = PackedInt32Array()   # [chunk_id, lod, ...] 视口外 chunk
	var lod_total = 0
	var w_max = 0.0
	for raw_id in host._chunk_nodes.keys():
		var chunk_id = int(raw_id)
		var node: MultiMeshInstance2D = host._chunk_nodes[raw_id]
		if node == null or not is_instance_valid(node) or node.multimesh == null:
			continue
		var count = mini(int(host._chunk_instance_counts.get(chunk_id, 0)), node.multimesh.instance_count)
		if count <= 0:
			continue
		var far_count = clampi(int(host._chunk_far_instance_counts.get(chunk_id, count)), 0, count)
		var lod = _vp_budget_lod_ceiling(host, count, far_count)
		var t = 0.0
		if use_view:
			t = _vp_budget_chunk_distance_t(host, chunk_id, rect, view_radius)
		elif not host.detail_chunk_is_render_visible(chunk_id):
			t = -1.0
		if t < 0.0:
			# 视口外：本来就被 detail_chunk_is_render_visible 隐藏，不计入预算。
			# 仍写回 LOD 天花板，避免它刚进视口时顶着 0 计数而闪一帧空白。
			off_view.append(chunk_id)
			off_view.append(lod)
			continue
		var weight = clampf(1.0 - falloff * t, 0.02, 1.0)
		var want = 0
		if lod > 0:
			# 第一遍：ceil(LOD 天花板 × f × w × boost)。boost 让视口内 w≈1 的 chunk
			# 在 f<1 时也能补到 100%（boost = 1/f，夹在 [1, 6]）。
			want = clampi(int(ceil(float(lod) * fraction * weight * boost)), 0, lod)
		ids.append(chunk_id)
		lods.append(lod)
		weights.append(weight)
		ts.append(t)
		wants.append(want)
		lod_total += lod
		w_max = maxf(w_max, weight)
	# 预算：与 hex_renderer 扫描 total 同口径（只算 render-host.visible chunk 的
	# count×zoom_fraction），再夹到本层 LOD 天花板合计。后者保证「不会显示超过 LOD」。
	var budget = lod_total
	if fraction < 1.0:
		budget = mini(int(floor(float(active_instance_count(host, )) * fraction)), lod_total)
	budget = maxi(budget, 0)
	# 覆盖保底：视口内每个有实例的 chunk 至少留 COVERAGE_FLOOR × 期望值，总保底不超过
	# 预算的 60%（剩下的 40% 才用来做「近处优先」）。否则最靠近视口中心的 chunk 会
	# 独占整个预算，视口其余部分整块变空 —— 那正是「近景更荒」的另一种形态。
	var reserve_ratio = host.VP_BUDGET_COVERAGE_FLOOR
	var reserve_raw = 0
	for i in range(ids.size()):
		reserve_raw += int(wants[i])
	if reserve_raw > 0:
		var base_reserve = 0
		for i in range(ids.size()):
			base_reserve += mini(int(wants[i]),
				int(ceil(float(wants[i]) * host.VP_BUDGET_COVERAGE_FLOOR)))
		var reserve_cap = int(floor(float(budget) * host.VP_BUDGET_COVERAGE_SHARE))
		if base_reserve > reserve_cap:
			reserve_ratio = host.VP_BUDGET_COVERAGE_FLOOR * float(reserve_cap) / float(base_reserve)
	var reserves = PackedInt32Array()
	var extras = PackedInt32Array()
	var targets = PackedInt32Array()
	var reserve_total = 0
	var kept = 0
	for i in range(ids.size()):
		var want_i = int(wants[i])
		var reserve_i = 0
		if want_i > 0 and reserve_ratio > 0.0:
			reserve_i = mini(want_i, int(ceil(float(want_i) * reserve_ratio)))
		reserves.append(reserve_i)
		extras.append(want_i - reserve_i)
		targets.append(want_i)
		reserve_total += reserve_i
		kept += want_i
	var rebalanced = false
	var theta = 0.0
	if kept > budget and not ids.is_empty():
		# 第二遍：预算不够。只压「第一遍里可让的那部分」（extras = want - 保底），
		# 按「离视口中心多远」做软阈值 θ：越远削得越深，距离相同则保留比例相同
		# —— 不会出现「矩形块整块消失」的硬边。
		var budget_extra = maxi(budget - reserve_total, 0)
		theta = _vp_budget_solve_theta(host, w_max, extras, weights, budget_extra)
		var denom = maxf(w_max - theta, 0.0001)
		var compressed = 0
		for i in range(ids.size()):
			var ramp = 1.0
			if theta > 0.000001:
				ramp = clampf((weights[i] - theta) / denom, 0.0, 1.0)
			var next_extra = clampi(
				int(ceil(float(extras[i]) * ramp)), 0, int(extras[i]))
			extras[i] = next_extra
			targets[i] = int(reserves[i]) + next_extra
			compressed += int(targets[i])
		kept = compressed
		rebalanced = true
		if kept > budget and budget_extra > 0:
			# 兜底 1：软阈值压不动的情况（一个贴近中心的 chunk 自己就吃满预算），
			# 把可让部分整体等比缩放；保底那层不动，视口覆盖仍在。
			var extra_kept = kept - reserve_total
			var scale = float(budget_extra) / maxf(float(extra_kept), 1.0)
			var scaled = 0
			for i in range(ids.size()):
				extras[i] = clampi(int(floor(float(extras[i]) * scale)), 0, int(extras[i]))
				targets[i] = int(reserves[i]) + int(extras[i])
				scaled += int(targets[i])
			kept = scaled
	var order = _vp_budget_weight_order(host, ids, weights)
	var refilled = false
	if kept < budget:
		# 第三遍：还有余量，按权重从高到低回填（不超过各 chunk 的 LOD 天花板）。
		var surplus = budget - kept
		for k in range(order.size()):
			if surplus <= 0:
				break
			var i = int(order[k])
			var room = int(lods[i]) - int(targets[i])
			if room <= 0:
				continue
			var add = mini(room, surplus)
			targets[i] += add
			surplus -= add
			kept += add
			refilled = true
	if refilled and fraction < 0.999:
		# f≈1 时的回填只是把「权重期望」还原成 LOD 原始结果，不算重分配。
		rebalanced = true
	# 兜底 2：无论如何都不许突破 budget（远端先削）。
	if kept > budget and not order.is_empty():
		for k in range(order.size() - 1, -1, -1):
			if kept <= budget:
				break
			var i = int(order[k])
			var cut = mini(int(targets[i]), kept - budget)
			if cut <= 0:
				continue
			targets[i] -= cut
			kept -= cut
	# 落盘：只写 visible_instance_count / host.visible，复用现有 chunk 可见计数路径。
	var layer_enabled: bool = bool(host._profile().enabled)
	var show_shadow = host._shadow_should_render()
	var any_visible = false
	var visible_chunks = 0
	for i in range(ids.size()):
		var chunk_id = int(ids[i])
		var next_visible = int(targets[i])
		_apply_chunk_viewport_counts(host, chunk_id, next_visible, true, layer_enabled, show_shadow)
		if next_visible > 0:
			any_visible = true
			visible_chunks += 1
	for k in range(0, off_view.size(), 2):
		_apply_chunk_viewport_counts(host, 
			int(off_view[k]), int(off_view[k + 1]), false, layer_enabled, show_shadow)
	host._visible_chunk_count = visible_chunks
	host.visible = not host._family_batch_suppressed and layer_enabled \
		and not host._camera_lod_hidden and any_visible
	if host._shadow_mmi != null:
		host._shadow_mmi.visible = false
	var diag = _vp_budget_build_diag(host, 
		ids, lods, weights, ts, targets, kept, budget, lod_total, fraction,
		zoom_value, px_world, falloff, boost, theta, rebalanced,
		off_view.size() / 2)
	diag["coverage_reserve"] = reserve_total
	diag["coverage_ratio"] = reserve_ratio
	diag["w_max"] = w_max
	host._vp_budget_applies += 1
	host._vp_budget_last_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	diag["ms"] = host._vp_budget_last_ms
	_store_viewport_budget_cache(host, rect, zoom_value, fraction, diag)
	if (log_enabled or host._vp_budget_log_enabled) and PKLog.enabled and fraction < 0.999:
		host._vp_budget_log_count += 1
		if host._vp_budget_log_count <= 8 or host._vp_budget_log_count % 60 == 0:
			print("[detail_scatter/VIEWPORT_BUDGET] layer=%s zoom=%.3f f=%.3f kept=%d/%d chunks=%d skip=%d near[min=%.2f max=%.2f mean=%.2f] far_mean=%.2f theta=%.3f boost=%.2f falloff=%.2f rebalanced=%s" % [
				host.name,
				float(diag.get("zoom", 0.0)),
				fraction,
				int(diag.get("kept", 0)),
				int(diag.get("budget", 0)),
				int(diag.get("chunks", 0)),
				int(diag.get("skipped_chunks", 0)),
				float(diag.get("near_fraction_min", 0.0)),
				float(diag.get("near_fraction_max", 0.0)),
				float(diag.get("near_fraction_mean", 0.0)),
				float(diag.get("far_fraction_mean", 0.0)),
				theta,
				boost,
				falloff,
				str(rebalanced),
			])
	return diag


# 诊断用：某 chunk 的 LOD 天花板（不含视口权重 / 不含全局 fraction）。
# 供 hex_renderer 报告与 smoke 断言核对「保留率」用的分母。

static func detail_chunk_lod_ceiling(host, chunk_id: int) -> int:

	var node: MultiMeshInstance2D = host._chunk_nodes.get(chunk_id, null)
	if node == null or not is_instance_valid(node) or node.multimesh == null:
		return 0
	var count = mini(int(host._chunk_instance_counts.get(chunk_id, 0)), node.multimesh.instance_count)
	if count <= 0:
		return 0
	return _vp_budget_lod_ceiling(host, 
		count, clampi(int(host._chunk_far_instance_counts.get(chunk_id, count)), 0, count))


# LOD 天花板：与 _lod_visible_count 同一套 zoom / 远景分层，但屏蔽全局均匀
# _shadow_fraction —— 预算压缩交给视口权重，LOD 只表达「拉远看远景 / 放大看细节」。

static func _vp_budget_lod_ceiling(host, count: int, far_count: int) -> int:

	if count <= 0:
		return 0
	var saved = host._shadow_fraction
	host._shadow_fraction = 1.0
	var out = _lod_visible_count(host, count, far_count)
	host._shadow_fraction = saved
	return clampi(out, 0, count)


# 边缘衰减深度：一 hex 占的屏幕像素越多（越近景）衰减越浅，玩家在看细节时
# 视口内圈与外圈的差距应该更小；总览时外圈（离视线中心远）可以让得更狠。

static func _vp_budget_edge_falloff(host, zoom_value: float, pixel_world_size: float) -> float:

	var pixels_per_hex = host._hex_size / maxf(pixel_world_size, 0.00001)
	if not is_finite(pixels_per_hex) or pixels_per_hex <= 0.0:
		return lerpf(host.VP_BUDGET_EDGE_FALLOFF_MAX, host.VP_BUDGET_EDGE_FALLOFF_MIN,
			clampf((zoom_value - 0.20) / 1.30, 0.0, 1.0))
	# log 尺度：6px/hex 以下算总览，48px/hex 以上算近景。
	var near_t = clampf(
		(log(maxf(pixels_per_hex, 0.001)) - log(6.0)) / (log(48.0) - log(6.0)), 0.0, 1.0)
	return lerpf(host.VP_BUDGET_EDGE_FALLOFF_MAX, host.VP_BUDGET_EDGE_FALLOFF_MIN, near_t)


# chunk 中心到视口中心的归一化距离 t：0 = 视口中心，1 = 视口对角半径处。
# 返回 < 0 表示该 chunk 与视口不相交（含东西环绕副本也不相交）→ 完全让出预算。

static func _vp_budget_chunk_distance_t(host, chunk_id: int, rect: Rect2, view_radius: float) -> float:

	if not host._chunk_intersects_rect(chunk_id, rect):
		return -1.0
	var bounds = host._chunk_world_bounds(chunk_id)
	if bounds.size == Vector2.ZERO:
		return -1.0
	var chunk_center = bounds.get_center()
	var view_center = rect.get_center()
	var dx = chunk_center.x - view_center.x
	var period = host._wrap_period_x()
	if period > 0.0001:
		dx = fposmod(dx + period * 0.5, period) - period * 0.5
	var dy = chunk_center.y - view_center.y
	return clampf(Vector2(dx, dy).length() / maxf(view_radius, 0.0001), 0.0, 1.0)


# 软阈值 θ 下「可让部分」还能保住多少实例（θ 越大保得越少，严格单调不增）。
# 注意：这里刻意不调用 clampf/maxf/clampi —— 它会被二分调用 VP_BUDGET_BISECT_STEPS×N
# 次，GDScript 里每一次函数调用都比几行内联算术贵一个量级。

static func _vp_budget_extra_at(host, 
		theta: float,
		w_max: float,
		extras: PackedInt32Array,
		weights: PackedFloat32Array) -> int:

	var total = 0
	var denom = w_max - theta
	if denom < 0.0001:
		denom = 0.0001
	for i in range(extras.size()):
		var extra = int(extras[i])
		if extra <= 0:
			continue
		var ramp = (weights[i] - theta) / denom
		if ramp <= 0.0:
			continue
		if ramp > 1.0:
			ramp = 1.0
		var take = int(ceil(float(extra) * ramp))
		if take > extra:
			take = extra
		total += take
	return total


# 二分出「刚好压进 budget_extra」的最小 θ（固定 VP_BUDGET_BISECT_STEPS 步 →
# 同输入同结果）。θ 上界取 w_max：到那一步所有 chunk 的 ramp 都归零。

static func _vp_budget_solve_theta(host, 
		w_max: float,
		extras: PackedInt32Array,
		weights: PackedFloat32Array,
		budget_extra: int) -> float:

	if extras.is_empty():
		return 0.0
	if _vp_budget_extra_at(host, 0.0, w_max, extras, weights) <= budget_extra:
		return 0.0
	var lo = 0.0
	var hi = w_max if w_max > 0.0001 else 0.0001
	for _step in range(host.VP_BUDGET_BISECT_STEPS):
		var mid = (lo + hi) * 0.5
		if _vp_budget_extra_at(host, mid, w_max, extras, weights) <= budget_extra:
			hi = mid
		else:
			lo = mid
	return hi


# 权重降序 + chunk_id 升序的稳定顺序（回填/兜底削减都按它，跨帧确定）。

static func _vp_budget_weight_order(host, ids: PackedInt32Array, weights: PackedFloat32Array) -> Array:

	var order: Array = []
	order.resize(ids.size())
	for i in range(ids.size()):
		order[i] = i
	if order.size() <= 1:
		return order
	order.sort_custom(func(a: int, b: int) -> bool:
		if absf(weights[a] - weights[b]) > 0.000001:
			return weights[a] > weights[b]
		return ids[a] < ids[b]
	)
	return order



static func _vp_budget_build_diag(host, 
		ids: PackedInt32Array,
		lods: PackedInt32Array,
		weights: PackedFloat32Array,
		ts: PackedFloat32Array,
		targets: PackedInt32Array,
		kept: int,
		budget: int,
		lod_total: int,
		fraction: float,
		zoom_value: float,
		pixel_world_size: float,
		falloff: float,
		boost: float,
		theta: float,
		rebalanced: bool,
		skipped_chunks: int) -> Dictionary:

	var near_min = 1.0
	var near_max = 0.0
	var near_sum = 0.0
	var near_n = 0
	var far_sum = 0.0
	var far_n = 0
	var weight_min = 1.0
	var weight_max = 0.0
	for i in range(ids.size()):
		weight_min = minf(weight_min, weights[i])
		weight_max = maxf(weight_max, weights[i])
		var lod = int(lods[i])
		if lod <= 0:
			continue
		var kept_ratio = float(targets[i]) / float(lod)
		if ts[i] <= host.VP_BUDGET_NEAR_T:
			near_min = minf(near_min, kept_ratio)
			near_max = maxf(near_max, kept_ratio)
			near_sum += kept_ratio
			near_n += 1
		else:
			far_sum += kept_ratio
			far_n += 1
	return {
		"kept": kept,
		"budget": budget,
		"chunks": ids.size(),
		"near_fraction_min": near_min if near_n > 0 else fraction,
		"near_fraction_max": near_max if near_n > 0 else fraction,
		"near_fraction_mean": (near_sum / float(near_n)) if near_n > 0 else fraction,
		"far_fraction_mean": (far_sum / float(far_n)) if far_n > 0 else fraction,
		"rebalanced": rebalanced,
		"skipped_chunks": skipped_chunks,
		"near_chunks": near_n,
		"far_chunks": far_n,
		"global_fraction": fraction,
		"lod_total": lod_total,
		"kept_ratio": (float(kept) / float(lod_total)) if lod_total > 0 else 0.0,
		"edge_falloff": falloff,
		"boost": boost,
		"theta": theta,
		"weight_min": weight_min,
		"weight_max": weight_max,
		"zoom": zoom_value,
		"pixel_world_size": pixel_world_size,
		"degraded": "",
		"ms": 0.0,
	}



static func _vp_budget_signature_matches(host, rect: Rect2, zoom_value: float, fraction: float) -> bool:

	if absf(fraction - host._vp_budget_cache_fraction) >= host.VP_BUDGET_FRACTION_EPSILON:
		return false
	var zoom_eps = maxf(host._vp_budget_cache_zoom * host.VP_BUDGET_ZOOM_EPSILON, 0.001)
	if absf(zoom_value - host._vp_budget_cache_zoom) > zoom_eps:
		return false
	var ref_extent = maxf(
		maxf(host._vp_budget_cache_rect.size.x, host._vp_budget_cache_rect.size.y),
		maxf(rect.size.x, rect.size.y))
	var eps = maxf(host.VP_BUDGET_RECT_EPSILON, ref_extent * 0.02)
	var delta = rect.get_center() - host._vp_budget_cache_rect.get_center()
	if absf(delta.x) > eps or absf(delta.y) > eps:
		return false
	if absf(rect.size.x - host._vp_budget_cache_rect.size.x) > eps \
			or absf(rect.size.y - host._vp_budget_cache_rect.size.y) > eps:
		return false
	return true



static func _store_viewport_budget_cache(host, 
		rect: Rect2,
		zoom_value: float,
		fraction: float,
		diag: Dictionary) -> void:

	host._vp_budget_cache_rect = rect
	host._vp_budget_cache_zoom = zoom_value
	host._vp_budget_cache_fraction = fraction
	host._vp_budget_cache_diag = diag
	host._vp_budget_cache_valid = true


# 写一个 chunk 的可见计数（植株 + 镜像 shadow chunk + 环绕副本）。只有
# visible_instance_count / host.visible，不碰 buffer，不重建 MultiMesh。

static func _apply_chunk_viewport_counts(host, 
		chunk_id: int,
		next_visible: int,
		in_view: bool,
		layer_enabled: bool,
		show_shadow: bool) -> void:

	var node: MultiMeshInstance2D = host._chunk_nodes.get(chunk_id, null)
	if node == null or not is_instance_valid(node) or node.multimesh == null:
		return
	var mm = node.multimesh
	var applied = clampi(next_visible, 0, mm.instance_count)
	mm.visible_instance_count = applied
	node.visible = in_view and not host._family_batch_suppressed \
		and layer_enabled and not host._camera_lod_hidden and applied > 0
	host._sync_chunk_wrap_nodes(chunk_id)
	var snode: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
	if snode == null or not is_instance_valid(snode) or snode.multimesh == null:
		return
	snode.multimesh.visible_instance_count = clampi(applied, 0, snode.multimesh.instance_count)
	snode.visible = show_shadow and node.visible and applied > 0
	host._sync_shadow_chunk_wrap_nodes(chunk_id)



