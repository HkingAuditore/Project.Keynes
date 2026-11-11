class_name NarrativeEventService
extends RefCounted

signal offer_ready(offer: Dictionary)
signal offer_resolved(record: Dictionary)
signal chronicle_updated()
signal ai_generation_requested(request_spec: Dictionary)

const NarrativeRngScript = preload("res://scripts/narrative/narrative_rng.gd")
const NarrativeContextSamplerScript = preload("res://scripts/narrative/narrative_context_sampler.gd")
const NarrativeEffectAdapterScript = preload("res://scripts/narrative/narrative_effect_adapter.gd")
const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeOptionScript = preload("res://scripts/narrative/narrative_option.gd")
const NarrativeOutcomeScript = preload("res://scripts/narrative/narrative_outcome.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeStateProbeScript = preload("res://scripts/narrative/narrative_state_probe.gd")
const NarrativeStateProbeCatalogScript = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")

const SCHEMA_NAME := "PKNarrativeRuntime"
const SCHEMA_VERSION := 1
const Q16_ONE := 65536

# ─── 触发节奏（Pacing）────────────────────────────────────────────────────────
# 1 现实秒 = 1 游戏天（x1 速度）。旧档的默认节奏约为「每 8 天一次弹窗」（x5 速度下
# 约 1.6 秒一次），实测过于密集，故整体下调约一个数量级：
#   旧：脉冲每 5 天一次 × 60% 放行，且 15 天间隔仅在弹窗未关闭时生效 → 平均 8 天一次
#   新：脉冲每 20 天一次 × 25% 放行，且 60 天间隔对全部弹窗通道无条件生效
# 实测新节奏：1440 天（4 年）内约 10~16 次，平均 90~140 天一次
# （x5 速度下约 18~28 秒一次）。链式/定时事件不受影响。
const DEFAULT_PULSE_INTERVAL_DAYS := 20
const DEFAULT_MIN_POPUP_GAP_DAYS := 60
const MAX_CELL_EVENTS_PER_YEAR := 2
const MAX_SAMPLED_CELLS_PER_PULSE := 8
const MAX_CHRONICLE_RECORDS := 256
const AI_PREFETCH_LEAD_DAYS := 3
const CONSUMER_ID := &"narrative_event_service"
const NEVER_POPPED_DAY := -999

# ─── AI 生成入口（Ingress）────────────────────────────────────────────────────
# AI 事件现在有三个入口：脉冲预热（局势加权）、事实驱动（GameplayEventBus）、
# 定时后续预取。三个入口共用 _last_ai_request_day 节流与「同时只允许一条在途请求」，
# 避免一次战斗刷出十几条 LLM 调用。数值全部是 Q16 / 游戏日。
const AI_MAX_IN_FLIGHT := 1
## 事实类型 → 事件切入点。军事事实的 cell 可能为 -1，由 _resolve_valid_player_cell
## 兜到首都格；未列出的类型（视觉脏标记、epoch 提交、天气观测等）不触发 AI。
const AI_FACT_HINTS := {
	3: "天气锋面过境",        # EVENT_WEATHER_FRONT_CHANGED
	6: "营造完工",            # EVENT_ECONOMY_CONSTRUCTION_COMPLETED
	7: "商队抵达",            # EVENT_ECONOMY_TRADE_ARRIVED
	8: "民生压力上升",        # EVENT_ECONOMY_SOCIAL_PRESSURE
	9: "科研线索被发现",      # EVENT_RESEARCH_SIGNAL_DISCOVERED
	10: "地图地貌新发现",     # EVENT_MAP_FEATURE_DISCOVERED
	13: "技术被采纳",         # EVENT_TECHNOLOGY_ADOPTED
	40: "战事爆发",           # EVENT_MILITARY_WAR_DECLARED
	41: "战事结束",           # EVENT_MILITARY_WAR_ENDED
	42: "会战分出胜负",       # EVENT_MILITARY_BATTLE_RESOLVED
	43: "城池易手",           # EVENT_MILITARY_CELL_CONTROL_CHANGED
	44: "部队被歼",           # EVENT_MILITARY_ARMY_DESTROYED
	45: "国家被吞并",         # EVENT_MILITARY_COUNTRY_ANNEXED
}

# ─── 状态探针与 AI 事件池 ─────────────────────────────────────────────────────
# 状态成立且维持 dwell_days 后才预取；写好的事件先在池子里等着，
# 状态再次成立时才出池。池子就是「下次出现时再触发」的实现，不需要额外调度器。
const STATE_PROBE_INTERVAL_DAYS := 7
const MAX_STATE_PROBE_CELLS := 8
const AI_POOL_MAX_ENTRIES := 24
const AI_POOL_MAX_PER_STATE := 2
const AI_POOL_TTL_DAYS := 730
const AI_POOL_FLUSH_LIMIT := 4

var pulse_interval_days: int = DEFAULT_PULSE_INTERVAL_DAYS
var min_popup_gap_days: int = DEFAULT_MIN_POPUP_GAP_DAYS
var pulse_trigger_chance_q16: int = 16384 # ~25% per pulse when eligible events exist
## 脉冲预热的基础概率；真实概率由 _ai_chance_q16() 按局势在 [base, ai_max_chance_q16] 间抬升。
var ai_slot_chance_q16: int = 2621 # ~4% baseline
## 单条事实触发 AI 的基础概率；同样吃局势加权。
var ai_fact_chance_q16: int = 13107 # ~20% baseline
## 局势拉满（紧缺/不满/极端气候同时出现）时的概率上限。
var ai_max_chance_q16: int = 26214 # ~40% ceiling
## 两次 AI 请求的最小间隔，防止一次战争/一次饥荒把 API 打爆。
## 与全局弹窗间隔同档（60 日）：AI 事件不允许挤占静态事件的展示预算。
var ai_min_request_gap_days: int = 60
## 结果到达时允许的最大滞后（游戏日）。快照是请求日采的，超过窗口直接丢弃，
## 宁可不弹也不再展示「三十天前的天气」。0 或负数表示不设窗口。
var ai_max_staleness_days: int = 60

var _generator = null
var _map = null
var _view_adapter = null
var _world_clock = null
var _catalog: NarrativeEventCatalog = null
var _player_country_handle: int = 0
var _world_seed: int = 1

var _next_offer_id: int = 1
var _next_offer_generation: int = 1
var _next_record_id: int = 1
var _next_bias_id: int = 1
var _next_mod_source_id: int = 1

var _last_pulse_day: int = 0
var _last_popup_day: int = NEVER_POPPED_DAY
var _last_fact_event_id: int = -1
var _cell_year_event_counts: Dictionary = {}

var _last_ai_request_day: int = NEVER_POPPED_DAY
var _next_ai_request_seq: int = 1
## seq → {request_day, cell_idx, chain_id, scheduled_followup, due_day, state_id}。
## 在途请求只活在本次会话；读档后清空，迟到的响应因找不到 seq 被 accept_ai_generation 丢弃。
var _pending_ai_requests: Dictionary = {}

## 状态探针：条件由引擎判定，AI 只写文案。
var state_probe_interval_days: int = STATE_PROBE_INTERVAL_DAYS
var _state_probes: Array = []
var _last_state_probe_day: int = NEVER_POPPED_DAY
## "<state>:<cell>" → {since_day, peak_price_ratio, min_satisfaction}
var _state_tracking: Dictionary = {}
## "<state>:<cell>" → 最近一次预取/出池的日，用于 cooldown。
var _state_last_seed: Dictionary = {}

## 已写好但状态不成立（或被闸门拦住）的 AI 事件。出池时用引擎条件重新校验。
## 每条：{pool_id, state_id, cell_idx, created_day, def_dict}
var _ai_event_pool: Array[Dictionary] = []
var _next_pool_id: int = 1

var _active_offer: Dictionary = {}
var _ready_queue: Array[Dictionary] = []
var _cooldowns: Dictionary = {}
var _completed_one_shots: Dictionary = {}
var _story_flags: Dictionary = {}
var _weight_biases: Array[Dictionary] = []
var _scheduled_events: Array[Dictionary] = []
var _chronicle: Array[Dictionary] = []
var _dynamic_events_by_id: Dictionary = {}


func configure(
		generator,
		map,
		view_adapter,
		world_clock,
		player_country_handle: int,
		world_seed: int,
		catalog: NarrativeEventCatalog = null
) -> void:
	_generator = generator
	_map = map
	_view_adapter = view_adapter
	_world_clock = world_clock
	_player_country_handle = player_country_handle
	_world_seed = maxi(1, world_seed)
	_catalog = catalog if catalog != null else NarrativeEventCatalogScript.build_default_catalog()
	if _state_probes.is_empty():
		_state_probes = NarrativeStateProbeCatalogScript.build_default_probes()


func set_state_probes(probes: Array) -> void:
	_state_probes = probes.duplicate()
	_state_tracking.clear()
	_state_last_seed.clear()


func state_probes() -> Array:
	return _state_probes.duplicate()


func state_probe_by_id(state_id: StringName):
	var key_str := String(state_id)
	if key_str.is_empty():
		return null
	for probe in _state_probes:
		if probe != null and String(probe.state_id) == key_str:
			return probe
	return null


func ai_event_pool() -> Array[Dictionary]:
	return _ai_event_pool.duplicate(true)


func set_player_country_handle(handle: int) -> void:
	_player_country_handle = handle


func catalog() -> NarrativeEventCatalog:
	if _catalog == null:
		_catalog = NarrativeEventCatalogScript.build_default_catalog()
	return _catalog


func active_offer() -> Dictionary:
	return _active_offer.duplicate(true)


func has_active_offer() -> bool:
	return not _active_offer.is_empty()


func ready_queue_size() -> int:
	return _ready_queue.size()


func ready_queue() -> Array[Dictionary]:
	return _ready_queue.duplicate(true)


func promote_next_offer() -> Dictionary:
	if not _active_offer.is_empty():
		return _active_offer.duplicate(true)
	if _ready_queue.is_empty():
		return {}
	var day: int = int(_world_clock.day_index()) if _world_clock != null and _world_clock.has_method("day_index") else _last_pulse_day
	_promote_next_ready_offer(day)
	return _active_offer.duplicate(true)


func allocate_modifier_source_id() -> int:
	var id := _next_mod_source_id
	_next_mod_source_id += 1
	return id


# ─── Story Flags, Weight Biases & Scheduled Followups ────────────────────────

func set_story_flag(
		flag_key: StringName,
		cell_idx: int = -1,
		current_day: int = 0,
		duration_days: int = -1,
		value: int = 1
) -> void:
	var key_str := String(flag_key).strip_edges()
	if key_str.is_empty():
		return
	var full_key := "cell:%d:%s" % [cell_idx, key_str] if cell_idx >= 0 else "country:%s" % key_str
	var expires := -1 if duration_days < 0 else (current_day + duration_days)
	_story_flags[full_key] = {
		"set_day": current_day,
		"expires_day": expires,
		"value": value,
	}


func clear_story_flag(flag_key: StringName, cell_idx: int = -1) -> void:
	var key_str := String(flag_key).strip_edges()
	if key_str.is_empty():
		return
	if cell_idx >= 0:
		_story_flags.erase("cell:%d:%s" % [cell_idx, key_str])
	_story_flags.erase("country:%s" % key_str)
	_story_flags.erase(key_str)


func has_story_flag(flag_key: StringName, cell_idx: int = -1) -> bool:
	var key_str := String(flag_key).strip_edges()
	if key_str.is_empty():
		return false
	if cell_idx >= 0 and _story_flags.has("cell:%d:%s" % [cell_idx, key_str]):
		return true
	return _story_flags.has("country:%s" % key_str) or _story_flags.has(key_str)


func add_weight_bias(
		target_event_id: StringName,
		target_tag: StringName,
		scope_cell: int,
		add_weight: int,
		mul_q16: int,
		current_day: int,
		duration_days: int = 180,
		source_event_id: StringName = &""
) -> int:
	var bias_id := _next_bias_id
	_next_bias_id += 1
	var expires := -1 if duration_days < 0 else (current_day + maxi(1, duration_days))
	_weight_biases.append({
		"id": bias_id,
		"target_event_id": String(target_event_id),
		"target_tag": String(target_tag),
		"scope_cell": scope_cell,
		"add_weight": add_weight,
		"mul_q16": maxi(0, mul_q16),
		"expires_day": expires,
		"source_event_id": String(source_event_id),
	})
	return bias_id


func weight_biases() -> Array[Dictionary]:
	return _weight_biases.duplicate(true)


func schedule_followup_event(
		event_id: StringName,
		cell_idx: int,
		due_day: int,
		chain_id: StringName = &"",
		ai_prompt_hint: String = "",
		parent_record_id: int = 0
) -> void:
	_scheduled_events.append({
		"due_day": maxi(0, due_day),
		"event_id": String(event_id),
		"cell_idx": cell_idx,
		"chain_id": String(chain_id),
		"parent_record_id": parent_record_id,
		"ai_prompt_hint": ai_prompt_hint,
		"ai_requested": false,
	})


func scheduled_events() -> Array[Dictionary]:
	return _scheduled_events.duplicate(true)


func register_dynamic_event(def: NarrativeEventDefinition) -> void:
	if def == null or def.event_id == &"":
		return
	_dynamic_events_by_id[String(def.event_id)] = def.to_dict()


func resolve_definition(event_id: StringName) -> NarrativeEventDefinition:
	var key_str := String(event_id)
	if _dynamic_events_by_id.has(key_str):
		var d: Dictionary = _dynamic_events_by_id[key_str]
		return NarrativeEventDefinitionScript.from_dict(d)
	return catalog().get_event(event_id)


# ─── Daily Tick & Dual-Channel Evaluation ────────────────────────────────────

func on_day_committed(day: int, ai_enabled: bool = false) -> void:
	_prune_expired(day)
	_process_scheduled_events(day, ai_enabled)
	_poll_fact_events(day, ai_enabled)
	_poll_state_probes(day, ai_enabled)
	_flush_ai_pool(day)
	if day - _last_pulse_day >= pulse_interval_days:
		_last_pulse_day = day
		run_pulse_sample(day, ai_enabled)
	_promote_next_ready_offer(day)


func _prune_expired(day: int) -> void:
	var expired_flags: Array = []
	for k in _story_flags:
		var entry: Dictionary = _story_flags[k]
		var exp_day := int(entry.get("expires_day", -1))
		if exp_day >= 0 and day > exp_day:
			expired_flags.append(k)
	for k in expired_flags:
		_story_flags.erase(k)

	var kept_biases: Array[Dictionary] = []
	for b in _weight_biases:
		var exp_day := int(b.get("expires_day", -1))
		if exp_day < 0 or day <= exp_day:
			kept_biases.append(b)
	_weight_biases = kept_biases

	var expired_cd: Array = []
	for k in _cooldowns:
		if day >= int(_cooldowns[k]):
			expired_cd.append(k)
	for k in expired_cd:
		_cooldowns.erase(k)

	# 迟迟不回的请求不能永久占住「同时在途」名额：超过时效窗口即视为作废。
	# 它对应的迟到响应本来就该被 accept_ai_generation 丢掉。
	if ai_max_staleness_days > 0 and not _pending_ai_requests.is_empty():
		var abandoned: Array = []
		for seq in _pending_ai_requests:
			var req_day := int((_pending_ai_requests[seq] as Dictionary).get("request_day", day))
			if day - req_day > ai_max_staleness_days:
				abandoned.append(seq)
		for seq in abandoned:
			_pending_ai_requests.erase(seq)

	# 失去采样的状态跟踪与过期的 cooldown 记录同样要回收，否则长期存档会慢慢膨胀。
	if not _state_tracking.is_empty():
		var stale_tracking: Array = []
		for key in _state_tracking:
			var tracked: Dictionary = _state_tracking[key]
			if day - int(tracked.get("last_seen_day", day)) > 60:
				stale_tracking.append(key)
		for key in stale_tracking:
			_state_tracking.erase(key)
	if not _state_last_seed.is_empty():
		var stale_seed: Array = []
		for key in _state_last_seed:
			if day - int(_state_last_seed[key]) > 730:
				stale_seed.append(key)
		for key in stale_seed:
			_state_last_seed.erase(key)


func _process_scheduled_events(day: int, ai_enabled: bool) -> void:
	if _scheduled_events.is_empty():
		return
	var remaining: Array[Dictionary] = []
	for item in _scheduled_events:
		var due_day := int(item.get("due_day", 0))
		var ai_hint := String(item.get("ai_prompt_hint", "")).strip_edges()
		var event_id_str := String(item.get("event_id", "")).strip_edges()
		var cell_idx := _resolve_valid_player_cell(int(item.get("cell_idx", -1)))
		if not ai_hint.is_empty() and event_id_str.is_empty() and ai_enabled \
				and not bool(item.get("ai_requested", false)) \
				and day >= due_day - AI_PREFETCH_LEAD_DAYS:
			var country_ctx := NarrativeContextSamplerScript.sample_country_context(
				_map, _generator, _player_country_handle, day, _story_flags)
			var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
				cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)
			var seq := _request_ai_generation(
				day, cell_idx, String(item.get("chain_id", "")), ai_hint, "",
				due_day, true, cell_ctx)
			# 被节流/在途占满时不打标，下一天继续试，直到 due_day 前仍有机会预热。
			if seq >= 0:
				item["ai_requested"] = true
		if day >= due_day:
			if not event_id_str.is_empty():
				var def := resolve_definition(StringName(event_id_str))
				if def != null:
					enqueue_event_offer(def, cell_idx, day, StringName(item.get("chain_id", "")), true)
		else:
			remaining.append(item)
	_scheduled_events = remaining


