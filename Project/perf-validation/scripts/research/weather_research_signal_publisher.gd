class_name WeatherResearchSignalPublisher
extends RefCounted

const GameplayEventBusScript = preload("res://scripts/data_core/gameplay_event_bus.gd")

const PROTOCOL_VERSION := 1
const RULE_TYPHOON := 0
const RULE_MAJOR_FLOOD := 1
const RULE_DROUGHT := 2
const RULE_MONSOON := 3
const RULE_FROST := 4
const RULE_STORM_SURGE := 5

const WEATHER_INTENSITY_THRESHOLD := 0.50
const FROST_TEMPERATURE_THRESHOLD := 0.18
const STRONG_WIND_THRESHOLD := 0.62


static func publish(map: MapData, country_facade, event_bus, day: int,
		cyclone_snapshot: Dictionary = {}) -> Dictionary:
	if map == null or country_facade == null or event_bus == null \
			or not event_bus.is_available():
		return {"published": 0, "reason": "weather_signal_publisher_unavailable"}
	var batch := build_batch(map, country_facade, day, cyclone_snapshot)
	if int(batch.get("count", 0)) <= 0:
		return {"published": 0, "reason": "no_qualifying_weather"}
	return event_bus.publish_events_batch(batch)


static func build_batch(map: MapData, country_facade, day: int,
		cyclone_snapshot: Dictionary = {}) -> Dictionary:
	var evidence := {}
	var cyclone_cells := _cyclone_affected_cells(map, cyclone_snapshot)
	var count := map.cell_count()
	for cell in range(count):
		var summary: Dictionary = country_facade.cell_summary(cell)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0:
			continue
		var weather_type := int(map.weather_type_arr[cell]) \
			if cell < map.weather_type_arr.size() else int(WeatherType.WT.CLEAR)
		var intensity := float(map.weather_intensity_arr[cell]) \
			if cell < map.weather_intensity_arr.size() else 0.0
		var temperature := float(map.temp_arr[cell]) \
			if cell < map.temp_arr.size() else 0.5
		var cover := int(map.cover_arr[cell]) if cell < map.cover_arr.size() else -1
		var wind := float(map.wind_speed_arr[cell]) \
			if cell < map.wind_speed_arr.size() else 0.0
		if weather_type == int(WeatherType.WT.DROUGHT) \
				and intensity >= WEATHER_INTENSITY_THRESHOLD:
			_add_evidence(evidence, handle, RULE_DROUGHT, cell, intensity)
		if weather_type == int(WeatherType.WT.MONSOON) \
				and intensity >= WEATHER_INTENSITY_THRESHOLD:
			_add_evidence(evidence, handle, RULE_MONSOON, cell, intensity)
		if temperature <= FROST_TEMPERATURE_THRESHOLD:
			_add_evidence(evidence, handle, RULE_FROST, cell,
				FROST_TEMPERATURE_THRESHOLD - temperature)
		if cover == int(CoverType.CV.FLOODING):
			_add_evidence(evidence, handle, RULE_MAJOR_FLOOD, cell, intensity)
		if cyclone_cells.has(cell):
			_add_evidence(evidence, handle, RULE_TYPHOON, cell, intensity)
			if cover == int(CoverType.CV.FLOODING) or wind >= STRONG_WIND_THRESHOLD:
				_add_evidence(evidence, handle, RULE_STORM_SURGE, cell, maxf(intensity, wind))
	var rows: Array = evidence.values()
	rows.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.handle) < int(right.handle) \
			or (int(left.handle) == int(right.handle) and int(left.rule) < int(right.rule)))
	var batch := {
		"count": rows.size(), "tick_scalar": day, "phase_scalar": 0,
		"type_scalar": GameplayEventBusScript.EVENT_WEATHER_OBSERVED,
		"source_scalar": GameplayEventBusScript.SOURCE_GDSCRIPT,
		"flags_scalar": 0,
		"payload_schema_scalar": GameplayEventBusScript.PAYLOAD_WEATHER_OBSERVED_V1,
		"cell_idx": PackedInt32Array(), "entity_id": PackedInt32Array(),
		"entity_handle": PackedInt64Array(), "value_i64": PackedInt64Array(),
		"payload_i0": PackedInt32Array(), "payload_i1": PackedInt32Array(),
		"payload_i2": PackedInt32Array(), "payload_i3": PackedInt32Array(),
	}
	for row in rows:
		batch.cell_idx.append(int(row.first_cell))
		batch.entity_id.append(int(row.first_cell))
		batch.entity_handle.append(int(row.handle))
		batch.value_i64.append(maxi(1, int(round(float(row.max_intensity) * 65536.0))))
		batch.payload_i0.append(int(row.rule))
		batch.payload_i1.append(int(row.cell_count))
		batch.payload_i2.append(int(row.first_cell))
		batch.payload_i3.append(PROTOCOL_VERSION)
	return batch


static func _cyclone_affected_cells(map: MapData, snapshot: Dictionary) -> Dictionary:
	var affected := {}
	var neighbors := map.neighbor_indices_packed()
	var count := map.cell_count()
	for cyclone_value in snapshot.get("cyclones", []):
		if not cyclone_value is Dictionary:
			continue
		var cyclone: Dictionary = cyclone_value
		var center := int(cyclone.get("cell_idx", -1))
		var radius := maxi(0, int(ceil(float(cyclone.get("radius_cells", 0.0)))))
		if center < 0 or center >= count:
			continue
		var frontier := PackedInt32Array([center])
		affected[center] = true
		for _distance in range(radius):
			var next := PackedInt32Array()
			for cell in frontier:
				for direction in range(6):
					var edge := int(cell) * 6 + direction
					if edge < 0 or edge >= neighbors.size():
						continue
					var neighbor := int(neighbors[edge])
					if neighbor < 0 or affected.has(neighbor):
						continue
					affected[neighbor] = true
					next.append(neighbor)
			frontier = next
			if frontier.is_empty():
				break
	return affected


static func _add_evidence(evidence: Dictionary, handle: int, rule: int,
		cell: int, intensity: float) -> void:
	var key := "%d:%d" % [handle, rule]
	if not evidence.has(key):
		evidence[key] = {"handle": handle, "rule": rule, "first_cell": cell,
			"cell_count": 1, "max_intensity": intensity}
		return
	var row: Dictionary = evidence[key]
	row.cell_count = int(row.cell_count) + 1
	row.max_intensity = maxf(float(row.max_intensity), intensity)
	evidence[key] = row
