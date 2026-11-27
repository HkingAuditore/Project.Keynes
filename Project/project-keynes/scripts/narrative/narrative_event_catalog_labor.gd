class_name NarrativeEventCatalogLabor
extends RefCounted

## 工业与劳工包：地、机器、工时（5 条）。
##
## 链（三幕）：
##   牧场（脉冲，era 6–8）→ 砸机器（脉冲，需完成牧场 + 失业≥8%）→ 工时（定时，由砸机器三个分支排程）
## 孤立：
##   行会特许（脉冲，era 3–6）· 寡妇的作坊（脉冲，微观，era 3–8）
##
## 连线：牧场选"递呈文"会留下"呈文未批"，抬高砸机器的权重；
## 行会选"押着不办"会留下"火漆未干"，抬高寡妇事件的权重；
## 寡妇"保住招牌"又会抬高行会事件的权重——三件事互相咬住，不是一条直线。
##
## 数值：这一包的代价货币是产能、工时与手艺；负向全国产出不存在，
## 所以"厂子受损"一律写成本地制造业 `.cut`。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const PACK_ID := &"labor"
const PREFIX := "evt.labor."

const CAST := [
	"圈地牧场", "自耕农", "纱厂资本", "动力织机",
	"劳工群体", "工厂法案", "十小时制", "匠作行会",
	"行会特许状", "独立作坊", "市政当局",
]

