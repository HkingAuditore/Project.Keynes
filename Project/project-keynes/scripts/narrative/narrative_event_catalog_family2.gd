class_name NarrativeEventCatalogFamily2
extends RefCounted

## 家族桥包：十条读家族快照、改写家族特质的事件。
##
## 与 family 包的分工：
##   family  写「一家人的一件小事」，机制上是通用杠杆；
##   family2 写「本地最大族与官府的一次交易」，机制上真的读家族、真的改家族。
##
## 读：`primary_family_*`（人口占比、威望档、拥有建筑、名人）。
## 写：GRANT / REMOVE_FAMILY_TRAIT，走 queue_family_trait_mutation。
## 约束：特质只是家族身份/偏好，不是“加威望”；现金转移仍落在本地人数最多的那群人，
## 标签不写“这个族出钱/得钱”。无族时条件不成立，效果静默模拟。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const PACK_ID := &"family2"
const PREFIX := "evt.family2."

const CAST := [
	"本地大族", "宗族长老", "地方官署", "度支司", "族学", "族仓", "宗祠", "行会", "商船队", "门第联姻",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197


static func _grant(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.GRANT_FAMILY_TRAIT,
		"target_key": trait_key,
		"magnitude_q16": 65536,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」获特质「%s」，永久" % display_name,
	}


static func _remove(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.REMOVE_FAMILY_TRAIT,
		"target_key": trait_key,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」失去特质「%s」" % display_name,
	}


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "家族桥",
		"theme": "本地最大族与官府",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "10 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAMILY2_SCHOOL),
			String(Ids.EVT_FAMILY2_GRANARY),
			String(Ids.EVT_FAMILY2_FEUD),
			String(Ids.EVT_FAMILY2_LOAN),
			String(Ids.EVT_FAMILY2_OFFICE),
			String(Ids.EVT_FAMILY2_MIGRATION),
			String(Ids.EVT_FAMILY2_GUILD),
			String(Ids.EVT_FAMILY2_MARRIAGE),
			String(Ids.EVT_FAMILY2_RELIEF),
			String(Ids.EVT_FAMILY2_SEA),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 族学 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_SCHOOL),
		"title": "{settlement_name}·宗族义学",
		"body_text": "{settlement_name}的本地大族近期腾出宗祠偏厢筹办族学，延请宿儒专授经史与算学，优先培育本族子弟，优者再荐送出仕。宗族长老向地方官署呈文，希望获得官方资助或匾额嘉奖。反对派官吏私下警告，大族垄断教育渠道势必强化其在地方政坛的话语权，日后尾大不掉；支持者则认为，借民间资本兴办教化正是补足官学短板的良机。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan hall side room turned into a school, low desks, a failed scholar, account books and a paperweight",
		"tags": ["family", "school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"required_technologies": ["tech.writing"],
		"conditions": [
			{"op": Op.HAS_NOTABLE_FAMILY, "bool_value": true},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "这一族在这一带说话有分量",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "有祠堂也有空屋",
			},
		],
		"options": [
			Shared.option(
				"fund_the_school", "国库助资，共建族学",
				"官民合办文风大兴",
				"国库拨付专款补贴笔墨束脩，族学迅速满额开课。本地学术氛围显著提振，大族亦由此确立了崇文重教的声望，成为地方人才辈出的摇篮。",
				[
					_grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(12, 540),
					Shared.cash_out(4, 360),
				]),
			Shared.option(
				"let_them_run_it", "赐匾嘉勉，由其自办",
				"赐匾背书大族扩学",
				"官府未出分文，仅赐予嘉奖匾额以示认可。本地大族借此光耀门楣、自主扩建学舍，地方文教稳步增长，其在朝野间的政治影响力亦悄然上升。",
				[
					_grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(8, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"repair_the_granary", "驳回呈文，令修仓廪",
				"族学搁置士林失望",
				"官署以务实备荒为由驳回办校请求，勒令将款项转用于修缮粮仓。学舍重归冷清，本地教化发展受挫，大族与读书阶层对官府的疏离感随之加深。",
				[
					Shared.knowledge(-10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 族仓 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_GRANARY),
		"title": "{settlement_name}·族仓囤粮",
		"body_text": "今年收成本称丰稔，但{settlement_name}的本地大族将大批新谷悉数锁入族仓惜售，市面粮源骤紧。地方官署多次遣员交涉，宗族长老却以储备族内度荒之粮为由拒不开仓。随着街面买粮长队日渐焦躁，底层民众的怨气正迅速汇聚。若官府强行征购，恐引发豪强剧烈反弹；若放任其待价而沽，城中恐难逃动荡。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A clan granary with two locks on the door, a queue of townspeople with empty bowls, an official arguing with the clan",
		"tags": ["family", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.25},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 25,
				"multiplier_q16": MUL_125,
				"reason": "米价一高，仓里的粮就扎眼",
			},
			{
				"condition": {"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.35},
				"add_weight": 20,
				"reason": "这一族占了半城的人",
			},
		],
		"options": [
			Shared.option(
				"let_them_hold", "默许囤积，待市自调",
				"大族囤粮获利甚丰",
				"官署未加干预，本地大族凭借雄厚粮储牢牢掌控了货殖渠道，商业流通有所拓展。但田租与囤积压力反噬耕作积极性，城中暗流涌动。",
				[
					_grant("i001_agrarian", "重农"),
					Shared.agriculture(-10, 360),
					Shared.trade_capacity(8, 360),
				]),
			Shared.option(
				"buy_at_the_listed_price", "依官定折价强制征购",
				"强征族粮埋下宿怨",
				"地方官署强令族仓按官定标准交纳粮款，部分折价充入公库。城中粮荒虽暂告缓解，但大族将此视为公然掠夺，地方官民关系骤然紧绷。",
				[
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"ask_them_to_open", "国库贴补，劝其平粜",
				"官贴族仓平抑粮荒",
				"朝廷拨款给予补偿，劝服本地大族开仓设棚施济。街面恐慌迅速平息，口粮开销明显回落，大族亦因识大体而赢得朝廷与坊间的双重信赖。",
				[
					_grant("j017_loyal", "老实"),
					Shared.staple(-15, 360),
					Shared.cash_out(3, 360),
				]),
		],
	}))

	# ═══ 争产 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_FEUD),
		"title": "{settlement_name}·豪强争产",
		"body_text": "{settlement_name}的本地大族内部爆发严重分裂，长房与次房因核心宅基地与水源归属反目成仇，双方族众已发展至当街阻路、毁弃农具的地步。宗族长老深陷派系泥潭无力仲裁，遂联名呈请地方官署介入断案。幕僚指出，此族在本地产业盘根错节，官府若偏袒一方必令另一派反噬；若听之任之，内斗恐将波及全城秩序。",
		"image_key": "family.house",
		"ai_visual_prompt": "Two branches of a clan quarrelling in a courtyard, farm tools thrown into the street, a well bucket hanging",
		"tags": ["family", "law", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 1},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.20},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "人多的族，分家就是分城",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有宅有井，才争得起来",
			},
		],
		"options": [
			Shared.option(
				"judge_for_the_elder", "依宗法裁决，判归长房",
				"官断长房次房怨愤",
				"地方官署依嫡长旧制判产业归长房，并依律收取诉讼规费。宗祠门口贴出官榜后很快遭人毁损，失意的次房势力暗中积聚不满，地方隐患未除。",
				[
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"let_them_split_it", "责令析产，两房分治",
				"砌墙分治内耗不止",
				"官署裁定两房各分其半、自行划界。双方随即在宅院与水源处砌墙对峙，连带拖累了族下作坊与商铺的正常运转，街面摩擦此起彼伏。",
				[
					Shared.manufacturing(-10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"suppress_it", "严令禁斗，强压争议",
				"强压争端暗流涌动",
				"官府以扰乱治安罪名强行弹压两房械斗，迫使大族表面重归平静。经历此番敲打，该族行事愈发老辣审慎，但被强行掩盖的裂痕随时可能再度爆发。",
				[
					_grant("j016_shrewd", "精明"),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 借粮 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_LOAN),
		"title": "{settlement_name}·公私借贷",
		"body_text": "{settlement_name}的度支司近来财政吃紧，驻军饷银与市政开支皆告短缺，不得不向财力雄厚的本地大族寻求应急周转。宗族长老并未直接回绝，而是亮出充盈的族仓，提出须以明年盐课收益作抵，并按民间高息计账。财政官吏深知此举无异于饮鸩止渴，让大族进一步染指国家税源；但若不借此款，便只能加征赋税或大砍公共预算。",
		"image_key": "country.economy",
		"ai_visual_prompt": "An official borrowing from a clan, a granary door ajar, an account book with a blank last page",
		"tags": ["family", "fiscal"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "只有这种族拿得出这笔钱",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "度支房开始按月算账",
			},
		],
		"options": [
			Shared.option(
				"borrow_from_the_clan", "质押盐课，向族举债",
				"押税举债暂解燃眉",
				"借券画押后资金迅速到位，军饷如期发放。本地大族借此逆势扩张了金融势力，然而未来税源受制于豪强，坊间对官府债台高筑的忧虑日增。",
				[
					Shared.cash_in(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					_grant("i028_counter", "逆周期经营"),
				]),
			Shared.option(
				"levy_instead", "拒绝举债，按亩加征",
				"加征田赋民怨沸腾",
				"度支司拒绝向豪强低头，改向全城农商强行加征临时赋税。国库虽迅速充实，但苛重税负重创了农业生产，城门告示屡遭撕毁，社会动荡风险陡升。",
				[
					Shared.cash_in(5, 360),
					Shared.agriculture(-10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"cut_the_budget", "紧缩开支，削减公费",
				"紧缩财政拖累工坊",
				"地方官署大幅裁减行政与营造预算，压低官营工匠酬劳。此举避免了举债与加税，但订单骤减令本地制造业萎缩，工匠阶层的活力也随之下滑。",
				[
					Shared.manufacturing(-10, 360),
					Shared.bias(Ids.TAG_LABOR, 0.90, 360),
				]),
		],
	}))

	# ═══ 求官 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_OFFICE),
		"title": "{settlement_name}·门阀求仕",
		"body_text": "{settlement_name}地方官署新近空出一个要职，本地大族的宗族长老随即递来举荐文书，意在将本族年轻子弟安插其中。按制补缺本需严核资历与保荐，但该族在本地根深蒂固，已暗中打通多名保人关节。清流官吏力陈选官必循法度，绝不可开豪强私相授受之先例；务实派则提醒，若借此笼络大族，日后推行地方政令或可事半功倍。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan elder asking an official for a post, a roster open at a blank page, a brush hovering",
		"tags": ["family", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族大势大，缺一个名分",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
				"add_weight": 15,
				"reason": "城里有人替他说得上话",
			},
		],
		"options": [
			Shared.option(
				"give_him_the_post", "准予举荐，授以官职",
				"大族子弟跻身官场",
				"名册落笔成定局，本地大族正式跻身士绅官僚门第。政令推行虽得豪强配合，但裙带关系随即渗透营造与采购环节，公私营建成本亦水涨船高。",
				[
					_grant("j020_gentry", "士绅门第"),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"keep_the_exam", "严守考选，婉拒私荐",
				"婉拒私荐得罪豪强",
				"地方官署合上名册，坚持按既有考选制度公开补缺。官府守住了程序底线，但大族深感颜面受损，随即减少对本地文教的支持，暗中掣肘政令。",
				[
					Shared.knowledge(-10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"sell_the_post", "纳资捐官，价高者得",
				"鬻官筹款清议哗然",
				"空缺最终由出资更高的别家豪绅买下，国库由此进账一笔可观捐纳。然而买官者尸位素餐，不仅激怒了原有大族，更令坊间对吏治腐败怨声载道。",
				[
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 迁族 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_MIGRATION),
		"title": "{settlement_name}·大族外迁",
		"body_text": "因不满本地税负与生存空间受限，{settlement_name}人口占比颇重的本地大族正筹划举族外迁。宗族长老已在城外购置大片新地，族仓存粮陆续装车，准备带走半数族众与资本。地方官署急忙介入挽留，深知此族一旦撤离，全城人口、劳动力与税基将瞬间遭受重创；但若强行封禁房产交易，又恐激起激烈对抗。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan loading carts to leave a town, an elder on the last cart holding an ancestral tablet",
		"tags": ["family", "people", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.30},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.40},
				"add_weight": 25,
				"multiplier_q16": MUL_125,
				"reason": "走一半人，城就空一半",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "日子过不下去，才想着搬",
			},
		],
		"options": [
			Shared.option(
				"let_them_go", "准其迁徙，好聚好散",
				"大族外迁城池骤空",
				"官署未加阻拦，大批族众携家带口迁往城外拓荒。城内人口随之骤减，但腾出的耕地与城郊新辟农田相互呼应，留守居民的农业产出反倒有所提升。",
				[
					_grant("i025_pioneer", "拓荒者"),
					# 人真的跟着族走了：族占城中人口三到四成，走一半即全城减两成。
					# 这是守恒的人口迁出，不是「出生率下降」——改写 birth(-4) 是错位代理。
					Shared.population_rate(-20, "本地人口 -20%（李氏一族迁出）"),
					Shared.agriculture(10, 360),
				]),
			Shared.option(
				"forbid_the_sale", "禁售产业，强令留居",
				"强留不成反激逃亡",
				"官府强行冻结大族宅产交易，却仍未能阻挡半数族众悄然离城。被迫留下的族人虽继续维系部分作坊生产，但心怀怨恨，地方动荡暗潮汹涌。",
				[
					Shared.population_rate(-10, "本地人口 -10%（半数族人不告而去）"),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"give_them_land", "拨地补贴，诚意挽留",
				"拨地留族转危为安",
				"国库出资购置并划拨城郊荒地归大族开垦，宗族长老终于同意留驻本地。全城人口与税基得以保全，新垦农田也很快为本地带来丰厚产出。",
				[
					Shared.cash_out(4, 360),
					Shared.agriculture(12, 540),
				]),
		],
	}))

	# ═══ 族与行会 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_GUILD),
		"title": "{settlement_name}·宗族资本",
		"body_text": "{settlement_name}的本地大族近期注资入股数家核心手工作坊，并公然挂出宗族徽记，试图绕开传统行会规章自主定价招工。行会执事团对此反应强烈，携带百年名册赴地方官署抗议，指责大族资本破坏行业准入秩序、挤压独立匠人生存空间。工坊学徒与投资方则主张，唯有引入雄厚宗族资本方能扩大产能。官府必须在资本扩张与行会自治间作出裁决。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A workshop with a clan lantern, a guild steward slamming a roster on the desk, apprentices watching",
		"tags": ["family", "labor", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"required_technologies": ["tech.guild_organization"],
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "族里已经有铺面",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.12},
				"add_weight": 15,
				"reason": "匠户多，行会才管得着",
			},
		],
		"options": [
			Shared.option(
				"two_plaques", "准族入会，双牌并行",
				"资本与行会达成合流",
				"官署促成妥协，允许大族注资作坊同时悬挂族牌与行会匾额，并按章缴纳会费。资金与技艺的结合令本地制造业迅速扩张，工具供给也随之充裕。",
				[
					_grant("j004_craft", "工匠世家"),
					Shared.manufacturing(12, 540),
					Shared.tools(15, 540),
				]),
			Shared.option(
				"guild_rules", "维护行会，限制资本",
				"行会自治得以保全",
				"地方官署裁定作坊须摘除族徽、全归行会统管。传统匠人生产秩序得以稳定，但受挫的本地大族撤回投资，与行会及官府的隔阂进一步加深。",
				[
					Shared.manufacturing(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"break_the_lantern", "官府弹压，没收罚金",
				"强力整顿重创产能",
				"官署强行取缔私挂徽记并课以重罚，大族愤而退出手工业领域。此举虽为国库带来一笔罚没收入，却导致作坊停工、本地制造元气大伤。",
				[
					_remove("j004_craft", "工匠世家"),
					Shared.manufacturing(-10, 360),
					Shared.cash_in(3, 360),
				]),
		],
	}))

	# ═══ 联姻 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_MARRIAGE),
		"title": "{settlement_name}·门第联姻",
		"body_text": "{settlement_name}两大显赫的本地大族正紧锣密鼓地商议门第联姻，意图通过结亲整合城南大片商铺与田产。然而围绕商铺公产如何写入婚书，双方宗族长老寸步不让，谈判几度濒临破裂。地方官署密切关注此事：一旦两大豪强彻底合流，其雄厚财势恐成地方一霸；但若联姻告吹引发两族倾轧，同样会令本地商贸与社会秩序蒙受损失。",
		"image_key": "family.house",
		"ai_visual_prompt": "A marriage contract on a clan hall table with one blank line, a woman winding thread behind a curtain",
		"tags": ["family", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "两家都要脸面",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 18},
				"add_weight": 15,
				"reason": "城大了，联姻才有利可图",
			},
		],
		"options": [
			Shared.option(
				"sign_as_asked", "官府赐礼，促成联姻",
				"豪强合流门第大盛",
				"官府出资备办贺礼促成婚书签署，两大豪强正式结为政治与商业同盟。本地人口繁衍态势随之向好，但家大业大的新兴门阀也获得了前所未有的地方权势。",
				[
					_grant("i026_magnate", "家大业大"),
					Shared.birth(12, 540),
					Shared.cash_out(3, 360),
				]),
			Shared.option(
				"call_it_off", "暗中作梗，拆散联盟",
				"联姻告吹豪强分立",
				"地方官署借审查产契之名拖延作梗，两族最终不欢而散。豪强合流之患得以化解，朝廷在地方的制衡筹码增加，但两族交恶也波及了本地文教赞助。",
				[
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
					Shared.knowledge(-8, 360),
				]),
			Shared.option(
				"let_them_settle", "保持中立，听凭自决",
				"务实妥协合营商铺",
				"官署拒绝介入豪强家务，两族最终各退一步，以合资经营商铺取代彻底并产。城中婚育风气温和向好，但豪强联手控盘也令日常口粮开销略有抬升。",
				[
					Shared.staple(10, 360),
					Shared.birth(8, 540),
				]),
		],
	}))

	# ═══ 族赈 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_RELIEF),
		"title": "{settlement_name}·宗族义赈",
		"body_text": "{settlement_name}遭遇严峻断粮危机，市面恐慌蔓延之际，本地大族率先敞开族仓设棚施粮。然而灾民远超预期，不仅本族饥民涌至，大批外姓贫户亦排入长队，族仓余粮很快见底，再发便要动及来年种粮。宗族长老急向地方官署求助，官署则面临微妙的政治权衡：是借大族义举顺水推舟，还是由官仓亲自接手赈济以免民心尽归豪强。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan granary distributing grain, a half-empty measure overturned on a table, a mixed queue",
		"tags": ["family", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.40},
				"add_weight": 25,
				"multiplier_q16": MUL_125,
				"reason": "再不放粮就要出事",
			},
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "这一族仓里有底",
			},
		],
		"options": [
			Shared.option(
				"let_the_clan_feed", "准族续赈，官署立账",
				"宗族义赈化解危局",
				"官署以借贷名义核准大族倾囊赈济，并借机清算了部分陈欠公款。饥荒危机与主食压力迅速缓解，本地大族亦因深明大义而赢得忠诚美誉。",
				[
					_grant("j017_loyal", "老实"),
					Shared.staple(-15, 360),
					Shared.cash_in(4, 360),
				]),
			Shared.option(
				"open_the_state_granary", "开启官仓，朝廷亲赈",
				"官仓放粮重掌民心",
				"朝廷斥资开启官仓全面接管救济，粮价随即回落，饥民队伍秩序井然。官府不仅牢牢稳住了基层民心，更在救荒调度中积累了宝贵的政务经验。",
				[
					Shared.cash_out(5, 360),
					Shared.staple(-12, 360),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"let_them_endure", "暂不介入，令其自渡",
				"救济中断灾情恶化",
				"官府既不拨款亦不支持族赈，族仓被迫匆忙闭门。大批饥民陷入绝境，口粮短缺进一步加剧，整座城池在寒冬中弥漫着随时可能爆发的动荡气息。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.staple(12, 360),
				]),
		],
	}))

	# ═══ 族船 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_SEA),
		"title": "{settlement_name}·海贸特许",
		"body_text": "{settlement_name}的本地大族经营远洋贸易多年，其商船队近日满载南方香料与铜料凯旋入港。该族趁势向地方官署递交折子，恳请颁布正式的远洋特许凭状以扩建船队。度支司官吏指出，若放任民间豪强坐拥庞大商船队，恐难控走私与海防；但一味实行海禁，又会白白断绝丰厚的关税来源与海外稀缺物资。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A clan trading fleet back in harbour, patched hulls, spices and copper in the hold, a tax clerk on the pier",
		"tags": ["family", "sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 7,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "这种族才养得起船队",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 15,
				"reason": "港口的货有人接",
			},
		],
		"options": [
			Shared.gamble(
				"charter_the_fleet", "颁布特许，按舱抽税",
				Shared.branch(39322, "海贸大兴关税丰盈", # 60%
					"特许凭状落地，本地大族迅速扩充商船队，成长为雄踞一方的沿海资本。港口贸易容量大幅跃升，按舱征收的关税亦源源不断充实国库。",
					[
						_grant("i029_coastal", "沿海资本"),
						Shared.trade_capacity(12, 540),
						Shared.cash_in(3, 360),
					]),
				Shared.branch(26214, "船队遇险海贸受挫", # 40%
					"扩编后的船队在远洋遭遇飓风沉没多艘，大族血本无归。朝廷被迫出资善后，本地造船与相关制造业蒙受打击，港口人心浮躁不安。",
					[
						Shared.manufacturing(-10, 360),
						Shared.cash_out(4, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"state_fleet", "收归官营，由族承运",
				"官营船队扬帆远航",
				"国库斥巨资接管船队并改悬官旗，雇佣原班海员承运官货。此举虽耗费不菲，却在确保朝廷掌控海权的同时，有效拉动了本地造船制造与贸易运力。",
				[
					Shared.cash_out(6, 360),
					Shared.trade_capacity(10, 540),
					Shared.manufacturing(10, 540),
				]),
			Shared.option(
				"close_the_sea", "严申海禁，封存船只",
				"海禁封港百业萧条",
				"官署下令封存所有远洋商船，水手与船匠被迫四散谋生。港口彻底沉寂，本地造船与关联手工业随之萎缩，沿海商民对海禁令怨声载道。",
				[
					Shared.manufacturing(-10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))
