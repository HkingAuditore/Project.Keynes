class_name StratumRebellionContent
extends RefCounted

## Authored four-stage rebellion chain. The service builds these definitions at
## offer time because the body needs the local settlement/profession and the
## option probabilities are computed from native odds, not authored weights.

const NarrativeEventDefinitionScript = preload(
	"res://scripts/narrative/narrative_event_definition.gd")
const NarrativeOptionScript = preload(
	"res://scripts/narrative/narrative_option.gd")
const NarrativeOutcomeScript = preload(
	"res://scripts/narrative/narrative_outcome.gd")

const ACTION_CONCEDE := 0
const ACTION_BRIBE := 1
const ACTION_REPRESS := 2
const ACTION_IGNORE := 3
const ACTION_AMNESTY := 4
const ACTION_ABANDON := 5


static func build(stage: int, profession_name: String, settlement_name: String,
		actions: Array, probabilities: Dictionary, costs: Array,
		profession_key: String = "") -> NarrativeEventDefinition:
	var def := NarrativeEventDefinitionScript.new()
	def.event_id = StringName("evt.rebellion.stage_%d" % clampi(stage, 1, 4))
	def.trigger_channel = NarrativeEventDefinitionScript.TriggerChannel.SCHEDULED_ONLY
	def.scope = NarrativeEventDefinitionScript.Scope.CELL
	def.base_weight = 100
	def.trigger_chance_q16 = 65536
	def.cooldown_days = 0
	def.one_shot = false
	def.tags = PackedStringArray(["unrest", "rebellion", "labor"])
	def.title = _title(stage, settlement_name)
	def.body_text = _body(stage, profession_name, settlement_name, profession_key)
	for i in range(actions.size()):
		var action := int(actions[i])
		var option := _option(stage, action, costs[i] if i < costs.size() else 0)
		var probs: PackedInt32Array = probabilities.get(i, PackedInt32Array([32768, 32768]))
		var success_prob := int(probs[0]) if probs.size() > 0 else 32768
		var failure_prob := int(probs[1]) if probs.size() > 1 else 65536 - success_prob
		option.outcomes = [
			_outcome(true, stage, action, success_prob),
			_outcome(false, stage, action, failure_prob),
		]
		option.tooltip_hint = _tooltip(stage, action, success_prob)
		def.options.append(option)
	return def


static func actions_for_stage(stage: int) -> Array:
	match stage:
		1:
			return [ACTION_CONCEDE, ACTION_BRIBE, ACTION_REPRESS, ACTION_IGNORE]
		2:
			return [ACTION_CONCEDE, ACTION_BRIBE, ACTION_REPRESS]
		3:
			return [ACTION_CONCEDE, ACTION_BRIBE, ACTION_REPRESS]
		_:
			return [ACTION_AMNESTY, ACTION_REPRESS, ACTION_ABANDON]


static func option_text(stage: int, action: int) -> String:
	var stage_key := "%d_%d" % [clampi(stage, 1, 4), action]
	match stage_key:
		"1_0": return "宽减赋役，安抚民心"
		"1_1": return "私下笼络核心人物"
		"1_2": return "逮捕首倡者，以儆效尤"
		"1_3": return "维持现状，不予理会"
		"2_0": return "公开谈判，做出让步"
		"2_1": return "暗中分化并收买代表"
		"2_2": return "调遣守军驱散集会"
		"3_0": return "承诺改革，平息风潮"
		"3_1": return "重金收买组织核心"
		"3_2": return "全城戒严，逮捕首领"
		"4_4": return "颁布大赦，招安归顺"
		"4_2": return "派兵强行平叛"
		"4_5": return "撤离守军，暂弃此城"
		_: return "暂且静观其变"


static func _option(stage: int, action: int, cost_bp: int) -> NarrativeOption:
	var option := NarrativeOptionScript.new()
	option.option_id = StringName("rebellion_%d_%d" % [stage, action])
	option.text = option_text(stage, action)
	if cost_bp > 0:
		option.tooltip_hint = "耗费国库约 %d%%" % int(round(cost_bp / 100.0))
	return option


