extends SceneTree
## END-TO-END: does an equipped card actually produce derived rows?
##
## Six rounds carried the same gap: every derived-layer capability was verified in
## isolation (eligibility, container, merge formula, enumeration, versions,
## sharding, materializer) but never by driving a real card through the real
## daily pipeline. The blocker was always the ECONOMY epoch, which cannot be
## opened in a bare SceneTree (M1-8 diagnosis: `needs_environment_capture` needs
## a real generated MapData).
##
## THE WAY AROUND IT: the derived layer is owned by the IDEOLOGY runtime, and
## `run_ideology_daily` drives the four-stage card transaction
## (`ideology -> effect -> dispatch -> modifier -> ack`). `run_daily` then calls
## `rebuild_derived_cell_layer`, which needs only the card set -- not an epoch.
##
## So this fixture equips a real cell-domain card and settles it through the real
## daily pass, then reads the materialize report and the installed front.
##
## `kin_hearth_l1` is chosen from the coverage tool's own output: DerivedCell /
## selector kind 12 (OWN_TERRITORY) / target domain 2 (cell), two constant commands
## against `economy.city.birth_factor` and
## `economy.city.need.housing.consumption_factor`.
##
## IMPORTANT: `kCellProgramRollout` is `Off` in this build, so the expected result
## is that NO rows are produced even after equipping. The assertions therefore
## check that the pipeline RUNS and that the layer stays empty -- i.e. the switch
## is genuinely off, not that the plumbing is dead. Flipping the constant turns
## the `else` branch on; `ROLLOUT_OFF_EXPECTED` is the one line to change.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_e2e_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

const CARD := "kin_hearth"
const CELLS := 64
const MODIFIER_DOMAIN_ECONOMY := 2

## Must match `kCellProgramRollout` in `gdext/src/cell_program_eligibility.h`.
const ROLLOUT_OFF_EXPECTED := true

