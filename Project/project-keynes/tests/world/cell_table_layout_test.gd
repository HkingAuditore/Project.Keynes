extends SceneTree

# Headless:
#   cd Project/project-keynes
#   godot --headless -s tests/world/cell_table_layout_test.gd
#
# 守的契约：
#   docs/plans/terrain-cell-field-contract.md §3（cell_table 层契约 / offset 空间）
#   docs/plans/terrain-hex-mesh-implementation-plan.md §3.4（按 offset_to_index 重排）
#
# `cell_table` 是 Texture2DArray（RGBA8，map_w × map_h，1 texel = 1 格）。layer0/1/2 的坐标
# 空间是 **offset 空间**而不是 `cell.index` 空间，layer3 反过来（index 空间）。baker 侧
# （cell_lut_baker.gd）由另一条任务接线，所以本测试用 **mock publisher**：
#   1. 造 cells_by_index：`cell.index` 顺序 ≠ offset 顺序，含回绕列（q 推出来的 col
#      落在 [0,map_w) 之外）与空槽（o2i == -1）；
#   2. 按 DCTerrainIndexBaker.build_cell_inputs() 的规则造 offset_to_index；
#   3. 用 scripts/rendering/bakers/cell_table_codec.gd 生成四层字节：前三层重排到
#      offset 空间，layer3 保持 index 空间（不重排）；
#   4. 每一层逐 texel 与「cells_by_index[...] 的字段」逐字节对比
#      （期望值在测试里按契约 §3 的字段表独立派生，不复用 codec 的搬运逻辑）。
#
# 层布局（契约 §3 + Web 方案 §3.1）：
#   layer0 class : R=biome  G=vegetation  B=cover   A=landform        ← offset 空间（重排）
#   layer1 state : R=temp   G=wet         B=snow    A=vitality（陆）/ sea_ice（水）
#   layer2 aux   : R=fog_k  G=water_depth B=flags   A=reserved
#   layer3 class_by_index : 同 layer0 的四个通道，但坐标空间是 **cell.index 空间**
#                  （第 i 格放在 (i % map_w, i / map_w)，**不重排**；Web 方案 §3.1）。
#
# layer3 是这一轮（Web 方案 W1）的交付重点，所以除了「每 texel 与 cells_by_index[i]
# 逐字节一致」，还要断它和 layer0 是**同一份内容的两种排布**（方案 §6 风险表：只更新
# layer0、忘了 layer3 会让 Web 的 GI 弹射色过时），以及 n_cells > map_w*map_h 时
# 发布器降级成 3 层 + 一条 warning（不越界写）。

const Codec = preload("res://scripts/rendering/bakers/cell_table_codec.gd")
## [cell-field-web 2026-11-18] 发布器的层数决策（cell_table_layer_target）在 baker 里，
## 这里只调它的**静态纯函数**，不建 MapBaker/MapData（同 mock publisher 的取舍）。
const Baker = preload("res://scripts/rendering/bakers/cell_lut_baker.gd")

const MAP_W := 9
const MAP_H := 6

## 空槽（没有 cell 的 offset）：o2i 必须保持 -1，texel 写 fill。
const HOLES: Array[Vector2i] = [Vector2i(2, 3), Vector2i(6, 0), Vector2i(0, 5)]

var _checks := 0
var _failures := 0

## 按 cell.index 排列的 mock cell（Dictionary，供字段语义检查与可读性）。
var _cells: Array = []
## 按 cell.index 排列的通道数组 —— mock publisher 传给 codec 的**真实输入**，
## 期望值也从这里派生（避免 float32 存储与 Dictionary 里 float64 取值的 1LSB 差异）。
var _terr := PackedByteArray()
var _veg := PackedByteArray()
var _cover := PackedByteArray()
var _landform := PackedByteArray()
var _temp := PackedFloat32Array()
var _wet := PackedFloat32Array()
var _snow := PackedFloat32Array()
var _vit_or_ice := PackedFloat32Array()
var _fog := PackedByteArray()
var _depth := PackedFloat32Array()
var _flags := PackedByteArray()
## offset 线性下标 → cell.index（-1 = 空）。
var _o2i := PackedInt32Array()
## 回绕列两个探针 cell 的 index。
var _wrap_east_index := -1   # 未回绕 col == MAP_W  ⇒ 落进 col 0
var _wrap_west_index := -1   # 未回绕 col == -1     ⇒ 落进 col MAP_W-1


