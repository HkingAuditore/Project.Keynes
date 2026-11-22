extends RefCounted

static func reset_for_bake(host) -> void:
	# 重新烘焙世界 → 失效旧海冰独立纹理缓冲与 cell-byte 快照。
	host._sea_ice_only_buf = PackedByteArray()
	host._sea_ice_cache_size = Vector2i.ZERO
	host._sea_ice_pixel_to_cell_idx = PackedInt32Array()
	host._last_sea_ice_cell_bytes = {}
	host._last_sea_ice_cell_bytes_packed = PackedByteArray()
	# 阶段 P：cover / vegetation 的增量缓存同样要随地图重生 / 重烘失效。
	host._last_cover_cell_bytes = {}
	host._last_vegetation_cell_bytes = {}
	host._last_cover_cell_bytes_packed = PackedByteArray()
	host._last_vegetation_cell_bytes_packed = PackedByteArray()
	host._cover_cache_size = Vector2i.ZERO
	host._vegetation_cache_size = Vector2i.ZERO
	# J: biome 增量缓存随地图重生失效（首次 rebake_biome_axes_only 走 fallback 重建路径）
	host._last_biome_cell_bytes = {}
	host._last_biome_cell_bytes_packed = PackedByteArray()
	host._biome_cache_size = Vector2i.ZERO
	# 阶段 P2：enum_atlas 交错 data 缓存随地图重生失效（首次 _encode_enum_atlas 会重新填）
	host._enum_atlas_data = PackedByteArray()
	host._enum_atlas_data_size = Vector2i.ZERO
	# plan/sim-2ms-simd-dirty-budget：地图重生 → enum atlas 整张重烘必走 GPU upload；
	# 累积的 throttle 计数同步清零，避免老 axis 的 pending dirty 在新地图上误触发自愈。
	host.force_flush_enum_atlas_throttle()
	# weather_field 增量缓存：地图重生 → 缓冲与 sig 失效；首次 bake_weather_field_only 会重建。
	host._weather_field_buf = PackedByteArray()
	host._weather_field_cache_size = Vector2i.ZERO
	host._last_weather_field_cell_sigs = {}
	# dynamic_cell_atlas 增量缓存同样随地图重生失效。
	host._dynamic_cell_atlas_buf = PackedByteArray()
	host._dynamic_cell_atlas_cache_size = Vector2i.ZERO
	host._last_dynamic_cell_sigs = {}
	host._ecology_visual_atlas_buf = PackedByteArray()
	host._ecology_visual_atlas_cache_size = Vector2i.ZERO
	host._last_ecology_visual_sigs = {}
	# map-visual-overhaul-v1：新 atlas 缓存随地图重生失效
	host._dyn_atlas_smooth_buf = PackedByteArray()
	host._dyn_atlas_smooth_cache_size = Vector2i.ZERO
	host._last_dyn_smooth_cell_sigs = {}
	host._ice_state_buf = PackedByteArray()
	host._ice_state_cache_size = Vector2i.ZERO
	host._last_ice_state_cell_bytes = {}
	host._last_ecology_veg_bytes = {}
	host._last_ecology_vitality_bytes = {}
	host._ecology_transition_age_bytes = {}
	# P1-E：SoA 镜像同步清空，下一次 ecology cache prepare 时按 N 重 resize 填零
	host._eco_veg_bytes_arr = PackedByteArray()
	host._eco_vitality_bytes_arr = PackedByteArray()
	host._eco_transition_age_arr = PackedByteArray()
	host._eco_soa_initialized = false
	host._eco_active_decay_set = {}  # plan/dirty-push-atlas-encode 阶段 E：地图重生时清空
	host._cell_enum_lut_bytes_cache = PackedByteArray()
	host._cell_dyn_lut_bytes_cache = PackedByteArray()
	host._cell_eco_lut_bytes_cache = PackedByteArray()
	host._cell_bounce_lut_bytes_cache = PackedByteArray()
	host._cell_lut_active_transition_count = 0
	host._cell_offset_layout.clear()
	host._cell_table_source_cache.clear()
	# L: vector atlas 持久交错缓冲随地图重生失效（首次 commit 走 fallback 路径重建）。
	host._vector_atlas_data = PackedByteArray()
	host._vector_atlas_data_size = Vector2i.ZERO
