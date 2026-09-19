extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_shadow_test.gd --quit
#
# P0 native daily safety-gate smoke test. Full legacy-vs-native hash
# equivalence requires a generated map fixture; this test locks the exported
# API surface and verifies that an unconfigured native world fails closed.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily shadow smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return

	_expect("run_native_sim_tick exported", ext.has_method("run_native_sim_tick"))
	_expect("get_native_daily_report exported", ext.has_method("get_native_daily_report"))
	_expect("get_native_shadow_diff_report exported", ext.has_method("get_native_shadow_diff_report"))
	_expect("native climate state report exported", ext.has_method("get_native_climate_round_state_report"))
	_expect("native climate state reset exported", ext.has_method("reset_native_climate_round_state"))
	_expect("native climate begin facade exported", ext.has_method("native_climate_round_begin"))
	_expect("native climate begin round facade exported", ext.has_method("native_climate_round_begin_round"))
	_expect("native climate kick facade exported", ext.has_method("native_climate_round_kick"))
	_expect("native climate poll facade exported", ext.has_method("native_climate_round_poll"))
	_expect("native climate finish round facade exported", ext.has_method("native_climate_round_finish_round"))
	if not ext.has_method("run_native_sim_tick"):
		_finish()
		return

	var res: Dictionary = ext.call("run_native_sim_tick", {
		"probe": true,
		"shadow_diff_enabled": true,
	})
	_expect("unconfigured native sim fails closed", int(res.get("rc", 0)) == -1)
	_expect("unconfigured fail stage explicit", str(res.get("fail_stage", "")) == "native_world_not_configured")
	_expect("unconfigured report has path", str(res.get("path", "")) == "gdext_native_daily")
	_expect("unconfigured report has fallback reason", str(res.get("fallback_reason", "")) != "")
	_expect("unconfigured report has publish slots array", typeof(res.get("published_slots", [])) == TYPE_ARRAY)
	_expect("unconfigured report has visual intents array", typeof(res.get("visual_dirty_intents", [])) == TYPE_ARRAY)
	_expect("unconfigured report has native state snapshot", typeof(res.get("native_state_snapshot", {})) == TYPE_DICTIONARY)

	var daily_report: Dictionary = ext.call("get_native_daily_report")
	_expect("daily report captures rc", int(daily_report.get("rc", 0)) == -1)
	_expect("daily report captures native timing", daily_report.has("native_ms"))
	_expect("daily report captures publish slots", daily_report.has("published_slots"))
	var diff_report: Dictionary = ext.call("get_native_shadow_diff_report")
	_expect("shadow diff report exported as dictionary", typeof(diff_report) == TYPE_DICTIONARY)
	_expect("native hashes present", typeof(diff_report.get("native_hashes", {})) == TYPE_DICTIONARY)
	if ext.has_method("get_native_climate_round_state_report"):
		var climate_state: Dictionary = ext.call("get_native_climate_round_state_report")
		_expect("native climate state report is dictionary", typeof(climate_state) == TYPE_DICTIONARY)
		_expect("native climate state starts unregistered", not bool(climate_state.get("registered", true)))
		_expect("native climate authority readiness is explicit", climate_state.has("climate_round_authority_ready"))
		_expect("native climate owner is ready for handoff", bool(climate_state.get("climate_round_authority_ready", false)))
		_expect("native climate authority blockers are listed", typeof(climate_state.get("climate_round_authority_blockers", [])) == TYPE_ARRAY)
		_expect("native climate remaining gdscript authority is listed", typeof(climate_state.get("remaining_gdscript_authority", [])) == TYPE_ARRAY)
	if ext.has_method("reset_native_climate_round_state"):
		var reset_res: Dictionary = ext.call("reset_native_climate_round_state", "native_daily_shadow_test")
		var reset_intents: Array = reset_res.get("reset_boundary_intents", [])
		_expect("native climate state reset succeeds", int(reset_res.get("rc", -1)) == 0)
		_expect("native climate reset declares abort intent", reset_intents.has("abort_active_pass"))
		_expect("native climate reset declares local state reset intent", reset_intents.has("reset_round_local_state"))
		_expect("native climate reset declares full sweep seed intent", reset_intents.has("seed_full_sweep_counter"))
	if ext.has_method("native_climate_round_begin"):
		var begin_res: Dictionary = ext.call("native_climate_round_begin", {})
		_expect("native climate begin facade succeeds", int(begin_res.get("rc", -1)) == 0)
		_expect("native climate begin remains probe", not bool(begin_res.get("simulation_authority", true)))
		if ext.has_method("native_climate_round_begin_round"):
			var begin_round_res: Dictionary = ext.call("native_climate_round_begin_round", {
				"phase_locked": 0.25,
				"tick_index": 7,
				"pass_cursor": 0,
			})
			var begin_round_state: Dictionary = begin_round_res.get("state", {})
			var begin_round_start_intents: Array = begin_round_res.get("start_state_intents", [])
			var begin_round_intents: Array = begin_round_res.get("boundary_intents", [])
			_expect("native climate begin round succeeds", int(begin_round_res.get("rc", -1)) == 0)
			_expect("native climate begin round records phase", is_equal_approx(float(begin_round_state.get("phase_locked", -1.0)), 0.25))
			_expect("native climate begin round active", bool(begin_round_state.get("lifecycle_round_active", false)))
			_expect("native climate begin round declares active state intent", begin_round_start_intents.has("set_round_active"))
			_expect("native climate begin round declares phase lock intent", begin_round_start_intents.has("set_phase_locked"))
			_expect("native climate begin round declares poll reset intent", begin_round_start_intents.has("reset_poll_attempts"))
			_expect("native climate begin round declares terrain sync intent", begin_round_intents.has("sync_runtime_terrain_views"))
			_expect("native climate begin round declares pass state intent", begin_round_intents.has("begin_round_pass_state"))
			_expect("native climate begin round declares soa transaction intent", begin_round_intents.has("soa_begin_climate_transaction"))
		if ext.has_method("native_climate_round_poll"):
			var poll_res: Dictionary = ext.call("native_climate_round_poll")
			_expect("native climate poll facade has publish slots", typeof(poll_res.get("published_slots", [])) == TYPE_ARRAY)
			_expect("native climate poll facade has visual intents", typeof(poll_res.get("visual_dirty_intents", [])) == TYPE_ARRAY)
			_expect("native climate poll facade has breakdown", typeof(poll_res.get("breakdown", {})) == TYPE_DICTIONARY)
			_expect("native climate poll facade has finish intents", typeof(poll_res.get("finish_boundary_intents", [])) == TYPE_ARRAY)
			_expect("native climate poll facade has finalize tail intents", typeof(poll_res.get("finalize_tail_boundary_intents", [])) == TYPE_ARRAY)
		if ext.has_method("native_climate_round_finish_round"):
			var finish_round_res: Dictionary = ext.call("native_climate_round_finish_round", {
				"pass_cursor": 8,
				"stage": "test_done",
			})
			var finish_round_state: Dictionary = finish_round_res.get("state", {})
			_expect("native climate finish round succeeds", int(finish_round_res.get("rc", -1)) == 0)
			_expect("native climate finish round inactive", not bool(finish_round_state.get("lifecycle_round_active", true)))
		if ext.has_method("reset_native_climate_round_state"):
			ext.call("reset_native_climate_round_state", "native_daily_shadow_test_cleanup")
	_finish()


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
