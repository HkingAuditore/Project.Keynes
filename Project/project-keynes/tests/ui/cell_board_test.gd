extends SceneTree

## 悬停展板与地名层的数据契约：
##   1. 行情表选出的五类物资（含去重、未解锁过滤、最低价的有效性门槛）。
##   2. 阶层表按当地影响力排序，组织度缺失时整格不占位。
##   3. 原生 read-view 未就绪时的 pending 契约。
##   4. 展板组件在窄高度下的三段压缩，以及地名层的 LOD / 首都 / 悬停纸签。

const BOARD_SCENE := "res://scenes/ui/cell_board.tscn"

var _failures: Array[String] = []


class BoardEconomyFacade extends RefCounted:
	var market_payloads: Dictionary = {}
	var population_payloads: Dictionary = {}
	var mobilization_payloads: Dictionary = {}
	var busy := false

	func market_cell_snapshot(cell_idx: int) -> Dictionary:
		if busy:
			return {"ok": false, "busy": true}
		return market_payloads.get(cell_idx, {"ok": false, "reason": "absent"})

	func population_cell_snapshot(cell_idx: int, _include_details: bool = true) -> Dictionary:
		if busy:
			return {"ok": false, "busy": true}
		return population_payloads.get(cell_idx, {"ok": false, "reason": "absent"})

	func cell_mobilization_snapshot(cell_idx: int) -> Dictionary:
		return mobilization_payloads.get(cell_idx, {"ok": false})


class BoardGenerator extends RefCounted:
	var economy := BoardEconomyFacade.new()

	func get_economy_facade():
		return economy

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 0}


class LabelFacade extends RefCounted:
	var revision := 1
	var rows: Array = []

	func named_settlement_snapshot() -> Dictionary:
		var cells := PackedInt32Array()
		var tiers := PackedByteArray()
		var active := PackedByteArray()
		var names := PackedStringArray()
		for row in rows:
			cells.append(int(row[0]))
			tiers.append(int(row[1]))
			active.append(1)
			names.append(String(row[2]))
		return {
			"ok": true, "revision": revision, "full_snapshot": true,
			"cell_indices": cells, "prosperity_tiers": tiers,
			"name_active": active, "settlement_names": names,
		}

	func settlement_delta(_since_revision: int) -> Dictionary:
		return {"ok": true, "revision": revision, "full_snapshot": false}


var _economy: BoardEconomyFacade
var _generator: BoardGenerator
var _clock: WorldClock
var _map: MapData
var _inspector: CellInspectorViewModel
var _view_model: CellBoardViewModel


func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	_build_world()
	_test_market_selection()
	_test_market_distinct()
	_test_cohort_ranking()
	_test_pending()
	_test_board_widget()
	_test_label_lod()
	_test_capital_and_hover()
	_test_card_avoid_rect()
	if _failures.is_empty():
		print("[cell-board] PASS")
		quit(0)
	else:
		for message in _failures:
			printerr("[cell-board] FAIL: %s" % message)
		quit(1)


func _build_world() -> void:
	_economy = BoardEconomyFacade.new()
	_generator = BoardGenerator.new()
	_generator.economy = _economy
	_clock = WorldClock.new()
	_clock.auto_start = false
	_map = MapData.new(2, 1)
	for index in 2:
		var cell := HexCell.new(index, 0)
		cell.index = index
		_map.set_cell(cell)
	_map._build_indices()
	_map.visible_arr = PackedByteArray([1, 1])
	_inspector = CellInspectorViewModel.new()
	_inspector.set_context(_map, _generator, null, _clock, 0.42, 22.0)
	_view_model = CellBoardViewModel.new()
	_view_model.set_context(_map, func() -> Object: return _economy,
		_inspector, _clock)
	_clock.current_day = 1.0


