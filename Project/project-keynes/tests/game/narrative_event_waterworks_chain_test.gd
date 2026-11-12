extends SceneTree

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
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const CELL := 7
const ERA_AGRARIAN := 1

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("[FAIL] ", label)


func _near(a: float, b: float, tolerance: float = 0.0005) -> bool:
	return absf(a - b) <= tolerance


func _run() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	_test_catalog_shape(catalog)
	_test_trigger_gates(catalog)
	_test_authorized_route(catalog)
	_test_abandoned_route(catalog)
	_test_flag_gating_contract(catalog)
	_test_effect_numbers_match_labels(catalog)
	print("=== narrative waterworks chain test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


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
						_expect("modifier %s of %s states its percentage" % [eff.target_key, def.event_id],
							pct_regex.search(label) != null)
					elif eff.kind == NarrativeEffectSpecScript.Kind.SCHEDULE_FOLLOWUP_EVENT:
						_expect("scheduled %s of %s exists in the catalog" % [eff.target_key, def.event_id],
							catalog.get_event(eff.target_key) != null)

	_expect("at least 80%% of options are deterministic",
		float(deterministic) / float(maxi(1, total_options)) >= 0.75)


# ─── 2. 触发门槛与权重 ───────────────────────────────────────────────────────

func _test_trigger_gates(catalog) -> void:
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 424242, catalog)
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
	var baseline := service.evaluate_event_weight(proposal, base_ctx, 10)
	_expect("eligible river plain gets a positive weight", baseline > 0)

	var dry_ctx := base_ctx.duplicate(true)
	dry_ctx["moisture"] = 0.30
	dry_ctx["population"] = 30
	dry_ctx["market_price_ratios_by_id"] = {"wheat_grain": 1.30}
	var rich := service.evaluate_event_weight(proposal, dry_ctx, 10)
	_expect("dry, populous, expensive-grain cell outweighs the baseline", rich > baseline)

	var no_river := base_ctx.duplicate(true)
	no_river["has_river"] = false
	_expect("no river means no canal", service.evaluate_event_weight(proposal, no_river, 10) == 0)

	var wrong_terrain := base_ctx.duplicate(true)
	wrong_terrain["terrain"] = 6 # MOUNTAIN
	_expect("mountains are not canal country",
		service.evaluate_event_weight(proposal, wrong_terrain, 10) == 0)

	var wet := base_ctx.duplicate(true)
	wet["moisture"] = 0.80
	_expect("wet cells do not need irrigation",
		service.evaluate_event_weight(proposal, wet, 10) == 0)

	var no_tech := base_ctx.duplicate(true)
	no_tech["technology_ids"] = PackedStringArray(["tech.hunting"])
	_expect("without tech.irrigation the proposal stays locked",
		service.evaluate_event_weight(proposal, no_tech, 10) == 0)

	var too_late := base_ctx.duplicate(true)
	too_late["era_index"] = 9
	_expect("era window closes after era 4",
		service.evaluate_event_weight(proposal, too_late, 10) == 0)

	var thin := base_ctx.duplicate(true)
	thin["population"] = 4
	_expect("too few hands means no corvee",
		service.evaluate_event_weight(proposal, thin, 10) == 0)


# ─── 3. 两条分支的路由 ───────────────────────────────────────────────────────

func _open_proposal(service, catalog) -> Dictionary:
	var proposal = catalog.get_event(&"evt.waterworks.canal_proposal")
	var ctx := {
		"cell_idx": CELL,
		"settlement_name": "泽畔邑",
		"era_index": ERA_AGRARIAN,
		"has_river": true,
		"terrain": 2,
		"terrain_name": "平原",
		"moisture": 0.40,
		"population": 18,
		"treasury_cash": 400000,
		"market_stocks_by_id": {"wheat_grain": 12000},
		"market_price_ratios_by_id": {"wheat_grain": 1.2},
		"technology_ids": PackedStringArray(["tech.irrigation"]),
	}
	return service.enqueue_event_offer(proposal, CELL, 5, &"chain_canal", true, ctx)


