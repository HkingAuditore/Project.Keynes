extends RefCounted

## Bakes the terrain fields and prepares or encodes their horizon textures.

static func bake_geometry_fallback(baker: MapBaker, map: MapData, world: WorldData,
		hex_size: float, seed_val: int, pix_count: int, t: int) -> void:
	# ── 旧 per-pass 编排（fused 不可用/失败时回退；行为同迁移前）──
	# 一次循环同时算 heightmap + biome + moisture + vegetation + cover（共享 warp 计算）。
	# C++ 不可用 / 方法缺失 / 返回 fallback 时回退 GDScript ground-truth（无 dither）。
	if not baker._bake_terrain_index_native(map, hex_size, world):
		var height_buf := PackedFloat32Array(); height_buf.resize(pix_count)
		var biome_buf := PackedByteArray(); biome_buf.resize(pix_count)
		var moist_buf := PackedFloat32Array(); moist_buf.resize(pix_count)
		var veg_buf := PackedByteArray(); veg_buf.resize(pix_count)
		var cover_buf := PackedByteArray(); cover_buf.resize(pix_count)
		MapBaker.TerrainBakerScript.bake_height_biome_moisture(
			map, hex_size, world, height_buf, biome_buf, moist_buf, veg_buf, cover_buf,
			baker._warp_noise_lo, baker._warp_noise_hi, baker._ridge_noise, baker._detail_noise, {
				"warp_amp": MapBaker.WARP_AMP,
				"warp_high_amp_ratio": MapBaker.WARP_HIGH_AMP_RATIO,
				"relief_amp": MapBaker.RELIEF_AMP,
				"relief_lo": MapBaker.RELIEF_LO,
				"relief_hi": MapBaker.RELIEF_HI,
				"ridge_smear_hex": MapBaker.RIDGE_SMEAR_HEX,
				"k_crest": MapBaker.K_CREST,
				"valley_bias": MapBaker.VALLEY_BIAS,
				"crag_amp": MapBaker.CRAG_AMP,
				"crag_freq_mul": MapBaker.CRAG_FREQ_MUL,
				"hypsometric_mix": MapBaker.HYPSO_LAYER_A_MIX,
				"coast_beach": MapBaker.COAST_BEACH,
			})
		world.height_buffer = height_buf
		world.biome_buffer = biome_buf
		world.moisture_buffer = moist_buf
		world.vegetation_buffer = veg_buf
		world.cover_buffer = cover_buf
	print("  height+biome+moisture+veg+cover: %dms" % (Time.get_ticks_msec() - t))

	# 轻度侵蚀，让 hex 边界进一步自然（C++ 权威 run_bake_erosion_pass）。
	t = Time.get_ticks_msec()
	world.height_buffer = MapBaker.TerrainBakerScript.bake_hydraulic_erosion(
		world.height_buffer, world.hm_size, baker._world_ext, seed_val, {
			"num_drops": MapBaker.EROSION_DROPS,
			"max_steps": MapBaker.EROSION_MAX_STEPS,
			"inertia": MapBaker.EROSION_INERTIA,
			"capacity_factor": MapBaker.EROSION_CAPACITY_FACTOR,
			"min_capacity": MapBaker.EROSION_MIN_CAPACITY,
			"deposit_speed": MapBaker.EROSION_DEPOSIT_SPEED,
			"erode_speed": MapBaker.EROSION_ERODE_SPEED,
			"evaporation": MapBaker.EROSION_EVAPORATION,
			"gravity": MapBaker.EROSION_GRAVITY,
			"brush_radius": MapBaker.EROSION_RADIUS,
		})
	print("  light erosion: %dms" % (Time.get_ticks_msec() - t))

	# 河流：cell.has_river 链 → trace → Catmull-Rom → SDF（全 C++）。
	t = Time.get_ticks_msec()
	var inv_world_x: float = float(world.derived_size.x) / world.world_bounds.size.x
	var river_radius_px: float = maxf(
		hex_size * MapBaker.RIVER_STROKE_HEX_FACTOR * inv_world_x, 0.5)
	world.flow_buffer = MapBaker.TerrainBakerScript.bake_river_sdf(
		map, hex_size, world.world_bounds, world.derived_size, baker._world_ext,
		int(baker._rng.seed) if baker._rng != null else 0, river_radius_px, MapBaker.SDF_MAX_DIST_PX,
		MapBaker.RIVER_CR_STEP, world.wrap_period_x)
	print("  river SDF: %dms" % (Time.get_ticks_msec() - t))

	# [river-carve-bake 2026-06-25] #2a：legacy 路径把河流刻进 height_buffer（fused 路径已在 C++ 内 carve）。
	baker._carve_river_into_height(world)

	# Phase 1：纬度纹理（每像素 ny），给 shader 算半球 + 季节温度偏移
	t = Time.get_ticks_msec()
	world.latitude_buffer = MapBaker.ClimateBakerScript.bake_latitude_buffer(
		world.world_bounds, world.derived_size, baker._world_ext)
	print("  latitude: %dms" % (Time.get_ticks_msec() - t))


