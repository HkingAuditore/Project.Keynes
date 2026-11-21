extends SceneTree

## Satisfaction-source channel coverage.
##
## Narrative events, political regimes and family effects all reach cohort
## satisfaction through the SAME Modifier definition family added by this change
## (`narrative.*`, `regime.*`, `family.country.*`). The kernel already reads one
## frozen `(country, profession)` table per epoch, so the channel costs nothing
## in the settlement hot loop; what this test pins down is that the definitions
## actually resolve, and that a resolved definition moves the frozen bias and
## the cohort composite.
##

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const NarrativeEffectSpecScript = preload(
	"res://scripts/narrative/narrative_effect_spec.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const RegimeEffectBindingScript = preload(
	"res://scripts/country/regime_effect_binding.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const FamilyEffectDefinitionScript = preload(
	"res://scripts/family/family_effect_definition.gd")
const FamilyEffectCatalogScript = preload(
	"res://scripts/family/family_effect_catalog.gd")

const Q16_ONE := 65536
const RELIEF := "narrative.relief.agrarian_satisfaction"
const LEVY := "narrative.levy.labor_satisfaction"
const REGIME_EARLY := "regime.early_clan.cohesion"
const FAMILY_PATRONAGE := "family.country.patronage_satisfaction"
const ALL_KEYS := [RELIEF, LEVY, REGIME_EARLY,
	"regime.local_council.cohesion", FAMILY_PATRONAGE]

## Shipped regime balance, in bp (100 bp = 1.0 satisfaction point out of 100).
## A regime is the only free, nationwide, permanent satisfaction source, so its
## core estate must sit in the ±450~750 bp band — the old ±100~200 bp sat below a
## single timelimited narrative event and read as rounding noise in the charter
## card. Changing a number here is a deliberate content decision: edit the
## catalog and this table together. Ladder:
## docs/cpp-dots-runtime/satisfaction-runtime.md.
const REGIME_BALANCE_BP := {
	"regime.early_clan.cohesion": {
		"tenant_farmer": 600,
		"serf": 600,
		"household_farmer": 450,
		"subsistence_farmer": 450,
		"landlord": 300,
		"merchant": -600,
		"unemployed": 450,
	},
	"regime.local_council.cohesion": {
		"merchant": 750,
		"industrialist": 600,
		"artisan": 450,
		"journeyman": 450,
		"worker": 300,
		"landlord": -600,
	},
}
const SATISFACTION_STAT_PATTERN := \
	"^economy\\.profession\\.([a-z0-9_]+)\\.satisfaction_bp$"

## Shipped structural terms, one MULTIPLY factor per stat. A regime's other half
## is not mood: it moves national output / trade / construction cost, and those
## multiply through the whole epoch, so the exact factors are pinned here for the
## same reason as the bp table.
const REGIME_CHARTER := {
	"regime.early_clan.charter": {
		"country.construction.cost_factor": 0.94,
		"country.output.agriculture_factor": 1.04,
		"country.research.society_efficiency": 0.95,
	},
	"regime.local_council.charter": {
		"country.trade.capacity_factor": 1.08,
		"country.output.manufacturing_factor": 1.04,
		"country.construction.cost_factor": 1.06,
	},
}

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== satisfaction sources %s: checks=%d failures=%d ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(economy.get("ok", false)))
	if not bool(economy.get("ok", false)):
		return
	var catalog_resource: Resource = load(
		"res://data/modifiers/default_modifier_catalog.tres")
	if catalog_resource == null:
		_expect("modifier catalog loads", false)
		return
	var modifiers: Dictionary = catalog_resource.compile_native_catalog()
	_expect("modifier catalog compiles", bool(modifiers.get("ok", false)))
	if not bool(modifiers.get("ok", false)):
		return
	_test_definitions(modifiers)
	_test_regime_declarations(modifiers)
	_test_regime_balance(modifiers)
	_test_regime_charter(modifiers)
	_test_family_effect_binding(economy, modifiers)
	if ClassDB.class_exists("DCWorldExt"):
		_test_frozen_channel(economy, modifiers)
	else:
		print("[SKIP] DCWorldExt unavailable; the frozen-table half is not exercised")


