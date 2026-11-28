# cell_table_codec.gd
# ═══════════════════════════════════════════════════════════════════════════
# [cell-field 2026-11-18] `cell_table`（Texture2DArray）的字节布局与 offset 空间重排。
#
# 这是 **纯静态、无 GPU / 无 MapData 依赖** 的字节搬运层：baker 调它生成四层
# PackedByteArray，测试调它验证逐 texel 布局。不改任何纹理、不读 HexCell。
#
# 契约：docs/plans/terrain-cell-field-contract.md §3（层契约）/ §5.3（发布）
#   cell_table = Texture2DArray，RGBA8，尺寸 map_w × map_h，1 texel = 1 格，
#   坐标空间是 **offset 空间**（`idx = row * map_w + col`），**不是** `cell.index` 空间。
#   `cell.index` 是 `_cells` 字典的插入顺序（map_data.gd），shader 由坐标推不出来，
#   所以发布时必须按 `DCTerrainIndexBaker.build_cell_inputs()` 的 `offset_to_index`
#   把同一份字节重排一次（方案 §3.4）。
#
#   layer 0 `class` : R=biome   G=vegetation  B=cover   A=landform                （生成期）
#   layer 1 `state` : R=temp    G=wet         B=snow    A=vitality（陆）/ sea_ice（水）（每日）
#   layer 2 `aux`   : R=fog_k   G=water_depth B=exact visibility A=reserved    （探索 / 水深）
#   layer 3 `class_by_index` : 同 layer0 的四个通道，但坐标空间是 **cell.index 空间**
#                     （Web 方案 §3.1）：第 i 格放在 (i % map_w, i / map_w)，**不重排**。
#                     用途是把 `enum_lut[cell.index].r`（GI 弹射色）从 legacy 槽里搬出来。
#                     前提 n_cells ≤ map_w × map_h；装不下时不发布（见 index_space_fits）。
#
# 字节约定：
#   * 输入数组可以是 PackedByteArray（已经是 0..255 的量化值，原样 clamp 后使用），
#     也可以是 PackedFloat32Array / Array[float]（**归一化 0..1**，按 `q01_byte` 量化）。
#   * 数组长度不足 n_cells 时，缺失索引用各通道的 documented 默认值
#     （class/state = 0；aux 的 fog_k = 255「未接线即全知」，与 cell_lut_baker 的
#       enum_lut.A 处理一致；water_depth / flags = 0）。
#   * `offset_to_index[idx] == -1`（南北 padding / 空槽）的 texel 全部写 `fill`
#     （默认 0）。shader 侧 row 越界的 padding 另有 `B_SEA_ICE` 语义，不靠这个字节，
#     见 hex_cell_field.gdshaderinc::pk_cell_table_fetch。
# ═══════════════════════════════════════════════════════════════════════════
extends RefCounted
class_name DCCellTableCodec

## 层号常量：layer0/1/2 与 shader 的 PK_CELL_LAYER_CLASS/STATE/AUX = 0/1/2 同值（契约 §3）；
## layer3 = class_by_index，shader 侧对应 PK_CELL_LAYER_CLASS_INDEX（Web 方案 §3.1）。
const LAYER_CLASS := 0
const LAYER_STATE := 1
const LAYER_AUX := 2
## layer3：**cell.index 空间**的 class 镜像（第 i 格在 (i % map_w, i / map_w)）。
const LAYER_CLASS_BY_INDEX := 3
## 纹理实际建出来的层数（4）。发布器是否把 layer3 托管给 shader 由 WorldData.cell_table_layers
## 表达（n_cells > map_w*map_h 时为 3，第 4 层只是占位零层）。
const LAYER_COUNT := 4

## RGBA8。
const BYTES_PER_TEXEL := 4

## o2i == -1 的 texel 的默认填充字节（契约 §3 的 padding / 空槽）。
const FILL_BYTE := 0

