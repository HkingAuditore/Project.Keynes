# world_data.gd
# 由 MapBaker.synthesize_world 产出的"世界"——高分辨率地理仿真结果。
#
# - height_buffer    (hm_size, [0,1])：归一化海拔，深海到山顶
# - moisture_buffer  (derived_size, [0,1])：湿度，受 flow 扩散影响
# - flow_buffer      (derived_size, [0,1])：log-scaled 流量累积，0=干旱，1=主河道
# - biome_buffer     (derived_size, byte)：每像素 TerrainType.TERRAIN id
#
# 4 张对应的 ImageTexture 直接喂给 world_map.gdshader 做像素级合成。
# 同时提供给 MapGenerator 在 hex 中心采样，反推 cell.terrain / elevation / has_river。

class_name WorldData
extends RefCounted

# ─── 高分辨率原始 buffer（GDScript 端可直接采样） ─────────────────────────
var height_buffer: PackedFloat32Array = PackedFloat32Array()
var moisture_buffer: PackedFloat32Array = PackedFloat32Array()
var flow_buffer: PackedFloat32Array = PackedFloat32Array()
var biome_buffer: PackedByteArray = PackedByteArray()
# Milestone 2：植被 / 覆盖物双通道（与 biome_buffer 同分辨率，warp 完全一致，
# 因此 fragment 端 sample 同一 uv 直接对齐）。
#   - vegetation_buffer (R8) ：每像素 = VegetationType.VEG id（0..23）
#   - cover_buffer      (R8) ：每像素 = CoverType.CV id（0..5）
# 这两轴允许 shader 在不动现有 biome 着色路径的前提下，给 HILL/MOUNTAIN/PLAIN 等
# 主色单一的地形按真实植被微调色相，并把 SNOW/GLACIER/FLOODING 等覆盖物独立叠加。
var vegetation_buffer: PackedByteArray = PackedByteArray()
var cover_buffer: PackedByteArray = PackedByteArray()
# Phase 1：每像素 ny ∈ [0, 1]，shader 用来算半球 + 季节温度偏移
var latitude_buffer: PackedFloat32Array = PackedFloat32Array()
# Phase 3：每像素海洋洋流向量；陆地像素值无意义。RG 各编码 [-1, 1] → [0, 1]
var ocean_current_buffer: PackedByteArray = PackedByteArray()  # RG8
# Phase 6：每像素盛行风向（按纬度风带模型 + 大陆扰动 + 季风偏置）。RG8。
# 海洋洋流通过 Ekman 偏转读它当主驱动力；shader 陆地端用它做风迹噪声。
var wind_field_buffer: PackedByteArray = PackedByteArray()  # RG8
# Phase 14：每像素火山强度（r 通道）。靠近火山中心 = 1.0，向外径向衰减。
# shader 用来叠加红光晕 / 烟柱效果。
var volcano_field_buffer: PackedByteArray = PackedByteArray()  # R8

# ─── 元数据 ───────────────────────────────────────────────────────────────
var hm_size: Vector2i = Vector2i.ZERO       # heightmap 分辨率（高，用于 hillshading）
var derived_size: Vector2i = Vector2i.ZERO  # 派生 buffer 分辨率（低，省内存）
var world_bounds: Rect2 = Rect2()
var sea_level: float = 0.42                  # 与 cfg.sea_level 一致，[0,1] 范围
var bake_seed: int = 0                       # Phase 2：复刷 biome_tex 时复用同一 seed

# ─── shader 用 ImageTexture（编码后） ─────────────────────────────────────
# v9.atlas：把 9 张 derived 贴图合并成 3 张 atlas，降低 sampler 绑定数与 uniform 上传量。
# height_tex 因为分辨率与精度需求独立保留（hm_size + RG8 16-bit）。
#
# enum_atlas_tex   (RGB8 NEAREST, derived_size)
#   R = biome (TerrainType.TERRAIN id)
#   G = vegetation (VegetationType.VEG id)
#   B = cover (CoverType.CV id)
#
# scalar_atlas_tex (RGBA8 LINEAR, derived_size)
#   R = moisture        (原 moisture_tex)
#   G = flow_accum      (原 flow_tex)
#   B = latitude_norm   (原 latitude_tex)
#   A = volcano_field   (原 volcano_field_tex)
#
# vector_atlas_tex (RGBA8 LINEAR, derived_size)
#   RG = ocean_current  (原 ocean_current_tex，[-1,1] mapped from [0,1])
#   BA = wind_field     (原 wind_field_tex，[-1,1] mapped from [0,1])
var height_tex: ImageTexture
var enum_atlas_tex: ImageTexture
var scalar_atlas_tex: ImageTexture
var vector_atlas_tex: ImageTexture
# v9.fbm-opt：共享的 tileable noise 贴图（256×256 R8，filter_linear + repeat_enable）。
# shader 端用它替换原本 value_noise(p) 内部的 4×hash21 + smoothstep mix —— 单 octave
# 从 ~30 ALU 降到 1 次 bilinear texture fetch（dedicated hardware，几乎免费）。
# 由 MapBaker 在 bake_world 时一次性 lazy 生成，跨 world 实例共享同一张 ImageTexture。
var noise_tex: ImageTexture

