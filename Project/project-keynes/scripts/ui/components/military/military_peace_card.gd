extends "res://scripts/ui/components/military/military_frame_panel.gd"

## 战争页/总览里的「议和」启动卡：只读汇总 + 一个印章按钮。
##
## 议和条款不再内嵌在军事工作台里（旧 `PeaceEditor` 下线），这里只回答三个问题：
## 跟谁打、打得怎样、点了会去哪。真正的条款编辑和地图选格在 MilitaryPeaceWindow 里。
## 节点全部来自 military_peace_card.tscn，脚本只写值。

signal peace_requested(war_id: int)

var war_id := 0

@onready var _icon: IconBadge = $Box/Header/Icon
@onready var _title: Label = $Box/Header/Title
@onready var _role: Label = $Box/Header/Role
@onready var _summary: Label = $Box/Summary
@onready var _hint: Label = $Box/Hint
@onready var _action: Button = $Box/Footer/Action


func _ready() -> void:
	_icon.set_semantic(&"military.war.peace", UITokens.DOSSIER_OXBLOOD)
	_action.custom_minimum_size = Vector2(0, 30)
	_action.pressed.connect(func() -> void: peace_requested.emit(war_id))


## `data` 来自 MilitaryViewModel.war_card() + 议和摘要：
## war_id / 敌国 / 角色 / 已战日 / 战争分 / 我方占领 / 可交割格 / 冷却日。
func set_data(data: Dictionary) -> void:
	war_id = int(data.get("war_id", 0))
	_title.text = "对%s" % String(data.get("enemy_name", "敌国"))
	_role.text = String(data.get("role", ""))
	_summary.text = "已战 %d 日 · 战争分 %s · 占据 %d 格" % [
		int(data.get("days", 0)), String(data.get("score_text", "0")),
		int(data.get("occupied", 0))]
	var cooldown := int(data.get("cooldown_until", -1))
	var day := int(data.get("day", -1))
	if cooldown > day and day >= 0:
		_hint.text = "对方上次拒绝和议：第 %d 日后可再次提出。" % cooldown
	elif int(data.get("candidates", 0)) > 0:
		_hint.text = "打开窗口勾选条款，并在地图上点选要交割的占领格。"
	else:
		_hint.text = "打开窗口提出和议；我方尚未占领对方领土，只能白和平或赔款。"
	_action.disabled = war_id <= 0
	_action.tooltip_text = _hint.text if _action.disabled else "打开议和窗口"