func _poll_fact_events(day: int, ai_enabled: bool = false) -> void:
	if _generator == null or not _generator.has_method("get_gameplay_event_bus"):
		return
	var bus = _generator.get_gameplay_event_bus()
	if bus == null or not bus.is_available():
		return
	var batch: Dictionary = bus.poll_events(CONSUMER_ID, 64, 0, true, _last_fact_event_id)
	var count := int(batch.get("count", 0))
	if count <= 0:
		return
	# Always advance the cursor so stale facts never replay as a burst later.
	var event_ids: PackedInt64Array = batch.get("event_id", PackedInt64Array())
	for i in range(count):
		if i < event_ids.size():
			_last_fact_event_id = maxi(_last_fact_event_id, int(event_ids[i]))
	# 事实驱动通道同样受全局弹窗间隔闸门限制，避免高频事实（市场、人口等）连续弹窗。
	if popup_pacing_blocked(day):
		return
	var fact_defs := catalog().events_for_channel(NarrativeEventDefinitionScript.TriggerChannel.FACT_DRIVEN)
	# AI 关闭且没有静态事实事件时，这批事实没有任何消费者，不必再采样上下文。
	if fact_defs.is_empty() and not ai_enabled:
		return
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	var territory: PackedInt32Array = country_ctx.get("territory_cells", PackedInt32Array())
	var types: PackedInt32Array = batch.get("type", PackedInt32Array())
	var cells: PackedInt32Array = batch.get("cell_idx", PackedInt32Array())
	for i in range(count):
		var ev_type := int(types[i]) if i < types.size() else int(batch.get("type_scalar", 0))
		var cell_idx := int(cells[i]) if i < cells.size() else -1
		if cell_idx >= 0 and not territory.is_empty() and not territory.has(cell_idx):
			continue
		var resolved_cell := _resolve_valid_player_cell(cell_idx, territory)
		var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
			resolved_cell, country_ctx, _map, _generator, _view_adapter, _story_flags)
		# AI 事实通道先跑：它不回退队列，也不会因为静态事实事件命中而 return 掉。
		if ai_enabled:
			_maybe_request_fact_ai(day, ev_type, resolved_cell, cell_ctx)
		for def in fact_defs:
			if def.fact_event_type != 0 and def.fact_event_type != ev_type:
				continue
			var weight := evaluate_event_weight(def, cell_ctx, day)
			if weight <= 0:
				continue
			var roll := NarrativeRngScript.roll_q16(
				_world_seed, day, _player_country_handle, resolved_cell, String(def.event_id).hash() + i)
			if roll < def.trigger_chance_q16:
				enqueue_event_offer(def, resolved_cell, day)
				return


