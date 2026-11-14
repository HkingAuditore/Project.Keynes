extends SceneTree

## 军事维护实物化的 UI/读模型契约（docs/plans/military-physical-maintenance.md
## D7 契约冻结 / S4-6 显示）。
##
## 只测 GDScript 侧，不碰原生语义：
##
##   1. `MilitaryFacade.shape_maintenance()`：稠密 object_id → 稳定 id、短缺优先排序、
##      原因文案、需求加权满足率、失修计数。纯函数，喂合成字典即可。
##   2. facade 出口：旧 DLL 没有 `get_military_maintenance_snapshot()` 时降级为空数组
##      （永不 null），同一刷新里只读一次原生。
##   3. `CountryViewModel.military_spending_model()`：维护通道的实物键，且
##      `maintenance_paid_last_period` 的来源不变。
##   4. 地块档案：同一格的建筑各读各的失修（城防折半只影响它自己），快照为空时
##      回落到国家级旗标。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_maintenance_view_model_test.gd

const Cell := 42
const PlayerHandle := 0x100000001

const FacadeScript = preload("res://scripts/military/military_facade.gd")
const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")
const InspectorScript = preload("res://scripts/ui/cell_inspector_view_model.gd")
const BlockScript = preload("res://scripts/ui/components/military_spending_block.gd")

var _failures := 0


## 旧 DLL：没有维护快照方法（只有军事命令面）。
class ExtWithoutMaintenance:
	var batches: Array = []

	func submit_military_commands(batch: Array) -> Dictionary:
		batches.append(batch)
		return {"ok": true, "accepted": batch.size(), "rejected": []}


## 新 DLL：每次调用都记账，用来验证「同一刷新只读一次」。
class ExtWithMaintenance:
	var calls := 0
	var snapshot: Dictionary = {}

	func get_military_maintenance_snapshot() -> Dictionary:
		calls += 1
		return snapshot


class FakeCountryFacade:
	func cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "owned": true, "country_handle": PlayerHandle,
			"country_name": "测试国"}

	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "technology_ids": PackedStringArray()}

	func treasury_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "cash": 0, "good_ids": PackedStringArray(),
			"quantities": PackedInt64Array()}


class FakeMilitaryFacade:
	var catalog_data: Dictionary = {}
	var snapshot_data: Dictionary = {}
	var maintenance_data: Array = []

	func catalog() -> Dictionary:
		return catalog_data

	func cell_snapshot(_cell: int, _observer: int) -> Dictionary:
		return snapshot_data

	func maintenance_supported() -> bool:
		return true

	func maintenance_snapshot(_country_slot: int = -1) -> Array:
		return maintenance_data


## 更老的 DLL：连 `maintenance_snapshot` 都没有（真实门面里它靠 has_method 守护）。
class LegacyMilitaryFacade:
	var catalog_data: Dictionary = {}
	var snapshot_data: Dictionary = {}

	func catalog() -> Dictionary:
		return catalog_data

	func cell_snapshot(_cell: int, _observer: int) -> Dictionary:
		return snapshot_data


class FakeGenerator:
	var military = null
	var country = null

	func get_military_facade():
		return military

	func get_country_facade():
		return country

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": Cell}


func _init() -> void:
	_test_empty_input()
	_test_dense_to_stable_ids()
	_test_sorting_puts_shortage_first()
	_test_reason_text_mapping()
	_test_weighted_ratio_math()
	_test_disrepair_and_shortage_counts()
	_test_facade_degrades_without_native()
	_test_facade_reads_native_once()
	_test_country_panel_keys()
	_test_legacy_call_without_maintenance()
	_test_spending_block_detail_section()
	_test_three_viewport_tiers()
	_test_tile_dossier_per_building_disrepair()
	print("=== military maintenance view model: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool, detail := "") -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s %s" % [label, detail])


# ---------------------------------------------------------------- fixtures

## 编译目录的最小形状：`state_buildings` 的**下标**就是快照的 `object_id`，
## `units` 同理（与 military_catalog_compiler.gd 的稠密表一致）。
func _catalog() -> Dictionary:
	return {
		"units": [
			{"id": "militia", "name": "民兵"},
			{"id": "bronze_spearmen", "name": "青铜矛兵"},
		],
		"state_buildings": [
			{"id": "warrior_lodge", "name": "战士营地"},
			{"id": "garrison_barracks", "name": "戍卫营"},
			{"id": "earthen_rampart", "name": "夯土城垣"},
		],
	}


