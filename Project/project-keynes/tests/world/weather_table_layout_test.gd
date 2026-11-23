extends SceneTree

# Headless:
#   cd Project/project-keynes
#   godot --headless -s tests/world/weather_table_layout_test.gd
# 真后端（**必须跑**，headless 的 GPU 回读恒为 null，不能当视觉证据）：
#   godot --rendering-driver opengl3 -s tests/world/weather_table_layout_test.gd
#   godot --rendering-driver vulkan  -s tests/world/weather_table_layout_test.gd
#
# 守的契约：
#   docs/plans/terrain-cell-field-overlays-plan.md §3.3（weather_table 层契约 / 双缓冲）
#   docs/plans/terrain-cell-field-contract.md §3（cell_table 同一套范式）
#
# `weather_table` 是 Texture2DArray（RGBA8，map_w × map_h，1 texel = 1 格，**offset 空间**）：
#   layer 0 / 1  天气 A / B : R=type G=intensity B=cloud A=vapor（与 weather_lut 同布局）
#   layer 2 / 3  风     A / B : RG=单位风向*0.5+0.5  B=speed/20  A=1（与 wind_lut 同编码）
#
# 本测试分两层做断言，**不假绿**：
#   1) 纯字节层（headless 也有意义）：weather_table_commit_plan() 是发布器与测试共用的
#      唯一出口 —— 逐字节对 weather_lut / wind_lut 的 index 空间字节按 o2i 重排后的结果，
#      空洞按 padding 规则，翻转语义靠"4 层字节存储 + 只写 back 层"的模拟来守。
#   2) 发布器层：真建一张 Texture2DArray，断言尺寸/层数/格式/valid/层号翻转；
#      **内容**回读（get_layer_data）在 headless 下恒为 null ⇒ 该组断言显式 SKIPPED，
#      真后端（opengl3 / vulkan）下才逐字节比对 —— 报告里逐字贴两个后端的实测结果。
#
# 层号双缓冲的核心断言（方案 §3.3「只写旧的那一层，不拷贝数据」）：
#   提交 N 之后 prev 层（1 - cur）的内容 == 提交 N-1 之后 cur 层的内容。
#   这条成立才说明"翻转层号"真的等价于旧的 weather_lut / weather_lut_prev 两张纹理，
#   而不是每次偷偷整张重传。

const Baker = preload("res://scripts/rendering/bakers/cell_lut_baker.gd")
const Codec = preload("res://scripts/rendering/bakers/cell_table_codec.gd")
const WindSource = preload("res://scripts/rendering/weather_wind_source.gd")

const MAP_W := 9
const MAP_H := 6
## 空槽（没有 cell 的 offset）：o2i 保持 -1，texel 写 padding 规则。
const HOLES: Array[Vector2i] = [Vector2i(2, 3), Vector2i(6, 0), Vector2i(0, 5)]

var _checks := 0
var _failures := 0
var _skipped := 0

## 按 cell.index 排列的 mock 输入（index 空间，与真实 weather_lut 字节同布局）。
var _weather_src: PackedByteArray = PackedByteArray()
var _wind_src: PackedByteArray = PackedByteArray()
## offset 线性下标 → cell.index（-1 = 空），由测试**独立**按契约规则推导。
var _o2i: PackedInt32Array = PackedInt32Array()
var _map: MapData = null
var _n_cells := 0
var _wrap_east_index := -1
var _wrap_west_index := -1


func _init() -> void:
	_build_mock_world()
	_check_layer_constants()
	_check_padding_type()
	_check_wind_encoding_contract()
	_check_wind_publication_reuse()
	_check_offset_to_index_rule()
	_check_commit_plan_bytes()
	_check_padding_rows()
	_check_wrap_columns()
	_check_flip_semantics()
	_check_plan_failure_paths()
	_check_publisher_headless()
	_check_publisher_failure_keeps_table_untouched()
	_check_backend_readback()
	print("=== weather table layout: %d checks, %d failures, %d skipped ===" % [
		_checks, _failures, _skipped])
	quit(0 if _failures == 0 else 1)


# ─────────────────────────────────────────────────────────────────────────
# mock world：index 顺序 ≠ offset 顺序，含回绕列与空槽
# ─────────────────────────────────────────────────────────────────────────

func _build_mock_world() -> void:
	var slots: Array[Vector2i] = []
	for row in range(MAP_H):
		for col in range(MAP_W):
			if HOLES.has(Vector2i(col, row)):
				continue
			slots.append(Vector2i(col, row))
	_n_cells = slots.size()
	_map = MapData.new(MAP_W, MAP_H)
	_weather_src.resize(_n_cells * 4)
	_wind_src.resize(_n_cells * 4)

	# index 顺序故意打乱：index = (slot*7 + 3) % n_cells（gcd(7, n_cells) == 1 ⇒ 双射）。
	for s in range(slots.size()):
		var slot: Vector2i = slots[s]
		var row: int = slot.y
		var unwrapped_col: int = slot.x
		if slot == Vector2i(0, 4):
			unwrapped_col = MAP_W      # 东侧越过边界，physically 落在 col 0
		elif slot == Vector2i(MAP_W - 1, 1):
			unwrapped_col = -1         # 西侧越界，physically 落在 col MAP_W-1
		var idx: int = (s * 7 + 3) % _n_cells
		var cube: Vector3i = HexUtils.offset_to_cube(unwrapped_col, row)
		var cell := HexCell.new(cube.x, cube.y)
		cell.index = idx
		_map.set_cell(cell)
		# weather 字节：四个通道都给可辨认的值（R=type 取 0..7 的真实枚举范围）。
		_weather_src[idx * 4] = int(WeatherType.WT.CLEAR + (idx % 8)) & 0xFF
		_weather_src[idx * 4 + 1] = (idx * 37 + 11) % 256
		_weather_src[idx * 4 + 2] = (idx * 53 + 7) % 256
		_weather_src[idx * 4 + 3] = (idx * 29 + 3) % 256
		_wind_src[idx * 4] = (idx * 17 + 5) % 256
		_wind_src[idx * 4 + 1] = (idx * 41 + 9) % 256
		_wind_src[idx * 4 + 2] = (idx * 13 + 2) % 256
		_wind_src[idx * 4 + 3] = 255
		if slot == Vector2i(0, 4):
			_wrap_east_index = idx
		elif slot == Vector2i(MAP_W - 1, 1):
			_wrap_west_index = idx

	# 独立推 o2i：off = cube_to_offset(q, r)；只丢 row 越界；col 走 posmod(map_w)。
	_o2i.resize(MAP_W * MAP_H)
	_o2i.fill(-1)
	for cell in _map.all_cells():
		var off: Vector2i = HexUtils.cube_to_offset(cell.q, cell.r)
		if off.y >= 0 and off.y < MAP_H:
			_o2i[off.y * MAP_W + posmod(off.x, MAP_W)] = int(cell.index)


