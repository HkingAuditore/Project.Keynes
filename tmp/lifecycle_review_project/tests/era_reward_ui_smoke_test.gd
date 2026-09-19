extends SceneTree

var _failures := 0

func _init() -> void:
	var packed := load("res://scenes/ui/era_reward_dialog.tscn") as PackedScene
	var dialog := packed.instantiate() as EraRewardDialog if packed != null else null
	_expect("era reward scene loads", dialog != null)
	if dialog != null:
		root.add_child(dialog)
		await process_frame
		dialog.present_offer({
			"offer_generation": 7,
			"era_title": "测试时代",
			"alternatives": [
				_option("奖励甲", "适配甲"),
				_option("奖励乙", "适配乙"),
				_option("奖励丙", "适配丙"),
			],
		})
		_expect("offer opens as an input-blocking modal",
			dialog.visible and dialog.mouse_filter == Control.MOUSE_FILTER_STOP)
		var grid := dialog.get_node("Margin/Column/CardsScroll/CardGrid") as GridContainer
		_expect("offer has exactly three static cards", grid != null and grid.get_child_count() == 3)
		var enabled := 0
		for index in range(3):
			var button := grid.get_node("Card%d/Margin/Column/Choose" % index) as Button
			if button != null and not button.disabled:
				enabled += 1
		_expect("all three alternatives are selectable", enabled == 3)
		dialog.show_pending()
		var disabled := 0
		for index in range(3):
			var button := grid.get_node("Card%d/Margin/Column/Choose" % index) as Button
			if button != null and button.disabled:
				disabled += 1
		_expect("pending state disables every choice", disabled == 3)
		dialog.close_offer()
		_expect("resolved offer closes", not dialog.visible)
		dialog.queue_free()
	print("era_reward_ui_smoke_test: %s" % (
		"PASS" if _failures == 0 else "%d failures" % _failures))
	quit(0 if _failures == 0 else 1)

func _option(title: String, reason: String) -> Dictionary:
	return {
		"title": title,
		"description": "冻结的效果说明",
		"icon_id": "reward",
		"target_summary": "玩家国家",
		"reasons": PackedStringArray([reason]),
	}

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
