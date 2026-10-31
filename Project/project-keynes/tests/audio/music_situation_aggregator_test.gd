extends SceneTree

const AggregatorScript = preload("res://scripts/audio/music_situation_aggregator.gd")

var _failed := false


func _init() -> void:
	_check(is_equal_approx(AggregatorScript.social_pressure_score(4), 0.0),
		"social pressure level 4 is calm")
	_check(is_equal_approx(AggregatorScript.social_pressure_score(0), 1.0),
		"social pressure level 0 is maximum tension")
	_check(is_equal_approx(AggregatorScript.near_weight_for_camera_zoom(0.60), 0.0),
		"far camera disables local weight")
	_check(is_equal_approx(AggregatorScript.near_weight_for_camera_zoom(0.35), 1.0),
		"near camera enables local weight")
	var risks := PackedFloat32Array([0.0, 0.2, 0.4, 0.8, 1.0])
	var aggregate := AggregatorScript.aggregate_risk_values(risks)
	_check(aggregate > 0.65 and aggregate < 0.90,
		"local risk combines P90 and mean")
	_check(AggregatorScript.aggregate_risk_values(PackedFloat32Array()) == 0.0,
		"empty local sample is neutral")
	print("MUSIC_SITUATION_AGGREGATOR_TEST_OK=", not _failed)
	quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	print("[music-situation] ", "PASS " if ok else "FAIL ", message)
	_failed = _failed or not ok
