extends SceneTree

const NarrativeRngScript = preload("res://scripts/narrative/narrative_rng.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeWeightRuleScript = preload("res://scripts/narrative/narrative_weight_rule.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeOutcomeScript = preload("res://scripts/narrative/narrative_outcome.gd")
const NarrativeOptionScript = preload("res://scripts/narrative/narrative_option.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEventFlowScript = preload("res://scripts/narrative/narrative_event_flow.gd")
const NarrativeAiPromptBuilderScript = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")
const NarrativeStateProbeScript = preload("res://scripts/narrative/narrative_state_probe.gd")
const NarrativeStateProbeCatalogScript = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

var _checks := 0
var _failures := 0

class CashEconomyStub extends RefCounted:
	var transfers: Array[Dictionary] = []
	var details_requested := false
	func is_configured() -> bool: return true
	func population_cell_snapshot(_cell: int, include_details: bool = true) -> Dictionary:
		details_requested = include_details
		if not include_details:
			return {"population": 25, "funds": 8000}
		return {"handles": PackedInt64Array([101, 102]),
			"populations": PackedInt64Array([5, 20]), "funds": PackedInt64Array([3000, 5000])}
	func transfer_country_cash_to_cohort(country: int, cohort: int, amount: int,
			day: int, sequence: int) -> Dictionary:
		transfers.append({"country": country, "cohort": cohort, "amount": amount,
			"day": day, "sequence": sequence})
		return {"ok": true}

class CashCountryStub extends RefCounted:
	func treasury_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "cash": 100000}

class CashGeneratorStub extends RefCounted:
	var economy := CashEconomyStub.new()
	var country := CashCountryStub.new()
	func get_economy_facade(): return economy
	func get_country_facade(): return country

class FactBusStub extends RefCounted:
	var batch: Dictionary = {"count": 0}
	func is_available() -> bool:
		return true
	func poll_events(_consumer, _max_events, _event_type, _auto_ack, _after_event_id) -> Dictionary:
		return batch

class FactGeneratorStub extends RefCounted:
	var bus := FactBusStub.new()
	func get_gameplay_event_bus(): return bus
	func get_country_facade(): return null
	func get_economy_facade(): return null

class StateCountryStub extends RefCounted:
	var territory := PackedInt32Array([5])
	func snapshot(_country: int) -> Dictionary:
		return {"ok": true, "display_name": "测试国", "territory_cells": territory,
			"technology_ids": PackedStringArray()}
	func current_era_index(_country: int) -> int:
		return 1
	func treasury_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "cash": 50000, "good_ids": PackedStringArray(),
			"quantities": PackedInt64Array()}

class StateEconomyStub extends RefCounted:
	var grain_price := 200
	var base_price := 100
	func is_configured() -> bool:
		return true
	func settlement_display_name(_cell: int) -> String:
		return "测试邑"
	func population_cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "population": 30, "composite_satisfaction_q16": 40000}
	func population_cell_snapshot(_cell: int, _include_details: bool) -> Dictionary:
		return {"handles": PackedInt64Array([11]), "populations": PackedInt64Array([30]),
			"funds": PackedInt64Array([9000])}
	func building_cell_snapshot(_cell: int) -> Dictionary:
		return {}
	func market_cell_snapshot(_cell: int) -> Dictionary:
		return {"good_stable_ids": PackedStringArray(["grain"]),
			"stocks": PackedInt64Array([20]),
			"prices": PackedInt64Array([grain_price]),
			"base_prices": PackedInt64Array([base_price])}

