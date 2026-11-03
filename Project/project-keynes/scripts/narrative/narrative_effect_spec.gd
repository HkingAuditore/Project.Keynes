class_name NarrativeEffectSpec
extends Resource

const Q16_ONE: int = 65536

enum Kind {
	CITY_MODIFIER = 1,
	COUNTRY_MODIFIER = 2,
	TREASURY_CASH_TO_COHORT = 3,
	COHORT_CASH_TO_TREASURY = 4,
	COUNTRY_GOOD_TO_MARKET = 5,
	MARKET_GOOD_TO_COUNTRY = 6,
	MARKET_ADD_STOCK = 7,
	MARKET_REMOVE_STOCK = 8,
	DISCOVER_RESEARCH_SIGNAL = 9,
	SET_STORY_FLAG = 10,
	CLEAR_STORY_FLAG = 11,
	ADD_EVENT_WEIGHT_BIAS = 12,
	SCHEDULE_FOLLOWUP_EVENT = 13,
}

const GOOD_LABELS: Dictionary = {
	"grain": "粮食",
	"food": "食物",
	"fish": "鱼获",
	"meat": "肉类",
	"salt": "食盐",
	"timber": "木材",
	"wood": "木材",
	"stone": "石料",
	"clay": "黏土",
	"copper": "铜矿",
	"tin": "锡矿",
	"bronze": "青铜",
	"iron": "铁矿",
	"coal": "煤炭",
	"tools": "工具",
	"cloth": "布匹",
	"clothing": "衣物",
	"pottery": "陶器",
	"wine": "酒类",
	"luxury": "奢侈品",
	"livestock": "牲畜",
	"herbs": "药材",
	"paper": "纸张",
}

const TAG_LABELS: Dictionary = {
	"unrest": "动荡",
	"rebellion": "叛乱",
	"famine": "饥荒",
	"plague": "疫病",
	"disease": "疫病",
	"disaster": "天灾",
	"flood": "洪涝",
	"drought": "旱灾",
	"harvest": "丰收",
	"prosperity": "繁荣",
	"trade": "商贸",
	"commerce": "商业",
	"innovation": "革新",
	"discovery": "发现",
	"scholar": "学术",
	"family": "世家",
	"frontier": "边疆",
	"maritime": "航海",
	"festival": "庆典",
	"omen": "征兆",
}

@export var kind: int = Kind.CITY_MODIFIER
@export var target_key: StringName = &""
@export var tag_key: StringName = &""
@export var magnitude_q16: int = Q16_ONE
@export var int_value: int = 0
@export var ratio_bp: int = 0
@export var duration_days: int = 90
@export var scope_to_cell: bool = true
@export var custom_label: String = ""
@export var ai_followup_prompt: String = ""

func clamp_safe() -> NarrativeEffectSpec:
	kind = clampi(kind, Kind.CITY_MODIFIER, Kind.SCHEDULE_FOLLOWUP_EVENT)
	magnitude_q16 = clampi(magnitude_q16, 655, 131072)
	duration_days = clampi(duration_days, 1, 1825)
	ratio_bp = clampi(ratio_bp, 0, 5000)
	match kind:
		Kind.ADD_EVENT_WEIGHT_BIAS:
			int_value = clampi(int_value, -500, 1000)
		Kind.TREASURY_CASH_TO_COHORT, Kind.COHORT_CASH_TO_TREASURY:
			int_value = clampi(int_value, 0, 500000000)
		Kind.COUNTRY_GOOD_TO_MARKET, Kind.MARKET_GOOD_TO_COUNTRY, Kind.MARKET_ADD_STOCK, Kind.MARKET_REMOVE_STOCK:
			int_value = clampi(int_value, 0, 50000000)
		_:
			int_value = maxi(0, int_value)
	return self

