class_name StratumRebellionContent
extends RefCounted

## Authored four-stage rebellion chain. The service builds these definitions at
## offer time because the body needs the local settlement/profession and the
## option probabilities are computed from native odds, not authored weights.

const NarrativeEventDefinitionScript = preload(
	"res://scripts/narrative/narrative_event_definition.gd")
const NarrativeOptionScript = preload(
	"res://scripts/narrative/narrative_option.gd")

const ACTION_CONCEDE := 0
const ACTION_BRIBE := 1
const ACTION_REPRESS := 2
const ACTION_IGNORE := 3
const ACTION_AMNESTY := 4
const ACTION_ABANDON := 5


static func build(stage: int, profession_name: String, settlement_name: String,
		actions: Array, profession_key: String = "") -> NarrativeEventDefinition:
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
	for action: int in actions:
		var option := NarrativeOptionScript.new()
		option.option_id = StringName("rebellion_%d_%d" % [stage, action])
		option.text = option_text(stage, action)
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
		"1_0": return "减免今岁赋役"
		"1_1": return "召见头面人物"
		"1_2": return "拘押首倡者"
		"1_3": return "置之不理"
		"2_0": return "公开与众人谈"
		"2_1": return "暗中分化收买"
		"2_2": return "派兵驱散人群"
		"3_0": return "承诺改弦更张"
		"3_1": return "收买领头的匠户"
		"3_2": return "戒严，拿下首领"
		"4_4": return "开城招安"
		"4_2": return "调兵镇压"
		"4_5": return "带兵退出此城"
		_: return "静观其变"


static func _title(stage: int, settlement: String) -> String:
	match stage:
		1: return "%s的怨声" % settlement
		2: return "%s的请愿" % settlement
		3: return "%s的罢市" % settlement
		_: return "%s举旗" % settlement


static func _body(stage: int, profession: String, settlement: String,
		profession_key: String = "") -> String:
	if profession_key == "soldier":
		return _soldier_body(stage, profession, settlement)
	if profession_key == "merchant":
		return _merchant_body(stage, profession, settlement)
	match stage:
		1:
			return "先是粮价，后是工钱，再后来是官府那两道新加的税。%s的%s没有聚众，也没有喊口号；他们只是把话捎到了衙门口：今年能不能缓一缓。衙门外站着的人比往年多，没人说话，雪落在肩上也不拍。" % [settlement, profession]
		2:
			return "市集没有开。%s的%s把摊子收了，聚在城隍庙前，递上来一张写满名字的状纸。他们要求的不多：把仓里那批发霉的谷子换掉，把今年的丁税免了。城里其他行当的人站在街边看，没有散去的意思。" % [settlement, profession]
		3:
			return "午后，鼓声从作坊那头一直传到城门。%s的%s关了炉子，街上的人越聚越多，有人把去年修渠时各家凑布缝的旧旗挂上了秤杆。守门的兵丁没有动；他们在等一句准话。" % [settlement, profession]
		_:
			return "天没亮，城门口的火把已经排成一条线。%s的%s昨夜就占了仓房和铁匠铺，街上没有叫卖，只有脚步声。领头的不是生人——他替官府修过城门，也替城里人打过铁。他托人带话：要么开仓，要么开城。" % [settlement, profession]


static func _soldier_body(stage: int, profession: String, settlement: String) -> String:
	match stage:
		1:
			return "%s的营里已经三个月没见着足饷。%s把刀擦得很亮，却没人提开拔的事；夜里有人围着火堆算日子，算来算去，算到了粮台上。" % [settlement, profession]
		2:
			return "营门没有关。%s推了几个老军士出来，递上一张按满手印的状子：补饷、换粮、放还欠下的假。他们说得很平，手却一直按在刀柄上。" % profession
		3:
			return "%s的兵丁没有上操，也没有回营房。他们占了粮台和武库，把旗降了一半。城里的官署关着门，谁也不敢先派文官去问。" % settlement
		_:
			return "天没亮，%s的营门从里面打开。%s列着队走上街，甲叶响成一片。领头的把一封书信放在衙门口：要么补饷，要么这座城换个人来守。" % [settlement, profession]