## Every source definition must exist and hold only ADD terms on the existing
## per-profession satisfaction stat. A MULTIPLY term would scale a 0 baseline and
## silently do nothing.
func _test_definitions(modifiers: Dictionary) -> void:
	var definition_keys: PackedStringArray = modifiers.get(
		"definition_keys", PackedStringArray())
	var offsets: PackedInt32Array = modifiers.get(
		"definition_term_offsets", PackedInt32Array())
	var stat_ids: PackedInt32Array = modifiers.get("term_stat_ids", PackedInt32Array())
	var operations: PackedInt32Array = modifiers.get(
		"term_operations", PackedInt32Array())
	var stat_keys: PackedStringArray = modifiers.get("stat_keys", PackedStringArray())
	for key in ALL_KEYS:
		var index := definition_keys.find(String(key))
		_expect("definition %s is compiled" % key, index >= 0)
		if index < 0:
			continue
		var terms := 0
		var all_add := true
		var all_satisfaction := true
		for term in range(offsets[index], offsets[index + 1]):
			terms += 1
			if int(operations[term]) != 0:
				all_add = false
			var stat_id := int(stat_ids[term])
			if stat_id < 0 or stat_id >= stat_keys.size():
				all_satisfaction = false
				continue
			if not String(stat_keys[stat_id]).ends_with(".satisfaction_bp"):
				all_satisfaction = false
		_expect("%s has at least one term (%d)" % [key, terms], terms > 0)
		_expect("%s uses ADD terms only" % key, all_add)
		_expect("%s targets profession satisfaction stats" % key, all_satisfaction)


