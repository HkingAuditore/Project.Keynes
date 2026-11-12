class_name NarrativeEventCatalogSchool
extends RefCounted

## 学院：七条孤立事件，写知识怎么在一座城里落成规矩（不接链条，单条收束）。
##
##   书院 · 学会 · 印刷所 · 专利 · 考试 · 留学 · 优先权
##
## 这一包补的是知识线：凭状、会规、印版、证书、卷子、船票、邮戳。
## 七条全部走脉冲入口，各带三条权重规则，随建筑、职业构成、时代浮动。
## 代价货币刻意错开：摊派的钱、掉下去的知识产出、涨起来的耗材、抬上去的风险。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"school"
const PREFIX := "evt.school."

const CAST := [
	"沈砚舟", "范守拙", "陆知白", "卫兰台", "蒋秋帆", "罗敬斋", "岑子衡", "顾少陵",
	"崇文书院", "明德堂", "铅字", "显微镜", "挂号信", "专利证书", "凭状",
]

const MUL_085 := 55706
const MUL_090 := 58982
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "学院",
		"theme": "纸墨、凭状与署名：一门学问怎么落成规矩",
		"era_band": "3-9",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_SCHOOL_CHARTER),
			String(Ids.EVT_SCHOOL_SOCIETY),
			String(Ids.EVT_SCHOOL_PRESS),
			String(Ids.EVT_SCHOOL_PATENT),
			String(Ids.EVT_SCHOOL_EXAM),
			String(Ids.EVT_SCHOOL_ABROAD),
			String(Ids.EVT_SCHOOL_PRIORITY),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 书院 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_CHARTER),
		"title": "{settlement_name}·书院",
		"body_text": "崇文书院的门槛被踩出一道浅槽，沈砚舟从立春起就在等一张纸。凭状盖了印，书院就成了官学：山长每月领一份廪米，生员的课业要报上去。范守拙不想要这张纸，他把旧名册摊在案上，说报上去的名字要过三个人的手，念错一个字，人就算白读三年。陆知白在旁边磨墨，墨磨稠了还没停手。城里肯出钱的只有罗敬斋，他的条件是书院替他带两个账房。沈砚舟把笔提起来，笔尖悬在纸上，屋里谁也没催他落。",
		"image_key": "country.technology",
		"ai_visual_prompt": "An academy gate worn smooth by feet, an old headmaster holding a brush over a blank official charter, a clerk with a name register, a merchant waiting at the door",
		"tags": ["school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 5,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "讲堂和藏书的地方都盖起来了",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "读书人多，这张纸才有人争",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "取士的名额早定死了，凭状不值钱",
			},
		],
		"options": [
			Shared.option(
				"ask_for_the_charter", "请下这张凭状",
				"印盖在纸上",
				"凭状请下来了，盖的是朱印，锁在案头的木匣里。报上去的名册抄了两份，范守拙抄的那份，有三个名字写错又划掉。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（请凭状的使费）"),
					Shared.knowledge(4, 540),
					Shared.country_sector("knowledge", 2, 540),
				]),
			Shared.option(
				"refuse_the_charter", "凭状不要了",
				"山长自己掏钱",
				"凭状退了回去，沈砚舟把自家的两亩田写进书院的账。廪米的名字从册子上划掉，讲堂后排空出两张桌子。",
				[
					Shared.knowledge(-4, 540),
					Shared.cash_out(1.0, 360, "国库拨付本地人数最多的{primary_profession}，占国库现金 1%（贴补书院的廪米）"),
				]),
			Shared.option(
				"report_three_names", "只报三个名字",
				"名册短了一截",
				"名册上只写三个人，剩下的照旧在院里听课。入秋官府来人点名，范守拙把册子翻到末页，说人都在这儿。差役往院里看了一眼，把册子合上。",
				[
					Shared.knowledge(2, 360),
					Shared.tools(3, 540),
				]),
		],
	}))

	# ═══ 学会 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_SOCIETY),
		"title": "{settlement_name}·学会",
		"body_text": "明德堂的门锁换过三回，末了那把钥匙挂在卫兰台腰上。学会是他张罗的，每月初一聚一次，谁的文章好、谁的注疏错，都由在座的人当面评。陆知白头一回被评，站在堂中听人念他的错处，念到第七处，他把茶盏放回桌上，盏底磕出一声响。罗敬斋愿意每年出一笔钱，条件是学会里要讲算学。卫兰台拟了十二条会规，抄在墙上，末一条写着：评人的人，也归人评。他把笔递给陆知白，让他先落名。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A scholarly hall with rules written on the wall, young men standing to be judged, an older patron seated with a purse, a brush being handed over",
		"tags": ["school", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.04},
				"add_weight": 25,
				"reason": "读书人扎堆，才评得起来",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "讲堂、印坊都在一条街上",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "评语进了印本，传得比嘴快",
			},
		],
		"options": [
			Shared.option(
				"let_them_meet", "准他们立会",
				"会规上了墙",
				"会规贴在明德堂的墙上，十二条，末一条被人用指甲划了一道。学会每年往官府交一份名册，卫兰台交了两回，第二回多添了五个名字。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（学会登记，按户摊的会费）"),
					Shared.knowledge(4, 540),
					Shared.country_sector("knowledge", 3, 540),
				]),
			Shared.option(
				"lock_the_hall", "不许立会",
				"堂门上了锁",
				"明德堂的门锁了，锁眼用蜡封上。读书人改在茶铺里碰头，一个月换一个地方，评人的话还是那些。",
				[
					Shared.knowledge(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"let_them_judge", "官府不认，随他们评",
				"评语传到邻县",
				"陆知白的名字被人写在纸上，传到邻县，说他注疏抄错了三处。他把那三处重新校了一遍，校完没说是谁传的。",
				[
					Shared.knowledge(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 印刷所 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_PRESS),
		"title": "{settlement_name}·印刷所",
		"body_text": "蒋秋帆的印刷所开在崇文书院后墙外，一间屋，两副架子，铅字按笔画排在木盘里。头一批活是书院的课业，第二批是罗敬斋要的货单，第三批他没敢接：一本讲利息怎么算的小册子，没有署名。范守拙被请来校对，一天三页，校到第五天，把利息两个字挑出来，说这两个字错一个，照着算的人要赔钱。赔多少，赔给谁，屋里没有一个人接话。蒋秋帆把那一页翻过去，背面还是空的。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A small printing shop behind an academy wall, lead type sorted in wooden trays, an old proofreader marking two characters on a page",
		"tags": ["school", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 5,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "印坊、纸铺、书院挤在一处",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.03},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "写稿的人多，稿子就杂",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 15,
				"reason": "铅字便宜了，谁都能开一间",
			},
		],
		"options": [
			Shared.option(
				"only_official_texts", "照官本印",
				"一年只印一种书",
				"架子上只剩官定的课业，一年印三回，回回一样。蒋秋帆把私活都推了，夜里听见隔壁书院背书，就把窗关上。",
				[
					Shared.knowledge(-3, 540),
					Shared.manufacturing(3, 540),
					Shared.stock("paper", 10),
				]),
			Shared.option(
				"choose_and_proof", "自己选题，请人校",
				"第一本署了名",
				"小册子印出来了，末尾添了一行校者的名字：范守拙。他把利息两个字圈在样书上，说这一圈，照书算账的人少赔一半。",
				[
					Shared.knowledge(5, 540),
					Shared.tools(4, 360),
					Shared.research_signal("breakthrough.printing", "活字与印版"),
				]),
			Shared.option(
				"print_what_is_paid", "谁出钱印谁的书",
				"错字卖得最快",
				"钱多的先印，钱少的排到下月。第一批书里有一页把利息少算了一半，读的人照着算，算完来找印刷所，门口堵了三天。",
				[
					Shared.manufacturing(4, 540),
					Shared.knowledge(2, 360),
					Shared.bias(Ids.TAG_MARKET, 1.20, 540, "市面类事件权重 ×1.2，540 日"),
				]),
		],
	}))

	# ═══ 专利 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_PATENT),
		"title": "{settlement_name}·专利",
		"body_text": "岑子衡把法子写在一张纸上：纺车加一道偏心轮，一个人摇，出两倍的纱。他要一张专利证书，纸上写明年限，别人要用，先跟他谈价钱。罗敬斋看了半天，说这法子在他家作坊里已经有人摸出一半，真要按纸上的写法办，先得把那个人赶出去。蒋秋帆愿意替他印，说印出来，全城都知道是谁先想出来的。岑子衡拿铜尺把纸压住，风从窗口进来，纸角掀了一下，又落回去。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A workshop table with a spinning wheel drawing pinned by a brass ruler, a merchant reading it, a printer offering to set it in type",
		"tags": ["school", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 20,
				"reason": "商号多，一个法子有人肯出钱买",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "作坊挨着作坊，谁也瞒不住",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 8},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "机器贵了，省一步就是省一间屋的工",
			},
		],
		"options": [
			Shared.option(
				"grant_the_patent", "给他一张证书",
				"纸上有了年限",
				"专利证书办下来了，年限写的是十四年。岑子衡把它钉在作坊的墙上，来学的人先看纸，再看他那只手。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（专利证书的登记费）"),
					Shared.knowledge(3, 540),
					Shared.manufacturing(3, 540),
				]),
			Shared.option(
				"deny_the_patent", "不认，谁都能用",
				"偏心轮满街转",
				"半年里城里多了七架这样的纺车，谁也没给岑子衡钱。他把自己的那架拆了，零件收进箱子，箱子推到床底下。",
				[
					Shared.knowledge(-3, 540),
					Shared.manufacturing(4, 540),
				]),
			Shared.option(
				"buy_it_public", "官府出钱买下",
				"法子贴在衙门口",
				"官府按纸上的价钱把钱付了，法子抄成大字贴在衙门口，谁都能看。岑子衡去看了一回，站了半晌，回来把墙上的那张纸揭下来。",
				[
					Shared.cash_out(2.0, 720, "国库拨付本地人数最多的{primary_profession}，占国库现金 2%（买断法子的钱）"),
					Shared.knowledge(5, 540),
					Shared.bias(Ids.TAG_LABOR, 1.15, 540),
				]),
		],
	}))

	# ═══ 考试 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_EXAM),
		"title": "{settlement_name}·考试",
		"body_text": "崇文书院门口贴了告示，今年取十个童生。来报名的过了百，名册写了三本，范守拙按保举人的名字分堆，堆得最高的那一摞是罗敬斋荐的。沈砚舟要糊名，糊住姓名籍贯，只按卷子取。罗敬斋说糊了名，考官认不出是谁家的孩子，取上来的将来谁认这门亲。题目谁出也没定：陆知白出了三道，都是算学，说要取能算账的；范守拙嫌浅，把旧题翻出来，纸都脆了。门外的人还排着，队伍拐过墙角。",
		"image_key": "family.house",
		"ai_visual_prompt": "A notice pasted on an academy gate, stacks of recommendation lists weighted by name, candidates queuing around the corner with paper and ink",
		"tags": ["school", "court", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 5,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"reason": "孩子多，报名的人就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 10,
				"reason": "讲堂和考棚都腾得出来",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "出题的人多了，题目就有人争",
			},
		],
		"options": [
			Shared.option(
				"seal_the_names", "糊名，按卷取",
				"取上来的不认门",
				"卷子糊了名，取上来的十个里有六个是佃户家的孩子。罗敬斋荐的那几个落了两个，他没说什么，把名册还给了衙门。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（誊录与纸墨，按户摊）"),
					Shared.knowledge(4, 540),
					Shared.country_sector("knowledge", 2, 540),
				]),
			Shared.option(
				"take_recommendations", "各家保举",
				"名册退回三本",
				"保举的名册送上去，取的多是城里铺户的儿子。佃户家的孩子来了两年，第三年不来了，说家里的地没人看。",
				[
					Shared.knowledge(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"let_the_academy_set_it", "题目由书院出",
				"落榜的人堵了门",
				"题目出得偏，三道里有两道是算学，落榜的二十几个人堵在书院门口。沈砚舟出来念了一遍题，念完没人走，他回身把门关上了。",
				[
					Shared.knowledge(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 留学 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_ABROAD),
		"title": "{settlement_name}·留学",
		"body_text": "顾少陵的名字写在第一批出去的单子上，一共四个人，另三个是罗敬斋商号的伙计。船钱各家摊，官府贴一半，条件写在契上：学成回来，在崇文书院教五年。陆知白替他们抄契，抄到五年两个字，笔停了一下。顾少陵的母亲把一件旧棉袍塞进箱底，说那边冷。卫兰台在码头上问了一句，谁带了显微镜；四个人互相看看，谁也没带。船开的时候，岸上的人还在数人头。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A wharf with four young men boarding, an old woman tucking a padded coat into a trunk, a contract copied by candlelight, instruments left behind",
		"tags": ["school", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 7,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 20,
				"reason": "读书人多，才凑得出几个能出去的人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "书院有屋子安置回来的人",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 8},
				"add_weight": 15,
				"reason": "洋船按期靠岸，出去一趟不算难",
			},
		],
		"options": [
			Shared.option(
				"send_on_the_public_purse", "官费送出去",
				"单子上添了名字",
				"第二批单子添了七个人，船钱官府拿六成，各家摊四成。走的那天码头上下着雨，顾少陵的母亲没去，托人捎了一双鞋。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（各家摊的川资）"),
					Shared.knowledge(4, 720),
					Shared.country_sector("knowledge", 2, 540),
				]),
			Shared.option(
				"self_funded_only", "自费，官府给凭",
				"出去的人没回来",
				"凭给了，钱自己出，出去的十一个，三年里回来三个。崇文书院的讲堂空了一半，卫兰台把多出来的桌椅搬到后院。",
				[
					Shared.knowledge(-3, 720),
					Shared.staple(3, 540),
				]),
			Shared.option(
				"bind_them_by_contract", "签契，学成必回",
				"契放在抽屉里",
				"契签了，人还是没全回来。家里来衙门要人，衙门拿出契来念，念到五年那一行，屋里就静了。顾少陵的母亲坐在地上不起来。",
				[
					Shared.knowledge(3, 720),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 优先权 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_PRIORITY),
		"title": "{settlement_name}·优先权",
		"body_text": "陆知白和岑子衡在同一旬里把同一句话写进各自的稿子：偏心轮要装在摇臂里头，不是外头。两份稿子都压在崇文书院的案上，一份写初一，一份写初九，中间那八天谁也说不清谁先动的手。蒋秋帆说印出来才算数，印谁的由他定；罗敬斋说两本都印，卖得好的那个算先。范守拙把两份稿子并排摆着，用指头点住那一行，说这一行一模一样。卫兰台从抽屉里拿出两封挂号信，信还没拆，邮戳上的日子是同一天。",
		"image_key": "country.technology",
		"ai_visual_prompt": "Two handwritten manuscripts side by side on a desk, a finger marking an identical line, two sealed registered letters with the same postmark date",
		"tags": ["school", "knowledge"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 7,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.04},
				"add_weight": 20,
				"reason": "读书人多，撞车的也多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "印坊就在隔壁，一天能出两版",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 8},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "同样的题目，几处同时在动手",
			},
		],
		"options": [
			Shared.option(
				"trust_the_postmark", "按邮戳的日子算",
				"日子早的那封",
				"两封挂号信拆开，邮戳上初一那封字迹潦草，初九那封誊得干净。卫兰台把初一那封摊在案上，说字潦草的这个人先想到，只是没工夫写好看。",
				[
					Shared.knowledge(4, 540),
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（挂号信的驿费）"),
				]),
			Shared.option(
				"share_the_signature", "两人并列署名",
				"序上写了两个名字",
				"书上印了两个名字，前一个后一个隔了半行。两人在印坊门口碰见，谁也没先开口；陆知白把手里的样书递过去，岑子衡接了，翻了两页就还给他。",
				[
					Shared.knowledge(-3, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.gamble(
				"seal_both_and_wait", "封起来，等外人断",
				Shared.branch(42598, "外县的老匠人来了", # 65%
					"老匠人把两份稿子对着光看了半天，说初一那封的边上有炭条改过的痕，痕比墨早。两本都印，序上照实写了前后。",
					[
						Shared.knowledge(5, 540),
						Shared.country_sector("knowledge", 3, 540),
					]),
				Shared.branch(22938, "两份都退了回来", # 35%
					"老匠人看了三天，说分不出先后，两份都退回来。陆知白把稿子锁进柜子，岑子衡把偏心轮装回原处，转起来还是响。第二年开春，外县先出了同样的机子。",
					[
						Shared.knowledge(-4, 540),
						Shared.manufacturing(-2, 360),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					])),
		],
	}))
