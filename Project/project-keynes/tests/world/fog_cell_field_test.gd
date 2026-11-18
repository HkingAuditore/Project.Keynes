extends SceneTree
## [cell-field-overlays 2026-11-18 / O3] 战争迷雾改用场函数（战争迷雾 O3 验收）。
##
## 方案：docs/plans/terrain-cell-field-overlays-plan.md §3.6（迷雾显示 / 三条约束）、
##       §3.7、§3.9（迷雾采样账）、§4（开关跟随地形）、§5 O3、§6（迷雾不变量 1 / 2）、§7
## 契约：docs/plans/terrain-cell-field-contract.md §1（AA 带宽 / 平局次序）、
##       §9.1（回绕接缝 AA 修复）、§9.3（世界 uniform 不得硬编码）
##
## ── 三组断言，各自补不同的洞 ─────────────────────────────────────────────────
## A「源码」：`PK_CELL_FIELD` 变体里旧取 k 链路（map_index / enum_lut / edge 副格 /
##    Bayer 选格）**整段缺席**，新场函数符号**必须出现**；宏关时反向断言这些场函数
##    符号**不出现**（否则"反向断言"是恒真的空话）。用源码预处理器展开后判断，
##    不看文件全文 —— 两条路径在同一个文件里由 #ifdef 二选一，看全文两边都在。
## B「材质绑定」：FogOfWarLayer 用**同一个判定口**注入 `#define PK_CELL_FIELD`
##    （RendererShaderWater._cell_field_active），并把这些 uniform 真的推到材质上；
##    host 开关翻转后要重编回旧路径。全部 headless 可跑。
## C「GPU 不变量」（方案 §6）：**必须真后端**，headless 下 SKIPPED（dummy 渲染器
##    读不回像素，见契约 §6 的 headless 陷阱）。
##      不变量 1：`terrain_hidden` 为真的像素，迷雾 alpha ≥ 254/255。
##        非恒真证明：同一场景再把 `fog_early_out_enabled` 关掉渲染一次，这些像素里
##        必须**存在** alpha < 254/255 的（否则"强制不透明"这一条根本没被触发过）。
##      不变量 2：k = 1 的格子，其格心像素迷雾 alpha < 0.02（合成全 1 的 cell_table）。
##      不变量 3：[fog-padding 2026-11-18] 地图外 padding（row < 0 / row ≥ map_h）
##        必须**完全不透明**（alpha ≥ 254/255），同一张图里的格网内部格心仍必须透明。
##        守的是用户截图那个 bug：屏幕上下各一条蓝色冰带 —— padding 行被按地形侧
##        「全知 k=1、早退判定不生效」的语义处理（`fog_cell_k()` 曾写成
##        `mix(1.0, k, inside)`），而迷雾侧 k 是**显示不透明度**的语义（k=1 ⇒ 透明），
##        于是 padding 那圈薄带透明，露出 world_bounds 里多出来的极地海冰。
##        不变量 1/2 的探针世界有 96 行（96 × 33 wu ≈ 3168 wu），240 px 的视口永远落在
##        row 0..7 附近，padding 从来没进过画面；所以不变量 3 另造一个 map_h = 4 的
##        合成世界，并把探针矩形挪成 y ∈ [-80, +160]，同时跨过 row<0 与 row≥map_h
##        两条边（详细推导见 `_check_gpu_padding_invariant`）。
##
## ── 用法 ────────────────────────────────────────────────────────────────────
##   godot --headless -s tests/world/fog_cell_field_test.gd                 # A + B，C 跳过
##   godot --rendering-driver vulkan  -s tests/world/fog_cell_field_test.gd # A + B + C
##   （本机 --rendering-driver opengl3 目前挂在 "Unable to initialize video driver"，
##    所以 C 组只按 vulkan 记录；不要为了绕过驱动问题去改断言。）
##
## ── 为什么调试视图写在颜色里（而不是直接读 alpha）──────────────────────────────
## canvas_item 是 `render_mode blend_mix`（fog_of_war.gdshader:2）：alpha = 0 的片元会把
## rgb 一起乘成 0，回读就是清屏色 —— 与"什么都没画"无法区分（契约 §9.3 的 view 22 踩过
## 同一个坑）。所以 shader 的三个调试档都把值写进 **rgb** 且 alpha 固定 1.0。

const SHADER_PATH := "res://shaders/fog_of_war.gdshader"
const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")

# ── C 组探针尺度（1 像素 = 1 世界单位，与 cell_field_gpu_parity_probe.gd 同一约定）──
const VIEW_W := 320
const VIEW_H := 240
const WORLD_PER_PIXEL := 1.0
const HEX_SIZE := 22.0
const MAP_W := 96
const MAP_H := 96
const ORIGIN := Vector2(-131.31, 0.0)     # x 跨过 0（把负列喂给 pk_posmod）
const WRAP_ORIGIN_X := 0.0
const VIEW_HIDDEN := 1                    # fog_of_war.gdshader 的 fog_debug_view = 1
const VIEW_ALPHA := 2
const VIEW_K := 3
const ALPHA_OPAQUE_MIN := 254             # 不变量 1 的阈值（8bit 回读）
const ALPHA_CLEAR_MAX := 0.02             # 不变量 2 的阈值

