extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

var _failures := 0

func _init() -> void:
	var first := _fixture(912345)
	if not bool(first.get("ok", false)):
		print("first fixture diagnostic: ", first)
	_expect("first deterministic fixture opens offer", bool(first.get("ok", false)))
	var second := _fixture(912345)
	if not bool(second.get("ok", false)):
		print("second fixture diagnostic: ", second)
	_expect("second deterministic fixture opens offer", bool(second.get("ok", false)))
	if bool(first.get("ok", false)) and bool(second.get("ok", false)):
		_expect("same seed produces byte-equivalent alternative ids and plan hash",
			int(first.offer.plan_hash) == int(second.offer.plan_hash)
			and _option_ids(first.offer) == _option_ids(second.offer))
		_expect("resource and environment evidence contributes visible reward weighting",
			_offer_has_reason(first.offer, "资源或环境证据"))
		var ext: Object = first.ext
		var generation := int(first.offer.offer_generation)
		var chosen: Dictionary = ext.choose_era_reward(generation, 0, 1)
		_expect("formal native choice accepts current generation",
			bool(chosen.get("ok", false)))
		_expect("duplicate choice is rejected",
			not bool(ext.choose_era_reward(generation, 0, 1).get("ok", false)))
		var pending: Dictionary = ext.get_era_reward_offer()
		_expect("choice locks frozen offer pending ACK",
			String(pending.get("status", "")) == "SELECTED_PENDING")
		var saved: PackedByteArray = ext.capture_effect_state()
		var country_saved := _capture_country(first.country)
		_expect("PKEF captures frozen alternatives and pending transaction",
			not saved.is_empty() and not country_saved.is_empty())
		ext.clear_effect_state()
		var country_restored: Dictionary = first.country.restore_bytes(country_saved)
		var restored: Dictionary = ext.restore_effect_state(saved)
		_expect("PKCN/PKEF round trip preserves and audits selected pending offer",
			bool(country_restored.get("ok", false))
			and bool(restored.get("ok", false)) and String(
				ext.get_era_reward_offer().get("status", "")) == "SELECTED_PENDING")
		var legacy := saved.duplicate()
		legacy[4] = 6
		legacy[5] = 0
		legacy[6] = 0
		legacy[7] = 0
		var legacy_result: Dictionary = ext.restore_effect_state(legacy)
		_expect("legacy PKEF is rejected with stable era reward error",
			String(legacy_result.get("reason", "")) ==
				"catalog_hash_mismatch")
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		_expect("selected span alone dispatches one Modifier transaction",
			int(dispatched.get("submitted_transactions", 0)) == 1)
		ext.run_modifier_daily(1)
		ext.ack_effect_native_modifier()
		var resolved: Dictionary = ext.get_era_reward_offer()
		_expect("offer resolves only after domain ACK",
			String(resolved.get("status", "")) == "RESOLVED")
		var option_id := String((first.offer.alternatives as Array)[0].option_id)
		var theme := option_id.get_slice(".", 2)
		var stat_by_theme := {
			"food": "country.output.agriculture_factor",
			"industry": "country.output.manufacturing_factor",
			"research": "country.research.institution_output_factor",
			"trade": "country.trade.capacity_factor",
			"capital": "country.construction.time_factor",
			"society": "country.output.knowledge_factor",
			"state": "country.construction.time_factor",
			"science": "country.research.institution_output_factor",
			"mobilize": "country.output.manufacturing_factor",
		}
		var stat := String(stat_by_theme.get(theme, ""))
		var value := float(ext.evaluate_modifier_stat(
			1, int(first.handle), 0, stat, 1.0))
		_expect("selected reward reaches existing country Modifier consumer",
			not is_equal_approx(value, 1.0))
	print("era_reward_runtime_test: %s" % (
		"PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _fixture(seed: int) -> Dictionary:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return {"ok": false}
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifiers = ModifierFacadeScript.new()
	if not bool(modifiers.configure(ext, 4).get("ok", false)):
		return {"ok": false}
	var country = CountryFacadeScript.new()
	if not bool(country.configure(ext, 1, seed,
			load("res://data/country/default_country.tres"), catalog).get("ok", false)):
		return {"ok": false}
	if not bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.reward_test"]),
		"country_names": PackedStringArray(["Reward Test"]),
		"country_cash": PackedInt64Array([10000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}).get("ok", false)):
		return {"ok": false}
	var effect = EffectDomainCatalogScript.build()
	var effect_ir: Dictionary = effect.compile_native_catalog()
	effect_ir.erase("ok")
	if not bool(ext.configure_effects(effect_ir).get("ok", false)):
		return {"ok": false}
	var handle := int(country.cell_summary(0).country_handle)
	var evidence_sequence := 1
	for signal_id in [&"resource.fertile_soil", &"landform.river_valley",
			&"resource.stone", &"landform.forest"]:
		if not bool(country.discover_research_signal(handle, signal_id, 0, 1,
				0, evidence_sequence).get("ok", false)):
			return {"ok": false, "reason": "signal_submit_failed"}
		evidence_sequence += 1
	if not bool(ext.bind_era_reward_player_country(handle).get("ok", false)):
		return {"ok": false}
	if not bool(country.grant_technology(handle, &"tech.settled_knowledge",
			0, evidence_sequence).get("ok", false)):
		return {"ok": false}
	ext.run_country_slice({"day_index": 0})
	ext.run_effect_daily(0)
	ext.dispatch_effect_native_modifier()
	ext.dispatch_effect_native_gameplay()
	ext.run_modifier_daily(0)
	ext.ack_effect_native_modifier()
	ext.run_gameplay_effects(0)
	ext.ack_effect_native_gameplay()
	ext.run_country_slice({"day_index": 1})
	var offer: Dictionary = ext.get_era_reward_offer()
	return {"ok": String(offer.get("status", "")) == "OPEN",
		"ext": ext, "country": country, "handle": handle, "offer": offer,
		"effect_report": ext.get_effect_report(),
		"country_report": country.report()}

func _option_ids(offer: Dictionary) -> PackedStringArray:
	var ids := PackedStringArray()
	for row in offer.get("alternatives", []):
		ids.append(String(row.get("option_id", "")))
	return ids

func _offer_has_reason(offer: Dictionary, fragment: String) -> bool:
	for row in offer.get("alternatives", []):
		for reason in (row as Dictionary).get("reasons", PackedStringArray()):
			if String(reason).contains(fragment):
				return true
	return false

func _capture_country(country) -> PackedByteArray:
	var begun: Dictionary = country.begin_save(4096)
	if not bool(begun.get("ok", false)):
		return PackedByteArray()
	var bytes := PackedByteArray()
	while true:
		var chunk: PackedByteArray = country.read_save_chunk(4096)
		if chunk.is_empty():
			break
		bytes.append_array(chunk)
	var ended: Dictionary = country.end_save()
	return bytes if bool(ended.get("ok", false)) else PackedByteArray()

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
