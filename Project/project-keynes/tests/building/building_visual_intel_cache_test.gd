extends SceneTree

const IntelCacheScript = preload(
	"res://scripts/rendering/building_visual_intel_cache.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_snapshot_and_bucket_signature()
	_test_unknown_era_preserves_building_intel()
	_test_empty_row_clears_last_seen()
	_test_social_bands()
	_test_pkfg_v3_round_trip_and_v2_migration()
	_test_v1_migration_and_atomic_rejection()
	print("building visual intel: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_snapshot_and_bucket_signature() -> void:
	var cache: BuildingVisualIntelCache = IntelCacheScript.new()
	cache.configure(16)
	var first := cache.apply_snapshot(_snapshot(
		PackedInt32Array([3]), PackedInt32Array([2]), PackedInt32Array([6]),
		PackedInt32Array([0, 2]), PackedInt32Array([4, 9]),
		PackedInt64Array([8, 3])))
	_expect("valid sparse snapshot is accepted", bool(first.get("ok", false)))
	_expect("known row keeps exact authoritative counts",
		(cache.row_for_cell(3).counts as PackedInt64Array) == PackedInt64Array([8, 3]))
	_expect("density bucket is logarithmic", cache.settlement_core_buckets()[3] == 3)
	var same_bucket := cache.apply_snapshot(_snapshot(
		PackedInt32Array([3]), PackedInt32Array([2]), PackedInt32Array([6]),
		PackedInt32Array([0, 2]), PackedInt32Array([4, 9]),
		PackedInt64Array([9, 3])))
	_expect("exact count change inside scale bucket does not rebuild geometry",
		(same_bucket.changed_cells as PackedInt32Array).is_empty())
	_expect("exact count still refreshes intelligence",
		int((cache.row_for_cell(3).counts as PackedInt64Array)[0]) == 9)
	var next_bucket := cache.apply_snapshot(_snapshot(
		PackedInt32Array([3]), PackedInt32Array([2]), PackedInt32Array([6]),
		PackedInt32Array([0, 2]), PackedInt32Array([4, 9]),
		PackedInt64Array([16, 3])))
	_expect("crossing a scale bucket rebuilds geometry",
		(next_bucket.changed_cells as PackedInt32Array) == PackedInt32Array([3]))


func _test_empty_row_clears_last_seen() -> void:
	var cache: BuildingVisualIntelCache = IntelCacheScript.new()
	cache.configure(8)
	cache.apply_snapshot(_snapshot(PackedInt32Array([1]), PackedInt32Array([0]),
		PackedInt32Array([0]), PackedInt32Array([0, 1]),
		PackedInt32Array([5]), PackedInt64Array([2])))
	var cleared := cache.apply_snapshot(_snapshot(PackedInt32Array([1]),
		PackedInt32Array([-1]), PackedInt32Array([-1]), PackedInt32Array([0, 0]),
		PackedInt32Array(), PackedInt64Array()))
	_expect("visible empty snapshot clears prior last-seen building",
		bool(cleared.get("ok", false)) and not cache.has_cell(1))
	_expect("clearing intelligence clears settlement core", cache.settlement_core_buckets()[1] == 0)


func _test_unknown_era_preserves_building_intel() -> void:
	var cache: BuildingVisualIntelCache = IntelCacheScript.new()
	cache.configure(4)
	var result := cache.apply_snapshot(_snapshot(PackedInt32Array([2]),
		PackedInt32Array([0]), PackedInt32Array([-1]),
		PackedInt32Array([0, 1]), PackedInt32Array([3]), PackedInt64Array([18])))
	_expect("unknown technology era keeps visible building intelligence",
		bool(result.get("ok", false)) and cache.has_cell(2)
		and int(cache.row_for_cell(2).observed_era_index) == -1
		and int(cache.row_for_cell(2).counts[0]) == 18)


func _test_social_bands() -> void:
	var cache: BuildingVisualIntelCache = IntelCacheScript.new()
	cache.configure(8)
	var base := _snapshot(PackedInt32Array([1, 4]), PackedInt32Array([0, 0]),
		PackedInt32Array([2, 2]), PackedInt32Array([0, 1, 1]),
		PackedInt32Array([5]), PackedInt64Array([3]))
	_with_social(base, [3, 2], [3, 4], [0, 1], [1, 0])
	var first := cache.apply_snapshot(base)
	_expect("populated cell without buildings keeps a settlement row",
		bool(first.get("ok", false)) and cache.has_cell(4)
		and int(cache.row_for_cell(4).settlement_tier) == 2
		and int(cache.row_for_cell(4).living_level) == 4)
	var richer := base.duplicate(true)
	_with_social(richer, [3, 2], [4, 4], [0, 1], [1, 0])
	var changed := cache.apply_snapshot(richer)
	_expect("living-standard change rebuilds only that cell",
		(changed.changed_cells as PackedInt32Array) == PackedInt32Array([1]))
	var empty := _snapshot(PackedInt32Array([4]), PackedInt32Array([0]),
		PackedInt32Array([2]), PackedInt32Array([0, 0]),
		PackedInt32Array(), PackedInt64Array())
	_with_social(empty, [0], [255], [255], [255])
	cache.apply_snapshot(empty)
	_expect("depopulated empty cell clears its last-seen row", not cache.has_cell(4))
	var bad := base.duplicate(true)
	_with_social(bad, [3, 9], [3, 4], [0, 1], [1, 0])
	_expect("out-of-range settlement tier is rejected",
		not bool(cache.apply_snapshot(bad).get("ok", false)))


func _test_pkfg_v3_round_trip_and_v2_migration() -> void:
	var source: BuildingVisualIntelCache = IntelCacheScript.new()
	source.configure(12)
	var snapshot := _snapshot(PackedInt32Array([2, 9]), PackedInt32Array([0, 3]),
		PackedInt32Array([1, 8]), PackedInt32Array([0, 1, 3]),
		PackedInt32Array([7, 1, 11]), PackedInt64Array([4, 2, 32]))
	_with_social(snapshot, [1, 6], [2, 5], [0, 3], [2, 0])
	source.apply_snapshot(snapshot)
	var payload := {"schema": "PKFogOfWar", "version": 3}
	payload.merge(source.to_pkfg_fields(), true)
	var restored: BuildingVisualIntelCache = IntelCacheScript.new()
	restored.configure(12)
	var result := restored.restore_pkfg(payload, 12)
	_expect("PKFG v3 sparse CSR round-trips", bool(result.get("ok", false))
		and restored.known_cells() == PackedInt32Array([2, 9]))
	_expect("round-trip preserves observed era, counts and social bands",
		int(restored.row_for_cell(9).observed_era_index) == 8
		and (restored.row_for_cell(9).counts as PackedInt64Array) == PackedInt64Array([2, 32])
		and int(restored.row_for_cell(9).settlement_tier) == 6
		and int(restored.row_for_cell(9).rich_bucket) == 3
		and int(restored.row_for_cell(2).poor_bucket) == 2)
	var v2 := payload.duplicate(true)
	v2.version = 2
	for key in ["building_intel_settlement_tiers", "building_intel_living_levels",
			"building_intel_rich_buckets", "building_intel_poor_buckets"]:
		v2.erase(key)
	var migrated: BuildingVisualIntelCache = IntelCacheScript.new()
	migrated.configure(12)
	var v2_result := migrated.restore_pkfg(v2, 12)
	_expect("PKFG v2 migrates with unknown social bands",
		bool(v2_result.get("ok", false)) and migrated.known_cells() == PackedInt32Array([2, 9])
		and int(migrated.row_for_cell(9).settlement_tier) == 255
		and int(migrated.row_for_cell(9).living_level) == 255)
	var truncated := payload.duplicate(true)
	truncated.building_intel_rich_buckets = PackedByteArray([1])
	_expect("truncated v3 social column is rejected",
		not bool(migrated.restore_pkfg(truncated, 12).get("ok", false)))


func _with_social(snapshot: Dictionary, tiers: Array, living: Array, rich: Array,
		poor: Array) -> void:
	snapshot.settlement_tiers = PackedByteArray(tiers)
	snapshot.living_levels = PackedByteArray(living)
	snapshot.rich_buckets = PackedByteArray(rich)
	snapshot.poor_buckets = PackedByteArray(poor)


func _test_v1_migration_and_atomic_rejection() -> void:
	var migrated: BuildingVisualIntelCache = IntelCacheScript.new()
	migrated.configure(6)
	var v1 := migrated.restore_pkfg({"schema": "PKFogOfWar", "cells": 6}, 20)
	_expect("versionless PKFG v1 migrates with empty building intelligence",
		bool(v1.get("ok", false)) and migrated.known_cells().is_empty())
	var cache: BuildingVisualIntelCache = IntelCacheScript.new()
	cache.configure(6)
	cache.apply_snapshot(_snapshot(PackedInt32Array([1]), PackedInt32Array([0]),
		PackedInt32Array([0]), PackedInt32Array([0, 1]),
		PackedInt32Array([2]), PackedInt64Array([2])))
	var before := cache.to_pkfg_fields()
	var malformed := _snapshot(PackedInt32Array([2, 4]), PackedInt32Array([0, 0]),
		PackedInt32Array([0, 0]), PackedInt32Array([0, 1, 2]),
		PackedInt32Array([3, 3]), PackedInt64Array([1, -2]))
	var rejected := cache.apply_snapshot(malformed)
	_expect("malformed CSR is rejected", not bool(rejected.get("ok", false)))
	_expect("failed snapshot does not partially alter cache",
		cache.to_pkfg_fields() == before)
	var bad_type_payload := {"schema": "PKFogOfWar", "version": 2,
		"building_intel_cells": PackedInt32Array([1]),
		"building_intel_country_slots": PackedInt32Array([0]),
		"building_intel_era_indices": PackedInt32Array([0]),
		"building_intel_type_offsets": PackedInt32Array([0, 1]),
		"building_intel_type_indices": PackedInt32Array([20]),
		"building_intel_counts": PackedInt64Array([1])}
	var bad_type := cache.restore_pkfg(bad_type_payload, 20)
	_expect("out-of-range PKFG building type is rejected",
		String(bad_type.get("reason", "")) == "pkfg_building_type_out_of_range")


func _snapshot(cells: PackedInt32Array, countries: PackedInt32Array,
		eras: PackedInt32Array, offsets: PackedInt32Array,
		types: PackedInt32Array, counts: PackedInt64Array) -> Dictionary:
	return {"ok": true, "cell_indices": cells, "country_slots": countries,
		"era_indices": eras, "type_offsets": offsets, "type_indices": types,
		"counts": counts, "building_generation": 4, "country_era_generation": 7}


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error(label)
