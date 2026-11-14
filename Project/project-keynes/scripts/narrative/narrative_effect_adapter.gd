class_name NarrativeEffectAdapter
extends RefCounted

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const NARRATIVE_MODIFIER_SOURCE_TYPE: int = 0x4E415252
const NARRATIVE_PRODUCER_ID: int = 190

## falloff=1 的逐环幅度（Q16）：中心 100% / 1 环 60% / 2 环 30%。
const CITY_RADIUS_FALLOFF_Q16: Array[int] = [65536, 39322, 19661]


static func apply_effects(
		effects: Array,
		ctx: Dictionary,
		service,
		generator,
		player_country_handle: int,
		cell_idx: int,
		effective_day: int,
		sequence_alloc: Callable
) -> Dictionary:
	var applied_summaries := PackedStringArray()
	var results: Array[Dictionary] = []

	var modifier_facade = generator.get_modifier_facade() \
		if generator != null and generator.has_method("get_modifier_facade") else null
	var economy_facade = generator.get_economy_facade() \
		if generator != null and generator.has_method("get_economy_facade") else null
	var country_facade = generator.get_country_facade() \
		if generator != null and generator.has_method("get_country_facade") else null

	for raw_effect in effects:
		var spec: NarrativeEffectSpec = null
		if raw_effect is NarrativeEffectSpec:
			spec = raw_effect
		elif raw_effect is Dictionary:
			spec = NarrativeEffectSpecScript.from_dict(raw_effect)
		if spec == null:
			continue
		spec.clamp_safe()
		var item_res := _apply_single_effect(
			spec, ctx, service, modifier_facade, economy_facade, country_facade,
			player_country_handle, cell_idx, effective_day, sequence_alloc
		)
		results.append(item_res)
		var desc := NarrativeEffectSpecScript.format_label(spec.describe(), ctx)
		if not desc.is_empty():
			applied_summaries.append(desc)

	return {
		"ok": true,
		"applied_summaries": applied_summaries,
		"results": results,
	}