## 效果标签一律「对象 + 幅度 + 时长」，无修饰词，供事件弹窗与史册直接显示。
func describe() -> String:
	if not custom_label.strip_edges().is_empty():
		return custom_label.strip_edges()
	match kind:
		Kind.CITY_MODIFIER:
			var stat_label: String = _describe_modifier_target(String(target_key), true)
			return _format_modifier_change(stat_label, magnitude_q16, duration_days)
		Kind.COUNTRY_MODIFIER:
			var stat_label: String = _describe_modifier_target(String(target_key), false)
			return _format_modifier_change(stat_label, magnitude_q16, duration_days)
		Kind.TREASURY_CASH_TO_COHORT:
			if int_value > 0:
				return "国库转出 %d 给本地居民" % _format_gold_units(int_value)
			if ratio_bp > 0:
				return "国库转出 %.1f%% 资金给本地居民" % (float(ratio_bp) / 100.0)
			return "国库转出资金给本地居民"
		Kind.COHORT_CASH_TO_TREASURY:
			if int_value > 0:
				return "地方上缴国库 %d" % _format_gold_units(int_value)
			if ratio_bp > 0:
				return "地方资金 %.1f%% 上缴国库" % (float(ratio_bp) / 100.0)
			return "地方资金上缴国库"
		Kind.COUNTRY_GOOD_TO_MARKET:
			return "国家储备 %s %s 投放本地市场" % [_friendly_good_name(target_key), _format_qty_or_ratio(int_value, ratio_bp)]
		Kind.MARKET_GOOD_TO_COUNTRY:
			return "本地市场 %s %s 征调入国库" % [_friendly_good_name(target_key), _format_qty_or_ratio(int_value, ratio_bp)]
		Kind.MARKET_ADD_STOCK:
			return "本地市场新增 %s %s" % [_friendly_good_name(target_key), _format_qty_or_ratio(int_value, ratio_bp)]
		Kind.MARKET_REMOVE_STOCK:
			return "本地市场减少 %s %s" % [_friendly_good_name(target_key), _format_qty_or_ratio(int_value, ratio_bp)]
		Kind.DISCOVER_RESEARCH_SIGNAL:
			return "科研线索 %s" % _friendly_key_name(target_key)
		Kind.SET_STORY_FLAG:
			if duration_days > 0:
				return "标记 %s，%d 日" % [_friendly_key_name(target_key), duration_days]
			return "标记 %s" % _friendly_key_name(target_key)
		Kind.CLEAR_STORY_FLAG:
			return "清除标记 %s" % _friendly_key_name(target_key)
		Kind.ADD_EVENT_WEIGHT_BIAS:
			var subject: String = ""
			if tag_key != &"":
				subject = "%s类事件" % _friendly_tag_name(tag_key)
			elif target_key != &"":
				subject = "事件 %s" % _friendly_key_name(target_key)
			else:
				subject = "相关事件"
			if magnitude_q16 != Q16_ONE:
				var pct: int = maxi(1, roundi(absf(float(magnitude_q16 - Q16_ONE)) * 100.0 / float(Q16_ONE)))
				var sign_word: String = "+" if magnitude_q16 > Q16_ONE else "-"
				return "%s概率 %s%d%%，%d 日" % [subject, sign_word, pct, duration_days]
			if int_value != 0:
				var sign_word: String = "+" if int_value > 0 else "-"
				return "%s权重 %s%d，%d 日" % [subject, sign_word, absi(int_value), duration_days]
			return "%s概率调整，%d 日" % [subject, duration_days]
		Kind.SCHEDULE_FOLLOWUP_EVENT:
			if target_key != &"":
				return "%d 日后触发 %s" % [duration_days, _friendly_key_name(target_key)]
			return "%d 日后触发后续事件" % duration_days
		_:
			return "无效果"

static func _format_modifier_change(stat_label: String, mag_q16: int, days: int) -> String:
	var pct: int = roundi(absf(float(mag_q16 - Q16_ONE)) * 100.0 / float(Q16_ONE))
	if mag_q16 > Q16_ONE:
		return "%s +%d%%，%d 日" % [stat_label, maxi(1, pct), days]
	if mag_q16 < Q16_ONE:
		return "%s -%d%%，%d 日" % [stat_label, maxi(1, pct), days]
	return "%s 不变，%d 日" % [stat_label, days]

