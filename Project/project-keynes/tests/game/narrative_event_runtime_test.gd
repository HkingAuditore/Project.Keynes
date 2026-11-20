extends SceneTree

const NarrativeRngScript = preload("res://scripts/narrative/narrative_rng.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeWeightRuleScript = preload("res://scripts/narrative/narrative_weight_rule.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeOutcomeScript = preload("res://scripts/narrative/narrative_outcome.gd")
const NarrativeOptionScript = preload("res://scripts/narrative/narrative_option.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEventFlowScript = preload("res://scripts/narrative/narrative_event_flow.gd")
const NarrativeAiPromptBuilderScript = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")
const NarrativeStateProbeScript = preload("res://scripts/narrative/narrative_state_probe.gd")
const NarrativeStateProbeCatalogScript = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const NarrativeEffectAdapterScript = preload("res://scripts/narrative/narrative_effect_adapter.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

var _checks := 0
var _failures := 0

class CashEconomyStub extends RefCounted:
	var transfers: Array[Dictionary] = []
	var population_deltas: Array[Dictionary] = []
	var details_requested := false
	func is_configured() -> bool: return true
	func population_cell_snapshot(_cell: int, include_details: bool = true) -> Dictionary:
		details_requested = include_details
		if not include_details:
			return {"population": 25, "funds": 8000}
		return {"handles": PackedInt64Array([101, 102]),
			"populations": PackedInt64Array([5, 20]), "funds": PackedInt64Array([3000, 5000])}
	func transfer_country_cash_to_cohort(country: int, cohort: int, amount: int,
			day: int, sequence: int) -> Dictionary:
		transfers.append({"country": country, "cohort": cohort, "amount": amount,
			"day": day, "sequence": sequence})
		return {"ok": true}
	func add_population(cohort: int, amount: int, day: int, sequence: int) -> Dictionary:
		population_deltas.append({"cohort": cohort, "amount": amount,
			"day": day, "sequence": sequence})
		return {"ok": true, "settled_value": amount}

class CashCountryStub extends RefCounted:
	func treasury_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "cash": 100000}

class CashGeneratorStub extends RefCounted:
	var economy := CashEconomyStub.new()
	var country := CashCountryStub.new()
	func get_economy_facade(): return economy
	func get_country_facade(): return country

class FactBusStub extends RefCounted:
	var batch: Dictionary = {"count": 0}
	func is_available() -> bool:
		return true
	func poll_events(_consumer, _max_events, _event_type, _auto_ack, _after_event_id) -> Dictionary:
		return batch

class FactGeneratorStub extends RefCounted:
	var bus := FactBusStub.new()
	func get_gameplay_event_bus(): return bus
	func get_country_facade(): return null
	func get_economy_facade(): return null

class StateCountryStub extends RefCounted:
	var territory := PackedInt32Array([5])
	func snapshot(_country: int) -> Dictionary:
		return {"ok": true, "display_name": "测试国", "territory_cells": territory,
			"technology_ids": PackedStringArray()}
	func current_era_index(_country: int) -> int:
		return 1
	func treasury_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "cash": 50000, "good_ids": PackedStringArray(),
			"quantities": PackedInt64Array()}

class StateEconomyStub extends RefCounted:
	var grain_price := 200
	var base_price := 100
	func is_configured() -> bool:
		return true
	func settlement_display_name(_cell: int) -> String:
		return "测试邑"
	func population_cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "population": 30, "composite_satisfaction_q16": 40000}
	func population_cell_snapshot(_cell: int, _include_details: bool) -> Dictionary:
		return {"handles": PackedInt64Array([11]), "populations": PackedInt64Array([30]),
			"funds": PackedInt64Array([9000])}
	func building_cell_snapshot(_cell: int) -> Dictionary:
		return {}
	func market_cell_snapshot(_cell: int) -> Dictionary:
		return {"good_stable_ids": PackedStringArray(["grain"]),
			"stocks": PackedInt64Array([20]),
			"prices": PackedInt64Array([grain_price]),
			"base_prices": PackedInt64Array([base_price])}

