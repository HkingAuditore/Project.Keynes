extends SceneTree

# [terrain-gi 2026-07-31] 天空可见度 / bent normal / 遮挡源打包的契约测试。
#
# shader 侧的 GI 数学全部依赖 HexRenderer.build_gi_horizon_lut 预计算的 16 项查表，
# 表算错了不会报错、只会让全图 AO 悄悄偏亮或偏暗，因此这里在 GDScript 里按 shader
# 的同一公式重算一遍，锁住表的形状与端点值。

const HexRendererScript = preload("res://scripts/rendering/hex_renderer.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const ShrubLayerScript = preload("res://scripts/rendering/shrub_layer.gd")

const WORLD_SHADER_PATH := "res://shaders/world_map.gdshader"
const QUALITY_VARIANTS := {
	"desktop": "",
	"mobile_low": "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
	"mobile_mid": "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n",
	"mobile_high": "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n",
}

const INV_SQRT2 := 0.70710678118654752
const DIRECTIONS: Array[Vector2] = [
	Vector2(1.0, 0.0), Vector2(INV_SQRT2, INV_SQRT2),
	Vector2(0.0, 1.0), Vector2(-INV_SQRT2, INV_SQRT2),
	Vector2(-1.0, 0.0), Vector2(-INV_SQRT2, -INV_SQRT2),
	Vector2(0.0, -1.0), Vector2(INV_SQRT2, -INV_SQRT2),
]
const OCCLUDER_SENTINEL := 65535


func _init() -> void:
	var failures: Array[String] = []
	_test_lut_shape(failures)
	_test_sky_visibility(failures)
	_test_ao_remap(failures)
	_test_tap_weights(failures)
	_test_bent_normal(failures)
	_test_occluder_packing(failures)
	_test_bounce_albedo_table(failures)
	_test_shader_variants(failures)
	_test_shrub_shader_variants(failures)
	if failures.is_empty():
		print("terrain_gi_test: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("terrain_gi_test: FAIL")
	quit(1)


# ── shader 侧公式的 GDScript 镜像 ───────────────────────────────────────────
# 与 terrain_horizon.gdshaderinc 的 horizon_gi_from_packed 的两个累加器一一对应。

func _sky_visibility(lut: PackedVector3Array, nibbles: Array) -> float:
	var sum := 0.0
	for d in range(8):
		sum += lut[int(nibbles[d])].x
	return clampf(sum * 0.125, 0.0, 1.0)


func _bent_normal(lut: PackedVector3Array, nibbles: Array) -> Vector3:
	var bent := Vector3.ZERO
	for d in range(8):
		var entry: Vector3 = lut[int(nibbles[d])]
		bent += entry.x * Vector3(
			DIRECTIONS[d].x * entry.y, DIRECTIONS[d].y * entry.y, entry.z)
	return bent.normalized() if bent.length() > 1e-6 else Vector3(0.0, 0.0, 1.0)


func _uniform_nibbles(value: int) -> Array:
	var n: Array = []
	n.resize(8)
	n.fill(value)
	return n


# ── 查表本身 ────────────────────────────────────────────────────────────────

func _test_lut_shape(failures: Array[String]) -> void:
	var max_angle := 1.309
	var lut: PackedVector3Array = HexRendererScript.build_gi_horizon_lut(max_angle)
	_expect(lut.size() == 16, "gi_horizon_lut must have exactly 16 entries (4-bit quantization)",
		failures)
	if lut.size() != 16:
		return
	# n=0 → h=0：完全无遮挡，cos²0=1，可见锥质心 m=(0+π/2)/2=π/4。
	_expect(absf(lut[0].x - 1.0) < 1e-6,
		"lut[0].x must be cos^2(0)=1; unoccluded texels would not be fully lit", failures)
	_expect(absf(lut[0].y - cos(PI * 0.25)) < 1e-6 and absf(lut[0].z - sin(PI * 0.25)) < 1e-6,
		"lut[0] centroid direction must be 45 degrees for an unoccluded horizon", failures)
	var expect_last := cos(max_angle) * cos(max_angle)
	_expect(absf(lut[15].x - expect_last) < 1e-6,
		"lut[15].x must be cos^2(max_angle); quantization endpoint drifted", failures)
	for i in range(1, 16):
		_expect(lut[i].x < lut[i - 1].x,
			"lut visibility weight must decrease monotonically (broken at %d)" % i, failures)
		# (y, z) = (cos m, sin m) 必须是单位向量，否则 bent normal 长度会带上表的缩放误差。
		var yz := Vector2(lut[i].y, lut[i].z)
		_expect(absf(yz.length() - 1.0) < 1e-6,
			"lut[%d] centroid (cos m, sin m) is not unit length" % i, failures)
		_expect(lut[i].z >= lut[i].y - 1e-6,
			"lut[%d] centroid must stay above 45 degrees as occlusion grows" % i, failures)
	# max_angle 是可调 uniform：表必须跟着变，否则植被/地形会用错角度刻度。
	var steep: PackedVector3Array = HexRendererScript.build_gi_horizon_lut(PI * 0.5)
	_expect(absf(steep[15].x) < 1e-6,
		"a 90-degree max_angle must drive the last bucket to zero visibility", failures)


# ── V_sky ───────────────────────────────────────────────────────────────────

func _test_sky_visibility(failures: Array[String]) -> void:
	var lut: PackedVector3Array = HexRendererScript.build_gi_horizon_lut(PI * 0.5)
	_expect(absf(_sky_visibility(lut, _uniform_nibbles(0)) - 1.0) < 1e-6,
		"a flat plain (all horizon angles 0) must have sky visibility 1.0", failures)
	_expect(_sky_visibility(lut, _uniform_nibbles(15)) < 1e-6,
		"a fully enclosed pit (all horizon angles 90) must have sky visibility 0.0", failures)
	var prev := 1.1
	for q in range(16):
		var v := _sky_visibility(lut, _uniform_nibbles(q))
		_expect(v < prev, "sky visibility must fall as horizon angle rises (bucket %d)" % q,
			failures)
		prev = v
	# 单侧峡壁：只有一个方向被挡满 → 恰好损失 1/8 的可见度。
	var one_sided := _uniform_nibbles(0)
	one_sided[0] = 15
	_expect(absf(_sky_visibility(lut, one_sided) - 0.875) < 1e-6,
		"one fully blocked sector must remove exactly one eighth of sky visibility", failures)


# ── V_sky 的强度/下限重映射 ─────────────────────────────────────────────────
# shader 侧：v_scaled = mix(1, v, strength)；sky = mix(floor, 1, v_scaled)。
# 两条不变量必须同时成立，否则要么关不掉 GI，要么关掉 GI 后画面整体变暗。

func _remap(v: float, strength: float, ao_floor: float) -> float:
	return clampf(lerpf(ao_floor, 1.0, lerpf(1.0, v, strength)), 0.0, 1.0)


func _test_ao_remap(failures: Array[String]) -> void:
	# 强度归零必须精确回到 1.0，且与下限取值无关——这是视觉回归定位的主要手段，
	# 一旦下限渗进这条路径，"把 GI 关掉对比"就不再是无损对照。
	for ao_floor in [0.0, 0.45, 0.9]:
		for v in [0.0, 0.3, 1.0]:
			_expect(absf(_remap(v, 0.0, ao_floor) - 1.0) < 1e-6,
				"gi_ao_strength=0 must yield exactly 1.0 (floor=%s v=%s)" % [ao_floor, v],
				failures)
	# 全封闭地形不再是死黑，而是恰好落在下限上。
	_expect(absf(_remap(0.0, 1.0, 0.45) - 0.45) < 1e-6,
		"a fully enclosed pit must land exactly on gi_ao_floor", failures)
	# 完全开阔无论下限多高都不能被压暗。
	for ao_floor in [0.0, 0.45, 0.9]:
		_expect(absf(_remap(1.0, 1.0, ao_floor) - 1.0) < 1e-6,
			"open sky must stay at 1.0 regardless of the floor (floor=%s)" % ao_floor, failures)
	# 单调性：下限只压缩动态范围，不能翻转明暗关系。
	var prev := -1.0
	for i in range(11):
		var cur := _remap(float(i) / 10.0, 0.85, 0.45)
		_expect(cur > prev, "the AO remap must stay monotonic at v=%.1f" % (float(i) / 10.0),
			failures)
		prev = cur


# ── tap 权重 ────────────────────────────────────────────────────────────────
# V_sky 与 bent normal 共用一组权重：w = 双线性权重按 gi_ao_smoothing 向 1/4 靠拢。
# 权重必须始终是单位分割，否则平滑档位一变，全图亮度就跟着漂。

func _tap_weights(f: Vector2, smoothing: float) -> PackedFloat32Array:
	var fw := Vector2(lerpf(f.x, 0.5, smoothing), lerpf(f.y, 0.5, smoothing))
	return PackedFloat32Array([
		(1.0 - fw.x) * (1.0 - fw.y), fw.x * (1.0 - fw.y),
		(1.0 - fw.x) * fw.y, fw.x * fw.y,
	])


func _test_tap_weights(failures: Array[String]) -> void:
	for smoothing in [0.0, 0.5, 0.75, 1.0]:
		for fx in [0.0, 0.25, 0.5, 0.9]:
			for fy in [0.0, 0.6, 1.0]:
				var w := _tap_weights(Vector2(fx, fy), smoothing)
				var total := w[0] + w[1] + w[2] + w[3]
				_expect(absf(total - 1.0) < 1e-5,
					"tap weights must sum to 1 (smoothing=%s f=%s,%s got %s)"
						% [smoothing, fx, fy, total], failures)
				for i in range(4):
					_expect(w[i] >= 0.0, "tap weight %d went negative" % i, failures)
	# smoothing=1 是等权箱式；smoothing=0 是精确双线性。
	var box := _tap_weights(Vector2(0.9, 0.1), 1.0)
	for i in range(4):
		_expect(absf(box[i] - 0.25) < 1e-6,
			"gi_ao_smoothing=1 must give an equal-weight 2x2 box", failures)
	var bilinear := _tap_weights(Vector2(1.0, 1.0), 0.0)
	_expect(absf(bilinear[3] - 1.0) < 1e-6,
		"gi_ao_smoothing=0 must fall back to exact bilinear", failures)


# ── bent normal ─────────────────────────────────────────────────────────────

func _test_bent_normal(failures: Array[String]) -> void:
	var lut: PackedVector3Array = HexRendererScript.build_gi_horizon_lut(PI * 0.5)
	# 各向同性遮挡（碗底）：水平分量对消，平均可见方向应指向正上方。
	var bowl := _bent_normal(lut, _uniform_nibbles(8))
	_expect(bowl.z > 0.999,
		"isotropic occlusion must leave the bent normal pointing straight up", failures)
	# 东侧峭壁：可见天空偏西，bent normal 必须背离遮挡物。
	var east_wall := _uniform_nibbles(0)
	east_wall[0] = 15
	east_wall[1] = 12
	east_wall[7] = 12
	var bent := _bent_normal(lut, east_wall)
	_expect(bent.x < -0.02,
		"an eastern cliff must tilt the bent normal west, away from the occluder", failures)
	_expect(absf(bent.y) < 1e-6,
		"a north-south symmetric occluder must not tilt the bent normal sideways", failures)
	_expect(bent.z > 0.0, "the bent normal must never point below the surface", failures)
	# 完全开阔：正上方。
	var open := _bent_normal(lut, _uniform_nibbles(0))
	_expect(open.z > 0.999, "an unoccluded texel must have a straight-up bent normal", failures)


# ── 遮挡源 cell id 打包 ──────────────────────────────────────────────────────
# 烘焙侧（compute + C++）写 RGBA8 = [cid0_lo, cid0_hi, cid1_lo, cid1_hi]，
# shader 侧按 r + g*256 / b + a*256 还原。任一端改了字节序，弹射就会取到错误的 cell 颜色。

func _test_occluder_packing(failures: Array[String]) -> void:
	for cid in [0, 1, 255, 256, 4095, 32768, 65534]:
		var bytes := PackedByteArray([cid & 0xFF, (cid >> 8) & 0xFF, 0, 0])
		var decoded: int = int(bytes[0]) + int(bytes[1]) * 256
		_expect(decoded == cid,
			"occluder cell id %d did not survive the RGBA8 round trip" % cid, failures)
	# 两个源打包进同一个 texel 不能互相污染。
	var packed := PackedByteArray([
		1234 & 0xFF, (1234 >> 8) & 0xFF, 60001 & 0xFF, (60001 >> 8) & 0xFF])
	_expect(int(packed[0]) + int(packed[1]) * 256 == 1234
		and int(packed[2]) + int(packed[3]) * 256 == 60001,
		"dual occluder slots bled into each other", failures)
	# 哨兵：无遮挡 / 无效落点必须能被 shader 识别并跳过弹射。
	_expect(OCCLUDER_SENTINEL == 0xFFFF and OCCLUDER_SENTINEL > 65534,
		"the occluder sentinel must sit above every representable cell id", failures)


# ── 弹射代表色表 ────────────────────────────────────────────────────────────

func _test_bounce_albedo_table(failures: Array[String]) -> void:
	var terrain_count: int = TerrainTypeScript.TERRAIN.size()
	var albedo: Array = MapBakerScript._BOUNCE_ALBEDO
	_expect(albedo.size() == terrain_count,
		"_BOUNCE_ALBEDO has %d entries but TERRAIN has %d; append the new terrain's bounce colour"
			% [albedo.size(), terrain_count], failures)
	for i in range(albedo.size()):
		var c: Color = albedo[i]
		# 反照率越界会让弹射项自行增益，谷底反而比开阔地更亮。
		_expect(c.r >= 0.0 and c.r <= 1.0 and c.g >= 0.0 and c.g <= 1.0
			and c.b >= 0.0 and c.b <= 1.0,
			"bounce albedo %d is outside [0,1]" % i, failures)
		_expect(maxf(maxf(c.r, c.g), c.b) <= 0.95,
			"bounce albedo %d is too close to a perfect reflector" % i, failures)
	for water in MapBakerScript._BOUNCE_WATER_TERRAINS:
		_expect(int(water) >= 0 and int(water) < terrain_count,
			"water terrain id %d in _BOUNCE_WATER_TERRAINS is out of range" % water, failures)
	_expect(not MapBakerScript._BOUNCE_WATER_TERRAINS.has(TerrainTypeScript.TERRAIN.SEA_ICE),
		"sea ice is a bright land-like reflector and must keep contributing bounce light",
		failures)
	_expect(MapBakerScript._BOUNCE_WATER_TERRAINS.has(TerrainTypeScript.TERRAIN.OCEAN)
		and MapBakerScript._BOUNCE_WATER_TERRAINS.has(TerrainTypeScript.TERRAIN.LAKE),
		"open water must be excluded from diffuse bounce", failures)


# ── shader 变体 ────────────────────────────────────────────────────────────
# GI 的 uniform 与采样器分散在 uniforms / terrain_horizon / brdf / visual_tile_sampling
# 四个 include 里，靠 #ifdef 拼装。编译失败时 Godot 只往日志打一行、材质静默变黑，所以
# 这里用「编译成功 → uniform 列表非空」的判据把 8 个变体全过一遍。

func _uniform_names(code: String) -> Dictionary:
	var shader := Shader.new()
	shader.code = code
	var names := {}
	for entry in shader.get_shader_uniform_list():
		names[String(entry.get("name", ""))] = true
	return names


func _test_shader_variants(failures: Array[String]) -> void:
	var source := FileAccess.get_file_as_string(WORLD_SHADER_PATH)
	_expect(not source.is_empty(), "world_map.gdshader source is missing", failures)
	if source.is_empty():
		return
	for label in QUALITY_VARIANTS:
		var prefix := String(QUALITY_VARIANTS[label])
		var legacy := _uniform_names(prefix + source)
		_expect(not legacy.is_empty(), "%s legacy variant failed to compile" % label, failures)
		var tiled := _uniform_names("#define MAP_VISUAL_TILED\n" + prefix + source)
		_expect(not tiled.is_empty(), "%s tiled variant failed to compile" % label, failures)
		for names in [legacy, tiled]:
			if names.is_empty():
				continue
			for required in ["gi_horizon_lut", "gi_lut_bound", "gi_ao_strength",
					"gi_ao_floor", "gi_ao_smoothing", "gi_bent_strength",
					"gi_normal_floor", "gi_bounce_strength",
					"bounce_lut", "gi_bounce_bound", "gi_debug_view"]:
				_expect(names.has(required),
					"%s variant does not expose %s" % [label, required], failures)
		# 遮挡源采样器必须与 horizon 走同一条寻址路径，两条路径不能同时出现。
		_expect(tiled.has("visual_gi_occluder_tiles") and not tiled.has("gi_occluder_tex"),
			"%s tiled variant must read the occluder from the tile array only" % label, failures)
		_expect(legacy.has("gi_occluder_tex") and not legacy.has("visual_gi_occluder_tiles"),
			"%s legacy variant must read the occluder from the global map only" % label, failures)


func _test_shrub_shader_variants(failures: Array[String]) -> void:
	# 植被与地形共用 gi_horizon_lut 与强度参数；缺一个 uniform 就意味着 HexRenderer
	# 推送时会静默丢弃，谷底灌木亮于脚下地面。
	for label in ["legacy", "tiled"]:
		var prefix := "#define MAP_VISUAL_TILED\n" if label == "tiled" else ""
		var names := _uniform_names(prefix + ShrubLayerScript._SHADER_CODE)
		_expect(not names.is_empty(), "shrub %s variant failed to compile" % label, failures)
		if names.is_empty():
			continue
		for required in ["gi_horizon_lut", "gi_lut_bound", "gi_ao_strength",
				"gi_ao_floor", "gi_bent_strength", "gi_normal_floor"]:
			_expect(names.has(required),
				"shrub %s variant does not expose %s" % [label, required], failures)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
