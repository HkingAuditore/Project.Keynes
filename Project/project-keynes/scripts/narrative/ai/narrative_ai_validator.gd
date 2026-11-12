class_name NarrativeAiValidator
extends RefCounted

## Parses raw LLM JSON output (stripping markdown fences if present) and validates
## and sanitizes it into a safe Dictionary compatible with NarrativeEventDefinition.from_dict().

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")

const Q16_ONE: int = 65536
const MIN_MAGNITUDE_Q16: int = 3277  # 5% of 65536
const MAX_MAGNITUDE_Q16: int = 32768 # 50% of 65536
const MIN_DURATION_DAYS: int = 15
const MAX_DURATION_DAYS: int = 365
const MIN_RATIO_BP: int = 50         # 0.5%
const MAX_RATIO_BP: int = 2000       # 20%

const SAFE_CITY_MODIFIER_KEYS := {
	"family.city.production_boost": "economy.city.building.manufacturing_output_factor",
	"family.city.hunting_output_boost": "economy.city.good.game_meat.output_factor",
	"family.city.agriculture_output_boost": "economy.city.building.agriculture_output_factor",
	"family.city.extractive_output_boost": "economy.city.building.extractive_output_factor",
	"family.city.manufacturing_output_boost": "economy.city.building.manufacturing_output_factor",
	"family.city.energy_output_boost": "economy.city.building.energy_output_factor",
	"family.city.knowledge_output_boost": "economy.city.building.knowledge_output_factor",
	"family.city.birth_boost": "economy.city.birth_factor",
	"family.city.birth_cut": "economy.city.birth_factor.cut",
	"family.city.Birth_cut": "economy.city.birth_factor.cut",
	"family.city.trade_output_boost": "economy.city.building.manufacturing_output_factor",
	"family.city.food_consumption_boost": "economy.city.need.staple_food.consumption_factor",
	"family.city.austere_consumption": "economy.city.need.staple_food.consumption_factor.cut",
	"family.city.staple_consumption_cut": "economy.city.need.staple_food.consumption_factor.cut",
	"economy.city.output_factor": "economy.city.building.manufacturing_output_factor",
	"economy.city.output_factor.cut": "economy.city.output_factor.cut",
	"economy.city.building.agriculture_output_factor": "economy.city.building.agriculture_output_factor",
	"economy.city.building.agriculture_output_factor.cut": "economy.city.building.agriculture_output_factor.cut",
	"economy.city.building.extractive_output_factor": "economy.city.building.extractive_output_factor",
	"economy.city.building.extractive_output_factor.cut": "economy.city.building.extractive_output_factor.cut",
	"economy.city.building.manufacturing_output_factor": "economy.city.building.manufacturing_output_factor",
	"economy.city.building.manufacturing_output_factor.cut": "economy.city.building.manufacturing_output_factor.cut",
	"economy.city.building.energy_output_factor": "economy.city.building.energy_output_factor",
	"economy.city.building.energy_output_factor.cut": "economy.city.building.energy_output_factor.cut",
	"economy.city.building.knowledge_output_factor": "economy.city.building.knowledge_output_factor",
	"economy.city.building.knowledge_output_factor.cut": "economy.city.building.knowledge_output_factor.cut",
	"economy.city.birth_factor": "economy.city.birth_factor",
	"economy.city.birth_factor.cut": "economy.city.birth_factor.cut",
}

const SAFE_COUNTRY_MODIFIER_KEYS := {
	"country.economic_mobilization": "ideology.country.output.manufacturing_factor.gain",
	"ideology.country.output.agriculture_factor.gain": "ideology.country.output.agriculture_factor.gain",
	"ideology.country.output.extractive_factor.gain": "ideology.country.output.extractive_factor.gain",
	"ideology.country.output.manufacturing_factor.gain": "ideology.country.output.manufacturing_factor.gain",
	"ideology.country.output.energy_factor.gain": "ideology.country.output.energy_factor.gain",
	"ideology.country.output.knowledge_factor.gain": "ideology.country.output.knowledge_factor.gain",
	"ideology.country.trade.capacity_factor.gain": "ideology.country.trade.capacity_factor.gain",
	"ideology.country.population.death_factor.cut": "ideology.country.population.death_factor.cut",
	"ideology.country.construction.cost_factor.cut": "ideology.country.construction.cost_factor.cut",
	"ideology.country.research.cost_factor.cut": "ideology.country.research.cost_factor.cut",
	"family.country.trade_capacity": "family.country.trade_capacity",
}