static func _merchant_body(stage: int, profession: String, settlement: String) -> String:
	match stage:
		1:
			return "先是新加的一道厘金，后是码头上的规费。%s的%s没有闹，只是把账本摊在会馆的桌上，一页一页算给同行看：再这么抽下去，年底就剩不下什么了。" % [settlement, profession]
		2:
			return "%s的铺面一家接一家上了板。%s没有喊口号，只在会馆门口贴了一张纸：厘金不减，市不开。街上的脚夫和船户都停了手，等一个准话。" % [settlement, profession]
		3:
			return "商队不再出城。%s的%s把货压在仓里，码头的船一条条系着不卸。城里的米价开始往上走，官署的采买也断了来路。" % [settlement, profession]
		_:
			return "%s的商团自己出了人、出了钱，把城门和税关都看了起来。%s领头的人没有称王，只说从今日起，本城的捐税由会馆自己议。" % [settlement, profession]


static func outcome(success: bool, stage: int, action: int, probability: int,
		cash: int, secession: bool) -> Dictionary:
	var success_weight := probability if success else 65536 - probability
	var success_percent := roundi(success_weight * 100.0 / 65536.0)
	return {
		"rebellion_success": success,
		"probability_q16": probability,
		"probability_percent": success_percent if success else 100 - success_percent,
		"outcome_title": _outcome_title(success, action, secession),
		"outcome_narrative": _outcome_narrative(success, action, secession),
		"effect_summaries": effect_summaries(success, stage, action, cash, secession),
	}


static func effect_summaries(success: bool, stage: int, action: int,
		cash: int, secession: bool) -> PackedStringArray:
	var effects := PackedStringArray()
	if secession:
		effects.append("城市将独立，旧主权国将宣战")
	elif success and action == ACTION_AMNESTY:
		effects.append("组织度清零，动员结束并进入冷却")
	elif success:
		effects.append("组织度下降，动员降一阶并冷却")
	elif stage < 4:
		effects.append("组织度上升，动员推进一阶")
	else:
		effects.append("组织度上升，叛乱持续")
	if action == ACTION_REPRESS:
		effects.append("加重镇压创伤")
	if cash > 0:
		effects.append("国库将拨 %s 给当地居民" % String.num(cash / 10000.0, 4))
	return effects


static func _outcome_title(success: bool, action: int, secession: bool) -> String:
	if action == ACTION_IGNORE:
		return "请愿声渐高"
	if not success:
		if action == ACTION_REPRESS:
			return "压不住"
		if secession:
			return "城头换了旗"
		return "话说僵了"
	match action:
		ACTION_CONCEDE: return "暂时按下去了"
		ACTION_BRIBE: return "各退一步"
		ACTION_REPRESS: return "街面静了"
		ACTION_AMNESTY: return "收了刀兵"
		ACTION_ABANDON: return "城还是那座城"
		_: return "尘埃落定"


static func _outcome_narrative(success: bool, action: int, secession: bool) -> String:
	if action == ACTION_IGNORE:
		return "衙门没有回话。人群等了两天，散了；但那张状纸上的名字，被很多人记住了。"
	if not success:
		if action == ACTION_REPRESS:
			return "兵丁进了街，人群却没有散。有人从巷子里扔出第一块石头；再往后，事情就不由官府说了算了。"
		if secession:
			return "城里的旗换了颜色。旧日的官吏被请出衙门，仓房和城门落到了举事者手里。"
		return "话没有谈拢。为首的人回去之后，来听的人反而更多了；衙门的告示贴在墙上，没人去撕，也没人去看。"
	match action:
		ACTION_CONCEDE:
			return "众人看着承诺一条条写进告示，这才慢慢散去。有人临走时回头望了一眼，记住了落款的日子。"
		ACTION_BRIBE:
			return "为首几个人被请进后堂。出来以后，他们劝守在街口的人先回家。到了傍晚，那条街又能过车了。"
		ACTION_REPRESS:
			return "兵丁把街口封了，为首的人被带走。街面很快安静下来，只是从此以后，夜里很少有人再在那一带走动。"
		ACTION_AMNESTY:
			return "招安的告示贴出去，城里没有立刻放下刀兵。谈了三天，最后是领头的匠户先开了仓，把兵器堆在院子里。"
		ACTION_ABANDON:
			return "官军趁夜退出了城。第二天清早，城门从里面关上——这座城从此不归旧主，但也没有立刻归谁。"
		_:
			return "事情暂时平息。"


static func tooltip(action: int, funded: bool) -> String:
	match action:
		ACTION_CONCEDE, ACTION_BRIBE:
			return "这笔支出会提高成功率，两种结果均需支付。" if funded else "本次按无资金投入计算成功率。"
		ACTION_REPRESS:
			return "当地驻军和补给会影响成功率。"
	return ""
