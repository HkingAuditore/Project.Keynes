## M3: why does `discover` return `accepted=1` while `get_ideology_snapshot` reports
## zero ideas?
##
## WHAT THIS SETTLES
##
## The real-world fixture (ten minutes per run) shows:
##   discover -> ok=true accepted=1 pending=1
##   equip    -> ok=true accepted=0 pending=0
##   snapshot -> ideas=0
##
## `accepted=1` with `pending=1` means the command was QUEUED, and `ideas=0` means
## the queue was never drained into a stored idea. So either:
##   * the daily pass needs a day the fixture never reached, or
##   * the idea is stored but `get_ideology_snapshot` reports a different shape.
##
## Rather than burn another ten-minute run guessing, this probe asks the runtime
## directly for (a) the queue depth after submit and (b) whether `run_ideology_daily`
## reports work -- and does it in a loop of cheap calls, no world generation.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_ideology_queue_probe.gd

extends SceneTree

const CELLS := 64
const Q16_ONE := 65536

## Monotonic idempotency key across every batch this fixture submits.
var _seq := 0
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const CARD := "idea.salt_monopoly"


func _init() -> void:
	_run()


func _run() -> void:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	var ids: PackedStringArray = native.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD)
	print("[q] dense=%d of %d ids" % [dense, ids.size()])
	native.erase("ok")

	var domain: Resource = EffectDomainCatalogScript.build()
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# `configure_economy` requires a real profile Dictionary; passing null raises
	# "Cannot convert argument 2 from Nil to Dictionary". Load the production one.
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	print("[q] configure_economy ok=%s"
		% str(ext.configure_economy(country_ir, profile, CELLS, 97).get("ok", false)))
	print("[q] configure_effects ok=%s"
		% str(ext.configure_effects(effect_ir).get("ok", false)))
	print("[q] configure_modifiers ok=%s"
		% str(ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	# ── configure_country + bootstrap_country ───────────────────────────
	#
	# `validate_country` (`ideology_runtime.cpp:1173`) requires
	# `_country_runtime != nullptr && valid_handle(handle)`. Without it EVERY
	# ideology command is rejected at submit time -- while still returning
	# `ok=true`, which is why `pending_commands` was 0 and `receipts` was empty even
	# though `submit` reported `pending: 1`.
	print("[q] configure_country ok=%s"
		% str(ext.configure_country(country_ir, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELLS, 97).get("ok", false)))
	var bootstrap := PackedInt32Array()
	for c in range(CELLS):
		bootstrap.append(c)
	var boot_out: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.ramp_probe"]),
		"country_names": PackedStringArray(["Ramp Probe"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": bootstrap,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill_zero(CELLS))
	print("[q] bootstrap_country ok=%s" % str(boot_out.get("ok", false)))

	# What did the compiled ideology catalog actually carry for this card?
	# `seen=0` needs `active_templates` to be empty, and that list comes from
	# `level_persistent_offsets` / `persistent_definition_keys` (:2172-2177).
	var pkeys: PackedStringArray = native.get("persistent_definition_keys",
		PackedStringArray())
	var poffs: PackedInt32Array = native.get("level_persistent_offsets",
		PackedInt32Array())
	print("[q] persistent_definition_keys=%d offsets=%d"
		% [pkeys.size(), poffs.size()])
	var mine: Array = []
	for kk in pkeys:
		if String(kk).find("salt") >= 0:
			mine.append(String(kk))
	print("[q] salt persistent keys=%s" % str(mine.slice(0, 8)))
	print("[q] level_persistent_offsets=%s" % str(poffs.slice(0, 12)))
	print("[q] configure_ideologies ok=%s"
		% str(ext.configure_ideologies(native).get("ok", false)))

	# A bare ext has no country, so use the handle the country catalog seeded.
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	print("[q] handle=%d" % handle)
	if handle == 0:
		print("[q] no country in a bare ext -- discovering requires one")
		quit(0)
		return

	# ── HYPOTHESIS: ideology cannot settle without an Economy opinion ─────
	#
	# `run_ideology_daily` settles points from Economy's opinion revision
	# (world_ext_ideology.cpp:381-385). A bare ext has never opened an economy
	# epoch, so there is no opinion and `accrue_points` does nothing -- which would
	# leave every discovered idea PENDING forever.
	#
	# Drive one economy epoch BEFORE discovering, so the comparison is meaningful.
	# ── fill the 9 environment slots the epoch capture requires ───────────
	#
	# `world_ext_economy.cpp:802-828` returns `required_environment_slot_missing`
	# (in `fatal_reason`, not `reason`) unless all of these exist with the right
	# dtype: 8 x F32 + 1 x U8, each `cell_count` long. M1-8 established that the
	# DataCore write helpers can satisfy this; the missing piece was only that the
	# slots need size-`CELLS` data.
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f32 := PackedFloat32Array()
	zeros_f32.resize(CELLS)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(CELLS)
	# The slots do not exist on a bare ext, so `component_id` returns -1 and the
	# writes silently did nothing (`filled=0`). `register_component(name, dtype,
	# stride, track_prev)` is bound to GDScript (`world_ext_bind_methods.cpp:28`)
	# and needs no MapData -- dtype: F32=0, I32=1, U8=2 (components/slot.h:20-24).
	# ── SIZE THE SLOTS FIRST ─────────────────────────────────────────────
	#
	# `write_f32_range` does NOT grow a slot: it bails on
	# `start + n > s.arr_f32.size()` (world_ext.cpp:411) and the failure is silent.
	# Slots are sized from `_entity_count` -- `register_component` pre-sizes to it
	# (world_ext.cpp:182-185) and `create_entities` grows every existing slot
	# (:226-228). So the entities must exist BEFORE the slots are registered.
	#
	# Without this the probe reported `filled=10 of 10` while every write had been
	# dropped, and the economy then failed with
	# `economy_environment_snapshot_invalid` on a length mismatch.
	var before_entities := int(ext.entity_count()) if ext.has_method("entity_count") else -1
	if before_entities < CELLS and ext.has_method("create_entities"):
		ext.create_entities(CELLS - maxi(before_entities, 0))
	print("[q] entity_count before=%d after=%d"
		% [before_entities,
			int(ext.entity_count()) if ext.has_method("entity_count") else -1])

	var filled := 0
	for slot_name in f32_slots:
		var sid := int(ext.component_id(slot_name))
		if sid < 0:
			sid = int(ext.register_component(slot_name, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f32)
			filled += 1
	for slot_name in u8_slots:
		var sid := int(ext.component_id(slot_name))
		if sid < 0:
			sid = int(ext.register_component(slot_name, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u8)
			filled += 1
	# Print the ACTUAL slot length vs the economy's own cell_count. The earlier
	# attempt assumed both were CELLS; `capture_environment` compares
	# `count != _cell_count` (economy_runtime.cpp:4466) and I never verified the two
	# numbers matched.
	var temp_sid := int(ext.component_id("cell_temp"))
	print("[q] cell_temp sid=%d" % temp_sid)
	print("[q] environment slots filled=%d of %d"
		% [filled, f32_slots.size() + u8_slots.size()])

	var epoch_ok := false
	if ext.has_method("begin_or_reuse_economy_input_epoch"):
		# Six generation fields (world_ext_economy.cpp:171-182). Passing an int
		# raises "Cannot convert argument 2 from int to Dictionary" -- the failure is
		# reported in `fatal_reason`, not `reason`, which is why the first attempt
		# printed an empty reason.
		var ep: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
			"sample_day": 0, "epoch_id": 1, "map_generation": 1,
			"building_generation": 1, "country_generation": 1,
			"resource_generation": 1})
		epoch_ok = bool(ep.get("ok", false))
		print("[q] economy epoch ok=%s reason=%s"
			% [str(ep.get("ok", "?")),
				str(ep.get("reason", ep.get("fatal_reason", "-")))])
	# ── BOOTSTRAP the economy ────────────────────────────────────────────
	#
	# `run_economy_slice` on an unbootstrapped runtime returns `ok=? done=true`
	# without doing anything, so no class opinion is ever produced and `equip`
	# stays rejected. The working sequence is bootstrap_economy(population,
	# market) then slice (building_resource_chain_test.gd:102-118, 414-419).
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var sig_keys: PackedStringArray = econ_catalog.get(
		"signature_keys", PackedStringArray())
	var good_count: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * good_count)
	stock.fill(0)
	var farmer_sig: int = sig_keys.find("subsistence_farmer|default")
	var serf_sig: int = sig_keys.find("serf|default")
	var merchant_sig: int = sig_keys.find("merchant|default")
	print("[q] sigs farmer=%d serf=%d merchant=%d goods=%d"
		% [farmer_sig, serf_sig, merchant_sig, good_count])
	if farmer_sig >= 0 and serf_sig >= 0:
		var cells_idx := PackedInt32Array()
		var sig_ids := PackedInt32Array()
		var pops := PackedInt64Array()
		var funds := PackedInt64Array()
		for c in range(CELLS):
			for pair in [[farmer_sig, 20], [serf_sig, 20]]:
				cells_idx.append(c)
				sig_ids.append(int(pair[0]))
				pops.append(int(pair[1]))
				funds.append(10000000)
		var econ_boot: Dictionary = ext.bootstrap_economy({
			"cell_indices": cells_idx,
			"signature_ids": sig_ids,
			"population": pops,
			"funds": funds,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		print("[q] bootstrap_economy ok=%s reason=%s"
			% [str(econ_boot.get("ok", "?")),
				str(econ_boot.get("reason", econ_boot.get("code", "-")))])

	# The slice takes `{day_index, tick_index}`, not a budget
	# (building_resource_chain_test.gd:417). Passing `{budget_ms}` returned
	# `ok=false done=true`, which read as "the economy finished" when in fact it
	# never ran.
	# Run the economy to COMPLETION. `done=false` after one slice simply means the
	# day is sliced across many calls, exactly as `building_resource_chain_test.gd`
	# says with its `for slice in range(256)` loop. One slice was never enough --
	# and until the day finishes, no class opinion exists, so `equip` stays rejected
	# with `ideology_class_opinion_unavailable`.
	if ext.has_method("run_economy_slice"):
		var slices := 0
		for _slice in range(0, 256):
			var esl: Dictionary = ext.run_economy_slice(
				{"day_index": 0, "tick_index": _slice})
			slices += 1
			if bool(esl.get("done", false)):
				break
			if not bool(esl.get("ok", true)):
				print("[q] economy slice failed at #%d: %s"
					% [_slice, str(esl)])
				break
		print("[q] economy day 0 finished after %d slices" % slices)

	# ── THE ACTUAL BLOCKER: no country row ───────────────────────────────
	#
	# `apply_command` bails at `ideology_runtime.cpp:4549`:
	#     if (!validate_country(command.country_handle, country_slot)) {
	#         error = "ideology_country_handle_stale"; return false;
	#     }
	# so EVERY ideology command (discover / equip / grant points alike) fails
	# whenever the ideology runtime has no matching country row -- which is exactly
	# what `bootstrap_country` creates. A bare ext that only calls
	# `configure_economy` never does that, so `ideas=0` regardless of the command.
	#
	# The receipts are the witness: a rejected command still returns
	# `ok=true accepted=1`, so `ok` alone can NEVER be read as "the command ran".
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 8) \
		if ext.has_method("poll_ideology_receipts") else {}
	print("[q] receipts=%s" % str(receipts))

	# ── BYPASS attempt: grant points directly ────────────────────────────
	#
	# `run_ideology_daily` settles points from Economy's opinion
	# (world_ext_ideology.cpp:381-385), and Economy cannot open an epoch here
	# (`required_environment_slot_missing`). `GRANT_IDEOLOGY_POINTS = 2`
	# (ideology_runtime.h:66) is a COMMAND, so it may supply the points without an
	# opinion revision -- which would break the dependency chain at its root.
	var granted: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 2, "day": 0, "handle": handle, "idea": -1,
		 "value": 64 * Q16_ONE}]))
	print("[q] grant points=%s" % str(granted))
	for _g in range(3):
		var gsl: Dictionary = ext.run_ideology_daily(0)
		if bool(gsl.get("done", false)):
			break
	print("[q] after grant: snapshot ideas=%d"
		% (ext.get_ideology_snapshot(handle).get("ideas", []) as Array).size())

	var disc: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": dense}]))
	print("[q] discover=%s" % str(disc))
	# discover only marks the idea KNOWN; `location` stays INACTIVE until equip.
	# `commands_applied=1` on day 0 confirms the queue finally drains, so the next
	# step is the actual equip and a re-check.
	for _d in range(0, 3):
		var ds: Dictionary = ext.run_ideology_daily(_d)
		if bool(ds.get("done", false)):
			break
	# Raise understanding BEFORE equipping, exactly as the working card fixture does
	# (ideology_card_content_test.gd:662-678). Level thresholds are 0 / 4 / 12, so
	# 12.0 Q16 lands the card at level 3 -- a level-0 card may satisfy `equip` yet
	# still start no transition, which is what `transition_pending=[0]` suggested.
	var under: Dictionary = ext.submit_ideology_commands(_commands([
		# Level 1 (understanding 0). Raising to level 2/3 was the mistake:
		# `collect_effect_activations` bails at
		#     if (state.level >= definition.level_count) return true;   // :2165
		# so a card raised above its authored level count contributes NOTHING and
		# the rebuild reports seen=0 while the idea looks perfectly ACTIVE.
		{"op": 8, "day": 0, "handle": handle, "idea": dense,
		 "value": 0}]))
	print("[q] understanding=%s" % str(under))
	for _u in range(0, 3):
		var us: Dictionary = ext.run_ideology_daily(_u)
		if bool(us.get("done", false)):
			break
	var equip: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 5, "day": 0, "handle": handle, "idea": dense}]))
	print("[q] equip=%s" % str(equip))
	for _d2 in range(0, 4):
		var es: Dictionary = ext.run_ideology_daily(_d2)
		var snap2: Dictionary = ext.get_ideology_snapshot(handle)
		# The snapshot exposes PARALLEL ARRAYS (`idea_ids` / `locations` /
		# `levels` / `understanding_q16`), not a list of dictionaries. Reading
		# `ideas` returned an empty Array every time, which looked identical to
		# "no idea exists" -- the sixth wrong-shape read in this investigation.
		var idea_ids: PackedInt32Array = snap2.get("idea_ids", PackedInt32Array())
		var locs: PackedInt32Array = snap2.get("locations", PackedInt32Array())
		var levels: PackedInt32Array = snap2.get("levels", PackedInt32Array())
		var active := 0
		for loc in locs:
			if int(loc) != 0:
				active += 1
		# A REJECTED command writes a receipt carrying the reason
		# (`ideology_runtime.cpp:4672`). Polling after the daily pass is what makes
		# the rejection visible -- the earlier attempt polled BEFORE any pass ran and
		# correctly got zero receipts, which read as "nothing happened".
		var rec: Dictionary = ext.poll_ideology_receipts(0, 32)
		var reasons: PackedStringArray = rec.get("reasons", PackedStringArray())
		var statuses: PackedInt32Array = rec.get("statuses", PackedInt32Array())
		print("[q]   receipts count=%d statuses=%s reasons=%s"
			% [int(rec.get("count", 0)), str(statuses), str(reasons)])
		var pend: PackedByteArray = snap2.get("transition_pending",
			PackedByteArray())
		var slots: PackedInt32Array = snap2.get("slot_indices",
			PackedInt32Array())
		print("[q]   transition_pending=%s slot_indices=%s points_q16=%s"
			% [str(pend), str(slots), str(snap2.get("ideology_points_q16", "?"))])
		print("[q] equip-settle day=%d idea_ids=%d locations=%s levels=%s active=%d applied=%s"
			% [_d2, idea_ids.size(), str(locs), str(levels), active,
				str(es.get("commands_applied", "?"))])
		if active > 0:
			print("[q] ACTIVE!")
			# The derived layer is rebuilt INSIDE `run_daily`
			# (ideology_runtime.cpp:4611), so reading the counters immediately after
			# activation reports the PREVIOUS rebuild, when no idea was active yet.
			# Drive one more day first.
			for _post in range(0, 4):
				await process_frame
				if bool(ext.run_ideology_daily(_d2 + 1 + _post).get("done", false)):
					break
			# ── THE ACTUAL GOAL ───────────────────────────────────────────
			#
			# An ACTIVE idea is what the cell layer needs in order to produce a
			# derived contribution. Read the four counters the production sampler
			# exposes (ideology_runtime.cpp:5949-5952) and, if a ramp term ran, the
			# materialise report.
			var rep: Dictionary = ext.get_ideology_report()
			# `collect_effect_activations` bails at
			#     if (state.level >= definition.level_count) return true;   // :2165
			# so a card raised ABOVE its level count produces nothing. Level was 2;
			# print the card's level count and the idea's program list so a mismatch
			# is visible instead of inferred.
			var snap3: Dictionary = ext.get_ideology_snapshot(handle)
			print("[q] levels=%s understanding=%s"
				% [str(snap3.get("levels", "?")),
					str(snap3.get("understanding_q16", "?"))])
			# Which backend does the runtime assign to the ACTIVE card's program?
			# `seen=0` with an ACTIVE idea means the eligibility column said
			# EffectInstance, not DerivedCell -- the collector then produces an
			# instance and NO derived row (I01). Ask it directly instead of inferring.
			if ext.has_method("probe_cell_program_backend"):
				var probe: Dictionary = ext.probe_cell_program_backend({
					"target_domain": 2,
					"target_selector_kind": 12,
					"lifecycle": 0, "duration_days": -1,
					"stack_policy": 0, "max_stacks": 1,
					"command_value_mode": 1,
					"command_stack_top_is_constant": false,
					"command_has_metric_ramp": true,
					"command_definition_resolved": true,
					"command_all_terms_sum": true,
					"command_stacks": 1,
					"command_duration_days": -1,
				})
				print("[q] probe backend=%s reason=%s detail=%s"
					% [str(probe.get("backend", "?")),
						str(probe.get("reason", "?")),
						str(probe.get("detail", "?"))])
				# The old v1 cell-program plane is deleted (plan §15.7); its summary bridge
				# no longer exists. The derived layer's own counts are the equivalent read.
				print("[q] derived_front_cells=%s"
					% str(ext.get_derived_cell_layer_report().get("cell_count", "?")))
			# Does the compiled EFFECT catalog contain the card's program at all?
			# `metric_mask` is computed from the program definition, so a missing
			# definition means `has_metric_ramp` is false and the eligibility column
			# files the card under `non_constant_value_mode` -- which is exactly the
			# answer the probe already returned. Verify the definition is present.
			var keys2: PackedStringArray = effect_ir.get("program_keys",
				PackedStringArray()) if effect_ir.has("program_keys") \
				else PackedStringArray()
			# DECISIVE: does EffectRuntime hold the card's program?
			# `evaluate_effect_program_magnitude` returns
			# `effect_program_not_found` when it does not -- and a missing program is
			# what makes `metric_mask` empty, which makes `has_metric_ramp` false,
			# which files the card under `non_constant_value_mode`.
			var z := PackedInt64Array()
			z.resize(108)
			z.fill(0)
			for pk in ["ideology.effect.salt_monopoly_l1",
					"ideology.effect.salt_monopoly",
					"ideology.effect.SaltMonopolyL1"]:
				var ev: Dictionary = ext.evaluate_effect_program_magnitude(pk, z) \
					if ext.has_method("evaluate_effect_program_magnitude") else {}
				print("[q] program %s -> ok=%s reason=%s"
					% [pk, str(ev.get("ok", "?")), str(ev.get("reason", "-"))])
			print("[q] effect catalog program_keys=%d" % keys2.size())
			var ramp_keys: Array = []
			for kk in keys2:
				var s := String(kk)
				if s.find("salt_monopoly") >= 0 or s.find("ideology.effect") >= 0:
					ramp_keys.append(s)
			print("[q] ideology programs in effect catalog=%s"
				% str(ramp_keys.slice(0, 6)))
			# ROOT CAUSE CHECK (M3-25): `resolve_effect_targets` bails at
			#     const int32_t anchor = country_anchor_cell(country_slot);
			#     if (anchor < 0) return false;              // ideology_runtime.cpp:1907-1908
			# and `country_anchor_cell` returns -1 when `_epoch_cell_country.size() !=
			# _cell_count` (economy_runtime_family_buff.cpp:1024). If this prints -1,
			# the empty territory plane -- not the eligibility column -- is why
			# `seen` stays 0.
			if ext.has_method("query_country_anchor_cell"):
				var slot_id := int(handle & 0xffffffff)
				var anchor_v: Variant = ext.query_country_anchor_cell(slot_id)
				print("[q] country_anchor_cell(slot=%d) = %s"
					% [slot_id, str(anchor_v)])
			# M4 diagnosis: does the eligibility column accept kind 16 at all?
			# `present=[1,1,1,1]` in the x1b fixture means instances still exist, so
			# `backend.backend` was NOT DerivedCell even with Sources enabled.
			if ext.has_method("probe_cell_program_backend"):
				for probe_kind in [12, 16]:
					var p16: Dictionary = ext.probe_cell_program_backend({
						"target_domain": 2,
						"target_selector_kind": probe_kind,
						"lifecycle": 0, "duration_days": -1,
						"stack_policy": 0, "max_stacks": 1,
						"command_value_mode": 0,
						"command_definition_resolved": true,
						"command_all_terms_sum": true,
						"command_stacks": 1,
						"command_duration_days": -1,
					})
					print("[q] kind=%d -> backend=%s reason=%s detail=%s"
						% [probe_kind, str(p16.get("backend", "?")),
							str(p16.get("reason", "?")),
							str(p16.get("detail", "?"))])
			print("[q] === RAMP COUNTERS ===")
			print("[q] cell_layer_rebuild_visits=%s"
				% str(rep.get("cell_layer_rebuild_visits", "?")))
			print("[q] ramp_samples_taken=%s memoised=%s evaluated=%s deferred=%s"
				% [str(rep.get("ramp_samples_taken", "?")),
					str(rep.get("ramp_samples_memoised", "?")),
					str(rep.get("ramp_terms_evaluated", "?")),
					str(rep.get("ramp_terms_deferred", "?"))])
			var mat: Dictionary = ext.get_derived_materialize_report()
			print("[q] materialise seen=%s derived=%s legacy=%s truncated=%s"
				% [str(mat.get("programs_seen", "?")),
					str(mat.get("programs_derived", "?")),
					str(mat.get("programs_skipped_legacy", "?")),
					str(mat.get("truncated", "?"))])
			break

	# Drain, printing each pass so a pass that does nothing is visible.
	for d in range(0, 4):
		var last: Dictionary = {}
		for i in range(4):
			last = ext.run_ideology_daily(d)
			if bool(last.get("done", false)) or not bool(last.get("ok", false)):
				break
		var snap: Dictionary = ext.get_ideology_snapshot(handle)
		var ideas: Array = snap.get("ideas", [])
		# `commands_applied` / `pending_commands` from the slice itself tell us
		# whether the consume loop reached the command. The earlier version read
		# `work_done`, which `run_daily_slices` does not even set (-1), so it printed
		# a meaningless number for four rounds.
		print("[q] day=%d ideas=%d commands_applied=%s pending_commands=%s stage=%s"
			% [d, ideas.size(), str(last.get("commands_applied", "?")),
				str(last.get("pending_commands", "?")), str(last.get("stage", "?"))])
		if ideas.size() > 0:
			print("[q] IDEA ROW=%s" % str(ideas[0]))
			break

	quit(0)


func _u8_fill_zero(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	return out


func _commands(rows: Array) -> Dictionary:
	var count: int = rows.size()
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for i in range(count):
		var row: Dictionary = rows[i]
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		producers.append(1)
		# `sequences` is the IDEMPOTENCY KEY, not a within-batch index.
		#
		# `submit_commands` drops any command whose `sequence` is <= the producer's
		# high watermark (`ideology_runtime.cpp:4536-4539`), and that watermark is
		# updated on every accepted batch. Restarting at 1 each batch therefore made
		# every command after the first look like a duplicate -- `accepted=0
		# duplicates=1`, which is exactly what five rounds of debugging hit.
		_seq += 1
		sequences.append(_seq)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days,
		"source_priorities": priorities, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}