# ── [fog-padding 2026-11-18] 不变量 3 的合成世界与探针矩形 ─────────────────────
# 行步长 = 1.5·hex_size = 33 wu。240 px 高的探针（1 px = 1 世界单位）要在同一张图里
# 同时跨过 row<0 与 row≥map_h 两条边，只能把 map_h 压小：map_h = 4 时格心在
# y = 0 / 33 / 66 / 99，地图格体最南到 y = 99 + hex_size = 121，探针 y ∈ [-80, +160]
# 于是覆盖 row ∈ [-2.42, +4.85]（北侧 3 条 padding 行、南侧 1 条以上）。
const PAD_MAP_H := 4
const PAD_Y_MIN := -80.0
const PAD_Y_MAX := 160.0
const PAD_ORIGIN := Vector2(ORIGIN.x, PAD_Y_MIN)
const PAD_SIZE := Vector2(VIEW_W, PAD_Y_MAX - PAD_Y_MIN)

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_source_variants()
	_check_uniform_sets()
	await _check_layer_binding()
	await _check_web_warmup_prefix()
	await _check_gpu_invariants()
	await _check_gpu_padding_invariant()
	print("=== fog cell field (O3): %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ═══════════════════════════════════════════════════════════════════════════
# A. 源码变体
# ═══════════════════════════════════════════════════════════════════════════

func _check_source_variants() -> void:
	var raw := FileAccess.get_file_as_string(SHADER_PATH)
	_expect(not raw.is_empty(), "fog shader source loads")
	var off := _expand_shader(SHADER_PATH, {})
	var on := _expand_shader(SHADER_PATH, {"PK_CELL_FIELD": true})
	var on_tiled := _expand_shader(SHADER_PATH,
		{"PK_CELL_FIELD": true, "MAP_VISUAL_TILED": true})
	_expect(off.length() > 4000 and on.length() > 4000 and off != on,
		"preprocessor expands both variants and the define changes the token stream"
			+ " (%d vs %d chars)" % [off.length(), on.length()])

	# ── A1：PK 变体里旧链路必须**整段缺席**（方案 §3.6「删除」那一条）──────────
	for needle in [
		"visual_sample_map_index",
		"texture(enum_lut",
		"decode_edge_secondary_index",
		"fog_decode_edge_secondary",
		"fog_decode_cell_index",
		"fog_mobile_dither_uv_threshold",
		"fog_edge_secondary_weight",
		"dyn_lut",
		"map_index_atlas",
		"visual_map_index_tiles",
	]:
		_expect(not on.contains(needle),
			"PK_CELL_FIELD variant compiles out the legacy k path ('%s' absent)" % needle)
	_expect(not on_tiled.contains("visual_map_index_tiles")
			and not on_tiled.contains("visual_edge_neighbor_tiles"),
		"PK_CELL_FIELD tiled variant drops both legacy tile arrays")

	# ── A2：PK 变体里新场函数必须**出现**（含三条约束各自的代码形状）──────────
	for needle in [
		"pk_hex_sharpen",             # 约束 1：锐化权重（带宽）
		"pk_overlay_fog_k",           # 三格 k 加权
		"pk_soft_warp_tiled",         # 可平铺扭曲（§3.2 第 3 条）
		"pk_hex_field_aa",            # AA 带宽下限（契约 §9.1）
		"PK_FIELD_BAND_MAX",          # 与地形同一个带宽上限 / 早退阈值
		"PK_HEX_SQRT3",               # A_max 推导里的 √3
		"fog_clamp_length",           # 约束 2：按长度 clamp
		"fog_hidden_margin",          # 约束 3：2 个屏幕像素的 gap 余量
		"fog_early_out_k",            # 约束 3：与地形同一条判定
		"fog_terrain_hidden",         # 约束 3 的布尔量
		"terrain_warp_layer_bound",   # 约束 3：与地形同一张扭曲场
		"cell_table",                 # k 的新来源（layer2.R）
	]:
		_expect(on.contains(needle),
			"PK_CELL_FIELD variant contains '%s'" % needle)
	_expect(on.contains("pk_overlay_tri") and on.contains("fog_hex_grid"),
		"PK_CELL_FIELD variant routes through the shared overlay tri helper")
	# include 指令本身在展开结果里会被内联掉，所以这两条对**去注释后的源码**断言。
	var raw_code := _strip_shader_comments(raw.replace("\r\n", "\n"))
	_expect(raw_code.contains("res://shaders/include/cell_field_overlays.gdshaderinc"),
		"PK_CELL_FIELD variant includes the shared zero-uniform overlay glue")
	_expect(raw_code.contains("#ifdef PK_CELL_FIELD"),
		"the glue include sits under #ifdef PK_CELL_FIELD")
	_expect(not raw_code.contains("res://shaders/include/hex_cell_field.gdshaderinc"),
		"fog shader must NOT include the terrain wrapper (it needs uniforms.gdshaderinc)")

	# ── A3：宏关时反向断言必须非恒真 ─────────────────────────────────────────
	#   两个方向都要断言：场函数符号不在，且旧链路的符号**确实在**。
	for needle in [
		"pk_hex_sharpen",
		"pk_overlay_fog_k",
		"pk_overlay_tri",
		"fog_cell_k",
		"fog_clamp_length",
		"fog_terrain_hidden",
		"fog_warp_amax",
		"cell_table",
	]:
		_expect(not off.contains(needle),
			"legacy variant (no PK_CELL_FIELD) has no field symbol '%s'" % needle)
	for needle in [
		"visual_sample_map_index",
		"texture(enum_lut",
		"fog_decode_edge_secondary",
		"fog_mobile_dither_uv_threshold",
		"fog_edge_secondary_weight",
	]:
		_expect(off.contains(needle),
			"legacy variant still draws k the old way ('%s' present)" % needle)

	# ── A4：三条约束的**具体表达式**必须逐字在（防止有人悄悄改掉推导）────────
	_expect(on.contains("max(PK_HEX_SQRT3 * 0.5 - fog_band * 0.5, 0.0) * hex_size"),
		"constraint 2: A_max = (√3/2 − band/2)·hex_size computed from the band")
	_expect(on.contains("4.0 / max(hex_size, 1e-4) * fog_px_world"),
		"constraint 3: fog_hidden_margin = 4·world_per_px/hex_size (2 screen pixels)")
	_expect(on.contains("pk_hex_tri_gap(fog_ttri) >= PK_FIELD_BAND_MAX - fog_hidden_margin"),
		"constraint 3: gap threshold is PK_FIELD_BAND_MAX minus the margin (safe direction)")
	_expect(on.contains("alpha = mix(alpha, 1.0, fog_hidden01)"),
		"constraint 3: forced opacity applied with mix (no per-pixel branch)")
	_expect(not on.contains("fog_hidden01) ? 1.0 : alpha"),
		"constraint 3: no `? :` on the alpha itself (mix only)")
	# 约束 3 的前半：**结构**保证「早退像素一定进云体分支」。
	# 显示侧 k 与地形侧 k 来自两张不同扭曲场（位移差上界 ≈1.47·hex_size），所以存在
	# 「地形说未探索、显示侧 k=1」的像素；那时 fog_amount=0 会让云体分支整段跳过、
	# 只改 alpha 改不到。这条断言守着那个 max()。
	_expect(on.contains("fog_amount = max(fog_amount, fog_hidden01)"),
		"constraint 3: fog_amount is floored to 1 on terrain_hidden pixels, so the cloud"
			+ " branch cannot be skipped there")
	_expect(on.find("fog_amount = max(fog_amount, fog_hidden01)")
			< on.find("if (fog_amount > 0.02)"),
		"constraint 3: the floor is applied BEFORE the fog_amount gate")


# ═══════════════════════════════════════════════════════════════════════════
# B. uniform 集合与材质绑定（headless 可跑）
# ═══════════════════════════════════════════════════════════════════════════

func _check_uniform_sets() -> void:
	var src := FileAccess.get_file_as_string(SHADER_PATH)
	var off := _uniform_names("", src)
	var off_tiled := _uniform_names("#define MAP_VISUAL_TILED\n", src)
	var on := _uniform_names("#define PK_CELL_FIELD\n", src)
	var on_tiled := _uniform_names("#define MAP_VISUAL_TILED\n#define PK_CELL_FIELD\n", src)
	_expect(not off.is_empty() and not on.is_empty(),
		"both fog variants compile in the shader language")

	# 方案 §3.9 的迷雾采样账：sampler 4 → 2。
	var off_samplers := _count_samplers(off)
	var on_samplers := _count_samplers(on)
	var on_tiled_samplers := _count_samplers(on_tiled)
	_expect(off_samplers == 4,
		"legacy fog program uses 4 samplers (got %d)" % off_samplers)
	_expect(on_samplers == 2,
		"PK fog program uses 2 samplers: cell_table + terrain warp source (got %d)"
			% on_samplers)
	_expect(on_tiled_samplers == 2,
		"PK tiled fog program uses 2 samplers: cell_table + visual_warp_tiles (got %d)"
			% on_tiled_samplers)
	for name in ["enum_lut", "map_index_atlas", "terrain_edge_neighbor_tex",
			"terrain_edge_distance_tex"]:
		_expect(not on.has(name), "PK fog program drops legacy sampler '%s'" % name)
	for name in ["visual_map_index_tiles", "visual_edge_neighbor_tiles",
			"visual_edge_distance_tiles"]:
		_expect(not on_tiled.has(name),
			"PK tiled fog program drops legacy sampler '%s'" % name)
	for name in ["cell_table", "cell_table_size", "cell_table_bound", "hex_size", "map_dims",
			"terrain_warp_layer_bound", "terrain_warp_range", "terrain_warp_amp",
			"fog_field_band", "fog_warp_freq", "fog_warp_amp",
			"fog_early_out_enabled", "fog_early_out_k", "fog_debug_view"]:
		_expect(on.has(name), "PK fog program exposes uniform '%s'" % name)
	_expect(on_tiled.has("visual_warp_tiles"),
		"PK tiled fog program exposes the warp tile array")

	# 生产上真正存在的四套前缀组合都必须在 shader 语言层编得过（移动 / web 的编译期档
	# 与本仓的 tier 宏链一起进来；旧的 Bayer 分支正好在 MOBILE_QUALITY_LOW 下）。
	for combo in [
		{"label": "mobile_low", "prefix": "#define PK_CELL_FIELD\n#define MOBILE_QUALITY_LOW\n"
			+ "#define PK_SHADER_TIER_LOW\n"},
		{"label": "mobile_low_tiled",
			"prefix": "#define MAP_VISUAL_TILED\n#define PK_CELL_FIELD\n"
			+ "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"},
		{"label": "web_fog_runtime",
			"prefix": "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
			+ "#define PK_WEB_FOG_RUNTIME\n#define PK_CELL_FIELD\n"},
	]:
		var names := _uniform_names(String(combo["prefix"]), src)
		_expect(not names.is_empty(),
			"PK fog variant compiles with the '%s' prefix" % combo["label"])

	# 世界坐标 uniform 不得硬编码（契约 §9.3）：hex_size / map_dims 必须由宿主推送。
	var layer_src := FileAccess.get_file_as_string(
		"res://scripts/rendering/fog_of_war_layer.gd")
	for needle in ["\"hex_size\"", "\"map_dims\"", "\"cell_table_bound\"",
			"\"terrain_warp_layer_bound\"", "\"fog_early_out_enabled\""]:
		_expect(layer_src.contains(needle),
			"fog layer pushes %s (world uniforms are never defaulted)" % needle)


func _uniform_names(prefix: String, source: String) -> Dictionary:
	var sh := Shader.new()
	sh.code = prefix + source
	var names := {}
	for entry in sh.get_shader_uniform_list():
		names[String(entry.get("name", ""))] = int(entry.get("type", TYPE_NIL))
	return names


func _count_samplers(names: Dictionary) -> int:
	# `get_shader_uniform_list()` 把 sampler2D / sampler2DArray 都报成 TYPE_OBJECT
	# （与 tests/world/web_water_pass_node_test.gd:144 同一口径）。
	var n := 0
	for key in names:
		if int(names[key]) == TYPE_OBJECT:
			n += 1
	return n


# ═══════════════════════════════════════════════════════════════════════════
# B2. 图层绑定：同一个判定口注入 define + 推 uniform（headless 可跑）
# ═══════════════════════════════════════════════════════════════════════════

func _check_layer_binding() -> void:
	# 钉住 boot 自检结论（受限平台未判定时一律不启用；桌面 / headless 本来就是 pass，
	# 钉住只是让这条断言与机器无关）。
	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)

	var world := _build_world_stripes()
	var host := _FakeFogHost.new()
	host.name = "FakeFogHost"
	host.terrain_cell_field_enabled = true
	host._world = world
	host._shader_mat = _build_host_material(true, 0.02)
	root.add_child(host)

	var fog := FogOfWarLayer.new()
	fog.name = "FogOfWarLayerProbe"
	host.add_child(fog)
	# setup() 是"世界数据已就绪"的唯一入口（renderer_material_publish.gd:495）。
	fog.setup(Rect2(ORIGIN, Vector2(VIEW_W, VIEW_H)), DataOverlayBaker.get_empty_texture(),
		Vector2i(MAP_W, MAP_H), HEX_SIZE, 0.0)
	await process_frame

	var mat: ShaderMaterial = fog.get("_shader_mat")
	_expect(mat != null, "fog layer builds a shader material")
	var code := String(mat.shader.code) if mat != null and mat.shader != null else ""
	_expect(code.contains("#define PK_CELL_FIELD"),
		"fog layer injects PK_CELL_FIELD when _cell_field_active(host) is true")
	_expect(not code.contains("#define PK_CELL_FIELD")
			or code.find("#define PK_CELL_FIELD") < code.find("shader_type"),
		"the define lands in the prefix, before shader_type")
	_expect(bool(fog.get("_built_cell_field")),
		"fog layer records that the current program is the field variant")

	# ── 推上去的 uniform 必须就是宿主那份数据 ────────────────────────────────
	_expect(bool(mat.get_shader_parameter("cell_table_bound")),
		"layer pushes cell_table_bound=true when the table is published")
	_expect(mat.get_shader_parameter("cell_table") == world.cell_table_tex,
		"layer pushes the real cell_table texture object")
	var dims: Variant = mat.get_shader_parameter("map_dims")
	_expect(dims is Vector2 and Vector2(dims) == Vector2(MAP_W, MAP_H),
		"layer pushes map_dims = cell_table dims (%s)" % str(dims))
	_expect(is_equal_approx(float(mat.get_shader_parameter("hex_size")), HEX_SIZE),
		"layer pushes hex_size = host.hex_size")
	_expect(bool(mat.get_shader_parameter("terrain_warp_layer_bound")),
		"layer pushes terrain_warp_layer_bound from WorldData (same gate as terrain)")
	_expect(mat.get_shader_parameter("terrain_surface_tex") == world.terrain_surface_tex,
		"layer pushes terrain_surface_tex (non-tiled warp source = layer6)")
	_expect(is_equal_approx(float(mat.get_shader_parameter("terrain_warp_range")),
			world.boundary_warp_range),
		"layer pushes terrain_warp_range = WorldData.boundary_warp_range")
	_expect(is_equal_approx(float(mat.get_shader_parameter("terrain_warp_amp")),
			MapBaker.WARP_AMP),
		"layer pushes terrain_warp_amp = MapBaker.WARP_AMP (generation-time constant)")
	_expect(bool(mat.get_shader_parameter("fog_early_out_enabled")),
		"layer mirrors the terrain material's fog_early_out_enabled (same source)")
	_expect(is_equal_approx(float(mat.get_shader_parameter("fog_early_out_k")), 0.02),
		"layer mirrors the terrain material's fog_early_out_k")
	_expect(is_equal_approx(float(mat.get_shader_parameter("fog_field_band")),
			FogOfWarLayer.FOG_FIELD_BAND) and FogOfWarLayer.FOG_FIELD_BAND < 0.8661,
		"constraint 1: fog_field_band default %.2f < √3/2" % FogOfWarLayer.FOG_FIELD_BAND)
	# [O23 2026-11-18] 通向"同一个边界"的另一半：迷雾材质上的扭曲参数必须就是真源那两个数。
	# 天气材质那一侧的镜像断言在 weather_overlay_field_test.gd 的 E 组（同一个常量、同一组值）。
	_expect(is_equal_approx(float(mat.get_shader_parameter("fog_warp_freq")),
			FogOfWarLayer.FOG_WARP_FREQ),
		"[O23] the fog material carries fog_warp_freq = FOG_WARP_FREQ (%.6f)"
			% FogOfWarLayer.FOG_WARP_FREQ)
	_expect(is_equal_approx(float(mat.get_shader_parameter("fog_warp_amp")),
			FogOfWarLayer.FOG_WARP_AMP),
		"[O23] the fog material carries fog_warp_amp = FOG_WARP_AMP (%.6f)"
			% FogOfWarLayer.FOG_WARP_AMP)

	# ── 缺数据时必须降级成"不读表"而不是读未初始化纹理 ──────────────────────
	world.cell_table_bound = false
	world.cell_table_layers = 0
	fog.setup(Rect2(ORIGIN, Vector2(VIEW_W, VIEW_H)), DataOverlayBaker.get_empty_texture(),
		Vector2i(MAP_W, MAP_H), HEX_SIZE, 0.0)
	await process_frame
	mat = fog.get("_shader_mat")
	_expect(mat != null and not bool(mat.get_shader_parameter("cell_table_bound")),
		"unpublished cell_table pushes cell_table_bound=false (shader paints thick fog,"
			+ " never reads the table)")
	world.cell_table_bound = true
	world.cell_table_layers = 4

	# ── 关掉 host 开关 ⇒ 必须重编回旧路径（与地形同一边）──────────────────────
	host.terrain_cell_field_enabled = false
	await process_frame
	await process_frame
	mat = fog.get("_shader_mat")
	code = String(mat.shader.code) if mat != null and mat.shader != null else ""
	_expect(mat != null and not code.contains("#define PK_CELL_FIELD"),
		"flipping host.terrain_cell_field_enabled off rebuilds the legacy fog program")
	_expect(mat != null and not bool(fog.get("_built_cell_field")),
		"layer records the legacy variant after the flip")

	# ── 没有新开关：判定口只能是 RendererShaderWater._cell_field_active ────────
	_expect(layer_src_has_call("RendererShaderWaterScript._cell_field_active("),
		"fog layer routes the switch through RendererShaderWater._cell_field_active")
	_expect(not layer_src_has_call("cell_field_setting_enabled(")
			and not layer_src_has_call("CELL_FIELD_SETTING"),
		"fog layer introduces no second switch (no project-setting read)")

	host.queue_free()
	await process_frame