# ─────────────────────────────────────────────────────────────────────────
# 1. 层号常量 / 总层数（方案 §3.3 表格）
# ─────────────────────────────────────────────────────────────────────────

func _check_layer_constants() -> void:
	_expect(Baker.WEATHER_TABLE_LAYERS == 4,
		"weather_table builds exactly 4 layers (2 weather + 2 wind), got %d"
			% Baker.WEATHER_TABLE_LAYERS)
	_expect(Baker.WEATHER_TABLE_LAYER_WEATHER_A == 0 and Baker.WEATHER_TABLE_LAYER_WEATHER_B == 1,
		"weather A/B are layers 0/1 (R=type G=intensity B=cloud A=vapor)")
	_expect(Baker.WEATHER_TABLE_LAYER_WIND_A == 2 and Baker.WEATHER_TABLE_LAYER_WIND_B == 3,
		"wind A/B are layers 2/3 (same encoding as wind_lut)")
	_expect(Baker.WEATHER_TABLE_LAYER_WIND_BASE == 2,
		"wind layer base is 2 so wind_cur == 2 + weather_cur")
	# 双缓冲只靠层号 ⇒ 天气两层 + 风两层必须两两相邻且成对。
	_expect(Baker.WEATHER_TABLE_LAYER_WEATHER_A % 2 == 0
			and Baker.WEATHER_TABLE_LAYER_WEATHER_B == Baker.WEATHER_TABLE_LAYER_WEATHER_A + 1,
		"weather layers are the A/B pair (even layer = cur, odd = prev by construction)")
	_expect(Baker.WEATHER_TABLE_LAYER_WIND_BASE + 1 == Baker.WEATHER_TABLE_LAYER_WIND_B
			and Baker.WEATHER_TABLE_LAYER_WIND_B == Baker.WEATHER_TABLE_LAYERS - 1,
		"wind pair 2+cur / 2+prev fits inside the 4-layer array")
	_expect(Codec.BYTES_PER_TEXEL == 4, "one weather_table texel is RGBA8 (4 bytes)")


## padding 行的 type 必须写 `WT_CLEAR` 的**真值**（不是别处另立一个字面量）。
func _check_padding_type() -> void:
	_expect(WeatherType.WT.CLEAR == 0,
		"WeatherType.WT.CLEAR is 0 (weather_type.gd:24), got %d" % int(WeatherType.WT.CLEAR))
	_expect(Baker.WEATHER_TABLE_PAD_TYPE == int(WeatherType.WT.CLEAR),
		"WEATHER_TABLE_PAD_TYPE follows WeatherType.WT.CLEAR (%d)" % Baker.WEATHER_TABLE_PAD_TYPE)


# ─────────────────────────────────────────────────────────────────────────
# 2. 风场编码契约：与 wind_lut 同编码（Color->RGBA8 是**截断**，不是 q01 的 round）
# ─────────────────────────────────────────────────────────────────────────

