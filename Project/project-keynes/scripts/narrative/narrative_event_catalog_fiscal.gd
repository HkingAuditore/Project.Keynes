class_name NarrativeEventCatalogFiscal
extends RefCounted

## 财政包：钱从哪里来（5 条）。
##
## 链（三幕）：
##   借饷（脉冲，era 4–7）→ 小钱（定时，枢纽；入口：本包「铸小钱」120 日 / 宫廷「发兵」40 日）
##                        → 查账（定时，由借饷或小钱排程）
## 孤立：
##   盐（脉冲，era 3–6）· 两本账（脉冲，微观，era 3–8）
##
## 连线：查账的「停查」会把 720 日后的借饷再排一次——这不是环，是债务周期；
## 小钱与查账都只由上游排程，不走脉冲，避免"没借钱也查账"。
##
## 数值：财政事件的代价货币是现金流（双边守恒）与建设/军粮；钱一律只动
## "本地人数最多的那一群"，标签写 {primary_profession}。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"fiscal"
const PREFIX := "evt.fiscal."

const CAST := [
	"沈砚舟", "陆秉", "韦崇", "韩九", "吴敬斋", "郭阿满", "白茅渡", "青塘堰", "沙沟场", "落雁坡",
	"白茅渡钱监", "度支房", "河工估册", "收粮则例", "借券", "盐引",
]