const _LAYER_SRC := "res://scripts/rendering/fog_of_war_layer.gd"

func layer_src_has_call(needle: String) -> bool:
	var src := FileAccess.get_file_as_string(_LAYER_SRC)
	# 跳过注释行：注释里出现这两个词是解释，不是调用点。
	for line in src.replace("\r\n", "\n").split("\n"):
		var trimmed := String(line).strip_edges()
		if trimmed.begins_with("#"):
			continue
		if trimmed.contains(needle):
			return true
	return false


# ═══════════════════════════════════════════════════════════════════════════
# B3. [O23 2026-11-18] Web 预热前缀 = 运行期前缀（逐字节；开关开 / 关两态）
#
# 真 bug（本轮修的那个）：web_shader_warmup.gd 的 fog 条目只写了
#   FOG_PREFIX + "#define PK_WEB_FOG_RUNTIME\n"
# 而 O3 之后运行期 fog_of_war_layer.gd::_load_shader() 在**最后**还会追加
# `#define PK_CELL_FIELD`（判定口 = RendererShaderWater._cell_field_active）。
# 于是 Web 上菜单期预热的 program 与进游戏后真正要画的 program 差一个宏 ⇒ 驱动缓存
# 不命中 ⇒ 迷雾在进入世界时真编一次（冻帧）。
#
# 这一组守三件事：
#   ① 预热前缀的**动态段**来自运行期同一个判定口（不是本文件/预热文件里再写一个 if）；
#   ② `_collect_codes()` 里 fog 的 code **逐字节等于** 运行期前缀 + 源码（0/1 两态）；
#   ③ 顺序与 `_load_shader()` 一致：场函数段是**最后一个** prefix +=，紧跟 web 运行期宏。
# 本机（非 web）拿不到 OS.has_feature("web") 分支，所以：
#   · web 前缀本身按"运行期各段真源 + 同一个判定口"逐字节拼（段序另有源码断言守着）；
#   · 本机真实 `_load_shader()` 的字节另行逐字节对账（它只含场函数段）。
# ═══════════════════════════════════════════════════════════════════════════