# ─── AI 生成入口：局势加权、事实触发、请求/回执事务 ──────────────────────────
# 设计约束：
# 1) 概率吃局势，但掷骰仍是确定性的（只依赖 world_seed/day/country/cell/salt）；
# 2) 三条入口共用一个节流与一个在途名额，避免一次战事把 API 打爆；
# 3) 请求记录 request_day，回执在 ai_max_staleness_days 内才落地，落地时重新采样，
#    保证「文案里的天气」与「真正结算时的地块状态」不会差出季节。

## 0..100 的局势紧迫度。只读即时快照，不引入历史依赖，便于测试与解释。
static func situation_pressure_score(cell_ctx: Dictionary) -> int:
	if cell_ctx.is_empty():
		return 0
	var score := 0
	# 市场紧缺（最多 30）：每条紧缺 15 分。
	var shortages: Variant = cell_ctx.get("shortage_good_ids",
		cell_ctx.get("shortage_goods", PackedStringArray()))
	var shortage_count := 0
	if shortages is PackedStringArray:
		shortage_count = (shortages as PackedStringArray).size()
	elif shortages is Array:
		shortage_count = (shortages as Array).size()
	score += mini(30, shortage_count * 15)
	# 价格溢价（最多 25）：以 1.30 为紧缺线起算。
	var ratios: Variant = cell_ctx.get("market_price_ratios_by_id",
		cell_ctx.get("market_price_ratios", {}))
	if ratios is Dictionary:
		var worst := 1.0
		for key in (ratios as Dictionary).keys():
			worst = maxf(worst, float((ratios as Dictionary)[key]))
		score += clampi(int(round((worst - 1.3) * 50.0)), 0, 25)
	# 满意度缺口（最多 25）：0.60 以下开始计分。
	var satisfaction := clampf(float(cell_ctx.get("satisfaction_norm",
		cell_ctx.get("satisfaction", 0.65))), 0.0, 1.0)
	score += clampi(int(round((0.6 - satisfaction) * 100.0)), 0, 25)
	# 气候极端（最多 20）：30℃ 以上或 0℃ 以下。
	var temp_c := float(cell_ctx.get("temperature_c", cell_ctx.get("temperature", 15.0)))
	var temp_stress := 0.0
	if temp_c >= 30.0:
		temp_stress = (temp_c - 30.0) / 10.0
	elif temp_c <= 0.0:
		temp_stress = (0.0 - temp_c) / 15.0
	score += clampi(int(round(temp_stress * 20.0)), 0, 20)
	# 积雪（最多 10）。
	var snow := maxf(0.0, float(cell_ctx.get("snow_cover", 0.0)))
	score += clampi(int(round((snow - 0.35) * 40.0)), 0, 10)
	return clampi(score, 0, 100)


## 把基础概率按局势抬到 [base, ai_max_chance_q16]。
func _ai_chance_q16(base_q16: int, cell_ctx: Dictionary) -> int:
	var base := clampi(base_q16, 0, Q16_ONE)
	var cap := clampi(maxi(ai_max_chance_q16, base), 0, Q16_ONE)
	if cap <= base:
		return base
	var score := situation_pressure_score(cell_ctx)
	return clampi(base + int((cap - base) * score / 100), 0, Q16_ONE)


func _ai_request_allowed(day: int) -> bool:
	if _pending_ai_requests.size() >= AI_MAX_IN_FLIGHT:
		return false
	if ai_min_request_gap_days > 0 and _last_ai_request_day > NEVER_POPPED_DAY \
			and day - _last_ai_request_day < ai_min_request_gap_days:
		return false
	return true


## 唯一的 AI 请求出口：分配 seq、登记在途、发信号。返回 -1 表示被节流挡下。
func _request_ai_generation(
		day: int,
		cell_idx: int,
		chain_id: String,
		chain_hint: String,
		fact_hint: String,
		due_day: int,
		scheduled_followup: bool,
		cell_ctx: Dictionary = {},
		state_id: String = "",
		state_hint: String = ""
) -> int:
	if not _ai_request_allowed(day):
		return -1
	var seq := _next_ai_request_seq
	_next_ai_request_seq += 1
	_last_ai_request_day = day
	_pending_ai_requests[seq] = {
		"request_day": day,
		"cell_idx": cell_idx,
		"chain_id": chain_id,
		"scheduled_followup": scheduled_followup,
		"due_day": due_day,
		"state_id": state_id,
	}
	var ctx := cell_ctx
	if ctx.is_empty():
		var country_ctx := NarrativeContextSamplerScript.sample_country_context(
			_map, _generator, _player_country_handle, day, _story_flags)
		ctx = NarrativeContextSamplerScript.sample_cell_context(
			cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)
	ai_generation_requested.emit({
		"ai_request_seq": seq,
		"day": day,
		"due_day": due_day,
		"scheduled_followup": scheduled_followup,
		"cell_idx": cell_idx,
		"chain_id": chain_id,
		"ai_prompt_hint": chain_hint,
		"fact_hint": fact_hint,
		"state_id": state_id,
		"state_hint": state_hint,
		"cell_ctx": ctx,
		"recent_chronicle": get_chronicle(0, 3),
	})
	return seq


