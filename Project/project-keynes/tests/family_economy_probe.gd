extends Node

## 只读家族经济探针。与 headless_save_replay.gd 同进程运行：回放脚本推进时钟，
## 本节点在每个新的权威提交日采样家族、其持有建筑组与业主 cohort 的账本。
##
##   $env:PK_SAVE_REPLAY = "1"; $env:PK_FAMILY_PROBE = "1"
##   $env:PK_FAMILY_PROBE_EVERY = "1"        # 采样间隔（权威日）
##   $env:PK_FAMILY_PROBE_SCAN_EVERY = "10"  # 全图发现新家族的间隔
##
## 产物写到 <repo>/tmp/family_probe_<stamp>/：families.csv、holdings.csv、events.csv。

const RUNTIME_READY_FRAMES := 4800

var _out_dir := ""
var _families_file: FileAccess
var _holdings_file: FileAccess
var _events_file: FileAccess
var _every := 1
var _scan_every := 10
var _last_sample_day := -1
var _last_scan_day := -1000000
var _known: Dictionary = {}
var _last_rows: Dictionary = {}
var _building_type_ids := PackedStringArray()
var _profession_ids := PackedStringArray()


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_every = maxi(1, int(_env("PK_FAMILY_PROBE_EVERY", "1")))
	_scan_every = maxi(1, int(_env("PK_FAMILY_PROBE_SCAN_EVERY", "10")))
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	_out_dir = ProjectSettings.globalize_path("res://").path_join(
		"../../tmp/family_probe_%s" % stamp).simplify_path()
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_families_file = FileAccess.open(_out_dir.path_join("families.csv"), FileAccess.WRITE)
	_holdings_file = FileAccess.open(_out_dir.path_join("holdings.csv"), FileAccess.WRITE)
	_events_file = FileAccess.open(_out_dir.path_join("events.csv"), FileAccess.WRITE)
	_families_file.store_line(",".join([
		"day", "family_handle", "stable_id", "surname", "founded_day", "home_cell",
		"flags", "decline_reviews", "population", "cash_claim",
		"snapshot_asset_value", "net_worth", "branch_building_asset",
		"owned_buildings", "notable_person_count", "branch_count",
		"home_prestige_level", "home_share_q16", "home_target_share_q16",
		"home_distress_q16", "professions",
	]))
	_holdings_file.store_line(",".join([
		"day", "family_handle", "cell", "building_type", "owner_signature",
		"owner_profession", "owned_count", "family_filled_owner", "group_count",
		"group_filled_owner", "owner_capacity", "operating_state", "last_revenue",
		"last_expected_revenue", "last_operating_cost", "last_wages_paid",
		"realized_margin_q16", "owner_cohort_population", "owner_cohort_funds",
		"owner_cohort_income", "owner_cohort_expense", "owner_cohort_owner_employed",
		"owner_cohort_employee_employed", "family_people_in_cell",
		"family_cash_in_cell", "cell_population", "cell_funds",
	]))
	_events_file.store_line(",".join([
		"day", "event", "family_handle", "stable_id", "surname", "founded_day",
		"home_cell", "last_population", "last_cash_claim", "last_owned_buildings",
		"last_decline_reviews",
	]))
	print("[family-probe] output=%s every=%d scan_every=%d" % [_out_dir, _every, _scan_every])

	var host := await _wait_for_runtime()
	if host == null:
		push_error("[family-probe] runtime never became ready")
		return
	var generator := host.generator()
	var economy = generator.get_economy_facade()
	var ext = generator.get_data_core_world_ext()
	var cell_count := host.current_map().cell_count()
	_building_type_ids = economy.building_type_ids()
	_profession_ids = economy.profession_ids()
	while is_inside_tree():
		await get_tree().process_frame
		var progress: Dictionary = generator.get_runtime_perf_snapshot(0)
		var day := int(progress.get("simulation_committed_day", -1))
		if day < 0 or day == _last_sample_day:
			continue
		if _last_sample_day >= 0 and day - _last_sample_day < _every:
			continue
		_sample(day, economy, ext, cell_count)
		_last_sample_day = day


