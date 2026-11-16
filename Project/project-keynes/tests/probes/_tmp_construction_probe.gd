extends Node

# 临时探针：走真实 begin_new_game，检查营造窗口模型、原生报价与营造命令的
# 完整闭环。只打印，不改状态（除了真正下一次营造命令）。
#   PK_CONSTRUCTION_PROBE=1 <godot> --headless --path . > /tmp/construction.log 2>&1

const RUN_SECONDS := 30

var _generator: Object = null
var _scene: Node = null
var _issued := false
var _frame := 0
var _cell := -1
var _handle := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow == null:
		print("[construction-probe] GameFlowService missing")
		get_tree().quit(1)
		return
	var result: Dictionary = flow.begin_new_game(NewGameConfig.create_default())
	print("[construction-probe] begin_new_game ok=%s code=%s" % [
		str(result.get("ok", false)), str(result.get("code", ""))])
	if not bool(result.get("ok", false)):
		get_tree().quit(2)
		return
	var deadline := Time.get_ticks_msec() + RUN_SECONDS * 1000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		_frame += 1
		_scene = get_tree().current_scene
		if _generator == null:
			_generator = _find_generator()
		if not _issued and _frame > 600 and _frame % 30 == 0:
			if _ready_to_probe():
				_probe_and_issue()
		if _issued and _frame % 600 == 0:
			_report_receipts()
	print("[construction-probe] done frames=%d" % _frame)
	get_tree().quit(0)


func _find_generator() -> Object:
	var scene := get_tree().current_scene
	if scene != null:
		var host = scene.get("_world_runtime_host")
		if host == null and scene.has_method("get_world_runtime_host"):
			host = scene.call("get_world_runtime_host")
		if host != null and host.has_method("get_generator"):
			var generator = host.call("get_generator")
			if generator != null:
				return generator
	for node in get_tree().root.find_children("*", "", true, false):
		if node.has_method("get_generator"):
			var via_host = node.call("get_generator")
			if via_host != null and via_host.has_method("get_runtime_thread_report"):
				return via_host
	return null


func _economy():
	if _generator != null and _generator.has_method("get_economy_facade"):
		return _generator.call("get_economy_facade")
	return null


func _country():
	if _generator != null and _generator.has_method("get_country_facade"):
		return _generator.call("get_country_facade")
	return null


func _ui():
	if _scene == null:
		return null
	return _scene.get_node_or_null("UI")


func _ready_to_probe() -> bool:
	var economy = _economy()
	var country = _country()
	var ui = _ui()
	if economy == null or country == null or ui == null:
		return false
	var vm = ui.get("_inspector_view_model")
	if vm == null:
		return false
	_cell = _find_start_cell()
	if _cell < 0:
		return false
	var summary: Dictionary = country.cell_summary(_cell)
	_handle = int(summary.get("country_handle", 0))
	return _handle > 0


func _find_start_cell() -> int:
	if _generator != null and _generator.has_method("gameplay_start_report"):
		var report: Dictionary = _generator.call("gameplay_start_report")
		var cell := int(report.get("cell", -1))
		if cell >= 0:
			return cell
	var ui = _ui()
	if ui != null:
		var selected = ui.get("_selected_cell")
		if selected != null:
			return int(selected.get("index"))
	return -1