## A regime declares which Modifier definitions it keeps applied. The catalog
## must reject a key the Modifier catalog does not carry, otherwise a typo would
## silently leave the regime with no effect at all.
func _test_regime_declarations(modifiers: Dictionary) -> void:
	var regime_catalog: Resource = load(
		"res://data/country/default_political_regime_catalog.tres")
	if not _expect("political regime catalog loads", regime_catalog != null):
		return
	var compiled: Dictionary = regime_catalog.compile_native_catalog({}, modifiers)
	_expect("regime catalog compiles against the modifier catalog",
		bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print("regime compile result=", compiled)
		return
	var definition_keys: PackedStringArray = modifiers.get(
		"definition_keys", PackedStringArray())
	var declared := 0
	for key in [REGIME_EARLY, "regime.local_council.cohesion"]:
		_expect("regime definition %s exists in the modifier catalog" % key,
			definition_keys.has(key))
	for raw in regime_catalog.get("definitions"):
		var definition: Resource = raw
		var keys := PackedStringArray(definition.get("modifier_definition_keys"))
		_expect("regime %s declares at least one modifier definition" % String(
			definition.get("id")), not keys.is_empty())
		declared += keys.size()
	_expect("the shipped regimes declare cohesion + charter definitions (%d)" % declared,
		declared == 4)
	# The binding reads the *view*, so pin the view shape it depends on.
	var view: Dictionary = regime_catalog.catalog_view()
	_expect("catalog view exposes the declared definition keys",
		RegimeEffectBindingScript.definition_keys_for(view, "early_clan") ==
			PackedStringArray(["regime.early_clan.cohesion",
				"regime.early_clan.charter"]))
	_expect("an unknown regime exposes no definition keys",
		RegimeEffectBindingScript.definition_keys_for(view, "no_such_regime").is_empty())
	_expect("a dense regime id resolves to its stable key",
		RegimeEffectBindingScript.regime_key_from_snapshot(
			{"regime_id": 0}, view) == "early_clan")
	_expect("an explicit regime key wins over the dense id",
		RegimeEffectBindingScript.regime_key_from_snapshot(
			{"regime_key": "local_council", "regime_id": 0}, view) == "local_council")
	_expect("an empty snapshot yields no regime key",
		RegimeEffectBindingScript.regime_key_from_snapshot({}, view).is_empty())
	# A mutated duplicate must fail the compile, not pass silently.
	var broken: Resource = regime_catalog.duplicate(true) as Resource
	var broken_definitions: Array = broken.get("definitions")
	if not broken_definitions.is_empty():
		var first: Resource = (broken_definitions[0] as Resource).duplicate(true)
		first.set("modifier_definition_keys",
			PackedStringArray(["regime.does_not_exist"]))
		broken_definitions[0] = first
		broken.set("definitions", broken_definitions)
		var rejected: Dictionary = broken.compile_native_catalog({}, modifiers)
		_expect("an unknown regime definition key is rejected",
			not bool(rejected.get("ok", true)) and String(
				rejected.get("reason", "")).begins_with(
					"political_regime_modifier_definition_unknown"))


## The charter card only reports what these terms say, so a silently shrunken
## regime (a term dropped, a value left at the old ±1~2 points) would still read
## as "the regime works". Pin the whole shipped table per estate.
func _test_regime_balance(modifiers: Dictionary) -> void:
	var definition_keys: PackedStringArray = modifiers.get(
		"definition_keys", PackedStringArray())
	var offsets: PackedInt32Array = modifiers.get(
		"definition_term_offsets", PackedInt32Array())
	var stat_ids: PackedInt32Array = modifiers.get("term_stat_ids", PackedInt32Array())
	var values: PackedFloat64Array = modifiers.get("term_values", PackedFloat64Array())
	var stat_keys: PackedStringArray = modifiers.get("stat_keys", PackedStringArray())
	var pattern := RegEx.create_from_string(SATISFACTION_STAT_PATTERN)
	for key in REGIME_BALANCE_BP:
		var index := definition_keys.find(String(key))
		if not _expect("regime balance definition %s is compiled" % key, index >= 0):
			continue
		var actual := {}
		for term in range(offsets[index], offsets[index + 1]):
			var stat_id := int(stat_ids[term])
			if stat_id < 0 or stat_id >= stat_keys.size():
				continue
			var hit := pattern.search(String(stat_keys[stat_id]))
			if hit != null:
				actual[hit.get_string(1)] = int(round(values[term]))
		var expected: Dictionary = REGIME_BALANCE_BP[key]
		_expect("%s covers exactly %d estates (%s)" % [
				key, expected.size(), str(actual.keys())],
			actual.size() == expected.size())
		for profession in expected:
			_expect("%s %s = %d bp (catalog %d)" % [key, profession,
					int(expected[profession]), int(actual.get(profession, 0))],
				int(actual.get(profession, 0)) == int(expected[profession]))


## The non-satisfaction half: every term must be a COUNTRY-domain MULTIPLY on the
## stat the table names. An ADD term here would land on a factor of 1.0 and read
## as a rounding error instead of the shipped multiplier.
func _test_regime_charter(modifiers: Dictionary) -> void:
	var definition_keys: PackedStringArray = modifiers.get(
		"definition_keys", PackedStringArray())
	var domains: PackedInt32Array = modifiers.get(
		"definition_domains", PackedInt32Array())
	var offsets: PackedInt32Array = modifiers.get(
		"definition_term_offsets", PackedInt32Array())
	var stat_ids: PackedInt32Array = modifiers.get("term_stat_ids", PackedInt32Array())
	var operations: PackedInt32Array = modifiers.get(
		"term_operations", PackedInt32Array())
	var values: PackedFloat64Array = modifiers.get("term_values", PackedFloat64Array())
	var stat_keys: PackedStringArray = modifiers.get("stat_keys", PackedStringArray())
	for key in REGIME_CHARTER:
		var index := definition_keys.find(String(key))
		if not _expect("regime charter %s is compiled" % key, index >= 0):
			continue
		_expect("%s is a COUNTRY-domain definition" % key, int(domains[index]) == 1)
		var actual := {}
		var multiply_only := true
		for term in range(offsets[index], offsets[index + 1]):
			if int(operations[term]) != 2:
				multiply_only = false
			var stat_id := int(stat_ids[term])
			if stat_id >= 0 and stat_id < stat_keys.size():
				actual[String(stat_keys[stat_id])] = float(values[term])
		_expect("%s holds only MULTIPLY terms" % key, multiply_only)
		var expected: Dictionary = REGIME_CHARTER[key]
		_expect("%s covers exactly %d stats (%s)" % [
				key, expected.size(), str(actual.keys())],
			actual.size() == expected.size())
		for stat_key in expected:
			var want := float(expected[stat_key])
			var got := float(actual.get(stat_key, 0.0))
			_expect("%s %s = %.2f (catalog %.2f)" % [key, stat_key, want, got],
				is_equal_approx(got, want))


## Family effects reach satisfaction through the same definition, and the
## cross-catalog binding check must accept a COUNTRY-domain satisfaction effect
## while still rejecting a definition whose domain does not match.
func _test_family_effect_binding(economy: Dictionary, modifiers: Dictionary) -> void:
	var command := EffectCommandScript.new()
	command.opcode = 1  # APPLY
	command.target_resolver = 1  # TARGET_INSTANCE
	command.command_key = &"family.effect.patronage_satisfaction"
	command.definition_key = StringName(FAMILY_PATRONAGE)
	var effect := FamilyEffectDefinitionScript.new()
	effect.key = &"family.effect.patronage_satisfaction"
	effect.source_kind = FamilyEffectDefinitionScript.SourceKind.TRAIT
	effect.target_domain = FamilyEffectDefinitionScript.TargetDomain.COUNTRY
	effect.operation = FamilyEffectDefinitionScript.Operation.ADD
	effect.max_stacks = 1
	effect.commands = [command]
	var catalog := FamilyEffectCatalogScript.new()
	catalog.effects = [effect]
	var valid: Dictionary = catalog.validate_domain_bindings(economy, modifiers)
	_expect("a family effect may target the satisfaction definition (%s)" %
		str(valid.get("reason", "")), bool(valid.get("ok", false)))
	# Negative control: the same command pointed at a city-scope definition must
	# fail, because a family ADD cannot bind to an ECONOMY-domain definition.
	var wrong_command := EffectCommandScript.new()
	wrong_command.opcode = 1
	wrong_command.target_resolver = 1
	wrong_command.command_key = &"family.effect.patronage_satisfaction"
	wrong_command.definition_key = &"family.city.production_boost"
	var wrong_effect := FamilyEffectDefinitionScript.new()
	wrong_effect.key = &"family.effect.patronage_satisfaction"
	wrong_effect.source_kind = FamilyEffectDefinitionScript.SourceKind.TRAIT
	wrong_effect.target_domain = FamilyEffectDefinitionScript.TargetDomain.COUNTRY
	wrong_effect.operation = FamilyEffectDefinitionScript.Operation.ADD
	wrong_effect.max_stacks = 1
	wrong_effect.commands = [wrong_command]
	var wrong_catalog := FamilyEffectCatalogScript.new()
	wrong_catalog.effects = [wrong_effect]
	var rejected: Dictionary = wrong_catalog.validate_domain_bindings(
		economy, modifiers)
	_expect("a country family effect cannot bind a city-scope definition",
		not bool(rejected.get("ok", true)) and String(
			rejected.get("reason", "")) == "family_effect_modifier_contract_mismatch")
	_test_official_family_effect(economy, modifiers)


## The shipped `patronage_house` effect must survive the official compile and the
## whole official catalog must still bind against the real economy/modifier
## columns. This is the guard that keeps authored family content from silently
## targeting a definition the Modifier runtime never resolved.
func _test_official_family_effect(economy: Dictionary, modifiers: Dictionary) -> void:
	var official = FamilyEffectCatalogScript.load_default()
	if not _expect("official family effect catalog loads", official != null):
		return
	var found: Resource = null
	for raw in official.effects:
		var definition: Resource = raw
		if String(definition.key) == "patronage_house":
			found = definition
			break
	if not _expect("the shipped patronage_house effect is present", found != null):
		return
	_expect("patronage_house targets the country domain",
		int(found.get("target_domain")) ==
			FamilyEffectDefinitionScript.TargetDomain.COUNTRY)
	_expect("patronage_house is an additive effect",
		int(found.get("operation")) == FamilyEffectDefinitionScript.Operation.ADD)
	_expect("patronage_house keeps six prestige magnitudes",
		(found.get("magnitude_by_prestige_q16") as PackedInt32Array).size() == 6)
	var commands: Array = found.get("commands")
	if not _expect("patronage_house carries exactly one command", commands.size() == 1):
		return
	var command: Resource = commands[0]
	_expect("patronage_house points at the satisfaction definition",
		String(command.get("definition_key")) == FAMILY_PATRONAGE)
	var compiled: Dictionary = official.compile_native_catalog(
		economy.get("technology_ids", PackedStringArray()))
	_expect("the official family effect catalog compiles",
		bool(compiled.get("ok", false)))
	var effect_keys: PackedStringArray = compiled.get(
		"family_effect_keys", PackedStringArray())
	_expect("the compiled catalog carries patronage_house",
		effect_keys.has("family.effect.patronage_house"))
	var binding: Dictionary = official.validate_domain_bindings(economy, modifiers)
	_expect("every official family effect binds against the real catalogs (%s)" %
		str(binding.get("reason", "")), bool(binding.get("ok", false)))


## End-to-end native half: apply a definition, let the Modifier domain commit,
## then read the frozen epoch table Economy publishes for the country.
func _test_frozen_channel(economy: Dictionary, modifiers: Dictionary) -> void:
	var ext := _new_world(2)
	if ext == null:
		return
	var native_economy := economy.duplicate(true)
	native_economy.erase("ok")
	var native_modifiers := modifiers.duplicate(true)
	native_modifiers.erase("ok")
	if not _expect("modifier runtime configures",
			bool(ext.configure_modifiers(native_modifiers, 2).get("ok", false))):
		return
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": economy.get("technology_ids", PackedStringArray()),
	}
	if not _expect("country configures", bool(ext.configure_country(
			native_economy, country_profile, 2, 7301).get("ok", false))):
		return
	var water := PackedByteArray()
	water.resize(2)
	water.fill(0)
	if not _expect("country bootstraps with territory", bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.satisfaction_sources"]),
		"country_names": PackedStringArray([" Satisfaction Fixture"]),
		"regime_ids": PackedStringArray(["early_clan"]),
		"territory_offsets": PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 1]),
	}, water).get("ok", false))):
		return
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("a country handle is published for the fixture", handle > 0)
	if handle <= 0:
		return
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.economy_cadence_force_market_days = 1
	profile.economy_accuracy_preset = "EXACT"
	profile.worker_enabled = false
	profile.employment_mobility_daily_q16 = 0
	profile.starvation_death_rate_q32 = 0
	profile.carrying_surplus_elasticity_q16 = 0
	profile.carrying_sat_elasticity_q16 = 0
	if not _expect("economy configures", bool(ext.configure_economy(
			native_economy, profile, 2, 7301).get("ok", false))):
		return
	var signatures: PackedStringArray = native_economy.get(
		"signature_keys", PackedStringArray())
	var farmer := signatures.find("tenant_farmer|default")
	var worker := signatures.find("worker|default")
	if not _expect("fixture signatures exist", farmer >= 0 and worker >= 0):
		return
	var good_count := (native_economy.get("good_ids", PackedStringArray()) as PackedStringArray).size()
	var stock := PackedInt64Array()
	# One local market per bootstrapped cell, so the stock payload is a dense
	# (market x good) matrix.
	stock.resize(good_count * 2)
	stock.fill(1000000)
	var bootstrap_result: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([farmer, worker]),
		"population": PackedInt64Array([60, 60]),
		"funds": PackedInt64Array([40000000, 40000000]),
	}, {"stock": stock})
	if not bool(bootstrap_result.get("ok", false)):
		print("bootstrap_economy result=", bootstrap_result)
	_expect("economy bootstraps two cells", bool(bootstrap_result.get("ok", false)))
	_run_economy_day(ext, 0)
	_run_economy_day(ext, 1)
	var report: Dictionary = ext.get_epoch_profession_report(_country_slot(ext))
	if not _expect("epoch profession report is published",
			bool(report.get("ok", false))):
		return
	var profession_ids: PackedStringArray = report.get("profession_ids", PackedStringArray())
	var baseline: PackedInt64Array = report.get("satisfaction_bp", PackedInt64Array())
	if not _expect("report carries one bias per profession",
			baseline.size() == profession_ids.size()):
		return
	var farmer_slot := profession_ids.find("tenant_farmer")
	var worker_slot := profession_ids.find("worker")
	if not _expect("report indexes the fixture professions",
			farmer_slot >= 0 and worker_slot >= 0):
		return
	var farmer_before := int(baseline[farmer_slot])
	var worker_before := int(baseline[worker_slot])
	var farmer_cell_before := _cell_satisfaction(ext, 0)
	# Apply the relief definition exactly as the narrative adapter does.
	_apply_definition(ext, handle, RELIEF, 1, 2)
	_expect("modifier boundary commits", bool(ext.run_modifier_daily(2).get("ok", false)))
	_run_economy_day(ext, 2)
	_run_economy_day(ext, 3)
	report = ext.get_epoch_profession_report(_country_slot(ext))
	baseline = report.get("satisfaction_bp", PackedInt64Array())
	var farmer_after := int(baseline[farmer_slot])
	var worker_after := int(baseline[worker_slot])
	_expect("relief raises the tenant farmer bias by the authored 400 bp (%d -> %d)" % [
			farmer_before, farmer_after], farmer_after - farmer_before == 400)
	_expect("relief leaves an unrelated profession untouched (%d -> %d)" % [
			worker_before, worker_after], worker_after == worker_before)
	var farmer_cell_after := _cell_satisfaction(ext, 0)
	_expect("relief keeps the settled composite in a sane band (%.4f -> %.4f)" % [
			farmer_cell_before, farmer_cell_after],
		absf(farmer_cell_after - farmer_cell_before) < 0.05)
	# `explain` recomputes the identity from the stored dimensions, so it is the
	# noise-free place to assert that the bias entered the settlement kernel.
	var farmer_handle := _cohort_handle(ext, 0, farmer_slot)
	if farmer_handle > 0:
		var explain: Dictionary = ext.explain_cohort_satisfaction(farmer_handle)
		_expect("explain is available for the biased cohort",
			bool(explain.get("ok", false)))
		var raw_before := int(explain.get("raw_before_bias_q16", 0))
		var bias := int(explain.get("bias_q16", 0))
		var ceiling := int(explain.get("ceiling_q16", 0))
		var composite := int(explain.get("composite_q16", 0))
		_expect("explain reports the authored 400 bp bias in Q16 (got %d)" % bias,
			bias == 2621)
		_expect("the settled composite equals min(raw + bias, ceiling)",
			composite == mini(raw_before + bias, ceiling))
		if raw_before + bias <= ceiling:
			_expect("a non-binding ceiling lets the bias lift the composite", 
				composite > raw_before)
		else:
			_stage("relief ceiling binds (raw+bias=%d ceiling=%d)" % [
				raw_before + bias, ceiling])
	var worker_cell_after := _cell_satisfaction(ext, 1)
	# Apply the corvée definition on a second source; a negative bias must not
	# raise satisfaction even though the ceiling gates the positive side.
	_apply_definition(ext, handle, LEVY, 2, 4)
	_expect("second modifier boundary commits",
		bool(ext.run_modifier_daily(4).get("ok", false)))
	_run_economy_day(ext, 4)
	_run_economy_day(ext, 5)
	report = ext.get_epoch_profession_report(_country_slot(ext))
	baseline = report.get("satisfaction_bp", PackedInt64Array())
	_expect("corvée lowers the worker bias by 400 bp (%d -> %d)" % [
			worker_after, int(baseline[worker_slot])],
		int(baseline[worker_slot]) - worker_after == -400)
	var worker_handle := _cohort_handle(ext, 1, worker_slot)
	if worker_handle > 0:
		var worker_explain: Dictionary = ext.explain_cohort_satisfaction(worker_handle)
		_expect("explain reports the negative bias in Q16 (got %d)" % int(
				worker_explain.get("bias_q16", 0)),
			int(worker_explain.get("bias_q16", 0)) == -2621)
		# A negative bias can only pull the composite down or leave the ceiling
		# binding; it must never manufacture satisfaction.
		_expect("the negative bias never exceeds the raw score",
			int(worker_explain.get("raw_q16", 0)) <=
				int(worker_explain.get("raw_before_bias_q16", 0)))
	var worker_cell_corvee := _cell_satisfaction(ext, 1)
	_expect("corvée keeps the settled composite in a sane band (%.4f -> %.4f)" % [
			worker_cell_after, worker_cell_corvee],
		absf(worker_cell_corvee - worker_cell_after) < 0.05)
	_test_regime_binding(ext, handle, profession_ids, baseline)


