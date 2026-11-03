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

const SCHEMA_NAME := "PKNarrativeRuntime"
const SCHEMA_VERSION := 1
const Q16_ONE := 65536
const DEFAULT_PULSE_INTERVAL_DAYS := 5
const DEFAULT_MIN_POPUP_GAP_DAYS := 15
const MAX_SAMPLED_CELLS_PER_PULSE := 8
const MAX_CHRONICLE_RECORDS := 256
const AI_PREFETCH_LEAD_DAYS := 3
const CONSUMER_ID := &"narrative_event_service"

var pulse_interval_days: int = DEFAULT_PULSE_INTERVAL_DAYS
var min_popup_gap_days: int = DEFAULT_MIN_POPUP_GAP_DAYS
var pulse_trigger_chance_q16: int = 39322 # ~60% per pulse when eligible events exist
var ai_slot_chance_q16: int = 16384 # 25% chance to also pre-warm an AI event when AI is enabled

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
var _last_popup_day: int = -999
var _last_fact_event_id: int = -1

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
	_poll_fact_events(day)
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
			item["ai_requested"] = true
			var country_ctx := NarrativeContextSamplerScript.sample_country_context(
				_map, _generator, _player_country_handle, day, _story_flags)
			var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
				cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)
			ai_generation_requested.emit({
				"day": day,
				"due_day": due_day,
				"cell_idx": cell_idx,
				"chain_id": String(item.get("chain_id", "")),
				"ai_prompt_hint": ai_hint,
				"cell_ctx": cell_ctx,
				"recent_chronicle": get_chronicle(0, 3),
			})
		if day >= due_day:
			if not event_id_str.is_empty():
				var def := resolve_definition(StringName(event_id_str))
				if def != null:
					enqueue_event_offer(def, cell_idx, day, StringName(item.get("chain_id", "")), true)
		else:
			remaining.append(item)
	_scheduled_events = remaining


func _poll_fact_events(day: int) -> void:
	if _generator == null or not _generator.has_method("get_gameplay_event_bus"):
		return
	var bus = _generator.get_gameplay_event_bus()
	if bus == null or not bus.is_available():
		return
	var batch: Dictionary = bus.poll_events(CONSUMER_ID, 64, 0, true, _last_fact_event_id)
	var count := int(batch.get("count", 0))
	if count <= 0:
		return
	var fact_defs := catalog().events_for_channel(NarrativeEventDefinitionScript.TriggerChannel.FACT_DRIVEN)
	if fact_defs.is_empty():
		return
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	var territory: PackedInt32Array = country_ctx.get("territory_cells", PackedInt32Array())
	var types: PackedInt32Array = batch.get("type", PackedInt32Array())
	var cells: PackedInt32Array = batch.get("cell_idx", PackedInt32Array())
	var event_ids: PackedInt64Array = batch.get("event_id", PackedInt64Array())
	for i in range(count):
		if i < event_ids.size():
			_last_fact_event_id = maxi(_last_fact_event_id, int(event_ids[i]))
		var ev_type := int(types[i]) if i < types.size() else int(batch.get("type_scalar", 0))
		var cell_idx := int(cells[i]) if i < cells.size() else -1
		if cell_idx >= 0 and not territory.is_empty() and not territory.has(cell_idx):
			continue
		var resolved_cell := _resolve_valid_player_cell(cell_idx, territory)
		var cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
			resolved_cell, country_ctx, _map, _generator, _view_adapter, _story_flags)
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


func run_pulse_sample(day: int, ai_enabled: bool = false) -> Dictionary:
	if day - _last_popup_day < min_popup_gap_days and (_active_offer.size() > 0 or _ready_queue.size() > 0):
		return {"ok": false, "reason": "popup_cooldown_active"}
	var country_ctx := NarrativeContextSamplerScript.sample_country_context(
		_map, _generator, _player_country_handle, day, _story_flags)
	var territory: PackedInt32Array = country_ctx.get("territory_cells", PackedInt32Array())
	var sampled_cells := _pick_sampled_cells(territory, day)
	if sampled_cells.is_empty():
		sampled_cells.append(-1)

	# Optional AI pre-warm slot
	if ai_enabled:
		var ai_roll := NarrativeRngScript.roll_q16(_world_seed, day, _player_country_handle, sampled_cells[0], 0x4149)
		if ai_roll < ai_slot_chance_q16:
			var target_cell := int(sampled_cells[0])
			var ai_cell_ctx := NarrativeContextSamplerScript.sample_cell_context(
				target_cell, country_ctx, _map, _generator, _view_adapter, _story_flags)
			ai_generation_requested.emit({
				"day": day,
				"due_day": day + 1,
				"cell_idx": target_cell,
				"chain_id": "",
				"ai_prompt_hint": "",
				"cell_ctx": ai_cell_ctx,
				"recent_chronicle": get_chronicle(0, 3),
			})

	var pulse_defs := catalog().events_for_channel(NarrativeEventDefinitionScript.TriggerChannel.PULSE_SAMPLED)
	if pulse_defs.is_empty():
		return {"ok": false, "reason": "no_pulse_events"}

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

	var pulse_gate := NarrativeRngScript.roll_q16(_world_seed, day, _player_country_handle, sampled_cells[0], 0x50554C53)
	if pulse_gate >= pulse_trigger_chance_q16:
		return {"ok": false, "reason": "pulse_roll_skipped"}

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
	if not bypass_gap and (day - _last_popup_day < min_popup_gap_days) and not _active_offer.is_empty():
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
	var next_offer: Dictionary = _ready_queue.pop_front()
	_active_offer = next_offer.duplicate(true)
	_last_popup_day = day
	offer_ready.emit(_active_offer.duplicate(true))


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
		cell_idx, country_ctx, _map, _generator, _view_adapter, _story_flags)

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
	var record := {
		"record_id": record_id,
		"offer_id": offer_id,
		"day": int(_active_offer.get("day", effective_day)),
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
	_last_popup_day = int(state.get("last_popup_day", -999))
	_last_fact_event_id = int(state.get("last_fact_event_id", -1))

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
	_last_popup_day = -999
	_last_fact_event_id = -1
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
