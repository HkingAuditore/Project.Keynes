extends SceneTree

## 科技详情栏的两条契约：效果排在条件前面，效果数字全卡只有一个口径。
##
## 玩家报的问题：详情栏读完不知道研发这个科技能带来什么。根因有两条，都在详情栏：
##
## 1) 「掌握后效果」排在「研究条件」之后。条件区在后期科技上能顶到十几行（时代
##    门槛 + 每条前置 + 每条研究路线 + 路线下的细项），效果被压到要滚动才看得见
##    的位置。效果是玩家决定点不点这个科技的唯一依据，它必须排在条件前面。
##
## 2) 效果行的百分比曾经自己算：`value * 100` 取整，既不认 operation（倍率类
##    modifier 的 value 是乘数），也不认 `_bp`（基点，单位 0.01%）与 `_add`
##    （绝对加量）。于是「地产测绘」的地主税率 400bp 渲染成 +40000%，
##    「常备军」的训练时长 -10% 渲染成 +90%（符号还反了），「军事测绘」的
##    视野 +10 渲染成 +1000%。而卡片上方的摘要行走的是正确口径，同一张卡
##    因此会同时出现两种数字。
##
## 本用例钉住：效果块在条件之前、效果行与共享格式化函数一致、摘要行与逐条行
## 的百分比集合完全一样（不允许一张卡自相矛盾）。

const CardScene := preload("res://scenes/ui/technology_detail_card.tscn")
const CatalogScript := preload("res://scripts/economy/technology_catalog.gd")
const PresentationScript := preload(
	"res://scripts/technology/technology_network_presentation.gd")

