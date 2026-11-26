extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func military_map_pick(host, world: Vector2) -> bool:
	if host._ui_manager == null or not host._ui_manager.has_method("open_military_dossier"):
		return false
	var layers = host._military_layers()
	if layers == null or not layers.has_method("pick_at_world"):
		return false
	var pick: Dictionary = layers.pick_at_world(world)
	match String(pick.get("kind", "")):
		"army":
			var handle = int(pick.get("handle", 0))
			if handle == 0:
				return false
			host._military_component._apply_military_render_selection(host, handle)
			if layers.has_method("set_selected_cell"):
				layers.call("set_selected_cell", int(pick.get("cell", -1)))
			return bool(host._ui_manager.call("open_military_dossier", "army", handle,
				int(pick.get("cell", -1))))
		"front":
			var edge = int(pick.get("edge", -1))
			if edge < 0:
				return false
			host._military_component._apply_military_render_selection(host, 0)
			if layers.has_method("set_selected_front_edge"):
				layers.call("set_selected_front_edge", edge)
			return bool(host._ui_manager.call("open_military_dossier", "front", edge))
	return false


## 军务档案的战线扇区：几何与聚合都在图层侧，UI 只消费结果。

func military_front_sector(host, edge_key: int) -> Dictionary:
	var layers = host._military_layers()
	if layers == null or not layers.has_method("front_sector"):
		return {}
	return layers.call("front_sector", int(edge_key))


## 同格部队（军务档案「同格部队」名录）。空数组 = 该格只有这一支或图层未就绪。

func military_armies_at_cell(host, cell: int) -> Array:
	var layers = host._military_layers()
	if layers == null or not layers.has_method("armies_at_cell"):
		return []
	var rows = layers.call("armies_at_cell", int(cell))
	return rows if rows is Array else []


## 部队所在格（-1 = 未知）。换页时用来留住「同格部队」名录。

func military_army_cell(host, handle: int) -> int:
	var layers = host._military_layers()
	if layers == null or not layers.has_method("army_cell"):
		return -1
	return int(layers.call("army_cell", int(handle)))


## 关掉档案时同时撤掉地图上的选中态（部队选中环 / 战线高亮 / 区域与路线层）。

func clear_military_map_selection(host) -> void:
	host._military_component._apply_military_render_selection(host, 0)
	var layers = host._military_layers()
	if layers == null:
		return
	if layers.has_method("set_selected_front_edge"):
		layers.call("set_selected_front_edge", -1)
	if layers.has_method("set_selected_cell"):
		layers.call("set_selected_cell", -1)


## 把某一格移进地图安全区（不改变选中态）。军务档案打开后用它把实体带进视野。

func has_military_runtime(host) -> bool:
	var facade = host._military_facade()
	return facade != null



