extends SceneTree

## L4-10b + L4-11 acceptance: the draw offer is no longer a fixed 3-wide drawer.
##
## Why this exists
## ---------------
## `Offer::ideology_ids` was `std::array<int32_t, 3>` with `3` written into the
## draw, the choice bound and the save layout; `_draw_count` was read from the
## catalog, validated to be exactly 3, and never used again. On top of that the
## pool was "every card not yet owned", so a duplicate was impossible and the
## only sink for a deep pool was nothing at all.
##
## Three mechanics are new, and each needs a deterministic proof:
##
##  1. Row count follows the catalog (and later the stat), not a literal.
##  2. 封存 removes a card from the pool for good, charges for it, and refuses
##     the two states it must refuse (already owned, already banned).
##  3. 精进 returns an owned-but-not-maxed card to the pool, and picking it pays
##     understanding instead of unlocking something.
##
## The pity guarantee (at least one current-era row) is NOT covered here: it
## needs a country that has actually reached an era milestone, and this fixture
## has no technology progression. It is covered where the era is reachable --
## see the note in docs §36.
##
## 封存 doubles as the tool that makes 精进 deterministic: banning everything
## except one new card leaves a pool of exactly {one new, one owned}, so the
## refine row must appear.

const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const Q16_ONE := 65536
const BAN_OPCODE := 11

var _checks := 0
var _failures := 0
var _sequence := 1


