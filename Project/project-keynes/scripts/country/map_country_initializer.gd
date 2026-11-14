extends "res://scripts/simulation/generator_context.gd"

const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const TriggerFacadeScript = preload("res://scripts/trigger/trigger_facade.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const IdeologyFacadeScript = preload("res://scripts/ideology/ideology_facade.gd")
const StarterSettlementBootstrapScript = preload("res://scripts/economy/starter_settlement_bootstrap.gd")
const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const MilitaryFacadeScript = preload("res://scripts/military/military_facade.gd")
const MilitaryDailySystemScript = preload("res://scripts/simulation/systems/military_daily_system.gd")
const CountryAiFacadeScript = preload("res://scripts/country/country_ai_facade.gd")

const IDEOLOGY_CATALOG_PATH := "res://data/ideologies/default_ideology_catalog.tres"

## 第 5 批：国家、领土、起始国家与军事初始化。可变状态仍由 MapGenerator 持有。

func _setup_economy_runtime(map: MapData, cfg: MapConfig, scheduler_profile) -> void:
	_generator._economy_facade = null
	_generator._economy_daily_job = null
	_generator._country_facade = null
	_generator._country_ai_facade = null
	if _generator._data_core_world_ext != null:
		_generator._data_core_world_ext.set_country_ai_mode("OFF")
	_generator._country_daily_job = null
	_generator._modifier_facade = null
	_generator._modifier_daily_job = null
	_generator._natural_resource_regen_factors_valid = false
	_generator._natural_resource_regen_factor_prime_ms = 0.0
	_generator._trigger_facade = null
	_generator._trigger_daily_job = null
	_generator._ideology_facade = null
	_generator._ideology_daily_job = null
	if _generator._data_core_world_ext == null:
		# No large GDScript fallback: an unavailable native authority leaves the
		# economy explicitly disabled while environmental simulation continues.
		print("[economy] native DCWorldExt economy API unavailable; economy disabled")
		return
	var seed_value := int(cfg.seed) if cfg != null else 0
	_generator._modifier_facade = ModifierFacadeScript.new()
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("_modifier_facade.configure(")
	var modifier_configured: Dictionary = _generator._modifier_facade.configure(
		_generator._data_core_world_ext, map.cell_count(), _generator._world_clock_ref)
	if not bool(modifier_configured.get("ok", false)):
		push_error("[modifier] configure failed: %s" % String(
			modifier_configured.get("reason", "unknown")))
		_generator._modifier_facade = null
		return
	# Resource regeneration factors are derived from the Economy modifier domain.
	# Keep the packed table across daily passes and invalidate it only when the
	# modifier journal reports an Economy-domain mutation. The native getter also
	# owns an equivalent cache, but avoiding the GDScript/C++ payload round-trip
	# removes a full resource_count*n_cells Variant copy from every resource day.
	var modifier_events_callback := Callable(_generator, "_on_modifier_events_available")
	if not _generator._modifier_facade.modifier_events_available.is_connected(modifier_events_callback):
		_generator._modifier_facade.modifier_events_available.connect(modifier_events_callback)
	if true and _generator._gameplay_event_bus != null:
		_generator._trigger_facade = TriggerFacadeScript.new()
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("_trigger_facade.configure(")
		var trigger_configured: Dictionary = _generator._trigger_facade.configure(
			_generator._data_core_world_ext, _generator._gameplay_event_bus, _generator._world_clock_ref, _generator._modifier_facade)
		if not bool(trigger_configured.get("ok", false)):
			push_error("[trigger] configure failed: %s" % String(trigger_configured.get("reason", "unknown")))
			_generator._trigger_facade = null
	_generator._country_facade = CountryFacadeScript.new()
	# Transient A/B knobs are applied to the facade profile for this world only;
	# the .tres resource is never saved or mutated by the runtime contract.
	var country_profile = ResourceLoader.load(
		CountryFacadeScript.DEFAULT_PROFILE_PATH, "Resource")
	if country_profile != null:
		if Engine.has_meta(&"country_full_diagnostics"):
			country_profile.country_full_diagnostics = bool(
				Engine.get_meta(&"country_full_diagnostics"))
		if Engine.has_meta(&"country_light_report_enabled"):
			country_profile.country_light_report_enabled = bool(
				Engine.get_meta(&"country_light_report_enabled"))
		if Engine.has_meta(&"country_pending_queue_enabled"):
			country_profile.country_pending_queue_enabled = bool(
				Engine.get_meta(&"country_pending_queue_enabled"))
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("_country_facade.configure(")
	var country_configured: Dictionary = _generator._country_facade.configure(
		_generator._data_core_world_ext, map.cell_count(), seed_value, country_profile)
	if not bool(country_configured.get("ok", false)):
		push_error("[country] configure failed: %s" % String(country_configured.get("reason", "unknown")))
		_generator._country_facade = null
		return
	if _generator._save_restore_preparation_enabled:
		_generator._save_restore_seed = seed_value
		print("[save/restore] country configured without bootstrap; awaiting PKCN")
		return
	var country_packet := _build_gameplay_country_packet() \
		if not _generator._gameplay_start_context.is_empty() else {}
	if not _generator._gameplay_start_context.is_empty() and country_packet.is_empty():
		_generator._gameplay_start_report = {"ok": false, "code": "country_packet_failed",
			"message": "无法建立玩家国家。"}
		_generator._country_facade = null
		return
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("_country_facade.bootstrap(map.is_water_arr, country_packet)")
	var country_bootstrapped: Dictionary = _generator._country_facade.bootstrap(map.is_water_arr, country_packet)
	if not bool(country_bootstrapped.get("ok", false)):
		push_error("[country] bootstrap failed: %s" % String(
			country_bootstrapped.get("reason", "unknown")))
		_generator._country_facade = null
		return
	await _generator._yield_generation_frame()
	var economy_configured: Dictionary = await _configure_economy_runtime_cooperative(map, seed_value)
	if not bool(economy_configured.get("ok", false)):
		push_error("[economy] configure failed: %s" % String(
			economy_configured.get("reason", "unknown")))
		return
	var ideology_facade := IdeologyFacadeScript.new()
	await _generator._yield_generation_frame()
	var ideology_catalog: Resource = await _load_ideology_catalog_cooperative()
	_generator._loading_profile_step("ideology_facade.configure(")
	var ideology_configured: Dictionary = ideology_facade.configure(
		_generator._data_core_world_ext, _generator._country_facade.native_catalog(), ideology_catalog,
		_generator._economy_facade.native_catalog(), seed_value)
	if bool(ideology_configured.get("ok", false)):
		_generator._ideology_facade = ideology_facade
	else:
		push_error("[ideology] configure failed: %s" % String(
			ideology_configured.get("reason", "unknown")))
	if not _generator._gameplay_start_context.is_empty():
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("country_ai_init")
		_configure_country_ai(map, seed_value, _gameplay_player_country_handles())
		await _generator._yield_generation_frame()
	# Production bootstrap remains empty. The explicit test fixture is a
	# generation-time cold path and never becomes a historical population source.
	var population_packet: Dictionary = {}
	var market_packet: Dictionary = {}
	var building_packet: Dictionary = {}
	var test_bootstrap_report: Dictionary = {}
	var starter_bootstrap_report: Dictionary = {}
	if not _generator._gameplay_start_context.is_empty():
		var country_starts: Array[Dictionary] = []
		for start in _generator._gameplay_start_context.get("country_starts", []):
			country_starts.append((start as Dictionary).duplicate(true))
		_generator._loading_profile_step("starter_settlements")
		starter_bootstrap_report = StarterSettlementBootstrapScript.build_many(
			map, _generator._economy_facade, country_starts)
		if not bool(starter_bootstrap_report.get("ok", false)):
			_generator._gameplay_start_report = starter_bootstrap_report.duplicate(true)
			_generator._economy_facade = null
			return
		population_packet = starter_bootstrap_report.get("population_packet", {})
		market_packet = starter_bootstrap_report.get("market_packet", {})
		building_packet = starter_bootstrap_report.get("building_packet", {})
	elif _generator._test_economy_bootstrap_enabled:
		test_bootstrap_report = EconomyTestBootstrapScript.build(
			map, _generator._economy_facade, seed_value, _generator._test_economy_population_scale)
		if not bool(test_bootstrap_report.get("ok", false)):
			push_error(("[economy] test bootstrap failed: %s "
				+ "candidate_regions=%d skipped_regions=%d details=%s diagnostics=%s") % [
				String(test_bootstrap_report.get("reason", "unknown")),
				int(test_bootstrap_report.get("candidate_component_count", 0)),
				(test_bootstrap_report.get("skipped_components", []) as Array).size(),
				str(test_bootstrap_report.get("skipped_components", [])),
				str(test_bootstrap_report.get("source_diagnostics", {})),
			])
			_generator._economy_facade = null
			return
		population_packet = test_bootstrap_report.get("population_packet", {})
		market_packet = test_bootstrap_report.get("market_packet", {})
		building_packet = test_bootstrap_report.get("building_packet", {})
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("_economy_facade.bootstrap(")
	var bootstrapped: Dictionary = _generator._economy_facade.bootstrap(
		population_packet, market_packet, building_packet)
	if not bool(bootstrapped.get("ok", false)):
		push_error("[economy] bootstrap failed: %s" % String(bootstrapped.get("reason", "unknown")))
		_generator._economy_facade = null
		return


	# Prime modifier-derived resource factors during generation/setup. The table is
	# immutable between Economy-domain modifier events, so the first gameplay day
	# does not pay a synchronous resource_count*n_cells bridge lookup.
	_generator._prime_natural_resource_regen_factors(map.cell_count())
	# Register only after both native authorities have accepted their bootstrap
	# packets. Country remains ordered before economy in the daily graph.
	var registered: Dictionary = _generator._get_map_rules_initializer()._register_country_economy_systems(scheduler_profile)
	if not bool(registered.get("ok", false)):
		push_error("[economy] scheduler registration failed: %s" % String(
			registered.get("reason", "unknown")))
		return
	# Military consumes Country territory/treasury + Economy good/profession
	# dense ids, so it configures only after both bootstraps succeeded. An older
	# DLL without the military API is reported once and skipped silently.
	var military_configured: Dictionary = _configure_military_runtime(
		map, cfg, seed_value)
	if bool(military_configured.get("ok", false)):
		_arm_military_ai(_gameplay_player_country_handles())
	var economy_report: Dictionary = _generator._economy_facade.report()
	print(("[economy] %s native graph cells=%d goods=%d cohorts=%d epoch_days=%d "
			+ "trade=%s topology_ready=%s topology_generation=%d "
			+ "bootstrap=%s founder_families=%d founder_people=%d") % [
		String(economy_report.get("market_runtime_mode", "OFF")),
		map.cell_count(),
		int(bootstrapped.get("good_count", 0)),
		int(bootstrapped.get("cohort_count", 0)),
		int(bootstrapped.get("epoch_days", 1)),
		String(economy_report.get("trade_runtime_mode", "OFF")),
		str(bool(economy_report.get("trade_topology_ready", false))),
		int(economy_report.get("trade_topology_generation", 0)),
		String(starter_bootstrap_report.get("source", "none")),
		int(bootstrapped.get("founder_family_count", 0)),
		int(bootstrapped.get("founder_person_count", 0)),
	])
	print("[country] %s native authority countries=%d cells=%d generation=%d" % [
		String(country_bootstrapped.get("runtime_mode", "OFF")),
		int(country_bootstrapped.get("country_count", 0)), map.cell_count(),
		int(country_bootstrapped.get("generation", 0)),
	])
	if not _generator._gameplay_start_context.is_empty():
		_generator._gameplay_start_report["country_count"] = int(country_bootstrapped.get("country_count", 0))
		_generator._gameplay_start_report["total_population"] = int(starter_bootstrap_report.get("total_population", 0))
		_generator._gameplay_start_report["settlement_count"] = int(
			starter_bootstrap_report.get("settlement_count", 0))
		_generator._gameplay_start_report["settlement_source"] = String(starter_bootstrap_report.get("source", ""))
		_generator._gameplay_start_report["founder_family_count"] = int(
			bootstrapped.get("founder_family_count", 0))
		_generator._gameplay_start_report["founder_person_count"] = int(
			bootstrapped.get("founder_person_count", 0))
	if _generator._test_economy_bootstrap_enabled:
		print(("[economy/test-bootstrap] scale_mode=%s populated_cells=%d population=%d cohorts=%d "
			+ "professions=%d/%d building_groups=%d building_types=%d/%d "
			+ "capacity_buildings=%d->%d trimmed=%d population_range=%d..%d cap=%d goods=%d "
			+ "tiers=%s construction_regions=%d/%d skipped=%d") % [
			String(test_bootstrap_report.get("population_scale_mode", "capacity")),
			int(test_bootstrap_report.get("populated_cells", 0)),
			int(test_bootstrap_report.get("total_population", 0)),
			int(test_bootstrap_report.get("cohort_count", 0)),
			int(test_bootstrap_report.get("generated_profession_count", 0)),
			int(test_bootstrap_report.get("catalog_profession_count", 0)),
			int(test_bootstrap_report.get("building_group_count", 0)),
			int(test_bootstrap_report.get("placed_building_type_count", 0)),
			int(test_bootstrap_report.get("building_type_count", 0)),
			int(test_bootstrap_report.get("basic_capacity_initial_buildings", 0)),
			int(test_bootstrap_report.get("basic_capacity_final_buildings", 0)),
			int(test_bootstrap_report.get("basic_capacity_trimmed_buildings", 0)),
			int(test_bootstrap_report.get("carrying_capacity_min", 0)),
			int(test_bootstrap_report.get("carrying_capacity_max", 0)),
			int(test_bootstrap_report.get("cell_population_cap", 0)),
			int(test_bootstrap_report.get("good_count", 0)),
			str(test_bootstrap_report.get("population_tier_counts", {})),
			int(test_bootstrap_report.get("construction_source_component_count", 0)),
			int(test_bootstrap_report.get(
				"construction_source_candidate_component_count", 0)),
			(test_bootstrap_report.get(
				"construction_source_skipped_components", []) as Array).size(),
		])



func _load_ideology_catalog_cooperative() -> Resource:
	# IdeologyCatalog is a large authored resource with many subresources. Start
	# its threaded load before the configure call so resource parsing does not
	# occupy one render frame; the catalog remains the same runtime authority.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return ResourceLoader.load(IDEOLOGY_CATALOG_PATH, "Resource") as Resource
	ResourceLoader.load_threaded_request(IDEOLOGY_CATALOG_PATH, "Resource")
	while ResourceLoader.load_threaded_get_status(IDEOLOGY_CATALOG_PATH) == \
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await _generator._yield_generation_frame()
	if ResourceLoader.load_threaded_get_status(IDEOLOGY_CATALOG_PATH) == \
			ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(IDEOLOGY_CATALOG_PATH) as Resource
	return ResourceLoader.load(IDEOLOGY_CATALOG_PATH, "Resource") as Resource


func _configure_economy_runtime(map: MapData, seed_value: int) -> Dictionary:
	if map == null or _generator._data_core_world_ext == null:
		return {"ok": false, "reason": "economy_world_unavailable"}
	_generator._economy_facade = EconomyFacadeScript.new()
	var configured: Dictionary = _generator._economy_facade.configure(
		_generator._data_core_world_ext, map.cell_count(), seed_value)
	if not bool(configured.get("ok", false)):
		_generator._economy_facade = null
		return configured
	var trade_topology := _capture_economy_trade_topology(map)
	if not bool(trade_topology.get("ok", false)):
		_generator._economy_facade = null
		return trade_topology
	return configured


func _capture_economy_trade_topology(map: MapData) -> Dictionary:
	if map == null or _generator._economy_facade == null or _generator._data_core_world_ext == null:
		return {"ok": false, "reason": "economy_world_unavailable"}
	var economy_config_report: Dictionary = _generator._economy_facade.report()
	var trade_runtime_mode := String(economy_config_report.get("trade_runtime_mode", "OFF"))
	if trade_runtime_mode == "OFF":
		return {"ok": true}
	var trade_topology: Dictionary = _generator._data_core_world_ext.capture_economy_trade_topology(
		map.neighbor_indices_packed(),
		map.base_terrain_arr,
		map.economy_trade_passable_lut(),
		map.economy_trade_move_cost_lut(),
		1,
		map.base_landform_arr,
		map.has_river_arr)
	return trade_topology


func _configure_military_runtime(map: MapData, cfg: MapConfig, seed_value: int) -> Dictionary:
	_generator._military_facade = null
	_generator._military_daily_job = null
	if map == null or _generator._data_core_world_ext == null:
		return {"ok": false, "reason": "military_world_unavailable"}
	if _generator._country_facade == null or _generator._economy_facade == null:
		return {"ok": false, "reason": "military_requires_country_and_economy"}
	var technology_catalog: Dictionary = {}
	if _generator._country_facade != null and _generator._country_facade.has_method("native_catalog"):
		technology_catalog = _generator._country_facade.native_catalog()
	if technology_catalog.is_empty():
		technology_catalog = TechnologyCatalogScript.compile_native_catalog()
	if technology_catalog.is_empty():
		return {"ok": false, "reason": "military_technology_catalog_unavailable"}
	var facade := MilitaryFacadeScript.new()
	var configured: Dictionary = facade.configure(_generator._data_core_world_ext,
		_generator._economy_facade.native_catalog(), technology_catalog, seed_value)
	if not bool(configured.get("ok", false)):
		push_error("[military] configure failed: %s" % String(
			configured.get("reason", "unknown")))
		return configured
	var terrain: Dictionary = facade.set_terrain(map, -1, true,
		_military_settlement_tiers(map))
	if not bool(terrain.get("ok", false)):
		push_error("[military] terrain rejected: %s" % String(
			terrain.get("reason", "unknown")))
		_generator._military_facade = null
		return terrain
	_generator._military_facade = facade
	print("[military] configured units=%d categories=%d unlock=%d goods=%d barracks=%d catalog_hash=%d" % [
		(configured.get("unit_count", 0) as int),
		(facade.catalog().get("categories", []) as Array).size(),
		(configured.get("unlock_count", 0) as int),
		int(facade.catalog().get("economy_good_count", 0)),
		_military_barracks_count(facade.catalog()),
		facade.catalog_hash()])
	return configured


## Barracks capacity needs the building catalog; kept as a tiny helper so the
## boot log stays one line even when D's catalog ships partial roles.

static func _military_barracks_count(catalog: Dictionary) -> int:
	var count := 0
	for building_value in catalog.get("state_buildings", []):
		if int((building_value as Dictionary).get("role", -1)) == 0:
			count += 1
	return count


## Settlement tier band (0 none .. 4 capital) used by the military terrain layer.
## Read from Economy's named settlements so the military and the renderer agree
## on what counts as a city, with a MapData fallback when Economy is unavailable.

func _military_settlement_tiers(map: MapData) -> PackedByteArray:
	var count := map.cell_count()
	var tiers := PackedByteArray()
	tiers.resize(count)
	if _generator._economy_facade == null or not _generator._economy_facade.has_method(
			"named_settlement_snapshot"):
		return tiers
	var snapshot: Dictionary = _generator._economy_facade.named_settlement_snapshot()
	if not bool(snapshot.get("ok", false)):
		return tiers
	var cells: PackedInt32Array = snapshot.get("cell_indices", PackedInt32Array())
	var prosperity: PackedByteArray = snapshot.get("prosperity_tiers", PackedByteArray())
	for index in range(mini(cells.size(), prosperity.size())):
		var cell := int(cells[index])
		if cell < 0 or cell >= count:
			continue
		# prosperity 0..3 = named village / town / city / capital in Economy;
		# clamp into the military 1..4 band (any named settlement is >= 1).
		tiers[cell] = clampi(int(prosperity[index]) + 1, 1, 4)
	return tiers


## Re-push terrain after a season refresh changed cover (snow / flood / glacier
## move the passability and attrition tables). Cheap: the facade skips the call
## when the cover signature is unchanged.

func refresh_military_terrain(day: int = -1) -> Dictionary:
	if _generator._military_facade == null or not _generator._military_facade.is_configured():
		return {"ok": false, "reason": "military_not_configured"}
	if _generator._sus_map == null:
		return {"ok": false, "reason": "military_map_unavailable"}
	var result: Dictionary = _generator._military_facade.set_terrain(
		_generator._sus_map, day, false, _military_settlement_tiers(_generator._sus_map))
	return result


## AI 军事议程：玩家国以外的所有国家。player_handles 为空时按
## gameplay start 的 is_player 标记解析；读档后由 PKAI/PKMI 恢复路径再调一次。

func _arm_military_ai(player_handles: PackedInt64Array) -> Dictionary:
	if _generator._military_facade == null or not _generator._military_facade.is_configured():
		return {"ok": false, "reason": "military_not_configured"}
	var handles := player_handles
	if handles.is_empty():
		handles = _gameplay_player_country_handles()
	return _generator._military_facade.arm_ai(handles)


## [economy-facade-accessor 2026-11-02] 这个访问器在军事运行时落地时被误删，
## 但 player_game / game_save_coordinator / player_controller / 心跳诊断都在调它，
## 结果每帧报 `Nonexistent function 'get_economy_facade'`，经济水位读到 -1、
## 存档链路拿不到 facade。补回来（就是取 _economy_facade 这一个字段）。

func _maybe_register_military_system() -> void:
	if _generator._sus == null or _generator._military_facade == null or not _generator._military_facade.is_configured():
		return
	var cp = _generator._c()
	var graph_mode := 0
	if cp != null and cp.get("native_runtime_graph_mode") != null:
		graph_mode = int(cp.native_runtime_graph_mode)
	if _generator._military_daily_job != null:
		if graph_mode == _generator._military_registered_graph_mode:
			return
		var registered_active: bool = bool(_generator._military_registered_graph_active)
		if registered_active == _generator._runtime_graph_active:
			_generator._military_registered_graph_mode = graph_mode
			return
		_generator._military_registered_graph_mode = graph_mode
		return
	_generator._military_registered_graph_active = _generator._runtime_graph_active
	_generator._military_registered_graph_mode = graph_mode
	_generator._military_daily_job = MilitaryDailySystemScript.new(
		_generator._military_facade, _generator._world_clock_ref, _generator, _generator._gameplay_event_bus)
	_generator._sus.configure_job_from_profile(_generator._military_daily_job, cp, false,
		MilitaryFacadeScript.SYSTEM_ID, 1)
	_generator._runtime_register_system(_generator._military_daily_job)
	print("[military] registered military_daily (graph_active=%s)" % str(
		_generator._runtime_graph_active))


func _configure_country_ai(map, seed_value: int, player_handles: PackedInt64Array) -> void:
	_generator._country_ai_facade = null
	if _generator._data_core_world_ext == null:
		return
	var facade := CountryAiFacadeScript.new()
	var configured: Dictionary = facade.configure(_generator._data_core_world_ext, seed_value, map, player_handles)
	if not bool(configured.get("ok", false)):
		push_error("[country_ai] configure failed: %s" % String(configured.get("reason", "unknown")))
		_generator._data_core_world_ext.set_country_ai_mode("OFF")
		return
	_generator._country_ai_facade = facade


func _gameplay_player_country_handles() -> PackedInt64Array:
	var handles := PackedInt64Array()
	if _generator._country_facade == null:
		return handles
	for start_value in _generator._gameplay_start_context.get("country_starts", []):
		var start: Dictionary = start_value
		if not bool(start.get("is_player", false)):
			continue
		var handle := int(_generator._country_facade.cell_summary(int(start.get("cell", -1))).get(
			"country_handle", 0))
		if handle != 0:
			handles.append(handle)
	return handles


func _gameplay_start_has_resource_topups(report: Dictionary) -> bool:
	for start_value in report.get("country_starts", []):
		var start: Dictionary = start_value
		if not (start.get("resource_topups", {}) as Dictionary).is_empty():
			return true
	return false


func _build_gameplay_country_packet() -> Dictionary:
	if _generator._country_facade == null or _generator._gameplay_start_context.is_empty():
		return {}
	var config: Dictionary = _generator._gameplay_start_context.get("config", {})
	var research_config: Dictionary = config.get("research", {})
	var country_starts: Array = _generator._gameplay_start_context.get("country_starts", [])
	if country_starts.is_empty():
		return {}
	var catalog: Dictionary = _generator._country_facade.native_catalog()
	var country_ids := PackedStringArray()
	var country_names := PackedStringArray()
	var regime_ids := PackedStringArray()
	var country_cash := PackedInt64Array()
	var territory_offsets := PackedInt32Array([0])
	var territory_cells := PackedInt32Array()
	var technology_offsets := PackedInt32Array([0])
	var all_technology_indices := PackedInt32Array()
	var research_signal_offsets := PackedInt32Array([0])
	var research_signal_indices := PackedInt32Array()
	var research_signal_cells := PackedInt32Array()
	var research_signal_days := PackedInt64Array()
	var treasury_offsets := PackedInt32Array([0])
	var treasury_good_indices := PackedInt32Array()
	var treasury_quantities := PackedInt64Array()
	var discovered_offsets := PackedInt32Array([0])
	var all_discovered_indices := PackedInt32Array()
	var research_weights := PackedInt32Array()
	var research_budgets := PackedInt64Array()
	var research_auto_purchase := PackedByteArray()
	var configured_weights: PackedInt32Array = research_config.get(
		"domain_weights_bp", PackedInt32Array([2500, 2500, 2500, 2500]))
	var points_good := (catalog.get("good_ids", PackedStringArray()) as PackedStringArray).find(
		"technology_points")
	if points_good < 0:
		return {}
	for start_value in country_starts:
		var start: Dictionary = start_value
		var country_id := String(start.get("country_id", ""))
		var country_name := String(start.get("country_name", "")).strip_edges()
		var cell := int(start.get("cell", -1))
		if country_id.is_empty() or country_name.is_empty() or cell < 0:
			return {}
		country_ids.append(country_id)
		country_names.append(country_name)
		regime_ids.append(String(start.get("regime_id",
			catalog.get("political_regime_default_id", "early_clan"))))
		country_cash.append(int(research_config.get(
			"starting_country_cash", 100000000)))
		territory_cells.append(cell)
		territory_offsets.append(territory_cells.size())
		var starter_ids: PackedStringArray = start.get(
			"starter_technology_ids", PackedStringArray())
		var starter_eligible: Dictionary = {}
		for starter_id in catalog.get("starter_eligible_technology_ids", PackedStringArray()):
			starter_eligible[String(starter_id)] = true
		var technology_indices := PackedInt32Array()
		var seen_technology := {}
		for starter_id in starter_ids:
			var starter_id_string := String(starter_id)
			if not starter_eligible.has(starter_id_string):
				return {}
			var technology_index := (catalog.technology_ids as PackedStringArray).find(starter_id_string)
			if technology_index < 0 or seen_technology.has(technology_index):
				continue
			seen_technology[technology_index] = true
			technology_indices.append(technology_index)
		if technology_indices.is_empty():
			return {}
		for technology_index in technology_indices:
			all_technology_indices.append(technology_index)
		technology_offsets.append(all_technology_indices.size())
		var signal_ids: PackedInt32Array = start.get("visible_signal_ids", PackedInt32Array())
		var signal_cells: PackedInt32Array = start.get("visible_signal_cells", PackedInt32Array())
		if signal_ids.size() != signal_cells.size():
			return {}
		for signal_edge in range(signal_ids.size()):
			research_signal_indices.append(int(signal_ids[signal_edge]))
			research_signal_cells.append(int(signal_cells[signal_edge]))
			research_signal_days.append(0)
		research_signal_offsets.append(research_signal_indices.size())
		var discovered_ids: PackedStringArray = start.get(
			"starter_discovered_technology_ids", PackedStringArray())
		var seen_discovered := {}
		for discovered_id in discovered_ids:
			var discovered_index := (catalog.technology_ids as PackedStringArray).find(
				String(discovered_id))
			if discovered_index < 0 or seen_discovered.has(discovered_index) \
					or seen_technology.has(discovered_index):
				continue
			seen_discovered[discovered_index] = true
			all_discovered_indices.append(discovered_index)
		discovered_offsets.append(all_discovered_indices.size())
		var treasury_quantity := int(start.get("starter_treasury_quantity", 0))
		if treasury_quantity > 0:
			treasury_good_indices.append(points_good)
			treasury_quantities.append(treasury_quantity)
		treasury_offsets.append(treasury_good_indices.size())
		for weight in configured_weights:
			research_weights.append(weight)
		research_budgets.append(int(research_config.get(
			"procurement_budget_per_day", 10000000)))
		research_auto_purchase.append(
			1 if bool(research_config.get("auto_purchase_enabled", true)) else 0)
	return {
		"country_ids": country_ids,
		"country_names": country_names,
		"regime_ids": regime_ids,
		"country_cash": country_cash,
		"territory_offsets": territory_offsets,
		"territory_cells": territory_cells,
		"technology_offsets": technology_offsets,
		"technology_indices": all_technology_indices,
		"discovered_technology_offsets": discovered_offsets,
		"discovered_technology_indices": all_discovered_indices,
		"research_signal_offsets": research_signal_offsets,
		"research_signal_indices": research_signal_indices,
		"research_signal_cells": research_signal_cells,
		"research_signal_days": research_signal_days,
		"treasury_offsets": treasury_offsets,
		"treasury_good_indices": treasury_good_indices,
		"treasury_quantities": treasury_quantities,
		"research_weights_bp": research_weights,
		"research_daily_budgets": research_budgets,
		"research_auto_purchase": research_auto_purchase,
	}


func _configure_economy_runtime_cooperative(map: MapData, seed_value: int) -> Dictionary:
	if map == null or _generator._data_core_world_ext == null:
		return {"ok": false, "reason": "economy_world_unavailable"}
	_generator._economy_facade = EconomyFacadeScript.new()
	var configured: Dictionary = _generator._economy_facade.configure(
		_generator._data_core_world_ext, map.cell_count(), seed_value)
	if not bool(configured.get("ok", false)):
		_generator._economy_facade = null
		return configured
	await _generator._yield_generation_frame()
	var trade_topology := _capture_economy_trade_topology(map)
	if not bool(trade_topology.get("ok", false)):
		_generator._economy_facade = null
		return trade_topology
	return configured