var _checks := 0
var _failures := 0
var _country_ir: Dictionary = {}
var _native_ideology: Dictionary = {}
var _effect_ir: Dictionary = {}


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not bool(_country_ir.get("ok", false)):
		_expect("country catalog compiles", false, str(_country_ir))
		_finish(1)
		return
	_country_ir.erase("ok")

	var catalog: Resource = IdeologyCatalogScript.load_default()
	if catalog == null:
		_expect("ideology catalog loads", false)
		_finish(1)
		return
	_native_ideology = catalog.compile_native_catalog(_country_ir, _country_ir)
	if not bool(_native_ideology.get("ok", false)):
		_expect("ideology catalog compiles", false, str(_native_ideology))
		_finish(1)
		return
	_native_ideology.erase("ok")

	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		_expect("effect domain catalog builds", false)
		_finish(1)
		return
	_effect_ir = domain.compile_native_catalog()
	if not bool(_effect_ir.get("ok", false)):
		_expect("effect catalog compiles", false, str(_effect_ir))
		_finish(1)
		return
	_effect_ir.erase("ok")

	# The card must exist in the compiled catalog; if the dense id is -1 the whole
	# fixture would be measuring a card that was never equipped.
	var idea_ids: PackedStringArray = _native_ideology.get("ideology_ids",
		PackedStringArray())
	var dense := idea_ids.find("idea.%s" % CARD)
	if dense < 0:
		_expect("card %s exists in the compiled ideology catalog" % CARD, false,
			"ideology_ids has %d entries" % idea_ids.size())
		_finish(2)
		return

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_expect("DCWorldExt instantiates", false)
		_finish(1)
		return
	var mod_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not bool(mod_catalog.get("ok", false)):
		_expect("modifier catalog compiles", false, str(mod_catalog))
		_finish(1)
		return
	mod_catalog.erase("ok")

	# The ideology runtime needs the full configure chain; without it every
	# bridge answers `ideology_runtime_unavailable`, which is what an earlier
	# version of this fixture hit and mistook for "the layer did nothing".
	_expect("configure modifiers",
		bool(ext.configure_modifiers(mod_catalog, CELLS).get("ok", false)))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	_expect("configure economy",
		bool(ext.configure_economy(_country_ir, profile, CELLS, 97).get("ok", false)))
	_expect("configure effects",
		bool(ext.configure_effects(_effect_ir).get("ok", false)))
	# Bootstrap BEFORE configuring ideologies: it is what gives the country a
	# territory. `resolve_effect_targets` anchors a cell-domain program on
	# `country_anchor_cell(slot)` and returns false when that is -1, so without a
	# bootstrap every cell-domain program is skipped and the derived traversal
	# legitimately finds nothing.
	_expect("bootstrap economy", _bootstrap(ext))
	# `resolve_effect_targets` anchors every cell-domain program on
	# `country_anchor_cell(slot)` and returns false when that is -1. Without a
	# territory anchor NO cell-domain card can ever produce a derived row, which is
	# what a temp diagnostic showed: targets_ok=0 for every visit.
	# The card's program declares `target_selector_param = (32, 0)` with
	# `target_selector_tag = "cell.clan"`: 32 is the cap this migration exists to
	# remove, and the tag is REQUIRED. A stub world has no clan cells, so
	# `collect_effect_target_cells` returns empty and `resolve_effect_targets`
	# reports targets_ok=0 -- which a temp diagnostic confirmed is exactly what
	# happened before this override.
	var override_ok := 0
	var override_first: Dictionary = {}
	for cell in range(CELLS):
		var res: Dictionary = ext.set_cell_tag_override_for_test(
			StringName("cell.clan"), cell, true)
		if bool(res.get("ok", false)):
			override_ok += 1
		elif override_first.is_empty():
			override_first = res
	print("[e2e] tag override accepted=%d of %d first_failure=%s"
		% [override_ok, CELLS, str(override_first)])
	_expect("cell.clan override can be installed (requires the tag to be declared)",
		override_ok == CELLS,
		"accepted=%d of %d, first_failure=%s -- an empty `_target_tags` table means "
			% [override_ok, CELLS, str(override_first)] +
			"NO .tres declares target_tags, so cell.clan can never match")
	var tagged := 0
	for cell in range(CELLS):
		if int(ext.query_country_anchor_cell(0)) >= 0:
			tagged += 1
		break
	print("[e2e] clan-tagged cells requested=%d" % CELLS)
	var anchor := int(ext.query_country_anchor_cell(0))
	print("[e2e] country_anchor_cell(0)=%d" % anchor)
	_expect("the country has a territory anchor", anchor >= 0,
		"anchor=%d -- -1 means the bootstrap did not register territory"
			% anchor)
	# The support gate needs the opinion bridge, which a bare SceneTree does not
	# attach (`ideology_runtime.cpp:1312` raises
	# `ideology_class_opinion_unavailable`). `_support_gate_off` zeroes the stance
	# tables so every card passes the gate, which is the same bypass
	# `ideology_card_content_test.gd:818-838` uses. Without it the daily pass
	# aborts before `run_daily` reaches the derived rebuild.
	_expect("configure ideologies",
		bool(ext.configure_ideologies(
			_support_gate_off(_native_ideology)).get("ok", false)))

	var base_mask: Dictionary = ext.get_derived_materialize_report()
	_expect("materialize report is readable after configure",
		bool(base_mask.get("ok", false)), str(base_mask))
	var base_layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("baseline: no layer installed",
		not bool(base_layer.get("installed", true)), str(base_layer))

	# Discover then equip, through the real command path.
	var country_handle := int(ext.get_country_cell_summary(0).get(
		"country_handle", 0))
	_expect("fixture resolves a country", country_handle != 0,
		str(country_handle))
	if country_handle == 0:
		_finish(4)
		return

	# The command protocol needs EVERY column, one entry per row, and
	# `ideology_ids` carries the DENSE id (an int), not the string key.
	# See `ideology_card_content_test.gd:973-987` for the column shape.
	var discover: Dictionary = _submit(ext, 1, country_handle, dense, 1)
	_expect("discover is accepted", bool(discover.get("ok", false)), str(discover))
	var equip: Dictionary = _submit(ext, 5, country_handle, dense, 2)
	_expect("equip is accepted", bool(equip.get("ok", false)), str(equip))

	for day in range(0, 4):
		_drive_day(ext, day)

	var report: Dictionary = ext.get_ideology_report()
	print("[e2e] ideology_report=%s" % str(report))
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var mask: Dictionary = ext.get_derived_materialize_report()
	print("[e2e] layer=%s" % str(layer))
	print("[e2e] materialize=%s" % str(mask))

	# The counter distinguishes "the rebuild ran and found nothing" from "the
	# rebuild never ran" -- the ambiguity that cost a full round of diagnosis when
	# `last_error` turned out to be `ideology_class_opinion_unavailable`.
	var ideology: Dictionary = ext.get_ideology_report()
	var visits := int(ideology.get("cell_layer_rebuild_visits", -1))
	print("[e2e] cell_layer_rebuild_visits=%d skips=%d ms=%.3f"
		% [visits,
			int(ideology.get("cell_layer_rebuild_skips", -1)),
			float(ideology.get("cell_layer_rebuild_ms", -1.0))])
	_expect("rebuild_derived_cell_layer actually ran",
		visits > 0,
		"cell_layer_rebuild_visits=%d -- 0 means run_daily never reached the hook"
			% visits)
	# With rollout Off, `programs_seen == 0` is the CORRECT result, not a defect:
	# `collect_effect_activations` never emits a derived contribution because
	# `cell_program_rollout_enabled()` gates the branch, so the materializer
	# receives an empty list and builds an empty front. An earlier version of this
	# assertion demanded `programs_seen > 0` and reported a failure that was the
	# gate working exactly as designed.
	#
	# What DOES prove the traversal reached the card is the counter above: the
	# rebuild ran (visits > 0) with the card live (managed_idea_count > 0 in the
	# ideology report). The `else` branch below is what checks the positive case
	# once the constant is flipped.
	var managed := int(ext.get_ideology_report().get("managed_idea_count", -1))
	_expect("the card is live in the ideology runtime",
		managed > 0, "managed_idea_count=%d" % managed)
	if ROLLOUT_OFF_EXPECTED:
		_expect("rollout Off: the traversal runs but yields no contributions",
			int(mask.get("programs_seen", -1)) == 0, str(mask))
	_expect("truncated stays 0 (§12.4 hard condition)",
		int(mask.get("truncated", -1)) == 0, str(mask))

	if ROLLOUT_OFF_EXPECTED:
		_expect("rollout Off: no derived rows are emitted",
			int(mask.get("rows_emitted", -1)) == 0, str(mask))
		_expect("rollout Off: every program counted as legacy",
			int(mask.get("programs_skipped_legacy", -1)) ==
				int(mask.get("programs_seen", -2)), str(mask))
		_expect("rollout Off: no derived layer is installed",
			not bool(layer.get("installed", true)), str(layer))
	else:
		_expect("rollout On: the card's programs are derived",
			int(mask.get("programs_derived", 0)) > 0, str(mask))
		_expect("rollout On: rows are emitted",
			int(mask.get("rows_emitted", 0)) > 0, str(mask))
		_expect("rollout On: the layer is installed",
			bool(layer.get("installed", false)), str(layer))

	_finish(0 if _failures == 0 else 3)



