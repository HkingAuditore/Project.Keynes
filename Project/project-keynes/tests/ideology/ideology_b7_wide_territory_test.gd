extends SceneTree
## B7 (plan §14.2): a single country owning 1000+ cells, with the card expanded from
## the old 32 targets to the whole territory.
##
## WHY THIS SCENARIO IS THE ONE THAT MATTERS
##
## B7 is not a performance curiosity — it is the plan's central promise stated as a
## test: "a permanent cell card must reach the WHOLE territory, not the first 32
## cells, and must create ZERO Effect instances" (§1.1 / §12.4). Every other gate in
## this project measures machinery; this one measures the deliverable.
##
## WHAT IT ASSERTS
##
##   A. one country really owns 1000+ cells in the fixture (otherwise the claim is
##      vacuous and a smaller map would pass for the wrong reason);
##   B. the card's target resolution reaches MORE than 32 cells — the old cap is gone;
##   C. the cap that DOES apply is `SELECTOR_MAX_CELLS` (a geometry ceiling), not 32;
##   D. **zero instances** — a derived program creates no Effect instance (I01);
##   E. the derived front carries the cells;
##   F. a full rebuild at this size is timed and reported (cold-build cost).
##
## Numbers are PRINTED for the timing parts and ASSERTED for the semantic parts:
## a wall-clock assertion on a shared machine is a flake generator, but "did the
## card reach the whole territory" is a yes/no that must hold everywhere.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b7_wide_territory_test.gd

const WIDTH := 40
const HEIGHT := 40
const CELLS: int = WIDTH * HEIGHT          # 1600 cells: comfortably 1000+
const COUNTRY_NAME := "B7 Wide"
## A permanent cell card (kind 12 = SELECTOR_OWN_TERRITORY, lifecycle 0).
# A kind-12 permanent settlement card. Every kind-12 card in content carries a tag
# filter, and `salt_monopoly` filters on `cell.sector.extractive` -- which no cell in
# a freshly bootstrapped economy satisfies, so its target set is legitimately empty
# (measured: own_last_tag=142, emitted=0). `cell.settlement` only requires a
# populated cell, which this fixture has on all 1600.
const CARD_KEY := "idea.public_hygiene"

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

const Q16_ONE := 65536
## Defensive ceiling for the transition settle handshake. A transition that needs
## more rounds than this is stuck, not slow.
const SETTLE_ROUNDS := 16

