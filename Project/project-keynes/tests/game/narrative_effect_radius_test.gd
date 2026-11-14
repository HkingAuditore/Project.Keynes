extends SceneTree

## 叙事事件「范围效果」（`radius_cells` / `falloff`）契约测试。
##
## 覆盖六件事：
##   1. radius=0 完全向后兼容：只对当前格发一次 queue_apply；
##   2. radius=1 / falloff=0：当前格 + 1 环，各环同幅度；
##   3. radius=2 / falloff=1：当前格 + 1 环 + 2 环，100% / 60% / 30%，每格独立 source id；
##   4. from_dict/to_dict 往返保留字段，clamp_safe 把 radius=9 夹到 2、非 CITY_MODIFIER 归零；
##   5. describe() 在无 custom_label 时补「（周边 N 格）」，有 custom_label 时原样返回；
##   6. 采样器 nearby_owned_cells_r1/r2：只含己方陆地、去重、升序、2 环 BFS 不吞掉 1 环。
##
## 用假 modifier_facade 记录每次 queue_apply，不碰原生 ModifierRuntime。

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeEffectAdapterScript = preload("res://scripts/narrative/narrative_effect_adapter.gd")
const NarrativeContextSamplerScript = preload("res://scripts/narrative/narrative_context_sampler.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")

const CENTER := 10
const STAT_KEY := "economy.city.building.agriculture_output_factor"

var _checks := 0
var _failures := 0


class ModifierFacadeStub extends RefCounted:
	var calls: Array[Dictionary] = []
	var configured := true
	var next_request_id := 1
	var fail_cells: Dictionary = {}

	func is_configured() -> bool:
		return configured

	func queue_apply(definition_key: StringName, target: Dictionary, source: Dictionary,
			duration_days: int, initial_stacks: int, effective_day: int,
			producer_id: int, magnitude_q16: int) -> int:
		var cell := int(target.get("group_handle", -1))
		calls.append({
			"key": String(definition_key),
			"domain": int(target.get("domain", -1)),
			"scope": int(target.get("scope", -1)),
			"group_handle": cell,
			"source_type": int(source.get("type", 0)),
			"source_id": int(source.get("id", 0)),
			"duration_days": duration_days,
			"stacks": initial_stacks,
			"effective_day": effective_day,
			"producer_id": producer_id,
			"magnitude_q16": magnitude_q16,
		})
		if fail_cells.has(cell):
			return 0
		var rid := next_request_id
		next_request_id += 1
		return rid


class GeneratorStub extends RefCounted:
	var facade := ModifierFacadeStub.new()

	func get_modifier_facade():
		return facade


class ServiceStub extends RefCounted:
	var next_source_id := 900

	func allocate_modifier_source_id() -> int:
		var sid := next_source_id
		next_source_id += 1
		return sid


class FakeCell extends RefCounted:
	var index := 0
	var q := 0
	var r := 0
	var landform := LandformTypeScript.LF.PLAIN
	var terrain := 2
	var vegetation := 0
	var cover := 0
	var temperature := 18.0
	var moisture := 0.5
	var height := 0.3
	var snow_cover := 0.0
	var weather_precip := 0.0
	var has_river := false

	func _init(idx: int, lf: int) -> void:
		index = idx
		q = idx
		r = 0
		landform = lf


class FakeMap extends RefCounted:
	var cells: Array = []
	var adjacency: Dictionary = {}

	func cell_count() -> int:
		return cells.size()

	func cell_at(idx: int):
		if idx < 0 or idx >= cells.size():
			return null
		return cells[idx]

	func get_neighbors(cell) -> Array:
		var out: Array = []
		for n in adjacency.get(int(cell.index), PackedInt32Array()):
			out.append(cells[int(n)])
		return out


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("[FAIL] ", label)


func _pct(p: int) -> int:
	return roundi(65536.0 * float(p) / 100.0)


