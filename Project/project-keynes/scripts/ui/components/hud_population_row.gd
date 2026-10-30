extends HBoxContainer
class_name HudPopulationRow

## 人口悬浮卡的一行职业：左侧色签对齐构成条，右侧人口与占比，
## 第二行给满意度（语义色）与生活档（档位图标 + 档名）。行本身不参与点击。

const NAME_FONT_SIZE := 13
const DETAIL_FONT_SIZE := 11

@onready var _accent: ColorRect = %Accent
@onready var _icon: IconBadge = %Icon
@onready var _name_label: Label = %NameLabel
@onready var _satisfaction: Label = %Satisfaction
@onready var _living_icon: IconBadge = %LivingIcon
@onready var _living: Label = %Living
@onready var _people: Label = %People
@onready var _share: Label = %Share


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_name_label.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_name_label.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
	_name_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	_people.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_people.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
	_people.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	for label: Label in [_satisfaction, _living, _share]:
		label.add_theme_font_override("font", UITokens.dossier_font("sans"))
		label.add_theme_font_size_override("font_size", DETAIL_FONT_SIZE)
	_share.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_living.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)


func set_data(row: Dictionary) -> void:
	if _name_label == null:
		_ready()
	var color: Color = row.get("color", UITokens.DOSSIER_BRASS)
	_accent.color = color
	_icon.set_semantic(StringName(row.get("icon", "population.heart")), color)
	_name_label.text = String(row.get("name", ""))
	_people.text = String(row.get("population_text", "—"))
	_share.text = String(row.get("share_text", ""))
	_satisfaction.text = "满意度 %s" % String(row.get("satisfaction_text", "—"))
	_satisfaction.add_theme_color_override("font_color",
		row.get("satisfaction_color", UITokens.DOSSIER_INK_MUTED))
	# 档位图标直接说明「哪一档」，所以档名前不再重复写「生活」两个字。
	_living_icon.set_semantic(StringName(row.get("living_icon", "population.living.poor")),
		color)
	_living_icon.visible = not String(row.get("living_icon", "")).is_empty()
	_living.text = String(row.get("living_text", "—"))
	tooltip_text = "%s\n人口 %s（占 %s）\n满意度 %s\n生活水平 %s\n%s" % [
		String(row.get("name", "")), String(row.get("population_text", "—")),
		String(row.get("share_text", "—")), String(row.get("satisfaction_text", "—")),
		String(row.get("living_text", "—")),
		"其中含未单列的较小职业，数值为合计。" if bool(row.get("folded", false)) \
			else "点击上方的纸签可进入民生页查看全部职业。",
	]
