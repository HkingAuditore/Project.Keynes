extends SceneTree

## Headless contract test for the peace-negotiation window (design §12.3 / §14.3).
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_peace_window_test.gd
##
## Two layers are covered:
##   1. MilitaryPeaceViewModel: war situation, cession candidates, term encoding,
##      annex gate, price fallback — all without a live native runtime.
##   2. MilitaryPeaceWindow: static tree, draft toggling, submit gating, map-cell
##      consumption, value-only refresh (node count never changes).
##
## A rendered screenshot pass lives in tests/qa/military_peace_window_screenshot_qa.gd.

const WINDOW_SCENE := "res://scenes/ui/military_peace_window.tscn"
const CARD_SCENE := "res://scenes/ui/military_peace_card.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const PeaceViewModelScript = preload("res://scripts/ui/military_peace_view_model.gd")

const Q16 := 65536
const DAY := 404
const WAR_ID := 7
const PLAYER_SLOT := 0
const ENEMY_SLOT := 3
## Cells of the enemy that the player currently controls.
const CANDIDATES := [3, 4, 5]
## All cells the enemy still owns in this 24-cell fixture (3 of them occupied).
const ENEMY_OWNED := [3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23]

var _failures := PackedStringArray()


## Stand-in for PlayerController's map-highlight API. The window only
## feature-detects these three methods, so this also documents the contract the
## wiring pass has to implement.
class FakeController extends Node:
	var candidates := PackedInt32Array()
	var draft := PackedInt32Array()
	var cleared := 0

	func highlight_peace_candidates(cells: PackedInt32Array) -> void:
		candidates = cells

	func highlight_peace_draft(cells: PackedInt32Array) -> void:
		draft = cells

	func clear_peace_highlights() -> void:
		cleared += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	_check_terms_encoding()
	_check_view_model()
	await _check_launcher_card()
	_check_controller_api()
	await _check_window()
	print("military peace window: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


# ── 1. pure encoding ─────────────────────────────────────────────────────

func _check_terms_encoding() -> void:
	var draft := PeaceViewModelScript.empty_draft()
	_expect("a fresh draft is a white peace",
		PeaceViewModelScript.peace_terms(draft) == [{"kind": "white"}])
	draft["white"] = false
	draft["ceding"] = {12: true, 4: true, 9: false}
	var terms := PeaceViewModelScript.peace_terms(draft)
	_expect("ceding cells become cede terms in ascending cell order",
		terms.size() == 2 and int(terms[0]["cell"]) == 4 and int(terms[1]["cell"]) == 12)
	_expect("ceded cells are encoded as cede, never as a slot id",
		String(terms[0]["kind"]) == "cede" and String(terms[1]["kind"]) == "cede")
	draft["install"] = true
	draft["install_amount"] = 500.0
	draft["install_count"] = 99
	var with_install := PeaceViewModelScript.peace_terms(draft)
	var install_term: Dictionary = {}
	for term_value in with_install:
		if String((term_value as Dictionary).get("kind", "")) == "installments":
			install_term = term_value
	_expect("installments clamp to the 2..12 design range",
		not install_term.is_empty() and int(install_term["n"]) == 12
		and is_equal_approx(float(install_term["amount"]), 500.0))
	_expect("white peace is exclusive of every other term",
		PeaceViewModelScript.peace_terms({"white": true, "annex": true,
			"ceding": {4: true}}) == [{"kind": "white"}])


# ── 2. view model ────────────────────────────────────────────────────────

func _check_view_model() -> void:
	var vm := PeaceViewModelScript.new()
	vm.configure(_fixture_model())
	_expect("peace model reports the war situation", vm.available())
	var draft := PeaceViewModelScript.empty_draft()
	var data: Dictionary = vm.peace_model(WAR_ID, draft)
	_expect("peace model builds for an active war", bool(data.get("ok", false)))
	var war: Dictionary = data.get("war", {})
	_expect("enemy name comes from the country table",
		String(war.get("enemy_name", "")) == "赤原")
	_expect("war picks the player's role", String(war.get("role", "")) == "进攻方")
	var cession: Dictionary = data.get("cession", {})
	_expect("cession candidates are the occupied enemy cells",
		int(cession.get("total", 0)) == CANDIDATES.size())
	_expect("a fresh draft selects no cell", int(cession.get("checked", 0)) == 0)
	_expect("the default draft submits a white peace",
		PeaceViewModelScript.peace_terms(draft) == [{"kind": "white"}])
	var situation: Dictionary = data.get("situation", {})
	_expect("situation carries four KPIs", (situation.get("kpis", []) as Array).size() == 4)
	_expect("score parts stay hidden when the snapshot has none",
		(situation.get("parts", []) as Array).is_empty())
	var kpis: Array = situation.get("kpis", [])
	_expect("occupation KPI reports the candidate count",
		(kpis[1] as Dictionary).get("value", -1.0) == float(CANDIDATES.size()))
	_expect("enemy KPI reports the enemy's remaining territory",
		int((kpis[2] as Dictionary).get("value", -1.0)) == ENEMY_OWNED.size())
	var annex: Dictionary = data.get("annex", {})
	_expect("annex is refused while the enemy is not fully occupied",
		not bool(annex.get("can", true)))
	_expect("enemy territory is readable from the fixture owner map",
		int(annex.get("enemy_owned", -1)) == ENEMY_OWNED.size())

	# Two picked cells -> two cede terms and a priced draft.
	draft["white"] = false
	draft["ceding"] = {CANDIDATES[0]: true, CANDIDATES[1]: true}
	var picked: Dictionary = vm.peace_model(WAR_ID, draft)
	var picked_cession: Dictionary = picked.get("cession", {})
	_expect("picked cells are reported back as selected",
		int(picked_cession.get("checked", 0)) == 2
		and (picked_cession.get("cells", PackedInt32Array()) as PackedInt32Array).size() == 2)
	var terms: Dictionary = picked.get("terms", {})
	_expect("ceded land is priced above zero even without the native evaluator",
		float(terms.get("price", 0.0)) >= 4.0 and bool(terms.get("estimated", false)))
	_expect("picked land is sent as cede terms",
		(terms.get("terms", []) as Array).size() == 2)

	# Full occupation still refuses annex when someone else holds cells too.
	var half := vm.peace_model(WAR_ID, draft)
	var full_model := _fixture_model()
	full_model["military"]["snapshot"]["wars"][0]["fully_occupied"] = true
	var full_vm := PeaceViewModelScript.new()
	full_vm.configure(full_model)
	var full := full_vm.peace_model(WAR_ID, draft)
	_expect("full occupation alone does not unlock annex while the enemy holds free cells",
		not bool((full.get("annex", {}) as Dictionary).get("can", true)))
	_expect("a finished war yields a readable reason, not empty data",
		String(vm.peace_model(999, draft).get("reason", "")).contains("结束"))
	_expect("half-picked draft stays consistent between reads",
		(half.get("cession", {}) as Dictionary).get("checked", 0) == 2)


# ── 3. launcher card (replaces the inline PeaceEditor in the war page) ───

func _check_launcher_card() -> void:
	var host := Control.new()
	host.size = Vector2(520.0, 200.0)
	host.theme = load(THEME) as Theme
	root.add_child(host)
	var card := (load(CARD_SCENE) as PackedScene).instantiate() as Control
	host.add_child(card)
	await process_frame
	var fired := [0]
	card.peace_requested.connect(func(id: int) -> void: fired[0] = id)
	card.call("set_data", {"war_id": WAR_ID, "enemy_name": "赤原", "role": "进攻方",
		"days": 53, "score_text": "+27", "occupied": 3, "candidates": 3, "day": DAY})
	_expect("launcher card names the enemy and the war score",
		(card.get_node("Box/Header/Title") as Label).text.contains("赤原")
		and (card.get_node("Box/Summary") as Label).text.contains("+27"))
	(card.get_node("Box/Footer/Action") as Button).pressed.emit()
	_expect("launcher card asks for the peace window with its war id", fired[0] == WAR_ID)
	card.call("set_data", {"war_id": 0})
	_expect("a launcher card without a war disables its action",
		(card.get_node("Box/Footer/Action") as Button).disabled)
	host.queue_free()
	await process_frame


# ── 4. controller contract (unconfigured session must not crash) ──────────

func _check_controller_api() -> void:
	var controller = load("res://scripts/game/player_controller.gd").new()
	controller.set_peace_highlight_sets(null, null)
	controller.highlight_peace_candidates(PackedInt32Array([1, 2]))
	controller.highlight_peace_draft(PackedInt32Array([3]))
	controller.clear_peace_highlights()
	controller.focus_map_cell(5)
	controller.focus_map_cell(-1)
	var painted: int = controller.highlight_cells(PackedInt32Array([1]), false)
	_expect("peace highlight API tolerates a session without WorldRoot children",
		painted == 0)
	controller.free()


# ── 5. window behaviour ──────────────────────────────────────────────────

func _check_window() -> void:
	var host := Control.new()
	host.size = Vector2(1280.0, 720.0)
	host.theme = load(THEME) as Theme
	root.add_child(host)
	var window := (load(WINDOW_SCENE) as PackedScene).instantiate() as Control
	host.add_child(window)
	await process_frame
	var controller := FakeController.new()
	window.set_player_controller(controller)
	window.open(WAR_ID, _fixture_model())
	await process_frame

	_expect("window is a docked, non-modal surface", window.visible
		and window.size.x >= 520.0 and window.size.y > 300.0)
	_expect("window leaves most of a 1280 px map visible", window.size.x <= 1280.0 * 0.5)
	_expect("window keeps the static paper tree",
		window.has_node("Frame/Box/Header/PeaceTitle")
		and window.has_node("Frame/Box/Scroll/Body/TermsNote/TermsBox/CedeScroll/CedingList")
		and window.has_node("Frame/Box/Footer/Submit"))
	_expect("open paints every cession candidate on the map",
		controller.candidates.size() == CANDIDATES.size())
	var snapshot: Dictionary = window.call("debug_snapshot")
	_expect("open draft is a white peace",
		(snapshot.get("terms", []) as Array).size() == 1
		and String((snapshot["terms"] as Array)[0]["kind"]) == "white")
	_expect("open draft lists every cession candidate",
		(snapshot.get("candidates", PackedInt32Array()) as PackedInt32Array).size()
			== CANDIDATES.size())
	_expect("white peace is submittable on open",
		not (window.get_node("%Submit") as Button).disabled)

	var nodes_before := _count_nodes(window)
	window.refresh_model(_fixture_model())
	await create_timer(0.30).timeout
	_expect("daily refresh rebuilds no node", _count_nodes(window) == nodes_before)

	_expect("a candidate cell is consumed by the draft",
		bool(window.call("handle_map_cell", CANDIDATES[0])))
	var picked: Dictionary = window.call("debug_snapshot")
	_expect("map pick lands in the cede terms",
		(picked.get("selected", PackedInt32Array()) as PackedInt32Array).size() == 1
		and (picked.get("terms", []) as Array).size() == 1
		and String((picked["terms"] as Array)[0]["kind"]) == "cede")
	_expect("picking land overrides the white peace checkbox",
		not (window.get_node("%PeaceWhite") as CheckBox).button_pressed)
	_expect("map pick repaints only the draft highlight",
		controller.draft.size() == 1 and controller.candidates.size() == CANDIDATES.size())
	_expect("a picked cell can be picked again to undo",
		bool(window.call("handle_map_cell", CANDIDATES[0]))
		and (window.call("debug_snapshot")["selected"] as PackedInt32Array).is_empty())
	var status_before := String(window.call("debug_snapshot").get("status", ""))
	_expect("a non-candidate cell is consumed with a reason",
		bool(window.call("handle_map_cell", 22))
		and String(window.call("debug_snapshot").get("status", "")) != status_before
		and (window.call("debug_snapshot")["selected"] as PackedInt32Array).is_empty())
	_expect("annex stays disabled in this fixture",
		(window.get_node("%PeaceAnnex") as CheckBox).disabled)

	window.set_player_controller(null)
	window.open(WAR_ID, _fixture_model())
	_expect("a window with no live session refuses to stamp a treaty",
		(window.get_node("%Submit") as Button).disabled)
	window.set_player_controller(controller)

	var closed := [false]
	window.closed.connect(func() -> void: closed[0] = true)
	window.open(WAR_ID, _fixture_model())
	window.set_command_result({"ok": true, "message": "queued"})
	_expect("a submitted deal blocks a second stamp the same day",
		(window.get_node("%Submit") as Button).disabled
		and int(window.call("debug_snapshot").get("submitted_day", -1)) == DAY)
	window.close_panel()
	_expect("closing emits the shell signal", closed[0] and not window.visible)
	_expect("closing clears both map highlight sets", controller.cleared >= 1)

	window.open(999, _fixture_model())
	await process_frame
	_expect("an ended war blocks submission with a reason",
		(window.get_node("%Submit") as Button).disabled
		and not String(window.call("debug_snapshot").get("submit_blocked", "")).is_empty())
	window.close_panel()
	host.queue_free()
	await process_frame


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total


# ── fixture ──────────────────────────────────────────────────────────────

func _fixture_model() -> Dictionary:
	var owners := PackedInt32Array()
	for index in range(24):
		owners.append(ENEMY_SLOT if index in ENEMY_OWNED else PLAYER_SLOT)
	var snapshot := {
		"ok": true,
		"country_slot": PLAYER_SLOT,
		"country_handle": 0x100000000,
		"wars": [{
			"war_id": WAR_ID,
			"attacker_slot": PLAYER_SLOT,
			"defender_slot": ENEMY_SLOT,
			"start_day": 351,
			"score_q16": int(0.27 * Q16),
			"attacker_losses": 2140,
			"defender_losses": 3980,
			"fully_occupied": false,
		}],
		"wars_active": 1,
		"control": {
			"cells": PackedInt32Array(CANDIDATES),
			"controller_slots": PackedInt32Array([PLAYER_SLOT, PLAYER_SLOT, PLAYER_SLOT]),
		},
		"engagements": [{
			"cell_a": 3, "cell_b": 2, "attacker_slot": PLAYER_SLOT,
			"defender_slot": ENEMY_SLOT, "progress_q16": int(0.62 * Q16),
			"start_day": 388, "battle": true, "zone_a": "青阳", "zone_b": "青阳",
		}],
		"front_edge_keys": PackedInt32Array([3 * 6, 3 * 6 + 1]),
		"front_edge_progress": PackedByteArray([200, 255]),
		"daily_wage": 4200,
	}
	return {
		"country_handle": 0x100000000,
		"country_slot": PLAYER_SLOT,
		"current_day": DAY,
		"population": 214000,
		"good_ids": PackedStringArray(["grain"]),
		"cell_names": {3: "北岸", 4: "南岸", 5: "渡口"},
		"country_names": {ENEMY_SLOT: "赤原"},
		"army_names": {},
		"military": {
			"available": true,
			"facade": null,
			"country_handle": 0x100000000,
			"country_handles": {ENEMY_SLOT: 0x300000001},
			"region_names": {3: "青阳", 4: "青阳", 5: "洛雁"},
			"cell_owners": {"owners": owners},
			"snapshot": snapshot,
			"armies": [],
			"catalog": {"ok": true, "units": [], "categories": []},
			"researched_tech_ids": PackedStringArray(),
			"tech_gate_known": false,
		},
	}