static func _title(stage: int, settlement: String) -> String:
	match stage:
		1: return "%s·阶层骚动" % settlement
		2: return "%s·联名请愿" % settlement
		3: return "%s·全城罢工" % settlement
		_: return "%s·武装起事" % settlement


static func _body(stage: int, profession: String, settlement: String,
		profession_key: String = "") -> String:
	if profession_key == "soldier":
		return _soldier_body(stage, profession, settlement)
	if profession_key == "merchant":
		return _merchant_body(stage, profession, settlement)
	match stage:
		1:
			return "物价波动与沉重税负令%s的%s怨声载道。尽管尚未爆发公开冲突，该阶层已向地方官署递交抗议，要求朝廷立刻减轻负担。若放任不满继续蔓延，地方秩序恐将迅速失控。" % [settlement, profession]
		2:
			return "%s的%s集体停工并聚集于城区广场，向地方官署呈上联名请愿书，要求减免税役并保障基本生计。周边其他行业亦在观望局势，政局已滑向公开对抗的边缘，中央必须尽快表态。" % [settlement, profession]
		3:
			return "%s的%s正式发起大规模罢工与抗议浪潮，主要工坊与市集相继停摆，组织者已竖起反抗旗帜并开始串联其他阶层。地方守军处于高度戒备状态，正等待中央下达妥协或镇压的明确指令。" % [settlement, profession]
		_:
			return "局势彻底失控，%s的%s在昨夜发动武装起事，迅速控制了当地仓储与交通要冲。起事首领自称代表本城民意，向中央发出最后通牒：若不立刻答应改革与开仓要求，该城将正式宣告脱离统治。" % [settlement, profession]


static func _soldier_body(stage: int, profession: String, settlement: String) -> String:
	match stage:
		1:
			return "驻守%s的%s因长期欠饷与给养不足而军心浮动。营中私下串联日渐频繁，对后勤与财政部门的怨恨正在迅速累积，若不及时安抚，恐将酿成兵变。" % [settlement, profession]
		2:
			return "驻地纪律已濒临崩溃，%s推举代表向地方官署递交联名陈情书，强硬要求补发全部欠饷、改善给养并兑现轮休承诺。全军上下枕戈待旦，绝非寻常请愿可比。" % profession
		3:
			return "%s驻军公然抗命，大批官兵拒不执行操演并占领了当地军械库与粮秣仓库。地方行政机构已被迫停摆，军政对峙一触即发，急需中央最高层做出决断。" % settlement
		_:
			return "兵变全面爆发，%s的%s武装接管了城区防务与官署要地。叛军首领发出最后通牒：要么立刻补足欠饷并颁布大赦，要么该城将另立旗号、与中央决裂。" % [settlement, profession]


static func _merchant_body(stage: int, profession: String, settlement: String) -> String:
	match stage:
		1:
			return "接连加征的商税与通行规费令%s的%s强烈不满。当地商会已联合核算税负并向官署提出正式抗议，警告若继续竭泽而渔，全城商贸将难以为继。" % [settlement, profession]
		2:
			return "%s爆发大规模集体罢市，商铺相继关门停业。当地%s通过商会发出通牒，宣称若不立刻削减商税便拒绝复市，连带港口与货运全面停滞，全城经济命脉正面临瘫痪。" % [settlement, profession]
		3:
			return "%s的%s全面切断物资流通，商队停运、货船滞港，市场供应急剧萎缩。地方官署的常规采购亦已中断，商会企图以经济窒息逼迫中央在税政上彻底低头。" % [settlement, profession]
		_:
			return "%s的商业寡头与%s出资组织武装商团，强行接管了城防与税关要冲。起事者宣告废除中央税令，企图将本地变为不受朝廷节制的自治商埠，国家主权已遭公然挑衅。" % [settlement, profession]


