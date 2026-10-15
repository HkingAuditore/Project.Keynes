extends PapercutAtlasBackdrop


func _ready() -> void:
	_loading = true
	super._ready()
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("survey_progress", 0.08)


func set_layout_state(state: Dictionary) -> void:
	if _stage != null:
		var knobs := state.duplicate(true)
		knobs.seed = state.get("initial_seed", state.get("seed", 29))
		_stage.set_layout_state(knobs)
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("seed_offset", float(int(state.get("initial_seed", state.get("seed", 29))) % 1000))


func set_loading_progress(fraction: float) -> void:
	var clamped := clampf(fraction, 0.0, 1.0)
	if _stage != null:
		_stage.reveal = 0.14 + clamped * 0.86
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("survey_progress", maxf(0.08, clamped))
		_sea_mat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)
