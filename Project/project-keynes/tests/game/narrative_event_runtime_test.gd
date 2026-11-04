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
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_deterministic_rng()
	_test_multidimensional_conditions_and_catalog()
	_test_event_chain_and_weight_bias_and_chronicle()
	_test_save_restore_roundtrip()
	_test_ai_sandbox_and_image_cache()
	_test_ui_dialog_and_chronicle_panel()
	_test_player_controller_integration()
	print("=== narrative event runtime test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


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
	_expect("Hallucinated modifier key is safely mapped to whitelisted fallback and clamped",
		eff0.target_key == &"family.city.production_boost"
		and eff0.duration_days <= 365)

	# Test malformed JSON rejection
	var bad_res := NarrativeAiValidatorScript.validate_and_sanitize("not a json at all {{{", cell_ctx)
	_expect("Validator rejects malformed JSON gracefully without crashing", not bool(bad_res.get("ok", true)))

	# Test NarrativeAiClient with mock responders (LLM + Image)
	var client := NarrativeAiClientScript.new()
	client.set_mock_llm_responder(Callable(self, "_mock_llm_reply"))
	client.set_mock_image_responder(Callable(self, "_mock_img_reply"))
	var gen_res: Dictionary = {}
	client.request_event_generation({"day": 30, "cell_idx": 9, "cell_ctx": cell_ctx}, Callable(self, "_capture_dict").bind(gen_res))
	_expect("NarrativeAiClient mock LLM pipeline produces a valid definition",
		bool(gen_res.get("ok", false)) and gen_res.get("definition", null) != null)

	var img_res_out: Dictionary = {}
	client.request_event_illustration("test_ai_event_img", "Ships in port", Callable(self, "_capture_dict").bind(img_res_out))
	_expect("NarrativeAiClient mock image pipeline caches PNG and creates Texture2D",
		bool(img_res_out.get("ok", false)) and img_res_out.get("texture", null) != null)
	client.free()


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

	var res := service.choose_option(int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 0, 16)
	dialog.show_outcome(res)
	_expect("NarrativeEventDialog displays rolled outcome view",
		dialog._outcome_panel.visible and not dialog._options_vbox.visible)
	dialog.close_offer()
	_expect("NarrativeEventDialog closes cleanly", not dialog.is_offer_open())
	dialog.free()

	var chron := NarrativeChroniclePanelScript.new()
	root.add_child(chron)
	chron.open_panel(service.get_chronicle())
	_expect("NarrativeChroniclePanel opens and renders recorded history",
		chron.is_panel_open() and not chron._empty_label.visible)
	chron.close_panel()
	chron.free()


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
