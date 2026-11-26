extends RefCounted

## Prepares the current fog bindings from published cell fields and terrain state.

const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")


static func prepare(layer, force: bool) -> bool:
	if layer._shader_mat == null:
		return false
	var host: Variant = layer._cell_field_host()
	var want_active: bool = host != null and RendererShaderWaterScript._cell_field_active(host)
	# 判定口与当前 program 不一致（运行期翻转开关 / boot 自检结论晚到）⇒ 重编一次。
	# 与陆地 program 的重编时机同源（RendererShaderWater._apply_cell_field_enabled），
	# 那条路径会走 _refresh_split_configuration → _apply_uniforms → 本层 setup()。
	if want_active != layer._built_cell_field:
		var sh: Shader = layer._load_shader()
		if sh != null:
			layer._shader_mat.shader = sh
		force = true
	if not layer._built_cell_field:
		return false

	var world: Variant = host._world if host != null else null
	var tiled: bool = layer._visual_tiles_active()
	var table: Texture2DArray = null
	var dims := Vector2i.ZERO
	var bound := false
	var surface: Texture2DArray = null
	var warp_tiles: Texture2DArray = null
	var warp_bound := false
	var warp_range := 1.6
	if world != null:
		table = world.cell_table_tex
		dims = world.cell_table_dims
		# **与地形 program 逐字同一门控**（renderer_material_publish.gd:357-358 的
		# `cell_table_bound = world.cell_table_bound and cell_table != null`）：
		# 两边对"表是否可读"必须给出同一个答案，否则会出现"地形正渲染、迷雾却整屏厚云"
		# 这种更糟的不一致。表一旦建出来就恒有 4 层（offset 空间三层恒有效，第 4 层
		# 在 index 空间装不下时是占位），所以 layer2 的可用性由建表成功本身保证。
		bound = bool(world.cell_table_bound) and table != null
		warp_range = float(world.boundary_warp_range)
		if tiled:
			var vt: Variant = world.visual_tiles
			if vt != null:
				warp_tiles = vt.boundary_warp
			warp_bound = warp_tiles != null
		else:
			surface = world.terrain_surface_tex
			# 与 renderer_material_publish.gd:247-249 同一门控：surface array 恒 7 层，
			# 中性兜底层也是 7 层之一 ⇒ 必须同时看 terrain_warp_layer_bound（烘焙报告）。
			warp_bound = bool(world.terrain_warp_layer_bound) and surface != null \
				and int(surface.get_layers()) >= 7
	if dims.x <= 0 or dims.y <= 0:
		var mp: Variant = host._map if host != null else null
		if mp != null:
			dims = Vector2i(int(mp.width), int(mp.height))

	# 早退判定的实参：**直接读地形材质上推过的值**（renderer_scene_services.gd:664-665
	# 推的就是这两条），而不是在本文件里复述 _effective_fog_early_out() 的判定链
	# （迷雾层档位 / _fog_enabled / 请求位三条与运算，复述一遍就是第二个真源）。
	# 拿不到地形材质时按"不强制"处理（与今日行为相同：只有旧路径的早退，没有强制项）。
	var early_on := false
	var early_k: float = layer.FOG_EARLY_OUT_K_FALLBACK
	var host_mat: Variant = host._shader_mat if host != null else null
	if host_mat is ShaderMaterial:
		var e: Variant = host_mat.get_shader_parameter("fog_early_out_enabled")
		early_on = bool(e) if e != null else false
		var ek: Variant = host_mat.get_shader_parameter("fog_early_out_k")
		early_k = float(ek) if ek != null else layer.FOG_EARLY_OUT_K_FALLBACK

	var sig := {
		"tiled": tiled,
		"table": table,
		"dims": dims,
		"bound": bound,
		"surface": surface,
		"warp_tiles": warp_tiles,
		"warp_bound": warp_bound,
		"warp_range": warp_range,
		"hex": layer._hex_size,
		"early": early_on,
		"early_k": early_k,
	}
	if not force and sig == layer._cell_field_sig:
		return false
	var previous_early: bool = layer._cell_field_sig.get("early", false)
	layer._scaled.dirty = true
	layer._cell_field_sig = sig
	# Even at high quality the terrain material is authoritative. Compile the
	# opacity check back in whenever terrain actually starts skipping pixels.
	if previous_early != early_on and layer._uses_gradient_table():
		layer._shader_mat.shader = layer._load_shader()
	return true