static func _outcome(success: bool, stage: int, action: int, probability: int) -> NarrativeOutcome:
	var outcome := NarrativeOutcomeScript.new()
	outcome.probability_q16 = clampi(probability, 1, 65535)
	outcome.outcome_title = _outcome_title(success, stage, action)
	outcome.outcome_narrative = _outcome_narrative(success, stage, action)
	outcome.effects = []
	return outcome


static func _outcome_title(success: bool, stage: int, action: int) -> String:
	if not success:
		if action == ACTION_REPRESS:
			return "镇压受挫"
		if stage >= 4:
			return "城池易帜"
		return "谈判破裂"
	match action:
		ACTION_CONCEDE: return "局势暂缓"
		ACTION_BRIBE: return "分化奏效"
		ACTION_REPRESS: return "秩序恢复"
		ACTION_IGNORE: return "风波暂歇"
		ACTION_AMNESTY: return "招安成功"
		ACTION_ABANDON: return "守军撤离"
		_: return "尘埃落定"


static func _outcome_narrative(success: bool, stage: int, action: int) -> String:
	if not success:
		if action == ACTION_REPRESS:
			return "武装清场遭到激烈反抗，冲突迅速升级。尽管部分示威者遭到拘捕，强硬镇压反而彻底点燃了全城怒火，反抗组织的凝聚力不降反升。"
		if stage >= 4:
			return "镇压与安抚皆告失败，城头已换上反抗者的旗帜。原地方官署遭到驱逐，仓储与防务全面落入叛军之手。"
		return "双方在核心诉求上寸步不让，谈判彻底破裂。代表们返回后迅速动员更多追随者，官署威信进一步受挫，危机正滑向更危险的阶段。"
	match action:
		ACTION_CONCEDE:
			return "朝廷的让步与救济迅速落实，聚集的人群陆续散去。尽管底层怨气尚未根除，这场迫在眉睫的动荡危机终究得以暂时化解。"
		ACTION_BRIBE:
			return "在私下利益输送与分化瓦解之下，抗议阵营的核心代表相继倒戈妥协。失去统一领导的集会很快瓦解，风波随之平息。"
		ACTION_REPRESS:
			return "守军迅速封锁要道并逮捕了主要组织者，街头很快恢复了表面上的平静。然而高压手段留下的恐惧与敌意，仍在暗处悄然积聚。"
		ACTION_IGNORE:
			return "面对官署的冷处理，示威人群在徒劳等待后暂且散去。但未被回应的诉求已在民间广为流传，随时可能再次爆发。"
		ACTION_AMNESTY:
			return "经过连日艰苦斡旋，大赦令终于奏效。起事首领同意交出武装与仓储控制权，一场濒临内战的危机得以和平收场。"
		ACTION_ABANDON:
			return "中央守军趁夜撤出城区，叛军随即接管防务并宣布脱离统治。该地已正式沦为敌对势力，唯有以武力收复。"
		_:
			return "地方局势暂时恢复稳定。"


static func _tooltip(stage: int, action: int, success_q16: int) -> String:
	var percent := int(round(float(success_q16) * 100.0 / 65536.0))
	match action:
		ACTION_CONCEDE:
			return "成功率约 %d%%；成则组织度回落，败则对方更硬" % percent
		ACTION_BRIBE:
			return "成功率约 %d%%；花钱分化，成则缓一缓" % percent
		ACTION_REPRESS:
			if stage >= 4:
				return "成功率约 %d%%；败则此城脱离并进入战争" % percent
			return "成功率约 %d%%；需驻军，败则组织度上涨" % percent
		ACTION_IGNORE:
			return "不掷骰；组织度继续上涨"
		ACTION_AMNESTY:
			return "成功率约 %d%%；成则整条链终结，败则此城脱离" % percent
		ACTION_ABANDON:
			return "不掷骰；该地立即脱离并进入战争"
		_:
			return "成功率约 %d%%" % percent
