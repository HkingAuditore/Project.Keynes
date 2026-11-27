extends SceneTree

## 悬停展板的数据契约：
##   1. 行情表选出的五类物资（含去重、未解锁过滤、最低价的有效性门槛）。
##   2. 阶层表按当地影响力排序，组织度缺失时整格不占位。
##   3. 原生 read-view 未就绪时的 pending 契约。
##   4. 展板组件在窄高度下的三段压缩和对悬停卡的避让。

const BOARD_SCENE := "res://scenes/ui/cell_board.tscn"

var _failures: Array[String] = []


class BoardEconomyWithoutMobilization extends RefCounted:
	var market_payloads: Dictionary = {}
	var population_payloads: Dictionary = {}
	var busy := false

	func market_cell_snapshot(cell_idx: int) -> Dictionary:
		if busy:
			return {"ok": false, "busy": true}
		return market_payloads.get(cell_idx, {"ok": false, "reason": "absent"})

	func population_cell_snapshot(cell_idx: int, _include_details: bool = true) -> Dictionary:
		if busy:
			return {"ok": false, "busy": true}
		return population_payloads.get(cell_idx, {"ok": false, "reason": "absent"})


class BoardEconomyFacade extends BoardEconomyWithoutMobilization:
	var mobilization_payloads: Dictionary = {}

	func cell_mobilization_snapshot(cell_idx: int) -> Dictionary:
		return mobilization_payloads.get(cell_idx, {"ok": false})


class BoardGenerator extends RefCounted:
	var economy := BoardEconomyFacade.new()

	func get_economy_facade():
		return economy

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 0}


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
	_test_same_published_day()
	_test_board_widget()
	_test_narrow_board_layout()
	_test_same_cell_daily_refresh()
	_test_retry_while_map_frame_behind()
	_test_card_avoid_rect()
	_clock.free()
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
		var farmer := _row_id(rows, 11)
		if farmer >= 0:
			_expect("存款显示为阶层人均值",
				String((rows[farmer] as Dictionary).get("funds_text", "")) == "0.17")
			_expect("收入显示为阶层人均值",
				String((rows[farmer] as Dictionary).get("income_text", "")) == "+0.02")
		var landlord := _row_id(rows, 16)
		_expect("人口最少的地主被挤出前五", landlord < 0)
		_expect("影响力占比合计不超过 1", _total_share(rows) <= 1.0001)
		var worker := _row_id(rows, 13)
		if worker >= 0:
			_expect("组织度落在对应职业上",
				is_equal_approx(float((rows[worker] as Dictionary).get("organization", -1.0)),
					13107.0 / 65536.0))
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


