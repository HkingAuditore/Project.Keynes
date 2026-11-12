class_name NarrativeEventCatalogAtomChain
extends RefCounted

## 停堆链（三幕，era 9–10）：一座反应堆如何变成全城的表决。
##
##   第一次并网（脉冲，one_shot）→ 废料池（脉冲，需完成并网）→ 表决（定时，由第二幕排程）
##
## 这是补 era 9–10 的链：此前高时代只有四条孤立事件，没有前后幕。
## 三幕的代价依次是：噪声与风险 → 土地与运输 → 电与就业；最后一幕让玩家为前两幕付总账。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"atomchain"
const PREFIX := "evt.atomchain."

const CAST := [
	"郝工", "池监", "岑代表", "白塔", "废料池", "控制室", "表决票", "冷却水", "坡地",
]

const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "停堆链",
		"theme": "并网、废料与表决",
		"era_band": "9-10",
		"prefix": PREFIX,
		"scale": "3 幕宏观链",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_CHAIN_ATOM_LIGHT),
			String(Ids.EVT_CHAIN_ATOM_WASTE),
			String(Ids.EVT_CHAIN_ATOM_VOTE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 第一次并网 ═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_ATOM_LIGHT),
		"title": "{settlement_name}·并网",
		"body_text": "白塔的反应堆第一次并网，控制室里的灯全亮了。郝工盯着表盘，说还能再往上推两格；池监按住他的手，说先跑半个月再说。城里的电灯比往年亮，工厂的机器转到了半夜。白塔脚下的村子却没睡，有人蹲在院墙外听那声音。岑代表从村里来，问这东西要是出事，往哪跑。没人答他。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A reactor hall control room at first grid connection, dials lit, an engineer and a supervisor arguing over the controls",
		"tags": ["atom", "chain", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "厂多，电就不够用",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 15,
				"reason": "技术攒够了",
			},
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 15,
				"reason": "要电，也要活干",
			},
		],
		"options": [
			Shared.gamble(
				"full_power", "满功率并网",
				Shared.branch(39322, "表盘推到顶", # 60%
					"表盘推到顶，控制室的嗡声比平时低了一点。城里的灯亮到后半夜，工厂的汽笛在半夜响了一次。白塔脚下的村子，那一夜没有熄灯。",
					[
						Shared.manufacturing(5, 540),
						Shared.energy(5, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
						Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 360, "废料池"),
					]),
				Shared.branch(26214, "跳了一次机", # 40%
					"推到第二格，警报先响了。控制棒落下去，整座城的灯灭了一瞬，又亮起来。池监在记录本上写了一行，写完把笔放下，手还在抖。",
					[
						Shared.energy(-4, 540),
						Shared.manufacturing(-2, 360),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
						Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 300, "废料池"),
					])),
			Shared.option(
				"half_power", "半功率试运行",
				"只推了一格",
				"只推了一格，控制室里的人轮班守着。城里的电够用，工厂加了一班。郝工把记录本写满了两页，池监在旁边看着，没有说话。",
				[
					Shared.knowledge(4, 540),
					Shared.manufacturing(2, 540),
					Shared.staple(3, 360),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 300, "废料池"),
				]),
			Shared.option(
				"wait_a_year", "推迟并网，再查一遍",
				"白塔空转了一年",
				"白塔空转了一年，冷却水在管道里来回走，没有进汽轮机。城里的电还是老样子，工厂少开一班。郝工把图纸锁进柜子，钥匙挂在池监腰上。",
				[
					Shared.manufacturing(-3, 540),
					Shared.knowledge(2, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 240, "废料池"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 废料池 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_ATOM_WASTE),
		"title": "{settlement_name}·废料池",
		"body_text": "废料池的水位线又高了一指。池监把记录本翻给郝工看，说再装半年就满了。扩建要占白塔脚下一片坡地，那片坡地是岑代表村里的。运走要车队，路上要人押，走到哪儿都得先问一声。封存最省事，可机器一停，城里的灯就得另找来源。三个人站在池边，风从坡上下来，带着一股铁锈味。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A spent fuel pool with a rising water line, a supervisor showing a logbook, a village representative standing at the fence",
		"tags": ["atom", "chain", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 160,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_events_completed": [String(Ids.EVT_CHAIN_ATOM_LIGHT)],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 20,
				"reason": "厂越多，废料越多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 15,
				"reason": "人多，地就紧",
			},
		],
		"options": [
			Shared.option(
				"expand_here", "就地扩建，占那片坡地",
				"围栏往外推了三十步",
				"围栏往外推了三十步，坡地上的果树砍了。岑代表在围栏外站了半天，捡了一根断枝回去。池监把新池的水位线画在墙上，画得很高。",
				[
					Shared.extraction(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_VOTE, 300, "表决"),
				]),
			Shared.option(
				"ship_it_away", "装车运往外地",
				"车队夜里出发",
				"车队在夜里出发，六辆车，前后各一辆空车。走到边界被拦下来，对方要一份文件，文件在池监的抽屉里。车在界上停了两天，最后原路开回来。",
				[
					Shared.cash_out(2.5, 360),
					Shared.trade_capacity(3, 540),
					Shared.bias(Ids.TAG_FRONTIER, 1.15, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_VOTE, 240, "表决"),
				]),
			Shared.option(
				"seal_it_for_now", "先封存，停一半机组",
				"一半的灯灭了",
				"一半机组停下来，城里的灯暗了一截，工厂改回夜里开工。池监把封条贴上去，贴了两道。郝工站在控制室里，把一半的表盘用布盖上。",
				[
					Shared.energy(-3, 540),
					Shared.knowledge(2, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_VOTE, 180, "表决"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 表决 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_ATOM_VOTE),
		"title": "{settlement_name}·表决",
		"body_text": "全城表决那天，投票的桌子摆在白塔脚下。岑代表的人来得最早，郝工的人来得最齐。票数一张一张念，念到一半，两边都不说话了。念票的人嗓子哑了，换了一个人接着念。池监站在桌子后面，手里捏着最后一张，没投。风把票纸吹起来一张，落在废料池的围栏边上，没人去捡。",
		"image_key": "family.house",
		"ai_visual_prompt": "A public vote at the foot of a reactor tower, two groups watching a clerk count ballots, one ballot blown against a fence",
		"tags": ["atom", "chain", "unrest"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 220,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 9,
		"max_era_index": 10,
		"options": [
			Shared.option(
				"keep_it_running", "继续运行",
				"白塔没有停",
				"白塔没有停，城里的灯照旧亮到后半夜。岑代表的人在围栏外搭了一个棚子，住了下来。池监把最后一张票投进箱子，箱子满了，盖子合不上。",
				[
					Shared.energy(6, 540),
					Shared.manufacturing(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"phase_it_out", "逐步停堆",
				"灯一盏一盏地换",
				"机组一台一台停，城里的灯一盏一盏换回旧的电。工厂走了一批人，村里回来了一批。白塔还立着，塔顶的灯灭了以后，夜里能看见星星。",
				[
					Shared.energy(-5, 540),
					Shared.manufacturing(-3, 540),
					Shared.birth(3, 540),
				]),
			Shared.option(
				"send_it_upstairs", "交给上头决定",
				"文件装进牛皮纸袋",
				"文件装进牛皮纸袋，封了口，送到更远的地方。白塔照旧运行，围栏外的棚子拆了又搭。池监在记录本最后一页写下日期，写完把笔帽盖上，盖了很久。",
				[
					Shared.knowledge(-3, 540),
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))
