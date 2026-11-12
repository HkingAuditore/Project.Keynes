extends SceneTree

## 主题事件网（8 包 34 条）的契约测试。
##
## 数据驱动：所有断言都从 `NarrativeEventRegistry.packs()` 展开，加一个包就自动纳入覆盖，
## 不需要回来改测试。七组断言：
##   1. 注册与唯一性：pack meta 自检、声明节点 = 实际注册、前缀合法、id 全局唯一；
##   2. 文字契约：正文长度/句数、无数字读数、无行内引语、选项字数、结果句数；
##   3. 专名契约：每包 cast ≥4，每条正文命中 ≥2 个；
##   4. 效果契约：标签、内部 id 泄漏、修饰键存在、标签百分比 = 幅度、概率和、确定性比例；
##   5. 取舍契约：每个选项至少一种代价、同一事件的选项代价不重复、每包 ≥1 个博弈；
##   6. 引用完整性：排程/偏置/事件门/标记门全部可解析，写的标记都有人读；
##   7. 图结构：非入口有硬入边、多入边节点数、跨包边数、时代窗口相交、BFS 可达。
##
## 跑法：
##   & "...Godot...console.exe" --headless --path Project/project-keynes \
##     --script tests/game/narrative_event_web_test.gd --quit

const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventRegistryScript = preload("res://scripts/narrative/narrative_event_registry.gd")
const NarrativeEventPackScript = preload("res://scripts/narrative/narrative_event_pack.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEventIdsScript = preload("res://scripts/narrative/narrative_event_ids.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")

## 一个事件正文至少命中几个专名。
const CAST_HITS_MIN := 2
## 带引语的事件占比上限。
const QUOTE_SHARE_MAX := 0.40

var _checks := 0
var _failures := 0
var _cast_by_prefix: Dictionary = {}
var _prefix_by_event: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("[FAIL] ", label)


func _run() -> void:
	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	_index_packs(catalog)
	_test_registry(catalog)
	_test_text_contract(catalog)
	_test_repetition_budget(catalog)
	_test_pack_repetition_budget(catalog)
	_test_price_claims(catalog)
	_test_cast_contract(catalog)
	_test_effect_contract(catalog)
	_test_tradeoff_contract(catalog)
	_test_references(catalog)
	_test_graph(catalog)
	_test_trigger_layers(catalog)
	_test_behaviour(catalog)
	_test_runtime_parity(catalog)
	print("=== narrative event web test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ─── 索引 ───────────────────────────────────────────────────────────────────

func _index_packs(catalog) -> void:
	_cast_by_prefix.clear()
	_prefix_by_event.clear()
	for meta in NarrativeEventRegistryScript.packs():
		var prefix := String(meta.get("prefix", ""))
		_cast_by_prefix[prefix] = meta.get("cast", [])
		for node in NarrativeEventPackScript.node_ids(meta):
			_prefix_by_event[node] = prefix


func _web_events(catalog) -> Array:
	var out: Array = []
	for def in catalog.all_events():
		if def != null and _prefix_by_event.has(String(def.event_id)):
			out.append(def)
	return out


func _pack_events(catalog, prefix: String) -> Array:
	var out: Array = []
	for def in catalog.all_events():
		if def != null and String(def.event_id).begins_with(prefix):
			out.append(def)
	return out


func _pack_of(event_id: String) -> String:
	return String(_prefix_by_event.get(event_id, ""))


# ─── 1. 注册与唯一性 ────────────────────────────────────────────────────────

func _test_registry(catalog) -> void:
	var seen: Dictionary = {}
	var declared: Dictionary = {}
	for meta in NarrativeEventRegistryScript.packs():
		var check: Dictionary = NarrativeEventPackScript.validate(meta)
		_expect("pack %s meta validates (%s)" % [meta.get("id", "?"), check.get("reason", "")],
			bool(check.get("ok", false)))
		var prefix := String(meta.get("prefix", ""))
		var events := _pack_events(catalog, prefix)
		var nodes := NarrativeEventPackScript.node_ids(meta)
		_expect("pack %s declares %d nodes and registers %d" % [meta.get("id", "?"), nodes.size(), events.size()],
			nodes.size() == events.size())
		for node in nodes:
			declared[node] = true
			_expect("pack %s node %s is registered" % [meta.get("id", "?"), node],
				catalog.get_event(StringName(node)) != null)
		for def in events:
			var key := String(def.event_id)
			_expect("event id %s is unique" % key, not seen.has(key))
			seen[key] = true
			if not declared.has(key):
				_expect("event %s is declared by its pack meta" % key, false)
	_expect("the registry contributes at least one event", not seen.is_empty())


# ─── 2. 文字契约 ────────────────────────────────────────────────────────────

func _sentence_count(text: String) -> int:
	return int(text.count("。")) + int(text.count("！")) + int(text.count("？"))


func _test_text_contract(catalog) -> void:
	var quoted := 0
	var total := 0
	for def in _web_events(catalog):
		var key := String(def.event_id)
		var body := String(def.body_text)
		total += 1
		_expect("%s body is 120-300 chars" % key, body.length() >= 120 and body.length() <= 300)
		_expect("%s body is 3-8 sentences" % key,
			_sentence_count(body) >= 3 and _sentence_count(body) <= 8)
		_expect("%s body carries no numeric readings" % key,
			not _contains_ascii_digit(body))
		_expect("%s body avoids the old quote-block markup" % key,
			not body.contains("：『") and not body.contains("』") and not body.contains("\""))
		_expect("%s title carries the settlement placeholder" % key,
			String(def.title).begins_with("{settlement_name}·"))
		var speaker := String(def.speaker).strip_edges()
		var quote := String(def.quote_text).strip_edges()
		_expect("%s quote fields are both empty or both set" % key,
			(speaker.is_empty() and quote.is_empty()) or (not speaker.is_empty() and not quote.is_empty()))
		if not speaker.is_empty():
			quoted += 1
			_expect("%s quote is short" % key, quote.length() <= 40)
		_expect("%s has 2-3 options" % key, def.options.size() >= 2 and def.options.size() <= 3)
		var texts: Dictionary = {}
		for opt in def.options:
			_expect("%s option %s text is 4-16 chars" % [key, opt.option_id],
				opt.text.length() >= 4 and opt.text.length() <= 16)
			_expect("%s option %s is not a duplicate" % [key, opt.option_id],
				not texts.has(String(opt.text)))
			texts[String(opt.text)] = true
			_expect("%s option %s leaves tooltip empty" % [key, opt.option_id],
				String(opt.tooltip_hint).is_empty())
			_expect("%s option %s has 1-2 outcomes" % [key, opt.option_id],
				opt.outcomes.size() >= 1 and opt.outcomes.size() <= 2)
			for out in opt.outcomes:
				var title := String(out.outcome_title).strip_edges()
				var narrative := String(out.outcome_narrative).strip_edges()
				_expect("%s/%s outcome title is 2-12 chars" % [key, opt.option_id],
					title.length() >= 2 and title.length() <= 12)
				_expect("%s/%s outcome text is 1-3 sentences" % [key, opt.option_id],
					_sentence_count(narrative) >= 1 and _sentence_count(narrative) <= 3)
				_expect("%s/%s outcome stays compact" % [key, opt.option_id],
					narrative.length() <= 110)
	if total > 0:
		_expect("quotes stay a minority device",
			float(quoted) / float(total) <= QUOTE_SHARE_MAX)


func _contains_ascii_digit(text: String) -> bool:
	for i in range(text.length()):
		var code := text.unicode_at(i)
		if code >= 48 and code <= 57:
			return true
	return false


## 单条事件里的重复套路预算。全量文本审读发现「蹲」「钥匙」「界石」「沉默句」等
## 被当成万能标点，跨包复用成模板；这里先按单条事件设上限，跨包配额再由审读推进。
const REPETITION_BUDGET := {
	"蹲": 2,
	"钥匙": 1,
	"界石|界桩": 1,
	"没有人说话|谁也没说话|没人说话|没人接话|一句话没说|没人答": 1,
	"站了很久|看了很久|站了半天|站了半晌": 1,
	"册子上多了一行|册子多了一行|添了一行|多了一页": 1,
	"收进怀里|揣进怀里|收进袖子|收进柜子|塞进怀里": 1,
	"第二天早上|第二天清早|天亮时": 1,
}


func _test_repetition_budget(catalog) -> void:
	for def in _web_events(catalog):
		var text := String(def.body_text)
		for opt in def.options:
			for outcome in opt.outcomes:
				text += "\n" + String(outcome.outcome_narrative)
		for pattern in REPETITION_BUDGET:
			var found := _count_pattern(text, pattern)
			var budget := int(REPETITION_BUDGET[pattern])
			if found > budget:
				_expect("%s repetition budget exceeded: %s (%d > %d)" % [
					def.event_id, pattern, found, budget], false)


func _count_pattern(text: String, pattern: String) -> int:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search_all(text).size()


## 跨包配额：一个包内同一姿态/道具/转场不许超过上限。单条事件已经卡过一遍，
## 这里卡的是「同一包里换着事件重复」——审读时最容易被连着触发看穿的就是这种。
const PACK_REPETITION_BUDGET := {
	"蹲": 3,
	"钥匙": 1,
	"界石|界桩": 1,
	"没有人说话|谁也没说话|没人说话|没人接话|一句话没说|没人答": 1,
	"站了很久|看了很久|站了半天|站了半晌": 1,
	"册子上多了一行|册子多了一行|添了一行|多了一页": 1,
	"收进怀里|揣进怀里|收进袖子|收进柜子|塞进怀里": 1,
	"第二天早上|第二天清早|天亮时": 1,
}


func _test_pack_repetition_budget(catalog) -> void:
	var texts := {}
	for def in _web_events(catalog):
		var prefix := String(_prefix_by_event.get(String(def.event_id), ""))
		if prefix.is_empty():
			continue
		var text := String(texts.get(prefix, ""))
		text += "\n" + String(def.body_text)
		for opt in def.options:
			for outcome in opt.outcomes:
				text += "\n" + String(outcome.outcome_narrative)
		texts[prefix] = text
	for prefix in texts.keys():
		for pattern in PACK_REPETITION_BUDGET:
			var found := _count_pattern(String(texts[prefix]), pattern)
			var budget := int(PACK_REPETITION_BUDGET[pattern])
			if found > budget:
				_expect("%s pack repetition budget exceeded: %s (%d > %d)" % [
					prefix, pattern, found, budget], false)


## 价格句契约：结果文本声称「价涨/价落/变贵/变便宜」，这条结果就必须有一条真能
## 影响物价、库存或主食开销的效果；否则文本在骗玩家。只查 outcome_narrative，
## body 里的氛围性提价不在此列。
func _test_price_claims(catalog) -> void:
	var claim := RegEx.new()
	claim.compile("价.{0,16}(涨|落|跌|贵|便宜|贱)|(涨|落|跌).{0,16}价")
	for def in _web_events(catalog):
		for opt in def.options:
			for outcome in opt.outcomes:
				var text := String(outcome.outcome_narrative)
				if claim.search(text) == null:
					continue
				if not _has_price_effect(outcome.effects):
					_expect("%s/%s claims a price move without a price effect" % [
						def.event_id, opt.option_id], false)


func _has_price_effect(effects: Array) -> bool:
	for raw in effects:
		var spec = raw
		if raw is Dictionary:
			spec = NarrativeEffectSpecScript.from_dict(raw)
		if spec == null or not spec is NarrativeEffectSpec:
			continue
		var kind := int(spec.kind)
		if kind == NarrativeEffectSpecScript.Kind.MARKET_ADD_STOCK \
				or kind == NarrativeEffectSpecScript.Kind.MARKET_REMOVE_STOCK \
				or kind == NarrativeEffectSpecScript.Kind.MARKET_GOOD_TO_COUNTRY \
				or kind == NarrativeEffectSpecScript.Kind.COUNTRY_GOOD_TO_MARKET:
			return true
		if kind == NarrativeEffectSpecScript.Kind.CITY_MODIFIER:
			var key := String(spec.target_key)
			if key.contains("good.") or key.contains("staple_food") or key.contains("market"):
				return true
	return false


# ─── 3. 专名契约 ────────────────────────────────────────────────────────────

func _test_cast_contract(catalog) -> void:
	for meta in NarrativeEventRegistryScript.packs():
		var prefix := String(meta.get("prefix", ""))
		var cast: Array = meta.get("cast", [])
		_expect("pack %s names at least four concrete things" % meta.get("id", "?"),
			cast.size() >= 4)
		for def in _pack_events(catalog, prefix):
			var hits := 0
			for token in cast:
				if String(def.body_text).contains(String(token)):
					hits += 1
			_expect("%s body names at least %d cast members (got %d)" % [
				def.event_id, CAST_HITS_MIN, hits], hits >= CAST_HITS_MIN)


# ─── 4. 效果契约 ────────────────────────────────────────────────────────────

func _test_effect_contract(catalog) -> void:
	var compiled: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	_expect("modifier catalog compiles", bool(compiled.get("ok", false)))
	var definitions: PackedStringArray = compiled.get("definition_keys", PackedStringArray())
	var deterministic := 0
	var total_options := 0
	var kinds_by_pack: Dictionary = {}

	for def in _web_events(catalog):
		var key := String(def.event_id)
		var prefix := _pack_of(key)
		for opt in def.options:
			total_options += 1
			if opt.outcomes.size() == 1:
				deterministic += 1
				_expect("%s/%s deterministic option is a clean 100%%" % [key, opt.option_id],
					int(opt.outcomes[0].probability_q16) == 65536)
			var prob_sum := 0
			for out in opt.outcomes:
				prob_sum += int(out.probability_q16)
			_expect("%s/%s probabilities sum to 65536" % [key, opt.option_id], prob_sum == 65536)
			for out in opt.outcomes:
				_expect("%s/%s keeps effects at five lines or fewer" % [key, opt.option_id],
					out.effects.size() <= 5)
				for eff in out.effects:
					var kind := int(eff.kind)
					var bucket: Array = kinds_by_pack.get(prefix, [])
					if not bucket.has(kind):
						bucket.append(kind)
					kinds_by_pack[prefix] = bucket
					var label := String(eff.custom_label).strip_edges()
					_expect("%s effect carries a custom label" % key, not label.is_empty())
					_expect("%s effect label hides internal ids" % key,
						not label.contains("flag_") and not label.contains("evt.")
						and not label.contains("economy.") and not label.contains("ideology.")
						and not label.contains("_factor") and not label.contains(".cut"))
					if kind == int(NarrativeEffectSpecScript.Kind.CITY_MODIFIER) \
							or kind == int(NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER):
						var target := String(eff.target_key)
						_expect("%s modifier %s exists in the catalog" % [key, target],
							definitions.has(target))
						var expected := _expected_percent(target, int(eff.magnitude_q16))
						var found := _label_percent(label)
						_expect("%s label states a percentage (%s)" % [key, target], found.has("pct"))
						if found.has("pct") and expected.has("pct"):
							_expect("%s label matches magnitude on %s (label %d vs magnitude %d)" % [
								key, target, int(found["pct"]), int(expected["pct"])],
								absi(int(found["pct"]) - int(expected["pct"])) <= 1)
	if total_options > 0:
		_expect("at least 80%% of options are deterministic",
			float(deterministic) / float(total_options) >= 0.80)
	for meta in NarrativeEventRegistryScript.packs():
		var prefix := String(meta.get("prefix", ""))
		var kinds: Array = kinds_by_pack.get(prefix, [])
		_expect("pack %s exercises at least three effect kinds" % meta.get("id", "?"),
			kinds.size() >= 3)


## 标签里解析出的百分比（带符号）。
func _label_percent(label: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("([+-])([0-9]+(?:\\.[0-9]+)?)%")
	var m := re.search(label)
	if m == null:
		return {}
	var pct := float(m.get_string(2))
	if m.get_string(1) == "-":
		pct = -pct
	return {"pct": int(round(pct))}


## 与 Shared 的构造语义一致：标签上写的百分比应等于这里算出的。
func _expected_percent(target: String, magnitude_q16: int) -> Dictionary:
	var delta := float(magnitude_q16) / 65536.0
	if target.begins_with("economy.city."):
		var pct := int(round(delta * 100.0))
		return {"pct": -pct if target.ends_with(".cut") else pct}
	if target.begins_with("ideology.country.output.") and target.ends_with(".gain"):
		return {"pct": int(round(delta * 100.0))}
	if target == "ideology.country.trade.capacity_factor.gain":
		return {"pct": int(round(delta * 100.0))}
	if target == "ideology.country.construction.cost_factor.cut":
		return {"pct": -int(round(delta * 100.0))}
	if target == "narrative.military.supply_cut":
		return {"pct": -int(round(delta * 10.0))}
	if target == "country.economic_mobilization":
		return {"pct": int(round(delta * 10.0))}
	return {}


# ─── 5. 取舍契约 ────────────────────────────────────────────────────────────

## 代价指纹：.cut 修正 / 人群→国库 / 库存回收 / 延迟到未来的标记与排程 / 抬升风险的偏置。
func _cost_markers(option) -> Array:
	var out: Array = []
	for outcome in option.outcomes:
		for eff in outcome.effects:
			var kind := int(eff.kind)
			var target := String(eff.target_key)
			if kind == int(NarrativeEffectSpecScript.Kind.CITY_MODIFIER) and target.ends_with(".cut"):
				out.append("cut:" + target)
			elif kind == int(NarrativeEffectSpecScript.Kind.CITY_MODIFIER) \
					and target.begins_with("economy.city.need.") \
					and int(eff.magnitude_q16) > 0:
				out.append("need_up:" + target)
			elif kind == int(NarrativeEffectSpecScript.Kind.COHORT_CASH_TO_TREASURY):
				out.append("cash_in")
			elif kind == int(NarrativeEffectSpecScript.Kind.TREASURY_CASH_TO_COHORT):
				out.append("cash_out")
			elif kind == int(NarrativeEffectSpecScript.Kind.MARKET_REMOVE_STOCK):
				out.append("remove:" + target)
			elif kind == int(NarrativeEffectSpecScript.Kind.SET_STORY_FLAG):
				out.append("flag:" + target)
			elif kind == int(NarrativeEffectSpecScript.Kind.SCHEDULE_FOLLOWUP_EVENT):
				out.append("schedule:" + target)
			elif kind == int(NarrativeEffectSpecScript.Kind.ADD_EVENT_WEIGHT_BIAS) \
					and int(eff.magnitude_q16) > 65536:
				out.append("risk:" + target + String(eff.tag_key))
	return out


func _test_tradeoff_contract(catalog) -> void:
	for meta in NarrativeEventRegistryScript.packs():
		var prefix := String(meta.get("prefix", ""))
		var gambles := 0
		for def in _pack_events(catalog, prefix):
			var signatures: Dictionary = {}
			for opt in def.options:
				if opt.outcomes.size() > 1:
					gambles += 1
				var costs := _cost_markers(opt)
				_expect("%s/%s offers no free lunch" % [def.event_id, opt.option_id],
					not costs.is_empty())
				var signature := "|".join(PackedStringArray(costs))
				_expect("%s/%s pays with a distinct currency" % [def.event_id, opt.option_id],
					not signatures.has(signature))
				signatures[signature] = true
		_expect("pack %s contains at least one gamble" % meta.get("id", "?"), gambles >= 1)


# ─── 6. 引用完整性 ──────────────────────────────────────────────────────────

func _all_flags_set(catalog) -> Dictionary:
	var out: Dictionary = {}
	for def in catalog.all_events():
		for opt in def.options:
			for outcome in opt.outcomes:
				for eff in outcome.effects:
					if int(eff.kind) == int(NarrativeEffectSpecScript.Kind.SET_STORY_FLAG):
						out[String(eff.target_key)] = true
	return out


func _all_flags_read(catalog) -> Dictionary:
	var out: Dictionary = {}
	for def in catalog.all_events():
		for flag in def.required_story_flags:
			out[String(flag)] = true
		for flag in def.blocked_story_flags:
			out[String(flag)] = true
		for rule in def.weight_rules:
			var cond = rule.get("condition")
			if cond != null and int(cond.op) == int(NarrativeConditionScript.Op.HAS_STORY_FLAG):
				out[String(cond.target_key)] = true
		for cond in def.conditions:
			if int(cond.op) == int(NarrativeConditionScript.Op.HAS_STORY_FLAG):
				out[String(cond.target_key)] = true
	return out


## 构建期：还没建完的包不应该让跨包引用提前失败。
func _packs_complete() -> bool:
	return NarrativeEventRegistryScript.packs().size() >= 8


func _pending_event(event_id: String) -> bool:
	return not _packs_complete() and not _prefix_by_event.has(event_id)


func _known_pack_id(value: String) -> bool:
	for meta in NarrativeEventRegistryScript.packs():
		if String(meta.get("id", "")) == value:
			return true
	return false


func _test_references(catalog) -> void:
	var setters := _all_flags_set(catalog)
	var readers := _all_flags_read(catalog)
	var technologies: PackedStringArray = PackedStringArray()
	var tech_compiled: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if bool(tech_compiled.get("ok", false)):
		technologies = tech_compiled.get("technology_ids", PackedStringArray())
	var signals: PackedStringArray = PackedStringArray()
	var signal_compiled: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	if bool(signal_compiled.get("ok", false)):
		signals = signal_compiled.get("research_signal_ids", PackedStringArray())

	for def in _web_events(catalog):
		var key := String(def.event_id)
		for req in def.required_events_completed:
			_expect("%s requires an existing event %s" % [key, req],
				(_has_event(catalog, String(req)) or _pending_event(String(req))) and String(req) != key)
		for req in def.required_story_flags:
			_expect("%s requires a flag somebody sets (%s)" % [key, req],
				setters.has(String(req)))
		for blocked in def.blocked_story_flags:
			_expect("%s blocks a flag somebody sets (%s)" % [key, blocked],
				setters.has(String(blocked)))
		for tech in def.required_technologies:
			_expect("%s requires an existing technology %s" % [key, tech],
				technologies.has(String(tech)))
		for opt in def.options:
			for outcome in opt.outcomes:
				for eff in outcome.effects:
					var kind := int(eff.kind)
					var target := String(eff.target_key)
					if kind == int(NarrativeEffectSpecScript.Kind.SCHEDULE_FOLLOWUP_EVENT):
						_expect("%s schedules an existing event %s" % [key, target],
							_has_event(catalog, target) or _pending_event(target))
					elif kind == int(NarrativeEffectSpecScript.Kind.ADD_EVENT_WEIGHT_BIAS):
						if not target.is_empty():
							_expect("%s biases an existing event %s" % [key, target],
								_has_event(catalog, target) or _pending_event(target))
						var tag := String(eff.tag_key)
						if not tag.is_empty():
							var hits := 0
							for other in catalog.all_events():
								if other != null and String(other.event_id) != key and other.tags.has(tag):
									hits += 1
							var pending_tag := hits == 0 and not _packs_complete() and _known_pack_id(tag)
							_expect("%s bias tag %s hits at least one event" % [key, tag],
								hits >= 1 or pending_tag)
					elif kind == int(NarrativeEffectSpecScript.Kind.DISCOVER_RESEARCH_SIGNAL):
						_expect("%s discovers a real research signal %s" % [key, target],
							signals.has(target))
		for opt in def.options:
			for outcome in opt.outcomes:
				for eff in outcome.effects:
					if int(eff.kind) == int(NarrativeEffectSpecScript.Kind.SET_STORY_FLAG):
						_expect("%s sets a flag that is read somewhere (%s)" % [key, eff.target_key],
							readers.has(String(eff.target_key)) or not _packs_complete())


# ─── 7. 图结构 ──────────────────────────────────────────────────────────────

func _hard_inbound(catalog) -> Dictionary:
	var inbound: Dictionary = {}
	for def in _web_events(catalog):
		var key := String(def.event_id)
		if not inbound.has(key):
			inbound[key] = []
		for req in def.required_events_completed:
			if _has_event(catalog, String(req)):
				var parent := String(req)
				if not inbound[key].has(parent):
					inbound[key].append(parent)
		for opt in def.options:
			for outcome in opt.outcomes:
				for eff in outcome.effects:
					if int(eff.kind) == int(NarrativeEffectSpecScript.Kind.SCHEDULE_FOLLOWUP_EVENT):
						var target := String(eff.target_key)
						if not inbound.has(target):
							inbound[target] = []
						if not inbound[target].has(key):
							inbound[target].append(key)
	return inbound


func _has_event(catalog, event_id: String) -> bool:
	return not event_id.is_empty() and catalog.get_event(StringName(event_id)) != null


func _is_entry(def) -> bool:
	# 定时通道只能被上游排程；脉冲与事实通道都由引擎侧的入口触发，算 entry。
	if int(def.trigger_channel) == 2:
		return false
	if not def.required_events_completed.is_empty():
		return false
	if not def.required_story_flags.is_empty():
		return false
	return true


func _test_graph(catalog) -> void:
	var events := _web_events(catalog)
	var inbound := _hard_inbound(catalog)
	var entries: Array = []
	for def in events:
		if _is_entry(def):
			entries.append(String(def.event_id))
	_expect("the web has at least one pulse entry", not entries.is_empty())

	var multi := 0
	for def in events:
		var key := String(def.event_id)
		var parents: Array = inbound.get(key, [])
		if not _is_entry(def):
			_expect("%s has a hard inbound edge" % key, not parents.is_empty())
		if parents.size() >= 2:
			multi += 1
	if NarrativeEventRegistryScript.packs().size() >= 8:
		_expect("at least eight nodes have two or more parents", multi >= 8)
	elif NarrativeEventRegistryScript.packs().size() >= 5:
		_expect("the web already has a few multi-parent nodes", multi >= 2)

	# 跨包边：排程、完成门、标记门都算。
	var cross := 0
	for def in events:
		var key := String(def.event_id)
		var home := _pack_of(key)
		for parent in inbound.get(key, []):
			if _pack_of(parent) != home:
				cross += 1
	if NarrativeEventRegistryScript.packs().size() >= 8:
		_expect("at least eight cross-pack edges", cross >= 8)
	elif NarrativeEventRegistryScript.packs().size() >= 5:
		_expect("cross-pack edges already exist", cross >= 3)

	# 时代窗口：父事件的窗口必须与子事件相交，否则链条永远不可能触发。
	for def in events:
		var key := String(def.event_id)
		for parent_id in inbound.get(key, []):
			var parent = catalog.get_event(StringName(parent_id))
			if parent == null:
				continue
			_expect("%s era window overlaps its parent %s" % [key, parent_id],
				int(parent.min_era_index) <= int(def.max_era_index)
				and int(parent.max_era_index) >= int(def.min_era_index))

	# BFS：从入口沿硬边可达。
	var adjacency: Dictionary = {}
	for target in inbound:
		for parent in inbound[target]:
			var bucket: Array = adjacency.get(parent, [])
			bucket.append(String(target))
			adjacency[parent] = bucket
	var reached: Dictionary = {}
	var queue: Array = entries.duplicate()
	while not queue.is_empty():
		var current: String = queue.pop_back()
		if reached.has(current):
			continue
		reached[current] = true
		for nxt in adjacency.get(current, []):
			if not reached.has(nxt):
				queue.append(nxt)
	for def in events:
		_expect("%s is reachable from an entry" % def.event_id,
			reached.has(String(def.event_id)))


# ─── 8. 触发分层 ────────────────────────────────────────────────────────────

const DIMENSION_OF_OP := {
	1: "climate", 2: "climate", 3: "climate", 4: "climate", 5: "climate", 6: "climate", 7: "climate",
	8: "geography", 9: "geography", 10: "geography", 11: "geography", 12: "geography", 13: "geography",
	14: "geography", 15: "geography", 16: "geography",
	17: "people", 18: "people", 19: "people", 20: "people", 36: "people", 37: "people", 38: "people", 39: "people",
	21: "economy", 22: "economy", 23: "economy", 24: "economy", 25: "economy", 26: "economy", 27: "economy",
	28: "country", 29: "country", 30: "country", 31: "country", 32: "country", 33: "country", 34: "story", 35: "story",
	40: "family", 41: "family", 42: "family", 43: "family", 44: "family",
	45: "war", 46: "war", 47: "war",
}


func _test_trigger_layers(catalog) -> void:
	for def in _web_events(catalog):
		if int(def.trigger_channel) == 2:
			continue
		_expect("%s reads at least two development signals" % def.event_id,
			def.weight_rules.size() >= 2)
		var dimensions: Dictionary = {}
		for rule in def.weight_rules:
			var cond = rule.condition if "condition" in rule else null
			if cond != null:
				dimensions[String(DIMENSION_OF_OP.get(int(cond.op), "other"))] = true
		_expect("%s spans at least two condition dimensions" % def.event_id,
			dimensions.size() >= 2)

	# 合成对照：同一事件在"发达格"的权重必须高于"荒凉格"。
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 24680, catalog)
	for def in _web_events(catalog):
		if int(def.trigger_channel) != 0:
			continue
		var lean := _synthetic_ctx(false)
		var grown := _synthetic_ctx(true)
		var lean_weight := service.evaluate_event_weight(def, lean, 10)
		var grown_weight := service.evaluate_event_weight(def, grown, 10)
		_expect("%s responds to development (%d vs %d)" % [
			def.event_id, lean_weight, grown_weight], grown_weight >= lean_weight)

	# 时代门：空座只在 2–5。
	var seat = catalog.get_event(StringName("evt.court.empty_seat"))
	if seat != null:
		var era1 := _synthetic_ctx(true)
		era1["era_index"] = 1
		_expect("court.empty_seat stays closed before era 2",
			service.evaluate_event_weight(seat, era1, 10) == 0)
		var era6 := _synthetic_ctx(true)
		era6["era_index"] = 6
		_expect("court.empty_seat closes after era 5",
			service.evaluate_event_weight(seat, era6, 10) == 0)
	# 完成门：掌印的人在空座完成前不可入池。
	var regent = catalog.get_event(StringName("evt.court.regent_bargain"))
	if regent != null:
		_expect("court.regent_bargain stays closed until the empty seat is resolved",
			service.evaluate_event_weight(regent, _synthetic_ctx(true), 10) == 0)


func _synthetic_ctx(developed: bool) -> Dictionary:
	if developed:
		return {
			"cell_idx": 7, "era_index": 4, "population": 32,
			"satisfaction_norm": 0.42, "building_count": 8,
			"profession_share_by_id": {"merchant": 0.05, "scholar": 0.03, "artisan": 0.12},
			"technology_ids": PackedStringArray([
				"tech.irrigation", "tech.writing", "tech.guild_apprenticeship",
				"tech.double_entry_bookkeeping", "tech.steam_pumping"]),
			"market_price_ratios_by_id": {"wheat_grain": 1.30, "salt": 1.20},
			"story_flags": {},
		}
	return {
		"cell_idx": 7, "era_index": 4, "population": 9,
		"satisfaction_norm": 0.78, "building_count": 0,
		"profession_share_by_id": {},
		"technology_ids": PackedStringArray(),
		"market_price_ratios_by_id": {},
		"story_flags": {},
	}


# ─── 9. 行为：阻断、市场增补前提、定时链 ────────────────────────────────────

func _test_behaviour(catalog) -> void:
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, null, 1, 13579, catalog)

	# 负向门：边将坐大之后，商人不敢借钱。
	var loan = catalog.get_event(NarrativeEventIdsScript.EVT_FISCAL_STATE_LOAN)
	_expect("state_loan is registered", loan != null)
	if loan != null:
		var open_ctx := _synthetic_ctx(true)
		open_ctx["era_index"] = 5
		_expect("state_loan opens without a warlord",
			service.evaluate_event_weight(loan, open_ctx, 10) > 0)
		var blocked_ctx := open_ctx.duplicate(true)
		blocked_ctx["story_flags"] = {String(NarrativeEventIdsScript.FLAG_WARLORD): true}
		_expect("a warlord blocks state_loan",
			service.evaluate_event_weight(loan, blocked_ctx, 10) == 0)

	# 市场增补：原生要求该格有商人，条件里必须写出来。
	for def in _web_events(catalog):
		var uses_stock := false
		var has_merchant := false
		for opt in def.options:
			for out in opt.outcomes:
				for eff in out.effects:
					if int(eff.kind) == int(NarrativeEffectSpecScript.Kind.MARKET_ADD_STOCK):
						uses_stock = true
		for cond in def.conditions:
			if int(cond.op) == int(NarrativeConditionScript.Op.PROFESSION_SHARE_GTE) \
					and String(cond.target_key) == "merchant":
				has_merchant = true
		if uses_stock:
			_expect("%s stocks goods only where a merchant exists" % def.event_id, has_merchant)

	# 定时链：两方印「发兵」→ 40 日后小钱。
	var seals = catalog.get_event(NarrativeEventIdsScript.EVT_COURT_TWO_SEALS)
	if seals != null:
		var offer := service.enqueue_event_offer(seals, 9, 10, &"", true, {
			"cell_idx": 9, "settlement_name": "测试邑", "era_index": 5,
			"population": 30, "treasury_cash": 400000,
		})
		_expect("two_seals opens as a scheduled beat", not offer.is_empty())
		var choose := service.choose_option(
			int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 1, 11)
		_expect("marching south resolves", bool(choose.get("ok", false)))
		_expect("marching south schedules the thin coin", service.scheduled_events().size() >= 1)
		service.on_day_committed(51, false)
		var later := service.active_offer()
		_expect("the thin coin fires on its due day",
			String(later.get("event_id", "")) == "evt.fiscal.debased_coin")


# ─── 10. 数值对账：标签百分比 = 原生实测乘数 ────────────────────────────────

func _stat_key_for(definition_key: String) -> String:
	if definition_key.begins_with("economy.city."):
		return definition_key.trim_suffix(".cut")
	if definition_key.begins_with("ideology.country.output.") and definition_key.ends_with(".gain"):
		return definition_key.trim_prefix("ideology.").trim_suffix(".gain")
	if definition_key == "ideology.country.trade.capacity_factor.gain":
		return "country.trade.capacity_factor"
	if definition_key == "ideology.country.construction.cost_factor.cut":
		return "country.construction.cost_factor"
	if definition_key == "narrative.military.supply_cut":
		return "country.military.supply_consumption_factor"
	if definition_key == "country.economic_mobilization":
		return "country.economy_output_factor"
	return ""


func _test_runtime_parity(catalog) -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable: runtime parity skipped")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var facade = ModifierFacadeScript.new()
	var configured: Dictionary = facade.configure(ext, 2048)
	_expect("modifier facade configures", bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)):
		return

	var pending: Array = []
	var index := 0
	for def in _web_events(catalog):
		for opt in def.options:
			for out in opt.outcomes:
				for eff in out.effects:
					var kind := int(eff.kind)
					if kind != int(NarrativeEffectSpecScript.Kind.CITY_MODIFIER) \
							and kind != int(NarrativeEffectSpecScript.Kind.COUNTRY_MODIFIER):
						continue
					var stat_key := _stat_key_for(String(eff.target_key))
					_expect("runtime stat mapping exists for %s" % eff.target_key,
						not stat_key.is_empty())
					if stat_key.is_empty():
						continue
					var parsed := _label_percent(String(eff.custom_label))
					if not parsed.has("pct"):
						continue
					index += 1
					var city := kind == int(NarrativeEffectSpecScript.Kind.CITY_MODIFIER)
					var cell := 2 + index
					var entity := 900 + index
					var target: Dictionary = {"domain": 2, "scope": 1, "group_handle": cell} \
						if city else {"domain": 1, "scope": 2, "entity_handle": entity}
					facade.queue_apply(eff.target_key, target, {"type": 0x4E415252, "id": index},
						eff.duration_days, 1, 1, 190, eff.magnitude_q16)
					pending.append({
						"key": String(eff.target_key), "stat": stat_key, "city": city,
						"cell": cell, "entity": entity,
						"expected": 1.0 + float(int(parsed["pct"])) / 100.0,
					})
	_expect("the web exercises at least twenty modifier effects", pending.size() >= 20)
	ext.run_modifier_daily(1)
	for row in pending:
		var actual := float(ext.evaluate_modifier_stat(
			2, 0, int(row["cell"]), String(row["stat"]), 1.0)) if bool(row["city"]) \
			else float(ext.evaluate_modifier_stat(1, int(row["entity"]), 0, String(row["stat"]), 1.0))
		_expect("label of %s matches its runtime factor (%.4f vs %.4f)" % [
			row["key"], actual, float(row["expected"])],
			absf(actual - float(row["expected"])) <= 0.012)