## Regime channel: a regime declares Modifier definitions; reconciling applies
## them and a switch replaces the previous regime's rows instead of stacking.
func _test_regime_binding(ext: Object, handle: int,
		profession_ids: PackedStringArray, baseline: PackedInt64Array) -> void:
	var merchant_slot := profession_ids.find("merchant")
	var landlord_slot := profession_ids.find("landlord")
	if not _expect("report indexes the regime fixture professions",
			merchant_slot >= 0 and landlord_slot >= 0):
		return
	var merchant_before := int(baseline[merchant_slot])
	var landlord_before := int(baseline[landlord_slot])
	# The economy fixture only populates farmers and workers, so the regime
	# additions are read from the frozen table, not from a settled cell.
	var facade := ModifierFacadeScript.new()
	facade.attach_existing(ext)
	_expect("borrowed modifier facade is usable",
		bool(facade.is_configured()))
	var applied: Dictionary = RegimeEffectBindingScript.reconcile(facade, handle,
		PackedStringArray(["regime.early_clan.cohesion"]), 6)
	_expect("early clan regime applies one definition (%s)" % str(applied),
		bool(applied.get("ok", false)) and int(applied.get("applied", -1)) == 1)
	_expect("a first regime has no previous rows to remove",
		int(applied.get("removed", -1)) == 0)
	_expect("regime modifier boundary commits",
		bool(ext.run_modifier_daily(6).get("ok", false)))
	var rows: Dictionary = ext.list_modifiers(1, handle, "")
	_expect("the regime row is owned by the regime source",
		_count_regime_rows(rows) == 1)
	_run_economy_day(ext, 6)
	_run_economy_day(ext, 7)
	var report: Dictionary = ext.get_epoch_profession_report(_country_slot(ext))
	var frozen: PackedInt64Array = report.get("satisfaction_bp", PackedInt64Array())
	# Channel property, not a balance number: the frozen table must move by
	# exactly the declared term. `_test_regime_balance` pins the values.
	var early_landlord := int(REGIME_BALANCE_BP[REGIME_EARLY]["landlord"])
	var early_merchant := int(REGIME_BALANCE_BP[REGIME_EARLY]["merchant"])
	_expect("early clan moves the landlord bias by %d bp (%d -> %d)" % [
			early_landlord, landlord_before, int(frozen[landlord_slot])],
		int(frozen[landlord_slot]) - landlord_before == early_landlord)
	_expect("early clan moves the merchant bias by %d bp (%d -> %d)" % [
			early_merchant, merchant_before, int(frozen[merchant_slot])],
		int(frozen[merchant_slot]) - merchant_before == early_merchant)
	# Switch: the previous regime's rows must disappear, not accumulate.
	var switched: Dictionary = RegimeEffectBindingScript.reconcile(facade, handle,
		PackedStringArray(["regime.local_council.cohesion"]), 8)
	_expect("regime switch removes exactly one previous row (%s)" % str(switched),
		bool(switched.get("ok", false)) and int(switched.get("removed", -1)) == 1)
	_expect("regime switch applies the new definition",
		int(switched.get("applied", -1)) == 1)
	_expect("switch boundary commits",
		bool(ext.run_modifier_daily(8).get("ok", false)))
	rows = ext.list_modifiers(1, handle, "")
	_expect("only the new regime row survives",
		_count_regime_rows(rows) == 1)
	_expect("the early clan definition is gone",
		not (rows.get("definition_keys", PackedStringArray()) as PackedStringArray).has(
			"regime.early_clan.cohesion"))
	_run_economy_day(ext, 8)
	_run_economy_day(ext, 9)
	report = ext.get_epoch_profession_report(_country_slot(ext))
	frozen = report.get("satisfaction_bp", PackedInt64Array())
	var council_merchant := int(
		REGIME_BALANCE_BP["regime.local_council.cohesion"]["merchant"])
	var council_landlord := int(
		REGIME_BALANCE_BP["regime.local_council.cohesion"]["landlord"])
	_expect("local council moves the merchant bias by %d bp (%d -> %d)" % [
			council_merchant, merchant_before, int(frozen[merchant_slot])],
		int(frozen[merchant_slot]) - merchant_before == council_merchant)
	_expect("local council moves the landlord bias by %d bp (%d -> %d)" % [
			council_landlord, landlord_before, int(frozen[landlord_slot])],
		int(frozen[landlord_slot]) - landlord_before == council_landlord)