func _check_wind_encoding_contract() -> void:
	_expect(WindSource.encode_wind(Vector2(1, 0), 20.0) == Color(1.0, 0.5, 1.0, 1.0),
		"encode_wind maps unit +x / 20 speed to (r=1, g=0.5, b=1, a=1)")
	_expect(WindSource.encode_wind(Vector2(0, 0), 0.0) == Color(0.5, 0.5, 0.0, 1.0),
		"encode_wind maps zero wind to (0.5, 0.5, 0) so RG decode is neutral")

	# build_bytes() 必须是 build_image() 的逐字节镜像 —— 不允许第二份量化。
	# 注意 PackedFloat32Array 是值类型：必须先建局部数组再整体赋回成员（不靠属性链就地改）。
	var wx := PackedFloat32Array()
	var wy := PackedFloat32Array()
	var wspd := PackedFloat32Array()
	wx.resize(_n_cells)
	wy.resize(_n_cells)
	wspd.resize(_n_cells)
	for i in range(_n_cells):
		match i % 4:
			0:
				wx[i] = 1.0
				wy[i] = 0.0
				wspd[i] = 20.0
			1:
				wx[i] = 0.0
				wy[i] = -1.0
				wspd[i] = 0.0
			2:
				wx[i] = 0.0
				wy[i] = 0.0
				wspd[i] = 0.0
			_:
				wx[i] = 0.6
				wy[i] = 0.8
				wspd[i] = 7.5
	_map.wind_x_arr = wx
	_map.wind_y_arr = wy
	_map.wind_speed_arr = wspd
	var dims := Vector2i(_n_cells, 1)
	var bytes: PackedByteArray = WindSource.build_bytes(_map, dims)
	var image: Image = WindSource.build_image(_map, dims)
	_expect(image != null and bytes.size() == dims.x * dims.y * 4,
		"build_bytes emits dims.x*dims.y*4 bytes (%d)" % bytes.size())
	_expect(image != null and bytes == image.get_data(),
		"build_bytes is literally Image.get_data() of the wind_lut image (no second quantization)")

	# 截断口径的显式探针：unit +x / speed 20 ⇒ [255, 127, 255, 255]。
	# 0.5 * 255 = 127.5，Godot 的 Color->RGBA8 是 uint8 截断（127），
	# **不是** weather_lut 用的 q01_byte 的 round（128）。两者不同源，不能混用。
	var want_plus_x := PackedByteArray([255, 127, 255, 255])
	var got_plus_x := PackedByteArray()
	got_plus_x.append_array(bytes.slice(0, 4))
	_expect(got_plus_x == want_plus_x,
		"wind byte encoding truncates like Color->RGBA8 (0.5*255 = 127), got %s" % str(got_plus_x))
	var want_minus_y := PackedByteArray([127, 0, 0, 255])
	var got_minus_y := PackedByteArray()
	got_minus_y.append_array(bytes.slice(4, 8))
	_expect(got_minus_y == want_minus_y,
		"unit -y / zero speed encodes [127, 0, 0, 255], got %s" % str(got_minus_y))
	var want_zero := PackedByteArray([127, 127, 0, 255])
	var got_zero := PackedByteArray()
	got_zero.append_array(bytes.slice(8, 12))
	_expect(got_zero == want_zero,
		"zero wind encodes neutral (127, 127, 0, 255), got %s" % str(got_zero))


func _check_wind_publication_reuse() -> void:
	var baker := MapBaker.new()
	baker._last_bake_map = _map
	var world := WorldData.new()
	world.lut_dims = Vector2i(_n_cells + 1, 1)
	var source := WindSource.new()
	source.bind(world, _map)
	var expected := WindSource.build_bytes(_map, world.lut_dims)
	var published := Baker._publish_weather_table_from_luts(
		baker, world, _weather_src, world.lut_dims.x, world.lut_dims.y)
	_expect(published.get("weather_table_published", false), "weather table publishes real wind bytes")
	var first := _published_wind_image(world)
	_expect(first != null and first.get_data() == expected,
		"the weather table keeps its encoded image including padding")
	if first == null:
		return
	world.weather_lut_update_usec += 1
	_expect(source.update() and _published_wind_image(world) == first,
		"the wind textures share the table's image at the published update")
	_map.wind_x_arr = _map.wind_x_arr.duplicate()
	world.weather_lut_update_usec += 1
	_expect(source.update() and source.has_previous and _published_wind_image(world) == first,
		"a new weather update with identical wind keeps the encoding and advances texture history")
	for field in [&"wind_x_arr", &"wind_y_arr", &"wind_speed_arr"]:
		var before := _published_wind_image(world)
		var values: PackedFloat32Array = _map.get(field)
		var original := values[0]
		values[0] = -3.0 if field != &"wind_speed_arr" else 2.0
		_map.set(field, values)
		world.weather_lut_update_usec += 1
		var updated := source.update()
		var after := _published_wind_image(world)
		_expect(updated and after != null and after != before \
			and after.get_data() == WindSource.build_bytes(_map, world.lut_dims),
			"changing %s invalidates the image and retains exact encoding" % field)
		values[0] = original
		_map.set(field, values)
	world.lut_dims.x += 1
	var resized := source.update()
	var resized_image := _published_wind_image(world)
	_expect(resized and resized_image != null and resized_image.get_size() == world.lut_dims,
		"a new layout is encoded even with the same weather timestamp")
	var original_y := _map.wind_y_arr
	_map.wind_y_arr = PackedFloat32Array()
	world.weather_lut_update_usec += 1
	_expect(source.update() and source.current == null and _published_wind_image(world) == null,
		"an incomplete wind source cannot reuse the previous image")
	_map.wind_y_arr = original_y
	world.weather_lut_update_usec += 1
	_expect(source.update() and _published_wind_image(world) != null and first.get_data() == expected,
		"a recovered source publishes again without altering the old image")
	var replacement := WorldData.new()
	replacement.lut_dims = world.lut_dims
	source.bind(replacement, _map)
	_expect(source.update() and not source.has_previous and _published_wind_image(replacement) != null
		and _published_wind_image(replacement) != _published_wind_image(world),
		"a replacement world starts its own image and texture history")


func _published_wind_image(world: WorldData) -> Image:
	var cache = world.get("weather_wind_image_cache")
	return cache.get("image") as Image if cache is Dictionary else null


# ─────────────────────────────────────────────────────────────────────────
# 3. o2i 规则：发布器与测试用同一条 · 回绕列真的越界 · 空槽保持 -1
# ─────────────────────────────────────────────────────────────────────────