const DEFAULT_KNOWN_GOODS := [
	"grain", "food", "fish", "meat", "salt", "timber", "wood", "stone", "clay",
	"copper", "tin", "bronze", "iron", "coal", "tools", "cloth", "clothing",
	"pottery", "wine", "luxury", "livestock", "herbs", "paper", "corn_grain",
]


static func validate_and_sanitize(
		raw_content: Variant,
		cell_ctx: Dictionary = {},
		allowed_goods: PackedStringArray = PackedStringArray(),
		event_id_override: String = ""
) -> Dictionary:
	var parsed_dict: Dictionary = {}
	if raw_content is Dictionary:
		parsed_dict = (raw_content as Dictionary).duplicate(true)
	elif raw_content is String or raw_content is StringName:
		var cleaned := strip_markdown_fences(String(raw_content))
		if cleaned.is_empty():
			return {
				"ok": false,
				"code": "empty_response",
				"reason": "AI 返回内容为空。",
				"event_dict": {},
			}
		var json := JSON.new()
		var err := json.parse(cleaned)
		if err != OK or not (json.data is Dictionary):
			var extracted := _extract_outer_json_object(cleaned)
			if not extracted.is_empty() and json.parse(extracted) == OK and json.data is Dictionary:
				parsed_dict = json.data as Dictionary
			else:
				return {
					"ok": false,
					"code": "invalid_json",
					"reason": "AI 返回的 JSON 无法解析：%s" % json.get_error_message(),
					"event_dict": {},
				}
		else:
			parsed_dict = json.data as Dictionary
	else:
		return {
			"ok": false,
			"code": "invalid_payload_type",
			"reason": "不支持的 AI 响应类型。",
			"event_dict": {},
		}

	var raw_title := String(parsed_dict.get("title", "")).strip_edges()
	var raw_body_text := String(parsed_dict.get("body_text", parsed_dict.get("narrative", ""))).strip_edges()
	if raw_title.is_empty() or raw_body_text.is_empty():
		return {
			"ok": false,
			"code": "missing_title_or_body",
			"reason": "AI 事件缺少 title 或 body_text。",
			"event_dict": {},
		}
	# 数字不一定是数据：数量词、年份、序号都该保留。只有「温度读数」有现成占位符，
	# 就地改写成 `{temperature}` 交给引擎填充，其余文本原样放行。
	var title := normalize_temperature_readings(raw_title)
	var body_text := normalize_temperature_readings(raw_body_text)

	var raw_options: Variant = parsed_dict.get("options", [])
	if not (raw_options is Array) or (raw_options as Array).is_empty():
		return {
			"ok": false,
			"code": "missing_options",
			"reason": "AI 事件缺少有效的 options 列表。",
			"event_dict": {},
		}

	var available_cash := _read_available_cash(cell_ctx)
	var goods_set := _build_allowed_goods_set(allowed_goods, cell_ctx)

	var sanitized_options: Array[Dictionary] = []
	var opt_arr: Array = raw_options as Array
	for opt_idx in range(mini(opt_arr.size(), 4)):
		var raw_opt: Variant = opt_arr[opt_idx]
		if not (raw_opt is Dictionary):
			continue
		var sanitized_opt := _sanitize_option(raw_opt as Dictionary, opt_idx, available_cash, goods_set)
		if not sanitized_opt.is_empty():
			sanitized_options.append(sanitized_opt)

	if sanitized_options.is_empty():
		return {
			"ok": false,
			"code": "no_valid_options",
			"reason": "AI 事件的所有选项均无效。",
			"event_dict": {},
		}

	var event_id_str := event_id_override.strip_edges()
	if event_id_str.is_empty():
		event_id_str = String(parsed_dict.get("event_id", "")).strip_edges()
	if event_id_str.is_empty():
		var day_val := int(cell_ctx.get("day", 1))
		var cell_val := int(cell_ctx.get("cell_idx", 0))
		event_id_str = "ai_event_d%d_c%d_%d" % [day_val, cell_val, absi(title.hash() % 100000)]

	var sanitized_tags: Array[String] = []
	var raw_tags: Variant = parsed_dict.get("tags", [])
	if raw_tags is Array or raw_tags is PackedStringArray:
		for t in raw_tags:
			var ts := _sanitize_identifier(String(t))
			if not ts.is_empty() and not sanitized_tags.has(ts):
				sanitized_tags.append(ts)
	if sanitized_tags.is_empty():
		sanitized_tags.append("ai_narrative")

	var ai_visual_prompt := String(parsed_dict.get("ai_visual_prompt", "")).strip_edges()
	var era_idx := clampi(int(cell_ctx.get("era_index", 0)), 0, 10)

	var event_dict := {
		"event_id": event_id_str,
		"version": int(parsed_dict.get("version", 1)),
		"title": title.left(32),
		# 界面只放两行事实：模型若写成大段叙事，这里直接截断。
		"body_text": body_text.left(160),
		"image_key": String(parsed_dict.get("image_key", "")),
		"image_path": String(parsed_dict.get("image_path", "")),
		"ai_visual_prompt": ai_visual_prompt.left(500),
		"tags": sanitized_tags,
		"trigger_channel": int(parsed_dict.get("trigger_channel", NarrativeEventDefinitionScript.TriggerChannel.PULSE_SAMPLED)),
		"fact_event_type": int(parsed_dict.get("fact_event_type", 0)),
		"scope": int(parsed_dict.get("scope", NarrativeEventDefinitionScript.Scope.CELL)),
		"base_weight": maxi(1, int(parsed_dict.get("base_weight", 100))),
		"trigger_chance_q16": Q16_ONE,
		"cooldown_days": clampi(int(parsed_dict.get("cooldown_days", 180)), 15, 3650),
		"one_shot": bool(parsed_dict.get("one_shot", true)),
		"min_era_index": clampi(int(parsed_dict.get("min_era_index", 0)), 0, era_idx),
		"max_era_index": clampi(int(parsed_dict.get("max_era_index", 10)), era_idx, 10),
		"required_technologies": [],
		"blocked_technologies": [],
		"required_events_completed": [],
		"required_story_flags": [],
		"blocked_story_flags": [],
		"on_trigger_effects": [],
		"conditions": [],
		"weight_rules": [],
		"options": sanitized_options,
		"is_ai_generated": true,
	}

	return {
		"ok": true,
		"code": "ok",
		"reason": "",
		"event_dict": event_dict,
	}


