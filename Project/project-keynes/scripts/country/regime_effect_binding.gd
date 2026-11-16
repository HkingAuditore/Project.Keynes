class_name RegimeEffectBinding
extends RefCounted

## Applies the Modifier definitions a political regime keeps in force.
##
## A regime never authors stat values: `PoliticalRegimeDefinition.modifier_definition_keys`
## references definitions that already live in the Modifier catalog. Switching a
## regime is therefore "drop the rows this country got from a regime, then apply
## the new regime's definitions" -- no new authority, no new save lane (the rows
## are ordinary COUNTRY-domain Modifier rows and persist with PKCM).
##
## Cost: two cold paths, both outside the simulation loop. `reconcile` runs once
## per confirmed country commit whose regime key actually changed, so a steady
## regime costs one snapshot read and zero commands per commit.

const REGIME_SOURCE_TYPE := 0x5245474D  # 'REGM'
const REGIME_PRODUCER_ID := 191
const COUNTRY_DOMAIN := 1
const ENTITY_SCOPE := 2
const Q16_ONE := 65536


## Replace this country's regime rows with the ones the new regime declares.
## Idempotent: calling it again with the same keys re-applies the same rows.
static func reconcile(modifier_facade, country_handle: int,
		definition_keys: PackedStringArray, effective_day: int = -1) -> Dictionary:
	if modifier_facade == null or not modifier_facade.is_configured():
		return {"ok": false, "reason": "modifier_runtime_unavailable",
			"removed": 0, "applied": 0}
	if country_handle <= 0:
		return {"ok": false, "reason": "country_handle_invalid",
			"removed": 0, "applied": 0}
	var removed := clear(modifier_facade, country_handle, effective_day)
	var applied := 0
	var failed: PackedStringArray = PackedStringArray()
	for raw_key in definition_keys:
		var key := String(raw_key).strip_edges()
		if key.is_empty():
			continue
		var request_id: int = modifier_facade.queue_apply(
			StringName(key),
			{"domain": COUNTRY_DOMAIN, "scope": ENTITY_SCOPE,
				"entity_handle": country_handle},
			{"type": REGIME_SOURCE_TYPE, "id": 0},
			-1, 1, effective_day, REGIME_PRODUCER_ID, Q16_ONE)
		if request_id > 0:
			applied += 1
		else:
			failed.append(key)
	var out := {"ok": failed.is_empty(), "removed": removed, "applied": applied}
	if not failed.is_empty():
		out["reason"] = "regime_effect_apply_rejected"
		out["failed_keys"] = failed
	return out


## Drop every regime-owned row for one country, whatever regime produced it.
## Removal is by source type, not by definition key, so an obsolete regime's
## effects cannot survive a switch even if its content was renamed.
static func clear(modifier_facade, country_handle: int,
		effective_day: int = -1) -> int:
	if modifier_facade == null or not modifier_facade.is_configured() \
			or country_handle <= 0:
		return 0
	var listed: Dictionary = modifier_facade.list_for_target(
		COUNTRY_DOMAIN, country_handle, &"")
	var handles: PackedInt64Array = listed.get("handles", PackedInt64Array())
	var source_types: PackedInt64Array = listed.get(
		"source_types", PackedInt64Array())
	var removed := 0
	for index in range(handles.size()):
		if index >= source_types.size():
			break
		if int(source_types[index]) != REGIME_SOURCE_TYPE:
			continue
		if modifier_facade.queue_remove(int(handles[index]), COUNTRY_DOMAIN,
				effective_day, REGIME_PRODUCER_ID) > 0:
			removed += 1
	return removed


## Pure read of the compiled regime catalog view: the definitions a regime
## declares, or an empty array when the catalog does not know the regime.
static func definition_keys_for(regime_view: Dictionary,
		regime_key: String) -> PackedStringArray:
	var rows: Array = regime_view.get("definitions", [])
	for raw_row in rows:
		var row: Dictionary = raw_row
		if String(row.get("id", "")) != regime_key:
			continue
		var keys := PackedStringArray(row.get("modifier_definition_keys",
			PackedStringArray()))
		var cleaned := PackedStringArray()
		for raw_key in keys:
			var key := String(raw_key).strip_edges()
			if not key.is_empty():
				cleaned.append(key)
		return cleaned
	return PackedStringArray()


## The regime stable id of a country, tolerating both snapshot shapes: the
## explicit `regime_key` and the dense `regime_id` that older fixtures emit.
static func regime_key_from_snapshot(snapshot: Dictionary,
		regime_view: Dictionary = {}) -> String:
	var raw = snapshot.get("regime_key", snapshot.get("regime_stable_id", ""))
	if raw is String or raw is StringName:
		var text := String(raw).strip_edges()
		if not text.is_empty():
			return text
	var dense := int(snapshot.get("regime_id", -1))
	if dense < 0:
		return ""
	var rows: Array = regime_view.get("definitions", [])
	if dense < rows.size():
		return String((rows[dense] as Dictionary).get("id", ""))
	return ""