## 五行的合成快照：四行属于国家 1，一行属于国家 2（无需求，days = -1）。
##
##   行 0  戍卫营   需要 3000 / 库存 3000 / 满足 100%  / 可用 3.5 日
##   行 1  夯土城垣 需要 1000 / 库存  500 / 满足  50%  / 可用 1.5 日 · 失修 · 缺货
##   行 2  战士营地 需要 2000 / 库存 8000 / 满足  90%  / 可用 4.0 日
##   行 3  青铜矛兵 需要  500 / 库存  100 / 满足  20%  / 可用 0.5 日 · 运输未到
##   行 4  战士营地 需要    0 / 无需求        / 可用 -1（排最后）
func _snapshot() -> Dictionary:
	return {
		"country_slot": PackedInt32Array([1, 1, 1, 1, 2]),
		"cell": PackedInt32Array([42, 42, 43, 43, 7]),
		"kind": PackedInt32Array([0, 0, 0, 1, 0]),
		"object_id": PackedInt32Array([1, 2, 0, 1, 0]),
		"units": PackedInt64Array([3, 1, 2, 400, 1]),
		"daily_need_goods": PackedInt64Array([3000, 1000, 2000, 500, 0]),
		"stock_goods": PackedInt64Array([3000, 500, 8000, 100, 0]),
		"inbound_goods": PackedInt64Array([0, 0, 0, 200, 0]),
		"ratio_bp": PackedInt32Array([10000, 5000, 9000, 2000, 0]),
		"days_cover_x10": PackedInt32Array([35, 15, 40, 5, -1]),
		"disrepair": PackedInt32Array([0, 1, 0, 0, 0]),
		"shortage_reason": PackedInt32Array([0, 1, 0, 3, 0]),
	}


func _shaped(snapshot: Dictionary = {}) -> Dictionary:
	return FacadeScript.shape_maintenance(
		snapshot if not snapshot.is_empty() else _snapshot(), _catalog())


func _row_ids(rows: Array) -> Array:
	var ids: Array = []
	for raw in rows:
		ids.append(String((raw as Dictionary).get("id", "")))
	return ids


## 国家槽快照的最小可用集合（`has_policy` 是维护板块的前提）。
func _country_snapshot() -> Dictionary:
	return {
		"ok": true, "has_policy": true,
		"spend_payroll_30": 3000000, "spend_upkeep_30": 1500000,
		"spend_procurement_30": 600000,
		"budget_enabled": true, "budget_share_bp": 3000,
		"budget_upkeep_bp": 3000, "budget_upkeep_daily": 540000,
		"training": [],
	}


# ---------------------------------------------------------------- shaping

## 空输入必须是空表，不是 null、不是一条「0% 满足」的假行。
func _test_empty_input() -> void:
	var empty_dict := FacadeScript.shape_maintenance({}, _catalog())
	_expect("an empty snapshot yields no maintenance rows",
		empty_dict.get("rows", null) is Array and (empty_dict["rows"] as Array).is_empty())
	var empty_arrays := _shaped({
		"country_slot": PackedInt32Array(), "kind": PackedInt32Array(),
		"object_id": PackedInt32Array(),
	})
	_expect("a snapshot with empty parallel arrays yields no rows",
		(empty_arrays.get("rows", []) as Array).is_empty())
	_expect("an array input is accepted too",
		(FacadeScript.shape_maintenance([], _catalog()).get("rows", []) as Array).is_empty())
	var summary: Dictionary = empty_dict.get("summary", {})
	_expect("an empty snapshot summarizes to zeros",
		int(summary.get("rows", -1)) == 0 and int(summary.get("need_goods", -1)) == 0
		and int(summary.get("weighted_ratio_bp", -1)) == 0
		and int(summary.get("disrepair_rows", -1)) == 0
		and int(summary.get("shortage_rows", -1)) == 0, str(summary))
	_expect("a non-dictionary input degrades to an empty table",
		(FacadeScript.shape_maintenance("garbage", _catalog()).get("rows", []) as Array).is_empty())