## aux 层 fog_k 的默认值：255 = 全知。与 cell_lut_baker 的
## `enum_data[e4+3] = fog_k_override[ci] if ... else 255` 同语义
## （迷雾系统未接线时不应把整张地图刷黑）。
const FOG_K_DEFAULT := 255


## 归一化 0..1 → 8bit。与 DCDynamicAtlasBaker.q01_byte 同式（round + clamp）；
## shader 侧用 pk_byte_of(v) = int(v * 255.0 + 0.5) 还原，两侧必须同一量化。
static func q01_byte(v: float) -> int:
	return clampi(int(round(clampf(v, 0.0, 1.0) * 255.0)), 0, 255)


## layer0 class：每格 4 字节 = [biome, vegetation, cover, landform]，按 cell.index 排列。
static func class_bytes(n_cells: int, terr,
		veg, cover, landform) -> PackedByteArray:
	var count: int = maxi(n_cells, 0)
	var out := PackedByteArray()
	out.resize(count * BYTES_PER_TEXEL)
	for i in range(count):
		var base: int = i * BYTES_PER_TEXEL
		out[base] = _channel_byte(terr, i, 0)
		out[base + 1] = _channel_byte(veg, i, 0)
		out[base + 2] = _channel_byte(cover, i, 0)
		out[base + 3] = _channel_byte(landform, i, 0)
	return out


## layer1 state：每格 4 字节 = [temp, wet, snow, vitality_or_ice]，按 cell.index 排列。
## 与 dyn_lut 同字节布局：temp/moist/snow 是归一化量；第 4 通道陆格写
## vegetation_vitality、水格写 sea_ice_fraction（调用方已按 `MapData.terrain_is_water`
## 选好传入，本函数不做水陆判定）。
static func state_bytes(n_cells: int, temp, wet, snow,
		vitality_or_ice) -> PackedByteArray:
	var count: int = maxi(n_cells, 0)
	var out := PackedByteArray()
	out.resize(count * BYTES_PER_TEXEL)
	for i in range(count):
		var base: int = i * BYTES_PER_TEXEL
		out[base] = _channel_byte(temp, i, 0)
		out[base + 1] = _channel_byte(wet, i, 0)
		out[base + 2] = _channel_byte(snow, i, 0)
		out[base + 3] = _channel_byte(vitality_or_ice, i, 0)
	return out


## layer2 aux：每格 4 字节 = [fog_k, water_depth, flags, 0]，按 cell.index 排列。
## water_depth 与今天 layer5.B 同精度（8bit）；flags 预留（陆格 6 方向临陆位等）。
static func aux_bytes(n_cells: int, fog_k, water_depth, flags) -> PackedByteArray:
	var count: int = maxi(n_cells, 0)
	var out := PackedByteArray()
	out.resize(count * BYTES_PER_TEXEL)
	for i in range(count):
		var base: int = i * BYTES_PER_TEXEL
		out[base] = _channel_byte(fog_k, i, FOG_K_DEFAULT)
		out[base + 1] = _channel_byte(water_depth, i, 0)
		out[base + 2] = _channel_byte(flags, i, 0)
		out[base + 3] = 0
	return out


## 把「按 cell.index 排列」的字节重排成「offset 空间」的 texel 序列。
##
##   src_by_index : 长度 >= n_cells * bytes_per_cell，按 cell.index 连续排布
##   o2i          : 长度 = map_w * map_h，offset 线性下标 → cell.index，-1 = 空
##   map_w/map_h  : cell_table 的尺寸（1 texel = 1 格）
##   返回         : 长度 = map_w * map_h * bytes_per_cell
##
## 越界 / 空槽 / 源数组不足一律写 `fill`（不崩、不读越界）。`bytes_per_cell`
## 允许 1..4，方便同一函数服务三张 RGBA8 层与将来的单通道实测。
static func reorder_to_offset(src_by_index: PackedByteArray, o2i: PackedInt32Array,
		map_w: int, map_h: int, bytes_per_cell: int = BYTES_PER_TEXEL,
		fill: int = FILL_BYTE) -> PackedByteArray:
	var out := PackedByteArray()
	var texels: int = maxi(map_w, 0) * maxi(map_h, 0)
	if texels <= 0 or bytes_per_cell <= 0:
		return out
	out.resize(texels * bytes_per_cell)
	out.fill(clampi(fill, 0, 255))
	var src_texels: int = src_by_index.size() / bytes_per_cell
	var limit: int = mini(texels, o2i.size())
	for idx in range(limit):
		var ci: int = o2i[idx]
		if ci < 0 or ci >= src_texels:
			continue
		var src_base: int = ci * bytes_per_cell
		var dst_base: int = idx * bytes_per_cell
		for k in range(bytes_per_cell):
			out[dst_base + k] = src_by_index[src_base + k]
	return out


