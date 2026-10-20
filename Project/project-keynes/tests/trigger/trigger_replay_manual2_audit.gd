extends SceneTree

# manual_2 recovery audit: replay the 8 completed-but-missing development
# achievement signals through the real Trigger -> Effect -> Country path and
# prove that (a) the permanent Country research signals appear, (b) the four
# projected technologies become revealed/eligible, and (c) a second automatic
# reconciliation does not resubmit already recorded country-wide evidence.
#
# Run:
#   $env:PK_SAVE_DIR='F:\...\tmp\manual2_research_20261019'
#   & <godot_console> --headless --path <project> --script res://tests/trigger/trigger_replay_manual2_audit.gd
#
# The save is only read. Output: <repo>/tmp/trigger_replay_manual2_<unix>.json

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

const EXPECTED_ACHIEVEMENTS := [
	"development.employment.agriculture.10_90d",
	"development.employment.extractive.10_90d",
	"development.employment.manufacturing.10_90d",
	"development.output.extractive.100_180d",
	"development.agricultural_employment_100_360d",
	"development.satisfaction.60_720d",
	"development.satisfaction.65_1095d",
	"development.satisfaction.70_1095d",
]
const FOCUS_TECHNOLOGIES := [
	"tech.market_institutions",
	"tech.currency",
	"tech.urban_sanitation",
	"tech.customary_tenancy",
]
const TECH_COMPLETED := 5
const MAX_COUNTRY_SLICES := 64

var _failures := 0