func _count_regime_rows(listed: Dictionary) -> int:
	var source_types: PackedInt64Array = listed.get(
		"source_types", PackedInt64Array())
	var count := 0
	for index in range(source_types.size()):
		if int(source_types[index]) == RegimeEffectBindingScript.REGIME_SOURCE_TYPE:
			count += 1
	return count


func _cohort_handle(ext: Object, cell: int, profession: int) -> int:
	var snapshot: Dictionary = ext.get_population_cell_snapshot(cell)
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var professions: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	for index in range(professions.size()):
		if int(professions[index]) == profession and index < handles.size():
			return int(handles[index])
	return -1


func _stage(message: String) -> void:
	print("[stage] ", message)


func _country_slot(ext: Object) -> int:
	var summary: Dictionary = ext.get_country_cell_summary(0)
	return int(summary.get("country_slot", 0))


func _apply_definition(ext: Object, handle: int, key: String, source_id: int,
		day: int) -> void:
	var submitted: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([190]),
		"sequences": PackedInt64Array([source_id]),
		"effective_days": PackedInt64Array([day]),
		"definition_keys": PackedStringArray([key]),
		"domains": PackedInt32Array([1]),
		"scopes": PackedInt32Array([2]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([0x4E415252]),
		"source_ids": PackedInt64Array([source_id]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([Q16_ONE]),
		"modifier_handles": PackedInt64Array([0]),
	})
	_expect("definition %s submits" % key, bool(submitted.get("ok", false)))