func _check_offset_to_index_rule() -> void:
	var built: PackedInt32Array = Baker._build_offset_to_index(_map, MAP_W, MAP_H)
	_expect(built == _o2i,
		"publisher's _build_offset_to_index matches the contract rule (off.y in range, col via posmod)")
	_expect(_n_cells == MAP_W * MAP_H - HOLES.size(),
		"mock map has %d cells over %dx%d offsets (%d holes)" % [
			_n_cells, MAP_W, MAP_H, HOLES.size()])
	var holes_ok := true
	for hole in HOLES:
		if _o2i[hole.y * MAP_W + hole.x] != -1:
			holes_ok = false
	_expect(holes_ok, "declared holes stay -1 in offset_to_index")
	var out_of_order := 0
	for idx in range(_o2i.size()):
		if _o2i[idx] >= 0 and _o2i[idx] != idx:
			out_of_order += 1
	_expect(out_of_order > 0,
		"mock deliberately reorders cell.index vs offset order (%d/%d texels differ)" % [
			out_of_order, _o2i.size()])
	_expect(_wrap_east_index >= 0 and _wrap_west_index >= 0,
		"mock contains both wrap-column probe cells")
	# 两个探针 cell 的未回绕列确实越界（col == MAP_W / col == -1），但折回后落在表内。
	var east_cell := _cell_by_index(_wrap_east_index)
	var west_cell := _cell_by_index(_wrap_west_index)
	var east_off: Vector2i = HexUtils.cube_to_offset(east_cell.q, east_cell.r)
	var west_off: Vector2i = HexUtils.cube_to_offset(west_cell.q, west_cell.r)
	_expect(east_off.x == MAP_W and west_off.x == -1,
		"wrap probes are built outside [0, map_w): east col %d, west col %d" % [
			east_off.x, west_off.x])


# ─────────────────────────────────────────────────────────────────────────
# 4. 逐字节：layer0（天气）/ layer2（风）== LUT 字节按 o2i 重排
# ─────────────────────────────────────────────────────────────────────────

func _check_commit_plan_bytes() -> void:
	var plan: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, _o2i, MAP_W, MAP_H, _n_cells, -1)
	_expect(bool(plan.get("ok", false)),
		"commit plan accepts a well-formed payload (reason=%s)" % String(plan.get("reason", "")))
	if not bool(plan.get("ok", false)):
		return
	_expect(bool(plan.get("rebuild", true)),
		"first commit (cur_before = -1) is a full rebuild")
	_expect(int(plan.get("next_cur", -1)) == Baker.WEATHER_TABLE_LAYER_WEATHER_A,
		"first commit leaves cur at layer %d" % Baker.WEATHER_TABLE_LAYER_WEATHER_A)
	var ids: PackedInt32Array = plan.get("layer_ids", PackedInt32Array())
	_expect(ids.size() == 4 and ids[0] == 0 and ids[1] == 1 and ids[2] == 2 and ids[3] == 3,
		"rebuild writes all 4 layers in order, got %s" % str(ids))
	var writes: Array = plan.get("layer_bytes", [])
	var layer0: PackedByteArray = writes[0]   # 天气 A
	var layer1: PackedByteArray = writes[1]   # 天气 B
	var layer2: PackedByteArray = writes[2]   # 风 A
	var layer3: PackedByteArray = writes[3]   # 风 B
	var want_size: int = MAP_W * MAP_H * 4
	_expect(layer0.size() == want_size and layer2.size() == want_size,
		"every layer is map_w*map_h*4 bytes (%d)" % want_size)
	_expect(layer0 == layer1 and layer2 == layer3,
		"a rebuild writes the same payload into both A and B (prev == cur, like today's first publish)")

	# 逐 offset 逐通道：layer[o] == src[o2i[o]*4 + c]
	var bad_weather := 0
	var bad_wind := 0
	var first_weather := ""
	var first_wind := ""
	for o in range(_o2i.size()):
		var ci: int = _o2i[o]
		if ci < 0:
			continue
		for c in range(4):
			if layer0[o * 4 + c] != _weather_src[ci * 4 + c]:
				bad_weather += 1
				if first_weather.is_empty():
					first_weather = " first: offset %d (cell %d) ch %d = %d want %d" % [
						o, ci, c, layer0[o * 4 + c], _weather_src[ci * 4 + c]]
			if layer2[o * 4 + c] != _wind_src[ci * 4 + c]:
				bad_wind += 1
				if first_wind.is_empty():
					first_wind = " first: offset %d (cell %d) ch %d = %d want %d" % [
						o, ci, c, layer2[o * 4 + c], _wind_src[ci * 4 + c]]
	_expect(bad_weather == 0,
		"layer0 weather: every texel == weather_lut[o2i[o]] byte-for-byte (%d bad)%s"
			% [bad_weather, first_weather])
	_expect(bad_wind == 0,
		"layer2 wind: every texel == wind_lut[o2i[o]] byte-for-byte (%d bad)%s"
			% [bad_wind, first_wind])
	# 通道语义：R 通道原样搬运（不重新量化 type）。
	var type_ok := true
	for o in range(_o2i.size()):
		var ci: int = _o2i[o]
		if ci < 0:
			continue
		if int(layer0[o * 4]) != int(_weather_src[ci * 4]):
			type_ok = false
	_expect(type_ok, "weather layer R channel keeps the raw weather_type byte (no re-quantization)")


# ─────────────────────────────────────────────────────────────────────────
# 5. padding 行：type 写 WT_CLEAR，其余通道 0
# ─────────────────────────────────────────────────────────────────────────

