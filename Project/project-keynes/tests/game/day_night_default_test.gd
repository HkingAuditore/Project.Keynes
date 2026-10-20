extends SceneTree


func _init() -> void:
	var failures := PackedStringArray()
	var player_game := PlayerGame.new()
	if not player_game.day_night_enabled:
		failures.append("PlayerGame 新会话必须默认开启昼夜循环")

	var runtime_host := WorldRuntimeHost.new()
	if not runtime_host.is_day_night_enabled():
		failures.append("WorldRuntimeHost 必须默认开启昼夜循环")

	var renderer := HexRenderer.new()
	if not renderer.day_night_enabled:
		failures.append("HexRenderer 必须默认开启昼夜循环")

	player_game.free()
	runtime_host.free()
	renderer.free()

	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("[day-night-default] PASS")
	quit(0 if failures.is_empty() else 1)
