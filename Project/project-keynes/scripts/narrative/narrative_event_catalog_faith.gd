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
	"教团", "寺产", "敕牒", "鱼鳞册", "书院", "星历典籍", "铜镜", "圣坛", "祭典",
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
		"body_text": "城西大片肥沃良田归属当地教团作为寺产，长年享有免税特权。财政官员携鱼鳞册实地清丈时，教团代表搬出前朝颁发的泛黄敕牒力证免赋合法性，但官员查验后指出敕牒纪年与碑文存在明显出入。与此同时，耕种寺产的佃户私下怨言颇深，称教团收取的私租远重于官税。是强行清丈收税、以豁免换取开仓济民，还是暂且搁置争议，关乎国家财源与政教关系。",
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
				"measure_and_seize", "铁腕清丈，将寺产编入官册",
				"寺田入官",
				"丈量官强行将寺产折入官册并追缴旧税，国库获得了一笔可观入账。然而教团愤然关闭抄经讲堂，大批僧侣离城，本地文教事业遭受重创。",
				[
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（补缴旧租折税）"),
					Shared.knowledge(-18, 540),
					Shared.flag(Ids.FLAG_TEMPLE_SEIZED, 900, "标记「田入官册」"),
				]),
			Shared.gamble(
				"bargain_for_granary", "特许免税三年，换取教团开仓",
				Shared.branch(36045, "开仓济市", # 55%
					"教团如约开启私仓，大批粮食运抵城中，显著压低了本地主食开销。但作为交换，教团大兴土木扩建经楼，世俗学术的影响力随之萎缩。",
					[
						Shared.staple(-24, 360),
						Shared.knowledge(-10, 360),
						Shared.flag(Ids.FLAG_TEMPLE_BARGAINED, 900, "标记「折税未动」"),
						Shared.schedule(Ids.EVT_FAITH_ONE_BOOK, 120, "一本书"),
					]),
				Shared.branch(29491, "以次充好", # 45%
					"直到秋末教团才敷衍送来数车掺沙陈米，反手却向佃户加征地租。主食开销不降反升，民间对官府姑息教团的怨气迅速积聚。",
					[
						Shared.staple(25, 360),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
						Shared.flag(Ids.FLAG_TEMPLE_BARGAINED, 900, "标记「折税未动」"),
					])),
			Shared.option(
				"close_the_ledger", "合上鱼鳞册，待秋后再议",
				"清丈搁置",
				"清丈行动半途而废，教团趁冬日将大批良田暗中过户至外乡代理人名下。开春复核时田籍早已面目全非，政教积怨为后续风波埋下伏笔。",
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
		"body_text": "本地书院的学者编纂了一部星历典籍，在卷末赫然断言天象运行自有恒常规律，无须依赖祭祀与神坛祈禳。抄本刚在学子间流传，教团长老便率众闯入书院，以亵渎圣统为由强硬要求交出原稿与全部抄本。书院山长婉言推诿，学者们则视此书为理性求知的根基。这已不仅是一卷书稿的存废，更是世俗学术与正统教权之间的一次正面交锋。",
		"image_key": "country.economy",
		"ai_visual_prompt": "Seven hand-copied books on a long academy table, a white-robed elder waiting, rain dripping from the eaves",
		"tags": ["faith", "scholar", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 6,
		"required_technologies": ["tech.writing"],
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
				"burn_the_book", "当众焚毁典籍，封院整顿三日",
				"焚书息争",
				"全部抄本在广场付之一炬，教团满意离去，地方动荡风险暂时平息。但书院复课后讲席被经学派接管，本地学术与科研产出陷入长期低迷。",
				[
					Shared.knowledge(-18, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 360),
					Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 150, "新坛"),
				]),
			Shared.gamble(
				"let_him_prove_it", "准许学者在庙前公开推演天象",
				Shared.branch(39322, "星历胜出", # 60%
					"学者精准预言了月食时刻，令教团历官哑口无言。星历典籍随即风行全城并催生了印刷术的探索热情，但也彻底激怒了保守教派。",
					[
						Shared.knowledge(15, 540),
						Shared.research_signal("breakthrough.printing", "印刷"),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
						Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 150, "新坛"),
					]),
				Shared.branch(26214, "推演失准", # 40%
					"公开推演的时刻竟出现明显偏差，教团趁机大造声势并将讲席彻底清场。书院颜面扫地，本地学术元气大伤，派系冲突愈演愈烈。",
					[
						Shared.knowledge(-12, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
						Shared.schedule(Ids.EVT_FAITH_NEW_ALTAR, 120, "新坛"),
					])),
			Shared.option(
				"lock_the_book", "封存书稿入库，双方均不发还",
				"封存冷处理",
				"七部抄本被悉数锁入官库，教团与书院数度交涉皆未获答复。这种回避立场的拖延手段两面不讨好，令双方积怨在沉默中不断发酵。",
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
		"body_text": "耗资修筑的城中圣坛基座已告竣工，究竟供奉何物却引发三方激烈角力。正统教团抬来象征神权的古旧铜镜，要求确立唯一国教地位；书院呈上一块无字素牌，主张以理性与礼法为宗；民间乡绅则拥护本土神明泥像，坚称其最得百姓香火。三份呈文同时压在执政案头，圣坛的归属将长远塑造国家的意识形态与文化根基。",
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
				"raise_the_mirror", "钦定铜镜入坛，确立正统教权",
				Shared.branch(36045, "国坛既立", # 55%
					"铜镜在盛大仪仗中登上圣坛，教团协助稳定了民间秩序并折纳寺田税赋。代价是书院被迫改制，世俗学术在正统神权压制下大幅萎缩。",
					[
						Shared.bias(Ids.TAG_UNREST, 0.80, 720),
						Shared.knowledge(-15, 720),
						Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（寺田折租入库）"),
						Shared.flag(Ids.FLAG_ALTAR_OFFICIAL, 900, "标记「国坛已立」"),
					]),
				Shared.branch(29491, "坛前骚乱", # 45%
					"仪仗登坛之际遭到书院学子冲撞，铜镜摔损，民间信众趁乱将泥像抬上正位。圣坛沦为派系分裂的现场，学术与社会秩序双双受创。",
					[
						Shared.bias(Ids.TAG_UNREST, 1.35, 720),
						Shared.knowledge(-10, 540),
						Shared.flag(Ids.FLAG_ALTAR_SPLIT, 900, "标记「坛前分家」"),
					])),
			Shared.option(
				"hold_a_council", "召集三方会盟，共议兼容礼制",
				"三方合议",
				"历时数月的辩论最终诞生了一套折中礼制，虽耗费国库资金并一度拖累地方制造，但思想碰撞极大提振了全国的学术与知识产出。",
				[
					Shared.country_sector("knowledge", 15, 720),
					Shared.cash_out(5),
					Shared.manufacturing(-12, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 720),
				]),
			Shared.option(
				"leave_the_altar_empty", "圣坛留白虚设，圣物悉数入库",
				"坛上无像",
				"三方圣物皆被封存，空荡的圣坛成为世俗政权中立的象征。然而缺乏官方精神寄托导致城外私龛遍地开花，营建与治安成本随之抬升。",
				[
					Shared.flag(Ids.FLAG_ALTAR_EMPTY, 900, "标记「坛上无像」"),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 720),
				]),
		],
	}))

	# ═══ 孤立 · 抬神出城 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAITH_PLAGUE_PROCESSION),
		"title": "{settlement_name}·抬神出城",
		"body_text": "入秋以来，城西爆发不明疫病，接连有居民病亡，恐慌迅速在街巷蔓延。教团与民间社首四处募捐，执意要举行盛大祭典，抬出供奉的铜镜游街出城以驱散瘟疫。随行医官急切劝阻，警告大规模人群聚集只会加速疫病扩散；而城门守军见城外已聚集大批焦躁民众，正焦急请示是否放行。安抚民心与科学防疫，此刻尖锐对立。",
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
				"open_the_gate", "开启城门，准许祭典出城巡游",
				"巡游驱疫",
				"浩荡的巡游队伍抬着铜镜出城祈福，恐慌情绪一时大为缓解。但密集聚集导致疫病进一步蔓延，本地人口出生率与作坊开工均受重创。",
				[
					Shared.bias(Ids.TAG_UNREST, 0.90, 270),
					Shared.population_rate(-8),
					Shared.manufacturing(-12, 360),
				]),
			Shared.option(
				"three_streets_only", "限制规模，仅许仪仗在主街简行",
				"城内简行",
				"祭典被限制在城内数条街道举行，勉强兼顾了民情与管控。然而街口拥挤仍加剧了传播与物资紧张，出生率下滑且主食开销随之增加。",
				[
					Shared.bias(Ids.TAG_UNREST, 0.95, 270),
					Shared.population_rate(-5),
					Shared.staple(12, 270),
				]),
			Shared.option(
				"bar_the_gate_three_days", "严令封城三日，禁止一切聚集",
				"破门强行",
				"强硬封城阻断了初期传染，保住了人口生机。但连日高压彻底激怒了恐慌的民众，第三夜人群冲破城门强行抬神出城，社会动荡风险陡增。",
				[
					Shared.birth(10, 180),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
		],
	}))