class StateGeneratorStub extends RefCounted:
	var country := StateCountryStub.new()
	var economy := StateEconomyStub.new()
	func get_country_facade(): return country
	func get_economy_facade(): return economy


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_deterministic_rng()
	_test_frost_cash_transfer()
	_test_shared_event_quota()
	_test_multidimensional_conditions_and_catalog()
	_test_event_chain_and_weight_bias_and_chronicle()
	_test_save_restore_roundtrip()
	_test_ai_sandbox_and_image_cache()
	_test_ai_fact_trigger_and_staleness()
	_test_state_probe_and_ai_pool()
	_test_ui_dialog_and_chronicle_panel()
	_test_player_controller_integration()
	print("=== narrative event runtime test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_frost_cash_transfer() -> void:
	var generator := CashGeneratorStub.new()
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(generator, null, null, null, 1, 98765, catalog)
	var offer := service.enqueue_event_offer(catalog.get_event(&"evt.climate.bitter_frost"), 1828, 500)
	_expect("event trigger scan keeps summary-only population query", not generator.economy.details_requested)
	var result := service.choose_option(int(offer.offer_id), int(offer.offer_generation), 0, 501)
	_expect("frost aid choice resolves and requests cohort details",
		bool(result.get("ok", false)) and generator.economy.details_requested)
	_expect("frost aid submits a real transfer instead of simulated success", generator.economy.transfers.size() == 1)
	if generator.economy.transfers.size() == 1:
		var transfer: Dictionary = generator.economy.transfers[0]
		_expect("frost aid sends 3 percent to the largest local cohort at the effective day",
			transfer.country == 1 and transfer.cohort == 102 and transfer.amount == 3000 and transfer.day == 501)

func _test_shared_event_quota() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 98765, catalog)
	var def = catalog.get_event(&"evt.climate.bitter_frost")
	for day in [20, 100]:
		var offer := service.enqueue_event_offer(def, 3, day)
		service.choose_option(int(offer.offer_id), int(offer.offer_generation), 1, day + 1)
	for channel in [0, 1]:
		var ordinary = def.duplicate(true)
		ordinary.trigger_channel = channel
		_expect("pulse and fact channels share exhausted annual quota",
			service.enqueue_event_offer(ordinary, 3, 200).is_empty())
	var ai = def.duplicate(true)
	ai.is_ai_generated = true
	_expect("ordinary AI shares exhausted annual quota", service.enqueue_event_offer(ai, 3, 200).is_empty())
	# 模拟旧档积压：超额普通事件在出队时被剔除，后续定时事件仍可展示。
	var queued := {"cell_idx": 3, "event_id": String(def.event_id), "bypass_pacing": false}
	service._ready_queue.append(queued)
	service._ready_queue.append({"cell_idx": 3, "event_id": "scheduled", "bypass_pacing": true})
	var restored := NarrativeEventServiceScript.new()
	restored.configure(null, null, null, null, 1, 98765, catalog)
	restored.restore_state(service.export_state())
	restored.on_day_committed(200)
	_expect("restored over-quota queue cannot display ordinary events",
		String(restored.active_offer().get("event_id", "")) == "scheduled" and restored.ready_queue_size() == 0)
	_expect("scheduled followup does not consume quota", int(restored._cell_year_event_counts.get("0:3", 0)) == 2)
	var gap_service := NarrativeEventServiceScript.new()
	gap_service.configure(null, null, null, null, 1, 98765, catalog)
	gap_service._last_popup_day = 190
	gap_service._ready_queue.append({"cell_idx": 4, "event_id": "ordinary", "bypass_pacing": false})
	gap_service._ready_queue.append({"cell_idx": 4, "event_id": "scheduled", "bypass_pacing": true})
	gap_service._promote_next_ready_offer(200)
	_expect("scheduled followup passes ordinary events waiting for global gap",
		String(gap_service.active_offer().get("event_id", "")) == "scheduled" and gap_service.ready_queue_size() == 1)
	gap_service._active_offer.clear()
	gap_service._promote_next_ready_offer(201)
	_expect("queued ordinary event must wait for global gap", not gap_service.has_active_offer())
	gap_service._promote_next_ready_offer(260)
	_expect("queued ordinary event displays after global gap", gap_service.has_active_offer())
	_expect("annual quota resets next year", not restored.cell_year_pacing_blocked(3, 365))


func _test_deterministic_rng() -> void:
	var r1 := NarrativeRngScript.roll_q16(42, 10, 1, 5, 99)
	var r2 := NarrativeRngScript.roll_q16(42, 10, 1, 5, 99)
	var r3 := NarrativeRngScript.roll_q16(42, 11, 1, 5, 99)
	_expect("roll_q16 is deterministic for identical inputs", r1 == r2 and r1 >= 0 and r1 < 65536)
	_expect("roll_q16 varies across days", r1 != r3)

	var weights := PackedInt64Array([49152, 16384])
	var pick1 := NarrativeRngScript.pick_weighted_index(weights, 12345, 20, 1, 8, 7)
	var pick2 := NarrativeRngScript.pick_weighted_index(weights, 12345, 20, 1, 8, 7)
	_expect("pick_weighted_index is deterministic and in range", pick1 == pick2 and (pick1 == 0 or pick1 == 1))