class StateGeneratorStub extends RefCounted:
	var country := StateCountryStub.new()
	var economy := StateEconomyStub.new()
	func get_country_facade(): return country
	func get_economy_facade(): return economy


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_deterministic_rng()
	_test_frost_cash_transfer()
	_test_shared_event_quota()
	_test_multidimensional_conditions_and_catalog()
	_test_event_chain_and_weight_bias_and_chronicle()
	_test_save_restore_roundtrip()
	_test_ai_sandbox_and_image_cache()
	_test_ai_fact_trigger_and_staleness()
	_test_state_probe_and_ai_pool()
	_test_ui_dialog_and_chronicle_panel()
	_test_player_controller_integration()
	_test_population_effect_lever()
	print("=== narrative event runtime test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_frost_cash_transfer() -> void:
	var generator := CashGeneratorStub.new()
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(generator, null, null, null, 1, 98765, catalog)
	var offer := service.enqueue_event_offer(catalog.get_event(&"evt.climate.bitter_frost"), 1828, 500)
	_expect("event trigger scan keeps summary-only population query", not generator.economy.details_requested)
	var result := service.choose_option(int(offer.offer_id), int(offer.offer_generation), 0, 501)
	_expect("frost aid choice resolves and requests cohort details",
		bool(result.get("ok", false)) and generator.economy.details_requested)
	_expect("frost aid submits a real transfer instead of simulated success", generator.economy.transfers.size() == 1)
	if generator.economy.transfers.size() == 1:
		var transfer: Dictionary = generator.economy.transfers[0]
		_expect("frost aid sends 3 percent to the largest local cohort at the effective day",
			transfer.country == 1 and transfer.cohort == 102 and transfer.amount == 3000 and transfer.day == 501)

## 「收留游民」「编入户籍」这类文案必须真的改人口。
## 这条杠杆之前不存在，作者只能拿 agriculture/birth 糊弄，于是字面在收人、数值上空转。
func _test_population_effect_lever() -> void:
	var Kind = NarrativeEffectSpecScript.Kind
	# ── 文案：有符号，人数与占比两种说法 ──
	var plus := NarrativeEffectSpecScript.from_dict({
		"kind": Kind.ADD_POPULATION, "int_value": 12, "duration_days": 1})
	plus.clamp_safe()
	_expect("population effect prints a signed head count",
		plus.describe() == "本地人口 +12 人")
	var minus := NarrativeEffectSpecScript.from_dict({
		"kind": Kind.ADD_POPULATION, "int_value": -30, "duration_days": 1})
	minus.clamp_safe()
	_expect("negative population survives clamping instead of collapsing to zero",
		minus.int_value == -30 and minus.describe() == "本地人口 -30 人")
	var pct := NarrativeEffectSpecScript.from_dict({
		"kind": Kind.ADD_POPULATION, "ratio_bp": -2000, "duration_days": 1})
	pct.clamp_safe()
	_expect("population ratio keeps its sign and reads as a percentage",
		pct.ratio_bp == -2000 and pct.describe() == "本地人口 -20.0%")
	var runaway := NarrativeEffectSpecScript.from_dict({
		"kind": Kind.ADD_POPULATION, "int_value": 99999, "ratio_bp": 9000,
		"duration_days": 1})
	runaway.clamp_safe()
	_expect("runaway population magnitudes clamp to the allowed band",
		runaway.int_value == 5000 and runaway.ratio_bp == 5000)
	var unknown := NarrativeEffectSpecScript.from_dict({
		"kind": 99, "int_value": 10, "duration_days": 1})
	unknown.clamp_safe()
	_expect("unknown future kind degrades to a harmless city modifier, not a family trait removal",
		unknown.kind == Kind.CITY_MODIFIER)

	# ── 结算：比例按本地现有人口折算，真调 add_population ──
	var generator := CashGeneratorStub.new()
	var ctx := {
		"population": 200,
		"primary_cohort_handle": 102,
		"settlement_name": "测试邑",
	}
	var seq := func() -> int: return 1
	NarrativeEffectAdapterScript.apply_effects(
		[{"kind": Kind.ADD_POPULATION, "ratio_bp": 1000, "duration_days": 1,
			"custom_label": "本地人口 +10%"}],
		ctx, null, generator, 1, 7, 800, seq)
	_expect("population ratio resolves against local head count and reaches the economy facade",
		generator.economy.population_deltas.size() == 1
		and int(generator.economy.population_deltas[0]["amount"]) == 20
		and int(generator.economy.population_deltas[0]["cohort"]) == 102)
	_expect("applied population is written back into the cell context",
		int(ctx.get("population", 0)) == 220)

	# 迁出同样走同一条路径，不会被「只许为正」的老夹紧吃掉。
	generator.economy.population_deltas.clear()
	ctx["population"] = 200
	NarrativeEffectAdapterScript.apply_effects(
		[{"kind": Kind.ADD_POPULATION, "ratio_bp": -1500, "duration_days": 1}],
		ctx, null, generator, 1, 7, 800, seq)
	_expect("population outflow is dispatched as a negative delta",
		generator.economy.population_deltas.size() == 1
		and int(generator.economy.population_deltas[0]["amount"]) == -30)

	# 四十口的小聚落按 1% 会算成 0.4 人：保底搬动一人，否则「收留」是空操作。
	generator.economy.population_deltas.clear()
	ctx["population"] = 40
	NarrativeEffectAdapterScript.apply_effects(
		[{"kind": Kind.ADD_POPULATION, "ratio_bp": 100, "duration_days": 1}],
		ctx, null, generator, 1, 7, 800, seq)
	_expect("a tiny settlement still moves at least one person",
		generator.economy.population_deltas.size() == 1
		and int(generator.economy.population_deltas[0]["amount"]) == 1)

	# 没有 cohort 句柄时静默模拟，不炸，也不写坏数据。
	generator.economy.population_deltas.clear()
	var res: Dictionary = NarrativeEffectAdapterScript.apply_effects(
		[{"kind": Kind.ADD_POPULATION, "int_value": 5, "duration_days": 1}],
		{"population": 200, "primary_cohort_handle": 0}, null, generator, 1, 7, 800, seq)
	_expect("missing cohort degrades to a simulated no-op",
		generator.economy.population_deltas.is_empty()
		and bool((res.get("results", [{}])[0] as Dictionary).get("simulated", false)))

	# ── 内容契约：字面收人的选项必须带真实人口效果 ──
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var required := {
		&"evt.people.gruel_aftermath": &"register_as_tenants",
		&"evt.war.refugees": &"open_the_gate",
		&"evt.war.army_lost": &"take_the_survivors_in",
		&"evt.war.aftermath": &"settle_the_fields",
	}
	for event_id in required.keys():
		var def = catalog.get_event(event_id)
		if def == null:
			_expect("event %s exists" % event_id, false)
			continue
		var found := false
		for opt in def.options:
			if opt == null or opt.option_id != required[event_id]:
				continue
			for outcome in opt.outcomes:
				if outcome == null:
					continue
				for eff in outcome.effects:
					if eff != null and int(eff.kind) == int(Kind.ADD_POPULATION):
						found = true
		_expect("option %s/%s really changes local population" % [event_id, required[event_id]],
			found)

	# 迁族：写「走一半人」就不能只掉出生率。
	var migration = catalog.get_event(&"evt.family2.migration")
	var outflow_found := false
	if migration != null:
		for opt in migration.options:
			if opt == null or opt.option_id != &"let_them_go":
				continue
			for outcome in opt.outcomes:
				for eff in outcome.effects:
					if eff != null and int(eff.kind) == int(Kind.ADD_POPULATION) \
							and eff.ratio_bp < 0:
						outflow_found = true
	_expect("clan migration 'let them go' carries a real population outflow", outflow_found)

	# ── AI 链路：模型写 ADD_POPULATION 必须过白名单，负号不能被「只做加项」的夹紧抹掉 ──
	var ai_ctx := {
		"settlement_name": "测试邑", "population": 120,
		"primary_profession_name": "农户", "day": 300,
	}
	var ai_raw := {
		"title": "城下的人",
		"body_text": "北边来的人堵在城门口，说要进去。守门的把门闩抬起来，又放下。",
		"ai_visual_prompt": "refugees crowding a city gate at dusk",
		"tags": ["people"],
		"options": [{
			"text": "开门收容",
			"outcomes": [{
				"probability_percent": 100,
				"outcome_title": "城门开了",
				"outcome_narrative": "城门开了一条缝，人挤着进来，庙里铺了草。",
				"effects": [{"kind": "ADD_POPULATION", "ratio_bp": 1200, "duration_days": 1}],
			}],
		}],
	}
	var ai_res := NarrativeAiValidatorScript.validate_and_sanitize(
		ai_raw, ai_ctx, PackedStringArray(), "evt.ai.refugee")
	var ai_event: Dictionary = ai_res.get("event_dict", {})
	var ai_effects: Array = []
	var ai_options: Array = ai_event.get("options", [])
	if not ai_options.is_empty():
		var ai_outcomes: Array = (ai_options[0] as Dictionary).get("outcomes", [])
		if not ai_outcomes.is_empty():
			ai_effects = (ai_outcomes[0] as Dictionary).get("effects", [])
	_expect("AI-generated population effect survives validation",
		bool(ai_res.get("ok", false)) and ai_effects.size() == 1
		and int((ai_effects[0] as Dictionary).get("kind", -1)) == int(Kind.ADD_POPULATION)
		and int((ai_effects[0] as Dictionary).get("ratio_bp", 0)) == 1200)
	_expect("AI population effect gets a readable fallback label",
		ai_effects.size() == 1
		and String((ai_effects[0] as Dictionary).get("custom_label", "")) == "本地人口 +12.0%")

	# 模型说了「迁走」却写负数：负号要留住，不能被抹成 0。
	var ai_out_raw := ai_raw.duplicate(true)
	var out_options: Array = ai_out_raw.get("options", [])
	if not out_options.is_empty():
		var out_outcomes: Array = (out_options[0] as Dictionary).get("outcomes", [])
		if not out_outcomes.is_empty():
			(out_outcomes[0] as Dictionary)["effects"] = [
				{"kind": "ADD_POPULATION", "ratio_bp": -900, "duration_days": 1}]
	var ai_out_res := NarrativeAiValidatorScript.validate_and_sanitize(
		ai_out_raw, ai_ctx, PackedStringArray(), "evt.ai.exodus")
	var ai_out_effects: Array = []
	var ai_out_options: Array = (ai_out_res.get("event_dict", {}) as Dictionary).get("options", [])
	if not ai_out_options.is_empty():
		var ocs: Array = (ai_out_options[0] as Dictionary).get("outcomes", [])
		if not ocs.is_empty():
			ai_out_effects = (ocs[0] as Dictionary).get("effects", [])
	_expect("AI negative population ratio keeps its sign",
		ai_out_effects.size() == 1
		and int((ai_out_effects[0] as Dictionary).get("ratio_bp", 0)) == -900)

	# ── 城市场景 prompt：人的构成、民生压力、邻城都必须进快照 ──
	# 只给「满意度五成四」是写不出人的；这三样是「写谁」的最小前提。
	var prompt_ctx := {
		"day": 900, "country_name": "临漳", "settlement_name": "柳湾", "cell_idx": 431,
		"era_index": 4, "era_name": "帝国与封建时代",
		"terrain_name": "平原", "landform_name": "河漫滩",
		"temperature_c": 9.0, "moisture": 0.6, "precipitation": 0.1, "snow_cover": 0.0,
		"elevation": 0.3, "has_river": true, "is_coastal": false,
		"population": 380, "satisfaction_norm": 0.54,
		"treasury_cash": 12000, "primary_cohort_cash": 860,
		"territory_cells": PackedInt32Array([1, 2, 3]),
		"human_context_available": true,
		"dominant_profession_name": "佃农",
		"dominant_profession_share": 0.44,
		"subsistence_shortfall_ratio": 0.17,
		"unemployment_ratio": 0.05,
		"primary_cohort_profession_name": "佃农",
		"neighbor_settlements": [
			{"name": "上河渡", "population": 210, "shortage_good": "grain"},
		],
	}
	var prompt_msgs := NarrativeAiPromptBuilderScript.build_messages(prompt_ctx)
	var system_prompt := String((prompt_msgs[0] as Dictionary).get("content", ""))
	var user_prompt := String((prompt_msgs[1] as Dictionary).get("content", ""))
	_expect("prompt carries the dominant livelihood",
		user_prompt.contains("主要生计：佃农"))
	_expect("prompt carries subsistence pressure",
		user_prompt.contains("养不活家") and user_prompt.contains("二成"))
	_expect("prompt carries neighbor settlements",
		user_prompt.contains("上河渡") and user_prompt.contains("210 口"))
	_expect("system prompt carries prose few-shot",
		system_prompt.contains("文风样例") and system_prompt.contains("渠线只挖了一半"))
	_expect("system prompt drops the anti-prose ban",
		not system_prompt.contains("不写场景与修辞"))

	# ── 正文长度：六十到一百四十字必须原样保留 ──
	# 早先 validator 的 left(160) 会把正常长度的叙事腰斩，改完之后不能再回到那个状态。
	var long_body := ""
	for _i in range(4):
		long_body += "渠线只挖了一半，工棚空了，挖出来的土堆在河边，被雨水冲出一道道沟。"
	var long_raw: Dictionary = ai_raw.duplicate(true)
	long_raw["body_text"] = long_body
	var long_res := NarrativeAiValidatorScript.validate_and_sanitize(
		long_raw, ai_ctx, PackedStringArray(), "evt.ai.long_body")
	var long_event: Dictionary = long_res.get("event_dict", {})
	_expect("long narrative body survives validation intact",
		bool(long_res.get("ok", false))
		and String(long_event.get("body_text", "")).length() == long_body.length())

	# ── LLM endpoint 归一化 ──
	# 设置界面允许只填 host，直接 POST 会 404，而且失败只有一行 HTTP 404，
	# 看起来像「服务不可用」。这条回归守住三种明显不完整的写法。
	_expect("bare host endpoint gets the chat path",
		NarrativeAiClientScript.normalize_llm_endpoint("https://api.deepseek.com")
		== "https://api.deepseek.com/v1/chat/completions")
	_expect("trailing slash endpoint gets the chat path",
		NarrativeAiClientScript.normalize_llm_endpoint("https://api.deepseek.com/")
		== "https://api.deepseek.com/v1/chat/completions")
	_expect("version-only endpoint gets the chat path",
		NarrativeAiClientScript.normalize_llm_endpoint("https://api.deepseek.com/v1")
		== "https://api.deepseek.com/v1/chat/completions")
	_expect("complete endpoint is left untouched",
		NarrativeAiClientScript.normalize_llm_endpoint("https://api.deepseek.com/v1/chat/completions")
		== "https://api.deepseek.com/v1/chat/completions")
	_expect("custom gateway path is never guessed",
		NarrativeAiClientScript.normalize_llm_endpoint("https://gw.example.com/openai")
		== "https://gw.example.com/openai")


func _test_shared_event_quota() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 98765, catalog)
	var def = catalog.get_event(&"evt.climate.bitter_frost")
	for day in [20, 100]:
		var offer := service.enqueue_event_offer(def, 3, day)
		service.choose_option(int(offer.offer_id), int(offer.offer_generation), 1, day + 1)
	for channel in [0, 1]:
		var ordinary = def.duplicate(true)
		ordinary.trigger_channel = channel
		_expect("pulse and fact channels share exhausted annual quota",
			service.enqueue_event_offer(ordinary, 3, 200).is_empty())
	var ai = def.duplicate(true)
	ai.is_ai_generated = true
	_expect("ordinary AI shares exhausted annual quota", service.enqueue_event_offer(ai, 3, 200).is_empty())
	# 模拟旧档积压：超额普通事件在出队时被剔除，后续定时事件仍可展示。
	var queued := {"cell_idx": 3, "event_id": String(def.event_id), "bypass_pacing": false}
	service._ready_queue.append(queued)
	service._ready_queue.append({"cell_idx": 3, "event_id": "scheduled", "bypass_pacing": true})
	var restored := NarrativeEventServiceScript.new()
	restored.configure(null, null, null, null, 1, 98765, catalog)
	restored.restore_state(service.export_state())
	restored.on_day_committed(200)
	_expect("restored over-quota queue cannot display ordinary events",
		String(restored.active_offer().get("event_id", "")) == "scheduled" and restored.ready_queue_size() == 0)
	_expect("scheduled followup does not consume quota", int(restored._cell_year_event_counts.get("0:3", 0)) == 2)
	var gap_service := NarrativeEventServiceScript.new()
	gap_service.configure(null, null, null, null, 1, 98765, catalog)
	gap_service._last_popup_day = 190
	gap_service._ready_queue.append({"cell_idx": 4, "event_id": "ordinary", "bypass_pacing": false})
	gap_service._ready_queue.append({"cell_idx": 4, "event_id": "scheduled", "bypass_pacing": true})
	gap_service._promote_next_ready_offer(200)
	_expect("scheduled followup passes ordinary events waiting for global gap",
		String(gap_service.active_offer().get("event_id", "")) == "scheduled" and gap_service.ready_queue_size() == 1)
	gap_service._active_offer.clear()
	gap_service._promote_next_ready_offer(201)
	_expect("queued ordinary event must wait for global gap", not gap_service.has_active_offer())
	gap_service._promote_next_ready_offer(260)
	_expect("queued ordinary event displays after global gap", gap_service.has_active_offer())
	_expect("annual quota resets next year", not restored.cell_year_pacing_blocked(3, 365))