func _check_padding_rows() -> void:
	var plan: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, _o2i, MAP_W, MAP_H, _n_cells, -1)
	var writes: Array = plan.get("layer_bytes", [])
	if writes.size() < 4:
		_expect(false, "padding check needs a rebuild plan")
		return
	var layer0: PackedByteArray = writes[0]
	var layer2: PackedByteArray = writes[2]
	var pad_ok := true
	var first := ""
	for hole in HOLES:
		var base: int = (hole.y * MAP_W + hole.x) * 4
		if layer0[base] != Baker.WEATHER_TABLE_PAD_TYPE \
				or layer0[base + 1] != 0 or layer0[base + 2] != 0 or layer0[base + 3] != 0:
			pad_ok = false
			if first.is_empty():
				first = " first: hole %s -> %d/%d/%d/%d" % [str(hole), layer0[base],
					layer0[base + 1], layer0[base + 2], layer0[base + 3]]
		if layer2[base] != 0 or layer2[base + 1] != 0 \
				or layer2[base + 2] != 0 or layer2[base + 3] != 0:
			pad_ok = false
	_expect(pad_ok,
		"padding texels (o2i == -1) write WT_CLEAR for type and 0 elsewhere%s" % first)

	# 反证：padding 不是"所有 texel 都是 0"（否则上一条退化成恒真）。
	var nonzero := 0
	for b in layer0:
		if b != 0:
			nonzero += 1
	_expect(nonzero > 0, "the weather layer is genuinely non-zero (%d non-zero bytes)" % nonzero)


# ─────────────────────────────────────────────────────────────────────────
# 6. 回绕列：东侧越界落 col 0，西侧落 col map_w-1
# ─────────────────────────────────────────────────────────────────────────

func _check_wrap_columns() -> void:
	var plan: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, _o2i, MAP_W, MAP_H, _n_cells, -1)
	var writes: Array = plan.get("layer_bytes", [])
	if writes.size() < 4:
		_expect(false, "wrap check needs a rebuild plan")
		return
	var layer0: PackedByteArray = writes[0]
	var east_slot: int = 4 * MAP_W + 0
	var west_slot: int = 1 * MAP_W + (MAP_W - 1)
	_expect(_o2i[east_slot] == _wrap_east_index and _o2i[west_slot] == _wrap_west_index,
		"offset_to_index folds out-of-range columns with posmod(col, map_w)")
	var east_ok: bool = layer0[east_slot * 4] == _weather_src[_wrap_east_index * 4]
	var west_ok: bool = layer0[west_slot * 4] == _weather_src[_wrap_west_index * 4]
	_expect(east_ok and west_ok,
		"wrap-column texels carry the wrapped cell's bytes (east col %d -> 0, west col -1 -> %d)" % [
			MAP_W, MAP_W - 1])


# ─────────────────────────────────────────────────────────────────────────
# 7. 翻转语义（本文件的核心断言）
#    layer_store 模拟 GPU 的 4 层；两次不同数据的提交后：
#      prev 层（1 - cur）内容 == 上一次的 cur 层内容
#    并且本次只写了 back 层 + 风 back 层（没有整张重传）。
# ─────────────────────────────────────────────────────────────────────────

func _check_flip_semantics() -> void:
	var layer_store: Array[PackedByteArray] = []
	layer_store.resize(Baker.WEATHER_TABLE_LAYERS)
	var cur: int = -1
	var prev_cur_snapshot: PackedByteArray = PackedByteArray()

	# 三份完全不同的数据（第二次 / 第三次提交的天气与风都要变）。
	var weather_2: PackedByteArray = _shift_bytes(_weather_src, 17)
	var wind_2: PackedByteArray = _shift_bytes(_wind_src, 29)
	var weather_3: PackedByteArray = _shift_bytes(_weather_src, 91)
	var wind_3: PackedByteArray = _shift_bytes(_wind_src, 113)

	# ── 提交 1（首次 ⇒ 重建）──
	var plan1: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, _o2i, MAP_W, MAP_H, _n_cells, cur)
	var applied1: Dictionary = _apply_plan(layer_store, plan1)
	_expect(bool(applied1.get("ok", false)) and bool(plan1.get("rebuild", false)),
		"commit #1 rebuilds the whole 4-layer table")
	cur = int(plan1.get("next_cur", -1))
	_expect(cur == 0, "commit #1 sets cur = 0, got %d" % cur)
	_expect(layer_store[1 - cur] == layer_store[cur],
		"commit #1 leaves prev == cur (no interpolation across the very first frame)")
	prev_cur_snapshot = layer_store[cur].duplicate()
	var cur1_wind: PackedByteArray = layer_store[Baker.WEATHER_TABLE_LAYER_WIND_BASE + cur].duplicate()

	# ── 提交 2（数据不同 ⇒ 只写 back 层）──
	var plan2: Dictionary = Baker.weather_table_commit_plan(
		weather_2, wind_2, _o2i, MAP_W, MAP_H, _n_cells, cur)
	_expect(bool(plan2.get("ok", false)) and not bool(plan2.get("rebuild", true)),
		"commit #2 takes the incremental branch (update_layer, no rebuild)")
	var ids2: PackedInt32Array = plan2.get("layer_ids", PackedInt32Array())
	_expect(ids2.size() == 2,
		"commit #2 writes exactly 2 layers (weather back + wind back), got %d" % ids2.size())
	_expect(ids2.size() == 2 and ids2[0] == (1 - cur) and ids2[1] == (Baker.WEATHER_TABLE_LAYER_WIND_BASE + (1 - cur)),
		"commit #2 writes the *back* layers %d / %d (cur state is never touched)" % [
			1 - cur, Baker.WEATHER_TABLE_LAYER_WIND_BASE + (1 - cur)])
	var applied2: Dictionary = _apply_plan(layer_store, plan2)
	_expect(bool(applied2.get("ok", false)), "commit #2 applies cleanly")
	var old_cur: int = cur
	cur = int(plan2.get("next_cur", -1))
	_expect(cur == 1 - old_cur,
		"commit #2 flips cur %d -> %d" % [old_cur, cur])
	# ★ 核心：翻转后 prev 层 == 上一次（提交 1）的 cur 层内容。
	_expect(layer_store[1 - cur] == prev_cur_snapshot,
		"FLIP: after commit #2 the prev layer (%d) still holds commit #1's cur payload byte-for-byte"
			% (1 - cur))
	_expect(layer_store[cur] == _reorder_expected(weather_2, Baker.WEATHER_TABLE_PAD_TYPE),
		"after commit #2 the cur layer holds commit #2's reordered payload")
	_expect(layer_store[Baker.WEATHER_TABLE_LAYER_WIND_BASE + 1 - cur] == cur1_wind,
		"FLIP: the wind prev layer (%d) still holds commit #1's wind payload"
			% (Baker.WEATHER_TABLE_LAYER_WIND_BASE + 1 - cur))
	_expect(layer_store[Baker.WEATHER_TABLE_LAYER_WIND_BASE + cur] == _reorder_expected(wind_2),
		"after commit #2 the wind cur layer holds commit #2's reordered payload")
	prev_cur_snapshot = layer_store[cur].duplicate()

	# ── 提交 3（再翻一次，回到 layer 0）──
	var plan3: Dictionary = Baker.weather_table_commit_plan(
		weather_3, wind_3, _o2i, MAP_W, MAP_H, _n_cells, cur)
	var prev_before_3: int = cur
	_apply_plan(layer_store, plan3)
	cur = int(plan3.get("next_cur", -1))
	_expect(cur == 1 - prev_before_3 and cur == 0,
		"commit #3 flips back to layer 0, got %d" % cur)
	_expect(layer_store[1 - cur] == prev_cur_snapshot,
		"FLIP: after commit #3 the prev layer (%d) still holds commit #2's cur payload" % (1 - cur))
	_expect(layer_store[cur] == _reorder_expected(weather_3, Baker.WEATHER_TABLE_PAD_TYPE),
		"after commit #3 the cur layer holds commit #3's reordered payload")

	# 反证：三份数据两两不同（否则上面的 FLIP 断言会退化成"永远是同一份字节"）。
	_expect(_reorder_expected(weather_2, Baker.WEATHER_TABLE_PAD_TYPE) != _reorder_expected(weather_3, Baker.WEATHER_TABLE_PAD_TYPE)
			and _reorder_expected(_weather_src, Baker.WEATHER_TABLE_PAD_TYPE) != _reorder_expected(weather_2, Baker.WEATHER_TABLE_PAD_TYPE),
		"the three commits really carry different payloads (flip assertions are not vacuous)")


