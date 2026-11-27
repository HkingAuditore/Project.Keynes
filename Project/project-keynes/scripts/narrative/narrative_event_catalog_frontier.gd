class_name NarrativeEventCatalogFrontier
extends RefCounted

## 边镇包：军粮、久镇、城下的兵、质子（4 条）。
##
## 链（三幕）：
##   军粮田（脉冲，era 2–5）→ 久镇（脉冲，需完成军粮田；era 3–6）→ 城下的兵（定时，断粮分支排程）
## 孤立：
##   质子（脉冲，微观，era 2–6）
##
## 连线：久镇选"召还"会把宫廷包的"两方印"提前引爆（45 日）；
## 选"加封"会留下"边将坐大"，从此刻起商人不敢借钱（阻断国库的"借饷"）；
## 选"断粮"会先逼出"城下的兵"，再把人送回"回家的兵"。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const PACK_ID := &"frontier"
const PREFIX := "evt.frontier."

const CAST := [
	"边堡", "屯田", "戍军", "军粮", "边将", "召书", "质子", "驿馆", "关隘", "号角",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_130 := 85197
const MUL_145 := 95027


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "边镇",
		"theme": "军粮、久镇与质子",
		"era_band": "2-7",
		"prefix": PREFIX,
		"scale": "2 宏观链节 + 1 宏观收束 + 1 微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FRONTIER_SOLDIER_FARM),
			String(Ids.EVT_FRONTIER_LONG_GARRISON),
			String(Ids.EVT_FRONTIER_GENERAL_AT_GATE),
			String(Ids.EVT_FRONTIER_HOSTAGE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 军粮田 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_SOLDIER_FARM),
		"title": "{settlement_name}·军粮田",
		"body_text": "边堡外的河滩荒地绵延数里，驻军将领以连年军粮短缺为由，擅自将防线标帜内移，要求圈地开展屯田。军需官实地勘查后回报，该处土质偏旱，开垦初期恐难有收成，而戍军老卒亦抱怨军务繁重无力兼顾农事。然而若继续完全依赖后方转运，沉重的漕粮损耗将拖垮财政。是推行军屯、募民实边，还是责成营中自筹，亟待中枢裁决。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A frontier fort beside dry wasteland, stakes moved inward, a garrison officer's sword stuck in the soil, a supply clerk testing the dirt",
		"tags": ["frontier", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 2,
		"max_era_index": 5,
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.PLAIN, TerrainTypeScript.TERRAIN.FLOODPLAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "堡里养得起屯田的人",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "soldier", "float_value": 0.05},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "吃饷的人多，田就分得下去",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 15,
				"reason": "人手够开荒",
			},
		],
		"options": [
			Shared.option(
				"give_land_to_soldiers", "推行军屯，分地予戍军耕种",
				"戍军屯垦",
				"荒地按编制分拨各营，地方摊派了首批农具与种粮。首年收成虽微，但次年便初见成效，不仅缓解了军粮压力，也提升了周边农垦产出。",
				[
					Shared.agriculture(15, 360, 1, 0),
					Shared.supply(10, 360),
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（农具与种粮的摊派）"),
					Shared.bias(Ids.TAG_COURT, 1.10, 540),
				]),
			Shared.option(
				"settle_farmers", "拨款募民，迁户落籍开荒",
				"募民实边",
				"国库拨付安家费招徕大批民户迁入边堡落籍，荒原上很快建起新村。人口与农产双双增长，但新旧居民间的土地摩擦也随之显现。",
				[
					# 募来的民户是真迁入：之前只给 agriculture + birth，人在册上根本没多。
					Shared.population_rate(20, "本地人口 +20%（募民落籍屯垦）"),
					Shared.cash_out(6, 360),
					Shared.agriculture(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.option(
				"let_the_camp_provide", "责成边营自行筹措军粮",
				"营中自筹",
				"筹粮任务被层层摊派至各营与地方百姓，荒地未曾开垦分毫，摊派重负却迅速激化了军民矛盾。边军自筹粮草的先例一开，中枢威信随之削弱。",
				[
					Shared.flag(Ids.FLAG_FRONTIER_SELFRAISE, 900, "标记「营中自筹」"),
					Shared.cash_in(4, 360, "向本地人数最多的{primary_profession}征收其现金的 4%（营中摊派）"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 第 2 幕 · 久镇 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_LONG_GARRISON),
		"title": "{settlement_name}·久镇",
		"body_text": "驻守边堡的边将久镇一方已近十载，朝廷使者三度巡边，迎候礼节一次比一次怠慢，如今竟已不出堡门。营中戍军多由其一手提拔，只认将旗而不问中枢政令，边堡俨然成了独立王国。此次朝廷遣使携厚赏与召书前来调其回京，边将却只收赏赐而不拆召书，军营内外号角森严。尾大不掉之势已成，中枢必须做出抉择。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A frontier general's hall with an unopened summons and a cart of gifts, soldiers changing guard outside under his banner",
		"tags": ["frontier", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 150,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 6,
		"required_events_completed": [String(Ids.EVT_FRONTIER_SOLDIER_FARM)],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "堡子修得比县衙还厚",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_FRONTIER_SELFRAISE)},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "营里自己筹过粮，就不肯再听京里的",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 15,
				"reason": "靠他的旗吃饭的人多",
			},
		],
		"options": [
			Shared.option(
				"recall_him", "严令回京，兵权留归中枢",
				"抗命不归",
				"边将原封不动退回赏赐，拒不奉诏回京，反而率亲信南下联络宗室异己。虽暂时节省了边军补给开支，但分裂的导火索已被彻底点燃。",
				[
					Shared.supply(10, 240),
					Shared.schedule(Ids.EVT_COURT_TWO_SEALS, 45, "两方印"),
				]),
			Shared.option(
				"promote_and_leave_him", "加官进爵，承认其节度之权",
				"边将坐大",
				"朝廷赐予新节钺以换取名义上的效忠，边境商路与军需得以维持。代价是商税与文书从此皆须经其手，边将坐大的格局正式成型。",
				[
					Shared.flag(Ids.FLAG_WARLORD, 1825, "标记「边将坐大」"),
					Shared.trade_capacity(10, 540),
					Shared.supply(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"cut_his_supply", "断绝军粮，迫其交出兵权",
				"断粮激变",
				"运粮车队奉命在关隘外停发，断粮的戍军迅速陷入骚动。营中哗变接连发生，本地农事遭到劫掠，大批无粮之兵正拔营向城下开进。",
				[
					Shared.agriculture(-18, 360),
					Shared.bias(Ids.TAG_UNREST, 1.45, 540),
					Shared.schedule(Ids.EVT_FRONTIER_GENERAL_AT_GATE, 45, "城下的兵"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 城下的兵 ═══════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_GENERAL_AT_GATE),
		"title": "{settlement_name}·城下的兵",
		"body_text": "断粮七日后，边堡戍军在夜色中不宣而动，沿着河道急行军，黎明前已悉数兵临城下。领头的边将未穿全甲，按剑立于阵前，要求开启关隘与执政者当面谈判。城头守军虽已挽弓戒备，但面对昔日同袍，士气明显动摇。城外号角低沉，若强行开战恐酿成惨烈内耗，若轻易开门则城防尽失，局势已到千钧一发之际。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Unbannered soldiers at dawn before a city gate, a half-armoured general with a drawn blade, archers on the wall",
		"tags": ["frontier", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 200,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 7,
		"options": [
			Shared.option(
				"open_and_talk", "开启城门，准其单骑入城议和",
				"城下议和",
				"边将卸甲入城谈判半日，朝廷最终以地方摊派补发欠饷换取了退兵。城外哗变总算和平平息，但中枢向骄兵妥协的先例已然留下。",
				[
					Shared.cash_in(5, 360, "向本地人数最多的{primary_profession}征收其现金的 5%（补发欠饷）"),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"close_and_shoot", "紧闭城门，下令城头放箭驱离",
				"血溅城下",
				"箭雨倾泻而下，叛军丢下数十具遗体后溃退，边将负伤被亲兵救走。城池虽得以保全，但战火重创了本地作坊，财政与流兵善后接踵而至。",
				[
					Shared.manufacturing(-12, 360),
					Shared.bias(Ids.TAG_UNREST, 1.50, 540),
					Shared.schedule(Ids.EVT_FAMILY_RETURNING_SOLDIER, 60, "回家的兵"),
					Shared.schedule(Ids.EVT_FISCAL_STATE_LOAN, 90, "借饷"),
				]),
			Shared.option(
				"camp_outside_the_wall", "划地安营，准其驻扎城外对峙",
				"城外扎营",
				"戍军在城外筑起长期营垒，既不攻城也不撤离。兵营截留过往菜蔬并私设关卡，导致城内主食开销大涨，朝廷权威荡然无存。",
				[
					Shared.staple(18, 360),
					Shared.bias(Ids.TAG_COURT, 1.20, 540),
				]),
		],
	}))

	# ═══ 孤立 · 质子 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_HOSTAGE),
		"title": "{settlement_name}·质子",
		"body_text": "两年前邻邦遣送一名宗室少年入质，名义上留居驿馆研习典籍，实为维系边疆停战的筹码。两年间，这名质子不仅精通我朝官话与书法，更对本地政情与学风耳濡目染。如今西方邻邦遣使携国书与二十匹骏马前来，要求赎回质子以续邦交。朝臣意见分歧：留之可为长远棋子，放之可换取实利，亦可趁机令其充当向导探查敌情。",
		"image_key": "family.house",
		"ai_visual_prompt": "A young hostage standing at an inn gate looking at twenty horses, a letter in a rider's hand, his calligraphy on the table behind",
		"tags": ["frontier", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 15,
				"reason": "城大了，才养得起一个质子",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "soldier", "float_value": 0.03},
				"add_weight": 20,
				"reason": "边上有兵，人质才有用",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "驿馆和学堂都在城里",
			},
		],
		"options": [
			Shared.option(
				"keep_him_in_school", "婉拒赎请，留其继续深造",
				"留质育才",
				"邻邦使团空手而归，质子继续留馆研读典籍，促进了本地文教交流。朝廷为此征收了质子馆用度，而这份筹码日后是福是祸尚难预料。",
				[
					Shared.knowledge(12, 540),
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（质子馆的用度）"),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"trade_him_for_horses", "接受骏马，放还质子归国",
				"以质换马",
				"二十匹精良战马充实了本地马政与商运，质子则随使团安然离境。然而失去质子牵制后，邻邦骑兵次年便频频在边境试探，扰乱了农事。",
				[
					Shared.stock("horses", 20),
					Shared.trade_capacity(12, 360),
					Shared.agriculture(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.gamble(
				"let_him_guide", "准其归国，命其暗绘西疆路线",
				Shared.branch(39322, "暗得敌情", # 60%
					"质子借归途之便详尽测绘了西疆隐蔽渡口与水道，并秘密传回详图。这份珍贵情报大幅拓宽了我朝的地理认知与边境商路。",
					[
						Shared.knowledge(10, 540),
						Shared.trade_capacity(10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.10, 360),
					]),
				Shared.branch(26214, "误入绝境", # 40%
					"随行斥候被质子引入险峻断谷，折损战马与经费后狼狈撤回。此事不仅暴露了我方意图，也让邻邦彻底加强了边境防务。",
					[
						Shared.cash_out(5, 360),
						Shared.knowledge(-8, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
		],
	}))
