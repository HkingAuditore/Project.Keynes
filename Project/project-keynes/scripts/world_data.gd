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
# Systemic Ocean Currents：每像素上升/下沉流强度。R8 编码：
#   0   = 下沉流满强度（映射为 upwelling_strength = -1）
#   128 = 无（0）
#   255 = 上升流满强度（+1）
# 产出自 MapBaker._bake_ocean_upwelling（高纬冷水汇点 + 沿岸 Ekman 抽吸识别）。
# 陆地像素维持 128（0）。由 MapGenerator._compute_ocean_currents 回填到
# HexCell.upwelling_strength，下游海冰 / 海洋生物 / 调试可视化共用。
var ocean_upwelling_buffer: PackedByteArray = PackedByteArray()  # R8
# Phase 6：每像素盛行风向（按纬度风带模型 + 大陆扰动 + 季风偏置）。RG8。
# 海洋洋流通过 Ekman 偏转读它当主驱动力；shader 陆地端用它做风迹噪声。
var wind_field_buffer: PackedByteArray = PackedByteArray()  # RG8
# Phase 14：每像素火山强度（r 通道）。靠近火山中心 = 1.0，向外径向衰减。
# shader 用来叠加红光晕 / 烟柱效果。
var volcano_field_buffer: PackedByteArray = PackedByteArray()  # R8
# Emergent Climate Coupling（海冰连续化）：每像素海冰覆盖率 ∈ [0, 1]。
# 由 MapBaker.bake_sea_ice_fraction_only 从 HexCell.sea_ice_fraction 光栅化而来；
# 每 stride 日由 SeaIceAtlasUploadJob 触发上传一次（Daily Sim SoA Refactor 阶段 1 之前
# 是每日内嵌在 refresh_climate_daily 末尾）。
# shader 端从独立的 sea_ice_tex.r 连续读取（原 scalar_atlas.a），用 smoothstep 做 0..1 过渡，
# 不再依赖 biome==SEA_ICE 这种硬标签（彻底消除"高覆盖率却显示海洋 / 低覆盖率却显示冰"）。
var sea_ice_fraction_buffer: PackedByteArray = PackedByteArray()  # R8

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
#   R = moisture              (原 moisture_tex)
#   G = flow_accum            (原 flow_tex)
#   B = latitude_norm         (原 latitude_tex)
#   A = 0（保留，无语义；原先是 sea_ice_fraction，自 SoA 阶段 1 起拆为独立 sea_ice_tex）
#
# vector_atlas_tex (RGBA8 LINEAR, derived_size)
#   RG = ocean_current  (原 ocean_current_tex，[-1,1] mapped from [0,1])
#   BA = wind_field     (原 wind_field_tex，[-1,1] mapped from [0,1])
var height_tex: ImageTexture
var enum_atlas_tex: ImageTexture
var scalar_atlas_tex: ImageTexture
var vector_atlas_tex: ImageTexture
# 火山强度场独立 R8 纹理（原先挤在 scalar_atlas.a，已让位给 sea_ice_fraction）。
# 主视觉路径读它做火山红光晕 / 烟柱；bake_world 烘焙一次，之后不变。
var volcano_field_tex: ImageTexture
# Daily Sim SoA Refactor 阶段 1：海冰覆盖率独立 R8 纹理（原先挤在 scalar_atlas.a）。
# 由 SeaIceAtlasUploadJob 通过 MapBaker.bake_sea_ice_fraction_only 每 stride 日上传一次；
# scalar_atlas 改回静态地形数据，bake_world 后永不变更，避免每日 RGBA8 整张回传。
# shader 端 sample sea_ice_tex.r（替代原 scalar_atlas.a）。
var sea_ice_tex: ImageTexture
# Systemic Ocean Currents：独立的上升流 R8 纹理。仅调试可视化（F6 扩展）消费；
# 主视觉路径不需要它。bake_world 与 rebake_ocean_currents 都会同步更新。
var upwelling_tex: ImageTexture
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

# Daily-sim perf opt：water cell → PackedInt32Array(像素 index 列表) 反向索引。
# 在 _bake_height_biome_moisture 的同一次循环里，pixel_to_cell_lookup 写入时
# 顺带按 cell 分桶。`bake_sea_ice_fraction_only` 据此**只遍历水格像素**，把
# 全图 620k 像素循环降到 ~180k（水占 ~30%）；同时按 cell 量化字节后批量写入，
# 而不是每像素重新读取 sea_ice_fraction → clampf → round。
# - key   : HexCell 引用（仅 _is_water(terrain) 的格子；陆地恒 0 不需要写入像素）
# - value : PackedInt32Array，元素是该 cell 在 derived buffer 中覆盖的像素 1D index
# 当 bake_world 重跑时连同 pixel_to_cell_lookup 一起重建；其它路径只读。
var water_cell_pixel_lists: Dictionary = {}

# Daily-sim perf opt 阶段 P：**所有 cell**（含陆地） → PackedInt32Array 反向索引。
# 与 water_cell_pixel_lists 同源构建（_bake_height_biome_moisture 的同一桶式分发），
# 但覆盖整图所有非空 cell。给 rebake_cover_tex_only / rebake_vegetation_tex_only 用——
# weather_system 每日翻 cover 的 cell 一般 < 30 个，而当前 fast path 仍需扫 614k 像素
# 拷贝所有 byte。改造后逐 cell 比对 byte 缓存，只写真正变化的 cell 像素列表，典型日
# 像素操作量从 614k 降到 < 5k（命中率 ~99% 跳过），与 ice_bake 完全同构。
# - key   : HexCell 引用（包括陆地）
# - value : PackedInt32Array，该 cell 在 derived buffer 中覆盖的像素 1D index
# bake_world 重跑时与 pixel_to_cell_lookup 同步重建。
var cell_pixel_lists: Dictionary = {}

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

# Systemic Ocean Currents：上升/下沉流采样（R8 解码回 [-1, 1]）。
# 语义与 ocean_upwelling_buffer 字段注释一致。
func sample_upwelling(world_pos: Vector2) -> float:
	if ocean_upwelling_buffer.is_empty():
		return 0.0
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	var idx := y * W + x
	if idx >= ocean_upwelling_buffer.size():
		return 0.0
	return (float(ocean_upwelling_buffer[idx]) / 255.0) * 2.0 - 1.0

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
