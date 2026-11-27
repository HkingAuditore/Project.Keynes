class_name NarrativeEventCatalogPlague
extends RefCounted

## 疫与医包：热病来了以后，人怎么过日子（7 条，全部孤立）。
##
##   疫船（沿海+人口，era 2–8）· 隔离（人口+屋，era 2–9）· 产褥热（人口，era 1–8）
##   药圃（人口+屋，era 1–7）· 医院（屋+人口，era 5–9）
##   疫苗（屋+学者，era 6–9）· 庸医（人口，era 2–9）
##
## 没有一条接链：不写旗标、不排后续，全部走 PULSE_SAMPLED 自己进池。
## 两个"赌一把"：隔离只封病家、疫苗先拿孩子试，其余十九条结果都是定的。
##
## 数值口径：这一包不解释病理，只结账。代价落在出生率、主食开销、本地人头上的摊派、
## 与人心（unrest / market 类事件权重）上；产出修正只用来表示一条街停了工这种后果。
## 时代白话一律说热病、烂喉、痘，不写真实疫病名，也不借真实人物。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"plague"
const PREFIX := "evt.plague."

const CAST := [
	"医政署", "地方官署", "商旅船队", "隔离封锁线", "病籍名册",
	"济贫医馆", "药草官圃", "接生旧俗", "种痘方术", "市井民众",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "疫与医",
		"theme": "热病过境时，人怎么分饭、封街、洗手、试药",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_PLAGUE_SHIP),
			String(Ids.EVT_PLAGUE_QUARANTINE),
			String(Ids.EVT_PLAGUE_MIDWIFE),
			String(Ids.EVT_PLAGUE_HERBS),
			String(Ids.EVT_PLAGUE_HOSPITAL),
			String(Ids.EVT_PLAGUE_VACCINE),
			String(Ids.EVT_PLAGUE_QUACK),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 一 · 疫船 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_SHIP),
		"title": "{settlement_name}·疫船",
		"body_text": "一艘满载食盐与铁料的外来商旅船队在{settlement_name}口外下锚，船首高悬疫病警示白布。医政署派员查验后急报，底舱已有数名水手身染烈性热病，随时可能蔓延上岸。船主坚持只求卸货便即刻离港，本地商贾亦觊觎这批紧俏物资；然而港口劳工与市井民众人心惶惶，纷纷要求地方官署严防死守，哪怕焚船驱离亦不可放疫入城。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A three-masted ship anchored outside a small harbour, a strip of white cloth on its bow, a rowboat with one man watching from the water",
		"tags": ["plague", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"multiplier_q16": MUL_120,
				"reason": "码头上有人做买卖，才有人敢接这条船",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.05},
				"add_weight": 20,
				"reason": "盐一紧，就有人想赌这一船",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "屋挤在一处，病传得快",
			},
		],
		"options": [
			Shared.option(
				"let_it_dock", "准许靠岸，优先卸货",
				"货通港城疫病登岸",
				"紧俏盐铁顺利入库，港口贸易运力与工坊制造随之提振。然而热病当夜便在码头扩散，全城人丁因此蒙受折损。",
				[
					Shared.trade_capacity(12, 360),
					Shared.manufacturing(12, 360),
					Shared.population_rate(-8),
				]),
			Shared.option(
				"burn_it_off", "下令焚船，彻底驱离",
				"烈焰断疫商路受挫",
				"巡防队纵火焚毁疫船，口外浓烟彻夜不散。强硬手段虽挡住了热病，却重创港口制造与主食周转，商民惊恐怨恨交加。",
				[
					Shared.manufacturing(-12, 540),
					Shared.staple(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"hold_at_anchor", "滞留口外，按日补给",
				"严守锚地静待疫熄",
				"地方官署按户摊派护港费，雇小艇每日向口外疫船运送水粮。直至船上再无声息，全城方得安宁，唯口粮供给略显吃紧。",
				[
					Shared.cash_in(3, 360,
						"向本地人数最多的{primary_profession}征收其现金的 3%（护港摊派，按户收）"),
					Shared.staple(10, 360),
				]),
		],
	}))

	# ═══ 二 · 隔离 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_QUARANTINE),
		"title": "{settlement_name}·隔离",
		"body_text": "{settlement_name}人口稠密的旧街区爆发烈性热病，数户居民接连病倒。地方官署与医政署火速设立隔离封锁线，逐户登记病籍名册并定时投放口粮。如今朝野对封控尺度争执不下：主严派要求彻底钉死整片街区，不惜令作坊停摆也要阻断传播；务实派则主张仅封锁确诊病家以保农商运转，或直接将病患迁往城外搭棚集中照看，唯需向地方摊派额外照护经费。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A narrow lane blocked by planks with a white cloth strip, a meal bucket left on a stone, lime dust blowing at dusk",
		"tags": ["plague", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 660,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 25,
				"multiplier_q16": MUL_110,
				"reason": "巷子越密，越封不住",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "人心已经散了，封街就有人翻墙",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.25},
				"multiplier_q16": MUL_115,
				"reason": "种地的人一天不出门，地就荒一天",
			},
		],
		"options": [
			Shared.option(
				"nail_the_lanes", "严封整片街区，禁止出入",
				"铁腕封控民怨沸腾",
				"官署派兵加固封锁木板并严禁越界，疫势虽被压制，却令周边工坊停摆、主食供给吃紧，被困居民的怨怒一触即发。",
				[
					Shared.manufacturing(-12, 540),
					Shared.staple(15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.gamble(
				"seal_only_the_sick", "仅封病家，余户照常生计",
				Shared.branch(39322, "精准控疫城池安然", # 六成
					"国库拨款保障病家补给，病籍名册再未添新名。封锁如期撤除，全城农事与市面运转未受大碍。",
					[
						Shared.agriculture(10, 360),
						Shared.cash_out(3, 360),
					]),
				Shared.branch(26214, "管控失守疫势复燃", # 四成
					"封锁松动令热病迅速波及邻巷，官署被迫仓促加严封控。疫情扩散致使人丁受损，城中恐慌与动荡随之加剧。",
					[
						Shared.population_rate(-10),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"move_them_out", "迁往城外，摊派雇人照护",
				"城外设棚移治病患",
				"官署向地方摊派筹款，在城外河滩搭棚集中收治并详录病程，积累了宝贵医知。唯棚区条件简陋，仍有不少病患不治。",
				[
					Shared.cash_in(4, 540,
						"向本地人数最多的{primary_profession}征收其现金的 4%（雇人照看的工钱）"),
					Shared.population_rate(-5),
					Shared.knowledge(10, 360),
				]),
		],
	}))

	# ═══ 三 · 产褥热 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_MIDWIFE),
		"title": "{settlement_name}·产褥热",
		"body_text": "{settlement_name}近期接连发生多起产妇死于产后热病的惨剧。医政署派驻的革新医官查验后指出，根源在于民间沿袭已久的接生旧俗，力主颁布政令强制产婆在接生前一律修剪指甲并以滚水反复烫洗手具。然而地方产婆与保守市井民众抵触情绪强烈，斥责新规繁琐耗柴、侮辱老手艺，地方官署须决断是否强推这项卫生改革。",
		"image_key": "family.house",
		"ai_visual_prompt": "An old midwife with stained hands standing at a doorway beside a steaming copper basin, a young physician with a bag behind her",
		"tags": ["plague", "people", "faith"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "人口聚起来，产床就不够用",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "日子紧的人家，请不起大夫",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 15,
				"reason": "粮贵，产妇吃得更少",
			},
		],
		"options": [
			Shared.option(
				"boil_the_basin", "颁令推行滚水洁手新规",
				"洁手新规显著保命",
				"官署严令各地接生一律备置铜盆滚水洁手，虽略增器具消耗，但产妇与新生儿存活率大幅提升，新医理亦得以确立。",
				[
					Shared.birth(18, 540),
					Shared.tools(10, 540),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"keep_the_old_way", "顺应民间，沿用旧俗",
				"墨守旧俗产厄频发",
				"官署未予干预，产婆仍沿旧法接生。次年产褥热再度肆虐，城中人丁蒙受损失，医政革新亦因缺乏公信而受挫。",
				[
					Shared.population_rate(-6),
					Shared.knowledge(-8, 360),
				]),
			Shared.option(
				"wash_in_summer_only", "折中推行，夏洗冬省",
				"半途妥协学理难立",
				"官署仅令伏天烧水洁手、寒冬听任省柴。此举虽保住部分母婴性命，却令医政规程流于敷衍，正统医学认知反受削弱。",
				[
					Shared.birth(8, 540),
					Shared.knowledge(-10, 540),
				]),
		],
	}))

	# ═══ 四 · 药圃 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_HERBS),
		"title": "{settlement_name}·药圃",
		"body_text": "时疫横行之际，{settlement_name}坡上的药草官圃成为全城退烧救命的最后指望，圃中历时数年方才成片的苦蒿引来无数市井民众围堵讨药。医政署管圃官吏警告，苦蒿若连根拔除，整片山坡数载之内都将寸草不生。然而面对门外危在旦夕的病患家属，地方官署面临艰难取舍，须在竭泽采挖、只摘药叶保根与封圃摊派外购之间立刻决断。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A hillside herb plot fenced with thorn branches, an old gatherer squatting with a hoe across the rows, a queue of villagers at the gate",
		"tags": ["plague", "people", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 660,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.VEGETATION_IN,
					"int_list": [VegetationTypeScript.VEG.TEMPERATE_DECIDUOUS,
						VegetationTypeScript.VEG.TEMPERATE_CONIFER,
						VegetationTypeScript.VEG.SUBTROPICAL_FOREST,
						VegetationTypeScript.VEG.TEMPERATE_GRASSLAND]},
				"multiplier_q16": MUL_120,
				"reason": "坡上有林子，才长得住药",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "有人家，才有人开圃",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
				"add_weight": 10,
				"reason": "种地的人也认得几味草",
			},
		],
		"options": [
			Shared.option(
				"dig_it_all", "连根采挖，竭力救人",
				"救回人丁药圃尽毁",
				"官圃苦蒿被连根挖尽煎汤施药，大批高热病患转危为安。然而山坡表土翻毁、药根断绝，本地农垦产出随之受损。",
				[
					Shared.birth(15, 540),
					Shared.agriculture(-12, 540),
				]),
			Shared.option(
				"leaves_only", "限采药叶，保全根系",
				"留根存种重患难救",
				"官署严令只摘叶片不伤药根，并记录下苦蒿再生之法充实医籍。但药效大减令部分重症病患未能熬过寒冬，人丁略有折损。",
				[
					Shared.population_rate(-5),
					Shared.knowledge(10, 360),
				]),
			Shared.option(
				"fence_and_buy", "封圃护种，摊派外购",
				"摊派购药工坊受累",
				"药草官圃被严密围封保护，地方官署按户摊派筹资从水路购药应急。然征费与转运调度抽紧了地方资源，工坊制造随之承压。",
				[
					Shared.cash_in(4, 540,
						"向本地人数最多的{primary_profession}征收其现金的 4%（买药摊派）"),
					Shared.manufacturing(-10, 540),
				]),
		],
	}))

	# ═══ 五 · 医院 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_HOSPITAL),
		"title": "{settlement_name}·医院",
		"body_text": "医政署在{settlement_name}租用空仓改建的济贫医馆人满为患，病籍名册上登记的尽是码头力夫、纤夫与贫苦工匠。医馆坚持免收诊金并赊账配药，如今仓租与药债债台高筑，药商已断绝赊供，医馆随时面临关门歇业。地方官署须决定如何填补这笔亏空：动用国库直接拨款补贴、向全城居民按户摊派药费，抑或开放本地大商号认捐冠名以换取资助。",
		"image_key": "family.house",
		"ai_visual_prompt": "Two rented warehouses turned into a ward, rows of plank beds with the poor, a physician holding a ledger open at a blank page",
		"tags": ["plague", "people", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 780,
		"min_era_index": 5,
		"max_era_index": 9,
		"required_technologies": ["tech.public_health"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 25,
				"multiplier_q16": MUL_110,
				"reason": "屋多了，才腾得出两间空仓",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.40},
				"add_weight": 25,
				"reason": "人已经撑不住了，才会来躺这两间仓",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.08},
				"multiplier_q16": MUL_115,
				"reason": "做工的人一病，整条街就停了",
			},
		],
		"options": [
			Shared.option(
				"ask_the_treasury", "国库拨款，维持官办",
				"公帑续命医籍日丰",
				"国库批复专款维系医馆运转，医官借此整理出详尽病案充实学识。唯资金仍显紧俏，抽调人手照护亦略微拖慢了周边工坊。",
				[
					Shared.cash_out(4, 540),
					Shared.knowledge(12, 360),
					Shared.manufacturing(-10, 540),
				]),
			Shared.option(
				"levy_the_households", "按户摊派，共担药资",
				"摊派筹款病患得救",
				"地方官署按户强征药费填平了医馆亏空，贫苦病患得以继续收治、人口略有回升，唯屡次摊派令市井百姓怨声颇重。",
				[
					Shared.cash_in(5, 540),
					Shared.birth(8, 540),
				]),
			Shared.option(
				"let_the_firms_endow", "引入商号认捐并配资",
				"商号冠名医政旁落",
				"国库辅以少量配资并准许大商号刻名认捐，商业势力借机扩大声望。然而医馆沦为名利场，医官精力耗于应酬，医学研习反受荒废。",
				[
					Shared.cash_out(3, 540),
					Shared.bias(Ids.TAG_MARKET, 1.15, 540),
					Shared.knowledge(-8, 540),
				]),
		],
	}))

	# ═══ 六 · 疫苗 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_VACCINE),
		"title": "{settlement_name}·疫苗",
		"body_text": "医政署遣赴外域考察的医官带回一套尚未验证的种痘方术，声称将干燥痘痂研末接种于孩童体内，引发轻症后便可终身免疫烈性痘疫。然而此术闻所未闻，市井民众与药铺掌柜皆深怀畏惧，无一家庭愿拿骨肉冒险试药。地方官署面临艰难抉择：强行遴选孩童先行试种、出重金向地方筹资招募自愿者，抑或再等一年待外域确凿实绩传来再议。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A physician unwrapping a small oil-paper packet of dried scabs, a father with his hand flat on a doorframe, neighbours watching from behind a counter",
		"tags": ["plague", "people", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 840,
		"min_era_index": 6,
		"max_era_index": 9,
		"required_technologies": ["tech.public_health"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.03},
				"multiplier_q16": MUL_130,
				"reason": "有读书人，才有人肯试",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "有屋子收得住孩子",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "时候到了，南边的信才有人信",
			},
		],
		"options": [
			Shared.gamble(
				"try_it_on_a_child", "下令遴选幼童先行试种",
				Shared.branch(42598, "试种告捷痘疫渐息", # 六成半
					"受试孩童仅发轻热数日便告痊愈，国库随即拨款推广种痘方术。城中幼童存活率大增，本国医学认知亦迈出关键一步。",
					[
						Shared.birth(18, 540),
						Shared.knowledge(15, 360),
						Shared.cash_out(3, 540),
					]),
				Shared.branch(22938, "试种夭折民情大哗", # 三成半
					"受试孩童高烧不退最终夭折，残存痘痂被愤怒的民众付之一炬。此番惨剧重创人口信心，城中反抗医政的怨潮迅速蔓延。",
					[
						Shared.population_rate(-10),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"wait_one_more_year", "暂缓推行，静候外域实绩",
				"延宕一年幼童多殇",
				"外域确信直到隆冬方才传回，证实种痘有效。然这一年延宕已令城中大批孩童死于痘疫，本地医学探索也落于人后。",
				[
					Shared.knowledge(-12, 540),
					Shared.population_rate(-6),
				]),
			Shared.option(
				"buy_a_volunteer", "筹资悬赏，招募试药者",
				"重金募试犹有折损",
				"官署按户摊派并由国库贴补，终以重金募得贫户幼童试种。虽免于强征抗拒，但仓促施术仍致人丁受损，舆论颇多非议。",
				[
					Shared.cash_in(5, 540,
						"向本地人数最多的{primary_profession}征收其现金的 5%（凑给试药人家的钱）"),
					Shared.population_rate(-3),
					Shared.cash_out(3, 540),
				]),
		],
	}))

	# ═══ 七 · 庸医 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_QUACK),
		"title": "{settlement_name}·庸医",
		"body_text": "一名游方术士在{settlement_name}闹市设摊兜售所谓包治热病与烂喉的神药，因索价低廉且夸口立效，排队购药的市井民众络绎不绝，门庭远盛于正统医馆。医政署暗中化验后证实药瓶内不过是糖水兑烈酒，痛陈其贻误病情、草菅人命，敦请地方官署立刻取缔驱逐。但财政吏员提出可借机发照征税纳管，也有人建议动用公费当街化验以正视听。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A quack's table at a market corner with seven identical bottles tied with red cloth, a long queue, a physician watching from across the street",
		"tags": ["plague", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 660,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 25,
				"reason": "大夫治不好的时候，人就去找便宜的",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 20,
				"reason": "粮一贵，买药的钱就只够买一瓶",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.01},
				"multiplier_q16": MUL_115,
				"reason": "集市上有人流，摊子才摆得下去",
			},
		],
		"options": [
			Shared.option(
				"drive_him_out", "查抄药摊，驱逐出境",
				"铁腕取缔民怨暗生",
				"巡防队当街捣毁假药摊并将术士逐出城外，正统医政权威得以维护。但买不起良药的底层病患愤懑不已，城中怨气随之滋长。",
				[
					Shared.knowledge(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"tax_him", "准其设摊，按月征税",
				"征税背书延误病机",
				"官署颁发执照并按月抽税，公库进项颇丰。然而官府准许反令百姓对假药深信不疑，无数病患因延误诊治而折损性命。",
				[
					Shared.cash_in(4, 540),
					Shared.population_rate(-6),
				]),
			Shared.option(
				"test_it_in_the_street", "拨款当街验药，以正视听",
				"公费辟谣反遭疑谤",
				"医政署动用公款当街析出糖水沉渣，围观者却半信半疑，反谣传官医嫉贤妒能。此举徒耗经费，更令正统医政公信受损。",
				[
					Shared.knowledge(-10, 540),
					Shared.cash_out(3, 540),
				]),
		],
	}))