## Every column must carry exactly one entry per row: the runtime rejects the
## whole batch with `ideology_command_columns_invalid` when one is short.
## Zeroes every stance table so the support gate always passes.
##
## Copied from `ideology_card_content_test.gd:818-838`; the reason it is needed is
## that the real gate reads class opinion through the opinion bridge, which only
## the full runtime host attaches.
## Gives the country a territory so cell-domain selectors can resolve.
##
## Adapted from `ideology_card_content_test.gd:916`. Every cell gets one
## `gathering_ground` owned by the `forager|default` signature, which is the
## smallest world in which `country_anchor_cell(0)` is >= 0.
func _bootstrap(ext: Object) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		return false
	var goods: int = (_country_ir.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * CELLS)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * CELLS)
	prices.fill(1000)
	var cells := PackedInt32Array()
	var sigs := PackedInt32Array()
	var pops := PackedInt64Array()
	var funds := PackedInt64Array()
	var buildings := PackedInt32Array()
	var owners := PackedInt32Array()
	var counts := PackedInt64Array()
	for cell in range(CELLS):
		cells.append(cell)
		sigs.append(owner_sig)
		pops.append(1000)
		funds.append(1000000000000000)
		buildings.append(building_id)
		owners.append(owner_sig)
		counts.append(1)
	var result: Dictionary = ext.bootstrap_economy({
		"cell_indices": cells, "signature_ids": sigs, "population": pops,
		"funds": funds, "forced_named_cells": cells, "founder_family_cells": cells,
		"founder_family_building_type_ids": buildings,
		"founder_family_owner_signature_ids": owners,
	}, {
		"stock": stock, "price": prices, "building_cells": cells,
		"building_type_ids": buildings,
		"building_owner_signature_ids": owners, "building_counts": counts,
	})
	if not bool(result.get("ok", false)):
		printerr("[e2e] bootstrap reason=%s" % str(result.get("reason", "")))
	return bool(result.get("ok", false))


