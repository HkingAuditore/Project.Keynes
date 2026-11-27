extends RefCounted

## Builds visible fronts and blends their published positions and strength.

static func reset_snapshot_pacing(layer: WeatherLayer) -> void:
	layer._last_front_snapshot_time = -1.0
	layer._front_snapshot_interval_sec = WeatherLayer._WEATHER_FRONT_INITIAL_BLEND_SEC
	# 不清 _front_blend_duration / _front_blend_elapsed，让当前正在进行的 lerp
	# 自然走完，新节奏从下一次 set_weather_fronts 起生效。

# fronts: Array[WeatherFront]（也接受 untyped Array，避免 caller 强转）


static func set_weather_fronts(layer: WeatherLayer, fronts: Array) -> void:
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	var start_candidates := layer._front_visual_snapshots.duplicate(true)
	var targets := layer._make_front_snapshots(fronts)
	var aligned := layer._align_front_blend_snapshots(start_candidates, targets)
	layer._front_start_snapshots = aligned[0]
	layer._front_target_snapshots = aligned[1]
	layer._front_blend_elapsed = 0.0
	if layer._last_front_snapshot_time < 0.0:
		layer._front_snapshot_interval_sec = WeatherLayer._WEATHER_FRONT_INITIAL_BLEND_SEC
		layer._front_blend_duration = WeatherLayer._WEATHER_FRONT_INITIAL_BLEND_SEC
	else:
		var raw_interval: float = maxf(now_sec - layer._last_front_snapshot_time, 0.001)
		# 抽动修复（2026-05-18）：snapshot_interval 也走 IIR，吸收单次 commit
		# 切片造成的抖动（例如某 tick 被 climate 抢占多花 1s）。
		layer._front_snapshot_interval_sec = lerpf(
			layer._front_snapshot_interval_sec, raw_interval, WeatherLayer._WEATHER_FRONT_BLEND_IIR_ALPHA
		)
		var target_duration: float = clampf(
			layer._front_snapshot_interval_sec * WeatherLayer._WEATHER_FRONT_BLEND_LAG_FACTOR,
			WeatherLayer._WEATHER_FRONT_MIN_BLEND_SEC,
			WeatherLayer._WEATHER_FRONT_MAX_BLEND_SEC
		)
		# IIR 平滑 blend_duration：新值 = 0.35 × target + 0.65 × prev。
		# 防止 interval 抖动直接打到时长上造成"这段飘很快、下段飘很慢"。
		if layer._front_blend_duration > 0.0001:
			layer._front_blend_duration = lerpf(
				layer._front_blend_duration, target_duration, WeatherLayer._WEATHER_FRONT_BLEND_IIR_ALPHA
			)
		else:
			layer._front_blend_duration = target_duration
		if targets.size() < start_candidates.size():
			layer._front_blend_duration = maxf(layer._front_blend_duration, WeatherLayer._WEATHER_FRONT_DESPAWN_FADE_SEC)
	layer._last_front_snapshot_time = now_sec

	# Drift-fix（2026-05-10）：对 lerp target 做 forward-bias，让"云会飘"在
	# 1× 速度也能可见。
	#
	# 背景：blend_duration ≈ 1.15 × snapshot_interval，意味着 lerp 完成时刻
	# 比下次 snapshot 到达晚 15%——所以 raw_t >= 1.0 后的外推路径在正常游戏里
	# 永远不到，老的 _predict_front_snapshots 是死代码。视觉位移完全靠
	# "lerp(start, raw_target)" 提供，而 raw_target = 新 tick 的聚类质心，
	# 在身份继承稳住了之后这个质心几乎不动 → 云就静止了。
	#
	# 修法：把 target.center 沿 front.velocity 向前推 forward_bias 个 snapshot。
	# 这样 lerp 终点 = "下次 snapshot 到达时云应该在的位置"，每 frame 内
	# lerp 都在持续向前推进。前后两 tick 的 forward-biased target 又能首尾相接，
	# 所以不会出现"先飘到未来、新 snapshot 一来又被拉回当前"的回弹。
	#
	# forward_bias 的单位是 snapshot interval（与 front.velocity 单位匹配）。
	# 1.15 = blend_duration / snapshot_interval：lerp 把视觉推到下次 snapshot
	# 到达时的预期位置。clamp [0, 1.5] 防止 blend_duration 被 MIN 抬高时过冲。
	var forward_bias: float = clampf(
		layer._front_blend_duration / maxf(layer._front_snapshot_interval_sec, 0.001),
		0.0, 1.5
	)
	if WeatherLayer.DRIFT_DEBUG_LOG:
		print("[weather-layer] set_weather_fronts: n=%d snap_interval=%.3fs blend_dur=%.3fs forward_bias=%.3f starts=%d" % [
			layer._front_target_snapshots.size(), layer._front_snapshot_interval_sec,
			layer._front_blend_duration, forward_bias, layer._front_start_snapshots.size(),
		])
	if forward_bias > 0.0:
		for i in range(layer._front_target_snapshots.size()):
			var t: Dictionary = layer._front_target_snapshots[i]
			var v: Vector2 = layer._front_velocity(t)
			var raw_center: Vector2 = layer._front_center(t)
			if v.length_squared() > 0.0001:
				t["center"] = raw_center + v * forward_bias
				layer._front_target_snapshots[i] = t
			if WeatherLayer.DRIFT_DEBUG_LOG and i < 3:
				var start_center: Vector2 = Vector2.INF
				if i < layer._front_start_snapshots.size():
					start_center = layer._front_center(layer._front_start_snapshots[i])
				var target_center: Vector2 = layer._front_center(t)
				var delta: Vector2 = target_center - start_center if start_center != Vector2.INF else Vector2.ZERO
				print("[weather-layer]   front%d type=%d raw=%s vel=%s |vel|=%.1f bias=%s start=%s target=%s |Δ|=%.1f" % [
					i, layer._front_type(t),
					str(raw_center.round()), str(v.round()), v.length(),
					str((v * forward_bias).round()),
					str(start_center.round()) if start_center != Vector2.INF else "<none>",
					str(target_center.round()), delta.length(),
				])

	# 目标为空时保留当前视觉快照做淡出；如果也没有视觉快照则立即清空。
	layer._update_weather_front_blend(0.0)

