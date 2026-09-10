extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
var failures := 0
var checks := 0

func _init() -> void:
	_run()
	print("runtime country POD: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var ext := DCWorldExt.new()
	_expect("worker country authority self-test", ext.has_method("runtime_country_pod_authority_self_test")
		and bool(ext.runtime_country_pod_authority_self_test()))
	_expect("snapshot facade exported", ext.has_method("capture_country_runtime_snapshot"))
	_expect("country catalog capture facade exported", ext.has_method("capture_country_pod_catalog"))
	var missing: Dictionary = ext.capture_country_runtime_snapshot()
	_expect("unconfigured capture reports explicit error", not bool(missing.get("ok", true))
		and str(missing.get("code", "")) == "country_runtime_unavailable")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	_expect("country configures", bool(ext.configure_country(catalog, profile, 2, 17).get("ok", false)))
	_expect("country bootstraps", bool(ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false)))
	_expect("typed command seal and receipt contract",
		ext.has_method("runtime_country_core_protocol_self_test")
		and bool(ext.runtime_country_core_protocol_self_test()))
	_expect("peer context identity and stale ACK contract",
		ext.has_method("runtime_country_peer_protocol_self_test")
		and bool(ext.runtime_country_peer_protocol_self_test()))
	var captured: Dictionary = ext.capture_country_runtime_snapshot()
	_expect("bootstrapped snapshot accepted", bool(captured.get("ok", false)))
	_expect("snapshot exposes bounded metadata", int(captured.get("country_count", 0)) > 0
		and int(captured.get("cell_count", 0)) == 2
		and int(captured.get("generation", 0)) > 0)
	var pod_catalog: Dictionary = ext.capture_country_pod_catalog()
	_expect("numeric country catalog capture is explicit", bool(pod_catalog.get("ok", false))
		and int(pod_catalog.get("catalog_hash", 0)) != 0
		and bool(pod_catalog.get("research_conditions_complete", false)))
	var effect_required: PackedByteArray = pod_catalog.get(
		"technology_effect_required", PackedByteArray())
	var modifier_keys: PackedStringArray = catalog.get(
		"technology_modifier_definition_keys", PackedStringArray())
	var effect_shape_matches := effect_required.size() == int(
		pod_catalog.get("technology_count", 0))
	var effect_values_valid := true
	var effect_values_match_source := modifier_keys.size() == effect_required.size()
	for index in range(effect_required.size()):
		if effect_required[index] > 1:
			effect_values_valid = false
		if effect_values_match_source:
			var expected := 1 if not String(modifier_keys[index]).is_empty() else 0
			if int(effect_required[index]) != expected:
				effect_values_match_source = false
	_expect("catalog exports typed technology Effect requirements",
		effect_shape_matches and effect_values_valid and effect_values_match_source)
	_expect("Country worker read view facade is exported",
		ext.has_method("get_country_worker_read_view"))
	var initial_view: Dictionary = ext.get_country_worker_read_view(0)
	var initial_cells: PackedInt32Array = initial_view.get(
		"changed_cells", PackedInt32Array())
	var initial_owners: PackedInt32Array = initial_view.get(
		"changed_owners", PackedInt32Array())
	_expect("captured Country view is immediately readable",
		bool(initial_view.get("ok", false))
		and bool(initial_view.get("available", false))
		and int(initial_view.get("generation", 0)) == int(captured.get("generation", -1))
		and int(initial_view.get("cell_count", 0)) == 2)
	_expect("bootstrap view exposes an explicit full initialization patch",
		initial_cells.size() == 2
		and initial_owners.size() == 2
		and initial_cells[0] == 0 and initial_cells[1] == 1
		and initial_owners[0] == 0 and initial_owners[1] == 0)
	var same_cursor: Dictionary = ext.get_country_worker_read_view(
		int(initial_view.get("generation", 0)))
	_expect("Country view cursor suppresses duplicate reads",
		bool(same_cursor.get("ok", false))
		and not bool(same_cursor.get("available", true)))
	_run_read_view_patch_contract(catalog)
	var shadow: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 5.0,
		"paused": false,
	})
	_expect("shadow worker starts", bool(shadow.get("ok", false)))
	OS.delay_msec(40)
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("country probe diagnostics are exported", report.has("country_pod_snapshot_generation")
		and report.has("country_pod_blocker"))
	_expect("active research index diagnostics are exported",
		report.has("country_pod_active_index_count")
		and int(report.get("country_pod_active_index_count", -1)) >= 0)
	_expect("active authority remains blocked", not bool(report.get("simulation_worker_ready", true))
		and int(report.get("missing_domain_mask", 0)) != 0)
	ext.request_runtime_stop()
	OS.delay_msec(30)


