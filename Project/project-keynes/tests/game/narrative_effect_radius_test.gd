extends "res://tests/support/runtime_narrative_scenario.gd"

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const STAT_KEY := "economy.city.building.agriculture_output_factor"
const CENTER := 4739


func _run() -> void:
	_test_serialization_and_clamp()
	_test_describe_label()
	_test_ai_validator_range_fields()
	await _test_native_radius()
	print("narrative effect radius: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _pct(p: int) -> int:
	return int(round(float(p) * 65536.0 / 100.0))


func _test_native_radius() -> void:
	var definitions := {}
	var schedule := []
	for radius in range(3):
		var id := "evt.test.radius_%d" % radius
		definitions[id] = _story_fixture_event(id, [{
			"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER, "target_key": STAT_KEY,
			"magnitude_q16": _pct(6), "duration_days": 20,
			"radius_cells": radius, "falloff": int(radius == 2),
		}])
		schedule.append({"event_id": id, "cell_idx": CENTER, "due_day": 3 + radius * 2})
	if await _start_story({"dynamic_events_by_id": definitions, "scheduled_events": schedule}):
		await _check_native_radius()
	await _close_story()


func _claim_rings() -> Array[Dictionary]:
	var map := story_host.current_map()
	var neighbors := map.neighbor_indices_packed()
	var seen := {int(story_cell): true}
	var frontier := [story_cell]
	var rings: Array[Dictionary] = []
	var country = story_host.get_generator().get_country_facade()
	for ring in range(2):
		var layer := {}
		for cell in frontier:
			for dir in range(6):
				var neighbor: int = neighbors[cell * 6 + dir]
				if neighbor < 0 or map.is_water_arr[neighbor] != 0 or seen.has(neighbor):
					continue
				seen[neighbor] = true
				layer[neighbor] = true
				var transfer: Dictionary = country.transfer_territory(neighbor,
					story_player, 2, 910000 + neighbor, true)
				_expect("radius fixture territory command accepted", bool(transfer.get("ok", false)))
		frontier = layer.keys()
		rings.append(layer)
	return rings


func _check_native_radius() -> void:
	_expect("the radius center is the player's opening cell", story_cell == CENTER)
	var rings := _claim_rings()
	_expect("fixture covers both rings", not rings[0].is_empty() and not rings[1].is_empty())
	for radius in range(3):
		var day := 3 + 2 * radius
		if not await _advance_story(day):
			return
		_choose_story(0)
		if not await _advance_story(day + 1):
			return
		var expected := {int(story_cell): _pct(6)}
		var scales := [39322, 19661]
		for ring in range(radius):
			for cell in rings[ring]:
				expected[cell] = (_pct(6) * scales[ring] + 32768) >> 16 if radius == 2 else _pct(6)
		var list: Dictionary = story_ext.list_modifiers(2, 0, STAT_KEY)
		var actual := {}
		var sources := {}
		for index in range(list.get("definition_keys", PackedStringArray()).size()):
			if list.applied_days[index] != day + 1 or list.source_types[index] != 0x4e415252:
				continue
			actual[list.group_handles[index]] = list.magnitude_q16[index]
			sources[list.source_ids[index]] = true
		_expect("radius %d targets precisely the owned land in range" % radius, actual == expected)
		_expect("each modifier of radius %d has its own source" % radius, sources.size() == actual.size())


func _test_serialization_and_clamp() -> void:
	var spec := NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"target_key": STAT_KEY,
		"magnitude_q16": _pct(6),
		"duration_days": 540,
		"radius_cells": 2,
		"falloff": 1,
	})
	_expect("from_dict reads radius_cells", int(spec.radius_cells) == 2)
	_expect("from_dict reads falloff", int(spec.falloff) == 1)
	var d: Dictionary = spec.to_dict()
	_expect("to_dict writes radius_cells", int(d.get("radius_cells", -1)) == 2)
	_expect("to_dict writes falloff", int(d.get("falloff", -1)) == 1)
	var back := NarrativeEffectSpecScript.from_dict(d)
	_expect("round-trip keeps radius_cells and falloff",
		int(back.radius_cells) == 2 and int(back.falloff) == 1)

	var risky := NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"radius_cells": 9,
		"falloff": 7,
	})
	risky.clamp_safe()
	_expect("clamp_safe caps radius at 2", int(risky.radius_cells) == 2)
	_expect("clamp_safe caps falloff at 1", int(risky.falloff) == 1)

	var country := NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER,
		"radius_cells": 2,
		"falloff": 1,
	})
	country.clamp_safe()
	_expect("non CITY_MODIFIER forces radius/falloff to 0",
		int(country.radius_cells) == 0 and int(country.falloff) == 0)

	var legacy := NarrativeEffectSpecScript.from_dict({"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER})
	legacy.clamp_safe()
	_expect("legacy effects without the fields default to radius=0/falloff=0",
		int(legacy.radius_cells) == 0 and int(legacy.falloff) == 0)


# ─── 5. describe() 标签 ────────────────────────────────────────────────────

func _test_describe_label() -> void:
	var ranged := NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"target_key": STAT_KEY,
		"magnitude_q16": _pct(4),
		"duration_days": 540,
		"radius_cells": 2,
	})
	var text := ranged.describe()
	_expect("describe appends the range suffix", text.contains("周边 2 环"))
	_expect("describe still carries the percentage and duration",
		text.contains("+4%") and text.contains("540 日"))

	var single := NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"target_key": STAT_KEY,
		"magnitude_q16": _pct(4),
		"duration_days": 540,
		"radius_cells": 0,
	})
	_expect("radius=0 describe does not mention a range",
		not single.describe().contains("周边"))

	var custom := NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"target_key": STAT_KEY,
		"magnitude_q16": _pct(4),
		"duration_days": 540,
		"radius_cells": 2,
		"custom_label": "渠口周边 2 环农业 +4%，540 日",
	})
	_expect("custom_label wins over the generated range suffix",
		custom.describe() == "渠口周边 2 环农业 +4%，540 日")


