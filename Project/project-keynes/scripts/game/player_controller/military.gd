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
			host._apply_military_render_selection(handle)
			if layers.has_method("set_selected_cell"):
				layers.call("set_selected_cell", int(pick.get("cell", -1)))
			return bool(host._ui_manager.call("open_military_dossier", "army", handle,
				int(pick.get("cell", -1))))
		"front":
			var edge = int(pick.get("edge", -1))
			if edge < 0:
				return false
			host._apply_military_render_selection(0)
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
	host._apply_military_render_selection(0)
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


## 官营建筑（兵营 / 城防 / 军校）的玩家侧闸门：科技必须已研究，且只能在本国、
## 未被占领的领土上营造。原生 `state.build` 对 AI 与自测保持宽松，所以玩家边界
## 在这里拦一次，避免旧 UI 缓存或脚本绕过科技门槛。
## `demolishing` 为真时跳过科技检查：占领来的高阶城防也得能拆。

func _state_building_gate(host, cell: int, building: int,
		demolishing: bool = false) -> Dictionary:
	var facade = host._military_facade()
	if facade == null:
		return {"ok": false, "code": "runtime_unavailable", "message": "军事机构尚未接通。"}
	var catalog: Dictionary = facade.catalog() if facade.has_method("catalog") else {}
	var rows: Array = catalog.get("state_buildings", []) if catalog.get(
		"state_buildings", null) is Array else []
	if building < 0 or building >= rows.size() or not rows[building] is Dictionary:
		return {"ok": false, "code": "invalid_args", "message": "建筑不在军事目录里。"}
	var row: Dictionary = rows[building]
	var tech_id = String(row.get("unlock_tech_id", ""))
	if not demolishing and not tech_id.is_empty():
		var researched = host._completed_technology_ids()
		if researched == null:
			return {"ok": false, "code": "technology_unknown",
				"message": "科技状态暂不可读，稍后再试。"}
		if not (researched as PackedStringArray).has(tech_id):
			return {"ok": false, "code": "technology_locked",
				"message": "尚未解锁这项科技。"}
	var country_facade = host._country_facade
	if country_facade != null and country_facade.has_method("cell_summary"):
		var summary: Dictionary = country_facade.cell_summary(cell)
		if bool(summary.get("ok", false)):
			if not bool(summary.get("owned", false)) \
					or int(summary.get("country_handle", 0)) != host._player_country_handle:
				return {"ok": false, "code": "not_own_territory",
					"message": "只能在自家领土上营造。"}
	return {"ok": true}



func _player_owns_military_cell(host, cell: int) -> Dictionary:
	var country_facade = host._country_facade
	if country_facade == null or not country_facade.has_method("cell_summary"):
		return {"ok": false, "code": "country_unavailable", "message": "国家领土数据暂不可读。"}
	var summary: Dictionary = country_facade.cell_summary(cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)) \
			or int(summary.get("country_handle", 0)) != host._player_country_handle:
		return {"ok": false, "code": "not_own_territory", "message": "只能编成本国可控领土上的驻军。"}
	var military = host._military_facade()
	if military == null or not military.has_method("cell_snapshot"):
		return {"ok": false, "code": "military_unavailable", "message": "军事数据暂不可读。"}
	var snapshot: Dictionary = military.cell_snapshot(cell, host._player_country_handle)
	if not bool(snapshot.get("ok", false)) \
			or int(snapshot.get("controller_slot", -1)) != int(snapshot.get("owner_slot", -2)):
		return {"ok": false, "code": "cell_occupied", "message": "被占领的地块不能编成部队。"}
	return {"ok": true}


## 玩家已完成的科技稳定 id。读不到国家快照时返回 null（调用方据此拒绝而不是放行）。

func _completed_technology_ids(host):
	var country_facade = host._country_facade
	if country_facade == null or not country_facade.has_method("snapshot"):
		return null
	if host._player_country_handle <= 0:
		return null
	var country: Dictionary = country_facade.snapshot(host._player_country_handle)
	if not bool(country.get("ok", false)):
		return null
	var ids = country.get("technology_ids", null)
	return ids if ids is PackedStringArray else PackedStringArray()