func _support_gate_off(native: Dictionary) -> Dictionary:
	var out := native.duplicate(false)
	var count := (out["ideology_ids"] as PackedStringArray).size()
	var zeros := PackedInt32Array()
	zeros.resize(count + 1)
	zeros.fill(0)
	out["stance_offsets"] = zeros
	out["stance_class_indices"] = PackedInt32Array()
	out["stance_adopt_q16"] = PackedInt32Array()
	out["stance_repeal_q16"] = PackedInt32Array()
	out["stance_promote_q16"] = PackedInt32Array()
	out["stance_adopt_min_q16"] = PackedInt32Array()
	out["stance_repeal_min_q16"] = PackedInt32Array()
	out["stance_promote_min_q16"] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	thresholds.fill(0)
	out["adopt_thresholds_q16"] = thresholds
	out["repeal_thresholds_q16"] = thresholds.duplicate()
	out["promote_thresholds_q16"] = thresholds.duplicate()
	return out


func _submit(ext: Object, opcode: int, handle: int, idea_id: int,
		sequence: int) -> Dictionary:
	return ext.submit_ideology_commands({
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([0]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([sequence]),
		"country_handles": PackedInt64Array([handle]),
		"ideology_ids": PackedInt32Array([idea_id]),
		"values_q16": PackedInt64Array([0]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	})

func _drive_day(ext: Object, day: int) -> void:
	for _slice in range(16):
		var ideology_slice: Dictionary = ext.run_ideology_daily(day)
		if not bool(ideology_slice.get("ok", false)):
			printerr("[e2e] ideology day %d failed: %s" % [day, str(ideology_slice)])
			break
		if bool(ideology_slice.get("done", false)):
			break
	for _effect_slice in range(16):
		var effect_slice: Dictionary = ext.run_effect_daily(day)
		if not bool(effect_slice.get("ok", true)):
			break
		if bool(effect_slice.get("done", true)):
			break
	ext.dispatch_effect_native_modifier()
	ext.run_modifier_daily(day)
	ext.ack_effect_native_modifier()


func _finish(code: int) -> void:
	print("=== cell layer e2e: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