func _test_deterministic_rng() -> void:
	var r1 := NarrativeRngScript.roll_q16(42, 10, 1, 5, 99)
	var r2 := NarrativeRngScript.roll_q16(42, 10, 1, 5, 99)
	var r3 := NarrativeRngScript.roll_q16(42, 11, 1, 5, 99)
	_expect("roll_q16 is deterministic for identical inputs", r1 == r2 and r1 >= 0 and r1 < 65536)
	_expect("roll_q16 varies across days", r1 != r3)

	var weights := PackedInt64Array([49152, 16384])
	var pick1 := NarrativeRngScript.pick_weighted_index(weights, 12345, 20, 1, 8, 7)
	var pick2 := NarrativeRngScript.pick_weighted_index(weights, 12345, 20, 1, 8, 7)
	_expect("pick_weighted_index is deterministic and in range", pick1 == pick2 and (pick1 == 0 or pick1 == 1))


func _test_multidimensional_conditions_and_catalog() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	_expect("default catalog has at least 10 authored events", catalog.all_events().size() >= 10)

	var drought_def := catalog.get_event(&"evt.climate.severe_drought")
	var ocean_def := catalog.get_event(&"evt.ocean.upwelling_bonanza")
	var market_def := catalog.get_event(&"evt.market.grain_panic")
	_expect("core climate, ocean and market events exist",
		drought_def != null and ocean_def != null and market_def != null)

	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 98765, catalog)

	var hot_dry_ctx := {
		"cell_idx": 12,
		"era_index": 1,
		"temperature": 31.0,
		"moisture": 0.25,
		"population": 25,
		"is_coastal": false,
	}
	var w_drought := service.evaluate_event_weight(drought_def, hot_dry_ctx, 10)
	var w_ocean_inland := service.evaluate_event_weight(ocean_def, hot_dry_ctx, 10)
	_expect("hot dry inland cell matches severe_drought with boosted weight", w_drought > drought_def.base_weight)
	_expect("inland cell does not match coastal upwelling event", w_ocean_inland == 0)

	var coastal_upwelling_ctx := {
		"cell_idx": 18,
		"era_index": 1,
		"temperature": 16.0,
		"moisture": 0.65,
		"population": 20,
		"is_coastal": true,
		"ocean_upwelling": 0.32,
		"ocean_current_speed": 0.35,
	}
	var w_ocean_coastal := service.evaluate_event_weight(ocean_def, coastal_upwelling_ctx, 10)
	_expect("coastal cell with strong upwelling and current gets high weight", w_ocean_coastal > ocean_def.base_weight * 2)