func _require(value: bool, message: String) -> void:
	if not value:
		_failures += 1
		push_error(message)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var slot := String(OS.get_environment("PK_TRIGGER_REPLAY_SLOT")) \
		if OS.has_environment("PK_TRIGGER_REPLAY_SLOT") else "manual_2"
	if not OS.has_environment("PK_SAVE_DIR"):
		print("[trigger-replay/warn] PK_SAVE_DIR not set; using the default user://saves")
	var loaded: Dictionary = SaveRepository.new().load_slot(slot)
	if not bool(loaded.get("ok", false)):
		print("[trigger-replay/fail] load_slot=", JSON.stringify(loaded))
		quit(1)
		return
	var sections: Dictionary = loaded.section_bytes
	var header: Dictionary = loaded.header
	var day := int(header.get("day", 0))
	var width := int(header.get("width", 0))
	var height := int(header.get("height", 0))
	var cell_count := width * height
	print("[trigger-replay/save] slot=%s day=%d cells=%d" % [slot, day, cell_count])

	var compiled := EconomyCatalog.compile_native_catalog()
	var ext := DCWorldExt.new()
	ext.create_entities(cell_count)
	var facade := CountryFacade.new()
	var configured: Dictionary = facade.configure(ext, cell_count, int(header.get("seed", 0)), null, compiled)
	print("[trigger-replay/country/config] ", JSON.stringify(configured))
	if not bool(configured.get("ok", false)):
		quit(1)
		return
	var country_restore: Dictionary = facade.restore_bytes(sections.pkcn)
	print("[trigger-replay/country/restore] ok=%s" % str(country_restore.get("ok", false)))
	if not bool(country_restore.get("ok", false)):
		quit(1)
		return

	var trigger_catalog: Resource = TriggerCatalogScript.load_default()
	var compiled_triggers: Dictionary = trigger_catalog.compile_native_catalog()
	_require(bool(compiled_triggers.get("ok", false)), "trigger catalog compile")
	_require(bool(ext.configure_triggers(compiled_triggers).get("ok", false)), "trigger configure")
	var trigger_restore: Dictionary = ext.restore_trigger_state(sections.pktr)
	print("[trigger-replay/trigger/restore] ok=%s pending=%s" % [
		str(trigger_restore.get("ok", false)),
		str(ext.get_trigger_report().get("pending_effects", -1))])
	if not bool(trigger_restore.get("ok", false)):
		print("[trigger-replay/fail] trigger_restore=", JSON.stringify(trigger_restore))
		quit(1)
		return

	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_require(bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)),
		"effect configure")
	var effect_restore: Dictionary = ext.restore_effect_state(sections.pkef)
	print("[trigger-replay/effect/restore] ok=%s" % str(effect_restore.get("ok", false)))
	if not bool(effect_restore.get("ok", false)):
		quit(1)
		return

	# Player country: the save's player_context has no handle; the start cell
	# summary returns the packed (generation<<32)|slot country handle.
	var player_context: Dictionary = bytes_to_var(sections.player_context)
	var start_cell := int(player_context.get("start_cell", 0))
	var summary: Dictionary = ext.get_country_cell_summary(start_cell)
	var handle := int(summary.get("country_handle", 0))
	print("[trigger-replay/player] start_cell=%d handle=%d" % [start_cell, handle])
	if handle <= 0:
		print("[trigger-replay/fail] player country handle unresolved")
		quit(1)
		return

	var signal_ids: PackedStringArray = ResearchSignalCatalog.compile_native_catalog().research_signal_ids
	var metrics: Dictionary = DevelopmentAchievementCatalog.compile_native_catalog(signal_ids)
	var known_before := _signal_counts(ext, handle)
	var missing_before := _missing_achievements(ext, handle, metrics, known_before)
	var before_signals := _signal_ids(ext, handle)
	var research_before: Dictionary = ext.get_country_research_snapshot(handle)
	var definitions: Array = TechnologyCatalog.public_definitions(compiled)
	var states_before: PackedInt32Array = research_before.get("technology_states", PackedInt32Array())
	var focus_before := _focus_projection(definitions, states_before, before_signals)

	var missing_ids := []
	for entry in missing_before:
		missing_ids.append(String(entry.id))
	missing_ids.sort()
	var expected := EXPECTED_ACHIEVEMENTS.duplicate()
	expected.sort()
	_require(missing_ids == expected,
		"missing achievement set must match the stored 8, got %s" % str(missing_ids))

	var trigger_keys: PackedStringArray = compiled_triggers.trigger_keys
	var replay_results := []
	var automatic_recovery: Dictionary = ext.reconcile_completed_research_signals(256)
	_require(bool(automatic_recovery.get("ok", false)) and bool(automatic_recovery.get("complete", false)),
		"automatic recovery admits all completed missing signals: %s" % str(automatic_recovery))
	# The explicit replay probes below must now see the same pending effects;
	# automatic session repair is the producer, not a hand-authored list.
	for entry in missing_before:
		var signal_id := String(entry.id)
		var trigger_key := "development.achievement.%s" % signal_id.trim_prefix("development.")
		var trigger_id := trigger_keys.find(trigger_key)
		if trigger_id < 0:
			_require(false, "trigger missing for %s" % signal_id)
			continue
		var result: Dictionary = ext.replay_completed_research_signal(
			trigger_id, handle, start_cell, day)
		replay_results.append({
			"signal": signal_id,
			"trigger_id": trigger_id,
			"trigger_key": trigger_key,
			"ok": bool(result.get("ok", false)),
			"enqueued": bool(result.get("enqueued", false)),
			"reason": String(result.get("reason", "")),
		})
		_require(bool(result.get("ok", false)), "replay failed for %s: %s" % [signal_id, str(result)])

	var first_cycle := _deliver_pending(ext, day)
	print("[trigger-replay/cycle1] ", JSON.stringify({
		"replay": replay_results.size(),
		"handoff": first_cycle.get("handoff", {}),
		"dispatch": first_cycle.get("dispatch", {}),
		"country_slice": first_cycle.get("country_slice", {}),
		"ack": first_cycle.get("ack", {}),
	}))

	var after_signals := _signal_ids(ext, handle)
	var known_after := _signal_counts(ext, handle)
	var after_missing := _missing_achievements(ext, handle, metrics, known_after)
	var research_after: Dictionary = ext.get_country_research_snapshot(handle)
	var states_after: PackedInt32Array = research_after.get("technology_states", PackedInt32Array())
	var focus_after := _focus_projection(definitions, states_after, after_signals)

	var restored := []
	for index in EXPECTED_ACHIEVEMENTS.size():
		var signal_id := String(EXPECTED_ACHIEVEMENTS[index])
		var signal_index := signal_ids.find(signal_id)
		var present := signal_index >= 0 and after_signals.has(signal_index)
		restored.append({"signal": signal_id, "signal_index": signal_index, "present": present})
		_require(present, "signal missing after replay: %s" % signal_id)
	_require(after_missing.is_empty(),
		"achievements still missing evidence after replay: %s" % str(after_missing.size()))

	# Recovery is country-wide. Once the signal exists, a later session must not
	# add another provenance cell, even if the representative territory changes.
	var second_reconciliation: Dictionary = ext.reconcile_completed_research_signals(256)
	var second_replay := [second_reconciliation]
	_require(bool(second_reconciliation.get("ok", false)) and
		int(second_reconciliation.get("submitted", -1)) == 0,
		"automatic recovery is idempotent after Country has the signals")
	var second_cycle := _deliver_pending(ext, day)
	var known_second := _signal_counts(ext, handle)
	var evidence_growth := []
	for signal_index in known_second.keys():
		var previous := int(known_after.get(signal_index, 0))
		var current := int(known_second.get(signal_index, 0))
		if current != previous:
			evidence_growth.append({"signal_index": signal_index,
				"before": previous, "after": current})
	_require(evidence_growth.is_empty(),
		"second replay changed signal evidence counts: %s" % str(evidence_growth))

	var focus_checks := []
	var focus_ok := true
	for index in FOCUS_TECHNOLOGIES.size():
		var tech_id := String(FOCUS_TECHNOLOGIES[index])
		var before_entry: Dictionary = focus_before[tech_id]
		var after_entry: Dictionary = focus_after[tech_id]
		var check := {
			"id": tech_id,
			"revealed_before": before_entry.revealed,
			"revealed_after": after_entry.revealed,
			"eligible_before": before_entry.eligible,
			"eligible_after": after_entry.eligible,
			"state_before": before_entry.state,
			"state_after": after_entry.state,
		}
		focus_checks.append(check)
		var ok := bool(after_entry.revealed) and bool(after_entry.eligible)
		if not ok:
			focus_ok = false
		_require(ok, "focus technology not reveal+eligible after replay: %s" % str(check))

	var report := {
		"slot": slot,
		"day": day,
		"start_cell": start_cell,
		"player_handle": handle,
		"catalog_hash": int(compiled_triggers.get("catalog_hash", 0)),
		"missing_before": missing_before,
		"replay_results": replay_results,
		"automatic_recovery": automatic_recovery,
		"first_cycle": first_cycle,
		"second_cycle": second_cycle,
		"second_replay": second_replay,
		"evidence_growth": evidence_growth,
		"restored_signals": restored,
		"remaining_missing": after_missing.size(),
		"focus_technologies": focus_checks,
		"signal_counts_after": _counts_to_json(known_after),
		"ok": _failures == 0 and focus_ok,
	}
	var out_path := _output_path()
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
		print("[trigger-replay/out] ", out_path)
	else:
		print("[trigger-replay/warn] cannot write ", out_path)
	print("[trigger-replay/summary] missing_before=%d restored=%d remaining_missing=%d ok=%s" % [
		missing_before.size(), restored.size(), after_missing.size(), str(report.ok)])
	print("[trigger-replay/focus] ", JSON.stringify(focus_checks))
	print("trigger_replay_manual2_audit: %s" % ("PASS" if report.ok else "FAIL"))
	quit(0 if report.ok else 1)