## 把面板参数翻译成契约 §2 的命令项。缺省字段留空，由 facade/原生侧给默认。

func _submit_state_build_command(host, args: Dictionary, effective_day: int,
		sequence: int) -> Dictionary:
	var facade = host._military_facade()
	if facade == null:
		return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
	var building = int(args.get("building", -1))
	var cell = int(args.get("cell", -1))
	if not facade.has_method("state_building_economy_id"):
		return host._result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少官营建筑目录。")
	var economy_type = int(facade.state_building_economy_id(building))
	if economy_type < 0:
		return host._result(false, "military_state_building_unmapped",
			"该项官营建筑尚未接入经济目录，暂时无法营造。")
	if host._economy_facade == null or not host._economy_facade.has_method(
			"treasury_sponsored_build"):
		return host._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	var economy_ids = PackedStringArray()
	if host._economy_facade.has_method("building_type_ids"):
		economy_ids = host._economy_facade.building_type_ids()
	if economy_type >= economy_ids.size():
		return host._result(false, "military_state_building_unmapped",
			"该项官营建筑与经济目录不一致，暂时无法营造。")
	var building_id = StringName(economy_ids[economy_type])
	var paid: Dictionary = host._economy_facade.treasury_sponsored_build(
		host._player_country_handle, cell, building_id, effective_day, sequence)
	if not bool(paid.get("ok", false)):
		var code = String(paid.get("code", paid.get("reason", "command_rejected")))
		var message = String(paid.get("message", ""))
		if message.is_empty() or message == code:
			message = "营造未能下单，请稍后重试。"
		return host._result(false, code, message)
	var forwarded = host._submit_military_command(host.COMMAND_MILITARY_STATE_BUILD,
		args, effective_day, sequence)
	if not bool(forwarded.get("ok", false)):
		# The economy already accepted (and will settle) the lot, so a military
		# bookkeeping failure must not read like "nothing happened": report the
		# economy code and say the schedule still lands.
		var forwarded_code = String(forwarded.get("code", "command_rejected"))
		var out = host._result(false, forwarded_code,
			"营造已由国库出资排队，但军事排期未能登记。")
		out["economy_code"] = String(paid.get("code", "construction_queued"))
		return out
	var settled = host._result(true, "construction_queued",
		"营造已由国库出资排队，将在下一个经济结算边界执行。")
	settled["building_id"] = String(building_id)
	settled["economy_sequence"] = sequence
	return settled


## 拆除是营造的镜像：先让经济账本把这座建筑减掉，再让军事侧记账。
## 顺序不能反——官营建筑组的座数是唯一账本，军事侧只是它的派生缓存，
## 若先发军事命令，军事侧会报出一座账本里已经不存在的建筑。
##
## 与营造一样，`economy_building_id` 只是编译期坐标，这里反查回稳定 id
## 再交给经济外观层重新解析。

