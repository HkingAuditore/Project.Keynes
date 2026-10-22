extends SceneTree

## PROBE, not a suite test. Known blocker: `ideology_class_opinion_unavailable`.
##
## Cause, traced 2026-10-21: `bootstrap_country` CANNOT supply political classes.
## Its packet is country ids/names/cash/territory/tech only. Class influence comes
## from `NativeEconomyRuntime::country_class_opinion_snapshot()`, which
## `evaluate_support` reads directly -- so a harness without an economy runtime can
## never satisfy the support gate, and picking a card without class stances does
## not help either (the intersection is empty: every cell card that is directly
## discoverable also has stances).
##
## To finish this probe, give it the economy fixture from
## ideology_effect_metric_publish_test (_build_ext + _bootstrap_economy), not a
## richer country packet.
##
## End-to-end: does a REAL authored card reach the per-cell coefficient plane?
##
## Every other ideology test either uses a synthetic catalog or stops at the data
## layer. This one loads the three shipped catalogs, equips a real card through
## the real command path, runs the daily pass, and asks the plane what it sees.
##
## It deliberately does NOT assert a factor change: that needs an economy runtime
## with cells and goods, which is `ideology_effect_metric_publish_test`'s fixture.
## The two together cover the chain -- real card -> plane entry (here), and
## plane entry -> per-cell factor (there).

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const EFFECTS_PATH := "res://data/ideologies/default_ideology_effects.tres"
## The plane accepts both cell-scoped domains: 2 = settlement cell, 5 = building
## or resource within a cell. Restricting to one of them would skip half the
## cards for a reason that has nothing to do with this test.
const CELL_DOMAINS := [2, 5]

var _checks := 0
var _next_sequence := 1
var _failures := 0


func _init() -> void:
	print("=== ideology card -> cell plane ===")
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles", bool(economy_ir.get("ok", false)),
			str(economy_ir.get("reason", ""))):
		_finish()
		return
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	if not _require("country catalog compiles", bool(country_ir.get("ok", false))):
		_finish()
		return
	var ideology_ir: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(economy_ir, economy_ir)
	if not _require("real ideology catalog compiles", bool(ideology_ir.get("ok", false)),
			str(ideology_ir.get("reason", ""))):
		_finish()
		return

	# Pick a real cell-domain card. `target_domains` lives on the EFFECT program,
	# not on the card row -- the card only names its programs through the level
	# rows, so the domain has to be looked up after resolving that key.
	# The shipped effects live in a domain catalog; the .tres on its own is only
	# a container with no compile entry point.
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("real effects domain catalog builds", domain != null):
		_finish()
		return
	var effects_ir: Dictionary = domain.compile_native_catalog()
	if not _require("real effects catalog compiles",
			bool(effects_ir.get("ok", false)), str(effects_ir.get("reason", ""))):
		_finish()
		return
	effects_ir.erase("ok")
	var program_domains := {}
	var effect_keys: PackedStringArray = effects_ir.get("effect_keys", PackedStringArray())
	var effect_domains: PackedInt32Array = effects_ir.get("target_domains", PackedInt32Array())
	for index in mini(effect_keys.size(), effect_domains.size()):
		program_domains[String(effect_keys[index])] = int(effect_domains[index])

	var card_index := -1
	var card_program := ""
	var level_offsets: PackedInt32Array = ideology_ir.get(
		"level_persistent_offsets", PackedInt32Array())
	var template_keys: PackedStringArray = ideology_ir.get(
		"persistent_definition_keys", PackedStringArray())
	for index in level_offsets.size() - 1:
		var begin := int(level_offsets[index])
		var end := int(level_offsets[index + 1])
		if begin >= end or begin >= template_keys.size():
			continue
		var candidate := "ideology.effect." + String(template_keys[begin])
		# Only cards the country may discover outright. The real catalog gates
		# most cards behind an offer/era, and DISCOVER_IDEOLOGY is rejected for
		# those -- which makes the whole batch fail, not just that command.
		var flags: PackedByteArray = ideology_ir.get("acquisition_flags", PackedByteArray())
		if index >= flags.size() or (int(flags[index]) & 1) == 0:
			continue
		# The support gate needs class influence, which needs a populated country.
		# A card with no class stance skips the gate entirely, so pick one of
		# those: the plane is what this probe is about, not the support model.
		var stance_offsets: PackedInt32Array = ideology_ir.get(
			"stance_offsets", PackedInt32Array())
		if index + 1 < stance_offsets.size() \
				and int(stance_offsets[index + 1]) != int(stance_offsets[index]):
			continue
		if int(program_domains.get(candidate, -1)) in CELL_DOMAINS:
			card_index = index
			card_program = candidate
			break
	if not _require("a real cell-domain card exists", card_index >= 0):
		_finish()
		return
	print("    using card index %d (%s)" % [card_index, card_program])

	var ext: Object = _configured_ext(country_ir, ideology_ir)
	if ext == null:
		_finish()
		return

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("country handle is generation safe", handle != 0):
		_finish()
		return

	var before: Dictionary = ext.get_ideology_cell_program_summary()
	_expect("no card equipped -> no plane entries yet",
		int(before.get("entry_count", -1)) == 0, str(before))

	var submitted: Dictionary = ext.submit_ideology_commands(
		_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": card_index},
			{"op": 5, "day": 0, "handle": handle, "idea": card_index},
		]))
	_expect("discover and equip the real card", bool(submitted.get("ok", false)),
		str(submitted))
	_expect("daily pass runs", bool(ext.run_ideology_daily(0).get("ok", false)))

	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var locations: PackedInt32Array = snapshot.get("locations", PackedInt32Array())
	_expect("the card is equipped", locations.size() > 0 and int(locations[0]) == 1,
		str(snapshot.get("last_error", "")))

	var after: Dictionary = ext.get_ideology_cell_program_summary()
	if not _require("the plane scanned the equipped card",
			int(after.get("scanned_cards", 0)) >= 1, str(after)):
		_finish()
		return
	_expect("the card has a persistent template", int(after.get("scanned_templates", 0)) >= 1)
	# The point of the test: an authored card reaches the plane without any
	# synthetic fixture. If this is zero, either the card's commands no longer
	# resolve, or every path was counted into an `unsupported_*` bucket -- the
	# counters below say which.
	_expect("the real card yields at least one plane entry",
		int(after.get("entry_count", 0)) >= 1, str(after))
	_finish()


