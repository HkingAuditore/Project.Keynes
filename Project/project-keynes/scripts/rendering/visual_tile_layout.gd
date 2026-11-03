class_name VisualTileLayout
extends RefCounted

const MODE_LEGACY := "legacy"
const MODE_PROBE := "probe"
const MODE_TILED := "tiled"

const DEFAULT_TILE_EDGE := 512
const DEFAULT_GUTTER_PX := 2
const DEFAULT_LAYER_CAP := 64
# 200x150 级大地图在 14 texels/hex 下需要约 70 层；桌面放宽，移动端维持 64。
const DESKTOP_LAYER_CAP := 128
const MIN_TEXELS_PER_HEX := 1.0
const DENSITY_DEGRADE_FACTOR := 0.90
# height 4 (RGBA8: RG=elev16, B=flow) + terrain_normal 4 + terrain_relief 4
# + map_index 4 + water_depth 4 + terrain_detail 1 + edge_neighbor 2 + edge_distance 4
# + horizon 4 + gi_occluder 4 = 35.
# [static-bake 2026-10-10] 运行期不变的细节法线 / 海岸邻域 / 水面软权重改为烘焙：23→36；
#   海岸邻域随后并入 edge_distance.ba、terrain_detail 回到 R8：36→35。
# [height-flow-pack 2026-08-06] height 2→4、去掉独立 flow 1：22→23。
# [terrain-gi 2026-07-31] gi_occluder 使这一项由 18 升到 22；漏改会让 resolver 低估
# 显存占用，把本该降级的大地图放行到超预算。
const BYTES_PER_PHYSICAL_TEXEL := 35
# terrain_relief 按 relief_scale 倍分辨率存（RGBA8），超出基础 4 字节的部分另计。
const RELIEF_BYTES_PER_TEXEL := 4
# Local RenderingDevice keeps a duplicate RG8 input, a float max pyramid and
# the packed output until readback. Round up so the resolver enforces peak RAM.
# [terrain-gi 2026-07-31] compute 现在还多持有一份 RGBA8 map_index 输入与一份 RGBA8
# occluder 输出，故由 12 升到 16。
const COMPUTE_TEMP_BYTES_PER_TEXEL := 16

var mode: String = MODE_LEGACY
var fallback_reason: String = ""
var degradation_reason: String = ""
var profile: String = ""
var visual_domain: Rect2 = Rect2()
var wrap_x: bool = false
var wrap_period_x: float = 0.0
var grid_size: Vector2i = Vector2i.ONE
var layer_count: int = 1
var interior_size: Vector2i = Vector2i.ZERO
var gutter_px: int = DEFAULT_GUTTER_PX
# 分地形细节坡度（terrain_relief）相对基础 tile 的分辨率倍数。
# [mobile-density 2026-11-03] 旧注释「移动端 shader 不读这一层」与代码不符，已纠正：
#   tiled 下 hex_renderer 无条件绑 visual_terrain_relief_tiles，hillshade_tod 的
#   terrain_baked_normal() 在 terrain_relief_tex_bound && terrain_erosion_strength>0
#   时确实采样它，而 world_map_material.tres 把 terrain_erosion_strength 固定为 1.0、
#   移动端也没有任何把它清零的分支 ⇒ 移动端**读** relief 层。
#   移动端仍保持 1 是刻意的取舍：×2 超采样要多付 4×(2²−1)=12 bytes/texel（35→47，
#   同样内存下等效 texel 密度 −13.6%，96/128 MB 上限内会把 100x64 high 从 12.09 压到
#   ~9.8）。本轮玩家反馈的根因是 texel 稀疏而不是 relief 分辨率，故不为它挤占密度预算；
#   要开就在调用方 options 里显式传 relief_scale=2。
var relief_scale: int = 1
var layer_size: Vector2i = Vector2i.ZERO
var logical_size: Vector2i = Vector2i.ZERO
var hex_size: float = 1.0
var requested_texels_per_hex: float = 0.0
var effective_texels_per_hex: float = 0.0
var requested_world_units_per_texel: float = 0.0
var effective_world_units_per_texel: Vector2 = Vector2.ZERO
var requested_tile_world_span: Vector2 = Vector2.ZERO
var tile_world_span: Vector2 = Vector2.ZERO
var tile_world_area: float = 0.0
var requested_budget_px: int = 0
var effective_budget_px: int = 0
var estimated_resident_bytes: int = 0
var estimated_peak_bytes: int = 0
var generation_id: int = 0