func _test_event_chain_and_weight_bias_and_chronicle() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 77777, catalog)

	var stage1 := catalog.get_event(&"evt.chain.strange_outcrop")
	var stage2 := catalog.get_event(&"evt.chain.subterranean_cavern")
	var stage3 := catalog.get_event(&"evt.chain.ancient_foundry_legacy")
	_expect("3-stage event chain definitions exist", stage1 != null and stage2 != null and stage3 != null)

	var cell_ctx := {
		"cell_idx": 7,
		"settlement_name": "云山镇",
		"landform_name": "丘陵",
		"terrain_name": "森林",
		"temperature": 18.5,
		"population": 30,
		"treasury_cash": 500000,
		"era_index": 1,
	}

	# Before Stage 1 is completed, Stage 2 must have weight 0 (missing prerequisite event & story flag)
	_expect("Stage 2 is locked before Stage 1 completes",
		service.evaluate_event_weight(stage2, cell_ctx, 5) == 0)

	# Trigger Stage 1
	var offer1 := service.enqueue_event_offer(stage1, 7, 5, &"chain_strange_outcrop", true, cell_ctx)
	_expect("Stage 1 offer is active and formatted with settlement name",
		service.has_active_offer() and String(offer1.get("title", "")).find("云山镇") >= 0)
	_expect("Encountering Stage 1 immediately registers on_trigger weight bias for 'prospecting' tag",
		service.weight_biases().size() >= 1)

	# Choose Option 0 ("组建勘探队，顺矿脉向地底深掘")
	var choose1 := service.choose_option(
		int(offer1.get("offer_id", 0)),
		int(offer1.get("offer_generation", 0)),
		0,
		6
	)
	_expect("Choosing Stage 1 option 0 succeeds and records chronicle",
		bool(choose1.get("ok", false)) and service.chronicle_total_count() == 1)
	_expect("Stage 1 option sets story flag 'flag_deep_prospecting'",
		service.has_story_flag(&"flag_deep_prospecting", 7))
	_expect("Stage 1 option schedules Stage 2 followup event",
		service.scheduled_events().size() == 1)

	# Now Stage 2 is eligible and its weight is boosted by the weight bias!
	var w_stage2 := service.evaluate_event_weight(stage2, cell_ctx, 10)
	_expect("Stage 2 becomes eligible with boosted weight after Stage 1 option",
		w_stage2 > stage2.base_weight)

	# Advance to day 22 (past the 15-day delay from day 6 -> due_day 21)
	service.on_day_committed(22, false)
	var offer2 := service.active_offer()
	_expect("Scheduled Stage 2 automatically triggers on due day",
		not offer2.is_empty() and String(offer2.get("event_id", "")) == "evt.chain.subterranean_cavern")