## `object_id` 是稠密下标，必须翻成稳定 id：建筑走 `state_buildings`，装备走 `units`。
func _test_dense_to_stable_ids() -> void:
	var rows: Array = _shaped().get("rows", [])
	var by_id := {}
	for raw in rows:
		by_id[String((raw as Dictionary).get("id", ""))] = raw
	var barracks: Dictionary = by_id.get("garrison_barracks", {})
	_expect("building object_id 1 resolves to the stable id",
		String(barracks.get("id", "")) == "garrison_barracks", str(by_id.keys()))
	_expect("the stable id carries the catalog display name",
		String(barracks.get("name", "")) == "戍卫营", String(barracks.get("name", "")))
	_expect("buildings are labelled 建筑",
		String(barracks.get("kind_name", "")) == "建筑")
	_expect("dense ids are kept for the caller that needs them",
		int(barracks.get("object_id", -1)) == 1)
	var equipment: Dictionary = by_id.get("bronze_spearmen", {})
	_expect("equipment object_id resolves through the unit table",
		String(equipment.get("kind_name", "")) == "装备"
		and String(equipment.get("name", "")) == "青铜矛兵", str(equipment))
	_expect("raw integers survive the shaping",
		int(equipment.get("units", -1)) == 400
		and int(equipment.get("daily_need_goods", -1)) == 500
		and int(equipment.get("stock_goods", -1)) == 100
		and int(equipment.get("inbound_goods", -1)) == 200
		and int(equipment.get("ratio_bp", -1)) == 2000
		and int(equipment.get("days_cover_x10", -2)) == 5, str(equipment))
	# 越界/未知下标的行不能丢，也不能变成空名字：玩家至少要知道「哪一号对象」。
	var out_of_range := FacadeScript.shape_maintenance([
		{"country_slot": 1, "cell": 42, "kind": 0, "object_id": 99},
	], _catalog())
	var orphan: Dictionary = (out_of_range.get("rows", []) as Array)[0]
	_expect("an out-of-range object_id keeps a readable placeholder name",
		String(orphan.get("id", "x")).is_empty()
		and String(orphan.get("name", "")).contains("99"), str(orphan))


## 短缺优先：可用天数升序；无需求（-1）不是短缺，排最后；同天数按稳定 id。
func _test_sorting_puts_shortage_first() -> void:
	var rows: Array = _shaped().get("rows", [])
	var days: Array = []
	for raw in rows:
		days.append(int((raw as Dictionary).get("days_cover_x10", -99)))
	_expect("rows are sorted by days_cover ascending with no-demand last",
		days == [5, 15, 35, 40, -1], str(days))
	_expect("the most starved object comes first",
		String((rows[0] as Dictionary).get("id", "")) == "bronze_spearmen",
		String((rows[0] as Dictionary).get("id", "")))
	# 同一可用天数时按稳定 id 升序：排序结果不能依赖原生数组的排列顺序。
	var tie := FacadeScript.shape_maintenance({
		"country_slot": PackedInt32Array([1, 1]),
		"cell": PackedInt32Array([42, 42]),
		"kind": PackedInt32Array([0, 0]),
		"object_id": PackedInt32Array([2, 0]),
		"daily_need_goods": PackedInt64Array([1000, 1000]),
		"days_cover_x10": PackedInt32Array([20, 20]),
	}, _catalog())
	_expect("equal cover days tie-break on the stable id",
		_row_ids(tie.get("rows", [])) == ["earthen_rampart", "warrior_lodge"],
		str(_row_ids(tie.get("rows", []))))


## 0 无 / 1 缺货 / 2 预算不足 / 3 运输未到；越界不崩。
func _test_reason_text_mapping() -> void:
	_expect("reason 0 reads as a dash",
		FacadeScript.maintenance_reason_text(0) == "—")
	_expect("reason 1 reads as 缺货",
		FacadeScript.maintenance_reason_text(1) == "缺货")
	_expect("reason 2 reads as 预算不足",
		FacadeScript.maintenance_reason_text(2) == "预算不足")
	_expect("reason 3 reads as 运输未到",
		FacadeScript.maintenance_reason_text(3) == "运输未到")
	_expect("an unknown reason falls back to the dash",
		FacadeScript.maintenance_reason_text(9) == "—"
		and FacadeScript.maintenance_reason_text(-1) == "—")
	var rows: Array = _shaped().get("rows", [])
	var mapped: Array = []
	for raw in rows:
		mapped.append(String((raw as Dictionary).get("reason_text", "")))
	_expect("rows carry the mapped reason text",
		mapped == ["运输未到", "缺货", "—", "—", "—"], str(mapped))


