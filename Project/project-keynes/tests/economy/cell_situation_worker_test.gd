extends "res://tests/ideology/ideology_social_media_worker_test.gd"

func _run() -> int:
	var fixture := await _build_world()
	if fixture.is_empty():
		_teardown()
		return 1
	var facade: EconomyFacade = _generator.get_economy_facade()
	var cells := PackedInt32Array()
	for cell in range(128): cells.append(cell)
	var first: Dictionary = facade.cell_situation_snapshot(cells)
	var first_day := int(first.get("sample_day", -1))
	var observed := false
	var boundary_source := false
	var packet := first
	var max_us := 0
	for iteration in 3:
		_ext.set_runtime_clock(false, 50.0)
		for attempt in 12:
			_ext.service_country_worker_peer_adapter(64, true)
			var started := Time.get_ticks_usec()
			packet = facade.cell_situation_snapshot(cells)
			max_us = maxi(max_us, Time.get_ticks_usec() - started)
			boundary_source = boundary_source or String(packet.get("read_view_source", "")) in ["committed_view", "live_boundary"]
			if bool(packet.get("ok", false)):
				observed = bool(packet.get("committed", false)) and packet.severity_q16.size() == 1024
			await create_timer(0.002).timeout
		_tick = _drive_days(1)
		if observed and boundary_source and int(packet.get("sample_day", -1)) > first_day:
			break
	_expect("production facade receives bounded committed rows", observed, str(packet.get("reason", "")))
	_expect("worker-owned queries use committed-read boundaries", boundary_source,
		str(_ext.get_economy_read_view_status()))
	var final_packet: Dictionary = facade.cell_situation_snapshot(cells)
	_expect("later commits refresh the same stable batch", int(final_packet.get("sample_day", -1)) > first_day,
		"before=%d after=%d" % [first_day, int(final_packet.get("sample_day", -1))])
	_expect("queries leave the production worker healthy", _worker_fault().is_empty(), _worker_fault())
	print("[situation-worker] max_128_cell_query_us=", max_us,
		" source=", packet.get("read_view_source", ""),
		" sample_day=", final_packet.get("sample_day", -1))
	_teardown()
	return 1 if _failures else 0