static func validate_json(
		raw_content: Variant,
		cell_ctx: Dictionary = {},
		allowed_goods: PackedStringArray = PackedStringArray(),
		event_id_override: String = ""
) -> Dictionary:
	return validate_and_sanitize(raw_content, cell_ctx, allowed_goods, event_id_override)


static func strip_markdown_fences(raw_text: String) -> String:
	var s := raw_text.strip_edges()
	if s.begins_with("```"):
		var first_newline := s.find("\n")
		if first_newline >= 0:
			s = s.substr(first_newline + 1).strip_edges()
		else:
			s = s.trim_prefix("```json").trim_prefix("```JSON").trim_prefix("```").strip_edges()
		if s.ends_with("```"):
			s = s.substr(0, s.length() - 3).strip_edges()
	return s


static func _extract_outer_json_object(s: String) -> String:
	var start := s.find("{")
	var end := s.rfind("}")
	if start >= 0 and end > start:
		return s.substr(start, end - start + 1)
	return ""


## 数字不一定是数据：「三人」「三成」「第 3 条」都是叙述，不能因为出现数字就删句子。
## 唯一能在不丢信息的前提下修掉的是「温度读数」——它有 `{temperature}` 这个现成占位符，
## 因此把 `34.2℃` / `34.2 °C` 就地改写成占位符，由引擎在入队时填当前气温。
## 价格、库存、百分比等没有对应占位符，交给 prompt 约束，不在这里做文本手术。
static func normalize_temperature_readings(text: String) -> String:
	if text.is_empty():
		return text
	var out := ""
	var index := 0
	var length := text.length()
	while index < length:
		var code := text.unicode_at(index)
		if code < 48 or code > 57:
			out += char(code)
			index += 1
			continue
		var number_start := index
		while index < length:
			var digit := text.unicode_at(index)
			if (digit >= 48 and digit <= 57) or digit == 46:
				index += 1
			else:
				break
		# 数字与单位之间允许一个空格（"34.2 ℃"）。
		var unit_index := index
		while unit_index < length and text.unicode_at(unit_index) == 32:
			unit_index += 1
		var unit_length := 0
		if unit_index < length and text.unicode_at(unit_index) == 8451:  # ℃
			unit_length = 1
		elif unit_index + 1 < length and text.unicode_at(unit_index) == 176 \
				and text.unicode_at(unit_index + 1) == 67:  # °C
			unit_length = 2
		if unit_length == 0:
			out += text.substr(number_start, index - number_start)
			continue
		out += "{temperature}"
		index = unit_index + unit_length
	return out