func _check_web_warmup_prefix() -> void:
	var had_setting := ProjectSettings.has_setting(RendererShaderWaterScript.CELL_FIELD_SETTING)
	var old_setting: Variant = ProjectSettings.get_setting(
		RendererShaderWaterScript.CELL_FIELD_SETTING, null)
	var layer_src := FileAccess.get_file_as_string(_LAYER_SRC).replace("\r\n", "\n")
	var fog_src := FileAccess.get_file_as_string(SHADER_PATH)
	var warmup_src := FileAccess.get_file_as_string(
		"res://scripts/rendering/web_shader_warmup.gd").replace("\r\n", "\n")
	_expect(not layer_src.is_empty() and not fog_src.is_empty() and not warmup_src.is_empty(),
		"[warmup] fog layer / fog shader / warmup sources all load")

	# ── ① 段序：与 _load_shader() 的实际拼装一致（源码级，平台无关）─────────────
	var load_body := _region(layer_src, "func _load_shader() -> Shader:",
		"func _fog_runtime_quality_override()")
	_expect(not load_body.is_empty(),
		"[warmup] _load_shader() body is locatable (%d chars)" % load_body.length())
	var web_macro := _runtime_prefix_literal(layer_src, "PK_WEB_FOG_RUNTIME")
	_expect(web_macro == "#define PK_WEB_FOG_RUNTIME\n",
		"[warmup] the runtime web define is read out of _load_shader() (got '%s')"
			% web_macro.replace("\n", "|"))
	var cell_append_at := load_body.find("prefix += CELL_FIELD_DEFINE")
	var last_append_at := load_body.rfind("prefix +=")
	_expect(cell_append_at > 0,
		"[warmup] _load_shader() appends CELL_FIELD_DEFINE (the owner constant)")
	_expect(cell_append_at == last_append_at,
		"[warmup] the field define is the LAST prefix += in _load_shader() (got %d / %d)"
			% [cell_append_at, last_append_at])
	_expect(load_body.find("_shader_quality_define_prefix") < load_body.find(
			"PK_WEB_FOG_RUNTIME") and load_body.find("PK_WEB_FOG_RUNTIME") < cell_append_at,
		"[warmup] runtime order is [tier] → PK_WEB_FOG_RUNTIME → CELL_FIELD_DEFINE")

	# 预热文件里不许出现宏字面量（前缀只能来自 owner 常量 / 同一个判定口）。
	var warmup_literals: Array = []
	for line in _code_lines(warmup_src):
		if String(line).contains("PK_CELL_FIELD"):
			warmup_literals.append(String(line).strip_edges())
	_expect(warmup_literals.is_empty(),
		"[warmup] web_shader_warmup.gd writes no PK_CELL_FIELD literal (offenders: %s)"
			% str(warmup_literals))
	_expect(not _shaders_entry_for("res://shaders/fog_of_war.gdshader").has("prefix"),
		"[warmup] the fog entry carries no stale prefix constant (bytes come from"
			+ " WebShaderWarmup.fog_prefix_active() only)")
	var tier_probe := FogOfWarLayer.new()
	var tier_segment: String = tier_probe._shader_quality_define_prefix("MOBILE_QUALITY_LOW")
	tier_probe.free()
	_expect(WebShaderWarmup.FOG_WEB_PREFIX == tier_segment + web_macro,
		"[warmup] FOG_WEB_PREFIX == the runtime tier segment + the runtime web define"
			+ " (got %s)" % WebShaderWarmup.FOG_WEB_PREFIX.replace("\n", "|"))

	# ── ② 两态（开关开 / 关）+ 第三态（boot 自检 fail）：逐字节等值 ──────────────
	var host_on := _FakeFogHost.new()
	host_on.terrain_cell_field_enabled = true
	var host_off := _FakeFogHost.new()
	host_off.terrain_cell_field_enabled = false
	var pass_state := RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS
	var fail_state := RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL
	var prefix_by_state := {}
	for state in [
		{"label": "on", "setting": true, "verdict": pass_state},
		{"label": "off", "setting": false, "verdict": pass_state},
		{"label": "boot_fail", "setting": true, "verdict": fail_state},
	]:
		var label := String(state["label"])
		var setting_on := bool(state["setting"])
		ProjectSettings.set_setting(RendererShaderWaterScript.CELL_FIELD_SETTING, setting_on)
		RendererShaderWaterScript.reset_cell_field_boot_state()
		RendererShaderWaterScript.set_cell_field_boot_verdict(String(state["verdict"]))
		# 运行期判定口（**真函数**，不是本文件复述的 if）：host 开关在 boot 时刻就等于
		# 项目设置（HexRenderer._init 读的是同一个键）。
		host_on.terrain_cell_field_enabled = setting_on
		var runtime_gate := RendererShaderWaterScript._cell_field_active(host_on) \
			and setting_on
		var expected := tier_segment + web_macro + (
			RendererShaderWaterScript.CELL_FIELD_DEFINE if runtime_gate else "")
		var warm := WebShaderWarmup.fog_prefix_active()
		prefix_by_state[label] = warm
		_expect(warm == expected,
			("[warmup/%s] warmup fog prefix == the runtime prefix (byte for byte): %s vs %s")
				% [label, warm.replace("\n", "|"), expected.replace("\n", "|")])
		_expect(warm.contains(web_macro) and warm.begins_with(tier_segment),
			"[warmup/%s] prefix keeps [tier] → [web define] → [field define] order" % label)
		# 真实清单：`_collect_codes()` 里 fog 那条的 code 逐字节等于前缀 + 源码。
		var plan_codes := _plan_codes()
		_expect(String(plan_codes.get("fog_of_war", "")) == warm + fog_src,
			"[warmup/%s] the warmup plan compiles the runtime fog program byte for byte"
				% label)
		# 本机真实 `_load_shader()` 的字节：非 web 没有 tier / 运行期宏，只剩场函数段。
		var host := _FakeFogHost.new()
		host.terrain_cell_field_enabled = setting_on
		host._world = _build_world_stripes()
		host._shader_mat = _build_host_material(true, 0.02)
		root.add_child(host)
		var fog := FogOfWarLayer.new()
		host.add_child(fog)
		fog.setup(Rect2(ORIGIN, Vector2(VIEW_W, VIEW_H)),
			DataOverlayBaker.get_empty_texture(), Vector2i(MAP_W, MAP_H), HEX_SIZE, 0.0)
		await process_frame
		var mat: ShaderMaterial = fog.get("_shader_mat")
		var real_code := String(mat.shader.code) if mat != null and mat.shader != null else ""
		var real_expected := (RendererShaderWaterScript.CELL_FIELD_DEFINE
			if RendererShaderWaterScript._cell_field_active(host) else "") + fog_src
		_expect(real_code == real_expected,
			("[warmup/%s] the real _load_shader() bytes are exactly [gate segment] + source"
				+ " (define at the very front of the prefix, %d vs %d chars)")
				% [label, real_code.length(), real_expected.length()])
		host.queue_free()
		await process_frame
	# 三态必须**真的不同**：否则"只预热选中那一套"可以退化成"每态编同一份"还全绿。
	_expect(String(prefix_by_state["on"]) != String(prefix_by_state["off"])
			and String(prefix_by_state["on"]) != String(prefix_by_state["boot_fail"]),
		"[warmup] the three states really select different bytes (on=%s off=%s boot_fail=%s)"
			% [String(prefix_by_state["on"]).replace("\n", "|"),
				String(prefix_by_state["off"]).replace("\n", "|"),
				String(prefix_by_state["boot_fail"]).replace("\n", "|")])
	_expect(String(prefix_by_state["off"]) == String(prefix_by_state["boot_fail"]),
		"[warmup] switch-off and boot-fail both compile the legacy program (same bytes)")

	# ── ③ 复原设置与 boot 结论 ────────────────────────────────────────────────
	if had_setting:
		ProjectSettings.set_setting(RendererShaderWaterScript.CELL_FIELD_SETTING, old_setting)
	else:
		ProjectSettings.set_setting(RendererShaderWaterScript.CELL_FIELD_SETTING, null)
	RendererShaderWaterScript.reset_cell_field_boot_state()
	host_on.free()
	host_off.free()


## 预热计划里 label → code 的实际内容（真调 `_collect_codes()`，不复述它的拼装）。
func _plan_codes() -> Dictionary:
	var out := {}
	for entry in WebShaderWarmup._collect_codes():
		out[String(entry.get("label", ""))] = String(entry.get("code", ""))
	return out


## WebShaderWarmup.SHADERS 里某条 path 的条目（不存在时返回空字典）。
func _shaders_entry_for(path: String) -> Dictionary:
	for entry in WebShaderWarmup.SHADERS:
		if String(entry.get("path", "")) == path:
			return entry
	return {}


## 源码里 `prefix += "<字面量>"` 那条语句的字面量（把 `\n` 还原成换行）。
## 用来证明预热侧读的是运行期**同一批字节**，而不是本文件再抄一遍宏。
func _runtime_prefix_literal(source: String, macro: String) -> String:
	for line in source.split("\n"):
		var text := String(line).strip_edges()
		if not text.begins_with("prefix +=") or not text.contains(macro):
			continue
		var start := text.find("\"")
		var end := text.find("\"", start + 1)
		if start < 0 or end < 0:
			continue
		return text.substr(start + 1, end - start - 1).replace("\\n", "\n")
	return ""


## 去掉 `#` 注释行后的代码行（预热文件的"不许写宏字面量"断言用）。
func _code_lines(source: String) -> Array:
	var out: Array = []
	for line in source.split("\n"):
		var trimmed := String(line).strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		out.append(String(line))
	return out


