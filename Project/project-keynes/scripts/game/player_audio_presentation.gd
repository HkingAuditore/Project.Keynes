extends RefCounted

## Updates the soundtrack inputs and camera zoom audio.


static func _apply_camera_view_scale_compensation(owner: PlayerController) -> void:
	if owner._camera == null or not owner._camera.has_method("set_view_scale_compensation"):
		return
	if not (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")):
		return
	var settings := owner.get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return
	var scaling = settings.call("ui_scaling")
	if scaling == null or not scaling.has_method("total_scale"):
		return
	var total_scale := float(scaling.call("total_scale"))
	if total_scale <= 0.01:
		return
	owner._camera.set_view_scale_compensation(total_scale)



static func _on_clock_control_changed(owner: PlayerController, _paused: bool, _speed: float) -> void:
	owner.ClockPresentation._sync_clock_visual_state(owner)
	owner.ClockPresentation._sync_time_ui(owner)



static func music_situation_diagnostics(owner: PlayerController) -> Dictionary:
	return owner._music_situation.diagnostics() if owner._music_situation != null else {}



static func selected_cell(owner: PlayerController):
	return owner._selected_cell


## The many-cell overlay that answers "where does this card act?". Injected
## separately from `configure` so every existing caller keeps working, and so a
## headless session (which builds no WorldRoot children) can simply not set it.
static func _configure_music_situation(owner: PlayerController) -> void:
	owner._narrative_component._configure_music_situation(owner)



static func _sync_era_music(owner: PlayerController, force_population_sync: bool = false) -> void:
	owner._narrative_component._sync_era_music(owner, force_population_sync)



static func _sync_camera_zoom_audio(owner: PlayerController, reset_baseline: bool = false) -> void:
	owner._narrative_component._sync_camera_zoom_audio(owner, reset_baseline)



static func _on_camera_zoom_changed(owner: PlayerController, zoom_val: float) -> void:
	var audio := owner.get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("set_active_suite_camera_zoom"):
		return
	if not owner._camera_zoom_user_engaged:
		if owner._camera_zoom_baseline < 0.0:
			owner._camera_zoom_baseline = zoom_val
		if absf(zoom_val - owner._camera_zoom_baseline) <= 0.02:
			return
		owner._camera_zoom_user_engaged = true
	var min_z := 0.55
	var max_z := 3.6
	if owner._camera != null:
		if owner._camera.has_method("_minimum_zoom"):
			min_z = clampf(float(owner._camera._minimum_zoom()), 0.25, 1.2)
		elif "zoom_min" in owner._camera:
			min_z = maxf(0.35, float(owner._camera.zoom_min))
		if "zoom_max" in owner._camera:
			max_z = maxf(min_z + 0.6, minf(float(owner._camera.zoom_max), 4.0))
	audio.set_active_suite_camera_zoom(
		PlayerController.camera_zoom_to_audio_ratio(zoom_val, min_z, max_z), false)
	if owner._music_situation != null and owner._camera != null and owner._camera.has_method("current_world_view_rect"):
		owner._music_situation.refresh_local_from_view(
			owner._camera.current_world_view_rect(),
			PlayerController.camera_zoom_to_audio_ratio(zoom_val, min_z, max_z))



static func _on_camera_view_changed(owner: PlayerController, world_rect: Rect2, _center: Vector2, zoom_value: float) -> void:
	if owner._music_situation == null:
		return
	var min_z := 0.55
	var max_z := 3.6
	if owner._camera != null:
		if owner._camera.has_method("_minimum_zoom"):
			min_z = clampf(float(owner._camera._minimum_zoom()), 0.25, 1.2)
		if "zoom_max" in owner._camera:
			max_z = maxf(min_z + 0.6, minf(float(owner._camera.zoom_max), 4.0))
	owner._music_situation.refresh_local_from_view(
		world_rect, PlayerController.camera_zoom_to_audio_ratio(zoom_value, min_z, max_z))



static func music_camera_zoom_ratio(owner: PlayerController) -> float:
	return owner._narrative_component.music_camera_zoom_ratio(owner)



static func camera_zoom_to_audio_ratio(zoom_val: float,
		min_zoom: float = 0.55, max_zoom: float = 3.6) -> float:
	var lo := maxf(0.1, min_zoom)
	var hi := maxf(lo + 0.2, max_zoom)
	var clamped := clampf(zoom_val, lo, hi)
	var t := inverse_lerp(log(lo), log(hi), log(clamped))
	return clampf(1.0 - t, 0.0, 1.0)


## 理念音效：抽（offer/choose/reroll）与用（equip/unequip/promote）分开。
## 只在成功时发声，被拒绝的命令不响。
## 日常游戏事件音效：经济 trace 流自带消费游标，不遍历全图。
##   贸易 / 人口 → 经济 trace 流；建筑由可见地图活动层播放。
##   科技/理念 → GameUIManager 的完成通知与命令回执，避免日切重复播放。
##   开拓      → diff territory_cells.size()
static func _sync_event_audio(owner: PlayerController) -> void:
	owner._narrative_component._sync_event_audio(owner)
