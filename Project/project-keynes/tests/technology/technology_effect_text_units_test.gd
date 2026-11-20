extends SceneTree

## 详情卡的效果行曾经自己算增量：`int(round(value * 100))` 再套 `%+d%%`。
## 于是 `_bp` 基点统计被放大 100 倍（地产测绘的地主税率 400bp 显示成 +40000%）、
## operation=2 的倍率项符号反了（恶劣环境减员 0.7 显示成 +70%）、小数被取整
## （+26.4% 显示成 +26%）。同一张卡顶部摘要走的是 NetworkPresentation，两处
## 数字因此对不上，玩家在同一屏里读到两个不同的值。
##
## 现在效果行统一走 NetworkPresentation.modifier_delta / modifier_effect_subject。
## 本用例锁两件事：效果数字与顶部摘要一致；效果块排在详情栏靠前的位置，
## 不再被进度条和研究条件压到需要滚动才看得到。

const EffectTextScript = preload(
	"res://scripts/ui/components/technology_effect_text.gd")
const CatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const CardScene := preload("res://scenes/ui/technology_detail_card.tscn")

const PERCENT_PATTERN := "[+-]?\\d+(?:\\.\\d+)?"

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("technology effect text units: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _term(stat: String, value: float, operation: int, display: String) -> Dictionary:
	return {"stat": stat, "value": value, "operation": operation,
		"subject_display_name": display}


func _lines(definition: Dictionary) -> String:
	return "\n".join(EffectTextScript.effect_texts(definition))


## 把文本里的数值抽成排序后的字符串，用来比较两处是否讲同一个数。
func _numbers(text: String, regex: RegEx) -> String:
	var kept: Array = []
	for match_value in regex.search_all(text):
		var token := String((match_value as RegExMatch).get_string())
		if not kept.has(token):
			kept.append(token)
	kept.sort()
	return ",".join(PackedStringArray(kept))


func _run() -> void:
	# --- 量纲：基点与绝对加量不是百分比 ---
	var basis_points := {"modifier_terms": [
		_term("country.tax.income.landlord.rate_bp", 400.0, 0, "地主")]}
	_expect("400bp reads as 地主 +4%, not +40000%",
		_lines(basis_points).contains("地主 +4%"))

	var satisfaction := {"modifier_terms": [
		_term("economy.profession.worker.satisfaction_bp", 120.0, 0, "工人")]}
	_expect("120bp reads as 工人 +1.2%", _lines(satisfaction).contains("工人 +1.2%"))

	var vision := {"modifier_terms": [
		_term("country.military.vision_add", 10.0, 0, "视野")]}
	_expect("absolute vision reads as 视野 +10, not +1000%",
		_lines(vision).contains("视野 +10"))

	# --- operation：2 是倍率，0.7 表示 -30%，不是 +70% ---
	var attrition := {"modifier_terms": [
		_term("country.military.attrition_factor", 0.7, 2, "恶劣环境减员")]}
	_expect("multiplier 0.7 reads as -30%",
		_lines(attrition).contains("恶劣环境减员 -30%"))

	var transport := {"modifier_terms": [
		_term("country.military.supply_transport_factor", 2.0, 2, "车队速度")]}
	_expect("multiplier 2.0 reads as +100%", _lines(transport).contains("车队速度 +100%"))

	# --- 小数不再被取整 ---
	var decimal := {"modifier_terms": [
		_term("country.output.family.specialty_commodity_crops_factor", 0.264, 0,
			"专用商品作物")]}
	_expect("26.4% keeps its decimal", _lines(decimal).contains("+26.4%"))

	# --- 真实目录：效果行与摘要必须讲同一组数字 ---
	var definitions: Array = CatalogScript.public_definitions()
	_expect("catalog exposes public definitions", not definitions.is_empty())
	if definitions.is_empty():
		return
	var regex := RegEx.new()
	regex.compile(PERCENT_PATTERN)
	var disagreed := PackedStringArray()
	for value in definitions:
		var definition: Dictionary = value
		var summary_numbers := _numbers(String(definition.get("effect_summary", "")), regex)
		var card_numbers := _numbers(_lines(definition), regex)
		if summary_numbers != card_numbers:
			disagreed.append(String(definition.get("id", "")))
	_expect("every technology shows the same numbers in the card and the summary",
		disagreed.is_empty())
	if not disagreed.is_empty():
		print("    disagreeing nodes: ", disagreed)

	# --- 位置：效果块排在进度条与研究条件之前 ---
	var card := CardScene.instantiate() as Control
	if card == null:
		_expect("detail card scene instantiates", false)
		return
	var block := card.get_node_or_null("%DetailBlock") as VBoxContainer
	_expect("detail card exposes DetailBlock", block != null)
	if block != null:
		var positions := {}
		for cursor in range(block.get_child_count()):
			positions[String(block.get_child(cursor).name)] = cursor
		var summary_at := int(positions.get("Summary", -1))
		var effects_at := int(positions.get("Effects", -1))
		var gauge_at := int(positions.get("Gauge", -1))
		var conditions_at := int(positions.get("Conditions", -1))
		_expect("detail block still has Summary / Effects / Gauge / Conditions",
			summary_at >= 0 and effects_at >= 0 and gauge_at >= 0 and conditions_at >= 0)
		_expect("effects come right after the summary, before the gauge",
			effects_at > summary_at and effects_at < gauge_at)
		_expect("effects come before the research conditions",
			effects_at < conditions_at)
	card.free()
