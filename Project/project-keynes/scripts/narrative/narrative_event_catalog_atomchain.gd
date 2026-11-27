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
	"能源委员会", "反应堆", "电网", "安全局", "废料池", "地方议会", "公投", "工业界", "机组",
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
		"body_text": "{settlement_name}的新建核电反应堆已完成前期调试，正准备首次接入区域电网。能源委员会与工业界呼吁立即满功率并网，以彻底缓解制造业的电力瓶颈；核安全局则警告机组尚未经历完整热负荷周期，强行推高出力存在重大隐患。与此同时，周边社区代表通过地方议会发出质询，要求政府公开应急疏散预案并暂缓商运。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A reactor hall control room at first grid connection, dials lit, an engineer and a supervisor arguing over the controls",
		"tags": ["atom", "chain", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.nuclear_energy"],
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
				"full_power", "批准满功率并网",
				Shared.branch(39322, "满载稳定运行", # 60%
					"反应堆顺利达成满功率输出，区域电网负荷骤降，本地工业区迅速开启全天候生产。尽管能源危机暂解，周边居民对核设施安全的疑虑仍持续发酵。",
					[
						Shared.manufacturing(15, 540),
						Shared.energy(15, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
						Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 360, "废料池"),
					]),
				Shared.branch(26214, "触发紧急停机", # 40%
					"推升功率期间冷却回路触发高温警报，控制棒紧急插入导致机组跳闸并引发短暂大停电。事故简报虽被迅速压下，但公众恐慌与问责声浪已席卷全城。",
					[
						Shared.energy(-12, 540),
						Shared.manufacturing(-8, 360),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
						Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 300, "废料池"),
					])),
			Shared.option(
				"half_power", "核准半功率试运行",
				"稳步接入电网",
				"机组按半功率方案投入试运行，工程团队借此积累了详尽的堆芯运行数据。尽管未能立刻满足全部工业需求，安全局的审慎策略赢得了专业界认可。",
				[
					Shared.knowledge(12, 540),
					Shared.manufacturing(8, 540),
					Shared.staple(10, 360),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 300, "废料池"),
				]),
			Shared.option(
				"wait_a_year", "推迟并网，全面复检",
				"机组延期投产",
				"政府下令暂停并网并开展为期一年的全系统安全审计。电网缺口迫使部分工厂缩减班次，但严格的审查标准为后续核电规范奠定了基础。",
				[
					Shared.manufacturing(-10, 540),
					Shared.knowledge(8, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_WASTE, 240, "废料池"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 废料池 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_ATOM_WASTE),
		"title": "{settlement_name}·废料池",
		"body_text": "连续运转令{settlement_name}核电站的乏燃料废料池逼近设计库容，安全局警告半年内必须落实处置方案。能源委员会主张征用厂区外围坡地就地扩建储池，但此举将直接触怒地方议会与周边农业社区。若改为专列跨区外运，则需承担高昂的安保转运开支并面临沿线抵制；若选择封存减产，区域电网又将立刻承压。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A spent fuel pool with a rising water line, a supervisor showing a logbook, a village representative standing at the fence",
		"tags": ["atom", "chain", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 160,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.nuclear_energy"],
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
				"expand_here", "征地就地扩建废料池",
				"外围坡地划入禁区",
				"政府强行征用外围坡地并扩建了隔离设施，核电站得以维持满载运转。失去果园与耕地的社区随即发起抗议，地方矛盾进一步激化。",
				[
					Shared.extraction(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_VOTE, 300, "表决"),
				]),
			Shared.option(
				"ship_it_away", "拨款组织跨区专列外运",
				"乏燃料转运受阻",
				"国库拨出重金组建武装转运车队，但专列在边界屡遭邻区盘查与抗议阻拦，周转成本远超预期。外运通道虽勉强打通，区域摩擦却随之升级。",
				[
					Shared.cash_out(6, 360),
					Shared.trade_capacity(8, 540),
					Shared.bias(Ids.TAG_FRONTIER, 1.15, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_VOTE, 240, "表决"),
				]),
			Shared.option(
				"seal_it_for_now", "封存半数机组，降载运行",
				"电网出力大幅缩减",
				"安全局对半数机组实施预防性封存以减缓废料累积。区域电力供应随之吃紧，但科研部门借机获得了宝贵的乏燃料减容研究窗口。",
				[
					Shared.energy(-10, 540),
					Shared.knowledge(8, 540),
					Shared.schedule(Ids.EVT_CHAIN_ATOM_VOTE, 180, "表决"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 表决 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_ATOM_VOTE),
		"title": "{settlement_name}·表决",
		"body_text": "围绕{settlement_name}核电站去留的争论最终演变为全城公投。工业界与能源委员会反复强调，一旦停堆将导致区域电网崩溃与大批工厂外迁；而反对派联合地方议会，以废料池风险和社区安全为由要求彻底弃核。计票结果极其接近，全城舆论已然撕裂，最终的能源国策仍需由国家最高层拍板定案。",
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
				"keep_it_running", "否决停堆，维持核电运转",
				"核电国策得以延续",
				"中央政府力排众议批准机组继续运行，充沛的电力保障了工业区的长期扩张。反对派在隔离区外发起持久静坐，社会对立短期内难以弥合。",
				[
					Shared.energy(18, 540),
					Shared.manufacturing(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"phase_it_out", "尊重民意，逐步停堆退役",
				"核电站进入退役程序",
				"各机组按计划陆续停机并切换回常规电网，重工业产出与就业随之回落。社区紧张局势显著缓和，居民对地方居住环境的信心得以恢复。",
				[
					Shared.energy(-15, 540),
					Shared.manufacturing(-10, 540),
					Shared.birth(10, 540),
				]),
			Shared.option(
				"send_it_upstairs", "冻结公投结果，行政裁定",
				"能源争端被强行搁置",
				"政府以国家战略安全为由冻结地方公投效力，强行维持现行运转并征收特别安全费。此举虽保住了短期财政进项，却严重折损了公信力与科研士气。",
				[
					Shared.knowledge(-10, 540),
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))