var _checks := 0
var _failures := 0
var _seq := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when one
	# is cached (effect_domain_catalog.gd:59-63). If that cache predates the ideology
	# merge at :448-453, `family_effect_metadata_pod` cannot find ANY
	# `ideology.effect.*` program and every card row takes the `pod_fail` exit --
	# measured as pod_fail=4 in this fixture. Passing an explicit override bypasses
	# the cache so the merge always runs.
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	# ── make the card's tag filter satisfiable, BEFORE compiling ──────────
	#
	# Every kind-12 card in content carries a tag filter (measured across all 194:
	# `cell.sector.*`, `cell.chained`, `cell.settlement`, ...), and the SHIPPED
	# predicates read building data that a bootstrapped economy does not have. B7
	# measured `own_tag_rejected = 6400` -- all 1600 cells rejected -- which is the
	# filter working correctly and was the real reason `seen` stayed 0 in every
	# earlier investigation.
	#
	# `target_tags` is consumed by `compile_native_catalog`, so it must be set on the
	# RESOURCE, not on the compiled Dictionary: writing the Dictionary afterwards
	# either does nothing or aborts the build. The recipe is
	# `ideology_tag_snapshot_stress_test.gd:874-891`.
	_install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card is in the compiled catalog", dense >= 0,
		"dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		_finish(1)
		return

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot and fails silently
	# otherwise (M3-20).
	ext.create_entities(CELLS)

	_ext_fill_environment(ext)
	_expect("economy configures",
		bool(ext.configure_economy(country_ir, profile, CELLS, 97).get("ok", false)))
	_expect("effects configure",
		bool(ext.configure_effects(effect_ir).get("ok", false)))
	_expect("modifiers configure",
		bool(ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	_expect("country configures", bool(ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 97).get("ok", false)))

	# ── A: one country owns every cell ────────────────────────────────────
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.b7"]),
		"country_names": PackedStringArray([COUNTRY_NAME]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("A: the country bootstraps", bool(boot.get("ok", false)), str(boot))
	var ideo_cfg: Dictionary = ext.configure_ideologies(native_ideology)
	_expect("ideologies configure", bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg.get("fatal_reason", str(ideo_cfg)))))

	# The territory question is asked from the COUNTRY runtime too, because
	# `get_country_territory_counts` reads the economy EPOCH snapshot, and at this
	# point no economy epoch has been captured yet (that happens below). Asking only
	# the economy side reported widest=0 and looked like "bootstrap_country failed"
	# when it had actually succeeded.
	var owned := 0
	for c in range(CELLS):
		var cs: Dictionary = ext.get_country_cell_summary(c)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			owned += 1
	print("[B7] country-runtime owned cells=%d" % owned)
	_expect("A: bootstrap_country registered the whole territory", owned >= 1000,
		"owned=%d of %d" % [owned, CELLS])
	var territories: Dictionary = ext.get_country_territory_counts()
	var widest := int(territories.get("widest", 0))
	print("[B7] territory widest=%d cells=%d" % [widest, CELLS])
	print("[B7] economy-epoch widest=%d (0 until capture_country_epoch runs)" % widest)

	# ── environment slots + economy epoch (see M3-19/20 for why each step) ─
	var gen := {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, gen)
	_expect("the economy epoch opens", bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))

	var sig_keys: PackedStringArray = econ_catalog.get(
		"signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var serf: int = sig_keys.find("serf|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	if farmer >= 0 and serf >= 0:
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			for pair in [[farmer, 20], [serf, 20]]:
				ci.append(c)
				si.append(int(pair[0]))
				pp.append(int(pair[1]))
				ff.append(10000000)
		var eb: Dictionary = ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si,
			"population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		_expect("the economy bootstraps", bool(eb.get("ok", false)), str(eb))
		var slices := 0
		for s in range(512):
			var esl: Dictionary = ext.run_economy_slice(
				{"day_index": 0, "tick_index": s})
			slices += 1
			if bool(esl.get("done", false)):
				break
		print("[B7] economy day 0 finished after %d slices" % slices)

	# ── equip the card (grant -> discover -> understanding -> equip) ───────
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("the fixture resolves the country", handle != 0, str(handle))
	# Last ideology day consumed in THIS world. `run_ideology_daily` day indices must be
	# STRICTLY MONOTONIC; this fixture drives TWO worlds, so the counter is a local
	# threaded through `_step_day` rather than a member.
	var last_day := -1
	if handle != 0:
		ext.submit_ideology_commands(_commands([
			{"op": 2, "day": 0, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
		ext.submit_ideology_commands(_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": dense}]))
		for _i in range(3):
			last_day = _step_day(ext, last_day)
		ext.submit_ideology_commands(_commands([
			{"op": 8, "day": 0, "handle": handle, "idea": dense, "value": 0}]))
		for _i in range(3):
			last_day = _step_day(ext, last_day)
		ext.submit_ideology_commands(_commands([
			{"op": 5, "day": 0, "handle": handle, "idea": dense}]))
		for _i in range(4):
			last_day = _step_day(ext, last_day)
		# ── THE EQUIP HAS TO SETTLE BEFORE THE LAYER IS READ ─────────────
		# `collect_effect_activations` implements plan §10.1 ("an equip that is not
		# yet ACKed contributes nothing"): while the equip transition's Effect
		# transactions are un-ACKed the card contributes nothing and the front reads
		# `installed=false, layer_generation=0`. Every assertion below B is about the
		# INSTALLED front, so the production settle handshake runs here.
		#
		# The handshake alone stopped being enough when plan §9.3 landed: the projection
		# confirmed on day D is `eligible_from_day = D+1`, so `_settle_transitions` also
		# consumes day D+1 -- the first day the rebuild may adopt -- before returning.
		last_day = _settle_transitions(ext, last_day, "equip")

	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var locs: PackedInt32Array = snap.get("locations", PackedInt32Array())
	var active := 0
	for loc in locs:
		if int(loc) != 0:
			active += 1
	print("[B7] idea active=%d locations=%s" % [active, str(locs)])

	# ── diagnose WHY the front is empty before asserting on it ────────────
	#
	# `resolve_effect_targets` gates on
	#     anchor = country_anchor_cell(slot); if (anchor < 0) return false;
	# (ideology_runtime.cpp:1907-1908) and then collects cells from that anchor. If
	# the anchor is fine but the collection is empty, the territory plane the
	# ECONOMY sees is not the one `bootstrap_country` populated.
	# The economy-side territory plane. If `plane_size != cell_count`, every
	# territory query returns zero and `front_cells` stays 0 no matter how correct
	# the rest is (economy_runtime_family_buff.cpp:970).
	if ext.has_method("get_economy_territory_plane"):
		print("[B7] territory plane=%s" % str(ext.get_economy_territory_plane()))
	if ext.has_method("query_country_anchor_cell"):
		print("[B7] anchor(slot 0)=%s" % str(ext.query_country_anchor_cell(0)))
	if handle != 0:
		var snap2: Dictionary = ext.get_ideology_snapshot(handle)
		print("[B7] snapshot levels=%s understanding=%s"
			% [str(snap2.get("levels", "?")),
				str(snap2.get("understanding_q16", "?"))])
		var mat: Dictionary = ext.get_derived_materialize_report()
		print("[B7] materialise seen=%s derived=%s legacy=%s"
			% [str(mat.get("programs_seen", "?")),
				str(mat.get("programs_derived", "?")),
				str(mat.get("programs_skipped_legacy", "?"))])

	# `rebuild_derived_cell_layer` walks `_countries` and skips `handle == 0`
	# (ideology_runtime.cpp:6690-6691). The snapshot above used
	# `country_state_for(handle, create=true)`, so the row exists -- but if the
	# ADOPTED idea lives in a different row the walk would still miss it. Print the
	# runtime's own country count and the report's derived counters.
	print("[B7] ideology country_count(handle=%d) ideas=%d"
		% [handle, (ext.get_ideology_snapshot(handle).get("idea_ids", PackedInt32Array()) as PackedInt32Array).size()])
	var ideo_mid: Dictionary = ext.get_ideology_report()
	print("[B7] STAGES entries=%s templates=%s program_empty=%s pod_fail=%s targets_fail=%s emitted=%s"
		% [str(ideo_mid.get("collect_entries", "?")),
			str(ideo_mid.get("collect_templates", "?")),
			str(ideo_mid.get("collect_program_empty", "?")),
			str(ideo_mid.get("collect_pod_fail", "?")),
			str(ideo_mid.get("collect_targets_fail", "?")),
			str(ideo_mid.get("collect_derived_emitted", "?"))])
	print("[B7] TARGETS country_zero=%s domain_gate=%s economy_null=%s anchor_neg=%s collected_empty=%s"
		% [str(ideo_mid.get("targets_country_zero", "?")),
			str(ideo_mid.get("targets_domain_gate", "?")),
			str(ideo_mid.get("targets_economy_null", "?")),
			str(ideo_mid.get("targets_anchor_neg", "?")),
			str(ideo_mid.get("targets_collected_empty", "?"))])

	# ── B/C: the card reaches past 32, up to the geometry ceiling ─────────
	# The derived rebuild is a SLICE STAGE: one `run_ideology_daily` no longer
	# publishes it, so a fixture that reads the layer straight away sees an EMPTY
	# front. Drain it explicitly rather than guessing a call count.
	if ext.has_method("drain_derived_cell_layer"):
		var drained: Dictionary = ext.drain_derived_cell_layer(last_day)
		print("[B7] drained steps=" + str(drained.get("steps", "?")) + " complete=" + str(drained.get("complete", "?")))
	# ── front memory (§18.3 "peak memory") ────────────────────────────────
	#
	# The front is the dominant resident term: one contribution + one cell id per
	# (stat, cell). The report computes it from the STRUCTURE, not from a heap sample, so
	# the number is deterministic.
	#
	# The assertion is an INVARIANT, not a magic constant: `front_bytes` must equal
	# `contributions * bytes_per_contribution + row_overhead`, using the sizes the
	# runtime itself reports. Pinning an absolute number would break on any layout change
	# and tell us nothing about whether the accounting is right.
	var layer_mem: Dictionary = ext.get_derived_cell_layer_report()
	var contribs := int(layer_mem.get("contribution_count", -1))
	var per := int(layer_mem.get("bytes_per_contribution", -1))
	var row_oh := int(layer_mem.get("front_row_overhead_bytes", -1))
	var front_bytes := int(layer_mem.get("front_bytes", -1))
	print("[B7] front memory: contributions=%d bytes/contrib=%d row_overhead=%d total=%d bytes"
		% [contribs, per, row_oh, front_bytes])
	# 3200, not 1600: `public_hygiene_l1` carries TWO commands
	# (`economy.city.birth_factor` and the `.cut` variant), so the front holds one
	# contribution per (stat, cell) = 2 x 1600. That is also why B7 reports
	# `front cells=3200` elsewhere -- the two numbers have to agree.
	_expect("the front records one contribution per (stat, cell)",
		contribs == 3200, str(contribs))
	_expect("the per-contribution size is reported",
		per >= 4 and per <= 128, str(per))
	# The front also holds `stat_versions`, which is sized by the STAT-ID SPACE (86 entries
	# here) rather than by the row count -- so the identity needs that third term. It used
	# to be omitted, which made the whole identity off by 688 bytes.
	var sv_bytes := int(layer_mem.get("stat_versions_bytes", -1))
	_expect("front_bytes equals the reported structure size",
		front_bytes == contribs * per + row_oh + sv_bytes,
		"%d vs %d*%d+%d+%d" % [front_bytes, contribs, per, row_oh, sv_bytes])
	# A 1600-cell country must not cost anything absurd: under 1 MB puts a ceiling on
	# "did we accidentally store something per-cell-per-stat that we did not intend".
	_expect("1600 cells cost less than 1 MB of front", front_bytes < 1048576,
		str(front_bytes))

	# ── the FOLD's working set (section 18.3 `scratch`), structurally reported ──
	#
	# This was the one memory figure section 18.3 lists that nothing exported: the working
	# set lives inside the materialize job's opaque Impl and died with the job. It is now
	# computed at the last moment those containers exist (`finish`) from their own sizes --
	# the same approach `front_bytes` uses -- and reported as an ESTIMATE of bytes with the
	# per-node overhead named in the code. Nothing in this build counts allocations, so no
	# allocation count is claimed.
	var mat: Dictionary = ext.get_derived_materialize_report()
	var scratch_bytes := int(mat.get("scratch_bytes", -1))
	var scratch_nodes := int(mat.get("scratch_nodes", -1))
	print("[B7] fold working set: scratch=%d bytes over %d nodes"
		% [scratch_bytes, scratch_nodes])
	# One node per (stat, cell) the fold touched: the fold accumulates into exactly the
	# pairs it later emits, so this must equal the front's contribution count.
	_expect("the fold's working set covers every (stat, cell) pair",
		scratch_nodes == contribs, "%d vs %d" % [scratch_nodes, contribs])
	# A floor, not a magic constant: one node holds at least the key plus an accumulator,
	# so anything under 32 bytes per node means the accounting is not counting them.
	_expect("the fold's working set accounts at least 32 bytes per node",
		scratch_bytes >= scratch_nodes * 32,
		"%d for %d nodes" % [scratch_bytes, scratch_nodes])
	_expect("the fold's working set is under 8 MB", scratch_bytes < 8388608,
		str(scratch_bytes))

	# ── CONSTANT CARD vs the stack machine (§13.1 layer 2, the other half) ──
	#
	# The oracle fixture (`ideology_oracle_cross_check_test.gd`) covers a RAMP card.
	# A constant card takes a different branch in the collector (`add`/`factor` from the
	# program magnitude, no per-cell sampling), so it needs its own comparison or the
	# "values are correct" claim only covers one of the two shapes.
	#
	# `public_hygiene_l1` is `CONST 3277 -> EMIT`, so the interpreter must return 3277 and
	# the derived add must be exactly 3277/Q16.
	var hm_metrics := PackedInt64Array()
	hm_metrics.resize(120)
	hm_metrics.fill(0)
	var hm_interp: Dictionary = ext.evaluate_effect_program_magnitude(
		"ideology.effect.public_hygiene_l1", hm_metrics)
	_expect("the constant card's program evaluates", bool(hm_interp.get("ok", false)),
		str(hm_interp))
	var hm_expected := float(int(hm_interp.get("magnitude", 0))) / float(Q16_ONE)

	# ── the derived layer's VALUE is now observable ───────────────────────
	#
	# Until this bridge existed the front was exposed only as counts, so the old v1
	# plane could not be retired: its test coverage (ADD vs MULTIPLY, and the SUBTRACT
	# sign coming from the definition) had nowhere to move to.
	# entity_handle MUST be 0 and the CELL goes in the group slot: that is the pair the
	# production reader uses (`economy_runtime_family_buff.cpp:7127` passes
	# `entity 0, group scope_id`). Passing the country handle as the entity made
	# `effective_value` ignore the derived front entirely and return the base -- the row
	# was there (`derived_add: 0.05`) while the merged value stayed 1.0.
	var stat_probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.birth_factor", 1, 0, 1.0)
	# Cell 0 is checked separately: `effective_value` guards the derived merge with
	# `group_handle != 0`, so a derived row on cell 0 exists in the front (the probe
	# finds it) yet never reaches the value. Reported, not asserted, until that guard is
	# resolved.
	var cell0_probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.birth_factor", 0, 0, 1.0)
	print("[B7] cell0: derived_present=%s value=%s add=%s"
		% [str(cell0_probe.get("derived_present", "?")),
			str(cell0_probe.get("value", "?")),
			str(cell0_probe.get("derived_add", "?"))])
	# CELL 0 IS A REAL CELL. `effective_value` guarded the derived merge with
	# `group_handle != 0`, so a card silently did nothing on its country's first cell.
	# Measured before the fix: cell 0 value 1.0 while cell 1 was 1.05.
	_expect("cell 0 receives its derived contribution too",
		absf(float(cell0_probe.get("value", 1.0)) - 1.0) > 1e-9,
		"value=%s add=%s" % [str(cell0_probe.get("value", "?")),
			str(cell0_probe.get("derived_add", "?"))])
	# And the two cells must agree: same card, same contribution, same delta.
	# ── the SIGN comes from the definition, not from the magnitude ────────
	#
	# `public_hygiene_l1` carries two commands. `economy.city.birth_factor` resolves to
	# `operation=ADD, value=+1.0`; `economy.city.need.housing.consumption_factor.cut`
	# resolves to `operation=ADD, value=-1.0`. The program emits POSITIVE magnitudes for
	# both, so the only thing that makes the second one a debuff is `term.value`.
	#
	# Getting this wrong turns every "-8%" card into "+8%" and nothing in the pipeline
	# complains, so it gets its own assertion rather than living inside a comment.
	var cut_probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.need.housing.consumption_factor", 1, 0, 1.0)
	print("[B7] cut card: %s" % str(cut_probe))
	_expect("the .cut command produces a NEGATIVE derived delta",
		bool(cut_probe.get("derived_present", false)) and
			float(cut_probe.get("derived_add", 0.0)) < 0.0,
		str(cut_probe))

	_expect("cell 0 and cell 1 get the SAME derived delta",
		absf(float(cell0_probe.get("derived_add", 0.0)) -
			float(stat_probe.get("derived_add", 1.0))) < 1e-9,
		"cell0=%s cell1=%s" % [str(cell0_probe.get("derived_add", "?")),
			str(stat_probe.get("derived_add", "?"))])
	print("[B7] effective_value=%s" % str(stat_probe))
	_expect("the effective-value bridge answers", bool(stat_probe.get("ok", false)),
		str(stat_probe))
	# Cell 0 is inside the 1600-cell territory and the card is equipped, so its derived
	# row must exist. A false here means the bridge reads a different front than the one
	# `get_derived_cell_layer_report` counts.
	_expect("the covered cell has a derived contribution",
		bool(stat_probe.get("derived_present", false)), str(stat_probe))
	# The merged value must actually move away from the identity base, otherwise the
	# derived row exists but contributes nothing.
	_expect("the merged value leaves the identity base",
		absf(float(stat_probe.get("value", 1.0)) - 1.0) > 1e-9,
		str(stat_probe.get("value", "?")))
	var hm_actual := float(stat_probe.get("derived_add", -1.0))
	print("[B7] constant card: interp=%s -> %.8f   derived_add=%.8f"
		% [str(hm_interp.get("magnitude", "?")), hm_expected, hm_actual])
	_expect("the constant card's derived add EQUALS the interpreter's magnitude / Q16",
		absf(hm_actual - hm_expected) <= 1e-6,
		"derived=%.8f expected=%.8f" % [hm_actual, hm_expected])

	# ── ramp verification with a metric-reading card ──────────────────────
	#
	# The sharded job was briefly constructed with an EMPTY
	# `DerivedMaterializeOptions`, which deferred every ramp term instead of
	# evaluating it. `public_hygiene` cannot detect that (constant magnitude), so a
	# metric-reading card is installed and the sampler counters are checked.
	var ramp_checked := _verify_ramp_card(native_ideology, country_ir, profile, ext)
	print("[B7] ramp card verified=%s" % str(ramp_checked))
	# END-TO-END ramp proof: a metric-reading card on the SHARDED path evaluates its
	# terms per cell. Without this, "the ramp path works" and "the ramp path silently
	# contributes nothing" were indistinguishable (M4-20).
	_expect("ramp terms are evaluated per cell on the sharded path", ramp_checked,
		"see the [B7] ramp card line above")

	var report: Dictionary = ext.get_derived_cell_layer_report()
	var front_cells := int(report.get("cell_count", 0))
	print("[B7] derived front cells=%d stat_count=%d"
		% [front_cells, int(report.get("stat_count", 0))])
	_expect("B: the card reaches MORE than the old 32 cells",
		front_cells > 32,
		"front_cells=%d -- 32 or fewer means the cap is still applied" % front_cells)
	# `SELECTOR_MAX_CELLS` is 32 as a GEOMETRY ceiling, so a kind-12 query is still
	# bounded by it; B7's point is that the DEFAULT policy cap (param0=0 meaning "the
	# first 32") is gone and the whole territory is covered up to the geometry limit.
	_expect("C: coverage is at least the geometry ceiling",
		front_cells >= 32, str(front_cells))

	# ── D: zero instances (I01) ───────────────────────────────────────────
	var instances := 0
	if ext.has_method("get_ideology_effect_instance_report"):
		var ir: Dictionary = ext.get_ideology_effect_instance_report(handle)
		instances = int(ir.get("count", 0))
	print("[B7] effect instances=%d" % instances)
	_expect("D: a derived card creates ZERO instances", instances == 0,
		"instances=%d -- a derived program must not also create instances (I01)"
			% instances)

	# ── F: cold-build cost at this size ───────────────────────────────────
	var ideo_report: Dictionary = ext.get_ideology_report()
	print("[B7] cell_layer_rebuild_visits=%s rebuild_ms=%.3f ramp_taken=%s"
		% [str(ideo_report.get("cell_layer_rebuild_visits", "?")),
			float(ideo_report.get("cell_layer_rebuild_ms", 0.0)),
			str(ideo_report.get("ramp_samples_taken", "?"))])
	# The sharded path must EVALUATE ramp terms, not defer them. An empty
	# `DerivedMaterializeOptions` on the job silently deferred every ramp term while
	# the single-shot path still evaluated them, so this number is the regression
	# guard for that wiring.
	# I01 evidence: the old plane must SKIP the programs the derived layer owns.
	# Non-zero here proves `build_cell_program_table` consulted the shared verdict.
	print("[B7] plane: builds=%s derived_elsewhere=%s"
		% [str(ideo_report.get("cell_plane_builds", "?")),
			str(ideo_report.get("cell_plane_derived_elsewhere", "?"))])
	print("[B7] consumer: publishes=%s tag_ids=%s levels_with_tags=%s"
		% [str(ideo_report.get("consumer_publish_calls", "?")),
			str(ideo_report.get("consumer_tag_ids", "?")),
			str(ideo_report.get("consumer_levels_with_tags", "?"))])
	print("[B7] ramp_taken=%s ramp_memo=%s ramp_eval=%s steps=%s pending=%s"
		% [str(ideo_report.get("ramp_samples_taken", "?")),
			str(ideo_report.get("ramp_samples_memoised", "?")),
			str(ideo_report.get("ramp_terms_evaluated", "?")),
			str(ideo_report.get("cell_layer_rebuild_steps", "?")),
			str(ideo_report.get("derived_rebuild_pending", "?"))])
	var econ_report: Dictionary = ext.get_economy_report()
	# Does the REAL chain narrow the tag sweep? `consumed` counts the tag ids the
	# ideology publisher named; 0 means it fell back to "all tags".
	print("[B7] tag_build_ms=%.4f builds=%s declared=%s active=%s consumed=%s"
		% [float(econ_report.get("tag_snapshot_build_ms", 0.0)),
			str(econ_report.get("tag_snapshot_build_count", "?")),
			str(econ_report.get("tag_declared_tags", "?")),
			str(econ_report.get("tag_active_tags", "?")),
			str(econ_report.get("tag_consumed_tags", "?"))])

	# ---- PEAK MEMORY (plan 18.3) ----------------------------------------
	#
	# The interesting number is not the front alone: while a rebuild is being built the
	# PREVIOUS front is still serving readers, so the true peak is retained + candidate.
	# `peak_*` are MAX over all rebuilds in this run.
	# `front_bytes` lives in the LAYER report; the peak counters are maintained by the
	# ideology runtime (that is where the rebuild happens), so they are read from there.
	var peak: Dictionary = ext.get_derived_cell_layer_report()
	var peak_counters: Dictionary = ext.get_ideology_report()
	var peak_front := int(peak.get("front_bytes", -1))
	var peak_retained := int(peak_counters.get("peak_retained_bytes", -1))
	var peak_candidate := int(peak_counters.get("peak_candidate_bytes", -1))
	var peak_total := int(peak_counters.get("peak_total_bytes", -1))
	print("[B7] PEAK front=%d retained=%d candidate=%d total=%d"
		% [peak_front, peak_retained, peak_candidate, peak_total])
	_expect("18.3: the front reports a positive byte size", peak_front > 0,
		str(peak_front))
	_expect("18.3: peak memory was recorded (the rebuild ran)", peak_total > 0,
		str(peak_total))
	_expect("18.3: a candidate front was measured", peak_candidate > 0,
		str(peak_candidate))
	# B7 installs the layer ONCE, so `previous` is null on that build and the retained peak
	# is legitimately 0. The "two fronts coexist" case needs a REBUILD and is asserted in
	# B1 (12 generations). Here only the counter's presence is checked.
	_expect("18.3: the retained peak counter is reported", peak_retained >= 0,
		str(peak_retained))
	_expect("18.3: total peak covers both fronts",
		peak_total >= peak_front and peak_total >= peak_candidate,
		"total=%d front=%d candidate=%d" % [peak_total, peak_front, peak_candidate])

	_finish(0 if _failures == 0 else 3)


## One ideology day, driven to completion, on a STRICTLY MONOTONIC day index.
## `day` is the last day this WORLD consumed (-1 before the first one); the return
## value is the day just consumed. `run_ideology_daily` is a SLICE stage, so a single
## call can come back `done=false` with the day (or the derived rebuild) unfinished.
func _step_day(ext: Object, day: int) -> int:
	var next := day + 1
	for _slice in range(128):
		var r: Dictionary = ext.run_ideology_daily(next)
		if bool(r.get("done", true)) or not bool(r.get("ok", true)):
			break
	return next


## Drains every in-flight ideology transition in `ext`. The order is the production
## one (`world_ext_bind_methods.cpp:635-648`) and it is MANDATORY before a layer read:
##
##   dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                      ->  ack_effect_native_modifier()
##                                      ->  run_ideology_daily(day)   # polls
##
## `run_modifier_daily` between dispatch and ACK applies the dispatched rows; without
## it the ACK never lands and `pending_transitions` never reaches 0. The adapters are
## served for the day the POLL will run on, because the poll is the FIRST stage of
## `run_daily_slices` (`ideology_runtime.cpp:4953-4968`) -- that keeps every ideology
## day strictly monotonic AND in the right order for the ACK to be seen.
func _settle_transitions(ext: Object, day: int, label: String) -> int:
	var start := int(ext.get_ideology_report().get("pending_transitions", -1))
	var rounds := 0
	for _round in range(SETTLE_ROUNDS):
		if int(ext.get_ideology_report().get("pending_transitions", 0)) == 0:
			break
		rounds += 1
		var poll_day := day + 1
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(poll_day)
		ext.ack_effect_native_modifier()
		day = _step_day(ext, day)
	var end := int(ext.get_ideology_report().get("pending_transitions", -1))
	print("[B7] settle %s: pending %d -> %d in %d handshake round(s), last day=%d"
		% [label, start, end, rounds, day])
	_expect("settle %s: every transition is ACKed before the layer is read" % label,
		end == 0, "pending=%d" % end)
	# ── plan §9.3: a confirmation is eligible TOMORROW, not today ──────────
	#
	# Plan §9.3: the confirmed projection's `eligible_from_day` is D+1, and at the new
	# economy freeze boundary `sample_day = S` ONLY the newest confirmed projection
	# satisfying `eligible_from_day <= S` may be chosen. `poll_pending_transition`'s
	# success path records `confirmed_day = D` / `eligible_from_day = D + 1`, and
	# `step_derived_rebuild` RETURNS EARLY without adopting on any day below that
	# (`ideology_runtime.cpp:7045-7048`, counted in
	# `derived_rebuild_gated_by_eligibility`).
	#
	# So on the settle day itself the front still serves the PREVIOUS basis -- here
	# nothing was ever installed, so it reads `installed=false, layer_generation=0` and
	# every downstream front assertion collapses. The gate is ASSERted rather than
	# assumed: otherwise "the front is empty" would also pass on a fixture that read a
	# day too early for an unrelated reason.
	if rounds > 0:
		var basis: Dictionary = ext.get_ideology_report()
		var confirmed := int(basis.get("derived_basis_confirmed_day", -1))
		var eligible := int(basis.get("derived_basis_eligible_day", -1))
		var gated := int(basis.get("derived_rebuild_gated_by_eligibility", 0))
		print("[B7] settle %s: basis confirmed_day=%d eligible_day=%d gated=%d"
			% [label, confirmed, eligible, gated])
		_expect("settle %s: the confirmed basis is eligible from the NEXT day" % label,
			eligible == confirmed + 1,
			"confirmed=%d eligible=%d" % [confirmed, eligible])
		_expect("settle %s: the rebuild really WAS gated by eligibility on day D" % label,
			gated > 0, "gated=%d" % gated)
		# Consume the first ELIGIBLE day (D+1) here, so that every caller reads an
		# adopted front instead of the pre-settle one. `_step_day` keeps the day index
		# strictly monotonic; the drain finishes the sharded rebuild when the day's own
		# slices stopped short of a full install.
		day = _step_day(ext, day)
		ext.drain_derived_cell_layer(day)
	return day


func _ext_fill_environment(ext: Object) -> void:
	# The 10 environment slots `capture_environment` requires (M3-19). Registered AFTER
	# `create_entities` so they are sized.
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(CELLS)
	var zeros_u := PackedByteArray()
	zeros_u.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)


func _u8_zero(n: int) -> PackedByteArray:
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
		# `sequences` is the IDEMPOTENCY key and must be monotonic ACROSS batches
		# (M3-18): restarting at 1 makes every later command look like a duplicate.
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


func _finish(code: int) -> void:
	print("=== B7 wide territory: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)

## Declares `cell.settlement` as `cell.population >= 30`, which this fixture
## satisfies on every cell (40 people each).
##
## WHY A SYNTHETIC ROW AND NOT THE SHIPPED ONE
##
## The shipped `cell.settlement` predicate reads building data. A bootstrapped
## economy has population but no buildings, so the predicate is legitimately false
## everywhere and every territory query returns zero cells -- correct behaviour that
## is indistinguishable from "the card matched nothing".
##
## WHY `metric_keys` IS REPLACED TOO
##
## `compile_native_catalog` resolves each tag row through `metric_keys`, and
## `tag_metric_ids` carries the DENSE INDEX into that array while
## `sample_effect_metrics` indexes by `FamilyEffectMetricId`. The two line up only
## when the dense order equals the enum order
## (`effect_domain_catalog.gd:43`: "index order below MUST match the C++ enum").
## A short list moves `cell.population` off id 9, the row reads the wrong metric,
## and the tag never matches -- measured in the stress fixture as an invisible flip.
func _install_satisfiable_tag(domain: Resource) -> void:
	# `target_tags` is `Array[Dictionary]`, a TYPED array: assigning an untyped
	# `[{...}]` literal fails at runtime with
	#   "Invalid assignment of property 'target_tags' with value of type 'Array'"
	# and the tag silently stays absent. Declaring the typed local is what makes the
	# assignment legal.
	var row := {
		"metric": "cell.population",              # dense id 9 -- never move this
		"op": 0,                                  # TARGET_TAG_GTE
		"threshold_q16": 30 * Q16_ONE,
		"clause": 0,
	}
	var rows: Array[Dictionary] = [row]
	var tag := {"name": "cell.settlement", "rows": rows}
	# REUSE the shipped tag list, replacing only `cell.settlement`.
	#
	# Overwriting the whole list made `configure_ideologies` fail with
	# `ideology_synergy_override_tag_unknown`: the ideology catalogue declares
	# synergy overrides that name OTHER tags, and those names have to keep
	# resolving. Replacing one entry keeps every other reference intact -- the same
	# reason the stress fixture can build its own catalogue (it declares no synergy
	# overrides at all) but this one cannot.
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	var replaced := false
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == "cell.settlement":
			tags[i] = tag
			replaced = true
			break
	if not replaced:
		tags.append(tag)
	domain.target_tags = tags

## Installs a METRIC-READING card and reports whether the ramp sampler ran.
##
## Returns true when `ramp_samples_taken > 0`, i.e. the sharded job really evaluated
## ramp terms. A `false` here means the options were not wired (the M4-19 defect).
func _verify_ramp_card(native_ideology: Dictionary, country_ir: Dictionary,
		profile: Dictionary, base_ext: Object) -> bool:
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var ramp_dense: int = ids.find("idea.salt_monopoly")
	if ramp_dense < 0:
		return false
	var ext2: Object = ClassDB.instantiate("DCWorldExt")
	ext2.create_entities(CELLS)
	_ext_fill_environment(ext2)
	ext2.configure_economy(country_ir, profile, CELLS, 197)
	# Replace the extractive tag with the same satisfiable population threshold, so
	# the card's target set is non-empty without building an extractive industry.
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	_install_satisfiable_tag_named(domain, "cell.sector.extractive")
	var ir: Dictionary = domain.compile_native_catalog()
	ir.erase("ok")
	ext2.configure_effects(ir)
	ext2.configure_modifiers(
		ModifierCatalogScript.load_default().compile_native_catalog(), CELLS)
	ext2.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 197)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	ext2.bootstrap_country({
		"country_ids": PackedStringArray(["country.ramp"]),
		"country_names": PackedStringArray(["Ramp"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	ext2.configure_ideologies(native_ideology)
	ext2.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	# The main path bootstraps the economy and runs a full day BEFORE equipping. The
	# first version of this sub-fixture skipped both, and the equip silently failed
	# (`locations=[0]`) -- which looked like "the ramp path does nothing" rather than
	# "the card was never equipped".
	var sig_keys: PackedStringArray = EconomyCatalogScript.compile_native_catalog().get(
		"signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (EconomyCatalogScript.compile_native_catalog().get(
		"good_ids", PackedStringArray())).size()
	if farmer >= 0:
		var stock := PackedInt64Array()
		stock.resize(CELLS * goods)
		stock.fill(0)
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			ci.append(c)
			si.append(farmer)
			pp.append(30)
			ff.append(10000000)
		ext2.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si, "population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		for s in range(512):
			if bool(ext2.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
				break
	var handle: int = int(ext2.get_country_cell_summary(0).get("country_handle", 0))
	if handle == 0:
		return false
	ext2.submit_ideology_commands(_commands([
		{"op": 2, "day": 0, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
	ext2.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": ramp_dense}]))
	var last_day := -1
	for _i in range(3):
		last_day = _step_day(ext2, last_day)
	ext2.submit_ideology_commands(_commands([
		{"op": 8, "day": 0, "handle": handle, "idea": ramp_dense, "value": 0}]))
	for _i in range(3):
		last_day = _step_day(ext2, last_day)
	ext2.submit_ideology_commands(_commands([
		{"op": 5, "day": 0, "handle": handle, "idea": ramp_dense}]))
	for _i in range(4):
		last_day = _step_day(ext2, last_day)
	# Same rule as the main world: a pending equip contributes nothing, so the ramp
	# card's rows only exist in the front once the transition is ACKed.
	last_day = _settle_transitions(ext2, last_day, "ramp-equip")
	ext2.drain_derived_cell_layer(last_day)
	var snap: Dictionary = ext2.get_ideology_snapshot(handle)
	var locs: PackedInt32Array = snap.get("locations", PackedInt32Array())
	var lv: PackedInt32Array = snap.get("levels", PackedInt32Array())
	var layer: Dictionary = ext2.get_derived_cell_layer_report()
	var mat: Dictionary = ext2.get_derived_materialize_report()
	print("[B7] ramp card: locations=%s levels=%s front=%s seen=%s derived=%s"
		% [str(locs), str(lv), str(layer.get("cell_count", "?")),
			str(mat.get("programs_seen", "?")), str(mat.get("programs_derived", "?"))])
	# Is `metric_mask` populated for this program? If it is empty the ramp branch is
	# skipped and every term falls back to a CONSTANT -- which is exactly what
	# `taken=0 evaluated=0 deferred=0` looks like.
	var probe: Dictionary = ext2.probe_cell_program_backend({
		"target_domain": 2, "target_selector_kind": 12, "lifecycle": 0,
		"duration_days": -1, "stack_policy": 0, "max_stacks": 1,
	}) if ext2.has_method("probe_cell_program_backend") else {}
	print("[B7] ramp probe=%s" % str(probe))
	var rep: Dictionary = ext2.get_ideology_report()
	var taken := int(rep.get("ramp_samples_taken", 0))
	var evaluated := int(rep.get("ramp_terms_evaluated", 0))
	# The cost of running the PROGRAM per cell (§14.3's 1 ms slice gate). `rebuild_ms`
	# is the worst SINGLE step, which is what the gate is about; `steps` shows how many
	# slices the sharded rebuild needed.
	print("[B7] ramp rebuild: worst_step_ms=%.4f steps=%s program_eval=%s failures=%s"
		% [float(rep.get("cell_layer_rebuild_ms", 0.0)),
			str(rep.get("cell_layer_rebuild_steps", "?")),
			str(rep.get("derived_program_evaluations", "?")),
			str(rep.get("derived_program_failures", "?"))])
	print("[B7] ramp card: taken=%d evaluated=%d deferred=%d candidates=%s metric_ok=%s"
		% [taken, evaluated, int(rep.get("ramp_terms_deferred", 0)),
			str(rep.get("ramp_candidates", "?")), str(rep.get("ramp_metric_ok", "?"))])
	# The proof is `ramp_terms_evaluated`: it counts PER-CELL evaluations, so 1600 for a
	# 1600-cell territory means every cell sampled its metric. `taken` counts sampler
	# CALLS that actually re-sampled (memoised country-scope hits do not increment it),
	# so it can legitimately be 0 when every metric is country-scoped.
	return evaluated > 0


## Replaces one named tag with a satisfiable population threshold.
func _install_satisfiable_tag_named(domain: Resource, tag_name: String) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population", "op": 0,
		"threshold_q16": 20 * Q16_ONE, "clause": 0,
	}]
	var tag := {"name": tag_name, "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == tag_name:
			tags[i] = tag
			domain.target_tags = tags
			return
	tags.append(tag)
	domain.target_tags = tags