func _run() -> void:
	_test_radius_zero_keeps_single_cell()
	_test_radius_one_uniform()
	_test_radius_two_falloff()
	_test_per_cell_failure_does_not_stop_others()
	_test_serialization_and_clamp()
	_test_describe_label()
	_test_ai_validator_range_fields()
	_test_sampler_nearby_owned_cells()
	print("=== narrative effect radius test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ─── 1. radius=0：单格向后兼容 ─────────────────────────────────────────────

func _test_radius_zero_keeps_single_cell() -> void:
	var generator := GeneratorStub.new()
	var service := ServiceStub.new()
	var spec := _make_spec(0, 0)
	var ctx := _make_ctx()
	var res: Dictionary = NarrativeEffectAdapterScript.apply_effects(
		[spec], ctx, service, generator, 1, CENTER, 100, Callable())

	_expect("radius=0 sends exactly one queue_apply", generator.facade.calls.size() == 1)
	if generator.facade.calls.size() != 1:
		return
	var call: Dictionary = generator.facade.calls[0]
	_expect("radius=0 targets the current cell", int(call["group_handle"]) == CENTER)
	_expect("radius=0 keeps the original magnitude", int(call["magnitude_q16"]) == _pct(20))
	_expect("radius=0 keeps duration and stat key",
		int(call["duration_days"]) == 120 and String(call["key"]) == STAT_KEY)
	_expect("radius=0 result reports success", bool(res.get("ok", false)))
	var handles: PackedInt32Array = res["results"][0].get("handles", PackedInt32Array())
	_expect("radius=0 result keeps one handle", handles == PackedInt32Array([CENTER]))


# ─── 2. radius=1, falloff=0：当前格 + 1 环，同幅度 ─────────────────────────

func _test_radius_one_uniform() -> void:
	var generator := GeneratorStub.new()
	var service := ServiceStub.new()
	var spec := _make_spec(1, 0)
	var ctx := _make_ctx()
	NarrativeEffectAdapterScript.apply_effects(
		[spec], ctx, service, generator, 1, CENTER, 100, Callable())

	_expect("radius=1 sends 1+2 queue_apply calls", generator.facade.calls.size() == 3)
	if generator.facade.calls.size() != 3:
		return
	var handles := _handles_of(generator.facade.calls)
	_expect("radius=1 targets current cell then ring 1 in ascending order",
		handles == PackedInt32Array([CENTER, 2, 3]))
	var magnitudes := _magnitudes_of(generator.facade.calls)
	var uniform := true
	for m in magnitudes:
		if int(m) != _pct(20):
			uniform = false
	_expect("falloff=0 keeps every ring at the same magnitude", uniform)
	_expect("radius=1 gives each cell its own source id",
		_source_ids_unique(generator.facade.calls))


# ─── 3. radius=2, falloff=1：100% / 60% / 30% ──────────────────────────────

func _test_radius_two_falloff() -> void:
	var generator := GeneratorStub.new()
	var service := ServiceStub.new()
	var spec := _make_spec(2, 1)
	var ctx := _make_ctx()
	NarrativeEffectAdapterScript.apply_effects(
		[spec], ctx, service, generator, 1, CENTER, 100, Callable())

	_expect("radius=2 sends 1+2+3 queue_apply calls", generator.facade.calls.size() == 6)
	if generator.facade.calls.size() != 6:
		return
	var handles := _handles_of(generator.facade.calls)
	_expect("radius=2 targets current cell + r1 + r2",
		handles == PackedInt32Array([CENTER, 2, 3, 4, 5, 6]))

	var base := _pct(20)
	var mags := _magnitudes_of(generator.facade.calls)
	_expect("falloff=1 keeps the center at 100%",
		absi(int(mags[0]) - base) <= 1)
	_expect("falloff=1 sends ring 1 at 60%",
		absi(int(mags[1]) - roundi(float(base) * 0.6)) <= 1
		and absi(int(mags[2]) - roundi(float(base) * 0.6)) <= 1)
	_expect("falloff=1 sends ring 2 at 30%",
		absi(int(mags[3]) - roundi(float(base) * 0.3)) <= 1
		and absi(int(mags[4]) - roundi(float(base) * 0.3)) <= 1
		and absi(int(mags[5]) - roundi(float(base) * 0.3)) <= 1)
	_expect("radius=2 gives each cell its own source id",
		_source_ids_unique(generator.facade.calls))
	_expect("radius=2 keeps duration and stat key",
		int(generator.facade.calls[5]["duration_days"]) == 120
		and String(generator.facade.calls[5]["key"]) == STAT_KEY)


# ─── 3b. 单格失败不中断其余格 ───────────────────────────────────────────────

func _test_per_cell_failure_does_not_stop_others() -> void:
	var generator := GeneratorStub.new()
	generator.facade.fail_cells = {2: true}
	var service := ServiceStub.new()
	var spec := _make_spec(2, 0)
	var res: Dictionary = NarrativeEffectAdapterScript.apply_effects(
		[spec], _make_ctx(), service, generator, 1, CENTER, 100, Callable())

	_expect("one failing cell still queues every other cell",
		generator.facade.calls.size() == 6)
	var handles: PackedInt32Array = res["results"][0].get("handles", PackedInt32Array())
	_expect("failed cell is still reported in handles", handles.size() == 6)
	_expect("partial failure marks the effect result as not ok",
		not bool(res["results"][0].get("ok", true)))


# ─── 4. 序列化与 clamp ─────────────────────────────────────────────────────

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


# ─── 5b. AI 接口：解析并 clamp 范围字段 ────────────────────────────────────

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
	_expect("AI CITY_MODIFIER clamps radius to 2", int(city.get("radius_cells", -1)) == 2)
	_expect("AI CITY_MODIFIER clamps falloff to 1", int(city.get("falloff", -1)) == 1)
	_expect("AI CITY_MODIFIER fallback label states the range",
		String(city.get("custom_label", "")).contains("周边 2 环"))

	var country := _sanitize_first_effect({
		"kind": "COUNTRY_MODIFIER",
		"target_key": "ideology.country.output.agriculture_factor.gain",
		"magnitude_percent": 15,
		"duration_days": 90,
		"radius_cells": 2,
		"falloff": 1,
	}, cell_ctx)
	_expect("AI COUNTRY_MODIFIER forces radius/falloff to 0",
		int(country.get("radius_cells", -1)) == 0 and int(country.get("falloff", -1)) == 0)


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

func _test_sampler_nearby_owned_cells() -> void:
	var map := _build_fake_map()
	# 0 己方中心；1/2/5/6 己方陆地 1 环；3 外国陆地；4 己方水面；7/8/10/12 己方陆地 2 环；
	# 9 外国陆地；11 己方水面 2 环。
	var territory := PackedInt32Array([0, 1, 2, 4, 5, 6, 7, 8, 10, 11, 12])
	var ctx: Dictionary = NarrativeContextSamplerScript.sample_cell_context(
		0, {"territory_cells": territory}, map, null)

	var r1: PackedInt32Array = ctx.get("nearby_owned_cells_r1", PackedInt32Array())
	var r2: PackedInt32Array = ctx.get("nearby_owned_cells_r2", PackedInt32Array())
	_expect("sampler r1 keeps owned land neighbours only",
		r1 == PackedInt32Array([1, 2, 5, 6]))
	_expect("sampler r2 keeps owned land at distance 2 only",
		r2 == PackedInt32Array([7, 8, 10, 12]))
	_expect("sampler r1/r2 are disjoint (two rings, no double application)",
		_disjoint(r1, r2))
	_expect("sampler r2 is sorted ascending and deduplicated",
		_ascending_unique(r2))
	# 10 只能经 3（外国陆地）与 4（水面）到达：BFS 必须穿过非己方格继续扩到 2 环。
	_expect("sampler radius 2 BFS walks through foreign/water ring 1", r2.has(10))
	# 1 环结果不会因为 2 环 BFS 而丢失。
	_expect("radius 2 sampling still reports every ring 1 cell", r1.size() == 4)
	_expect("sampler excludes water even when owned",
		not r1.has(4) and not r2.has(11))
	_expect("sampler excludes foreign cells",
		not r1.has(3) and not r2.has(9))

	var empty_ctx: Dictionary = NarrativeContextSamplerScript.sample_cell_context(
		0, {"territory_cells": PackedInt32Array()}, map, null)
	var empty_r1: PackedInt32Array = empty_ctx.get(
		"nearby_owned_cells_r1", PackedInt32Array())
	var empty_r2: PackedInt32Array = empty_ctx.get(
		"nearby_owned_cells_r2", PackedInt32Array())
	_expect("empty territory yields empty r1", empty_r1.is_empty())
	_expect("empty territory yields empty r2", empty_r2.is_empty())


func _build_fake_map() -> FakeMap:
	var map := FakeMap.new()
	for i in range(13):
		map.cells.append(FakeCell.new(i, LandformTypeScript.LF.PLAIN))
	map.cells[4].landform = LandformTypeScript.LF.OCEAN
	map.cells[11].landform = LandformTypeScript.LF.LAKE
	map.adjacency = {
		0: PackedInt32Array([1, 2, 3, 4, 5, 6]),
		1: PackedInt32Array([0, 2, 6, 7, 8]),
		2: PackedInt32Array([0, 1, 3, 8, 9]),
		3: PackedInt32Array([0, 2, 4, 9, 10]),
		4: PackedInt32Array([0, 3, 5, 10, 11]),
		5: PackedInt32Array([0, 4, 6, 11, 12]),
		6: PackedInt32Array([0, 5, 1, 12, 7]),
		7: PackedInt32Array([1, 6]),
		8: PackedInt32Array([1, 2]),
		9: PackedInt32Array([2, 3]),
		10: PackedInt32Array([3, 4]),
		11: PackedInt32Array([4, 5]),
		12: PackedInt32Array([5, 6]),
	}
	return map


# ─── helpers ──────────────────────────────────────────────────────────────

func _make_spec(radius: int, falloff: int) -> NarrativeEffectSpec:
	return NarrativeEffectSpecScript.from_dict({
		"kind": NarrativeEffectSpecScript.Kind.CITY_MODIFIER,
		"target_key": STAT_KEY,
		"magnitude_q16": _pct(20),
		"duration_days": 120,
		"radius_cells": radius,
		"falloff": falloff,
	})


func _make_ctx() -> Dictionary:
	return {
		"nearby_owned_cells_r1": PackedInt32Array([2, 3]),
		"nearby_owned_cells_r2": PackedInt32Array([4, 5, 6]),
	}


func _handles_of(calls: Array[Dictionary]) -> PackedInt32Array:
	var out := PackedInt32Array()
	for call in calls:
		out.append(int(call["group_handle"]))
	return out


func _magnitudes_of(calls: Array[Dictionary]) -> PackedInt32Array:
	var out := PackedInt32Array()
	for call in calls:
		out.append(int(call["magnitude_q16"]))
	return out


func _source_ids_unique(calls: Array[Dictionary]) -> bool:
	var seen := {}
	for call in calls:
		var sid := int(call["source_id"])
		if seen.has(sid):
			return false
		seen[sid] = true
	return true


func _disjoint(a: PackedInt32Array, b: PackedInt32Array) -> bool:
	for v in a:
		if b.has(v):
			return false
	return true


func _ascending_unique(values: PackedInt32Array) -> bool:
	for i in range(1, values.size()):
		if int(values[i]) <= int(values[i - 1]):
			return false
	return true
