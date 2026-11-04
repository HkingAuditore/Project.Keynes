extends "res://scripts/ui/components/budget_share_slider.gd"
class_name ChannelShareSlider

## 国家购买里的通道份额滑条：时代收购、派遣储备（开拓）。
##
## 份额是「国家购买总额」——`national_daily` ——里面的占比，所以满量程恒为
## 100%。三项份额之和不得超过 100%，可拖上限由宿主按
## `100% - 科技份额 - 另一通道份额` 收窄，玩家拖到边缘就自然停在剩余额度上，
## 不需要事后弹错。
##
## 交互与绘制骨架全部来自 BudgetShareSlider（拖动即预览、松手才提交、最左端
## 关闭、键盘/手柄逐档、四态材质），这里只负责把份额折算成日额读数。

const SHARE_FULL_BP := 10000
const STEP_BP := 100
const CHANNEL_HEIGHT := 104.0
const CHANNEL_TRACK_TOP := 62.0
const CHANNEL_CONDENSED_HEIGHT := 56.0
const CHANNEL_CONDENSED_TRACK_TOP := 30.0
const CASH_SCALE := 10000.0

var _base_daily := 0
var _active := true
var _auto := false


func _init() -> void:
	configure_layout(CHANNEL_HEIGHT, CHANNEL_TRACK_TOP,
		CHANNEL_CONDENSED_HEIGHT, CHANNEL_CONDENSED_TRACK_TOP)
	configure("通道份额", &"metric.treasury", SHARE_FULL_BP, STEP_BP, "")


## title / icon 只在不紧凑的版式下显示标题行；财政页里恒用紧凑档，
## 标题由撕纸板块的板块头承担，这里不重复。
func configure_channel(title: String, icon_key: StringName) -> void:
	configure(title, icon_key, SHARE_FULL_BP, STEP_BP, "")


## share_bp：本通道份额 0..10000。
## base_daily：国家购买总额的每日额度（MONEY_SCALE），份额是它的百分比。
## active_channel：本通道当前是否有待办需求（时代收购是缺口驱动的）。
## interactive=false 时整块降透明并忽略输入，读数与说明仍可读。
## ceiling_bp：可拖上限，由三项之和约束算出。
## auto_allocated：份额仍沿用原生自动分配（滑条显示的是反推位置）。
func set_channel_state(share_bp: int, base_daily: int, active_channel: bool,
		interactive: bool, ceiling_bp: int, auto_allocated := false) -> void:
	_base_daily = maxi(0, base_daily)
	_active = active_channel
	_auto = auto_allocated
	set_ceiling_bp(ceiling_bp)
	set_share_state(share_bp, interactive, hint_text(), display_text())


## 当前份额折算出的每日额度（MONEY_SCALE）；关闭或无需求时为 0。
func daily_budget() -> int:
	if not is_enabled() or not _active:
		return 0
	return int(round(float(_base_daily) * float(share_bp()) / float(SHARE_FULL_BP)))


func is_active_channel() -> bool:
	return _active


func is_auto_allocated() -> bool:
	return _auto


## 说明文字：暂停 / 无需求 / 自动 / 占比。
func hint_text() -> String:
	if not is_interactive():
		return "暂不可用"
	if not _active:
		return "当前没有待办需求"
	if share_bp() <= 0:
		return "未分配，采购暂停"
	if _auto:
		return "自动分配 %s" % percent_text(share_bp())
	return "占国家购买 %s" % percent_text(share_bp())


## 右侧读数：每日额度。
func display_text() -> String:
	if not is_interactive():
		return ""
	if share_bp() <= 0 or not _active:
		return "暂停采购"
	return "每日 %s" % amount_text(daily_budget())


## 份额变化的钩子：拖动时读数要跟手。这里只写读数缓存，不回调 set_share_state，
## 否则会被基类的 set_share_state -> _on_share_changed 链路递归回来。
func _on_share_changed(_dragging_share: bool) -> void:
	_hint_text = hint_text()
	_value_text = display_text()
	queue_redraw()


static func amount_text(cash: int) -> String:
	return UITokens.format_compact_number_cn(float(cash) / CASH_SCALE, 2)


static func percent_text(bp: int) -> String:
	return "%.0f%%" % (float(clampi(bp, 0, SHARE_FULL_BP)) / 100.0)