## [cell-field-web 2026-11-18] 捕获 push_warning 的最小 Logger。
## 用途：证明「layer3 装不下 ⇒ 3 层」这条降级**不是静默的**（方案 §0：让错误报出来）。
## Godot 4 的 push_warning 会作为 error_type=1 的 _log_error 落到这里，正文在 code 参数；
## 这里不区分 warning/error 类型，直接按正文里的关键字判定，避免依赖 ErrorType 枚举名。
class WarningLog extends Logger:
	var messages: Array[String] = []

	func _log_error(_function: String, _file: String, _line: int, code: String,
			_rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		messages.append(code)

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _init() -> void:
	_build_mock_publisher()
	_check_layer_constants_and_quantization()
	_check_mock_shape()
	_check_class_layer()
	_check_state_layer()
	_check_aux_layer()
	_check_empty_slots_and_fill()
	_check_wrap_columns()
	_check_generic_reorder()
	_check_class_by_index_layer()
	_check_layer3_mirrors_layer0()
	_check_layer3_index_derivation()
	_check_index_space_overflow_degrades()
	_check_publisher_layer_target()
	_check_publisher_payload_guards()
	print("=== cell table layout: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ─────────────────────────────────────────────────────────────────────────
# mock publisher
# ─────────────────────────────────────────────────────────────────────────

func _build_mock_publisher() -> void:
	var slots: Array[Vector2i] = []
	for row in range(MAP_H):
		for col in range(MAP_W):
			if HOLES.has(Vector2i(col, row)):
				continue
			slots.append(Vector2i(col, row))
	var n_cells := slots.size()
	_cells.resize(n_cells)
	_terr.resize(n_cells)
	_veg.resize(n_cells)
	_cover.resize(n_cells)
	_landform.resize(n_cells)
	_temp.resize(n_cells)
	_wet.resize(n_cells)
	_snow.resize(n_cells)
	_vit_or_ice.resize(n_cells)
	_fog.resize(n_cells)
	_depth.resize(n_cells)
	_flags.resize(n_cells)

	# 索引顺序故意打乱：index = (slot*7 + 3) % n_cells，gcd(7, n_cells) == 1 ⇒ 双射。
	for s in range(n_cells):
		var slot: Vector2i = slots[s]
		var row := slot.y
		var unwrapped_col := slot.x
		if slot == Vector2i(0, 4):
			unwrapped_col = MAP_W      # 东侧越过边界，physically 落在 col 0
		elif slot == Vector2i(MAP_W - 1, 1):
			unwrapped_col = -1         # 西侧越界，physically 落在 col MAP_W-1
		var idx := (s * 7 + 3) % n_cells
		var q := unwrapped_col - (row - (row & 1)) / 2
		var is_water := (idx % 5) == 0
		_terr[idx] = (idx * 37 + 11) % 256
		_veg[idx] = (idx * 53 + 7) % 256
		_cover[idx] = (idx * 29 + 3) % 256
		_landform[idx] = (idx * 17 + 5) % 256
		_temp[idx] = float((idx * 13) % 100) / 100.0
		_wet[idx] = float((idx * 31) % 100) / 100.0
		_snow[idx] = float((idx * 7) % 100) / 100.0
		# A 通道双语义：水格写 sea_ice，陆格写 vegetation_vitality（与 dyn_lut 一致）。
		_vit_or_ice[idx] = float((idx * 41) % 100) / 100.0 if is_water \
			else float((idx * 23) % 100) / 100.0
		_fog[idx] = (idx * 11 + 64) % 256
		_depth[idx] = float((idx * 19) % 100) / 100.0
		_flags[idx] = (idx * 3) % 256
		_cells[idx] = {
			"index": idx,
			"q": q,
			"r": row,
			"slot": slot,
			"unwrapped_col": unwrapped_col,
			"is_water": is_water,
		}
		if slot == Vector2i(0, 4):
			_wrap_east_index = idx
		elif slot == Vector2i(MAP_W - 1, 1):
			_wrap_west_index = idx

	# offset_to_index：与 build_cell_inputs() 同规则（off.y 越界丢弃，off.x 走 posmod）。
	_o2i.resize(MAP_W * MAP_H)
	_o2i.fill(-1)
	for idx in range(_cells.size()):
		var cell: Dictionary = _cells[idx]
		var off := HexUtils.cube_to_offset(int(cell["q"]), int(cell["r"]))
		if off.y >= 0 and off.y < MAP_H:
			_o2i[off.y * MAP_W + posmod(off.x, MAP_W)] = idx


# ─────────────────────────────────────────────────────────────────────────
# 1. 层号常量（契约 §3 / shader PK_CELL_LAYER_*）与 8bit 量化口径
# ─────────────────────────────────────────────────────────────────────────

func _check_layer_constants_and_quantization() -> void:
	_expect(Codec.LAYER_CLASS == 0 and Codec.LAYER_STATE == 1 and Codec.LAYER_AUX == 2,
		"layer ids match the contract / shader PK_CELL_LAYER_CLASS/STATE/AUX = 0/1/2")
	# [cell-field-web 2026-11-18] layer3 = class_by_index（Web 方案 §3.1）：层号 3、总层数 4。
	_expect(Codec.LAYER_CLASS_BY_INDEX == 3,
		"layer3 is the class_by_index mirror at layer id 3")
	_expect(Codec.LAYER_COUNT == 4,
		"cell_table builds exactly 4 layers (3 offset-space + 1 index-space)")
	_expect(Codec.BYTES_PER_TEXEL == 4, "one cell_table texel is RGBA8 (4 bytes)")
	_expect(Codec.FILL_BYTE == 0, "documented fill byte for o2i == -1 is 0")
	# 8bit 量化口径：与 DCDynamicAtlasBaker.q01_byte / shader pk_byte_of 同一式。
	_expect(Codec.q01_byte(0.0) == 0 and Codec.q01_byte(0.25) == 64 \
			and Codec.q01_byte(0.5) == 128 and Codec.q01_byte(1.0) == 255,
		"q01_byte round-trips the documented 0 / 0.25 / 0.5 / 1.0 quanta")
	_expect(Codec.q01_byte(-0.3) == 0 and Codec.q01_byte(1.7) == 255,
		"q01_byte clamps out-of-range normalized values")


# ─────────────────────────────────────────────────────────────────────────
# 2. mock 形状：索引顺序 ≠ offset 顺序，回绕列真的越界
# ─────────────────────────────────────────────────────────────────────────

func _check_mock_shape() -> void:
	var n_cells := _cells.size()
	_expect(n_cells == MAP_W * MAP_H - HOLES.size(),
		"mock map has %d cells over %dx%d offsets (%d holes)" % [
			n_cells, MAP_W, MAP_H, HOLES.size()])
	var seen := PackedByteArray()
	seen.resize(n_cells)
	var covered := 0
	var out_of_order := 0
	for idx in range(_o2i.size()):
		var ci: int = _o2i[idx]
		if ci < 0:
			continue
		covered += 1
		if ci < n_cells:
			seen[ci] = 1
		if ci != idx:
			out_of_order += 1
	var all_once := true
	for ci in range(n_cells):
		if seen[ci] == 0:
			all_once = false
	_expect(covered == n_cells and all_once,
		"offset_to_index covers every cell.index exactly once (%d/%d)" % [covered, n_cells])
	_expect(out_of_order > 0,
		"mock deliberately reorders cell.index vs offset order (%d/%d texels differ)" % [
			out_of_order, _o2i.size()])
	var holes_ok := true
	for hole in HOLES:
		if _o2i[hole.y * MAP_W + hole.x] != -1:
			holes_ok = false
	_expect(holes_ok, "declared holes stay -1 in offset_to_index")


# ─────────────────────────────────────────────────────────────────────────
# 3-5. layer0/1/2（offset 空间）逐 texel 对比
# ─────────────────────────────────────────────────────────────────────────

func _check_class_layer() -> void:
	var n_cells := _cells.size()
	var by_index := Codec.class_bytes(n_cells, _terr, _veg, _cover, _landform)
	_expect(by_index.size() == n_cells * 4,
		"class_bytes emits 4 bytes per cell.index (%d bytes)" % by_index.size())
	var index_order_ok := true
	for idx in range(n_cells):
		if by_index[idx * 4] != _terr[idx] or by_index[idx * 4 + 1] != _veg[idx] \
				or by_index[idx * 4 + 2] != _cover[idx] \
				or by_index[idx * 4 + 3] != _landform[idx]:
			index_order_ok = false
	_expect(index_order_ok, "class_bytes lays cells out in cell.index order (R=biome..A=landform)")

	var layer := Codec.reorder_to_offset(by_index, _o2i, MAP_W, MAP_H, 4)
	_expect(layer.size() == MAP_W * MAP_H * 4,
		"class layer is map_w*map_h*4 bytes (%d)" % layer.size())
	var result := _compare_layer(layer, "class")
	_expect(result["bad"] == 0,
		"layer0 class: every texel equals cells_by_index[o2i[idx]] byte-for-byte (%d bad)%s" % [
			result["bad"], result["first"]])


func _check_state_layer() -> void:
	var n_cells := _cells.size()
	var by_index := Codec.state_bytes(n_cells, _temp, _wet, _snow, _vit_or_ice)
	_expect(by_index.size() == n_cells * 4,
		"state_bytes emits 4 bytes per cell.index (%d bytes)" % by_index.size())
	var layer := Codec.reorder_to_offset(by_index, _o2i, MAP_W, MAP_H, 4)
	var result := _compare_layer(layer, "state")
	_expect(result["bad"] == 0,
		"layer1 state: temp/wet/snow/vitality-or-sea_ice match cell fields (%d bad)%s" % [
			result["bad"], result["first"]])
	# A 通道双语义：水格 = sea_ice，陆格 = vegetation_vitality，两种都要有样本。
	var semantic_ok := true
	var found_water := false
	var found_land := false
	for idx in range(_o2i.size()):
		var ci: int = _o2i[idx]
		if ci < 0:
			continue
		var is_water: bool = bool((_cells[ci] as Dictionary)["is_water"])
		var want_a := _q01(_vit_or_ice[ci])
		if layer[idx * 4 + 3] != want_a:
			semantic_ok = false
		found_water = found_water or is_water
		found_land = found_land or not is_water
	_expect(semantic_ok and found_water and found_land,
		"state layer A channel keeps the land/water dual meaning (vitality vs sea_ice)")


func _check_aux_layer() -> void:
	var n_cells := _cells.size()
	var by_index := Codec.aux_bytes(n_cells, _fog, _depth, _flags)
	_expect(by_index.size() == n_cells * 4,
		"aux_bytes emits 4 bytes per cell.index (%d bytes)" % by_index.size())
	var layer := Codec.reorder_to_offset(by_index, _o2i, MAP_W, MAP_H, 4)
	var result := _compare_layer(layer, "aux")
	_expect(result["bad"] == 0,
		"layer2 aux: fog_k/water_depth/flags match cell fields (%d bad)%s" % [
			result["bad"], result["first"]])
	# 缺数组时的 documented 默认：fog_k = 255（未接线即全知），其余 0。
	var fallback := Codec.aux_bytes(n_cells, null, null, null)
	var fallback_ok := true
	for idx in range(n_cells):
		var base := idx * 4
		if fallback[base] != Codec.FOG_K_DEFAULT or fallback[base + 1] != 0 \
				or fallback[base + 2] != 0 or fallback[base + 3] != 0:
			fallback_ok = false
	_expect(fallback_ok,
		"aux defaults are fog_k=255 (unwired = omniscient) and 0 for depth/flags/reserved")


# ─────────────────────────────────────────────────────────────────────────
# 6. 空槽：o2i == -1 的 texel 必须是 fill
# ─────────────────────────────────────────────────────────────────────────

func _check_empty_slots_and_fill() -> void:
	var n_cells := _cells.size()
	var by_index := Codec.class_bytes(n_cells, _terr, _veg, _cover, _landform)
	var layer := Codec.reorder_to_offset(by_index, _o2i, MAP_W, MAP_H, 4)
	var holes_ok := true
	for hole in HOLES:
		var base: int = (hole.y * MAP_W + hole.x) * 4
		for k in range(4):
			if layer[base + k] != Codec.FILL_BYTE:
				holes_ok = false
	_expect(holes_ok, "cells with o2i == -1 are the documented fill byte (0)")

	var filled := Codec.reorder_to_offset(by_index, _o2i, MAP_W, MAP_H, 4, 7)
	var fill_ok := true
	for hole in HOLES:
		var base: int = (hole.y * MAP_W + hole.x) * 4
		for k in range(4):
			if filled[base + k] != 7:
				fill_ok = false
	_expect(fill_ok, "reorder_to_offset honours an explicit fill byte")


# ─────────────────────────────────────────────────────────────────────────
# 7. 回绕列
# ─────────────────────────────────────────────────────────────────────────

func _check_wrap_columns() -> void:
	_expect(_wrap_east_index >= 0 and _wrap_west_index >= 0,
		"mock contains both wrap-column probe cells")
	if _wrap_east_index < 0 or _wrap_west_index < 0:
		return
	var east_cell: Dictionary = _cells[_wrap_east_index]
	var west_cell: Dictionary = _cells[_wrap_west_index]
	# 这两个 cell 的未回绕列确实越界：q 推出来的 col 不在 [0, map_w)。
	var east_off := HexUtils.cube_to_offset(int(east_cell["q"]), int(east_cell["r"]))
	var west_off := HexUtils.cube_to_offset(int(west_cell["q"]), int(west_cell["r"]))
	_expect(east_off.x == MAP_W and west_off.x == -1,
		"wrap probes are built outside [0, map_w): east col %d, west col %d" % [
			east_off.x, west_off.x])

	var n_cells := _cells.size()
	var layer := Codec.reorder_to_offset(
		Codec.state_bytes(n_cells, _temp, _wet, _snow, _vit_or_ice),
		_o2i, MAP_W, MAP_H, 4)

	# 东侧越界（col == MAP_W）落进 col 0；西侧（col == -1）落进 col MAP_W-1。
	var east_idx := 4 * MAP_W + 0
	var west_idx := 1 * MAP_W + (MAP_W - 1)
	_expect(_o2i[east_idx] == _wrap_east_index and _o2i[west_idx] == _wrap_west_index,
		"offset_to_index folds out-of-range columns with posmod(col, map_w)")
	var east_want := _q01(_temp[_wrap_east_index])
	var west_want := _q01(_temp[_wrap_west_index])
	_expect(layer[east_idx * 4] == east_want and layer[west_idx * 4] == west_want,
		"wrap-column texels carry the wrapped cell's bytes (east col %d -> 0, west col -1 -> %d)" % [
			MAP_W, MAP_W - 1])


# ─────────────────────────────────────────────────────────────────────────
# 8. reorder_to_offset 的通用行为（步长 / 越界 / 尺寸）
# ─────────────────────────────────────────────────────────────────────────

func _check_generic_reorder() -> void:
	# 任意 bytes_per_cell（这里 1）都能按 stride 搬运。
	var src := PackedByteArray([10, 20, 30, 40])
	var o2i := PackedInt32Array([3, 1, -1, 0])
	var out := Codec.reorder_to_offset(src, o2i, 2, 2, 1, 9)
	_expect(out == PackedByteArray([40, 20, 9, 10]),
		"reorder_to_offset honours bytes_per_cell and fill for arbitrary strides")

	# o2i 越界（>= 源 texel 数）与过短的 o2i 都退化为 fill，不崩不越界。
	var oob := PackedInt32Array([0, 99])
	var clamped := Codec.reorder_to_offset(PackedByteArray([5, 6, 7, 8]), oob, 2, 2, 2, 1)
	_expect(clamped.size() == 8 and clamped[0] == 5 and clamped[1] == 6 \
			and clamped[2] == 1 and clamped[3] == 1 \
			and clamped[4] == 1 and clamped[7] == 1,
		"out-of-range and short offset_to_index fall back to fill without reading OOB")

	_expect(Codec.reorder_to_offset(src, o2i, 0, 4, 1).is_empty(),
		"zero-width map returns an empty reorder result")


# ─────────────────────────────────────────────────────────────────────────
# 9. layer3 class_by_index：**cell.index 空间**，内容是 layer0 的原样字节
#    （Web 方案 §3.1）
# ─────────────────────────────────────────────────────────────────────────

func _check_class_by_index_layer() -> void:
	var n_cells := _cells.size()
	var layer := Codec.class_by_index_bytes(
		n_cells, _terr, _veg, _cover, _landform, MAP_W, MAP_H)
	_expect(layer.size() == MAP_W * MAP_H * 4,
		"layer3 class_by_index keeps the layer0 size (map_w*map_h*4 = %d bytes)" % layer.size())

	# 逐字节：第 i 个 texel 就是 cells_by_index[i] 的 (biome, veg, cover, landform)，**不重排**。
	var bad := 0
	var first := ""
	for i in range(n_cells):
		var want := _expected_texel(i, "class")
		for k in range(4):
			var got: int = layer[i * 4 + k]
			if got != want[k]:
				bad += 1
				if first.is_empty():
					first = " first: texel %d (cell %d) byte %d = %d want %d" % [i, i, k, got, want[k]]
				break
	_expect(bad == 0,
		"layer3: texel i == cells_by_index[i] (R=biome G=veg B=cover A=landform), no reorder (%d bad)%s"
			% [bad, first])

	# 与 layer0 的**输入**逐字节同源：layer3 的前 n_cells*4 字节必须 == class_bytes 的返回值
	# （不做任何重新量化，也不做 offset 重排）。
	var raw := Codec.class_bytes(n_cells, _terr, _veg, _cover, _landform)
	var prefix_ok := layer.size() >= raw.size()
	if prefix_ok:
		for b in range(raw.size()):
			if layer[b] != raw[b]:
				prefix_ok = false
				break
	_expect(prefix_ok,
		"layer3 bytes are literally DCCellTableCodec.class_bytes(...) — no second quantization")

	# 非满格地图（n_cells < map_w*map_h）：尾部按 fill 补齐，不缩短层尺寸。
	var short_cells: int = n_cells - 2
	var short_layer := Codec.class_by_index_bytes(
		short_cells, _terr, _veg, _cover, _landform, MAP_W, MAP_H)
	var tail_ok: bool = short_layer.size() == MAP_W * MAP_H * 4
	if tail_ok:
		for b in range(short_cells * 4, short_layer.size()):
			if short_layer[b] != Codec.FILL_BYTE:
				tail_ok = false
				break
	_expect(tail_ok,
		"a non-full grid pads layer3's tail with the fill byte and keeps map_w*map_h size")


func _check_layer3_mirrors_layer0() -> void:
	var n_cells := _cells.size()
	var layer0 := Codec.reorder_to_offset(
		Codec.class_bytes(n_cells, _terr, _veg, _cover, _landform), _o2i, MAP_W, MAP_H, 4)
	var layer3 := Codec.class_by_index_bytes(
		n_cells, _terr, _veg, _cover, _landform, MAP_W, MAP_H)
	# 方案 §6「新增 layer3 被遗漏同步」的直接守卫：同一份内容，两种排布。
	# 对每个 offset o：layer3[o2i[o]] == layer0[o]；o2i[o] == -1 的空洞跳过。
	var bad := 0
	var checked := 0
	var skipped := 0
	var seen := PackedByteArray()
	seen.resize(n_cells)
	var first := ""
	for o in range(_o2i.size()):
		var ci: int = _o2i[o]
		if ci < 0:
			skipped += 1
			continue
		checked += 1
		if ci < n_cells:
			seen[ci] = 1
		for k in range(4):
			if layer3[ci * 4 + k] != layer0[o * 4 + k]:
				bad += 1
				if first.is_empty():
					first = " first: offset %d (cell %d) byte %d layer3=%d layer0=%d" % [
						o, ci, k, layer3[ci * 4 + k], layer0[o * 4 + k]]
				break
	# 同时验证重排是**双射**：每个 cell.index 都被某个 offset 取到恰好一次（上面的 seen）。
	var bijective := true
	for ci in range(n_cells):
		if seen[ci] == 0:
			bijective = false
	_expect(bad == 0 and checked == n_cells and bijective,
		"layer0 and layer3 are one payload in two layouts: layer3[o2i[o]] == layer0[o] for all %d slots (%d bad, %d holes)%s"
			% [checked, bad, skipped, first])

	# 守卫的非空性：若两种排布恰好相同，上一条断言就退化成恒真。
	var differing := 0
	for o in range(_o2i.size()):
		if _o2i[o] >= 0 and _o2i[o] != o:
			differing += 1
	_expect(differing > 0,
		"the two layouts genuinely differ (%d/%d slots where cell.index != offset)"
			% [differing, _o2i.size()])


func _check_layer3_index_derivation() -> void:
	var n_cells := _cells.size()
	var layer := Codec.class_by_index_bytes(
		n_cells, _terr, _veg, _cover, _landform, MAP_W, MAP_H)
	# index 空间没有回绕问题：第 i 格的列就是 i % map_w、行就是 i / map_w。
	var bad := 0
	var first := ""
	for i in range(n_cells):
		var col: int = i % MAP_W
		var row: int = int(i / MAP_W)
		var texel: int = row * MAP_W + col
		var want := _expected_texel(i, "class")
		for k in range(4):
			if layer[texel * 4 + k] != want[k]:
				bad += 1
				if first.is_empty():
					first = " first: cell %d at (col %d,row %d) texel %d byte %d" % [
						i, col, row, texel, k]
				break
	_expect(bad == 0,
		"layer3 texel (i %% map_w, i / map_w) carries cell.index i's bytes (%d bad)%s"
			% [bad, first])
	var last: int = n_cells - 1
	_expect(int(last / MAP_W) < MAP_H and last % MAP_W < MAP_W,
		"the last cell.index %d still lands inside the %dx%d layer at (col %d, row %d)" % [
			last, MAP_W, MAP_H, last % MAP_W, int(last / MAP_W)])

	# 回绕探针：offset 空间靠 posmod 把它折到 col MAP_W-1，index 空间里它就在自己的序号处。
	# 两种排布在这个 cell 上指向**不同** texel —— 这正是不能拿 layer0 代替 layer3 的理由。
	if _wrap_west_index >= 0:
		var col: int = _wrap_west_index % MAP_W
		var row: int = int(_wrap_west_index / MAP_W)
		var index_texel: int = row * MAP_W + col
		var wrapped_texel: int = 1 * MAP_W + (MAP_W - 1)
		var want := _expected_texel(_wrap_west_index, "class")
		var at_index := true
		for k in range(4):
			if layer[index_texel * 4 + k] != want[k]:
				at_index = false
		_expect(at_index and index_texel != wrapped_texel,
			"a wrap-column cell sits at index-space texel %d (col %d,row %d), not at the wrapped offset %d" % [
				index_texel, col, row, wrapped_texel])


func _check_index_space_overflow_degrades() -> void:
	var n_cells := _cells.size()
	_expect(Codec.index_space_fits(n_cells, MAP_W, MAP_H),
		"index_space_fits accepts a full-grid cell count (%d <= %d x %d)" % [
			n_cells, MAP_W, MAP_H])
	_expect(not Codec.index_space_fits(MAP_W * MAP_H + 1, MAP_W, MAP_H),
		"index_space_fits rejects n_cells > map_w*map_h (one extra cell does not fit)")
	_expect(not Codec.index_space_fits(0, MAP_W, MAP_H)
			and not Codec.index_space_fits(n_cells, 0, MAP_H),
		"index_space_fits rejects empty maps / zero dimensions")

	# 装不下 ⇒ 一个字节都不产（发布器只能跳过 layer3，不存在"越界/错位写"的可能）。
	var overflow := Codec.class_by_index_bytes(
		MAP_W * MAP_H + 1, _terr, _veg, _cover, _landform, MAP_W, MAP_H)
	_expect(overflow.is_empty(),
		"class_by_index_bytes returns empty instead of writing OOB when n_cells > map_w*map_h")

	# 层数契约：降级后对外承诺 3 层，正好等于 layer3 的层号 ⇒ 第 4 层在 shader 侧不可达
	# （推送侧 cell_class_index_bound = cell_table_layers >= 4 因此为 false）。
	_expect(Codec.LAYER_CLASS_BY_INDEX == 3 and Codec.LAYER_CLASS_BY_INDEX < Codec.LAYER_COUNT,
		"the degraded layer count (3) is LAYER_CLASS_BY_INDEX, below LAYER_COUNT (%d)" % Codec.LAYER_COUNT)

	# 占位层：仍要凑够 LAYER_COUNT 层才能建 Texture2DArray，内容是整层 fill。
	var placeholder := Codec.index_space_fill_bytes(MAP_W, MAP_H)
	var fill_ok: bool = placeholder.size() == MAP_W * MAP_H * 4
	if fill_ok:
		for b in placeholder:
			if b != Codec.FILL_BYTE:
				fill_ok = false
				break
	_expect(fill_ok,
		"the degraded layer3 is a full FILL_BYTE placeholder at map_w*map_h (LAYER_COUNT stays 4)")


func _check_publisher_layer_target() -> void:
	var n_cells := _cells.size()
	# 发布器自己的判定（不是测试里复述的判据）：放得下 ⇒ 4 层、无 warning。
	var log_full := WarningLog.new()
	OS.add_logger(log_full)
	var target_full: int = Baker.cell_table_layer_target(n_cells, MAP_W, MAP_H)
	OS.remove_logger(log_full)
	_expect(target_full == Codec.LAYER_COUNT and log_full.messages.is_empty(),
		"publisher promises %d layers and stays quiet when %d cells fit %dx%d (warnings: %d)" % [
			target_full, n_cells, MAP_W, MAP_H, log_full.messages.size()])

	# 装不下 ⇒ 3 层，并且**真的**有一条 warning（方案 §0：错误要报出来，不许静默降级）。
	print("  [EXPECTED] the [cell-table] warning below is the degraded-layer3 path under test")
	var log_over := WarningLog.new()
	OS.add_logger(log_over)
	var target_over: int = Baker.cell_table_layer_target(MAP_W * MAP_H + 1, MAP_W, MAP_H)
	OS.remove_logger(log_over)
	_expect(target_over == Codec.LAYER_CLASS_BY_INDEX,
		"publisher drops to %d layers (not 4) when n_cells > map_w*map_h" % target_over)
	var warned: bool = log_over.messages.size() == 1 \
			and log_over.messages[0].contains("class_by_index")
	_expect(warned,
		"the degraded path emits exactly one warning mentioning class_by_index (got %d: %s)" % [
			log_over.messages.size(), str(log_over.messages)])


func _check_publisher_payload_guards() -> void:
	var source := PackedByteArray([11, 12, 13, 14, 21, 22, 23, 24])
	var padded: PackedByteArray = Baker._cell_index_table_bytes(source, 2, 2, 2)
	_expect(padded.size() == 16 and padded.slice(0, 8) == source
			and padded.slice(8, 16) == PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]),
		"class_by_index pads only the unused tail after a complete per-cell payload")
	_expect(Baker._cell_index_table_bytes(source.slice(0, 4), 2, 2, 2).is_empty(),
		"class_by_index rejects a short source instead of silently padding missing cell data")
	var oversized := source.duplicate()
	oversized.append_array(PackedByteArray([31, 32, 33, 34]))
	_expect(Baker._cell_index_table_bytes(oversized, 2, 2, 2).is_empty(),
		"class_by_index rejects an oversized source instead of silently truncating it")

	var images: Array[Image] = [Image.new(), Image.new(), Image.new(), Image.new()]
	var required := [true, true, true, true]
	_expect(Baker.cell_table_images_valid(images, required),
		"all required cell_table layers pass the publication guard")
	images[Codec.LAYER_AUX] = null
	_expect(not Baker.cell_table_images_valid(images, required),
		"a missing required layer fails the publication guard before publishing")
	required[Codec.LAYER_AUX] = false
	_expect(Baker.cell_table_images_valid(images, required),
		"an unchanged optional layer may remain null during an incremental publish")


