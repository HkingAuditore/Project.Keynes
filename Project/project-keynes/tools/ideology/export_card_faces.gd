extends SceneTree

## Exports every published ideology card level to Markdown for content review.
## Run from the repository root:
##   <godot_console.exe> --headless --path . \
##     --script res://tools/ideology/export_card_faces.gd
## This is a display-only report: it never writes the generated catalogs.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const OUTPUT_PATH := "res://docs/ideology-card-faces.md"


func _init() -> void:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy_ir.get("ok", false)):
		push_error("[export_card_faces] economy catalog failed: %s" % str(economy_ir))
		quit(1)
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if catalog == null:
		push_error("[export_card_faces] default ideology catalog missing")
		quit(1)
		return
	var view: Dictionary = catalog.catalog_view(economy_ir, economy_ir)
	if not bool(view.get("ok", false)):
		push_error("[export_card_faces] catalog view failed: %s"
			% String(view.get("reason", "")))
		quit(1)
		return
	var rows: Array = view.get("ideologies", [])
	var lines := PackedStringArray([
		"# 理念卡面文案",
		"",
		"> 由 `tools/ideology/export_card_faces.gd` 自动生成；只读取 `catalog_view()` 的玩家可见文案。",
		"",
	])
	for row_value in rows:
		var row: Dictionary = row_value
		lines.append("## %s · %s" % [
			String(row.get("display_name", row.get("id", ""))),
			String(row.get("school_name", row.get("school", ""))),
		])
		lines.append("")
		lines.append("- ID：`%s`" % String(row.get("id", "")))
		lines.append("- 稀有度：%s" % String(row.get("rarity_label",
			row.get("rarity", ""))))
		lines.append("- 详情：%s" % String(row.get("detail_key", "")))
		var requirement_lines := PackedStringArray()
		var technology_names: PackedStringArray = row.get(
			"required_technology_names", PackedStringArray())
		for technology_name in technology_names:
			requirement_lines.append("科技：%s" % String(technology_name))
		for signal_name in row.get("required_research_signal_names",
				PackedStringArray()):
			requirement_lines.append("研究信号：%s" % String(signal_name))
		if not requirement_lines.is_empty():
			lines.append("- 抽取条件：%s" % "；".join(requirement_lines))
		var levels: Array = row.get("level_effect_lines", [])
		for level_index in levels.size():
			lines.append("")
			lines.append("### %s" % String(
				(row.get("level_labels", []) as Array)[level_index]
				if level_index < (row.get("level_labels", []) as Array).size()
				else "等级 %d" % (level_index + 1)))
			for effect_line in levels[level_index]:
				lines.append("- %s" % String(effect_line))
		if row_value != rows.back():
			lines.append("")
	lines.append("")
	lines.append("## 羁绊与流派共鸣")
	lines.append("")
	var synergies: Array = view.get("synergies", [])
	for synergy in synergies:
		lines.append("### %s" % String(synergy.get("display_name", "")))
		lines.append("")
		lines.append("- %s" % String(synergy.get("tooltip", "")))
		lines.append("")
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[export_card_faces] cannot write %s" % OUTPUT_PATH)
		quit(1)
		return
	file.store_string("\n".join(lines).strip_edges() + "\n")
	file.close()
	print("[PASS] exported %d ideology cards and %d synergies to %s" % [
		rows.size(), synergies.size(), OUTPUT_PATH])
	quit(0)