## 六种物资各占一个位置，外加两个必须被淘汰的诱饵：未解锁物资与零价物资。
func _market_payload() -> Dictionary:
	return {
		"ok": true,
		"good_ids": PackedStringArray([
			"grain", "timber", "gold", "salt", "iron_ore", "gemstone", "wonder"]),
		# 储量：grain 100、timber 900、gold 10、salt 40、iron 5、gemstone 800、wonder 500
		"stock": PackedInt64Array([
			100000, 900000, 10000, 40000, 5000, 800000, 500000]),
		# 价格：grain 2、timber 3、gold 30、salt 4、iron 9、gemstone 19、wonder 0
		"price": PackedInt32Array([
			20000, 30000, 300000, 40000, 90000, 190000, 0]),
		"cost_anchor_price": PackedInt32Array([
			20000, 30000, 300000, 40000, 90000, 190000, 0]),
		# 居民需求：grain 最高；产业需求把 wonder 抬到需求第一但未解锁。
		"demand_ema": PackedInt64Array([
			500000, 100000, 20000, 60000, 70000, 90000, 900000]),
		"business_demand_ema": PackedInt64Array([0, 0, 0, 0, 0, 0, 0]),
		# 本地供给：timber 最高；iron_ore 需求 70 供给 0 = 缺口最大。
		"offered_supply_ema": PackedInt64Array([
			400000, 260000, 15000, 80000, 0, 40000, 0]),
		"good_technology_available": PackedByteArray([1, 1, 1, 1, 1, 0, 1]),
	}


func _test_market_selection() -> void:
	_economy.busy = false
	_economy.market_payloads = {0: _market_payload()}
	_economy.population_payloads = {0: _population_payload()}
	_economy.mobilization_payloads = {}
	_fresh_view_model()
	var payload := _view_model.build(0)
	_expect("行情 payload 就绪", bool(payload.get("ok", false)))
	var rows: Array = (payload.get("market", {}) as Dictionary).get("rows", [])
	_expect("五类各取一枚，共 5 行", rows.size() == 5)
	if rows.size() == 5:
		var roles := []
		for row in rows:
			roles.append(String((row as Dictionary).get("role", "")))
		_expect("需求最大 = 谷类", roles[0] == "demand" and String(rows[0]["id"]) == "grain")
		_expect("本地供给最大 = 木材", roles[1] == "supply" and String(rows[1]["id"]) == "timber")
		_expect("价格最高 = 金子", roles[2] == "price_high" and String(rows[2]["id"]) == "gold")
		_expect("价格最低 = 盐（粮已上榜）",
			roles[3] == "price_low" and String(rows[3]["id"]) == "salt")
		_expect("缺口最大 = 铁矿", roles[4] == "gap" and String(rows[4]["id"]) == "iron_ore")
		_expect("未解锁物资不进表",
			not _has_id(rows, "gemstone") and not _has_id(rows, "wonder"))
		_expect("储备条按本轮最大储备归一",
			is_equal_approx(float(rows[0]["stock_ratio"]), 100000.0 / 900000.0))
		_expect("价格随成本锚着色", float(rows[2]["price_index"]) >= 0.99)


func _test_market_distinct() -> void:
	_economy.market_payloads = {0: {
		"ok": true,
		"good_ids": PackedStringArray(["grain", "timber"]),
		"stock": PackedInt64Array([100000, 100000]),
		"price": PackedInt32Array([20000, 10000]),
		"cost_anchor_price": PackedInt32Array([20000, 10000]),
		"demand_ema": PackedInt64Array([500000, 0]),
		"business_demand_ema": PackedInt64Array([0, 0]),
		"offered_supply_ema": PackedInt64Array([0, 0]),
		"good_technology_available": PackedByteArray([1, 1]),
	}}
	# 只有两种物资：谷类包揽需求/缺口，木材只能顶价格位；任何物资不得出现两次。
	_fresh_view_model()
	var payload := _view_model.build(0)
	var rows: Array = (payload.get("market", {}) as Dictionary).get("rows", [])
	var ids := {}
	for row in rows:
		ids[String((row as Dictionary).get("id", ""))] = true
	_expect("同一物资只列一次", ids.size() == rows.size())
	_expect("挑不出角色的位置留空，不重复凑数", rows.size() == 2)