func _maybe_request_fact_ai(day: int, ev_type: int, cell_idx: int, cell_ctx: Dictionary) -> void:
	if cell_idx < 0 or not AI_FACT_HINTS.has(ev_type):
		return
	if not _ai_request_allowed(day):
		return
	var chance := _ai_chance_q16(ai_fact_chance_q16, cell_ctx)
	var roll := NarrativeRngScript.roll_q16(
		_world_seed, day, _player_country_handle, cell_idx, 0x464149 + ev_type)
	if roll >= chance:
		return
	var fact_name := String(AI_FACT_HINTS[ev_type])
	var settlement := String(cell_ctx.get("settlement_name", "本地")).strip_edges()
	var fact_hint := "%s（%s，第 %d 日）" % [fact_name, settlement, day]
	_request_ai_generation(day, cell_idx, "", "", fact_hint, day + 1, false, cell_ctx)


# ─── 状态探针：条件成立并维持 dwell_days 天后才预取 ──────────────────────────
# 状态由引擎判定；AI 只写文案。预取结果先不进弹窗队列：
# 状态仍成立 → 立即入队；状态已破/闸门关 → 进池子，等状态下次成立再出池。

func _poll_state_probes(day: int, ai_enabled: bool) -> void:
	if _state_probes.is_empty():
		return
	if state_probe_interval_days > 0 and _last_state_probe_day > NEVER_POPPED_DAY \
			and day - _last_state_probe_day < state_probe_interval_days:
		return
	_last_state_probe_day = day
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	var territory: PackedInt32Array = country_ctx.get("territory_cells", PackedInt32Array())
	if territory.is_empty():
		return
	var cells := _pick_sampled_cells(territory, day)
	# 已在状态里的格子必须继续采样，否则随机抽样会把 dwell 计数打断。
	for key in _state_tracking.keys():
		var tracked: Dictionary = _state_tracking[key]
		var tracked_cell := int(tracked.get("cell", -1))
		if tracked_cell >= 0 and not cells.has(tracked_cell) \
				and cells.size() < MAX_STATE_PROBE_CELLS * 2:
			cells.append(tracked_cell)
	for cell_idx in cells:
		var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
			cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)
		for probe in _state_probes:
			if probe != null and probe.has_method("matches"):
				_evaluate_probe_state(probe, cell_idx, cell_ctx, day, ai_enabled)


func _evaluate_probe_state(
		probe,
		cell_idx: int,
		cell_ctx: Dictionary,
		day: int,
		ai_enabled: bool
) -> void:
	var key := "%s:%d" % [String(probe.state_id), cell_idx]
	if not probe.matches(cell_ctx):
		_state_tracking.erase(key)
		return
	var price_ratio := _max_price_ratio(cell_ctx)
	var satisfaction := clampf(float(cell_ctx.get("satisfaction_norm", 0.65)), 0.0, 1.0)
	var entry: Dictionary = _state_tracking.get(key, {})
	if entry.is_empty():
		entry = {
			"cell": cell_idx,
			"since_day": day,
			"last_seen_day": day,
			"peak_price_ratio": price_ratio,
			"min_satisfaction": satisfaction,
		}
	else:
		entry["last_seen_day"] = day
		entry["peak_price_ratio"] = maxf(
			float(entry.get("peak_price_ratio", price_ratio)), price_ratio)
		entry["min_satisfaction"] = minf(
			float(entry.get("min_satisfaction", satisfaction)), satisfaction)
	_state_tracking[key] = entry
	if not ai_enabled:
		return
	var held_days := day - int(entry.get("since_day", day))
	if held_days < probe.dwell_days:
		return
	if _has_state_request_in_flight(probe.state_id):
		return
	if day - int(_state_last_seed.get(key, NEVER_POPPED_DAY)) < probe.cooldown_days:
		return
	# 池子里已有同状态的稿子：先出池，不花 API。
	if _pool_has_state(probe.state_id):
		if _try_fire_pooled_event(probe.state_id, cell_idx, day):
			_state_last_seed[key] = day
		return
	var hint := _build_state_hint(probe, cell_ctx, held_days, entry)
	var seq := _request_ai_generation(
		day, cell_idx, "", "", "", day + 1, false, cell_ctx,
		String(probe.state_id), hint)
	if seq >= 0:
		_state_last_seed[key] = day


func _build_state_hint(
		probe,
		cell_ctx: Dictionary,
		held_days: int,
		entry: Dictionary
) -> String:
	var parts := PackedStringArray()
	parts.append("状态：%s" % probe.display_name)
	if not probe.prompt_hint.strip_edges().is_empty():
		parts.append(probe.prompt_hint.strip_edges())
	parts.append("已持续 %d 日" % held_days)
	parts.append("本地人口 %d，当前满意度 %.0f%%" % [
		int(cell_ctx.get("population", 0)),
		clampf(float(cell_ctx.get("satisfaction_norm", 0.65)), 0.0, 1.0) * 100.0,
	])
	var shortages: Variant = cell_ctx.get("shortage_good_ids",
		cell_ctx.get("shortage_goods", PackedStringArray()))
	if shortages is PackedStringArray and (shortages as PackedStringArray).size() > 0:
		parts.append("市场紧缺：%s" % ", ".join(shortages as PackedStringArray))
	parts.append("期间最高价格比 %.2f" % float(entry.get("peak_price_ratio", 1.0)))
	parts.append("期间最低满意度 %.0f%%" % (
		clampf(float(entry.get("min_satisfaction", 0.65)), 0.0, 1.0) * 100.0))
	return "；".join(parts)


func _max_price_ratio(cell_ctx: Dictionary) -> float:
	var ratios: Variant = cell_ctx.get("market_price_ratios_by_id", {})
	if ratios is Dictionary:
		var worst := 1.0
		for value in (ratios as Dictionary).values():
			worst = maxf(worst, float(value))
		return worst
	return 1.0


func _has_state_request_in_flight(state_id: StringName) -> bool:
	var key_str := String(state_id)
	for seq in _pending_ai_requests:
		if String((_pending_ai_requests[seq] as Dictionary).get("state_id", "")) == key_str:
			return true
	return false


func _sample_cell_ctx(cell_idx: int, day: int) -> Dictionary:
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	return NarrativeContextSamplerScript.sample_cell_context(
		cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)


# ─── AI 事件池：写好但此刻不能弹的事件 ──────────────────────────────────────

func _pool_has_state(state_id: StringName) -> bool:
	var key_str := String(state_id)
	for entry in _ai_event_pool:
		if String(entry.get("state_id", "")) == key_str:
			return true
	return false


func _try_fire_pooled_event(state_id: StringName, cell_idx: int, day: int) -> bool:
	var key_str := String(state_id)
	var index := 0
	while index < _ai_event_pool.size():
		var entry: Dictionary = _ai_event_pool[index]
		if String(entry.get("state_id", "")) != key_str:
			index += 1
			continue
		var def = NarrativeEventDefinitionScript.from_dict(entry.get("def_dict", {}))
		if def == null or def.event_id == &"":
			_ai_event_pool.remove_at(index)
			continue
		# 出池同样要过全局闸门与年度额度；被拦住就留在池里，改天再试。
		if enqueue_event_offer(def, cell_idx, day, &"", false).is_empty():
			return false
		_ai_event_pool.remove_at(index)
		return true
	return false


func _flush_ai_pool(day: int) -> void:
	if _ai_event_pool.is_empty() or popup_pacing_blocked(day):
		return
	var attempts := 0
	var index := 0
	while index < _ai_event_pool.size() and attempts < AI_POOL_FLUSH_LIMIT:
		var entry: Dictionary = _ai_event_pool[index]
		if day - int(entry.get("created_day", day)) > AI_POOL_TTL_DAYS:
			_ai_event_pool.remove_at(index)
			continue
		var probe = state_probe_by_id(StringName(String(entry.get("state_id", ""))))
		if probe == null:
			_ai_event_pool.remove_at(index)
			continue
		attempts += 1
		var cell_idx := _resolve_valid_player_cell(int(entry.get("cell_idx", -1)))
		if cell_idx < 0:
			index += 1
			continue
		if not probe.matches(_sample_cell_ctx(cell_idx, day)):
			index += 1
			continue
		var def = NarrativeEventDefinitionScript.from_dict(entry.get("def_dict", {}))
		if def == null or def.event_id == &"":
			_ai_event_pool.remove_at(index)
			continue
		if enqueue_event_offer(def, cell_idx, day, &"", false).is_empty():
			index += 1
			continue
		_ai_event_pool.remove_at(index)
		_state_last_seed["%s:%d" % [String(probe.state_id), cell_idx]] = day


