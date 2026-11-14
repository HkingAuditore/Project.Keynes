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
		"body_text": "殿里烧着炭，门口还是漏风。沈渠跪在石板上，膝盖底下垫着那卷渠图，图角被手汗浸得发软。他不是本地人，说话带着东边的口音，报名字的时候顿了一下，像在想要不要用真名。他说这条渠能把河水引进城外的盐碱地，三年以后，那片白花花的地能长麦子。没有人接话。管粮的官吏低头翻册子，算征发民夫要吃多少粮；杜衡站在柱子旁边，一直没有看你。最后是他先开口：东边的邻国，正等着我们把青壮年都耗在土方上。",
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
				"text": "把渠交给他，征发民夫",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "动工了",
						"outcome_narrative": "民夫在河边扎下营寨。国库拨出的口粮先到，名册后到，念名字的人念错了好几个，没人纠正。有人说是仁政，也有人说，这是把种地的人赶去挖土。",
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
				"text": "先关起来，把图验清楚",
				"outcomes": [
					{
						"probability_q16": 36045, # 55%
						"outcome_title": "他画了一夜",
						"outcome_narrative": "沈渠在牢里画了一夜。天亮时他把图从门缝里递出来，手上全是墨。你让人放他出去，说，去凿吧。他磕头，站起来的时候踉跄了一下。杜衡站在台阶上，一直没说话。",
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
						"outcome_title": "图进了库房",
						"outcome_narrative": "沈渠被押进牢里，图卷起来，塞进库房最里层的架子。那天夜里，邻国的使者在客栈喝了很多酒，第二天走的时候，赏了伙计一枚钱。",
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
				"text": "停工，让人回去种地",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "名册合上了",
						"outcome_narrative": "民夫各自回乡，河边的口粮摊撤了。里正挨户来收这一冬的摊派，走到王三家门口，王三把门开了一条缝。河边打好的木桩没人管，一场雨之后，歪了。",
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
		"body_text": "通水那天，渠口围了很多人。河水第一次拐进新开的支流，浑黄的水推着草根和树枝往前走，漫过白花花的盐碱地，像有人在田里铺了一层湿泥。没有人欢呼。民夫们蹲在渠边，看水，也看工头的脸色——工钱还没发，谁也不敢先走。王三把手伸进水里，捞出一把泥，在指间搓了搓，又扔回去。他家里那两亩地，今年还种不种得上，他心里没底。",
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
				"text": "放洪水灌田，压住盐碱",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "地换了颜色",
						"outcome_narrative": "渠水裹着泥沙漫过田面，老农蹲下去抓了一把，说这是给地喂饭。秋后麦穗压弯了秆，王三家也分到了一水。他去领粮的时候，特意换了件干净的衣裳。",
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
				"text": "渠粮折钱，解送国库",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "粮车走了",
						"outcome_narrative": "粮行的渠粮折成钱，连夜解送国库；民夫的工钱也折成粮发下去。王三领了粮去市上换盐，粮行门口排的队比昨天长。他算了一遍，这点粮刚好够买回春天借出去的种粮。",
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
				"text": "放水漫灌，一次灌透",
				"outcomes": [
					{
						"probability_q16": 39321, # 60%
						"outcome_title": "水退之后",
						"outcome_narrative": "水退之后，田面结了一层新淤，白碱被压到土下面。渠田连片泛绿，王三把春天借的种粮还了，还剩半袋。他把剩下的半袋埋在地窖里，没告诉任何人。",
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
						"outcome_title": "碱又回来了",
						"outcome_narrative": "水退得太慢，盐碱又泛上来。渠边的禾苗成片枯黄。王三蹲在田埂上，一句话也没说。收工的时候，他把铁锹插在土里，没带走。",
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
		"body_text": "渠线只挖了一半。工棚空了，挖出来的土堆在河边，被雨水冲出一道道沟。邻国的使者送来贺礼，话说得很客气：贵国终于懂得爱惜民力。议事的时候，没有人再提那卷图。它还在库房里，落着灰，压在一摞旧账本下面。只有管库的老吏记得它——每年夏天翻晒的时候，他会把图抽出来，抖一抖灰，再放回去。",
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
				"text": "把图收好，等以后再挖",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "图又被翻出来",
						"outcome_narrative": "图卷被重新裱好，收进库房最里面。几年后有人翻出它，纸边已经发黄，折痕处裂了一道口子。管库的老吏已经换了人，新来的不认识那是什么，差点拿去引火。",
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
				"text": "算了，专心种地",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "没人再提",
						"outcome_narrative": "渠线被雨水冲平，渠边的木桩被人拆回去当柴烧。邻国的使者回国之后升了官。那年冬天，河边结冰，孩子们在旧渠的沟底上跑。",
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
		"body_text": "渠田连着几年丰收。城外的粮车多了起来，市集上开始出现从没见过的大车，车轴压过石板路，声音很沉。收粮的账房在仓门口支了张桌，算盘珠子响到天黑。你的仓廪和兵源一起涨了起来。何老四家添了一头驴，他逢人就说，这驴是渠水养的。只有一件事没人提：渠口上游那几个村子，这两年打井，水位一年比一年低。",
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
				"text": "用渠田的粮养兵",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "粮仓与兵源",
						"outcome_narrative": "西门出去的粮车少了一截，兵册上新添的名字还没干。渠田的粮被装上车，往东边的前线去了。何老四牵着驴在路边看，车过去很久，他才想起来把驴拉开。",
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
				"text": "拨钱贴补，粮留本地",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "村里立了碑",
						"outcome_narrative": "官府按户发了贴补，村里立了碑，碑上刻着督工官吏的名字，没有民夫的名字。粮册上没添几笔，村口的名册上多了十一户。",
						"effects": [
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