## layer3 的可发布判据（Web 方案 §3.1 的前提条件）。
##
## cell.index 空间把第 i 格放在 (i % map_w, i / map_w)，层尺寸**必须与 layer0 相同**
## （map_w × map_h）——shader 只有一个 `cell_table_size`，两套层尺寸会让 `cid / W` 的
## 行号无解。所以「装得下」等价于 n_cells ≤ map_w × map_h。放不下时调用方必须**不发布**
## layer3（cell_table_layers = LAYER_CLASS_BY_INDEX = 3），而不是换一种尺寸硬排。
static func index_space_fits(n_cells: int, map_w: int, map_h: int) -> bool:
	return n_cells > 0 and map_w > 0 and map_h > 0 and n_cells <= map_w * map_h


## layer3 class_by_index：**内容与 layer0 逐字节同值**，只是不重排——第 i 个 texel
## 就是 `cells_by_index[i]` 的 (biome, veg, cover, landform)，落在 (i % map_w, i / map_w)。
##
## 返回长度恒为 map_w * map_h * 4（纹理层尺寸必须与其它层一致）：
##   * i < n_cells       → class_bytes 的第 i 格；
##   * i ≥ n_cells       → fill（非满格地图的尾部，默认 0）。
## n_cells > map_w*map_h（装不下）时返回**空数组**：宁可让调用方跳过这一层，也不写
## 越界/错位字节（返回空是这条前提的唯一失败信号）。
static func class_by_index_bytes(n_cells: int, terr, veg, cover, landform,
		map_w: int, map_h: int) -> PackedByteArray:
	var texels: int = maxi(map_w, 0) * maxi(map_h, 0)
	if texels <= 0 or not index_space_fits(n_cells, map_w, map_h):
		return PackedByteArray()
	var out: PackedByteArray = class_bytes(n_cells, terr, veg, cover, landform)
	var want: int = texels * BYTES_PER_TEXEL
	if out.size() != want:
		# 非满格地图：尾部按 fill 补齐。不依赖 resize 的零填充（FILL_BYTE 改值后依旧正确）。
		var head: int = out.size()
		out.resize(want)
		for i in range(head, want):
			out[i] = clampi(FILL_BYTE, 0, 255)
	return out


## layer3 的**退化占位层**：index 空间装不下时仍要凑够 LAYER_COUNT 层才能建
## Texture2DArray，于是整层写 fill。配合 WorldData.cell_table_layers = 3，
## shader 侧 cell_class_index_bound 永远是 false，这一层不会被读到。
static func index_space_fill_bytes(map_w: int, map_h: int,
		fill: int = FILL_BYTE) -> PackedByteArray:
	var out := PackedByteArray()
	var want: int = maxi(map_w, 0) * maxi(map_h, 0) * BYTES_PER_TEXEL
	if want <= 0:
		return out
	out.resize(want)
	out.fill(clampi(fill, 0, 255))
	return out


## 单通道取值：byte 数组原样 clamp；float 数组按归一化 0..1 量化；缺失用 fallback。
static func _channel_byte(values, index: int, fallback: int) -> int:
	if values == null:
		return fallback
	if index < 0 or index >= values.size():
		return fallback
	var v = values[index]
	if typeof(v) == TYPE_FLOAT:
		return q01_byte(float(v))
	return clampi(int(v), 0, 255)