func _test_multidimensional_conditions_and_catalog() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	_expect("default catalog has at least 10 authored events", catalog.all_events().size() >= 10)

	var drought_def := catalog.get_event(&"evt.climate.severe_drought")
	var ocean_def := catalog.get_event(&"evt.ocean.upwelling_bonanza")
	var market_def := catalog.get_event(&"evt.market.grain_panic")
	_expect("core climate, ocean and market events exist",
		drought_def != null and ocean_def != null and market_def != null)

	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 98765, catalog)

	var hot_dry_ctx := {
		"cell_idx": 12,
		"era_index": 1,
		"temperature": 31.0,
		"moisture": 0.25,
		"population": 25,
		"is_coastal": false,
	}
	var w_drought := service.evaluate_event_weight(drought_def, hot_dry_ctx, 10)
	var w_ocean_inland := service.evaluate_event_weight(ocean_def, hot_dry_ctx, 10)
	_expect("hot dry inland cell matches severe_drought with boosted weight", w_drought > drought_def.base_weight)
	_expect("inland cell does not match coastal upwelling event", w_ocean_inland == 0)

	var coastal_upwelling_ctx := {
		"cell_idx": 18,
		"era_index": 1,
		"temperature": 16.0,
		"moisture": 0.65,
		"population": 20,
		"is_coastal": true,
		"ocean_upwelling": 0.32,
		"ocean_current_speed": 0.35,
	}
	var w_ocean_coastal := service.evaluate_event_weight(ocean_def, coastal_upwelling_ctx, 10)
	_expect("coastal cell with strong upwelling and current gets high weight", w_ocean_coastal > ocean_def.base_weight * 2)


func _test_event_chain_and_weight_bias_and_chronicle() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 77777, catalog)

	var stage1 := catalog.get_event(&"evt.chain.strange_outcrop")
	var stage2 := catalog.get_event(&"evt.chain.subterranean_cavern")
	var stage3 := catalog.get_event(&"evt.chain.ancient_foundry_legacy")
	_expect("3-stage event chain definitions exist", stage1 != null and stage2 != null and stage3 != null)

	var cell_ctx := {
		"cell_idx": 7,
		"settlement_name": "云山镇",
		"landform_name": "丘陵",
		"terrain_name": "森林",
		"temperature": 18.5,
		"population": 30,
		"treasury_cash": 500000,
		"era_index": 1,
	}

	# Before Stage 1 is completed, Stage 2 must have weight 0 (missing prerequisite event & story flag)
	_expect("Stage 2 is locked before Stage 1 completes",
		service.evaluate_event_weight(stage2, cell_ctx, 5) == 0)

	# Trigger Stage 1
	var offer1 := service.enqueue_event_offer(stage1, 7, 5, &"chain_strange_outcrop", true, cell_ctx)
	_expect("Stage 1 offer is active and formatted with settlement name",
		service.has_active_offer() and String(offer1.get("title", "")).find("云山镇") >= 0)
	_expect("Encountering Stage 1 immediately registers on_trigger weight bias for 'prospecting' tag",
		service.weight_biases().size() >= 1)

	# Choose Option 0 ("组建勘探队，顺矿脉向地底深掘")
	var choose1 := service.choose_option(
		int(offer1.get("offer_id", 0)),
		int(offer1.get("offer_generation", 0)),
		0,
		6
	)
	_expect("Choosing Stage 1 option 0 succeeds and records chronicle",
		bool(choose1.get("ok", false)) and service.chronicle_total_count() == 1)
	_expect("Stage 1 option sets story flag 'flag_deep_prospecting'",
		service.has_story_flag(&"flag_deep_prospecting", 7))
	_expect("Stage 1 option schedules Stage 2 followup event",
		service.scheduled_events().size() == 1)

	# Now Stage 2 is eligible and its weight is boosted by the weight bias!
	var w_stage2 := service.evaluate_event_weight(stage2, cell_ctx, 10)
	_expect("Stage 2 becomes eligible with boosted weight after Stage 1 option",
		w_stage2 > stage2.base_weight)

	# Advance to day 22 (past the 15-day delay from day 6 -> due_day 21)
	service.on_day_committed(22, false)
	var offer2 := service.active_offer()
	_expect("Scheduled Stage 2 automatically triggers on due day",
		not offer2.is_empty() and String(offer2.get("event_id", "")) == "evt.chain.subterranean_cavern")


