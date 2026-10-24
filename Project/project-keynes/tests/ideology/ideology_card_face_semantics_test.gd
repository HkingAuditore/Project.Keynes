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
	"来源地块", "每有 1 个来源", "每个来源", "最多计算",
	"国库现金每相当于", "民意对理念点获取的加成保底", "时农业提高",
	"：工业降低", "支柱地块", "繁市", "大邑", "通衢", "多元地块",
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
	"海岸繁市地块周围", "工业建筑 ≥2 座", "宗族数", "年均温", "产出 -0%",
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
	var level_count := 0
	var missing_school_name_count := 0
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := String(row.get("id", ""))
		by_id[card_id] = row
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

	_expect_contains(by_id, "idea.civil_examination", 2,
		"首次达到化育等级时：免费获得 1 次理念抽取。该奖励只能领取一次。")
	_expect_contains(by_id, "idea.experimental_method", 0,
		"周围 2 格内每有 1 个以知识业为主的地块，该地块的工业产出提高 6%；每个目标地块最多累计 3 个满足条件的地块，最高提高 18%；最多影响 32 个目标地块")
	_expect_contains(by_id, "idea.agricultural_chemistry", 0,
		"周围 2 格内每有 1 个主产化肥的地块，该地块的农业产出提高 8%；每个目标地块最多累计 3 个满足条件的地块，最高提高 24%；最多影响 32 个目标地块")
	_expect_contains(by_id, "idea.telegraph", 0, "知识产出提高 6%")
	_expect_contains(by_id, "idea.telegraph", 2, "周围 3 格")
	_expect_contains(by_id, "idea.container_port", 0, "海岸地块")
	_expect_contains(by_id, "idea.container_port", 0,
		"周围 2 格内每有 1 个海岸地块，该地块的工业产出提高 10%；每个目标地块最多累计 3 个满足条件的地块，最高提高 30%；最多影响 32 个目标地块")
	_expect_contains(by_id, "idea.carbon_market", 0, "当地至少有 3 个经济部门")
	_expect_contains(by_id, "idea.autonomous_logistics", 0,
		"当地贸易事件至少达到 24 次的地块，其周围 1 格内的地块：全部产出提高 2%；全国交通路线的影响范围由周围 1 格扩大为周围 2 格")
	_expect_contains(by_id, "idea.frontier_garrison", 2, "边境或边远地块")
	_expect_contains(by_id, "idea.fire_keeping", 0, "冻原地块")
	_expect_contains(by_id, "idea.manufactory_regulation", 0, "每有 1 座工业建筑")
	_expect_contains(by_id, "idea.marriage_alliance", 0, "家族分支")
	_expect_contains(by_id, "idea.marriage_alliance", 0,
		"周围 1 格内每有 1 个有至少 1 个家族分支的地块")
	_expect_contains(by_id, "idea.family_office", 2,
		"全国每有 1 个拥有至少 3 个家族分支的家族，研究成本降低 0.5%；最多按 24 个家族计算，最高降低 12%。另有一组独立效果：拥有至少 3 个家族分支且持有建筑的家族，其名下全部建筑产出提高 6%；最多按 32 个家族计算")
	_expect_contains(by_id, "idea.colonial_plantation", 2, "农业产出提高 28%")
	_expect_contains(by_id, "idea.social_media", 0,
		"理念点获取的民意加成下限降低 10 个百分点")
	_expect_contains(by_id, "idea.excise", 2,
		"按“国库现金 ÷ 全国人口一年收入总额”计算，该比例每提高 1 个百分点，建设成本降低 0.5%（最多降低 4%）")
	_expect_contains(by_id, "idea.treasury_reserve", 0,
		"按“国库现金 ÷ 全国人口一年收入总额”计算，该比例每提高 1 个百分点，建设成本降低 1%（最多降低 5%）")
	_expect("rice is named in plain language", joined.contains("稻米"))
	_expect("wheat is named in plain language", joined.contains("小麦"))
	_expect("fertilizer is named in plain language", joined.contains("肥料"))
	_expect("dryland production is named in plain language",
		joined.contains("旱作作物"))
	_expect("paddy production is named in plain language",
		joined.contains("水田作物"))
	_expect("treasury reserve is explained against annual income",
		_has_line_with_fragments(all_lines,
			["国库现金", "全国人口一年收入总额"]))
	_expect("measured net tax is explained against pre-tax income",
		_has_line_with_fragments(all_lines,
			["实际净纳税额", "税前收入"]))
	_expect("industrial workforce and class support are explained together",
		_has_line_with_fragments(all_lines, ["工业职业", "支持度"]))
	_expect("production input is explained as material use",
		joined.contains("生产所需原料"))
	_expect("trade capacity is explained by goods per trade",
		joined.contains("每次贸易可成交的货物量"))
	_expect("trade speed is explained as transport speed",
		joined.contains("贸易运输速度"))
	_expect("research efficiency names its actual discipline lane",
		joined.contains("社会研究速度") and joined.contains("科学研究速度"))
	_expect_contains(by_id, "idea.free_trade", 0,
		"经济部门少于 3 个的以工业为主的地块：工业产出降低 5%")
	_expect_contains(by_id, "idea.heaven_human", 0,
		"以农业为主的地块：降水充足时农业产出提高 6%")
	_expect_contains(by_id, "idea.salt_monopoly", 0,
		"以采掘业为主的地块：全国每有 1 个采掘业地块，这些目标地块的采掘产出提高 1%；这些目标地块最多累计 15 个满足条件的地块，最高提高 15%")
	_expect_contains(by_id, "idea.semiconductor", 0,
		"当地至少已建成 1 条完整建筑升级链（同一升级系列的各等级建筑均已建成）的地块：全国每有 1 个这样的地块，这些目标地块的半导体产出提高 2%；这些目标地块最多累计 20 个满足条件的地块，最高提高 40%")
	_expect_contains(by_id, "idea.silver_flow", 0,
		"主产白银的地块：全国每有 1 个这样的地块，这些目标地块的全部产出提高 3%；这些目标地块最多累计 5 个满足条件的地块，最高提高 15%")
	_expect_contains(by_id, "idea.silver_standard", 0,
		"按“国库现金 ÷ 全国人口一年收入总额”计算")
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