## head 与 tail 之间的源码片段（head 必须存在；tail 不存在时取到结尾）。
func _region(text: String, head: String, tail: String) -> String:
	var at := text.find(head)
	if at < 0:
		return ""
	var end_at := text.find(tail, at + head.length())
	if end_at < 0:
		return text.substr(at)
	return text.substr(at, end_at - at)


# ═══════════════════════════════════════════════════════════════════════════
# C. GPU 不变量（真后端）
# ═══════════════════════════════════════════════════════════════════════════

func _check_gpu_invariants() -> void:
	print("[fog-cell-field] display=%s rendering_method=%s adapter=%s" % [
			DisplayServer.get_name(), RenderingServer.get_current_rendering_method(),
			RenderingServer.get_video_adapter_name()])
	if not _real_backend_available():
		print("[fog-cell-field] SKIP 迷雾不变量 1/2 需要真实渲染后端（headless 用 dummy 渲染器，"
				+ "读不回像素）。请改用：")
		print("[fog-cell-field]   godot --rendering-driver opengl3 "
				+ "-s res://tests/world/fog_cell_field_test.gd")
		print("[fog-cell-field]   godot --rendering-driver vulkan "
				+ "-s res://tests/world/fog_cell_field_test.gd")
		print("=== fog cell field invariants: SKIPPED (needs a real rendering backend) ===")
		return

	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
	var world := _build_world_stripes()
	var host := _FakeFogHost.new()
	host.name = "FakeFogHostGpu"
	host.terrain_cell_field_enabled = true
	host._world = world
	host._shader_mat = _build_host_material(true, 0.02)
	root.add_child(host)
	var fog := FogOfWarLayer.new()
	fog.name = "FogOfWarLayerGpu"
	host.add_child(fog)
	fog.setup(Rect2(ORIGIN, Vector2(VIEW_W, VIEW_H)), DataOverlayBaker.get_empty_texture(),
		Vector2i(MAP_W, MAP_H), HEX_SIZE, 0.0)
	await process_frame
	var layer_mat: ShaderMaterial = fog.get("_shader_mat")
	_expect(layer_mat != null, "[gpu] fog layer provides a usable material")
	if layer_mat == null:
		return

	# 探针自己铺几何 / 相机（1 像素 = 1 世界单位），但**材质用图层那份**：uniform 全部
	# 由生产代码推上去，探针只切 debug 档 / early_out 开关 —— 这条链上不重复写一套 uniform。
	var viewport: SubViewport = await _build_probe_scene(layer_mat, ORIGIN,
		Vector2(VIEW_W, VIEW_H))
	if viewport == null:
		return

	# ── 不变量 1：terrain_hidden ⇒ alpha ≥ 254/255 ────────────────────────────
	fog.set_fog_debug_view(VIEW_HIDDEN)
	var hidden_img := await _render(viewport)
	fog.set_fog_debug_view(VIEW_ALPHA)
	var alpha_on_img := await _render(viewport)
	# 对照：把早退关掉再画一遍。若这些像素的 alpha 在对照里依然是 1，"强制不透明"
	# 这一条就没有被真正触发过 ⇒ 本组断言会退化成恒真，必须显式证明不是。
	host._shader_mat.set_shader_parameter("fog_early_out_enabled", false)
	await process_frame
	await process_frame
	var alpha_off_img := await _render(viewport)
	fog.set_fog_debug_view(VIEW_K)
	var k_img := await _render(viewport)
	fog.set_fog_debug_view(0)

	_expect(hidden_img != null and alpha_on_img != null and alpha_off_img != null,
		"[gpu] every invariant-1 pass returns a readable image")
	if hidden_img != null and alpha_on_img != null and alpha_off_img != null:
		_report_invariant1(hidden_img, alpha_on_img, alpha_off_img, k_img)

	# ── 不变量 2：k = 1 的格子，格心 alpha < 0.02 ─────────────────────────────
	var visible_world := _build_world_all_visible()
	host._world = visible_world
	host._shader_mat.set_shader_parameter("fog_early_out_enabled", true)
	fog.setup(Rect2(ORIGIN, Vector2(VIEW_W, VIEW_H)), DataOverlayBaker.get_empty_texture(),
		Vector2i(MAP_W, MAP_H), HEX_SIZE, 0.0)
	await process_frame
	# setup() 只重推参数、不换材质对象 —— 探针那束 quad 继续指向同一份材质。
	_expect(fog.get("_shader_mat") == layer_mat,
		"[gpu] setup() keeps the same material object (probe quad stays valid)")
	fog.set_fog_debug_view(VIEW_ALPHA)
	await process_frame
	var clear_img := await _render(viewport)
	fog.set_fog_debug_view(VIEW_K)
	var k_visible_img := await _render(viewport)
	fog.set_fog_debug_view(0)
	if clear_img != null:
		_report_invariant2(clear_img, k_visible_img)

	host.queue_free()
	await process_frame


## 不变量 1：逐像素比对三个通道。
func _report_invariant1(hidden: Image, alpha_on: Image, alpha_off: Image,
		k_img: Variant) -> void:
	var hidden_count := 0
	var violations := 0
	var control_low := 0
	var control_clear := 0
	var min_alpha_on := 255
	var worst := ""
	var k_on_hidden_sum := 0.0
	for j in VIEW_H:
		for i in VIEW_W:
			var h := hidden.get_pixel(i, j).r
			if h < 0.5:
				continue
			hidden_count += 1
			var a_on := int(round(alpha_on.get_pixel(i, j).r * 255.0))
			var a_off := int(round(alpha_off.get_pixel(i, j).r * 255.0))
			min_alpha_on = mini(min_alpha_on, a_on)
			if a_on < ALPHA_OPAQUE_MIN:
				violations += 1
				if worst.is_empty():
					worst = "pixel(%d,%d) alpha_on=%d alpha_off=%d" % [i, j, a_on, a_off]
			if a_off < ALPHA_OPAQUE_MIN:
				control_low += 1
			# 显示侧 k == 1（云体分支本该整段跳过）的早退像素：约束 3 的
			# `fog_amount = max(fog_amount, fog_hidden01)` 就是为这一类准备的。
			if a_off == 0:
				control_clear += 1
			if k_img is Image:
				k_on_hidden_sum += float((k_img as Image).get_pixel(i, j).r)
	# 打印原始数字（方案 §6 要求"实测数字"，不能只报 0 违例）。
	print("[fog-cell-field] 不变量 1：terrain_hidden 像素 %d / %d，最小 alpha = %d/255，"
			% [hidden_count, VIEW_W * VIEW_H, min_alpha_on]
			+ "违例 %d；对照（早退关）里 alpha<254 的同类像素 %d 个"
			% [violations, control_low])
	print("[fog-cell-field] 不变量 1：其中显示侧 k=1（alpha=0，云体分支本该跳过）的 %d 个"
			% control_clear + " —— 这些只能靠 fog_amount 的 max() 兜住")
	if hidden_count > 0 and k_img is Image:
		print("[fog-cell-field] 不变量 1：hidden 像素上的显示用 k 均值 = %.4f"
				% (k_on_hidden_sum / float(hidden_count)))
	_expect(hidden_count > 0,
		"[gpu] invariant 1 is non-vacuous: %d pixels are classified terrain_hidden"
			% hidden_count)
	_expect(violations == 0,
		("[gpu] invariant 1: fog alpha >= 254/255 on 100%% of terrain_hidden pixels"
			+ " (%d violations, first: %s)")
			% [violations, "none" if worst.is_empty() else worst])
	_expect(control_low > 0,
		("[gpu] invariant 1 is load-bearing: %d of those pixels would be"
			+ " translucent (<254/255) with fog_early_out_enabled=false, i.e."
			+ " constraint 3 is what makes them opaque") % control_low)
	_expect(control_clear > 0,
		("[gpu] invariant 1 covers the worst case: %d terrain_hidden pixels have display"
			+ " k == 1 (the cloud branch would be skipped entirely), so the"
			+ " fog_amount=max(...) floor is exercised, not just the alpha mix")
			% control_clear)