func _stash_pooled_event(
		state_id: String,
		def: NarrativeEventDefinition,
		cell_idx: int,
		day: int
) -> void:
	if def == null or def.event_id == &"":
		return
	var same: Array[Dictionary] = []
	var others: Array[Dictionary] = []
	for entry in _ai_event_pool:
		if String(entry.get("state_id", "")) == state_id:
			same.append(entry)
		else:
			others.append(entry)
	while same.size() >= AI_POOL_MAX_PER_STATE:
		same.remove_at(0)
	same.append({
		"pool_id": _next_pool_id,
		"state_id": state_id,
		"cell_idx": cell_idx,
		"created_day": day,
		"def_dict": def.to_dict(),
	})
	_next_pool_id += 1
	_ai_event_pool.clear()
	for entry in others:
		_ai_event_pool.append(entry)
	for entry in same:
		_ai_event_pool.append(entry)
	while _ai_event_pool.size() > AI_POOL_MAX_ENTRIES:
		_ai_event_pool.remove_at(0)


## 回执事务：按 seq 找到请求 → 判时效 → 重新采样 → 入队/改约。控制器只负责转发。
func accept_ai_generation(result: Dictionary, current_day: int = -1) -> Dictionary:
	if result.is_empty():
		return {"ok": false, "code": "ai_result_empty"}
	var seq := int(result.get("ai_request_seq", -1))
	if not _pending_ai_requests.has(seq):
		# 读档清空在途、或请求已被 prune：迟到响应直接丢弃，不污染新世界。
		return {"ok": false, "code": "ai_request_unknown", "ai_request_seq": seq}
	var pending: Dictionary = _pending_ai_requests[seq]
	_pending_ai_requests.erase(seq)
	if not bool(result.get("ok", false)):
		return {"ok": false, "code": String(result.get("code", "ai_generation_failed"))}
	var def = result.get("definition", null)
	if def == null:
		return {"ok": false, "code": "ai_definition_missing"}
	var arrival_day := current_day
	if arrival_day < 0 and _world_clock != null and _world_clock.has_method("day_index"):
		arrival_day = int(_world_clock.day_index())
	if arrival_day < 0:
		arrival_day = int(pending.get("request_day", 0))
	var stale_days := arrival_day - int(pending.get("request_day", arrival_day))
	if ai_max_staleness_days > 0 and stale_days > ai_max_staleness_days:
		return {"ok": false, "code": "ai_result_stale", "stale_days": stale_days}
	var cell_idx := _resolve_valid_player_cell(int(pending.get("cell_idx", -1)))
	var chain_id := StringName(String(pending.get("chain_id", "")))
	if bool(pending.get("scheduled_followup", false)):
		register_dynamic_event(def)
		schedule_followup_event(
			def.event_id, cell_idx,
			maxi(arrival_day, int(pending.get("due_day", arrival_day))), chain_id)
		return {"ok": true, "code": "ok", "scheduled": true, "stale_days": stale_days}
	# 状态探针请求：先复核「到达这一刻」状态是否仍成立，不成立就入池等下次。
	var state_id := String(pending.get("state_id", ""))
	if not state_id.is_empty():
		var probe = state_probe_by_id(StringName(state_id))
		if probe == null or not probe.matches(_sample_cell_ctx(cell_idx, arrival_day)):
			_stash_pooled_event(state_id, def, cell_idx, arrival_day)
			return {"ok": true, "code": "ai_event_pooled", "stale_days": stale_days}
	# 重新采样发生在 enqueue_event_offer 内部：落地用的是「到达这一刻」的地块状态，
	# 只有 body_text 仍出自请求日快照 —— 时效窗口就是它的保质期。
	var offer := enqueue_event_offer(def, cell_idx, arrival_day, chain_id)
	if offer.is_empty():
		if not state_id.is_empty():
			# 闸门或年度额度拦住：稿子不丢，回池等下一次。
			_stash_pooled_event(state_id, def, cell_idx, arrival_day)
			return {"ok": true, "code": "ai_event_pooled", "stale_days": stale_days}
		return {"ok": false, "code": "ai_paced_out", "stale_days": stale_days}
	return {"ok": true, "code": "ok", "offer": offer, "stale_days": stale_days}


# ─── Popup Pacing Gate ───────────────────────────────────────────────────────
# 全局弹窗间隔闸门：对所有非强制通道（脉冲采样、事实驱动、AI 生成）无条件生效，
# 与「当前是否有弹窗在屏」无关。链式后续与定时事件走 bypass_gap，不受此限，
# 以保证剧情链的因果连续性。

func days_until_next_allowed_popup(day: int) -> int:
	if min_popup_gap_days <= 0 or _last_popup_day <= NEVER_POPPED_DAY:
		return 0
	return maxi(0, _last_popup_day + min_popup_gap_days - day)


func popup_pacing_blocked(day: int) -> bool:
	return days_until_next_allowed_popup(day) > 0


func _days_per_year() -> int:
	if _world_clock != null and _world_clock.has_method("days_per_year"):
		return maxi(1, int(_world_clock.days_per_year()))
	return 365


## 事件弹窗与史册只显示日历（第 N 年 · M 月 D 日），不显示第几天、地貌与气温。
## 没有时钟时退回「第 N 日」，只出现在无会话的测试/诊断路径。
func _format_calendar_date(day: int) -> String:
	if _world_clock != null and _world_clock.has_method("calendar_date_for_day"):
		var cal: Dictionary = _world_clock.calendar_date_for_day(day)
		var year_no := 1
		if _world_clock.has_method("year_index_for_day"):
			year_no = int(_world_clock.year_index_for_day(day)) + 1
		return "第%d年 · %d月%d日" % [
			year_no, int(cal.get("month", 1)), int(cal.get("day_of_month", 1))]
	if _world_clock != null and _world_clock.has_method("calendar_date"):
		var cal_now: Dictionary = _world_clock.calendar_date()
		var year_now := int(_world_clock.year_index()) + 1 \
			if _world_clock.has_method("year_index") else 1
		return "第%d年 · %d月%d日" % [
			year_now, int(cal_now.get("month", 1)), int(cal_now.get("day_of_month", 1))]
	return "第 %d 日" % day


func _cell_year_key(cell_idx: int, day: int) -> String:
	return "%d:%d" % [int(floor(float(day) / float(_days_per_year()))), cell_idx]


func cell_year_pacing_blocked(cell_idx: int, day: int) -> bool:
	if cell_idx < 0:
		return false
	return int(_cell_year_event_counts.get(_cell_year_key(cell_idx, day), 0)) >= MAX_CELL_EVENTS_PER_YEAR


func _record_cell_year_event(cell_idx: int, day: int) -> void:
	if cell_idx < 0:
		return
	var key := _cell_year_key(cell_idx, day)
	_cell_year_event_counts[key] = int(_cell_year_event_counts.get(key, 0)) + 1
	# Keep only the current and previous year so long-running games do not grow this map.
	var current_year := int(floor(float(day) / float(_days_per_year())))
	var stale_keys: Array[String] = []
	for old_key in _cell_year_event_counts.keys():
		var parts := String(old_key).split(":")
		if parts.size() >= 2 and int(parts[0]) < current_year - 1:
			stale_keys.append(String(old_key))
	for old_key in stale_keys:
		_cell_year_event_counts.erase(old_key)


