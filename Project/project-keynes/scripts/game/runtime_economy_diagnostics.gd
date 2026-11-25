extends RefCounted


static func get_economy_perf_report(_generator) -> Dictionary:
	# ACTIVE owns Economy scheduling in the native graph, so the legacy SUS job
	# has no report to offer (it is intentionally policy-gated). Prefer the
	# graph's compact native result, while retaining the legacy report for OFF /
	# SHADOW and older DLLs that do not expose the graph accessor.
	var graph_report: Dictionary = {}
	if _generator._runtime_graph_active and _generator._data_core_world_ext is DCWorldExt:
		graph_report = _generator._data_core_world_ext.get_runtime_graph_last_economy_report()
	# The graph capture freezes once the simulation worker owns the day loop.
	# The direct probe accessor is read per sampled row, so it stays aligned
	# with the committed day even when the graph no longer pulses.
	var probe: Dictionary = get_economy_probe_report(_generator)
	if not probe.is_empty():
		var probe_day: int = int(probe.get("current_day", -1))
		var graph_day: int = int(graph_report.get("current_day", -1))
		if graph_report.is_empty() or probe_day >= graph_day:
			return probe
	if not graph_report.is_empty():
		return graph_report
	return _generator._economy_daily_job.last_perf_report() \
		if _generator._economy_daily_job != null and _generator._economy_daily_job.has_method("last_perf_report") \
		else {}


static func get_economy_probe_report(_generator) -> Dictionary:
	if _generator._data_core_world_ext == null \
			or not (_generator._data_core_world_ext is DCWorldExt):
		return {}
	if not _generator._data_core_world_ext.has_method("get_runtime_economy_probe_report"):
		return {}
	return _generator._data_core_world_ext.get_runtime_economy_probe_report()



static func get_runtime_perf_snapshot(_generator, detail_level: int = 0) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {}
	var snapshot: Dictionary = _generator._data_core_world_ext.get_runtime_perf_snapshot(detail_level)
	snapshot["country_territory_sync_ms"] = _generator._runtime_graph_country_territory_sync_ms
	snapshot["event_dispatch_ms"] = _generator._runtime_graph_country_event_dispatch_ms
	# P1：环境帧发布者的 GDScript 侧账本（C++ 侧看不到谁在打包）。
	snapshot["environment_publish_callsite_mask"] = _generator._environment_publish_callsite_mask
	snapshot["environment_publish_count"] = _generator._environment_publish_count
	snapshot["environment_publish_orphan_day"] = _generator._environment_publish_orphan_day
	snapshot["environment_frames_ahead"] = maxi(0,
		int(snapshot.get("simulation_environment_day", 0)) \
		- int(snapshot.get("simulation_committed_day", 0)))
	return snapshot