# ─── overlay shader uniform 上传 ─────────────────────────────────────────


static func _push_fronts_to_overlay(layer: WeatherLayer, _fronts: Array) -> void:
	# 云分布已改用 weather_lut（per-cell LUT，见 weather_overlay.sample_field_weather）：
	# fronts 不再驱动 overlay 云 uniform，此函数保留为空避免改动多个调用点。
	# 注：fronts 仍经 _sync_particles_pool 驱动 GPUParticles 雨雪粒子（粒子需椭圆发射盒）。
	pass


static func _push_empty_fronts_to_overlay(layer: WeatherLayer) -> void:
	layer._push_fronts_to_overlay([])

# v-data-driven：把 WeatherProfileRegistry 里 8 个 profile 的 overlay 颜色
# 推入 shader 的 uniform 数组。每局游戏只需调用一次（在 setup() 里）。


static func _push_weather_profile_uniforms_to_overlay(layer: WeatherLayer) -> void:
	if layer._overlay_mat == null:
		return
	var colors := PackedColorArray()
	colors.resize(WeatherLayer._MAX_WEATHER_TYPES)
	for wt in range(WeatherLayer._MAX_WEATHER_TYPES):
		var p := WeatherProfileRegistry.get_profile(wt)
		if p == null:
			colors[wt] = Color(0.0, 0.0, 0.0, 0.0)
			continue
		# rgb = overlay_color, a = overlay_base_alpha（shader 端直接当作 vec4 读）
		colors[wt] = Color(
			p.overlay_color.r, p.overlay_color.g, p.overlay_color.b,
			p.overlay_base_alpha
		)
	layer._overlay_mat.set_shader_parameter("weather_profile_colors", colors)

# ─── 池子同步（B5 / B6 实装） ────────────────────────────────────────────


static func _sync_particles_pool(layer: WeatherLayer, fronts: Array) -> void:
	WeatherLayer.WeatherLayerParticlesScript.sync_particles_pool(layer, fronts)


static func _disable_particle_slot(layer: WeatherLayer, node: GPUParticles2D, slot_idx: int) -> void:
	if node.emitting:
		node.emitting = false
	if node.visible:
		node.visible = false
	node.process_mode = Node.PROCESS_MODE_DISABLED
	layer._particles_type_cache[slot_idx] = WeatherLayer._WT_CLEAR
	# Phase A 止血：slot 重新激活时强制下发 amount/visibility_rect。
	layer._particles_amount_cache[slot_idx] = -1
	layer._particles_vis_radius_cache[slot_idx] = -1.0

# ─── WeatherFront 表现层插值 ─────────────────────────────────────────────