func _population_payload() -> Dictionary:
	return {
		"ok": true,
		"population": 1065,
		"populations": PackedInt64Array([600, 300, 100, 40, 20, 5]),
		"handles": PackedInt64Array([11, 12, 13, 14, 15, 16]),
		# 第 4 名人口最少但存款极高，按影响力应排进前五。
		"funds_by_cohort": PackedInt64Array([
			1000000, 2000000, 4000000, 900000000, 500000, 100000]),
		"epoch_income_by_cohort": PackedInt64Array([
			120000, 60000, 20000, 500000, -40000, 10000]),
		"owner_employed_by_cohort": PackedInt64Array([0, 0, 0, 6, 0, 0]),
		"overall_satisfaction_by_cohort_q16": PackedInt32Array([
			40000, 50000, 30000, 60000, 10000, 20000]),
		"living_standard_level_by_cohort": PackedInt32Array([4, 3, 2, 6, 0, 1]),
		"profession_ids": PackedInt32Array([0, 1, 2, 3, 4, 5]),
		"profession_stable_ids": PackedStringArray([
			"farmer", "artisan", "worker", "merchant", "unemployed", "landlord"]),
		"profession_display_names": PackedStringArray([
			"农户", "匠户", "工人", "商人", "失业者", "地主"]),
		"ethnicity_ids": PackedInt32Array([0, 0, 0, 0, 0, 0]),
	}


func _test_cohort_ranking() -> void:
	_economy.busy = false
	_economy.population_payloads = {0: _population_payload()}
	_economy.mobilization_payloads = {0: {
		"ok": true,
		"rows": [{"profession": 2, "mobilization_q16": 13107, "stage": 1}],
	}}
	_fresh_view_model()
	var payload := _view_model.build(0)
	var rows: Array = (payload.get("cohorts", {}) as Dictionary).get("rows", [])
	_expect("阶层表最多五行", rows.size() == 5)
	if rows.size() == 5:
		var merchant := _row_id(rows, 14)
		_expect("存款极高的小阶层按影响力进前五", merchant >= 0)
		var landlord := _row_id(rows, 16)
		_expect("人口最少的地主被挤出前五", landlord < 0)
		_expect("影响力占比合计不超过 1", _total_share(rows) <= 1.0001)
		var worker := _row_id(rows, 13)
		if worker >= 0:
			_expect("组织度落在对应职业上",
				is_equal_approx(float((rows[worker] as Dictionary).get("organization", -1.0)),
					13107.0 / 65536.0))
		var farmer := _row_id(rows, 11)
		if farmer >= 0:
			_expect("无组织读数的阶层不出组织格",
				float((rows[farmer] as Dictionary).get("organization", 0.0)) < 0.0)
		var unemployed := _row_id(rows, 15)
		if unemployed >= 0:
			_expect("赤字收入标为负",
				not bool((rows[unemployed] as Dictionary).get("income_positive", true)))


func _test_pending() -> void:
	_economy.busy = true
	_fresh_view_model()
	var payload := _view_model.build(0)
	_expect("原生未就绪时不返回假数据",
		not bool(payload.get("ok", false)) and bool(payload.get("pending", false)))
	_economy.busy = false


## 同一格里 payloads 会被换掉，缓存按 (cell, day) 命中——每个子用例都要一份新实例。
func _fresh_view_model() -> void:
	_view_model = CellBoardViewModel.new()
	_view_model.set_context(_map, func() -> Object: return _economy,
		_inspector, _clock)