static func _apply_single_effect(
		spec: NarrativeEffectSpec,
		ctx: Dictionary,
		service,
		modifier_facade,
		economy_facade,
		country_facade,
		player_country_handle: int,
		cell_idx: int,
		effective_day: int,
		sequence_alloc: Callable
) -> Dictionary:
	var Kind = NarrativeEffectSpecScript.Kind
	match spec.kind:
		Kind.CITY_MODIFIER:
			if modifier_facade == null or not modifier_facade.is_configured() or cell_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind}
			# radius_cells=0 或 ctx 没有邻居数组 → targets 只有当前格，与旧路径完全一致。
			var targets := _resolve_city_modifier_targets(spec, ctx, cell_idx)
			var handles := PackedInt32Array()
			var request_ids := PackedInt64Array()
			var all_ok := true
			for target in targets:
				var target_cell := int(target.get("cell", cell_idx))
				var ring := int(target.get("ring", 0))
				# 每格一个自己的 source id：单格路径本来就是一格一个 id，范围效果沿用同一约定，
				# 这样解绑/到期时各格的修正互不牵连。
				var source_id: int = service.allocate_modifier_source_id() if service != null and service.has_method("allocate_modifier_source_id") else 1
				var req_id: int = modifier_facade.queue_apply(
					spec.target_key,
					{
						"domain": ModifierFacadeScript.Domain.ECONOMY,
						"scope": ModifierFacadeScript.Scope.GROUP,
						"group_handle": target_cell,
					},
					{"type": NARRATIVE_MODIFIER_SOURCE_TYPE, "id": source_id},
					spec.duration_days,
					1,
					effective_day,
					NARRATIVE_PRODUCER_ID,
					_radius_scaled_magnitude_q16(spec.magnitude_q16, ring, spec.falloff)
				)
				handles.append(target_cell)
				request_ids.append(req_id)
				# 一格失败不打断其余格：原生按格排队，没有跨格事务。
				if req_id <= 0:
					all_ok = false
			var result := {
				"ok": all_ok,
				"kind": spec.kind,
				"handles": handles,
				"request_ids": request_ids,
				"radius_cells": spec.radius_cells,
			}
			if not request_ids.is_empty():
				result["request_id"] = int(request_ids[0])
			return result

		Kind.COUNTRY_MODIFIER:
			if modifier_facade == null or not modifier_facade.is_configured() or player_country_handle <= 0:
				return {"ok": true, "simulated": true, "kind": spec.kind}
			var source_id: int = service.allocate_modifier_source_id() if service != null and service.has_method("allocate_modifier_source_id") else 1
			var req_id: int = modifier_facade.queue_apply(
				spec.target_key,
				{
					"domain": ModifierFacadeScript.Domain.COUNTRY,
					"scope": ModifierFacadeScript.Scope.ENTITY,
					"entity_handle": player_country_handle,
				},
				{"type": NARRATIVE_MODIFIER_SOURCE_TYPE, "id": source_id},
				spec.duration_days,
				1,
				effective_day,
				NARRATIVE_PRODUCER_ID,
				spec.magnitude_q16
			)
			return {"ok": req_id > 0, "request_id": req_id, "kind": spec.kind}

		Kind.TREASURY_CASH_TO_COHORT:
			var avail_cash := int(ctx.get("treasury_cash", 0))
			var cohort_handle := int(ctx.get("primary_cohort_handle", 0))
			var raw_amount := spec.int_value
			if raw_amount <= 0 and spec.ratio_bp > 0:
				raw_amount = int((avail_cash * spec.ratio_bp) / 10000)
			var amount := clampi(raw_amount, 0, maxi(0, avail_cash))
			if economy_facade == null or not economy_facade.is_configured() or amount <= 0 or cohort_handle == 0 or player_country_handle <= 0:
				return {"ok": true, "simulated": true, "kind": spec.kind, "amount": amount}
			var seq := _alloc_seq(sequence_alloc)
			var res: Dictionary = economy_facade.transfer_country_cash_to_cohort(
				player_country_handle, cohort_handle, amount, effective_day, seq
			)
			ctx["treasury_cash"] = maxi(0, avail_cash - amount)
			return res

		Kind.COHORT_CASH_TO_TREASURY:
			var avail_cohort_cash := int(ctx.get("primary_cohort_cash", 0))
			var cohort_handle := int(ctx.get("primary_cohort_handle", 0))
			var raw_amount := spec.int_value
			if raw_amount <= 0 and spec.ratio_bp > 0:
				raw_amount = int((avail_cohort_cash * spec.ratio_bp) / 10000)
			var amount := clampi(raw_amount, 0, maxi(0, avail_cohort_cash))
			if economy_facade == null or not economy_facade.is_configured() or amount <= 0 or cohort_handle == 0 or player_country_handle <= 0:
				return {"ok": true, "simulated": true, "kind": spec.kind, "amount": amount}
			var seq := _alloc_seq(sequence_alloc)
			var res: Dictionary = economy_facade.transfer_cohort_cash_to_country(
				cohort_handle, player_country_handle, amount, effective_day, seq
			)
			ctx["primary_cohort_cash"] = maxi(0, avail_cohort_cash - amount)
			return res

		Kind.COUNTRY_GOOD_TO_MARKET:
			var good_str := String(spec.target_key)
			var treas_goods: Dictionary = ctx.get("treasury_goods_by_id", {})
			var avail_qty := int(treas_goods.get(good_str, 0))
			var raw_qty := spec.int_value
			if raw_qty <= 0 and spec.ratio_bp > 0:
				raw_qty = int((avail_qty * spec.ratio_bp) / 10000)
			var qty := clampi(raw_qty, 0, maxi(0, avail_qty))
			if economy_facade == null or not economy_facade.is_configured() or qty <= 0 or cell_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind, "quantity": qty}
			var seq := _alloc_seq(sequence_alloc)
			return economy_facade.transfer_country_good_to_market(
				player_country_handle, cell_idx, spec.target_key, qty, effective_day, seq
			)

		Kind.MARKET_GOOD_TO_COUNTRY:
			var good_str := String(spec.target_key)
			var m_stocks: Dictionary = ctx.get("market_stocks_by_id", {})
			var avail_qty := int(m_stocks.get(good_str, 0))
			var raw_qty := spec.int_value
			if raw_qty <= 0 and spec.ratio_bp > 0:
				raw_qty = int((avail_qty * spec.ratio_bp) / 10000)
			var qty := clampi(raw_qty, 0, maxi(0, avail_qty))
			if economy_facade == null or not economy_facade.is_configured() or qty <= 0 or cell_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind, "quantity": qty}
			var seq := _alloc_seq(sequence_alloc)
			return economy_facade.transfer_market_good_to_country(
				player_country_handle, cell_idx, spec.target_key, qty, effective_day, seq
			)

		Kind.MARKET_ADD_STOCK:
			var qty := maxi(1, spec.int_value)
			if economy_facade == null or not economy_facade.is_configured() or cell_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind, "quantity": qty}
			var seq := _alloc_seq(sequence_alloc)
			return economy_facade.add_stock(cell_idx, spec.target_key, qty, effective_day, seq)

		Kind.MARKET_REMOVE_STOCK:
			var good_str := String(spec.target_key)
			var m_stocks: Dictionary = ctx.get("market_stocks_by_id", {})
			var avail_qty := int(m_stocks.get(good_str, 0))
			var raw_qty := spec.int_value
			if raw_qty <= 0 and spec.ratio_bp > 0:
				raw_qty = int((avail_qty * spec.ratio_bp) / 10000)
			var qty := clampi(raw_qty, 0, maxi(0, avail_qty))
			if economy_facade == null or not economy_facade.is_configured() or qty <= 0 or cell_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind, "quantity": qty}
			var goods: PackedStringArray = economy_facade._catalog.get("good_ids", PackedStringArray()) \
				if "_catalog" in economy_facade else PackedStringArray()
			var good_idx := goods.find(good_str)
			if good_idx < 0:
				return {"ok": false, "reason": "unknown_good_id"}
			var seq := _alloc_seq(sequence_alloc)
			return economy_facade.submit([{
				"opcode": economy_facade.Opcode.REMOVE_STOCK,
				"effective_day": effective_day,
				"sequence": seq,
				"target_handle": 0,
				"i32_0": cell_idx,
				"i32_1": good_idx,
				"i64_0": qty,
				"i64_1": 0,
			}])

		Kind.DISCOVER_RESEARCH_SIGNAL:
			if country_facade == null or not country_facade.is_configured() or player_country_handle <= 0 or cell_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind}
			var signals: PackedStringArray = country_facade.native_catalog().get(
				"research_signal_ids", PackedStringArray())
			var sig_idx := signals.find(String(spec.target_key))
			if sig_idx < 0:
				return {"ok": true, "simulated": true, "kind": spec.kind}
			return country_facade.submit_observation_batch(
				player_country_handle,
				PackedInt32Array([cell_idx]),
				PackedInt32Array([sig_idx]),
				effective_day
			)

		Kind.GRANT_FAMILY_TRAIT, Kind.REMOVE_FAMILY_TRAIT:
			if economy_facade == null or not economy_facade.is_configured() \
					or not economy_facade.has_method("queue_family_trait_mutation"):
				return {"ok": true, "simulated": true, "kind": spec.kind}
			var family_handle := int(ctx.get("primary_family_handle", 0))
			var trait_key := String(spec.target_key).strip_edges()
			if family_handle <= 0 or trait_key.is_empty():
				return {"ok": true, "simulated": true, "kind": spec.kind}
			var grant := int(spec.kind) == int(Kind.GRANT_FAMILY_TRAIT)
			economy_facade.queue_family_trait_mutation(
				family_handle,
				"grant" if grant else "remove",
				spec.target_key,
				clampi(spec.magnitude_q16, 49152, 81920),
				effective_day,
				100,
				_alloc_seq(sequence_alloc))
			return {"ok": true, "kind": spec.kind}

		Kind.SET_STORY_FLAG:
			if service != null and service.has_method("set_story_flag"):
				service.set_story_flag(
					spec.target_key,
					cell_idx if spec.scope_to_cell else -1,
					effective_day,
					spec.duration_days,
					maxi(1, spec.int_value)
				)
			return {"ok": true, "kind": spec.kind}

		Kind.CLEAR_STORY_FLAG:
			if service != null and service.has_method("clear_story_flag"):
				service.clear_story_flag(
					spec.target_key,
					cell_idx if spec.scope_to_cell else -1
				)
			return {"ok": true, "kind": spec.kind}

		Kind.ADD_EVENT_WEIGHT_BIAS:
			if service != null and service.has_method("add_weight_bias"):
				service.add_weight_bias(
					spec.target_key,
					spec.tag_key,
					cell_idx if spec.scope_to_cell else -1,
					spec.int_value,
					spec.magnitude_q16,
					effective_day,
					spec.duration_days
				)
			return {"ok": true, "kind": spec.kind}

		Kind.SCHEDULE_FOLLOWUP_EVENT:
			if service != null and service.has_method("schedule_followup_event"):
				service.schedule_followup_event(
					spec.target_key,
					cell_idx,
					effective_day + maxi(1, spec.duration_days),
					spec.tag_key,
					spec.ai_followup_prompt
				)
			return {"ok": true, "kind": spec.kind}

	return {"ok": true, "kind": spec.kind}


