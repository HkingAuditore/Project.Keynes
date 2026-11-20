extends "res://tests/support/runtime_narrative_scenario.gd"

const NarrativeStateProbeCatalogScript = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")
const NarrativeAiPromptBuilderScript = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")


func _run() -> void:
	_test_probes()
	_test_prompt_context()
	# A notification about an actual declaration is independent of the
	# story that uses the same fact.
	var mask := 255 | 1 << (8 + 1)
	if await _start_story({"event_pause_mask": mask}):
		await _check_war_notice()
	await _close_story()
	if await _start_story({"event_pause_mask": 255}):
		await _check_batched_war_notice()
	await _close_story()
	print("narrative war bridge: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _declare_war() -> bool:
	var map := story_host.current_map()
	var enemy := 0
	for cell in map.cell_count():
		if map.country_slot_arr[cell] > 0:
			enemy = int(story_ext.get_country_cell_summary(cell).get("country_handle", 0))
			break
	_expect("the scenario has a foreign country", enemy != 0)
	var military = story_host.get_generator().get_military_facade()
	var order: Dictionary = military.submit([{"op": "war.declare_forced", "country": enemy,
		"other": story_player, "effective_day": 2}])
	var dated := bool(order.get("ok", false)) and int(order.get("effective_day", -1)) == 2
	_expect("the permitted declaration is dated", dated)
	return dated


func _check_war_notice() -> void:
	if not _declare_war():
		return
	if not await _advance_story(3):
		return
	var offer := story_service.active_offer()
	_expect("the player defender receives a stopping notice",
		offer.get("event_id") == "military.war_declared.player_defender"
		and bool(offer.get("notice_only", false)))
	var facts: Dictionary = story_ext.poll_gameplay_events({"type": 40})
	var days: PackedInt64Array = facts.get("tick", PackedInt64Array())
	_expect("the committed declaration carries the military settlement day", days == PackedInt64Array([2]))
	_choose_story(0)
	if await _advance_story(4):
		_expect("confirming a notice records it on the following day",
			not _story_records().is_empty() and int(_story_records()[0].resolved_day) == 4)


func _check_batched_war_notice() -> void:
	if not _declare_war():
		return
	story_host.set_process(false)
	_publish_day(story_host, story_clock, 4)
	for _frame in range(MAX_SLICES_PER_DAY):
		if story_ext.runtime_committed_day() >= 4:
			break
		await process_frame
	_expect("a non-pausing notice allows the whole batch to settle",
		story_ext.runtime_committed_day() == 4 and story_host._runtime_commit_day < 3)
	story_host._consume_runtime_commit_if_ready()
	var records: Array = story_host._runtime_last_commit.get("days", [])
	var notices := story_service.chronicle_for_display(-1).filter(func(row: Dictionary) -> bool:
		return row.event_id == "military.war_declared.player_defender")
	_expect("the notice survives skipping the display of its day exactly once",
		records.size() == 4 and notices.size() == 1 and notices[0].day == 3
		and not story_service.has_active_offer())
	var restored_service := NarrativeEventService.new()
	restored_service.restore_notice_history(story_controller.capture_view_state().narrative_notices)
	_expect("the player view preserves the notification after restore",
		restored_service.chronicle_for_display(-1) == story_service.chronicle_for_display(-1))


func _test_probes() -> void:
	var probes: Array = NarrativeStateProbeCatalogScript.build_default_probes()
	var ids := PackedStringArray()
	for probe in probes:
		ids.append(String(probe.state_id))
	_expect("war probes are registered",
		ids.has("state.war.homefront") and ids.has("state.war.defeat"))
	_expect("probe catalog grew to five", ids.size() == 5)


func _test_prompt_context() -> void:
	var ctx := {
		"era_index": 5,
		"era_name": "文艺复兴与航海时代",
		"family_available": true,
		"primary_family_name": "西街周氏",
		"primary_family_population_share": 0.32,
		"primary_family_prestige": 3,
		"primary_family_owned_buildings": 2,
		"primary_family_notable_people": 1,
		"primary_family_trait_names": PackedStringArray(["学术赞助", "商路人脉"]),
		"military_available": true,
		"at_war": true,
		"war_count": 1,
		"soldiers_total": 520,
		"soldiers_in_armies": 300,
		"war_score_min_q16": -40000,
		"war_losses_total": 120,
		"technologies": PackedStringArray(["tech.irrigation", "tech.gunpowder_weapons"]),
	}
	var messages := NarrativeAiPromptBuilderScript.build_messages(ctx, [], "")
	_expect("prompt builder still returns two messages", messages.size() == 2)
	if messages.size() < 2:
		return
	var user := String((messages[1] as Dictionary).get("content", ""))
	_expect("AI prompt carries family structure without the name",
		user.contains("本地最大族") and user.contains("门风")
		and not user.contains("西街周氏") and user.contains("不要写族名"))
	_expect("AI prompt carries the war situation", user.contains("战事")
		and user.contains("在战"))
	_expect("AI prompt carries the technology list", user.contains("已掌握科技")
		and user.contains("tech.irrigation"))

	var base_event := {
		"title": "粮价飞涨",
		"body_text": "粮价飞涨，三人因囤积被拘。",
		"options": [{
			"text": "开仓平粜",
			"outcomes": [{
				"probability_percent": 100,
				"outcome_title": "市面稍安",
				"effects": [],
			}],
		}],
	}
	var chinese_digits := NarrativeAiValidatorScript.validate_and_sanitize(base_event, {})
	_expect("validator accepts Chinese numerals", bool(chinese_digits.get("ok", false)))

	var arabic_event := base_event.duplicate(true)
	arabic_event["body_text"] = "粮价飞涨，3 人因囤积被拘。"
	var arabic_digits := NarrativeAiValidatorScript.validate_and_sanitize(arabic_event, {})
	_expect("validator rejects Arabic digits in narrative",
		not bool(arabic_digits.get("ok", true))
		and String(arabic_digits.get("code", "")) == "arabic_digits_in_narrative")
