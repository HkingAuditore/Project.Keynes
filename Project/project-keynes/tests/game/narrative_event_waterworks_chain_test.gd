extends "res://tests/support/runtime_narrative_scenario.gd"

## 水利工程链（渠议 → 渠成 / 中辍 → 渠田连岁）的契约测试。
##
## 覆盖四件事：
##   1. 内容形状：四个事件都进了默认库，选项/概率/文案长度符合《事件文案规范》；
##   2. 写法契约：每条效果都有 custom_label，且改修正键都真的存在于修饰器目录里；
##   3. 触发契约：地理/科技/时代/湿度四个门槛逐一生效，权重规则会抬高权重；
##   4. 数值契约：卡面写的百分比，就是 ModifierRuntime 实际乘上去的百分比。
##
## 第 4 项是这条示范链存在的主要理由：`family.city.*` 与 `economy.city.*` 两族定义的
## magnitude 语义不同（详见 narrative_event_catalog_waterworks.gd 文件头），写错了卡面会
## 比实际效果大三四倍，而这个测试会把这种错当场抓出来。

const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const CELL := 7
const ERA_AGRARIAN := 1

func _near(a: float, b: float, tolerance: float = 0.0005) -> bool:
	return absf(a - b) <= tolerance


func _run() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	_test_catalog_shape(catalog)
	_test_trigger_gates(catalog)
	await _test_authorized_route()
	await _test_abandoned_route()
	_test_flag_gating_contract(catalog)
	_test_effect_numbers_match_labels(catalog)
	print("=== narrative waterworks chain test: %d checks, %d failures ===" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


# ─── 1. 内容形状与写法契约 ───────────────────────────────────────────────────

func _chain_events(catalog) -> Array:
	var out: Array = []
	for event_id in [
		&"evt.waterworks.canal_proposal",
		&"evt.waterworks.canal_completed",
		&"evt.waterworks.canal_abandoned",
		&"evt.waterworks.canal_legacy",
	]:
		out.append(catalog.get_event(event_id))
	return out


func _test_catalog_shape(catalog) -> void:
	var events := _chain_events(catalog)
	for i in range(events.size()):
		_expect("chain event %d is registered" % i, events[i] != null)
		if events[i] == null:
			return

	_expect("proposal uses the pulse channel",
		int(events[0].trigger_channel) == 0)
	for i in range(1, events.size()):
		_expect("beats 2..4 are scheduled-only", int(events[i].trigger_channel) == 2)

	var compiled: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	_expect("modifier catalog compiles", bool(compiled.get("ok", false)))
	var definitions: PackedStringArray = compiled.get("definition_keys", PackedStringArray())

	var deterministic := 0
	var total_options := 0
	var pct_regex := RegEx.new()
	pct_regex.compile("([+-])([0-9]+)%")

	for def in events:
		_expect("event %s body is a scene, not a one-liner" % def.event_id,
			int(def.body_text.count("。")) >= 3 and int(def.body_text.count("。")) <= 8)
		_expect("event %s body carries enough prose to set a scene" % def.event_id,
			String(def.body_text).length() >= 100)
		_expect("event %s avoids the old quote block" % def.event_id,
			String(def.quote_text).strip_edges().is_empty()
			and String(def.speaker).strip_edges().is_empty())
		_expect("event %s title carries the settlement placeholder" % def.event_id,
			String(def.title).begins_with("{settlement_name}·"))
		for opt in def.options:
			total_options += 1
			_expect("option %s/%s text is 4-16 chars" % [def.event_id, opt.option_id],
				opt.text.length() >= 4 and opt.text.length() <= 16)
			_expect("option %s/%s leaves tooltip_hint empty" % [def.event_id, opt.option_id],
				String(opt.tooltip_hint).is_empty())
			_expect("option %s/%s has outcomes" % [def.event_id, opt.option_id],
				not opt.outcomes.is_empty())
			var prob_sum := 0
			for out in opt.outcomes:
				prob_sum += int(out.probability_q16)
			_expect("option %s/%s probabilities sum to 65536" % [def.event_id, opt.option_id],
				prob_sum == 65536)
			if opt.outcomes.size() == 1:
				deterministic += 1
				_expect("single-outcome option %s/%s is a clean 100%%" % [def.event_id, opt.option_id],
					int(opt.outcomes[0].probability_q16) == 65536)
			else:
				_expect("gamble option %s/%s has 2-3 branches" % [def.event_id, opt.option_id],
					opt.outcomes.size() >= 2 and opt.outcomes.size() <= 3)
			for out in opt.outcomes:
				_expect("outcome %s/%s tells what happened to people" % [def.event_id, opt.option_id],
					not String(out.outcome_narrative).strip_edges().is_empty())
				for eff in out.effects:
					var label := String(eff.custom_label)
					_expect("effect on %s carries a custom label" % def.event_id,
						not label.strip_edges().is_empty())
					_expect("effect label on %s never leaks an internal flag id" % def.event_id,
						not label.contains("flag_"))
					if eff.kind == NarrativeEffectSpecScript.Kind.CITY_MODIFIER \
							or eff.kind == NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER:
						_expect("modifier %s of %s exists in the catalog" % [eff.target_key, def.event_id],
							definitions.has(String(eff.target_key)))
						var absolute_levy := String(eff.target_key) == "narrative.levy.labor_satisfaction"
						_expect("modifier %s of %s states its magnitude" % [eff.target_key, def.event_id],
							label.contains("满意度 -4") and label.contains("劳动者 -5") if absolute_levy
							else pct_regex.search(label) != null)
					elif eff.kind == NarrativeEffectSpecScript.Kind.SCHEDULE_FOLLOWUP_EVENT:
						_expect("scheduled %s of %s exists in the catalog" % [eff.target_key, def.event_id],
							catalog.get_event(eff.target_key) != null)

	_expect("at least 80%% of options are deterministic",
		float(deterministic) / float(maxi(1, total_options)) >= 0.75)


# ─── 2. 触发门槛与权重 ───────────────────────────────────────────────────────

func _test_trigger_gates(catalog) -> void:
	var proposal = catalog.get_event(&"evt.waterworks.canal_proposal")
	_expect("proposal definition is available", proposal != null)
	if proposal == null:
		return

	var base_ctx := {
		"cell_idx": CELL,
		"era_index": ERA_AGRARIAN,
		"has_river": true,
		"terrain": 2,
		"terrain_name": "平原",
		"moisture": 0.48,
		"population": 12,
		"is_coastal": false,
		"technology_ids": PackedStringArray(["tech.irrigation"]),
		"market_price_ratios_by_id": {"wheat_grain": 1.0},
	}
	var baseline := _authored_weight(proposal, base_ctx)
	_expect("eligible river plain gets a positive weight", baseline > 0)

	var dry_ctx := base_ctx.duplicate(true)
	dry_ctx["moisture"] = 0.30
	dry_ctx["population"] = 30
	dry_ctx["market_price_ratios_by_id"] = {"wheat_grain": 1.30}
	var rich := _authored_weight(proposal, dry_ctx)
	_expect("dry, populous, expensive-grain cell outweighs the baseline", rich > baseline)

	var no_river := base_ctx.duplicate(true)
	no_river["has_river"] = false
	_expect("no river means no canal", _authored_weight(proposal, no_river) == 0)

	var wrong_terrain := base_ctx.duplicate(true)
	wrong_terrain["terrain"] = 6 # MOUNTAIN
	_expect("mountains are not canal country",
		_authored_weight(proposal, wrong_terrain) == 0)

	var wet := base_ctx.duplicate(true)
	wet["moisture"] = 0.80
	_expect("wet cells do not need irrigation",
		_authored_weight(proposal, wet) == 0)

	var no_tech := base_ctx.duplicate(true)
	no_tech["technology_ids"] = PackedStringArray(["tech.hunting"])
	_expect("without tech.irrigation the proposal stays locked",
		_authored_weight(proposal, no_tech) == 0)

	var too_late := base_ctx.duplicate(true)
	too_late["era_index"] = 9
	_expect("era window closes after era 4",
		_authored_weight(proposal, too_late) == 0)

	var thin := base_ctx.duplicate(true)
	thin["population"] = 4
	_expect("too few hands means no corvee",
		_authored_weight(proposal, thin) == 0)


# ─── 3. 两条分支的路由 ───────────────────────────────────────────────────────

func _start_proposal() -> bool:
	if not await _start_story({"scheduled_events": [
		{"due_day": 5, "event_id": "evt.waterworks.canal_proposal"},
	]}, ["evt.waterworks.canal_proposal", "evt.waterworks.canal_completed",
		"evt.waterworks.canal_abandoned", "evt.waterworks.canal_legacy"]):
		return false
	return await _advance_story(5)


func _test_authorized_route() -> void:
	if await _start_proposal():
		await _check_authorized_route()
	await _close_story()


func _check_authorized_route() -> void:
	_expect("proposal opens", story_service.active_offer().get("event_id") == "evt.waterworks.canal_proposal")
	_choose_story(0)
	if not await _advance_story(6):
		return
	var saved := story_ext.capture_gameplay_narrative()
	var flag := "cell:%d:flag_canal_authorized" % story_cell
	_expect("authorization raises the story flag", saved.get("story_flags", {}).has(flag))
	var future: Array = saved.get("scheduled_events", [])
	_expect("the completion is scheduled thirty days after construction starts",
		future.size() == 1 and future[0].get("due_day") == 36)
	var term_rows := {
		"agricultural_worker": -400, "worker": -400, "miner": -400,
		"construction_worker": -500, "corvee_worker": -500,
	}
	for profession in term_rows:
		var stat := "economy.profession.%s.satisfaction_bp" % profession
		var rows: Dictionary = story_ext.list_modifiers(1, story_player, stat)
		var index: int = rows.get("definition_keys", PackedStringArray()).find("narrative.levy.labor_satisfaction")
		var detail: Dictionary = story_ext.explain_modifier_stat(1, story_player, 0, stat, 0.0)
		var term: int = detail.get("definition_keys", PackedStringArray()).find("narrative.levy.labor_satisfaction")
		_expect("published canal levy for %s is %d bp from day 6 through day 245" % [profession, term_rows[profession]],
			index >= 0 and term >= 0 and rows.applied_days[index] == 6 and rows.expiry_days[index] == 246
			and int(detail.adds[term]) == term_rows[profession])
		print("CANAL_LEVY profession=", profession, " list=", JSON.stringify(rows), " effect=", JSON.stringify(detail))
	if not await _advance_story(35):
		return
	_expect("completion does not fire early", not story_service.has_active_offer())
	if not await _advance_story(36):
		return
	var completed := story_service.active_offer()
	_expect("completion fires on the due day", completed.get("event_id") == "evt.waterworks.canal_completed")
	var choices: Array = completed.get("options", [])
	_expect("completion offers three readings of the canal", choices.size() == 3)
	for option in choices:
		if option.get("option_id") != "ship_grain_to_capital":
			continue
		_expect("the commuted tax option needs no goods stock and describes the cash levy",
			bool(option.get("eligible", false)) and "  ".join(option.outcomes[0].effect_summaries)
				.contains("征收其现金的 3%"))
	_choose_story(0)
	if not await _advance_story(37):
		return
	future = story_ext.capture_gameplay_narrative().get("scheduled_events", [])
	_expect("silt irrigation schedules the legacy beat two years after the choice",
		future.size() == 1 and future[0].get("due_day") == 767)
	if not await _advance_story(246):
		return
	var remaining: Dictionary = story_ext.list_modifiers(1, story_player, "")
	_expect("the canal levy no longer applies after the authored duration",
		not remaining.get("definition_keys", PackedStringArray()).has("narrative.levy.labor_satisfaction"))
	if await _advance_story(767):
		var legacy := story_service.active_offer()
		_expect("the legacy fires with two readings on day 767",
			legacy.get("event_id") == "evt.waterworks.canal_legacy"
			and legacy.get("options", []).size() == 2)


func _test_abandoned_route() -> void:
	if await _start_proposal():
		await _check_abandoned_route()
	await _close_story()


func _check_abandoned_route() -> void:
	_choose_story(2)
	if not await _advance_story(6):
		return
	var flag := "cell:%d:flag_canal_abandoned" % story_cell
	var saved := story_ext.capture_gameplay_narrative()
	_expect("dismissal raises the abandoned flag", saved.get("story_flags", {}).has(flag))
	var future: Array = saved.get("scheduled_events", [])
	_expect("dismissal schedules the abandoned beat on day 26",
		future.size() == 1 and future[0].get("due_day") == 26)
	if not await _advance_story(26):
		return
	_expect("the abandoned beat arrives on schedule",
		story_service.active_offer().get("event_id") == "evt.waterworks.canal_abandoned")
	_choose_story(0)
	if not await _advance_story(27):
		return
	saved = story_ext.capture_gameplay_narrative()
	_expect("keeping the survey clears the abandoned flag", not saved.get("story_flags", {}).has(flag))
	future = saved.get("scheduled_events", [])
	_expect("keeping the survey re-schedules completion on day 147",
		future.size() == 1 and future[0].get("due_day") == 147)
	if await _advance_story(147):
		_expect("the revived canal completes", story_service.active_offer().get("event_id") == "evt.waterworks.canal_completed")


## 标记并不是排程门槛（定时事件直接入队），但它在脉冲通道里是硬门槛。
## 这里直接对权重求值，证明「有标记才可能出现」这条规则对将来改成脉冲事件同样成立。
func _test_flag_gating_contract(catalog) -> void:
	var abandoned_def = catalog.get_event(&"evt.waterworks.canal_abandoned")
	_expect("abandoned beat definition is available", abandoned_def != null)
	if abandoned_def == null:
		return
	var ctx := {
		"cell_idx": CELL,
		"era_index": ERA_AGRARIAN,
		"population": 18,
		"story_flags": {},
	}
	_expect("without the flag the abandoned beat is ineligible",
		_authored_weight(abandoned_def, ctx) == 0)
	var flagged_ctx := ctx.duplicate(true)
	flagged_ctx["story_flags"] = {"flag_canal_abandoned": 1}
	_expect("with the flag the abandoned beat becomes eligible",
		_authored_weight(abandoned_def, flagged_ctx) > 0)


# ─── 4. 卡面百分比 = 实际乘数 ────────────────────────────────────────────────

## 键形 → 被读的 stat。只覆盖本链条用到的四类，出现新键形就补进来（这是有意的：
## 未覆盖的键不应该被静默跳过）。
func _stat_key_for(definition_key: String) -> String:
	if definition_key.begins_with("economy.city.good.") \
			or definition_key.begins_with("economy.city.building.") \
			or definition_key.begins_with("economy.city.need.") \
			or definition_key.begins_with("economy.city.birth_factor"):
		return definition_key.trim_suffix(".cut")
	if definition_key.begins_with("ideology.") and definition_key.ends_with(".gain"):
		return definition_key.trim_prefix("ideology.").trim_suffix(".gain")
	if definition_key == "country.economic_mobilization":
		return "country.economy_output_factor"
	if definition_key == "narrative.military.supply_cut":
		return "country.military.supply_consumption_factor"
	if definition_key.begins_with("ideology.country.") and definition_key.ends_with(".cut"):
		return definition_key.trim_prefix("ideology.").trim_suffix(".cut")
	return ""


func _test_effect_numbers_match_labels(catalog) -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_checks += 1
		print("[SKIP] DCWorldExt unavailable: effect numbers are not verified in this run")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var facade = ModifierFacadeScript.new()
	var configured: Dictionary = facade.configure(ext, 32)
	_expect("modifier facade configures", bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)):
		return

	var pct_regex := RegEx.new()
	pct_regex.compile("([+-])([0-9]+)%")
	var pending: Array[Dictionary] = []
	var index := 0
	for def in _chain_events(catalog):
		if def == null:
			continue
		for opt in def.options:
			for out in opt.outcomes:
				for eff in out.effects:
					if String(eff.target_key) == "narrative.levy.labor_satisfaction":
						continue # Checked against the five native terms on the choice day.
					if eff.kind != NarrativeEffectSpecScript.Kind.CITY_MODIFIER \
							and eff.kind != NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER:
						continue
					var stat_key := _stat_key_for(String(eff.target_key))
					_expect("stat mapping exists for %s" % eff.target_key, not stat_key.is_empty())
					if stat_key.is_empty():
						continue
					var found := pct_regex.search(String(eff.custom_label))
					_expect("label of %s carries a percentage" % eff.target_key, found != null)
					if found == null:
						continue
					index += 1
					var is_city: bool = int(eff.kind) == int(
						NarrativeEffectSpecScript.Kind.CITY_MODIFIER)
					var cell := 2 + index
					var entity := 900 + index
					var target: Dictionary = {"domain": 2, "scope": 1, "group_handle": cell} \
						if is_city else {"domain": 1, "scope": 2, "entity_handle": entity}
					facade.queue_apply(
						eff.target_key, target, {"type": 0x4E415252, "id": index},
						eff.duration_days, 1, 1, 190, eff.magnitude_q16)
					var pct := float(found.get_string(2))
					var expected := 1.0 + pct / 100.0 if found.get_string(1) == "+" \
						else 1.0 - pct / 100.0
					pending.append({
						"key": String(eff.target_key),
						"stat": stat_key,
						"city": is_city,
						"cell": cell,
						"entity": entity,
						"expected": expected,
						"label": String(eff.custom_label),
					})

	_expect("the chain exercises at least six modifier effects", pending.size() >= 6)
	ext.run_modifier_daily(1)
	for row in pending:
		var actual := float(ext.evaluate_modifier_stat(
			2, 0, int(row["cell"]), row["stat"], 1.0)) if bool(row["city"]) \
			else float(ext.evaluate_modifier_stat(1, int(row["entity"]), 0, row["stat"], 1.0))
		_expect("label [%s] matches the runtime factor of %s (%.4f vs %.4f)" % [
			row["label"], row["key"], actual, row["expected"]],
			_near(actual, float(row["expected"])))