# v9.perf：每像素 → HexCell 引用 lookup（W*H 个，与 derived_size 严格对齐）。
# 在 _bake_height_biome_moisture 里第一遍 warp + cube_round 时顺手填好；之后
# rebake_*_only / rebake_biome_axes_only 不再需要重跑 noise 与 cube_round —— 
# 只是 O(W*H) 的纯 array indexing + cell 字段读取（~2-3ms vs 重跑的 ~25-30ms）。
# 注意：hex_size 改变会让 lookup 失效；MapBaker.bake_world 重跑时会重建。
var pixel_to_cell_lookup: Array = []  # Array[HexCell]，null 表示该像素落在 map 外

# ─── 采样接口（给 MapGenerator 在 hex 中心采样用） ────────────────────────

func sample_height(world_pos: Vector2) -> float:
	return _bilinear_float(height_buffer, hm_size, world_pos)

func sample_flow(world_pos: Vector2) -> float:
	return _bilinear_float(flow_buffer, derived_size, world_pos)

func sample_moisture(world_pos: Vector2) -> float:
	return _bilinear_float(moisture_buffer, derived_size, world_pos)

func sample_biome(world_pos: Vector2) -> int:
	return _sample_byte(biome_buffer, world_pos)

# Milestone 2：植被 / 覆盖物采样接口，调用方语义与 sample_biome 完全一致。
func sample_vegetation(world_pos: Vector2) -> int:
	return _sample_byte(vegetation_buffer, world_pos)

func sample_cover(world_pos: Vector2) -> int:
	return _sample_byte(cover_buffer, world_pos)

# Milestone 3：盛行风采样（RG8 解码回 [-1, 1]）。给 WeatherSystem 推进锋面用。
func sample_wind(world_pos: Vector2) -> Vector2:
	if wind_field_buffer.is_empty():
		return Vector2.ZERO
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	var idx := (y * W + x) * 2
	if idx + 1 >= wind_field_buffer.size():
		return Vector2.ZERO
	var r: float = float(wind_field_buffer[idx]) / 255.0 * 2.0 - 1.0
	var g: float = float(wind_field_buffer[idx + 1]) / 255.0 * 2.0 - 1.0
	return Vector2(r, g)

# 任务 7：洋流采样（RG8 解码回 [-1, 1]）。给 MapGenerator._compute_ocean_currents 将
# per-pixel 场折返到 per-cell（HexCell.ocean_current）。也可给将来的逻辑系统直读。
func sample_ocean_current(world_pos: Vector2) -> Vector2:
	if ocean_current_buffer.is_empty():
		return Vector2.ZERO
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	var idx := (y * W + x) * 2
	if idx + 1 >= ocean_current_buffer.size():
		return Vector2.ZERO
	var r: float = float(ocean_current_buffer[idx]) / 255.0 * 2.0 - 1.0
	var g: float = float(ocean_current_buffer[idx + 1]) / 255.0 * 2.0 - 1.0
	return Vector2(r, g)

# 任务 7：打包所有 is_water cell 的 ocean_current 为 PackedVector2Array（按主存储遥历顺序）。
# 供渲染层纹理化（编码为 RG16F）上传给 water shader 做流线 scroll 使用。
#
# 结果顺序与 map.all_cells() 一致；陆地 cell 对应的项为 Vector2.ZERO。
func get_ocean_current_field(map) -> PackedVector2Array:
	var arr := PackedVector2Array()
	if map == null:
		return arr
	var cells: Array = map.all_cells()
	arr.resize(cells.size())
	for i in range(cells.size()):
		var cell = cells[i]
		arr[i] = cell.ocean_current if cell != null else Vector2.ZERO
	return arr

func _sample_byte(buf: PackedByteArray, world_pos: Vector2) -> int:
	if buf.is_empty():
		return 0
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	return int(buf[y * W + x])

# ─── 内部 ─────────────────────────────────────────────────────────────────

func _world_to_uv(world_pos: Vector2) -> Vector2:
	if world_bounds.size.x < 0.001 or world_bounds.size.y < 0.001:
		return Vector2(0.5, 0.5)
	var u := (world_pos.x - world_bounds.position.x) / world_bounds.size.x
	var v := (world_pos.y - world_bounds.position.y) / world_bounds.size.y
	return Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))

func _bilinear_float(buf: PackedFloat32Array, size: Vector2i, world_pos: Vector2) -> float:
	if buf.is_empty() or size.x <= 0 or size.y <= 0:
		return 0.0
	var uv := _world_to_uv(world_pos)
	var W := size.x
	var H := size.y
	var fx := uv.x * float(W - 1)
	var fy := uv.y * float(H - 1)
	var x0 := clampi(int(floor(fx)), 0, W - 1)
	var y0 := clampi(int(floor(fy)), 0, H - 1)
	var x1 := mini(x0 + 1, W - 1)
	var y1 := mini(y0 + 1, H - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var v00 := buf[y0 * W + x0]
	var v10 := buf[y0 * W + x1]
	var v01 := buf[y1 * W + x0]
	var v11 := buf[y1 * W + x1]
	var v0 := lerpf(v00, v10, tx)
	var v1 := lerpf(v01, v11, tx)
	return lerpf(v0, v1, ty)