# ─────────────────────────────────────────────────────────────────────────
# 8. 失败路径（纯函数层）：尺寸/形状不对一律 ok = false，且不产一个字节
# ─────────────────────────────────────────────────────────────────────────

func _check_plan_failure_paths() -> void:
	var bad_dims: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, _o2i, 0, MAP_H, _n_cells, -1)
	_expect(not bool(bad_dims.get("ok", true)) and String(bad_dims.get("reason", "")) == "invalid_map_dims",
		"zero map width is rejected (reason=%s)" % String(bad_dims.get("reason", "")))
	_expect((bad_dims.get("layer_bytes", []) as Array).is_empty(),
		"a rejected plan produces no layer payload at all")

	var bad_o2i: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, PackedInt32Array([0, 1]), MAP_W, MAP_H, _n_cells, -1)
	_expect(not bool(bad_o2i.get("ok", true))
			and String(bad_o2i.get("reason", "")) == "offset_to_index_size_mismatch",
		"an offset_to_index of the wrong length is rejected (reason=%s)"
			% String(bad_o2i.get("reason", "")))

	var short_weather: PackedByteArray = _weather_src.slice(0, _weather_src.size() - 4)
	var bad_payload: Dictionary = Baker.weather_table_commit_plan(
		short_weather, _wind_src, _o2i, MAP_W, MAP_H, _n_cells, -1)
	_expect(not bool(bad_payload.get("ok", true))
			and String(bad_payload.get("reason", "")) == "lut_payload_too_small",
		"a weather LUT shorter than n_cells*4 is rejected (reason=%s)"
			% String(bad_payload.get("reason", "")))
	_expect((bad_payload.get("layer_bytes", []) as Array).is_empty(),
		"a short weather LUT never reaches the texture (no out-of-bounds write)")

	var short_wind: PackedByteArray = _wind_src.slice(0, _wind_src.size() - 4)
	var bad_wind: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, short_wind, _o2i, MAP_W, MAP_H, _n_cells, -1)
	_expect(not bool(bad_wind.get("ok", true))
			and String(bad_wind.get("reason", "")) == "lut_payload_too_small",
		"a wind LUT shorter than n_cells*4 is rejected (reason=%s)"
			% String(bad_wind.get("reason", "")))

	# offset 空间装不下全部 cell（例如回绕把两个 cell 折到同一列且 map_w 更小）。
	var tight_o2i := PackedInt32Array()
	tight_o2i.resize(4 * 2)
	tight_o2i.fill(0)
	var too_small: Dictionary = Baker.weather_table_commit_plan(
		_weather_src, _wind_src, tight_o2i, 4, 2, _n_cells, -1)
	_expect(not bool(too_small.get("ok", true))
			and String(too_small.get("reason", "")) == "offset_space_too_small",
		"an offset grid smaller than n_cells is rejected (reason=%s)"
			% String(too_small.get("reason", "")))


# ─────────────────────────────────────────────────────────────────────────
# 9. 发布器（headless）：真建 Texture2DArray，断言尺寸/层数/格式/valid/层号翻转
# ─────────────────────────────────────────────────────────────────────────

