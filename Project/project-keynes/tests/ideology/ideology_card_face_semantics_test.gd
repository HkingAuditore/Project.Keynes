extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const BANNED_TERMS := [
	"每源", "上限", "×", ">=", "<=", "R1", "R2", "metric", "selector",
	"ramp", "factor", "cut", "bp", "Q16", "+0%", "-0%", "≥", "≤",
]
const SIGNED_PERCENT_PATTERN := "[+\\-][0-9]+(?:\\.[0-9]+)?%"
const RAW_RESOURCE_ID_PATTERN := "(?<![a-z0-9_])(?:phosphate_rock|fertile_soil|copper_ore|tin_ore|coal|oil|timber|salt|wild_game|jewelry|fine_clothing|beverages|flint)(?![a-z0-9_])"
const CARD_FACE_FORBIDDEN_IDS := [
	"rice_grain", "wheat_grain", "dryland_crop", "paddy_crop", "fertilizer",
]
const MECHANICAL_PHRASES := [
	"每档", "实测净税负", "相关建筑成链", "职业占比", "工人阶层民意",
	"每个来源", "失业率每点", "每个矿业支柱地块使", "每个主产白银地块使",
	"=提高", "= +",
]
const OBSOLETE_OR_OPAQUE_PHRASES := [
	"每有 1 个来源", "每个来源", "最多计算",
	"国库现金每相当于", "民意对理念点获取的加成保底", "时农业提高",
	"：工业降低", "支柱地块", "繁市", "大邑", "多元地块",
	"非多元", "专精的粮作", "的地块的地块", "全社会", "资源再生",
	"管护再生", "同一产业链", "相邻地块", "家族聚落", "装备时",
	"全国一年收入的 1%", "全国各类生产投入", "全国家庭消费需求",
	"国内贸易容量", "贸易速度", "制造部门产出", "知识部门产出",
	"农业部门产出", "采掘部门产出", "能源部门产出",
	"社会领域研究效率", "科学领域研究效率", "工程领域研究效率",
	"农业领域研究效率",
]
const OLD_MISMATCH_TERMS := [
	"知识占比", "知识建筑", "非工业支柱地块", "通衢地块周围 1 格（",
	"海岸繁市地块周围", "工业建筑 ≥2 座", "宗族数", "产出 -0%",
	"贸易 +3%", "家产建筑", "诊断：", " 3 源 = ", "= +",
	"建造成本",
]
const RAW_ID_PATTERN := "[a-z][a-z0-9_]*\\.[a-z][a-z0-9_.]*"

var _checks := 0
var _failures := 0


