extends SceneTree

const Player = preload("res://scripts/game/player_game.gd")

func _initialize() -> void:
	var failures := 0
	for quality in ["auto", "low", "medium", "high"]:
		if Player.msaa_for_quality(quality, false) != Viewport.MSAA_DISABLED:
			failures += 1
		var expected := Viewport.MSAA_DISABLED if quality == "low" else Viewport.MSAA_2X
		if Player.msaa_for_quality(quality, true) != expected:
			failures += 1
	print("mobile MSAA policy: %d failures" % failures)
	quit(0 if failures == 0 else 1)