func _test_save_restore_roundtrip() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service_a := NarrativeEventServiceScript.new()
	service_a.configure(null, null, null, null, 1, 54321, catalog)

	var drought_def := catalog.get_event(&"evt.climate.severe_drought")
	var ctx := {
		"cell_idx": 3,
		"settlement_name": "河阳邑",
		"landform_name": "平原",
		"temperature": 29.0,
		"moisture": 0.2,
		"population": 40,
		"treasury_cash": 200000,
	}
	var offer := service_a.enqueue_event_offer(drought_def, 3, 12, &"", true, ctx)
	service_a.set_story_flag(&"flag_test_persist", 3, 12, 90, 1)
	var saved_state := service_a.export_state()

	# Restore into a brand-new service instance
	var service_b := NarrativeEventServiceScript.new()
	service_b.configure(null, null, null, null, 1, 1, catalog)
	var restore_res := service_b.restore_state(saved_state)
	_expect("pknr state restores cleanly", bool(restore_res.get("ok", false)))
	_expect("active offer survives save/load round-trip",
		service_b.has_active_offer()
		and int(service_b.active_offer().get("offer_id", -1)) == int(offer.get("offer_id", -2)))
	_expect("story flags survive save/load round-trip",
		service_b.has_story_flag(&"flag_test_persist", 3))

	# Verify deterministic outcome roll is identical between original and restored service
	var offer_id_val := int(offer.get("offer_id", 0))
	var offer_gen_val := int(offer.get("offer_generation", 0))
	var res_a := service_a.choose_option(offer_id_val, offer_gen_val, 0, 13)
	var res_b := service_b.choose_option(offer_id_val, offer_gen_val, 0, 13)
	_expect("post-restore option choice rolls the exact same probabilistic outcome",
		bool(res_a.get("ok", false)) and bool(res_b.get("ok", false))
		and int(res_a.get("outcome_index", -1)) == int(res_b.get("outcome_index", -2)))


