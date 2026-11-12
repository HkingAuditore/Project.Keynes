class_name NarrativeEventShared
extends RefCounted

## 叙事事件的构造器：把 12 行字典压成一行，同时**消灭标签与幅度的手抄错配**。
##
## 约定（与 narrative-event-authoring.md 一致）：
##   - 城修正走 ADD 1.0 族：magnitude_q16 就是百分比本身，负向自动切 `.cut` 孪生定义；
##   - 全国部门走 `ideology.country.output.<sector>_factor.gain`，magnitude 就是百分比；
##   - `build_cost` / `supply` 是"越大越省"的政策级键，传 3–6 / 8–12；
##   - 现金转移只作用于"本地人数最多的那一群"，标签必须写 `{primary_profession}`；
##   - 市场增补按**整数单位**（原始 quantity = 单位 × 1000），且该格必须有商人。
##
## 标签默认自动生成；需要特殊措辞时传 `label` 覆盖。测试会核对"标签百分比 = magnitude"。

const Q16_ONE: int = 65536
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

# ── 城修正 stat 键 ──────────────────────────────────────────────────────────
const STAT_AGRICULTURE := "economy.city.building.agriculture_output_factor"
const STAT_MANUFACTURING := "economy.city.building.manufacturing_output_factor"
const STAT_EXTRACTIVE := "economy.city.building.extractive_output_factor"
const STAT_ENERGY := "economy.city.building.energy_output_factor"
const STAT_KNOWLEDGE := "economy.city.building.knowledge_output_factor"
const STAT_STAPLE := "economy.city.need.staple_food.consumption_factor"
const STAT_TOOLS := "economy.city.need.work_equipment.consumption_factor"
const STAT_BIRTH := "economy.city.birth_factor"

const SECTOR_NAMES := {
	"agriculture": "农业",
	"manufacturing": "制造",
	"extractive": "采掘",
	"energy": "能源",
	"knowledge": "知识",
}


# ── 数值 ────────────────────────────────────────────────────────────────────

## 百分比 → Q16 幅度。传 5 表示 5%，传 2.5 表示 2.5%。
static func percent(value: float) -> int:
	return int(round(absf(value) * 65536.0 / 100.0))


## 倍率 → Q16。传 1.3 表示 ×1.3。
static func mul(factor: float) -> int:
	return int(round(factor * 65536.0))

static func _fmt(value: float) -> String:
	if absf(value - roundf(value)) < 0.001:
		return "%d" % int(roundf(value))
	return "%.1f" % value

static func _signed(value: float) -> String:
	return "+%s" % _fmt(value) if value >= 0.0 else "-%s" % _fmt(absf(value))


# ── 城修正 ──────────────────────────────────────────────────────────────────

static func city(stat: String, value: float, days: int, subject: String,
		radius: int = 0, falloff: int = 0, label: String = "") -> Dictionary:
	var negative := value < 0.0
	var scope := "本地" if radius <= 0 else "本地及周边 %d 环" % radius
	var decay := "（逐环递减）" if falloff == 1 and radius > 0 else ""
	var text := label
	if text.strip_edges().is_empty():
		text = "%s%s %s%%%s，%d 日" % [scope, subject, _signed(value), decay, days]
	return {
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"target_key": stat + (".cut" if negative else ""),
		"magnitude_q16": percent(value),
		"duration_days": days,
		"radius_cells": radius,
		"falloff": falloff,
		"custom_label": text,
	}

static func agriculture(value: float, days: int, radius: int = 0,
		falloff: int = 0, label: String = "") -> Dictionary:
	return city(STAT_AGRICULTURE, value, days, "农业", radius, falloff, label)

static func manufacturing(value: float, days: int, radius: int = 0,
		falloff: int = 0, label: String = "") -> Dictionary:
	return city(STAT_MANUFACTURING, value, days, "制造", radius, falloff, label)

static func extraction(value: float, days: int, radius: int = 0,
		falloff: int = 0, label: String = "") -> Dictionary:
	return city(STAT_EXTRACTIVE, value, days, "采掘", radius, falloff, label)