func _test_save_restore_roundtrip() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service_a := NarrativeEventServiceScript.new()
	service_a.configure(null, null, null, null, 1, 54321, catalog)

	var drought_def := catalog.get_event(&"evt.climate.severe_drought")
	var ctx := {
		"cell_idx": 3,
		"settlement_name": "河阳邑",
		"landform_name": "平原",
		"temperature": 29.0,
		"moisture": 0.2,
		"population": 40,
		"treasury_cash": 200000,
	}
	var offer := service_a.enqueue_event_offer(drought_def, 3, 12, &"", true, ctx)
	service_a.set_story_flag(&"flag_test_persist", 3, 12, 90, 1)
	var saved_state := service_a.export_state()

	# Restore into a brand-new service instance
	var service_b := NarrativeEventServiceScript.new()
	service_b.configure(null, null, null, null, 1, 1, catalog)
	var restore_res := service_b.restore_state(saved_state)
	_expect("pknr state restores cleanly", bool(restore_res.get("ok", false)))
	_expect("active offer survives save/load round-trip",
		service_b.has_active_offer()
		and int(service_b.active_offer().get("offer_id", -1)) == int(offer.get("offer_id", -2)))
	_expect("story flags survive save/load round-trip",
		service_b.has_story_flag(&"flag_test_persist", 3))

	# Verify deterministic outcome roll is identical between original and restored service
	var offer_id_val := int(offer.get("offer_id", 0))
	var offer_gen_val := int(offer.get("offer_generation", 0))
	var res_a := service_a.choose_option(offer_id_val, offer_gen_val, 0, 13)
	var res_b := service_b.choose_option(offer_id_val, offer_gen_val, 0, 13)
	_expect("post-restore option choice rolls the exact same probabilistic outcome",
		bool(res_a.get("ok", false)) and bool(res_b.get("ok", false))
		and int(res_a.get("outcome_index", -1)) == int(res_b.get("outcome_index", -2)))