## 不变量 2：k 全 1 的世界里，格心像素的迷雾 alpha 必须近似 0。
func _report_invariant2(alpha_img: Image, k_img: Variant) -> void:
	var total_bad := 0
	var max_alpha := 0.0
	for j in VIEW_H:
		for i in VIEW_W:
			var a := float(alpha_img.get_pixel(i, j).r)
			max_alpha = maxf(max_alpha, a)
			if a > ALPHA_CLEAR_MAX:
				total_bad += 1
	# 格心像素：把 cell 的 offset 反算成世界坐标（pointy-top：x = √3·s·(q + r/2)、
	# y = 1.5·s·r），与 pk_hex_tri 的分数 axial 公式互为逆（契约 §1）。
	var center_checked := 0
	var center_bad := 0
	var center_max := 0.0
	var sqrt3 := 1.7320508075688772
	for row in range(0, int(float(VIEW_H) / (1.5 * HEX_SIZE)) + 2):
		for col in range(-2, int(float(VIEW_W) / (sqrt3 * HEX_SIZE)) + 4):
			var q := float(col) - float(row - (row & 1)) * 0.5
			var wx := sqrt3 * HEX_SIZE * (q + float(row) * 0.5)
			var wy := 1.5 * HEX_SIZE * float(row)
			var px := int(floor((wx - ORIGIN.x) / WORLD_PER_PIXEL))
			var py := int(floor((wy - ORIGIN.y) / WORLD_PER_PIXEL))
			if px < 0 or py < 0 or px >= VIEW_W or py >= VIEW_H:
				continue
			center_checked += 1
			var a := float(alpha_img.get_pixel(px, py).r)
			center_max = maxf(center_max, a)
			if a > ALPHA_CLEAR_MAX:
				center_bad += 1
	print(("[fog-cell-field] 不变量 2：k=1 世界，全屏 %.4f%% 像素 alpha>0.02（最大 %.4f）；"
			+ "格心采样 %d 个，其中 alpha>0.02 的 %d 个（最大 %.4f）")
			% [100.0 * float(total_bad) / float(VIEW_W * VIEW_H), max_alpha,
				center_checked, center_bad, center_max])
	if k_img is Image:
		var k_min := 1.0
		for j in range(0, VIEW_H, 7):
			for i in range(0, VIEW_W, 7):
				k_min = minf(k_min, float((k_img as Image).get_pixel(i, j).r))
		print("[fog-cell-field] 不变量 2：显示用 k 的最小值 = %.4f（合成表恒 1）" % k_min)
		_expect(k_min > 0.99,
			"[gpu] invariant 2 setup is honest: k == 1 everywhere (min %.4f)" % k_min)
	_expect(center_checked > 20,
		"[gpu] invariant 2 samples real cell centers (%d)" % center_checked)
	_expect(center_bad == 0,
		("[gpu] invariant 2: fog alpha < 0.02 at 100%% of visible cell centers"
			+ " (%d/%d bad, max %.4f)") % [center_bad, center_checked, center_max])
	_expect(total_bad == 0,
		("[gpu] invariant 2: with k == 1 the whole screen is clear"
			+ " (%d/%d pixels > 0.02, max %.4f)")
			% [total_bad, VIEW_W * VIEW_H, max_alpha])


# ═══════════════════════════════════════════════════════════════════════════
# C2. [fog-padding 2026-11-18] 不变量 3：地图外 padding 必须完全不透明
#
# 用户截图报告的 bug：屏幕上下各一条蓝色冰带。
#   根因：O3 把迷雾的 k 改成场函数后，`fog_cell_k()` 对 row 越界（地图外 padding）用了
#   `mix(1.0, k, inside)` —— 那是**地形侧**的语义（padding 视作全知 k=1 走过场，早退判定
#   不生效）；迷雾侧 k 是**显示不透明度**的语义（k=1 ⇒ 透明）。照抄就得到「padding 那圈
#   薄带透明 ⇒ 露出 world_bounds 里多出来的极地海冰」。修复：`mix(0.0, k, inside)`。
#
# 为什么原有不变量 1/2 看不到它：那两支的探针世界是 MAP_H = 96 行（≈3168 wu），而
# SubViewport 只有 240 px 高（1 px = 1 世界单位）⇒ 画面永远落在 row 0..7 附近。
# 这里另造一个 map_h = PAD_MAP_H 的合成世界，并把探针矩形整体下移成 y ∈ [-80, +160]，
# 让同一张图同时跨过 row<0 与 row≥map_h 两条边。
#
# 三条断言（缺一条就可能恒真）：
#   A：padding 带的**每个**像素 alpha ≥ 254/255。
#      ← 变异验证：把 shader 改回 `mix(1.0, k, inside)`，这一条必须红。
#   B：同一张图里格网内部的格心（合成表里 k=1）alpha < 0.02。
#      ← 证明 A 不是「整屏都不透明」的退化；内部全 1 是**有意的对照**。
#   C：padding 带像素数 > 0，且南北两侧各 > 0（否则探针没真的跨过两条边）。
# ═══════════════════════════════════════════════════════════════════════════

func _check_gpu_padding_invariant() -> void:
	if not _real_backend_available():
		print("[fog-padding] SKIP 不变量 3（padding 必须完全不透明）同样需要真实渲染后端，"
				+ "headless 的 dummy 渲染器读不回像素。")
		return

	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
	var world := _build_world_padding()
	var host := _FakeFogHost.new()
	host.name = "FakeFogHostPadding"
	host.terrain_cell_field_enabled = true
	host._world = world
	host._shader_mat = _build_host_material(true, 0.02)
	root.add_child(host)
	var fog := FogOfWarLayer.new()
	fog.name = "FogOfWarLayerPadding"
	host.add_child(fog)
	# 探针矩形自己就是世界矩形（1 像素 = 1 世界单位）：y ∈ [-80, +160] 同时跨过两条边。
	fog.setup(Rect2(PAD_ORIGIN, PAD_SIZE), DataOverlayBaker.get_empty_texture(),
		Vector2i(MAP_W, PAD_MAP_H), HEX_SIZE, 0.0)
	await process_frame
	var layer_mat: ShaderMaterial = fog.get("_shader_mat")
	_expect(layer_mat != null, "[fog-padding] fog layer provides a usable material")
	if layer_mat == null:
		return
	# 表的行数必须真的只有 PAD_MAP_H 行：否则「两条 padding 边」会落在别处，断言白跑。
	var dims: Variant = layer_mat.get_shader_parameter("map_dims")
	_expect(dims is Vector2 and Vector2(dims) == Vector2(MAP_W, PAD_MAP_H),
		"[fog-padding] the cell table really has %d rows (map_dims = %s)"
			% [PAD_MAP_H, str(dims)])

	var viewport: SubViewport = await _build_probe_scene(layer_mat, PAD_ORIGIN, PAD_SIZE)
	if viewport == null:
		return
	fog.set_fog_debug_view(VIEW_ALPHA)
	var alpha_img := await _render(viewport)
	fog.set_fog_debug_view(VIEW_K)
	var k_img := await _render(viewport)
	fog.set_fog_debug_view(0)
	_expect(alpha_img != null, "[fog-padding] the alpha pass returns a readable image")
	if alpha_img != null:
		_report_invariant3(alpha_img, k_img)

	host.queue_free()
	await process_frame


## 不变量 3：padding 带完全不透明 + 同一张图内部格心透明（互为对照）。
func _report_invariant3(alpha_img: Image, k_img: Variant) -> void:
	var width := alpha_img.get_width()
	var height := alpha_img.get_height()
	var edges := _padding_band_edges()
	var north_max := float(edges["north_max"])
	var south_min := float(edges["south_min"])
	var north_count := 0
	var south_count := 0
	var violations := 0
	var min_alpha := 255
	var worst := ""
	var k_pad_max := 0.0
	for j in height:
		var wy := PAD_ORIGIN.y + (float(j) + 0.5) * WORLD_PER_PIXEL
		var north := wy <= north_max
		var south := wy >= south_min
		if not (north or south):
			continue
		if north:
			north_count += width
		else:
			south_count += width
		for i in width:
			var a := int(round(alpha_img.get_pixel(i, j).r * 255.0))
			min_alpha = mini(min_alpha, a)
			if a < ALPHA_OPAQUE_MIN:
				violations += 1
				if worst.is_empty():
					worst = "pixel(%d,%d) world_y=%.2f alpha=%d/255" % [i, j, wy, a]
			if k_img is Image:
				k_pad_max = maxf(k_pad_max, float((k_img as Image).get_pixel(i, j).r))
	# ── 内部对照（断言 B）：格网内、格心像素的 k = 1 ⇒ 迷雾必须几乎全透明 ──────────
	var centers := _interior_cell_centers(width, height)
	var center_bad := 0
	var center_max := 0.0
	var center_first := ""
	for point in centers:
		var px := int(point.x)
		var py := int(point.y)
		var a := float(alpha_img.get_pixel(px, py).r)
		center_max = maxf(center_max, a)
		if a > ALPHA_CLEAR_MAX:
			center_bad += 1
			if center_first.is_empty():
				center_first = "pixel(%d,%d) alpha=%.4f" % [px, py, a]
	var padding_count := north_count + south_count
	# 打印原始数字（方案 §6 要求"实测数字"，不能只报 0 违例）。
	print(("[fog-padding] 不变量 3：padding 带 %d 像素（北 %d / 南 %d；world_y ≤ %.2f 或"
			+ " ≥ %.2f；A_max = %.2f wu），最小 alpha = %d/255，违例 %d")
			% [padding_count, north_count, south_count, north_max, south_min,
				float(edges["amax"]), min_alpha, violations])
	print(("[fog-padding] 不变量 3：格网内部格心采样 %d 个（合成表 k=1），其中 alpha>0.02 的"
			+ " %d 个（最大 %.4f）") % [centers.size(), center_bad, center_max])
	if k_img is Image:
		print("[fog-padding] 不变量 3：padding 带的显示用 k 最大值 = %.4f（修复后应为 0）"
				% k_pad_max)

	# ── A：padding 必须完全不透明 ──────────────────────────────────────────────
	_expect(violations == 0,
		("[fog-padding] A: fog alpha >= 254/255 on 100%% of padding pixels"
			+ " (%d violations out of %d, min alpha %d/255, first: %s)")
			% [violations, padding_count, min_alpha, "none" if worst.is_empty() else worst])
	# ── B：内部格心必须透明（否则 A 可以靠"整屏不透明"作弊）────────────────────
	_expect(centers.size() >= 20,
		"[fog-padding] B is non-vacuous: %d interior cell centers are sampled"
			% centers.size())
	_expect(center_bad == 0,
		("[fog-padding] B: fog alpha < 0.02 at 100%% of interior cell centers (k=1 in the"
			+ " synthetic table), so A is not 'the whole screen is opaque'"
			+ " (%d/%d bad, max %.4f, first: %s)")
			% [center_bad, centers.size(), center_max,
				"none" if center_first.is_empty() else center_first])
	# ── C：padding 带必须真的有像素（南北两侧都要有）──────────────────────────
	_expect(padding_count > 0 and north_count > 0 and south_count > 0,
		("[fog-padding] C: the probe rect really crosses both padding edges"
			+ " (north %d px @ world_y ≤ %.2f, south %d px @ world_y ≥ %.2f)")
			% [north_count, north_max, south_count, south_min])
	# ── 成因层：padding 行的显示用 k 必须恒 0（A 的语义来源）────────────────────
	if k_img is Image:
		_expect(k_pad_max < ALPHA_CLEAR_MAX,
			("[fog-padding] padding rows report display k == 0 (max %.4f) — the padding"
				+ " semantics, not just the alpha, survive the fix") % k_pad_max)