const MUL_090 := 58982
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474
const MUL_145 := 95027


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "工业与劳工",
		"theme": "地、机器、工时",
		"era_band": "3-8",
		"prefix": PREFIX,
		"scale": "2 中观链节 + 1 宏观收束 + 2 中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_LABOR_ENCLOSURE),
			String(Ids.EVT_LABOR_BROKEN_LOOM),
			String(Ids.EVT_LABOR_FACTORY_ACT),
			String(Ids.EVT_LABOR_GUILD_CHARTER),
			String(Ids.EVT_LABOR_WIDOW_WORKSHOP),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 牧场 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_ENCLOSURE),
		"title": "{settlement_name}·圈地牧场",
		"body_text": "受纺织业原毛需求激增驱动，大型农牧公司正在{settlement_name}近郊大肆设立圈地牧场，将传统公地与零散耕地纳入围栏。资本方援引地籍清丈令，宣称集约牧羊的商业回报远超分散耕作。世代耕作于此的自耕农则联名向市政当局申诉，一旦失地便将沦为流民，双方在田埂上剑拔弩张。",
		"image_key": "map.construction",
		"ai_visual_prompt": "White-painted pasture stakes driven into a hillside beside a worn boundary stone, sheep on the ridge, a clerk reading a roll",
		"tags": ["labor", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.property_cadastre"],
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [TerrainTypeScript.TERRAIN.PLAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "厂子已经开到坡下",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.20},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "种地的人多，地才值得圈",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 30},
				"add_weight": 20,
				"reason": "人多地少，桩子钉得进去",
			},
		],
		"options": [
			Shared.option(
				"pull_the_stakes", "默许乡民拔桩，驳回圈地令",
				"驱牧保耕",
				"乡民连夜拔除牧场围栏，耕地与农业产出得以保全，官府顺势向涉事公司课以罚金。但强硬对抗激化了劳资与土地矛盾。",
				[
					Shared.agriculture(24, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
					Shared.cash_in(4, 180),
					Shared.schedule(Ids.EVT_LABOR_BROKEN_LOOM, 90, "砸机器"),
				]),
			Shared.gamble(
				"take_shares_in_the_pasture", "财政贴补，推行农地入股牧场",
				Shared.branch(39322, "股息丰厚", # 60%
					"国库注资担保后牧场顺利投产，原毛外销畅旺，农牧产出与商贸运力同步跃升。尽管部分失地农户仍感不安，整体改革初见成效。",
					[
						Shared.agriculture(30, 720),
						Shared.trade_capacity(16, 720),
						Shared.cash_out(5, 180),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					]),
				Shared.branch(26214, "牧业崩盘", # 40%
					"外部原毛需求骤冷，牧场公司大幅裁员并变卖草场。失地农户既失田产又无分红，农产重挫、口粮趋紧，人口元气大伤。",
					[
						Shared.agriculture(-18, 540),
						Shared.staple(24, 540),
						Shared.birth(-15, 540),
					])),
			Shared.option(
				"petition_and_wait", "留中不发，暂搁农户土地呈文",
				"呈文积压",
				"农户联名呈文被无限期搁置，牧群趁隙侵占大片麦田，农业产出明显下滑。失地流民涌入城镇，为劳工动荡埋下伏笔。",
				[
					Shared.flag(Ids.FLAG_ENCLOSURE_PETITION, 540, "标记「呈文未批」"),
					Shared.bias(Ids.TAG_LABOR, 1.25, 540),
					Shared.agriculture(-18, 360),
					Shared.schedule(Ids.EVT_FAMILY_FATHERS_DEBT, 90, "父债"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 砸机器 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_BROKEN_LOOM),
		"title": "{settlement_name}·捣毁织机",
		"body_text": "大批因机械化失业的织工在夜间突袭{settlement_name}工业区，砸毁了数台高速运转的动力织机与纺锭。纱厂资本震怒异常，要求市政当局立刻派出巡警镇压并向全城摊派治安费；而劳工群体则声称这是被逼入绝境后的反抗，呼吁将熟练旧匠吸纳入厂培训而非一味驱逐。工业秩序已到爆发边缘。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Weavers breaking spindles inside a cotton mill at night, a wooden shuttle jammed into the gears, two abandoned shoes on the floor",
		"tags": ["labor", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 150,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.textile_machinery"],
		"required_events_completed": [String(Ids.EVT_LABOR_ENCLOSURE)],
		"conditions": [
			{"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.08},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.15},
				"add_weight": 40,
				"multiplier_q16": MUL_120,
				"reason": "巷子里闲人太多",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ENCLOSURE_PETITION)},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "呈文没批，怨气没处去",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "厂子越多，夜里越好藏人",
			},
		],
		"options": [
			Shared.gamble(
				"put_him_on_a_machine", "招安带头工匠，转任机修技师",
				Shared.branch(39322, "旧匠驯机", # 60%
					"老练的手工织匠迅速摸透了机械传动脾气，反而大幅降低了织机故障率。全国制造效率与本地工业技艺皆得提振。",
					[
						Shared.country_sector("manufacturing", 12, 540),
						Shared.knowledge(12, 540),
						Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 45, "工时"),
					]),
				Shared.branch(26214, "工伤酿成罢工", # 40%
					"缺乏防护规程的培训引发严重卷入事故，带头工匠重伤致残。工厂被迫停产整顿，全城劳工怒火彻底点燃。",
					[
						Shared.manufacturing(-18, 360),
						Shared.bias(Ids.TAG_UNREST, 1.45, 540),
						Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 90, "工时"),
					])),
			Shared.option(
				"call_the_patrol", "派遣巡警镇压，课征治安罚金",
				"铁腕戒严",
				"巡警连夜搜捕为首工人并焊死厂区铁门，全国纺织工业得以强力运转且国库收缴罚金。但高压手段令地下劳工串联愈发激进。",
				[
					Shared.country_sector("manufacturing", 15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					Shared.cash_in(5, 180),
					Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 60, "工时"),
				]),
			Shared.option(
				"stop_for_one_night", "停工一日整顿，另招新工顶替",
				"换血复产",
				"厂方草草清理现场并张榜重招廉价生手，既流失了熟练技工导致制造与技艺滑坡，也让失业劳工的积怨进一步发酵。",
				[
					Shared.manufacturing(-15, 360),
					Shared.knowledge(-10, 360),
					Shared.bias(Ids.TAG_LABOR, 1.30, 540),
					Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 120, "工时"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 工时 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_FACTORY_ACT),
		"title": "{settlement_name}·工厂工时法案",
		"body_text": "连日工伤频发终于引爆了{settlement_name}关于工厂法案的激烈议政。劳工群体与社会改良派递交联名请愿，要求立法确立每日十小时制上限以遏制无休止的夜班压榨。纱厂资本与出口商会则强烈反对国家干预契约自由，警告缩短工时将令本国产品丧失竞争优势，甚至威胁将订单转往邻省。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A brass time clock in a factory portico, a one-armed woman worker standing beneath it, the owner holding a pocket watch",
		"tags": ["labor", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 220,
		"cooldown_days": 400,
		"one_shot": true,
		"min_era_index": 6,
		"max_era_index": 8,
		"options": [
			Shared.gamble(
				"try_ten_hours", "财政补贴过渡，试行十小时制",
				Shared.branch(39322, "十小时制立稳", # 60%
					"国库补贴助厂方渡过排班磨合期，工人得以休养生息，人口生育回升。现代轮班与工厂管理经验随之在全国推广。",
					[
						Shared.flag(Ids.FLAG_HOURS_TEN, 900, "标记「十小时制」"),
						Shared.birth(15, 720),
						Shared.cash_out(5, 180),
						Shared.research_signal("breakthrough.industrial_organization", "工厂组织"),
					]),
				Shared.branch(26214, "订单外流受挫", # 40%
					"严苛工时限制令大批外商订单转向邻地无管制工场，本地制造产出下滑。资方借机克扣薪资，人口与治安皆受冲击。",
					[
						Shared.manufacturing(-18, 540),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
						Shared.birth(-10, 540),
					])),
			Shared.option(
				"let_the_factory_decide", "否决工时立法，由厂方自主定夺",
				"资本主导",
				"纱厂全面延长夜班并探索夜间电气照明，全国制造产出显著拉升。但过度压榨令劳工健康与生育率骤降，社会动荡急剧加剧。",
				[
					Shared.country_sector("manufacturing", 15, 720),
					Shared.birth(-18, 720),
					Shared.research_signal("breakthrough.electrification", "电气化"),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"pay_by_the_piece", "废除计时考勤，改行计件薪酬",
				"计件竞速",
				"计件制彻底激发了工场产能，本地制造业产出猛增。但工人为维持生计被迫携家眷超时赶工，家庭元气与口粮负担双双恶化。",
				[
					Shared.manufacturing(24, 540),
					Shared.birth(-15, 540),
					Shared.staple(18, 540),
				]),
		],
	}))

	# ═══ 孤立 · 行会特许 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_GUILD_CHARTER),
		"title": "{settlement_name}·行会特许状",
		"body_text": "{settlement_name}的匠作行会呈递了一份行会特许状草案，请求官府正式钤印确认其垄断经营权：凡未入行会者一律不得在城中开设独立作坊。行会承诺以此包缴匠税并严控器物成色；而大批涌入城郊的流民手艺人则呼吁废除行会壁垒，允许自由开张营生。究竟扶植行会还是放开竞争，已交由当局决断。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A guild charter with a blank name line, a bronze seal without wax, a cooper waiting outside with his tool pole",
		"tags": ["labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 6,
		"required_technologies": ["tech.guild_organization"],
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.15},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "匠户成街，行会说话才有人听",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "作坊多，字号就值钱",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_WIDOW_SIGN)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "寡妇的招牌保住了，别家也想讨一张纸",
			},
		],
		"options": [
			Shared.option(
				"stamp_the_charter", "钤印特许状，确立行会垄断权",
				"行会专营",
				"行会缴纳税款取得独占特许，作坊品控与本地制造稳步增强，外来游匠则被悉数逐出城外，唯工具耗费随之略增。",
				[
					Shared.manufacturing(15, 540),
					Shared.tools(18, 540),
					Shared.cash_in(4, 180),
				]),
			Shared.option(
				"let_anyone_open", "废除行会门槛，准许游匠落籍",
				"开放竞业",
				"外来逃荒匠户获准落籍开张，全境制造业活力与器具日常供给双双受惠。但老牌行会罢市抵制，本地作坊秩序短期震荡。",
				[
					# 逃荒来的箍桶匠从此在镇上落了脚：一户人，按 3 人（本人+家口）算。
					Shared.population(3, "本地人口 +3 人（逃荒匠户落籍）"),
					Shared.country_sector("manufacturing", 10, 540),
					Shared.tools(-18, 540),
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"hold_the_paper", "暂压特许状，待详拟章程再议",
				"火漆未干",
				"特许状迟迟未获批复，城内新旧匠户皆不敢放手扩产。制造产出随之滑坡，行会与游匠间的暗中摩擦日渐升级。",
				[
					Shared.flag(Ids.FLAG_CHARTER_PENDING, 540, "标记「火漆未干」"),
					Shared.manufacturing(-15, 360),
					Shared.bias(Ids.TAG_LABOR, 1.30, 540),
				]),
		],
	}))

	# ═══ 孤立 · 寡妇的作坊 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_WIDOW_WORKSHOP),
		"title": "{settlement_name}·作坊承继权",
		"body_text": "{settlement_name}一处由已故老匠人留下的独立作坊，正面临匠作行会收回字号的强硬通牒。按照行会特许状旧规，东家身故后其遗孀无权继续承继招牌，须于月底前缴纳高额入会份子或摘牌并入行会大坊。城中不少中小独立作坊正密切观望此案裁决，视其为当局对待民间产权与行会特权的风向标。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A widow wiping the three brass nails of a workshop sign, an apprentice twisting hemp on the threshold",
		"tags": ["labor", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 600,
		"min_era_index": 3,
		"max_era_index": 8,
		"required_technologies": ["tech.guild_organization"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "一条街上都是作坊，招牌才有人争",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_CHARTER_PENDING)},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "行会正忙着抢字号",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.10},
				"add_weight": 20,
				"reason": "匠户多，寡妇的活才有人接",
			},
		],
		"options": [
			Shared.option(
				"keep_the_sign", "准予补缴份子，保住独立字号",
				"招牌留存",
				"遗孀补缴核验规费后得以保留独立作坊字号，手艺与产能顺利延续。此例一开，城中多家小坊亦纷纷要求确认独立产权。",
				[
					Shared.cash_in(4, 180),
					Shared.manufacturing(12, 540),
					Shared.flag(Ids.FLAG_WIDOW_SIGN, 540, "标记「招牌未摘」"),
				]),
			Shared.option(
				"take_the_sign_down", "依行会旧规摘牌，并入大坊",
				"字号兼并",
				"独立作坊被摘牌兼并，行会借机整合人力提升了整体制造产出。但失坊匠户被迫沦为雇工，生计压榨令生育下滑且民怨暗生。",
				[
					Shared.manufacturing(15, 540),
					Shared.birth(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 360),
				]),
			Shared.option(
				"wait_until_month_end", "不予裁断，任由债主与行会处置",
				"产权悬空",
				"当局袖手旁观，作坊月底即被债主与行会瓜分停摆。城中中小匠户人心惶惶，本地制造产出受挫且劳工怨气随之攀升。",
				[
					Shared.manufacturing(-15, 360),
					Shared.bias(Ids.TAG_LABOR, 1.20, 540),
				]),
		],
	}))
