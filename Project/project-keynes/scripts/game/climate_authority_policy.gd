class_name ClimateAuthorityPolicy
extends RefCounted

## B8-4：Climate ACTIVE 的单点启用策略。
##
## 三态 override：
##   AUTO      —— 由实测阈值决定（默认）；当前无正阈值可落地时保持开启；
##   FORCE_ON  —— 无论规模都开（GM「Climate worker 权威」开）；
##   FORCE_OFF —— 无论规模都关（GM「Climate worker 权威」关）。
##
## 「按规模自动判定」GM 开关已移除：关 auto 曾被错误映射成 force_off，
## 会在运行中硬重启 worker 并堵死主线程。规模阈值仍由本策略对象持有，
## 供诊断与日后实测落地，但不再暴露成会误伤权威的玩家开关。
##
## 2026-09-11 C1/C3 尺寸阶梯实测结论（见 tools/runtime/climate_b8_soak_policy.json）：
##   60x40 / 120x80 / 180x120 在 x50 下均不满足
##   "worker p95 单日成本 ≤ 日预算且 climate_wait_ms p95 ≈ 0"。
## 因此不存在可静默落地的正阈值；产品选择在 AUTO 下保持历史默认开启
## （权威正确性优先于 x50 吞吐），诊断显式报
## `auto_measured_keep_on_no_affordable_size`。FORCE_OFF 是性能逃生口。

enum Override { AUTO = 0, FORCE_ON = 1, FORCE_OFF = 2 }

const THRESHOLD_SOURCE_MEASURED := "c1_c3_ladder_20260911_no_affordable_size_at_x50_keep_on"

var override: int = Override.AUTO
## 0 = 无正阈值可落地；AUTO 保持开启（见上）。
var threshold_cells: int = 0
var threshold_source: String = THRESHOLD_SOURCE_MEASURED
## 实测"可负担"上限；-1 表示阶梯内无一档满足。
var measured_affordable_threshold_cells: int = -1


func set_override_mode(mode: String) -> Dictionary:
	match mode:
		"auto":
			override = Override.AUTO
		"force_on":
			override = Override.FORCE_ON
		"force_off":
			override = Override.FORCE_OFF
		_:
			return {"ok": false, "code": "climate_authority_override_invalid",
				"message": "mode must be auto|force_on|force_off"}
	return {"ok": true, "code": "ok", "override": override_mode_name()}


func set_force_enabled(enabled: bool) -> void:
	override = Override.FORCE_ON if enabled else Override.FORCE_OFF


func override_mode_name() -> String:
	match override:
		Override.FORCE_ON:
			return "force_on"
		Override.FORCE_OFF:
			return "force_off"
		_:
			return "auto"


## 返回生效决策。`requested` 是会话/玩家层"想要 ACTIVE"的请求
## （WorldRuntimeHost.runtime_climate_authority_enabled），`n_cells` 是地图规模。
func resolve(requested: bool, n_cells: int) -> Dictionary:
	var enabled := requested
	var effective := override_mode_name()
	var reason := ""
	if override == Override.FORCE_OFF:
		enabled = false
		reason = "override_force_off"
	elif not requested:
		enabled = false
		reason = "session_requested_off"
	elif override == Override.FORCE_ON:
		enabled = true
		reason = "override_force_on"
	elif threshold_cells <= 0:
		# 实测无正阈值：保持历史默认开启，但诊断写明依据。
		reason = "auto_measured_keep_on_no_affordable_size"
	elif n_cells >= threshold_cells:
		enabled = true
		reason = "auto_at_or_above_threshold"
	else:
		enabled = false
		reason = "auto_below_threshold"
	if enabled and threshold_cells > 0 and n_cells < threshold_cells:
		# force_on 低于阈值是允许的，但必须可见。
		reason = reason + "_below_threshold"
	return {
		"enabled": enabled,
		"reason": reason,
		"override": effective,
		"requested": requested,
		"n_cells": n_cells,
		"threshold_cells": threshold_cells,
		"threshold_source": threshold_source,
		"measured_affordable_threshold_cells": measured_affordable_threshold_cells,
	}