static func _describe_modifier_target(key: String, is_city: bool) -> String:
	var prefix: String = "本地" if is_city else "全国"
	if key.is_empty():
		return prefix + "综合产出"
	if key.begins_with("economy.city.good.") and key.ends_with(".output_factor"):
		var good_part: String = key.trim_prefix("economy.city.good.").trim_suffix(".output_factor")
		return "%s%s产出" % [prefix, _friendly_good_name(StringName(good_part))]
	if key.begins_with("economy.city.building.") and key.ends_with("_output_factor"):
		var b_part: String = key.trim_prefix("economy.city.building.").trim_suffix("_output_factor")
		return "%s%s建筑产出" % [prefix, _friendly_key_name(StringName(b_part))]
	match key:
		"economy.city.birth_factor":
			return "本地人口出生率"
		"economy.city.mortality_factor", "economy.city.death_factor":
			return "本地人口死亡率"
		"family.city.production_boost":
			return "本地综合生产效率"
		"ideology.country.output.agriculture_factor.gain":
			return "全国农业产出"
		"ideology.country.output.industry_factor.gain":
			return "全国工业产出"
		"ideology.country.output.commerce_factor.gain":
			return "全国贸易效率"
		"country.economic_mobilization":
			return "全国经济动员效率"
		_:
			return "%s修正" % prefix

static func _friendly_good_name(good_id: StringName) -> String:
	var k: String = String(good_id).strip_edges().to_lower()
	if k.is_empty():
		return "物资"
	if GOOD_LABELS.has(k):
		return String(GOOD_LABELS[k])
	return String(good_id)

static func _friendly_tag_name(tag: StringName) -> String:
	var k: String = String(tag).strip_edges().to_lower()
	if k.is_empty():
		return "相关"
	if TAG_LABELS.has(k):
		return String(TAG_LABELS[k])
	return String(tag)

static func _friendly_key_name(key: StringName) -> String:
	var s: String = String(key).strip_edges()
	if s.is_empty():
		return "未知"
	if GOOD_LABELS.has(s.to_lower()):
		return String(GOOD_LABELS[s.to_lower()])
	if TAG_LABELS.has(s.to_lower()):
		return String(TAG_LABELS[s.to_lower()])
	return s

static func _format_gold_units(val: int) -> int:
	if val >= 10000 and val % 100 == 0:
		return maxi(1, roundi(float(val) / 10000.0))
	return val

static func _format_qty_or_ratio(qty: int, bp: int) -> String:
	if qty > 0:
		var units: int = maxi(1, roundi(float(qty) / 1000.0)) if (qty >= 1000 and qty % 100 == 0) else qty
		return "%d 单位" % units
	if bp > 0:
		return "%.1f%%" % (float(bp) / 100.0)
	return "若干"

static func parse_kind(raw_kind: Variant) -> int:
	if raw_kind is int or raw_kind is float:
		return int(raw_kind)
	if raw_kind is String or raw_kind is StringName:
		var name_upper: String = String(raw_kind).strip_edges().to_upper()
		if Kind.has(name_upper):
			return int(Kind[name_upper])
	return Kind.CITY_MODIFIER

func to_dict() -> Dictionary:
	return {
		"kind": kind,
		"target_key": String(target_key),
		"tag_key": String(tag_key),
		"magnitude_q16": magnitude_q16,
		"int_value": int_value,
		"ratio_bp": ratio_bp,
		"duration_days": duration_days,
		"scope_to_cell": scope_to_cell,
		"custom_label": custom_label,
		"ai_followup_prompt": ai_followup_prompt,
	}

static func from_dict(d: Dictionary) -> NarrativeEffectSpec:
	var spec := NarrativeEffectSpec.new()
	if d.is_empty():
		return spec
	spec.kind = parse_kind(d.get("kind", Kind.CITY_MODIFIER))
	spec.target_key = StringName(String(d.get("target_key", "")))
	spec.tag_key = StringName(String(d.get("tag_key", "")))
	spec.magnitude_q16 = int(d.get("magnitude_q16", Q16_ONE))
	spec.int_value = int(d.get("int_value", 0))
	spec.ratio_bp = int(d.get("ratio_bp", 0))
	spec.duration_days = int(d.get("duration_days", 90))
	spec.scope_to_cell = bool(d.get("scope_to_cell", true))
	spec.custom_label = String(d.get("custom_label", ""))
	spec.ai_followup_prompt = String(d.get("ai_followup_prompt", ""))
	return spec
