extends SceneTree

## Probe: what the charter card actually shows, and what a regime switch is
## worth to each estate before the satisfaction ceiling is applied.
##
## The card text comes from `RegimePresenter.attitudes_for`, the same call the
## regime workspace makes, so this table is the player-facing read of the
## shipped catalog rather than a re-derivation of it.
##
##   godot --headless --path Project/project-keynes \
##     --script tests/probes/probe_regime_balance.gd

const REGIME_CATALOG := "res://data/country/default_political_regime_catalog.tres"


func _init() -> void:
	var catalog: Resource = load(REGIME_CATALOG)
	if catalog == null:
		print("PROBE FAIL: regime catalog does not load")
		quit(1)
		return
	var rows: Array = []
	for raw in catalog.get("definitions"):
		var definition: Resource = raw
		var keys := PackedStringArray(definition.get("modifier_definition_keys"))
		rows.append({
			"id": String(definition.get("id")),
			"keys": keys,
			"attitudes": RegimePresenter.attitudes_for(keys),
			"charter": RegimePresenter.charter_for(keys),
		})
	var by_profession := {}
	for row in rows:
		print("[probe] %s %s" % [row.id, str(row.keys)])
		for side in ["supporters", "opponents"]:
			var entries: Array = (row.attitudes as Dictionary).get(side, [])
			for raw_entry in entries:
				var entry: Dictionary = raw_entry
				print("  %-11s %-12s %s bp=%d" % [side, entry.get("name", ""),
					entry.get("value_text", ""), int(entry.get("value_bp", 0))])
				var per: Dictionary = by_profession.get(entry.get("profession_id"), {})
				per[row.id] = int(entry.get("value_bp", 0))
				by_profession[entry.get("profession_id")] = per
		for raw_entry in row.charter:
			var charter_entry: Dictionary = raw_entry
			print("  charter     %-12s %-10s %s" % [charter_entry.get("label", ""),
				charter_entry.get("value_text", ""),
				"beneficial" if bool(charter_entry.get("beneficial", false)) else "harmful"])
	print("[probe] switch swing (early_clan -> local_council), points of 100:")
	var ids := by_profession.keys()
	ids.sort()
	for profession in ids:
		var per: Dictionary = by_profession[profession]
		var before := int(per.get("early_clan", 0))
		var after := int(per.get("local_council", 0))
		print("  %-20s %+6.1f -> %+6.1f  swing %+6.1f" % [profession,
			float(before) / 100.0, float(after) / 100.0,
			float(after - before) / 100.0])
	quit(0)