func _check_publisher_headless() -> void:
	var baker := MapBaker.new()
	var world := WorldData.new()
	var wind_bytes: PackedByteArray = WindSource.build_bytes(_map, Vector2i(_n_cells, 1))
	_expect(wind_bytes.size() == _n_cells * 4,
		"wind payload from weather_wind_source is n_cells*4 bytes (%d)" % wind_bytes.size())

	var rep1: Dictionary = Baker._publish_weather_table(
		baker, _map, world, _weather_src, wind_bytes)
	_expect(bool(rep1.get("weather_table_published", false)),
		"publisher reports published=true on the first commit (reason=%s)"
			% String(rep1.get("weather_table_reason", "")))
	var tex: Texture2DArray = world.weather_table_tex
	_expect(tex != null, "publisher created a Texture2DArray")
	if tex == null:
		return
	_expect(tex.get_layers() == Baker.WEATHER_TABLE_LAYERS,
		"weather_table has %d layers, got %d" % [Baker.WEATHER_TABLE_LAYERS, tex.get_layers()])
	_expect(tex.get_width() == MAP_W and tex.get_height() == MAP_H,
		"weather_table is %dx%d (map_w x map_h), got %dx%d" % [
			MAP_W, MAP_H, tex.get_width(), tex.get_height()])
	_expect(tex.get_format() == Image.FORMAT_RGBA8,
		"weather_table format is FORMAT_RGBA8, got %d" % tex.get_format())
	_expect(world.weather_table_valid and world.weather_table_cur == 0,
		"WorldData.weather_table_valid = true, cur = 0 (got valid=%s cur=%d)" % [
			str(world.weather_table_valid), world.weather_table_cur])
	_expect(world.weather_table_dims == Vector2i(MAP_W, MAP_H),
		"WorldData.weather_table_dims = (map_w, map_h), got %s" % str(world.weather_table_dims))
	_expect(bool(rep1.get("weather_table_rebuilt", false)),
		"first commit reports rebuilt=true (no update_layer possible without a table)")

	# 第二次提交：形状一致 ⇒ 走 update_layer 增量，层号翻转。
	var weather_2: PackedByteArray = _shift_bytes(_weather_src, 17)
	var wind_2: PackedByteArray = _shift_bytes(wind_bytes, 29)
	var rep2: Dictionary = Baker._publish_weather_table(baker, _map, world, weather_2, wind_2)
	_expect(bool(rep2.get("weather_table_published", false)),
		"second commit publishes (reason=%s)" % String(rep2.get("weather_table_reason", "")))
	_expect(not bool(rep2.get("weather_table_rebuilt", true)),
		"second commit reuses the same Texture2DArray (update_layer path, no rebuild)")
	_expect(String(rep2.get("weather_table_reason", "")) == "flipped",
		"second commit reports reason=flipped (got %s)" % String(rep2.get("weather_table_reason", "")))
	_expect(world.weather_table_cur == 1,
		"second commit flips weather_table_cur 0 -> 1, got %d" % world.weather_table_cur)
	_expect(world.weather_table_tex == tex,
		"the Texture2DArray object is reused across commits (no per-day texture churn)")

	# 第三次：翻回 0。
	var rep3: Dictionary = Baker._publish_weather_table(
		baker, _map, world, _shift_bytes(_weather_src, 91), _shift_bytes(wind_bytes, 113))
	_expect(bool(rep3.get("weather_table_published", false)) and world.weather_table_cur == 0,
		"third commit flips back to cur = 0 (got cur=%d)" % world.weather_table_cur)
	print("    [INFO] publisher path on this backend: reason=%s rebuilt=%s update_layer=%s" % [
		String(rep2.get("weather_table_reason", "")),
		str(rep2.get("weather_table_rebuilt", false)),
		str(world.weather_table_tex.has_method("update_layer"))])


# ─────────────────────────────────────────────────────────────────────────
# 10. 发布器失败路径：valid = false、cur = -1、纹理对象不被顶替（不越界写）
# ─────────────────────────────────────────────────────────────────────────

func _check_publisher_failure_keeps_table_untouched() -> void:
	var baker := MapBaker.new()
	var world := WorldData.new()
	var wind_bytes: PackedByteArray = WindSource.build_bytes(_map, Vector2i(_n_cells, 1))
	Baker._publish_weather_table(baker, _map, world, _weather_src, wind_bytes)
	var tex_before: Texture2DArray = world.weather_table_tex
	_expect(tex_before != null and world.weather_table_valid,
		"baseline: a healthy table exists before the failure case")

	# 尺寸不匹配：weather 字节比 n_cells*4 短 4 字节。
	var short_weather: PackedByteArray = _weather_src.slice(0, _weather_src.size() - 4)
	var rep: Dictionary = Baker._publish_weather_table(
		baker, _map, world, short_weather, wind_bytes)
	_expect(not bool(rep.get("weather_table_published", true)),
		"a short weather payload is not published (reason=%s)"
			% String(rep.get("weather_table_reason", "")))
	_expect(not world.weather_table_valid,
		"WorldData.weather_table_valid turns false on a failed publish")
	_expect(world.weather_table_cur == -1,
		"WorldData.weather_table_cur resets to -1 (no stale layer number survives), got %d"
			% world.weather_table_cur)
	_expect(world.weather_table_tex == tex_before,
		"the failed publish does not replace the existing texture (nothing was written)")

	# 恢复：下一次健康提交必须**重建**（cur 已被清成 -1），并重新置 valid。
	var rep_ok: Dictionary = Baker._publish_weather_table(
		baker, _map, world, _weather_src, wind_bytes)
	_expect(bool(rep_ok.get("weather_table_published", false))
			and bool(rep_ok.get("weather_table_rebuilt", false)),
		"the next healthy commit rebuilds and republishes")
	_expect(world.weather_table_valid and world.weather_table_cur == 0,
		"valid is restored and cur is back to 0 (got valid=%s cur=%d)" % [
			str(world.weather_table_valid), world.weather_table_cur])

	# 没有 map：明确标不可用（shader 退回旧 LUT 路径），不抛错也不留旧层号。
	var world2 := WorldData.new()
	var rep_no_map: Dictionary = Baker._publish_weather_table(
		baker, null, world2, _weather_src, wind_bytes)
	_expect(not bool(rep_no_map.get("weather_table_published", true))
			and String(rep_no_map.get("weather_table_reason", "")) == "missing_map",
		"missing map is reported as missing_map, not silently skipped (reason=%s)"
			% String(rep_no_map.get("weather_table_reason", "")))
	_expect(not world2.weather_table_valid and world2.weather_table_cur == -1,
		"missing map leaves weather_table_valid = false / cur = -1")