static func resolve(
		world_bounds: Rect2,
		wrap_period_x: float,
		quality: String,
		mobile: bool,
		options: Dictionary = {}
):
	var layout = load("res://scripts/rendering/visual_tile_layout.gd").new()
	layout.generation_id = int(options.get("generation_id", 0))
	layout.mode = String(options.get("mode", _configured_mode()))
	if layout.mode not in [MODE_LEGACY, MODE_PROBE, MODE_TILED]:
		layout.mode = MODE_TILED
	# WebGL2(Compatibility) 下运行时 **单张大尺寸纹理**（1024×642 这类 derived-size 图）会
	# 静默落成引擎 4×4 默认白纹理，而 Texture2DArray 分层上传是本项目在 Web 上唯一逐张
	# 验证过的稳定通道（2026-08-05 flow 全红根因）。因此 compat 不再强制 LEGACY，
	# 反而优先 tiled；预算由后面的 density/max_layers/max_texture_size 约束兜底。
	if String(options.get("rendering_method", _rendering_method())) == "gl_compatibility":
		layout.mode = MODE_TILED
		layout.fallback_reason = "compatibility_renderer_tiles_preferred"

	layout.wrap_x = wrap_period_x > 0.0001
	layout.wrap_period_x = wrap_period_x if layout.wrap_x else 0.0
	if layout.wrap_x:
		layout.visual_domain = Rect2(0.0, world_bounds.position.y,
			wrap_period_x, world_bounds.size.y)
	else:
		layout.visual_domain = world_bounds

	var normalized_quality := quality if quality in ["low", "medium", "high"] else "auto"
	layout.profile = "%s_%s" % ["mobile" if mobile else "desktop", normalized_quality]
	layout.hex_size = maxf(float(options.get("hex_size", 1.0)), 0.0001)
	layout.requested_texels_per_hex = maxf(float(options.get(
		"texels_per_hex", _configured_texels_per_hex(normalized_quality, mobile))),
		MIN_TEXELS_PER_HEX)
	layout.requested_world_units_per_texel = (
		layout.hex_size / layout.requested_texels_per_hex)

	layout.gutter_px = maxi(1, int(options.get("gutter_px", DEFAULT_GUTTER_PX)))
	layout.relief_scale = clampi(int(options.get("relief_scale", 1 if mobile else 2)), 1, 4)
	var tile_edge := clampi(int(options.get("tile_edge", DEFAULT_TILE_EDGE)), 64, 2048)
	var layer_cap := DEFAULT_LAYER_CAP if mobile else DESKTOP_LAYER_CAP
	var max_layers := mini(layer_cap, maxi(1, int(options.get(
		"max_array_layers", _device_limit(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS, layer_cap)
	))))
	var max_texture_size := maxi(64, int(options.get(
		"max_texture_size", _device_limit(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D, 4096)
	)))
	tile_edge = _align_down(mini(tile_edge,
		max_texture_size - layout.gutter_px * 2), 8)
	layout.requested_tile_world_span = Vector2.ONE * (
		float(tile_edge) * layout.requested_world_units_per_texel)

	var resident_cap_mb := float(options.get("resident_cap_mb",
		_configured_cap_mb("resident_cap_mb", _default_resident_cap_mb(mobile))))
	var peak_cap_mb := float(options.get("peak_cap_mb",
		_configured_cap_mb("peak_cap_mb", _default_peak_cap_mb(mobile))))
	var resident_cap := maxi(1, int(round(resident_cap_mb * 1024.0 * 1024.0)))
	var peak_cap := maxi(1, int(round(peak_cap_mb * 1024.0 * 1024.0)))

	var requested_target: Vector2i = layout._target_size_for_density(
		layout.requested_texels_per_hex)
	layout.requested_budget_px = requested_target.x * requested_target.y
	var density: float = layout.requested_texels_per_hex
	var degrade_reasons: Array[String] = []
	# Kept as a compatibility/QA override. It may cap a density-derived layout,
	# but it is no longer the source from which the grid is chosen.
	var budget_cap_mp := float(options.get("budget_mp", _configured_budget_mp_cap()))
	if budget_cap_mp > 0.0:
		var cap_px := maxi(1, int(round(budget_cap_mp * 1_000_000.0)))
		if layout.requested_budget_px > cap_px:
			density *= sqrt(float(cap_px) / float(layout.requested_budget_px))
			degrade_reasons.append("whole_map_budget_cap")

	var solved: bool = false
	for _attempt in range(64):
		layout._derive_grid_from_density(density, tile_edge)
		layout._estimate_memory()
		var failure: String = layout._constraint_failure(
			max_layers, max_texture_size, resident_cap, peak_cap)
		if failure.is_empty():
			solved = true
			break
		if failure not in degrade_reasons:
			degrade_reasons.append(failure)
		density *= DENSITY_DEGRADE_FACTOR
		if density < MIN_TEXELS_PER_HEX:
			break

	layout.degradation_reason = ",".join(degrade_reasons)
	if not solved or tile_edge < 64 or layout.visual_domain.size.x <= 0.0 \
			or layout.visual_domain.size.y <= 0.0:
		layout.mode = MODE_LEGACY
		if layout.fallback_reason.is_empty():
			layout.fallback_reason = "tile_density_or_device_limit"
	return layout