func _run_read_view_patch_contract(catalog: Dictionary) -> void:
	var ext := DCWorldExt.new()
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	_expect("read-view patch fixture configures",
		bool(ext.configure_country(catalog, profile, 3, 1901).get("ok", false)))
	_expect("read-view patch fixture bootstraps",
		bool(ext.bootstrap_country({}, PackedByteArray([0, 0, 0])).get("ok", false)))
	var initial_capture: Dictionary = ext.capture_country_runtime_snapshot()
	var initial := ext.get_country_worker_read_view(0)
	var initial_generation := int(initial.get("generation", 0))
	_expect("read-view patch fixture publishes bootstrap",
		bool(initial_capture.get("ok", false))
		and bool(initial.get("available", false))
		and not bool(initial.get("full_snapshot_required", true))
		and (initial.get("full_cell_owners", PackedInt32Array()) as PackedInt32Array).is_empty())

	var create: Dictionary = ext.submit_country_commands(_single_country_command(
		1, 0, 0, 2, 0, "patch.country", "Patch Country"))
	_expect("read-view CREATE command admitted", bool(create.get("ok", false)))
	_expect("read-view CREATE commits", bool(ext.run_country_slice({
		"day_index": 0}).get("ok", false)))
	_expect("read-view CREATE snapshot captured",
		bool(ext.capture_country_runtime_snapshot().get("ok", false)))
	var created := ext.get_country_worker_read_view(initial_generation)
	var created_cells: PackedInt32Array = created.get(
		"changed_cells", PackedInt32Array())
	var created_owners: PackedInt32Array = created.get(
		"changed_owners", PackedInt32Array())
	var created_generation := int(created.get("generation", 0))
	_expect("single CREATE produces one sparse territory cell",
		bool(created.get("available", false))
		and not bool(created.get("full_snapshot_required", true))
		and created_cells.size() == 1 and created_owners.size() == 1
		and created_cells[0] == 2 and created_owners[0] == 1)
	_expect("sparse patch advances the read cursor",
		created_generation > initial_generation
		and not bool(ext.get_country_worker_read_view(created_generation).get(
			"available", true)))

	var created_handle := int(ext.get_country_cell_summary(2).get(
		"country_handle", 0))
	_expect("read-view CREATE exposes a generation-safe handle", created_handle != 0)
	var rename: Dictionary = ext.submit_country_commands(_single_country_command(
		2, 0, 1, -1, 1, "", "Renamed Country", -1, created_handle))
	_expect("read-view RENAME command admitted", bool(rename.get("ok", false)))
	_expect("read-view RENAME commits", bool(ext.run_country_slice({
		"day_index": 1}).get("ok", false)))
	_expect("read-view RENAME snapshot captured",
		bool(ext.capture_country_runtime_snapshot().get("ok", false)))
	var renamed := ext.get_country_worker_read_view(created_generation)
	var renamed_cells: PackedInt32Array = renamed.get(
		"changed_cells", PackedInt32Array())
	_expect("research/identity generation without territory stays sparse-empty",
		bool(renamed.get("available", false))
		and renamed_cells.is_empty())

	var skipped := ext.get_country_worker_read_view(initial_generation)
	var full_owners: PackedInt32Array = skipped.get(
		"full_cell_owners", PackedInt32Array())
	_expect("skipped generation explicitly requires full snapshot",
		bool(skipped.get("available", false))
		and bool(skipped.get("full_snapshot_required", false))
		and full_owners.size() == 3
		and full_owners[0] == 0 and full_owners[1] == 0 and full_owners[2] == 1)


func _single_country_command(opcode: int, target_generation: int,
		effective_day: int, cell: int, sequence: int, stable_id: String,
		display_name: String, target_slot: int = -1,
		target_handle_override: int = 0) -> Dictionary:
	var target_handle := 0
	if target_handle_override != 0:
		target_handle = target_handle_override
	elif target_slot >= 0:
		target_handle = (target_generation << 32) | target_slot
	return {
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([effective_day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([target_handle]),
		"cell_indices": PackedInt32Array([cell]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([-1]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_basis_points": PackedInt32Array([0]),
		"tax_assessment_modes": PackedInt32Array([0]),
		"stable_ids": PackedStringArray([stable_id]),
		"display_names": PackedStringArray([display_name]),
	}

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	failures += 1
	push_error("[FAIL] " + label)
