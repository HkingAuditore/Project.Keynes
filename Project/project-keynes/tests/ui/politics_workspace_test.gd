extends SceneTree

const REGIME_SCENE := "res://scenes/ui/regime_workspace.tscn"
const POLITICS_SCENE := "res://scenes/ui/politics_workspace.tscn"

var _failures := 0


class FakeController extends RefCounted:
	var requests: Array = []

	func request_command(command: StringName, args: Dictionary) -> Dictionary:
		requests.append([command, args])
		return {"ok": true, "code": "queued"}


func _initialize() -> void:
	call_deferred("_run")


func _model(current_id: String) -> Dictionary:
	var options := RegimePresenter.enrich([
		{"id": "early_clan", "display_name": "早期氏族", "detail": "允许建造",
			"capability_keys": PackedStringArray(["treasury_construction"]),
			"modifier_definition_keys": PackedStringArray([
				"regime.early_clan.cohesion", "regime.early_clan.charter"])},
		{"id": "local_council", "display_name": "地方议会", "detail": "暂不开放国库建造",
			"modifier_definition_keys": PackedStringArray([
				"regime.local_council.cohesion", "regime.local_council.charter"])},
	])
	return {"regime": {"available": true, "current_id": current_id,
		"current_name": "早期氏族" if current_id == "early_clan" else "地方议会",
		"options": options}, "current_day": 5}


func _run() -> void:
	var workspace := (load(REGIME_SCENE) as PackedScene).instantiate() as RegimeWorkspace
	workspace.size = Vector2(900, 600)
	get_root().add_child(workspace)
	var controller := FakeController.new()
	workspace.set_player_controller(controller)
	workspace.set_model(_model("early_clan"))
	await process_frame
	var cards := workspace.get_node("Scroll/Column/Cards")
	_expect("two regime cards render", cards.get_child_count() == 2)
	var current := cards.get_child(0) as RegimeCharterCard
	var other := cards.get_child(1) as RegimeCharterCard
	_expect("current regime is listed first", current.regime_id == "early_clan")
	_expect("current regime title renders",
		(current.get_node("Margin/Column/Head/Titles/Name") as Label).text == "早期氏族")
	_expect("current regime has no change action", not current.action_button().visible)
	_expect("alternative regime is focusable",
		other.action_button().visible and not other.action_button().disabled
		and other.action_button().focus_mode == Control.FOCUS_ALL)
	_expect("supporters are listed from regime modifiers",
		other.get_node("Margin/Column/SupportRow/People").get_child_count() > 0)
	_expect("opponents are listed from regime modifiers",
		other.get_node("Margin/Column/OpposeRow/People").get_child_count() > 0)
	var charter := other.get_node("Margin/Column/CharterRow/Charter")
	_expect("charter effects are listed from regime modifiers",
		charter.get_child_count() == 3)
	var charter_text := PackedStringArray()
	for child in charter.get_children():
		charter_text.append((child as Label).text)
	var joined := ", ".join(charter_text)
	_expect("charter names the structural trade-off (%s)" % joined,
		joined.contains("贸易容量") and joined.contains("全国建设成本"))
	other.action_button().pressed.emit()
	_expect("first press only arms the change", controller.requests.is_empty())
	var hint := (other.get_node("Margin/Column/Footer/Hint") as Label).text
	_expect("armed card names the lost power", hint.contains("失去国库建造"))
	other.action_button().pressed.emit()
	_expect("second press submits the regime command", controller.requests.size() == 1
		and String(controller.requests[0][0]) == "politics.regime.set")
	_expect("submitted card shows pending", other.action_button().disabled)
	workspace.set_model(_model("local_council"))
	await process_frame
	_expect("committed regime moves to the front",
		(cards.get_child(0) as RegimeCharterCard).regime_id == "local_council")
	workspace.queue_free()
	var filtered := RegimePresenter.attitudes_for(
		PackedStringArray(["regime.early_clan.cohesion"]), {"merchant": true})
	_expect("absent professions are not listed",
		filtered.supporters.is_empty() and filtered.opponents.size() == 1
		and String(filtered.opponents[0].profession_id) == "merchant")

	var politics := (load(POLITICS_SCENE) as PackedScene).instantiate() as PoliticsWorkspace
	get_root().add_child(politics)
	politics.size = Vector2(1000, 640)
	politics.set_model({"politics": _model("early_clan")})
	await process_frame
	politics.select_tab("ideology")
	await process_frame
	var nav := politics.get_node("%ChapterNav") as DossierChapterNav
	_expect("chapter nav follows tab selection", nav.current == "ideology")
	_expect("ideology page shown", (politics.get_node("Root/Pages/IdeologyScroll/Ideology") as Control).is_visible_in_tree()
		and not (politics.get_node("Root/Pages/Regime") as Control).is_visible_in_tree())
	_expect("nav stays inside the workspace", nav.get_global_rect().position.y
		>= politics.get_global_rect().position.y - 0.5)
	print("politics workspace: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