## 目标列表 = 当前格 + r1（radius>=1）+ r2（radius==2）。
## radius_cells=0、或 ctx 里根本没有邻居数组（旧上下文/旧存档）时，退回「只有当前格」的单格路径。
static func _resolve_city_modifier_targets(
		spec: NarrativeEffectSpec, ctx: Dictionary, cell_idx: int) -> Array:
	var targets: Array = [{"cell": cell_idx, "ring": 0}]
	if spec.radius_cells <= 0:
		return targets
	var r1_raw: Variant = ctx.get("nearby_owned_cells_r1", null)
	var r2_raw: Variant = ctx.get("nearby_owned_cells_r2", null)
	if r1_raw == null and r2_raw == null:
		return targets
	var seen: Dictionary = {cell_idx: true}
	_append_city_modifier_targets(targets, seen, r1_raw, 1)
	if spec.radius_cells >= 2:
		_append_city_modifier_targets(targets, seen, r2_raw, 2)
	return targets


static func _append_city_modifier_targets(
		targets: Array, seen: Dictionary, raw: Variant, ring: int) -> void:
	if raw == null or not (raw is Array or raw is PackedInt32Array):
		return
	var count := int(raw.size())
	for i in range(count):
		var target_cell := int(raw[i])
		if target_cell < 0 or seen.has(target_cell):
			continue
		seen[target_cell] = true
		targets.append({"cell": target_cell, "ring": ring})


## falloff=0 → 各环同幅度；falloff=1 → 中心 100% / 1 环 60% / 2 环 30%，按 Q16 定点四舍五入。
static func _radius_scaled_magnitude_q16(base_magnitude_q16: int, ring: int, falloff: int) -> int:
	if falloff <= 0 or ring <= 0:
		return base_magnitude_q16
	var ring_idx := clampi(ring, 0, CITY_RADIUS_FALLOFF_Q16.size() - 1)
	var factor_q16: int = CITY_RADIUS_FALLOFF_Q16[ring_idx]
	return maxi(1, (base_magnitude_q16 * factor_q16 + 32768) >> 16)


static func _alloc_seq(sequence_alloc: Callable) -> int:
	if sequence_alloc.is_valid():
		return int(sequence_alloc.call())
	return 1
