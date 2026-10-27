extends SceneTree

const WorkspaceScene = preload("res://scenes/ui/ideology_workspace.tscn")
const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")


class FakeIdeologyFacade extends RefCounted:
	var explain_calls := 0
	var allowed := true
	var effect_instance_count := 0

	func explain_ideologies(_handle: int, ideology_ids: PackedInt32Array) -> Dictionary:
		explain_calls += 1
		var count := ideology_ids.size()
		var supports := PackedInt32Array()
		var thresholds := PackedInt32Array()
		var blockers := PackedInt32Array()
		var available := PackedByteArray()
		var support_allowed := PackedByteArray()
		var equip_allowed := PackedByteArray()
		var unequip_allowed := PackedByteArray()
		var promote_allowed := PackedByteArray()
		var stance_offsets := PackedInt32Array([0])
		for _index in count:
			for _direction in 3:
				supports.append(32768)
				thresholds.append(0)
				blockers.append(-1)
				available.append(1)
				support_allowed.append(1 if allowed else 0)
			equip_allowed.append(1 if allowed else 0)
			unequip_allowed.append(1 if allowed else 0)
			promote_allowed.append(1 if allowed else 0)
			stance_offsets.append(stance_offsets[stance_offsets.size() - 1])
		return {
			"ok": true,
			"ideology_ids": ideology_ids,
			"support_q16": supports,
			"support_thresholds_q16": thresholds,
			"support_blocking_classes": blockers,
			"support_available": available,
			"support_allowed": support_allowed,
			"equip_allowed": equip_allowed,
			"unequip_allowed": unequip_allowed,
			"promote_allowed": promote_allowed,
			"stance_offsets": stance_offsets,
			"stance_class_indices": PackedInt32Array(),
			"class_influence": PackedInt64Array(),
			"adopt_contributions": PackedInt64Array(),
			"repeal_contributions": PackedInt64Array(),
			"promote_contributions": PackedInt64Array(),
		}

	func effect_instances(_handle: int) -> Dictionary:
		var idea_ids := PackedInt64Array()
		var idea_levels := PackedInt64Array()
		var target_handles := PackedInt64Array()
		var target_domains := PackedInt32Array()
		var present := PackedByteArray()
		for _index in effect_instance_count:
			idea_ids.append(0)
			idea_levels.append(0)
			target_handles.append(12)
			target_domains.append(2)
			present.append(1)
		return {"ok": true, "idea_ids": idea_ids,
			"idea_levels": idea_levels, "instance_ids": PackedInt64Array(),
			"generations": PackedInt64Array(), "program_hashes": PackedInt64Array(),
			"target_handles": target_handles,
			"target_generations": PackedInt32Array(),
			"target_domains": target_domains, "present": present}