const ERA_NAME := "石器时代"
const DOMAIN_NAME := "农业"
const PERCENT_PATTERN := "[+-]?[0-9]+(?:\\.[0-9]+)?%"

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("technology detail card effect priority: %d checks, %d failures"
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	var definitions: Array = CatalogScript.public_definitions()
	_expect("catalog exposes public definitions", not definitions.is_empty())
	if definitions.is_empty():
		return
	var card := CardScene.instantiate() as Control
	if card == null:
		_expect("detail card scene instantiates", false)
		return
	get_root().add_child(card)
	_check_effect_first(card, definitions)
	_check_effect_numbers(card, definitions)
	_check_named_regressions(card, definitions)
	get_root().remove_child(card)
	card.free()


## 条件区用一组刻意压长的条目，模拟后期科技——效果仍必须排在它前面。
func _check_effect_first(card: Control, definitions: Array) -> void:
	var definition := _find(definitions, "tech.crop_domestication")
	if definition.is_empty():
		definition = definitions[0]
	var conditions: Array = []
	for cursor in range(8):
		conditions.append({
			"text": "需要先完成：假前置 %d" % cursor,
			"icon": &"technology.state.locked",
			"accent": UITokens.WARN,
			"met": false,
		})
	_show(card, definition, conditions)
	var block := card.get_node("%DetailBlock") as VBoxContainer
	var effect_title := card.get_node("%EffectTitle") as Control
	var effects := card.get_node("%Effects") as Control
	var condition_title := card.get_node("%ConditionTitle") as Control
	var conditions_list := card.get_node("%Conditions") as Control
	var gauge := card.get_node("%Gauge") as Control

	_expect("a researchable node shows the effect block",
		effect_title.visible and effects.visible)
	_expect("effects sit above the research conditions",
		effect_title.get_index() < condition_title.get_index()
		and effects.get_index() < conditions_list.get_index())
	_expect("effects sit above the progress gauge",
		effects.get_index() < gauge.get_index())

	# 效果标题之前只允许有那一行合并摘要；再多的东西就是把效果往下推。
	var before := PackedStringArray()
	for child in block.get_children():
		var control := child as Control
		if control == null or not control.visible:
			continue
		if control == effect_title:
			break
		before.append(control.name)
	_expect("nothing but the merged summary line sits above the effect rows",
		before.size() <= 1 and (before.is_empty() or before[0] == "Summary"))


## 效果行文字必须就是共享模块给的文字，且摘要行与逐条行的百分比必须一致。
func _check_effect_numbers(card: Control, definitions: Array) -> void:
	var missing := PackedStringArray()
	var wrong := PackedStringArray()
	var miscounted := PackedStringArray()
	var contradictions := PackedStringArray()
	var summary_drift := PackedStringArray()
	var compared := 0
	for value in definitions:
		var definition: Dictionary = value
		var terms: Array = definition.get("modifier_terms", [])
		var technology_id := String(definition.get("id", ""))
		var rendered := _rendered_effect_texts(card, definition)
		var items: Array = card._effect_items(definition)
		if rendered.size() != items.size():
			miscounted.append("%s（%d 行 / %d 条）"
				% [technology_id, rendered.size(), items.size()])
		var summary_text := (card.get_node("%Summary") as Label).text
		var declared := String(definition.get("effect_summary", "")).strip_edges()
		if summary_text != declared:
			summary_drift.append("%s: 显示「%s」，数据「%s」"
				% [technology_id, summary_text, declared])
		var summary_percents := _percent_tokens(summary_text)
		var row_percents := _percent_tokens(" ".join(rendered))
		if summary_percents != row_percents:
			contradictions.append("%s: 摘要 %s / 逐条 %s" % [
				technology_id, str(summary_percents), str(row_percents)])
		for term_value in terms:
			var term: Dictionary = term_value
			compared += 1
			var subject := PresentationScript.modifier_effect_subject(term)
			var expected := "%s %s" % [subject, PresentationScript.modifier_delta(term)]
			if rendered.has(expected):
				continue
			var actual := ""
			for text in rendered:
				if String(text).begins_with(subject):
					actual = String(text)
					break
			if actual.is_empty():
				missing.append("%s → %s" % [technology_id, expected])
			else:
				wrong.append("%s: 期望「%s」，实际「%s」" % [technology_id, expected, actual])
	_expect("all %d modifier lines render through the shared formatter" % compared,
		missing.is_empty() and wrong.is_empty())
	_expect("every technology renders exactly one row per effect item",
		miscounted.is_empty())
	_expect("the merged summary line still matches the authored effect_summary",
		summary_drift.is_empty())
	_expect("the summary line and the effect rows never disagree on a percentage",
		contradictions.is_empty())
	if not missing.is_empty():
		print("    missing: ", ", ".join(missing.slice(0, 6)))
	if not wrong.is_empty():
		print("    wrong: ", " | ".join(wrong.slice(0, 6)))
	if not miscounted.is_empty():
		print("    miscounted: ", ", ".join(miscounted.slice(0, 6)))
	if not summary_drift.is_empty():
		print("    summary drift: ", " | ".join(summary_drift.slice(0, 6)))
	if not contradictions.is_empty():
		print("    contradictions: ", " | ".join(contradictions.slice(0, 6)))


## 四个具体的、玩家读出来会做错决定的例子。
func _check_named_regressions(card: Control, definitions: Array) -> void:
	_check_one(card, definitions, "tech.property_cadastre", "地主", "+4%", "40000")
	_check_one(card, definitions, "tech.military.standing_army", "训练时长",
		"-10%", "+90%")
	_check_one(card, definitions, "tech.military.legion_logistics", "补给消耗",
		"-30%", "+70%")
	_check_one(card, definitions, "tech.state_bureaucracy", "学者", "+3%", "30000")


func _check_one(card: Control, definitions: Array, technology_id: String,
		subject: String, expected_suffix: String, forbidden: String) -> void:
	var definition := _find(definitions, technology_id)
	if definition.is_empty():
		_expect("%s exists in the catalog" % technology_id, false)
		return
	var line := ""
	for text in _rendered_effect_texts(card, definition):
		if String(text).begins_with(subject):
			line = String(text)
			break
	_expect("%s reads as 「%s %s」 (got 「%s」)"
		% [technology_id, subject, expected_suffix, line],
		line.ends_with(expected_suffix))
	_expect("%s does not print %s" % [technology_id, forbidden],
		not line.contains(forbidden))


func _find(definitions: Array, technology_id: String) -> Dictionary:
	for value in definitions:
		var definition: Dictionary = value
		if String(definition.get("id", "")) == technology_id:
			return definition
	return {}


func _percent_tokens(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var regex := RegEx.create_from_string(PERCENT_PATTERN)
	for found in regex.search_all(text):
		out.append(found.get_string())
	out.sort()
	return out


func _show(card: Control, definition: Dictionary, conditions: Array) -> void:
	card.show_technology(0, definition, 2, 0.3, Color.WHITE, ERA_NAME, DOMAIN_NAME,
		{"condition_items": conditions})


## 走详情卡自己的取值入口，再读 InsightList 里真正写进 Label 的文字——
## 断言的是玩家看到的字，不是中间列表。
func _rendered_effect_texts(card: Control, definition: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	_show(card, definition, [])
	var effects := card.get_node("%Effects") as VBoxContainer
	for child in effects.get_children():
		var row := child as HBoxContainer
		if row == null or not row.visible:
			continue
		var label := row.get_node_or_null("Label") as Label
		if label != null:
			out.append(label.text)
	return out
