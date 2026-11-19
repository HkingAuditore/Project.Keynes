extends RefCounted

## Runs the main-thread resource schedule when a simulation day commits.


static func run_scheduled(generator, map_ref, day: int, live_cells: PackedInt32Array,
		worker_commit: bool = false) -> Dictionary:
	if map_ref == null:
		return generator._remember_natural_resource_report({"done": true, "path": "skip", "published_to_slot": false})
	var n_cells: int = map_ref.cell_count()
	generator._ensure_natural_resource_cadence(n_cells, day)
	var planned: Dictionary = generator.collect_natural_resource_pass_cells(day, live_cells)
	var cell_indices: PackedInt32Array = planned.get("cell_indices", PackedInt32Array())
	var cell_dt_days: PackedInt32Array = planned.get("cell_dt_days", PackedInt32Array())
	if cell_indices.is_empty():
		return generator._remember_natural_resource_report({
			"done": true,
			"path": "indexed_empty",
			"published_to_slot": true,
			"dt_days": 1,
			"indexed_cell_count": 0,
			"n_cells": n_cells,
			"total_delta": 0.0,
		})
	var reserve_slots := PackedStringArray()
	if worker_commit:
		generator._ensure_natural_resource_knobs()
		reserve_slots = generator._natural_resource_pass_knobs.get("reserve_slots", PackedStringArray())
	var ext = generator._data_core_world_ext
	# The worker has already regenerated these reserves. The day still advances
	# the synchronous cadence in case this world changes execution mode.
	var res: Dictionary
	if not reserve_slots.is_empty() and ext != null \
			and ext.has_method("natural_resource_slots_are_worker_owned") \
			and ext.natural_resource_slots_are_worker_owned(reserve_slots):
		res = generator._remember_natural_resource_report({
			"done": true, "path": "worker_owned", "published_to_slot": true,
			"n_cells": n_cells, "dt_days": 1, "total_delta": 0.0,
			"indexed_cell_count": cell_indices.size(),
			"resource_count": reserve_slots.size(), "input_resource_count": reserve_slots.size(),
			"published_resource_count": 0,
			"skipped_worker_owned_resources": reserve_slots.size(),
		})
	else:
		res = generator.run_natural_resource_pass_native(map_ref, 1, cell_indices, cell_dt_days)
	if bool(res.get("published_to_slot", false)):
		generator._commit_natural_resource_pass_days(day, cell_indices, planned.get("live_set", {}))
	res["indexed_cell_count"] = cell_indices.size()
	return res
