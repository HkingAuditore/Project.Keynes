extends RefCounted

const PlannerLabels = preload("res://scripts/ui/components/colonization_planner_labels.gd")

static func _preparing_missing_text(controller, handle: int, state: int, snapshot: Dictionary = {}, include_progress: bool = true) -> String:
	if state != 4 or controller == null or not controller.has_method(
			"get_family_expedition_snapshot"):
		return ""
	var snap := snapshot
	if snap.is_empty():
		snap = controller.get_family_expedition_snapshot(handle)
	if not bool(snap.get("ok", false)):
		return ""
	var lines := PackedStringArray()
	# The party only leaves once both the survival bridge and the whole opening
	# build plan are funded, so a single percentage has to cover both. Showing
	# the bridge alone is what used to read 100% while the kit was still short.
	var bridge_required := int(snap.get("kit_bridge_required_units", 0))
	var bridge_missing := int(snap.get("kit_bridge_missing_units", 0))
	var material_required := int(snap.get("kit_material_required_units", 0))
	var material_missing := int(snap.get("kit_material_missing_units", 0))
	var required := bridge_required + material_required
	var missing := bridge_missing + material_missing
	if required > 0 and include_progress:
		lines.append("已囤积 %d%%（补给 %d%% / 建材 %d%%），每日自动收进源地可用现货" % [
			clampi(required - missing, 0, required) * 100 / required,
			_stock_percent(bridge_required, bridge_missing),
			_stock_percent(material_required, material_missing)])
	var blocker := String(snap.get("kit_blocker", ""))
	match blocker:
		"UNBUILDABLE":
			lines.append("源地无法获得开工包所需的某组建材，筹备将中止并退回托管物资")
		"NO_BUILDINGS":
			lines.append("目标地块放不下任何开工建筑，筹备无法完成")
		"READY":
			lines.append("开工包已齐套，等待出发")
		"BRIDGE":
			lines.append("仍缺旅途补给（食品、衣物或必需工具），等源地备货")
		"MATERIALS":
			lines.append("仍缺开工建材，等源地产出")
		"INCOMPLETE":
			lines.append("开工包尚未凑齐可出发的完整方案，等源地备货")
	var procurement := _procurement_status_text(controller, snap)
	if not procurement.is_empty():
		lines.append(procurement)
	var ids: PackedInt32Array = snap.get("kit_missing_good_ids", PackedInt32Array())
	var qtys: PackedInt64Array = snap.get(
		"kit_missing_good_quantities", PackedInt64Array())
	if not ids.is_empty():
		var parts := PackedStringArray()
		for i in range(ids.size()):
			var qty := int(qtys[i]) if i < qtys.size() else 0
			var good_name := "物资#%d" % int(ids[i])
			if controller.has_method("good_display_name"):
				good_name = String(controller.good_display_name(int(ids[i])))
			parts.append("%s %s 件" % [good_name,
				UITokens.format_compact_number_cn(float(qty) / 1000.0, 1)])
		lines.append("可用替代物资与源地现货：" + "，".join(parts))
	return "\n".join(lines)


static func _procurement_status_text(controller, snap: Dictionary) -> String:
	if bool(snap.get("kit_procurement_blocked_by_peer", false)):
		return "等待另一支开拓队的国库采购完成"
	if bool(snap.get("kit_procurement_pending", false)):
		return "正在用国库采购%s（第 %d 日开始）" % [
			_good_name(controller, int(snap.get("kit_procurement_good_id", -1))),
			int(snap.get("kit_procurement_started_day", -1))]
	var reason := String(snap.get("kit_procurement_rejection", ""))
	if reason.is_empty():
		return ""
	return "第 %d 日采购%s被拒：%s" % [
		int(snap.get("kit_procurement_rejected_day", -1)),
		_good_name(controller, int(snap.get("kit_procurement_rejected_good_id", -1))),
		_procurement_reason_text(reason)]


static func _good_name(controller, good_id: int) -> String:
	if good_id < 0:
		return ""
	if controller != null and controller.has_method("good_display_name"):
		return String(controller.good_display_name(good_id))
	return "物资#%d" % good_id


static func _procurement_reason_text(reason: String) -> String:
	return PlannerLabels._procurement_reason_text(reason)


static func _stock_percent(required: int, missing: int) -> int:
	if required <= 0:
		return 100
	return clampi(required - missing, 0, required) * 100 / required