func _submit_state_demolish_command(host, args: Dictionary, effective_day: int,
		sequence: int) -> Dictionary:
	var facade = host._military_facade()
	if facade == null:
		return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
	var building = int(args.get("building", -1))
	var cell = int(args.get("cell", -1))
	if not facade.has_method("state_building_economy_id"):
		return host._result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少官营建筑目录。")
	var economy_type = int(facade.state_building_economy_id(building))
	if economy_type < 0:
		return host._result(false, "military_state_building_unmapped",
			"该项官营建筑尚未接入经济目录，暂时无法拆除。")
	if host._economy_facade == null or not host._economy_facade.has_method(
			"treasury_sponsored_demolish"):
		return host._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	var economy_ids = PackedStringArray()
	if host._economy_facade.has_method("building_type_ids"):
		economy_ids = host._economy_facade.building_type_ids()
	if economy_type >= economy_ids.size():
		return host._result(false, "military_state_building_unmapped",
			"该项官营建筑与经济目录不一致，暂时无法拆除。")
	var building_id = StringName(economy_ids[economy_type])
	# 一次拆一座：行内拆除键的语义就是「减掉这一座」，批量拆除没有入口，
	# 也就不需要在这里替玩家猜一个数量。
	var removed: Dictionary = host._economy_facade.treasury_sponsored_demolish(
		host._player_country_handle, cell, building_id, 1, effective_day, sequence)
	if not bool(removed.get("ok", false)):
		var code = String(removed.get("code", removed.get("reason", "command_rejected")))
		var message = String(removed.get("message", ""))
		if message.is_empty() or message == code:
			message = "拆除未能下单，请稍后重试。"
		return host._result(false, code, message)
	var forwarded = host._submit_military_command(host.COMMAND_MILITARY_STATE_DEMOLISH,
		args, effective_day, sequence)
	if not bool(forwarded.get("ok", false)):
		# 经济侧已经受理（并会在下一个结算边界减掉座数），所以军事记账失败
		# 不能读成「什么都没发生」。
		var forwarded_code = String(forwarded.get("code", "command_rejected"))
		var out = host._result(false, forwarded_code,
			"拆除已由经济账本受理，但军事侧记账未能登记。")
		out["economy_code"] = String(removed.get("code", "demolish_queued"))
		return out
	var settled = host._result(true, "demolish_queued",
		"拆除已排队，将在下一个经济结算边界执行。")
	settled["building_id"] = String(building_id)
	settled["economy_sequence"] = sequence
	return settled



