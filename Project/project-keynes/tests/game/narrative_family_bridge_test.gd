extends SceneTree

## 家族桥接的行为测试：采样、四个条件、两个效果、无族兜底、占位符。
##
## 跑法：
##   Godot --headless --path Project/project-keynes \
##     --script tests/game/narrative_family_bridge_test.gd --quit

const NarrativeContextSamplerScript = preload("res://scripts/narrative/narrative_context_sampler.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeEffectAdapterScript = preload("res://scripts/narrative/narrative_effect_adapter.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")

const CELL := 11

var _checks := 0
var _failures := 0


class FamilyEconomyStub extends RefCounted:
	var snapshot_calls := 0
	var trait_calls: Array[Dictionary] = []
	var family_rows: Array[Dictionary] = []

	func is_configured() -> bool:
		return true

	func population_cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "population": 60, "composite_satisfaction_q16": 42000}

	func settlement_display_name(_cell: int) -> String:
		return "测试邑"

	func family_cell_snapshot(_cell: int, _offset: int, _limit: int) -> Dictionary:
		snapshot_calls += 1
		if family_rows.is_empty():
			return {"ok": true, "cell_idx": CELL, "family_handles": PackedInt64Array()}
		var handles := PackedInt64Array()
		var names := PackedStringArray()
		var surnames := PackedStringArray()
		var disambiguators := PackedInt32Array()
		var populations := PackedInt64Array()
		var prestige_levels := PackedInt32Array()
		var prestige_scores := PackedInt32Array()
		var owned := PackedInt64Array()
		var notables := PackedInt32Array()
		for row in family_rows:
			handles.append(int(row.get("handle", 0)))
			names.append(String(row.get("name", "")))
			surnames.append(String(row.get("surname", "")))
			disambiguators.append(int(row.get("disambiguator", 0)))
			populations.append(int(row.get("population", 0)))
			prestige_levels.append(int(row.get("prestige", 0)))
			prestige_scores.append(int(row.get("score", 0)))
			owned.append(int(row.get("owned", 0)))
			notables.append(int(row.get("notables", 0)))
		return {
			"ok": true, "cell_idx": CELL,
			"family_handles": handles, "family_names": names, "surnames": surnames,
			"surname_disambiguators": disambiguators, "populations": populations,
			"prestige_levels": prestige_levels, "prestige_scores": prestige_scores,
			"owned_buildings": owned, "notable_person_counts": notables,
		}

	func get_family_traits(_family_handle: int) -> Dictionary:
		return {
			"ok": true,
			"trait_keys": PackedStringArray(["i001_agrarian", "j004_craft"]),
			"display_names": PackedStringArray(["重农", "工匠世家"]),
		}

	func queue_family_trait_mutation(family_handle: int, operation, trait_key: StringName,
			strength_q16: int, effective_day: int, priority: int, sequence: int) -> int:
		trait_calls.append({
			"handle": family_handle, "operation": String(operation),
			"trait": String(trait_key), "strength": strength_q16,
			"day": effective_day, "priority": priority, "sequence": sequence,
		})
		return trait_calls.size()


class FamilyGeneratorStub extends RefCounted:
	var economy := FamilyEconomyStub.new()
	func get_economy_facade():
		return economy


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("[FAIL] ", label)