func run_pulse_sample(day: int, ai_enabled: bool = false) -> Dictionary:
	if popup_pacing_blocked(day):
		return {"ok": false, "reason": "popup_cooldown_active"}
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	var territory: PackedInt32Array = country_ctx.get("territory_cells", PackedInt32Array())
	var sampled_cells := _pick_sampled_cells(territory, day)
	if sampled_cells.is_empty():
		sampled_cells.append(-1)

	# 脉冲预热槽：概率吃局势（紧缺/不满/极端气候会把 4% 抬到 40% 上限），
	# 掷骰仍只依赖 (seed, day, country, cell, salt)：同一状态下存读档不会换结果。
	if ai_enabled:
		var target_cell := int(sampled_cells[0])
		if target_cell >= 0 and _ai_request_allowed(day):
			var ai_cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
				target_cell, country_ctx, _map, _generator, _view_adapter, _story_flags)
			var ai_chance := _ai_chance_q16(ai_slot_chance_q16, ai_cell_ctx)
			var ai_roll := NarrativeRngScript.roll_q16(
				_world_seed, day, _player_country_handle, target_cell, 0x4149)
			if ai_roll < ai_chance:
				_request_ai_generation(day, target_cell, "", "", "", day + 1, false, ai_cell_ctx)

	var pulse_defs := catalog().events_for_channel(NarrativeEventDefinitionScript.TriggerChannel.PULSE_SAMPLED)
	if pulse_defs.is_empty():
		return {"ok": false, "reason": "no_pulse_events"}

	# Gate first, sample later: the roll only depends on (day, capital cell), so rejecting
	# here skips the expensive 8-cell context scan on the majority of pulses.
	var pulse_gate := NarrativeRngScript.roll_q16(_world_seed, day, _player_country_handle, sampled_cells[0], 0x50554C53)
	if pulse_gate >= pulse_trigger_chance_q16:
		return {"ok": false, "reason": "pulse_roll_skipped"}

	var candidate_defs: Array[NarrativeEventDefinition] = []
	var candidate_cells := PackedInt32Array()
	var candidate_weights := PackedInt64Array()

	for c_idx in sampled_cells:
		var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
			c_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)
		for def in pulse_defs:
			var w := evaluate_event_weight(def, cell_ctx, day)
			if w > 0:
				candidate_defs.append(def)
				candidate_cells.append(c_idx)
				candidate_weights.append(w)

	if candidate_defs.is_empty():
		return {"ok": false, "reason": "no_eligible_events"}

	var picked_idx := NarrativeRngScript.pick_weighted_index(
		candidate_weights, _world_seed, day, _player_country_handle, sampled_cells[0], 0x57474854)
	if picked_idx < 0 or picked_idx >= candidate_defs.size():
		return {"ok": false, "reason": "weighted_pick_empty"}

	var chosen_def := candidate_defs[picked_idx]
	var chosen_cell := int(candidate_cells[picked_idx])
	var chance_roll := NarrativeRngScript.roll_q16(
		_world_seed, day, _player_country_handle, chosen_cell, String(chosen_def.event_id).hash())
	if chance_roll >= chosen_def.trigger_chance_q16:
		return {"ok": false, "reason": "event_chance_skipped"}

	var offer := enqueue_event_offer(chosen_def, chosen_cell, day)
	return {"ok": true, "offer": offer}


func _pick_sampled_cells(territory: PackedInt32Array, day: int) -> PackedInt32Array:
	if territory.size() <= MAX_SAMPLED_CELLS_PER_PULSE:
		return territory.duplicate()
	var out := PackedInt32Array()
	out.append(territory[0]) # Always include capital / first territory cell
	var used := {int(territory[0]): true}
	var attempts := 0
	while out.size() < MAX_SAMPLED_CELLS_PER_PULSE and attempts < MAX_SAMPLED_CELLS_PER_PULSE * 3:
		attempts += 1
		var idx := NarrativeRngScript.roll_range(
			_world_seed, day, _player_country_handle, attempts, 0, territory.size() - 1, 0x43454C4C)
		var cell_val := int(territory[idx])
		if not used.has(cell_val):
			used[cell_val] = true
			out.append(cell_val)
	return out


func evaluate_event_weight(def: NarrativeEventDefinition, cell_ctx: Dictionary, day: int) -> int:
	if def == null or def.event_id == &"":
		return 0
	var ev_id_str := String(def.event_id)
	if def.one_shot and _completed_one_shots.has(ev_id_str):
		return 0
	var cell_idx := int(cell_ctx.get("cell_idx", -1))
	var cd_key := _cooldown_key(ev_id_str, def.scope, cell_idx)
	if _cooldowns.has(cd_key) and day < int(_cooldowns[cd_key]):
		return 0

	var era_idx := int(cell_ctx.get("era_index", 0))
	if era_idx < def.min_era_index or era_idx > def.max_era_index:
		return 0

	var techs: PackedStringArray = cell_ctx.get("technology_ids", PackedStringArray())
	for req_tech in def.required_technologies:
		if not String(req_tech).is_empty() and not techs.has(String(req_tech)):
			return 0
	for blk_tech in def.blocked_technologies:
		if not String(blk_tech).is_empty() and techs.has(String(blk_tech)):
			return 0

	for req_ev in def.required_events_completed:
		if not String(req_ev).is_empty() and not _completed_one_shots.has(String(req_ev)):
			return 0

	var flags: Dictionary = cell_ctx.get("story_flags", {})
	for req_flag in def.required_story_flags:
		var fk := String(req_flag)
		if not fk.is_empty() and not flags.has(fk) and not has_story_flag(StringName(fk), cell_idx):
			return 0
	for blk_flag in def.blocked_story_flags:
		var fk := String(blk_flag)
		if not fk.is_empty() and (flags.has(fk) or has_story_flag(StringName(fk), cell_idx)):
			return 0

	for cond in def.conditions:
		if cond != null and cond.has_method("evaluate"):
			if not bool(cond.evaluate(cell_ctx)):
				return 0

	var add_sum: int = def.base_weight
	var mul_q16_acc: int = Q16_ONE

	for rule in def.weight_rules:
		if rule == null:
			continue
		var matched := false
		if rule.has_method("matches"):
			matched = bool(rule.matches(cell_ctx))
		elif rule.has_method("evaluate_rule"):
			matched = bool(rule.evaluate_rule(cell_ctx))
		if matched:
			add_sum += int(rule.add_weight)
			mul_q16_acc = int((mul_q16_acc * maxi(0, int(rule.multiplier_q16))) / Q16_ONE)

	for bias in _weight_biases:
		var b_cell := int(bias.get("scope_cell", -1))
		if b_cell >= 0 and b_cell != cell_idx:
			continue
		var b_ev := String(bias.get("target_event_id", ""))
		var b_tag := String(bias.get("target_tag", ""))
		var matches_ev := not b_ev.is_empty() and b_ev == ev_id_str
		var matches_tag := not b_tag.is_empty() and def.tags.has(b_tag)
		if matches_ev or matches_tag:
			add_sum += int(bias.get("add_weight", 0))
			var b_mul := int(bias.get("mul_q16", Q16_ONE))
			if b_mul > 0:
				mul_q16_acc = int((mul_q16_acc * b_mul) / Q16_ONE)

	var final_weight := int((maxi(0, add_sum) * maxi(0, mul_q16_acc)) / Q16_ONE)
	return clampi(final_weight, 0, 1000000)


func enqueue_event_offer(
		def: NarrativeEventDefinition,
		cell_idx: int,
		day: int,
		chain_id: StringName = &"",
		bypass_gap: bool = false,
		custom_ctx: Dictionary = {}
) -> Dictionary:
	if def == null:
		return {}
	if not bypass_gap and popup_pacing_blocked(day):
		return {}
	# Scheduled follow-ups explicitly bypass pacing so authored chains remain intact;
	# ordinary pulse/fact/AI events are capped at two visible events per cell-year.
	if not bypass_gap and cell_year_pacing_blocked(cell_idx, day):
		return {}
	if def.is_ai_generated:
		register_dynamic_event(def)

	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	var cell_ctx := custom_ctx if not custom_ctx.is_empty() else NarrativeContextSamplerScript.sample_cell_context(
		cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)

	var ev_id_str := String(def.event_id)
	if def.cooldown_days > 0:
		var cd_key := _cooldown_key(ev_id_str, def.scope, cell_idx)
		_cooldowns[cd_key] = day + def.cooldown_days

	# Apply immediate on_trigger_effects (e.g., encountering event A boosts probability of event B)
	var on_trigger_summaries := PackedStringArray()
	if not def.on_trigger_effects.is_empty():
		var trig_res := NarrativeEffectAdapterScript.apply_effects(
			def.on_trigger_effects, cell_ctx, self, _generator,
			_player_country_handle, cell_idx, day + 1, Callable()
		)
		on_trigger_summaries = trig_res.get("applied_summaries", PackedStringArray())

	var offer_id := _next_offer_id
	_next_offer_id += 1
	var offer_gen := _next_offer_generation
	_next_offer_generation += 1

	var formatted_title := NarrativeEventDefinitionScript.format_text(def.title, cell_ctx)
	var formatted_body := NarrativeEventDefinitionScript.format_text(def.body_text, cell_ctx)

	var options_payload: Array[Dictionary] = []
	for opt_idx in range(def.options.size()):
		var opt: NarrativeOption = def.options[opt_idx] as NarrativeOption
		if opt == null:
			continue
		var elig := opt.check_eligibility(cell_ctx)
		var norm_probs := opt.normalized_probabilities_q16()
		var outcomes_payload: Array[Dictionary] = []
		for out_idx in range(opt.outcomes.size()):
			var out_res: NarrativeOutcome = opt.outcomes[out_idx] as NarrativeOutcome
			if out_res == null:
				continue
			var prob_q16 := int(norm_probs[out_idx]) if out_idx < norm_probs.size() else Q16_ONE
			var prob_pct := int(round(float(prob_q16) * 100.0 / float(Q16_ONE)))
			var eff_lines := PackedStringArray()
			for eff in out_res.effects:
				if eff != null and eff.has_method("describe"):
					eff_lines.append(String(eff.describe()))
			outcomes_payload.append({
				"probability_q16": prob_q16,
				"probability_percent": prob_pct,
				"outcome_title": NarrativeEventDefinitionScript.format_text(out_res.outcome_title, cell_ctx),
				"outcome_narrative": NarrativeEventDefinitionScript.format_text(out_res.outcome_narrative, cell_ctx),
				"effect_summaries": eff_lines,
				"effects": out_res.to_dict().get("effects", []),
			})
		options_payload.append({
			"index": opt_idx,
			"option_id": String(opt.option_id),
			"text": NarrativeEventDefinitionScript.format_text(opt.text, cell_ctx),
			"tooltip_hint": NarrativeEventDefinitionScript.format_text(opt.tooltip_hint, cell_ctx),
			"eligible": bool(elig.get("ok", true)),
			"ineligible_reason": String(elig.get("reason", "")),
			"outcomes": outcomes_payload,
		})

	var offer := {
		"offer_id": offer_id,
		"offer_generation": offer_gen,
		"event_id": ev_id_str,
		"day": day,
		"date_text": _format_calendar_date(day),
		"cell_idx": cell_idx,
		"settlement_name": String(cell_ctx.get("settlement_name", "本地")),
		"terrain_name": String(cell_ctx.get("terrain_name", "")),
		"landform_name": String(cell_ctx.get("landform_name", "")),
		"temperature": float(cell_ctx.get("temperature", 18.0)),
		"title": formatted_title,
		"body_text": formatted_body,
		"image_key": String(def.image_key),
		"image_path": def.image_path,
		"ai_visual_prompt": def.ai_visual_prompt,
		"tags": Array(def.tags),
		"chain_id": String(chain_id),
		"bypass_pacing": bypass_gap,
		"is_ai_generated": def.is_ai_generated,
		"one_shot": def.one_shot,
		"on_trigger_summaries": Array(on_trigger_summaries),
		"options": options_payload,
	}

	_ready_queue.append(offer)
	_promote_next_ready_offer(day)
	return offer