func _test_ai_sandbox_and_image_cache() -> void:
	var cell_ctx := {
		"day": 30,
		"cell_idx": 9,
		"country_name": "华夏",
		"settlement_name": "临海城",
		"era_index": 2,
		"era_name": "青铜与城邦时代",
		"terrain_name": "海岸",
		"landform_name": "三角洲",
		"temperature": 24.0,
		"is_coastal": true,
		"ocean_upwelling": 0.28,
		"treasury_cash": 100000,
	}
	var messages := NarrativeAiPromptBuilderScript.build_messages(cell_ctx, [], "延续海贸兴盛")
	_expect("Prompt builder generates system + user messages", messages.size() == 2)
	var img_prompt := NarrativeAiPromptBuilderScript.build_era_image_prompt(2, "Bronze ships in harbor", cell_ctx)
	_expect("Image prompt includes era art direction and no-text guard",
		img_prompt.find("Bronze Age") >= 0 and img_prompt.find("no text") >= 0)
	var fact_messages := NarrativeAiPromptBuilderScript.build_messages(
		cell_ctx, [], "", PackedStringArray(), PackedStringArray(),
		"民生压力上升（临海城，第 30 日）")
	_expect("Fact hint reaches the user prompt as a triggering-fact section",
		String((fact_messages[1] as Dictionary).get("content", "")).find("本次触发事实") >= 0)

	# 数字不一定是数据：只把温度读数改写成占位符，叙述里的数量词原样保留。
	var numeric_raw := {
		"title": "粮价飞涨",
		"body_text": "本地气温 34.2℃，粮价飞涨，三人因囤积被拘。",
		"options": [
			{
				"text": "开仓平粜",
				"outcomes": [{
					"probability_percent": 100,
					"outcome_title": "市面稍安",
					"effects": [],
				}],
			},
		],
	}
	var numeric_res := NarrativeAiValidatorScript.validate_and_sanitize(
		numeric_raw, cell_ctx, PackedStringArray(), "evt.ai.numeric")
	var numeric_event: Dictionary = numeric_res.get("event_dict", {})
	_expect("temperature readings become the placeholder without dropping the sentence",
		bool(numeric_res.get("ok", false))
		and String(numeric_event.get("body_text", "")) == "本地气温 {temperature}，粮价飞涨，三人因囤积被拘。")
	_expect("system prompt spells out the no-data-readings rule",
		String((messages[0] as Dictionary).get("content", "")).find("数据读数") >= 0
		and String((messages[0] as Dictionary).get("content", "")).find("{temperature}") >= 0)

	# Test AI validator against fenced JSON with out-of-bounds numbers and unknown modifier key
	var raw_llm_output := """```json
	{
	  "title": "海港异域商船抵岸",
	  "body_text": "顺着近岸洋流，一队满载铜料与香料的远方商船驶入临海城港湾，请求开市互易。",
	  "ai_visual_prompt": "Bronze age merchant ships docked at a busy delta port",
	  "tags": ["maritime", "trade"],
	  "options": [
	    {
	      "text": "设市互易，厚待远客",
	      "tooltip_hint": "促进贸易与生产",
	      "require_treasury_cash": 999999999,
	      "outcomes": [
	        {
	          "probability_percent": 75,
	          "outcome_title": "互市大兴",
	          "outcome_narrative": "商旅往来络绎不绝，本城百工受益。",
	          "effects": [
	            {
	              "kind": "CITY_MODIFIER",
	              "target_key": "non_existent_hallucinated_modifier_key",
	              "magnitude_percent": 500,
	              "duration_days": 99999
	            }
	          ]
	        },
	        {
	          "probability_percent": 25,
	          "outcome_title": "平平无奇",
	          "outcome_narrative": "小规模交易后商船离去。",
	          "effects": []
	        }
	      ]
	    }
	  ]
	}
	```"""
	var validated := NarrativeAiValidatorScript.validate_and_sanitize(raw_llm_output, cell_ctx)
	_expect("Validator accepts fenced JSON and sanitizes it", bool(validated.get("ok", false)))
	var ev_dict: Dictionary = validated.get("event_dict", {})
	var def := NarrativeEventDefinitionScript.from_dict(ev_dict)
	_expect("Sanitized AI event converts to NarrativeEventDefinition", def != null and def.is_ai_generated)
	var opt0: NarrativeOption = def.options[0] as NarrativeOption
	var probs := opt0.normalized_probabilities_q16()
	_expect("Validator normalizes outcome probabilities to sum to 65536",
		probs.size() == 2 and probs[0] + probs[1] == 65536)
	var out0: NarrativeOutcome = opt0.outcomes[0] as NarrativeOutcome
	var eff0: NarrativeEffectSpec = out0.effects[0] as NarrativeEffectSpec
	_expect("Hallucinated modifier key is safely mapped to a live ADD key and clamped",
		eff0.target_key == &"economy.city.building.manufacturing_output_factor"
		and eff0.duration_days <= 365)

	# Test malformed JSON rejection
	var bad_res := NarrativeAiValidatorScript.validate_and_sanitize("not a json at all {{{", cell_ctx)
	_expect("Validator rejects malformed JSON gracefully without crashing", not bool(bad_res.get("ok", true)))

	# Test NarrativeAiClient with mock responders (LLM + Image)
	var client := NarrativeAiClientScript.new()
	client.set_mock_llm_responder(Callable(self, "_mock_llm_reply"))
	client.set_mock_image_responder(Callable(self, "_mock_img_reply"))
	var gen_res: Dictionary = {}
	client.request_event_generation({
		"day": 30,
		"cell_idx": 9,
		"cell_ctx": cell_ctx,
		"ai_request_seq": 7,
	}, Callable(self, "_capture_dict").bind(gen_res))
	_expect("NarrativeAiClient mock LLM pipeline produces a valid definition",
		bool(gen_res.get("ok", false)) and gen_res.get("definition", null) != null)
	_expect("NarrativeAiClient echoes the request seq back for the service to claim",
		int(gen_res.get("ai_request_seq", -1)) == 7)

	var img_res_out: Dictionary = {}
	client.request_event_illustration("test_ai_event_img", "Ships in port", Callable(self, "_capture_dict").bind(img_res_out))
	_expect("NarrativeAiClient mock image pipeline caches PNG and creates Texture2D",
		bool(img_res_out.get("ok", false)) and img_res_out.get("texture", null) != null)
	client.free()


