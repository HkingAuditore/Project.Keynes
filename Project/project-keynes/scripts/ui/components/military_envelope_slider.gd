extends "res://scripts/ui/components/budget_share_slider.gd"
class_name MilitaryEnvelopeSlider

## 军事总预算份额滑条：每日从国库现金里拨给军队的比例。
##
## 份额口径与原生 `budget_share_bp` 一致（0..10000 = 0–100%），满量程就是
## 100%，不需要像国家购买那样另设 10% 的上限——原生校验的上界就是 10000。
## 最左端为 0，正是原生文档里「没有信封」的状态：军饷、维护与采购回落到
## 按现金与需求直接结算的旧行为。所以这里不需要额外的开关按钮，
## 「拖到最左端」本身就是关闭。
##
## 交互骨架全部来自 BudgetShareSlider（拖动即预览、松手才提交、键盘/手柄
## 逐档、四态材质），本类只负责把份额折算成每日信封额。
##
## 组件只发意图：`share_committed` 由宿主折算成
## `military.policy.set_budget {total_bp, wage_bp, upkeep_bp, procurement_bp}`。

const SHARE_FULL_BP := 10000
## 1% 一档：满量程 100 档，拖动分辨率与读数精度一致，不出现伪精度。
const STEP_BP := 100
const ENVELOPE_HEIGHT := 104.0
const ENVELOPE_TRACK_TOP := 62.0
const ENVELOPE_CONDENSED_HEIGHT := 56.0
const ENVELOPE_CONDENSED_TRACK_TOP := 30.0
const CASH_SCALE := 10000.0

var _cash := 0
var _envelope_daily := 0
## 快照里那一份份额；与滑条当前值相等时直接用运行时冻结的信封额，
## 否则（拖动中 / 刚提交未生效）按国库现金估算。
var _snapshot_bp := -1


func _init() -> void:
	configure_layout(ENVELOPE_HEIGHT, ENVELOPE_TRACK_TOP,
		ENVELOPE_CONDENSED_HEIGHT, ENVELOPE_CONDENSED_TRACK_TOP)
	configure("军事预算", &"military.banner", SHARE_FULL_BP, STEP_BP, "")


## share_bp：本份额 0..10000。
## treasury_cash：国家已提交的国库现金（MONEY_SCALE），拖动时按它估算日额。
## interactive=false 时整块降透明并忽略输入，读数仍可读。
## envelope_daily：快照里冻结的每日信封额（未启用时为 0）。
## snapshot_bp：快照里那一份份额，用于判断能否直接采信 envelope_daily。
func set_envelope_state(share_bp: int, treasury_cash: int, interactive: bool,
		envelope_daily: int, snapshot_bp := -1) -> void:
	_cash = maxi(0, treasury_cash)
	_envelope_daily = maxi(0, envelope_daily)
	_snapshot_bp = snapshot_bp
	set_share_state(share_bp, interactive, hint_text(), display_text())


## 当前份额下的每日信封额（MONEY_SCALE）；关闭时为 0。
func daily_envelope() -> int:
	if not is_enabled():
		return 0
	if _snapshot_bp == share_bp() and _envelope_daily > 0:
		return _envelope_daily
	return int(round(float(_cash) * float(share_bp()) / float(SHARE_FULL_BP)))


## 左读数：份额口径。未分配时明确写出回落到旧行为，避免被读成"军费归零"。
func hint_text() -> String:
	if not is_interactive():
		return "军事预算 · 暂不可用"
	if share_bp() <= 0:
		return "军事预算 · 未设，按现金结算"
	return "军事预算 · 占国库 %s/日" % percent_text(share_bp())


## 右读数：折算后的每日额度。
func display_text() -> String:
	if not is_interactive():
		return ""
	if share_bp() <= 0:
		return "未启用"
	return "每日 %s" % amount_text(daily_envelope())


## 份额变化的钩子：拖动时读数要跟手。只能写读数缓存，不能回调
## `set_share_state`——基类的 `set_share_state -> _on_share_changed` 会递归回来。
func _on_share_changed(_dragging_share: bool) -> void:
	_hint_text = hint_text()
	_value_text = display_text()
	queue_redraw()


static func amount_text(cash: int) -> String:
	return UITokens.format_compact_number_cn(float(maxi(0, cash)) / CASH_SCALE, 2)


static func percent_text(bp: int) -> String:
	return "%.0f%%" % (float(clampi(bp, 0, SHARE_FULL_BP)) / 100.0)