static func energy(value: float, days: int, radius: int = 0,
		falloff: int = 0, label: String = "") -> Dictionary:
	return city(STAT_ENERGY, value, days, "能源", radius, falloff, label)

static func knowledge(value: float, days: int, radius: int = 0,
		falloff: int = 0, label: String = "") -> Dictionary:
	return city(STAT_KNOWLEDGE, value, days, "知识", radius, falloff, label)

## 主食开销：负数 = 吃得便宜，正数 = 变贵。
static func staple(value: float, days: int, label: String = "") -> Dictionary:
	return city(STAT_STAPLE, value, days, "主食开销", 0, 0, label)

static func tools(value: float, days: int, label: String = "") -> Dictionary:
	return city(STAT_TOOLS, value, days, "工具开销", 0, 0, label)

static func birth(value: float, days: int, label: String = "") -> Dictionary:
	return city(STAT_BIRTH, value, days, "人口出生率", 0, 0, label)


# ── 全国修正 ────────────────────────────────────────────────────────────────

static func country_sector(sector: String, value: float, days: int,
		label: String = "") -> Dictionary:
	var subject := String(SECTOR_NAMES.get(sector, "综合"))
	var text := label
	if text.strip_edges().is_empty():
		text = "全国%s部门产出 %s%%，%d 日" % [subject, _signed(value), days]
	return {
		"kind": NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER,
		"target_key": "ideology.country.output.%s_factor.gain" % sector,
		"magnitude_q16": percent(value),
		"duration_days": days,
		"custom_label": text,
	}

static func trade_capacity(value: float, days: int) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER,
		"target_key": "ideology.country.trade.capacity_factor.gain",
		"magnitude_q16": percent(value),
		"duration_days": days,
		"custom_label": "全国贸易容量 %s%%，%d 日" % [_signed(value), days],
	}

## 建设成本下调：传 5 表示 −5%。只允许负向。
static func build_cost(value: float, days: int) -> Dictionary:
	var magnitude := percent(value)
	return {
		"kind": NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER,
		"target_key": "ideology.country.construction.cost_factor.cut",
		"magnitude_q16": magnitude,
		"duration_days": days,
		"custom_label": "全国建设成本 -%s%%，%d 日" % [_fmt(absf(value)), days],
	}

## 军粮消耗下调：传 10 表示 −10%（原生 1.0 = −10%）。只允许 8–12。
static func supply(value: float, days: int) -> Dictionary:
	var magnitude := int(round(absf(value) / 10.0 * float(Q16_ONE)))
	return {
		"kind": NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER,
		"target_key": "narrative.military.supply_cut",
		"magnitude_q16": magnitude,
		"duration_days": days,
		"custom_label": "全国军队补给消耗 -%s%%，%d 日" % [_fmt(absf(value)), days],
	}

## 全国建筑产出：传 5 表示 +5%（原生基准 +10%）。只用于「举国动员」类。
static func mobilization(value: float, days: int) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER,
		"target_key": "country.economic_mobilization",
		"magnitude_q16": int(round(absf(value) / 10.0 * float(Q16_ONE))),
		"duration_days": days,
		"custom_label": "全国建筑产出 +%s%%，%d 日" % [_fmt(absf(value)), days],
	}


# ── 守恒转移与物资 ──────────────────────────────────────────────────────────

## 国库 → 本地人数最多的那一群。传 2.5 表示国库现金的 2.5%。
static func cash_out(percent_of_treasury: float, days: int = 540,
		label: String = "") -> Dictionary:
	var bp := int(round(absf(percent_of_treasury) * 100.0))
	var text := label
	if text.strip_edges().is_empty():
		text = "国库拨付本地人数最多的{primary_profession}，占国库现金 %s%%" % _fmt(percent_of_treasury)
	return {
		"kind": NarrativeEffectSpecScript.Kind.TREASURY_CASH_TO_COHORT,
		"ratio_bp": bp,
		"duration_days": days,
		"custom_label": text,
	}

