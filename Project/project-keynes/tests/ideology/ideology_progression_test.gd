extends SceneTree

# Native progression contract for the deepened ideology catalog: increment-only
# points (baseline first), draw cost curve, reroll, technology slot capacity and
# school resonance at 2 cards.

const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const Q16 := 65536

var _checks := 0
var _failures := 0
var _sequence := 1


func _init() -> void:
	_run()
	print("ideology progression: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var ext := _new_ext(native_catalog)
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, native_catalog, 1, 20260818))
	var modifier := ModifierFacadeScript.new()
	_expect("modifier configures",
		bool(modifier.configure(ext, 1).get("ok", false)))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	_expect("economy configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 20260818).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var selected := PackedInt32Array([
		signatures.find("hunter|default"),
		signatures.find("sharecropper|default"),
		signatures.find("corvee_worker|default"),
		signatures.find("scholar|default"),
	])
	_expect("population bootstraps", selected.find(-1) == -1 and bool(
		ext.bootstrap_economy({
			"cell_indices": PackedInt32Array([0, 0, 0, 0]),
			"signature_ids": selected,
			"population": PackedInt64Array([100, 100, 100, 100]),
			"funds": PackedInt64Array([0, 0, 0, 0]),
		}, {}).get("ok", false)))
	_run_economy(ext, 0)
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_expect("Effect runtime configures", effect_catalog != null and bool(
		ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)))
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
		native_catalog, native_catalog)
	_expect("ideology content compiles", bool(ideology_ir.get("ok", false)))
	if not bool(ideology_ir.get("ok", false)):
		return
	var runtime_ir := ideology_ir.duplicate(true)
	runtime_ir.erase("ok")
	_expect("ideology runtime configures",
		bool(ext.configure_ideologies(runtime_ir).get("ok", false)))
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	_expect("country handle exists", handle != 0)

	# --- Points: start at zero, first observation only sets the baseline.
	_drain_ideology(ext, 1)
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	_expect("points start at zero", int(snap.get("ideology_points_q16", -1)) == 0
		and int(snap.get("starting_points_q16", -1)) == 0)
	_expect("first observation establishes the baseline without income",
		bool(snap.get("point_baseline_ready", false))
		and int(snap.get("lifetime_points_q16", -1)) == 0
		and int(snap.get("point_ledger_gain_q16", -1)) == 0)
	var preview: Dictionary = ext.preview_ideology_offer_eligibility(handle)
	_expect("preview rejects a draw without points and does not mutate",
		not bool(preview.get("can_draw", true))
		and String(preview.get("reason", "")) == "ideology_points_insufficient"
		and int(preview.get("pool_size", 0)) >= 3
		and int(ext.get_ideology_snapshot(handle).get("draw_sequence", -1)) == 0)

	# --- Slot capacity grows with technology (all technologies owned here).
	var owned: PackedByteArray = snap.get("capacity_unlock_owned", PackedByteArray())
	_expect("all capacity unlocks are owned with full technology",
		owned.size() == 5 and owned.count(1) == 5)
	_expect("slot capacity reaches the catalog maximum",
		int(snap.get("ideology_slots_capacity", 0)) == 6
		and int(snap.get("national_spirit_slots_capacity", 0)) == 3)

	# --- Cost curve and reroll.
	_submit(ext, 2, [{"opcode": 2, "value": 80 * Q16}])
	_drain_ideology(ext, 2)
	snap = ext.get_ideology_snapshot(handle)
	_expect("grant adds points", int(snap.ideology_points_q16) == 80 * Q16)
	var points := int(snap.ideology_points_q16)
	var expected_cost := 6 * Q16
	var costs_ok := true
	var reroll_ok := true
	for draw in 10:
		snap = ext.get_ideology_snapshot(handle)
		if int(snap.next_offer_cost_q16) != expected_cost:
			costs_ok = false
		if int(snap.ideology_points_q16) < expected_cost:
			break
		# Settle the previous iteration's equip transaction before issuing the
		# next command: a PENDING transition rejects new commands, which would
		# make every second choice disappear.
		_commit_effect(ext, 3 + draw)
		_drain_ideology(ext, 3 + draw)
		_submit(ext, 3 + draw, [{"opcode": 3}])
		_drain_ideology(ext, 3 + draw)
		snap = ext.get_ideology_snapshot(handle)
		if int(snap.ideology_points_q16) != points - expected_cost \
				or not bool(snap.offer_active):
			costs_ok = false
			break
		if int(snap.reroll_cost_q16) != expected_cost * 50 / 100:
			reroll_ok = false
		points = int(snap.ideology_points_q16)
		if draw == 0:
			var generation := int(snap.offer_generation)
			var reroll_cost := int(snap.reroll_cost_q16)
			_submit(ext, 3, [{"opcode": 10, "generation": generation}])
			_drain_ideology(ext, 3)
			snap = ext.get_ideology_snapshot(handle)
			_expect("reroll replaces the offer for half the draw cost",
				bool(snap.offer_active)
				and int(snap.offer_generation) > generation
				and int(snap.ideology_points_q16) == points - reroll_cost)
			points = int(snap.ideology_points_q16)
		_submit(ext, 3 + draw, [{"opcode": 4, "generation": int(snap.offer_generation),
			"choice": 0}])
		_drain_ideology(ext, 3 + draw)
		_commit_effect(ext, 3 + draw)
		expected_cost = (expected_cost * 120 + 50) / 100
	snap = ext.get_ideology_snapshot(handle)
	_expect("every draw is paid and costs 20% more than the previous", costs_ok)
	_expect("reroll cost is 50% of the paid draw", reroll_ok)
	# Not `>= 5` any more: since §36.3 an already-known card comes back as a
	# refine, so N paid draws do not guarantee N distinct cards. What must hold
	# is that choosing keeps growing the collection, and that a duplicate is what
	# the remaining draws hit.
	_expect("chosen cards enter the collection",
		(snap.known_ids as PackedInt32Array).size() >= 3
		and (snap.known_ids as PackedInt32Array).size() <= 6)

	# No low ceiling: the cost keeps compounding by 20% per paid draw.
	var paid_draws := int(snap.draw_sequence)
	var compounded := 6 * Q16
	for _step in paid_draws:
		compounded = (compounded * 120 + 50) / 100
	_expect("draw cost compounds without a low cap",
		paid_draws >= 5 and int(snap.next_offer_cost_q16) == compounded
		and compounded > 12 * Q16)

	# --- School resonance activates at two equipped cards of one school.
	var synergy_ids: PackedStringArray = ideology_ir.get("synergy_ids", PackedStringArray())
	var ideology_ids: PackedStringArray = ideology_ir.ideology_ids
	var school_of := {}
	for definition in ideology_catalog.definitions:
		school_of[String(definition.id)] = String(definition.school_id)
	for index in ideology_ids.size():
		_submit(ext, 40, [{"opcode": 1, "idea": index}])
	_drain_ideology(ext, 40)
	var resonance_ok := false
	var dropped := false
	var day := 41
	for school in ["agrarian", "learning", "commerce", "mobilization", "industry", "harmony"]:
		var members := PackedInt32Array()
		for index in ideology_ids.size():
			if school_of.get(ideology_ids[index], "") == school:
				members.append(index)
		var explain: Dictionary = ext.explain_ideologies(handle, members)
		var equip_flags: PackedByteArray = explain.get("equip_allowed", PackedByteArray())
		var equipped := PackedInt32Array()
		for row in members.size():
			if equipped.size() >= 2 or row >= equip_flags.size() or equip_flags[row] == 0:
				continue
			_submit(ext, day, [{"opcode": 5, "idea": members[row]}])
			_drain_ideology(ext, day)
			_commit_effect(ext, day)
			_drain_ideology(ext, day + 1)
			day += 2
			if _location(ext, handle, members[row]) == 1:
				equipped.append(members[row])
			else:
				break
		if equipped.size() < 2:
			for idea in equipped:
				_submit(ext, day, [{"opcode": 6, "idea": idea}])
				_drain_ideology(ext, day)
				_commit_effect(ext, day)
				_drain_ideology(ext, day + 1)
				day += 2
			continue
		snap = ext.get_ideology_snapshot(handle)
		var active: PackedInt32Array = snap.get("active_synergy_ids", PackedInt32Array())
		var tier2 := synergy_ids.find("resonance.%s.2" % school)
		if tier2 < 0:
			for index in synergy_ids.size():
				if synergy_ids[index].contains("resonance") \
						and synergy_ids[index].contains(school) \
						and synergy_ids[index].ends_with("2"):
					tier2 = index
		resonance_ok = resonance_ok or (tier2 >= 0 and active.has(tier2))
		# Unequipping one card drops the resonance again.
		# Repeal is gated by support; drop whichever member may be repealed.
		var repeal_explain: Dictionary = ext.explain_ideologies(handle, equipped)
		var repeal_allowed: PackedByteArray = repeal_explain.get("support_allowed", PackedByteArray())
		var drop := -1
		for row in equipped.size():
			if row * 3 + 1 < repeal_allowed.size() and repeal_allowed[row * 3 + 1] != 0:
				drop = equipped[row]
				break
		if drop < 0:
			continue
		_submit(ext, day, [{"opcode": 6, "idea": drop}])
		_drain_ideology(ext, day)
		_commit_effect(ext, day)
		_drain_ideology(ext, day + 1)
		snap = ext.get_ideology_snapshot(handle)
		active = snap.get("active_synergy_ids", PackedInt32Array())
		_expect("%s resonance drops below two cards" % school, not active.has(tier2))
		dropped = true
		break
	if not dropped:
		print('  [SKIP] no repealable school pair for the drop check')
	_expect("a school resonance activates at two equipped cards", resonance_ok)