func _run() -> void:
	_test_sampling()
	_test_conditions()
	_test_effects()
	_test_placeholder()
	print("=== narrative family bridge test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _generator_with_families() -> FamilyGeneratorStub:
	var generator := FamilyGeneratorStub.new()
	generator.economy.family_rows = [
		{"handle": 55, "name": "西街周氏", "surname": "周", "population": 30,
			"prestige": 3, "score": 48000, "owned": 2, "notables": 1},
		{"handle": 44, "name": "南门李氏", "surname": "李", "population": 12,
			"prestige": 1, "score": 20000, "owned": 0, "notables": 0},
	]
	return generator


func _test_sampling() -> void:
	var generator := _generator_with_families()
	var ctx := NarrativeContextSamplerScript.sample_cell_context(
		CELL, {}, null, generator, null, {}, true)
	_expect("family context is flagged available", bool(ctx.get("family_available", false)))
	_expect("primary family is the first snapshot row (population desc)",
		int(ctx.get("primary_family_handle", 0)) == 55)
	_expect("family name comes from the snapshot", String(ctx.get("primary_family_name", "")) == "西街周氏")
	_expect("prestige is per-cell", int(ctx.get("primary_family_prestige", -1)) == 3)
	_expect("population share divides by cell population",
		absf(float(ctx.get("primary_family_population_share", 0.0)) - 0.5) < 0.001)
	_expect("owned buildings and notables are carried",
		int(ctx.get("primary_family_owned_buildings", 0)) == 2
		and int(ctx.get("primary_family_notable_people", 0)) == 1)
	_expect("family traits are sampled once",
		(ctx.get("primary_family_trait_keys", PackedStringArray()) as PackedStringArray).has("i001_agrarian")
		and (ctx.get("primary_family_trait_names", PackedStringArray()) as PackedStringArray).has("重农"))
	_expect("family count keeps the page size", int(ctx.get("family_count", 0)) == 2)

	# 入队汇总路径不取家族快照。
	var lean_generator := _generator_with_families()
	var lean := NarrativeContextSamplerScript.sample_cell_context(
		CELL, {}, null, lean_generator, null, {}, false)
	_expect("summary sampling skips the family snapshot",
		not bool(lean.get("family_available", true))
		and lean_generator.economy.snapshot_calls == 0)

	# 没有族时保持默认值，不崩。
	var empty_generator := FamilyGeneratorStub.new()
	var empty := NarrativeContextSamplerScript.sample_cell_context(
		CELL, {}, null, empty_generator, null, {}, true)
	_expect("a familyless cell stays unavailable",
		not bool(empty.get("family_available", true))
		and int(empty.get("primary_family_handle", -1)) == 0)


func _family_ctx() -> Dictionary:
	var generator := _generator_with_families()
	return NarrativeContextSamplerScript.sample_cell_context(
		CELL, {}, null, generator, null, {}, true)


func _test_conditions() -> void:
	var Op = NarrativeConditionScript.Op
	var ctx := _family_ctx()
	_expect("HAS_NOTABLE_FAMILY accepts a prestigious family",
		NarrativeConditionScript.from_dict({"op": Op.HAS_NOTABLE_FAMILY, "bool_value": true}).evaluate(ctx))
	_expect("FAMILY_PRESTIGE_GTE reads the per-cell level",
		NarrativeConditionScript.from_dict({"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4}).evaluate(ctx))
	_expect("FAMILY_POP_SHARE_GTE compares the share",
		NarrativeConditionScript.from_dict({"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.5}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.6}).evaluate(ctx))
	_expect("FAMILY_OWNS_BUILDINGS_GTE counts family buildings",
		NarrativeConditionScript.from_dict({"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 3}).evaluate(ctx))
	_expect("HAS_FAMILY_TRAIT matches an existing trait",
		NarrativeConditionScript.from_dict({"op": Op.HAS_FAMILY_TRAIT,
			"target_key": "i001_agrarian", "bool_value": true}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.HAS_FAMILY_TRAIT,
			"target_key": "i029_coastal", "bool_value": true}).evaluate(ctx))
	_expect("HAS_FAMILY_TRAIT can be negated",
		NarrativeConditionScript.from_dict({"op": Op.HAS_FAMILY_TRAIT,
			"target_key": "i029_coastal", "bool_value": false}).evaluate(ctx))

	var bare := {}
	_expect("family conditions are false without family data",
		not NarrativeConditionScript.from_dict({"op": Op.HAS_NOTABLE_FAMILY, "bool_value": true}).evaluate(bare)
		and not NarrativeConditionScript.from_dict({"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 0}).evaluate(bare)
		and not NarrativeConditionScript.from_dict({"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.0}).evaluate(bare)
		and not NarrativeConditionScript.from_dict({"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 0}).evaluate(bare)
		and not NarrativeConditionScript.from_dict({"op": Op.HAS_FAMILY_TRAIT,
			"target_key": "i001_agrarian", "bool_value": true}).evaluate(bare))


func _test_effects() -> void:
	var Kind = NarrativeEffectSpecScript.Kind
	var generator := _generator_with_families()
	var ctx := {
		"cell_idx": CELL,
		"primary_family_handle": 55,
		"primary_family_name": "西街周氏",
	}
	var result := NarrativeEffectAdapterScript.apply_effects([
		{
			"kind": Kind.GRANT_FAMILY_TRAIT,
			"target_key": "i005_knowledge",
			"magnitude_q16": 65536,
			"duration_days": 999,
			"custom_label": "本地最大族「{family_name}」获特质「学术赞助」，永久",
		},
		{
			"kind": Kind.REMOVE_FAMILY_TRAIT,
			"target_key": "j016_shrewd",
			"custom_label": "本地最大族「{family_name}」失去特质「精明」",
		},
	], ctx, null, generator, 1, CELL, 20, Callable())

	var calls: Array[Dictionary] = generator.economy.trait_calls
	_expect("two family trait commands are dispatched", calls.size() == 2)
	if calls.size() == 2:
		_expect("grant targets the sampled family",
			int(calls[0]["handle"]) == 55 and String(calls[0]["operation"]) == "grant"
			and String(calls[0]["trait"]) == "i005_knowledge")
		_expect("grant clamps the strength into the trait band",
			int(calls[0]["strength"]) == 65536 and int(calls[0]["day"]) == 20)
		_expect("remove targets the same family",
			int(calls[1]["handle"]) == 55 and String(calls[1]["operation"]) == "remove"
			and String(calls[1]["trait"]) == "j016_shrewd")
	var summaries: PackedStringArray = result.get("applied_summaries", PackedStringArray())
	_expect("labels substitute the family name",
		summaries.has("本地最大族「西街周氏」获特质「学术赞助」，永久")
		and summaries.has("本地最大族「西街周氏」失去特质「精明」"))

	# 没有族时：不调用 facade，标记 simulated。
	var empty_generator := FamilyGeneratorStub.new()
	var empty_result := NarrativeEffectAdapterScript.apply_effects([
		{"kind": Kind.GRANT_FAMILY_TRAIT, "target_key": "i005_knowledge",
			"custom_label": "本地最大族获特质「学术赞助」，永久"},
	], {"cell_idx": CELL}, null, empty_generator, 1, CELL, 20, Callable())
	var empty_results: Array = empty_result.get("results", [])
	_expect("no family means no command and a simulated result",
		empty_generator.economy.trait_calls.is_empty()
		and empty_results.size() == 1 and bool(empty_results[0].get("simulated", false)))

	# 存档往返：新 Kind 只是追加的整数，旧字段不变。
	for kind in [Kind.GRANT_FAMILY_TRAIT, Kind.REMOVE_FAMILY_TRAIT]:
		var spec = NarrativeEffectSpecScript.from_dict({
			"kind": kind, "target_key": "i005_knowledge", "magnitude_q16": 65536,
			"duration_days": 1, "custom_label": "本地最大族获特质「学术赞助」，永久",
		})
		var restored = NarrativeEffectSpecScript.from_dict(spec.to_dict())
		_expect("family effect kind %d survives to_dict/from_dict" % kind,
			int(restored.kind) == int(kind)
			and String(restored.target_key) == "i005_knowledge"
			and int(restored.magnitude_q16) == 65536)


func _test_placeholder() -> void:
	var ctx := {"primary_family_name": "西街周氏"}
	_expect("format_label fills {family_name}",
		NarrativeEffectSpecScript.format_label("「{family_name}」出钱", ctx) == "「西街周氏」出钱")
	_expect("format_text fills {family_name}",
		NarrativeEventDefinitionScript.format_text("{family_name}的人来了", ctx) == "西街周氏的人来了")
	_expect("missing family falls back to a readable word",
		NarrativeEffectSpecScript.format_label("{family_name}出钱", {}) == "本地大族出钱")