## 需求加权：Σ(need × ratio) / Σneed，整数除法；没有需求时为 0（不是 100%）。
func _test_weighted_ratio_math() -> void:
	var summary: Dictionary = _shaped().get("summary", {})
	# (3000×10000 + 1000×5000 + 2000×9000 + 500×2000 + 0×0) / 6500 = 54000000 / 6500
	_expect("weighted ratio is need-weighted integer basis points",
		int(summary.get("weighted_ratio_bp", -1)) == 8307,
		str(summary.get("weighted_ratio_bp", -1)))
	_expect("the summary totals need/stock/inbound in GOODS_SCALE",
		int(summary.get("need_goods", -1)) == 6500
		and int(summary.get("stock_goods", -1)) == 11600
		and int(summary.get("inbound_goods", -1)) == 200, str(summary))
	var no_demand := FacadeScript.shape_maintenance({
		"country_slot": PackedInt32Array([2]),
		"kind": PackedInt32Array([0]),
		"object_id": PackedInt32Array([0]),
		"daily_need_goods": PackedInt64Array([0]),
		"ratio_bp": PackedInt32Array([0]),
		"days_cover_x10": PackedInt32Array([-1]),
	}, _catalog())
	_expect("no demand reports 0 rather than 100%",
		int((no_demand.get("summary", {}) as Dictionary).get("weighted_ratio_bp", -1)) == 0)


## 失修与短缺各数各的：失修看 5 日窗口结果，短缺看当日原因码。
func _test_disrepair_and_shortage_counts() -> void:
	var summary: Dictionary = _shaped().get("summary", {})
	_expect("one disrepair row is counted",
		int(summary.get("disrepair_rows", -1)) == 1,
		str(summary.get("disrepair_rows", -1)))
	_expect("two shortage rows are counted (缺货 + 运输未到)",
		int(summary.get("shortage_rows", -1)) == 2,
		str(summary.get("shortage_rows", -1)))
	_expect("the row count is reported as an integer",
		int(summary.get("rows", -1)) == 5, str(summary.get("rows", -1)))
	_expect("disrepair is normalized to 0/1 ints",
		_shaped().get("rows", [])[1].get("disrepair", -1) == 1)


# ---------------------------------------------------------------- facade

## 旧 DLL：方法缺席 → supported = false、快照为空数组（不是 null）、汇总全 0。
func _test_facade_degrades_without_native() -> void:
	var facade = FacadeScript.new()
	facade._world_ext = ExtWithoutMaintenance.new()
	facade._configured = true
	_expect("an older DLL reports maintenance as unsupported",
		not facade.maintenance_supported())
	var rows = facade.maintenance_snapshot()
	_expect("an unsupported snapshot is an empty array, never null",
		rows != null and rows is Array and (rows as Array).is_empty())
	var summary: Dictionary = facade.maintenance_summary()
	_expect("an unsupported summary is all integers and all zero",
		int(summary.get("rows", -1)) == 0
		and int(summary.get("weighted_ratio_bp", -1)) == 0
		and int(summary.get("disrepair_rows", -1)) == 0)
	# 没有维护方法的门面必须照常转发命令：降级只影响这一块读数。
	_expect("degrading does not disable the rest of the facade",
		facade.maintenance_summary(0).size() == summary.size())


## 支持的 DLL：同一刷新里「明细 + 汇总」只跨桥一次，且按国家过滤。
func _test_facade_reads_native_once() -> void:
	var ext := ExtWithMaintenance.new()
	ext.snapshot = _snapshot()
	var facade = FacadeScript.new()
	facade._world_ext = ext
	facade._configured = true
	facade._catalog = _catalog()
	_expect("a DLL with the snapshot method reports support",
		facade.maintenance_supported())
	var rows: Array = facade.maintenance_snapshot(1)
	_expect("rows are filtered to the requested country slot",
		rows.size() == 4, str(rows.size()))
	var summary: Dictionary = facade.maintenance_summary(1)
	_expect("the summary is filtered to the same country",
		int(summary.get("rows", -1)) == 4
		and int(summary.get("weighted_ratio_bp", -1)) == 8307, str(summary))
	_expect("the native snapshot is read once per refresh, not per query",
		ext.calls == 1, str(ext.calls))
	var other: Dictionary = facade.maintenance_summary(2)
	_expect("a second country summarizes only its own row",
		int(other.get("rows", -1)) == 1
		and int(other.get("need_goods", -1)) == 0, str(other))
	_expect("asking about another country does not re-read the native table",
		ext.calls == 1, str(ext.calls))
	facade.invalidate_maintenance_cache()
	facade.maintenance_summary(1)
	_expect("an invalidation (day advance / command) re-reads once",
		ext.calls == 2, str(ext.calls))


