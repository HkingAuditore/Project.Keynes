extends "res://scripts/ui/components/budget_share_slider.gd"
class_name MilitaryChannelSlider

## 军事信封内的通道占比滑条：军饷 / 建筑维护 / 装备与给养采购。
##
## 份额是「军事信封」——`budget_share_bp × 国库现金` ——里面的占比，所以
## 满量程恒为 100%。三项份额之和不得超过 100%，可拖上限由宿主按
## `100% - 另两项份额` 收窄，玩家拖到边缘就自然停在剩余额度上，
## 不需要事后弹错；原生 `policy.set_budget` 的同一约束因此永远不会被触发。
##
## 与时代收购 / 开拓那两条通道的区别在结算语义，这也是本类存在的理由：
## 军饷与建筑维护是高优先级（需求 7.1），需求超过份额时允许超支，用铁锈红
## 与「超支」标签标出；装备与给养采购是低优先级（需求 7.2），永不超支，
## 被配额截断的部分标「待购」而不是「超支」。把两种标记硬塞进一个通用
## 组件会让语义互相污染，所以这里自带状态读数。
##
## 交互与绘制骨架仍然全部来自 BudgetShareSlider。注意不要重复声明基类已有的
## 成员（`_interactive` / `_max_bp` / `_step_bp` / `_warn` 等）——子类同名变量会
## 遮蔽父类那份，基类的 `is_interactive()` 将永远读到旧值。

const SHARE_FULL_BP := 10000
const STEP_BP := 100
const CHANNEL_HEIGHT := 104.0
const CHANNEL_TRACK_TOP := 62.0
const CHANNEL_CONDENSED_HEIGHT := 56.0
const CHANNEL_CONDENSED_TRACK_TOP := 30.0
const CASH_SCALE := 10000.0

## 通道类型：高优先级允许超支，低优先级只截断。
const KIND_WAGE := "wage"
const KIND_UPKEEP := "upkeep"
const KIND_PROCUREMENT := "procurement"

var _envelope_daily := 0
var _kind := KIND_WAGE
## 上一轮结算：需求、超支额（高优先级）、待购件数（低优先级）。
var _demand := 0
var _overspend := 0
var _deferred_units := 0


func _init() -> void:
	configure_layout(CHANNEL_HEIGHT, CHANNEL_TRACK_TOP,
		CHANNEL_CONDENSED_HEIGHT, CHANNEL_CONDENSED_TRACK_TOP)
	configure("通道份额", &"military.banner", SHARE_FULL_BP, STEP_BP, "")


## title 只在不紧凑的版式下显示标题行；财政页里恒用紧凑档，
## 标题由板块内的结算行承担，这里不重复。
func configure_channel(title: String, icon_key: StringName, kind: String) -> void:
	_kind = kind
	configure(title, icon_key, SHARE_FULL_BP, STEP_BP, "")


## share_bp：本通道份额 0..10000。
## envelope_daily：军事每日信封额（MONEY_SCALE），份额是它的百分比。
## editable=false 时整块降透明并忽略输入，读数与说明仍可读。
## ceiling_bp：可拖上限，由三项之和约束算出；传 -1 表示不约束。
## demand / overspend / deferred_units：上一轮结算结果，用于铁锈红与标签。
func set_channel_state(share_bp: int, envelope_daily: int, editable: bool,
		ceiling_bp: int, demand := 0, overspend := 0, deferred_units := 0) -> void:
	_envelope_daily = maxi(0, envelope_daily)
	_demand = maxi(0, demand)
	_overspend = maxi(0, overspend)
	_deferred_units = maxi(0, deferred_units)
	set_ceiling_bp(ceiling_bp)
	set_share_state(share_bp, editable, hint_text(), display_text(), _is_over_budget())


## 当前份额折算出的每日额度（MONEY_SCALE）；份额为 0 时该通道暂停。
func daily_budget() -> int:
	if not is_enabled():
		return 0
	return int(round(float(_envelope_daily) * float(share_bp()) / float(SHARE_FULL_BP)))


func channel_kind() -> String:
	return _kind


## 高优先级通道（军饷、维护）才有超支；低优先级只报告待购。
func is_high_priority() -> bool:
	return _kind != KIND_PROCUREMENT


## 是否处于超支态：高优先级通道的上一轮实付越过了份额上限。
func is_overspent() -> bool:
	return is_high_priority() and _overspend > 0


## 是否处于待购态：低优先级通道的配额被截断且仍有缺口。
func has_deferred() -> bool:
	return not is_high_priority() and _deferred_units > 0


## 上一轮需求额（MONEY_SCALE），超支时右读数改成它，因为那才是花掉的钱。
func demand_amount() -> int:
	return _demand


## 左读数：份额口径 + 该通道的结算状态。
func hint_text() -> String:
	if not is_interactive():
		if share_bp() <= 0:
			return "未分配，该通道暂停"
		return "占军费 %s" % percent_text(share_bp())
	if share_bp() <= 0:
		return "未分配，该通道暂停"
	var base := "占军费 %s" % percent_text(share_bp())
	if is_overspent():
		return "%s · 超支 %s" % [base, amount_text(_overspend)]
	if has_deferred():
		return "%s · 待购 %d 件" % [base, _deferred_units]
	return base


## 右读数：每日额度；超支时改显上一轮需求量。
func display_text() -> String:
	if not is_interactive():
		return ""
	if share_bp() <= 0:
		return "暂停"
	if is_overspent():
		return "实付 %s" % amount_text(_demand)
	return "每日 %s" % amount_text(daily_budget())


## 份额变化的钩子：拖动时读数要跟手。只能写读数缓存，不能回调
## `set_share_state`——基类的 `set_share_state -> _on_share_changed` 会递归回来。
func _on_share_changed(_dragging_share: bool) -> void:
	_hint_text = hint_text()
	_value_text = display_text()
	set_warn(_is_over_budget())
	queue_redraw()


## 只有高优先级通道在"份额不够"时才算告警：采购从不超支，画成告警会误导。
func _is_over_budget() -> bool:
	return is_interactive() and is_overspent()


static func amount_text(cash: int) -> String:
	return UITokens.format_compact_number_cn(float(maxi(0, cash)) / CASH_SCALE, 2)


static func percent_text(bp: int) -> String:
	return "%.0f%%" % (float(clampi(bp, 0, SHARE_FULL_BP)) / 100.0)