func _probe_and_issue() -> void:
	var economy = _economy()
	var country = _country()
	var ui = _ui()
	_issued = true
	print("[construction-probe] ---- probe at frame %d ----" % _frame)
	var pc = ui.get("_player_controller")
	var vm = ui.get("_inspector_view_model")
	var controller_handle := 0
	if pc != null:
		controller_handle = int(pc.get("_player_country_handle"))
	var summary: Dictionary = country.cell_summary(_cell)
	print("[construction-probe] cell=%d summary_handle=%s owned=%s controller_handle=%s" % [
		_cell, str(summary.get("country_handle", 0)), str(summary.get("owned", false)),
		str(controller_handle)])
	print("[construction-probe] facade configured=%s has_queue=%s has_quotes=%s" % [
		str(economy.get("_configured")),
		str(economy.get("_world_ext").has_method("queue_treasury_sponsored_build")),
		str(economy.get("_world_ext").has_method("get_treasury_construction_quotes"))])
	var ext = economy.get("_world_ext")
	var ids: PackedStringArray = economy.get("_catalog").get("building_type_ids", PackedStringArray())
	print("[construction-probe] catalog building types=%d" % ids.size())

	# 1. 窗口纸笺与目录模型
	var entry: Dictionary = vm.build_construction_entry(_cell)
	print("[construction-probe] entry=%s" % str(entry))
	var snapshot: Dictionary = economy.building_cell_snapshot(_cell)
	print("[construction-probe] snapshot ok=%s busy=%s read_view_pending=%s reason=%s type_ids=%d technology=%d kinds=%d" % [
		str(snapshot.get("ok", false)), str(snapshot.get("busy", false)),
		str(snapshot.get("read_view_pending", false)), str(snapshot.get("reason", "")),
		int((snapshot.get("building_type_ids", PackedStringArray()) as PackedStringArray).size()),
		int((snapshot.get("building_technology_available", PackedByteArray()) as PackedByteArray).size()),
		int((snapshot.get("building_kinds", PackedInt32Array()) as PackedInt32Array).size())])
	var model: Dictionary = vm.build_construction_model(_cell, "", "", "recommended", 0)
	var items: Array = model.get("items", [])
	var eligible_count := 0
	var first_eligible := ""
	var reasons := {}
	for raw in items:
		var item: Dictionary = raw
		if bool(item.get("eligible", false)):
			eligible_count += 1
			if first_eligible.is_empty():
				first_eligible = String(item.get("building_id", ""))
		var code := String(item.get("reason_code", ""))
		reasons[code] = int(reasons.get(code, 0)) + 1
	print("[construction-probe] MODEL available=%s message=%s data_pending=%s sector=%s total=%d items=%d eligible=%d reasons=%s first=%s" % [
		str(model.get("available", false)), str(model.get("message", "")),
		str(model.get("data_pending", false)), str(model.get("sector", "")),
		int(model.get("total", 0)), items.size(), eligible_count, str(reasons), first_eligible])

	# 1a. 部门索引签：military 只允许出现一次
	var sectors: Array = model.get("sectors", [])
	var military_tabs := 0
	var sector_ids_seen: Array = []
	for raw_sector in sectors:
		var sector_row: Dictionary = raw_sector
		var sid := String(sector_row.get("id", ""))
		sector_ids_seen.append(sid)
		if sid == "military":
			military_tabs += 1
	print("[construction-probe] SECTORS ids=%s military_tabs=%d" % [
		str(sector_ids_seen), military_tabs])

	# 1b. 军事部门：只列科技已解锁的档位
	var tech_ids: PackedStringArray = vm.player_technology_ids()
	var mil: Dictionary = vm.build_construction_model(_cell, "military", "", "recommended", 0)
	var mil_items: Array = mil.get("items", [])
	var mil_names: Array = []
	for raw_mil in mil_items:
		mil_names.append(String((raw_mil as Dictionary).get("building_id", "")))
	var facade = _generator.get_military_facade() if _generator != null \
		and _generator.has_method("get_military_facade") else null
	var catalog_total := -1
	var unlocked_total := -1
	if facade != null:
		var cat_rows: Array = (facade.catalog() as Dictionary).get("state_buildings", [])
		catalog_total = cat_rows.size()
		unlocked_total = 0
		for raw_cat in cat_rows:
			var tid := String((raw_cat as Dictionary).get("unlock_tech_id", ""))
			if tid.is_empty() or tech_ids.has(tid):
				unlocked_total += 1
	print("[construction-probe] MILITARY tech_resolved=%s tech_count=%d sector=%s total=%d items=%d catalog=%d unlocked=%d names=%s" % [
		str(vm.get("_technology_ids_resolved")), tech_ids.size(),
		str(mil.get("sector", "")), int(mil.get("total", 0)), mil_items.size(),
		catalog_total, unlocked_total, str(mil_names)])

	# 1c. 注入「一行已解锁 / 一行未解锁」的目录，精确验证部门签去重与科技过滤。
	# 新开局军事科技全锁，真实目录里两项都进不了列表，只能这样造出可观测场景。
	if facade != null:
		var known_tech := String(tech_ids[0]) if tech_ids.size() > 0 else ""
		var injected: Array = [
			{"id": "probe_unlocked", "name": "已解锁营", "role": 0, "tier": 1,
				"unlock_tech_id": known_tech, "capacity": 4,
				"fort_bonus": 0.0, "training_speed": 1.0},
			{"id": "probe_locked", "name": "未解锁营", "role": 1, "tier": 1,
				"unlock_tech_id": "tech.military.definitely_not_researched",
				"capacity": 0, "fort_bonus": 0.5, "training_speed": 1.0},
		]
		vm.set("_military_catalog_facade", facade)
		vm.set("_military_catalog_rows", injected)
		var inj_model: Dictionary = vm.build_construction_model(_cell, "", "", "recommended", 0)
		var inj_mil_tabs := 0
		var inj_sector_ids: Array = []
		for raw_inj_sector in (inj_model.get("sectors", []) as Array):
			var inj_sector: Dictionary = raw_inj_sector
			var inj_id := String(inj_sector.get("id", ""))
			inj_sector_ids.append(inj_id)
			if inj_id == "military":
				inj_mil_tabs += 1
		var inj_mil: Dictionary = vm.build_construction_model(_cell, "military", "", "recommended", 0)
		var inj_names: Array = []
		for raw_inj_mil in (inj_mil.get("items", []) as Array):
			inj_names.append(String((raw_inj_mil as Dictionary).get("building_id", "")))
		print("[construction-probe] INJECTED military_tabs=%d sectors=%s" % [
			inj_mil_tabs, str(inj_sector_ids)])
		print("[construction-probe] INJECTED_MILITARY sector=%s total=%d names=%s" % [
			str(inj_mil.get("sector", "")), int(inj_mil.get("total", 0)), str(inj_names)])

	# 2. 原生报价的 reason 分布（绕过 UI 过滤）
	var all_ids := PackedInt32Array()
	for i in range(ids.size()):
		all_ids.append(i)
	var quotes: Dictionary = ext.get_treasury_construction_quotes(_handle, _cell, all_ids)
	var qreasons := {}
	var codes: PackedStringArray = quotes.get("reason_codes", PackedStringArray())
	var qeligible := 0
	var qel: PackedByteArray = quotes.get("eligible", PackedByteArray())
	for value in qel:
		qeligible += int(value != 0)
	for code in codes:
		qreasons[String(code)] = int(qreasons.get(String(code), 0)) + 1
	print("[construction-probe] QUOTES ok=%s reason=%s eligible=%d/%d codes=%s" % [
		str(quotes.get("ok", false)), str(quotes.get("reason", "")),
		qeligible, codes.size(), str(qreasons)])
	# 2a. 枯枝采集营地的原生报价因由（修复前恒为 construction_resource_unavailable）
	var deadwood_idx := ids.find("deadwood_gathering_camp")
	if deadwood_idx >= 0:
		var dw_code := String(codes[deadwood_idx]) if deadwood_idx < codes.size() else "?"
		var dw_eligible := int(qel[deadwood_idx]) if deadwood_idx < qel.size() else -1
		print("[construction-probe] DEADWOOD idx=%d eligible=%s code=%s" % [
			deadwood_idx, str(dw_eligible), dw_code])

	# 3. GDScript facade 报价
	var facade_quotes: Dictionary = economy.construction_quotes(_handle, _cell, all_ids)
	var fq_items: Array = facade_quotes.get("items", [])
	var fq_eligible := 0
	for raw in fq_items:
		if bool((raw as Dictionary).get("eligible", false)):
			fq_eligible += 1
	print("[construction-probe] FACADE_QUOTES ok=%s reason=%s items=%d eligible=%d" % [
		str(facade_quotes.get("ok", false)), str(facade_quotes.get("reason", "")),
		fq_items.size(), fq_eligible])

	# 4. 真正下一次营造命令
	var target := first_eligible
	if target.is_empty() and ids.size() > 0:
		target = String(ids[0])
	if target.is_empty():
		print("[construction-probe] NO BUILDING ID -> cannot issue command")
		return
	var day := 1
	var seq := 9001
	var direct: Dictionary = economy.treasury_sponsored_build(
		_handle, _cell, StringName(target), day, seq)
	print("[construction-probe] DIRECT treasury_sponsored_build(%s)=%s" % [
		target, str(direct)])
	if pc != null:
		var cmd: Dictionary = pc.request_command(&"construction.build", {
			"cell_idx": _cell, "building_id": StringName(target),
			"ownership_policy": &"treasury_sponsored_private"})
		print("[construction-probe] COMMAND request_command(construction.build, %s)=%s" % [
			target, str(cmd)])
	# 手动驱动一次经济结算：headless 的 runtime graph 冻结，这里直接走 scalar
	# slice，让 epoch 真正 apply 命令并写出回执，才能看到被拒的具体 code。
	for slice in range(256):
		var rep: Dictionary = ext.run_economy_slice({
			"day_index": 5, "tick_index": 5000 + slice})
		if slice == 0 or bool(rep.get("done", false)) \
				or bool(rep.get("fatal", false)):
			print("[construction-probe] SLICE %d = %s" % [
				slice, str(rep).substr(0, 500)])
		if bool(rep.get("done", false)) or bool(rep.get("fatal", false)):
			break
	_report_receipts()
	if economy.has_method("economy_report"):
		var diag: Dictionary = economy.economy_report()
		print("[construction-probe] DIAG last_building_rejection_reason=%s rejected_commands=%s" % [
			str(diag.get("last_building_rejection_reason", "")),
			str(diag.get("rejected_commands", -1))])


func _report_receipts() -> void:
	var economy = _economy()
	if economy == null:
		return
	var ext = economy.get("_world_ext")
	if ext == null or not ext.has_method("get_construction_command_receipts"):
		return
	var page: Dictionary = ext.get_construction_command_receipts(0, 16)
	print("[construction-probe] RECEIPTS frame=%d ok=%s count=%s last=%s rows=%s" % [
		_frame, str(page.get("ok", false)), str(page.get("count", -1)),
		str(page.get("last_receipt_id", -1)), str(page.get("receipts", []))])
