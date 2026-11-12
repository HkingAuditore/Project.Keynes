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
	"霍连", "郝仓", "田五", "段禾", "雁回堡", "军粮田", "界桩", "号角", "驿馆", "召书",
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
		"body_text": "雁回堡外那片荒地，去年还是草。都尉霍连让人把界桩往里挪了三里，说营里的粮一年比一年少。军需官郝仓蹲在田埂上翻土，翻出来的土是干的，捏一下就散。堡里的老卒田五说，这地种不出东西，他小时候在这儿放过羊。霍连不接话，把腰间的刀解下来，插在土里。远处营里的号角响了一声，该吃饭了。",
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
				"give_land_to_soldiers", "把荒地分给营里的人",
				"界桩往里挪了三里",
				"田分到人头上，一人二十亩，种什么自己定。头一年收的不够吃，郝仓在册子上记了个零。第二年夏天，田五从地里拔了一根萝卜，在袖子上擦了两下就啃。",
				[
					Shared.agriculture(5, 360, 1, 0),
					Shared.supply(10, 360),
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（农具与种粮的摊派）"),
					Shared.bias(Ids.TAG_COURT, 1.10, 540),
				]),
			Shared.option(
				"settle_farmers", "募民来种，官府给粮",
				"车拉来三十户人家",
				"车拉来三十户人家，锅碗和种子一起卸在堡外。头一冬他们住的是地窨子，开春才垒墙。霍连去看过两回，第二回带了一扇猪肉。",
				[
					Shared.cash_out(2.5, 360),
					Shared.agriculture(3, 540),
					Shared.birth(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.option(
				"let_the_camp_provide", "让营里自己去筹",
				"册子上多了一行字",
				"霍连把筹粮的差事派给各营，营里再派给队，队里派到人头。堡外的荒地没动，堡里的粮价先动了。郝仓在册子上记了一笔，写完把笔搁下，没盖印。",
				[
					Shared.flag(Ids.FLAG_FRONTIER_SELFRAISE, 900, "标记「营中自筹」"),
					Shared.cash_in(1.5, 360, "向本地人数最多的{primary_profession}征收其现金的 1.5%（营中摊派）"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 第 2 幕 · 久镇 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_LONG_GARRISON),
		"title": "{settlement_name}·久镇",
		"body_text": "霍连在雁回堡待了九年。朝廷的使者来了三次，第一次他出城十里接，第二次在堡门口，第三次没出城门。堡里的兵只认他的旗，不认京里发下来的文书。使者这次带了一封召他回京的信，还有一车赏赐。霍连把信放在案上，没拆，先让人把赏赐搬进库房。田五在旁边看着，说这车东西比去年的饷还多。窗外，兵在换防，旗子没动。",
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
				"recall_him", "召他回京，兵留在堡里",
				"召书没拆",
				"召书送到堡里，霍连没拆，先让田五把马喂了。第三天，西边传来消息，说他没往京里去。使者回来时，车上的赏赐一件没少，人也一根头发没少。",
				[
					Shared.supply(10, 240),
					Shared.schedule(Ids.EVT_COURT_TWO_SEALS, 45, "两方印"),
				]),
			Shared.option(
				"promote_and_leave_him", "加他的官，让他自己守",
				"旗子换了颜色",
				"新的旗号送进堡里，霍连把旧旗收起来，没扔。商队开始从堡前过，每辆车抽一份，帐记在他自己的人手里。京里来的文书从此要先经他的手。",
				[
					Shared.flag(Ids.FLAG_WARLORD, 1825, "标记「边将坐大」"),
					Shared.trade_capacity(4, 540),
					Shared.supply(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"cut_his_supply", "断他的粮",
				"粮车在道上停了",
				"粮车在离堡四十里的地方停了，押车的说是上头的意思。堡里的兵先杀马，后开堡门出去找粮。田五在夜里听见有人磨刀，磨了很久，更鼓敲过二遍，营里空了一半。",
				[
					Shared.agriculture(-6, 360),
					Shared.bias(Ids.TAG_UNREST, 1.45, 540),
					Shared.schedule(Ids.EVT_FRONTIER_GENERAL_AT_GATE, 45, "城下的兵"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 城下的兵 ═══════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_GENERAL_AT_GATE),
		"title": "{settlement_name}·城下的兵",
		"body_text": "营里的兵是在第七天夜里出营的。他们没有打旗，沿着河走，天亮时到了城下。霍连走在最前面，甲没穿全，手里提着一把刀。城头的守兵把弓拉满，没人放箭。田五在队伍里，看见城墙上有个熟人，那人把脸转过去了。霍连抬头看了看城门，说开门，他要跟管事的说一句话。",
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
				"open_and_talk", "开城门，让他进来说",
				"他一个人进了城",
				"城门开了一条缝，霍连把刀交给田五，一个人进来。谈了半日，他出来时天上在下雨。兵在城外等到雨停，然后各回各的营，旗还是没打。",
				[
					Shared.cash_in(2.0, 360, "向本地人数最多的{primary_profession}征收其现金的 2%（补发欠饷）"),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"close_and_shoot", "闭门，放箭",
				"城下留了十几具尸首",
				"箭从城头下去，第一排人倒了，后面的人没退，往前挤。霍连挨了两箭，被自己的人拖走。收兵时城下留着十几具尸首，田五不在里面，也没有人找他。",
				[
					Shared.manufacturing(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.50, 540),
					Shared.schedule(Ids.EVT_FAMILY_RETURNING_SOLDIER, 60, "回家的兵"),
					Shared.schedule(Ids.EVT_FISCAL_STATE_LOAN, 90, "借饷"),
				]),
			Shared.option(
				"camp_outside_the_wall", "让他在城外扎营",
				"城下多了一片帐篷",
				"城下多了一片帐篷，兵不进也不走。他们在城外支锅、喂马、跟进城卖菜的人讨价。入冬后帐篷换成了土坯，城门口的税收到两份。",
				[
					Shared.staple(6, 360),
					Shared.bias(Ids.TAG_COURT, 1.20, 540),
				]),
		],
	}))

	# ═══ 孤立 · 质子 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FRONTIER_HOSTAGE),
		"title": "{settlement_name}·质子",
		"body_text": "段禾是前年送来的，说是来读书，其实是做人质。他在驿馆住了两年，学会了本地的口音，会写这里的字，写得比本地孩子还工整。教他的老先生说，这孩子记性好，可惜姓段。今天西边来了人，带着一封信和二十匹好马，说要接他回去。段禾站在驿馆门口，看着那二十匹马，没有动。",
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
				"keep_him_in_school", "留他读书，别放回去",
				"他又抄了一部书",
				"西边的人牵着马走了。段禾回屋里，把没抄完的那卷抄完，字比前一天更工整。老先生在门口站了一会儿，说这孩子将来要么很有用，要么很麻烦。",
				[
					Shared.knowledge(4, 540),
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（质子馆的用度）"),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"trade_him_for_horses", "换马，让他走",
				"二十匹马进了马厩",
				"二十匹马进了马厩，段禾跟着西边的人出了西门。走到坡上他回了一次头，城里的钟正好响。第二年秋天，西边的马队又来了，这次没带信。",
				[
					Shared.stock("horses", 20),
					Shared.trade_capacity(5, 360),
					Shared.agriculture(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.gamble(
				"let_him_guide", "让他带路，回西边去",
				Shared.branch(39322, "他记得每一条水沟", # 60%
					"段禾带着人往西走，走的不是官道，是水沟和羊肠。第七天他们摸到一处没设防的渡口。他把路线画在纸上，画完把纸折好，没要赏。",
					[
						Shared.knowledge(3, 540),
						Shared.trade_capacity(4, 360),
						Shared.bias(Ids.TAG_UNREST, 1.10, 360),
					]),
				Shared.branch(26214, "他带错了路", # 40%
					"走到第五天，前面是一条断沟。带路的人说段禾记错了，段禾不说话。队伍折回来时丢了两匹马，从此西边再来人，都带着自己的向导。",
					[
						Shared.cash_out(2.0, 360),
						Shared.knowledge(-2, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
		],
	}))