func _init() -> void:
	_run()
	print("ideology pool mechanics: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(economy_ir.get("ok", false)),
		str(economy_ir.get("reason", "")))
	if not bool(economy_ir.get("ok", false)):
		return
	var base: Resource = IdeologyCatalogScript.load_default()
	if base == null:
		_expect("default ideology catalog loads", false)
		return
	var compiled: Dictionary = base.compile_native_catalog(economy_ir, economy_ir)
	_expect("ideology catalog compiles", bool(compiled.get("ok", false)),
		str(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		return
	var ideology_ids: PackedStringArray = compiled.ideology_ids
	_expect("the pool is deep enough for these cases", ideology_ids.size() >= 8,
		str(ideology_ids.size()))

	# --- 1. Row count comes from the catalog. -------------------------------
	var three := _boot(base, economy_ir, 3)
	_expect("fixture boots with the authored 3 rows", bool(three.get("ok", false)),
		str(three.get("reason", "")))
	if bool(three.get("ok", false)):
		var offer: PackedInt32Array = _draw(three)
		_expect("a 3-row catalog draws 3 rows", offer.size() == 3, str(offer.size()))
		_expect("the snapshot reports the row count",
			int(three.ext.get_ideology_snapshot(three.handle).get(
				"offer_choice_count", -1)) == 3)
	_five_rows(base, economy_ir)

	# --- 2 + 3. 封存 and 精进, in one deterministic fixture. -----------------
	var fixture := _boot(base, economy_ir, 3)
	if not bool(fixture.get("ok", false)):
		_expect("ban/refine fixture boots", false, str(fixture.get("reason", "")))
		return
	_expect_ban_and_refine(fixture, ideology_ids)


## A 5-row catalog must produce 5 rows. This is the literal that used to be
## hard-coded in three places; the array is 5 wide, so 5 is the ceiling.
func _five_rows(base: Resource, economy_ir: Dictionary) -> void:
	var fixture := _boot(base, economy_ir, 5)
	_expect("a 5-row catalog configures", bool(fixture.get("ok", false)),
		str(fixture.get("reason", "")))
	if not bool(fixture.get("ok", false)):
		return
	var offer: PackedInt32Array = _draw(fixture)
	_expect("a 5-row catalog draws 5 rows", offer.size() == 5, str(offer.size()))
	# All five must be distinct: the drawer is non-replacement, and a duplicated
	# id would also make `choose_offer` able to pick a row twice.
	var distinct := {}
	for id in offer:
		distinct[int(id)] = true
	_expect("the rows are distinct", distinct.size() == offer.size(), str(offer))


func _expect_ban_and_refine(fixture: Dictionary, ideology_ids: PackedStringArray) -> void:
	var ext = fixture.ext
	var handle: int = fixture.handle
	var pool0 := int(ext.preview_ideology_offer_eligibility(handle).get("pool_size", -1))
	_expect("the fixture has an eligible pool to work with", pool0 > 0, str(pool0))
	if pool0 <= 0:
		return
	# Own a card by drawing and choosing, rather than by discovering a fixed id:
	# whatever comes out of the pool is guaranteed to satisfy its own
	# requirements, which is what the refine branch re-checks.
	var first := _draw(fixture, 1)
	_expect("the first draw produces rows", not first.is_empty(), str(first))
	if first.is_empty():
		return
	var owned := int(first[0])
	var generation := int(ext.get_ideology_snapshot(handle).get("offer_generation", 0))
	_expect("choosing the first row is accepted",
		bool(ext.submit_ideology_commands(_commands([
			{"op": 4, "day": 2, "handle": handle, "generation": generation,
				"choice": 0}])).get("ok", false))
		and bool(ext.run_ideology_daily(2).get("ok", false)))
	_expect("the card is now owned",
		(ext.get_ideology_snapshot(handle).get("known_ids", PackedInt32Array())
			as PackedInt32Array).has(owned))

	# 封存 refuses an owned card. GDScript only sees a rejection counter, so the
	# observable claim is the one that matters: the pool did not move.
	var pool_before := int(ext.preview_ideology_offer_eligibility(handle).get("pool_size", -1))
	_ban(ext, handle, owned, 3)
	var pool_after_refusal := int(ext.preview_ideology_offer_eligibility(handle).get("pool_size", -1))
	_expect("banning an owned card changes nothing",
		pool_after_refusal == pool_before,
		"%d -> %d" % [pool_before, pool_after_refusal])

	_expect("ban points are granted",
		bool(ext.submit_ideology_commands(_commands([
			{"op": 2, "day": 4, "handle": handle,
				"value": 4096 * 1000 * Q16_ONE}])).get("ok", false))
		and bool(ext.run_ideology_daily(4).get("ok", false)))
	# 封存 everything except the owned card. Ineligible rows are banned too and
	# that is fine: the cost is paid either way and the result is the state the
	# next assertion needs.
	var day := 5
	var batch: Array = []
	for index in ideology_ids.size():
		if index == owned:
			continue
		batch.append({"op": BAN_OPCODE, "day": day, "handle": handle, "idea": index})
	ext.submit_ideology_commands(_commands(batch))
	ext.run_ideology_daily(day)
	day += 1
	var pool_final := int(ext.preview_ideology_offer_eligibility(handle).get("pool_size", -1))
	_expect("封存 drains every new card from the pool", pool_final == 0, str(pool_final))

	# With no new cards left, the only possible row is the owned one via 精进.
	var understanding_before := _understanding(ext, handle, owned)
	var offer := _draw(fixture, day)
	_expect("精进 keeps an offer alive when the new-card pool is empty",
		offer.size() == 1, str(offer))
	_expect("the single row is the owned card", offer.has(owned), str(offer))
	if offer.is_empty():
		return
	var refine_generation := int(ext.get_ideology_snapshot(handle).get(
		"offer_generation", 0))
	_expect("choosing the 精进 row is accepted",
		bool(ext.submit_ideology_commands(_commands([
			{"op": 4, "day": day + 1, "handle": handle,
				"generation": refine_generation,
				"choice": offer.find(owned)}])).get("ok", false))
		and bool(ext.run_ideology_daily(day + 1).get("ok", false)))
	var understanding_after := _understanding(ext, handle, owned)
	_expect("精进 pays understanding instead of re-unlocking",
		understanding_after > understanding_before,
		"%d -> %d" % [understanding_before, understanding_after])


func _understanding(ext, handle: int, idea: int) -> int:
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var values: PackedInt64Array = snapshot.get("understanding_q16", PackedInt64Array())
	var index := ids.find(idea)
	return int(values[index]) if index >= 0 and index < values.size() else 0


func _ban(ext, handle: int, idea: int, sequence: int) -> Dictionary:
	var result: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": BAN_OPCODE, "day": sequence, "handle": handle, "idea": idea}]))
	ext.run_ideology_daily(sequence)
	var report: Dictionary = ext.get_ideology_command_report() \
		if ext.has_method("get_ideology_command_report") else {}
	if result.is_empty():
		return report
	return result


func _draw(fixture: Dictionary, day: int = 2) -> PackedInt32Array:
	var ext = fixture.ext
	var handle: int = fixture.handle
	var ok := bool(ext.submit_ideology_commands(_commands([
		{"op": 3, "day": day, "handle": handle}])).get("ok", false))
	if not ok:
		return PackedInt32Array()
	ext.run_ideology_daily(day)
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	return snapshot.get("offer_ids", PackedInt32Array())


## Boots one country with the given catalog, with enough points to draw.
func _boot(base: Resource, economy_ir: Dictionary, rows: int) -> Dictionary:
	var catalog: Resource = base.duplicate(true)
	if catalog.profile == null:
		return {"ok": false, "reason": "profile_missing"}
	catalog.profile.offer_choice_count = rows
	catalog.profile.refine_weight_bp = 10000
	catalog.profile.refine_understanding_q16 = 4 * Q16_ONE
	var native_catalog: Dictionary = catalog.compile_native_catalog(
		economy_ir, economy_ir)
	if not bool(native_catalog.get("ok", false)):
		return {"ok": false, "reason": String(native_catalog.get("reason", ""))}
	# Two different catalogs: `configure_country` takes the COUNTRY IR (the
	# economy catalog doubles as it here, same as ideology_runtime_test), while
	# `configure_ideologies` takes the ideology IR compiled from it.
	var country_ir: Dictionary = economy_ir.duplicate(true)
	country_ir.erase("ok")
	var config: Dictionary = native_catalog.duplicate(true)
	config.erase("ok")
	# Same minimal boot as ideology_runtime_test: one country, one cell, the
	# hunting technology so the country runtime has a starting tree.
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var country_profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	if not bool(ext.configure_country(country_ir, country_profile, 1, 20261020).get("ok", false)):
		return {"ok": false, "reason": "country_configure_failed"}
	if not bool(ext.bootstrap_country({}, PackedByteArray([0])).get("ok", false)):
		return {"ok": false, "reason": "country_bootstrap_failed"}
	# Every technology, so a card gated on one is at least eligible: otherwise the
	# pool is empty for reasons that have nothing to do with what is under test.
	CountryTestHelper.configure_all_technologies(ext, country_ir, 1, 20261020)
	var modifier := ModifierFacadeScript.new()
	modifier.configure(ext, 1)
	if not bool(ext.configure_effects(_effect_catalog().compile_native_catalog()).get("ok", false)):
		return {"ok": false, "reason": "effect_configure_failed"}
	if not bool(ext.configure_ideologies(config).get("ok", false)):
		return {"ok": false, "reason": "ideology_configure_failed"}
	var country: Dictionary = ext.get_country_cell_summary(0)
	var handle := int(country.get("country_handle", 0))
	if handle == 0:
		return {"ok": false, "reason": "country_handle_missing"}
	# Points: the shipped profile starts at 0, and every draw and every ban is
	# paid for.
	ext.submit_ideology_commands(_commands([
		{"op": 2, "day": 0, "handle": handle, "value": 64 * 1000 * Q16_ONE}]))
	ext.run_ideology_daily(0)
	return {"ok": true, "ext": ext, "handle": handle, "catalog": catalog}


## Minimal Effect catalog: the ideology runtime only needs the command program to
## exist so an equip/transition can complete. Progression is not under test here.
func _effect_catalog() -> Resource:
	var catalog := EffectCatalog.new()
	var definition := EffectDefinition.new()
	definition.key = &"ideology.command"
	definition.cadence_days = 3650
	var end := EffectInstruction.new()
	end.op = 12
	var instruction_list: Array[Resource] = [end]
	definition.instructions = instruction_list
	var command := EffectCommand.new()
	command.action = 1
	command.domain = 1
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 0
	command.command_key = &"ideology.persistent"
	command.definition_key = &"ideology.command"
	var command_list: Array[Resource] = [command]
	definition.commands = command_list
	var definition_list: Array[Resource] = [definition]
	catalog.definitions = definition_list
	return catalog


func _commands(rows: Array) -> Dictionary:
	var out := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array(),
		"sequences": PackedInt64Array(), "producer_ids": PackedInt32Array(),
		"source_priorities": PackedInt32Array()}
	for row in rows:
		var data: Dictionary = row
		out.opcodes.append(int(data.get("op", 0)))
		out.effective_days.append(int(data.get("day", 0)))
		out.country_handles.append(int(data.get("handle", 0)))
		out.ideology_ids.append(int(data.get("idea", -1)))
		out.values_q16.append(int(data.get("value", 0)))
		out.offer_generations.append(int(data.get("generation", 0)))
		out.choice_indices.append(int(data.get("choice", -1)))
		out.gate_ids.append(int(data.get("gate", -1)))
		out.sequences.append(_sequence)
		_sequence += 1
		out.producer_ids.append(1)
		out.source_priorities.append(0)
	return out


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("[FAIL] %s" % label)
	else:
		print("[FAIL] %s (%s)" % [label, detail])