# --- pipeline helpers ------------------------------------------------------

func _deliver_pending(ext: Object, day: int) -> Dictionary:
	var out := {}
	var handoff: Dictionary = ext.handoff_trigger_effects(256)
	out["handoff"] = _compact(handoff)
	var dispatch: Dictionary = ext.dispatch_effect_native_country()
	out["dispatch"] = _compact(dispatch)
	var slices := 0
	var done := false
	var slice_out := {}
	while slices < MAX_COUNTRY_SLICES:
		slice_out = ext.run_country_slice({"day_index": day})
		slices += 1
		if not bool(slice_out.get("ok", false)):
			break
		if bool(slice_out.get("done", false)):
			done = true
			break
	slice_out = _compact(slice_out)
	slice_out["slices"] = slices
	slice_out["done"] = done
	out["country_slice"] = slice_out
	var ack: Dictionary = ext.ack_effect_native_country()
	out["ack"] = _compact(ack)
	return out

func _compact(source: Dictionary) -> Dictionary:
	var out := {}
	for key in source.keys():
		if String(key).begins_with("_"):
			continue
		var value: Variant = source[key]
		if value is Dictionary or value is Array:
			continue
		out[String(key)] = value
	return out

func _signal_ids(ext: Object, handle: int) -> PackedInt32Array:
	return ext.get_country_research_signal_snapshot(handle).get(
		"signal_ids", PackedInt32Array())

func _signal_counts(ext: Object, handle: int) -> Dictionary:
	var snapshot: Dictionary = ext.get_country_research_signal_snapshot(handle)
	var ids: PackedInt32Array = snapshot.get("signal_ids", PackedInt32Array())
	var counts: PackedInt32Array = snapshot.get("counts", PackedInt32Array())
	var out := {}
	for index in ids.size():
		out[int(ids[index])] = int(counts[index]) if index < counts.size() else 0
	return out

func _counts_to_json(counts: Dictionary) -> Dictionary:
	var out := {}
	for key in counts.keys():
		out[str(key)] = counts[key]
	return out

func _missing_achievements(ext: Object, handle: int, metrics: Dictionary,
		known: Dictionary) -> Array:
	var out := []
	var metric_ids: PackedStringArray = metrics.development_metric_ids
	for era in 11:
		var progress: Dictionary = ext.get_development_progress(handle, era)
		if not bool(progress.get("ok", true)):
			continue
		var era_metrics: PackedInt32Array = progress.get("metric_ids", PackedInt32Array())
		var completed: PackedInt32Array = progress.get("completed", PackedInt32Array())
		for index in era_metrics.size():
			if index >= completed.size() or int(completed[index]) == 0:
				continue
			var metric := int(era_metrics[index])
			var signal_index := int(metrics.development_metric_signal_indices[metric])
			if not known.has(signal_index):
				out.append({
					"id": String(metric_ids[metric]),
					"metric": metric,
					"signal_index": signal_index,
					"current": int(progress.current_values[index]),
					"consecutive": int(progress.consecutive_days[index]),
					"target": int(progress.target_days[index]),
				})
	return out