static func _sanitize_option(
		raw_opt: Dictionary,
		opt_idx: int,
		available_cash: int,
		goods_set: Dictionary
) -> Dictionary:
	var text := normalize_temperature_readings(String(raw_opt.get("text", "")).strip_edges())
	if text.is_empty():
		text = "选项 %d" % (opt_idx + 1)
	var tooltip_hint := normalize_temperature_readings(
		String(raw_opt.get("tooltip_hint", "")).strip_edges())
	var req_cash := clampi(int(raw_opt.get("require_treasury_cash", 0)), 0, maxi(0, available_cash))
	var opt_id := String(raw_opt.get("option_id", "")).strip_edges()
	if opt_id.is_empty():
		opt_id = "opt_%d" % (opt_idx + 1)

	var raw_outcomes: Variant = raw_opt.get("outcomes", [])
	var sanitized_outcomes: Array[Dictionary] = []
	var weights: Array[int] = []

	if raw_outcomes is Array and not (raw_outcomes as Array).is_empty():
		var out_arr: Array = raw_outcomes as Array
		for i in range(mini(out_arr.size(), 4)):
			var item: Variant = out_arr[i]
			if not (item is Dictionary):
				continue
			var od: Dictionary = item as Dictionary
			var out_title := normalize_temperature_readings(
				String(od.get("outcome_title", od.get("title", "结果"))).strip_edges())
			if out_title.is_empty():
				out_title = "结果"
			var out_narrative := String(od.get("outcome_narrative", od.get("narrative", text))).strip_edges()
			var w := _extract_outcome_weight(od)
			var effs := _sanitize_effects_array(od.get("effects", []), available_cash, goods_set)
			sanitized_outcomes.append({
				"probability_q16": Q16_ONE,
				"outcome_title": out_title.left(32),
				"outcome_narrative": out_narrative.left(600),
				"effects": effs,
			})
			weights.append(w)
	else:
		# Allow flat option with direct effects if LLM omitted outcomes wrapper
		var direct_effs := _sanitize_effects_array(raw_opt.get("effects", []), available_cash, goods_set)
		var flat_title := normalize_temperature_readings(
			String(raw_opt.get("outcome_title", "已执行")).strip_edges())
		if flat_title.is_empty():
			flat_title = "已执行"
		sanitized_outcomes.append({
			"probability_q16": Q16_ONE,
			"outcome_title": flat_title.left(32),
			"outcome_narrative": String(raw_opt.get("outcome_narrative", text)).left(600),
			"effects": direct_effs,
		})
		weights.append(100)

	if sanitized_outcomes.is_empty():
		return {}

	var norm_probs := _normalize_weights_to_q16(weights)
	for i in range(sanitized_outcomes.size()):
		sanitized_outcomes[i]["probability_q16"] = norm_probs[i]

	var req_good_id := _sanitize_identifier(String(raw_opt.get("require_good_id", "")))
	var req_good_qty := maxi(0, int(raw_opt.get("require_good_qty", 0)))
	if not req_good_id.is_empty() and not goods_set.has(req_good_id):
		req_good_id = ""
		req_good_qty = 0

	return {
		"option_id": opt_id,
		"text": text.left(48),
		"tooltip_hint": tooltip_hint.left(160),
		"require_treasury_cash": req_cash,
		"require_good_id": req_good_id,
		"require_good_qty": req_good_qty,
		"require_technology": "",
		"outcomes": sanitized_outcomes,
	}