# ─────────────────────────────────────────────────────────────────────────
# 11. GPU 回读（真后端才可能）：headless 下 get_layer_data 恒 null ⇒ 显式 SKIPPED
# ─────────────────────────────────────────────────────────────────────────

func _check_backend_readback() -> void:
	var baker := MapBaker.new()
	var world := WorldData.new()
	var wind_bytes: PackedByteArray = WindSource.build_bytes(_map, Vector2i(_n_cells, 1))
	Baker._publish_weather_table(baker, _map, world, _weather_src, wind_bytes)
	var tex: Texture2DArray = world.weather_table_tex
	if tex == null:
		_skip("GPU readback: no texture was created on this backend")
		return
	var readback_ok := true
	var probe: Array[int] = [Baker.WEATHER_TABLE_LAYER_WEATHER_A, Baker.WEATHER_TABLE_LAYER_WIND_A]
	var want: Array[PackedByteArray] = [_reorder_expected(_weather_src, Baker.WEATHER_TABLE_PAD_TYPE), _reorder_expected(wind_bytes)]
	for i in range(probe.size()):
		var layer: Image = tex.get_layer_data(probe[i])
		if layer == null:
			_skip("GPU readback of layer %d returned null (dummy renderer: --headless cannot read back)"
				% probe[i])
			return
		readback_ok = readback_ok and layer.get_data() == want[i]
	_expect(readback_ok,
		"GPU readback: layer0 / layer2 match the reordered weather_lut / wind_lut byte-for-byte")
	# 翻转一次后读回：cur 层是新数据，prev 层仍是旧数据（真后端才有的端到端证据）。
	var weather_2: PackedByteArray = _shift_bytes(_weather_src, 17)
	Baker._publish_weather_table(baker, _map, world, weather_2, _shift_bytes(wind_bytes, 29))
	var prev_layer: int = 1 - world.weather_table_cur
	var img_prev: Image = world.weather_table_tex.get_layer_data(prev_layer)
	var img_cur: Image = world.weather_table_tex.get_layer_data(world.weather_table_cur)
	if img_prev == null or img_cur == null:
		_skip("GPU readback after the flip returned null on this backend")
		return
	_expect(img_prev.get_data() == _reorder_expected(_weather_src, Baker.WEATHER_TABLE_PAD_TYPE),
		"GPU readback: after the flip the prev layer still holds the first payload")
	_expect(img_cur.get_data() == _reorder_expected(weather_2, Baker.WEATHER_TABLE_PAD_TYPE),
		"GPU readback: after the flip the cur layer holds the second payload")


# ─────────────────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────────────────

## 按 cell.index 找 mock cell（_cells 字典是 cube 键，不能直接下标）。
func _cell_by_index(idx: int) -> HexCell:
	for cell in _map.all_cells():
		if int(cell.index) == idx:
			return cell
	return null


## 把 plan 写进模拟的 4 层存储。返回 {"ok": bool, "written": int}。
func _apply_plan(store: Array[PackedByteArray], plan: Dictionary) -> Dictionary:
	if not bool(plan.get("ok", false)):
		return {"ok": false, "written": 0}
	var ids: PackedInt32Array = plan.get("layer_ids", PackedInt32Array())
	var writes: Array = plan.get("layer_bytes", [])
	if ids.size() != writes.size():
		return {"ok": false, "written": 0}
	for i in range(ids.size()):
		store[ids[i]] = (writes[i] as PackedByteArray).duplicate()
	return {"ok": true, "written": ids.size()}


## 独立实现的"index 空间 → offset 空间"期望值（不复用 codec 的搬运逻辑）。
## fill = padding 行的 type 通道值；其余通道恒 0（方案 §3.3）。
func _reorder_expected(src: PackedByteArray, fill: int = 0) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(MAP_W * MAP_H * 4)
	out.fill(fill)
	for o in range(_o2i.size()):
		var ci: int = _o2i[o]
		if ci < 0:
			continue
		for c in range(4):
			out[o * 4 + c] = src[ci * 4 + c]
	return out


## 每个字节 +shift（256 取模），保证两份数据处处不同（含 type 通道）。
func _shift_bytes(src: PackedByteArray, shift: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(src.size())
	for i in range(src.size()):
		out[i] = (int(src[i]) + shift) & 0xFF
	return out


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1


## 需要真后端才能验的断言：显式 SKIPPED（**不计入通过**，也不假绿）。
func _skip(label: String) -> void:
	_skipped += 1
	print("  [SKIPPED] %s" % label)
