class_name NarrativeEventCatalogFaith
extends RefCounted

## 信仰包：教门、书与名分（4 条）。
##
## 链（三幕）：
##   寺产（脉冲，era 2–5）→ 一本书（脉冲，需完成寺产，era 3–6）→ 新坛（定时，由一本书三个分支排程）
## 孤立：
##   抬神出城（脉冲，era 1–8；若刚抄过寺产，教门不肯出面，本轮不弹）
##
## 连线：寺产的三个分支各留一个标记，只调第二幕的权重（不设硬门，避免"选错就断链"）；
## 第二幕的三个分支都排程第三幕，档期 120–210 日。第三幕的三个结果各留一个标记，
## 由第四幕读权重——"坛上有没有像"决定下一次抬神有多容易。
##
## 数值：教门事件的杠杆是人心——出生率、主食开销、知识产出；钱只作配角（1.5–2%）。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"faith"
const PREFIX := "evt.faith."

const CAST := [
	"静光寺", "慧灯", "韩牧", "邵九娘", "陆仲堪", "岑放", "瞿敬", "裴敬之", "卫阿六", "罗善", "陈艾",
	"明算堂", "汲古坊", "落星桥", "鱼鳞册", "星度常序", "铜镜", "敕牒",
]

const MUL_060 := 39322
const MUL_080 := 52429
const MUL_090 := 58982
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474
const MUL_140 := 91750


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "信仰",
		"theme": "教门、书与名分",
		"era_band": "1-8",
		"prefix": PREFIX,
		"scale": "3 中观链 + 1 中观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAITH_TEMPLE_ESTATE),
			String(Ids.EVT_FAITH_ONE_BOOK),
			String(Ids.EVT_FAITH_NEW_ALTAR),
			String(Ids.EVT_FAITH_PLAGUE_PROCESSION),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 寺产 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAITH_TEMPLE_ESTATE),
		"title": "{settlement_name}·寺产",
		"body_text": "静光寺的田在城西，一直不纳粮。户曹韩牧带了铜尺和鱼鳞册来，量到第三块地，鞋上全是泥。知客僧慧灯把一只铁匣放在田埂上，匣里是前朝的敕牒，纸边发脆，一翻就掉渣。韩牧看了很久，说上面的年号跟寺里碑上的差着十一年。慧灯没接话，去把匣盖按上。佃户邵九娘把麻束按在膝上捆，她租的是寺里的田，交租的斗比官斗大一圈，这话她没说。风把敕牒掀起一角，慧灯伸手按住，手背上全是墨。",
		"image_key": "family.house",
		"ai_visual_prompt": "An official measuring temple fields with a bronze ruler, a monk holding an iron box of old edicts, a tenant binding hemp",
		"tags": ["faith", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 2,
		"max_era_index": 5,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.20},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "城里缺粮，官府才想起寺里的仓",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 30,
				"reason": "民怨总得找一个人担",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "寺院与衙门挤在同一座城里",
			},
		],
		"options": [
			Shared.option(
				"measure_and_seize", "量完这块地，田入官册",
				"田册上多了一页",
				"铜尺量到天黑，韩牧在册子上添了一页，寺田折成官田，租额照旧。抄经房上了锁，几个小沙弥背着包袱出了西门。邵九娘第二天去交租，斗换成了官斗，收租的人说旧欠要一并补齐。",
				[
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（补缴旧租折税）"),
					Shared.knowledge(-6, 540),
					Shared.flag(Ids.FLAG_TEMPLE_SEIZED, 900, "标记「田入官册」"),
				]),
			Shared.gamble(
				"bargain_for_granary", "免三年税，换寺里开仓",
				Shared.branch(36045, "寺里开了仓", # 55%
					"寺里的车从西门进来，一车一车卸在落星桥头，米价当天就松了。慧灯站在仓门口数车，数到第九辆就不数了。经楼的架子立起来，木料是新的，刻工说三年也刻不完。",
					[
						Shared.staple(-8, 360),
						Shared.knowledge(-3, 360),
						Shared.flag(Ids.FLAG_TEMPLE_BARGAINED, 900, "标记「折税未动」"),
						Shared.schedule(Ids.EVT_FAITH_ONE_BOOK, 120, "一本书"),
					]),
				Shared.branch(29491, "只送来三车陈米", # 45%
					"秋天过完，寺里才送来三车陈米，米里掺着沙。韩牧让人把米倒进官仓，账上记作已缴。佃户在桥头等了半个月，等到的是寺里加租的话。",
					[
						Shared.staple(10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
						Shared.flag(Ids.FLAG_TEMPLE_BARGAINED, 900, "标记「折税未动」"),
					])),
			Shared.option(
				"close_the_ledger", "把册子合上，秋后再说",
				"册子合上了",
				"韩牧把鱼鳞册卷起来，铜尺还在田埂上，忘了拿。那年冬天，寺里把两百亩田挂到三个外乡人的名下，契纸上的墨还是湿的。开春再量，界石已经挪过两回。",
				[
					Shared.flag(Ids.FLAG_TEMPLE_PENDING, 900, "标记「田册未定」"),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 300, "新坛"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 一本书 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAITH_ONE_BOOK),
		"title": "{settlement_name}·一本书",
		"body_text": "《星度常序》抄了七本，蓝布封皮，第三卷最后一行写着：天有常序，不必问坛。陆仲堪把七本摊在明算堂的长桌上，让学生自己挑一本带走，自己留下最破的那本。三天后，白衣长老瞿敬带着两个人进了书院，说想借去看看，回去抄一份。山长岑放给他们倒了茶，没让人去取书。窗外的檐水滴在石阶上，一滴一滴，谁也没有先动。",
		"image_key": "country.economy",
		"ai_visual_prompt": "Seven hand-copied books on a long academy table, a white-robed elder waiting, rain dripping from the eaves",
		"tags": ["faith", "scholar", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 6,
		"required_events_completed": [String(Ids.EVT_FAITH_TEMPLE_ESTATE)],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_TEMPLE_BARGAINED)},
				"add_weight": 0,
				"multiplier_q16": MUL_140,
				"reason": "寺里有经楼，先咬住这本书",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_TEMPLE_SEIZED)},
				"add_weight": 40,
				"reason": "抄经房空了，旧书流到书摊上",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_TEMPLE_PENDING)},
				"add_weight": 0,
				"multiplier_q16": MUL_060,
				"reason": "学院抄不动书",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "书院里有人能抄、能算",
			},
		],
		"options": [
			Shared.option(
				"burn_the_book", "当众烧书，封院三日",
				"火在院子里烧了一夜",
				"书在院子当中烧到半夜，瞿敬站在火边看，走的时候朝韩牧拱了拱手。陆仲堪没出门，学生在墙根下站成一排，鞋底碾着地上的纸灰。第四天，明算堂开门，讲席上换了个念经疏的人。",
				[
					Shared.knowledge(-6, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 360),
					Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 150, "新坛"),
				]),
			Shared.gamble(
				"let_him_prove_it", "让他在庙前算一场",
				Shared.branch(39322, "算赢了", # 60%
					"陆仲堪把月食的时辰写在板上，历官算了三遍，三遍都对不上。人群里有人笑出声，笑到一半停住——瞿敬转身走了。第二天，城里传抄《星度常序》的人排到了落星桥。",
					[
						Shared.knowledge(5, 540),
						Shared.research_signal("breakthrough.printing", "印刷"),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
						Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 150, "新坛"),
					]),
				Shared.branch(26214, "差了一个时辰", # 40%
					"历官把两家的时辰并排写在板上，陆仲堪那一行差了一个时辰。他没再说话，学生替他说了两句，被人拉开。散场时，瞿敬的人把板子抬走了。",
					[
						Shared.knowledge(-4, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
						Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 120, "新坛"),
					])),
			Shared.option(
				"lock_the_book", "书锁进库房，谁也不给",
				"库里多了一只木箱",
				"七本书装进木箱，抬进官库，钥匙挂在韩牧腰上。教门来要过两回，学院来要过三回，都说等上面的话。三个月后开箱，纸已经发潮，字还认得出。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 210, "新坛"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 新坛 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAITH_NEW_ALTAR),
		"title": "{settlement_name}·新坛",
		"body_text": "坛的基座砌好了，三样东西摆在雨里等人来定。寺里送来那面铜镜，装在木匣里，四个人抬；明算堂送来一块无字的木牌，一个人抱得动；城西的老妇把泥塑的白公像放在台阶上，自己坐在旁边不走。石匠卫阿六靠着檐柱磨錾子，问三个都留下行不行。檐水砸在磨石上，浆水流到台阶下。掌印的老臣裴敬之把三份呈文叠在一起，压在铜镜的匣盖上。雨大了，木牌上的墨开始洇。",
		"image_key": "family.house",
		"ai_visual_prompt": "Three rival sacred objects on a rainy stone altar base, a mason sharpening a chisel under the eaves",
		"tags": ["faith", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 180,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 7,
		"options": [
			Shared.gamble(
				"raise_the_mirror", "定铜镜，昭告全城",
				Shared.branch(36045, "铜镜进了坛", # 55%
					"铜镜抬上坛那天，寺里出了六十个人，沿街撒米。明算堂的牌子摘下来，换成经院，陆仲堪的名字从讲席上抹掉了。白公的泥像送回城西，老妇坐在门口，没哭，也没让人扶。",
					[
						Shared.bias(Ids.TAG_UNREST, 0.80, 720),
						Shared.knowledge(-5, 720),
						Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（寺田折租入库）"),
						Shared.flag(Ids.FLAG_ALTAR_OFFICIAL, 900, "标记「国坛已立」"),
					]),
				Shared.branch(29491, "匣子在坛前砸了", # 45%
					"抬镜的人刚上台阶，学院的学生从侧面挤上来，匣子脱手，铜镜磕在石角上，缺了一块。白公的信众趁乱把泥像搬上正位。裴敬之站在雨里，把三份呈文一张一张撕了。",
					[
						Shared.bias(Ids.TAG_UNREST, 1.35, 720),
						Shared.knowledge(-3, 540),
						Shared.flag(Ids.FLAG_ALTAR_SPLIT, 900, "标记「坛前分家」"),
					])),
			Shared.option(
				"hold_a_council", "开一场会，让三方来议",
				"会开了三个月",
				"会开在明算堂，三方的凳子摆成一个圈，谁都不肯先坐。争到第三个月，议出一个长名字，把三方都写进去，谁也念不全。名字刻上碑那天，城里的活停了一半，木匠在碑背后又刻了一行小字。",
				[
					Shared.country_sector("knowledge", 6, 720),
					Shared.cash_out(2.0),
					Shared.manufacturing(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 720),
				]),
			Shared.option(
				"leave_the_altar_empty", "坛空着，神像都收进库",
				"坛上只有雨",
				"三样东西都抬进库房，基座上什么都没留。石匠卫阿六把錾子收进布袋，说开春再来。开春他没来，城外河滩上倒多了七八个小龛，泥塑的，没名字，香火一直没断。",
				[
					Shared.flag(Ids.FLAG_ALTAR_EMPTY, 900, "标记「坛上无像」"),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 720),
				]),
		],
	}))

	# ═══ 孤立 · 抬神出城 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAITH_PLAGUE_PROCESSION),
		"title": "{settlement_name}·抬神出城",
		"body_text": "入秋以后，城西死了七个人，棺材铺的木料不够，有人用门板。香头罗善挨家收钱，说要抬静光寺那面铜镜出城，走到河滩再回来，走过的地方病就退。医者陈艾按住他的手。罗善把手抽回来，去门口搬那根抬杠。守门的老卒把门闩抬起来，又放下，抬了三次。城外河滩上已经站了人，雾里看不清有多少。",
		"image_key": "family.house",
		"ai_visual_prompt": "A crowd waiting at a city gate in fog, a bronze mirror on a carrying pole, a physician holding a medicine box",
		"tags": ["faith", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 120,
		"cooldown_days": 540,
		"min_era_index": 1,
		"max_era_index": 8,
		"blocked_story_flags": [String(Ids.FLAG_TEMPLE_SEIZED)],
		"conditions": [
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.55},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.35},
				"add_weight": 50,
				"multiplier_q16": MUL_130,
				"reason": "已经没别的指望",
			},
			{
				"condition": {"op": Op.SUBSISTENCE_SHORTFALL_GTE, "float_value": 0.10},
				"add_weight": 40,
				"reason": "先饿，后病",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ALTAR_SPLIT)},
				"add_weight": 0,
				"multiplier_q16": MUL_130,
				"reason": "坛前分过家，这时候更容易各抬各的",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ALTAR_EMPTY)},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "坛上无像，私龛越立越多",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ALTAR_OFFICIAL)},
				"add_weight": 0,
				"multiplier_q16": MUL_090,
				"reason": "国坛已立，抬神有官家的人张罗",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SHRINE_KEPT)},
				"add_weight": 0,
				"multiplier_q16": MUL_090,
				"reason": "旧祠重立，人心有归处",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SHRINE_WAITING)},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "墙还塌着，人更信私龛",
			},
		],
		"options": [
			Shared.option(
				"open_the_gate", "开门，让他们抬出去",
				"队伍出了西门",
				"门开了，队伍从西门出去，铜镜走在最前面，后面跟着几百人，一路唱着。走到河滩，雾散了，有人跪下来磕头。三天后队伍回来，人少了十几个，走在后面的人说，是路上走散的。",
				[
					Shared.bias(Ids.TAG_UNREST, 0.90, 270),
					Shared.birth(-6, 540),
					Shared.manufacturing(-4, 360),
				]),
			Shared.option(
				"three_streets_only", "只许抬到城隍庙",
				"在城里绕了三圈",
				"队伍没出城门，在城里绕了三圈，铜镜从每条街上过。人挤在街口，家家门口摆一只水盆。陈艾背着药箱从人缝里挤，挤到第三条街，药箱被挤掉在地上。",
				[
					Shared.bias(Ids.TAG_UNREST, 0.95, 270),
					Shared.birth(-4, 540),
					Shared.staple(4, 270),
				]),
			Shared.option(
				"bar_the_gate_three_days", "封三天门，先不表态",
				"第四天门自己开了",
				"城门封了三天，第三天夜里有人撞门，撞到天亮，门闩断成两截。人自己抬着铜镜出去了，罗善走在最前面，没人拦。老卒蹲在门洞底下捡那两截门闩，捡了半天。",
				[
					Shared.birth(3, 180),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
		],
	}))
