extends SceneTree

## 真实生成探针：用当前 prompt 打一次真模型，把原文与校验后的结果并排打出来。
##
##   <godot_console> --headless --path . --script tools/narrative_live_probe.gd
##
## **会联网、会消耗调用额度**，只在手工验语气时跑，不进测试套件。
## 读 `user://ai_credentials.cfg` 的 llm_api_key 与 `user://settings.cfg` 的 endpoint/model；
## 没有 key 会直接退出，不会尝试匿名调用。
## 与 `narrative_prompt_probe.gd` 的分工：那个只看「模型看见了什么」，这个看「模型写成了什么」。

const PromptBuilder = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")
const Validator = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const Credentials = preload("res://scripts/narrative/ai/narrative_ai_credentials.gd")
const AiClient = preload("res://scripts/narrative/ai/narrative_ai_client.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	# `_initialize()` 期间 root 还没进树，HTTPRequest 会报 ERR_UNCONFIGURED。
	await process_frame
	var territory := PackedInt32Array()
	for i in range(23):
		territory.append(100 + i)
	var ctx := {
		"day": 1284, "country_name": "临漳", "settlement_name": "柳湾", "cell_idx": 431,
		"era_index": 4, "era_name": "帝国与封建时代",
		"terrain_name": "平原", "landform_name": "河漫滩", "elevation": 0.32,
		"has_river": true, "is_coastal": false,
		"temperature_c": 9.4, "moisture": 0.61, "precipitation": 0.18, "snow_cover": 0.0,
		"ocean_current_speed": 0.0, "ocean_upwelling": 0.0,
		"population": 380, "satisfaction_norm": 0.54,
		"treasury_cash": 12400, "primary_cohort_cash": 860,
		"territory_cells": territory,
		"building_counts_by_id": {"farm": 6, "mill": 2, "granary": 1, "market": 1},
		"market_stocks_by_id": {"grain": 4200, "timber": 300},
		"market_price_ratios_by_id": {"grain": 1.42, "timber": 0.95},
		"shortage_good_ids": ["grain"],
		"natural_resources_by_id": {"clay": 1200},
		"human_context_available": true,
		"dominant_profession_name": "佃农", "dominant_profession_share": 0.44,
		"subsistence_shortfall_ratio": 0.17, "unemployment_ratio": 0.05,
		"primary_cohort_profession_name": "佃农",
		"family_available": true, "primary_family_population_share": 0.21,
		"primary_family_prestige": 3, "primary_family_owned_buildings": 4,
		"primary_family_notable_people": 2,
		"primary_family_trait_names": ["勤俭", "重诺"],
		"military_available": true, "at_war": true, "war_count": 1,
		"soldiers_total": 640, "soldiers_in_armies": 410,
		"war_score_min_q16": 32768, "war_losses_total": 137,
		"technologies": ["three_field", "water_mill"], "story_flags": {},
		"neighbor_settlements": [
			{"cell_idx": 430, "name": "上河渡", "population": 210, "shortage_good": "grain"},
			{"cell_idx": 432, "name": "石桥铺", "population": 96, "shortage_good": ""},
			{"cell_idx": 415, "name": "柳湾北庄", "population": 54, "shortage_good": "salt"},
		],
	}
	var chronicle: Array = [
		{"day": 1201, "title": "粮价飞涨", "outcome_title": "官仓开仓"},
		{"day": 1240, "title": "北边来的车", "outcome_title": "闭门不纳"},
	]
	var msgs := PromptBuilder.build_messages(ctx, chronicle, "")

	var keys := Credentials.load_keys("user://ai_credentials.cfg",
		OS.get_environment("PK_AI_LLM_API_KEY"), "")
	var api_key := String(keys.get("llm_api_key", ""))
	if api_key.is_empty():
		print("[probe] 没有可用的 LLM key")
		quit()
		return
	var endpoint := "https://api.deepseek.com/v1/chat/completions"
	var model := "deepseek-chat"
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		endpoint = String(cfg.get_value("settings", "ai_llm_base_url", endpoint))
		model = String(cfg.get_value("settings", "ai_llm_model", model))
	endpoint = AiClient.normalize_llm_endpoint(endpoint)
	print("[probe] model=%s endpoint=%s" % [model, endpoint])

	var http := HTTPRequest.new()
	root.add_child(http)
	http.timeout = 90.0
	var body := JSON.stringify({
		"model": model, "messages": msgs, "temperature": 0.75,
		"response_format": {"type": "json_object"},
	})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key,
	])
	if http.request(endpoint, headers, HTTPClient.METHOD_POST, body) != OK:
		print("[probe] 请求发起失败")
		quit()
		return
	var res: Array = await http.request_completed
	http.queue_free()
	var http_code := int(res[1])
	var text := (res[3] as PackedByteArray).get_string_from_utf8()
	print("[probe] http=%d payload=%d bytes" % [http_code, text.length()])
	if http_code < 200 or http_code >= 300:
		print(text.left(800))
		quit()
		return

	var envelope := JSON.new()
	var content := text
	if envelope.parse(text) == OK and envelope.data is Dictionary:
		var choices: Variant = (envelope.data as Dictionary).get("choices", [])
		if choices is Array and not (choices as Array).is_empty():
			var msg: Variant = (choices[0] as Dictionary).get("message", {})
			if msg is Dictionary:
				content = String((msg as Dictionary).get("content", ""))

	print("---------- RAW ----------")
	print(content)
	var validated := Validator.validate_and_sanitize(
		content, ctx, "evt.ai.live_probe")
	print("---------- VALIDATED ok=%s code=%s ----------" % [
		validated.get("ok", false), validated.get("code", "")])
	if not bool(validated.get("ok", false)):
		print("reason: %s" % String(validated.get("reason", "")))
		quit()
		return
	var event: Dictionary = validated.get("event_dict", {})
	print("title: %s" % String(event.get("title", "")))
	print("body(%d chars): %s" % [
		String(event.get("body_text", "")).length(), String(event.get("body_text", ""))])
	for opt in (event.get("options", []) as Array):
		print("option: %s" % String((opt as Dictionary).get("text", "")))
		for outcome in ((opt as Dictionary).get("outcomes", []) as Array):
			print("   -> %s | %s" % [
				String((outcome as Dictionary).get("outcome_title", "")),
				String((outcome as Dictionary).get("outcome_narrative", "")).left(60)])
	quit()