# --- projection evaluation (mirrors tmp/manual2_research_20261019/analyze.py) ---

func _focus_projection(definitions: Array, states: PackedInt32Array,
		signals: PackedInt32Array) -> Dictionary:
	var index_by_id := {}
	for index in definitions.size():
		index_by_id[String(definitions[index].id)] = index
	var signal_names: PackedStringArray = \
		ResearchSignalCatalog.compile_native_catalog().research_signal_ids
	var signal_set := {}
	for entry in signals:
		if int(entry) >= 0 and int(entry) < signal_names.size():
			signal_set[signal_names[int(entry)]] = true
	var out := {}
	for index in FOCUS_TECHNOLOGIES.size():
		var tech_id := String(FOCUS_TECHNOLOGIES[index])
		if not index_by_id.has(tech_id):
			out[tech_id] = {"revealed": false, "eligible": false, "state": -1}
			continue
		var definition: Dictionary = definitions[int(index_by_id[tech_id])]
		var def_index := int(index_by_id[tech_id])
		var state := int(states[def_index]) if def_index < states.size() else 0
		var reveal_condition: Dictionary = definition.get("reveal_condition", {})
		var revealed: bool = state > 0 or (
			not reveal_condition.is_empty()
			and _evaluate_condition(reveal_condition, index_by_id, states, signal_set))
		var eligible := _eligible(definition, index_by_id, states, signal_set)
		out[tech_id] = {"revealed": revealed, "eligible": eligible, "state": state}
	return out

func _evaluate_condition(condition: Dictionary, index_by_id: Dictionary,
		states: PackedInt32Array, signals: Dictionary) -> bool:
	if condition.is_empty():
		return true
	if condition.has("kind"):
		var kind := int(condition.kind)
		if kind == 0:
			var completed_index := int(index_by_id.get(String(condition.get("id", "")), -1))
			return completed_index >= 0 and completed_index < states.size() \
				and int(states[completed_index]) == TECH_COMPLETED
		if kind == 1 or kind == 2:
			return signals.has(String(condition.get("id", "")))
		return false
	var op := int(condition.get("operator", 0))
	if op == 0:
		return _evaluate_condition(condition.get("atom", {}), index_by_id, states, signals)
	var results := []
	for child in condition.get("children", []):
		results.append(_evaluate_condition(child, index_by_id, states, signals))
	if op == 1:
		for result in results:
			if not bool(result):
				return false
		return true
	if op == 2:
		for result in results:
			if bool(result):
				return true
		return false
	if op == 3:
		var count := 0
		for result in results:
			if bool(result):
				count += 1
		return count >= int(condition.get("required_count", 1))
	if op == 4:
		return results.size() == 1 and not bool(results[0])
	return false

func _eligible(definition: Dictionary, index_by_id: Dictionary,
		states: PackedInt32Array, signals: Dictionary) -> bool:
	if bool(definition.get("is_milestone", false)):
		var entry := String(definition.get("era_entry_milestone_id", ""))
		if not entry.is_empty():
			var entry_index := int(index_by_id.get(entry, -1))
			if entry_index < 0 or entry_index >= states.size() \
					or int(states[entry_index]) != TECH_COMPLETED:
				return false
		var completed_candidates := 0
		for candidate in definition.get("milestone_candidate_ids", []):
			var candidate_index := int(index_by_id.get(String(candidate), -1))
			if candidate_index >= 0 and candidate_index < states.size() \
					and int(states[candidate_index]) == TECH_COMPLETED:
				completed_candidates += 1
		return completed_candidates >= int(definition.get("milestone_required_count", 0))
	for prerequisite in definition.get("prerequisite_ids", []):
		var prerequisite_index := int(index_by_id.get(String(prerequisite), -1))
		if prerequisite_index < 0 or prerequisite_index >= states.size() \
				or int(states[prerequisite_index]) != TECH_COMPLETED:
			return false
	var routes = definition.get("research_routes", [])
	if routes.is_empty():
		return true
	for route in routes:
		if _evaluate_condition(route.get("condition", {}), index_by_id, states, signals):
			return true
	return false

func _output_path() -> String:
	if OS.has_environment("PK_TRIGGER_REPLAY_OUT"):
		return String(OS.get_environment("PK_TRIGGER_REPLAY_OUT"))
	var repo_root := ProjectSettings.globalize_path("res://").path_join("..").path_join("..").simplify_path()
	return repo_root.path_join("tmp").path_join(
		"trigger_replay_manual2_%d.json" % int(Time.get_unix_time_from_system()))
