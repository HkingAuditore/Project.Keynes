extends SceneTree

## 「地块上的人」事件包与人群系统的契约测试。
##
## 覆盖六件事：
##   1. 事件模型能带住 speaker/quote 字段（schema 层；内容层禁用引语块）；
##   2. 人群采样：人数最多的 cohort、入不敷出、失业、职业构成；
##   3. 四个新条件算子按人群事实判定；
##   4. 国库→本地人群的现金转移只落在「人数最多的那一群」，标签写清其职业；
##   5. 饥民事件只在人群真的撑不住时出现，且能一路排到「粥棚撤了」；
##   6. 弹窗渲染纯散文正文与结果段落，不出现引语块。

const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeContextSamplerScript = preload("res://scripts/narrative/narrative_context_sampler.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeEffectAdapterScript = preload("res://scripts/narrative/narrative_effect_adapter.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")

const CELL := 9

var _checks := 0
var _failures := 0


class PeopleEconomyStub extends RefCounted:
	var _catalog := {"profession_ids": PackedStringArray(["farmer", "artisan"])}
	var transfers: Array[Dictionary] = []

	func is_configured() -> bool:
		return true

	func settlement_display_name(_cell: int) -> String:
		return "测试邑"

	func profession_display_name(stable_id: String) -> String:
		return "工匠" if stable_id == "artisan" else "农户"

	func population_cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "population": 45, "composite_satisfaction_q16": 40000}

	func population_cell_snapshot(_cell: int, _details: bool) -> Dictionary:
		return {
			"handles": PackedInt64Array([11, 12, 13]),
			"populations": PackedInt64Array([10, 30, 5]),
			"funds": PackedInt64Array([1000, 9000, 100]),
			"livelihood_coverage_by_cohort_q16": PackedInt64Array([19661, 78643, 26214]),
			"satisfaction_by_cohort_q16": PackedInt32Array([19661, 45875, 26214]),
			"unemployed_by_cohort": PackedInt64Array([2, 0, 1]),
			"profession_ids": PackedInt32Array([0, 1, 1]),
		}

	func building_cell_snapshot(_cell: int) -> Dictionary:
		return {}

	func market_cell_snapshot(_cell: int) -> Dictionary:
		return {
			"good_stable_ids": PackedStringArray(["wheat_grain"]),
			"stocks": PackedInt64Array([5000]),
			"prices": PackedInt64Array([100]),
			"base_prices": PackedInt64Array([100]),
		}

	func transfer_country_cash_to_cohort(country: int, cohort: int, amount: int,
			day: int, sequence: int) -> Dictionary:
		transfers.append({"country": country, "cohort": cohort, "amount": amount,
			"day": day, "sequence": sequence})
		return {"ok": true, "amount": amount}

	func add_stock(_cell: int, good_id: StringName, quantity: int, _day: int,
			_sequence: int) -> Dictionary:
		return {"ok": true, "good_id": String(good_id), "quantity": quantity}


class PeopleGeneratorStub extends RefCounted:
	var economy := PeopleEconomyStub.new()
	func get_economy_facade():
		return economy
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
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	_test_definition_quote_roundtrip()
	_test_human_context_sampling()
	_test_human_conditions()
	_test_cash_transfer_and_label()
	_test_hungry_trigger_and_chain(catalog)
	_test_dialog_prose_and_outcome(catalog)
	print("=== narrative people test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ─── 1. 引语字段（schema 层）────────────────────────────────────────────────

func _test_definition_quote_roundtrip() -> void:
	var def = NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.test.quote",
		"title": "{settlement_name}·试",
		"body_text": "正文。",
		"speaker": "城门吏 王顺",
		"quote_text": "「大人得给句话。」",
	})
	var restored = NarrativeEventDefinitionScript.from_dict(def.to_dict())
	_expect("speaker survives to_dict/from_dict", String(restored.speaker) == "城门吏 王顺")
	_expect("quote_text survives to_dict/from_dict",
		String(restored.quote_text) == "「大人得给句话。」")
	_expect("events without a quote stay empty",
		String(NarrativeEventDefinitionScript.from_dict({"title": "t"}).quote_text).is_empty())


# ─── 2. 人群采样 ────────────────────────────────────────────────────────────

func _sample_people_ctx() -> Dictionary:
	var generator := PeopleGeneratorStub.new()
	return NarrativeContextSamplerScript.sample_cell_context(
		CELL, {}, null, generator, null, {}, true)


