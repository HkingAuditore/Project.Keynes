extends SceneTree

## 叙事 prompt 快照探针：改完 prompt 后跑一次，肉眼确认模型到底看见了什么。
##
##   <godot_console> --headless --path . --script tools/narrative_prompt_probe.gd
##
## 用一份固定的城镇快照（佃农为主、粮价高、在战、有邻城）构造 prompt，
## 打印 system / user 全文与字符数。不联网、不读存档、不产生副作用。
## 样本刻意包含「人群构成 + 民生压力 + 邻城」三样，缺任何一样都会在输出里露出来。

const PromptBuilder = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")


func _initialize() -> void:
	var territory := PackedInt32Array()
	for i in range(23):
		territory.append(100 + i)
	var ctx := {
		"day": 1284,
		"country_name": "临漳",
		"settlement_name": "柳湾",
		"cell_idx": 431,
		"era_index": 4,
		"era_name": "帝国与封建时代",
		"terrain_name": "平原",
		"landform_name": "河漫滩",
		"elevation": 0.32,
		"has_river": true,
		"is_coastal": false,
		"temperature_c": 9.4,
		"moisture": 0.61,
		"precipitation": 0.18,
		"snow_cover": 0.0,
		"ocean_current_speed": 0.0,
		"ocean_upwelling": 0.0,
		"population": 380,
		"satisfaction_norm": 0.54,
		"treasury_cash": 12400,
		"primary_cohort_cash": 860,
		"territory_cells": territory,
		"building_counts_by_id": {"farm": 6, "mill": 2, "granary": 1, "market": 1},
		"market_stocks_by_id": {"grain": 4200, "timber": 300},
		"market_price_ratios_by_id": {"grain": 1.42, "timber": 0.95},
		"shortage_good_ids": ["grain"],
		"natural_resources_by_id": {"clay": 1200},
		"human_context_available": true,
		"dominant_profession_name": "佃农",
		"dominant_profession_share": 0.44,
		"subsistence_shortfall_ratio": 0.17,
		"unemployment_ratio": 0.05,
		"primary_cohort_profession_name": "佃农",
		"family_available": true,
		"primary_family_population_share": 0.21,
		"primary_family_prestige": 3,
		"primary_family_owned_buildings": 4,
		"primary_family_notable_people": 2,
		"primary_family_trait_names": ["勤俭", "重诺"],
		"military_available": true,
		"at_war": true,
		"war_count": 1,
		"soldiers_total": 640,
		"soldiers_in_armies": 410,
		"war_score_min_q16": 32768,
		"war_losses_total": 137,
		"technologies": ["three_field", "water_mill"],
		"story_flags": {},
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
	var msgs := PromptBuilder.build_messages(
		ctx, chronicle, "", PackedStringArray(), PackedStringArray(), "", "")
	for m in msgs:
		var role := String(m.get("role", "?"))
		var content := String(m.get("content", ""))
		print("========== %s (%d chars) ==========" % [role, content.length()])
		print(content)
	print("========== total: %d chars ==========" % (
		String((msgs[0] as Dictionary).get("content", "")).length()
		+ String((msgs[1] as Dictionary).get("content", "")).length()))
	quit()
