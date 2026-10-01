extends PanelContainer
class_name FamilyFoundingCard

signal selected()

@onready var _icon: IconBadge = %Icon
@onready var _category: Label = %Category
@onready var _title: Label = %Title
@onready var _industry: Label = %Industry
@onready var _traits: Label = %Traits
@onready var _effect: Label = %Effect
@onready var _choose: Button = %Choose

var _candidate_empty := true

func _ready() -> void:
	_choose.pressed.connect(func() -> void: selected.emit())

func set_candidate(candidate: Dictionary) -> void:
	_candidate_empty = candidate.is_empty()
	_icon.set_semantic(&"family.house", UITokens.ARCHIVE_BRASS)
	var building := String(candidate.get("building_display_name", "")).strip_edges()
	_category.text = "扶持候选 · %s" % building if not building.is_empty() else "扶持候选"
	_title.text = String(candidate.get("family_name", "暂无候选"))
	var profession := String(candidate.get("owner_profession_display_name", "")).strip_edges()
	var founders := int(candidate.get("founders", 0))
	if _candidate_empty:
		_industry.text = "当前没有可扶持的家族。"
	elif profession.is_empty():
		_industry.text = "立族产业：%s · 创始族人 %d 人" % [building, founders]
	else:
		_industry.text = "立族产业：%s · %s出身 · 创始族人 %d 人" % [
			building, profession, founders]
	var names: PackedStringArray = candidate.get("trait_display_names", PackedStringArray())
	var descriptions: PackedStringArray = candidate.get("trait_descriptions", PackedStringArray())
	var lines := PackedStringArray()
	for index in names.size():
		var description := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		lines.append("· %s%s" % [names[index],
			"：" + description if not description.is_empty() else ""])
	_traits.text = "家风：\n%s" % "\n".join(lines) if not lines.is_empty() else "家风：暂无"
	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var effect_description := String(candidate.get("effect_description", "")).strip_edges()
	if effect_name.is_empty():
		_effect.text = "家族效果：无"
	elif effect_description.is_empty():
		_effect.text = "家族效果：%s" % effect_name
	else:
		_effect.text = "家族效果：%s — %s" % [effect_name, effect_description]
	_choose.disabled = _candidate_empty
	_choose.tooltip_text = "当前没有可扶持的家族" if _candidate_empty \
		else "扶持「%s」在本地立族" % _title.text

func candidate_empty() -> bool:
	return _candidate_empty

func choose_button() -> Button:
	return _choose