## 迷雾场函数约束 2 的 A_max = 显示侧扭曲对采样点的最大位移（世界单位）：
##     A_max = max(√3/2 − band/2, 0)·hex_size，band = clamp(max(fog_field_band, fog_aa))
## 探针 1 像素 = 1 世界单位 ⇒ fog_aa = 2/hex_size·1 = 0.091 < FOG_FIELD_BAND ⇒ band = 0.6。
func _fog_warp_amax() -> float:
	var aa := 2.0 / HEX_SIZE * WORLD_PER_PIXEL
	var band := clampf(maxf(FogOfWarLayer.FOG_FIELD_BAND, aa), 1e-4, 0.86)
	return maxf(1.7320508075688772 * 0.5 - band * 0.5, 0.0) * HEX_SIZE


## padding 带的世界 y 判据（内缩到「采样点一定落在 padding 行」的那一段）。推导：
##   · 分数行 r = 2·y/(3·hex_size)；一个像素的对偶三角形三格的行号是 floor(r) 与
##     floor(r)+1 ⇒ 要三格全在 padding（行号 < 0 或 ≥ map_h），需要
##         r ≤ -1        ⇔ y ≤ -1.5·hex_size = -33
##         r ≥ map_h     ⇔ y ≥ map_h·1.5·hex_size = 132
##     （r = -1 时唯一那个 row 0 格的权重恰为 0，见 fog_cell_k 的 padding 语义）
##   · 显示侧 k 是在**被扭曲过的**采样点上算的，位移上限 A_max ⇒ 再退开 A_max：
##         north_max = -1.5·hex_size - A_max  = -45.45
##         south_min =  map_h·1.5·hex_size + A_max = 144.45
##   ⚠ 这里**不能**按 `world_y < 0` 判：六边形竖直半高 = hex_size（顶点在 y = -22），
##     row 0 的格体一直延伸到 y = -22 —— 那一截是真的地图内格（k=1、本来就该透明），
##     算进 padding 带会让断言 A 假红；断言 B 的格心采样就是它的对照。
##     实测（修复版 shader，vulkan 真后端）：按 `world_y < 0` / `≥ map_h·1.5·hex` 判，
##     34560 个带内像素里报 7844 个"违例"，全部落在 y ∈ [-22, 0) 的 row 0 格体与南缘
##     AA 过渡上 —— 那是假红，不是 bug。所以两条边都按上面推导内缩 A_max。
func _padding_band_edges() -> Dictionary:
	var amax := _fog_warp_amax()
	var row_step := 1.5 * HEX_SIZE
	return {
		"amax": amax,
		"north_max": -row_step - amax,
		"south_min": float(PAD_MAP_H) * row_step + amax,
	}


## 格网内部的格心像素（offset → 世界 → 像素反算，与 pk_hex_tri 的分数 axial 互为逆）。
## 只取 map_h 之内的所有行：padding 世界里的这些格子合成表 k 恒 1。
func _interior_cell_centers(width: int, height: int) -> Array:
	var sqrt3 := 1.7320508075688772
	var out: Array = []
	for row in PAD_MAP_H:
		for col in range(-4, 16):
			var q := float(col) - float(row - (row & 1)) * 0.5
			var wx := sqrt3 * HEX_SIZE * (q + float(row) * 0.5)
			var wy := 1.5 * HEX_SIZE * float(row)
			var px := int(floor((wx - PAD_ORIGIN.x) / WORLD_PER_PIXEL))
			var py := int(floor((wy - PAD_ORIGIN.y) / WORLD_PER_PIXEL))
			if px < 0 or py < 0 or px >= width or py >= height:
				continue
			out.append(Vector2i(px, py))
	return out


# ═══════════════════════════════════════════════════════════════════════════
# C 组场景 / 资产
# ═══════════════════════════════════════════════════════════════════════════

func _real_backend_available() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not String(RenderingServer.get_video_adapter_name()).is_empty()


## 探针场景：1 像素 = 1 世界单位，世界矩形 = origin..origin+size（顶点写世界坐标）。
## 不变量 1/2 传 (ORIGIN, VIEW_W×VIEW_H)，不变量 3 传 padding 世界的矩形。
func _build_probe_scene(material: ShaderMaterial, origin: Vector2,
		size: Vector2) -> SubViewport:
	var viewport := SubViewport.new()
	var pixels := Vector2i(int(round(size.x)), int(round(size.y)))
	viewport.size = pixels
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera2D.new()
	viewport.add_child(camera)
	var quad := MeshInstance2D.new()
	quad.mesh = _world_rect_mesh(origin, size)
	quad.material = material
	viewport.add_child(quad)
	camera.position = origin + size * 0.5
	camera.force_update_scroll()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = viewport.get_texture().get_image()
	_expect(img != null, "[gpu] viewport readback returns an image")
	if img == null:
		return null
	_expect(img.get_width() == pixels.x and img.get_height() == pixels.y,
		"[gpu] readback image is %dx%d (got %dx%d)"
			% [pixels.x, pixels.y, img.get_width(), img.get_height()])
	return viewport


## 世界矩形 —— 与 renderer_map_assets.gd 的 _build_world_quad_mesh() 同一构造
## （顶点 = 世界坐标，1 像素 = 1 世界单位）。
func _world_rect_mesh(origin: Vector2, size: Vector2) -> Mesh:
	var verts := PackedVector2Array([
		origin, origin + Vector2(size.x, 0.0), origin + size, origin + Vector2(0.0, size.y)])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 回读一帧（等 3 帧让图层 _process 推完 uniform + debug 档生效，再等一次绘制完成）。
func _render(viewport: SubViewport) -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


## 合成世界 1：k 条纹（偶数列未探索 / 奇数列可见）+ 一条真实的扭曲场。
## 条纹让"地形判定"与"显示判定"用不同的扭曲 ⇒ 必然出现
## 「地形说这块没探索、迷雾显示却半透明」的像素，约束 3 才有事可做。
func _build_world_stripes() -> WorldData:
	var k_layer := Image.create_empty(MAP_W, MAP_H, false, Image.FORMAT_RGBA8)
	k_layer.fill(Color(0, 0, 0, 0))
	for y in MAP_H:
		for x in MAP_W:
			var k := 0.0 if (x % 2) == 0 else 1.0
			k_layer.set_pixel(x, y, Color(k, 0.0, 0.0, 0.0))
	return _assemble_world(k_layer, Vector2i(MAP_W, MAP_H))


## 合成世界 2：k 恒 1（全可见）—— 不变量 2 用。
func _build_world_all_visible() -> WorldData:
	var k_layer := Image.create_empty(MAP_W, MAP_H, false, Image.FORMAT_RGBA8)
	k_layer.fill(Color(1, 1, 1, 1))
	return _assemble_world(k_layer, Vector2i(MAP_W, MAP_H))