static func bake_horizon(baker: MapBaker, world: WorldData, hex_size: float) -> void:
	# [terrain-horizon] 8 方向 horizon angle 烘焙，三条平台路径：
	#   1. GPU 离屏（默认仅桌面，DCFeatureFlags.terrain_horizon_gpu_bake_active）：这里只登记
	#      参数，实际由 HexRenderer.set_map 用 SubViewport + canvas shader 在场景树内延迟烘焙。
	#      生成期不阻塞、不占 CPU marching。
	#   2. CPU C++（DCAtlasEncoders.encode_horizon_tex，native SoA marching）：
	#      - 桌面 GPU 关时；
	#      - **Web 全部档位**（[terrain-web-baked-surface 2026-11-01]）：LOW/MID/HIGH 都 CPU 烘
	#        一张，否则 shader 侧 PK_WEB_HORIZON 解不到数据。步数用 TERRAIN_HORIZON_STEPS_WEB
	#        =128（真机 probe：512×298=15ms / 1024×596=79ms / 2048×1192=489ms native；
	#        max_distance=24 hex 还会自然截断有效步数），一次性生成期成本换"Web 地形也有
	#        烘焙法线 + horizon 阴影"。
	#   3. mobile：null，shader 检测 terrain_horizon_tex_bound=false → 无阴影回退。
	#      mobile 不放宽成 CPU marching：低端移动 GPU 的收益抵不上生成期卡顿。
	world.terrain_horizon_gpu_pending = false
	world.terrain_horizon_gpu_params = {}
	var horizon_height_scale_hex := maxf(float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/horizon_height_scale_hex",
		MapBaker.TERRAIN_HORIZON_HEIGHT_SCALE_HEX)), 0.01)
	if DCFeatureFlags.terrain_horizon_gpu_bake_active() and not OS.has_feature("web"):
		var wb: Vector2 = world.world_bounds.size
		var tx: float = (wb.x / float(world.hm_size.x)) if world.hm_size.x > 0 else 1.0
		var ty: float = (wb.y / float(world.hm_size.y)) if world.hm_size.y > 0 else 1.0
		world.terrain_horizon_gpu_params = {
			"steps": MapBaker.TERRAIN_HORIZON_STEPS,
			"step_px": MapBaker.TERRAIN_HORIZON_STEP_PX,
			"step_growth": MapBaker.TERRAIN_HORIZON_STEP_GROWTH,
			"lowpass_radius": MapBaker.TERRAIN_HORIZON_LOWPASS_RADIUS,
			"max_horizon_angle": MapBaker.TERRAIN_HORIZON_MAX_ANGLE,
			"bias": MapBaker.TERRAIN_HORIZON_BIAS,
			"height_world_scale": maxf(hex_size * horizon_height_scale_hex, 1e-4),
			"max_distance_world": maxf(hex_size * MapBaker.TERRAIN_HORIZON_MAX_DISTANCE_HEX, 1e-4),
			"sea_level": world.sea_level,
			"texel_x": tx,
			"texel_y": ty,
			# 真正经度周期：柱状地图东西连续，marching 须按此周期折叠（≠含 padding 的 world_bounds.x）。
			"wrap_period_x": world.wrap_period_x,
		}
		world.terrain_horizon_gpu_pending = true
		# 不清空 world.terrain_horizon_tex：regenerate 时旧图短暂沿用，GPU 烘完后回填，避免闪烁。
	elif OS.has_feature("web"):
		# Web 所有档位都 CPU 烘 horizon（steps 用 TERRAIN_HORIZON_STEPS_WEB）。
		# [terrain-web-baked-surface-B 2026-11-01] 改用 bundle encoder：同一次 marching
		# 顺带产出 GI 遮挡源 cell id（emit_occluder_cells + map_index_data），
		# 上传成 world.gi_occluder_tex → 非 tiled surface array 的 layer3（Web HIGH 的 GI 弹射）。
		# 代价：marching 内多写 4 字节/像素 occluder，horizon 部分逐字节不变。
		var horizon_bundle: Dictionary = DCAtlasEncoders.encode_horizon_bundle(
			world.height_buffer, world.hm_size, world.world_bounds.size, hex_size, world.terrain_horizon_tex,
			baker._world_ext, MapBaker.TERRAIN_HORIZON_STEPS_WEB, MapBaker.TERRAIN_HORIZON_STEP_PX, MapBaker.TERRAIN_HORIZON_MAX_ANGLE,
			MapBaker.TERRAIN_HORIZON_BIAS, hex_size * horizon_height_scale_hex, world.wrap_period_x,
			world.sea_level, MapBaker.TERRAIN_HORIZON_STEP_GROWTH, MapBaker.TERRAIN_HORIZON_LOWPASS_RADIUS,
			hex_size * MapBaker.TERRAIN_HORIZON_MAX_DISTANCE_HEX, baker._enum_atlas_data)
		world.terrain_horizon_tex = horizon_bundle.get("horizon_tex", null)
		world.gi_occluder_tex = horizon_bundle.get("occluder_tex", null)
		print("[terrain-horizon/web] bundle horizon=%s occluder=%s native_ms=%.1f fallback=%s" % [
			world.terrain_horizon_tex != null, world.gi_occluder_tex != null,
			float(horizon_bundle.get("elapsed_ms", -1.0)),
			bool(horizon_bundle.get("fallback", true))])
	elif OS.has_feature("mobile"):
		world.terrain_horizon_tex = null
	else:
		world.terrain_horizon_tex = DCAtlasEncoders.encode_horizon_tex(
			world.height_buffer, world.hm_size, world.world_bounds.size, hex_size, world.terrain_horizon_tex,
			baker._world_ext, MapBaker.TERRAIN_HORIZON_STEPS, MapBaker.TERRAIN_HORIZON_STEP_PX, MapBaker.TERRAIN_HORIZON_MAX_ANGLE,
			MapBaker.TERRAIN_HORIZON_BIAS, hex_size * horizon_height_scale_hex, world.wrap_period_x,
			world.sea_level, MapBaker.TERRAIN_HORIZON_STEP_GROWTH, MapBaker.TERRAIN_HORIZON_LOWPASS_RADIUS,
			hex_size * MapBaker.TERRAIN_HORIZON_MAX_DISTANCE_HEX)
