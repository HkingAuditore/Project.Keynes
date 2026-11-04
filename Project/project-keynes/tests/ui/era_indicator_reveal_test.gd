extends SceneTree

## 回归：大典结束（或被跳过）后，顶栏纸徽必须显示新时代图标。
## 场景：模型已推进到新时但 landed 路径没走到（索引不匹配 / skip / abort），
## 兜底调用 reveal_pending_era() 后图标要跟上模型，不能停在旧时代。
##
##   godot --headless --path . --script res://tests/ui/era_indicator_reveal_test.gd

const SCENE := "res://scenes/ui/era_indicator.tscn"

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load(SCENE) as PackedScene
	if scene == null:
		_expect("era indicator scene loads", false)
		_finish()
		return
	var badge = scene.instantiate()
	root.add_child(badge)
	await process_frame

	badge.set_model({"era_index": 0, "era_id": "stone", "era_name": "石器时代"})
	await process_frame
	_expect("starts on the stone icon", _icon_era(badge) == "stone")

	# 大典接管：旧图先留着（这是演出需要），换图由 reveal 完成。
	badge.defer_celebration = true
	badge.set_model({"era_index": 1, "era_id": "agrarian", "era_name": "农耕时代"})
	await process_frame
	_expect("keeps the old icon while the ceremony owns it", _icon_era(badge) == "stone")
	_expect("records a pending era", bool(badge.has_pending_era()))

	badge.reveal_pending_era(false)
	await process_frame
	_expect("reveals the new era icon", _icon_era(badge) == "agrarian")
	_expect("clears the pending era", not bool(badge.has_pending_era()))

	# 兜底：pending 已被消费 / 从未记录时，reveal 仍按模型对齐图标。
	badge.set_model({"era_index": 2, "era_id": "kingdom", "era_name": "王国时代"})
	await process_frame
	badge.reveal_pending_era(false)
	await process_frame
	_expect("reveal aligns the icon with the model even without a pending era",
		_icon_era(badge) == "kingdom")

	_finish()


func _icon_era(badge) -> String:
	var icon: TextureRect = badge.get_node("Badge/Icon")
	if icon == null or icon.texture == null:
		return ""
	return String(icon.texture.resource_path).get_file().trim_prefix("era_").trim_suffix(".png")


func _expect(label: String, ok: bool) -> void:
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)


func _finish() -> void:
	print("era indicator reveal: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