func _test_ai_sandbox_and_image_cache() -> void:
	var cell_ctx := {
		"day": 30,
		"cell_idx": 9,
		"country_name": "华夏",
		"settlement_name": "临海城",
		"era_index": 2,
		"era_name": "青铜与城邦时代",
		"terrain_name": "海岸",
		"landform_name": "三角洲",
		"temperature": 24.0,
		"is_coastal": true,
		"ocean_upwelling": 0.28,
		"treasury_cash": 100000,
	}
	var messages := NarrativeAiPromptBuilderScript.build_messages(cell_ctx, [], "延续海贸兴盛")
	_expect("Prompt builder generates system + user messages", messages.size() == 2)
	var img_prompt := NarrativeAiPromptBuilderScript.build_era_image_prompt(2, "Bronze ships in harbor", cell_ctx)
	_expect("Image prompt includes era art direction and no-text guard",
		img_prompt.find("Bronze Age") >= 0 and img_prompt.find("no text") >= 0)
	var fact_messages := NarrativeAiPromptBuilderScript.build_messages(
		cell_ctx, [], "", PackedStringArray(), PackedStringArray(),
		"民生压力上升（临海城，1年1月31日）")
	_expect("Fact hint reaches the user prompt as a triggering-fact section",
		String((fact_messages[1] as Dictionary).get("content", "")).find("本次触发事实") >= 0)

	# 数字不一定是数据：只把温度读数改写成占位符，叙述里的数量词原样保留。
	var numeric_raw := {
		"title": "粮价飞涨",
		"body_text": "本地气温 34.2℃，粮价飞涨，三人因囤积被拘。",
		"options": [
			{
				"text": "开仓平粜",
				"outcomes": [{
					"probability_percent": 100,
					"outcome_title": "市面稍安",
					"effects": [],
				}],
			},
		],
	}
	var numeric_res := NarrativeAiValidatorScript.validate_and_sanitize(
		numeric_raw, cell_ctx, PackedStringArray(), "evt.ai.numeric")
	var numeric_event: Dictionary = numeric_res.get("event_dict", {})
	_expect("temperature readings become the placeholder without dropping the sentence",
		bool(numeric_res.get("ok", false))
		and String(numeric_event.get("body_text", "")) == "本地气温 {temperature}，粮价飞涨，三人因囤积被拘。")
	_expect("system prompt spells out the no-data-readings rule",
		String((messages[0] as Dictionary).get("content", "")).find("阿拉伯数字") >= 0
		and String((messages[0] as Dictionary).get("content", "")).find("{temperature}") >= 0)

	# Test AI validator against fenced JSON with out-of-bounds numbers and unknown modifier key
	var raw_llm_output := """```json
	{
	  "title": "海港异域商船抵岸",
	  "body_text": "顺着近岸洋流，一队满载铜料与香料的远方商船驶入临海城港湾，请求开市互易。",
	  "ai_visual_prompt": "Bronze age merchant ships docked at a busy delta port",
	  "tags": ["maritime", "trade"],
	  "options": [
	    {
	      "text": "设市互易，厚待远客",
	      "tooltip_hint": "促进贸易与生产",
	      "require_treasury_cash": 999999999,
	      "outcomes": [
	        {
	          "probability_percent": 75,
	          "outcome_title": "互市大兴",
	          "outcome_narrative": "商旅往来络绎不绝，本城百工受益。",
	          "effects": [
	            {
	              "kind": "CITY_MODIFIER",
	              "target_key": "non_existent_hallucinated_modifier_key",
	              "magnitude_percent": 500,
	              "duration_days": 99999
	            }
	          ]
	        },
	        {
	          "probability_percent": 25,
	          "outcome_title": "平平无奇",
	          "outcome_narrative": "小规模交易后商船离去。",
	          "effects": []
	        }
	      ]
	    }
	  ]
	}
	```"""
	var validated := NarrativeAiValidatorScript.validate_and_sanitize(raw_llm_output, cell_ctx)
	_expect("Validator accepts fenced JSON and sanitizes it", bool(validated.get("ok", false)))
	var ev_dict: Dictionary = validated.get("event_dict", {})
	var def := NarrativeEventDefinitionScript.from_dict(ev_dict)
	_expect("Sanitized AI event converts to NarrativeEventDefinition", def != null and def.is_ai_generated)
	var opt0: NarrativeOption = def.options[0] as NarrativeOption
	var probs := opt0.normalized_probabilities_q16()
	_expect("Validator normalizes outcome probabilities to sum to 65536",
		probs.size() == 2 and probs[0] + probs[1] == 65536)
	var out0: NarrativeOutcome = opt0.outcomes[0] as NarrativeOutcome
	var eff0: NarrativeEffectSpec = out0.effects[0] as NarrativeEffectSpec
	_expect("Hallucinated modifier key is safely mapped to a live ADD key and clamped",
		eff0.target_key == &"economy.city.building.manufacturing_output_factor"
		and eff0.duration_days <= 365)

	# Test malformed JSON rejection
	var bad_res := NarrativeAiValidatorScript.validate_and_sanitize("not a json at all {{{", cell_ctx)
	_expect("Validator rejects malformed JSON gracefully without crashing", not bool(bad_res.get("ok", true)))

	# Test NarrativeAiClient with mock responders (LLM + Image)
	var client := NarrativeAiClientScript.new()
	client.set_mock_llm_responder(Callable(self, "_mock_llm_reply"))
	client.set_mock_image_responder(Callable(self, "_mock_img_reply"))
	var gen_res: Dictionary = {}
	client.request_event_generation({
		"day": 30,
		"cell_idx": 9,
		"cell_ctx": cell_ctx,
		"ai_request_seq": 7,
	}, Callable(self, "_capture_dict").bind(gen_res))
	_expect("NarrativeAiClient mock LLM pipeline produces a valid definition",
		bool(gen_res.get("ok", false)) and gen_res.get("definition", null) != null)
	_expect("NarrativeAiClient echoes the request seq back for the service to claim",
		int(gen_res.get("ai_request_seq", -1)) == 7)

	var img_res_out: Dictionary = {}
	client.request_event_illustration("test_ai_event_img", "Ships in port", Callable(self, "_capture_dict").bind(img_res_out))
	_expect("NarrativeAiClient mock image pipeline caches PNG and creates Texture2D",
		bool(img_res_out.get("ok", false)) and img_res_out.get("texture", null) != null)
	client.free()


