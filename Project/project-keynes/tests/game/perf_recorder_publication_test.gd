extends SceneTree

## Runs against the same PerfRecorder API before and after #82.
## The first measured publication contains two days but only one fast tick.
class PublicationHost extends RefCounted:
	signal simulation_day_records(records: Array)

	func publish(recorder: PerfRecorder, days: Array[int]) -> void:
		var records: Array[Dictionary] = []
		for day in days:
			records.append({"day": day, "generation": day + 100, "produced_at_us": day * 500})
		var last_day: int = days.back()
		recorder.on_fast_tick({
			"tick_idx": last_day,
			"speed_multiplier": 1.0,
			"t_sus_ms": 0.0,
			"runtime_graph": {
				"simulation_committed_day": last_day,
				"simulation_generation": last_day + 100,
			},
		})
		simulation_day_records.emit(records)


func _init() -> void:
	var host := PublicationHost.new()
	var recorder := PerfRecorder.new()
	recorder.bind_main(host)
	recorder.configure_authoritative_sampling(5)
	recorder.configure_export("user://stage_c_tests/perf", "publication_regression.csv")
	recorder.start()
	host.publish(recorder, [5])
	host.publish(recorder, [6, 7])
	for day in range(8, 56):
		host.publish(recorder, [day])
	var path := recorder.stop_and_export()
	recorder.bind_main(null)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Publication regression: perf CSV was not exported")
		quit(1)
		return
	var day_column := file.get_csv_line().find("runtime_graph_simulation_committed_day")
	var exported_days: Array[int] = []
	while not file.eof_reached():
		var cells := file.get_csv_line()
		if day_column >= 0 and day_column < cells.size():
			exported_days.append(int(cells[day_column]))
	var expected_days: Array[int] = []
	expected_days.assign(range(6, 56))
	if exported_days != expected_days:
		push_error("Publication regression: expected 50 days from 6 through 55, got %d days: %s"
			% [exported_days.size(), str(exported_days)])
		quit(1)
		return
	print("Publication regression: exported all 50 days in order")
	quit(0)