static func _extract_outcome_weight(od: Dictionary) -> int:
	if od.has("probability_q16"):
		return maxi(1, int(od["probability_q16"]))
	if od.has("probability_percent"):
		return maxi(1, int(round(float(od["probability_percent"]) * 100.0)))
	if od.has("probability"):
		var p := float(od["probability"])
		if p <= 1.0:
			return maxi(1, int(round(p * 10000.0)))
		return maxi(1, int(round(p * 100.0)))
	return 100


static func _normalize_weights_to_q16(weights: Array[int]) -> PackedInt32Array:
	var count := weights.size()
	var result := PackedInt32Array()
	if count == 0:
		return result
	result.resize(count)
	if count == 1:
		result[0] = Q16_ONE
		return result
	var total := 0
	for i in range(count):
		var w := maxi(1, int(weights[i]))
		result[i] = w
		total += w
	var assigned := 0
	for i in range(count - 1):
		var max_allowed := maxi(1, Q16_ONE - assigned - (count - 1 - i))
		var norm := int(round(float(result[i]) * float(Q16_ONE) / float(total)))
		norm = clampi(norm, 1, max_allowed)
		result[i] = norm
		assigned += norm
	result[count - 1] = maxi(1, Q16_ONE - assigned)
	return result


static func _sanitize_effects_array(
		raw_effects: Variant,
		available_cash: int,
		goods_set: Dictionary
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw_effects is Array):
		return out
	var arr: Array = raw_effects as Array
	for i in range(mini(arr.size(), 6)):
		var item: Variant = arr[i]
		if not (item is Dictionary):
			continue
		var sanitized := _sanitize_single_effect(item as Dictionary, available_cash, goods_set)
		if not sanitized.is_empty():
			out.append(sanitized)
	return out