func _test_human_context_sampling() -> void:
	var ctx := _sample_people_ctx()
	_expect("human context is flagged available", bool(ctx.get("human_context_available", false)))
	_expect("largest cohort stays the primary recipient",
		int(ctx.get("primary_cohort_handle", 0)) == 12)
	_expect("primary recipient carries its profession for effect labels",
		String(ctx.get("primary_cohort_profession_id", "")) == "artisan"
		and String(ctx.get("primary_cohort_profession_name", "")) == "工匠")
	_expect("subsistence shortfall counts the two cohorts under half coverage",
		int(ctx.get("subsistence_shortfall_population", 0)) == 15
		and absf(float(ctx.get("subsistence_shortfall_ratio", 0.0)) - 15.0 / 45.0) < 0.0001)
	_expect("unemployment ratio is aggregated over people, not cohorts",
		int(ctx.get("unemployed_population", 0)) == 3
		and absf(float(ctx.get("unemployment_ratio", 0.0)) - 3.0 / 45.0) < 0.0001)
	_expect("dominant profession resolves to a stable id and a display name",
		String(ctx.get("dominant_profession_id", "")) == "artisan"
		and String(ctx.get("dominant_profession_name", "")) == "工匠"
		and absf(float(ctx.get("dominant_profession_share", 0.0)) - 35.0 / 45.0) < 0.0001)
	_expect("neediest cohort carries its satisfaction",
		int(ctx.get("neediest_cohort_handle", 0)) == 11
		and absf(float(ctx.get("neediest_cohort_satisfaction", 1.0)) - 0.3) < 0.001)

	# 没有经济门面时不应崩，也不应伪造人群事实。
	var bare := NarrativeContextSamplerScript.sample_cell_context(CELL, {}, null, null, null, {}, true)
	_expect("no facade means no human facts", not bool(bare.get("human_context_available", true)))


# ─── 3. 人群条件 ────────────────────────────────────────────────────────────

func _test_human_conditions() -> void:
	var Op = NarrativeConditionScript.Op
	var ctx := _sample_people_ctx()
	_expect("shortfall condition accepts a poor cell",
		NarrativeConditionScript.from_dict({"op": Op.SUBSISTENCE_SHORTFALL_GTE,
			"float_value": 0.30}).evaluate(ctx))
	_expect("shortfall condition rejects a comfortable cell",
		not NarrativeConditionScript.from_dict({"op": Op.SUBSISTENCE_SHORTFALL_GTE,
			"float_value": 0.60}).evaluate(ctx))
	_expect("unemployment condition reads the aggregate ratio",
		NarrativeConditionScript.from_dict({"op": Op.UNEMPLOYMENT_GTE,
			"float_value": 0.05}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.UNEMPLOYMENT_GTE,
			"float_value": 0.10}).evaluate(ctx))
	_expect("profession share condition matches the stable id",
		NarrativeConditionScript.from_dict({"op": Op.PROFESSION_SHARE_GTE,
			"target_key": "artisan", "float_value": 0.5}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.PROFESSION_SHARE_GTE,
			"target_key": "farmer", "float_value": 0.5}).evaluate(ctx))
	_expect("cohort satisfaction condition follows the unhappiest cohort",
		NarrativeConditionScript.from_dict({"op": Op.COHORT_SATISFACTION_LTE,
			"float_value": 0.45}).evaluate(ctx)
		and not NarrativeConditionScript.from_dict({"op": Op.COHORT_SATISFACTION_LTE,
			"float_value": 0.20}).evaluate(ctx))


# ─── 4. 国库 → 人数最多的那群（职业名进标签）──────────────────────────────

func _test_cash_transfer_and_label() -> void:
	var generator := PeopleGeneratorStub.new()
	var ctx := {
		"cell_idx": CELL,
		"treasury_cash": 100000,
		"primary_cohort_handle": 12,
		"primary_cohort_profession_name": "工匠",
	}
	var result := NarrativeEffectAdapterScript.apply_effects(
		[{
			"kind": NarrativeEffectSpecScript.Kind.TREASURY_CASH_TO_COHORT,
			"ratio_bp": 250,
			"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2.5%",
		}],
		ctx, null, generator, 1, CELL, 20, Callable()
	)
	var transfers: Array[Dictionary] = generator.economy.transfers
	_expect("cash transfer issues exactly one conserved transfer", transfers.size() == 1)
	if transfers.size() == 1:
		_expect("cash transfer targets the primary cohort",
			int(transfers[0]["cohort"]) == 12)
		_expect("cash transfer converts the ratio against treasury cash",
			int(transfers[0]["amount"]) == 2500)
	_expect("cash transfer debits the working context",
		int(ctx.get("treasury_cash", -1)) == 97500)
	_expect("cash transfer names the actual profession in its summary",
		(result.get("applied_summaries", PackedStringArray()) as PackedStringArray).has(
			"国库拨付本地人数最多的工匠，占国库现金 2.5%"))


# ─── 5. 饥民事件：触发与善后 ────────────────────────────────────────────────

