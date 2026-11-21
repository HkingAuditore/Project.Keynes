class_name EraAdvancementService
extends RefCounted

const CatalogScript = preload("res://scripts/era/era_advancement_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const FLAG_MILESTONE := 2
const SHARE_UNSET := -1

signal changed(snapshot: Dictionary)
signal era_advanced(old_index: int, new_index: int, buffs: PackedStringArray)

var _country
var _ext: Object
var _handle := 0
var _displayed_era := -1
var _catalog_cache: Dictionary = {}
var _era_tech_indices: Array = []


func bind(country, economy, handle: int, regime_definitions: Array = [],
		opening_policy_sequence: int = 0) -> bool:
	if country == _country and handle == _handle and is_bound():
		return false
	_country = country
	_ext = country.world_ext() if country != null and country.has_method("world_ext") else null
	_handle = handle
	_displayed_era = -1
	_catalog_cache.clear()
	_era_tech_indices.clear()
	if not is_bound() or economy == null:
		return false
	var config := _compile(economy)
	var regimes := {}
	for row in regime_definitions:
		regimes[String(row.id)] = row.get("modifier_definition_keys", PackedStringArray())
	config["political_regimes"] = regimes
	var result := _submit("bind", 0, opening_policy_sequence, config)
	if not bool(result.get("ok", false)):
		_ext = null
		return false
	return true


func release_world() -> Dictionary:
	_country = null
	_ext = null
	_handle = 0
	return {"ok": true}


func is_bound() -> bool:
	return is_instance_valid(_ext) and _handle != 0


func _submit(action: String, day: int, sequence: int, data: Dictionary = {}) -> Dictionary:
	if not is_bound():
		return {"ok": false, "code": "session_unavailable", "message": "玩家国家尚未就绪，请稍后再试。"}
	return _ext.submit_era_advancement(action, _handle, day, sequence, data)


func _view() -> Dictionary:
	return _ext.get_era_advancement_view() if is_bound() else {}


func start(day: int, sequence: int) -> Dictionary:
	return _submit("start", day, sequence)


func pause(day: int, sequence: int) -> Dictionary:
	return _submit("pause", day, sequence)


func resume(day: int, sequence: int) -> Dictionary:
	return _submit("resume", day, sequence)


func set_policy(treasury_share_bp: int, research_share_bp: int, day: int, sequence: int,
		era_share_bp: int = SHARE_UNSET, colonization_share_bp: int = SHARE_UNSET) -> Dictionary:
	return _submit("policy", day, sequence, {
		"treasury_share_bp": treasury_share_bp,
		"research_share_bp": research_share_bp,
		"era_share_bp": era_share_bp,
		"colonization_share_bp": colonization_share_bp,
	})


func policy() -> Dictionary:
	var budget: Dictionary = snapshot().get("budget", {})
	var out := {}
	for key in ["treasury_share_bp", "research_share_bp", "era_share_bp", "colonization_share_bp"]:
		if budget.has(key):
			out[key] = budget[key]
	return out


func refresh(_day: int, _force: bool = false) -> Dictionary:
	var model := snapshot()
	var era := int(model.get("current_era_index", -1))
	if era >= 0:
		var previous := _displayed_era
		_displayed_era = era
		if previous >= 0 and era > previous:
			var buffs := PackedStringArray()
			for target in range(previous + 1, era + 1):
				buffs.append_array(CatalogScript.buff_lines(target, previous == 0 and target == 1))
			era_advanced.emit(previous, era, buffs)
	if not model.is_empty():
		changed.emit(model)
	return model


func snapshot() -> Dictionary:
	var model: Dictionary = _view().get("model", {})
	model.erase("blocked_reason")
	return model


func preview() -> Dictionary:
	return snapshot()


func blocked_reason() -> String:
	var model: Dictionary = _view().get("model", {})
	return String(model.get("blocked_reason", ""))


func to_save() -> Dictionary:
	return _view().get("state", {})


func capture() -> Dictionary:
	return _view().get("save", {})


func stage_restore(state: Dictionary) -> Dictionary:
	return {"ok": true} if state.is_empty() else _submit("restore", 0, 0, state)


func _compile(economy) -> Dictionary:
	var technology_ids: PackedStringArray = _catalog().get("technology_ids", PackedStringArray())
	var good_ids: PackedStringArray = economy.good_ids()
	var eras := []
	var labels := PackedStringArray()
	for key in CatalogScript.CONDITION_KEYS:
		labels.append(CatalogScript.CONDITION_LABELS[key])
	for era in range(mini(CatalogScript.era_count(), CatalogScript.MAX_ERA_INDEX + 1)):
		var goods := CatalogScript.procurement_goods(era)
		for row in goods:
			var index := good_ids.find(String(row.good_id))
			row["index"] = index
			row["name"] = economy.good_display_name(index) if index >= 0 else row.good_id
		eras.append({
			"name": CatalogScript.era_name(era),
			"milestone": technology_ids.find(String(CatalogScript.milestone_id(era))),
			"technology": _era_technologies(era),
			"condition_labels": labels,
			"condition_floor": PackedInt64Array([0, CatalogScript.POPULATION_THRESHOLDS[era],
				CatalogScript.BUILDING_THRESHOLDS[era], CatalogScript.TRADE_ORDER_THRESHOLDS[era]]),
			"condition_per_cell": PackedInt64Array([0, CatalogScript.POPULATION_PER_CELL[era],
				CatalogScript.BUILDINGS_PER_CELL[era], CatalogScript.TRADE_ORDERS_PER_CELL[era]]),
			"goods": goods,
			"buffs": CatalogScript.buff_lines(era, false) if era > 0 else PackedStringArray(),
			"buffs_with_prelude": CatalogScript.buff_lines(era, true) if era > 0 else PackedStringArray(),
		})
	return {"eras": eras, "conditions_required": CatalogScript.CONDITIONS_REQUIRED,
		"technology_ratio": CatalogScript.TECH_COMPLETION_RATIO}


func _catalog() -> Dictionary:
	if not _catalog_cache.is_empty():
		return _catalog_cache
	var catalog: Dictionary = {}
	if _country != null and _country.has_method("native_catalog"):
		catalog = _country.native_catalog()
	if not catalog.has("technology_ids") or not catalog.has("technology_flags"):
		var technology: Dictionary = TechnologyCatalogScript.compile_native_catalog()
		for key in technology:
			if not catalog.has(key):
				catalog[key] = technology[key]
	_catalog_cache = catalog
	return _catalog_cache

func _era_technologies(era_index: int) -> PackedInt32Array:
	if _era_tech_indices.is_empty():
		var catalog := _catalog()
		var era_order: PackedStringArray = catalog.get("technology_era_ids_ordered",
			PackedStringArray())
		var era_ids: PackedStringArray = catalog.get("technology_era_ids", PackedStringArray())
		var flags: PackedInt32Array = catalog.get("technology_flags", PackedInt32Array())
		var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
		var buckets: Array = []
		for _i in range(era_order.size()):
			buckets.append([])
		for technology in range(mini(era_ids.size(), flags.size())):
			if (int(flags[technology]) & FLAG_MILESTONE) != 0:
				continue
			if technology < ids.size() and String(ids[technology]).begins_with("app."):
				continue
			var position := era_order.find(String(era_ids[technology]))
			if position >= 0:
				(buckets[position] as Array).append(technology)
		# Packed arrays are value types: build plain arrays first, convert once.
		for bucket in buckets:
			_era_tech_indices.append(PackedInt32Array(bucket))
	if era_index < 0 or era_index >= _era_tech_indices.size():
		return PackedInt32Array()
	return _era_tech_indices[era_index]
