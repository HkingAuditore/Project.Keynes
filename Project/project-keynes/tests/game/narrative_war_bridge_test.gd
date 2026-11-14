extends SceneTree

## 战争桥的行为测试：国家军事快照 → 采样字段 → 三个条件。
##
## 跑法：
##   Godot --headless --path Project/project-keynes \
##     --script tests/game/narrative_war_bridge_test.gd --quit

const NarrativeContextSamplerScript = preload("res://scripts/narrative/narrative_context_sampler.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeStateProbeCatalogScript = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")
const NarrativeAiPromptBuilderScript = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")

var _checks := 0
var _failures := 0


class MilitaryStub extends RefCounted:
	var snapshot: Dictionary = {}
	var calls := 0

	func is_configured() -> bool:
		return true

	func country_snapshot(_country: int) -> Dictionary:
		calls += 1
		return snapshot


class MilitaryGeneratorStub extends RefCounted:
	var military := MilitaryStub.new()
	func get_military_facade():
		return military
	func get_country_facade():
		return null


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
	_test_unavailable()
	_test_probes()
	_test_prompt_context()
	print("=== narrative war bridge test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _generator_at_war() -> MilitaryGeneratorStub:
	var generator := MilitaryGeneratorStub.new()
	generator.military.snapshot = {
		"ok": true,
		"wars_active": 2,
		"wars": [
			{"war_id": 3, "score_q16": -40000, "attacker_losses": 80, "defender_losses": 40},
			{"war_id": 4, "score_q16": 12000, "attacker_losses": 0, "defender_losses": 0},
		],
		"soldiers_total": 520,
		"soldiers_in_armies": 300,
	}
	return generator


func _test_sampling() -> void:
	var generator := _generator_at_war()
	var ctx := NarrativeContextSamplerScript.sample_country_context(
		null, generator, 1, 30)
	_expect("military snapshot is read once", generator.military.calls == 1)
	_expect("war context is flagged available", bool(ctx.get("military_available", false)))
	_expect("war count comes from the snapshot", int(ctx.get("war_count", 0)) == 2
		and bool(ctx.get("at_war", false)))
	_expect("soldier totals are carried", int(ctx.get("soldiers_total", 0)) == 520
		and int(ctx.get("soldiers_in_armies", 0)) == 300)
	_expect("worst war score is kept", int(ctx.get("war_score_min_q16", 0)) == -40000)
	_expect("losses from all wars are summed", int(ctx.get("war_losses_total", 0)) == 120)


func _test_conditions() -> void:
	var Op = NarrativeConditionScript.Op
	var ctx := NarrativeContextSamplerScript.sample_country_context(
		null, _generator_at_war(), 1, 30)
	_expect("AT_WAR passes while fighting",
		NarrativeConditionScript.from_dict({"op": Op.AT_WAR, "bool_value": true}).evaluate(ctx))
	_expect("SOLDIERS_TOTAL_GTE compares the total",
		NarrativeConditionScript.from_dict({"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 500}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 600}).evaluate(ctx))
	_expect("WAR_GOING_BADLY passes at -0.61",
		NarrativeConditionScript.from_dict({"op": Op.WAR_GOING_BADLY, "bool_value": true}).evaluate(ctx))

	var winning := _generator_at_war()
	winning.military.snapshot["wars"] = [{"war_id": 5, "score_q16": 20000}]
	var win_ctx := NarrativeContextSamplerScript.sample_country_context(
		null, winning, 1, 30)
	_expect("WAR_GOING_BADLY rejects a winning war",
		not NarrativeConditionScript.from_dict({"op": Op.WAR_GOING_BADLY, "bool_value": true}).evaluate(win_ctx))

	var peace := _generator_at_war()
	peace.military.snapshot["wars_active"] = 0
	peace.military.snapshot["wars"] = []
	var peace_ctx := NarrativeContextSamplerScript.sample_country_context(
		null, peace, 1, 30)
	_expect("AT_WAR false passes after peace",
		NarrativeConditionScript.from_dict({"op": Op.AT_WAR, "bool_value": false}).evaluate(peace_ctx))


func _test_unavailable() -> void:
	var bare := {}
	var Op = NarrativeConditionScript.Op
	_expect("war conditions are false without military data",
		not NarrativeConditionScript.from_dict({"op": Op.AT_WAR, "bool_value": true}).evaluate(bare)
		and not NarrativeConditionScript.from_dict({"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 0}).evaluate(bare)
		and not NarrativeConditionScript.from_dict({"op": Op.WAR_GOING_BADLY, "bool_value": true}).evaluate(bare))

	var no_military := MilitaryGeneratorStub.new()
	no_military.military.snapshot = {"ok": false}
	var ctx := NarrativeContextSamplerScript.sample_country_context(
		null, no_military, 1, 30)
	_expect("an unavailable snapshot leaves defaults",
		not bool(ctx.get("military_available", true))
		and not bool(ctx.get("at_war", true))
		and int(ctx.get("war_count", -1)) == 0)


func _test_probes() -> void:
	var probes: Array = NarrativeStateProbeCatalogScript.build_default_probes()
	var ids := PackedStringArray()
	for probe in probes:
		ids.append(String(probe.state_id))
	_expect("war probes are registered",
		ids.has("state.war.homefront") and ids.has("state.war.defeat"))
	_expect("probe catalog grew to five", ids.size() == 5)


func _test_prompt_context() -> void:
	var ctx := {
		"era_index": 5,
		"era_name": "文艺复兴与航海时代",
		"family_available": true,
		"primary_family_name": "西街周氏",
		"primary_family_population_share": 0.32,
		"primary_family_prestige": 3,
		"primary_family_owned_buildings": 2,
		"primary_family_notable_people": 1,
		"primary_family_trait_names": PackedStringArray(["学术赞助", "商路人脉"]),
		"military_available": true,
		"at_war": true,
		"war_count": 1,
		"soldiers_total": 520,
		"soldiers_in_armies": 300,
		"war_score_min_q16": -40000,
		"war_losses_total": 120,
		"technologies": PackedStringArray(["tech.irrigation", "tech.gunpowder_weapons"]),
	}
	var messages := NarrativeAiPromptBuilderScript.build_messages(ctx, [], "")
	_expect("prompt builder still returns two messages", messages.size() == 2)
	if messages.size() < 2:
		return
	var user := String((messages[1] as Dictionary).get("content", ""))
	_expect("AI prompt carries the dominant family", user.contains("本地最大族")
		and user.contains("西街周氏"))
	_expect("AI prompt carries the war situation", user.contains("战事")
		and user.contains("在战"))
	_expect("AI prompt carries the technology list", user.contains("已掌握科技")
		and user.contains("tech.irrigation"))