# ─────────────────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────────────────

## 逐 texel 对比一层。期望值按契约的字段表直接从 mock 输入数组派生。
## 返回 {"bad": int, "first": String}。
func _compare_layer(layer: PackedByteArray, layer_name: String) -> Dictionary:
	var bad := 0
	var first := ""
	for idx in range(_o2i.size()):
		var ci: int = _o2i[idx]
		var want := _expected_texel(ci, layer_name)
		var base: int = idx * 4
		for k in range(4):
			if layer[base + k] != want[k]:
				bad += 1
				if first.is_empty():
					first = " first: texel %d (cell %d) byte %d = %d want %d" % [
						idx, ci, k, layer[base + k], want[k]]
				break
	return {"bad": bad, "first": first}


## 契约 §3 的层字段表：从 mock 的 per-index 输入数组直接派生 4 个字节（-1 槽 = fill 0）。
func _expected_texel(ci: int, layer_name: String) -> PackedByteArray:
	var want := PackedByteArray([0, 0, 0, 0])
	if ci < 0 or ci >= _cells.size():
		return want
	match layer_name:
		"class":
			want[0] = _terr[ci]
			want[1] = _veg[ci]
			want[2] = _cover[ci]
			want[3] = _landform[ci]
		"state":
			want[0] = _q01(_temp[ci])
			want[1] = _q01(_wet[ci])
			want[2] = _q01(_snow[ci])
			want[3] = _q01(_vit_or_ice[ci])
		"aux":
			want[0] = _fog[ci]
			want[1] = _q01(_depth[ci])
			want[2] = _flags[ci]
			want[3] = 0
	return want


## 与 DCDynamicAtlasBaker.q01_byte 同式的独立实现（量化契约）。
func _q01(v: float) -> int:
	return clampi(int(round(clampf(v, 0.0, 1.0) * 255.0)), 0, 255)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