func _cell_satisfaction(ext: Object, cell: int) -> float:
	var row: Dictionary = ext.get_cell_satisfaction_attractiveness(cell)
	if not bool(row.get("ok", false)):
		return -1.0
	return float(int(row.get("composite_q16", 0))) / float(Q16_ONE)


func _run_economy_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(64):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)):
			break
	return report


func _new_world(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_expect("DCWorldExt instantiates", false)
		return null
	ext.create_entities(cells)
	var climate := PackedFloat32Array()
	climate.resize(cells)
	climate.fill(0.5)
	var zero_f := PackedFloat32Array()
	zero_f.resize(cells)
	zero_f.fill(0.0)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, climate)
	for slot_name in [&"cell_snow_cover", &"cell_weather_intensity",
			&"cell_elevation", &"cell_temp_365d"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, zero_f)
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(cells)
	zeros_u8.fill(0)
	for pair in [[&"cell_terrain", terrain], [&"cell_landform", zeros_u8],
			[&"cell_vegetation", zeros_u8], [&"cell_is_water", zeros_u8],
			[&"cell_has_river", zeros_u8], [&"cell_weather_type", zeros_u8],
			[&"cell_cover", zeros_u8]]:
		var slot: int = ext.register_component(pair[0], 2, 1, false)
		ext.write_u8_range(slot, 0, pair[1])
	return ext


func _expect(label: String, condition: bool) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
		print("[FAIL] ", label)
	return condition