const MUL_075 := 49152
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_140 := 91750


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "财政",
		"theme": "钱从哪里来",
		"era_band": "3-8",
		"prefix": PREFIX,
		"scale": "3 宏观链 + 2 中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FISCAL_STATE_LOAN),
			String(Ids.EVT_FISCAL_DEBASED_COIN),
			String(Ids.EVT_FISCAL_AUDIT),
			String(Ids.EVT_FISCAL_SALT),
			String(Ids.EVT_FISCAL_TWO_LEDGERS),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 借饷 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FISCAL_STATE_LOAN),
		"title": "{settlement_name}·借饷",
		"body_text": "青塘堰的土方估完了，要三千个工，度支房的柜子里只剩半柜钱。都尉韦崇把兵册摊在案上，说再拖下去，营里有人要拿刀去换米。行首沈砚舟坐在末座，膝上搁一只漆匣，匣里是裁好的借券，纸边还是毛的。他说这钱能垫，息按月算，抵押要拿白茅渡的税。账房陆秉在旁边拨算盘，拨到一半停了，把一颗珠子推回去。窗外河工在量堤，竹竿上的刻度被水泡得发白。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A finance office with a cash box, bond slips on a lacquer case, a military roster on the desk, river workers measuring an embankment outside",
		"tags": ["fiscal", "market", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 4,
		"max_era_index": 7,
		"blocked_story_flags": [String(Ids.FLAG_WARLORD)],
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有堤有仓，处处要钱",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ARMY_GRIEVANCE)},
				"add_weight": 40,
				"multiplier_q16": MUL_130,
				"reason": "兵怨未平，饷不能拖",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SALT_OPEN)},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "盐课漏着，只能另想办法",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_COOKED_BOOKS)},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "账面好看，库里没钱",
			},
		],
		"options": [
			Shared.gamble(
				"pledge_the_ferry_tax", "拿白茅渡的税作抵",
				Shared.branch(39322, "券卖完了", # 60%
					"二十张借券当天就没了，第二天又加印了十张。陆秉把押税的那张契抄了两份，一份锁进柜里，一份塞进袖子。堤上开始打桩，商号的账房天天来量方。",
					[
						Shared.cash_in(3.0, 540, "向本地人数最多的{primary_profession}征借其现金的 3%（借券，以渡口税作抵）"),
						Shared.manufacturing(-3, 540),
						Shared.build_cost(4, 540),
						Shared.bias(Ids.TAG_LABOR, 1.15, 360),
						Shared.schedule(Ids.EVT_FISCAL_AUDIT, 180, "查账"),
					]),
				Shared.branch(26214, "只卖出六张", # 40%
					"只卖出六张，剩下的沈砚舟收了回去，说同行不肯认这个息。韦崇在门口等了半天，把兵册合上走了。国库的钱先垫了工钱，垫到一半，堤上的桩停在那。",
					[
						Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征借其现金的 1%（借券只卖出六张）"),
						Shared.cash_out(2.0, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
						Shared.schedule(Ids.EVT_FISCAL_AUDIT, 240, "查账"),
					])),
			Shared.option(
				"mint_thin_coin", "铸小钱，先发饷",
				"钱监开炉",
				"白茅渡钱监的炉子当夜就点了火，铜范不够，拿旧的改；收铜的告示贴到市口，铺子里存的铜器按官价抬走两车。饷发下去那天，营里没人闹，只是有人把钱在手里掂了掂，塞回怀里。陆秉在簿子上写「照旧钱支给」，写完停了一下，没改。",
				[
					Shared.manufacturing(4, 360),
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（官价收铜、新钱支饷）"),
					Shared.schedule(Ids.EVT_FISCAL_DEBASED_COIN, 120, "小钱"),
				]),
			Shared.option(
				"push_the_dike_to_next_year", "把堤推到明年",
				"堤上的草长起来了",
				"里正挨户收摊派的钱，收到第三家，那家把门从里面顶上。韦崇拿这点钱发了半个月的饷，带人上堤，桩打到一半撤了，桩头露在土外，一冬就烂。第二年开春，低田的水退得比别处慢，插秧的人弯着腰，把手伸进泥里，摸到的还是凉水。",
				[
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（按亩摊派，先发一半饷）"),
					Shared.agriculture(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
					Shared.schedule(Ids.EVT_FISCAL_AUDIT, 300, "查账"),
					Shared.schedule(Ids.EVT_LABOR_BROKEN_LOOM, 180, "砸机器"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 小钱 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FISCAL_DEBASED_COIN),
		"title": "{settlement_name}·小钱",
		"body_text": "白茅渡钱监的炉子七天没熄，墙熏到檐下都是黑的。炉头韩九撬开铜范，钱坯还烫手，他夹起一枚在砧子上磕，声音比旧钱闷。度支房的人站在炉口，只问一炉能出多少，韩九没答。他把新旧钱并排放在砖上，新钱薄了一层；同样一吊，串钱的麻绳松出半寸。门外换钱的人排到照壁，有人把整串解开，摊在掌心里，一枚一枚对着日头看。官定新旧同价，队伍里没有人说话。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A coin foundry at night, a furnace master knocking a thin new coin on an anvil, a queue of people weighing old and new coins",
		"tags": ["fiscal", "market", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 180,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 7,
		"options": [
			Shared.option(
				"keep_minting", "照这样铸下去",
				"钱轻了",
				"新钱一炉一炉地出，官价没动，市上的价自己动了。卖炭的老妇开始用牙咬钱边，咬出印子的才收。韩九把砧子上的钱扫进筐里，扫到最后几枚，没再磕。",
				[
					Shared.manufacturing(4, 360),
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（官炉收铜、新钱支饷，铸息入库）"),
					Shared.bias(Ids.TAG_UNREST, 1.40, 720),
					Shared.schedule(Ids.EVT_FISCAL_AUDIT, 240, "查账"),
				]),
			Shared.option(
				"recall_and_recast", "回炉，照旧钱重铸",
				"炉子重开",
				"韩九把新范砸了，旧范从库底翻出来，边角已经裂了。赔钱那天，换钱的人排得比上次更长，有人拿到旧钱当场就咬。陆秉在柜台后头数了一夜，天亮时把算盘一推，说这样下去不如不铸。",
				[
					Shared.cash_out(3.0),
					Shared.staple(-6, 540),
					Shared.manufacturing(-4, 360),
					Shared.schedule(Ids.EVT_FISCAL_AUDIT, 300, "查账"),
				]),
			Shared.option(
				"pay_soldiers_in_thin_coin", "新钱只进军饷",
				"营门口多了一个换钱的摊子",
				"饷照旧日子发，发的是新钱。第三天，营门口摆出一个摊子，用新钱换旧钱，每换一吊，摊主先摘下五枚。都尉韦崇从摊子前走过去，看了一眼，没停；摊主是同营的一个老兵，缺三根手指。",
				[
					Shared.supply(10, 720),
					Shared.flag(Ids.FLAG_TWO_PRICES, 720, "标记「官民两价」"),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.schedule(Ids.EVT_FISCAL_AUDIT, 420, "查账"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 查账 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FISCAL_AUDIT),
		"title": "{settlement_name}·查账",
		"body_text": "陆秉把三口箱子搬进度支房，一箱借券，一箱《河工估册》，一箱兵册。钱在账上走一圈，落成青塘堰的土方；堤只砌到七成。兵册上三百个名字，营里点过，应声的不到一半。韦崇站在门口不进来，说兵册是底下人递上来的，他只管打仗。最底下一张借券的角上有行小字，写着息按月计、以白茅渡的税作抵。陆秉把三样东西对齐，手指停在纸缝上——纸缝里还压着一层旧账，边缘被裁过。",
		"image_key": "country.economy",
		"ai_visual_prompt": "Three chests of bonds, work ledgers and army rolls in an audit office, a hidden older ledger pressed in the seams",
		"tags": ["fiscal", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 180,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 8,
		"options": [
			Shared.gamble(
				"audit_to_the_bottom", "一查到底，追赃",
				Shared.branch(45875, "箱底翻出来了", # 70%
					"旧账被裁的那一页在兵册后头找着了，数目对得上。追赃追到第三个名字，那人把家里的骡子牵到衙门口抵账。陆秉清了三天账，最后一笔勾完，把笔搁下，手在袖子里抖。",
					[
						Shared.cash_in(3.0, 540, "向本地人数最多的{primary_profession}追缴其现金的 3%"),
						Shared.manufacturing(-3, 360),
						Shared.flag(Ids.FLAG_ACCOUNTS_CLEAN, 900, "标记「账清吏肃」"),
						Shared.bias_event(Ids.EVT_FISCAL_TWO_LEDGERS, 1.40, 540, "两本账"),
						Shared.schedule(Ids.EVT_FAMILY_FATHERS_DEBT, 90, "父债"),
					]),
				Shared.branch(19661, "营里的人堵了门", # 30%
					"追到韦崇名下，第二天营里来了一队人，站在度支房门口不说话。饷先补发了，追赃的单子收进柜里，再没提。陆秉此后绕开东门走。",
					[
						Shared.cash_out(2.0, 360),
						Shared.bias(Ids.TAG_UNREST, 1.40, 720),
						Shared.flag(Ids.FLAG_ARMY_GRIEVANCE, 720, "标记「兵怨未平」"),
					])),
			Shared.option(
				"patch_with_salt_tax", "挪盐课把账做平",
				"账面上干干净净",
				"亏空从盐课里划出去，河工的欠工钱补了，兵册改了名字，改成一个已经退伍的。陆秉把新账誊清，晾在架上。沙沟场那边来人问今年的灶钱，他让人回话：再等等。",
				[
					Shared.cash_out(3.0),
					Shared.extraction(-3, 540),
					Shared.flag(Ids.FLAG_PATCHED_BOOKS, 900, "标记「账已做平」"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"stop_the_audit", "停查，先顾军情",
				"箱子上了锁",
				"三口箱子抬回库房，锁上，锁头由陆秉收着。腰绳上还系着去年那枚封条，纸已经脆了。韦崇第二天带兵出城，走的是东门。",
				[
					Shared.supply(8, 720),
					Shared.bias(Ids.TAG_UNREST, 1.30, 900),
					Shared.schedule(Ids.EVT_FISCAL_STATE_LOAN, 720, "借饷"),
				]),
		],
	}))

	# ═══ 孤立 · 盐 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FISCAL_SALT),
		"title": "{settlement_name}·盐",
		"body_text": "沙沟场的盐堆在苇席底下，白得晃眼，管场的把秤砣往袖子里塞。县里欠着半年的工钱，度支房想出一个法子：盐的买卖包给三家，先收一笔押金。行首吴敬斋带了两个人来，坐在盐仓门口的石阶上，手里捏着一叠空白引票。他开的价不高，条件是把查私盐的事一并交给他的人。挑盐的脚夫靠着墙根听，听到一半就起身走了，扁担在肩上一晃一晃。吴敬斋把引票在石阶上磕齐，抬眼看度支房的窗。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Salt mounds under reed mats, a merchant holding blank salt licences on stone steps, porters listening from the wall",
		"tags": ["fiscal", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 6,
		"blocked_story_flags": [String(Ids.FLAG_TWO_COURTS)],
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.20},
				"add_weight": 35,
				"multiplier_q16": MUL_130,
				"reason": "盐贵，私盐就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有仓有场，才包得出去",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_TWO_PRICES)},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "官民两价，盐也分成两种卖法",
			},
		],
		"options": [
			Shared.option(
				"farm_out_the_salt", "包给三家，连查禁",
				"盐仓换了锁",
				"押金当天就抬进库房，三口箱子，抬箱的人手都勒红了。盐仓换了锁，锁头当天交到吴敬斋的二掌柜手里。第三天，墙根下等着的脚夫少了一半，剩下的替三家挑盐，扁担上刻了号。",
				[
					Shared.cash_in(3.0, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（盐引押金）"),
					Shared.stock("salt", 30),
					Shared.extraction(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"run_it_as_a_state_shop", "官营，自己派人卖",
				"盐吏下乡",
				"官盐从沙沟场直接运到县城的官铺，队里跟着两个书手，一路记秤。灶户按册领工食，多煮的盐要交上来。脚夫挑着官盐走，扁担上挂了官发的木牌。",
				[
					Shared.extraction(5, 540),
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（盐利入库）"),
					Shared.trade_capacity(8, 540),
					Shared.staple(5, 540),
				]),
			Shared.option(
				"leave_it_alone", "谁也不包，照旧散卖",
				"苇席还盖着",
				"吴敬斋把引票收回袖里，起身时在石阶上蹭了蹭鞋底。管场的秤砣还是往袖子里塞，一天塞两回。到了年底盘仓，账上写着满仓，苇席底下只剩薄薄一层。",
				[
					Shared.extraction(-4, 540),
					Shared.flag(Ids.FLAG_SALT_OPEN, 720, "标记「盐禁虚设」"),
					Shared.bias(Ids.TAG_UNREST, 1.25, 720),
				]),
		],
	}))

	# ═══ 孤立 · 两本账 ═════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FISCAL_TWO_LEDGERS),
		"title": "{settlement_name}·两本账",
		"body_text": "郭阿满在落雁坡的仓房里对账，对到第三遍，手指在算盘上停住。官账上写着满仓，实地盘下来短了七十石，短的那截记在一本靛蓝封皮的小册上，只有他和仓吏知道。小册子藏在他家米缸后头，纸角被老鼠啃过。今天他来得早，是因为上头要派人清点，日子定在初八。仓吏把一串钥匙放在他手边，铜环上一层油汗，说这账你看着办。郭阿满把官账合上，又打开，把多出来的那一页折了个角。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A granary clerk comparing an official ledger with a hidden blue notebook, keys on the desk, grain sacks behind",
		"tags": ["fiscal", "unrest", "scholar"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 600,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_110,
				"reason": "仓多，账也多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 25,
				"reason": "粮价一高，仓里的数就有人动",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_TWO_PRICES)},
				"add_weight": 30,
				"multiplier_q16": MUL_115,
				"reason": "官价与市价两套，账更难对一个数",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ACCOUNTS_CLEAN)},
				"add_weight": 0,
				"multiplier_q16": MUL_075,
				"reason": "账清吏肃，小册子不敢留",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_PATCHED_BOOKS)},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "上头的账做过平，底下就学着做",
			},
		],
		"options": [
			Shared.option(
				"hand_over_the_book", "把册子交上去",
				"初八那天没下雨",
				"清点的人来了，郭阿满把靛蓝册子放在最上面。追亏空追了三天，仓吏把自己的牛牵去抵了。郭阿满还坐在原来的位置上，中午自己带饭，饭盒放在算盘旁边，没人过来分他的菜。",
				[
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}追缴其现金的 2%（补仓亏空）"),
					Shared.knowledge(4, 540),
					Shared.research_signal("breakthrough.industrial_organization", "复式记账"),
				]),
			Shared.option(
				"fold_it_into_the_wastage", "并进火耗，两本合一",
				"多出一成耗",
				"靛蓝册子烧了，灰倒进灶膛。新立的名目叫「收粮折耗」，写在官账的第三栏，字很小。秋后收粮，斗上加了一只木刮板，刮下来的归仓；交粮的人没说什么，只把刮板抬起来看了看。",
				[
					Shared.staple(5, 540),
					Shared.knowledge(-4, 540),
					Shared.flag(Ids.FLAG_COOKED_BOOKS, 900, "标记「火耗加征」"),
				]),
			Shared.option(
				"wait_for_the_count", "等清点的人来",
				"两不追究",
				"初八那天，清点的人在仓里转了一圈，看了官账，翻到第三页就合上了。他没问那七十石，郭阿满也没提。两人在仓门口站了一会，谁也没先走，门槛外的谷壳被风掀起一层。",
				[
					Shared.knowledge(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 900),
				]),
		],
	}))
