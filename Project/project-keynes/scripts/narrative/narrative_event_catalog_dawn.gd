class_name NarrativeEventCatalogDawn
extends RefCounted

## 黎明包：era 0–2 的七条孤立事件。
##
##   圈墙（第一道墙）/ 分地（博弈）/ 公井 / 集市 / 铁匠 / 盟誓 / 械斗。
##   七条全是脉冲入口，不接链、不写标记；都带两三条权重规则，吃建筑、职业、
##   价格、湿度、满意度分层。
##
## 代价货币刻意错开，同一事件的三条选项各付一种：
##   墙=人头摊派 / 误农时 / 粮价；地=摊派+风险 / 人心 / 农时；
##   井=误工 / 人心 / 孩子；市=秩序 / 货量 / 粮价；
##   匠=守夜人不平 / 农时 / 摊派；誓=人口 / 口粮 / 人心；斗=人心 / 公账 / 农时。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"dawn"
const PREFIX := "evt.dawn."

const CAST := [
	"长老议会", "氏族", "先民", "石垣", "公井", "黑矿", "盟石", "祭司", "河滩集市", "公粮窖",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "黎明",
		"theme": "谁圈墙、谁分地、谁先打水",
		"era_band": "0-2",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_DAWN_FIRST_WALL),
			String(Ids.EVT_DAWN_DIVIDE_FIELDS),
			String(Ids.EVT_DAWN_COMMON_WELL),
			String(Ids.EVT_DAWN_FIRST_MARKET),
			String(Ids.EVT_DAWN_FIRST_SMITH),
			String(Ids.EVT_DAWN_OATH_STONE),
			String(Ids.EVT_DAWN_WATER_BRAWL),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第一道墙 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_FIRST_WALL),
		"title": "{settlement_name}·第一道石垣",
		"body_text": "{settlement_name}的聚落坐落于河谷东侧，无险可守，近来屡遭外族游猎部众夜间袭扰，牲畜与存粮频频失窃。长老议会中主战一派主张即刻征发各氏族青壮，自河滩采石构筑第一道石垣以固根本。但掌管农事的代表强烈反对，警告此时正值农忙，抽调大批劳力搬石筑墙必误秋收；更有氏族忧虑，一旦围墙合拢，墙外开垦的田亩将彻底暴露于劫掠之下。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Villagers stacking a low stone wall around a settlement at dawn, stones carried up from a river beach, a half-dug ditch beside the wall base",
		"tags": ["dawn", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "屋挤在一处，才圈得起来",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "种地的人多，怕被抢",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 15,
				"reason": "心里没底，就想圈起来",
			},
		],
		"options": [
			Shared.option(
				"build_it", "征发部众，合筑石垣",
				"聚落首筑石垣",
				"各氏族摊派物资并轮番出工，一道齐胸高的石垣终于合拢。虽短暂延误了部分农活，但聚落首次拥有了可靠的屏障，人心安定，长远耕作反倒更有保障。",
				[
					Shared.cash_in(3, 360),
					Shared.agriculture(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"dig_a_ditch", "掘壕为障，不筑石墙",
				"深壕环绕聚落",
				"部众改以深挖壕沟、堆土为埂的方式设防，虽占用了一定农时，却在掘土取石的过程中磨砺了工具与采掘技艺，为聚落积累了宝贵的营造经验。",
				[
					Shared.agriculture(-10, 360),
					Shared.manufacturing(8, 360),
					Shared.extraction(8, 360),
				]),
			Shared.option(
				"wait", "暂缓筑城，以农为先",
				"秋收丰盈外患犹存",
				"长老议会搁置了筑墙之议，全力保障当年耕种与收获。秋粮虽得以充实，但无遮无拦的聚落仍屡遭外敌窥伺，牲畜失窃令部众口粮负担暗中加重。",
				[
					Shared.staple(10, 360),
					Shared.agriculture(8, 360),
				]),
		],
	}))

	# ═══ 分地（博弈）═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_DIVIDE_FIELDS),
		"title": "{settlement_name}·授田之争",
		"body_text": "河湾处新辟的大片沃土即将迎来分配，这是{settlement_name}由游猎转向定居农耕后的首次大规模授田。年轻的氏族主张按人口均分，认为口多食众者理应多得份地，否则难以为继；资历深厚的先民老户则坚持按原始户籍划拨，忧虑若任由新附之民瓜分良田，日后人心涣散、田地荒芜。长老议会反复丈量仍难定夺，眼看播种时节将近，拖延已危及全族生计。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Villagers measuring a river-bend field with a rope, wooden stakes driven into the soil, a child drawing lines in the mud",
		"tags": ["dawn", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 2,
		"required_technologies": ["tech.agrarian_society"],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.40},
				"add_weight": 20,
				"reason": "靠这块地吃饭的人多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "屋散在田边，各说各的地界",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 20,
				"multiplier_q16": MUL_110,
				"reason": "粮贵了，一分地都是口粮",
			},
		],
		"options": [
			Shared.gamble(
				"by_head", "按口均分，兼顾新民",
				Shared.branch(39322, "均田落地农产大增", # 60%
					"草绳丈量至日落，肥沃河湾按人口公平划入各户名下。新附氏族获得了立身之本，耕作热情空前高涨，当年便为聚落贡献了丰厚收成。",
					[
						Shared.cash_in(3, 360),
						Shared.agriculture(15, 540),
					]),
				Shared.branch(26214, "争地酿乱贻误农时", # 40%
					"老户与新民在丈量现场爆发激烈冲突，划界被迫中断。错过了最佳播种窗口，加之部众间裂痕加深，不仅耗费了公中积蓄，更令聚落人丁增长受挫。",
					[
						Shared.cash_in(5, 360),
						Shared.birth(-15, 540),
					])),
			Shared.option(
				"by_household", "按户授田，老户优先",
				"老户独占沃土",
				"长老议会维护了先民老户的优先权，肥沃河岸尽归旧族，新民仅获贫瘠坡地。老户精耕细作提升了产出并总结出历法经验，但新附氏族的怨恨已悄然埋下。",
				[
					Shared.agriculture(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"common_plough", "暂不分田，延续共耕",
				"共耕制效率下滑",
				"土地继续维持氏族公有共耕，收成由长老统一分配。虽避免了分地动荡并促进了协作技艺的交流，但缺乏私产激励致使耕作懈怠，田间产出明显回落。",
				[
					Shared.agriculture(-12, 360),
					Shared.knowledge(8, 360),
					Shared.manufacturing(8, 360),
				]),
		],
	}))

	# ═══ 公井 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_COMMON_WELL),
		"title": "{settlement_name}·公井归属",
		"body_text": "旱季将至，维系{settlement_name}全寨饮水的坡下公井却突发井壁坍塌，急需下井重砌石壁。此役既耗劳力又具风险，各氏族皆不愿白白出力。一派主张由长老议会强制征调全寨合修，修成后公井仍归众人共用；另一派实力较强的大族则愿独自包揽修缮，但要求事后执掌水权，凡取水者皆须缴纳粮物。井边排队取水的队伍日渐焦躁，水权制度亟待确立。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A stone-lined well with a collapsed side, buckets queued on the well platform at dawn, a young woman carrying a half bucket home",
		"tags": ["dawn", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.MOISTURE_LTE, "float_value": 0.50},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MOISTURE_LTE, "float_value": 0.35},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "地干，水比粮金贵",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "屋离井远，排队的就多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 16},
				"add_weight": 10,
				"reason": "人多，一桶水要分三家",
			},
		],
		"options": [
			Shared.option(
				"all_hands", "全寨合修，公井公用",
				"公井重修归于众",
				"全寨青壮暂放下农活合力重砌井壁，清冽井水重新惠及每一户人家。虽略微耽误了农时，但洁净水源保障了妇孺健康，也锤炼了部众的石作手艺。",
				[
					Shared.agriculture(-10, 360),
					Shared.birth(10, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"one_household", "大族包修，取水纳粮",
				"水权落入私门",
				"大族迅速修好井壁并派人值守，取水须按量纳献，公中亦从中抽成。井水供应虽得以维持，但饮水受制于人的屈辱感在中小氏族间迅速滋长。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.cash_in(4, 360),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"no_well", "弃井不修，远赴河滩",
				"弃井挑水苦不堪言",
				"长老议会未能达成共识，公井就此荒废。部众虽未耽误农时，却不得不每日长途往返河滩挑水，浑浊河水与繁重劳役很快拖累了聚落的人口繁衍。",
				[
					Shared.birth(-12, 540),
					Shared.agriculture(8, 360),
				]),
		],
	}))

	# ═══ 集市 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_FIRST_MARKET),
		"title": "{settlement_name}·河滩初市",
		"body_text": "入秋以来，{settlement_name}的河滩集市自发聚集了周边多个氏族与外来盐商，兽皮、陶器与食盐在此易物流通。然而缺乏规矩的交易很快引发混乱：各家自备的量器大小不一，换盐换谷屡生争执，更有商旅践踏田埂、留下一地污秽。长老议会面临抉择，是设立统一衡器并征收摊税以建秩序，还是保持绝对自由以吸引更多远方来客。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A first market on a river beach, hides, salt and clay pots laid out, a beam with two hanging baskets used as a scale",
		"tags": ["dawn", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 2,
		"required_technologies": ["tech.hand_pottery", "tech.early_trade"],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有匠人，才有东西可换",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "屋多了，各家缺的东西也多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.15},
				"add_weight": 15,
				"reason": "盐贵，远处的人才肯来",
			},
		],
		"options": [
			Shared.option(
				"free_stalls", "免租放开，任其交易",
				"自由集市熙攘无序",
				"河滩集市不设门槛，四方货殖蜂拥而至，商贸流通与手工交换随之兴旺。然而摊位挤占通道、纠纷频发，缺少仲裁的集市逐渐成为滋生摩擦的温床。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					Shared.trade_capacity(12, 540),
					Shared.manufacturing(10, 540),
				]),
			Shared.option(
				"fee_and_scale", "立公衡，征收市税",
				"公衡市税初具雏形",
				"长老议会颁布标准量器并划定摊区，按日征收市税。尽管初期繁琐规制略微抑制了部分手工业者的热情，但公信力大增，远方商队更愿前来交易。",
				[
					Shared.manufacturing(-8, 360),
					Shared.cash_in(4, 360),
					Shared.trade_capacity(15, 540),
				]),
			Shared.option(
				"let_them_weigh", "各自为衡，官不介入",
				"以物易物摩擦不断",
				"部众继续沿用各自量器讨价还价，集市在喧嚣中勉强运转。往来交流虽带来些许外界见闻，但短斤少两的猜忌推高了交易损耗，日常口粮开销随之见涨。",
				[
					Shared.staple(10, 360),
					Shared.trade_capacity(10, 540),
					Shared.knowledge(8, 360),
				]),
		],
	}))

	# ═══ 铁匠 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_FIRST_SMITH),
		"title": "{settlement_name}·初锻黑矿",
		"body_text": "先民在河谷冲积层中寻得一块质地奇特的黑矿，经烈火反复煅烧锤击后，竟能锻出远胜骨器与石器的坚硬金属。长老议会迅速围聚炉旁，为这批珍贵初锻金属的用途争执不休：农耕氏族力主锻造犁头，以深耕沃土、倍增收成；负责防卫的勇士要求打造利刃，威慑周边窥伺的部族；工匠则呼吁先制铁钉，加固岌岌可危的屋梁与车轴。金属稀缺，最初的锻造取向将深刻影响聚落的发展方向。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A black lump from a river beach heated in a fire and hammered on a stone, villagers arguing around the forge, a red-hot sliver of metal",
		"tags": ["dawn", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 1,
		"max_era_index": 2,
		"required_technologies": ["tech.natural_copper_working"],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.HAS_NATURAL_RESOURCE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "miner", "float_value": 0.03},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有人认得石头里的东西",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "屋要梁，车要轴，都缺硬家伙",
			},
			{
				"condition": {"op": Op.HAS_RIVER, "bool_value": true},
				"add_weight": 15,
				"reason": "河滩上冲下来的黑块不止一块",
			},
		],
		"options": [
			Shared.option(
				"plough_first", "优先锻造金属犁头",
				"铁犁破土农产跃升",
				"第一批金属悉数铸为犁头，深耕之效立竿见影，农田收成显著提升，工具损耗亦随之减少。唯防卫勇士因未得利器而颇感失落，聚落防务隐忧犹存。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
					Shared.agriculture(15, 540),
					Shared.tools(-10, 360),
				]),
			Shared.option(
				"blade_first", "优先锻造防身利刃",
				"利刃出炉威慑四邻",
				"炽热炉火锻出锋锐长刃，周边劫掠部族闻风退避，匠人亦借此摸清了铁矿冶炼的门道。然而抽调人力反复试锻占用了农时，当年耕作略有欠收。",
				[
					Shared.agriculture(-10, 360),
					Shared.manufacturing(8, 360),
					Shared.research_signal("resource.iron_ore", "黑石"),
				]),
			Shared.option(
				"nails_first", "锻制铁钉，加固营造",
				"营造工艺迈上新阶",
				"金属被拉拔为坚固铁钉用于加固屋梁与车具，聚落制造能力大幅增强。公中亦借分配铁件收取了一笔贡赋，但稀缺金属的争夺暂时推高了营造开销。",
				[
					Shared.cash_in(3, 360),
					Shared.manufacturing(12, 540),
					Shared.build_cost(8, 540),
				]),
		],
	}))

	# ═══ 盟誓 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_OATH_STONE),
		"title": "{settlement_name}·盟石立誓",
		"body_text": "{settlement_name}周边的山林狩猎部族与河谷农耕氏族为争夺林地边界已连年流血，双方终于同意在岭顶盟石前举行和谈。祭司主持盟誓，但围绕确保停火的质押之物，双方立场针锋相对：狩猎部族遵循古俗，要求互换孩童为质以结血缘之信；农耕氏族则只愿押上牲畜与来年良种。长老议会必须裁定盟誓之制，决定这场脆弱和平的根基。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two kin groups swearing an oath at a boundary stone on a ridge, marks being chiselled into the stone, a goat and a sack of seed set beside it",
		"tags": ["dawn", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 1,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "两边心里都有旧账",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 16},
				"add_weight": 15,
				"reason": "人多了，界上的事就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有仓有屋，才押得起种子",
			},
		],
		"options": [
			Shared.option(
				"children", "依循古俗，互换质子",
				"质子盟约维系和平",
				"两族互换子弟寄养，沉重的血缘羁绊换来了切实的边境安宁。年轻一代在异族中习得农耕与追踪之术，促进了技艺交融，但骨肉分离也短暂压低了生育意愿。",
				[
					Shared.birth(-12, 540),
					Shared.knowledge(10, 540),
					Shared.agriculture(8, 360),
				]),
			Shared.option(
				"beasts", "质押牲畜与来年良种",
				"粮畜为质勉强停火",
				"双方各出良种与牲畜交由祭司共管，林地争端暂告平息。农耕与手工业得以在和平中恢复，但抽调存粮作质令聚落当年的口粮调度略显吃紧。",
				[
					Shared.staple(10, 360),
					Shared.agriculture(10, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"cut_only", "仅刻盟文，不押人畜",
				"空文盟誓难久维系",
				"祭司仅在盟石上凿刻双方图腾记号便草草收场。未受实质约束的和平脆弱不堪，虽保住了当年农事与祭祀记录，但不过一载林地越界摩擦便再度抬头。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					Shared.knowledge(8, 360),
					Shared.agriculture(8, 360),
				]),
		],
	}))

	# ═══ 械斗 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_WATER_BRAWL),
		"title": "{settlement_name}·争水械斗",
		"body_text": "久旱少雨令河谷水位锐减，上游氏族擅自垒石筑堰，将河水尽数截入自家田亩，致使{settlement_name}下游禾苗成片枯黄。愤怒的下游农夫集结人马强行扒开石堰，双方在河湾爆发大规模械斗，多人负伤。面对一触即发的氏族血仇，长老议会必须立即介入：是强硬摧毁上游私堰、动用公粮窖赔偿和解，还是另辟新渠彻底绕开争端。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "Two groups fighting with wooden staves at a breached stone weir on a river, cracked fields downstream, water pouring through the gap",
		"tags": ["dawn", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 2,
		"required_technologies": ["tech.irrigation"],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.MOISTURE_LTE, "float_value": 0.40},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MOISTURE_LTE, "float_value": 0.28},
				"add_weight": 25,
				"multiplier_q16": MUL_130,
				"reason": "旱得狠，水就是命",
			},
			{
				"condition": {"op": Op.HAS_RIVER, "bool_value": true},
				"add_weight": 20,
				"reason": "有河可抢，才打得起来",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 15,
				"reason": "肚子空着，棍子举得快",
			},
		],
		"options": [
			Shared.option(
				"cut_them_off", "强拆私堰，放水济下",
				"破堰通水结下深仇",
				"长老议会下令彻底扒平上游石堰，河水奔涌而下挽救了下游濒枯的庄稼。然而上游氏族誓言报复，河谷两岸从此陷入更频繁的流血冲突。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.agriculture(12, 360),
				]),
			Shared.option(
				"pay_grain", "拨付公粮，调停分水",
				"出资赎水达成和解",
				"公中拨付粮物补偿上游氏族，换取对方降低堰顶高度并立下分水规约。河谷重归平静，农事稳步恢复，此次调停也沉淀出早期水利分配的制度雏形。",
				[
					Shared.cash_out(4, 360),
					Shared.agriculture(8, 540),
					Shared.knowledge(8, 540),
				]),
			Shared.option(
				"new_channel", "另凿支渠，绕开争端",
				"改道引水代价高昂",
				"下游部众耗费整月人力绕坡另凿新渠，虽被迫占用部分耕地导致当年减产，却彻底摆脱了上游掣肘，稳定的水源保障了聚落长远的人口繁衍与水利经验。",
				[
					Shared.agriculture(-12, 540),
					Shared.knowledge(8, 540),
					Shared.birth(8, 540),
				]),
		],
	}))