## 合成世界 3：[fog-padding 2026-11-18] 不变量 3 用。
##   · cell_table 只有 PAD_MAP_H = 4 行 ⇒ 探针矩形（240 px 高）能同时跨过 row<0 与
##     row≥map_h 两条 padding 边（96 行的世界里这不可能：3168 wu 远大于 240 px 视口）；
##   · 内部**所有**格子 k = 1 ⇒ 这是断言 A 的对照：同一张图里内部格心必须透明，
##     padding 带必须完全不透明。两边都成立，A 才不是"整屏都不透明"的恒真断言。
func _build_world_padding() -> WorldData:
	var dims := Vector2i(MAP_W, PAD_MAP_H)
	var k_layer := Image.create_empty(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	k_layer.fill(Color(1, 1, 1, 1))
	return _assemble_world(k_layer, dims)


func _assemble_world(k_layer: Image, dims: Vector2i) -> WorldData:
	var layers: Array[Image] = []
	for layer in 4:
		var img := Image.create_empty(dims.x, dims.y, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		layers.append(img)
	layers[2] = k_layer
	var table := Texture2DArray.new()
	table.create_from_images(layers)

	# terrain_surface_tex：0..5 中性，layer6 = 平滑的小振幅扭曲场（RG8 编码）。
	# 幅度换算见契约 §1「warp 解码」：range·hex·amp = 1.6·22·0.4 = 14.08 wu 是满值。
	var surface: Array[Image] = []
	for layer in 7:
		var img := Image.create_empty(VIEW_W, VIEW_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.5, 1.0, 1.0))
		surface.append(img)
	var warp_img: Image = surface[6]
	for j in VIEW_H:
		for i in VIEW_W:
			var wx := float(i) + 0.5
			var wy := float(j) + 0.5
			# 幅度接近编码上限（1.6·22·0.4 = 14.08 wu，见契约 §2）：地形扭曲与迷雾自己的
			# 扭曲（|fog_warp| ≤ A_max = 0.566·hex = 12.4 wu）方向相反时，两边的采样点
			# 可以差出 >1 个 hex 半径 —— 这正是「地形判未探索、显示侧 k 却等于 1」那个
			# 危险组合的构造条件（见下面的 k1_hidden 统计）。
			var wf := Vector2(
				9.5 * sin(wy * 0.0131 + 0.7) + 4.0 * cos(wx * 0.0091),
				8.5 * cos(wx * 0.0077 - 0.4) + 3.5 * sin(wy * 0.0113))
			var bytes := _encode_warp(wf)
			warp_img.set_pixel(i, j, Color(
				float(bytes.x) / 255.0, float(bytes.y) / 255.0, 0.0, 1.0))
	var surface_tex := Texture2DArray.new()
	surface_tex.create_from_images(surface)

	var world := WorldData.new()
	world.cell_table_tex = table
	world.cell_table_dims = dims
	world.cell_table_bound = true
	world.cell_table_layers = 4
	world.terrain_surface_tex = surface_tex
	world.terrain_warp_layer_bound = true
	world.boundary_warp_range = 1.6
	world.visual_tiles = null
	return world


## 世界单位 → RG8 两字节（与契约 §2 / hex_cell_field.gdshaderinc:113-125 的解码互逆）。
func _encode_warp(warp_world: Vector2) -> Vector2i:
	var denom := maxf(1.6 * HEX_SIZE * MapBaker.WARP_AMP, 1e-4)
	var v := Vector2(clampf(warp_world.x / denom, -1.0, 1.0),
		clampf(warp_world.y / denom, -1.0, 1.0))
	return Vector2i(int(round((v.x * 0.5 + 0.5) * 255.0)),
		int(round((v.y * 0.5 + 0.5) * 255.0)))


## 地形材质替身：图层只从它读 fog_early_out_enabled / fog_early_out_k 两个**实际值**
## （renderer_scene_services.gd:664-665 推的就是这两条），所以替身只要带着它们。
func _build_host_material(early_out: bool, early_k: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(0.0); }\n"
	mat.set_shader_parameter("fog_early_out_enabled", early_out)
	mat.set_shader_parameter("fog_early_out_k", early_k)
	return mat


# ═══════════════════════════════════════════════════════════════════════════
# HexRenderer 的替身：只提供 FogOfWarLayer._cell_field_host() 的识别面
# （_wrap_period_x / _push_world_uniform）+ _cell_field_active(host) 读到的字段。
# ═══════════════════════════════════════════════════════════════════════════

class _FakeFogHost extends Node:
	var terrain_cell_field_enabled: bool = true
	var visual_quality: int = 0
	var _mobile_quality_tier_define: String = ""
	var _world: WorldData = null
	var _map = null
	var _shader_mat: ShaderMaterial = null
	var split_land_water_passes: bool = false
	var _split_program_failed: bool = false

	func _wrap_period_x() -> float:
		return 0.0

	func _push_world_uniform(_key: Variant, _value: Variant) -> void:
		pass


# ═══════════════════════════════════════════════════════════════════════════
# 源码预处理器（从 tests/world/terrain_shader_variant_test.gd::_expand_shader 复制，
# 只服务本文件的"源码缺席"断言；复制而不是引用，是为了不修改别人的测试文件）
# ═══════════════════════════════════════════════════════════════════════════

func _expand_shader(path: String, defines: Dictionary, follow_includes: bool = true) -> String:
	var out: Array = []
	_expand_into(path, defines.duplicate(), out, 0, follow_includes)
	return "\n".join(out)


func _expand_into(path: String, defines: Dictionary, out: Array, depth: int,
		follow_includes: bool) -> void:
	if depth > 16:
		return
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return
	var text := _strip_shader_comments(raw.replace("\r\n", "\n").replace("\r", "\n"))
	var stack: Array = []
	for line in text.split("\n"):
		var trimmed := String(line).strip_edges()
		var active := true
		if not stack.is_empty():
			active = bool(stack[stack.size() - 1]["active"])
		if not trimmed.begins_with("#"):
			if active:
				out.append(line)
			continue
		var body := trimmed.substr(1).strip_edges()
		var head := body
		var rest := ""
		var sep := body.find(" ")
		if sep >= 0:
			head = body.substr(0, sep)
			rest = body.substr(sep + 1).strip_edges()
		match head:
			"ifdef":
				_push_cond(stack, active, defines.has(rest), false)
			"ifndef":
				_push_cond(stack, active, not defines.has(rest), false)
			"if":
				var cond_value := _eval_cond(rest, defines)
				_push_cond(stack, active, cond_value != 0, cond_value < 0)
			"elif":
				if stack.is_empty():
					continue
				var elif_frame: Dictionary = stack[stack.size() - 1]
				if bool(elif_frame["union"]) or not bool(elif_frame["parent"]):
					continue
				if bool(elif_frame["taken"]):
					elif_frame["active"] = false
				var elif_value := _eval_cond(rest, defines)
				if elif_value < 0:
					elif_frame["union"] = true
					elif_frame["active"] = true
				else:
					elif_frame["active"] = elif_value != 0
					elif_frame["taken"] = elif_value != 0
			"else":
				if stack.is_empty():
					continue
				var else_frame: Dictionary = stack[stack.size() - 1]
				if bool(else_frame["union"]):
					else_frame["active"] = bool(else_frame["parent"])
				elif bool(else_frame["taken"]):
					else_frame["active"] = false
				else:
					else_frame["active"] = bool(else_frame["parent"])
					else_frame["taken"] = true
			"endif":
				if not stack.is_empty():
					stack.pop_back()
			"include":
				if active and follow_includes:
					var inc := rest.trim_prefix("\"").trim_suffix("\"")
					if inc.begins_with("res://"):
						_expand_into(inc, defines, out, depth + 1, follow_includes)
			"define":
				if active and not rest.is_empty():
					defines[rest.split(" ")[0]] = true
			"undef":
				if active:
					defines.erase(rest)
			_:
				pass


func _push_cond(stack: Array, parent_active: bool, taken: bool, unknown: bool) -> void:
	stack.append({
		"parent": parent_active,
		"taken": false if unknown else taken,
		"union": unknown,
		"active": parent_active if unknown else (parent_active and taken),
	})


## 只求值 `defined(X)` / `!defined(X)` / `&&` / `||` 的组合；认不出的表达式返回 -1
## （调用方按"两支都算"的保守并集处理 ⇒ 缺席断言不会被蒙成恒真）。
func _eval_cond(expr: String, defines: Dictionary) -> int:
	var text := expr.strip_edges()
	if text.is_empty():
		return -1
	var unknown := false
	for part in text.split("||"):
		var chunk := String(part).strip_edges()
		if chunk.begins_with("defined("):
			var name := chunk.substr(8).trim_suffix(")").strip_edges()
			if not defines.has(name):
				return -1
			continue
		if chunk.begins_with("!defined("):
			var name2 := chunk.substr(9).trim_suffix(")").strip_edges()
			if not defines.has(name2):
				return -1
			continue
		unknown = true
	return -1 if unknown else 1


func _strip_shader_comments(text: String) -> String:
	var guarded := text.replace("res://", "res:\u0001~~")
	var block := RegEx.new()
	block.compile("(?s)/\\*.*?\\*/")
	var without_block: String = block.sub(guarded, "", true)
	var line_comment := RegEx.new()
	line_comment.compile("//[^\n]*")
	var stripped: String = line_comment.sub(without_block, "", true)
	return stripped.replace("res:\u0001~~", "res://")


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