static func _sanitize_single_effect(
		raw_eff: Dictionary,
		available_cash: int,
		goods_set: Dictionary
) -> Dictionary:
	var Kind = NarrativeEffectSpecScript.Kind
	var kind_val := _parse_allowed_kind(raw_eff.get("kind", ""))
	if kind_val <= 0:
		return {}

	var raw_target := String(raw_eff.get("target_key", "")).strip_edges()
	var raw_tag := _sanitize_identifier(String(raw_eff.get("tag_key", "")))
	var duration_days := clampi(int(raw_eff.get("duration_days", 90)), MIN_DURATION_DAYS, MAX_DURATION_DAYS)
	var mag_q16 := _extract_clamped_magnitude_q16(raw_eff)
	var ratio_bp := _extract_clamped_ratio_bp(raw_eff)
	var int_val := int(raw_eff.get("int_value", raw_eff.get("amount", raw_eff.get("quantity", 0))))
	var scope_to_cell := bool(raw_eff.get("scope_to_cell", kind_val != Kind.COUNTRY_MODIFIER))
	var custom_label := String(raw_eff.get("custom_label", "")).strip_edges().left(120)
	var ai_followup_prompt := String(raw_eff.get("ai_followup_prompt", "")).strip_edges().left(400)
	# 范围效果只属于 CITY_MODIFIER；其余 Kind 一律写 0，别让模型把全国修正也写成本地范围。
	var radius_cells := 0
	var falloff := 0

	var resolved_target := ""

	match kind_val:
		Kind.CITY_MODIFIER:
			resolved_target = _resolve_safe_city_modifier_key(raw_target, goods_set)
			if resolved_target.is_empty():
				return {}
			scope_to_cell = true
			radius_cells = clampi(int(raw_eff.get("radius_cells", 0)), 0, 2)
			falloff = clampi(int(raw_eff.get("falloff", 0)), 0, 1)

		Kind.COUNTRY_MODIFIER:
			resolved_target = _resolve_safe_country_modifier_key(raw_target)
			if resolved_target.is_empty():
				return {}
			scope_to_cell = false

		Kind.TREASURY_CASH_TO_COHORT:
			resolved_target = ""
			if int_val > 0:
				if available_cash > 0:
					int_val = clampi(int_val, 0, available_cash)
				else:
					int_val = clampi(int_val, 0, 1000000)
			else:
				int_val = 0
				if ratio_bp <= 0:
					ratio_bp = 500 # Default 5%

		Kind.COHORT_CASH_TO_TREASURY:
			resolved_target = ""
			if int_val > 0:
				int_val = clampi(int_val, 1, 1000000)
			else:
				int_val = 0
				if ratio_bp <= 0:
					ratio_bp = 500 # Default 5%

		Kind.COUNTRY_GOOD_TO_MARKET, Kind.MARKET_GOOD_TO_COUNTRY, Kind.MARKET_ADD_STOCK, Kind.MARKET_REMOVE_STOCK:
			var good_key := _sanitize_identifier(raw_target)
			if good_key.is_empty() or not goods_set.has(good_key):
				return {}
			resolved_target = good_key
			if int_val > 0:
				int_val = clampi(int_val, 1, 50000)
			else:
				int_val = 100 if kind_val == Kind.MARKET_ADD_STOCK else 0
				if ratio_bp <= 0 and int_val == 0:
					ratio_bp = 500

		Kind.SET_STORY_FLAG, Kind.CLEAR_STORY_FLAG:
			var flag_key := _sanitize_identifier(raw_target)
			if flag_key.is_empty():
				if not raw_tag.is_empty():
					flag_key = raw_tag
				else:
					return {}
			resolved_target = flag_key
			int_val = clampi(maxi(1, int_val), 1, 100)

		Kind.ADD_EVENT_WEIGHT_BIAS:
			resolved_target = _sanitize_identifier(raw_target)
			if raw_tag.is_empty() and not resolved_target.is_empty():
				raw_tag = resolved_target
			if raw_tag.is_empty() and resolved_target.is_empty():
				raw_tag = "economy"
			int_val = clampi(int_val if int_val != 0 else 50, -300, 500)

		Kind.SCHEDULE_FOLLOWUP_EVENT:
			resolved_target = _sanitize_identifier(raw_target)
			if resolved_target.is_empty():
				resolved_target = "ai_chain_followup"
			if raw_tag.is_empty():
				raw_tag = "chain"
			if ai_followup_prompt.is_empty():
				ai_followup_prompt = custom_label if not custom_label.is_empty() else "承接前事的后续演变"

		_:
			return {}

	if custom_label.is_empty() and (kind_val == Kind.CITY_MODIFIER or kind_val == Kind.COUNTRY_MODIFIER):
		# 兜底标签也必须说真话：ADD 族 magnitude 就是幅度，.cut 是减益。
		var pct := maxi(1, roundi(float(mag_q16) * 100.0 / float(Q16_ONE)))
		var sign_word := "-" if resolved_target.ends_with(".cut") else "+"
		custom_label = "%s修正 %s%d%%，%d 日" % [
			"本地" if kind_val == Kind.CITY_MODIFIER else "全国",
			sign_word, pct, duration_days,
		]
		if kind_val == Kind.CITY_MODIFIER and radius_cells > 0:
			custom_label += "（周边 %d 环）" % radius_cells

	return {
		"kind": kind_val,
		"target_key": resolved_target,
		"tag_key": raw_tag,
		"magnitude_q16": mag_q16,
		"int_value": int_val,
		"ratio_bp": ratio_bp,
		"duration_days": duration_days,
		"scope_to_cell": scope_to_cell,
		"custom_label": custom_label,
		"ai_followup_prompt": ai_followup_prompt,
		"radius_cells": radius_cells,
		"falloff": falloff,
	}