func _test_hungry_trigger_and_chain(catalog) -> void:
	var service := NarrativeEventServiceScript.new()
	service.configure(PeopleGeneratorStub.new(), null, null, null, 1, 20261112, catalog)
	var hungry = catalog.get_event(&"evt.people.hungry_crowd")
	var aftermath = catalog.get_event(&"evt.people.gruel_aftermath")
	_expect("people pack registers both beats", hungry != null and aftermath != null)
	if hungry == null or aftermath == null:
		return

	var comfortable := {
		"cell_idx": CELL, "era_index": 1, "population": 25,
		"subsistence_shortfall_ratio": 0.05,
		"profession_share_by_id": {"merchant": 0.05},
	}
	_expect("a fed cell never sees the hungry crowd",
		service.evaluate_event_weight(hungry, comfortable, 10) == 0)

	var pressed := {
		"cell_idx": CELL, "era_index": 1, "population": 25,
		"subsistence_shortfall_ratio": 0.30,
		"profession_share_by_id": {"merchant": 0.05},
	}
	var base_weight := service.evaluate_event_weight(hungry, pressed, 10)
	_expect("a hungry cell makes the event eligible", base_weight > 0)

	var miserable := pressed.duplicate(true)
	miserable["unemployment_ratio"] = 0.20
	miserable["market_price_ratios_by_id"] = {"wheat_grain": 1.35}
	miserable["neediest_cohort_satisfaction"] = 0.30
	_expect("unemployment, price and despair raise its weight",
		service.evaluate_event_weight(hungry, miserable, 10) > base_weight)

	var offer := service.enqueue_event_offer(hungry, CELL, 10, &"chain_people", true, {
		"cell_idx": CELL, "settlement_name": "泽畔邑", "era_index": 1,
		"population": 40, "treasury_cash": 400000,
		"human_context_available": true,
		"subsistence_shortfall_ratio": 0.4,
		"market_stocks_by_id": {"wheat_grain": 5000},
	})
	_expect("hungry crowd offer is pure prose, without a quote block",
		String(offer.get("speaker", "")).is_empty()
		and String(offer.get("quote_text", "")).is_empty()
		and String(offer.get("body_text", "")).contains("城门外"))
	var choose := service.choose_option(
		int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 0, 11)
	_expect("opening the granary resolves", bool(choose.get("ok", false)))
	_expect("opening the granary records its human outcome",
		String((choose.get("record", {}) as Dictionary).get("outcome_narrative", "")).contains("粥棚"))
	_expect("opening the granary raises the gruel flag",
		service.has_story_flag(&"flag_gruel_kitchen", CELL))
	_expect("opening the granary schedules the aftermath",
		service.scheduled_events().size() == 1)

	service.on_day_committed(57, false)
	var later := service.active_offer()
	_expect("aftermath fires after the relief window",
		String(later.get("event_id", "")) == "evt.people.gruel_aftermath")
	if String(later.get("event_id", "")) != "evt.people.gruel_aftermath":
		return
	var choose2 := service.choose_option(
		int(later.get("offer_id", 0)), int(later.get("offer_generation", 0)), 0, 58)
	_expect("registering the survivors resolves", bool(choose2.get("ok", false)))
	_expect("registering them buys long-term capacity",
		(choose2.get("applied_summaries", PackedStringArray()) as PackedStringArray).has(
			"本地农业 +5%，540 日"))
	_expect("registering them leaves a local grudge",
		service.weight_biases().size() >= 1)


# ─── 6. 弹窗：场景正文与结果段落 ───────────────────────────────────────────

func _test_dialog_prose_and_outcome(catalog) -> void:
	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 4242, catalog)
	var offer := service.enqueue_event_offer(
		catalog.get_event(&"evt.people.hungry_crowd"), CELL, 10, &"chain_people", true, {
			"cell_idx": CELL, "settlement_name": "泽畔邑", "era_index": 1,
			"population": 40, "treasury_cash": 400000,
			"human_context_available": true,
		})
	dialog.present_offer(offer)
	_expect("dialog hides the quote block when the event is pure prose",
		not dialog._quote_block.visible and dialog._quote_text_label.text.is_empty())
	_expect("dialog prints the scene prose",
		dialog._body_label.visible and dialog._body_label.text.contains("城门外"))

	var res := service.choose_option(
		int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 1, 11)
	dialog.show_outcome(res)
	_expect("dialog shows the outcome paragraph",
		dialog._outcome_narrative_label.visible
		and dialog._outcome_narrative_label.text.contains("工钱当天结算"))
	_expect("outcome view clears the scene prose to leave room for the result",
		not dialog._body_label.visible)
	dialog.close_offer()
	dialog.free()
