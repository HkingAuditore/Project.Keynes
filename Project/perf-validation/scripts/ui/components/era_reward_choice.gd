extends PanelContainer
class_name EraRewardChoice

signal selected()

@onready var _icon: IconBadge = %Icon
@onready var _category: Label = %Category
@onready var _title: Label = %Title
@onready var _description: Label = %Description
@onready var _target: Label = %Target
@onready var _reason: Label = %Reason
@onready var _choose: Button = %Choose

var _option_empty := true

func _ready() -> void:
	_choose.pressed.connect(func() -> void: selected.emit())

func set_option(option: Dictionary) -> void:
	_option_empty = option.is_empty()
	var icon_key := StringName(option.get("icon_key", "system.unknown"))
	_icon.set_semantic(icon_key, UITokens.ARCHIVE_BRASS)
	_category.text = String(option.get("category", "时代方案"))
	_title.text = String(option.get("title", "暂无方案"))
	_description.text = String(option.get("description", "当前没有可用的时代奖励。"))
	_target.text = "作用对象：%s" % String(option.get("target_summary", "玩家国家"))
	var reasons: PackedStringArray = option.get("reasons", PackedStringArray())
	_reason.text = "适配：%s" % "；".join(reasons) if not reasons.is_empty() else "适配：通用时代方案"
	_choose.disabled = _option_empty
	_choose.tooltip_text = "当前没有可用的时代方案" if _option_empty else "采纳「%s」" % _title.text

func option_empty() -> bool:
	return _option_empty