func _test_ai_fact_trigger_and_staleness() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var generator := FactGeneratorStub.new()
	var service := NarrativeEventServiceScript.new()
	service.configure(generator, null, null, null, 1, 424242, catalog)
	# 隔离脉冲通道，本用例只验证事实入口与回执事务。
	service.pulse_interval_days = 1000000
	service.ai_fact_chance_q16 = 65536
	service.ai_min_request_gap_days = 0

	var requests: Array = []
	service.ai_generation_requested.connect(
		func(spec: Dictionary) -> void: requests.append(spec.duplicate(true)))

	# 第 10 日：一条社会压力事实 → 立刻请求 AI，而不是等 20 天脉冲。
	generator.bus.batch = {
		"count": 1,
		"event_id": PackedInt64Array([1001]),
		"type": PackedInt32Array([8]),
		"cell_idx": PackedInt32Array([5]),
	}
	service.on_day_committed(10, true)
	_expect("gameplay fact triggers an immediate AI request", requests.size() == 1)
	if requests.size() != 1:
		return
	var spec: Dictionary = requests[0]
	var first_seq := int(spec.get("ai_request_seq", -1))
	_expect("AI fact request carries the triggering fact and a request seq",
		first_seq > 0 and String(spec.get("fact_hint", "")).find("民生压力上升") >= 0)

	var validated := NarrativeAiValidatorScript.validate_and_sanitize(
		_mock_llm_reply({}, []), {}, PackedStringArray(), "evt.ai.test_fact")
	var def = NarrativeEventDefinitionScript.from_dict(validated.get("event_dict", {}))
	var stale := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": first_seq, "definition": def}, 200)
	_expect("AI result past the staleness window is dropped instead of shown",
		String(stale.get("code", "")) == "ai_result_stale")

	# 第 300 日再来一条事实；回执在窗口内到达，应以到达日重新采样后入队。
	generator.bus.batch = {
		"count": 1,
		"event_id": PackedInt64Array([1002]),
		"type": PackedInt32Array([8]),
		"cell_idx": PackedInt32Array([5]),
	}
	service.on_day_committed(300, true)
	_expect("second qualifying fact requests another AI event", requests.size() == 2)
	if requests.size() != 2:
		return
	var second_seq := int((requests[1] as Dictionary).get("ai_request_seq", -1))
	var fresh := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": second_seq, "definition": def}, 301)
	_expect("in-window AI result lands as an AI-generated offer",
		bool(fresh.get("ok", false)) and service.has_active_offer()
		and bool(service.active_offer().get("is_ai_generated", false)))
	_expect("fresh AI offer is dated at arrival day, not request day",
		int(service.active_offer().get("day", -1)) == 301)

	# 第 600 日：请求在途时存档 → 读档后迟到的回执必须被丢弃（seq 不跨档）。
	generator.bus.batch = {
		"count": 1,
		"event_id": PackedInt64Array([1003]),
		"type": PackedInt32Array([8]),
		"cell_idx": PackedInt32Array([5]),
	}
	service.on_day_committed(600, true)
	_expect("third fact request stays pending for the save/load check", requests.size() == 3)
	if requests.size() == 3:
		var third_seq := int((requests[2] as Dictionary).get("ai_request_seq", -1))
		var restored := NarrativeEventServiceScript.new()
		restored.configure(null, null, null, null, 1, 424242, catalog)
		restored.restore_state(service.export_state())
		var late := restored.accept_ai_generation(
			{"ok": true, "ai_request_seq": third_seq, "definition": def}, 601)
		_expect("in-flight AI requests do not survive save/load",
			String(late.get("code", "")) == "ai_request_unknown")

	var unknown := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": 99999, "definition": def}, 602)
	_expect("AI result without a pending request is rejected",
		String(unknown.get("code", "")) == "ai_request_unknown")

	# 局势加权：同样的基础概率，危机格必须比平静格更容易被写到。
	var calm_ctx := {
		"shortage_good_ids": PackedStringArray(),
		"market_price_ratios_by_id": {},
		"satisfaction_norm": 0.80,
		"temperature_c": 18.0,
		"snow_cover": 0.0,
	}
	var crisis_ctx := {
		"shortage_good_ids": PackedStringArray(["grain", "fish"]),
		"market_price_ratios_by_id": {"grain": 1.9, "fish": 1.5},
		"satisfaction_norm": 0.32,
		"temperature_c": 35.0,
		"snow_cover": 0.0,
	}
	var calm_score := NarrativeEventServiceScript.situation_pressure_score(calm_ctx)
	var crisis_score := NarrativeEventServiceScript.situation_pressure_score(crisis_ctx)
	_expect("situation pressure rises with shortages, price spikes, discontent and heat",
		calm_score == 0 and crisis_score >= 80)
	_expect("situation scaling stays inside [base, ceiling]",
		service._ai_chance_q16(2621, calm_ctx) == 2621
		and service._ai_chance_q16(2621, crisis_ctx) > 2621
		and service._ai_chance_q16(2621, crisis_ctx) <= service.ai_max_chance_q16)


