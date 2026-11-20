extends "res://tests/support/runtime_narrative_scenario.gd"

const NarrativeRngScript = preload("res://scripts/narrative/narrative_rng.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeWeightRuleScript = preload("res://scripts/narrative/narrative_weight_rule.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeOutcomeScript = preload("res://scripts/narrative/narrative_outcome.gd")
const NarrativeOptionScript = preload("res://scripts/narrative/narrative_option.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeAiPromptBuilderScript = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")
const NarrativeStateProbeScript = preload("res://scripts/narrative/narrative_state_probe.gd")
const NarrativeStateProbeCatalogScript = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")


func _run() -> void:
	_test_deterministic_rng()
	_test_multidimensional_conditions_and_catalog()
	_test_state_probe_contract()
	_test_ai_sandbox_and_image_cache()
	_test_player_controller_integration()
	await _test_story_and_diary()
	await _test_ai_fixed_day()
	print("narrative event runtime: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _test_ai_fixed_day() -> void:
	if await _start_story({"ai_enabled": true, "scheduled_events": [
		{"due_day": 4, "chain_id": "ai_fixture", "ai_prompt_hint": "记录开荒。"},
	]}, [&"evt.chain.ancient_foundry_legacy"]):
		await _check_ai_fixed_day()
	await _close_story()


func _check_ai_fixed_day() -> void:
	if not await _advance_story(1):
		return
	var bus: GameplayEventBus = story_host.get_generator().get_gameplay_event_bus()
	var view := bus.story_view()
	var request: Dictionary = view.get("ai_request", {})
	var landing_day := 1 + int(view.ai_reply_delay_days)
	_expect("AI request snapshots its committed cell and fixed landing day",
		request.get("day") == 1 and request.get("effective_day") == landing_day
		and request.get("cell_ctx", {}).get("day") == 1 and request.get("cell_idx") == story_cell)
	if request.is_empty():
		return
	var setting := bus.submit_story_request(&"ai_enabled", {"enabled": false})
	var seal_day := int(request.day) + 1
	_expect("AI off is dated and leaves the already-issued request intact",
		setting.get("ok") == true and setting.get("effective_day") == seal_day
		and bus.story_view().get("ai_enabled") == true)
	if not await _advance_story(seal_day):
		return
	_expect("AI off takes effect on the admitted day",
		bus.story_view().get("ai_enabled") == false and bus.story_view().get("ai_request") == request)
	print("NARRATIVE_AI_SETTING day=", setting.get("effective_day"),
		" inline=", story_host._native_daily_inline_active)
	if not await _advance_story(landing_day - 1):
		return
	_expect("no offer lands early and the AI setting is now disabled",
		not story_service.has_active_offer() and bus.story_view().get("ai_enabled") == false)
	_publish_day(story_host, story_clock, landing_day)
	if story_host._native_daily_inline_active:
		_expect("inline waits at the same external-input boundary",
			story_host._runtime_native_daily_inline_last.get("reason") == "narrative_external_input_required")
	var frames := Engine.get_process_frames()
	OS.delay_msec(HOLD_MSEC)
	_expect("admitted landing day cannot advance without input",
		Engine.get_process_frames() == frames and story_ext.runtime_committed_day() == landing_day - 1
		and bus.story_view().get("waiting_for_external_input_day") == landing_day)
	var reply := {
		"ai_request_seq": request.get("ai_request_seq"), "effective_day": landing_day - 1,
		"ok": true, "definition": _story_fixture_event("evt.ai.fixture", []),
	}
	_expect("reply dated for another day is rejected",
		bus.submit_story_request(&"ai_result", reply).get("code") == "ai_reply_day_mismatch")
	reply.effective_day = landing_day
	_expect("reply resumes the same scheduled day",
		bus.submit_story_request(&"ai_result", reply).get("effective_day") == landing_day)
	if not await _advance_story(landing_day):
		return
	var offer := story_service.active_offer()
	_expect("AI candidate lands on the scheduled day even after the switch was turned off",
		offer.get("event_id") == "evt.ai.fixture" and offer.get("day") == landing_day
		and is_equal_approx(float(offer.get("temperature", INF)), story_host.current_map().temp_arr[story_cell]))
	print("NARRATIVE_AI_FIXED_DAY request=1 landed=", landing_day)


func _test_state_probe_contract() -> void:
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


func _test_story_and_diary() -> void:
	if await _start_story({"scheduled_events": [
		{"due_day": 2, "event_id": "evt.climate.severe_drought"},
		{"due_day": 2, "event_id": "evt.ages.first_seed"},
	]}):
		await _check_story_and_diary()
	await _close_story()


func _check_story_and_diary() -> void:
	if not await _advance_story(2):
		return
	var offer := story_service.active_offer()
	_expect("the drought is the only active offer and the seed is queued",
		offer.get("event_id") == "evt.climate.severe_drought" and story_service.ready_queue_size() == 1)
	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	dialog.present_offer(offer)
	_expect("the dialog prints the committed title and a calendar-only heading", dialog.is_offer_open()
		and dialog._title_label.text == String(offer.get("title", ""))
		and dialog._kicker_label.text == String(offer.get("date_text", ""))
		and dialog._tags_row.get_child_count() == 0)
	_choose_story(0)
	if not await _advance_story(3):
		dialog.free()
		return
	var records := _story_records()
	_expect("the next-day record identifies the chosen option and rolled outcome",
		records.size() == 1 and int(records[0].resolved_day) == 3
		and int(records[0].chosen_option_index) == 0 and int(records[0].rolled_outcome_index) == 0)
	dialog.close_offer()
	if not records.is_empty():
		dialog.show_outcome({"record": records[0]})
		_expect("the closed dialog reopens with the published outcome", dialog.is_offer_open()
			and dialog._title_label.text == String(records[0].title)
			and dialog._outcome_panel.visible and not dialog._options_vbox.visible)
	dialog.close_offer()
	_expect("the dialog closes", not dialog.is_offer_open())
	dialog.free()

	_expect("the queued event is promoted after the previous choice settles",
		story_service.active_offer().get("event_id") == "evt.ages.first_seed")
	var diary := NarrativeChroniclePanelScript.new()
	root.add_child(diary)
	diary.open_panel(records)
	_expect("the chronicle renders the committed history", diary.is_panel_open()
		and diary._records.size() == records.size() and diary._list_vbox.get_child_count() > 0)
	_expect("AI configuration lives outside the chronicle", _find_button_with_text(diary, "AI 配置") == null)
	diary.close_panel()
	diary.free()


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

	var hot_dry_ctx := {
		"cell_idx": 12,
		"era_index": 1,
		"temperature": 31.0,
		"moisture": 0.25,
		"population": 25,
		"is_coastal": false,
	}
	var w_drought := _authored_weight(drought_def, hot_dry_ctx)
	var w_ocean_inland := _authored_weight(ocean_def, hot_dry_ctx)
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
	var w_ocean_coastal := _authored_weight(ocean_def, coastal_upwelling_ctx)
	_expect("coastal cell with strong upwelling and current gets high weight", w_ocean_coastal > ocean_def.base_weight * 2)


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
		String((messages[0] as Dictionary).get("content", "")).find("阿拉伯数字") >= 0
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
