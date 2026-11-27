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
	"崇文书院", "官学凭状", "礼部", "学术公会",
	"活字印刷所", "商界资助人", "专利署", "专利证书",
	"糊名科考", "公派留洋", "学术期刊", "挂号邮戳",
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
		"title": "{settlement_name}·书院敕额",
		"body_text": "{settlement_name}的崇文书院规模日盛，礼部已拟好官学凭状，一旦颁授便可纳入国家学制、按月支领官仓廪米。然而书院主讲群体内部意见分歧：务实派愿接受官额以扩充师资，清流派则担忧从此沦为官僚附庸，连生员名册与讲学内容皆受掣肘。与此同时，地方商界资助人也提出以定向培养账房为条件注资，书院归属亟待朝廷裁决。",
		"image_key": "country.technology",
		"ai_visual_prompt": "An academy gate worn smooth by feet, an old headmaster holding a brush over a blank official charter, a clerk with a name register, a merchant waiting at the door",
		"tags": ["school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 5,
		"required_technologies": ["tech.scholarly_academies"],
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
				"ask_for_the_charter", "颁授官学凭状，纳入礼部管辖",
				"敕额立学",
				"书院缴纳册费后正式升格官学，生员课业与讲学体系全面规范，本地与全国学术产出皆有所进益。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（请凭状的使费）"),
					Shared.knowledge(12, 540),
					Shared.country_sector("knowledge", 6, 540),
				]),
			Shared.option(
				"refuse_the_charter", "驳回官学凭状，由国库酌情贴补",
				"留存民学",
				"书院保留民间讲学自由并由国库拨付少量贴补，却因缺乏官学晋升通道导致生源外流，本地学术产出短期下滑。",
				[
					Shared.knowledge(-12, 540),
					Shared.cash_out(3, 360, "国库拨付本地人数最多的{primary_profession}，占国库现金 3%（贴补书院的廪米）"),
				]),
			Shared.option(
				"report_three_names", "准予半官半民，仅呈报核心名册",
				"折中备案",
				"书院仅向礼部呈报少数骨干生员名册，其余讲席照旧自由治学。学风得以温和延续，但双轨运作增加了文书与器用耗费。",
				[
					Shared.knowledge(8, 360),
					Shared.tools(10, 540),
				]),
		],
	}))

	# ═══ 学会 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_SOCIETY),
		"title": "{settlement_name}·学术公会",
		"body_text": "{settlement_name}的学者群体拟在城中正式组建学术公会，推行同行公开评议制度，不论资历高低皆须当堂答辩。商界资助人已承诺按年捐助经费，条件是公会须开设实用算学与工程讲席。但保守官僚警告，不受管束的民间结社极易演变为议政党争，主张趁其尚未成势即刻查封。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A scholarly hall with rules written on the wall, young men standing to be judged, an older patron seated with a purse, a brush being handed over",
		"tags": ["school", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 9,
		"required_technologies": ["tech.learned_societies"],
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
				"let_them_meet", "核准公会章程，按年登记备案",
				"立会兴学",
				"学术公会依法缴纳登记会费并按年呈报名册，公开评议风气迅速成型，本地与全国的知识创新皆受其惠。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（学会登记，按户摊的会费）"),
					Shared.knowledge(12, 540),
					Shared.country_sector("knowledge", 8, 540),
				]),
			Shared.option(
				"lock_the_hall", "严禁民间结社，查封议事会馆",
				"查封会馆",
				"会馆被勒令关闭，城内清议之声一时沉寂，治安风险随之降低。但学者被迫转入地下私下切磋，正规学术产出明显萎缩。",
				[
					Shared.knowledge(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"let_them_judge", "不予官方背书，放任自由辩难",
				"清议四起",
				"公会未获官印却照常运转，尖锐的学术评议与时政议论迅速传遍邻省。思想激荡推动了知识进步，却也抬高了地方舆情波动。",
				[
					Shared.knowledge(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 印刷所 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_PRESS),
		"title": "{settlement_name}·活字印务",
		"body_text": "毗邻崇文书院的活字印刷所近日接到一批棘手委印：商界资助人送来一份未署名的复利核算手册，意图大规模刊印发售。审校学者指出，手册中多处算例存在纰漏，一旦流传市面势必引发契约与借贷纠纷。是严令其只印官定课本、推行署名校勘制，还是放任其按酬承印，地方政令亟待明确。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A small printing shop behind an academy wall, lead type sorted in wooden trays, an old proofreader marking two characters on a page",
		"tags": ["school", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 5,
		"required_technologies": ["tech.movable_type_printing"],
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
				"only_official_texts", "严限印务范围，只准承印官本",
				"专印官籍",
				"印刷所推拒一切私稿，专司官定典籍与公文印制，纸张供给与工坊周转顺畅。但民间著述出版受阻，思想传播趋于沉闷。",
				[
					Shared.knowledge(-10, 540),
					Shared.manufacturing(10, 540),
					Shared.stock("paper", 10),
				]),
			Shared.option(
				"choose_and_proof", "推行署名校勘制，严核印本",
				"精校成册",
				"新印算册末尾须列明校勘者署名并对错漏担责，虽增加了制版与耗材开销，却极大提升了出版公信力并催生印务革新。",
				[
					Shared.knowledge(15, 540),
					Shared.tools(12, 360),
					Shared.research_signal("breakthrough.printing", "活字与印版"),
				]),
			Shared.option(
				"print_what_is_paid", "开放商业承印，价高者先排",
				"商印繁荣",
				"印刷所按酬金次序满负荷运转，出版业产出与知识流通同步提速。但错漏百出的廉价手册流入坊间，引发多起商事纠纷。",
				[
					Shared.manufacturing(12, 540),
					Shared.knowledge(8, 360),
					Shared.bias(Ids.TAG_MARKET, 1.20, 540, "市面类事件权重 ×1.2，540 日"),
				]),
		],
	}))

	# ═══ 专利 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_PATENT),
		"title": "{settlement_name}·专利专权",
		"body_text": "{settlement_name}的机械工匠向专利署呈交了一项偏心轮纺车改良图纸，效率可翻倍，并正式申请独占年限的专利证书。商界资助人与大型工场主联名抗议，宣称同类构造早已在坊间摸索成型，授予垄断权只会抬高行业门槛、窒碍扩产。发明者群体则警告，若国家不保护首创者利益，今后无人再肯投入心血钻研技艺。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A workshop table with a spinning wheel drawing pinned by a brass ruler, a merchant reading it, a printer offering to set it in type",
		"tags": ["school", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 9,
		"required_technologies": ["tech.textile_machinery"],
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
				"grant_the_patent", "核发专利证书，确立独占年限",
				"产权确立",
				"专利署收取登记规费并签发独占证书，发明者权益获得法律保障。技术授权逐步规范，科研热情与制造业升级双双受惠。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（专利证书的登记费）"),
					Shared.knowledge(10, 540),
					Shared.manufacturing(10, 540),
				]),
			Shared.option(
				"deny_the_patent", "驳回垄断申请，允许全城仿制",
				"广为仿造",
				"新式纺车迅速在各作坊普及，短期内纺织产能显著提升。但发明者血本无归，匠人纷纷藏匿诀窍，本地技术创新陷入低谷。",
				[
					Shared.knowledge(-10, 540),
					Shared.manufacturing(12, 540),
				]),
			Shared.option(
				"buy_it_public", "国库出资买断，向全境公开",
				"公购开源",
				"国家拨款买断图纸并张榜公开，工匠与工场皆可免费仿制。科研界大受鼓舞，劳工与坊间对新器具的推广议论纷纷。",
				[
					Shared.cash_out(5, 720, "国库拨付本地人数最多的{primary_profession}，占国库现金 5%（买断法子的钱）"),
					Shared.knowledge(15, 540),
					Shared.bias(Ids.TAG_LABOR, 1.15, 540),
				]),
		],
	}))

	# ═══ 考试 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_EXAM),
		"title": "{settlement_name}·糊名取士",
		"body_text": "{settlement_name}崇文书院新一届取士开考在即，应试寒士逾百而名额仅十，选拔规制顿时成为地方豪强与礼部博弈的焦点。改革派力主推行糊名科考、全凭答卷真才录用；城中望族与商绅则要求沿用保举旧例，以维系宗族与官场的门生纽带。考题该侧重经义还是实务算学，两派同样僵持不下。",
		"image_key": "family.house",
		"ai_visual_prompt": "A notice pasted on an academy gate, stacks of recommendation lists weighted by name, candidates queuing around the corner with paper and ink",
		"tags": ["school", "court", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 5,
		"required_technologies": ["tech.scholarly_academies"],
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
				"seal_the_names", "全面推行糊名，唯才是举",
				"寒门入仕",
				"考卷严格糊名誊录，半数以上名额为寒门子弟所得。虽摊派了誊录考费，本地与全国的学术人才选拔质量却显著提升。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（誊录与纸墨，按户摊）"),
					Shared.knowledge(12, 540),
					Shared.country_sector("knowledge", 6, 540),
				]),
			Shared.option(
				"take_recommendations", "沿用乡绅保举，稳固地方秩序",
				"门阀旧例",
				"录取名额大多落入豪绅与大商子弟之手，地方既得利益集团深感满意，秩序波澜不惊。但寒门断了晋升之念，学风日趋萎靡。",
				[
					Shared.knowledge(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"let_the_academy_set_it", "由书院自主命题，增考实用算学",
				"新题风波",
				"书院力排众议将实用算学纳入主考，一批精于测算的新锐脱颖而出。大批专攻旧经的落榜举子聚众抗议，地方舆情骤然紧张。",
				[
					Shared.knowledge(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 留学 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_ABROAD),
		"title": "{settlement_name}·公派留洋",
		"body_text": "面对海外列强日益拉大的技术代差，{settlement_name}崇文书院与商界资助人联合呈请开启首批公派留洋计划，选派青年学子赴外研习近代工程与格致之学。财政官吏担忧高昂川资与外派人员学成滞留不归将令国库血本无归。主张严签效忠服务契约者，则遭到学子家族以人身束缚过苛为由强烈抵制。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A wharf with four young men boarding, an old woman tucking a padded coat into a trunk, a contract copied by candlelight, instruments left behind",
		"tags": ["school", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 7,
		"max_era_index": 9,
		"required_technologies": ["tech.experimental_science"],
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
				"send_on_the_public_purse", "官民共筹川资，扩大公派名额",
				"海归兴学",
				"地方按户摊派部分川资以扩大公派规模，大批学子负笈海外并带回前沿译著与仪具，本地与全国学术水准稳步跃升。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（各家摊的川资）"),
					Shared.knowledge(12, 720),
					Shared.country_sector("knowledge", 6, 540),
				]),
			Shared.option(
				"self_funded_only", "仅发官方护照，鼓励自费出洋",
				"人才外流",
				"自费留学生多滞留海外谋职，数年间归国者寥寥。书院讲席日渐空虚，资本与口粮外耗更令地方生计略感吃紧。",
				[
					Shared.knowledge(-10, 720),
					Shared.staple(10, 540),
				]),
			Shared.option(
				"bind_them_by_contract", "签署严苛效忠契，违约追责家族",
				"契约风波",
				"严苛的服务契约确保了部分新学人才回流任教，知识产出得以增长。但官府向滞留者家族追责引发多起冲突，民怨随之抬头。",
				[
					Shared.knowledge(10, 720),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 优先权 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SCHOOL_PRIORITY),
		"title": "{settlement_name}·发明优先权",
		"body_text": "{settlement_name}的学术公会与工匠圈爆出一桩轰动全城的优先权之争：两支独立研究团队在同一旬内向学术期刊递交了几乎完全相同的机械改良论文。两封密封稿件的挂号邮戳仅差数日，一方以字迹完备自居，另一方则坚持自己最早完成构思。如何裁定科学发现的署名规则，已直接关系到国家科研荣誉与工业转化秩序。",
		"image_key": "country.technology",
		"ai_visual_prompt": "Two handwritten manuscripts side by side on a desk, a finger marking an identical line, two sealed registered letters with the same postmark date",
		"tags": ["school", "knowledge"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 7,
		"max_era_index": 9,
		"required_technologies": ["tech.experimental_science"],
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
				"trust_the_postmark", "确立邮戳先至原则，严守程序",
				"邮戳定案",
				"学术公会收取核验驿费并正式确立挂号邮戳优先制，虽有落选者不平，清晰可循的裁定标准却令科研发表秩序大为稳固。",
				[
					Shared.knowledge(12, 540),
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（挂号信的驿费）"),
				]),
			Shared.option(
				"share_the_signature", "强制两家并列署名，平息争端",
				"和稀泥署名",
				"期刊强令双方并列署名，技术迅速流入工场带动了制造产出。但首创者深感不公，学术界对署名权威的信任随之滑坡。",
				[
					Shared.knowledge(-10, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.gamble(
				"seal_both_and_wait", "封存双稿，延请外埠权威仲裁",
				Shared.branch(42598, "外埠仲裁服众", # 65%
					"外埠资深学者与大匠仔细比对草稿改痕后厘清先后，双稿如实刊行并载明脉络。严谨的同行仲裁机制赢得全国学界推崇。",
					[
						Shared.knowledge(15, 540),
						Shared.country_sector("knowledge", 8, 540),
					]),
				Shared.branch(22938, "仲裁无果错失先机", # 35%
					"外埠仲裁久拖未决并将双稿退回，期间邻邦已抢先量产同类机械。本地学界与工场双双蒙损，指责当局推诿的舆论四起。",
					[
						Shared.knowledge(-12, 540),
						Shared.manufacturing(-8, 360),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					])),
		],
	}))
