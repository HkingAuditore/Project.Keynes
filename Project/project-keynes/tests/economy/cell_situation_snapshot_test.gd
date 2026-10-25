extends "res://tests/economy/satisfaction_runtime_test.gd"

func _init() -> void:
	_run()
	print("=== cell_situation_snapshot: checks=%d failures=%d ===" % [_checks, _failures])
	quit(1 if _failures else 0)

func _run() -> void:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	_expect("native catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)): return
	var ext := _configured_world(catalog, 9041, false, true)
	if ext == null: return
	for cycle in 3:
		var report := _run_cycle(ext, cycle)
		_expect("fixture commits an actual settlement", bool(report.get("done", false)))
	var hash_before: int = ext.get_economy_state_hash()
	var started := Time.get_ticks_usec()
	var packet: Dictionary = ext.get_cell_situation_snapshot(PackedInt32Array([0]))
	print("[situation] native query_us=", Time.get_ticks_usec() - started)
	_expect("bounded query returns committed state", packet.get("ok", false)
		and packet.get("committed", false) and packet.get("severity_stride", 0) == 8)
	if not bool(packet.get("ok", false)): return
	var severity: PackedInt32Array = packet.severity_q16
	_expect("one eight-wide row, three shortage causes", severity.size() == 8
		and packet.cause_good_ids.size() == 3 and packet.state_days.size() == 1)
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var summary: Dictionary = ext.get_population_cell_summary(0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var total := 0
	var unemployed := 0
	for row in pop.populations.size():
		total += int(pop.populations[row])
		unemployed += int(pop.unemployed_by_cohort[row])
	var expected := mini(65535, int(unemployed * 65536 / maxi(1, total)))
	_expect("unemployment matches authoritative population lanes", severity[6] == expected)
	var vacancy := mini(65535, int(int(summary.job_openings) * 65536 / maxi(1, int(summary.job_capacity))))
	_expect("vacancies match active planned jobs, including automatic investment", severity[7] == vacancy)
	var class_pop := {}
	var class_sat := {}
	var profession_ids: PackedInt32Array = pop.profession_ids
	var profession_classes: PackedStringArray = catalog.profession_class_ids
	for row in pop.populations.size():
		var cls := String(profession_classes[profession_ids[row]])
		class_pop[cls] = int(class_pop.get(cls, 0)) + int(pop.populations[row])
		class_sat[cls] = int(class_sat.get(cls, 0)) + int(pop.populations[row]) * int(pop.overall_satisfaction_by_cohort_q16[row])
	var lowest := 65536
	for cls in class_pop:
		lowest = mini(lowest, int(int(class_sat[cls]) / maxi(1, int(class_pop[cls]))))
	_expect("small unhappy classes are not hidden by whole-cell averaging", severity[3] == 65535 - lowest)
	_expect("class explanation identifies the worst political class", packet.worst_class_ids[0] >= 0)
	var kinds := PackedInt32Array()
	kinds.resize(catalog.good_ids.size())
	for need in catalog.need_satisfaction_tiers.size():
		var bit := 1 if catalog.need_satisfaction_tiers[need] <= 1 else 2
		for variant in range(catalog.need_variant_offsets[need], catalog.need_variant_offsets[need + 1]):
			for component in range(catalog.variant_component_offsets[variant], catalog.variant_component_offsets[variant + 1]):
				kinds[catalog.component_good_ids[component]] |= bit
	var essentials := 0
	var consumer := 0
	var industrial := 0
	for good in market.shortage_q16.size():
		if kinds[good] & 1: essentials = maxi(essentials, market.shortage_q16[good])
		elif kinds[good] & 2: consumer = maxi(consumer, market.shortage_q16[good])
		var required := maxi(int(market.production_input_reserve[good]), int(market.construction_material_reserve[good]))
		if required > 0:
			industrial = maxi(industrial, mini(65535, int(maxi(0, required - int(market.stock[good])) * 65536 / required)))
	_expect("living and consumer categories follow authored need tiers", severity[0] == essentials and severity[2] == consumer)
	_expect("industrial gaps follow recipe/material demand", severity[1] == industrial)
	_expect("an empty market creates a living-supply warning", int(packet.flags[0]) & 1 != 0)
	_expect("weather slots stay with published climate authority", severity[4] == 0 and severity[5] == 0)
	_expect("bounded scan visits only requested local cohorts", int(packet.scanned_cohorts) == pop.cohort_count)
	_expect("read has no simulation/hash side effects", ext.get_economy_state_hash() == hash_before)
	var invalid: Dictionary = ext.get_cell_situation_snapshot(PackedInt32Array([-1]))
	_expect("invalid cell rejected", not invalid.get("ok", false))
	var too_many := PackedInt32Array()
	too_many.resize(129)
	too_many.fill(0)
	var oversized: Dictionary = ext.get_cell_situation_snapshot(too_many)
	_expect("oversize rejected before subscription", oversized.get("reason", "") == "situation_cell_limit_exceeded")
	var empty: Dictionary = ext.get_cell_situation_snapshot(PackedInt32Array())
	_expect("empty batch stays empty", empty.get("ok", false) and empty.flags.is_empty())
	print("[situation] flags=", packet.flags, " severity=", severity,
		" scanned cohorts=", packet.scanned_cohorts, " goods=", packet.scanned_goods)