## 本地人数最多的那一群 → 国库。传 2 表示其现金的 2%。
static func cash_in(percent_of_cash: float, days: int = 360,
		label: String = "") -> Dictionary:
	var bp := int(round(absf(percent_of_cash) * 100.0))
	var text := label
	if text.strip_edges().is_empty():
		text = "向本地人数最多的{primary_profession}征收其现金的 %s%%" % _fmt(percent_of_cash)
	return {
		"kind": NarrativeEffectSpecScript.Kind.COHORT_CASH_TO_TREASURY,
		"ratio_bp": bp,
		"duration_days": days,
		"custom_label": text,
	}

## 本地市场增补实物。传整数单位（原始 quantity = 单位 × 1000）。该格必须有商人。
static func stock(good: String, units: int) -> Dictionary:
	var friendly := NarrativeEffectSpecScript._friendly_good_name(StringName(good))
	return {
		"kind": NarrativeEffectSpecScript.Kind.MARKET_ADD_STOCK,
		"target_key": good,
		"int_value": units * 1000,
		"duration_days": 90,
		"custom_label": "本地市场增补%s %d 单位（官府调拨）" % [friendly, units],
	}


# ── 科研、标记、偏置、排程 ──────────────────────────────────────────────────

static func research_signal(signal_id: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.DISCOVER_RESEARCH_SIGNAL,
		"target_key": signal_id,
		"duration_days": 90,
		"custom_label": "科研线索「%s」" % display_name,
	}

static func flag(flag_id: StringName, days: int, label: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.SET_STORY_FLAG,
		"target_key": flag_id,
		"duration_days": days,
		"custom_label": label,
	}

static func clear_flag(flag_id: StringName, label: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.CLEAR_STORY_FLAG,
		"target_key": flag_id,
		"duration_days": 1,
		"custom_label": label,
	}

## 按 tag 调权：factor > 1 抬升，< 1 压低。
static func bias(tag: StringName, factor: float, days: int, label: String = "") -> Dictionary:
	var text := label
	if text.strip_edges().is_empty():
		text = "%s类事件权重 ×%s，%d 日" % [
			NarrativeEffectSpecScript._friendly_tag_name(tag), _fmt(factor), days]
	return {
		"kind": NarrativeEffectSpecScript.Kind.ADD_EVENT_WEIGHT_BIAS,
		"tag_key": tag,
		"int_value": 0,
		"magnitude_q16": mul(factor),
		"duration_days": days,
		"custom_label": text,
	}

## 按 event_id 调权。
static func bias_event(event_id: StringName, factor: float, days: int,
		display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.ADD_EVENT_WEIGHT_BIAS,
		"target_key": event_id,
		"int_value": 0,
		"magnitude_q16": mul(factor),
		"duration_days": days,
		"custom_label": "「%s」权重 ×%s，%d 日" % [display_name, _fmt(factor), days],
	}

## N 日后在本地块触发。定时通道不复核条件/标记，分支必须排不同的 event_id。
static func schedule(event_id: StringName, days: int, display_name: String,
		chain_tag: StringName = &"") -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.SCHEDULE_FOLLOWUP_EVENT,
		"target_key": event_id,
		"tag_key": chain_tag,
		"duration_days": days,
		"custom_label": "%d 日后「%s」" % [days, display_name],
	}


# ── 选项与结果 ──────────────────────────────────────────────────────────────

static func option(option_id: String, text: String, outcome_title: String,
		outcome_narrative: String, effects: Array) -> Dictionary:
	return {
		"option_id": option_id,
		"text": text,
		"outcomes": [{
			"probability_q16": Q16_ONE,
			"outcome_title": outcome_title,
			"outcome_narrative": outcome_narrative,
			"effects": effects,
		}],
	}

static func branch(probability_q16: int, outcome_title: String,
		outcome_narrative: String, effects: Array) -> Dictionary:
	return {
		"probability_q16": probability_q16,
		"outcome_title": outcome_title,
		"outcome_narrative": outcome_narrative,
		"effects": effects,
	}

static func gamble(option_id: String, text: String, first: Dictionary,
		second: Dictionary) -> Dictionary:
	return {
		"option_id": option_id,
		"text": text,
		"outcomes": [first, second],
	}
