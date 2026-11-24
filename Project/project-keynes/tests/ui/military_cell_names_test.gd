extends SceneTree

## 军事面板的地块名数据源。
##
## 回归的缺陷：`MilitaryViewModel.cell_name()` 读的 `cell_names` 只有测试夹具会填，
## 生产环境没有任何地方装配它，于是兵营行、训练行、割地表一律写「未命名地块」——
## 一句话重复在整张表上，既不是名字也不提供定位信息（2026-11-20 玩家截图）。
##
## 现在：`CountryViewModel.build_military_model()` 从 Economy 的具名聚落快照装一份
## `cell_names` 进军事段，`MilitaryViewModel` 按「具名聚落 > 地区名 > 地块 N」取名。
##
## 这个测试钉住四件事：
##   1. 快照里 `name_active` 的格子才进表，未命名的占位行不许混进来；
##   2. 增量 delta 能补名字，`full_snapshot` 能整表替换，读失败保留上一份；
##   3. 名字进的是**军事段**， dossier 那种只拿 `model["military"]` 的调用面也能读到；
##   4. 取名链的降级顺序与割地表的判定（没有聚落名 → 只写地区名）。

const SETTLEMENT_CELL := 10
const UNNAMED_CELL := 11
const DELTA_CELL := 12
const REGION_ONLY_CELL := 20
const BARE_CELL := 99

var _failures := 0


class EconomyStub extends RefCounted:
	var first: Dictionary = {}
	var delta: Dictionary = {}
	var fail := false
	var calls: Array = []

	func settlement_delta(since: int) -> Dictionary:
		calls.append(since)
		if fail:
			return {"ok": false, "reason": "economy_read_view_pending"}
		return first if since < 0 else delta


class GeneratorStub extends RefCounted:
	var economy = null
	var military = null
	## cell -> 作者地区名
	var regions: Dictionary = {}

	func get_economy_facade():
		return economy

	func get_military_facade():
		return military

	func region_name_for_cell(cell: int) -> String:
		return String(regions.get(cell, ""))


## 走「军事段可用」的主路径：名字表必须跟着那条重新赋值的 section 一起交出去。
class MilitaryFacadeStub extends RefCounted:
	func is_configured() -> bool:
		return true

	func catalog() -> Dictionary:
		return {"ok": true, "units": []}

	func catalog_view() -> Dictionary:
		return {}

	func country_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "has_policy": true, "config_share_bp": PackedInt32Array()}

	func armies(_country: int) -> Array:
		return []

	func maintenance_supported() -> bool:
		return false


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error(label)


static func _rows(cells: Array, names: Array, active: Array, revision: int,
		full: bool) -> Dictionary:
	return {
		"ok": true, "revision": revision, "full_snapshot": full,
		"cell_indices": PackedInt32Array(cells),
		"settlement_names": PackedStringArray(names),
		"name_active": PackedByteArray(active),
	}