func _test_ai_fact_trigger_and_staleness() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var generator := FactGeneratorStub.new()
	var service := NarrativeEventServiceScript.new()
	service.configure(generator, null, null, null, 1, 424242, catalog)
	# 隔离脉冲通道，本用例只验证事实入口与回执事务。
	service.pulse_interval_days = 1000000
	service.ai_fact_chance_q16 = 65536
	service.ai_min_request_gap_days = 0

	var requests: Array = []
	service.ai_generation_requested.connect(
		func(spec: Dictionary) -> void: requests.append(spec.duplicate(true)))

	# 第 10 日：一条社会压力事实 → 立刻请求 AI，而不是等 20 天脉冲。
	generator.bus.batch = {
		"count": 1,
		"event_id": PackedInt64Array([1001]),
		"type": PackedInt32Array([8]),
		"cell_idx": PackedInt32Array([5]),
	}
	service.on_day_committed(10, true)
	_expect("gameplay fact triggers an immediate AI request", requests.size() == 1)
	if requests.size() != 1:
		return
	var spec: Dictionary = requests[0]
	var first_seq := int(spec.get("ai_request_seq", -1))
	_expect("AI fact request carries the triggering fact and a request seq",
		first_seq > 0 and String(spec.get("fact_hint", "")).find("民生压力上升") >= 0)

	var validated := NarrativeAiValidatorScript.validate_and_sanitize(
		_mock_llm_reply({}, []), {}, PackedStringArray(), "evt.ai.test_fact")
	var def = NarrativeEventDefinitionScript.from_dict(validated.get("event_dict", {}))
	var stale := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": first_seq, "definition": def}, 200)
	_expect("AI result past the staleness window is dropped instead of shown",
		String(stale.get("code", "")) == "ai_result_stale")

	# 第 300 日再来一条事实；回执在窗口内到达，应以到达日重新采样后入队。
	generator.bus.batch = {
		"count": 1,
		"event_id": PackedInt64Array([1002]),
		"type": PackedInt32Array([8]),
		"cell_idx": PackedInt32Array([5]),
	}
	service.on_day_committed(300, true)
	_expect("second qualifying fact requests another AI event", requests.size() == 2)
	if requests.size() != 2:
		return
	var second_seq := int((requests[1] as Dictionary).get("ai_request_seq", -1))
	var fresh := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": second_seq, "definition": def}, 301)
	_expect("in-window AI result lands as an AI-generated offer",
		bool(fresh.get("ok", false)) and service.has_active_offer()
		and bool(service.active_offer().get("is_ai_generated", false)))
	_expect("fresh AI offer is dated at arrival day, not request day",
		int(service.active_offer().get("day", -1)) == 301)

	# 第 600 日：请求在途时存档 → 读档后迟到的回执必须被丢弃（seq 不跨档）。
	generator.bus.batch = {
		"count": 1,
		"event_id": PackedInt64Array([1003]),
		"type": PackedInt32Array([8]),
		"cell_idx": PackedInt32Array([5]),
	}
	service.on_day_committed(600, true)
	_expect("third fact request stays pending for the save/load check", requests.size() == 3)
	if requests.size() == 3:
		var third_seq := int((requests[2] as Dictionary).get("ai_request_seq", -1))
		var restored := NarrativeEventServiceScript.new()
		restored.configure(null, null, null, null, 1, 424242, catalog)
		restored.restore_state(service.export_state())
		var late := restored.accept_ai_generation(
			{"ok": true, "ai_request_seq": third_seq, "definition": def}, 601)
		_expect("in-flight AI requests do not survive save/load",
			String(late.get("code", "")) == "ai_request_unknown")

	var unknown := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": 99999, "definition": def}, 602)
	_expect("AI result without a pending request is rejected",
		String(unknown.get("code", "")) == "ai_request_unknown")

	# 局势加权：同样的基础概率，危机格必须比平静格更容易被写到。
	var calm_ctx := {
		"shortage_good_ids": PackedStringArray(),
		"market_price_ratios_by_id": {},
		"satisfaction_norm": 0.80,
		"temperature_c": 18.0,
		"snow_cover": 0.0,
	}
	var crisis_ctx := {
		"shortage_good_ids": PackedStringArray(["grain", "fish"]),
		"market_price_ratios_by_id": {"grain": 1.9, "fish": 1.5},
		"satisfaction_norm": 0.32,
		"temperature_c": 35.0,
		"snow_cover": 0.0,
	}
	var calm_score := NarrativeEventServiceScript.situation_pressure_score(calm_ctx)
	var crisis_score := NarrativeEventServiceScript.situation_pressure_score(crisis_ctx)
	_expect("situation pressure rises with shortages, price spikes, discontent and heat",
		calm_score == 0 and crisis_score >= 80)
	_expect("situation scaling stays inside [base, ceiling]",
		service._ai_chance_q16(2621, calm_ctx) == 2621
		and service._ai_chance_q16(2621, crisis_ctx) > 2621
		and service._ai_chance_q16(2621, crisis_ctx) <= service.ai_max_chance_q16)


func _test_state_probe_and_ai_pool() -> void:
	var probes := NarrativeStateProbeCatalogScript.build_default_probes()
	_expect("default state probes cover shortage, discontent and drought",
		probes.size() >= 3
		and String(probes[0].state_id) == "state.market.food_shortage")
	if probes.is_empty():
		return
	var shortage_probe = probes[0]
	_expect("default shortage probe is judged by the engine, not the model",
		not shortage_probe.matches(
			{"era_index": 1, "population": 30, "market_price_ratios_by_id": {"grain": 1.1}})
		and shortage_probe.matches(
			{"era_index": 1, "population": 30, "market_price_ratios_by_id": {"grain": 1.6}}))

	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var generator := StateGeneratorStub.new()
	var service := NarrativeEventServiceScript.new()
	service.configure(generator, null, null, null, 1, 5150, catalog)
	service.pulse_interval_days = 1000000
	service.state_probe_interval_days = 1
	service.ai_min_request_gap_days = 0
	service.set_state_probes([_build_shortage_probe()])

	var requests: Array = []
	service.ai_generation_requested.connect(
		func(spec: Dictionary) -> void: requests.append(spec.duplicate(true)))
	var def = _build_ai_definition_for_test("evt.ai.state_test")

	for d in range(1, 5):
		service.on_day_committed(d, true)
	_expect("state probe tracks dwell before spending an AI call", requests.is_empty())

	service.on_day_committed(5, true)
	_expect("state probe requests AI once dwell is met", requests.size() == 1)
	if requests.size() != 1:
		return
	var spec: Dictionary = requests[0]
	_expect("state request carries the standing state and its recent digest",
		String(spec.get("state_id", "")) == "state.market.test_shortage"
		and String(spec.get("state_hint", "")).find("粮食紧缺") >= 0)

	# 回执到达时状态已破：进池，不弹。
	generator.economy.grain_price = 100
	var pooled := service.accept_ai_generation(
		{"ok": true, "ai_request_seq": int(spec.get("ai_request_seq", -1)), "definition": def}, 6)
	_expect("AI result is pooled when the state no longer holds",
		String(pooled.get("code", "")) == "ai_event_pooled"
		and service.ai_event_pool().size() == 1)
	_expect("pooled event does not open a popup", not service.has_active_offer())

	# 状态恢复：直接从池子出队，不再花一次 API。
	generator.economy.grain_price = 200
	service.on_day_committed(7, true)
	_expect("pooled event fires when the same state returns",
		service.has_active_offer() and requests.size() == 1)
	_expect("pool is emptied after a successful fire", service.ai_event_pool().is_empty())

	generator.economy.grain_price = 100
	for i in range(3):
		service._stash_pooled_event("state.market.test_shortage", def, 5, 10 + i)
	_expect("pool keeps at most two entries per state",
		service.ai_event_pool().size() == NarrativeEventServiceScript.AI_POOL_MAX_PER_STATE)

	var restored := NarrativeEventServiceScript.new()
	restored.configure(null, null, null, null, 1, 5150, catalog)
	restored.restore_state(service.export_state())
	_expect("pooled AI events survive save/load", restored.ai_event_pool().size() == 2)


