extends SceneTree

const PttGiBakerScript = preload("res://scripts/rendering/bakers/ptt_gi_baker.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_resolve_gi_size()
	_test_flat_heightfield()
	_test_two_slope_valley()
	_test_wrap_x_east_west_mountain()
	_test_bake_world_and_refresh_albedo()
	_test_published_surface_color_refresh()
	_test_invalid_inputs_rejected()
	print("=== ptt_gi_baker_test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("  [FAIL] %s" % msg)


func _test_resolve_gi_size() -> void:
	var s21: Vector2i = PttGiBakerScript.resolve_gi_size(Vector2i(1024, 512))
	_expect(s21 == Vector2i(128, 64), "2:1 heightmap resolves to 128x64 (got %s)" % str(s21))
	var s11: Vector2i = PttGiBakerScript.resolve_gi_size(Vector2i(512, 512))
	_expect(s11 == Vector2i(96, 96), "1:1 heightmap resolves to 96x96 (got %s)" % str(s11))
	var s_wide: Vector2i = PttGiBakerScript.resolve_gi_size(Vector2i(4096, 256))
	_expect(s_wide.x <= 128 and s_wide.x >= 16 and s_wide.y <= 96 and s_wide.y >= 16,
		"extreme aspect stays within [16..128] x [16..96] (got %s)" % str(s_wide))
	_expect(s_wide.x <= 255 and s_wide.y <= 255, "resolved dims fit in single RGBA8 byte")


func _test_flat_heightfield() -> void:
	var hm_size := Vector2i(64, 32)
	var gi_size := Vector2i(32, 16)
	var buf := PackedFloat32Array()
	buf.resize(hm_size.x * hm_size.y)
	buf.fill(0.55)

	var res: Dictionary = PttGiBakerScript.bake_from_height_buffer(
		buf, hm_size, Vector2(640.0, 320.0), 120.0, 0.42, true, gi_size, 32)
	_expect(bool(res.get("ok", false)), "flat heightfield bake succeeds")
	var coupling_bytes: PackedByteArray = res["coupling_bytes"]
	var transfer_tex: Texture2DArray = res["transfer_idx_tex"]
	var coupling_tex: ImageTexture = res["coupling_tex"]
	_expect(transfer_tex != null and transfer_tex.get_layers() == 4,
		"flat transfer_idx_tex has 4 layers")
	_expect(coupling_tex != null and coupling_tex.get_width() == gi_size.x
		and coupling_tex.get_height() == gi_size.y, "flat coupling_tex matches gi_size")

	var max_c := 0
	var normal_ok := true
	for i in range(gi_size.x * gi_size.y):
		var c_byte := int(coupling_bytes[i * 4])
		if c_byte > max_c:
			max_c = c_byte
		var gx_byte := int(coupling_bytes[i * 4 + 1])
		var gy_byte := int(coupling_bytes[i * 4 + 2])
		var gz_byte := int(coupling_bytes[i * 4 + 3])
		if abs(gx_byte - 128) > 1 or abs(gy_byte - 128) > 1 or gz_byte < 254:
			normal_ok = false
	_expect(max_c == 0, "flat heightfield has C_i == 0 everywhere (max=%d)" % max_c)
	_expect(normal_ok, "flat heightfield coarse normal encodes (0, 0, 1)")


func _test_two_slope_valley() -> void:
	# 构造沿 X 轴对称的双坡 V 形山谷：中心 x = hm_w/2 为谷底 (0.45)，两侧升高到 1.0
	var hm_size := Vector2i(64, 32)
	var gi_size := Vector2i(32, 16)
	var buf := PackedFloat32Array()
	buf.resize(hm_size.x * hm_size.y)
	var half_w := float(hm_size.x - 1) * 0.5
	for y in range(hm_size.y):
		for x in range(hm_size.x):
			var dist := absf(float(x) - half_w) / half_w  # 0 at center, 1 at edges
			buf[y * hm_size.x + x] = 0.45 + 0.55 * dist

	var res: Dictionary = PttGiBakerScript.bake_from_height_buffer(
		buf, hm_size, Vector2(320.0, 160.0), 160.0, 0.40, false, gi_size, 32)
	_expect(bool(res.get("ok", false)), "valley heightfield bake succeeds")

	var transfer_tex: Texture2DArray = res["transfer_idx_tex"]
	_expect(transfer_tex != null and transfer_tex.get_layers() == 4,
		"valley transfer_idx_tex has 4 layers")
	_expect(transfer_tex.get_width() == gi_size.x and transfer_tex.get_height() == gi_size.y,
		"valley transfer_idx_tex dimensions match gi_size")

	# 校验所有 4 层 RGBA8 格式以及全部索引严格落在 [0, R_w-1] x [0, R_h-1]
	# （注意：headless Dummy 渲染器下 Texture2DArray.get_layer_data() 会返回 null，
	# 因此同时检查 transfer_tex.get_format() 并回退到返回的 transfer_layers_bytes 进行逐像素核验）
	var tex_fmt: Image.Format = transfer_tex.get_format()
	_expect(tex_fmt == Image.FORMAT_RGBA8,
		"transfer_idx_tex format is Image.FORMAT_RGBA8 (got %d)" % int(tex_fmt))

	var all_layers_rgba8 := true
	var all_indices_in_bounds := true
	var layer_bytes: Array = res["transfer_layers_bytes"]
	_expect(layer_bytes.size() == 4, "transfer_layers_bytes has 4 layers")
	for l in range(4):
		var layer_img: Image = transfer_tex.get_layer_data(l)
		var data: PackedByteArray = layer_bytes[l]
		if layer_img != null:
			if layer_img.get_format() != Image.FORMAT_RGBA8:
				all_layers_rgba8 = false
			data = layer_img.get_data()
		elif data.size() != gi_size.x * gi_size.y * 4:
			all_layers_rgba8 = false
			continue
		for i in range(gi_size.x * gi_size.y):
			var p4 := i * 4
			var x0 := int(data[p4])
			var y0 := int(data[p4 + 1])
			var x1 := int(data[p4 + 2])
			var y1 := int(data[p4 + 3])
			if x0 < 0 or x0 >= gi_size.x or x1 < 0 or x1 >= gi_size.x \
					or y0 < 0 or y0 >= gi_size.y or y1 < 0 or y1 >= gi_size.y:
				all_indices_in_bounds = false
	_expect(all_layers_rgba8, "all 4 transfer_idx_tex layers are Image.FORMAT_RGBA8")
	_expect(all_indices_in_bounds, "all K=8 transfer indices are within [0, R_w-1] x [0, R_h-1]")

	# 检查谷底和左右两侧山坡的耦合与命中方向
	var coupling_bytes: PackedByteArray = res["coupling_bytes"]
	var mid_y := gi_size.y / 2
	var center_x := gi_size.x / 2
	var left_slope_x := gi_size.x / 4
	var right_slope_x := (gi_size.x * 3) / 4

	var c_center := int(coupling_bytes[(mid_y * gi_size.x + center_x) * 4])
	var c_left := int(coupling_bytes[(mid_y * gi_size.x + left_slope_x) * 4])
	var c_right := int(coupling_bytes[(mid_y * gi_size.x + right_slope_x) * 4])
	_expect(c_center > 0, "valley floor has C_i > 0 (got %d)" % c_center)
	_expect(c_left > 0 and c_right > 0,
		"both valley slopes have C_i > 0 (left=%d right=%d)" % [c_left, c_right])

	# 左坡面向右侧，其传输样本平均 X 应大于自身 x（指向对侧山坡）
	var left_sum_x := 0.0
	var right_sum_x := 0.0
	var left_idx := (mid_y * gi_size.x + left_slope_x) * 4
	var right_idx := (mid_y * gi_size.x + right_slope_x) * 4
	for l in range(4):
		var d: PackedByteArray = layer_bytes[l]
		left_sum_x += float(d[left_idx]) + float(d[left_idx + 2])
		right_sum_x += float(d[right_idx]) + float(d[right_idx + 2])
	var left_avg_x := left_sum_x / 8.0
	var right_avg_x := right_sum_x / 8.0
	_expect(left_avg_x > float(left_slope_x),
		"left slope hits point toward right opposite slope (avg_x=%.2f > x=%d)" % [left_avg_x, left_slope_x])
	_expect(right_avg_x < float(right_slope_x),
		"right slope hits point toward left opposite slope (avg_x=%.2f < x=%d)" % [right_avg_x, right_slope_x])


func _test_wrap_x_east_west_mountain() -> void:
	# 东边界 (x >= gw - 3) 放置高耸山墙 (1.0)，其余为平坦地面 (0.45)
	var gi_size := Vector2i(32, 16)
	var hm_size := gi_size
	var buf := PackedFloat32Array()
	buf.resize(hm_size.x * hm_size.y)
	for y in range(hm_size.y):
		for x in range(hm_size.x):
			buf[y * hm_size.x + x] = 1.0 if x >= hm_size.x - 3 else 0.45

	var res_wrap: Dictionary = PttGiBakerScript.bake_from_height_buffer(
		buf, hm_size, Vector2(320.0, 160.0), 200.0, 0.40, true, gi_size, 32)
	var res_nowrap: Dictionary = PttGiBakerScript.bake_from_height_buffer(
		buf, hm_size, Vector2(320.0, 160.0), 200.0, 0.40, false, gi_size, 32)
	_expect(bool(res_wrap.get("ok", false)) and bool(res_nowrap.get("ok", false)),
		"wrap_x and non-wrap_x bakes succeed")

	var mid_y := gi_size.y / 2
	var west_idx := (mid_y * gi_size.x + 0) * 4
	var c_wrap := int(res_wrap["coupling_bytes"][west_idx])
	var c_nowrap := int(res_nowrap["coupling_bytes"][west_idx])
	_expect(c_wrap > 0, "wrap_x=true: west edge x=0 receives occlusion from east mountain (C=%d)" % c_wrap)
	_expect(c_wrap > c_nowrap,
		"wrap_x=true produces strictly stronger occlusion at x=0 than wrap_x=false (%d > %d)" % [c_wrap, c_nowrap])

	# 检查西边界 x=0 的传输索引中确实有指向东边界高山 (x >= gi_size.x - 4) 的坐标
	var east_hits := 0
	var layers_wrap: Array = res_wrap["transfer_layers_bytes"]
	for l in range(4):
		var d: PackedByteArray = layers_wrap[l]
		if int(d[west_idx]) >= gi_size.x - 4:
			east_hits += 1
		if int(d[west_idx + 2]) >= gi_size.x - 4:
			east_hits += 1
	_expect(east_hits > 0,
		"wrap_x=true: west edge x=0 transfer indices include east boundary mountain (hits=%d/8)" % east_hits)


func _test_bake_world_and_refresh_albedo() -> void:
	# 构造一个轻量 WorldData（128x64，模拟真实 2:1 世界）验证 bake_world 端到端耗时与字段填充
	var world := WorldData.new()
	world.hm_size = Vector2i(256, 128)
	world.derived_size = world.hm_size
	world.world_bounds = Rect2(0.0, 0.0, 2560.0, 1280.0)
	world.wrap_period_x = 2560.0
	world.sea_level = 0.42

	var n := world.hm_size.x * world.hm_size.y
	world.height_buffer.resize(n)
	world.biome_buffer.resize(n)
	for y in range(world.hm_size.y):
		for x in range(world.hm_size.x):
			var idx := y * world.hm_size.x + x
			if x < 64:
				# 左侧海洋
				world.height_buffer[idx] = 0.25
				world.biome_buffer[idx] = 0  # OCEAN
			else:
				# 右侧起伏山地/沙漠
				var ridge := 0.45 + 0.45 * absf(sin(float(x) * 0.08)) * cos(float(y) * 0.05)
				world.height_buffer[idx] = clampf(ridge, 0.43, 0.98)
				world.biome_buffer[idx] = 7  # DESERT

	var res: Dictionary = PttGiBakerScript.bake_world(null, world, 16.0)
	_expect(bool(res.get("ok", false)), "bake_world returns ok=true")
	_expect(world.ptt_gi_ready, "world.ptt_gi_ready is true after bake_world")
	_expect(world.ptt_gi_size == Vector2i(128, 64),
		"world.ptt_gi_size is 128x64 for 2:1 world (got %s)" % str(world.ptt_gi_size))
	_expect(world.ptt_transfer_idx_tex != null and world.ptt_transfer_idx_tex.get_layers() == 4,
		"world.ptt_transfer_idx_tex is 4-layer Texture2DArray")
	_expect(world.ptt_coupling_tex != null, "world.ptt_coupling_tex is populated")
	_expect(world.ptt_albedo_tex != null, "world.ptt_albedo_tex is populated")

	# 校验 ptt_albedo_tex：左侧水体 A=0，右侧沙漠 A=255 且偏暖沙色 (R > B)
	var alb_img := world.ptt_albedo_tex.get_image()
	var alb_data := alb_img.get_data()
	var water_px := (32 * 128 + 8) * 4
	var land_px := (32 * 128 + 96) * 4
	_expect(int(alb_data[water_px + 3]) == 0,
		"ptt_albedo_tex marks ocean texel with A=0 (got %d)" % int(alb_data[water_px + 3]))
	_expect(int(alb_data[land_px + 3]) == 255 and int(alb_data[land_px]) > int(alb_data[land_px + 2]),
		"ptt_albedo_tex marks desert land texel with A=255 and warm RGB")

	# 验证 refresh_albedo 在 biome 更新为雪地 (9) 后刷新纹理并反映雪地高反照率
	for i in range(n):
		if world.biome_buffer[i] == 7:
			world.biome_buffer[i] = 9  # SNOW
	var refreshed: bool = PttGiBakerScript.refresh_albedo(world)
	_expect(refreshed, "refresh_albedo returns true")
	_expect(world.ptt_albedo_tex != null and world.ptt_albedo_tex.get_width() == 128
		and world.ptt_albedo_tex.get_height() == 64,
		"refresh_albedo keeps valid 128x64 ImageTexture")
	var alb_data2 := world.ptt_albedo_tex.get_image().get_data()
	_expect(int(alb_data2[land_px + 2]) > 200,
		"refresh_albedo reflects snow albedo change (B=%d)" % int(alb_data2[land_px + 2]))
	print("  [perf] bake_world 128x64 elapsed: %dms" % int(res.get("elapsed_ms", -1)))


func _test_published_surface_color_refresh() -> void:
	var world := WorldData.new()
	world.derived_size = Vector2i(2, 1)
	world.lut_dims = world.derived_size
	world.ptt_gi_size = world.derived_size
	world.ptt_gi_ready = true
	world.publish_pixel_lookup([], PackedInt64Array([0, 1]), PackedByteArray([1, 1]))
	var baker := MapBaker.new()
	var enum_bytes := PackedByteArray([7, 0, 0, 255, 0, 0, 0, 255])
	var dyn_bytes := PackedByteArray([0, 0, 0, 255, 0, 0, 0, 0])
	var changes := [0]
	world.ptt_albedo_changed.connect(func() -> void: changes[0] += 1)
	_expect(baker._publish_bounce_lut(enum_bytes, dyn_bytes, world, 2, 1),
		"initial bounce LUT publication promotes coarse albedo")
	var first := world.ptt_albedo_bytes
	dyn_bytes[2] = 255
	dyn_bytes[3] = 0
	var dirty := PackedInt32Array([0])
	_expect(baker._publish_bounce_lut(enum_bytes, dyn_bytes, world, 2, 1, dirty, false),
		"daily bounce LUT publication promotes changed land color")
	var snow := world.ptt_albedo_bytes
	_expect(snow.size() == 8 and snow[2] > first[2] and snow[3] == 255 and snow[7] == 0
		and world.ptt_albedo_tex.get_image().get_data() == snow and changes[0] == 2,
		"daily snow publishes to the PTT texture, keeps the land mask, and signals once")
	_expect(not baker._publish_bounce_lut(enum_bytes, dyn_bytes, world, 2, 1, dirty, false)
		and changes[0] == 2, "identical daily surface color does not invalidate PTT")


func _test_invalid_inputs_rejected() -> void:
	var r_null: Dictionary = PttGiBakerScript.bake_world(null, null, 16.0)
	_expect(not bool(r_null.get("ok", true)), "bake_world refuses null world")
	var empty_w := WorldData.new()
	var r_empty: Dictionary = PttGiBakerScript.bake_world(null, empty_w, 16.0)
	_expect(not bool(r_empty.get("ok", true)) and not empty_w.ptt_gi_ready,
		"bake_world refuses empty height_buffer and keeps ptt_gi_ready=false")
	var r_bad_buf: Dictionary = PttGiBakerScript.bake_from_height_buffer(
		PackedFloat32Array(), Vector2i(16, 16), Vector2(100.0, 100.0), 10.0, 0.4, true)
	_expect(not bool(r_bad_buf.get("ok", true)), "bake_from_height_buffer refuses short buffer")
	_expect(not PttGiBakerScript.refresh_albedo(null), "refresh_albedo refuses null world")