func _run() -> void:
	# Load the display scripts during the fixture, after the autoloads are ready.
	# Preloading this dependency graph leaves resources alive at headless shutdown.
	var country_script := load("res://scripts/ui/country_view_model.gd") as GDScript
	var military_script := load("res://scripts/ui/military_view_model.gd") as GDScript
	var vm = country_script.new()
	var generator := GeneratorStub.new()
	var economy := EconomyStub.new()
	economy.first = _rows([SETTLEMENT_CELL, UNNAMED_CELL], ["青川城", "废村"],
		[1, 0], 1, true)
	economy.delta = _rows([DELTA_CELL], ["河口渡"], [1], 2, false)
	generator.economy = economy
	generator.regions = {REGION_ONLY_CELL: "北岸", SETTLEMENT_CELL: "青川"}
	vm._generator = generator

	# ---- 1. 快照装表：只收 name_active 的格子 ----
	var model := {}
	var section: Dictionary = vm.build_military_model(42, model)
	var names: Dictionary = section.get("cell_names", {})
	_expect("the settlement snapshot seeds the cell-name table",
		String(names.get(SETTLEMENT_CELL, "")) == "青川城")
	_expect("unnamed settlement rows stay out of the table",
		not names.has(UNNAMED_CELL))
	_expect("names ride on the military section, not only the top-level model",
		model.get("military", null) is Dictionary
			and (model["military"] as Dictionary).has("cell_names"))
	_expect("the first read asks for a full snapshot", int(economy.calls[0]) < 0)

	# ---- 2. 增量与整表替换 ----
	var second: Dictionary = vm.build_military_model(42, model)
	var patched: Dictionary = second.get("cell_names", {})
	_expect("an incremental delta adds the new settlement",
		String(patched.get(DELTA_CELL, "")) == "河口渡")
	_expect("the delta keeps the earlier names",
		String(patched.get(SETTLEMENT_CELL, "")) == "青川城")
	_expect("the delta is requested from the cached revision",
		int(economy.calls[1]) == 1)

	economy.first = _rows([30], ["北港"], [1], 9, true)
	economy.delta = _rows([30], ["北港"], [1], 9, true)
	var replaced: Dictionary = vm.build_military_model(42, model).get("cell_names", {})
	_expect("a full snapshot replaces the table instead of merging",
		String(replaced.get(30, "")) == "北港" and not replaced.has(SETTLEMENT_CELL))

	# ---- 3. 读失败保留上一份（worker 忙时不能整列变空） ----
	economy.fail = true
	var stale: Dictionary = vm.build_military_model(42, model).get("cell_names", {})
	_expect("a failed read keeps the previous table",
		String(stale.get(30, "")) == "北港")

	# ---- 4. 取名链：具名聚落 > 地区名 > 地块序号 ----
	var military_vm = military_script.new()
	military_vm.configure({
		"military": {
			"available": true, "reason": "", "facade": null, "generator": generator,
			"map": null, "country_handle": 42, "tech_gate_known": false,
			"cell_names": {SETTLEMENT_CELL: "青川城", DELTA_CELL: "河口渡"},
			"catalog": {"units": [], "categories": [], "militia_unit": -1},
			"armies": [], "snapshot": {"ok": true},
		},
		"country_handle": 42,
	})
	_expect("a named settlement wins over the region",
		String(military_vm.cell_name(SETTLEMENT_CELL)) == "青川城")
	_expect("a cell without a settlement falls back to its region",
		String(military_vm.cell_name(REGION_ONLY_CELL)) == "北岸")
	_expect("a cell with neither falls back to the index, not 未命名地块",
		String(military_vm.cell_name(BARE_CELL)) == "地块 99")
	_expect("settlement_name exposes the raw name for the cession label",
		String(military_vm.settlement_name(SETTLEMENT_CELL)) == "青川城"
			and String(military_vm.settlement_name(REGION_ONLY_CELL)).is_empty())
	_expect("a region-only cession cell labels by region alone",
		String(military_vm.cession_label(REGION_ONLY_CELL, PackedInt32Array())) == "北岸")
	_expect("a settlement cession cell labels with both",
		String(military_vm.cession_label(SETTLEMENT_CELL, PackedInt32Array()))
			.contains("青川城"))

	# ---- 5. 夹具兼容：顶层的 cell_names 仍然认 ----
	var fixture_vm = military_script.new()
	fixture_vm.configure({
		"military": {"available": true, "reason": "", "generator": null, "map": null,
			"catalog": {"units": [], "categories": []}, "armies": [],
			"snapshot": {"ok": true}},
		"cell_names": {3: "北岸"},
		"country_handle": 1,
	})
	_expect("top-level cell_names keeps the screenshot fixtures working",
		String(fixture_vm.cell_name(3)) == "北岸")

	# ---- 6. 主路径（军事段可用）也要带名字表 ----
	# `build_military_model` 在通过快照检查后会**重新赋值** section；名字表如果只写在
	# 开头那个字面量里，可用状态下就会整份丢掉（这条曾经真的漏了）。
	generator.military = MilitaryFacadeStub.new()
	var live_model := {}
	var live_section: Dictionary = vm.build_military_model(42, live_model)
	_expect("the available military section stays available",
		bool(live_section.get("available", false)))
	_expect("the available military section carries the cell-name table",
		live_section.get("cell_names", null) is Dictionary
			and (live_section["cell_names"] as Dictionary).size() >= 1)
	var live_vm = military_script.new()
	live_vm.configure(live_model)
	_expect("the workspace reads names on the available path",
		live_vm.cell_name_count() >= 1
			and String(live_vm.cell_name(30)) == "北港")

	print("military cell names: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