func _target_size_for_density(texels_per_hex: float) -> Vector2i:
	if visual_domain.size.x <= 0.0 or visual_domain.size.y <= 0.0:
		return Vector2i.ZERO
	return Vector2i(
		maxi(8, int(ceil(visual_domain.size.x / hex_size * texels_per_hex))),
		maxi(8, int(ceil(visual_domain.size.y / hex_size * texels_per_hex)))
	)


func _derive_grid_from_density(texels_per_hex: float, tile_edge: int) -> void:
	var target := _target_size_for_density(texels_per_hex)
	grid_size = Vector2i(
		maxi(1, int(ceil(float(target.x) / float(tile_edge)))),
		maxi(1, int(ceil(float(target.y) / float(tile_edge))))
	)
	interior_size = Vector2i(
		_align_up(maxi(8, int(ceil(float(target.x) / float(grid_size.x)))), 8),
		_align_up(maxi(8, int(ceil(float(target.y) / float(grid_size.y)))), 8)
	)
	layer_count = grid_size.x * grid_size.y
	layer_size = interior_size + Vector2i.ONE * gutter_px * 2
	logical_size = Vector2i(interior_size.x * grid_size.x, interior_size.y * grid_size.y)
	effective_budget_px = logical_size.x * logical_size.y
	effective_world_units_per_texel = Vector2(
		visual_domain.size.x / float(logical_size.x),
		visual_domain.size.y / float(logical_size.y))
	var density_xy := Vector2(
		hex_size / effective_world_units_per_texel.x,
		hex_size / effective_world_units_per_texel.y)
	effective_texels_per_hex = sqrt(density_xy.x * density_xy.y)
	tile_world_span = visual_domain.size / Vector2(grid_size)
	tile_world_area = tile_world_span.x * tile_world_span.y


func _constraint_failure(max_layers: int, max_texture_size: int,
		resident_cap: int, peak_cap: int) -> String:
	if layer_count > max_layers:
		return "array_layer_limit"
	if layer_size.x > max_texture_size or layer_size.y > max_texture_size:
		return "texture_size_limit"
	if estimated_resident_bytes > resident_cap:
		return "resident_memory_limit"
	if estimated_peak_bytes > peak_cap:
		return "peak_memory_limit"
	return ""


