extends SceneTree


func _initialize() -> void:
	var view_model := CellInspectorViewModel.new()
	var category: Dictionary = view_model._building_category(_suspended_silver_mine_snapshot())
	var rows: Array = category.get("building_rows", [])
	if rows.size() != 1:
		_fail("loss-suspended building disappeared from the dossier")
		return
	var row: Dictionary = rows[0]
	var state: Dictionary = row.get("state_summary", {})
	var owner_job := _find_by_id(row.get("job_rows", []), "owner_job")
	var miner_job := _find_by_id(row.get("job_rows", []), "job_0")
	var finance: Dictionary = row.get("finance", {})
	if String(row.get("status", "")) != "亏损停产" \
			or String(row.get("profit_label", "")) != "状态" \
			or String(row.get("profit", "")) != "停产":
		_fail("header did not distinguish suspension from zero profit")
	elif String(owner_job.get("value", "")) != "0 / 0（物理容量 1247）":
		_fail("owner period demand did not retain physical-capacity context")
	elif not String(miner_job.get("value", "")).contains("岗位已释放"):
		_fail("employee period demand did not explain released jobs")
	elif not String(state.get("detail", "")).contains("连续亏损停产") \
			or not String(state.get("meta", "")).contains("上一经营期利润率 -50.0%") \
			or not String(state.get("meta", "")).contains("连续亏损 3 期"):
		_fail("expanded state summary omitted the cause or prior result")
	elif String(state.get("icon", "")) != "warning":
		_fail("collapsed row is missing its abnormal-state icon")
	elif not String(finance.get("warning", "")).contains("停产中"):
		_fail("zero cashflow still lacks suspension context")
	else:
		_test_loss_breakdown_model()
		print("[building-inspector-state] PASS")
		quit(0)


func _test_loss_breakdown_model() -> void:
	var dossier := CellInspectorViewModel.building_dossier_model({
		"status": "正常经营", "profit": "-1.00", "profit_float": -1.0,
		"finance": {
			"revenue": "8.00", "revenue_float": 8.0,
			"cash_revenue_float": 8.0, "cash_revenue_text": "8.00",
			"input_cost_float": 4.0, "input_cost_text": "4.00",
			"wages_cost_float": 3.0, "wages_cost_text": "3.00",
			"maintenance_float": 2.0, "maintenance_text": "2.00",
			"business_tax_float": 1.0, "business_tax_text": "1.00",
			"cost_float": 9.0, "cost": "9.00", "profit_positive": false,
		},
	})
	if not bool(dossier.get("loss_visible", false)):
		_fail("loss dossier did not expose the first-screen breakdown")
		return
	var bar: Dictionary = dossier.get("loss_diverging_bar", {})
	if absf(float(bar.get("left_value", 0.0)) - 10.0) > 0.001 \
			or absf(float(bar.get("right_value", 0.0)) - 9.0) > 0.001:
		_fail("loss comparison did not reconcile tax into gross income and total expense")
		return
	var labels := PackedStringArray()
	var segments: Array = dossier.get("loss_cost_segments", [])
	var segment_total := 0.0
	for raw_segment in segments:
		var segment: Dictionary = raw_segment
		labels.append(String(segment.get("label", "")))
		segment_total += float(segment.get("value", 0.0))
	if not labels.has("原材料成本") or not labels.has("工资成本") \
			or not labels.has("维护支出") or not labels.has("营业税费") \
			or absf(segment_total - 10.0) > 0.001:
		_fail("loss breakdown omitted a cost category or its total did not reconcile")


func _suspended_silver_mine_snapshot() -> Dictionary:
	return {
		"ok": true, "period_days": 5,
		"building_type_ids": PackedStringArray(["surface_silver_working"]),
		"building_type_display_names": PackedStringArray(["露天银矿"]),
		"building_technology_available": PackedByteArray([1]),
		"group_type_ids": PackedInt32Array([0]),
		"owner_signature_ids": PackedInt32Array([0]),
		"group_counts": PackedInt64Array([1247]),
		"owner_capacity": PackedInt64Array([1247]),
		"owner_required": PackedInt64Array([0]),
		"filled_owner": PackedInt64Array([0]),
		"owner_openings": PackedInt64Array([0]),
		"employee_fill_offsets": PackedInt32Array([0, 1]),
		"employee_profession_ids": PackedInt32Array([1]),
		"employee_required": PackedInt64Array([0]),
		"employee_filled": PackedInt64Array([0]),
		"operating_state": PackedByteArray([1]),
		"pending_operating_state": PackedByteArray([255]),
		"severe_loss_cycles": PackedInt32Array([3]),
		"recovery_cycles": PackedInt32Array([0]),
		"realized_profit_margin_q16": PackedInt32Array([-32768]),
		"planned_utilization_q16": PackedInt32Array([0]),
		"capacity_q16": PackedInt64Array([0]),
		"last_input": PackedInt64Array([0]),
		"last_output": PackedInt64Array([0]),
		"last_resource": PackedInt64Array([0]),
		"last_resource_generated": PackedInt64Array([0]),
		"last_revenue": PackedInt64Array([0]),
		"last_input_cost": PackedInt64Array([0]),
		"last_wages_paid": PackedInt64Array([0]),
		"last_wages_due": PackedInt64Array([0]),
		"last_operating_cost": PackedInt64Array([0]),
		"wage_suspended": PackedByteArray([0]),
		"building_counts_by_type": PackedInt64Array([1247]),
		"building_owner_slots": PackedInt64Array([1]),
		"signature_profession_ids": PackedInt32Array([0]),
		"profession_stable_ids": PackedStringArray(["merchant", "miner"]),
		"profession_display_names": PackedStringArray(["商人", "矿工"]),
		"building_input_offsets": PackedInt32Array([0, 0]),
		"building_input_good_ids": PackedInt32Array(),
		"building_input_quantities": PackedInt64Array(),
		"building_output_offsets": PackedInt32Array([0, 1]),
		"building_output_good_ids": PackedInt32Array([0]),
		"building_output_quantities": PackedInt64Array([2000]),
		"building_resource_offsets": PackedInt32Array([0, 0]),
		"building_production_resource_ids": PackedInt32Array(),
		"building_production_resource_quantities": PackedInt64Array(),
		"building_resource_ids": PackedStringArray(),
		"good_ids": PackedStringArray(["silver"]),
	}


func _find_by_id(rows: Array, target_id: String) -> Dictionary:
	for raw in rows:
		var row: Dictionary = raw
		if String(row.get("id", "")) == target_id:
			return row
	return {}


func _fail(message: String) -> void:
	push_error("[building-inspector-state] FAIL: %s" % message)
	quit(1)
