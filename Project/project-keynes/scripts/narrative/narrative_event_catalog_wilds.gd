class_name NarrativeEventCatalogWilds
extends RefCounted

## 风土：八条孤立事件，写自然与地块（不接链条，单条收束）。
##
##   枯井 · 蝗 · 狼冬 · 盐霜 · 塌方 · 渡口 · 苇火 · 倒春寒
##
## 这一包全部是脉冲入口；八条各带两三条权重规则，随建筑、职业构成、价格、时代、满意度浮动。
## 代价货币刻意错开：水、口粮、牲畜、地力、路、船、苇席、种粮。
## 没有负向全国贸易容量这种键，所以「路不通」一律写成本地制造 `.cut` 或主食开销上升。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"wilds"
const PREFIX := "evt.wilds."

const CAST := [
	"地方官署", "农垦乡民", "商旅车队", "水利沟渠", "官道驿路",
	"常平粮仓", "矿业工队", "边地巡防", "盐碱荒滩", "地方民壮",
]

const MUL_085 := 55706
const MUL_090 := 58982
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "风土",
		"theme": "水、蝗、雪、盐、路、船、火、霜",
		"era_band": "1-8",
		"prefix": PREFIX,
		"scale": "8 条中观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_WILDS_DRY_WELL),
			String(Ids.EVT_WILDS_LOCUST),
			String(Ids.EVT_WILDS_WOLF_WINTER),
			String(Ids.EVT_WILDS_SALT_BLOOM),
			String(Ids.EVT_WILDS_LANDSLIDE),
			String(Ids.EVT_WILDS_RIVER_FORD),
			String(Ids.EVT_WILDS_REED_FIRE),
			String(Ids.EVT_WILDS_COLD_SPRING),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 枯井 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_DRY_WELL),
		"title": "{settlement_name}·枯井",
		"body_text": "持续干旱令{settlement_name}的公用深井水位告急，提上来的井水混浊稀少，而周边农田正值灌浆关键期，水利沟渠早已干涸龟裂。农垦乡民强烈要求开闸引井水保苗，称若失此一季秋收，全境将陷入饥荒；地方官署中负责民生的官员则力主立刻封堵渠口，优先保障全城饮水安全，以防断水引发疫病与人丁折损。如何分配这最后一点水源，已成燃眉之急。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A village well nearly dry, buckets queued on the stone platform, a farmer pressing a spade into an irrigation ditch",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"required_technologies": ["tech.irrigation"],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.MOISTURE_LTE, "float_value": 0.35},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "还有几口井",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.40},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "靠地吃饭的人多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "镇上买得起抽水机",
			},
		],
		"options": [
			Shared.option(
				"plug_the_ditch", "封堵渠口，优先保饮水",
				"饮水无虞农田减产",
				"官署派人压石封死渠口，虽在初期引发农户冲突，但全城饮水得以保全，人丁平安无恙，地方秩序也随之趋于稳定。",
				[
					Shared.agriculture(-15, 540),
					Shared.birth(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"open_the_ditch", "开闸灌田，限额供水",
				"保得秋收人丁受损",
				"井水倾注麦田并顺势深凿取水，秋收得以保全，工匠亦摸索出深井暗渠之法。然饮水紧缺伤及妇孺，地方怨气随之高涨。",
				[
					Shared.agriculture(15, 540),
					Shared.population_rate(-5),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.research_signal("breakthrough.hydraulic_engineering", "深井暗渠"),
				]),
			Shared.option(
				"share_and_wait", "不设禁令，听凭分用",
				"水源枯竭争端四起",
				"官署未加管制，作坊暂得周转，但无序抢水很快耗干井底。农事与主食供给长期承压，乡里为争水频发械斗。",
				[
					Shared.manufacturing(10, 540),
					Shared.agriculture(-10, 900),
					Shared.staple(12, 900),
					Shared.bias(Ids.TAG_UNREST, 1.20, 900),
				]),
		],
	}))

	# ═══ 蝗 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_LOCUST),
		"title": "{settlement_name}·蝗",
		"body_text": "遮天蔽日的蝗群自东面荒滩压境而来，迅速吞噬{settlement_name}外围农田，常平粮仓本就吃紧的局势雪上加霜。农垦乡民急向地方官署求援，一派主张当机立断割出宽阔隔离带并纵火焚毁，以弃卒保车之法护住腹地主产区；另一派则建议动用公帑大开水利沟渠引水淹蝗，然此举若控水不当恐致苗木涝死。若坐视不理，整片平原的收成都将荡然无存。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A farmer in a millet field covered by a moving grey layer of locusts, another man running from a mill with a fire striker",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.PLAIN, TerrainTypeScript.TERRAIN.FLOODPLAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "田就是全部的活",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.20},
				"add_weight": 20,
				"reason": "仓里没粮，田里更不能丢",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "人心本来就浮",
			},
		],
		"options": [
			Shared.option(
				"burn_a_strip", "割带焚烧，阻断蝗群",
				"焦土阻蝗保住腹地",
				"官署下令焚毁外围田带，蝗群受阻北移，腹地主产区得以保全。然被焚边田的失收推高了主食负担，受灾农户颇多怨言。",
				[
					Shared.agriculture(12, 360),
					Shared.staple(15, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.gamble(
				"flood_the_field", "拨款引渠，漫灌灭蝗",
				Shared.branch(36045, "渠水淹蝗灾情大减", # 55%
					"国库拨款组织引水漫灌，蝗群落水难以起飞，被乡民悉数清扫。本地与全国农事均受益于此番治蝗方略。",
					[
						Shared.cash_out(4, 360),
						Shared.agriculture(18, 540),
						Shared.country_sector("agriculture", 8, 540),
					]),
				Shared.branch(29491, "水涝虫害双重重创", # 45%
					"渠水放量失控浸泡禾苗，蝗群又从侧翼绕入啃食殆尽。国库钱粮白白耗尽，本地农事重创，主食供给陷入严重困境。",
					[
						Shared.cash_out(4, 360),
						Shared.agriculture(-18, 540),
						Shared.staple(24, 540),
					])),
			Shared.option(
				"wait_for_the_county", "按兵不动，任其过境",
				"听任肆虐农事受挫",
				"官署迟迟未予处置，蝗群饱食南去。部分失计农夫被迫转入采掘谋生，本地农田长期减产，主食吃紧且民心大失。",
				[
					Shared.extraction(8, 360),
					Shared.agriculture(-12, 900),
					Shared.staple(18, 900),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 狼冬 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_WOLF_WINTER),
		"title": "{settlement_name}·狼冬",
		"body_text": "连日暴雪封山，饥饿的狼群逼近{settlement_name}外围定居点，冲毁多处牲畜围栏，甚至危及夜行乡民。地方官署与边地巡防紧急会商，若动员全境地方民壮轮班守夜并将畜群迁入城内，需由国库拨付额外粮饷与柴火。部分农垦乡民提议弃置少量老弱牲畜于村外诱狼退去，以换取喘息。亦有官员主张仅在要道燃火驱兽，避免大规模征调民壮引发怨气。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A collapsed sheep pen in heavy snow, wolves on the slope, an old woman calling into the dark, a shepherd with a billhook",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.TEMP_LTE, "float_value": 0.0},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "圈都挨着坡",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 2},
				"add_weight": 15,
				"reason": "墙是土打的，栏是柴扎的",
			},
			{
				"condition": {"op": Op.SATISFACTION_GTE, "float_value": 0.60},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "日子过得下去，肯守夜",
			},
		],
		"options": [
			Shared.option(
				"keep_watch", "拨款组壮，昼夜联防",
				"联防击退狼群安境",
				"国库拨资供应巡防粮柴，地方民壮分班值守终于逼退狼群。虽短期主食消耗略增，却保住了全境农牧根基，地方安宁如故。",
				[
					Shared.agriculture(12, 540),
					Shared.cash_out(4, 360),
					Shared.staple(10, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"feed_them_outside", "弃畜于外，诱狼退去",
				"损畜避患怨气难平",
				"官署强征牲畜弃于坡外喂狼，狼群暂且退去。然畜群折损拖累了次年农牧，城中主食开销攀升，乡民对官署懦弱之举深感不满。",
				[
					Shared.staple(18, 540),
					Shared.agriculture(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"fires_only", "仅燃篝火，免征民壮",
				"防务松懈人畜俱损",
				"因免去夜巡劳役，民间一时未起怨言。然大雪扑灭无人看管的火堆后，狼群屡次入村袭扰，致使人丁与畜群蒙受长期损失。",
				[
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
					Shared.population_rate(-6),
					Shared.agriculture(-10, 900),
				]),
		],
	}))

	# ═══ 盐霜 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_SALT_BLOOM),
		"title": "{settlement_name}·盐霜",
		"body_text": "开春融雪之后，{settlement_name}大片低洼农田返碱严重，地表凝结出厚重白霜，沦为盐碱荒滩。商旅车队闻讯赶来，向地方官署提议组织人手刮取表层硝盐贩售入市，既可解食盐紧缺又能坐收厚利。农垦乡民则恳请国库拨款，从远方水利沟渠引水洗地压碱以保住耕地；若既不治碱也不采盐、强行照常下种，恐将白白耗费宝贵的春耕种粮。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "White salt crust on a field, a salt merchant tasting it, a farmer holding a plough, a wooden rake on a cart",
		"tags": ["land", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.MOISTURE_LTE, "float_value": 0.30},
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.15},
				"add_weight": 20,
				"reason": "盐贵，刮了就能卖",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
				"add_weight": 15,
				"reason": "场子现成",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "知道地里的白霜能洗",
			},
		],
		"options": [
			Shared.option(
				"scrape_the_salt", "准许刮盐，充实市面",
				"采盐获利耕地受损",
				"商队雇工大举刮盐入市，采掘产出走高且本地食盐库存得以补充。但表层耕土遭到破坏，农田产出随之明显下滑。",
				[
					Shared.extraction(18, 540),
					Shared.stock("salt", 20),
					Shared.agriculture(-12, 540),
				]),
			Shared.option(
				"wash_the_field", "拨款引水，洗地压碱",
				"压碱保田农事回暖",
				"国库拨资动员劳力挑水洗地整春，盐碱渐退、农田产出回升且主食负担减轻。唯工程艰苦繁重，乡里对劳役颇有微词。",
				[
					Shared.agriculture(15, 540),
					Shared.cash_out(5, 360),
					Shared.staple(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.option(
				"sow_anyway", "不作处置，照常下种",
				"碱地薄收口粮承压",
				"官署未予干预，工坊运转未受征调影响。然而盐碱地中出苗寥寥，农田长期歉收，城中主食补给日益吃紧。",
				[
					Shared.manufacturing(8, 360),
					Shared.agriculture(-12, 900),
					Shared.staple(15, 900),
				]),
		],
	}))

	# ═══ 塌方 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_LANDSLIDE),
		"title": "{settlement_name}·塌方",
		"body_text": "连日暴雨引发山体滑坡，巨量土石彻底掩埋了{settlement_name}境内的官道驿路，大批商旅车队被迫滞留山脚。然而山体崩塌后的新鲜断面却意外裸露出一条富集铁矿脉。矿业工队兴奋请命，要求趁势顺脉开矿、将人力优先投入采掘；商旅与工坊代表则急催地方官署立刻清通官道以恢复货流。若暂且绕道河滩，恐将长期拖慢全境转运效率。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A landslide blocking a mountain road, an exposed dark ore seam, a cart with iron parts unloaded, a miner testing the rock",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"required_technologies": ["tech.iron_ore_identification"],
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.MOUNTAIN, TerrainTypeScript.TERRAIN.HILL]},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "矿上等着这条路",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "miner", "float_value": 0.15},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "吃这口饭的人多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "有炸药，清得快",
			},
		],
		"options": [
			Shared.option(
				"clear_the_road", "调集人手，抢通官道",
				"官道复通商工两旺",
				"官署集中劳力日夜清障，滞留货车悉数过境，贸易运力与本地制造迅速回升。连日高强度抢修也让劳工事务成为地方议题。",
				[
					Shared.trade_capacity(12, 540),
					Shared.manufacturing(12, 540),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"follow_the_seam", "顺脉开矿，暂缓修路",
				"新矿大兴转运受阻",
				"矿业工队顺断面掘得大片富铁矿，采掘激增并留下珍贵矿脉记录。但官道梗阻导致粮车绕远倾覆，本地制造与主食开销俱受拖累。",
				[
					Shared.extraction(18, 540),
					Shared.research_signal("resource.iron_ore", "铁帽石"),
					Shared.manufacturing(-10, 540),
					Shared.staple(15, 540),
				]),
			Shared.option(
				"take_the_long_way", "暂绕河滩，搁置塌方",
				"绕行维艰怨声载道",
				"车队被迫改走泥泞河滩，入冬冻土后更是寸步难行。虽零星采掘未断，但运力锐减推升主食开销，商民对官署敷衍颇为不满。",
				[
					Shared.extraction(8, 360),
					Shared.staple(12, 900),
					Shared.bias(Ids.TAG_UNREST, 1.15, 900),
				]),
		],
	}))

	# ═══ 渡口 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_RIVER_FORD),
		"title": "{settlement_name}·渡口",
		"body_text": "{settlement_name}城外要津仅靠一艘年久失修的官渡木船维系两岸交通，随着上游汛期涨水与商旅车队日益频繁，渡口拥堵已成常态。商旅与农垦乡民联名陈情，恳请地方官署动用国库添造新船并增派渡夫。财政幕僚则提议将渡口经营权发包给私人，准其提价收费以充实公库。也有官员主张维持旧制、避免额外开支，任由旧船继续勉力周转。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A small wooden ferry boat at a river crossing, a ferryman coiling the rope, travellers and a salt cart waiting on the bank",
		"tags": ["land", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.10},
				"add_weight": 20,
				"reason": "过河的全是货",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
				"add_weight": 15,
				"reason": "市就在岸上",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 3},
				"add_weight": 15,
				"reason": "没有桥，只能靠船",
			},
		],
		"options": [
			Shared.option(
				"add_a_boat", "国库拨款，增船添夫",
				"双舟并渡运力大增",
				"国库拨资打造新渡船并增雇渡夫，两岸积压商货迅速疏通，贸易运力大幅提升。唯修造工料与渡口调度略微推高了营造负担。",
				[
					Shared.trade_capacity(15, 540),
					Shared.cash_out(4, 360),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.05, 360),
				]),
			Shared.option(
				"farm_out_the_crossing", "发包渡口，准增渡资",
				"包渡加费商民怨沸",
				"官署收得包渡现款且周转略有起色，但承包者旋即倍增过河船资。小贩与挑夫不堪重负，本地主食开销上升，民间怨气骤增。",
				[
					Shared.cash_in(4, 540),
					Shared.trade_capacity(8, 540),
					Shared.staple(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"keep_it_as_it_is", "维持旧制，不增人船",
				"旧舟朽坏转运维艰",
				"因未加征费役，一时未起纷争。然而旧船超负荷运转终致朽坏，两岸货流与主食转运长期受阻，本地制造亦受牵连。",
				[
					Shared.manufacturing(-10, 900),
					Shared.staple(12, 900),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 苇火 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_REED_FIRE),
		"title": "{settlement_name}·苇火",
		"body_text": "{settlement_name}北面湿地突发荒火，借着北风迅速蔓延，直逼囤积大批苇席原料的手工业场院，而一沟之隔便是农垦乡民赖以为生的连片稻田。地方官署急令地方民壮集结，若立刻强行抢割隔离带，可望两全却须耗费大量口粮与人力。若放任火势烧至水利沟渠自然熄灭，虽能以草木灰肥田，却将彻底毁掉手工业场院。若观望风向再做决断，则恐酿成更大灾祸。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A reed marsh fire pushing south toward a matting yard, a reed cutter with a knife, a rice field across a ditch",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.VEGETATION_IN, "int_list": [
				VegetationTypeScript.VEG.MARSH,
				VegetationTypeScript.VEG.SWAMP,
				VegetationTypeScript.VEG.PEAT_BOG]},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "forestry_worker", "float_value": 0.20},
				"add_weight": 15,
				"reason": "苇子就是柴山",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "fisher", "float_value": 0.10},
				"add_weight": 15,
				"reason": "鱼窝在苇子里",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 4},
				"add_weight": 10,
				"reason": "火一过就没人拦得住",
			},
		],
		"options": [
			Shared.option(
				"cut_a_firebreak", "急调民壮，抢辟火道",
				"火道阻焰农工俱保",
				"地方民壮顶着浓烟抢割出宽阔隔离带，火势在场院外戛然而止。农田与编席作坊均得以保全，仅因紧急动员略增短期口粮开销。",
				[
					Shared.manufacturing(12, 540),
					Shared.agriculture(10, 540),
					Shared.staple(10, 360),
				]),
			Shared.option(
				"let_it_burn", "任其焚尽，以灰肥田",
				"灰肥稻田苇业尽毁",
				"大火烧至河边自灭，厚重草木灰令来年稻田丰产。然手工业场院与渔猎苇荡付之一炬，制造重挫、民生吃紧，失计手工业者怨声四起。",
				[
					Shared.agriculture(15, 540),
					Shared.manufacturing(-12, 540),
					Shared.staple(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"watch_the_wind", "暂且观望，视风定策",
				"夜风突变灾情失控",
				"入夜后风向骤转，烈焰绕过沟渠直扑稻田并波及周边作坊。农事与制造双双蒙受重创，民众纷纷责难官署优柔寡断。",
				[
					Shared.agriculture(-15, 900),
					Shared.manufacturing(-10, 900),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 倒春寒 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_COLD_SPRING),
		"title": "{settlement_name}·倒春寒",
		"body_text": "一场突如其来的倒春寒席卷{settlement_name}，刚破土的早稻秧苗遭遇严霜冻害，大片秧田危在旦夕。农垦乡民急向地方官署请命，若由国库拨款购置湿柴彻夜熏烟，可望护住现存秧苗却会消耗大量薪炭口粮。若动用常平粮仓仅存的备荒谷种抢时补播，虽能挽回秋收却会令春荒青黄不接更为严峻。若坐等天晴回暖，则恐颗粒无收。",
		"image_key": "family.house",
		"ai_visual_prompt": "Frost on young rice seedlings in a nursery bed, an old woman pressing old cotton wadding over the seedlings",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.TEMP_LTE, "float_value": 6.0},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "全村的苗都在这一畦",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 15,
				"reason": "补种的种粮拿不出来",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 3},
				"add_weight": 15,
				"reason": "没有暖房，只有草席",
			},
		],
		"options": [
			Shared.option(
				"smoke_the_field", "拨款购柴，彻夜熏烟",
				"烟幕护苗春耕得保",
				"国库拨资组织农户燃湿柴熏烟抵御寒霜，绝大多数秧苗安然过关，乡民交口称赞。唯连夜耗柴与补给略微增加了短期主食开销。",
				[
					Shared.agriculture(15, 540),
					Shared.cash_out(4, 360),
					Shared.staple(10, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"resow_with_stored_grain", "动用余种，抢时补播",
				"补种晚收口粮趋紧",
				"常平仓余留谷种悉数下地，秋收总算得以勉强维系。然而口粮储备见底令本地主食负担骤增，荒春困顿亦伤及人丁。",
				[
					Shared.staple(18, 360),
					Shared.agriculture(10, 540),
					Shared.population_rate(-5),
				]),
			Shared.option(
				"wait_for_the_sun", "暂不干预，静候回暖",
				"霜融苗烂民怨沸腾",
				"晴日化霜反致秧畦积水冻烂，春苗十不存一。本地农事蒙受长期重创，乡民对官署见危不救之举怨声载道。",
				[
					Shared.agriculture(-15, 900),
					Shared.bias(Ids.TAG_UNREST, 1.25, 900),
				]),
		],
	}))