func _estimate_memory() -> void:
	var physical_px := int(layer_size.x) * int(layer_size.y) * layer_count
	estimated_resident_bytes = physical_px * (BYTES_PER_PHYSICAL_TEXEL
		+ RELIEF_BYTES_PER_TEXEL * (relief_scale * relief_scale - 1))
	estimated_peak_bytes = estimated_resident_bytes + physical_px * COMPUTE_TEMP_BYTES_PER_TEXEL


func world_to_tile_address(world_pos: Vector2) -> Dictionary:
	if layer_count <= 0 or visual_domain.size.x <= 0.0 or visual_domain.size.y <= 0.0:
		return {"valid": false}
	var x := world_pos.x
	if wrap_x and wrap_period_x > 0.0001:
		x = visual_domain.position.x + fposmod(x - visual_domain.position.x, wrap_period_x)
	var u := clampf((x - visual_domain.position.x) / visual_domain.size.x, 0.0, 1.0)
	var v := clampf((world_pos.y - visual_domain.position.y) / visual_domain.size.y, 0.0, 1.0)
	u = minf(u, 1.0 - 1e-7)
	v = minf(v, 1.0 - 1e-7)
	var scaled := Vector2(u * float(grid_size.x), v * float(grid_size.y))
	var tile := Vector2i(
		clampi(int(floor(scaled.x)), 0, grid_size.x - 1),
		clampi(int(floor(scaled.y)), 0, grid_size.y - 1)
	)
	var local01 := Vector2(scaled.x - float(tile.x), scaled.y - float(tile.y))
	var local_px := Vector2(gutter_px, gutter_px) + local01 * Vector2(interior_size)
	return {
		"valid": true,
		"tile": tile,
		"layer": tile.y * grid_size.x + tile.x,
		"local_uv": (local_px + Vector2(0.5, 0.5)) / Vector2(layer_size),
		"global_uv": Vector2(u, v),
	}


func diagnostic_report() -> Dictionary:
	return {
		"mode": mode,
		"fallback_reason": fallback_reason,
		"degradation_reason": degradation_reason,
		"profile": profile,
		"visual_domain": visual_domain,
		"wrap_x": wrap_x,
		"wrap_period_x": wrap_period_x,
		"grid_size": grid_size,
		"layers": layer_count,
		"interior_size": interior_size,
		"gutter_px": gutter_px,
		"relief_scale": relief_scale,
		"layer_size": layer_size,
		"logical_size": logical_size,
		"hex_size": hex_size,
		"requested_texels_per_hex": requested_texels_per_hex,
		"effective_texels_per_hex": effective_texels_per_hex,
		"requested_world_units_per_texel": requested_world_units_per_texel,
		"effective_world_units_per_texel": effective_world_units_per_texel,
		"requested_tile_world_span": requested_tile_world_span,
		"tile_world_span": tile_world_span,
		"tile_world_area": tile_world_area,
		"requested_budget_px": requested_budget_px,
		"effective_budget_px": effective_budget_px,
		"estimated_resident_bytes": estimated_resident_bytes,
		"estimated_peak_bytes": estimated_peak_bytes,
		"generation_id": generation_id,
	}


static func _configured_mode() -> String:
	var value := String(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/mode", MODE_TILED))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-visual-mode="):
			value = arg.trim_prefix("--map-visual-mode=")
		elif arg.begins_with("--map-tile-mode="):
			value = arg.trim_prefix("--map-tile-mode=")
	return value