func _sample(day: int, economy, ext, cell_count: int) -> void:
	if day - _last_scan_day >= _scan_every:
		_last_scan_day = day
		for cell in cell_count:
			var page: Dictionary = ext.get_family_cell_snapshot(cell, 0, 256)
			if not bool(page.get("ok", false)):
				continue
			for handle in page.get("family_handles", PackedInt64Array()):
				if not _known.has(int(handle)):
					_known[int(handle)] = day
					_event(day, "discovered", int(handle), {})
	var building_cache := {}
	var population_cache := {}
	var gone: Array[int] = []
	for handle in _known.keys():
		var snapshot: Dictionary = economy.family_snapshot(int(handle))
		if not bool(snapshot.get("ok", false)):
			gone.append(int(handle))
			continue
		var branches: Dictionary = economy.family_branches(int(handle), 0, 64)
		var branch_cells: PackedInt32Array = branches.get("cell_indices", PackedInt32Array())
		var branch_people: PackedInt64Array = branches.get("populations", PackedInt64Array())
		var branch_cash: PackedInt64Array = branches.get("cash_claims", PackedInt64Array())
		var branch_assets: PackedInt64Array = branches.get("building_asset_values", PackedInt64Array())
		var branch_levels: PackedInt32Array = branches.get("prestige_levels", PackedInt32Array())
		var branch_shares: PackedInt32Array = branches.get("demography_shares_q16", PackedInt32Array())
		var branch_targets: PackedInt32Array = branches.get("target_shares_q16", PackedInt32Array())
		var branch_distress: PackedInt32Array = branches.get("distress_q16", PackedInt32Array())
		var branch_asset_total := 0
		var home_level := 0
		var home_share := 0
		var home_target := 0
		var home_distress := 0
		var home_cell := int(snapshot.get("home_cell", -1))
		for i in branch_cells.size():
			branch_asset_total += int(branch_assets[i]) if i < branch_assets.size() else 0
			if int(branch_cells[i]) == home_cell and i < branch_levels.size():
				home_level = int(branch_levels[i])
				home_share = int(_at(branch_shares, i)) if i < branch_shares.size() else 0
				home_target = int(_at(branch_targets, i)) if i < branch_targets.size() else 0
				home_distress = int(_at(branch_distress, i)) if i < branch_distress.size() else 0
		var professions := PackedStringArray()
		var prof_ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
		var prof_people: PackedInt64Array = snapshot.get("profession_people", PackedInt64Array())
		var prof_owner: PackedInt64Array = snapshot.get("profession_owner_employed", PackedInt64Array())
		var prof_employee: PackedInt64Array = snapshot.get("profession_employee_employed", PackedInt64Array())
		for i in prof_ids.size():
			professions.append("%s:%d/%d/%d" % [prof_ids[i], int(prof_people[i]),
				int(prof_owner[i]) if i < prof_owner.size() else 0,
				int(prof_employee[i]) if i < prof_employee.size() else 0])
		var row := {
			"stable_id": int(snapshot.get("stable_id", 0)),
			"surname": String(snapshot.get("surname", "")),
			"founded_day": int(snapshot.get("founded_day", -1)),
			"home_cell": home_cell,
			"population": int(snapshot.get("population", 0)),
			"cash_claim": int(snapshot.get("cash_claim", 0)),
			"owned_buildings": int(snapshot.get("owned_buildings", 0)),
			"decline_reviews": int(snapshot.get("decline_reviews", 0)),
		}
		_last_rows[int(handle)] = row
		_families_file.store_line(",".join(PackedStringArray([
			str(day), str(handle), str(row.stable_id), _csv(row.surname),
			str(row.founded_day), str(home_cell), str(int(snapshot.get("flags", 0))),
			str(row.decline_reviews), str(row.population), str(row.cash_claim),
			str(int(snapshot.get("productive_asset_value", 0))),
			str(int(snapshot.get("net_worth", 0))), str(branch_asset_total),
			str(row.owned_buildings), str(int(snapshot.get("notable_person_count", 0))),
			str(branch_cells.size()), str(home_level), str(home_share),
			str(home_target), str(home_distress), _csv(";".join(professions)),
		])))
		var industries: Dictionary = economy.family_industries(int(handle), 0, 64)
		var ind_cells: PackedInt32Array = industries.get("cell_indices", PackedInt32Array())
		var ind_types: PackedInt32Array = industries.get("building_type_ids", PackedInt32Array())
		var ind_sigs: PackedInt32Array = industries.get("owner_signature_ids", PackedInt32Array())
		var ind_counts: PackedInt64Array = industries.get("owned_counts", PackedInt64Array())
		var ind_filled: PackedInt64Array = industries.get("filled_owner", PackedInt64Array())
		for i in ind_cells.size():
			var cell := int(ind_cells[i])
			if not building_cache.has(cell):
				building_cache[cell] = ext.get_building_cell_snapshot(cell)
			if not population_cache.has(cell):
				population_cache[cell] = ext.get_population_cell_snapshot(cell, false)
			_holding_row(day, int(handle), cell, int(ind_types[i]), int(ind_sigs[i]),
				int(ind_counts[i]), int(ind_filled[i]), building_cache[cell],
				population_cache[cell], branch_cells, branch_people, branch_cash)
	for handle in gone:
		_event(day, "dissolved", handle, _last_rows.get(handle, {}))
		_known.erase(handle)
		_last_rows.erase(handle)
	_families_file.flush()
	_holdings_file.flush()
	_events_file.flush()


