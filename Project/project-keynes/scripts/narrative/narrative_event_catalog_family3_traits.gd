extends RefCounted

## Family events prompted by traits a clan already has.

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TraitChanges = preload("res://scripts/narrative/narrative_event_family_trait_changes.gd")


static func append(catalog, mul_115: int, mul_120: int) -> void:
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 重农族（B）══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_ENCLOSURE_RESIST),
		"title": "{settlement_name}·重农族",
		"body_text": "城外的荒地要圈给牧场，周家的地正好在中间。周朴说这一族三代种地，地是命根子；牧场的人说，一亩草养三只羊。韦顺带着文书来，文书上写着补偿的数目。周朴把文书推回去，说数目不对。推的时候，他的手在抖。院子里的犁还挂在墙上，犁头磨得发亮。他的指尖在“补偿”两个字上停了一下。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A farming clan elder refusing an enclosure document, a polished ploughshare hanging on the wall, pasture stakes outside",
		"tags": ["family", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i001_agrarian", "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": mul_120,
				"reason": "这一族挡得住圈地",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.20},
				"add_weight": 15,
				"reason": "种地的人还多",
			},
		],
		"options": [
			Shared.option(
				"force_the_enclosure", "强行圈走",
				"界桩钉进了他家的地",
				"界桩钉进他家的地，周朴带人拔了三回。第四回，衙门的差役站在坡上看着。那年周家不再种那块地，周朴把犁收进屋里，再没挂出来。",
				[
					TraitChanges.remove("i001_agrarian", "重农"),
					Shared.agriculture(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"trade_land", "拿别处换",
				"换到河那边",
				"换到河那边，地远了一截，水却更好。周朴去看了一回，蹲在田埂上抓了把土，说这土能种。补偿的钱还没到位，他已经让人去翻地了。",
				[
					Shared.cash_out(2.0, 360),
					Shared.agriculture(2, 540),
					TraitChanges.grant("i025_pioneer", "拓荒者"),
				]),
			Shared.option(
				"drop_it", "这事先作罢",
				"牧场另找地方",
				"牧场另找地方，周家的地保住了。那年秋天，牧场的人从坡下过，周朴让人给他们送了一担水。坡上坡下都没再动土。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 商帮（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_CHARTER_GUILD),
		"title": "{settlement_name}·商帮",
		"body_text": "李家的商队从北边回来，带回一张特许的样本：别处的商号拿到这张纸，就能包一条商路。李七想要，韦顺说特许要公开招。周敬之在旁边听着，说公开招也是价高者得。李七把样本放在桌上，纸角压着一枚铜印。窗外，另外两家商号的伙计已经在门口转了两圈。李七说，这张纸要是拿不到，明年北边的路就归别人了。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A merchant clan leader with a sample charter under a bronze seal, rival clerks loitering outside the window",
		"tags": ["family", "market", "trade"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i019_trade", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": mul_120,
				"reason": "这种族才拿得出保证金",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 15,
				"reason": "商号多，盯着这条路的人也多",
			},
		],
		"options": [
			Shared.gamble(
				"grant_the_charter", "把特许给他",
				Shared.branch(39322, "商路通了", # 60%
					"商路通了，李家的车队每月走一趟，回来时车厢里装着北边的皮子。李七在祠堂里供了那张特许，纸角压着铜印。另外两家商号把招牌改了。",
					[
						TraitChanges.grant("i026_magnate", "家大业大"),
						Shared.trade_capacity(6, 540),
						Shared.cash_in(1.0, 360),
					]),
				Shared.branch(26214, "同行把他告了", # 40%
					"同行把李家告了，说特许是私下许的。衙门来查，特许暂扣。李七在堂上站了半天，回来把样本锁进柜子，再没拿出来。",
					[
						Shared.cash_in(1.0, 360),
						Shared.manufacturing(-3, 360),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"open_bidding", "公开招标",
				"价高者得",
				"公开招标，价高者得。李家出的价排第二，商路归了别家。李七把标书收起来，说这样也好，输得明白；那年他家的车队改走水路。",
				[
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"turn_it_down", "把折子驳回",
				"样本退回去了",
				"样本退回去了，李七在门口站了一会儿。另外两家商号也没拿到，商路照旧没人包。那年北边的货少了一成，来的车也少了。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 工匠族（B）══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_CRAFT_SPLIT),
		"title": "{settlement_name}·工匠族",
		"body_text": "罗阿石的族里出了七个匠人，行会只认三个。行会说族里抢了行会的活，族里说行会的价压得太低。两边在作坊门口对峙，学徒站在中间，不知道该听谁。罗阿石把工具收进箱子，说这活不干了。箱子扣上，锁没锁。学徒的工钱是族里出的，行会不认这笔账，也不认这几个人。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Craftsmen facing a guild steward at a workshop door, apprentices standing between them, a tool chest half closed",
		"tags": ["family", "labor", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "j004_craft", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.15},
				"add_weight": 20,
				"multiplier_q16": mul_120,
				"reason": "匠户成街，行会才压得住",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "作坊多，活才抢得起来",
			},
		],
		"options": [
			Shared.option(
				"back_the_clan", "站在族里这边",
				"箱子又打开了",
				"箱子又打开了，罗阿石带着七个匠人另立了门户。行会的册子上少了七行。那年冬天，行会的活排到开春，族里的活接不完。",
				[
					TraitChanges.grant("i003_manufacturing", "制造世家"),
					Shared.manufacturing(4, 540),
					Shared.tools(5, 540),
				]),
			Shared.option(
				"back_the_guild", "站在行会这边",
				"七个减成三个",
				"七个减成三个，另外四个把工具卖了，去了码头。罗阿石不再挂族里的招牌，行会的册子上添了他的名字。作坊的门口，行会的牌子挂得比族牌高。",
				[
					TraitChanges.remove("j004_craft", "工匠世家"),
					Shared.manufacturing(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"mediate", "两头调停",
				"两边各让一步",
				"两边各让一步，行会认了五个，族里把价抬了一成。罗阿石请两边的人吃了一顿饭，饭桌上谁也没提这件事。",
				[
					Shared.cash_out(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 查书（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_LETTERS_RAID),
		"title": "{settlement_name}·查书",
		"body_text": "周家的藏书楼被查了。来的人说有一部书不该留，周朴说这书是祖上传的，书页上有先人的批注。韦顺站在书架前，把书抽出来又放回去。楼下的院子里，几个差役在等。周朴的手按在书脊上，没有松。楼外的风把窗纸吹得响。韦顺说，书是死的，人是活的，可这话他说得很轻。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan library being searched, an elder's hand resting on a book spine, clerks waiting in the courtyard",
		"tags": ["family", "school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "j009_letters", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": mul_115,
				"reason": "这种族的书楼才有人惦记",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "城里读书人多，书才传得开",
			},
		],
		"options": [
			Shared.option(
				"shield_the_books", "把书保下来",
				"书还在架上",
				"书还在架上，周朴在楼里坐了一夜。第二天，差役走了，书楼的门照旧开着。来借书的人多了一倍，也有人再没来过。",
				[
					TraitChanges.grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"hand_it_over", "把书交出去",
				"书架空了一格",
				"书架空了一格，周朴把那一格的灰擦了又擦。差役走的时候，把书装进一只木匣。族里的人从此不再提这部书。",
				[
					TraitChanges.remove("j009_letters", "书香门第"),
					Shared.knowledge(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"burn_half", "烧掉一半",
				"院子里烧了半夜",
				"院子里烧了半夜，纸灰飘到墙外。周朴站在火边，把没烧完的几页捡出来，夹进另一本书里。第二天，查的人来看了一眼，走了。",
				[
					Shared.knowledge(-2, 360),
					Shared.cash_out(1.0, 360),
				]),
		],
	}))

	# ═══ 抗税（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_MAGNATE_TAX),
		"title": "{settlement_name}·抗税",
		"body_text": "加税的告示贴到南门，李氏的铺子当天关了半边门。李七说族里的生意经不起再加，韦顺说税是朝廷的。周敬之把告示揭下来，卷好，放进袖子里。第二天，南门的铺子开了，价牌换了一块，字比原来小。李七说加一成税，铺子就得关一半；韦顺说，税不是他定的。价牌换了新的，字比原来小，老主顾得凑近才看清。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A shuttered clan shop at the south gate, a tax notice taken down and rolled, a new smaller price board",
		"tags": ["family", "fiscal", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 5,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i026_magnate", "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": mul_120,
				"reason": "这样的族一关铺子，半条街都看得见",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.20},
				"add_weight": 15,
				"reason": "米价高，税更收不上来",
			},
		],
		"options": [
			Shared.option(
				"collect_it_anyway", "照告示加税",
				"税吏进了铺子",
				"税吏进了铺子，李七把账本摊开，一页一页翻。税是收上来了，南门的铺子关了三家。那年冬天，街上的人少了一截。",
				[
					Shared.cash_in(2.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"negotiate", "跟族里谈",
				"税减了一成",
				"税减了一成，李家把铺子全开了，还添了一间。李七在祠堂里请了一桌，韦顺没去。第二年，李家的商队多走了两条路。",
				[
					Shared.cash_in(1.0, 360),
					Shared.trade_capacity(3, 540),
					TraitChanges.grant("i019_trade", "商路人脉"),
				]),
			Shared.option(
				"exempt_them", "免了这一回",
				"告示收进了袖子",
				"告示没有贴回去，税也没收。李家的铺子照旧开着，价牌也换了回去。别家商号看着，第二年也有样学样。",
				[
					Shared.manufacturing(2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 转产（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_COASTAL_SHIFT),
		"title": "{settlement_name}·转产",
		"body_text": "周家的船队跑了二十年，港口的税一年比一年重。李潮说把船卖了，在城外开纺织厂；周朴说船是祖上传下来的。韦顺把两种账都算了一遍，算完把两张纸并排放在桌上。港口传来汽笛声，是别家的船进港了。周朴说祖上也没见过这么大的厂，李潮说时代不一样了。李潮把两张纸往前推了推，周朴的指头压在上面那张，没动。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A clan shipowner weighing two account sheets, harbour and a factory site outside the window, a steamer arriving",
		"tags": ["family", "sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i029_coastal", "bool_value": true},
			{"op": Op.ERA_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": mul_120,
				"reason": "这种族才转得动",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "城里有厂，才谈得上转产",
			},
		],
		"options": [
			Shared.option(
				"shift_to_factory", "支持转产",
				"船卖了，厂开了",
				"船卖了，厂开了。李潮把第一批布匹装上火车，周朴去码头看了最后一眼。船坞空了，厂房里的机器响到半夜。",
				[
					TraitChanges.grant("i003_manufacturing", "制造世家"),
					Shared.manufacturing(5, 540),
					Shared.cash_out(2.0, 360),
				]),
			Shared.option(
				"keep_the_fleet", "维持船队",
				"船又补了一回",
				"船又补了一回，底舱换了新板。那年季风来得晚，船队少跑一趟。李潮把账本合上，说再撑一年看看。",
				[
					Shared.trade_capacity(4, 540),
					Shared.manufacturing(-2, 360),
				]),
			Shared.option(
				"hedge_both", "两头下注",
				"船和厂都留一半",
				"船和厂都留了一半，钱分成两处。周朴说这样稳，李潮说这样两头都做不大。第一年两边都没赔，也都没赚。",
				[
					Shared.cash_out(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
