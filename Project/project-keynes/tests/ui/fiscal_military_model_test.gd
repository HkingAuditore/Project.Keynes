extends SceneTree

## 国库页（经济章）军费板块的数据通路。
##
## 回归的缺陷：经济章的 `CountryViewModel.build("economy")` 从不装配 `military`
## 段，财政页拿到空字典 → 军事板块永远显示「暂不可用 / 军事账目尚未就绪」。
## 2026-11-20 玩家截图里的红框就是这个（与「招不了兵」无关，但同样会让玩家以为
## 军事系统没起来）。
##
## 这里钉三件事：
##   1. `build_military_spending_model()` 产出的键集合能让财政页/板块直接用；
##   2. 原生快照缺席、没有政策槽、快照报错这三种情况都给出可读原因，而不是空字典；
##   3. 板块拿到这段模型后 `is_available()` 为真（也就是不会再画那句占位）。

const ViewModelScript = preload("res://scripts/ui/country_view_model.gd")
const BlockScript = preload("res://scripts/ui/components/military_spending_block.gd")

var _failures := 0


class GeneratorStub extends RefCounted:
	var facade = null

	func get_military_facade():
		return facade


class FacadeStub extends RefCounted:
	var snapshot: Dictionary = {}
	var summary: Dictionary = {}
	var supported := true

	func country_snapshot(_country: int) -> Dictionary:
		return snapshot

	func maintenance_supported() -> bool:
		return supported

	func maintenance_summary(_country: int) -> Dictionary:
		return summary

	func maintenance_snapshot(_country: int) -> Array:
		return []


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error(label)


## 原生 `get_military_country_snapshot` 的最小可用集合（字段名必须与桥一致）。
static func _snapshot() -> Dictionary:
	return {
		"ok": true, "has_policy": true, "country_slot": 0,
		"target_mode": 0, "target_value": 0, "effective_target": 0, "per_soldier_cost": 5462,
		"daily_wage": 5462, "soldiers_total": 0, "soldiers_training": 0,
		"budget_enabled": true, "budget_share_bp": 3000,
		"budget_wage_bp": 6000, "budget_upkeep_bp": 2000,
		"budget_envelope_daily": 12000, "budget_wage_daily": 7200,
		"budget_upkeep_daily": 2400, "budget_procurement_daily": 2400,
		"spend_payroll_30": 9000, "spend_upkeep_30": 3000, "spend_procurement_30": 3000,
		"budget_wage_demand": 7200, "budget_wage_overspend": 0, "budget_wage_arrears": 0,
		"budget_upkeep_demand": 2400, "budget_upkeep_overspend": 0,
		"budget_upkeep_arrears": 0, "budget_procurement_used": 2400,
		"budget_procurement_deferred_units": 0,
		"procurement_share_bp": 2000, "training": [],
	}


func _run() -> void:
	# ---- 1. 正常快照：板块可读，三条通道的日均实付按 30 日窗口折好 ----
	var vm = ViewModelScript.new()
	var generator := GeneratorStub.new()
	var facade := FacadeStub.new()
	facade.snapshot = _snapshot()
	facade.summary = {"weighted_ratio_bp": 9000, "disrepair_rows": 1, "rows": 2}
	generator.facade = facade
	vm._generator = generator
	var model := {}
	var section: Dictionary = vm.build_military_spending_model(42, model)
	_expect("economy model carries the military section",
		model.get("military", null) is Dictionary and not (model["military"] as Dictionary).is_empty())
	_expect("fiscal military section is available", bool(section.get("available", false)))
	_expect("fiscal military section keeps the envelope state",
		bool(section.get("envelope_enabled", false))
			and int(section.get("budget_share_bp", -1)) == 3000)
	_expect("fiscal military section folds the 30-day window into a daily average",
		int(section.get("wage_paid_last_period", -1)) == 300
			and int(section.get("maintenance_paid_last_period", -1)) == 100
			and int(section.get("procurement_paid_last_period", -1)) == 100)
	_expect("fiscal military section carries the maintenance detail",
		bool(section.get("maintenance_supported", false))
			and int(section.get("maintenance_ratio_bp", -1)) == 9000
			and int(section.get("maintenance_disrepair_rows", -1)) == 1)
	_expect("fiscal military section publishes a reason slot",
		section.has("reason") and String(section["reason"]).is_empty())

	# 板块拿这份模型必须从占位态切到读数态（`available` + 信封已启用）。
	var block = BlockScript.new()
	block.set_state(section)
	_expect("spending block leaves the placeholder with the fiscal model",
		block.is_available() and block.is_envelope_enabled())
	block.free()

	# ---- 2. 会话没有军事 facade：给出可读原因，而不是空字典 ----
	var no_facade_vm = ViewModelScript.new()
	no_facade_vm._generator = GeneratorStub.new()
	var no_facade_model := {}
	var missing: Dictionary = no_facade_vm.build_military_spending_model(42, no_facade_model)
	_expect("missing facade degrades to an unavailable section",
		not bool(missing.get("available", true)))
	_expect("missing facade explains itself",
		not String(missing.get("reason", "")).is_empty())

	# ---- 3. 快照正常但没有政策槽：同样要有原因（不能静默 0 值） ----
	var no_policy_facade := FacadeStub.new()
	no_policy_facade.snapshot = _snapshot()
	no_policy_facade.snapshot["has_policy"] = false
	var no_policy_generator := GeneratorStub.new()
	no_policy_generator.facade = no_policy_facade
	var no_policy_vm = ViewModelScript.new()
	no_policy_vm._generator = no_policy_generator
	var no_policy_model := {}
	var blocked: Dictionary = no_policy_vm.build_military_spending_model(42, no_policy_model)
	_expect("country without a policy slot is unavailable",
		not bool(blocked.get("available", true)))
	_expect("country without a policy slot is explained",
		not String(blocked.get("reason", "")).is_empty())

	# ---- 4. 原生报错：原因要原样带出来（面板据此提示） ----
	var error_facade := FacadeStub.new()
	error_facade.snapshot = {"ok": false, "reason": "military_country_slot_unknown"}
	var error_generator := GeneratorStub.new()
	error_generator.facade = error_facade
	var error_vm = ViewModelScript.new()
	error_vm._generator = error_generator
	var error_model := {}
	var failed: Dictionary = error_vm.build_military_spending_model(42, error_model)
	_expect("native refusal keeps its reason",
		not bool(failed.get("available", true))
			and String(failed.get("reason", "")).contains("military_country_slot_unknown"))

	print("fiscal military model: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