func _test_same_published_day() -> void:
	_clock.current_day = 2.0
	var population := _population_payload()
	population["read_view_day"] = 1
	var market := _market_payload()
	market["read_view_day"] = 1
	var mobilization := {"ok": false, "read_view_pending": true}
	_economy.population_payloads = {0: population}
	_economy.market_payloads = {0: market}
	_economy.mobilization_payloads = {0: mobilization}
	_fresh_view_model()
	_expect("旧日的人口视图要等当天发布", bool(_view_model.build(0).get("pending", false)))
	population["read_view_day"] = 2
	_expect("人口和市场来自同一发布日", bool(_view_model.build(0).get("pending", false)))
	market["read_view_day"] = 2
	_expect("当天组织度仍待发布时不缓存空值", bool(_view_model.build(0).get("pending", false)))
	mobilization.merge({
		"ok": true, "read_view_pending": false, "read_view_day": 1,
		"rows": [{"profession": 2, "stage": 2, "mobilization_q16": 13107}],
	}, true)
	_expect("不把旧日组织度混入当天", bool(_view_model.build(0).get("pending", false)))
	mobilization["read_view_day"] = 2
	var payload := _view_model.build(0)
	var rows: Array = (payload.get("cohorts", {}) as Dictionary).get("rows", [])
	var worker := _row_id(rows, 13)
	_expect("三份视图到齐后显示组织度",
		bool(payload.get("ok", false)) and worker >= 0
			and is_equal_approx(float(rows[worker].organization), 13107.0 / 65536.0))
	_economy.mobilization_payloads.clear()

	var without_mobilization := BoardEconomyWithoutMobilization.new()
	without_mobilization.population_payloads = {0: population}
	without_mobilization.market_payloads = {0: market}
	var optional_view := CellBoardViewModel.new()
	optional_view.set_context(_map, func() -> Object: return without_mobilization, _inspector, _clock)
	_expect("没有组织度接口时仍可显示其他读数", bool(optional_view.build(0).get("ok", false)))
	# 第 0 天首次提交前（read_view_day == -1）应允许显示初始已发布快照；推进到第 1 天后 -1 必须判过期。
	_clock.current_day = 0.0
	var day0_pop := _population_payload()
	day0_pop["read_view_day"] = -1
	var day0_market := _market_payload()
	day0_market["read_view_day"] = -1
	_economy.population_payloads = {0: day0_pop}
	_economy.market_payloads = {0: day0_market}
	_fresh_view_model()
	_expect("第 0 天初始快照（read_view_day=-1）可读", bool(_view_model.build(0).get("ok", false)))
	_clock.current_day = 1.0
	_fresh_view_model()
	_expect("第 1 天时 read_view_day=-1 仍按过期重试", bool(_view_model.build(0).get("pending", false)))
	_economy.population_payloads = {0: _population_payload()}
	_economy.market_payloads = {0: _market_payload()}


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
	board.configure(_map,
		func() -> Object: return _economy, _inspector, _clock)
	board.apply_available_height(CellBoard.FULL_HEIGHT)
	if not board.debug_show_cell(0):
		_failures.append("debug_show_cell 应能展示有数据的格子")
	_expect("展板默认 MOUSE_FILTER_IGNORE", board.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_expect("行情表满五格", _visible_rows(board._market_slots) == 5)
	_expect("阶层表满五格", _visible_rows(board._cohort_slots) == 5)
	var first_name := (board._market_slots[0]["name"] as Label).text
	_expect("行情行写入物资名", first_name == "谷类" or not first_name.is_empty())
	_expect("储量条显示从零到本轮最大储量的刻度", board._stock_scale.text == "0–900")
	var refreshed := _market_payload()
	var stocks: PackedInt64Array = refreshed["stock"]
	stocks[1] = 200000
	refreshed["stock"] = stocks
	_economy.market_payloads[0] = refreshed
	var previous_day := _clock.current_day
	_clock.current_day += 1.0
	board.debug_show_cell(0)
	var stock_text := (board._market_slots[0]["stock"] as Label).text
	var fill := board._market_slots[0]["bar"] as ColorRect
	_expect("储量上限变化时同步更新刻度与条长，并保留精确读数",
		board._stock_scale.text == "0–200" and stock_text == "100"
			and is_equal_approx(fill.anchor_right, 0.5))
	_clock.current_day = previous_day
	board.apply_available_height(380.0)
	board.debug_show_cell(0)
	_expect("窄高度下阶层表压到三行", _visible_rows(board._cohort_slots) <= 3)
	board.apply_available_height(320.0)
	_expect("更窄时只剩行情表", board.desired_height() < 260.0)
	board.hide_board(true)
	_expect("hide_board 立即隐藏", not board.visible)
	root.remove_child(board)
	board.free()


func _test_narrow_board_layout() -> void:
	_economy.market_payloads = {0: _market_payload()}
	_economy.population_payloads = {0: _population_payload()}
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1000, 900)
	root.add_child(viewport)
	var board := (load(BOARD_SCENE) as PackedScene).instantiate() as CellBoard
	viewport.add_child(board)
	board.configure(_map, func() -> Object: return _economy, _inspector, _clock)
	var layout := preload("res://scripts/ui/game_hud_layout.gd").new()
	layout._viewport = viewport
	layout._cell_board = board
	layout._layout_cell_board()
	board.on_hover_cell_changed(0)
	board._dwell_timer.stop()
	board._on_resolve_timer_elapsed()
	_expect("空间充足时显示展板", board.visible)
	viewport.size = Vector2i(800, 900)
	layout._layout_cell_board()
	_expect("空间不能并排容纳悬停卡时收起展板", not board.visible and board.desired_height() == 0.0)
	viewport.size = Vector2i(1000, 900)
	layout._layout_cell_board()
	_expect("扩大窗口后仍悬停同一格可恢复展板", board.visible and board.current_cell_index() == 0)
	viewport.free()


