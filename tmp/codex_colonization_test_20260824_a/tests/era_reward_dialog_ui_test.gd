extends SceneTree

var _failures := PackedStringArray()
var _choice_generation := 0
var _choice_index := -1

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var dialog := (load("res://scenes/ui/era_reward_dialog.tscn") as PackedScene).instantiate()
	root.add_child(dialog)
	await process_frame
	dialog.choice_requested.connect(func(generation: int, index: int) -> void:
		_choice_generation = generation
		_choice_index = index)
	dialog.present_offer({
		"offer_generation": 17,
		"era_title": "石器时代",
		"alternatives": [
			{"icon_id": "industry", "title": "石器时代·产业跃迁",
				"description": "集中扩张采掘与制造能力。", "target_summary": "玩家国家",
				"reasons": PackedStringArray(["拥有石材证据"])},
			{"icon_id": "route", "title": "石器时代·物流网络",
				"description": "扩大国内贸易与流通速度。", "target_summary": "玩家国家",
				"reasons": PackedStringArray()},
		],
	})
	await process_frame
	var cards := dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/CardsScroll/CardGrid")
	_expect("dialog opens with three stable cards", dialog.visible and cards.get_child_count() == 3)
	var first := cards.get_child(0) as EraRewardChoice
	var second := cards.get_child(1) as EraRewardChoice
	var third := cards.get_child(2) as EraRewardChoice
	_expect("first card binds Chinese title and semantic icon",
		String(first.get_node("Margin/Column/Top/Labels/Title").text).find("产业跃迁") >= 0
		and String(first.get_node("Margin/Column/Top/Labels/Category").text) == "产业方案"
		and first.get_node("Margin/Column/Top/Icon").icon_key == &"economy.building")
	_expect("second card keeps a generic-fit explanation",
		String(second.get_node("Margin/Column/Reason").text).find("通用时代方案") >= 0)
	_expect("missing third offer disables only the empty choice",
		(not (first.get_node("Margin/Column/Choose") as Button).disabled
		and not (second.get_node("Margin/Column/Choose") as Button).disabled
		and (third.get_node("Margin/Column/Choose") as Button).disabled)
	(first.get_node("Margin/Column/Choose") as Button).emit_signal("pressed")
	_expect("choice keeps the original generation and index", _choice_generation == 17
		and _choice_index == 0)
	dialog.show_pending()
	_expect("pending state disables all choices",
		(first.get_node("Margin/Column/Choose") as Button).disabled
		and (second.get_node("Margin/Column/Choose") as Button).disabled)
	dialog.show_error("效果未完成")
	_expect("error state keeps a readable status line",
		String(dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/Status").text).find("效果未完成") >= 0)
	dialog.queue_free()
	print("era reward dialog ui: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("  [FAIL] %s" % label)