static func _parse_allowed_kind(raw_kind: Variant) -> int:
	var Kind = NarrativeEffectSpecScript.Kind
	if raw_kind is int or raw_kind is float:
		var k := int(raw_kind)
		if k in [
			Kind.CITY_MODIFIER,
			Kind.COUNTRY_MODIFIER,
			Kind.TREASURY_CASH_TO_COHORT,
			Kind.COHORT_CASH_TO_TREASURY,
			Kind.COUNTRY_GOOD_TO_MARKET,
			Kind.MARKET_GOOD_TO_COUNTRY,
			Kind.MARKET_ADD_STOCK,
			Kind.MARKET_REMOVE_STOCK,
			Kind.SET_STORY_FLAG,
			Kind.CLEAR_STORY_FLAG,
			Kind.ADD_EVENT_WEIGHT_BIAS,
			Kind.SCHEDULE_FOLLOWUP_EVENT,
		]:
			return k
		return -1
	if raw_kind is String or raw_kind is StringName:
		var upper := String(raw_kind).strip_edges().to_upper()
		if Kind.has(upper):
			return _parse_allowed_kind(int(Kind[upper]))
	return -1


static func _resolve_safe_city_modifier_key(raw_key: String, goods_set: Dictionary) -> String:
	var k := raw_key.strip_edges()
	if k.is_empty():
		return "economy.city.building.manufacturing_output_factor"
	if SAFE_CITY_MODIFIER_KEYS.has(k):
		return String(SAFE_CITY_MODIFIER_KEYS[k])
	var lower := k.to_lower()
	if SAFE_CITY_MODIFIER_KEYS.has(lower):
		return String(SAFE_CITY_MODIFIER_KEYS[lower])

	# Check economy.city.good.<good_id>.output_factor[.cut]
	if lower.begins_with("economy.city.good."):
		var is_cut := lower.ends_with(".output_factor.cut")
		var is_gain := lower.ends_with(".output_factor")
		if is_cut or is_gain:
			var good_part := lower.trim_prefix("economy.city.good.")
			good_part = good_part.trim_suffix(".output_factor.cut" if is_cut else ".output_factor")
			var clean_good := _sanitize_identifier(good_part)
			if not clean_good.is_empty() and goods_set.has(clean_good):
				return "economy.city.good.%s.output_factor%s" % [
					clean_good,
					".cut" if is_cut else "",
				]

	# Safe keyword heuristics so unknown AI modifier suggestions map to safe catalog keys
	if lower.contains("agri") or lower.contains("farm") or lower.contains("crop") or lower.contains("harvest"):
		return "economy.city.building.agriculture_output_factor"
	if lower.contains("mine") or lower.contains("extract") or lower.contains("ore") or lower.contains("timber"):
		return "economy.city.building.extractive_output_factor"
	if lower.contains("manuf") or lower.contains("craft") or lower.contains("indus") or lower.contains("work"):
		return "economy.city.building.manufacturing_output_factor"
	if lower.contains("energy") or lower.contains("fuel") or lower.contains("coal") or lower.contains("power"):
		return "economy.city.building.energy_output_factor"
	if lower.contains("know") or lower.contains("scholar") or lower.contains("research") or lower.contains("science"):
		return "economy.city.building.knowledge_output_factor"
	if lower.contains("birth") or lower.contains("pop") or lower.contains("growth"):
		if lower.contains("cut") or lower.contains("loss") or lower.contains("plague") or lower.contains("death"):
			return "economy.city.birth_factor.cut"
		return "economy.city.birth_factor"
	if lower.contains("trade") or lower.contains("market") or lower.contains("commerce") or lower.contains("merchant"):
		return "economy.city.building.manufacturing_output_factor"
	return "economy.city.building.manufacturing_output_factor"


