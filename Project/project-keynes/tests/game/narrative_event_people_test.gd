extends "res://tests/support/runtime_narrative_scenario.gd"

const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const CELL := 9


func _run() -> void:
	_test_definition_quote_roundtrip()
	_test_human_conditions()
	var beats := ["evt.people.hungry_crowd", "evt.people.gruel_aftermath"]
	if await _start_story({"scheduled_events": [{"due_day": 10, "event_id": beats[0]}]}, beats):
		await _check_hungry_chain()
	await _close_story()
	print("narrative people: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _check_hungry_chain() -> void:
	if not await _advance_story(10):
		return
	var offer := story_service.active_offer()
	_expect("hungry crowd is presented as prose without a quote block",
		offer.get("event_id") == "evt.people.hungry_crowd"
		and String(offer.get("quote_text", "")).is_empty()
		and String(offer.get("body_text", "")).contains("城门外"))
	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	dialog.present_offer(offer)
	_expect("dialog shows the prose without a quote block",
		not dialog._quote_block.visible and dialog._body_label.visible)
	_choose_story(0)
	if not await _advance_story(11):
		dialog.free()
		return
	var records := _story_records()
	_expect("opening the granary records the human outcome on day 11",
		records.size() == 1 and int(records[0].resolved_day) == 11
		and String(records[0].outcome_narrative).contains("粥棚"))
	if not records.is_empty():
		dialog.show_outcome({"record": records[0]})
		_expect("the outcome replaces the original scene prose",
			dialog._outcome_narrative_label.visible and not dialog._body_label.visible)
	dialog.free()
	var state := story_service.export_state()
	_expect("opening the granary raises the local gruel flag",
		state.get("story_flags", {}).has("cell:%d:flag_gruel_kitchen" % story_cell))
	var followups: Array = state.get("scheduled_events", [])
	_expect("opening the granary dates the aftermath", followups.size() == 1
		and followups[0].get("event_id") == "evt.people.gruel_aftermath"
		and int(followups[0].get("due_day", -1)) == 56)
	if not await _advance_story(56):
		return
	_expect("the aftermath opens at the end of the relief window",
		story_service.active_offer().get("event_id") == "evt.people.gruel_aftermath")
	_choose_story(0)
	if await _advance_story(57):
		records = _story_records()
		_expect("registering the survivors buys long-term capacity and leaves a grudge",
			records.size() == 2 and records[0].applied_effects_summary.has("本地农业 +5%，540 日")
			and not story_service.export_state().get("weight_biases", []).is_empty())


func _test_definition_quote_roundtrip() -> void:
	var def = NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.test.quote",
		"title": "{settlement_name}·试",
		"body_text": "正文。",
		"speaker": "城门吏 王顺",
		"quote_text": "「大人得给句话。」",
	})
	var restored = NarrativeEventDefinitionScript.from_dict(def.to_dict())
	_expect("speaker survives to_dict/from_dict", String(restored.speaker) == "城门吏 王顺")
	_expect("quote_text survives to_dict/from_dict",
		String(restored.quote_text) == "「大人得给句话。」")
	_expect("events without a quote stay empty",
		String(NarrativeEventDefinitionScript.from_dict({"title": "t"}).quote_text).is_empty())


# ─── 2. 人群采样 ────────────────────────────────────────────────────────────

func _test_human_conditions() -> void:
	var Op = NarrativeConditionScript.Op
	var ctx := {
		"human_context_available": true, "population": 45, "unemployment_ratio": 3.0 / 45.0,
		"subsistence_shortfall_ratio": 15.0 / 45.0, "neediest_cohort_satisfaction": 0.30,
		"profession_share_by_id": {"artisan": 35.0 / 45.0},
	}
	_expect("shortfall condition accepts a poor cell",
		NarrativeConditionScript.from_dict({"op": Op.SUBSISTENCE_SHORTFALL_GTE,
			"float_value": 0.30}).evaluate(ctx))
	_expect("shortfall condition rejects a comfortable cell",
		not NarrativeConditionScript.from_dict({"op": Op.SUBSISTENCE_SHORTFALL_GTE,
			"float_value": 0.60}).evaluate(ctx))
	_expect("unemployment condition reads the aggregate ratio",
		NarrativeConditionScript.from_dict({"op": Op.UNEMPLOYMENT_GTE,
			"float_value": 0.05}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.UNEMPLOYMENT_GTE,
			"float_value": 0.10}).evaluate(ctx))
	_expect("profession share condition matches the stable id",
		NarrativeConditionScript.from_dict({"op": Op.PROFESSION_SHARE_GTE,
			"target_key": "artisan", "float_value": 0.5}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.PROFESSION_SHARE_GTE,
			"target_key": "farmer", "float_value": 0.5}).evaluate(ctx))
	_expect("cohort satisfaction condition follows the unhappiest cohort",
		NarrativeConditionScript.from_dict({"op": Op.COHORT_SATISFACTION_LTE,
			"float_value": 0.45}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.COHORT_SATISFACTION_LTE,
			"float_value": 0.20}).evaluate(ctx))


# ─── 4. 国库 → 人数最多的那群（职业名进标签）──────────────────────────────