# ---------------------------------------------------------------- panel

## 财政页军事板块的维护通道：保持旧键，补齐实物键。
func _test_country_panel_keys() -> void:
	var maintenance := {
		"supported": true,
		"summary": _shaped().get("summary", {}),
		"rows": _shaped().get("rows", []),
	}
	var model: Dictionary = CountryViewModelScript.military_spending_model(
		_country_snapshot(), maintenance)
	# 旧键一个都不能少，值也不能变（30 日窗口 ÷ 30，来源不变）。
	_expect("the settled maintenance spend keeps its old source",
		int(model.get("maintenance_paid_last_period", -1)) == 50000,
		str(model.get("maintenance_paid_last_period", -1)))
	_expect("the window and channel fields are untouched",
		int(model.get("maintenance_paid_window", -1)) == 1500000
		and int(model.get("window_days", -1)) == 30
		and int(model.get("upkeep_budget_daily", -1)) == 540000)
	_expect("the 维护 channel declares itself physical",
		bool(model.get("maintenance_is_physical", false)))
	_expect("the model reports native support",
		bool(model.get("maintenance_supported", false)))
	_expect("ratio/disrepair/shortage come from the summary",
		int(model.get("maintenance_ratio_bp", -1)) == 8307
		and int(model.get("maintenance_disrepair_rows", -1)) == 1
		and int(model.get("maintenance_shortage_rows", -1)) == 2, str(model))
	var rows: Array = model.get("maintenance_rows", [])
	_expect("the detail list is projected row by row", rows.size() == 5,
		str(rows.size()))
	if rows.size() == 5:
		var first: Dictionary = rows[0]
		_expect("the projection keeps shortage-first order",
			String(first.get("id", "")) == "bronze_spearmen", str(first))
		_expect("the projection exposes the documented short keys",
			int(first.get("units", -1)) == 400
			and int(first.get("need", -1)) == 500
			and int(first.get("stock", -1)) == 100
			and int(first.get("inbound", -1)) == 200
			and int(first.get("ratio", -1)) == 2000
			and int(first.get("days_cover", -99)) == 5, str(first))
		_expect("reason text is mapped, not the raw code",
			String(first.get("reason_text", "")) == "运输未到", str(first))
		_expect("cover days are rendered with integer math",
			String(first.get("days_text", "")) == "0.5 日", str(first.get("days_text", "")))
		_expect("goods are rendered with integer math, not floats",
			String(first.get("inbound_text", "")) == "0.2"
			and String((rows[2] as Dictionary).get("need_text", "")) == "3.0",
			"%s / %s" % [String(first.get("inbound_text", "")),
				String((rows[2] as Dictionary).get("need_text", ""))])
		_expect("disrepair is a per-row boolean",
			not bool(first.get("disrepair", true))
			and bool((rows[1] as Dictionary).get("disrepair", false)))
	_expect("cover_days_text keeps integers only",
		CountryViewModelScript.cover_days_text(-1) == "—"
		and CountryViewModelScript.cover_days_text(40) == "4 日"
		and CountryViewModelScript.cover_days_text(35) == "3.5 日")


## 没有实物维护（旧 DLL）时旧键照旧可用：面板仍显示「实际结算的维护花费」，
## 只是不再声称有实物明细。
func _test_legacy_call_without_maintenance() -> void:
	var model: Dictionary = CountryViewModelScript.military_spending_model(
		_country_snapshot())
	_expect("a legacy call still reports the settled spend",
		int(model.get("maintenance_paid_last_period", -1)) == 50000)
	_expect("a legacy call names the channel as physical", 
		bool(model.get("maintenance_is_physical", false)))
	_expect("a legacy call reports no native support",
		not bool(model.get("maintenance_supported", true)))
	_expect("a legacy call carries no detail rows",
		(model.get("maintenance_rows", null) as Array).is_empty())
	_expect("a legacy call reports zero ratio instead of a fake 100%",
		int(model.get("maintenance_ratio_bp", -1)) == 0)


# ---------------------------------------------------------------- spending block