## [mobile-density 2026-11-03] 移动端默认内存上限 64/96 → 96/128 MB。
##
## 为什么必须同时抬上限：本 resolver 的密度是**内存反推**的
##   effective_texels_per_hex ≈ sqrt(cap / (bytes_per_texel × 地图面积))
## 所以「只把档位请求值从 6/8/10 改高」在大地图上完全无效——安全网会把它压回同一点，
## 甚至因为 0.90 逐级降级的落点不同而更低。实测（hex_size=22、64 层/4096 上限、
## 手机默认档位，见 docs/cpp-dots-runtime/visual-tile-rendering.md 的对照表）：
##   100x64   high 档：64/96 → 9.83（比改前的 10.10 还低）；96/128 → 满额 12.09
##   150x100  high 档：64/96 → 6.41；96/128 → 7.90
##   200x150  high 档：64/96 → 4.71；96/128 → 5.20
## 继续抬到 128/160 还能让 150x100 拿到 8.8、200x150 到 5.9，但中低端机的显存峰值
## 风险大于收益，本轮不采用。
## 结构性上限：200x150 级地图在 96/128 下仍拿不到 8 texels/hex——这是「整图全驻留、
## 不许流式」的必然结果（1 px 稳态 35 B、峰值 51 B）。要再提只能做可见区分块/流式高精度，
## 不在本轮范围。
static func _default_resident_cap_mb(mobile: bool) -> float:
	return 96.0 if mobile else 512.0


static func _default_peak_cap_mb(mobile: bool) -> float:
	return 128.0 if mobile else 768.0


static func _configured_texels_per_hex(quality: String, mobile: bool) -> float:
	var override := float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/texels_per_hex", -1.0
	))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-tile-texels-per-hex="):
			override = float(arg.trim_prefix("--map-tile-texels-per-hex="))
	if override > 0.0:
		return override
	if mobile:
		# [mobile-density 2026-11-03] 6/8/10/6 → 8/10/12/10 → **12/16/20/16**。
		# 手机每 hex 只有 6 texels，而 content_scale_mode=CANVAS_ITEMS 让 1 world unit
		# 占 zoom × 1.375 个物理像素（scripts/ui/mobile_ui_scaling.gd），放大到底时一个
		# texel 被拉到 ~30 物理像素——玩家反馈的"放大后颗粒明显"。
		# 第二轮反馈仍是"地块里全是方块"：颜色采样本来就是 filter_linear，线性过滤只能
		# 把方块磨圆，**放大时的块大小由纹素密度决定**，所以这轮直接把密度再抬一档
		# （12/16/20）。显存按密度²增长，靠 resolve() 的移动端上限 96/128 MB 兜底
		# （见 _default_resident_cap_mb），超了会自动降到 effective 可承受的值。
		# 自动档取 medium：默认手机走 auto，改它才真正改善默认体验。
		match quality:
			"low":
				return 12.0
			"medium":
				return 16.0
			"high":
				return 20.0
			_:
				return 16.0
	match quality:
		"low":
			return 8.0
		"medium":
			return 12.0
		"high":
			return 16.0
		_:
			return 14.0


static func _configured_budget_mp_cap() -> float:
	var value := float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/budget_mp", -1.0
	))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-tile-budget-mp="):
			value = float(arg.trim_prefix("--map-tile-budget-mp="))
	return value


static func _configured_cap_mb(setting_name: String, fallback: float) -> float:
	var value := float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/%s" % setting_name, fallback
	))
	var arg_prefix := "--map-tile-%s=" % setting_name.replace("_", "-")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(arg_prefix):
			value = float(arg.trim_prefix(arg_prefix))
	return maxf(value, 1.0)


static func _rendering_method() -> String:
	if RenderingServer.has_method("get_current_rendering_method"):
		return String(RenderingServer.get_current_rendering_method())
	return String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "mobile"))


static func _device_limit(limit: RenderingDevice.Limit, fallback: int) -> int:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return fallback
	var value := int(rd.limit_get(limit))
	return value if value > 0 else fallback


static func _align_up(value: int, alignment: int) -> int:
	return ((value + alignment - 1) / alignment) * alignment


static func _align_down(value: int, alignment: int) -> int:
	return (value / alignment) * alignment
