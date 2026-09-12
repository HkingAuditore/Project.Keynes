class_name ClimateAuthorityPolicy
extends RefCounted

## B8-4：Climate ACTIVE 的单点启用策略。
##
## 三态 override：
##   AUTO      —— 由实测阈值决定（默认）；
##   FORCE_ON  —— 无论规模都开（GM/开发调试；低于阈值时会在诊断里报
##                below_threshold，允许帧阻塞，但必须可见）；
##   FORCE_OFF —— 无论规模都关（回主线程权威）。
##
## 阈值本身必须由 C1（真实客户端帧延迟）与 C3（headless 调整后吞吐）的尺寸阶梯
## 实测得出，判据是"worker p95 单日成本 ≤ 日预算且 wait_climate_ms p95 ≈ 0 的
## 最大 cell 数，向下取整到档位"。在证据落地之前这里保持
## `threshold_cells = 0`：auto 的行为与历史默认一致（不静默改变），但诊断会明确
## 报 `auto_threshold_not_measured`，提醒这条尚未关闭。

enum Override { AUTO = 0, FORCE_ON = 1, FORCE_OFF = 2 }

const THRESHOLD_SOURCE_PROVISIONAL := "provisional_pending_c1_c3"

var override: int = Override.AUTO
var threshold_cells: int = 0
var threshold_source: String = THRESHOLD_SOURCE_PROVISIONAL


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
		# 阈值尚未实测：保持历史默认，但把"为什么没有阈值"写进诊断。
		reason = "auto_threshold_not_measured"
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
	}
