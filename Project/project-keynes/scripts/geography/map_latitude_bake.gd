extends RefCounted

static func bake_lat_temp_year_lut(host, generator) -> void:
	if not host._soa_built:
		push_warning("[map_data] bake_lat_temp_year_lut: SoA not built; call rebuild_soa_from_cells() first")
		return
	if generator == null:
		push_warning("[map_data] bake_lat_temp_year_lut: generator is null")
		return
	var n: int = host._cell_array.size()
	host.cell_lat_norm_arr.resize(n)
	host.temp_baseline_year_arr.resize(n)
	for i in range(n):
		var c: HexCell = host._cell_array[i]
		var ny: float = float(generator.public_cube_row_norm(c))
		host.cell_lat_norm_arr[i] = ny
		# fallback only：权威值由 C++ run_temp_baseline_year_bake 写入（见函数顶部注释）。
		# 公式统一走 DCClimateMath.lat_temp_bell（全工程单一来源），与 C++ pk_lat_temp_bell 同源。
		var lat_temp: float = DCClimateMath.lat_temp_bell_from_ny(ny)
		if lat_temp < 0.0:
			lat_temp = 0.0
		elif lat_temp > 1.0:
			lat_temp = 1.0
		host.temp_baseline_year_arr[i] = lat_temp
	host._lat_lut_baked = true
