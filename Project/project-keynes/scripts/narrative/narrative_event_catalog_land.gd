class_name NarrativeEventCatalogLand
extends RefCounted

## 地块包：一块地的前途，和地上的人（4 条，全部孤立）。
##
##   淤了的港（沿海+河，era 2–8）· 老矿（有矿产，era 2–8）
##   林边（森林，era 1–8）· 废祠（era 1–9；也会被宫廷「两方印·发兵」排程）
##
## 连线：废祠的两个结果（旧祠重立 / 墙还塌着）会改写教门「抬神出城」的权重；
## 老矿塌过一回、封过坑，都会在下一回被自己的标记挡住或抬高。
##
## 数值：地块事件的代价落在部门产出与市场实物上；没有"负向全国贸易容量"这种键，
## 所以港口衰败写成本地制造 `.cut` + 主食开销上升，不写全国贸易负数。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"land"
const PREFIX := "evt.land."

const CAST := [
	"地方官署", "商旅团体", "工匠行会", "采掘矿场", "林政界线",
	"河口航道", "乡绅长老", "地方公产", "税赋册籍", "营建署",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474
const MUL_140 := 91750


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "地块",
		"theme": "港、矿、林、废祠",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "2 中观 + 2 微观，全部孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_LAND_SILTED_HARBOR),
			String(Ids.EVT_LAND_OLD_MINE),
			String(Ids.EVT_LAND_FOREST_EDGE),
			String(Ids.EVT_LAND_RUINED_SHRINE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 淤了的港 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_SILTED_HARBOR),
		"title": "{settlement_name}·淤了的港",
		"body_text": "连年泥沙淤积令{settlement_name}的河口航道日益浅窄，大型货船被迫滞留外海，全靠小驳船反复倒运入港，转运损耗不断攀升。商旅团体向地方官署递呈，请求立刻征集资金雇佣清淤船彻底疏浚；营建署则提出将码头整体迁往下游深水滩地，虽可一劳永逸却势必侵占沿岸农田并令老港劳工生计断绝。也有官员主张暂缓大兴土木，寄望来年汛期洪水自行冲开新槽。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A silted river harbour with a rotting pier, a merchant measuring water depth against a notched stake, porters waiting",
		"tags": ["land", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 8},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "码头上还有活",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"reason": "船一停，货就压在岸上",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.10},
				"add_weight": 20,
				"reason": "盐要过三遍手，价就上去了",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SILT_WAITING)},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "泥封了一年，船更进不来",
			},
		],
		"options": [
			Shared.option(
				"dredge_the_bar", "摊派疏浚，清淤通航",
				"航道疏浚商船复通",
				"地方官署按货摊派筹措经费，清淤船昼夜作业数十日终将河口挖通。大船重新直抵码头，本地制造与对外运力迅速恢复。",
				[
					Shared.manufacturing(15, 360),
					Shared.trade_capacity(15, 360),
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（疏浚摊派，按货抽一份）"),
				]),
			Shared.option(
				"move_downstream", "迁港下游，重筑码头",
				"新埠落成老港凋敝",
				"新码头在下游深水滩地打桩建成，带动了周边工坊扩张。然而工程占去沿岸良田，老港搬运工群体失计，地方怨气随之滋长。",
				[
					Shared.manufacturing(18, 540),
					Shared.agriculture(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.gamble(
				"wait_for_the_flood", "暂缓动工，待汛冲槽",
				Shared.branch(39322, "夏汛冲淤航道自开", # 60%
					"盛夏一场大水恰将河口泥沙冲出深槽，商船得以复航，工坊随之回暖。唯地方商民对官署听天由命的治理姿态仍颇感不满。",
					[
						Shared.trade_capacity(10, 360),
						Shared.manufacturing(10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.15, 360),
					]),
				Shared.branch(26214, "枯水淤塞港口瘫痪", # 40%
					"当年河水未涨，入冬后连浅水驳船也难以进港，货品全赖人力背负过滩。港口制造大受拖累，城中主食补给开销随之攀升。",
					[
						Shared.manufacturing(-12, 540),
						Shared.staple(15, 540),
						Shared.flag(Ids.FLAG_SILT_WAITING, 900, "标记「泥封港口」"),
					])),
		],
	}))

	# ═══ 老矿 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_OLD_MINE),
		"title": "{settlement_name}·老矿",
		"body_text": "{settlement_name}的采掘矿场浅层矿脉日渐枯竭，每日出矿量已不及往年之半，且井下渗水日益严重。工匠行会勘察后呈报，若向下继续深掘，必须更换排水器具并加装重型支护，须向地方筹措一笔摊派；亦有矿工提议冒险改掘斜巷寻找偏转富脉。营建署则建议干脆封井止损，将井口完好的梁木与设施拆作城建公产，但矿区数十户人家的生计将就此断绝。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A tired mine head with two carts of ore, a miner whittling a wet wooden prop, a weigher shifting the scale weight",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"required_technologies": ["tech.copper_mine_engineering"],
		"blocked_story_flags": [String(Ids.FLAG_MINE_SEALED)],
		"conditions": [
			{"op": Op.HAS_NATURAL_RESOURCE, "int_value": 1},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 25,
				"reason": "还开着井",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 15,
				"reason": "矿上买得起抽水机",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_MINE_COLLAPSE)},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "塌过一回，井口更急着重开",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "靠这两趟车吃饭的人多",
			},
		],
		"options": [
			Shared.option(
				"dig_ten_more_fathoms", "筹资添械，继续深掘",
				"排水奏效矿产回升",
				"地方摊派筹款购置了新式排水器具与支护木料，矿井产量稳步回升。尽管额外征费引发些许怨言，矿区生计总算得以维系。",
				[
					Shared.extraction(18, 540),
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（换斗与撑架的摊派）"),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.gamble(
				"follow_the_vein", "冒险斜掘，探寻富脉",
				Shared.branch(36045, "斜巷贯通得遇富矿", # 55%
					"矿队冒险斜掘数日后撞上成色极佳的厚矿脉，本地及全国采掘均获提振，并留存了珍贵矿样。唯井下惊险仍令矿工群体心有余悸。",
					[
						Shared.extraction(24, 540),
						Shared.country_sector("extractive", 10, 360),
						Shared.research_signal("resource.iron_ore", "铁帽石"),
						Shared.bias(Ids.TAG_UNREST, 1.10, 360),
					]),
				Shared.branch(29491, "斜巷塌方矿井停摆", # 45%
					"斜巷支护未能承压，塌方砸毁矿车并造成人员遇难。矿场被迫停工整顿，采掘产出大跌，矿区上下对冒险政令愤慨不已。",
					[
						Shared.extraction(-12, 540),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
						Shared.flag(Ids.FLAG_MINE_COLLAPSE, 900, "标记「井下塌方」"),
					])),
			Shared.option(
				"seal_the_pit", "下令封井，拆料变现",
				"矿井封死众户失计",
				"官署下令封死井口，将拆除的支护梁木转作他用。采掘彻底停摆且工料周转反受牵连，失业的矿户群体令地方动荡风险骤增。",
				[
					Shared.extraction(-18, 540),
					Shared.build_cost(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.40, 540),
					Shared.flag(Ids.FLAG_MINE_SEALED, 1825, "标记「井口封死」"),
				]),
		],
	}))

	# ═══ 林边 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_FOREST_EDGE),
		"title": "{settlement_name}·林边",
		"body_text": "{settlement_name}外围林区因过度烧炭与开荒不断退缩，原有林政界线早已名存实亡。工匠行会与烧炭作坊要求放宽采伐以供燃料，无地农户则磨刀霍霍欲沿林缘扩垦耕地，而依赖山林狩猎采集的乡绅长老则警告毁林将招致水土流失。地方官署面临重新核定税赋册籍与林地边界的棘手抉择，各方代表均在官署外静候裁断。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A forest edge retreating up a slope, a charcoal kiln, a hunter with snares, a farmer with a polished ploughshare",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 600,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.VEGETATION_IN, "int_list": [
				VegetationTypeScript.VEG.TAIGA,
				VegetationTypeScript.VEG.TEMPERATE_DECIDUOUS,
				VegetationTypeScript.VEG.TEMPERATE_CONIFER,
				VegetationTypeScript.VEG.SUBTROPICAL_FOREST,
				VegetationTypeScript.VEG.TROPICAL_RAINFOREST,
				VegetationTypeScript.VEG.TROPICAL_DRY_FOREST,
				VegetationTypeScript.VEG.MANGROVE,
				VegetationTypeScript.VEG.CLOUD_FOREST,
				VegetationTypeScript.VEG.MONSOON_FOREST]},
			{"op": Op.POPULATION_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "窑还烧着",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 10},
				"add_weight": 15,
				"reason": "人多了，就要地",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "forestry_worker", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "靠林子吃饭的人就在村里",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_FOREST_CLOSED)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "封过一回，边上的人还盯着那条线",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_FOREST_PENDING)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "林界没定，明年还得议",
			},
		],
		"options": [
			Shared.option(
				"close_the_slope", "划界封林，严禁越垦",
				"山林得保怨气渐起",
				"地方官署强制封禁山坡林缘，水土得以涵养，坡下农田收成随之稳步提升。然伐木工与扩垦农户断了近利，对禁令颇多抵触。",
				[
					Shared.agriculture(15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.flag(Ids.FLAG_FOREST_CLOSED, 900, "标记「坡上封林」"),
				]),
			Shared.option(
				"cut_and_mark_the_line", "放宽采伐，供应炭窑",
				"炭产大增农田遭殃",
				"炭窑扩产为本地工坊提供了充足燃料，制造产出随之走高。但山坡失林导致春汛泥沙冲入低田，农事受损且主食供给显著承压。",
				[
					Shared.manufacturing(12, 540),
					Shared.agriculture(-12, 540),
					Shared.staple(18, 540),
				]),
			Shared.option(
				"report_and_wait", "沿用旧籍，暂缓定界",
				"林界悬而未决",
				"官署照抄往年旧数敷衍上报，未划定明确界线。各方趁机各自侵占，林缘加速退化，周边农田产出也因生态失衡渐次滑坡。",
				[
					Shared.flag(Ids.FLAG_FOREST_PENDING, 900, "标记「林界未定」"),
					Shared.bias(Ids.TAG_LAND, 1.20, 540),
					Shared.agriculture(-10, 540),
				]),
		],
	}))

	# ═══ 废祠 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_RUINED_SHRINE),
		"title": "{settlement_name}·废祠",
		"body_text": "{settlement_name}城郊一座年久失修的古旧宗祠后墙坍塌，危及过往行人。营建署勘查后指出，祠中留存的大批规整条石质地精良，若拆作地方公产可用于兴建新粮仓，能省下可观工料。然而地方乡绅长老与守祠信众强烈反对拆毁圣迹，恳请地方官署拨款照原样修缮，以维系一方教化与人心稳定；也有幕僚主张暂且围蔽封存，免得两头得罪。",
		"image_key": "family.house",
		"ai_visual_prompt": "A half-collapsed shrine with a stone lion, broken clay figures, a mason testing a carved stone block with his knuckles",
		"tags": ["land", "unrest", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 12},
				"add_weight": 15,
				"reason": "人多，路过的也多",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "塌了的东西更容易被看见",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 10,
				"reason": "有工地，条石就有人要",
			},
		],
		"options": [
			Shared.option(
				"take_the_stone", "拆取条石，改建公仓",
				"拆祠建仓务实招怨",
				"旧祠条石悉数拆运砌入新仓，城中储粮条件改善、主食开销显著下降，工坊亦得余料之利。唯传统乡绅与信众深感冒犯，民间怨言四起。",
				[
					Shared.staple(-18, 540),
					Shared.manufacturing(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"rebuild_it", "拨款修缮，重立旧祠",
				"旧祠重光人心安靖",
				"国库拨出专款按原制修复坍墙，落成之日地方乡绅与民众齐聚致谢。虽耗费一笔公帑，却有效安抚了地方情绪，稳固了基层秩序。",
				[
					Shared.cash_out(5, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.flag(Ids.FLAG_SHRINE_KEPT, 900, "标记「旧祠重立」"),
				]),
			Shared.option(
				"fence_it_off", "立栏围蔽，暂且搁置",
				"废墟倾颓争议犹存",
				"官署仅派人围起木栏并挂牌禁入，既未修缮亦未拆用。入冬几场豪雨后剩余墙垣彻底倾塌，留下满地瓦砾与地方持久的不满。",
				[
					Shared.flag(Ids.FLAG_SHRINE_WAITING, 900, "标记「墙还塌着」"),
					Shared.bias(Ids.TAG_LAND, 1.20, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
