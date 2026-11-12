class_name NarrativeEventCatalogLabor
extends RefCounted

## 工业与劳工包：地、机器、工时（5 条）。
##
## 链（三幕）：
##   牧场（脉冲，era 6–8）→ 砸机器（脉冲，需完成牧场 + 失业≥8%）→ 工时（定时，由砸机器三个分支排程）
## 孤立：
##   行会特许（脉冲，era 3–6）· 寡妇的作坊（脉冲，微观，era 3–8）
##
## 连线：牧场选"递呈文"会留下"呈文未批"，抬高砸机器的权重；
## 行会选"押着不办"会留下"火漆未干"，抬高寡妇事件的权重；
## 寡妇"保住招牌"又会抬高行会事件的权重——三件事互相咬住，不是一条直线。
##
## 数值：这一包的代价货币是产能、工时与手艺；负向全国产出不存在，
## 所以"厂子受损"一律写成本地制造业 `.cut`。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const PACK_ID := &"labor"
const PREFIX := "evt.labor."

const CAST := [
	"韩双贵", "祁玉山", "郜书办", "陶麻子", "常万山", "苗巧", "岑氏", "冯铁嘴", "潘有田", "关老闷",
	"南滩", "白碱滩", "铁砧巷", "石庙镇", "常记纱厂", "铁砧社", "界石", "梭子",
]