func _build_shortage_probe():
	var probe = NarrativeStateProbeScript.new()
	probe.state_id = &"state.market.test_shortage"
	probe.display_name = "粮食紧缺"
	probe.prompt_hint = "粮价高企，居民囤积"
	probe.dwell_days = 4
	probe.cooldown_days = 0
	probe.conditions.append(NarrativeConditionScript.from_dict({
		"op": NarrativeConditionScript.Op.MARKET_GOOD_PRICE_RATIO_GTE,
		"target_key": "grain",
		"float_value": 1.35,
	}))
	return probe


func _build_ai_definition_for_test(event_id: String):
	var validated := NarrativeAiValidatorScript.validate_and_sanitize(
		_mock_llm_reply({}, []), {}, PackedStringArray(), event_id)
	return NarrativeEventDefinitionScript.from_dict(validated.get("event_dict", {}))


func _test_ui_dialog_and_chronicle_panel() -> void:
	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 999, catalog)
	var def := catalog.get_event(&"evt.climate.severe_drought")
	var offer := service.enqueue_event_offer(def, 2, 15, &"", true, {
		"cell_idx": 2, "settlement_name": "洛邑", "landform_name": "平原", "temperature": 30.0
	})
	dialog.present_offer(offer)
	_expect("NarrativeEventDialog opens and displays formatted offer title",
		dialog.is_offer_open() and dialog._title_label.text.find("洛邑") >= 0)
	# 题头只留日历：不再堆聚落/地貌/气温。
	_expect("event kicker shows only the calendar date",
		dialog._kicker_label.text == String(offer.get("date_text", ""))
		and dialog._kicker_label.text.find("°C") < 0
		and dialog._kicker_label.text.find("平原") < 0)
	_expect("category tags are no longer rendered in the header",
		dialog._tags_row.get_child_count() == 0)

	var res := service.choose_option(int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 0, 16)
	dialog.show_outcome(res)
	_expect("NarrativeEventDialog displays rolled outcome view",
		dialog._outcome_panel.visible and not dialog._options_vbox.visible)
	dialog.close_offer()
	_expect("NarrativeEventDialog closes cleanly", not dialog.is_offer_open())

	# AI 事件：题头仍然只有日期，来源改挂一枚纸签，不挤回题头。
	var ai_offer := service.enqueue_event_offer(
		_build_ai_definition_for_test("evt.ai.dialog_pill"), 3, 20, &"", true)
	dialog.present_offer(ai_offer)
	var has_ai_tag := false
	for child in dialog._tags_row.get_children():
		if child is Label and (child as Label).text == "AI 生成":
			has_ai_tag = true
	_expect("AI events keep a paper tag while the kicker stays calendar-only",
		has_ai_tag and dialog._tags_row.get_child_count() == 1
		and dialog._kicker_label.text.find("°C") < 0)
	dialog.close_offer()
	dialog.free()

	var chron := NarrativeChroniclePanelScript.new()
	root.add_child(chron)
	chron.open_panel(service.get_chronicle())
	_expect("NarrativeChroniclePanel opens and renders recorded history",
		chron.is_panel_open() and chron._records.size() == service.chronicle_total_count()
		and chron._list_vbox.get_child_count() > 0)
	_expect("chronicle panel no longer hosts the AI configuration entry",
		_find_button_with_text(chron, "AI 配置") == null)
	chron.close_panel()
	chron.free()


func _find_button_with_text(node: Node, text_value: String) -> Button:
	if node is Button and (node as Button).text == text_value:
		return node as Button
	for child in node.get_children():
		var found := _find_button_with_text(child, text_value)
		if found != null:
			return found
	return null


func _test_player_controller_integration() -> void:
	var controller := PlayerControllerScript.new()
	_expect("PlayerController registers narrative.choose in SUPPORTED_COMMANDS",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"narrative.choose"))
	var state := controller.capture_view_state()
	_expect("PlayerController capture_view_state includes narrative_event_view",
		state.has("narrative_event_view"))
	controller.free()


func _mock_llm_reply(_spec: Dictionary, _msgs: Array) -> String:
	return """{
	  "title": "海港异域商船抵岸",
	  "body_text": "顺着近岸洋流，一队满载铜料与香料的远方商船驶入临海城港湾，请求开市互易。",
	  "ai_visual_prompt": "Bronze age merchant ships docked at a busy delta port",
	  "tags": ["maritime", "trade"],
	  "options": [
	    {
	      "text": "设市互易，厚待远客",
	      "outcomes": [
	        {
	          "probability_percent": 100,
	          "outcome_title": "互市大兴",
	          "outcome_narrative": "商旅往来络绎不绝，本城百工受益。",
	          "effects": [
	            {
	              "kind": "CITY_MODIFIER",
	              "target_key": "family.city.production_boost",
	              "magnitude_percent": 15,
	              "duration_days": 90
	            }
	          ]
	        }
	      ]
	    }
	  ]
	}"""


func _mock_img_reply(_ev_id: String, _prompt: String) -> PackedByteArray:
	var dummy_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	dummy_img.fill(Color(0.8, 0.6, 0.3, 1.0))
	return dummy_img.save_png_to_buffer()


func _capture_dict(res: Dictionary, target: Dictionary) -> void:
	target.merge(res, true)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