func _init() -> void:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles", bool(economy_ir.get("ok", false))):
		_finish()
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if not _require("default ideology catalog loads", catalog != null):
		_finish()
		return
	var view: Dictionary = catalog.catalog_view(economy_ir, economy_ir)
	if not _require("catalog view compiles", bool(view.get("ok", false)),
			String(view.get("reason", ""))):
		_finish()
		return
	var rows: Array = view.get("ideologies", [])
	_expect("card-face traversal covers all 113 published cards", rows.size() == 113)
	var by_id := {}
	var all_lines := PackedStringArray()
	var details := PackedStringArray()
	var level_count := 0
	var missing_school_name_count := 0
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := String(row.get("id", ""))
		by_id[card_id] = row
		details.append(String(row.get("detail_key", "")))
		if String(row.get("school_name", "")).strip_edges().is_empty():
			missing_school_name_count += 1
		var levels: Array = row.get("level_effect_lines", [])
		_expect("%s exposes three levels" % card_id, levels.size() == 3)
		for level_index in levels.size():
			level_count += 1
			var lines: PackedStringArray = levels[level_index]
			_expect("%s L%d has 1-6 lines" % [card_id, level_index + 1],
				lines.size() >= 1 and lines.size() <= 6)
			for line in lines:
				all_lines.append(line)
				_expect("%s L%d has no blank line" % [card_id, level_index + 1],
					not String(line).strip_edges().is_empty())
	_expect("card-face traversal covers 339 levels", level_count == 339)
	_expect("every exported card has a readable school heading",
		missing_school_name_count == 0)
	var joined := "\n".join(all_lines)
	for term in BANNED_TERMS:
		_expect("banned term absent: %s" % term, not joined.contains(String(term)))
	for term in OLD_MISMATCH_TERMS:
		_expect("old mismatch phrase absent: %s" % term, not joined.contains(String(term)))
	for raw_id in CARD_FACE_FORBIDDEN_IDS:
		_expect("raw card-face ID absent: %s" % raw_id,
			not joined.contains(String(raw_id)))
	for phrase in MECHANICAL_PHRASES:
		_expect("mechanical phrase absent: %s" % phrase,
			not joined.contains(String(phrase)))
	for phrase in OBSOLETE_OR_OPAQUE_PHRASES:
		_expect("obsolete or opaque phrase absent: %s" % phrase,
			not joined.contains(String(phrase)))
	var id_regex := RegEx.new()
	_expect("raw stable-id regex compiles", id_regex.compile(RAW_ID_PATTERN) == OK)
	_expect("raw stable IDs absent from card faces",
		id_regex.search(joined) == null)
	_expect("duplicate colons absent from card faces",
		not joined.contains("：：") and not joined.contains("::"))
	var signed_percent_regex := RegEx.new()
	_expect("signed-percent regex compiles",
		signed_percent_regex.compile(SIGNED_PERCENT_PATTERN) == OK)
	_expect("signed percentages are rewritten",
		signed_percent_regex.search(joined) == null)
	var resource_id_regex := RegEx.new()
	_expect("raw resource-id regex compiles",
		resource_id_regex.compile(RAW_RESOURCE_ID_PATTERN) == OK)
	_expect("raw resource IDs absent from card faces",
		resource_id_regex.search(joined) == null)
	_expect("research-signal draw gates are rendered by display name",
		(by_id["idea.semiconductor"].get("required_research_signal_names",
			PackedStringArray()) as PackedStringArray).has("硅砂"))

	_expect_contains(by_id, "idea.kin_hearth", 0, "居住维护消费需求提高 5%")
	_expect_contains(by_id, "idea.public_hygiene", 0, "居住维护消费需求降低 8%")
	_expect_contains(by_id, "idea.kin_hearth", 0, "至少有 1 个家族分支")
	_expect_contains(by_id, "idea.kin_hearth", 2, "威望不低于 50%")
	_expect_contains(by_id, "idea.civil_examination", 2,
		"首次达到化育等级时：免费获得 1 次理念抽取。该奖励只能领取一次。")
	_expect_contains(by_id, "idea.experimental_method", 0, "知识业产出占当地总产出至少 50%")
	_expect_contains(by_id, "idea.experimental_method", 0, "制造业产出提高 6%")
	_expect_contains(by_id, "idea.experimental_method", 0, "制造业产出最高提高 18%")
	_expect_contains(by_id, "idea.agricultural_chemistry", 0, "主产肥料")
	_expect_contains(by_id, "idea.agricultural_chemistry", 0, "农业产出最高提高 24%")
	_expect_contains(by_id, "idea.telegraph", 0, "知识产出提高 6%")
	_expect_contains(by_id, "idea.telegraph", 2, "周围 3 格")
	_expect_contains(by_id, "idea.container_port", 0, "本国海岸的地块")
	_expect_contains(by_id, "idea.container_port", 0, "制造业产出最高提高 30%")
	_expect_contains(by_id, "idea.carbon_market", 0, "至少有 3 个经济部门有产出")
	_expect_contains(by_id, "idea.autonomous_logistics", 0, "多个来源不叠加")
	_expect_contains(by_id, "idea.autonomous_logistics", 0, "改为周围 2 格")
	_expect_contains(by_id, "idea.autonomous_logistics", 0, "按来源数量累计的效果不变")
	_expect_contains(by_id, "idea.frontier_garrison", 2, "人口少于 120 人")
	_expect_contains(by_id, "idea.frontier_garrison", 2, "置于理念槽时")
	_expect_contains(by_id, "idea.fire_keeping", 0, "本国冻原的地块")
	_expect_contains(by_id, "idea.manufactory_regulation", 0, "当地每有 1 座制造业建筑")
	_expect_contains(by_id, "idea.marriage_alliance", 0, "当地家族分支至少 2 个")
	_expect_contains(by_id, "idea.family_office", 2, "研究成本降低 0.5%，最高降低 12%")
	_expect_contains(by_id, "idea.family_office", 2, "其名下建筑的全部产出提高 6%")
	_expect_contains(by_id, "idea.family_office", 2, "最多影响 32 个家族")
	_expect_contains(by_id, "idea.colonial_plantation", 2, "农业产出提高 28%")
	_expect_contains(by_id, "idea.social_media", 0, "理念点获取的民意加成下限降低 10 个百分点")
	_expect_contains(by_id, "idea.excise", 2, "全国建设成本降低 0.5%，最高降低 4%")
	_expect_contains(by_id, "idea.treasury_reserve", 0, "全国建设成本降低 1%，最高降低 5%")
	_expect_contains(by_id, "idea.treasury_reserve", 0, "国库现金 ÷ 全国人口一年收入总额")
	_expect_contains(by_id, "idea.trade_unions", 0, "全国工人阶层满意度")
	_expect_contains(by_id, "idea.hunting_tradition", 0, "单一职业占当地就业人口至少 60%")
	_expect_contains(by_id, "idea.village_compact", 0, "周围 1 格内人口合计至少 800 人")
	_expect_contains(by_id, "idea.terrace_farming", 2, "周围 1 格内农业产出占比至少 50% 的地块至少 2 个")
	_expect_contains(by_id, "idea.heaven_human", 0, "降水强度至少 50%")
	_expect_contains(by_id, "idea.ecological_balance", 0, "当地货物最高短缺率至少 30%")
	_expect_contains(by_id, "idea.ecological_balance", 0, "自然资源平均剩余比例至少 80%")
	_expect_contains(by_id, "idea.welfare_state", 0, "必需品短缺率不超过 1%")
	_expect_contains(by_id, "idea.coppice_rotation", 0, "主产木材")
	_expect_contains(by_id, "idea.coppice_rotation", 0, "木材产出降低 6%")
	_expect_contains(by_id, "idea.communal_feast", 0, "主产野味")
	_expect_contains(by_id, "idea.communal_feast", 0, "出生率提高 3%")
	_expect_contains(by_id, "idea.communal_feast", 0, "出生率最高提高 9%")
	_expect_contains(by_id, "idea.chartered_route", 0, "同种货物只计一次")
	_expect_contains(by_id, "idea.salt_monopoly", 2, "最高提高 15%")
	_expect_contains(by_id, "idea.semiconductor", 2, "最高提高 40%")
	_expect_contains(by_id, "idea.vertical_farm", 0, "地块本身的属性不变")
	_expect_contains(by_id, "idea.antibiotics", 0, "人口至少 400 人")
	_expect_contains(by_id, "idea.space_mining", 0, "主产铜矿石")
	_expect_contains(by_id, "idea.space_mining", 0, "主产锌矿石")
	_expect_contains(by_id, "idea.algorithmic_governance", 0, "包含其代价")
	_expect_contains(by_id, "idea.algorithmic_governance", 0, "左邻为空或为传世理念时不复制")
	for phantom in ["住房需求", "居住维护材料需求", "房租", "地价推高居住成本",
			"主产原木", "主产野味/鱼/采集物", "资源消耗提高 2%", "7.5 个", "13.3334 个"]:
		_expect("misleading effect absent: %s" % phantom, not joined.contains(phantom))
	var joined_details := "\n".join(details)
	for phantom in ["无条件发给每个人一笔钱", "短缺消失", "成本归零", "运距归零", "撤除关税", "污染水土", "物价与交易规模一起被推高", "永久压低", "能源需求随之上抬", "地价上涨", "地主付得起地税"]:
		_expect("unsupported description absent: %s" % phantom,
			not joined_details.contains(phantom))
	# Every published program must reach the visible face. This catches stale
	# per-card display overrides and silent line-budget truncation across all
	# cards, including independently targeted bonuses and costs on the same level.
	var program_by_key := {}
	for program in catalog.effect_programs.effects:
		program_by_key[String(program.definition_key)] = program
	var program_count := 0
	for definition in catalog.definitions:
		var card_id := String(definition.id)
		for level_index in definition.levels.size():
			var row: Dictionary = by_id[card_id]
			var visible := "\n".join(row.level_effect_lines[level_index])
			for effect in definition.levels[level_index].persistent_effects:
				var key := String(effect.definition_key)
				if not program_by_key.has(key):
					continue
				program_count += 1
				var summary := String(catalog.call("_clean_card_face_text",
					String(program_by_key[key].summary)))
				_expect("%s L%d preserves program %s" % [card_id, level_index + 1, key],
					not summary.is_empty() and visible.contains(summary))
	_expect("all 280 production programs are checked", program_count == 280)
	var synergy_count := 0
	for synergy in view.get("synergies", []):
		synergy_count += 1
		var tooltip := String(synergy.get("tooltip", ""))
		_expect("%s has visible effects" % synergy.id,
			not (synergy.effect_lines as PackedStringArray).is_empty())
		if not String(synergy.get("route_tag", "")).is_empty():
			_expect("%s states ideology-slot requirement" % synergy.id,
				tooltip.contains("理念槽中至少"))
		else:
			_expect("%s counts national spirits" % synergy.id,
				tooltip.contains("含民族精神"))
	_expect("all 40 visible synergies are reviewed", synergy_count == 40)
	_expect("full semantic traversal completed", _checks >= 1750)

	_finish()


func _expect_contains(by_id: Dictionary, card_id: String, level_index: int,
		fragment: String) -> void:
	var row: Dictionary = by_id.get(card_id, {})
	var levels: Array = row.get("level_effect_lines", [])
	var lines: PackedStringArray = levels[level_index] \
		if level_index >= 0 and level_index < levels.size() else PackedStringArray()
	_expect("%s L%d contains %s" % [card_id, level_index + 1, fragment],
		"\n".join(lines).contains(fragment))


func _has_line_with_fragments(lines: PackedStringArray,
		fragments: Array) -> bool:
	for line in lines:
		var matches_all := true
		for fragment in fragments:
			if not String(line).contains(String(fragment)):
				matches_all = false
				break
		if matches_all:
			return true
	return false


func _finish() -> void:
	print("ideology card-face semantics: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label if detail.is_empty() else "%s: %s" % [label, detail], condition)
	return condition


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
