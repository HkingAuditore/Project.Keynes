extends "res://tests/support/runtime_narrative_scenario.gd"

const EffectSpec = preload("res://scripts/narrative/narrative_effect_spec.gd")
const TRAIT := "i005_knowledge"


func _run() -> void:
	var grant := "evt.test.grant_trait"
	var remove := "evt.test.remove_trait"
	var effects := [
		{"kind": EffectSpec.Kind.GRANT_FAMILY_TRAIT, "target_key": TRAIT, "magnitude_q16": 65536},
		{"kind": EffectSpec.Kind.REMOVE_FAMILY_TRAIT, "target_key": TRAIT, "magnitude_q16": 65536},
	]
	for effect in effects:
		var spec := EffectSpec.from_dict(effect)
		_expect("family trait effect survives catalog serialization",
			EffectSpec.from_dict(spec.to_dict()).to_dict() == spec.to_dict())
	if await _start_story({
		"dynamic_events_by_id": {grant: _story_fixture_event(grant, [effects[0]]),
			remove: _story_fixture_event(remove, [effects[1]])},
		"scheduled_events": [{"due_day": 2, "event_id": grant}, {"due_day": 12, "event_id": remove}],
	}):
		await _check_family()
	await _close_story()
	print("narrative family bridge: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _check_family() -> void:
	if not await _advance_story(2):
		return
	var page := story_economy.family_cell_snapshot(story_cell, 0, 64)
	var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	_expect("the capital has a native family", not handles.is_empty())
	if handles.is_empty():
		return
	var family := handles[0]
	var names: PackedStringArray = page.get("family_names", PackedStringArray())
	var offer := story_service.active_offer()
	_expect("the published title substitutes the committed family name",
		not names.is_empty() and String(offer.get("title", "")).contains(names[0]))
	_choose_story(0)
	if not await _advance_story(12):
		return
	_expect("native family received the grant via Effect",
		story_economy.get_family_traits(family).get("trait_keys", PackedStringArray()).has(TRAIT))
	_choose_story(0)
	if await _advance_story(20):
		_expect("native family received the removal via Effect",
			not story_economy.get_family_traits(family).get("trait_keys", PackedStringArray()).has(TRAIT))
