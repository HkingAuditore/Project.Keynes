class_name CountryFacade
extends RefCounted

signal country_committed(report: Dictionary)
signal research_signal_discovered(event: Dictionary)

const DEFAULT_PROFILE_PATH := "res://data/country/default_country.tres"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryProfileScript = preload("res://scripts/data/country_profile.gd")
const TAX_RATE_MIN_BP := -100000
const TAX_RATE_MAX_BP := 10000
const TAX_ABSOLUTE_MIN := -1000000000
const TAX_ABSOLUTE_MAX := 1000000000
const TAX_MODE_PERCENT_BP := 0
const TAX_MODE_ABSOLUTE := 1

enum Opcode {
	CREATE_COUNTRY = 1,
	RENAME_COUNTRY = 2,
	TRANSFER_TERRITORY = 3,
	GRANT_TECHNOLOGY = 4,
	SET_RESEARCH_WEIGHTS = 5,
	ENQUEUE_RESEARCH = 6,
	REMOVE_RESEARCH = 7,
	MOVE_RESEARCH = 8,
	SET_RESEARCH_BUDGET = 9,
	REVEAL_ALL_TECHNOLOGIES = 10,
	SET_TAX_DEFAULT = 11,
	SET_TAX_OVERRIDE = 12,
	CLEAR_TAX_OVERRIDE = 13,
	DISCOVER_COUNTRY_SIGNAL = 14,
	SET_CELL_TAX_DEFAULT = 15,
	CLEAR_CELL_TAX_DEFAULT = 16,
	SET_CELL_TAX_OVERRIDE = 17,
	CLEAR_CELL_TAX_OVERRIDE = 18,
	CLEAR_CELL_TAX_POLICY = 19,
	CLAIM_UNOWNED_TERRITORY = 20,
}

enum TaxKind {
	INCOME = 0,
	CONSUMPTION = 1,
	BUSINESS = 2,
	IMPORT = 3,
	EXPORT = 4,
}

enum TaxAssessmentMode {
	PERCENT_BP = 0,
	ABSOLUTE = 1,
}

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _configured: bool = false
var _last_event_id: int = 0

func configure(world_ext: Object, cell_count: int, seed: int,
		profile = null, compiled_catalog: Dictionary = {}) -> Dictionary:
	_world_ext = world_ext
	_profile = profile
	if _profile == null:
		_profile = ResourceLoader.load(DEFAULT_PROFILE_PATH, "Resource")
	if _world_ext == null or not _world_ext.has_method("configure_country"):
		return {"ok": false, "reason": "DCWorldExt country API unavailable"}
	if _profile == null:
		return {"ok": false, "reason": "CountryProfile unavailable"}
	_catalog = compiled_catalog.duplicate(true) if not compiled_catalog.is_empty() \
		else EconomyCatalogScript.compile_native_catalog()
	if not bool(_catalog.get("ok", true)):
		return _catalog
	var native_catalog := _catalog.duplicate(false)
	native_catalog.erase("ok")
	var result: Dictionary = _world_ext.configure_country(
		native_catalog, _profile.to_native_profile(), cell_count, seed)
	_configured = bool(result.get("ok", false))
	return result