func _configured_ext(country_ir: Dictionary, ideology_ir: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var catalog := country_ir.duplicate(true)
	catalog.erase("ok")
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}
	assert(bool(ext.configure_country(catalog, profile, 1, 97).get("ok", false)))
	assert(bool(ext.bootstrap_country({}, PackedByteArray([0])).get("ok", false)))
	var modifier := ModifierFacadeScript.new()
	if not _require("modifier runtime configures",
			bool(modifier.configure(ext, 1).get("ok", false))):
		return null
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("real effects domain catalog builds", domain != null):
		return null
	var effects_ir: Dictionary = domain.compile_native_catalog()
	if not _require("real effects catalog compiles",
			bool(effects_ir.get("ok", false)), str(effects_ir.get("reason", ""))):
		return null
	effects_ir.erase("ok")
	if not _require("effects configure",
			bool(ext.configure_effects(effects_ir).get("ok", false))):
		return null
	var ideology_payload := ideology_ir.duplicate(true)
	ideology_payload.erase("ok")
	if not _require("ideologies configure",
			bool(ext.configure_ideologies(ideology_payload).get("ok", false))):
		return null
	return ext


## The exact column set the native ingress expects. A missing or renamed column
## fails the whole batch with `ideology_command_columns_invalid` -- there is no
## partial-diagnostic for it, which is why this mirrors the known-good helper in
## ideology_effect_instance_test.gd instead of inventing a shorter shape.
func _commands(rows: Array) -> Dictionary:
	var out := {
		"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(), "producer_ids": PackedInt32Array(),
		"sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array(),
	}
	for row in rows:
		out.opcodes.append(int(row.get("op", 0)))
		out.effective_days.append(int(row.get("day", 0)))
		out.source_priorities.append(0)
		out.producer_ids.append(1)
		out.sequences.append(_next_sequence)
		_next_sequence += 1
		out.country_handles.append(int(row.get("handle", 0)))
		out.ideology_ids.append(int(row.get("idea", -1)))
		out.values_q16.append(int(row.get("value", 0)))
		out.offer_generations.append(int(row.get("offer", 0)))
		out.choice_indices.append(int(row.get("choice", -1)))
		out.gate_ids.append(-1)
	return out


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s %s" % [label, detail])


func _finish() -> void:
	print("=== ideology card -> cell plane: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