static func _reset_front_blend_state(layer: WeatherLayer) -> void:
	layer._front_start_snapshots.clear()
	layer._front_target_snapshots.clear()
	layer._front_visual_snapshots.clear()
	layer._front_blend_elapsed = 0.0
	layer._front_blend_duration = 0.0
	layer._last_front_snapshot_time = -1.0
	layer._front_snapshot_interval_sec = WeatherLayer._WEATHER_FRONT_INITIAL_BLEND_SEC
	layer._active_count = 0
	# ambient-shadow：reset 也走统一可见性判定，启用时仍保持 visible 让影子继续画。
	layer._refresh_visibility()
	layer._push_empty_fronts_to_overlay()
	layer._sync_particles_pool([])
	layer.visual_fronts_changed.emit([])


static func _make_front_snapshots(layer: WeatherLayer, fronts: Array) -> Array:
	var snapshots: Array = []
	var n: int = mini(fronts.size(), WeatherLayer.MAX_WEATHER_FRONTS)
	for i in range(n):
		var f = fronts[i]
		snapshots.append({
			"center": layer._front_center(f),
			"radius": layer._front_radius(f),
			"velocity": layer._front_velocity(f),
			"type": layer._front_type(f),
			"intensity": layer._front_intensity(f),
			"axis": layer._front_axis(f),
			"major_scale": layer._front_major_scale(f),
			"minor_scale": layer._front_minor_scale(f),
			"cloud_amount": layer._front_cloud_amount(f),
			"precip_amount": layer._front_precip_amount(f),
			"dissolve_amount": layer._front_dissolve_amount(f),
			"life_progress": layer._front_life_progress(f),
		})
	return snapshots


static func _align_front_blend_snapshots(layer: WeatherLayer, start_candidates: Array, targets: Array) -> Array:
	var starts: Array = []
	var aligned_targets: Array = []
	var used: Array[bool] = []
	used.resize(start_candidates.size())
	for i in range(used.size()):
		used[i] = false

	for target in targets:
		var best_idx: int = -1
		var best_dist_sq: float = INF
		var best_candidate_radius: float = 0.0
		var target_center: Vector2 = layer._front_center(target)
		var target_radius: float = maxf(layer._front_radius(target), 1.0)
		for i in range(start_candidates.size()):
			if used[i]:
				continue
			var candidate = start_candidates[i]
			if layer._front_type(candidate) != layer._front_type(target):
				continue
			var dist_sq: float = layer._front_center(candidate).distance_squared_to(target_center)
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best_idx = i
				best_candidate_radius = maxf(layer._front_radius(candidate), 1.0)
		var start
		# Continuity-fix（B）：匹配阈值从 1.5 × target_radius 放宽到
		# 2.5 × max(target_radius, candidate_radius)。
		# 旧阈值在 cluster split / merge / wind advect 一天位移 (≈0.4 × radius) +
		# 边界 cell 抖动（再 ±0.5 × radius）叠加后会顶不住——明明是同一朵云，
		# 因为重新聚类的中心移动 1.6 × radius 就被判定为"不同 front"。
		# 取 max 半径意味着大簇能拉近小簇做匹配，避免"split 出的小半"被误判为新生。
		#
		# 抽动修复（2026-05-18）：阈值再放宽到 4.0 × max_radius。
		# 实测在 forward-bias = 1.0~1.5 interval 下，target.center 已经被沿 velocity
		# 预推了"接近一整个半径"的距离，叠加 cluster 重聚类抖动可达 2-3 倍半径，
		# 2.5 还是不够；放到 4.0 能在大半径 front（如 MONSOON）下吸收几乎所有
		# 误判，代价仅是偶发把"刚好擦肩而过的两朵不同云"识别为同一朵——可接受。
		var match_radius: float = maxf(target_radius, best_candidate_radius) * 4.0
		if best_idx >= 0 and best_dist_sq <= match_radius * match_radius:
			used[best_idx] = true
			start = start_candidates[best_idx]
		else:
			start = target.duplicate(true)
			layer._fade_out_snapshot(start)
		starts.append(start)
		aligned_targets.append(target)

	for i in range(start_candidates.size()):
		if used[i]:
			continue
		var fading_start = start_candidates[i]
		var fading_target = fading_start.duplicate(true)
		layer._fade_out_snapshot(fading_target)
		starts.append(fading_start)
		aligned_targets.append(fading_target)

	return [starts, aligned_targets]


static func _fade_out_snapshot(layer: WeatherLayer, snapshot: Dictionary) -> void:
	snapshot["intensity"] = 0.0
	snapshot["cloud_amount"] = 0.0
	snapshot["precip_amount"] = 0.0
	snapshot["dissolve_amount"] = 1.0
	snapshot["life_progress"] = 1.0