const MUL_090 := 58982
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474
const MUL_145 := 95027


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "工业与劳工",
		"theme": "地、机器、工时",
		"era_band": "3-8",
		"prefix": PREFIX,
		"scale": "2 中观链节 + 1 宏观收束 + 2 中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_LABOR_ENCLOSURE),
			String(Ids.EVT_LABOR_BROKEN_LOOM),
			String(Ids.EVT_LABOR_FACTORY_ACT),
			String(Ids.EVT_LABOR_GUILD_CHARTER),
			String(Ids.EVT_LABOR_WIDOW_WORKSHOP),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 牧场 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_ENCLOSURE),
		"title": "{settlement_name}·牧场",
		"body_text": "南滩牧业的木桩从荒坡下往上钉，一根接一根，钉到韩双贵家地头那条旧犁痕跟前。桩上刷白漆，写的是羊的编号，不是人的名字。犁痕尽头的石头卧在土里，他爹的名字被羊啃掉一个角，韩双贵伸手把石面上的土抹开。郜书办站在坡上念名册，念到「韩双桂」，没有人纠正。祁玉山在坡顶看羊，藤条一下一下敲着靴筒。公司的人说，一亩草养三只羊，一亩麦养不活一个人。韩双贵没接话，用鞋底把石头周围的土踩实了。",
		"image_key": "map.construction",
		"ai_visual_prompt": "White-painted pasture stakes driven into a hillside beside a worn boundary stone, sheep on the ridge, a clerk reading a roll",
		"tags": ["labor", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [TerrainTypeScript.TERRAIN.PLAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "厂子已经开到坡下",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.20},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "种地的人多，地才值得圈",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 30},
				"add_weight": 20,
				"reason": "人多地少，桩子钉得进去",
			},
		],
		"options": [
			Shared.option(
				"pull_the_stakes", "夜里把桩子拔了",
				"桩子拔了，沟没挖",
				"拔了大半夜，天亮只剩一地白漆木屑。排水沟的活停了，洼地的水排不出去，秋天的麦根泡在泥里，抓一把能捏出水。",
				[
					Shared.agriculture(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
					Shared.cash_in(1.5, 180),
					Shared.schedule(Ids.EVT_LABOR_BROKEN_LOOM, 90, "砸机器"),
				]),
			Shared.gamble(
				"take_shares_in_the_pasture", "拿地入股牧场",
				Shared.branch(39322, "羊毛价没塌", # 60%
					"头一年羊毛出了手，官家的贴补也跟着下来，韩双贵分到的钱够买半年的粮。他把石头搬回家垫门槛，有名字的那面朝上。",
					[
						Shared.agriculture(12, 720),
						Shared.trade_capacity(8, 720),
						Shared.cash_out(2.0, 180),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					]),
				Shared.branch(26214, "羊价塌了，地也没了", # 40%
					"羊毛一路往下跌，公司把牧工裁了一半。韩双贵领了工牌，站在自己原来的地头看羊，羊不认识他。",
					[
						Shared.agriculture(-6, 540),
						Shared.staple(8, 540),
						Shared.birth(-5, 540),
					])),
			Shared.option(
				"petition_and_wait", "递呈文，等批",
				"批文压在抽屉里",
				"呈文递上去，郜书办说等秋后。秋后没消息，羊进了麦地，韩双贵拿扫帚赶，赶不动，站在地头看羊把最后一片青的啃完。",
				[
					Shared.flag(Ids.FLAG_ENCLOSURE_PETITION, 540, "标记「呈文未批」"),
					Shared.bias(Ids.TAG_LABOR, 1.25, 540),
					Shared.agriculture(-6, 360),
					Shared.schedule(Ids.EVT_FAMILY_FATHERS_DEBT, 90, "父债"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 砸机器 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_BROKEN_LOOM),
		"title": "{settlement_name}·砸机器",
		"body_text": "铁砧巷的铜铃响了三下，不是换班，是有人翻墙。常记纱厂的院子里，锭子还在转，皮带打在轴上啪啪响。陶麻子从怀里掏出一把梭子，木头的，磨得发亮，是他老婆生前用的。他把梭子塞进第一台织机的齿轮，机器叫了一声，停了。跟来的人拿錾子敲锭子，一根一根，敲完扔进染缸。看门的瘸子靠在门框上，没喊。天亮前他们走了，厂门口的灯还亮着，照见地上两只踩掉的鞋。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Weavers breaking spindles inside a cotton mill at night, a wooden shuttle jammed into the gears, two abandoned shoes on the floor",
		"tags": ["labor", "unrest", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 150,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_events_completed": [String(Ids.EVT_LABOR_ENCLOSURE)],
		"conditions": [
			{"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.08},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.15},
				"add_weight": 40,
				"multiplier_q16": MUL_120,
				"reason": "巷子里闲人太多",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_ENCLOSURE_PETITION)},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "呈文没批，怨气没处去",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "厂子越多，夜里越好藏人",
			},
		],
		"options": [
			Shared.gamble(
				"put_him_on_a_machine", "让陶麻子管一台机",
				Shared.branch(39322, "他学会了看锭子的脾气", # 60%
					"陶麻子三天就摸清了皮带什么时候该松，停机比谁都准。他把老婆那把梭子挂在机头上，谁也没动它。",
					[
						Shared.country_sector("manufacturing", 5, 540),
						Shared.knowledge(4, 540),
						Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 45, "工时"),
					]),
				Shared.branch(26214, "梭子卡住了皮带", # 40%
					"陶麻子把手伸进齿轮去掏那把梭子，手背被咬掉一块。厂里赔了药钱，机器停了两天，夜里来的人更多了。",
					[
						Shared.manufacturing(-6, 360),
						Shared.bias(Ids.TAG_UNREST, 1.45, 540),
						Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 90, "工时"),
					])),
			Shared.option(
				"call_the_patrol", "叫巡警来抓人",
				"铁栅门焊上了",
				"巡警半夜进巷，抓走两个，一个十九，一个比陶麻子还大两岁。铁栅门第三天就焊上了，漆还没干，门口多了一盏灯。",
				[
					Shared.country_sector("manufacturing", 6, 540),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					Shared.cash_in(2.0, 180),
					Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 60, "工时"),
				]),
			Shared.option(
				"stop_for_one_night", "停工一夜，天亮照开",
				"红纸贴在门口",
				"停工一夜，第二天门口贴了招工的红纸，上头要「十五以上、手脚利索」，没写工钱。陶麻子站在纸前看了很久，把手插回袖子里。",
				[
					Shared.manufacturing(-5, 360),
					Shared.knowledge(-3, 360),
					Shared.bias(Ids.TAG_LABOR, 1.30, 540),
					Shared.schedule(Ids.EVT_LABOR_FACTORY_ACT, 120, "工时"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 工时 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_FACTORY_ACT),
		"title": "{settlement_name}·工时",
		"body_text": "记时钟挂在门廊下，铜面，上弦的钥匙在常万山腰上。女工苗巧站在钟底下，右边袖子空着，用别针别在肩上，是上个月皮带轮卷走的。郜医官在账房里数手指头，数到第七根，把笔放下了。常万山掏出怀表，跟钟对了一遍，说钟快了人就早来一刻，钟慢了人不能早走。苗巧没听懂，她只问了一句，天黑以前能不能出门。没有人答她。钟当当地敲了六下，院子里的人往里走。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A brass time clock in a factory portico, a one-armed woman worker standing beneath it, the owner holding a pocket watch",
		"tags": ["labor", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 220,
		"cooldown_days": 400,
		"one_shot": true,
		"min_era_index": 6,
		"max_era_index": 8,
		"options": [
			Shared.gamble(
				"try_ten_hours", "先试三个月十小时",
				Shared.branch(39322, "钟敲九下就散工", # 60%
					"头一个月单子没交齐，第二个月常万山添了两个人手，也就撑住了。苗巧第一次在天还亮的时候走回家，路上买了一把青菜。",
					[
						Shared.flag(Ids.FLAG_HOURS_TEN, 900, "标记「十小时制」"),
						Shared.birth(5, 720),
						Shared.cash_out(2.0, 180),
						Shared.research_signal("breakthrough.industrial_organization", "工厂组织"),
					]),
				Shared.branch(26214, "单子转去了外县", # 40%
					"南边的厂肯让人干到半夜，单子就转走了。常万山把钟往后拨了一刻，工钱按钟点算，账房门口多了一张写罚则的纸。",
					[
						Shared.manufacturing(-6, 540),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
						Shared.birth(-3, 540),
					])),
			Shared.option(
				"let_the_factory_decide", "不立规矩，厂里自己定",
				"钟往后拨了两刻",
				"常万山自己把钟拨了，说厂里的事厂里管。第二年春天苗巧没再来，招工的红纸上添了一行「招女工，能上夜班」。",
				[
					Shared.country_sector("manufacturing", 6, 720),
					Shared.birth(-6, 720),
					Shared.research_signal("breakthrough.electrification", "电气化"),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"pay_by_the_piece", "按件计钱，不按钟点",
				"钟拆了，换成秤",
				"门口的木箱抬走，换上一只大筐，月底过秤。苗巧一天织的布比别人少两尺，她就把邻家孩子的活也领回家，灯点到很晚。",
				[
					Shared.manufacturing(8, 540),
					Shared.birth(-5, 540),
					Shared.staple(6, 540),
				]),
		],
	}))

	# ═══ 孤立 · 行会特许 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_GUILD_CHARTER),
		"title": "{settlement_name}·行会特许",
		"body_text": "铁砧社的执事冯铁嘴把一张纸铺在案上，纸角压着一枚铜印，印还没蘸火漆。纸上留着一块空白，是写名字的地方。木匠潘有田认得那块空白：填进去的人能在镇上开张，填不进去的只能挑着担子走街。门外关老闷把扁担横在膝上，箍桶的，逃荒来的，担子上的锯条还缠着布。郜书办蘸了笔，笔尖悬在空白上头，问写谁。冯铁嘴不看他，看着潘有田。潘有田把手在围裙上擦了两下，没说话。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A guild charter with a blank name line, a bronze seal without wax, a cooper waiting outside with his tool pole",
		"tags": ["labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.15},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "匠户成街，行会说话才有人听",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "作坊多，字号就值钱",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_WIDOW_SIGN)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "寡妇的招牌保住了，别家也想讨一张纸",
			},
		],
		"options": [
			Shared.option(
				"stamp_the_charter", "盖印，只准行会开张",
				"火漆压下去了",
				"印盖在空白上，冯铁嘴吹了吹火漆，把纸卷起来塞进袖里。关老闷第二天挑着担子出了镇，锯条还缠着布，走的是石桥那条路。",
				[
					Shared.manufacturing(5, 540),
					Shared.tools(6, 540),
					Shared.cash_in(1.5, 180),
				]),
			Shared.option(
				"let_anyone_open", "不盖印，谁都能开张",
				"石桥底下支起摊子",
				"关老闷第一天就接了七只桶，箍到天黑，手上全是铁锈。铁砧社的人来看了一眼，回去把门关上了，门闩落得很响。",
				[
					Shared.country_sector("manufacturing", 4, 540),
					Shared.tools(-6, 540),
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"hold_the_paper", "押着不办，等章程",
				"纸还在案上",
				"纸压在铜印底下，火漆干了又化。关老闷搬到镇外的破庙住，白天不敢在主街生火，怕人认出来。",
				[
					Shared.flag(Ids.FLAG_CHARTER_PENDING, 540, "标记「火漆未干」"),
					Shared.manufacturing(-5, 360),
					Shared.bias(Ids.TAG_LABOR, 1.30, 540),
				]),
		],
	}))

	# ═══ 孤立 · 寡妇的作坊 ═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LABOR_WIDOW_WORKSHOP),
		"title": "{settlement_name}·寡妇的作坊",
		"body_text": "岑氏的招牌还挂在门框上，三颗铜钉，中间那颗被雨泡黑了。她男人苗德水死在春天，绳坊的活没停，欠常记的账也没停。铁砧社的执事冯铁嘴来了一趟，说招牌是行会的字号，人没了，字号要收回去。岑氏把招牌往里挪了半尺，说这牌子挡雨。学徒小顺坐在门槛上搓麻，头也不抬。冯铁嘴走的时候把话留在院里，月底以前，要么入行会，要么摘牌子。岑氏拿抹布去擦那三颗钉子，擦到中间那颗，停了一下。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A widow wiping the three brass nails of a workshop sign, an apprentice twisting hemp on the threshold",
		"tags": ["labor", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 600,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "一条街上都是作坊，招牌才有人争",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_CHARTER_PENDING)},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "行会正忙着抢字号",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.10},
				"add_weight": 20,
				"reason": "匠户多，寡妇的活才有人接",
			},
		],
		"options": [
			Shared.option(
				"keep_the_sign", "挂她的牌，缴份子",
				"招牌挪回来半尺",
				"冯铁嘴收了钱，把招牌重新钉上，用的还是那三颗钉，中间那颗换了个位置。岑氏在门后数钱，数完把借据压回米缸，压得很深。",
				[
					Shared.cash_in(1.5, 180),
					Shared.manufacturing(4, 540),
					Shared.flag(Ids.FLAG_WIDOW_SIGN, 540, "标记「招牌未摘」"),
				]),
			Shared.option(
				"take_the_sign_down", "摘牌，给人做下手",
				"招牌劈了烧水",
				"招牌摘下来靠在墙根，后来劈了烧水，铜钉收在碗柜里。岑氏天不亮去行会的作坊，天黑回来，手指上缠着麻线。",
				[
					Shared.manufacturing(5, 540),
					Shared.birth(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 360),
				]),
			Shared.option(
				"wait_until_month_end", "拖到月底再说",
				"月底过了",
				"月底那天冯铁嘴没来，来的是常记的伙计，拿着借据站在门口。岑氏把钱数了三遍，差一小截，伙计站着不走，看她把碗柜上的铜钉一颗一颗摆齐。",
				[
					Shared.manufacturing(-5, 360),
					Shared.bias(Ids.TAG_LABOR, 1.20, 540),
				]),
		],
	}))
