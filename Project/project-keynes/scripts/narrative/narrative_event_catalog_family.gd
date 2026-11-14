class_name NarrativeEventCatalogFamily
extends RefCounted

## 人与家：四件小事（微观，全部孤立，但彼此有回声）。
##
##   次子（era 1–6）→ 分家 / 抽丁（抽丁会排程"回家的兵"）
##   聘礼（era 1–7）→ 读"坡地新户 / 分家未决"两个标记，聘礼的价码随家产状态浮动
##   父债（era 2–9）→ 旧债未销会自己回头，债主下次来得更硬
##   回家的兵（era 2–9）→ 也会由边镇包的"城下的兵"收场时排程
##
## 这一包不写国家大事：幅度 3–4%，钱 1.0–1.5%，代价落在"多一双筷子、少一个劳力、门口多一句闲话"。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"family"
const PREFIX := "evt.family."

const CAST := [
	"罗长庚", "罗小满", "罗广田", "岑九", "甘守业", "甘杏", "韦全", "陶婶", "蒲掌柜", "邵平",
	"阿棠", "鸦关", "河埠", "磨盘", "地契", "字据", "名簿",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "人与家",
		"theme": "分家、婚事、债与回来的人",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "4 条微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAMILY_SECOND_SON),
			String(Ids.EVT_FAMILY_BRIDE_PRICE),
			String(Ids.EVT_FAMILY_FATHERS_DEBT),
			String(Ids.EVT_FAMILY_RETURNING_SOLDIER),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 次子 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_SECOND_SON),
		"title": "{settlement_name}·次子",
		"body_text": "分家的单子摊在磨盘上，墨还没干。罗长庚把地契折起来塞进怀里，又伸手按了按。罗小满站在门边，脚下一个包袱，两身衣裳，半袋种子。他问过里正：坡上的荒地开出来算谁的。里正说，算开的人。岑九念完最后一行，问有没有话说，屋里没人应。罗广田坐在灶前添柴，说地跟着姓走，不跟着人走。罗小满把包袱提起来，布带子勒进肩膀，站在门槛上等一句话。",
		"image_key": "family.house",
		"ai_visual_prompt": "A family division deed spread on a millstone, a younger son with a cloth bundle at the threshold, an elder folding the land deed",
		"tags": ["people", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.40},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "地少人多，次子最先被挤出去",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "日子紧，分家提得早",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "村里有了空屋，分出去才有地方住",
			},
		],
		"options": [
			Shared.option(
				"give_him_the_slope", "分他坡上三亩",
				"坡上起了新屋",
				"坡地的草根挖了三天，罗小满在坡顶立起两间土房，房梁是他从河滩上拖回来的。罗长庚来看过一回，站在门口没进去，说了一句，这坡漏水。秋后两家的谷分开晒，晒场上用石头划了一道线。",
				[
					Shared.agriculture(4, 540),
					Shared.staple(4, 360),
					Shared.flag(Ids.FLAG_SECOND_SON_SPLIT, 900, "标记「坡地新户」"),
				]),
			Shared.option(
				"send_him_to_the_camp", "送他去营里吃粮",
				"他吃了军粮",
				"罗小满跟着征丁的车走了，只带走那半袋种子，说营里管饭。罗长庚把坡地也圈进自家地里，界石往外挪了两步，没人拦。第二年秋，村口来了个人，左边袖子是空的。",
				[
					Shared.agriculture(-3, 360),
					Shared.schedule(Ids.EVT_FAMILY_RETURNING_SOLDIER, 210, "回家的兵"),
				]),
			Shared.option(
				"wait_until_autumn", "不分，等秋后再议",
				"单子压在匣底",
				"单子折了三折，压在祠堂的匣子底下。那年秋收两家还是一个灶，罗小满吃饭时话少了，筷子在碗沿上敲。罗长庚的媳妇开始把油罐往自己屋里搬，一次挪一寸。",
				[
					Shared.agriculture(3, 270),
					Shared.staple(3, 360),
					Shared.flag(Ids.FLAG_SECOND_SON_PENDING, 540, "标记「分家未决」"),
					Shared.bias(Ids.TAG_PEOPLE, 1.20, 540),
				]),
		],
	}))

	# ═══ 聘礼 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_BRIDE_PRICE),
		"title": "{settlement_name}·聘礼",
		"body_text": "甘家的堂屋摆了两张桌，一张放布和酒，一张放纸笔。甘守业不喝韦家送来的酒，只看纸上写的地。他要三亩水田，写在女儿名下，少一亩不谈。韦全说水田没有，坡地可以给两块，再替甘家还那笔旧债。媒人陶婶两头传话，鞋底在门槛上蹭得响。甘杏在里屋绞一根线，线断了两次。岑九把笔搁下，说写哪一样，你们先定。",
		"image_key": "family.house",
		"ai_visual_prompt": "A betrothal negotiation with cloth, wine and a deed on two tables, a matchmaker at the threshold, a daughter winding thread inside",
		"tags": ["people", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有人抬价，聘礼就浮起来",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "越穷越要在聘礼上找补",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SECOND_SON_SPLIT)},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "新户多了，聘礼要得更硬",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SECOND_SON_PENDING)},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "家产没分，亲家不敢定",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_BRIDE_PENDING)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "去年没谈成，今年还得谈",
			},
		],
		"options": [
			Shared.option(
				"sign_the_deed", "照甘家写的立契",
				"婚书写在红纸上",
				"婚书写在红纸上，按了三个印。酒席摆了六桌，甘家那头来了两车人。韦全喝到第二碗就不说话了，眼睛盯着院角那头牛；开春耕地，韦家的犁得从甘家的田里过。",
				[
					Shared.agriculture(-3, 360),
					Shared.birth(4, 540),
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（婚书立契，官账抽一份）"),
				]),
			Shared.gamble(
				"swap_slope_for_debt", "用坡地和旧债抵聘",
				Shared.branch(39322, "甘家收了坡地", # 60%
					"甘家收了坡地，也收了韦家还的那笔钱。立契那天甘守业没笑，只在契尾多按了一个印。第二年两块坡地种上豆，收成薄，甘杏回娘家时带了一斗。",
					[
						Shared.agriculture(3, 540),
						Shared.cash_out(1.0, 360),
						Shared.bias(Ids.TAG_UNREST, 1.10, 540),
					]),
				Shared.branch(26214, "甘家把茶泼了", # 40%
					"甘守业把茶泼在门槛外，让人把布和酒都提回去。三个月后甘杏许给了河埠一户姓邬的。韦全再去甘家，门关着，院里的狗认得他，叫了两声就不叫了。",
					[
						Shared.birth(-3, 540),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					])),
			Shared.option(
				"wait_a_year", "婚书先不写，再看一年",
				"两张桌撤了一张",
				"两张桌撤了一张，布和酒都提回韦家。甘杏那根线接上又断，她索性把线团收了。第二年来说亲的来了两家，甘守业都嫌远；岑九再提韦家，他说再看一年。",
				[
					Shared.birth(-3, 540),
					Shared.flag(Ids.FLAG_BRIDE_PENDING, 540, "标记「婚书未立」"),
					Shared.bias(Ids.TAG_PEOPLE, 1.20, 540),
				]),
		],
	}))

	# ═══ 父债 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_FATHERS_DEBT),
		"title": "{settlement_name}·父债",
		"body_text": "邵平把他爹埋在西坡，回来时鞋上的泥还没干。院门口站着钱铺的蒲掌柜，手里一张字据，纸边磨得起毛。字据上是他爹的印，红得发暗。蒲掌柜把纸摊在石桌上，用一根指头压住角，风一吹，纸就响。邵平说家里只剩两间土房、一头驴、坡上还没割的谷。蒲掌柜没接话，从袖子里摸出印泥盒，放在纸旁边，盒盖开着。院里那头驴叫了一声，没人去管。",
		"image_key": "family.house",
		"ai_visual_prompt": "A moneylender pressing a worn promissory note on a stone table with an open seal-ink box, a donkey in the yard",
		"tags": ["people", "fiscal", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 600,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.SATISFACTION_LTE, "float_value": 0.45},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "还不上，才来讨",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_DEBT_PENDING)},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "旧债没销，债主下次来得更硬",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有几间铺子，才有人拿得出字据",
			},
		],
		"options": [
			Shared.option(
				"sell_and_settle", "卖驴卖坡，一次还清",
				"驴是清早牵走的",
				"驴是清早牵走的，邵平没送到村口。蒲掌柜在字据背面画了一道，把纸还给他，说留着吧，日后好说话。开春犁地，邵平借了邻家的牛，犁到一半，牛不肯走。",
				[
					Shared.agriculture(-3, 360),
					Shared.cash_in(1.5, 360, "向本地人数最多的{primary_profession}征收其现金的 1.5%（债款过官账代还）"),
				]),
			Shared.option(
				"acknowledge_and_repay", "认账，分三季还",
				"字据上加了一行",
				"岑九在字据上加了一行：分三季还，秋后先给一半。蒲掌柜按了印，走时在院里站了一会儿，看那头驴。那年秋收，邵平家的谷先进了蒲家的仓，自己留下的都是碎的。",
				[
					Shared.agriculture(4, 540),
					Shared.staple(4, 360),
				]),
			Shared.option(
				"put_it_under_the_rice_jar", "压着不办，等他自己来",
				"纸压在米缸底下",
				"字据折起来，压在米缸底下。邵平把丧事办得体面，吹鼓手请了六个。入冬后蒲掌柜再没进过这条巷子，来赊种子的邻人在门口站了半天，走了；第二年开春，坡上有两块地空着。",
				[
					Shared.agriculture(-3, 360),
					Shared.flag(Ids.FLAG_DEBT_PENDING, 540, "标记「债字未销」"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 回家的兵 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_RETURNING_SOLDIER),
		"title": "{settlement_name}·回家的兵",
		"body_text": "他从鸦关回来，走了十九天。左边袖子空着，掖在腰带里，走快了就晃。家门是新换的，门框上他当年按的手印还在，浅了一层。阿棠从灶屋出来，先看他的袖子，再往他身后看。他哥不在，去河埠扛包，三天回一趟。里正岑九拿来一册名簿，翻到他的名字，说抚恤要往上报，得有人作保。他把包袱放在门槛上，人站在门外，没进去。",
		"image_key": "family.house",
		"ai_visual_prompt": "A one-armed soldier returning to a village door, a bundle on the threshold, a village clerk holding a register",
		"tags": ["people", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "回来的人先找不到活",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 25,
				"reason": "家里本来就挤",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有活可干，人才留得住",
			},
		],
		"options": [
			Shared.option(
				"clear_the_west_room", "把西屋收拾出来给他",
				"西屋的粮挪到灶边",
				"西屋的粮挪到灶边，腾出来的地方铺了一层干草。他用一只手编筐，编得慢，编出来的筐比别人的深。阿棠每天多舀半勺米，舀了半个月，开始把勺子在锅沿上磕。",
				[
					Shared.manufacturing(3, 540),
					Shared.staple(4, 360),
				]),
			Shared.option(
				"report_for_a_stipend", "报上去，领一份抚恤",
				"名簿上多了一行",
				"岑九在名簿上添了一行，写明缺一手，抚恤按半份算。钱在腊月里发下来，先到里正手上，再到哥嫂手里，最后到他手里剩一小把。他把那把钱包在布里，塞进墙缝。",
				[
					Shared.cash_out(1.2, 360),
					Shared.bias(Ids.TAG_PEOPLE, 1.15, 540),
				]),
			Shared.option(
				"sleep_in_the_woodshed", "柴房先住着，名分再说",
				"柴房的门帘是新的",
				"柴房的门帘是阿棠用旧布拼的，拼得齐整。他夜里睡在柴堆边上，白天坐在门槛上削一根木棍，削完就搁着。入冬后村里的孩子路过，会朝柴房里看一眼，被他看一眼就跑了。",
				[
					Shared.staple(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))
