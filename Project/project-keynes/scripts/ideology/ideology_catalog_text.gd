extends RefCounted

## Pure player-facing text rewrites shared by IdeologyCatalog.

static func replace_source_count_text(_host, text: String) -> String:
	# Source-count programs scale by the number of qualifying cells in range.
	# Rewrite the authored shorthand as a complete rule instead of exposing
	# "源", "每源" or an assignment such as "3 源 = +9%".
	var result := text
	# X1-b authors the source selector between the source description and the
	# target effect. Parse that whole row first: the generic per-source rules
	# below cannot know the source predicate, radius, source cap, or target cap.
	var source_row := RegEx.new()
	if source_row.compile(
			"^(.+?)周围\\s*([0-9]+)\\s*格\\s*[（(]每源\\s*\\+?\\s*([0-9]+(?:\\.[0-9]+)?)%[，,]\\s*最多\\s*([0-9]+)\\s*源(?:\\s*=\\s*\\+?\\s*([0-9]+(?:\\.[0-9]+)?)%)?[）)]\\s*[：:]\\s*(.+?)产出\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%$"
			) == OK:
		for found in source_row.search_all(result):
			var source_subject := found.get_string(1).strip_edges()
			var radius := found.get_string(2)
			var per_source := found.get_string(3)
			var source_cap := found.get_string(4)
			var ceiling := found.get_string(5)
			var target_label := found.get_string(6).strip_edges()
			var direction := "提高" if found.get_string(7) == "+" else "降低"
			var sentence := "周围 %s 格内每有 1 个%s，该地块的%s产出%s %s%%" % [
				radius, source_subject, target_label, direction,
				per_source]
			if not ceiling.is_empty():
				sentence += "；每个目标地块最多累计 %s 个满足条件的地块，最高提高 %s%%" % [
					source_cap, ceiling]
			else:
				var full_percent := float(per_source) * float(source_cap)
				sentence += "；每个目标地块最多累计 %s 个满足条件的地块，最高提高 %s%%" % [
					source_cap, _host._format_card_face_number(full_percent)]
			sentence += "；最多影响 32 个目标地块"
			result = result.replace(found.get_string(0), sentence)
	var source_row_without_assignment := RegEx.new()
	if source_row_without_assignment.compile(
			"^(.+?)周围\\s*([0-9]+)\\s*格\\s*[（(]每源\\s*\\+?\\s*([0-9]+(?:\\.[0-9]+)?)%[，,]\\s*最多\\s*([0-9]+)\\s*源[）)]\\s*[：:]\\s*(.+?)产出\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%$"
			) == OK:
		for found in source_row_without_assignment.search_all(result):
			var direction := "提高" if found.get_string(6) == "+" else "降低"
			result = result.replace(found.get_string(0),
				"周围 %s 格内每有 1 个%s，该地块的%s产出%s %s%%；每个目标地块最多累计 %s 个满足条件的地块；最多影响 32 个目标地块" % [
					found.get_string(2), found.get_string(1).strip_edges(),
					found.get_string(5).strip_edges(), direction, found.get_string(3),
					found.get_string(4)])
	result = result.replace("每源", "每个来源")
	var target_ramp := RegEx.new()
	if target_ramp.compile(
			"^(.+?)周围\\s*([0-9]+)\\s*格\\s*（每有 1 个符合条件的地块提高\\s*([0-9]+(?:\\.[0-9]+)?)%，最多计算\\s*([0-9]+)\\s*个地块）\\s*：\\s*(.+?)(提高|降低)\\s*([0-9]+(?:\\.[0-9]+)?)%$"
			) == OK:
		for found in target_ramp.search_all(result):
			result = result.replace(found.get_string(0),
				"周围 %s 格内每有 1 个%s，该地块的%s%s %s%%；每个目标地块最多累计 %s 个满足条件的地块，最高%s %s%%；最多影响 32 个目标地块" % [
					found.get_string(2), found.get_string(1), found.get_string(5),
					found.get_string(6), found.get_string(3), found.get_string(4),
					found.get_string(6), found.get_string(7)])
	# `每源 +X%，最多 N 源 = +Y%` is authored arithmetic. Preserve the cap and
	# final ceiling, but express them as a complete player-facing rule.
	var source_assignment := RegEx.new()
	if source_assignment.compile(
			"每个来源\\s*(?:提高\\s*)?\\+?\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[，,]?\\s*最多\\s*([0-9]+)\\s*(?:个来源|源)(?:\\s*=\\s*\\+?([0-9]+(?:\\.[0-9]+)?)%)?"
			) == OK:
		for found in source_assignment.search_all(result):
			result = result.replace(found.get_string(0),
				"每有 1 个符合条件的地块提高 %s%%，最多计入 %s 个地块" % [
					found.get_string(1), found.get_string(2)])
	var shorthand := RegEx.new()
	if shorthand.compile(
			"每个来源\\s*提高\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[，,]\\s*最多\\s*([0-9]+)\\s*(?:个来源|源)(?:\\s*[，,]?\\s*使效果达到\\s*([0-9]+(?:\\.[0-9]+)?)%)?"
			) == OK:
		for found in shorthand.search_all(result):
			var replacement := "每有 1 个符合条件的地块提高 %s%%，最多计入 %s 个地块" % [
				found.get_string(1), found.get_string(2)]
			result = result.replace(found.get_string(0), replacement)
	var plain_cap := RegEx.new()
	if plain_cap.compile(
			"每个来源\\s*提高\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[，,]\\s*最多\\s*([0-9]+)\\s*(?:个来源|源)"
			) == OK:
		for found in plain_cap.search_all(result):
			result = result.replace(found.get_string(0),
				"每有 1 个符合条件的地块提高 %s%%，最多计入 %s 个地块" % [
					found.get_string(1), found.get_string(2)])
	var assignment := RegEx.new()
	if assignment.compile(
			"每个来源\\s*提高\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[，,]\\s*最多\\s*([0-9]+)\\s*(?:个来源|源)\\s*=\\s*\\+?([0-9]+(?:\\.[0-9]+)?)%"
			) == OK:
		for found in assignment.search_all(result):
			result = result.replace(found.get_string(0),
				"每有 1 个符合条件的地块提高 %s%%，最多计入 %s 个地块" % [
					found.get_string(1), found.get_string(2)])
	var bare_source := RegEx.new()
	if bare_source.compile(
			"每个来源\\s*提高\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[，,]\\s*最多\\s*([0-9]+)\\s*源"
			) == OK:
		for found in bare_source.search_all(result):
			result = result.replace(found.get_string(0),
				"每有 1 个符合条件的地块提高 %s%%，最多计入 %s 个地块" % [
					found.get_string(1), found.get_string(2)])
	var remaining_source := RegEx.new()
	if remaining_source.compile("最多\\s*([0-9]+)\\s*源") == OK:
		for found in remaining_source.search_all(result):
			result = result.replace(found.get_string(0),
				"最多计入 %s 个地块" % found.get_string(1))
	result = result.replace("每个来源", "每有 1 个符合条件的地块")
	result = result.replace(" =提高", "")
	result = result.replace(" = 提高", "")
	return result

