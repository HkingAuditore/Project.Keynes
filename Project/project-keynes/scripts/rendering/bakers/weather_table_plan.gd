extends RefCounted

# [cell-field 2026-11-18] cell_table（Texture2DArray）的字节布局与 offset 空间重排由
# cell_table_codec.gd 负责；本文件只做「取源数据 → 调 codec → 建/复用纹理 → update_layer」。
# 用 preload 而不是裸 class_name：`DCCellTableCodec` 的 class_name 要编辑器扫描写进
# .godot/global_script_class_cache.cfg 后才全局可见，headless / 首次运行时尚不存在
# （tests/world/cell_table_layout_test.gd 同做法）。
const CellTableCodecScript = preload("res://scripts/rendering/bakers/cell_table_codec.gd")

# ─── [cell-field-overlays 2026-11-18] weather_table 层号（方案 §3.3）──────────────────
# Texture2DArray，RGBA8，map_w × map_h，1 texel = 1 格，**offset 空间**，无 mip。
# ```
#   layer 0 / 1  天气 A / B : R=type  G=intensity  B=cloud  A=vapor   （同 weather_lut 布局）
#   layer 2 / 3  风     A / B : RG=单位风向*0.5+0.5  B=speed/20  A=1   （同 wind_lut 编码）
# ```
# **双缓冲靠层号**：当前层号 cur ∈ {0,1}（WorldData.weather_table_cur），
# prev = 1 - cur；风同理 2 + cur / 2 + prev。每次提交只 update_layer 一层（天气）+ 一层
# （风），再翻转 cur，**不拷贝、不重传另一层**。层号常量与 shader 侧 O2 的
# `PK_WEATHER_LAYER_A/B`、`PK_WEATHER_WIND_LAYER_BASE(=2)` 必须同值。
const WEATHER_TABLE_LAYER_WEATHER_A := 0
const WEATHER_TABLE_LAYER_WEATHER_B := 1
const WEATHER_TABLE_LAYER_WIND_A := 2
const WEATHER_TABLE_LAYER_WIND_B := 3
const WEATHER_TABLE_LAYERS := 4
## 风的层号基址：wind_cur = WEATHER_TABLE_LAYER_WIND_BASE + cur。
const WEATHER_TABLE_LAYER_WIND_BASE := 2
## o2i == -1（南北 padding）的 texel：type 写 WT_CLEAR，其余通道 0。
## 真值 `WeatherType.WT.CLEAR`（weather_type.gd:24）= 0；
## tests/world/weather_table_layout_test.gd 里有等值断言，防止枚举被改后这条静默失效。
const WEATHER_TABLE_PAD_TYPE := 0

## 一次天气提交的**纯字节计划**（不碰 GPU）：发布器与布局测试共用同一个出口。
##
## 入参全部是 index 空间的原始字节（长度 = lut_w * lut_h * 4，按 cell.index 排布）：
##   weather_src : R=type G=intensity B=cloud A=vapor（weather_lut 字节）
##   wind_src    : RG=风向*0.5+0.5 B=speed/20 A=1（wind_lut 字节）
##   o2i         : _build_offset_to_index() 的结果（map_w * map_h，-1 = padding）
##   cur_before  : 上一次提交后的层号（0/1），-1 = 还没有任何一次成功提交
##
## 返回：
##   ok           : false 时 reason 说明原因，调用方必须把 weather_table_valid 置 false
##   重建（rebuild）: 首次提交 / cur_before 非法 ⇒ 4 层全写、next_cur = 0
##   增量           : 只写 back = 1 - cur_before（天气）与 2 + back（风），next_cur = back
##   layer_ids    : 本次要 update_layer 的层号（PackedInt32Array）
##   layer_bytes  : 与 layer_ids 一一对应的、已是 offset 空间的字节
static func weather_table_commit_plan(weather_src: PackedByteArray, wind_src: PackedByteArray,
		o2i: PackedInt32Array, map_w: int, map_h: int, n_cells: int,
		cur_before: int, identity: bool = false) -> Dictionary:
	var plan: Dictionary = {
		"ok": false,
		"reason": "",
		"rebuild": false,
		"next_cur": -1,
		"layer_ids": PackedInt32Array(),
		"layer_bytes": [],
	}
	if map_w <= 0 or map_h <= 0:
		plan.reason = "invalid_map_dims"
		return plan
	if n_cells <= 0:
		plan.reason = "invalid_cell_count"
		return plan
	var bytes_per_cell: int = CellTableCodecScript.BYTES_PER_TEXEL
	if o2i.size() != map_w * map_h:
		# 重排表的长度必须与纹理尺寸一致，否则 offset 语义直接错位。
		plan.reason = "offset_to_index_size_mismatch"
		return plan
	if map_w * map_h < n_cells:
		# offset 空间装不下全部 cell：重排会丢格（不是越界写，但也绝不发布）。
		plan.reason = "offset_space_too_small"
		return plan
	# 长度判据照 _publish_cell_table：LUT 网格比 n_cells 小时读到的就是错位字节。
	if weather_src.size() < n_cells * bytes_per_cell or wind_src.size() < n_cells * bytes_per_cell:
		plan.reason = "lut_payload_too_small"
		return plan
	var want: int = map_w * map_h * bytes_per_cell
	var weather_layer := weather_src if weather_src.size() == want else weather_src.slice(0, want)
	var wind_layer := wind_src if wind_src.size() == want else wind_src.slice(0, want)
	if not identity:
		weather_layer = CellTableCodecScript.reorder_to_offset(
			weather_src, o2i, map_w, map_h, bytes_per_cell, WEATHER_TABLE_PAD_TYPE)
		wind_layer = CellTableCodecScript.reorder_to_offset(
			wind_src, o2i, map_w, map_h, bytes_per_cell, 0)
	if weather_layer.size() != want or wind_layer.size() != want:
		# reorder_to_offset 在 texels<=0 时才返回空；这里等价于上面的尺寸检查，留着做双保险。
		plan.reason = "reorder_size_mismatch"
		return plan
	plan.ok = true
	plan.reason = "ok"
	if cur_before != WEATHER_TABLE_LAYER_WEATHER_A and cur_before != WEATHER_TABLE_LAYER_WEATHER_B:
		# 首次提交（或上次失败后 cur 被清成 -1）：整张重建，4 层写同一份。
		plan.rebuild = true
		plan.next_cur = WEATHER_TABLE_LAYER_WEATHER_A
		plan.layer_ids = PackedInt32Array([
			WEATHER_TABLE_LAYER_WEATHER_A, WEATHER_TABLE_LAYER_WEATHER_B,
			WEATHER_TABLE_LAYER_WIND_A, WEATHER_TABLE_LAYER_WIND_B])
		plan.layer_bytes = [
			weather_layer, weather_layer.duplicate(), wind_layer, wind_layer.duplicate()]
		return plan
	var back: int = WEATHER_TABLE_LAYER_WEATHER_A if cur_before == WEATHER_TABLE_LAYER_WEATHER_B \
		else WEATHER_TABLE_LAYER_WEATHER_B
	plan.rebuild = false
	plan.next_cur = back
	plan.layer_ids = PackedInt32Array([back, WEATHER_TABLE_LAYER_WIND_BASE + back])
	plan.layer_bytes = [weather_layer, wind_layer]
	return plan