static func _update_weather_front_blend(layer: WeatherLayer, delta: float) -> void:
	layer._front_blend_elapsed += maxf(delta, 0.0)
	var duration: float = maxf(layer._front_blend_duration, 0.0001)
	var raw_t: float = clampf(layer._front_blend_elapsed / duration, 0.0, 1.0)
	# 抽动修复（2026-05-18）：从 smoothstep 改为线性 t。
	# smoothstep 的 ease-in 会让每段 lerp 的前 ~25% 时长几乎不动，叠加每次 commit
	# 重置 _front_blend_elapsed=0 → 视觉上每隔一次 commit 就"顿一下、再起步"。
	# 线性 t 让云的视觉速度在两次 commit 之间恒定，配合 forward-bias 让首尾相接
	# 处的速度也连续——彻底消除"一抽一抽"的观感。
	var t: float = raw_t
	layer._front_visual_snapshots = layer._blend_front_snapshots(t)
	if raw_t >= 1.0:
		layer._front_target_snapshots = layer._filter_visible_front_snapshots(layer._front_target_snapshots)
		layer._front_start_snapshots = layer._front_target_snapshots.duplicate(true)
		layer._front_visual_snapshots = layer._front_target_snapshots.duplicate(true)
		if layer._front_target_snapshots.is_empty():
			layer._front_start_snapshots.clear()
			layer._front_visual_snapshots.clear()
			layer._front_blend_elapsed = 0.0
			layer._front_blend_duration = 0.0
		else:
			var extra_days: float = clampf(
				(layer._front_blend_elapsed - layer._front_blend_duration) / maxf(layer._front_snapshot_interval_sec, 0.001),
				0.0,
				WeatherLayer._WEATHER_FRONT_MAX_PREDICT_DAYS
			)
			if extra_days > 0.0:
				layer._front_visual_snapshots = layer._predict_front_snapshots(layer._front_visual_snapshots, extra_days)
	layer._active_count = mini(layer._front_visual_snapshots.size(), WeatherLayer.MAX_WEATHER_FRONTS)
	layer._refresh_visibility()
	layer._push_fronts_to_overlay(layer._front_visual_snapshots)
	layer._sync_particles_pool(layer._front_visual_snapshots)
	layer.visual_fronts_changed.emit(layer._front_visual_snapshots)


static func _filter_visible_front_snapshots(layer: WeatherLayer, snapshots: Array) -> Array:
	var filtered: Array = []
	for snapshot in snapshots:
		if layer._front_intensity(snapshot) > 0.001:
			filtered.append(snapshot)
	return filtered


static func _blend_front_snapshots(layer: WeatherLayer, t: float) -> Array:
	var visual: Array = []
	var n: int = mini(
		maxi(layer._front_start_snapshots.size(), layer._front_target_snapshots.size()),
		WeatherLayer.MAX_WEATHER_FRONTS
	)
	for i in range(n):
		var has_start: bool = i < layer._front_start_snapshots.size()
		var has_target: bool = i < layer._front_target_snapshots.size()
		if not has_start and not has_target:
			continue
		var start = layer._front_start_snapshots[i] if has_start else null
		var target = layer._front_target_snapshots[i] if has_target else null
		if start == null and target != null:
			start = target.duplicate(true)
			start["intensity"] = 0.0
		elif target == null and start != null:
			target = start.duplicate(true)
			target["intensity"] = 0.0
		var center: Vector2 = layer._front_center(start).lerp(layer._front_center(target), t)
		var radius: float = lerpf(layer._front_radius(start), layer._front_radius(target), t)
		var velocity: Vector2 = layer._front_velocity(start).lerp(layer._front_velocity(target), t)
		var intensity: float = lerpf(layer._front_intensity(start), layer._front_intensity(target), t)
		var axis := layer._blend_axis(layer._front_axis(start), layer._front_axis(target), t)
		var major_scale: float = lerpf(layer._front_major_scale(start), layer._front_major_scale(target), t)
		var minor_scale: float = lerpf(layer._front_minor_scale(start), layer._front_minor_scale(target), t)
		var cloud_amount: float = lerpf(layer._front_cloud_amount(start), layer._front_cloud_amount(target), t)
		var precip_amount: float = lerpf(layer._front_precip_amount(start), layer._front_precip_amount(target), t)
		var dissolve_amount: float = lerpf(layer._front_dissolve_amount(start), layer._front_dissolve_amount(target), t)
		var life_progress: float = lerpf(layer._front_life_progress(start), layer._front_life_progress(target), t)
		if intensity <= 0.001 and t >= 1.0:
			continue
		visual.append({
			"center": center,
			"radius": radius,
			"velocity": velocity,
			"type": layer._front_type(target),
			"intensity": clampf(intensity, 0.0, 1.0),
			"axis": axis,
			"major_scale": major_scale,
			"minor_scale": minor_scale,
			"cloud_amount": clampf(cloud_amount, 0.0, 1.0),
			"precip_amount": clampf(precip_amount, 0.0, 1.0),
			"dissolve_amount": clampf(dissolve_amount, 0.0, 1.0),
			"life_progress": clampf(life_progress, 0.0, 1.0),
		})
	return visual


