extends SceneTree

## 验证真实常规/粗体字面与完整中文字库，避免正文退回极细字或系统字体。
func _init() -> void:
	var sample := "Hamburgefontsiv 0123456789"
	var regular := UITokens.font_with_weight(500)
	var strong := UITokens.font_with_weight(800)
	var regular_width := regular.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20).x
	var strong_width := strong.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20).x
	if strong_width <= regular_width:
		push_error("[ui-font-readability] font weight has no measurable effect on glyph metrics")
		quit(1)
		return
	for path in ["player_session_theme", "family_workspace_theme", "menu_atlas_theme"]:
		var theme := load("res://assets/themes/%s.tres" % path) as Theme
		var body := theme.default_font
		if not body.get_font_name().contains("Swei"):
			push_error("[ui-font-readability] %s body is not Swei" % path)
			quit(1)
			return
	for character in "国家科技人口财政黏土铝钨镍％0123456789":
		if not UITokens.UI_FONT.has_char(character.unicode_at(0)):
			push_error("[ui-font-readability] missing body glyph: %s" % character)
			quit(1)
			return
	if not UITokens.UI_DISPLAY_FONT.get_font_name().contains("Muyao"):
		push_error("[ui-font-readability] display font is not Muyao")
		quit(1)
		return
	print("[ui-font-readability] PASS: Swei regular %.1fpx / bold %.1fpx; Muyao display and full Chinese glyphs" % [regular_width, strong_width])
	quit()
