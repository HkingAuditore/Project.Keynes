class_name NarrativeStateProbeCatalog
extends RefCounted

## 首批「可持续状态」定义。只收录有真实数据支撑、且能长期维持的处境：
## 粮食紧缺、民生不满、连旱。寒潮、锋面过境这类瞬时状态不适合预取
## （几秒后状态就没了，池子只会积压废稿）。
##
## 新增状态只需往这里追加一条：条件必须全部是 NarrativeCondition 支持的算子，
## AI 不参与状态定义。

const NarrativeStateProbeScript = preload("res://scripts/narrative/narrative_state_probe.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")


static func build_default_probes() -> Array:
	var Op = NarrativeConditionScript.Op
	var probes: Array = []

	probes.append(NarrativeStateProbeScript.from_dict({
		"state_id": "state.market.food_shortage",
		"display_name": "粮食紧缺",
		"prompt_hint": "本地粮价持续高于常年，居民抢购囤积，贫户开始以杂粮度日",
		"dwell_days": 10,
		"cooldown_days": 240,
		"min_era_index": 1,
		"conditions": [
			{"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "grain", "float_value": 1.35},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
	}))

	probes.append(NarrativeStateProbeScript.from_dict({
		"state_id": "state.society.discontent",
		"display_name": "民生不满",
		"prompt_hint": "居民对生计普遍不满，请愿与私议增多，乡里秩序开始松动",
		"dwell_days": 7,
		"cooldown_days": 240,
		"conditions": [
			{"op": Op.SATISFACTION_LTE, "float_value": 0.45},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
	}))

	probes.append(NarrativeStateProbeScript.from_dict({
		"state_id": "state.climate.drought",
		"display_name": "连旱",
		"prompt_hint": "土地持续失墒，河渠水位下降，农事与饮水都开始受影响",
		"dwell_days": 15,
		"cooldown_days": 300,
		"conditions": [
			{"op": Op.MOISTURE_LTE, "float_value": 0.28},
			{"op": Op.TEMP_GTE, "float_value": 28.0},
		],
	}))

	probes.append(NarrativeStateProbeScript.from_dict({
		"state_id": "state.war.homefront",
		"display_name": "战时后方",
		"prompt_hint": "仗在别处打，粮、丁、钱都从本地抽；市面还开着，但家家都在算还能撑多久",
		"dwell_days": 10,
		"cooldown_days": 180,
		"min_era_index": 2,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
	}))

	probes.append(NarrativeStateProbeScript.from_dict({
		"state_id": "state.war.defeat",
		"display_name": "战败阴影",
		"prompt_hint": "前线传来的都是坏消息，逃兵与难民开始出现，官府说话没人信",
		"dwell_days": 7,
		"cooldown_days": 180,
		"min_era_index": 2,
		"conditions": [
			{"op": Op.WAR_GOING_BADLY, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
	}))

	return probes