var _failures := PackedStringArray()
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var workspace := WorkspaceScene.instantiate() as Control
	root.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var facade := FakeIdeologyFacade.new()
	var catalog := _catalog()
	var snapshot := _snapshot()
	workspace.call("set_model", _model(facade, catalog, snapshot, 1))
	await process_frame
	var entries: Dictionary = workspace.get("_collection_entries")
	var card := entries.get(0) as Control
	var card_id := card.get_instance_id() if card != null else 0
	_expect("all 113 known cards are present", entries.size() == 113 and card_id != 0)
	_expect("initial explanation is queried once", facade.explain_calls == 1)

	var progress_snapshot := _snapshot()
	progress_snapshot["understanding_q16"] = PackedInt64Array([50])
	workspace.call("refresh_model", _model(facade, catalog, progress_snapshot, 1))
	_expect("understanding refresh preserves card node", _card_id(workspace) == card_id)
	var meter: Control = card.call("level_meter")
	_expect("understanding refresh updates its meter", int(meter.get("understanding_q16")) == 50)
	_expect("understanding refresh reuses support explanation", facade.explain_calls == 1)

	var pending_snapshot := _snapshot()
	pending_snapshot["transition_pending"] = PackedByteArray([1])
	workspace.call("refresh_model", _model(facade, catalog, pending_snapshot, 1))
	_expect("pending refresh preserves card node", _card_id(workspace) == card_id)
	_expect("pending refresh disables action without re-explaining support",
		(_button(card, "推行") as Button).disabled and facade.explain_calls == 1)

	var next_day := _snapshot()
	facade.effect_instance_count = 1
	workspace.call("refresh_model", _model(facade, catalog, next_day, 2))
	_expect("daily refresh preserves card node", _card_id(workspace) == card_id)
	_expect("daily effect report refreshes the changed card face",
		String(card.tooltip_text).contains("效果实例 1 处"))
	_expect("daily refresh does not re-explain support", facade.explain_calls == 1)
	facade.effect_instance_count = 0
	var following_day := _snapshot()
	workspace.call("refresh_model", _model(facade, catalog, following_day, 3))
	_expect("effect report removes stale target details",
		not String(card.tooltip_text).contains("效果实例 1 处"))

	var synergy_snapshot := _snapshot()
	synergy_snapshot["active_synergy_ids"] = PackedInt32Array([0])
	workspace.call("refresh_model", _model(facade, catalog, synergy_snapshot, 3))
	_expect("synergy change preserves card nodes", _card_id(workspace) == card_id)
	_expect("synergy change does not re-explain support", facade.explain_calls == 1)

	facade.allowed = false
	for revision in range(2, 102):
		var revised_snapshot := _snapshot()
		revised_snapshot["support_revision"] = revision
		workspace.call("refresh_model", _model(facade, catalog, revised_snapshot, 2))
	_expect("100 support revisions preserve card node", _card_id(workspace) == card_id)
	_expect("100 support revisions refresh explanation once each",
		facade.explain_calls == 101)
	_expect("support revision updates action availability",
		(_button(card, "推行") as Button).disabled)
	workspace.call("_on_sort_selected", 3)
	var leveled_snapshot := _snapshot()
	var sorted_levels: PackedInt32Array = leveled_snapshot["levels"]
	sorted_levels[112] = 1
	leveled_snapshot["levels"] = sorted_levels
	workspace.call("refresh_model", _model(facade, catalog, leveled_snapshot, 2))
	var sorted_entries: Dictionary = workspace.get("_collection_entries")
	var first_sorted_id := -1
	for idea_id in sorted_entries:
		if (sorted_entries[idea_id] as Control).get_index() == 0:
			first_sorted_id = int(idea_id)
			break
	_expect("level sort reorders cards after a level change",
		first_sorted_id == 112)

	workspace.queue_free()
	await process_frame
	for failure in _failures:
		push_error(failure)
	print("[ideology-workspace-stability] %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)


func _catalog() -> Dictionary:
	var ideologies: Array[Dictionary] = []
	for ideology_id in 113:
		ideologies.append({
			"dense_id": ideology_id,
			"id": "idea.test_%d" % ideology_id,
			"display_name": "测试理念 %d" % ideology_id,
			"school_id": "agrarian",
			"rarity": 1,
			"level_labels": PackedStringArray(["初境", "中境", "高境"]),
			"level_thresholds_q16": PackedInt64Array([0, 100, 200]),
			"level_effect_lines": [PackedStringArray(["效果提高 1%"]),
				PackedStringArray(["效果提高 2%"]), PackedStringArray(["效果提高 3%"])],
			"min_spirit_level": 2,
		})
	return {
		"ok": true,
		"ideology_capacity": 1,
		"national_spirit_capacity": 1,
		"political_class_ids": PackedStringArray(),
		"ideologies": ideologies,
		"synergies": [{"dense_id": 0, "school_id": "agrarian",
			"min_count": 1, "tooltip": "测试共鸣"}],
	}


func _snapshot() -> Dictionary:
	var known := PackedInt32Array()
	var levels := PackedInt32Array()
	var understanding := PackedInt64Array()
	var locations := PackedInt32Array()
	var pending := PackedByteArray()
	for ideology_id in 113:
		known.append(ideology_id)
		levels.append(0)
		understanding.append(0)
		locations.append(0)
		pending.append(0)
	return {
		"ok": true,
		"materialized": true,
		"known_ids": known,
		"idea_ids": known,
		"understanding_q16": understanding,
		"levels": levels,
		"locations": locations,
		"transition_pending": pending,
		"active_synergy_ids": PackedInt32Array(),
		"support_revision": 1,
		"ideology_slots_capacity": 1,
		"national_spirit_slots_capacity": 1,
		"offer_active": false,
		"ideology_points_q16": 0,
		"point_baseline_ready": true,
	}


func _model(facade: FakeIdeologyFacade, catalog: Dictionary,
		snapshot: Dictionary, day: int) -> Dictionary:
	var presentation := CountryViewModelScript.present_ideology(snapshot, catalog)
	return {"country_handle": 10, "current_day": day,
		"ideology": {"available": true, "facade": facade,
			"catalog": catalog, "snapshot": snapshot,
			"presentation": presentation}}


func _card_id(workspace: Control) -> int:
	var entries: Dictionary = workspace.get("_collection_entries")
	var card := entries.get(0) as Control
	return card.get_instance_id() if card != null else 0


func _button(card: Control, label: String) -> Button:
	var footer := card.call("footer") as HBoxContainer
	for child in footer.get_children():
		if child is Button and (child as Button).text == label:
			return child as Button
	return null


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("[%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)
