extends Button
class_name ConstructionOptionRow

var _icon: IconBadge
var _materials_icon: IconBadge
var _recipe_icon: IconBadge
var _jobs_icon: IconBadge
var _name: Label
var _materials: Label
var _recipe: Label
var _jobs: Label


func _ready() -> void:
	_icon = get_node("Margin/Line/Icon") as IconBadge
	_name = get_node("Margin/Line/Info/Name") as Label
	_materials_icon = get_node("Margin/Line/Info/MaterialsRow/Icon") as IconBadge
	_recipe_icon = get_node("Margin/Line/Info/RecipeRow/Icon") as IconBadge
	_jobs_icon = get_node("Margin/Line/Info/JobsRow/Icon") as IconBadge
	_materials = get_node("Margin/Line/Info/MaterialsRow/Materials") as Label
	_recipe = get_node("Margin/Line/Info/RecipeRow/Recipe") as Label
	_jobs = get_node("Margin/Line/Info/JobsRow/Jobs") as Label
	_materials_icon.set_semantic(&"economy.resource", UITokens.RESOURCE)
	_recipe_icon.set_semantic(&"economy.building.factory", UITokens.CLIMATE)
	_jobs_icon.set_semantic(&"population.profession.worker", UITokens.ACCENT)


func set_option(item: Dictionary) -> void:
	if _name == null:
		_ready()
	_icon.set_semantic(StringName(item.get("icon", "economy.building")),
			UITokens.CLIMATE)
	_name.text = String(item.get("name", "建筑"))
	_materials.text = _materials_text(item.get("materials", []),
			float(item.get("cash_required", 0)) / 10000.0)
	_recipe.text = _recipe_text(item.get("inputs", []), item.get("outputs", []))
	_jobs.text = _jobs_text(item.get("jobs", []))


func _materials_text(materials: Array, cash: float) -> String:
	var parts := PackedStringArray()
	for raw in materials:
		var material: Dictionary = raw
		parts.append("%s %.2f · 单价 %s · 小计 %s" % [
			String(material.get("name", material.get("good_id", "建材"))),
			float(material.get("required", 0)) / 1000.0,
			String(material.get("unit_price_text", "—")),
			String(material.get("cost_text", "—"))])
	if parts.is_empty():
		parts.append("建材：无")
	parts.append("现金 %.2f" % cash)
	return "建材 · " + "；".join(parts)


func _recipe_text(inputs: Array, outputs: Array) -> String:
	return "原料 · %s    产出 · %s" % [
		_recipe_side(inputs, "无"), _recipe_side(outputs, "无")]


func _recipe_side(rows: Array, empty: String) -> String:
	var parts := PackedStringArray()
	for raw in rows:
		var row: Dictionary = raw
		parts.append("%s %s" % [String(row.get("name", "物资")),
			String(row.get("quantity", "—"))])
	return "、".join(parts) if not parts.is_empty() else empty


func _jobs_text(jobs: Array) -> String:
	var parts := PackedStringArray()
	for raw in jobs:
		var job: Dictionary = raw
		parts.append("%s %d" % [String(job.get("name", "岗位")),
			int(job.get("slots", 0))])
	return "岗位 · " + ("、".join(parts) if not parts.is_empty() else "无")