func _holding_row(day: int, handle: int, cell: int, type_id: int, signature: int,
		owned: int, family_filled: int, buildings: Dictionary, population: Dictionary,
		branch_cells: PackedInt32Array, branch_people: PackedInt64Array,
		branch_cash: PackedInt64Array) -> void:
	var group := -1
	var group_types: PackedInt32Array = buildings.get("group_type_ids", PackedInt32Array())
	var group_sigs: PackedInt32Array = buildings.get("owner_signature_ids", PackedInt32Array())
	for g in group_types.size():
		if int(group_types[g]) == type_id and g < group_sigs.size() and int(group_sigs[g]) == signature:
			group = g
			break
	var cohort := -1
	var sigs: PackedInt32Array = population.get("signature_ids", PackedInt32Array())
	for c in sigs.size():
		if int(sigs[c]) == signature:
			cohort = c
			break
	var profession := ""
	if cohort >= 0:
		var prof := int(_at(population.get("profession_ids", PackedInt32Array()), cohort))
		profession = _profession_ids[prof] if prof >= 0 and prof < _profession_ids.size() else str(prof)
	var people_in_cell := 0
	var cash_in_cell := 0
	for i in branch_cells.size():
		if int(branch_cells[i]) == cell:
			people_in_cell = int(branch_people[i])
			cash_in_cell = int(branch_cash[i])
	_holdings_file.store_line(",".join(PackedStringArray([
		str(day), str(handle), str(cell),
		_building_type_ids[type_id] if type_id >= 0 and type_id < _building_type_ids.size() else str(type_id),
		str(signature), profession, str(owned), str(family_filled),
		str(_at(buildings.get("group_counts"), group)),
		str(_at(buildings.get("filled_owner"), group)),
		str(_at(buildings.get("owner_capacity"), group)),
		str(_at(buildings.get("operating_state"), group)),
		str(_at(buildings.get("last_revenue"), group)),
		str(_at(buildings.get("last_expected_revenue"), group)),
		str(_at(buildings.get("last_operating_cost"), group)),
		str(_at(buildings.get("last_wages_paid"), group)),
		str(_at(buildings.get("realized_profit_margin_q16"), group)),
		str(_at(population.get("populations"), cohort)),
		str(_at(population.get("funds_by_cohort"), cohort)),
		str(_at(population.get("epoch_income_by_cohort"), cohort)),
		str(_at(population.get("epoch_expense_by_cohort"), cohort)),
		str(_at(population.get("owner_employed_by_cohort"), cohort)),
		str(_at(population.get("employee_employed_by_cohort"), cohort)),
		str(people_in_cell), str(cash_in_cell),
		str(int(population.get("population", 0))), str(int(population.get("funds", 0))),
	])))


func _event(day: int, kind: String, handle: int, row: Dictionary) -> void:
	_events_file.store_line(",".join(PackedStringArray([
		str(day), kind, str(handle), str(row.get("stable_id", "")),
		_csv(String(row.get("surname", ""))), str(row.get("founded_day", "")),
		str(row.get("home_cell", "")), str(row.get("population", "")),
		str(row.get("cash_claim", "")), str(row.get("owned_buildings", "")),
		str(row.get("decline_reviews", "")),
	])))


func _at(values, index: int):
	if values == null or index < 0 or index >= values.size():
		return ""
	return values[index]


func _csv(text: String) -> String:
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		return "\"%s\"" % text.replace("\"", "\"\"")
	return text


func _wait_for_runtime() -> WorldRuntimeHost:
	for _frame in range(RUNTIME_READY_FRAMES):
		await get_tree().process_frame
		var scene := get_tree().current_scene
		if scene == null or not scene is PlayerGame:
			continue
		var host := scene.get_node_or_null("RuntimeHost") as WorldRuntimeHost
		if host != null and host.current_map() != null and host.generator() != null \
				and bool(host.generator().gameplay_start_report().get("ok", false)):
			await get_tree().process_frame
			return host
	return null


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name).strip_edges()
	return value if not value.is_empty() else fallback