static func _resolve_safe_country_modifier_key(raw_key: String) -> String:
	var k := raw_key.strip_edges()
	if k.is_empty():
		return "ideology.country.output.manufacturing_factor.gain"
	if SAFE_COUNTRY_MODIFIER_KEYS.has(k):
		return String(SAFE_COUNTRY_MODIFIER_KEYS[k])
	var lower := k.to_lower()
	if SAFE_COUNTRY_MODIFIER_KEYS.has(lower):
		return String(SAFE_COUNTRY_MODIFIER_KEYS[lower])
	if lower.contains("agri") or lower.contains("farm"):
		return "ideology.country.output.agriculture_factor.gain"
	if lower.contains("extract") or lower.contains("mine"):
		return "ideology.country.output.extractive_factor.gain"
	if lower.contains("manuf") or lower.contains("indus"):
		return "ideology.country.output.manufacturing_factor.gain"
	if lower.contains("energy"):
		return "ideology.country.output.energy_factor.gain"
	if lower.contains("know") or lower.contains("research") or lower.contains("science"):
		return "ideology.country.output.knowledge_factor.gain"
	if lower.contains("trade") or lower.contains("commerce"):
		return "ideology.country.trade.capacity_factor.gain"
	return "ideology.country.output.manufacturing_factor.gain"


static func _extract_clamped_magnitude_q16(raw_eff: Dictionary) -> int:
	if raw_eff.has("magnitude_q16"):
		return clampi(int(raw_eff["magnitude_q16"]), MIN_MAGNITUDE_Q16, MAX_MAGNITUDE_Q16)
	if raw_eff.has("magnitude_percent"):
		var pct := clampf( absf(float(raw_eff["magnitude_percent"])), 5.0, 50.0 )
		var q16 := int(round(pct * float(Q16_ONE) / 100.0))
		return clampi(q16, MIN_MAGNITUDE_Q16, MAX_MAGNITUDE_Q16)
	if raw_eff.has("magnitude"):
		var m := absf(float(raw_eff["magnitude"]))
		if m <= 1.0:
			var q16 := int(round(m * float(Q16_ONE)))
			return clampi(q16, MIN_MAGNITUDE_Q16, MAX_MAGNITUDE_Q16)
		var q16_pct := int(round(m * float(Q16_ONE) / 100.0))
		return clampi(q16_pct, MIN_MAGNITUDE_Q16, MAX_MAGNITUDE_Q16)
	return clampi(int(round(0.15 * float(Q16_ONE))), MIN_MAGNITUDE_Q16, MAX_MAGNITUDE_Q16)


static func _extract_clamped_ratio_bp(raw_eff: Dictionary) -> int:
	if raw_eff.has("ratio_bp"):
		var r := int(raw_eff["ratio_bp"])
		if r <= 0:
			return 0
		return clampi(r, MIN_RATIO_BP, MAX_RATIO_BP)
	if raw_eff.has("ratio_percent"):
		var rp := float(raw_eff["ratio_percent"])
		if rp <= 0.0:
			return 0
		return clampi(int(round(rp * 100.0)), MIN_RATIO_BP, MAX_RATIO_BP)
	return 0


static func _read_available_cash(cell_ctx: Dictionary) -> int:
	for k in ["treasury_cash", "country_cash", "cash", "treasury"]:
		if cell_ctx.has(k) and cell_ctx[k] != null:
			return maxi(0, int(cell_ctx[k]))
	return 0


static func _build_allowed_goods_set(allowed_goods: PackedStringArray, cell_ctx: Dictionary) -> Dictionary:
	var set_dict := {}
	for g in allowed_goods:
		var gs := _sanitize_identifier(String(g))
		if not gs.is_empty():
			set_dict[gs] = true
	if set_dict.is_empty():
		for g in DEFAULT_KNOWN_GOODS:
			set_dict[g] = true
		for dict_key in ["market_stocks_by_id", "market_stocks", "treasury_goods_by_id"]:
			if cell_ctx.has(dict_key) and cell_ctx[dict_key] is Dictionary:
				for k in (cell_ctx[dict_key] as Dictionary).keys():
					var ks := _sanitize_identifier(String(k))
					if not ks.is_empty():
						set_dict[ks] = true
	return set_dict


static func _sanitize_identifier(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	if s.is_empty():
		return ""
	var out := ""
	for i in range(mini(s.length(), 64)):
		var code := s.unicode_at(i)
		var is_lower := code >= 97 and code <= 122
		var is_digit := code >= 48 and code <= 57
		var is_sep := code == 95 or code == 46 or code == 45 # '_', '.', '-'
		if is_lower or is_digit or is_sep:
			out += char(code)
	return out.strip_edges()