func _test_state_probe_and_ai_pool() -> void:
	var probes := NarrativeStateProbeCatalogScript.build_default_probes()
	_expect("default state probes cover shortage, discontent and drought",
		probes.size() >= 3
		and String(probes[0].state_id) == "state.market.food_shortage")
	if probes.is_empty():
		return
	var shortage_probe = probes[0]
	_expect("default shortage probe is judged by the engine, not the model",
		not shortage_probe.matches(
			{"era_index": 1, "population": 30, "market_price_ratios_by_id": {"grain": 1.1}})
		and shortage_probe.matches(
			{"era_index": 1, "population": 30, "market_price_ratios_by_id": {"grain": 1.6}}))

	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var generator := StateGeneratorStub.new()
	var service := NarrativeEventServiceScript.new()
	service.configure(generator, null, null, null, 1, 5150, catalog)
	service.pulse_interval_days = 1000000
	service.state_probe_interval_days = 1
	service.ai_min_request_gap_days = 0
	service.set_state_probes([_build_shortage_probe()])

	var requests: Array = []
	service.ai_generation_requested.connect(
		func(spec: Dictionary) -> void: requests.append(spec.duplicate(true)))
	var def = _build_ai_definition_for_test("evt.ai.state_test")

	for d in range(1, 5):
		service.on_day_committed(d, true)
	_expect("state probe tracks dwell before spending an AI call", requests.is_empty())

	service.on_day_committed(5, true)
	_expect("state probe requests AI once dwell is met", requests.size() == 1)
	if requests.size() != 1:
		return
	var spec: Dictionary = requests[0]
	_expect("state request carries the standing state and its recent digest",
		String(spec.get("state_id", "")) == "state.market.test_shortage"
		and String(spec.get("state_hint", "")).find("粮食紧缺") >= 0)

	# 回执到达时状态已破：进池，不弹。
	generator.economy.grain_price = 100
	var pooled := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": int(spec.get("ai_request_seq", -1)), "definition": def}, 6)
	_expect("AI result is pooled when the state no longer holds",
		String(pooled.get("code", "")) == "ai_event_pooled"
		and service.ai_event_pool().size() == 1)
	_expect("pooled event does not open a popup", not service.has_active_offer())

	# 状态恢复：直接从池子出队，不再花一次 API。
	generator.economy.grain_price = 200
	service.on_day_committed(7, true)
	_expect("pooled event fires when the same state returns",
		service.has_active_offer() and requests.size() == 1)
	_expect("pool is emptied after a successful fire", service.ai_event_pool().is_empty())

	generator.economy.grain_price = 100
	for i in range(3):
		service._stash_pooled_event("state.market.test_shortage", def, 5, 10 + i)
	_expect("pool keeps at most two entries per state",
		service.ai_event_pool().size() == NarrativeEventServiceScript.AI_POOL_MAX_PER_STATE)

	var restored := NarrativeEventServiceScript.new()
	restored.configure(null, null, null, null, 1, 5150, catalog)
	restored.restore_state(service.export_state())
	_expect("pooled AI events survive save/load", restored.ai_event_pool().size() == 2)


func _build_shortage_probe():
	var probe = NarrativeStateProbeScript.new()
	probe.state_id = &"state.market.test_shortage"
	probe.display_name = "粮食紧缺"
	probe.prompt_hint = "粮价高企，居民囤积"
	probe.dwell_days = 4
	probe.cooldown_days = 0
	probe.conditions.append(NarrativeConditionScript.from_dict({
		"op": NarrativeConditionScript.Op.MARKET_GOOD_PRICE_RATIO_GTE,
		"target_key": "grain",
		"float_value": 1.35,
	}))
	return probe


func _build_ai_definition_for_test(event_id: String):
	var validated := NarrativeAiValidatorScript.validate_and_sanitize(
		_mock_llm_reply({}, []), {}, PackedStringArray(), event_id)
	return NarrativeEventDefinitionScript.from_dict(validated.get("event_dict", {}))