func _test_board_widget() -> void:
	_economy.busy = false
	_economy.market_payloads = {0: _market_payload()}
	_economy.population_payloads = {0: _population_payload()}
	_fresh_view_model()
	var packed := load(BOARD_SCENE) as PackedScene
	if packed == null:
		_failures.append("无法加载 cell_board.tscn")
		return
	var board := packed.instantiate() as CellBoard
	if board == null:
		_failures.append("cell_board.tscn 根节点不是 CellBoard")
		return
	root.add_child(board)
	board.configure(_map, null,
		func() -> Object: return _economy, _inspector, _clock)
	board.apply_available_height(600.0)
	if not board.debug_show_cell(0):
		_failures.append("debug_show_cell 应能展示有数据的格子")
	_expect("展板默认 MOUSE_FILTER_IGNORE", board.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_expect("行情表满五格", _visible_rows(board._market_slots) == 5)
	_expect("阶层表满五格", _visible_rows(board._cohort_slots) == 5)
	var first_name := (board._market_slots[0]["name"] as Label).text
	_expect("行情行写入物资名", first_name == "谷类" or not first_name.is_empty())
	board.apply_available_height(380.0)
	board.debug_show_cell(0)
	_expect("窄高度下阶层表压到三行", _visible_rows(board._cohort_slots) <= 3)
	board.apply_available_height(320.0)
	_expect("更窄时只剩行情表", board.desired_height() < 260.0)
	board.hide_board(true)
	_expect("hide_board 立即隐藏", not board.visible)
	root.remove_child(board)
	board.free()


func _test_label_lod() -> void:
	_expect("远档只放城市以上", SettlementLabelLayer.minimum_tier_for_zoom(0.4) == 5)
	_expect("中档放到县城", SettlementLabelLayer.minimum_tier_for_zoom(0.9) == 3)
	_expect("近档放到乡村", SettlementLabelLayer.minimum_tier_for_zoom(1.5) == 2)
	_expect("远档预算少", SettlementLabelLayer.budget_for_zoom(0.4)
		< SettlementLabelLayer.budget_for_zoom(1.5))


## 首都越过 LOD：远景也必须留名，并且悬停纸签读的是同一份地名。
func _test_capital_and_hover() -> void:
	var map := MapData.new(4, 1)
	for index in 4:
		var cell := HexCell.new(index, 0)
		cell.index = index
		map.set_cell(cell)
	map._build_indices()
	map.visible_arr = PackedByteArray([1, 1, 1, 1])
	var holder := Node2D.new()
	root.add_child(holder)
	var camera := Camera2D.new()
	holder.add_child(camera)
	camera.zoom = Vector2(0.4, 0.4)
	var facade := LabelFacade.new()
	# 三座小城 + 一座属于首都格的聚落（第 3 格）。
	facade.rows = [[0, 2, "青禾村"], [1, 2, "芦苇渡"], [2, 2, "石桥镇"], [3, 3, "临江市"]]
	var layer := SettlementLabelLayer.new()
	holder.add_child(layer)
	layer.configure(map, camera, facade, 22.0,
		HexUtils.wrap_period_x(map.width, 22.0), false)
	layer._rebuild_visible_labels()
	_expect("远档两枚小城都不出", layer._last_rebuild_label_count == 0)
	layer.set_player_capital_cell(3)
	layer._rebuild_visible_labels()
	_expect("首都远景仍留名", layer._last_rebuild_label_count == 1)
	_expect("留下的正是首都", layer._pool[0].text == "临江市")
	layer.set_hover_cell(0)
	layer._update_hover_label()
	_expect("悬停纸签显示该格地名",
		layer.hover_label_visible() and layer.hover_label_text() == "青禾村")
	layer.set_hover_cell(-1)
	layer._update_hover_label()
	_expect("指针离开后纸签退场", not layer.hover_label_visible())
	root.remove_child(holder)
	holder.free()


# ───────────────────────────── 工具 ─────────────────────────────

## 两块浮层不许互相遮挡：展板可见时卡片必须让开。
func _test_card_avoid_rect() -> void:
	var safe := Rect2(0.0, 0.0, 1600.0, 900.0)
	var avoid := Rect2(112.0, 76.0, 340.0, 520.0)
	var card_size := Vector2(320.0, 184.0)
	var blocked := CellHoverCard.avoid_overlap(Vector2(200.0, 200.0), card_size, avoid, safe)
	_expect("卡片与展板相交时让到右侧", blocked.x >= avoid.end.x)
	var clear := CellHoverCard.avoid_overlap(Vector2(900.0, 200.0), card_size, avoid, safe)
	_expect("不相交时保持原位", clear == Vector2(900.0, 200.0))
	var empty := CellHoverCard.avoid_overlap(Vector2(200.0, 200.0), card_size, Rect2(), safe)
	_expect("没有避让目标时保持原位", empty == Vector2(200.0, 200.0))
func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _has_id(rows: Array, id_value: String) -> bool:
	for row in rows:
		if String((row as Dictionary).get("id", "")) == id_value:
			return true
	return false


func _row_id(rows: Array, handle: int) -> int:
	for index in rows.size():
		if int((rows[index] as Dictionary).get("id", -1)) == handle:
			return index
	return -1


func _total_share(rows: Array) -> float:
	var total := 0.0
	for row in rows:
		total += float((row as Dictionary).get("share", 0.0))
	return total


func _visible_rows(slots: Array[Dictionary]) -> int:
	var count := 0
	for slot in slots:
		if (slot["root"] as Control).visible:
			count += 1
	return count