func _location(ext: Object, handle: int, idea: int) -> int:
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var ids: PackedInt32Array = snap.get("idea_ids", PackedInt32Array())
	var locations = snap.get("locations", PackedInt32Array())
	var pending = snap.get("transition_pending", PackedByteArray())
	var row := ids.find(idea)
	if row < 0 or (row < pending.size() and pending[row] != 0):
		return -1
	return int(locations[row]) if row < locations.size() else -1


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var slot: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(slot, 0, PackedByteArray([0]))
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for index in reserve_slots.size():
		var reserve: int = ext.register_component(
			StringName(reserve_slots[index]), 0, 1, false)
		var extra: int = ext.register_component(
			StringName(extra_slots[index]), 0, 1, false)
		ext.write_f32_range(reserve, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra, 0, PackedFloat32Array([0.0]))
	return ext


func _run_economy(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in 512:
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)):
			return report
	return report


func _submit(ext: Object, day: int, rows: Array[Dictionary]) -> bool:
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	var batch := {
		"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"producer_ids": PackedInt32Array(), "source_priorities": PackedInt32Array(),
		"sequences": PackedInt64Array(), "country_handles": PackedInt64Array(),
		"ideology_ids": PackedInt32Array(), "values_q16": PackedInt64Array(),
		"offer_generations": PackedInt64Array(), "choice_indices": PackedInt32Array(),
		"gate_ids": PackedInt32Array(),
	}
	for row in rows:
		batch.opcodes.append(int(row.opcode))
		batch.effective_days.append(day)
		batch.producer_ids.append(1)
		batch.source_priorities.append(0)
		batch.sequences.append(_sequence)
		_sequence += 1
		batch.country_handles.append(handle)
		batch.ideology_ids.append(int(row.get("idea", -1)))
		batch.values_q16.append(int(row.get("value", 0)))
		batch.offer_generations.append(int(row.get("generation", 0)))
		batch.choice_indices.append(int(row.get("choice", -1)))
		batch.gate_ids.append(-1)
	return bool(ext.submit_ideology_commands(batch).get("ok", false))


func _drain_ideology(ext: Object, day: int) -> bool:
	for _slice in 128:
		var report: Dictionary = ext.run_ideology_daily(day)
		if not bool(report.get("ok", false)):
			return false
		if bool(report.get("done", false)):
			return true
	return false


func _commit_effect(ext: Object, day: int) -> bool:
	for _slice in 128:
		var report: Dictionary = ext.run_effect_daily(day)
		if not bool(report.get("ok", false)):
			return false
		if bool(report.get("done", false)):
			break
	var dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	if not bool(dispatch.get("ok", false)):
		return false
	if not bool(ext.run_modifier_daily(day).get("ok", false)):
		return false
	return bool(ext.ack_effect_native_modifier().get("ok", false))


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _latest_reason(ext: Object) -> String:
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 128)
	var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
	return String(reasons[-1]) if not reasons.is_empty() else ""