func bootstrap(is_water: PackedByteArray, packet: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	return _world_ext.bootstrap_country(packet, is_water)

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(),
		"aux_i32": PackedInt32Array(),
		"domain_i32": PackedInt32Array(),
		"position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(),
		"weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(),
		"weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(),
		"tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"stable_ids": PackedStringArray(),
		"display_names": PackedStringArray(),
	}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.target_handles.append(int(command.get("target_handle", 0)))
		batch.cell_indices.append(int(command.get("cell", -1)))
		batch.aux_i32.append(int(command.get("signal", command.get("technology", -1))))
		batch.domain_i32.append(int(command.get("domain", -1)))
		batch.position_i32.append(int(command.get("position", -1)))
		var weights: PackedInt32Array = command.get("weights_bp",
			PackedInt32Array([0, 0, 0, 0]))
		for domain in range(4):
			batch["weight%d_bp" % domain].append(
				int(weights[domain]) if domain < weights.size() else 0)
		batch.value_i64.append(int(command.get("value", 0)))
		batch.tax_kinds.append(int(command.get("tax_kind", -1)))
		batch.tax_item_indices.append(int(command.get("tax_item", -1)))
		batch.tax_rate_basis_points.append(int(command.get(
			"tax_rate_basis_points",
			int(command.get("tax_rate_percent", 0)) * 100)))
		batch.tax_assessment_modes.append(int(command.get(
			"tax_assessment_mode", TAX_MODE_PERCENT_BP)))
		batch.stable_ids.append(String(command.get("stable_id", "")))
		batch.display_names.append(String(command.get("display_name", "")))
	return _world_ext.submit_country_commands(batch)


func submit_observation_batch(handle: int, cells: PackedInt32Array,
		signals: PackedInt32Array, effective_day: int) -> Dictionary:
	if not _configured or cells.size() != signals.size():
		return {"ok": false, "reason": "country_observation_batch_invalid"}
	var n := cells.size()
	if n == 0:
		return {"ok": true, "accepted": 0}
	var batch := {
		"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"cell_indices": cells, "aux_i32": signals, "domain_i32": PackedInt32Array(),
		"position_i32": PackedInt32Array(), "weight0_bp": PackedInt32Array(),
		"weight1_bp": PackedInt32Array(), "weight2_bp": PackedInt32Array(),
		"weight3_bp": PackedInt32Array(), "value_i64": PackedInt64Array(),
		"tax_kinds": PackedInt32Array(), "tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"stable_ids": PackedStringArray(),
		"display_names": PackedStringArray(),
	}
	for key in ["opcodes", "effective_days", "sequences", "target_handles",
			"domain_i32", "position_i32", "weight0_bp", "weight1_bp", "weight2_bp",
			"weight3_bp", "value_i64", "tax_kinds", "tax_item_indices",
			"tax_rate_basis_points", "tax_assessment_modes", "stable_ids",
			"display_names"]:
		batch[key].resize(n)
	for i in range(n):
		batch.opcodes[i] = Opcode.DISCOVER_COUNTRY_SIGNAL
		batch.effective_days[i] = effective_day
		batch.sequences[i] = i
		batch.target_handles[i] = handle
		batch.value_i64[i] = 1
		batch.domain_i32[i] = -1
		batch.position_i32[i] = -1
		batch.tax_kinds[i] = -1
		batch.tax_item_indices[i] = -1
	return _world_ext.submit_country_commands(batch)

func create_country(stable_id: StringName, display_name: String, first_cell: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.CREATE_COUNTRY, "stable_id": String(stable_id),
		"display_name": display_name, "cell": first_cell,
		"effective_day": effective_day, "sequence": sequence}])

func rename_country(handle: int, display_name: String,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.RENAME_COUNTRY, "target_handle": handle,
		"display_name": display_name, "effective_day": effective_day, "sequence": sequence}])

func transfer_territory(cell: int, target_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_TERRITORY, "target_handle": target_handle,
		"cell": cell, "effective_day": effective_day, "sequence": sequence}])

func grant_technology(handle: int, technology_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var ids: PackedStringArray = _catalog.get("technology_ids", PackedStringArray())
	var technology := ids.find(String(technology_id))
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.GRANT_TECHNOLOGY, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence}])

func set_research_weights(handle: int, weights_bp: PackedInt32Array,
		effective_day: int, sequence: int) -> Dictionary:
	if weights_bp.size() != 4:
		return {"ok": false, "reason": "research weights require four domains"}
	return submit([{"opcode": Opcode.SET_RESEARCH_WEIGHTS, "target_handle": handle,
		"weights_bp": weights_bp, "effective_day": effective_day, "sequence": sequence}])