func _promote_next_ready_offer(day: int) -> void:
	if not _active_offer.is_empty() or _ready_queue.is_empty():
		return
	var index := 0
	while index < _ready_queue.size():
		var next_offer: Dictionary = _ready_queue[index]
		var scheduled_followup := bool(next_offer.get("bypass_pacing", false))
		if not scheduled_followup:
			# 旧档与异步入队也必须在真正展示时复核额度，不能积压后连弹。
			if cell_year_pacing_blocked(int(next_offer.get("cell_idx", -1)), day):
				_ready_queue.remove_at(index)
				continue
			if popup_pacing_blocked(day):
				index += 1
				continue
		_ready_queue.remove_at(index)
		_active_offer = next_offer.duplicate(true)
		_last_popup_day = day
		if not scheduled_followup:
			_record_cell_year_event(int(_active_offer.get("cell_idx", -1)), day)
		offer_ready.emit(_active_offer.duplicate(true))
		return


func choose_option(
		offer_id: int,
		offer_generation: int,
		option_index: int,
		effective_day: int,
		sequence_alloc: Callable = Callable()
) -> Dictionary:
	if _active_offer.is_empty():
		return {"ok": false, "code": "narrative_no_active_offer", "message": "当前没有待处理的事件。"}
	if int(_active_offer.get("offer_id", -1)) != offer_id \
			or int(_active_offer.get("offer_generation", -1)) != offer_generation:
		return {"ok": false, "code": "narrative_offer_mismatch", "message": "事件已过期。"}
	var options: Array = _active_offer.get("options", [])
	if option_index < 0 or option_index >= options.size():
		return {"ok": false, "code": "narrative_option_invalid", "message": "选项无效。"}
	var chosen_opt: Dictionary = options[option_index]
	if not bool(chosen_opt.get("eligible", true)):
		return {
			"ok": false,
			"code": "narrative_option_ineligible",
			"message": String(chosen_opt.get("ineligible_reason", "条件不满足。")),
		}

	var cell_idx := int(_active_offer.get("cell_idx", -1))
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, effective_day, _story_flags)
	var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
		cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags, true)

	var outcomes: Array = chosen_opt.get("outcomes", [])
	var outcome_idx := 0
	var chosen_outcome := {
		"probability_q16": Q16_ONE,
		"probability_percent": 100,
		"outcome_title": "尘埃落定",
		"outcome_narrative": "",
		"effects": [],
	}
	if not outcomes.is_empty():
		var weights := PackedInt64Array()
		for out_item in outcomes:
			weights.append(maxi(1, int((out_item as Dictionary).get("probability_q16", Q16_ONE))))
		var salt := offer_id * 131 + option_index * 17 + 7
		outcome_idx = NarrativeRngScript.pick_weighted_index(
			weights, _world_seed, effective_day, _player_country_handle, cell_idx, salt)
		outcome_idx = clampi(outcome_idx, 0, outcomes.size() - 1)
		chosen_outcome = outcomes[outcome_idx]

	var raw_effects: Array = chosen_outcome.get("effects", [])
	var effect_res := NarrativeEffectAdapterScript.apply_effects(
		raw_effects, cell_ctx, self, _generator,
		_player_country_handle, cell_idx, effective_day, sequence_alloc
	)
	var applied_summaries: PackedStringArray = effect_res.get("applied_summaries", PackedStringArray())

	var ev_id_str := String(_active_offer.get("event_id", ""))
	_completed_one_shots[ev_id_str] = effective_day

	var year_idx: int = int(_world_clock.year_index()) if _world_clock != null and _world_clock.has_method("year_index") else 1
	var record_id := _next_record_id
	_next_record_id += 1
	var record_day := int(_active_offer.get("day", effective_day))
	var record_date_text := String(_active_offer.get("date_text", "")).strip_edges()
	if record_date_text.is_empty():
		record_date_text = _format_calendar_date(record_day)
	var record := {
		"record_id": record_id,
		"offer_id": offer_id,
		"day": record_day,
		"date_text": record_date_text,
		"resolved_day": effective_day,
		"year": year_idx,
		"cell_idx": cell_idx,
		"settlement_name": String(_active_offer.get("settlement_name", "本地")),
		"event_id": ev_id_str,
		"title": String(_active_offer.get("title", "")),
		"body_text": String(_active_offer.get("body_text", "")),
		"image_key": String(_active_offer.get("image_key", "")),
		"image_path": String(_active_offer.get("image_path", "")),
		"tags": _active_offer.get("tags", []),
		"chain_id": String(_active_offer.get("chain_id", "")),
		"is_ai_generated": bool(_active_offer.get("is_ai_generated", false)),
		"chosen_option_index": option_index,
		"chosen_option_text": String(chosen_opt.get("text", "")),
		"rolled_outcome_index": outcome_idx,
		"outcome_probability_percent": int(chosen_outcome.get("probability_percent", 100)),
		"outcome_title": String(chosen_outcome.get("outcome_title", "")),
		"outcome_narrative": String(chosen_outcome.get("outcome_narrative", "")),
		"applied_effects_summary": Array(applied_summaries),
	}

	_chronicle.push_front(record)
	if _chronicle.size() > MAX_CHRONICLE_RECORDS:
		_chronicle.resize(MAX_CHRONICLE_RECORDS)

	_active_offer.clear()
	offer_resolved.emit(record.duplicate(true))
	chronicle_updated.emit()

	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"effective_day": effective_day,
		"outcome_index": outcome_idx,
		"outcome": chosen_outcome.duplicate(true),
		"applied_summaries": applied_summaries,
		"record": record.duplicate(true),
	}


func get_chronicle(offset: int = 0, limit: int = 64, filter_cell: int = -1) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for rec in _chronicle:
		if filter_cell >= 0 and int(rec.get("cell_idx", -1)) != filter_cell:
			continue
		filtered.append(rec)
	var start := clampi(offset, 0, filtered.size())
	var end := mini(filtered.size(), start + maxi(1, limit))
	return filtered.slice(start, end)


func chronicle_total_count(filter_cell: int = -1) -> int:
	if filter_cell < 0:
		return _chronicle.size()
	var count := 0
	for rec in _chronicle:
		if int(rec.get("cell_idx", -1)) == filter_cell:
			count += 1
	return count