func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


## 财政页板块：维护通道下面那张明细表。最多 8 行、一行摘要、节点不随刷新增长；
## 旧 DLL 只写「实物维护未接通」，不留任何 0 值行。

## S5-8 的三档布局守卫（1280x720 / 1920x1080 / 720x1280）。
## 无渲染器也能查真实的 Control 最小尺寸：只要明细段的最小宽度放得进该档的可用宽度，
## 就不会在窄档被裁掉或横向溢出。三档都跑同一个模型，因此它守的是“布局随档位退化”，
## 不是“像素好看”——后者需要真实渲染器。
func _test_three_viewport_tiers() -> void:
	var maintenance := {
		"supported": true,
		"summary": _shaped().get("summary", {}),
		"rows": _shaped().get("rows", []),
	}
	var tiers := [
		{"label": "1280x720", "size": Vector2(1280, 720)},
		{"label": "1920x1080", "size": Vector2(1920, 1080)},
		{"label": "720x1280", "size": Vector2(720, 1280)},
	]
	for tier in tiers:
		var label := String((tier as Dictionary).label)
		var size: Vector2 = (tier as Dictionary).size
		var block := BlockScript.new() as Control
		get_root().add_child(block)
		block.set_size(size)
		block.set_state(CountryViewModelScript.military_spending_model(
			_country_snapshot(), maintenance))
		var minimum := block.get_combined_minimum_size()
		# 面板左右各留 24px 内边距，剩余才是内容可用宽度。
		var available := size.x - 48.0
		_expect("%s: the maintenance block fits the viewport width" % label,
			minimum.x <= available,
			"min=%.1f available=%.1f" % [minimum.x, available])
		# 高度也不能随对象数线性膨胀到超屏：明细行固定上限 8 行。
		_expect("%s: the maintenance block stays within the viewport height" % label,
			minimum.y <= size.y,
			"min=%.1f viewport=%.1f" % [minimum.y, size.y])
		var rendered: Array = block.maintenance_row_texts()
		_expect("%s: the detail section still renders its rows" % label,
			rendered.size() > 0, str(rendered.size()))
		get_root().remove_child(block)
		block.queue_free()


func _test_spending_block_detail_section() -> void:
	var maintenance := {
		"supported": true,
		"summary": _shaped().get("summary", {}),
		"rows": _shaped().get("rows", []),
	}
	var block := BlockScript.new() as Control
	get_root().add_child(block)
	block.set_state(CountryViewModelScript.military_spending_model(
		_country_snapshot(), maintenance))
	_expect("the block stays available with a maintenance model",
		block.is_available())
	_expect("the summary line counts disrepair and shows an integer ratio",
		block.maintenance_summary_text() == "1 项失修 · 加权满足率 83%",
		block.maintenance_summary_text())
	var rendered: Array = block.maintenance_row_texts()
	_expect("the detail section lists one row per object",
		rendered.size() == 5, str(rendered.size()))
	if rendered.size() == 5:
		_expect("the block lists the starved equipment group first",
			(rendered[0] as Array)[0] == "青铜矛兵", str(rendered[0]))
		_expect("equipment is counted in 人, buildings in 座",
			(rendered[0] as Array)[1] == "400 人"
			and (rendered[2] as Array)[1] == "3 座", str(rendered))
		_expect("the block prints the integer satisfaction rate",
			(rendered[0] as Array)[2] == "20%", str(rendered[0]))
		_expect("the block prints the cover days",
			(rendered[0] as Array)[3] == "0.5 日", str(rendered[0]))
		_expect("the block prints the inbound goods",
			(rendered[0] as Array)[4] == "0.2", str(rendered[0]))
	# 明细段自身的最小宽度必须容得下 424px 的档案列：它以后可能被挂到更窄的面板里。
	var detail_box = block.get("_maintenance_box")
	_expect("the detail rows fit a 424px dossier column",
		detail_box != null
		and (detail_box as Control).get_combined_minimum_size().x <= 424.0,
		str((detail_box as Control).get_combined_minimum_size().x
			if detail_box != null else -1.0))
	# 同一身份重复 set_state：节点数不变（每日补丁走这条路径）。
	var nodes_before := _count_nodes(block)
	block.set_state(CountryViewModelScript.military_spending_model(
		_country_snapshot(), maintenance))
	_expect("a same-identity refresh does not grow the detail list",
		_count_nodes(block) == nodes_before,
		"%d vs %d" % [_count_nodes(block), nodes_before])
	# 行数上限 8：多出来的对象不进节点树，只在模型里躺着。
	var many: Array = []
	for index in range(12):
		many.append({"id": "obj%d" % index, "name": "对象 %d" % index, "kind": 0,
			"cell": index, "units": 1, "daily_need_goods": 1000, "stock_goods": 0,
			"inbound_goods": 0, "ratio_bp": 0, "days_cover_x10": index,
			"disrepair": 0, "shortage_reason": 1, "reason_text": "缺货"})
	var crowded := {
		"supported": true,
		"summary": {"rows": 12, "weighted_ratio_bp": 0, "disrepair_rows": 0,
			"shortage_rows": 12, "need_goods": 12000, "stock_goods": 0,
			"inbound_goods": 0},
		"rows": many,
	}
	block.set_state(CountryViewModelScript.military_spending_model(
		_country_snapshot(), crowded))
	_expect("the detail list is capped at eight rows",
		block.maintenance_row_texts().size() == 8,
		str(block.maintenance_row_texts().size()))
	block.queue_free()

	# 旧 DLL：一句话，没有表头、没有行。
	var legacy := BlockScript.new() as Control
	get_root().add_child(legacy)
	legacy.set_state(CountryViewModelScript.military_spending_model(
		_country_snapshot()))
	_expect("an unsupported native says 实物维护未接通",
		legacy.maintenance_summary_text() == "实物维护未接通",
		legacy.maintenance_summary_text())
	_expect("an unsupported native shows no detail row at all",
		legacy.maintenance_row_texts().is_empty())
	legacy.queue_free()