func _submit_military_command(host, id: StringName, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = host._military_facade()
	if facade == null:
		return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
	var entry = host._military_command_entry(id, args)
	entry["country"] = host._player_country_handle
	entry["effective_day"] = effective_day
	entry["caller_sequence"] = sequence
	if not facade.has_method(host.MILITARY_FACADE_SUBMIT_METHOD):
		return host._result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少军事命令入口。")
	# 军事运行时确定生效日。控制器保留序号用于回执对齐和显示。
	var raw = facade.call(host.MILITARY_FACADE_SUBMIT_METHOD, [entry])
	var result: Dictionary
	if raw is Dictionary:
		result = raw
	else:
		result = host._result(false, "command_rejected", "军事命令未返回结果。")
	if bool(result.get("ok", false)):
		result["code"] = String(result.get("code", "queued"))
		if not result.has("message"):
			var admitted_day := int(result.get("effective_day", -1))
			result["message"] = "军事命令已排队，第 %d 日结算。" % admitted_day \
				if admitted_day >= 0 else "军事命令已排队。"
		host._military_last_sequence = sequence
	else:
		result["message"] = command_rejection_message(String(result.get("code",
			result.get("reason", "command_rejected"))))
	return result



static func command_rejection_message(code: String) -> String:
	return {
		"technology_locked": "尚未解锁这项科技。",
		"not_own_territory": "只能编成本国可控领土上的驻军。",
		"cell_occupied": "被占领的地块不能编成部队。",
		"command_no_local_garrison": "当地没有可编成部队的驻军。",
		"command_no_training_garrison": "当地没有可用于训练的驻军。",
		"command_budget_channels_exceed_10000": "军费各项份额合计不能超过 100%。",
		"command_unknown_army": "部队已不存在。",
		"command_not_owner": "只能指挥本国部队。",
		"command_army_in_engagement": "交战中无法开始探路。",
		"military_path_unreachable": "部队与目标之间没有可通行的路线。",
		"command_bad_state_building": "建筑不在军事目录里。",
		"military_state_building_unmapped": "该建筑暂未接入营造系统。",
		"military_executor_unavailable": "军事机构尚未接通。",
		"command_shares_exceed_10000": "兵种份额合计不能超过 100%。",
	}.get(code, "军事命令未能执行（%s）。" % code)


func military_last_sequence(host) -> int:
	return host._military_last_sequence


# ─── Military army orders on the map (design §14.2) ────────────────────────
# The workspace only asks for the mode; the targeting loop lives here because
# this is where a map click becomes a cell. 地图点击只预览，档案上的确认键提交。

## `mode` is "move", "area" or "explore". Returns the same result shape as
## request_command.

func begin_military_arm_order(host, army: int, mode: String, radius: int = 1) -> Dictionary:
	var facade = host._military_facade()
	if facade == null:
		return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
	if mode == "move" and not facade.has_method("preview_path"):
		return host._result(false, "runtime_unavailable", "军事机构尚未接通：缺少路径预览入口。")
	if army <= 0:
		return host._result(false, "invalid_args", "先选一支自己的部队。")
	if mode != "move" and mode != "area" and mode != "explore":
		return host._result(false, "invalid_args", "未知的部队指令。")
	if (mode == "area" or mode == "explore") and (radius < 1 or radius > 6):
		return host._result(false, "invalid_args", "选定半径必须在 1–6 格之间。")
	host.cancel_military_arm_order()
	host._military_order_army = army
	host._military_order_mode = mode
	host._military_order_radius = radius
	host._military_order_target = -1
	if mode == "area":
		host._military_order_message = "点击地图选择控制中心，再确认区域。"
	elif mode == "explore":
		host._military_order_message = "点击地图选择探查中心，再确认探查半径。"
	else:
		host._military_order_message = "点击地图预览路线，再确认行军。"
	host._military_component._apply_military_render_selection(host, army)
	host._military_component._clear_military_path_preview(host)
	host._military_component._notify_military_arm_order(host)
	var armed = host._result(true, "ok", "在地图上点目标格。")
	armed["mode"] = mode
	armed["radius"] = radius
	return armed



func cancel_military_arm_order(host) -> void:
	if host._military_order_mode == "area" or host._military_order_mode == "explore":
		host.clear_cell_highlights()
	host._military_order_army = 0
	host._military_order_mode = ""
	host._military_order_radius = 0
	host._military_order_target = -1
	host._military_order_preview.clear()
	host._military_order_message = ""
	host._military_component._clear_military_path_preview(host)
	host._military_component._notify_military_arm_order(host)



func military_arm_order(host) -> Dictionary:
	var selected_count = 0
	var area_cells = host._military_order_preview.get("area", PackedInt32Array())
	if area_cells is PackedInt32Array:
		selected_count = (area_cells as PackedInt32Array).size()
	var ready = host._military_order_target >= 0
	return {"army": host._military_order_army, "mode": host._military_order_mode,
		"radius": host._military_order_radius, "target": host._military_order_target,
		"ready": ready,
		"message": host._military_order_message,
		"days": int(host._military_order_preview.get("days", 0)),
		"cell_count": selected_count}



func _notify_military_arm_order(host) -> void:
	if host._ui_manager != null and host._ui_manager.has_method("update_military_arm_order"):
		host._ui_manager.call("update_military_arm_order", host.military_arm_order())



func set_military_arm_order_radius(host, radius: int) -> void:
	if host._military_order_mode != "area" and host._military_order_mode != "explore":
		return
	host._military_order_radius = clampi(radius, 1, 6)
	if host._military_order_target >= 0:
		host.military_arm_order_click(host._military_order_target)
	else:
		host._military_component._notify_military_arm_order(host)


func confirm_military_arm_order(host) -> Dictionary:
	if host._military_order_target < 0:
		return host._result(false, "target_required", "先在地图上选择目标。")
	var id := &"military.army.move"
	var args := {"army": host._military_order_army, "cell": host._military_order_target}
	match host._military_order_mode:
		"area": id = &"military.army.area_control"
		"explore": id = &"military.army.explore"
	if id != &"military.army.move":
		args["radius"] = host._military_order_radius
	var sent = host.request_command(id, args)
	if bool(sent.get("ok", false)):
		host.cancel_military_arm_order()
	else:
		host._military_order_message = String(sent.get("message", "命令未能下达，请重试。"))
		host._military_component._notify_military_arm_order(host)
	return sent


## Map click while an order is pending. Returns true when the click belonged to
## the order (the caller must then not open the cell panel for it).

func military_arm_order_click(host, cell: int) -> bool:
	if host._military_order_mode.is_empty() or cell < 0:
		return false
	if host._military_order_mode == "explore":
		host._military_order_target = -1
		host._military_order_preview.clear()
		host._military_component._clear_military_path_preview(host)
		host.clear_cell_highlights()
		var explore_cells = host._military_area_cells(cell, host._military_order_radius)
		host._military_order_target = cell
		host._military_order_preview = {"area": explore_cells, "days": 0,
			"cells": PackedInt32Array()}
		host.highlight_cells(explore_cells)
		host._military_order_message = "探查范围已标出，确认后部队将自动探路并返回出发点。"
		host._military_component._notify_military_arm_order(host)
		return true
	var facade = host._military_facade()
	var preview: Dictionary = facade.preview_path(host._military_order_army, cell) \
		if facade != null and facade.has_method("preview_path") else {}
	host._military_order_target = cell
	host._military_order_preview.clear()
	host._military_component._clear_military_path_preview(host)
	if host._military_order_mode == "area":
		host.clear_cell_highlights()
	if not bool(preview.get("ok", false)):
		host._military_component._preview_failed(host, preview, cell)
		return true
	if not host._military_component._show_military_path_preview(host, preview, cell):
		host._military_order_message = "路线暂不可显示，请重新选择目标。"
		host._military_component._notify_military_arm_order(host)
		return true
	host._military_order_target = cell
	host._military_order_preview = preview.duplicate()
	if host._military_order_mode == "area":
		var cells = host._military_area_cells(cell, host._military_order_radius)
		host._military_order_preview["area"] = cells
		host.highlight_cells(cells)
		host._military_order_message = "控制范围已标出，确认后部队将执行区域控制。"
	else:
		host._military_order_message = "路线已标出；可改选目标，或确认行军。"
	host._military_component._notify_military_arm_order(host)
	return true



func _preview_failed(host, preview: Dictionary, cell: int) -> void:
	var reason = String(preview.get("reason", ""))
	var text = "这段路走不通：目标格不可达。"
	if reason == "military_path_unreachable":
		text = "这段路走不通：与部队之间没有可通行的路线。"
	host._military_order_message = text
	host._military_component._notify_military_arm_order(host)
	if host._ui_manager != null and host._ui_manager.has_method("show_transient_message"):
		host._ui_manager.call("show_transient_message", text)
	else:
		push_warning("military arm order: %s (cell %d)" % [reason, cell])



func _show_military_path_preview(host, preview: Dictionary, cell: int) -> bool:
	var layers = host._military_layers()
	if layers == null or not layers.has_method("show_path_preview"):
		push_warning("military arm order: no map layers for the path preview")
		return false
	var cells = preview.get("cells", PackedInt32Array())
	var route = PackedInt32Array()
	for value in cells:
		route.append(int(value))
	var days = int(preview.get("days", 0))
	layers.call("show_path_preview", route, PackedInt32Array(), days)
	return true



func _clear_military_path_preview(host) -> void:
	var layers = host._military_layers()
	if layers != null and layers.has_method("clear_route"):
		layers.call("clear_route")


## Centre + radius as cell indices (the same hex radius the core uses for
## army.area_control). Bounded to the command's 256-cell cap.

func _military_area_cells(host, centre: int, radius: int) -> PackedInt32Array:
	var cells = PackedInt32Array()
	var map = host._runtime_host.current_map() if host._runtime_host != null \
		and host._runtime_host.has_method("current_map") else null
	if map == null or centre < 0:
		return cells
	var neighbours: PackedInt32Array = map.neighbor_indices_packed()
	var frontier = PackedInt32Array([centre])
	var seen = {}
	seen[centre] = true
	cells.append(centre)
	for _step in range(maxi(0, radius)):
		var next = PackedInt32Array()
		for cell in frontier:
			var base = int(cell) * 6
			if base + 6 > neighbours.size():
				continue
			for direction in range(6):
				var neighbour = int(neighbours[base + direction])
				if neighbour < 0 or seen.has(neighbour):
					continue
				seen[neighbour] = true
				next.append(neighbour)
				if cells.size() < 256:
					cells.append(neighbour)
		frontier = next
	return cells



func _apply_military_render_selection(host, army: int) -> void:
	var facade = host._military_facade()
	if facade != null and facade.has_method("set_render_selection"):
		facade.call("set_render_selection", army)



func _military_layers(host):
	if host._runtime_host != null and "military_map_layers" in host._runtime_host:
		return host._runtime_host.get("military_map_layers")
	return null


## Workspace selection: ask the native snapshot to expose this army's area and
## remaining path so the area/route layers follow the selection.

func set_military_render_selection(host, army_handle: int) -> Dictionary:
	var facade = host._military_facade()
	if facade == null or not facade.has_method("set_render_selection"):
		return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
	var result: Dictionary = facade.call("set_render_selection", int(army_handle))
	return result if result is Dictionary else host._result(false, "command_rejected", "")


## Same native preview used by the targeting draft, for other UI callers.

func preview_military_path(host, army_handle: int, cell: int) -> Dictionary:
	var facade = host._military_facade()
	if facade == null or not facade.has_method("preview_path"):
		return {"ok": false, "reason": "runtime_unavailable"}
	var result = facade.call("preview_path", int(army_handle), int(cell))
	return result if result is Dictionary else {"ok": false, "reason": "command_rejected"}


## Front-edge probe for the war chapter: the render snapshot carries the per-edge
## progress byte but not the keys (they only feed MilitaryFrontLayer).

func military_front_probe(host) -> Dictionary:
	var facade = host._military_facade()
	if facade == null or not facade.has_method("render_snapshot"):
		return {"ok": false, "keys": PackedInt32Array(), "progress": PackedByteArray()}
	var snapshot = facade.call("render_snapshot", 0)
	if not (snapshot is Dictionary):
		return {"ok": false, "keys": PackedInt32Array(), "progress": PackedByteArray()}
	return {"ok": true,
		"keys": (snapshot as Dictionary).get("front_edges", PackedInt32Array()),
		"progress": (snapshot as Dictionary).get("front_progress", PackedByteArray())}


## Latest military events for the battle log (same ring as the daily system's
## cursor; this read never advances it).

func military_events_probe(host, limit: int = 512) -> Array:
	var facade = host._military_facade()
	if facade == null or not facade.has_method("poll_events"):
		return []
	var batch = facade.call("poll_events", 0, limit)
	return batch if batch is Array else []


## MilitaryBattleLogRow (the core's last 64 battles) has no bridge accessor yet,
## so there is nothing truthful to report here; the battle log falls back to the
## event ring. Report unavailable rather than invent a row.

static func battle_log_probe(host) -> Dictionary:
	return {"available": false, "reason": "military_battle_log_api_missing"}


## Truce end day with a country slot, -1 when none. The bridge has no truce
## query; the war chapter shows "正在交战" without this and must not guess a date.

static func military_truce_until(host, _slot: int) -> int:
	return -1




func _military_facade(host):
	var runtime_host = host._runtime_host
	if runtime_host == null:
		return null
	if runtime_host.has_method("get_military_facade"):
		var direct = runtime_host.get_military_facade()
		if direct != null:
			return direct
	if not runtime_host.has_method("generator"):
		return null
	var generator = runtime_host.generator()
	if generator == null or not generator.has_method("get_military_facade"):
		return null
	return generator.get_military_facade()


static func _military_command_entry(id: StringName, args: Dictionary, command_map: Dictionary) -> Dictionary:
	var entry := {"op": String(command_map[id]), "country": 0}
	match String(id):
		"military.force.set_target":
			entry["count"] = int(args.get("mode", 0))
			entry["value"] = int(args.get("value", 0))
		"military.config.set":
			var shares := {}
			shares[String(args.get("unit", ""))] = int(args.get("bp", 0))
			entry["shares"] = shares
		"military.config.set_quality_policy":
			entry["policy"] = int(args.get("policy", 0))
		"military.config.auto_retrain", "military.force.set_levy", \
				"military.config.auto_discharge":
			entry["count"] = 1 if bool(args.get("enabled", false)) else 0
		"military.barracks.pause":
			entry["cell"] = int(args.get("cell", -1))
			entry["count"] = 1 if bool(args.get("paused", false)) else 0
		"military.train":
			entry["cell"] = int(args.get("cell", -1))
			entry["unit_from"] = String(args.get("from", "militia"))
			entry["unit_to"] = String(args.get("to", ""))
			entry["count"] = int(args.get("count", 0))
		"military.state.build", "military.state.demolish":
			entry["cell"] = int(args.get("cell", -1))
			entry["unit_to"] = int(args.get("building", -1))
		"military.policy.set_wage":
			entry["count"] = int(args.get("mode", 0))
			entry["value"] = int(args.get("value", 0))
		"military.policy.set_procurement":
			entry["value"] = int(args.get("bp", 0))
		"military.policy.set_budget":
			# -1 表示本项不改；原生按未传入项沿用当前值校验三项之和 <= 100%。
			entry["value"] = int(args.get("total_bp", 0))
			entry["int_pairs"] = PackedInt32Array([
				int(args.get("wage_bp", -1)),
				int(args.get("upkeep_bp", -1)),
				int(args.get("procurement_bp", -1)),
			])
		"military.army.create":
			entry["cell"] = int(args.get("cell", -1))
			entry["units"] = args.get("units", {})
		"military.army.station", "military.army.stop", \
				"military.army.disband":
			entry["army"] = int(args.get("army", 0))
		"military.army.move":
			entry["army"] = int(args.get("army", 0))
			entry["cell"] = int(args.get("cell", -1))
		"military.army.area_control":
			entry["army"] = int(args.get("army", 0))
			entry["cell"] = int(args.get("cell", -1))
			entry["cells"] = args.get("cells", PackedInt32Array())
			entry["radius"] = int(args.get("radius", 0))
		"military.army.explore":
			entry["army"] = int(args.get("army", 0))
			entry["cell"] = int(args.get("cell", -1))
			entry["cells"] = args.get("cells", PackedInt32Array())
			entry["radius"] = int(args.get("radius", 0))
		"military.army.stance":
			entry["army"] = int(args.get("army", 0))
			entry["count"] = int(args.get("stance", 0))
		"military.war.declare":
			entry["other"] = int(args.get("target", 0))
		"military.peace.propose", "military.peace.respond":
			entry["other"] = int(args.get("war_id", 0))
			entry["terms"] = args.get("terms", [])
			if String(id) == "military.peace.respond":
				entry["count"] = 1 if bool(args.get("accept", false)) else 0
	return entry
