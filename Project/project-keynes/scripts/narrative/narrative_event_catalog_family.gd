class_name NarrativeEventCatalogFamily
extends RefCounted

## 人与家：四件小事（微观，全部孤立，但彼此有回声）。
##
##   次子（era 1–6）→ 分家 / 抽丁（抽丁会排程"回家的兵"）
##   聘礼（era 1–7）→ 读"坡地新户 / 分家未决"两个标记，聘礼的价码随家产状态浮动
##   父债（era 2–9）→ 旧债未销会自己回头，债主下次来得更硬
##   回家的兵（era 2–9）→ 也会由边镇包的"城下的兵"收场时排程
##
## 这一包不写国家大事：幅度 3–4%，钱 1.0–1.5%，代价落在"多一双筷子、少一个劳力、门口多一句闲话"。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"family"
const PREFIX := "evt.family."

const CAST := [
	"宗族长老", "地方官署", "田产契约", "兵役名簿", "地方钱庄", "户籍册", "世族联姻", "伤残老兵",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "人与家",
		"theme": "分家、婚事、债与回来的人",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "4 条微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAMILY_SECOND_SON),
			String(Ids.EVT_FAMILY_BRIDE_PRICE),
			String(Ids.EVT_FAMILY_FATHERS_DEBT),
			String(Ids.EVT_FAMILY_RETURNING_SOLDIER),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 次子 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_SECOND_SON),
		"title": "{settlement_name}·析产继承",
		"body_text": "{settlement_name}人丁渐繁，可耕良田日趋紧张，围绕土地继承法的争端频频呈报至地方官署。宗族长老援引旧俗，坚持熟田归长房完整继承以防家业细碎化；大批无田可承的次子与旁支则要求依律析产，或获准开垦周边荒坡另立户籍册。官署官员亦提出第三条出路，建议将多余青壮征入行伍以解地少人多之困。如何裁定这份田产契约，将直接左右本地农产与兵源。",
		"image_key": "family.house",
		"ai_visual_prompt": "A family division deed spread on a millstone, a younger son with a cloth bundle at the threshold, an elder folding the land deed",
		"tags": ["people", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.40},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "地少人多，次子最先被挤出去",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "日子紧，分家提得早",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "村里有了空屋，分出去才有地方住",
			},
		],
		"options": [
			Shared.option(
				"give_him_the_slope", "准予析产，拨荒立户",
				"新户垦荒扩充田亩",
				"地方官署核准旁支分户，将城外荒坡拨归新户开垦。新增耕地提升了本地农业产出，但分家另灶短期内也推高了全城基本口粮消耗。",
				[
					Shared.agriculture(12, 540),
					Shared.staple(12, 360),
					Shared.flag(Ids.FLAG_SECOND_SON_SPLIT, 900, "标记「坡地新户」"),
				]),
			Shared.option(
				"send_him_to_the_camp", "编入行伍，以解田荒",
				"次子从军田产归一",
				"多余青壮被征调入伍吃粮，原有农田得以完整保留于长房名下。本地农忙劳力短期内有所流失，而这批远赴边关的士卒终有一日将带着战伤归乡。",
				[
					Shared.agriculture(-10, 360),
					Shared.schedule(Ids.EVT_FAMILY_RETURNING_SOLDIER, 210, "回家的兵"),
				]),
			Shared.option(
				"wait_until_autumn", "暂缓析产，维持合户",
				"分家搁置积怨暗生",
				"官署将析产呈文压下不议，强令宗族暂维合灶共耕。虽在短期内稳住了规模耕作，但同室操戈的裂痕与生计摩擦正迫使更多家族矛盾浮出水面。",
				[
					Shared.agriculture(10, 270),
					Shared.staple(10, 360),
					Shared.flag(Ids.FLAG_SECOND_SON_PENDING, 540, "标记「分家未决」"),
					Shared.bias(Ids.TAG_PEOPLE, 1.20, 540),
				]),
		],
	}))

	# ═══ 聘礼 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_BRIDE_PRICE),
		"title": "{settlement_name}·世族联姻",
		"body_text": "{settlement_name}两大有产之家的世族联姻陷入僵局，成为全城议论的焦点。女方宗族长老坚持将大片水田写入田产契约作为聘礼底线，男方则主张以边坡荒地折抵并代偿旧债。此类以重产议婚之风近来愈演愈烈，已令不少中小户无力成家。地方官署面临两难：是介入核准契约以稳住大族颜面，鼓励折中换产，还是暂缓公证以观后效。",
		"image_key": "family.house",
		"ai_visual_prompt": "A betrothal negotiation with cloth, wine and a deed on two tables, a matchmaker at the threshold, a daughter winding thread inside",
		"tags": ["people", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有人抬价，聘礼就浮起来",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "越穷越要在聘礼上找补",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SECOND_SON_SPLIT)},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "新户多了，聘礼要得更硬",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SECOND_SON_PENDING)},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "家产没分，亲家不敢定",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_BRIDE_PENDING)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "去年没谈成，今年还得谈",
			},
		],
		"options": [
			Shared.option(
				"sign_the_deed", "核准重聘，官署印契",
				"重聘成婚契税入库",
				"地方官署为这份高额田产契约加盖官印并征收契税，两族终成秦晋之好，带动了本地婚育风气。但水田割裂重组短期内打乱了原有耕作安排。",
				[
					Shared.agriculture(-10, 360),
					Shared.birth(12, 540),
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（婚书立契，官账抽一份）"),
				]),
			Shared.gamble(
				"swap_slope_for_debt", "折中调解，以坡抵债",
				Shared.branch(39322, "折中立契联姻告成", # 60%
					"在官署斡旋与贴补下，双方同意以坡地与清债折抵聘礼。荒坡随之得以开垦增产，但勉强达成的妥协仍令两族心存芥蒂。",
					[
						Shared.agriculture(10, 540),
						Shared.cash_out(3, 360),
						Shared.bias(Ids.TAG_UNREST, 1.10, 540),
					]),
				Shared.branch(26214, "议婚破裂两族交恶", # 40%
					"女方长老愤然回绝折中方案，婚事彻底告吹。大族间由此结怨，高攀无门的僵局也令本地婚嫁意愿随之低迷。",
					[
						Shared.birth(-10, 540),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					])),
			Shared.option(
				"wait_a_year", "搁置印契，延后再议",
				"婚契悬置议论纷起",
				"官署暂缓公证婚书，两族礼聘无果而终。受高额聘礼风气拖累，本地适龄男女成婚推迟，围绕家产与婚配的民间纠纷仍将反复浮现。",
				[
					Shared.birth(-10, 540),
					Shared.flag(Ids.FLAG_BRIDE_PENDING, 540, "标记「婚书未立」"),
					Shared.bias(Ids.TAG_PEOPLE, 1.20, 540),
				]),
		],
	}))

	# ═══ 父债 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_FATHERS_DEBT),
		"title": "{settlement_name}·高利借贷",
		"body_text": "{settlement_name}近来频发债主追索陈年父债的纠纷，地方钱庄持旧日田产契约与借据登门，要求新丧家主的农户变卖耕畜与坡地抵债。宗族长老痛陈，若任由钱庄强收生产资料，破产农户势必沦为流民；钱庄东家却向地方官署施压，警告一旦官府庇护赖账之风，民间信贷将彻底冻结，来年春耕无人敢再赊借种子。法理与生计的冲突已摆上案头。",
		"image_key": "family.house",
		"ai_visual_prompt": "A moneylender pressing a worn promissory note on a stone table with an open seal-ink box, a donkey in the yard",
		"tags": ["people", "fiscal", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 600,
		"min_era_index": 2,
		"max_era_index": 9,
		"required_technologies": ["tech.currency"],
		"conditions": [
			{"op": Op.SATISFACTION_LTE, "float_value": 0.45},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "还不上，才来讨",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_DEBT_PENDING)},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "旧债没销，债主下次来得更硬",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有几间铺子，才有人拿得出字据",
			},
		],
		"options": [
			Shared.option(
				"sell_and_settle", "依契清偿，变产抵债",
				"严守债契农户失畜",
				"地方官署裁定依约执行，欠户变卖耕畜与坡地结清宿债，官账亦按律抽取过户规费。商业信用得以维系，但失去农具与牲畜的农户产出随之下滑。",
				[
					Shared.agriculture(-10, 360),
					Shared.cash_in(4, 360, "向本地人数最多的{primary_profession}征收其现金的 4%（债款过官账代还）"),
				]),
			Shared.option(
				"acknowledge_and_repay", "官署作保，分季缓还",
				"分期偿债保住耕作",
				"官署居中订立分季偿还协议，保住了欠户的耕畜与农田，令其得以全力投入生产。然而秋收粮谷多半用于抵债，基层家庭的日常口粮顿时捉襟见肘。",
				[
					Shared.agriculture(12, 540),
					Shared.staple(12, 360),
				]),
			Shared.option(
				"put_it_under_the_rice_jar", "暂压债案，不予受理",
				"债案悬置信贷收紧",
				"官署将追债诉状束之高阁，欠户暂时保住了家产。但地方钱庄随即收紧春耕赊贷，周边农户因缺种少本致使耕地撂荒，宿债隐患日后恐将变本加厉。",
				[
					Shared.agriculture(-10, 360),
					Shared.flag(Ids.FLAG_DEBT_PENDING, 540, "标记「债字未销」"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 回家的兵 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY_RETURNING_SOLDIER),
		"title": "{settlement_name}·伤兵安置",
		"body_text": "一名在边关失去左臂的伤残老兵历经长途跋涉返回{settlement_name}，其旧宅已易主，亲族亦因生计艰难无力长期供养。地方官署翻查兵役名簿后回报，按现行规制申领国库抚恤不仅手续繁复，且须层层具保核验。宗族长老暗中担忧，若对浴血归乡的兵卒置之不理，日后朝廷再度征兵恐难服众；但若全面兜底抚恤，地方财政又将承受持续压力。",
		"image_key": "family.house",
		"ai_visual_prompt": "A one-armed soldier returning to a village door, a bundle on the threshold, a village clerk holding a register",
		"tags": ["people", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "回来的人先找不到活",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 25,
				"reason": "家里本来就挤",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有活可干，人才留得住",
			},
		],
		"options": [
			Shared.option(
				"clear_the_west_room", "责成宗族，授艺安置",
				"归乡伤兵习艺谋生",
				"官署责成原籍宗族腾出居所并安排轻省手艺，伤残老兵得以自食其力，本地手工业略有增益。但平添赡养负担仍让本就紧巴的家庭口粮愈发吃紧。",
				[
					Shared.manufacturing(10, 540),
					Shared.staple(12, 360),
				]),
			Shared.option(
				"report_for_a_stipend", "核准名簿，拨发抚恤",
				"抚恤落地安抚军心",
				"地方官署迅速核验兵役名簿，由国库拨付定额伤残抚恤金。此举虽增加了财政支出，却在民间树立了优待功臣的典范，令宗族与军属大感宽慰。",
				[
					Shared.cash_out(3, 360),
					Shared.bias(Ids.TAG_PEOPLE, 1.15, 540),
				]),
			Shared.option(
				"sleep_in_the_woodshed", "暂予栖身，抚恤待议",
				"冷遇功臣寒彻民心",
				"官署仅草草安排了简陋栖身之所，将抚恤事宜无限期搁置。伤残老兵流落乡里凄凉度日，坊间对此议论纷纷，民众对兵役与官府的怨怼暗自滋长。",
				[
					Shared.staple(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))
