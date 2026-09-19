class_name SettlementProfile
extends Resource

@export var tier_ids := PackedStringArray([
	"wilderness", "settlement", "rural", "town",
	"county_seat", "city", "metropolis", "megacity",
])
@export var tier_names := PackedStringArray([
	"无人区", "聚落", "乡村", "小镇", "县城", "城市", "都市", "特大都市",
])
@export var population_thresholds := PackedInt64Array([
	0, 1, 100, 500, 2500, 12500, 62500, 312500,
])
@export_range(1, 31, 1) var named_tier: int = 2
@export_range(1, 10000, 1) var downgrade_hysteresis_bp: int = 9000
@export var name_pack: SettlementNamePackProfile


func compile_native_columns() -> Dictionary:
	if tier_ids.size() < 2 or tier_ids.size() > 32 \
			or tier_ids.size() != tier_names.size() \
			or tier_ids.size() != population_thresholds.size() \
			or population_thresholds[0] != 0 \
			or named_tier <= 0 or named_tier >= tier_ids.size() \
			or name_pack == null:
		return {"ok": false, "reason": "settlement_profile_invalid"}
	for index in range(1, population_thresholds.size()):
		if population_thresholds[index] <= population_thresholds[index - 1]:
			return {"ok": false, "reason": "settlement_thresholds_not_strict"}
	var names := name_pack.compile_native_columns()
	if not bool(names.get("ok", false)):
		return names
	var out := {
		"ok": true,
		"prosperity_ids": tier_ids,
		"prosperity_names": tier_names,
		"prosperity_thresholds": population_thresholds,
		"settlement_named_tier": named_tier,
		"settlement_downgrade_bp": downgrade_hysteresis_bp,
		"prosperity_profile_hash": hash([
			tier_ids, population_thresholds, named_tier, downgrade_hysteresis_bp]),
	}
	for key in names:
		if key != "ok":
			out[key] = names[key]
	return out
