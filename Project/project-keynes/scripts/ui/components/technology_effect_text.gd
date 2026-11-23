class_name TechnologyEffectText
extends RefCounted

## content_effects / modifier_terms → 玩家可读的效果行。
##
## 详情卡和可研究清单原来各写一套，两边都漏同一件事：
## 详情的 `_effect_items` 只认 building / good / resource / class / terrain /
## landform / climate / tile 八类，把 `kind = "runtime"` 的航道效果整条丢掉；
## 清单的悬停提示只读 `effect_summary`，而「天文导航」的 effect_summary 是空串。
## 结果同一个科技在列表里和详情里都显示成「没有效果」，玩家也就看不出它开放的是
## 浅海航道。两处统一调这里，别再各写一份。

const TechnologyNetworkValidatorScript := preload(
	"res://scripts/technology/technology_network_validator.gd")


## 结构化效果行：[{text, icon, accent}]。没有结构化效果时退回 effect_summary 的分句。
static func effect_items(definition: Dictionary) -> Array:
	var items: Array = []
	for effect_value in definition.get("content_effects", []):
		var effect: Dictionary = effect_value
		var kind := String(effect.get("kind", ""))
		var id := String(effect.get("id", ""))
		var display_name := String(effect.get("display_name", id))
		var attribute := String(effect.get("attribute", ""))
		var text := ""
		match kind:
			"building": text = "解锁建筑 · %s" % display_name
			"good":
				text = ("解锁物资 · %s" if attribute == "production_access" \
					else "生产配方关联 · %s") % display_name
			"resource": text = "可利用资源 · %s" % display_name
			"class": text = "阶层岗位 · %s" % display_name
			"terrain": text = "地形专长 · %s" % display_name
			"landform": text = "地貌专长 · %s" % display_name
			"climate": text = "气候专长 · %s" % display_name
			"tile": text = "地块条件 · %s" % display_name
			# 运行时能力没有建筑/物资载体，只能靠 content_effects 自己说明
			# （如 water.* 的四档航道）。
			"runtime":
				text = ("开启航道 · %s" if id.begins_with("water.") \
					else "运行机制 · %s") % display_name
		if not text.is_empty():
			var icon := &"metric.technology"
			if kind == "building":
				icon = &"economy.building"
			elif kind == "runtime":
				icon = &"economy.building.transport"
			items.append({
				"text": text,
				"icon": icon,
				"accent": UITokens.RESOURCE,
			})
	var modifier_texts := {}
	for term_value in definition.get("modifier_terms", []):
		var term: Dictionary = term_value
		var value := int(round(float(term.get("value", 0.0)) * 100.0))
		var delta := "%+d%%" % value
		var subject := TechnologyNetworkValidatorScript.modifier_effect_subject(term)
		var text := ""
		if not subject.is_empty():
			text = "%s %s" % [subject, delta]
		if not text.is_empty() and not modifier_texts.has(text):
			modifier_texts[text] = true
			items.append({"text": text, "icon": &"metric.technology", "accent": UITokens.CLIMATE})
	if not items.is_empty():
		return items
	var summary := String(definition.get("effect_summary", ""))
	for chunk in summary.replace("，", "、").split("、", false):
		var text := String(chunk).strip_edges()
		if text.is_empty():
			continue
		var unlocks := text.begins_with("解锁") or text.begins_with("开启") \
			or text.begins_with("完成")
		items.append({
			"text": text,
			"icon": &"economy.building" if unlocks else &"metric.technology",
			"accent": UITokens.RESOURCE if unlocks else UITokens.CLIMATE,
		})
	return items


## 只要文字，给纯文本场合（悬停提示等）用。
static func effect_texts(definition: Dictionary) -> PackedStringArray:
	var texts := PackedStringArray()
	for item_value in effect_items(definition):
		var text := String((item_value as Dictionary).get("text", "")).strip_edges()
		if not text.is_empty():
			texts.append(text)
	return texts


## 一句话摘要：优先用作者写的 effect_summary，空的时候（如天文导航）才由结构化
## 效果拼出来。返回值可能是多行。
static func summary_text(definition: Dictionary) -> String:
	var summary := String(definition.get("effect_summary", "")).strip_edges()
	if not summary.is_empty():
		return summary
	return "\n".join(effect_texts(definition))