# ---------------------------------------------------------------- tile dossier
func _dossier_catalog() -> Dictionary:
	return {
		"units": [{"id": "militia", "name": "民兵", "class": 0}],
		"state_buildings": [
			{"id": "warrior_lodge", "name": "战士营地", "role": 0, "tier": 1,
				"unlock_tech_id": "", "capacity": 4, "fort_bonus": 0.0,
				"training_speed": 1.0, "build_days": 10},
			{"id": "earthen_rampart", "name": "夯土城垣", "role": 1, "tier": 1,
				"unlock_tech_id": "", "capacity": 0, "fort_bonus": 0.3,
				"training_speed": 1.0, "build_days": 20},
			{"id": "martial_academy", "name": "武学馆", "role": 2, "tier": 1,
				"unlock_tech_id": "", "capacity": 0, "fort_bonus": 0.0,
				"training_speed": 1.5, "build_days": 40},
		],
	}


func _dossier_snapshot(disrepair: bool) -> Dictionary:
	return {
		"ok": true, "cell": Cell, "owner_slot": 1, "controller_slot": 1,
		"post_count": 4, "present": 2, "pending_enlist": 0,
		# 档位取目录的 `tier` 值（不是数组下标）：三行都是 1 档。
		"fort_tier": 1, "college_tier": 1, "paused": false, "disrepair": disrepair,
		"barracks_tiers": PackedInt32Array([0, 1, 0, 0, 0, 0, 0, 0]),
		"construction_buildings": PackedInt32Array([-1, -1, -1]),
		"construction_done_days": PackedInt32Array([-1, -1, -1]),
		"armies": [], "training": [], "garrison_lots": [],
	}


## 这一格的维护行：城防（object_id 1）缺货失修，兵营（object_id 0）满仓。
func _dossier_maintenance() -> Array:
	return [
		{"country_slot": 1, "cell": Cell, "kind": 0, "object_id": 1,
			"id": "earthen_rampart", "name": "夯土城垣", "kind_name": "建筑",
			"units": 1, "daily_need_goods": 4000, "stock_goods": 2000,
			"inbound_goods": 0, "ratio_bp": 5000, "days_cover_x10": 12,
			"disrepair": 1, "shortage_reason": 1, "reason_text": "缺货"},
		{"country_slot": 1, "cell": Cell, "kind": 0, "object_id": 0,
			"id": "warrior_lodge", "name": "战士营地", "kind_name": "建筑",
			"units": 2, "daily_need_goods": 3000, "stock_goods": 9000,
			"inbound_goods": 0, "ratio_bp": 10000, "days_cover_x10": 40,
			"disrepair": 0, "shortage_reason": 0, "reason_text": "—"},
		# 别格的行必须被过滤掉，不能把邻格的失修算到这一格头上。
		{"country_slot": 1, "cell": Cell + 1, "kind": 0, "object_id": 2,
			"id": "martial_academy", "name": "武学馆", "kind_name": "建筑",
			"units": 1, "daily_need_goods": 1000, "stock_goods": 0,
			"inbound_goods": 0, "ratio_bp": 0, "days_cover_x10": 0,
			"disrepair": 1, "shortage_reason": 2, "reason_text": "预算不足"},
	]


