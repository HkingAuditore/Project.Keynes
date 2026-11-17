extends RefCounted

static func diagnose_ocean_heat(host) -> void:
	if host._current_map == null:
		print("[Ocean] diagnose: no map")
		return
	var mn: float = INF
	var mx: float = -INF
	var sm: float = 0.0
	var cnt: int = 0
	var hot_water: int = 0
	var hot_land: int = 0
	for c: HexCell in host._current_map.all_cells():
		var a: float = c.temperature_transport_anomaly
		mn = minf(mn, a)
		mx = maxf(mx, a)
		sm += a
		cnt += 1
		if absf(a) > 0.02:
			if c.ocean_current.length_squared() > 1e-6:
				hot_water += 1
			else:
				hot_land += 1
	if cnt > 0:
		print("[Ocean] heat_debug: anomaly min=%.3f max=%.3f mean=%.4f | |a|>0.02: water=%d land=%d" % [
			mn, mx, sm / float(cnt), hot_water, hot_land
		])


static func diagnose_selected_temperature(host) -> void:
	if host._selected_cell == null:
		print("[Temp] diagnose: no selection")
		return
	var cell: HexCell = host._selected_cell
	# B.1：通过 ViewAdapter 读 schema-mirrored 字段
	var diag_idx: int = int(cell.index)
	var diag_ad: DCViewAdapter = host._view_adapter
	var diag_t: float = diag_ad.get_temp(diag_idx) if diag_ad != null else float(cell.temperature)
	var diag_b: float = diag_ad.get_temp_baseline(diag_idx) if diag_ad != null else float(cell.temp_baseline)
	var diag_s: float = diag_ad.get_temp_season_offset(diag_idx) if diag_ad != null else float(cell.temp_season_offset)
	print("[Temp] cell(q=%d,r=%d) temperature=%.3f baseline=%.3f season_off=%.3f" % [
		cell.q, cell.r, diag_t, diag_b, diag_s
	])
	var bd: Dictionary = cell.temperature_breakdown
	if bd.is_empty():
		print("    (breakdown empty — selected cell not yet sampled this tick)")
	else:
		for k in bd.keys():
			print("    %s = %.3f" % [str(k), float(bd[k])])
