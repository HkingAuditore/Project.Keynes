class_name NarrativeEventDefinition
extends Resource

const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeWeightRuleScript = preload("res://scripts/narrative/narrative_weight_rule.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeOptionScript = preload("res://scripts/narrative/narrative_option.gd")

enum TriggerChannel {
	PULSE_SAMPLED = 0,
	FACT_DRIVEN = 1,
	SCHEDULED_ONLY = 2,
}

enum Scope {
	CELL = 0,
	COUNTRY = 1,
}

@export var event_id: StringName = &""
@export var version: int = 1
@export var title: String = ""
@export_multiline var body_text: String = ""
@export var image_key: StringName = &""
@export var image_path: String = ""
@export var ai_visual_prompt: String = ""
@export var tags: PackedStringArray = PackedStringArray()
@export var trigger_channel: int = TriggerChannel.PULSE_SAMPLED
@export var fact_event_type: int = 0
@export var scope: int = Scope.CELL
@export var base_weight: int = 100
@export var trigger_chance_q16: int = 65536
@export var cooldown_days: int = 180
@export var one_shot: bool = false
@export var min_era_index: int = 0
@export var max_era_index: int = 10
@export var required_technologies: PackedStringArray = PackedStringArray()
@export var blocked_technologies: PackedStringArray = PackedStringArray()
@export var required_events_completed: PackedStringArray = PackedStringArray()
@export var required_story_flags: PackedStringArray = PackedStringArray()
@export var blocked_story_flags: PackedStringArray = PackedStringArray()
@export var on_trigger_effects: Array[Resource] = []
@export var conditions: Array[Resource] = []
@export var weight_rules: Array[Resource] = []
@export var options: Array[Resource] = []
@export var is_ai_generated: bool = false


static func format_text(raw: String, ctx: Dictionary) -> String:
	if raw.is_empty():
		return ""
	var out := raw
	out = out.replace("{settlement_name}", String(ctx.get("settlement_name", "当地聚落")))
	out = out.replace("{country_name}", String(ctx.get("country_name", "我国")))
	out = out.replace("{terrain_name}", String(ctx.get("terrain_name", "原野")))
	out = out.replace("{landform_name}", String(ctx.get("landform_name", "平地")))
	var temp_raw: Variant = ctx.get("temperature", ctx.get("temperature_c", 15.0))
	var temp_str: String = String(temp_raw) if (temp_raw is String and String(temp_raw).contains("°")) else ("%.1f°C" % float(temp_raw))
	out = out.replace("{temperature}", temp_str)
	out = out.replace("{era_name}", String(ctx.get("era_name", "当前时代")))
	var good_str: String = String(ctx.get("good_name", ctx.get("highlight_good_name", "民生商品")))
	out = out.replace("{good_name}", good_str)
	return out


func to_dict() -> Dictionary:
	var trig_effs: Array[Dictionary] = []
	for eff in on_trigger_effects:
		if eff != null and eff.has_method("to_dict"):
			trig_effs.append(eff.to_dict())
	var conds: Array[Dictionary] = []
	for c in conditions:
		if c != null and c.has_method("to_dict"):
			conds.append(c.to_dict())
	var rules: Array[Dictionary] = []
	for r in weight_rules:
		if r != null and r.has_method("to_dict"):
			rules.append(r.to_dict())
	var opts: Array[Dictionary] = []
	for o in options:
		if o != null and o.has_method("to_dict"):
			opts.append(o.to_dict())
	return {
		"event_id": String(event_id),
		"version": version,
		"title": title,
		"body_text": body_text,
		"image_key": String(image_key),
		"image_path": image_path,
		"ai_visual_prompt": ai_visual_prompt,
		"tags": Array(tags),
		"trigger_channel": trigger_channel,
		"fact_event_type": fact_event_type,
		"scope": scope,
		"base_weight": base_weight,
		"trigger_chance_q16": trigger_chance_q16,
		"cooldown_days": cooldown_days,
		"one_shot": one_shot,
		"min_era_index": min_era_index,
		"max_era_index": max_era_index,
		"required_technologies": Array(required_technologies),
		"blocked_technologies": Array(blocked_technologies),
		"required_events_completed": Array(required_events_completed),
		"required_story_flags": Array(required_story_flags),
		"blocked_story_flags": Array(blocked_story_flags),
		"on_trigger_effects": trig_effs,
		"conditions": conds,
		"weight_rules": rules,
		"options": opts,
		"is_ai_generated": is_ai_generated,
	}


static func from_dict(d: Dictionary) -> NarrativeEventDefinition:
	var def := NarrativeEventDefinition.new()
	def.event_id = StringName(d.get("event_id", ""))
	def.version = int(d.get("version", 1))
	def.title = String(d.get("title", "未命名事件"))
	def.body_text = String(d.get("body_text", ""))
	def.image_key = StringName(d.get("image_key", ""))
	def.image_path = String(d.get("image_path", ""))
	def.ai_visual_prompt = String(d.get("ai_visual_prompt", ""))
	def.tags = PackedStringArray(d.get("tags", []))
	def.trigger_channel = int(d.get("trigger_channel", TriggerChannel.PULSE_SAMPLED))
	def.fact_event_type = int(d.get("fact_event_type", 0))
	def.scope = int(d.get("scope", Scope.CELL))
	def.base_weight = maxi(1, int(d.get("base_weight", 100)))
	def.trigger_chance_q16 = clampi(int(d.get("trigger_chance_q16", 65536)), 0, 65536)
	def.cooldown_days = maxi(0, int(d.get("cooldown_days", 180)))
	def.one_shot = bool(d.get("one_shot", false))
	def.min_era_index = int(d.get("min_era_index", 0))
	def.max_era_index = int(d.get("max_era_index", 10))
	def.required_technologies = PackedStringArray(d.get("required_technologies", []))
	def.blocked_technologies = PackedStringArray(d.get("blocked_technologies", []))
	def.required_events_completed = PackedStringArray(d.get("required_events_completed", []))
	def.required_story_flags = PackedStringArray(d.get("required_story_flags", []))
	def.blocked_story_flags = PackedStringArray(d.get("blocked_story_flags", []))
	def.is_ai_generated = bool(d.get("is_ai_generated", false))
	for raw_eff in d.get("on_trigger_effects", []):
		if raw_eff is Dictionary:
			def.on_trigger_effects.append(NarrativeEffectSpecScript.from_dict(raw_eff))
		elif raw_eff is Resource:
			def.on_trigger_effects.append(raw_eff)
	for raw_cond in d.get("conditions", []):
		if raw_cond is Dictionary:
			def.conditions.append(NarrativeConditionScript.from_dict(raw_cond))
		elif raw_cond is Resource:
			def.conditions.append(raw_cond)
	for raw_rule in d.get("weight_rules", []):
		if raw_rule is Dictionary:
			def.weight_rules.append(NarrativeWeightRuleScript.from_dict(raw_rule))
		elif raw_rule is Resource:
			def.weight_rules.append(raw_rule)
	for raw_opt in d.get("options", []):
		if raw_opt is Dictionary:
			def.options.append(NarrativeOptionScript.from_dict(raw_opt))
		elif raw_opt is Resource:
			def.options.append(raw_opt)
	return def