func _dossier_rows(facade) -> Array:
	var generator := FakeGenerator.new()
	generator.country = FakeCountryFacade.new()
	generator.military = facade
	var vm = InspectorScript.new()
	vm.set_context(null, generator, null, null, 0.42, 22.0)
	var category: Dictionary = vm._military_category(Cell)
	return ((category.get("military_cell", {}) as Dictionary).get("buildings", []) as Array)


func _test_tile_dossier_per_building_disrepair() -> void:
	var facade := FakeMilitaryFacade.new()
	facade.catalog_data = _dossier_catalog()
	# 国家级旗标故意关掉：同格城防失修、兵营完好，必须各读各的。
	facade.snapshot_data = _dossier_snapshot(false)
	facade.maintenance_data = _dossier_maintenance()
	var buildings := _dossier_rows(facade)
	_expect("the dossier still builds three state building rows",
		buildings.size() == 3, str(buildings.size()))
	if buildings.size() != 3:
		return
	var barracks: Dictionary = buildings[0]
	var fort: Dictionary = buildings[1]
	var college: Dictionary = buildings[2]
	_expect("the disrepair building type reports its own flag",
		bool(fort.get("disrepair", false)))
	_expect("a healthy type in the same cell is not dragged into disrepair",
		not bool(barracks.get("disrepair", true))
		and not bool(college.get("disrepair", true)))
	_expect("the fort bonus halves only for the disrepair type",
		String(fort.get("effect", "")) == "守备 +15%",
		String(fort.get("effect", "")))
	_expect("the row exposes its own satisfaction and cover days",
		int(fort.get("satisfaction_bp", -1)) == 5000
		and int(fort.get("cover_days_x10", -2)) == 12, str(fort))
	var text := String(fort.get("maintenance_text", ""))
	_expect("the row shows satisfaction, cover days, disrepair and the reason",
		text.contains("满足 50%") and text.contains("可用 1.2 日")
		and text.contains("失修") and text.contains("缺货"), text)
	_expect("the tooltip spells out the physical maintenance line",
		String(fort.get("tooltip", "")).contains("实物维护"), String(fort.get("tooltip", "")))
	_expect("a healthy row still reports its own satisfaction",
		String(barracks.get("maintenance_text", "")).contains("满足 100%"),
		String(barracks.get("maintenance_text", "")))
	_expect("a row without a maintenance entry stays blank, not 0%",
		String(college.get("maintenance_text", "")).is_empty(),
		String(college.get("maintenance_text", "")))

	# 快照为空（新 DLL 但这一格没有对象 / 维护面未接通）：回落国家级旗标。
	var empty := FakeMilitaryFacade.new()
	empty.catalog_data = _dossier_catalog()
	empty.snapshot_data = _dossier_snapshot(true)
	empty.maintenance_data = []
	var fallback := _dossier_rows(empty)
	_expect("an empty snapshot falls back to the country-wide disrepair flag",
		fallback.size() == 3 and bool((fallback[1] as Dictionary).get("disrepair", false)),
		str(fallback))
	_expect("the fallback keeps the old halved fort bonus",
		String((fallback[1] as Dictionary).get("effect", "")) == "守备 +15%",
		String((fallback[1] as Dictionary).get("effect", "")))

	# 更老的 DLL：门面根本没有 maintenance_snapshot（靠 has_method 守护）。
	var legacy := LegacyMilitaryFacade.new()
	legacy.catalog_data = _dossier_catalog()
	legacy.snapshot_data = _dossier_snapshot(false)
	var legacy_rows := _dossier_rows(legacy)
	_expect("a facade without the snapshot method degrades to the old flag",
		legacy_rows.size() == 3
		and not bool((legacy_rows[1] as Dictionary).get("disrepair", true))
		and String((legacy_rows[1] as Dictionary).get("effect", "")) == "守备 +30%",
		str(legacy_rows))
