class_name NarrativeOption
extends Resource

const Q16_ONE: int = 65536
const MONEY_SCALE: float = 10000.0
const GOODS_SCALE: float = 1000.0
const NarrativeOutcomeScript = preload("res://scripts/narrative/narrative_outcome.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

@export var option_id: StringName = &""
@export var text: String = ""
@export var tooltip_hint: String = ""
@export var require_treasury_cash: int = 0
@export var require_good_id: StringName = &""
@export var require_good_qty: int = 0
@export var require_technology: StringName = &""
@export var outcomes: Array[Resource] = []


func normalized_probabilities_q16() -> PackedInt32Array:
	var count := outcomes.size()
	var result := PackedInt32Array()
	if count == 0:
		return result
	result.resize(count)
	var total := 0
	for i in range(count):
		var out_res = outcomes[i]
		var w := maxi(1, int(out_res.probability_q16)) if out_res != null else 1
		result[i] = w
		total += w
	if total <= 0:
		result[0] = Q16_ONE
		for i in range(1, count):
			result[i] = 0
		return result
	var assigned := 0
	for i in range(count - 1):
		var norm := int(round(float(result[i]) * float(Q16_ONE) / float(total)))
		norm = clampi(norm, 1, maxi(1, Q16_ONE - assigned - (count - 1 - i)))
		result[i] = norm
		assigned += norm
	result[count - 1] = maxi(1, Q16_ONE - assigned)
	return result


func check_eligibility(ctx: Dictionary) -> Dictionary:
	if require_treasury_cash > 0:
		var cash: int = NarrativeConditionScript._read_int(
			ctx, ["treasury_cash", "country_cash", "cash", "treasury"], 0
		)
		if cash < require_treasury_cash:
			return {
				"ok": false,
				"reason": "国库资金不足（需 %.1f 资金）" % (float(require_treasury_cash) / MONEY_SCALE),
			}
	if not String(require_good_id).is_empty() and require_good_qty > 0:
		var market_stocks: Dictionary = ctx.get("market_stocks_by_id", {})
		var treasury_goods: Dictionary = ctx.get("treasury_goods_by_id", {})
		var key_str := String(require_good_id)
		var available := int(market_stocks.get(key_str, 0)) + int(treasury_goods.get(key_str, 0))
		if available <= 0:
			available = NarrativeConditionScript._read_market_good_stock(ctx, require_good_id)
		if available < require_good_qty:
			return {
				"ok": false,
				"reason": "缺少 %s（需 %.1f 单位）" % [
					NarrativeEffectSpecScript._friendly_good_name(require_good_id),
					float(require_good_qty) / GOODS_SCALE],
			}
	if not String(require_technology).is_empty():
		var has_tech: bool = NarrativeConditionScript._has_key_in_collection(
			ctx, ["technology_ids", "technologies", "unlocked_technologies", "completed_technologies", "techs"], require_technology
		)
		if not has_tech:
			return {
				"ok": false,
				"reason": "缺少科技 %s" % String(require_technology),
			}
	return {"ok": true, "reason": ""}


func to_dict() -> Dictionary:
	var serialized_outcomes: Array[Dictionary] = []
	for out_res in outcomes:
		if out_res != null and out_res.has_method("to_dict"):
			serialized_outcomes.append(out_res.to_dict())
	return {
		"option_id": String(option_id),
		"text": text,
		"tooltip_hint": tooltip_hint,
		"require_treasury_cash": require_treasury_cash,
		"require_good_id": String(require_good_id),
		"require_good_qty": require_good_qty,
		"require_technology": String(require_technology),
		"outcomes": serialized_outcomes,
	}


static func from_dict(d: Dictionary) -> NarrativeOption:
	var opt := NarrativeOption.new()
	opt.option_id = StringName(d.get("option_id", ""))
	opt.text = String(d.get("text", "确认"))
	opt.tooltip_hint = String(d.get("tooltip_hint", ""))
	opt.require_treasury_cash = int(d.get("require_treasury_cash", 0))
	opt.require_good_id = StringName(d.get("require_good_id", ""))
	opt.require_good_qty = int(d.get("require_good_qty", 0))
	opt.require_technology = StringName(d.get("require_technology", ""))
	var raw_outcomes: Array = d.get("outcomes", [])
	for raw in raw_outcomes:
		if raw is Dictionary:
			opt.outcomes.append(NarrativeOutcomeScript.from_dict(raw))
		elif raw is Resource:
			opt.outcomes.append(raw)
	return opt