func _test_ui_dialog_and_chronicle_panel() -> void:
	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 999, catalog)
	var def := catalog.get_event(&"evt.climate.severe_drought")
	var offer := service.enqueue_event_offer(def, 2, 15, &"", true, {
		"cell_idx": 2, "settlement_name": "洛邑", "landform_name": "平原", "temperature": 30.0
	})
	dialog.present_offer(offer)
	_expect("NarrativeEventDialog opens and displays formatted offer title",
		dialog.is_offer_open() and dialog._title_label.text.find("洛邑") >= 0)
	# 题头只留日历：不再堆聚落/地貌/气温。
	_expect("event kicker shows only the calendar date",
		dialog._kicker_label.text == String(offer.get("date_text", ""))
		and dialog._kicker_label.text.find("°C") < 0
		and dialog._kicker_label.text.find("平原") < 0)
	_expect("category tags are no longer rendered in the header",
		dialog._tags_row.get_child_count() == 0)

	var res := service.choose_option(int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 0, 16)
	dialog.show_outcome(res)
	_expect("NarrativeEventDialog displays rolled outcome view",
		dialog._outcome_panel.visible and not dialog._options_vbox.visible)
	dialog.close_offer()
	_expect("NarrativeEventDialog closes cleanly", not dialog.is_offer_open())

	# AI 事件：题头仍然只有日期，来源改挂一枚纸签，不挤回题头。
	var ai_offer := service.enqueue_event_offer(
		_build_ai_definition_for_test("evt.ai.dialog_pill"), 3, 20, &"", true)
	dialog.present_offer(ai_offer)
	var has_ai_tag := false
	for child in dialog._tags_row.get_children():
		if child is Label and (child as Label).text == "AI 生成":
			has_ai_tag = true
	_expect("AI events keep a paper tag while the kicker stays calendar-only",
		has_ai_tag and dialog._tags_row.get_child_count() == 1
		and dialog._kicker_label.text.find("°C") < 0)
	dialog.close_offer()
	dialog.free()

	var chron := NarrativeChroniclePanelScript.new()
	root.add_child(chron)
	chron.open_panel(service.get_chronicle())
	_expect("NarrativeChroniclePanel opens and renders recorded history",
		chron.is_panel_open() and chron._records.size() == service.chronicle_total_count()
		and chron._list_vbox.get_child_count() > 0)
	_expect("chronicle panel no longer hosts the AI configuration entry",
		_find_button_with_text(chron, "AI 配置") == null)
	chron.close_panel()
	chron.free()


func _find_button_with_text(node: Node, text_value: String) -> Button:
	if node is Button and (node as Button).text == text_value:
		return node as Button
	for child in node.get_children():
		var found := _find_button_with_text(child, text_value)
		if found != null:
			return found
	return null


func _test_player_controller_integration() -> void:
	var controller := PlayerControllerScript.new()
	_expect("PlayerController registers narrative.choose in SUPPORTED_COMMANDS",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"narrative.choose"))
	var state := controller.capture_view_state()
	_expect("PlayerController capture_view_state includes narrative_event_view",
		state.has("narrative_event_view"))
	controller.free()


func _mock_llm_reply(_spec: Dictionary, _msgs: Array) -> String:
	return """{
	  "title": "海港异域商船抵岸",
	  "body_text": "顺着近岸洋流，一队满载铜料与香料的远方商船驶入临海城港湾，请求开市互易。",
	  "ai_visual_prompt": "Bronze age merchant ships docked at a busy delta port",
	  "tags": ["maritime", "trade"],
	  "options": [
	    {
	      "text": "设市互易，厚待远客",
	      "outcomes": [
	        {
	          "probability_percent": 100,
	          "outcome_title": "互市大兴",
	          "outcome_narrative": "商旅往来络绎不绝，本城百工受益。",
	          "effects": [
	            {
	              "kind": "CITY_MODIFIER",
	              "target_key": "family.city.production_boost",
	              "magnitude_percent": 15,
	              "duration_days": 90
	            }
	          ]
	        }
	      ]
	    }
	  ]
	}"""


func _mock_img_reply(_ev_id: String, _prompt: String) -> PackedByteArray:
	var dummy_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	dummy_img.fill(Color(0.8, 0.6, 0.3, 1.0))
	return dummy_img.save_png_to_buffer()


func _capture_dict(res: Dictionary, target: Dictionary) -> void:
	target.merge(res, true)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