func _submit_military_command(host, id: StringName, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = host._military_facade()
	if facade == null:
		return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
	var entry = host._military_command_entry(id, args)
	entry["country"] = host._player_country_handle
	if not facade.has_method(host.MILITARY_FACADE_SUBMIT_METHOD):
		return host._result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少军事命令入口。")
	# 命令在下一游戏日生效由军事运行时自己排期；控制器只负责把玩家意图
	# 交出去、保留自己的 sequence 以便回执对齐，并把拒绝理由翻成玩家话。
	var raw = facade.call(host.MILITARY_FACADE_SUBMIT_METHOD, [entry])
	var result: Dictionary
	if raw is Dictionary:
		result = raw
	else:
		result = host._result(false, "command_rejected", "军事命令未返回结果。")
	if bool(result.get("ok", false)):
		result["code"] = String(result.get("code", "queued"))
		if not result.has("message"):
			result["message"] = "军事命令已排队，将在下一游戏日生效。"
		host._military_last_sequence = sequence
		if id == host.COMMAND_MILITARY_BUDGET:
			host._remember_military_budget(args)
	return result



func military_last_sequence(host) -> int:
	return host._military_last_sequence


## 命令成功后记下玩家这次真正改动的项。`-1` 表示「本次不改」，绝不覆盖已有值，
## 否则拖一次军饷滑条就会把另外两个通道的既有份额清空。

func _remember_military_budget(host, args: Dictionary) -> void:
	var total = int(args.get("total_bp", 0))
	if total < 0:
		return
	host._military_budget_state["total_bp"] = total
	for key in ["wage_bp", "upkeep_bp", "procurement_bp"]:
		if not args.has(key):
			continue
		var value = int(args[key])
		if value >= 0:
			host._military_budget_state[key] = value


## 读档恢复：先接受存档里的份额，再尝试重推。重推失败不算错误——玩家国家句柄
## 或军事 facade 可能还没接上，`refresh_country_binding()` 会再试一次。

func _restore_military_budget(host, state) -> void:
	host._military_budget_state = {
		"total_bp": -1, "wage_bp": -1, "upkeep_bp": -1, "procurement_bp": -1,
	}
	if state is Dictionary:
		var restored: Dictionary = state
		for key in ["total_bp", "wage_bp", "upkeep_bp", "procurement_bp"]:
			host._military_budget_state[key] = int(restored.get(key, -1))
	host._military_budget_repushed = false
	host._repush_military_budget()


## 把会话里记住的份额原样推回原生。原生这三个字段是 transient（读档归零），
## 不重推就等于玩家读档后预算控制静默失效。
##
## 返回 true 表示「已推成功」或「本来就没有可推的」；false 表示环境还没就绪，
## 调用方（`refresh_country_binding`）应在绑定完成后重试。

func _repush_military_budget(host) -> bool:
	if host._military_budget_repushed:
		return true
	if int(host._military_budget_state.get("total_bp", -1)) < 0:
		# 玩家从未设过预算，原生保持无信封，这正是存档前的状态。
		host._military_budget_repushed = true
		return true
	if host._player_country_handle <= 0 or host._military_facade() == null:
		return false
	var args = {"total_bp": int(host._military_budget_state.get("total_bp", 0))}
	for key in ["wage_bp", "upkeep_bp", "procurement_bp"]:
		args[key] = int(host._military_budget_state.get(key, -1))
	var result: Dictionary = host._submit_military_command(host.COMMAND_MILITARY_BUDGET,
		args, host._next_effective_day(), host._allocate_command_sequence())
	if not bool(result.get("ok", false)):
		return false
	host._military_budget_repushed = true
	return true


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
	var detail: Dictionary = facade.army(army)
	if not bool(detail.get("ok", false)) or int(detail.get("owner_slot", -1)) != \
			int(host._player_country_handle & 0xFFFFFFFF):
		return host._result(false, "not_owner", "只能指挥本国部队。")
	if mode == "explore" and int(detail.get("engagement", -1)) >= 0:
		return host._result(false, "army_in_engagement", "交战中无法开始探路。")
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
	host._apply_military_render_selection(army)
	host._clear_military_path_preview()
	host._notify_military_arm_order()
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
	host._clear_military_path_preview()
	host._notify_military_arm_order()



func military_arm_order(host) -> Dictionary:
	var selected_count = 0
	var area_cells = host._military_order_preview.get("area", PackedInt32Array())
	if area_cells is PackedInt32Array:
		selected_count = (area_cells as PackedInt32Array).size()
	var ready = host._military_order_target >= 0 and (
		selected_count > 0 if host._military_order_mode == "explore" \
		else not host._military_order_preview.is_empty())
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
		host._notify_military_arm_order()


## 确认时重算路径；快进期间部队位置、领土和通行条件都可能改变。

func confirm_military_arm_order(host) -> Dictionary:
	if host._military_order_target < 0:
		return host._result(false, "target_required", "先在地图上选择目标。")
	if host._military_order_mode != "explore" and host._military_order_preview.is_empty():
		return host._result(false, "target_required", "先在地图上选择可达的目标。")
	var target = host._military_order_target
	host.military_arm_order_click(target)
	if host._military_order_preview.is_empty():
		return host._result(false, "target_unreachable", host._military_order_message)
	if host._military_order_mode == "explore":
		var explore_cells = host._military_order_preview.get("area", PackedInt32Array())
		if not explore_cells is PackedInt32Array \
				or (explore_cells as PackedInt32Array).is_empty() \
				or (explore_cells as PackedInt32Array).size() > 256:
			return host._result(false, "area_required", "探查范围为空，请重新选择中心。")
		var facade = host._military_facade()
		if facade == null:
			return host._result(false, "runtime_unavailable", "军事机构尚未接通。")
		var detail: Dictionary = facade.army(host._military_order_army)
		if not bool(detail.get("ok", false)) or int(detail.get("owner_slot", -1)) != \
				int(host._player_country_handle & 0xFFFFFFFF):
			return host._result(false, "not_owner", "部队已不属于本国，探路命令未下达。")
		if int(detail.get("engagement", -1)) >= 0:
			return host._result(false, "army_in_engagement", "部队已进入交战，探路命令未下达。")
		var explore_sent = host.request_command(host.COMMAND_MILITARY_ARMY_EXPLORE, {
			"army": host._military_order_army,
			"cell": target,
			"cells": explore_cells,
			"radius": host._military_order_radius,
		})
		if bool(explore_sent.get("ok", false)):
			host.cancel_military_arm_order()
		else:
			host._military_order_message = String(explore_sent.get("message",
				"命令未能下达，请重试。"))
			host._notify_military_arm_order()
		return explore_sent
	var id = host.COMMAND_MILITARY_AREA_CONTROL if host._military_order_mode == "area" \
		else host.COMMAND_MILITARY_ARMY_MOVE
	var args = {"army": host._military_order_army, "cell": target}
	if host._military_order_mode == "area":
		args["cells"] = host._military_order_preview.get("area", PackedInt32Array())
		args["radius"] = host._military_order_radius
	var sent = host.request_command(id, args)
	if bool(sent.get("ok", false)):
		host.cancel_military_arm_order()
	else:
		host._military_order_message = String(sent.get("message", "命令未能下达，请重试。"))
		host._notify_military_arm_order()
	return sent


## Map click while an order is pending. Returns true when the click belonged to
## the order (the caller must then not open the cell panel for it).

func military_arm_order_click(host, cell: int) -> bool:
	if host._military_order_mode.is_empty() or cell < 0:
		return false
	if host._military_order_mode == "explore":
		host._military_order_target = -1
		host._military_order_preview.clear()
		host._clear_military_path_preview()
		host.clear_cell_highlights()
		var explore_cells = host._military_area_cells(cell, host._military_order_radius)
		if explore_cells.is_empty():
			host._military_order_message = "探查范围为空，请重新选择中心。"
			host._notify_military_arm_order()
			return true
		host._military_order_target = cell
		host._military_order_preview = {"area": explore_cells, "days": 0,
			"cells": PackedInt32Array()}
		host.highlight_cells(explore_cells)
		host._military_order_message = "探查范围已标出，确认后部队将自动探路并返回出发点。"
		host._notify_military_arm_order()
		return true
	var facade = host._military_facade()
	var preview: Dictionary = facade.preview_path(host._military_order_army, cell) \
		if facade != null and facade.has_method("preview_path") else {}
	host._military_order_target = -1
	host._military_order_preview.clear()
	host._clear_military_path_preview()
	if host._military_order_mode == "area":
		host.clear_cell_highlights()
	if not bool(preview.get("ok", false)):
		# Never send a move the pathfinder already refused to draw.
		host._preview_failed(preview, cell)
		return true
	if not host._show_military_path_preview(preview, cell):
		host._military_order_message = "路线暂不可显示，请重新选择目标。"
		host._notify_military_arm_order()
		return true
	host._military_order_target = cell
	host._military_order_preview = preview.duplicate()
	if host._military_order_mode == "area":
		var cells = host._military_area_cells(cell, host._military_order_radius)
		host._military_order_preview["area"] = cells
		host.highlight_cells(cells)
		if cells.is_empty():
			host._military_order_target = -1
			host._military_order_preview.clear()
		host._military_order_message = "控制范围已标出，确认后部队将执行区域控制。"
	else:
		host._military_order_message = "路线已标出；可改选目标，或确认行军。"
	host._notify_military_arm_order()
	return true



func _preview_failed(host, preview: Dictionary, cell: int) -> void:
	var reason = String(preview.get("reason", ""))
	var text = "这段路走不通：目标格不可达。"
	if reason == "military_path_unreachable":
		text = "这段路走不通：与部队之间没有可通行的路线。"
	host._military_order_message = text
	host._notify_military_arm_order()
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


## 官营建筑的营造先由经济侧按国库出资结算（国库物资优先、缺口按市价现购），
## 只有经济侧受理后才把排期命令交给军事侧记账。经济侧拒绝时一条军事命令都不发，
## 两本账因此不会各自为政：不会出现「经济没扣钱、军事却已动工」。
##
## `economy_building_id` 是军事目录里的经济建筑稠密索引，这里反查回稳定 id 再交给
## 经济外观层，因为它会在自己的目录里重新解析一次；稠密索引只是编译期坐标，
## 不能当身份跨运行时传递。
