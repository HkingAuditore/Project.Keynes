extends SceneTree

## Family founding 1-of-3 dialog plus the PlayerController modal lock:
## cards render, choices carry offer identity, the clock pauses while a
## player offer is OPEN and resumes at the previous speed once it settles.

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

class ClockStub:
	var paused := false
	var speed_multiplier := 4.0

	func pause(value: bool) -> void:
		paused = value

	func set_speed(value: float) -> void:
		speed_multiplier = value

	func day_index() -> int:
		return 12

	func year_index() -> int:
		return 0

	func calendar_date() -> Dictionary:
		return {"month": 1, "day_of_month": 13}


class UiStub:
	var shown: Dictionary = {}
	var open := false
	var closed_count := 0

	func update_time_state(_year: int, _month: int, _day: int, _paused: bool,
			_speed: float) -> void:
		pass

	func show_family_founding_offer(offer: Dictionary) -> void:
		shown = offer
		open = true

	func close_family_founding_offer() -> void:
		open = false
		closed_count += 1

	func is_family_founding_modal_open() -> bool:
		return open

	func show_family_founding_error(_message: String) -> void:
		pass


class FacadeStub:
	var offers: Array = []

	func family_founding_offers(_offset: int = 0, _limit: int = 16) -> Dictionary:
		return {"ok": true, "total": offers.size(), "offers": offers}


var _failures := PackedStringArray()
var _choice := [-1, -1, -1]


func _initialize() -> void:
	call_deferred("_run")


func _card(name: String, building: String, effect: String) -> Dictionary:
	return {
		"stable_id": name.hash(),
		"family_name": name,
		"building_display_name": building,
		"owner_profession_display_name": "采集者",
		"founders": 42,
		"trait_display_names": PackedStringArray(["节俭", "采集"]),
		"trait_descriptions": PackedStringArray(["日常消费减少 10%", ""]),
		"effect_display_name": effect,
		"effect_description": "本城产出小幅提高。",
	}


func _run() -> void:
	var dialog := (load("res://scenes/ui/family/family_founding_dialog.tscn")
		as PackedScene).instantiate() as FamilyFoundingDialog
	root.add_child(dialog)
	await process_frame
	dialog.choice_requested.connect(func(offer_id: int, generation: int, index: int) -> void:
		_choice = [offer_id, generation, index])
	dialog.present_offer({
		"offer_id": 9,
		"generation": 3,
		"settlement_name": "长安",
		"milestone_population": 200,
		"queue_remaining": 1,
		"candidates": [
			_card("长安张氏", "采集营地", "专精产业"),
			_card("长安李氏", "狩猎营地", "远亲"),
		],
	})
	await process_frame
	var cards := dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/CardsScroll/CardGrid")
	_expect("dialog opens with three card slots", dialog.visible
		and dialog.is_offer_open() and cards.get_child_count() == 3)
	var first := cards.get_child(0) as FamilyFoundingCard
	var third := cards.get_child(2) as FamilyFoundingCard
	_expect("card shows family name, industry, founders, traits and effect",
		String(first.get_node("Margin/Column/Top/Labels/Title").text) == "长安张氏"
		and String(first.get_node("Margin/Column/Industry").text).find("采集营地") >= 0
		and String(first.get_node("Margin/Column/Industry").text).find("42") >= 0
		and String(first.get_node("Margin/Column/Traits").text).find("节俭：日常消费减少 10%") >= 0
		and String(first.get_node("Margin/Column/Effect").text).find("专精产业") >= 0)
	_expect("prompt names the settlement, milestone and remaining queue",
		String(dialog.get_node(
			"ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text").text).find("长安人口已达 200") >= 0
		and String(dialog.get_node(
			"ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text").text).find("另有 1 处") >= 0)
	_expect("missing third candidate disables only its button",
		not first.choose_button().disabled and third.choose_button().disabled)
	_expect("first available choice takes keyboard focus",
		first.choose_button().has_focus())
	(cards.get_child(1) as FamilyFoundingCard).choose_button().emit_signal("pressed")
	_expect("choice carries offer id, generation and index", _choice == [9, 3, 1])
	_expect("pending state disables every choice",
		first.choose_button().disabled
		and (cards.get_child(1) as FamilyFoundingCard).choose_button().disabled)
	dialog.show_error("候选已过期")
	_expect("error re-enables valid choices and keeps a readable status",
		not first.choose_button().disabled and third.choose_button().disabled
		and String(dialog.get_node(
			"ArchiveSurface/Frame/Margin/Column/Body/Status").text).find("候选已过期") >= 0)
	dialog.close_offer()
	_expect("close hides the dialog", not dialog.is_offer_open())
	dialog.queue_free()
	_test_controller_lock()
	print("family founding dialog ui: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _test_controller_lock() -> void:
	var controller = PlayerControllerScript.new()
	var clock := ClockStub.new()
	var ui := UiStub.new()
	var facade := FacadeStub.new()
	controller._world_clock = clock
	controller._ui_manager = ui
	controller._economy_facade = facade
	facade.offers = [
		{"offer_id": 4, "generation": 1, "status": "OPEN", "player_choice": true,
			"candidates": [{}, {}, {}]},
		{"offer_id": 5, "generation": 1, "status": "OPEN", "player_choice": false,
			"candidates": [{}, {}, {}]},
	]
	controller._sync_family_founding_offer()
	_expect("open player offer locks the session and pauses the clock",
		controller.family_founding_locked() and clock.paused and ui.open
		and int(ui.shown.get("offer_id", 0)) == 4)
	_expect("non-player offers are never presented",
		int(ui.shown.get("queue_remaining", -1)) == 0)
	var blocked: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_SET_BUDGET,
		{"enabled": true, "daily_cash_limit": 1})
	_expect("other player commands wait for the founding choice",
		String(blocked.get("code", "")) == "family_founding_choice_required")
	var stale: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_FAMILY_FOUNDING_CHOOSE,
		{"offer_id": 99, "generation": 1, "choice_index": 0})
	_expect("choice for a different offer is rejected before the runtime",
		String(stale.get("code", "")) != "family_founding_choice_required"
		and not bool(stale.get("ok", true)))
	controller._on_pause_toggled(false)
	_expect("unpausing is ignored while the founding pick is open", clock.paused)
	var saved: Dictionary = controller.capture_view_state()
	_expect("view state records the founding lock and resume speed",
		bool(saved.get("family_founding_locked", false))
		and bool(saved.get("family_founding_resume_running", false))
		and is_equal_approx(float(saved.get("family_founding_previous_speed", 0.0)), 4.0))
	facade.offers[0]["status"] = "SELECTED_PENDING"
	controller._sync_family_founding_offer()
	_expect("settled choice unlocks and resumes at the previous speed",
		not controller.family_founding_locked() and not clock.paused
		and is_equal_approx(clock.speed_multiplier, 4.0) and not ui.open)
	controller.free()


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("  [FAIL] %s" % label)
