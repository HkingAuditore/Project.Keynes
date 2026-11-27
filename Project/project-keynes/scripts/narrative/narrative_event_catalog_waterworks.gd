class_name NarrativeEventCatalogWaterworks
extends RefCounted

## 水利工程链：一条渠如何改变一块地（架空世界内的「地方志」）。
##
## 四幕：
##   第 1 幕 · 开渠   脉冲抽样  地理（河流 / 平原地形 / 偏干）× 科技（灌溉）× 人口
##   第 2 幕 · 通水   定时触发  只有授权或验渠成功才排程
##   第 3 幕 · 半条渠 定时触发  只有停工或验渠失败才排程；可花代价重启
##   第 4 幕 · 渠田丰收 定时触发 两年后结账：全国性效果，一次性
##
## ─── 数值约定（照抄，否则卡面数字与模拟不符）─────────────────────────────
## 1. `economy.city.good.<good>.output_factor` / `economy.city.building.<sector>_output_factor`
##    在原生侧是 ADD 1.0 项，`magnitude_q16` 就是「幅度本身」：+25% 传 _pct(25)。
##    减益用它们的 `.cut` 孪生定义（减法项）：-12% 传 _pct(12)。
## 2. `family.city.*` 是 MULTIPLY 1.02~1.05 项（出生率削减是 0.97），`magnitude_q16` 只放大那点差额：
##    传 1.15 实测只有 +5.75%。同一串数字换个键就差三倍，别混用。
## 3. 全国侧同理：`ideology.country.output.<sector>_factor.gain` 以幅度为准；
##    `country.economic_mobilization` 基准 +10%（magnitude 0.5 即 +5%）；
##    `ideology.country.construction.cost_factor.cut` 的 term 值为 0，magnitude 0.05 = −5%。
## 4. 卡面文字一律手写 `custom_label`：`NarrativeEffectSpec.describe()` 的百分比走的是
##    另一套约定，只有 custom_label 能保证「写的」就是「算的」。
## 5. 只写农业部门整体（`economy.city.building.agriculture_output_factor`），不要单列某一种作物；
##    主食开销用 `economy.city.need.staple_food.consumption_factor[.cut]`。
## 6. 范围效果：`radius_cells` 0..2 + `falloff` 0/1；只作用己方陆地，标签写「本地及周边 N 环」。
## 7. 一个选项最多写 4 行效果（含标记/排程可到 5 行）；超过就把次要效果留给下一幕。
##
## ─── 排程与标记的分工（重要）────────────────────────────────────────────
## `NarrativeEventService._process_scheduled_events()` 拿到 event_id 就直接入队，
## 不再复核 conditions / required_story_flags。所以分支必须靠「排不同的 event_id」；
## 标记（story flag）是持久化的档案与扩展点，硬门槛只在脉冲通道
## （`required_story_flags` / `blocked_story_flags` / `HAS_STORY_FLAG`）里才生效。
##
## ─── 文本笔法（文学式，不是事件卡）──────────────────────────────────────
## 1. 写一个场景，不写摘要：谁在做什么小动作，桌上有什么，光从哪儿来。
## 2. 具体的名字与具体的物件：沈渠、王三、杜衡；渠图、界桩、名册、铁锹、半袋种粮。
## 3. 让细节承担判断。「名册念错了好几个名字，没人纠正」比「吏治腐败」有用。
## 4. 白描，白话。不写「之乎者也」，不堆四字成语；不要「某某说：『……』」这种引语块。
##    需要说话时，把话揉进叙述里（「他说，去凿吧」），或者干脆不写。
## 5. 结尾落在一个画面上：歪掉的界桩、没带走的铁锹、河面上漂着的门板。

const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const EVENT_PROPOSAL := &"evt.waterworks.canal_proposal"
const EVENT_COMPLETED := &"evt.waterworks.canal_completed"
const EVENT_ABANDONED := &"evt.waterworks.canal_abandoned"
const EVENT_LEGACY := &"evt.waterworks.canal_legacy"

const FLAG_AUTHORIZED := &"flag_canal_authorized"
const FLAG_ABANDONED := &"flag_canal_abandoned"