## 悬停同一格跨日时，展板必须随当日快照刷新，而不能冻死在初次悬停那天。
func _test_same_cell_daily_refresh() -> void:
	_economy.busy = false
	_clock.current_day = 1.0
	_economy.market_payloads = {0: _market_payload()}
	_economy.population_payloads = {0: _population_payload()}
	var packed := load(BOARD_SCENE) as PackedScene
	if packed == null:
		_failures.append("无法加载 cell_board.tscn")
		return
	var board := packed.instantiate() as CellBoard
	if board == null:
		_failures.append("cell_board.tscn 根节点不是 CellBoard")
		return
	root.add_child(board)
	board.configure(_map,
		func() -> Object: return _economy, _inspector, _clock)
	board.apply_available_height(CellBoard.FULL_HEIGHT)
	board.on_hover_cell_changed(0)
	# 仍在初次 dwell 期间，同格刷新不得抢跑提前显示。
	board.on_hover_cell_refreshed(0)
	_expect("dwell 未结束时刷新不提前出表", not board.visible)
	board._dwell_timer.stop()
	board._on_resolve_timer_elapsed()
	_expect("dwell 到期后展示当前格", board.visible and board.current_cell_index() == 0)
	var day1_pop := (board._cohort_slots[1]["population"] as Label).text
	var day1_builds := int(board._view_model.debug_stats().get("builds", 0))
	# 同日重复触发不应冗余重建。
	board.on_hover_cell_refreshed(0)
	_expect("同日重复刷新不冗余重建",
		int(board._view_model.debug_stats().get("builds", 0)) == day1_builds)
	# 跨日后更新底层快照，触发同格刷新。
	_clock.current_day = 2.0
	var next_pop := _population_payload()
	var pops := (next_pop["populations"] as PackedInt64Array).duplicate()
	pops[0] = 750
	next_pop["populations"] = pops
	next_pop["population"] = 1215
	_economy.population_payloads[0] = next_pop
	board.on_hover_cell_refreshed(0)
	var day2_pop := (board._cohort_slots[1]["population"] as Label).text
	_expect("跨日后同格展板刷新为新数据", day2_pop != day1_pop and day2_pop == "750")
	board.hide_board(true)
	root.remove_child(board)
	board.free()


## 模拟运行中新日已到达但地图视口尚未画完时，展板应排队重试而不是直接放弃；
## 真正不可见的迷雾格仍立即隐藏且不重试。
func _test_retry_while_map_frame_behind() -> void:
	_economy.busy = false
	_clock.current_day = 2.0
	var pop := _population_payload()
	pop["read_view_day"] = 2
	var market := _market_payload()
	market["read_view_day"] = 2
	_economy.population_payloads = {0: pop}
	_economy.market_payloads = {0: market}
	var frame := MapDrawnFrame.new()
	frame.attach(_map)
	frame.received_day = 2
	frame.staged_day = 1
	frame.stage_vision(_map.vision_revision, _map.visible_arr, PackedByteArray([1, 1]))
	frame.submit(Transform2D.IDENTITY, Vector2(1600, 900))
	frame.present()
	var board := (load(BOARD_SCENE) as PackedScene).instantiate() as CellBoard
	root.add_child(board)
	board.configure(_map, func() -> Object: return _economy, _inspector, _clock)
	board.apply_available_height(CellBoard.FULL_HEIGHT)
	board.on_hover_cell_changed(0)
	board._dwell_timer.stop()
	board._on_resolve_timer_elapsed()
	_expect("地图绘制落后于已接收日时进入重试而不放弃",
		not board.visible and not board._retry_timer.is_stopped())
	# 视口画完当日后，重试即可弹出展板。
	frame.staged_day = 2
	frame.submit(Transform2D.IDENTITY, Vector2(1600, 900))
	frame.present()
	board._retry_timer.stop()
	board._on_resolve_timer_elapsed()
	_expect("地图画完后重试弹出展板", board.visible and board.current_cell_index() == 0)
	# 已显示的同一格在下一日绘制尚未完成时保持可见并排队重试，不闪烁隐藏。
	frame.received_day = 3
	board.on_hover_cell_refreshed(0)
	_expect("同格跨日绘制中保持可见并等待重试",
		board.visible and not board._retry_timer.is_stopped())
	# 真正掉入迷雾的格子必须立即隐藏且不再重试。
	frame.staged_day = 3
	frame.stage_vision(_map.vision_revision + 1, PackedByteArray([0, 1]), PackedByteArray([1, 1]))
	_map.vision_revision += 1
	frame.submit(Transform2D.IDENTITY, Vector2(1600, 900))
	frame.present()
	board._retry_timer.stop()
	board._on_resolve_timer_elapsed()
	_expect("不可见迷雾格立即开始隐藏且不重试",
		(not board.visible or board._hiding) and board.current_cell_index() == -1
			and board._retry_timer.is_stopped())
	frame.detach(_map)
	_map.vision_revision = 0
	board.hide_board(true)
	root.remove_child(board)
	board.free()
	_clock.current_day = 1.0


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
