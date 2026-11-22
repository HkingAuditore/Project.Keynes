extends RefCounted

const MaintenancePresentation = preload("res://scripts/ui/military_maintenance_presentation.gd")

## 原始快照，输出三个通道的日均实付与招募集训的等待装备计数。
##
## `maintenance` 是维护实物化的模型（见 `_military_maintenance_model`）：`supported`、
## `summary`（聚合整数）与 `rows`（逐对象明细）。缺省 `{}` 表示「旧 DLL，没有实物维护」，
## 此时只多一个 `maintenance_is_physical = true` 的语义标记，其余维护键全 0/空。
##
## 招募本身不拨预算：这一点由 `recruitment_funded = false` 明确表达，
## 面板据此把招募行标成「不拨款」，而不是显示 0。
static func military_spending_model(snapshot: Dictionary,
		maintenance: Dictionary = {}) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"available": false}
	if not bool(snapshot.get("has_policy", false)):
		return {"available": false}
	# 30 日滑窗累计 ÷ 30。整除而非四舍五入：上报的是"至少花了这么多"。
	var payroll_30 := maxi(0, int(snapshot.get("spend_payroll_30", 0)))
	var upkeep_30 := maxi(0, int(snapshot.get("spend_upkeep_30", 0)))
	var procurement_30 := maxi(0, int(snapshot.get("spend_procurement_30", 0)))
	# 训练队列里还没拿到装备的兵：这就是"已排队但还在等"的装备需求。
	var waiting_equipment := 0
	var training_rows: Array = snapshot.get("training", [])
	if training_rows is Array:
		for row_value in training_rows:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			if bool(row.get("equipment_ready", false)):
				continue
			waiting_equipment += maxi(0, int(row.get("count", 0)))
	# ---- 维护实物化：满足率/失修/短缺由原生按 (国家, 地块, 类型) 判定 ----
	var maintenance_supported := bool(maintenance.get("supported", false))
	var summary: Dictionary = maintenance.get("summary", {}) \
		if maintenance.get("summary", null) is Dictionary else {}
	var maintenance_rows := MaintenancePresentation.maintenance_detail_rows(maintenance.get("rows", []))
	return {
		"available": true,
		"wage_paid_last_period": payroll_30 / 30,
		"maintenance_paid_last_period": upkeep_30 / 30,
		"procurement_paid_last_period": procurement_30 / 30,
		"wage_paid_window": payroll_30,
		"maintenance_paid_window": upkeep_30,
		"procurement_paid_window": procurement_30,
		"window_days": 30,
		"procurement_share_bp": clampi(
			int(snapshot.get("procurement_share_bp", 0)), 0, 10000),
		"waiting_equipment": waiting_equipment,
		"soldiers_training": maxi(0, int(snapshot.get("soldiers_training", 0))),
		# 招募与训练本身不领取军事预算：预算只覆盖军饷、维护与采购。
		"recruitment_funded": false,
		# ---- 预算信封（任务 6/7/8 的原生字段，任务 9 的可编辑 UI 直接消费）----
		# `envelope_enabled == false` 是「没有信封」：三个日额是 -1 而不是 0，
		# 表示"不设上限、跟随现金"，与"份额为 0 暂停该通道"是相反的语义。
		"envelope_enabled": bool(snapshot.get("budget_enabled", false)),
		"budget_share_bp": clampi(int(snapshot.get("budget_share_bp", 0)), 0, 10000),
		"budget_wage_bp": clampi(int(snapshot.get("budget_wage_bp", 6000)), 0, 10000),
		"budget_upkeep_bp": clampi(int(snapshot.get("budget_upkeep_bp", 2000)), 0, 10000),
		"budget_procurement_bp": clampi(
			int(snapshot.get("procurement_share_bp", 2000)), 0, 10000),
		"envelope_daily": int(snapshot.get("budget_envelope_daily", 0)),
		"wage_budget_daily": int(snapshot.get("budget_wage_daily", -1)),
		"upkeep_budget_daily": int(snapshot.get("budget_upkeep_daily", -1)),
		"procurement_budget_daily": int(snapshot.get("budget_procurement_daily", -1)),
		# ---- 上一轮结算结果（任务 7/8）----
		# 军饷与维护是高优先级：超支是允许的，用 `*_overspend` 画铁锈红。
		# 采购是低优先级：绝不超支，被配额截断的部分在 `procurement_deferred_units`
		# 里，面板用「待购」而不是「超支」标示。
		"wage_demand": maxi(0, int(snapshot.get("budget_wage_demand", 0))),
		"wage_arrears": maxi(0, int(snapshot.get("budget_wage_arrears", 0))),
		"wage_overspend": maxi(0, int(snapshot.get("budget_wage_overspend", 0))),
		"upkeep_demand": maxi(0, int(snapshot.get("budget_upkeep_demand", 0))),
		"upkeep_arrears": maxi(0, int(snapshot.get("budget_upkeep_arrears", 0))),
		"upkeep_overspend": maxi(0, int(snapshot.get("budget_upkeep_overspend", 0))),
		"procurement_used": maxi(0, int(snapshot.get("budget_procurement_used", 0))),
		"procurement_deferred_units": maxi(0,
			int(snapshot.get("budget_procurement_deferred_units", 0))),
		# ---- 维护实物化（D7 / S4-6）----
		# 「维护」通道从此描述**实物维修采购**：国库付给商人换维修材料，材料到货后
		# 才计入满足率。`maintenance_paid_last_period` 仍是「实际结算的维护花费」
		# （30 日窗口 ÷ 30），来源不变；下面这组键描述的是这笔钱买到的实物结果。
		"maintenance_is_physical": true,
		"maintenance_supported": maintenance_supported,
		"maintenance_ratio_bp": clampi(
			int(summary.get("weighted_ratio_bp", 0)), 0, 10000),
		"maintenance_disrepair_rows": maxi(0, int(summary.get("disrepair_rows", 0))),
		"maintenance_shortage_rows": maxi(0, int(summary.get("shortage_rows", 0))),
		"maintenance_object_rows": maxi(0, int(summary.get("rows", 0))),
		"maintenance_need_goods": maxi(0, int(summary.get("need_goods", 0))),
		"maintenance_stock_goods": maxi(0, int(summary.get("stock_goods", 0))),
		"maintenance_inbound_goods": maxi(0, int(summary.get("inbound_goods", 0))),
		# 逐对象明细（已按短缺优先排序）。面板只画前 N 条，但整表留在这里，
		# 「为什么是 0 座失修」这类追问不用再去查原生。
		"maintenance_rows": maintenance_rows,
		# 一行摘要的变更签名：维护读数天天变，财政页的节流比较需要它。
		"maintenance_signature": MaintenancePresentation.maintenance_signature(maintenance_rows, summary),
	}