# ─── 5b. AI 接口：解析范围字段，范围约束由执行器结算 ────────────────────────

func _test_ai_validator_range_fields() -> void:
	var cell_ctx := {"day": 320, "cell_idx": CENTER, "treasury_cash": 10000}
	var city := _sanitize_first_effect({
		"kind": "CITY_MODIFIER",
		"target_key": "economy.city.building.agriculture_output_factor",
		"magnitude_percent": 15,
		"duration_days": 90,
		"radius_cells": 9,
		"falloff": 5,
	}, cell_ctx)
	_expect("AI CITY_MODIFIER sends the requested radius", int(city.get("radius_cells", -1)) == 9)
	_expect("AI CITY_MODIFIER sends the requested falloff", int(city.get("falloff", -1)) == 5)
	_expect("AI CITY_MODIFIER leaves the final radius label for settlement",
		String(city.get("custom_label", "?")).is_empty())

	var country := _sanitize_first_effect({
		"kind": "COUNTRY_MODIFIER",
		"target_key": "ideology.country.output.agriculture_factor.gain",
		"magnitude_percent": 15,
		"duration_days": 90,
		"radius_cells": 2,
		"falloff": 1,
	}, cell_ctx)
	_expect("AI COUNTRY_MODIFIER forwards radius and falloff unchanged",
		int(country.get("radius_cells", -1)) == 2 and int(country.get("falloff", -1)) == 1)


func _sanitize_first_effect(effect: Dictionary, cell_ctx: Dictionary) -> Dictionary:
	var raw := JSON.stringify({
		"title": "田渠议",
		"body_text": "本地农户请开田渠。",
		"options": [{
			"text": "准予开渠",
			"outcomes": [{
				"probability_percent": 100,
				"outcome_title": "渠成",
				"effects": [effect],
			}],
		}],
	})
	var res := NarrativeAiValidatorScript.validate_and_sanitize(raw, cell_ctx)
	if not bool(res.get("ok", false)):
		return {}
	var options: Array = (res["event_dict"] as Dictionary).get("options", [])
	if options.is_empty():
		return {}
	var outcomes: Array = (options[0] as Dictionary).get("outcomes", [])
	if outcomes.is_empty():
		return {}
	var effects: Array = (outcomes[0] as Dictionary).get("effects", [])
	return effects[0] if not effects.is_empty() else {}


# ─── 6. 采样器：己方陆地邻居池 ─────────────────────────────────────────────
