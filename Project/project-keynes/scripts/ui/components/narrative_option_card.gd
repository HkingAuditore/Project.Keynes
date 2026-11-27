extends RefCounted

## Builds a narrative option's visible card and choice button.

const EraNoteStyle: StyleBoxTexture = preload("res://assets/ui/era/era_note_style.tres")
const UITokensScript = preload("res://scripts/ui/ui_tokens.gd")


static func prepare(opt_dict: Dictionary, make_button: Callable) -> Dictionary:
	var card := UIControlParts.panel_container()
	var normal_paper := EraNoteStyle.duplicate() as StyleBoxTexture
	normal_paper.content_margin_left = 18.0
	normal_paper.content_margin_right = 18.0
	normal_paper.content_margin_top = 12.0
	normal_paper.content_margin_bottom = 12.0
	normal_paper.modulate_color = Color(0.985, 0.955, 0.875, 1.0)

	var hover_paper := normal_paper.duplicate() as StyleBoxTexture
	hover_paper.modulate_color = Color(1.03, 1.0, 0.92, 1.0)
	card.add_theme_stylebox_override("panel", normal_paper)

	var row := UIControlParts.h_box_container()
	row.add_theme_constant_override("separation", 14)
	card.add_child(row)

	# Left accent wax/ink bar
	var outcomes: Array = opt_dict.get("outcomes", [])
	var is_probabilistic := outcomes.size() > 1
	var bar := UIControlParts.color_rect()
	bar.custom_minimum_size = Vector2(3.5, 0.0)
	bar.color = UITokensScript.DOSSIER_BRASS if is_probabilistic else UITokensScript.DOSSIER_OXBLOOD
	row.add_child(bar)

	var content_col := UIControlParts.v_box_container()
	content_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_col.add_theme_constant_override("separation", 5)
	row.add_child(content_col)

	var title_row := UIControlParts.h_box_container()
	title_row.add_theme_constant_override("separation", 8)
	content_col.add_child(title_row)

	var opt_title := UIControlParts.label()
	opt_title.text = String(opt_dict.get("text", "选项"))
	opt_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	opt_title.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	opt_title.add_theme_font_size_override("font_size", 16)
	opt_title.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	title_row.add_child(opt_title)

	var eligible := bool(opt_dict.get("eligible", true))
	# 选项本身已经显示为不可点；只有具体原因才值得占一行，「条件未满足」等于没说。
	var ineligible_reason := String(opt_dict.get("ineligible_reason", "")).strip_edges()
	if not eligible and not ineligible_reason.is_empty():
		var reason_lbl := UIControlParts.label()
		reason_lbl.text = ineligible_reason
		reason_lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
		reason_lbl.add_theme_font_size_override("font_size", 13)
		reason_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
		content_col.add_child(reason_lbl)

	# Render outcomes:
	# - Single deterministic outcome (majority of options): show effect lines directly, no probability noise.
	# - Multi-outcome gamble option (minority): one row per branch with its percentage.
	if outcomes.size() == 1 and outcomes[0] is Dictionary:
		var od: Dictionary = outcomes[0]
		var eff_lines: PackedStringArray = PackedStringArray(od.get("effect_summaries", []))
		var eff_text := "  ·  ".join(eff_lines) if not eff_lines.is_empty() else String(od.get("outcome_title", "无效果"))
		var eff_lbl := UIControlParts.label()
		eff_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		eff_lbl.text = eff_text
		eff_lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
		eff_lbl.add_theme_font_size_override("font_size", 14)
		eff_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_VERDIGRIS)
		content_col.add_child(eff_lbl)
	elif outcomes.size() > 1:
		for out_item in outcomes:
			if not (out_item is Dictionary):
				continue
			var od: Dictionary = out_item
			var prob_pct := int(od.get("probability_percent", 50))
			var out_title := String(od.get("outcome_title", "分支"))
			var eff_lines: PackedStringArray = PackedStringArray(od.get("effect_summaries", []))
			var eff_joined := "；".join(eff_lines) if not eff_lines.is_empty() else "无效果"

			var branch_row := UIControlParts.h_box_container()
			branch_row.add_theme_constant_override("separation", 6)
			content_col.add_child(branch_row)

			var pct_badge := UIControlParts.label()
			pct_badge.text = "%d%% %s" % [prob_pct, out_title]
			pct_badge.custom_minimum_size = Vector2(124.0, 0.0)
			pct_badge.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
			pct_badge.add_theme_font_size_override("font_size", 13)
			pct_badge.add_theme_color_override("font_color",
				UITokensScript.DOSSIER_VERDIGRIS if prob_pct >= 50 else UITokensScript.DOSSIER_UMBER)
			branch_row.add_child(pct_badge)

			var branch_eff := UIControlParts.label()
			branch_eff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			branch_eff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			branch_eff.text = eff_joined
			branch_eff.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
			branch_eff.add_theme_font_size_override("font_size", 13)
			branch_eff.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK_SOFT)
			branch_row.add_child(branch_eff)

	# Right-side action button
	var choose_btn: Button = make_button.call("选择")
	choose_btn.custom_minimum_size = Vector2(98.0, 38.0)
	choose_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	choose_btn.disabled = not eligible
	var hint := String(opt_dict.get("tooltip_hint", "")).strip_edges()
	if not hint.is_empty():
		choose_btn.tooltip_text = hint
	return {
		"card": card, "button": choose_btn, "row": row,
		"normal_paper": normal_paper, "hover_paper": hover_paper,
	}