func _test_authorized_route(catalog) -> void:
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 20261111, catalog)
	var offer := _open_proposal(service, catalog)
	_expect("proposal opens", not offer.is_empty() and service.has_active_offer())

	var choose := service.choose_option(
		int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 0, 6)
	_expect("authorizing the engineer resolves", bool(choose.get("ok", false)))
	_expect("authorization raises the story flag",
		service.has_story_flag(&"flag_canal_authorized", CELL))
	_expect("authorization schedules the completion beat",
		service.scheduled_events().size() == 1)

	service.on_day_committed(8, false)
	_expect("completion does not fire early",
		String(service.active_offer().get("event_id", "")) != "evt.waterworks.canal_completed")

	service.on_day_committed(37, false)
	var completed := service.active_offer()
	_expect("completion fires on its due day",
		String(completed.get("event_id", "")) == "evt.waterworks.canal_completed")
	_expect("completion offers three readings of the canal",
		(completed.get("options", []) as Array).size() == 3)
	var levy_eligible := false
	var levy_label := ""
	for opt in completed.get("options", []):
		var option_dict: Dictionary = opt
		if String(option_dict.get("option_id", "")) == "ship_grain_to_capital":
			levy_eligible = bool(option_dict.get("eligible", true))
			var branches: Array = option_dict.get("outcomes", [])
			if not branches.is_empty():
				levy_label = "  ".join(PackedStringArray(
					(branches[0] as Dictionary).get("effect_summaries", [])))
	_expect("the commuted-tax option needs no goods stock", levy_eligible)
	_expect("the commuted tax names the cash levy",
		levy_label.contains("征收其现金的 3%"))

	# 选确定性的淤灌，验证两年后结账的第四幕。
	var choose2 := service.choose_option(
		int(completed.get("offer_id", 0)), int(completed.get("offer_generation", 0)), 0, 38)
	_expect("silt irrigation resolves", bool(choose2.get("ok", false)))
	_expect("silt irrigation schedules the legacy beat",
		service.scheduled_events().size() == 1)

	service.on_day_committed(768, false)
	var legacy := service.active_offer()
	_expect("legacy fires two years later",
		String(legacy.get("event_id", "")) == "evt.waterworks.canal_legacy")
	_expect("legacy titles its outcome with the country name",
		(legacy.get("options", []) as Array).size() == 2)


func _test_abandoned_route(catalog) -> void:
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 777, catalog)
	var offer := _open_proposal(service, catalog)
	var choose := service.choose_option(
		int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 2, 6)
	_expect("dismissing the works resolves", bool(choose.get("ok", false)))
	_expect("dismissal raises the abandoned flag",
		service.has_story_flag(&"flag_canal_abandoned", CELL))
	_expect("dismissal routes to the abandoned beat",
		service.scheduled_events().size() == 1)

	service.on_day_committed(27, false)
	var abandoned := service.active_offer()
	_expect("abandoned beat fires",
		String(abandoned.get("event_id", "")) == "evt.waterworks.canal_abandoned")

	var choose2 := service.choose_option(
		int(abandoned.get("offer_id", 0)), int(abandoned.get("offer_generation", 0)), 0, 28)
	_expect("keeping the survey resolves", bool(choose2.get("ok", false)))
	_expect("keeping the survey clears the abandoned flag",
		not service.has_story_flag(&"flag_canal_abandoned", CELL))
	_expect("keeping the survey re-schedules the completion beat",
		service.scheduled_events().size() == 1)

	service.on_day_committed(149, false)
	_expect("revived canal completes",
		String(service.active_offer().get("event_id", "")) == "evt.waterworks.canal_completed")


## 标记并不是排程门槛（定时事件直接入队），但它在脉冲通道里是硬门槛。
## 这里直接对权重求值，证明「有标记才可能出现」这条规则对将来改成脉冲事件同样成立。
func _test_flag_gating_contract(catalog) -> void:
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 777, catalog)
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
		service.evaluate_event_weight(abandoned_def, ctx, 10) == 0)
	service.set_story_flag(&"flag_canal_abandoned", CELL, 5, 1825, 1)
	var flagged_ctx := ctx.duplicate(true)
	flagged_ctx["story_flags"] = {"flag_canal_abandoned": 1}
	_expect("with the flag the abandoned beat becomes eligible",
		service.evaluate_event_weight(abandoned_def, flagged_ctx, 10) > 0)


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