static func _predict_front_snapshots(layer: WeatherLayer, snapshots: Array, prediction_days: float) -> Array:
	var predicted: Array = []
	for snapshot in snapshots:
		var p = snapshot.duplicate(true)
		p["center"] = layer._front_center(p) + layer._front_velocity(p) * prediction_days
		predicted.append(p)
	return predicted


static func _front_center(layer: WeatherLayer, front) -> Vector2:
	if front is Dictionary:
		return front.get("center", Vector2.ZERO)
	return front.center


static func _front_radius(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return float(front.get("radius", 0.0))
	return float(front.radius)


static func _front_velocity(layer: WeatherLayer, front) -> Vector2:
	if front is Dictionary:
		return front.get("velocity", Vector2.ZERO)
	return front.velocity


static func _front_type(layer: WeatherLayer, front) -> int:
	if front is Dictionary:
		return int(front.get("type", WeatherLayer._WT_CLEAR))
	return int(front.type)


static func _front_intensity(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("intensity", 0.0)), 0.0, 1.0)
	return clampf(float(front.intensity), 0.0, 1.0)


static func _front_axis(layer: WeatherLayer, front) -> Vector2:
	var ax: Vector2 = Vector2.RIGHT
	if front is Dictionary:
		ax = front.get("axis", Vector2.RIGHT)
	elif front.has_method("normalized_axis"):
		ax = front.normalized_axis()
	if ax.length_squared() <= 0.0001:
		return Vector2.RIGHT
	return ax.normalized()


static func _front_major_scale(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return maxf(float(front.get("major_scale", 1.0)), 0.05)
	return maxf(float(front.major_scale), 0.05)


static func _front_minor_scale(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return maxf(float(front.get("minor_scale", 1.0)), 0.05)
	return maxf(float(front.minor_scale), 0.05)


static func _front_cloud_amount(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("cloud_amount", layer._front_visual_intensity(layer._front_intensity(front)))), 0.0, 1.0)
	return clampf(float(front.cloud_amount), 0.0, 1.0)


static func _front_precip_amount(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("precip_amount", layer._front_visual_intensity(layer._front_intensity(front)))), 0.0, 1.0)
	return clampf(float(front.precip_amount), 0.0, 1.0)


static func _front_dissolve_amount(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("dissolve_amount", 0.0)), 0.0, 1.0)
	return clampf(float(front.dissolve_amount), 0.0, 1.0)


static func _front_life_progress(layer: WeatherLayer, front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("life_progress", 0.0)), 0.0, 1.0)
	return clampf(float(front.life_progress), 0.0, 1.0)


static func _blend_axis(layer: WeatherLayer, a: Vector2, b: Vector2, t: float) -> Vector2:
	var aa := a.normalized() if a.length_squared() > 0.0001 else Vector2.RIGHT
	var bb := b.normalized() if b.length_squared() > 0.0001 else aa
	if aa.dot(bb) < 0.0:
		bb = -bb
	var out := aa.lerp(bb, t)
	if out.length_squared() <= 0.0001:
		return aa
	return out.normalized()


static func _front_visual_intensity(layer: WeatherLayer, raw_intensity: float) -> float:
	var i: float = clampf(raw_intensity, 0.0, 1.0)
	if i <= 0.0:
		return 0.0
	# 逻辑强度用于数值系统；视觉强度用幂曲线抬高中低段，同时在 0 附近
	# 保持淡出，避免刚清空的 front 留下残影。
	return clampf(pow(i, 0.55) * smoothstep(0.0, 0.08, i), 0.0, 1.0)


static func _particle_tod_tint_component(layer: WeatherLayer, sun_component: float, ambient_component: float) -> float:
	var night_t: float = clampf(layer._tod_night_factor, 0.0, 1.0)
	var sun_visible: float = lerpf(clampf(sun_component, 0.0, 1.25), 1.0, 0.45)
	var ambient_visible: float = lerpf(clampf(ambient_component, 0.0, 1.25), 1.0, 0.35)
	var tint: float = lerpf(sun_visible, ambient_visible, night_t * 0.35)
	var floor_value: float = lerpf(0.82, 0.58, night_t)
	return clampf(maxf(tint, floor_value), 0.0, 1.15)

# ─── 内部 ─────────────────────────────────────────────────────────────────
