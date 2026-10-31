extends SceneTree

## Ground truth for the UI-consumer guide: call every UI-facing query once and print the
## exact keys it returns. Written as a probe, not a gate -- it asserts nothing about
## values, it only reports shapes so the documentation cannot be guesswork.

const CASES := [
	["get_cell_program_rollout", []],
	["get_derived_cell_layer_report", []],
	["get_derived_materialize_report", []],
	["get_cell_layer_build_report", []],
	["get_modifier_report", []],
	["get_ideology_report", []],
	["get_effect_report", []],
]


func _initialize() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		print("[probe] DCWorldExt unavailable")
		quit(1)
		return
	for case in CASES:
		var name: String = case[0]
		var args: Array = case[1]
		if not ext.has_method(name):
			print("[probe] %-32s NOT BOUND" % name)
			continue
		var got: Variant = null
		if args.is_empty():
			got = ext.call(name)
		else:
			got = ext.callv(name, args)
		if got is Dictionary:
			var keys: Array = (got as Dictionary).keys()
			keys.sort()
			print("[probe] %-32s %d keys: %s" % [name, keys.size(), ", ".join(keys)])
		else:
			print("[probe] %-32s -> %s (%s)" % [name, str(got), type_string(typeof(got))])
	# The per-cell read and the selector query need real inputs; report their arity only.
	for sig in [["get_effective_stat_value", 4], ["query_effect_target_cells", 4],
			["query_country_anchor_cell", 1], ["explain_ideology", 2],
			["explain_ideologies", 2], ["explain_effect", 1]]:
		var nm: String = sig[0]
		print("[probe] %-32s bound=%s args=%d" % [nm, str(ext.has_method(nm)), sig[1]])
	quit(0)