## 幅度百分数 → Q16。ADD 项的直接写法：_pct(25) 就是 +25%。
static func _pct(percent: float) -> int:
	return int(round(percent * 65536.0 / 100.0))


static func append_waterworks_events(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Kind = NarrativeEffectSpecScript.Kind
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 开渠 ═══════════════════════════════════════════════════
	# 触发设计：四个维度同时成立才出现——有河（工程前提）、平原地形（可灌面积）、
	# 偏干（引水才有增量）、人口门槛（有劳力）。科技门槛把它锁在「已掌握灌溉」之后。
	# 权重设计：同样成立时，越干、人越多、当地粮价越高，越容易弹出。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(EVENT_PROPOSAL),
		"title": "{settlement_name}·开渠",
		"body_text": "一名外来水利工师向朝廷呈上引水方案，主张在{settlement_name}开凿干渠，将河水引入城外大片盐碱荒地，预计数年后即可辟为良田。度支官吏核算后警告，大规模征发民夫将消耗可观的国库口粮与地方劳力。军政重臣更提出严峻顾虑，邻国正伺机而动，此刻将青壮年倾注于土木工程，恐令边防空虚，疑此工师实为敌国疲兵之计。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "Ancient hydraulic engineer unrolling a canal survey before officials on a dry river plain",
		"tags": ["waterworks", "irrigation", "engineering", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 1,
		"max_era_index": 4,
		"required_technologies": ["tech.irrigation"],
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.PLAIN, TerrainTypeScript.TERRAIN.FLOODPLAIN]},
			{"op": Op.MOISTURE_LTE, "float_value": 0.55},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MOISTURE_LTE, "float_value": 0.32},
				"add_weight": 60,
				"multiplier_q16": 91750, # 1.4x
				"reason": "旱地引灌收益更高",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 40,
				"multiplier_q16": 85197, # 1.3x
				"reason": "劳力充足",
			},
			{
				"condition": {
					"op": Op.MARKET_GOOD_PRICE_RATIO_GTE,
					"target_key": "wheat_grain",
					"float_value": 1.15,
				},
				"add_weight": 30,
				"reason": "粮价偏高，官民皆有开渠之议",
			},
		],
		"options": [
			{
				"option_id": "appoint_engineer",
				"text": "批准开渠，征发民夫",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "动工兴修",
						"outcome_narrative": "水利工程正式破土动工，大批民夫沿河扎营。国库拨付的钱粮率先运抵工地，但仓促编制的役籍仍引发劳工阶层怨言，地方舆论对此褒贬不一。",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 250,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(3),
								"duration_days": 240,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 +3%（逐环递减），240 日",
							},
							{
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "ideology.country.construction.cost_factor.cut",
								"magnitude_q16": _pct(5),
								"duration_days": 240,
								"custom_label": "全国建设成本 -5%，240 日",
							},
							{
								# The corvée itself is the cost: laboring cohorts lose
								# satisfaction for as long as the works run.
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "narrative.levy.labor_satisfaction",
								"magnitude_q16": 65536,
								"duration_days": 240,
								"custom_label": "农业工人、工人、矿工满意度 -4，营造工与徭役劳动者 -5，240 日",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_AUTHORIZED),
								"duration_days": 1825,
								"custom_label": "标记「渠工已开」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_COMPLETED),
								"tag_key": "chain_canal",
								"duration_days": 30,
								"custom_label": "30 日后「通水」",
							},
						],
					},
				],
			},
			{
				"option_id": "imprison_then_verify",
				"text": "暂扣工师，复核勘测方案",
				"outcomes": [
					{
						"probability_q16": 36045, # 55%
						"outcome_title": "复核过关准予兴工",
						"outcome_narrative": "工师在看押期间连夜补绘水文细图，经朝廷工官核验确为绝佳良策。工程随即获批动工，这批详尽的水利图籍亦大幅充实了本地学识。",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 150,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 1.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.knowledge_output_factor",
								"magnitude_q16": _pct(4),
								"duration_days": 180,
								"radius_cells": 1,
								"falloff": 1,
								"custom_label": "本地及周边 1 环知识产出 +4%（逐环递减），180 日",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_AUTHORIZED),
								"duration_days": 1825,
								"custom_label": "标记「渠工已开」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_COMPLETED),
								"tag_key": "chain_canal",
								"duration_days": 45,
								"custom_label": "45 日后「通水」",
							},
						],
					},
					{
						"probability_q16": 29491, # 45%
						"outcome_title": "工师下狱渠图封存",
						"outcome_narrative": "朝廷终未打消疑虑，工师遭押入狱，渠图亦被封存入库。地方摊派追回前期筹备耗费，然旱地失灌令周边农事蒙受拖累，邻国使臣暗自庆幸。",
						"effects": [
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 150,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 1.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor.cut",
								"magnitude_q16": _pct(3),
								"duration_days": 240,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 -3%（逐环递减），240 日",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_ABANDONED),
								"duration_days": 1825,
								"custom_label": "标记「渠议中辍」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_ABANDONED),
								"tag_key": "chain_canal",
								"duration_days": 20,
								"custom_label": "20 日后「半条渠」",
							},
						],
					},
				],
			},
			{
				"option_id": "dismiss_and_farm",
				"text": "驳回工程，以农事为先",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "罢工归农",
						"outcome_narrative": "朝廷下令解散工役、遣散民夫归乡，并向地方征收前期筹备摊派以充公库。荒废的河滩旱地未能得水，周边农事产出随之小幅回落。",
						"effects": [
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 200,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 2%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor.cut",
								"magnitude_q16": _pct(2),
								"duration_days": 360,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 -2%（逐环递减），360 日",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_ABANDONED),
								"duration_days": 1825,
								"custom_label": "标记「渠议中辍」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_ABANDONED),
								"tag_key": "chain_canal",
								"duration_days": 20,
								"custom_label": "20 日后「半条渠」",
							},
						],
					},
				],
			},
		],
	}))

	# ═══ 第 2 幕 · 通水 ═══════════════════════════════════════════════════
	# 三个选项是三种治理读法：
	#   引洪淤田  = 用洪水带来的泥沙压碱肥地——地力与单产一起抬，时间最长；
	#   输粟入都  = 立刻变现充实军资——幅度小、且不再给产能；
	#   漫灌速成  = 工程冒险——博弈，成功翻倍、失败盐碱返上来。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(EVENT_COMPLETED),
		"title": "{settlement_name}·通水",
		"body_text": "{settlement_name}干渠终告合龙通水，裹挟泥沙的浑黄河水顺着新凿支流奔涌而出，首次漫过城外大片盐碱荒地。水利工官呈请推行稳健的引洪淤田之法，以泥沙压碱肥地、厚植长期农本。度支官员则急于收回巨额工程成本，主张立刻将渠田新粮折钱解送国库以充军资。另有激进督工建议开闸全量漫灌，赌一次彻底洗碱速成。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "Completed ancient irrigation canal feeding wheat fields, silt-laden water spreading over saline flats",
		"tags": ["waterworks", "irrigation", "harvest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 220,
		"cooldown_days": 30,
		"one_shot": true,
		# 定时事件由排程直接入队；这里只声明路线与防御，别指望它拦人。
		"required_story_flags": [String(FLAG_AUTHORIZED)],
		"blocked_story_flags": [String(FLAG_ABANDONED)],
		"options": [
			{
				"option_id": "silt_irrigation",
				"text": "引洪淤田，厚植长期地力",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "淤泥肥田良畴初成",
						"outcome_narrative": "富含肥力的泥沙层层沉降于荒地之上，盐碱尽退。周边农田连季丰产、主食负担大幅减轻，这一引洪治碱之法亦迅速推广至全国。",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(12),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 +12%（逐环递减），540 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.need.staple_food.consumption_factor.cut",
								"magnitude_q16": _pct(8),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环主食开销 -8%（逐环递减），540 日",
							},
							{
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "ideology.country.output.agriculture_factor.gain",
								"magnitude_q16": _pct(4),
								"duration_days": 540,
								"custom_label": "全国农业 +4%，540 日",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_LEGACY),
								"tag_key": "chain_canal",
								"duration_days": 730,
								"custom_label": "730 日后「渠田丰收」",
							},
						],
					},
				],
			},
			{
				"option_id": "ship_grain_to_capital",
				"text": "渠粮折钱，急输国库",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "折粮入库军资充盈",
						"outcome_narrative": "度支署迅速将渠田收益折现解送国库，充实了中央财政。随着水利配套与磨坊器械相继投用，本地及周边工坊的制造效率亦获提升。",
						"effects": [
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 300,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 3%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.manufacturing_output_factor",
								"magnitude_q16": _pct(4),
								"duration_days": 360,
								"radius_cells": 1,
								"falloff": 1,
								"custom_label": "本地及周边 1 环制造产出 +4%（逐环递减），360 日",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_LEGACY),
								"tag_key": "chain_canal",
								"duration_days": 730,
								"custom_label": "730 日后「渠田丰收」",
							},
						],
					},
				],
			},
			{
				"option_id": "flood_the_fields",
				"text": "开闸漫灌，一举洗碱",
				"outcomes": [
					{
						"probability_q16": 39321, # 60%
						"outcome_title": "洗碱大成丰产倍增",
						"outcome_narrative": "大水退去后新淤厚积，顽固盐碱被彻底压入深土。周边渠田连片翻绿，农业产出迎来井喷，本地主食供给压力大幅缓解。",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(18),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 +18%（逐环递减），540 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.need.staple_food.consumption_factor.cut",
								"magnitude_q16": _pct(10),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环主食开销 -10%（逐环递减），540 日",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_LEGACY),
								"tag_key": "chain_canal",
								"duration_days": 730,
								"custom_label": "730 日后「渠田丰收」",
							},
						],
					},
					{
						"probability_q16": 26215, # 40%
						"outcome_title": "积水返碱农田重创",
						"outcome_narrative": "排水不畅反令地下盐碱大面积上泛，沿岸禾苗成片枯萎。农业产出锐减、主食开销攀升，国库不得不紧急拨款赈济善后。",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor.cut",
								"magnitude_q16": _pct(10),
								"duration_days": 360,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 -10%（逐环递减），360 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.need.staple_food.consumption_factor",
								"magnitude_q16": _pct(8),
								"duration_days": 360,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环主食开销 +8%（逐环递减），360 日",
							},
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 200,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2%",
							},
						],
					},
				],
			},
		],
	}))

	# ═══ 第 3 幕 · 半条渠 ═════════════════════════════════════════════════
	# 失败不是死路：留着图籍就能花代价重启（CLEAR_STORY_FLAG + 再排程）。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(EVENT_ABANDONED),
		"title": "{settlement_name}·半条渠",
		"body_text": "{settlement_name}的引水干渠半途而废，未竟的渠沟在雨水冲刷下日渐坍塌。邻国使节适时遣使致贺，盛赞我国爱惜民力、不兴大役，言辞间却难掩如释重负之意。朝堂之上已无人愿再触及此案，唯有工部档案库中仍妥善保存着当年详尽的水文勘测图卷。如今朝廷须做最终决断：是拨款重启勘测图籍以续前功，还是彻底销案、将全部精力收归日常农耕。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Abandoned canal trench with surveyor stakes on a dry plain, envoys watching from a distance",
		"tags": ["waterworks", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 160,
		"cooldown_days": 30,
		"one_shot": true,
		"required_story_flags": [String(FLAG_ABANDONED)],
		"options": [
			{
				"option_id": "keep_the_survey",
				"text": "重裱图籍，拨款重启渠工",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "旧图重启再续前功",
						"outcome_narrative": "朝廷重新启用封存的水文图卷，拨付专款组织工官修补图纸并筹备复工。这番测绘整理不仅充实了本地学识，亦令未竟的干渠重现通水之望。",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 150,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 1.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.knowledge_output_factor",
								"magnitude_q16": _pct(5),
								"duration_days": 240,
								"radius_cells": 1,
								"falloff": 1,
								"custom_label": "本地及周边 1 环知识产出 +5%（逐环递减），240 日",
							},
							{
								"kind": Kind.CLEAR_STORY_FLAG,
								"target_key": String(FLAG_ABANDONED),
								"custom_label": "清除标记「渠议中辍」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_COMPLETED),
								"tag_key": "chain_canal",
								"duration_days": 120,
								"custom_label": "120 日后「通水」",
							},
						],
					},
				],
			},
			{
				"option_id": "close_the_dossier",
				"text": "彻底销案，专务农耕",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "渠案永绝归于平畴",
						"outcome_narrative": "半截渠沟被平毁复耕，地方按户补缴了收尾摊派。劳力悉数回归常规农事令周边收成略有起色，邻国使臣也因成功阻滞大计而获封赏。",
						"effects": [
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 150,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 1.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(3),
								"duration_days": 240,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 +3%（逐环递减），240 日",
							},
							{
								"kind": Kind.CLEAR_STORY_FLAG,
								"target_key": String(FLAG_ABANDONED),
								"custom_label": "清除标记「渠议中辍」",
							},
						],
					},
				],
			},
		],
	}))

	# ═══ 第 4 幕 · 渠田丰收 ═══════════════════════════════════════════════
	# 两年后结账：把「一次工程」升级成「国家能力」。一次性、长时长，是链条的收束点。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(EVENT_LEGACY),
		"title": "{settlement_name}·渠田丰收",
		"body_text": "干渠建成之后，{settlement_name}连年喜获丰收，满载谷物的重型粮车络绎不绝，官仓与兵源随之日益充盈。朝廷终于迎来将这项地方水利转化为国家长远实力的收获之期。军政重臣力请借此丰年加征渠赋、以渠田余粮供养精锐大军并推动全国营造动员；地方官吏与乡绅则恳请藏富于民，由国库拨款贴补新垦农户，以吸引更多人口落籍拓荒。",
		"image_key": "climate.sun",
		"ai_visual_prompt": "Prosperous ancient granary town beside irrigated wheat fields, carts loaded with grain",
		"tags": ["waterworks", "prosperity", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 240,
		"cooldown_days": 365,
		"one_shot": true,
		"required_story_flags": [String(FLAG_AUTHORIZED)],
		"options": [
			{
				"option_id": "fund_state_from_canal",
				"text": "征渠田余粮，强军兴邦",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "足食强兵国势大振",
						"outcome_narrative": "源源不断的渠粮与渠赋汇入中央，显著压低了全国军需补给负担并拉动全国营建产能。虽令本地主食开销略有上升，国家战略实力已然跃升。",
						"effects": [
							{
								"kind": Kind.COUNTRY_MODIFIER,
								# 基准 +10%：magnitude 0.5 = +5%。
								"target_key": "country.economic_mobilization",
								"magnitude_q16": int(32768),
								"duration_days": 730,
								"custom_label": "全国建筑产出 +5%，730 日",
							},
							{
								"kind": Kind.COUNTRY_MODIFIER,
								# 定义项：country.military.supply_consumption_factor ×0.9；后勤结算直接读。
								"target_key": "narrative.military.supply_cut",
								"magnitude_q16": int(65536),
								"duration_days": 730,
								"custom_label": "全国军队补给消耗 -10%，730 日",
							},
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 200,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 2%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(4),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 +4%（逐环递减），540 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.need.staple_food.consumption_factor",
								"magnitude_q16": _pct(5),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环主食开销 +5%（逐环递减），540 日",
							},
						],
					},
				],
			},
			{
				"option_id": "lighten_canal_tax",
				"text": "拨款贴补，藏富于民",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "沃野聚民百业俱兴",
						"outcome_narrative": "国库按户发放农垦贴补并留粮本地，大批外来农户闻讯迁入落籍。周边渠田农产与人口繁衍同步攀升，主食负担大幅减轻，乡里立碑纪功。",
						"effects": [
							{
								# 「名册上多了几户」是有人真的落了籍：光给产出与出生率，
								# 册子上的人不会多出来。
								"kind": Kind.ADD_POPULATION,
								"ratio_bp": 1500,
								"duration_days": 1,
								"custom_label": "本地人口 +15%（贴补后新户落籍）",
							},
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 300,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 3%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(6),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环农业 +6%（逐环递减），540 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.need.staple_food.consumption_factor.cut",
								"magnitude_q16": _pct(10),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环主食开销 -10%（逐环递减），540 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.birth_factor",
								"magnitude_q16": _pct(5),
								"duration_days": 540,
								"radius_cells": 2,
								"falloff": 1,
								"custom_label": "本地及周边 2 环出生率 +5%（逐环递减），540 日",
							},
						],
					},
				],
			},
		],
	}))