func update_offer_image_path(event_id: StringName, image_path: String) -> void:
	var key_str := String(event_id)
	if not _active_offer.is_empty() and String(_active_offer.get("event_id", "")) == key_str:
		_active_offer["image_path"] = image_path
	for i in range(_ready_queue.size()):
		if String(_ready_queue[i].get("event_id", "")) == key_str:
			_ready_queue[i]["image_path"] = image_path
	for i in range(_chronicle.size()):
		if String(_chronicle[i].get("event_id", "")) == key_str:
			_chronicle[i]["image_path"] = image_path
	if _dynamic_events_by_id.has(key_str):
		_dynamic_events_by_id[key_str]["image_path"] = image_path


# ─── Persistence (pknr Section) ──────────────────────────────────────────────

func export_state() -> Dictionary:
	return {
		"schema": SCHEMA_NAME,
		"version": SCHEMA_VERSION,
		"world_seed": _world_seed,
		"player_country_handle": _player_country_handle,
		"next_offer_id": _next_offer_id,
		"next_offer_generation": _next_offer_generation,
		"next_record_id": _next_record_id,
		"next_bias_id": _next_bias_id,
		"next_mod_source_id": _next_mod_source_id,
		"last_pulse_day": _last_pulse_day,
		"last_popup_day": _last_popup_day,
		"last_fact_event_id": _last_fact_event_id,
		# 可选字段：旧档没有这两个键时按默认值恢复，因此 SCHEMA_VERSION 不需要 bump。
		"last_ai_request_day": _last_ai_request_day,
		"next_ai_request_seq": _next_ai_request_seq,
		"ai_event_pool": _ai_event_pool.duplicate(true),
		"next_pool_id": _next_pool_id,
		"state_tracking": _state_tracking.duplicate(true),
		"state_last_seed": _state_last_seed.duplicate(true),
		"cell_year_event_counts": _cell_year_event_counts.duplicate(true),
		"active_offer": _active_offer.duplicate(true),
		"ready_queue": _ready_queue.duplicate(true),
		"cooldowns": _cooldowns.duplicate(true),
		"completed_one_shots": _completed_one_shots.duplicate(true),
		"story_flags": _story_flags.duplicate(true),
		"weight_biases": _weight_biases.duplicate(true),
		"scheduled_events": _scheduled_events.duplicate(true),
		"chronicle": _chronicle.duplicate(true),
		"dynamic_events_by_id": _dynamic_events_by_id.duplicate(true),
	}


func restore_state(state: Dictionary) -> Dictionary:
	if state.is_empty():
		_reset_empty()
		return {"ok": true, "code": "ok"}
	if String(state.get("schema", "")) != SCHEMA_NAME \
			or int(state.get("version", 0)) != SCHEMA_VERSION:
		return {
			"ok": false,
			"code": "pknr_schema_incompatible",
			"reason": "叙事事件存档 section 版本不兼容。",
		}
	_world_seed = maxi(1, int(state.get("world_seed", _world_seed)))
	_player_country_handle = int(state.get("player_country_handle", _player_country_handle))
	_next_offer_id = maxi(1, int(state.get("next_offer_id", 1)))
	_next_offer_generation = maxi(1, int(state.get("next_offer_generation", 1)))
	_next_record_id = maxi(1, int(state.get("next_record_id", 1)))
	_next_bias_id = maxi(1, int(state.get("next_bias_id", 1)))
	_next_mod_source_id = maxi(1, int(state.get("next_mod_source_id", 1)))
	_last_pulse_day = int(state.get("last_pulse_day", 0))
	_last_popup_day = int(state.get("last_popup_day", NEVER_POPPED_DAY))
	_last_fact_event_id = int(state.get("last_fact_event_id", -1))
	_last_ai_request_day = int(state.get("last_ai_request_day", NEVER_POPPED_DAY))
	_next_ai_request_seq = maxi(1, int(state.get("next_ai_request_seq", 1)))
	# 在途请求不跨存档：seq 不会恢复，迟到的响应找不到登记项，由 accept_ai_generation 丢弃。
	_pending_ai_requests.clear()
	# 池子与状态跟踪跨档保留：写好的稿子不该因为读档而丢；dwell 计数继续。
	_ai_event_pool.clear()
	for raw_pool in state.get("ai_event_pool", []):
		if raw_pool is Dictionary and not (raw_pool as Dictionary).is_empty():
			_ai_event_pool.append((raw_pool as Dictionary).duplicate(true))
	while _ai_event_pool.size() > AI_POOL_MAX_ENTRIES:
		_ai_event_pool.remove_at(0)
	_next_pool_id = maxi(1, int(state.get("next_pool_id", 1)))
	var raw_tracking = state.get("state_tracking", {})
	_state_tracking = (raw_tracking as Dictionary).duplicate(true) if raw_tracking is Dictionary else {}
	var raw_seed_day = state.get("state_last_seed", {})
	_state_last_seed = (raw_seed_day as Dictionary).duplicate(true) if raw_seed_day is Dictionary else {}
	# 读档后立即重探一次，旧档里没有这些字段时也能自愈。
	_last_state_probe_day = NEVER_POPPED_DAY
	var raw_cell_counts = state.get("cell_year_event_counts", {})
	_cell_year_event_counts = (raw_cell_counts as Dictionary).duplicate(true) if raw_cell_counts is Dictionary else {}

	var raw_active = state.get("active_offer", {})
	_active_offer = (raw_active as Dictionary).duplicate(true) if raw_active is Dictionary else {}

	_ready_queue.clear()
	for item in state.get("ready_queue", []):
		if item is Dictionary:
			_ready_queue.append((item as Dictionary).duplicate(true))

	var raw_cd = state.get("cooldowns", {})
	_cooldowns = (raw_cd as Dictionary).duplicate(true) if raw_cd is Dictionary else {}

	var raw_os = state.get("completed_one_shots", {})
	_completed_one_shots = (raw_os as Dictionary).duplicate(true) if raw_os is Dictionary else {}

	var raw_flags = state.get("story_flags", {})
	_story_flags = (raw_flags as Dictionary).duplicate(true) if raw_flags is Dictionary else {}

	_weight_biases.clear()
	for b in state.get("weight_biases", []):
		if b is Dictionary:
			_weight_biases.append((b as Dictionary).duplicate(true))

	_scheduled_events.clear()
	for s in state.get("scheduled_events", []):
		if s is Dictionary:
			var copy_s := (s as Dictionary).duplicate(true)
			# Reset in-flight AI flag so a reload before arrival can re-request cleanly
			copy_s["ai_requested"] = false
			_scheduled_events.append(copy_s)

	_chronicle.clear()
	for c in state.get("chronicle", []):
		if c is Dictionary:
			_chronicle.append((c as Dictionary).duplicate(true))

	var raw_dyn = state.get("dynamic_events_by_id", {})
	_dynamic_events_by_id = (raw_dyn as Dictionary).duplicate(true) if raw_dyn is Dictionary else {}

	return {"ok": true, "code": "ok"}


func _reset_empty() -> void:
	_next_offer_id = 1
	_next_offer_generation = 1
	_next_record_id = 1
	_next_bias_id = 1
	_next_mod_source_id = 1
	_last_pulse_day = 0
	_last_popup_day = NEVER_POPPED_DAY
	_last_fact_event_id = -1
	_last_ai_request_day = NEVER_POPPED_DAY
	_next_ai_request_seq = 1
	_pending_ai_requests.clear()
	_ai_event_pool.clear()
	_next_pool_id = 1
	_state_tracking.clear()
	_state_last_seed.clear()
	_last_state_probe_day = NEVER_POPPED_DAY
	_cell_year_event_counts.clear()
	_active_offer.clear()
	_ready_queue.clear()
	_cooldowns.clear()
	_completed_one_shots.clear()
	_story_flags.clear()
	_weight_biases.clear()
	_scheduled_events.clear()
	_chronicle.clear()
	_dynamic_events_by_id.clear()


func _cooldown_key(event_id_str: String, scope: int, cell_idx: int) -> String:
	if scope == NarrativeEventDefinitionScript.Scope.CELL and cell_idx >= 0:
		return "cell:%d:%s" % [cell_idx, event_id_str]
	return "country:%s" % event_id_str


func _resolve_valid_player_cell(cell_idx: int, territory: PackedInt32Array = PackedInt32Array()) -> int:
	var owned := territory
	if owned.is_empty() and _generator != null and _player_country_handle > 0:
		var country_facade = _generator.get_country_facade() \
			if _generator.has_method("get_country_facade") else null
		if country_facade != null and country_facade.has_method("snapshot"):
			owned = country_facade.snapshot(_player_country_handle).get(
				"territory_cells", PackedInt32Array())
	if cell_idx >= 0 and (owned.is_empty() or owned.has(cell_idx)):
		return cell_idx
	if not owned.is_empty():
		return int(owned[0])
	return cell_idx