func enqueue_research(handle: int, technology_id: StringName, domain: int,
		position: int, effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.ENQUEUE_RESEARCH, "target_handle": handle,
		"technology": technology, "domain": domain, "position": position,
		"effective_day": effective_day, "sequence": sequence}])

func remove_research(handle: int, technology_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.REMOVE_RESEARCH, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence}])

func move_research(handle: int, technology_id: StringName, domain: int,
		position: int, effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.MOVE_RESEARCH, "target_handle": handle,
		"technology": technology, "domain": domain, "position": position,
		"effective_day": effective_day, "sequence": sequence}])

func set_research_budget(handle: int, enabled: bool, daily_cash_limit: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.SET_RESEARCH_BUDGET, "target_handle": handle,
		"technology": 1 if enabled else 0, "value": maxi(0, daily_cash_limit),
		"effective_day": effective_day, "sequence": sequence}])

func reveal_all_technologies(handle: int, effective_day: int,
		sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.REVEAL_ALL_TECHNOLOGIES,
		"target_handle": handle, "effective_day": effective_day, "sequence": sequence}])

func discover_research_signal(handle: int, signal_id: StringName, cell: int,
		source_kind: int, effective_day: int, sequence: int) -> Dictionary:
	var ids: PackedStringArray = _catalog.get("research_signal_ids", PackedStringArray())
	var signal_index := ids.find(String(signal_id))
	if signal_index < 0:
		return {"ok": false, "reason": "unknown research signal id: %s" % String(signal_id)}
	return submit([{
		"opcode": Opcode.DISCOVER_COUNTRY_SIGNAL,
		"target_handle": handle,
		"signal": signal_index,
		"cell": cell,
		"value": source_kind,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func _tax_value_valid(mode: int, value: int) -> bool:
	if mode == TAX_MODE_ABSOLUTE:
		return value >= TAX_ABSOLUTE_MIN and value <= TAX_ABSOLUTE_MAX
	if mode == TAX_MODE_PERCENT_BP:
		return value >= TAX_RATE_MIN_BP and value <= TAX_RATE_MAX_BP
	return false


func set_tax_default(handle: int, kind: int, rate_percent: int,
		effective_day: int, sequence: int) -> Dictionary:
	return set_tax_default_basis_points(
		handle, kind, rate_percent * 100, effective_day, sequence)


func set_tax_default_basis_points(handle: int, kind: int, rate_basis_points: int,
		effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_TAX_DEFAULT,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func set_tax_override(handle: int, kind: int, item_id: StringName,
		rate_percent: int, effective_day: int, sequence: int) -> Dictionary:
	return set_tax_override_basis_points(
		handle, kind, item_id, rate_percent * 100, effective_day, sequence)


func set_tax_override_basis_points(handle: int, kind: int, item_id: StringName,
		rate_basis_points: int, effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_TAX_OVERRIDE,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_tax_override(handle: int, kind: int, item_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	return submit([{
		"opcode": Opcode.CLEAR_TAX_OVERRIDE,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func tax_policy_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_tax_policy_snapshot(handle) if _configured else {}


func set_cell_tax_default(handle: int, cell: int, kind: int, rate_percent: int,
		effective_day: int, sequence: int) -> Dictionary:
	return set_cell_tax_default_basis_points(
		handle, cell, kind, rate_percent * 100, effective_day, sequence)


func set_cell_tax_default_basis_points(handle: int, cell: int, kind: int,
		rate_basis_points: int, effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_CELL_TAX_DEFAULT,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_cell_tax_default(handle: int, cell: int, kind: int,
		effective_day: int, sequence: int) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	return submit([{
		"opcode": Opcode.CLEAR_CELL_TAX_DEFAULT,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func set_cell_tax_override(handle: int, cell: int, kind: int,
		item_id: StringName, rate_percent: int, effective_day: int,
		sequence: int) -> Dictionary:
	return set_cell_tax_override_basis_points(
		handle, cell, kind, item_id, rate_percent * 100,
		effective_day, sequence)


func set_cell_tax_override_basis_points(handle: int, cell: int, kind: int,
		item_id: StringName, rate_basis_points: int, effective_day: int,
		sequence: int, assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_CELL_TAX_OVERRIDE,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_cell_tax_override(handle: int, cell: int, kind: int,
		item_id: StringName, effective_day: int, sequence: int) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	return submit([{
		"opcode": Opcode.CLEAR_CELL_TAX_OVERRIDE,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_cell_tax_policy(handle: int, cell: int, effective_day: int,
		sequence: int) -> Dictionary:
	return submit([{
		"opcode": Opcode.CLEAR_CELL_TAX_POLICY,
		"target_handle": handle,
		"cell": cell,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func cell_tax_policy_snapshot(cell: int) -> Dictionary:
	return _world_ext.get_country_cell_tax_policy_snapshot(cell) \
		if _configured and _world_ext.has_method( \
			"get_country_cell_tax_policy_snapshot") else {}


func fiscal_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_fiscal_snapshot(handle) if _configured \
			and _world_ext.has_method("get_country_fiscal_snapshot") else {}


func _tax_item_index(kind: int, item_id: StringName) -> int:
	var key := ""
	match kind:
		TaxKind.INCOME:
			key = "profession_ids"
		TaxKind.CONSUMPTION, TaxKind.IMPORT, TaxKind.EXPORT:
			key = "good_ids"
		TaxKind.BUSINESS:
			key = "building_type_ids"
		_:
			return -1
	var ids: PackedStringArray = _catalog.get(key, PackedStringArray())
	return ids.find(String(item_id))

func research_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_research_snapshot(handle) if _configured else {}

func research_signal_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_research_signal_snapshot(handle) if _configured \
			and _world_ext.has_method("get_country_research_signal_snapshot") else {}


func has_completed_technology(handle: int, dense_id: int) -> bool:
	return _configured and _world_ext.has_method("has_completed_country_technology") \
		and _world_ext.has_completed_country_technology(handle, dense_id)

func _technology_index(technology_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("technology_ids", PackedStringArray())
	return ids.find(String(technology_id))

func cell_summary(cell: int) -> Dictionary:
	return _world_ext.get_country_cell_summary(cell) if _configured else {}

func snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_snapshot(handle) if _configured else {}

func treasury_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_treasury_snapshot(handle) if _configured else {}


func bind_era_reward_player_country(handle: int) -> Dictionary:
	return _world_ext.bind_era_reward_player_country(handle) if _configured \
		and _world_ext.has_method("bind_era_reward_player_country") else {
			"ok": false, "reason": "era_reward_runtime_unavailable"}


func era_reward_offer() -> Dictionary:
	return _world_ext.get_era_reward_offer() if _configured \
		and _world_ext.has_method("get_era_reward_offer") else {
			"ok": false, "reason": "era_reward_runtime_unavailable"}


func choose_era_reward(offer_generation: int, choice_index: int,
		effective_day: int) -> Dictionary:
	return _world_ext.choose_era_reward(offer_generation, choice_index,
		effective_day) if _configured and _world_ext.has_method(
			"choose_era_reward") else {
				"ok": false, "reason": "era_reward_runtime_unavailable"}

func report() -> Dictionary:
	return _world_ext.get_country_report() if _configured else {"configured": false}


func ui_snapshot(handle: int, section_mask: int) -> Dictionary:
	return _world_ext.get_country_ui_snapshot(handle, section_mask) if _configured \
		and _world_ext.has_method("get_country_ui_snapshot") else {
			"ok": false, "reason": "country_ui_snapshot_unavailable"}

func dispatch_committed_events(result: Dictionary) -> void:
	# Runtime graph 一次 pulse 可能跨过多个 country slice；此时 report 是
	# 最后一个 slice 的摘要，其 changed_cells 可能已被后续纯研究/税表提交
	# 覆盖为 0。领土事件流才是这个 generation 间隔内是否发生过领土
	# 变更的可靠证据，必须先 poll 再决定是否广播。
	if not _configured:
		return
	var events: Dictionary = _world_ext.poll_country_events(_last_event_id, 512)
	var ids: PackedInt64Array = events.get("event_ids", PackedInt64Array())
	if not ids.is_empty():
		_last_event_id = int(ids[ids.size() - 1])
	var opcodes: PackedInt32Array = events.get("opcodes", PackedInt32Array())
	var handles: PackedInt64Array = events.get("country_handles", PackedInt64Array())
	var cells: PackedInt32Array = events.get("cells", PackedInt32Array())
	var signal_ids: PackedInt32Array = events.get("signal_ids", PackedInt32Array())
	var sources: PackedInt32Array = events.get("signal_source_kinds", PackedInt32Array())
	var evidence_deltas: PackedInt32Array = events.get("evidence_deltas", PackedInt32Array())
	var territory_cells: Dictionary = {}
	for i in opcodes.size():
		var opcode := int(opcodes[i])
		if opcode == Opcode.CREATE_COUNTRY \
				or opcode == Opcode.TRANSFER_TERRITORY \
				or opcode == Opcode.CLAIM_UNOWNED_TERRITORY:
			var territory_cell := int(cells[i]) if i < cells.size() else -1
			if territory_cell >= 0:
				territory_cells[territory_cell] = true
		if opcode != Opcode.DISCOVER_COUNTRY_SIGNAL:
			continue
		research_signal_discovered.emit({
			"country_handle": int(handles[i]) if i < handles.size() else 0,
			"cell": int(cells[i]) if i < cells.size() else -1,
			"signal": int(signal_ids[i]) if i < signal_ids.size() else -1,
			"source_kind": int(sources[i]) if i < sources.size() else 0,
			"evidence_delta": int(evidence_deltas[i]) if i < evidence_deltas.size() else 1,
		})
	var normalized := result.duplicate(true)
	if not territory_cells.is_empty():
		normalized["changed_cells"] = maxi(
			int(normalized.get("changed_cells", 0)), territory_cells.size())
		normalized["changed_countries"] = maxi(
			int(normalized.get("changed_countries", 0)), 1)
	if int(normalized.get("changed_countries", 0)) <= 0 \
			and int(normalized.get("changed_cells", 0)) <= 0:
		return
	country_committed.emit(normalized)

func is_configured() -> bool:
	return _configured

func world_ext() -> Object:
	return _world_ext

func native_catalog() -> Dictionary:
	return _catalog.duplicate(false)

func begin_save(chunk_bytes: int = -1) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	return _world_ext.begin_country_save(
		int(_profile.save_chunk_bytes) if chunk_bytes < 0 else chunk_bytes)

func read_save_chunk(chunk_bytes: int = -1) -> PackedByteArray:
	if not _configured:
		return PackedByteArray()
	return _world_ext.read_country_save_chunk(
		int(_profile.save_chunk_bytes) if chunk_bytes < 0 else chunk_bytes)

func end_save() -> Dictionary:
	return _world_ext.end_country_save() if _configured else {"ok": false, "reason": "not configured"}

func restore_bytes(bytes: PackedByteArray, chunk_bytes: int = 4194304) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	var begun: Dictionary = _world_ext.begin_country_restore()
	if not bool(begun.get("ok", false)):
		return begun
	var cursor := 0
	while cursor < bytes.size():
		var fed: Dictionary = _world_ext.feed_country_restore_chunk(
			bytes.slice(cursor, mini(cursor + chunk_bytes, bytes.size())))
		if not bool(fed.get("ok", false)):
			return fed
		cursor += chunk_bytes
	return _world_ext.end_country_restore()
