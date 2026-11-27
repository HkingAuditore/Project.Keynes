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
	"度支房", "钱监", "商帮", "借券", "盐引", "河工估册", "官账", "盐仓", "国库", "兵册",
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
		"body_text": "大型水利工程的河工估册已呈报案头，预算所需劳力与资金极为庞大，而度支房国库却已捉襟见肘。军方将领摊开兵册发出严厉警告，若再拖欠军饷，边营恐生兵变。本地商帮代表趁机提出方案，愿认购官府发行的借券以垫付急款，但条件是按月计息并以重要渡口税权作为抵押。财政危机迫在眉睫，朝廷必须择路破局。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A finance office with a cash box, bond slips on a lacquer case, a military roster on the desk, river workers measuring an embankment outside",
		"tags": ["fiscal", "market", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 4,
		"max_era_index": 7,
		"required_technologies": ["tech.bills_of_exchange"],
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
				"pledge_the_ferry_tax", "以渡税作抵，发行借券",
				Shared.branch(39322, "借券售罄", # 60%
					"首批借券当日售罄并加印发行，水利工程得以顺利动工。然而渡口税权落入商帮之手，本地制造与营建成本均因债息负担而承压。",
					[
						Shared.cash_in(8, 540, "向本地人数最多的{primary_profession}征借其现金的 8%（借券，以渡口税作抵）"),
						Shared.manufacturing(-10, 540),
						Shared.build_cost(10, 540),
						Shared.bias(Ids.TAG_LABOR, 1.15, 360),
						Shared.schedule(Ids.EVT_FISCAL_AUDIT, 180, "查账"),
					]),
				Shared.branch(26214, "认购遇冷", # 40%
					"商帮对朝廷信用存疑，借券仅售出寥寥数张。国库被迫临时垫付部分工钱，工程半途停摆，军民怨言迅速发酵。",
					[
						Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征借其现金的 3%（借券只卖出六张）"),
						Shared.cash_out(5, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
						Shared.schedule(Ids.EVT_FISCAL_AUDIT, 240, "查账"),
					])),
			Shared.option(
				"mint_thin_coin", "命钱监铸行减重小钱",
				"钱监开炉",
				"钱监连夜点火开炉，并按官价收缴市面铜料铸造新钱支饷。军营哗变虽被暂时压下，但轻薄新钱流入市场已埋下货币贬值的祸根。",
				[
					Shared.manufacturing(12, 360),
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（官价收铜、新钱支饷）"),
					Shared.schedule(Ids.EVT_FISCAL_DEBASED_COIN, 120, "小钱"),
				]),
			Shared.option(
				"push_the_dike_to_next_year", "摊派暂支，工程延至明年",
				"工程搁置",
				"地方强行摊派勉强凑齐半月军饷，河堤工程却半途而废。次年春汛低田积水难退，农产受损，工匠与民众的不满情绪持续累积。",
				[
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（按亩摊派，先发一半饷）"),
					Shared.agriculture(-12, 540),
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
		"body_text": "钱监的炉火已连续数日未熄，新铸铜钱比旧制明显轻薄，成色大打折扣。度支房只顾催促产量以填补国库缺口，强令市面按新旧同价流通。兑换官钱的商民在门外排起长龙，商铺纷纷拒收轻钱或暗中抬高实价。劣币驱逐良币之势已难遏止，若任由币制崩坏，财政信用与社会秩序将一并动摇。",
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
				"keep_minting", "维持铸额，继续推行小钱",
				"币制失信",
				"钱监继续日夜赶工，铸息源源不断充入国库，冶铸作坊亦随之繁忙。但民间对官钱信心彻底崩塌，动荡暗流在市井间迅速涌动。",
				[
					Shared.manufacturing(12, 360),
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（官炉收铜、新钱支饷，铸息入库）"),
					Shared.bias(Ids.TAG_UNREST, 1.40, 720),
					Shared.schedule(Ids.EVT_FISCAL_AUDIT, 240, "查账"),
				]),
			Shared.option(
				"recall_and_recast", "停炉回铸，恢复足重旧制",
				"重铸足钱",
				"新范被尽数销毁，钱监赔本回收轻钱并按旧制重铸。国库为此蒙受巨额亏损，作坊一时停滞，但市面主食与民生开销总算随之回稳。",
				[
					Shared.cash_out(8),
					Shared.staple(-18, 540),
					Shared.manufacturing(-12, 360),
					Shared.schedule(Ids.EVT_FISCAL_AUDIT, 300, "查账"),
				]),
			Shared.option(
				"pay_soldiers_in_thin_coin", "实施双轨，新钱专发军饷",
				"官民两价",
				"新钱仅用于支应军饷，营门外很快出现折价兑换旧钱的黑市。军需开支虽在账面上大幅缩减，但官民两套折算标准令全城怨声载道。",
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
		"body_text": "度支房将借券存根、河工估册与军营兵册三箱档案齐聚案头，展开全面稽核。核对之下漏洞触目惊心：工程款项早已全额拨付，河堤却仅完工七成；兵册所列士卒名额，实点应卯者不足半数。军方将领坚称名册系下属呈报，拒绝承担责任，而案卷夹缝中更赫然查出被蓄意裁改过的官账残页。彻查还是遮掩，考验着中枢的决断力。",
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
				"audit_to_the_bottom", "一查到底，严厉追缴赃款",
				Shared.branch(45875, "清账追赃", # 70%
					"被裁改的账页在兵册深处被起获，涉案人员遭到严厉追缴。此举令吏治为之一肃，国库追回可观亏空，但也令地方商贸与作坊一时紧缩。",
					[
						Shared.cash_in(8, 540, "向本地人数最多的{primary_profession}追缴其现金的 8%"),
						Shared.manufacturing(-10, 360),
						Shared.flag(Ids.FLAG_ACCOUNTS_CLEAN, 900, "标记「账清吏肃」"),
						Shared.bias_event(Ids.EVT_FISCAL_TWO_LEDGERS, 1.40, 540, "两本账"),
						Shared.schedule(Ids.EVT_FAMILY_FATHERS_DEBT, 90, "父债"),
					]),
				Shared.branch(19661, "军方掣肘", # 30%
					"稽核刚触及高级将领，营中便派兵围堵度支房示威。朝廷被迫暂缓追查并拨款安抚军心，兵怨未平的隐患却已深深埋下。",
					[
						Shared.cash_out(5, 360),
						Shared.bias(Ids.TAG_UNREST, 1.40, 720),
						Shared.flag(Ids.FLAG_ARMY_GRIEVANCE, 720, "标记「兵怨未平」"),
					])),
			Shared.option(
				"patch_with_salt_tax", "挪用盐课，暗中平账结案",
				"账面做平",
				"亏空被悄然划入盐课名下抵扣，河工欠款与虚额兵册皆被重新誊清。账面虽恢复整洁，但盐场采掘元气大伤，地方流言亦难以平息。",
				[
					Shared.cash_out(8),
					Shared.extraction(-10, 540),
					Shared.flag(Ids.FLAG_PATCHED_BOOKS, 900, "标记「账已做平」"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"stop_the_audit", "封存案卷，以军情为重",
				"停查备战",
				"三箱账册被重新加封入库，稽核行动草草收场。边军顺利开拔并节省了调度成本，但未解的财政黑洞注定将在不久后再次爆发。",
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
		"title": "{settlement_name}·盐政",
		"body_text": "官办盐仓积盐如山，但监守自盗与私盐泛滥令税收连年亏空，地方已拖欠数月政务开支。度支房拟定改制方案，打算将盐引专卖权承包给三家大商帮，以预先收取巨额押金填补国库。商帮代表借机提出苛刻条件，要求一并接管缉私武装权力；而底层盐工与脚夫闻讯群情激愤，唯恐沦为大商盘剥的附庸。盐政归属，牵动财政与民生大局。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Salt mounds under reed mats, a merchant holding blank salt licences on stone steps, porters listening from the wall",
		"tags": ["fiscal", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 6,
		"required_technologies": ["tech.salt_preservation"],
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
				"farm_out_the_salt", "招商包卖，连同缉私权外包",
				"盐权外包",
				"商帮押金迅速充盈国库，官仓食盐亦得以投放市场。但商帮接管缉私后肆意压榨灶户与脚夫，盐场产能下滑，地方动荡风险骤升。",
				[
					Shared.cash_in(8, 540, "向本地人数最多的{primary_profession}征收其现金的 8%（盐引押金）"),
					Shared.stock("salt", 30),
					Shared.extraction(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"run_it_as_a_state_shop", "收归官营，由朝廷直接专卖",
				"官营盐务",
				"盐吏直接接管产销全链，统筹调运并按册核发工食。盐利稳定入库且采掘与商运效率大增，但官营溢利令百姓日常主食开销随之加重。",
				[
					Shared.extraction(15, 540),
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（盐利入库）"),
					Shared.trade_capacity(16, 540),
					Shared.staple(15, 540),
				]),
			Shared.option(
				"leave_it_alone", "搁置改制，维持散卖旧例",
				"盐禁虚设",
				"包卖方案被驳回，官仓监守自盗与私盐走私依旧畅行无阻。年底盘点时账实严重不符，盐业产出持续萎缩，财政缺口进一步扩大。",
				[
					Shared.extraction(-12, 540),
					Shared.flag(Ids.FLAG_SALT_OPEN, 720, "标记「盐禁虚设」"),
					Shared.bias(Ids.TAG_UNREST, 1.25, 720),
				]),
		],
	}))

	# ═══ 孤立 · 两本账 ═════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FISCAL_TWO_LEDGERS),
		"title": "{settlement_name}·两本账",
		"body_text": "巡查使团即将抵达清点粮仓，度支房基层账房却在核对官账时发现惊人真相：官账记载满仓无缺，实地盘点却短少大批储备，亏空悉数藏在一本私密暗账之中。主管仓吏明言此事牵连甚广，企图威逼利诱账房在清点前掩盖缺口。究竟是借此契机揭穿黑幕、革新会计制度，还是以损耗名义粉饰太平，将决定地方财政的清明与否。",
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
				"hand_over_the_book", "呈交暗账，严查仓储亏空",
				"彻查仓弊",
				"暗账在清点当日被公之于众，涉案仓吏被严厉追责并追缴罚没款项。朝廷趁机推行严密的对账规程，推动了复式记账理念的萌芽。",
				[
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}追缴其现金的 5%（补仓亏空）"),
					Shared.knowledge(12, 540),
					Shared.research_signal("breakthrough.industrial_organization", "复式记账"),
				]),
			Shared.option(
				"fold_it_into_the_wastage", "并入折耗，将两账合二为一",
				"火耗加征",
				"私密暗账被付之一炬，亏空被包装成官定收粮折耗转嫁给纳税户。账面虽得以弥合，却败坏了行政公信力，令民众主食负担沉重。",
				[
					Shared.staple(15, 540),
					Shared.knowledge(-12, 540),
					Shared.flag(Ids.FLAG_COOKED_BOOKS, 900, "标记「火耗加征」"),
				]),
			Shared.option(
				"wait_for_the_count", "静观其变，放任巡查敷衍",
				"上下相蒙",
				"巡查使团走马观花地翻过官账便草草结案，对巨额亏空视若无睹。官场默契保住了表面和气，却让制度腐败与民间怨气不断滋长。",
				[
					Shared.knowledge(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 900),
				]),
		],
	}))
