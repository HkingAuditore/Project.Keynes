extends SceneTree
## [cell-field 2026-11-18] GPU ↔ CPU 解析格界（cell field）**逐像素** parity 探针。
##
## ── 它补的是哪个洞（review 2026-11-18 原话）─────────────────────────────
## 「没有任何测试验证 GPU 和 CPU 用的是同一个坐标系。」44 条 parity 测试比的是 CPU
## 镜像与 C++ cube_round（同一个公式），debug view 18 比的是「重心 argmax」与「由坐标
## 反算的最近格心」（GPU 自己和自己比）。如果 `world_origin` / `hex_size` 这类 uniform
## 推错了，或者 `v_world` 与 `HexUtils` 原点差半格，整张地图会整体错位，而 400 多条
## 断言照样全绿。
##
## 本探针把 shader 算出的 dom offset **编码成颜色**（debug view 22）从真实渲染后端
## 回读，在 CPU 上逐像素与 `DCHexCellField.dom_at()` 对撞 —— 这是「GPU 与 CPU 用同一个
## 坐标系」的直接证据，不是自洽检查。
##
## ── 用法（**必须带真实渲染后端**，`--headless` 是 dummy 渲染器、读不回像素）──────
##   godot --path . --rendering-driver opengl3 -s res://tests/world/cell_field_gpu_parity_probe.gd
##   godot --path . --rendering-driver vulkan  -s res://tests/world/cell_field_gpu_parity_probe.gd
## headless 下打印一行 `SKIPPED` 并 exit 0；但只要后端可用就必须给出真实结论。
##
## ── 像素 ↔ 世界坐标的映射（本探针的立论，必须与生产一致）──────────────────
## 生产链（每条都带证据行号）：
##   `scripts/rendering/renderer_map_assets.gd:5-30` `_build_world_quad_mesh()`：
##     四条顶点 = `bounds.position` 与 `bounds.position + bounds.size`（wrap 时 x 换成
##     `[0, wrap_period_x]`，再复制到 ±wrap 两份 tile）；
##   `scripts/rendering/renderer_scene_services.gd:91-94`：`MeshInstance2D.new()` 直接
##     `add_child()`，**不设 position / transform**（MeshInstance2D 也没有 offset 属性）
##     ⇒ mesh 顶点坐标就是世界坐标；
##   `shaders/world_map.gdshader:411-413` `vertex()`：
##     `v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy` ⇒ v_world 就是插值出来的
##     世界坐标；
##   `scripts/rendering/renderer_material_publish.gd:394-398`：
##     `world_origin ← world_bounds.position`、`world_size ← world_bounds.size`、
##     `hex_size ← host.hex_size`、`wrap_origin_x ← 0.0`、
##     `wrap_period_x ← host._wrap_period_x()`（= `HexUtils.wrap_period_x(map.width, hex_size)`）。
##   ⇒ 像素中心的世界坐标 = `world_origin + 像素uv * world_size`；UV 的像素中心是
##      `(i+0.5)/W`，与 C++ 烘焙 `gdext/src/world_ext_bake.cpp:1501,1505`
##      `origin_y + (pixel + 0.5) * step` 是**同一约定**。
##
## 本探针照抄这条约定：**1 像素 = 1 世界单位**（`WORLD_PER_PIXEL = 1.0`），quad 顶点直接
## 用世界坐标，Camera2D 把这块世界矩形对到视口上，并把 `world_origin` / `world_size`
## 设成同一块矩形 —— 于是 shader 里的 uv 与生产同义。
## 「像素中心 = +0.5」这一条由 `tests/world/terrain_shader_variant_test.gd` 从
## **C++ 源码**与本文件的映射表达式两侧对账（frame invariant，不需要 GPU）。
##
## ── 四个 pass ───────────────────────────────────────────────────────────
##   A 关回绕：view 22 → 逐像素解码 dom offset 与 `DCHexCellField.dom_at()` 比，要求
##     可达像素 100% 一致（见下面的「数值可判定性」）。
##   B 开回绕：`wrap_period_x = map_w·√3·hex_size`，矩形跨过 x=0 的经线接缝，重复 A 的
##     比对（col 按 map_w 取模），并断言没有任何像素的偏差超出数值容差。
##   C 接缝回归（刚修好的 AA bug）：`terrain_ecotone_width = 0.02` 让 AA 项主导，
##     view 23 → `max(band) < 0.10`。旧代码把 `fwidth` 取在**已回绕**坐标上，
##     接缝那一列会被顶到 `PK_FIELD_BAND_MAX = 0.86`，这条立刻失败。
##   D 扭曲场 + uniform 映射：给 `terrain_surface_tex` layer6 烘一张逐像素 warp 场并
##     打开 `terrain_warp_layer_bound`，用 CPU 解码同一批字节后重算 dom。
##     **A/B 都不受 `world_origin` / `world_size` 影响**（无 warp 时场函数只用 v_world），
##     所以「uniform 推错」这一半只能靠 D 抓：uv 一旦算错，采到的 warp 就错，dom 就错。
##
## ── 断言口径：严格 100%，不做"容差放行"──────────────────────────────────
## GPU 用 float32、CPU 镜像用 float64，同一个像素的 `w_raw` 两边差 ~1e-6（接缝区因为
## 周期常数是 float32 而略大，实测 ≤ ~1e-5）。断言**要求 100%**（review 原话：
## 「If it is not 100 %, do NOT loosen the assertion」）。
## 为了失败时能一眼分清"真错位"和"最后一位差异"，探针把不一致像素按前两名权重差
## `margin = w_max − w_2nd` 分成两档**只用于报告**：
##   `hard` —— margin ≥ TIE_EPS(1e-3) 的像素：说明坐标系/映射/公式真的错了；
##   `tie`  —— margin < TIE_EPS 的像素：落在数值不可判定带上（谁赢取决于最后一位）。
## 两者都必须 0；`min top-2 margin` 每 pass 打印一次，用来表明"这条 100% 比对有多
## 接近数值边界"（Pass D 实测最小 margin = 1e-6，仍 100% 一致）。
## 任何真实的映射错误（原点差半格 / hex_size 半格 / wrap 周期错 / posmod 错）都会让
## 上万个 hard 像素变红，不可能被这套口径吸收。

const FieldScript = preload("res://scripts/geography/hex_cell_field.gd")
const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")
const SHADER_PATH := "res://shaders/world_map.gdshader"

# ── 探针尺度（小地图：只用来证明坐标系，不追求覆盖全图）────────────────────
const VIEW_W := 320
const VIEW_H := 240
const WORLD_PER_PIXEL := 1.0      # 1 像素 = 1 世界单位（见文件头的映射推导）
const HEX_SIZE := 22.0            # = HexRenderer.hex_size 的默认值
const MAP_W := 96                 # cell_table / posmod 的列数
const MAP_H := 96                 # 行数（探针的采样矩形完全落在 [0, MAP_H) 行内）
const WRAP_ORIGIN_X := 0.0        # 与 renderer_material_publish.gd:397 同值

# Pass A/D 的世界矩形原点：x 跨过 0（把负列喂给 pk_posmod），y 从 0 开始（row ≥ 0）。
const PASS_A_ORIGIN := Vector2(-131.31, 0.0)
# Pass B/C 的世界矩形原点：与周期 3658.15 相比，x ∈ [-160, 160] 正好骑在 x = 0 的接缝上。
const PASS_B_ORIGIN := Vector2(-160.37, 0.0)

const VIEW_DOM_ENCODE := 22       # world_map.gdshader 的 debug view 22
const VIEW_BAND := 23             # world_map.gdshader 的 debug view 23

const ECOTONE_DEFAULT := 0.84     # = uniforms.gdshaderinc 的 terrain_ecotone_width 默认值
const ECOTONE_SMALL := 0.02       # Pass C：让 AA 项主导
const BAND_MAX := 0.86            # = PK_FIELD_BAND_MAX（shader / CPU 镜像同值）
const VISUAL_QUALITY_LOW := 0     # terrain_edge_screen_width_px() 在 LOW 档 = 1.00

## 数值不可判定带（见文件头）。实测 GPU/CPU 的 w_raw 差 ≤ ~1e-5，取 1e-3 = 50~100×。
const TIE_EPS := 1e-3

var _checks := 0
var _failures := 0

var _viewport: SubViewport
var _camera: Camera2D
var _quad: MeshInstance2D
var _material: ShaderMaterial
var _shader: Shader
var _prefix_note := ""

var _cell_table: Texture2DArray
var _surface_tex: Texture2DArray
## 只用来取 `boundary_warp_range` 的默认值（与 production 读的同一个字段）。
var _world_frame: WorldData = WorldData.new()
## 逐像素 warp（世界单位）；Pass D 用。索引 = j * VIEW_W + i。
var _warp_pixels := PackedVector2Array()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[cell-field-gpu-parity] display=%s rendering_method=%s adapter=%s" % [
			DisplayServer.get_name(), RenderingServer.get_current_rendering_method(),
			RenderingServer.get_video_adapter_name()])
	if not _real_backend_available():
		print("[cell-field-gpu-parity] SKIP 本探针需要真实渲染后端（headless 用 dummy 渲染器，"
				+ "读不回像素）。请改用：")
		print("[cell-field-gpu-parity]   godot --path . --rendering-driver opengl3 "
				+ "-s res://tests/world/cell_field_gpu_parity_probe.gd")
		print("[cell-field-gpu-parity]   godot --path . --rendering-driver vulkan "
				+ "-s res://tests/world/cell_field_gpu_parity_probe.gd")
		print("=== cell field gpu parity: SKIPPED (needs a real rendering backend) ===")
		quit(0)
		return

	_build_variant()
	_build_assets()
	var scene_ok: bool = await _build_scene()
	if not scene_ok:
		print("=== cell field gpu parity: %d checks, %d failures ===" % [_checks, _failures])
		quit(1)
		return

	# ── Pass A：关回绕 ────────────────────────────────────────────────────
	var image_a := await _render(PASS_A_ORIGIN, 0.0, ECOTONE_DEFAULT, VIEW_DOM_ENCODE, false)
	if image_a != null:
		_compare_dom("Pass A (no wrap)", image_a, PASS_A_ORIGIN, 0.0, false)

	# ── Pass B：开回绕，矩形跨接缝 ────────────────────────────────────────
	# 比的是**按 map_w 取模后的 col**：GPU 的 pk_posmod(col, pk_cell_map_w) 与 CPU 镜像
	# 的 posmod_int(col, map_w) 是同一个取模（两侧 col 都落在 [0, map_w)），所以逐像素
	# 相等就是"取模后相等"。row 不取模（只有 col 横向回绕）。
	var wrap_period := HexUtils.wrap_period_x(MAP_W, HEX_SIZE)
	var image_b := await _render(PASS_B_ORIGIN, wrap_period, ECOTONE_DEFAULT,
			VIEW_DOM_ENCODE, false)
	if image_b != null:
		_compare_dom("Pass B (wrap+seam)", image_b, PASS_B_ORIGIN, wrap_period, false)

	# ── Pass C：接缝 AA 回归（view 23）───────────────────────────────────
	var image_c := await _render(PASS_B_ORIGIN, wrap_period, ECOTONE_SMALL, VIEW_BAND, false)
	if image_c != null:
		_check_band(image_c)

	# ── Pass D：扭曲场 + world_origin/world_size → uv 映射 ────────────────
	# A/B 的 dom 只由 v_world 决定，**不看** world_origin / world_size（无 warp 时
	# 场函数一个都不用）；这两个 uniform 只影响 pk_boundary_warp_world() 的采样 uv。
	# 所以「uniform 推错」这一半必须靠 D：uv 一旦算错，采到的 warp 就错，dom 就错。
	var image_d := await _render(PASS_A_ORIGIN, 0.0, ECOTONE_DEFAULT, VIEW_DOM_ENCODE, true)
	if image_d != null:
		_compare_dom("Pass D (warp field)", image_d, PASS_A_ORIGIN, 0.0, true)

	print("=== cell field gpu parity: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ─────────────────────────────────────────────────────────────────────────
# 后端 / 变体 / 资产
# ─────────────────────────────────────────────────────────────────────────

## dummy（headless）渲染器读不回像素：DisplayServer 名字就是 headless，且拿不到适配器名。
func _real_backend_available() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not String(RenderingServer.get_video_adapter_name()).is_empty()


## 用**真实的前缀拼装函数**（RendererShaderWater._apply_shader_variant_prefix）搭变体，
## 而不是抄一份前缀：这条探针的意义就是「测真的会跑的那份 program」。
##
## [cell-field-web 2026-11-18] Compatibility 后端（`--rendering-driver opengl3` 在桌面上
## 就是 gl_compatibility）现在**也走真实拼装**：W6 之后 8 槽预算已经装得下 `cell_table`
## （旧三槽从声明里退役，实测 8 → 6），唯一的门槛变成 **boot 自检结论**。所以这里先把
## Engine meta 钉成 `pass`（等价于「自检已经跑过且通过」），再调真实拼装 ——
## 于是两个后端走的是**同一条** `_apply_shader_variant_prefix`，不再有「探针手工补一个
## define」的旁路（那种写法测的不是生产路径，而且 `_expect(true, …)` 是恒真断言）。
## 结束时不还原 meta：SceneTree 脚本一个进程只跑一次，不污染别的测试。
func _build_variant() -> void:
	var host = _ProbeShaderHost.new()
	host.terrain_cell_field_enabled = true
	host.terrain_surface_debug_view = VIEW_DOM_ENCODE
	host.visual_quality = VISUAL_QUALITY_LOW
	# 钉住 boot 结论（未判定时受限平台一律不启用，见 cell_field_boot_allows）。
	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
	var template := Shader.new()
	template.code = FileAccess.get_file_as_string(SHADER_PATH)
	var variant: Shader = RendererShaderWaterScript._apply_shader_variant_prefix(
		host, template, SHADER_PATH)
	if variant == null:
		_expect(false, "prefix assembly returns a shader")
		return
	var code := String(variant.code)
	# 注意判据是 `#define PK_CELL_FIELD`，不是裸宏名：world_map.gdshader 自己就有
	# `#ifdef PK_CELL_FIELD` 之类的行，用裸名字判断会让"没注入 define"也过。
	_expect(code.contains("#define PK_CELL_FIELD"),
		"real shipped prefix carries PK_CELL_FIELD once the boot verdict is pass")
	_prefix_note = "real shipped prefix (boot verdict latched to pass)"
	_shader = variant
	_material = ShaderMaterial.new()
	_material.shader = _shader
	_expect(code.contains("#define PK_CELL_FIELD"),
		"variant carries PK_CELL_FIELD (%s)" % _prefix_note)
	_expect(not _shader.get_shader_uniform_list().is_empty(),
		"PK_CELL_FIELD world_map variant compiles in the shader language (%d uniforms)"
			% _shader.get_shader_uniform_list().size())
	var names := {}
	for entry in _shader.get_shader_uniform_list():
		names[String(entry.get("name", ""))] = true
	_expect(names.has("cell_table") and names.has("terrain_warp_range"),
		"variant exposes the cell-field uniforms (cell_table / terrain_warp_range)")


## cell_table（offset 空间 3 层）+ terrain_surface_tex（7 层，layer6 = warp）。
## cell_table 只有 class / aux 两个通道被场路径读：R=biome（2 = 陆地，保证走陆地管线
## 不会 discard）、aux.R=fog_k=1.0（= 完全可见，别让迷雾出口盖掉 debug 输出）。
func _build_assets() -> void:
	var layers: Array[Image] = []
	for layer in 3:
		var img := Image.create_empty(MAP_W, MAP_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		layers.append(img)
	var cls: Image = layers[0]
	var aux: Image = layers[2]
	for y in MAP_H:
		for x in MAP_W:
			cls.set_pixel(x, y, Color(2.0 / 255.0, 0.0, 0.0, 0.0))
			aux.set_pixel(x, y, Color(1.0, 0.0, 0.0, 0.0))
	_cell_table = Texture2DArray.new()
	_cell_table.create_from_images(layers)

	# terrain_surface_tex：0..5 中性（本探针只读 layer4.r（被解析 gap 覆盖）与 layer6），
	# layer6 = 逐像素 warp 的 RG8 编码（Pass D 打开 terrain_warp_layer_bound 才生效）。
	_warp_pixels.resize(VIEW_W * VIEW_H)
	var surface: Array[Image] = []
	for layer in 7:
		var img := Image.create_empty(VIEW_W, VIEW_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.5, 1.0, 1.0))
		surface.append(img)
	var warp_img: Image = surface[6]
	for j in VIEW_H:
		for i in VIEW_W:
			# 平滑、幅度远小于解码上限（range·hex·amp = 14.08 wu）的扭曲场。
			var wx := float(i) + 0.5
			var wy := float(j) + 0.5
			var warp := Vector2(
				3.1 * sin(wy * 0.0131 + 0.7) + 1.7 * cos(wx * 0.0091),
				2.9 * cos(wx * 0.0077 - 0.4) + 1.3 * sin(wy * 0.0113))
			var bytes := FieldScript.encode_warp_world(warp, HEX_SIZE)
			# 单位换算：第 (i, j) 个 texel 就是第 (i, j) 个像素（1 texel = 1 世界单位）。
			warp_img.set_pixel(i, j, Color(
				float(bytes.x) / 255.0, float(bytes.y) / 255.0, 0.0, 1.0))
			_warp_pixels[j * VIEW_W + i] = FieldScript.decode_warp_byte(
				bytes.x, bytes.y, HEX_SIZE)
	_surface_tex = Texture2DArray.new()
	_surface_tex.create_from_images(surface)


## 世界矩形 [origin, origin + (W,H)·WORLD_PER_PIXEL] 的四条顶点 —— 与
## renderer_map_assets.gd:5-30 的 _build_world_quad_mesh() 同一构造（只是把
## world_bounds 换成探针自己的矩形，1 像素 = 1 世界单位）。**每个 pass 都按自己的
## 矩形重建**：顶点一旦留在上一个 pass 的坐标上，屏幕边缘就会露出清屏色
## （第一版探针就踩了这个坑：Pass B 左边 29 列全是 clear color）。
func _build_world_rect_mesh(origin: Vector2) -> Mesh:
	var size := Vector2(float(VIEW_W), float(VIEW_H)) * WORLD_PER_PIXEL
	var verts := PackedVector2Array([
		origin, origin + Vector2(size.x, 0.0), origin + size, origin + Vector2(0.0, size.y)])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_scene() -> bool:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(VIEW_W, VIEW_H)
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_camera = Camera2D.new()
	_viewport.add_child(_camera)
	_quad = MeshInstance2D.new()
	_quad.mesh = _build_world_rect_mesh(PASS_A_ORIGIN)
	_quad.material = _material
	_viewport.add_child(_quad)
	# 静止配置：所有 pass 复用同一块 material / 同一个节点，只改 camera / uniform
	# （生产同理：quad 顶点=世界坐标，world_origin/world_size 跟着 bounds 走）。
	_apply_uniforms(PASS_A_ORIGIN, 0.0, ECOTONE_DEFAULT, VIEW_DOM_ENCODE, false)
	_camera.position = PASS_A_ORIGIN + Vector2(float(VIEW_W), float(VIEW_H)) * 0.5
	_camera.force_update_scroll()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	if img == null:
		_expect(false, "viewport texture readback returns an image")
		return false
	_expect(img.get_width() == VIEW_W and img.get_height() == VIEW_H,
		"readback image is %dx%d (got %dx%d)" % [
			VIEW_W, VIEW_H, img.get_width(), img.get_height()])
	return true


# ─────────────────────────────────────────────────────────────────────────
# 渲染
# ─────────────────────────────────────────────────────────────────────────

## uniform / 相机 / quad 顶点一次设好，等 3 帧 + frame_post_draw 后回读。
## 相机中心 = origin + 视口尺寸/2 ⇒ 像素 (i,j) 的中心横跨世界点
## origin + (i + 0.5, j + 0.5)·WORLD_PER_PIXEL（与 C++ 的 +0.5 约定同源）。
func _render(origin: Vector2, wrap_period: float, ecotone: float, view: int,
		warp_on: bool) -> Image:
	_apply_uniforms(origin, wrap_period, ecotone, view, warp_on)
	_quad.mesh = _build_world_rect_mesh(origin)
	var size := Vector2(float(VIEW_W), float(VIEW_H)) * WORLD_PER_PIXEL
	_camera.position = origin + size * 0.5
	_camera.force_update_scroll()
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	if img == null:
		_expect(false, "readback returns an image (view %d)" % view)
	return img


## 场路径需要的 uniform 全在这儿。**只有这些**：场的 dom/band 不读任何像素级纹理，
## cell_table / terrain_surface_tex 只是为了让 material 有效（sampler 必须绑上）。
func _apply_uniforms(origin: Vector2, wrap_period: float, ecotone: float, view: int,
		warp_on: bool) -> void:
	var size := Vector2(float(VIEW_W), float(VIEW_H)) * WORLD_PER_PIXEL
	_material.set_shader_parameter("world_origin", origin)
	_material.set_shader_parameter("world_size", size)
	_material.set_shader_parameter("hex_size", HEX_SIZE)
	_material.set_shader_parameter("wrap_period_x", wrap_period)
	_material.set_shader_parameter("wrap_origin_x", WRAP_ORIGIN_X)
	_material.set_shader_parameter("terrain_ecotone_width", ecotone)
	_material.set_shader_parameter("terrain_ecotone_noise", 0.0)
	_material.set_shader_parameter("terrain_surface_debug_view", view)
	_material.set_shader_parameter("cell_table", _cell_table)
	_material.set_shader_parameter("cell_table_size", Vector2(float(MAP_W), float(MAP_H)))
	_material.set_shader_parameter("cell_table_bound", true)
	_material.set_shader_parameter("terrain_surface_tex", _surface_tex)
	_material.set_shader_parameter("terrain_surface_layer_count", 7)
	_material.set_shader_parameter("terrain_edge_layers_bound", true)
	_material.set_shader_parameter("terrain_static_baked", true)
	# 扭曲场：Pass D 才绑真实 layer6；其余 pass 走「未烘」分支（pk_boundary_warp_world
	# 直接返回 0），与 CPU 侧传 Vector2.ZERO 一致。
	_material.set_shader_parameter("terrain_warp_layer_bound", warp_on)
	# 与生产同源：terrain_warp_range ← WorldData.boundary_warp_range（C++ PK_WARP_RANGE
	# 的镜像，renderer_material_publish.gd:413 / renderer_lighting_bindings.gd:127），
	# terrain_warp_amp ← MapBaker.WARP_AMP（renderer_material_publish.gd:414）。
	_material.set_shader_parameter("terrain_warp_range", _world_frame.boundary_warp_range)
	_material.set_shader_parameter("terrain_warp_amp", MapBaker.WARP_AMP)
	# 与生产一致的画质档（决定 terrain_edge_screen_width_px() = 1.00）。
	_material.set_shader_parameter("visual_quality", VISUAL_QUALITY_LOW)
	_material.set_shader_parameter("pixel_world_size", WORLD_PER_PIXEL)
	# 迷雾必须完全可见，否则 fog 出口会盖掉 debug 输出（cell_table aux.R 已给 1.0，
	# 这里再明确关掉早退，让结论不依赖 aux 内容）。
	_material.set_shader_parameter("fog_early_out_enabled", false)
	_material.set_shader_parameter("has_flow_tex", false)
	_material.set_shader_parameter("terrain_material_tex_bound", false)


# ─────────────────────────────────────────────────────────────────────────
# 比对
# ─────────────────────────────────────────────────────────────────────────

## 解码 view 22：R,G = col 低/高字节，B = row 低字节，A 恒 1.0。
## ⚠ 与「B,A = row 低/高字节」的差别只在 A：canvas_item 是
## `render_mode blend_mix`（world_map.gdshader:8），alpha = 0 的片元在 MIX 下
## `dst = src.rgb·src.a + dst·(1−src.a)` ⇒ rgb 也被乘成 0，回读就是 viewport 的清屏色
## （与"什么都没画"完全无法区分；第一版视图正是这么踩的坑）。row ∈ [0,255) 时高字节
## 本来就是 0，所以 shader 侧把 A 固定成 1.0 既保住可回读性，也保住 row 的精确性
## （超出 [0,255] 的 row —— padding 行 —— 不在本探针的采样矩形里）。
func _decode_dom(c: Color) -> Vector2i:
	var col := int(round(c.r * 255.0)) | (int(round(c.g * 255.0)) << 8)
	var row := int(round(c.b * 255.0))
	return Vector2i(col, row)


## 逐像素：GPU 解码出来的 dom offset vs `DCHexCellField.field_at()`。
func _compare_dom(label: String, image: Image, origin: Vector2, wrap_period: float,
		use_warp: bool) -> void:
	var total := VIEW_W * VIEW_H
	var hard := 0
	var tie := 0
	var wrapped := 0
	var first_hard := ""
	var first_tie := ""
	var distinct := {}
	var alpha_bad := 0
	var warp_changed := 0
	var min_margin := 1.0e9
	for j in VIEW_H:
		for i in VIEW_W:
			var c := image.get_pixel(i, j)
			if int(round(c.a * 255.0)) != 255:
				alpha_bad += 1
			var gpu := _decode_dom(c)
			distinct[gpu] = true
			# 像素中心的世界坐标：与 C++ 烘焙 / quad 顶点插值同一约定（+0.5）。
			var wp := origin + Vector2(float(i) + 0.5, float(j) + 0.5) * WORLD_PER_PIXEL
			var wp_wrapped := wp
			if wrap_period > 0.0001:
				# 与 shader 的 wrap_world_pos()（uniforms.gdshaderinc:212-221）同一语法：
				# mod 走 floor 语义（GLSL mod / GDScript fposmod 都是）。
				wp_wrapped = Vector2(
					fposmod(wp.x - WRAP_ORIGIN_X, wrap_period) + WRAP_ORIGIN_X, wp.y)
				if absf(wp_wrapped.x - wp.x) > 0.0001:
					wrapped += 1
			var warp := _warp_pixels[j * VIEW_W + i] if use_warp else Vector2.ZERO
			var field: Dictionary = FieldScript.field_at(
				wp_wrapped, HEX_SIZE, warp, ECOTONE_DEFAULT, MAP_H, MAP_W)
			var cpu := FieldScript.cell_offset(field, int(field["dom"]))
			if use_warp:
				var no_warp: Dictionary = FieldScript.field_at(
					wp_wrapped, HEX_SIZE, Vector2.ZERO, ECOTONE_DEFAULT, MAP_H, MAP_W)
				if FieldScript.cell_offset(no_warp, int(no_warp["dom"])) != cpu:
					warp_changed += 1
			var margin := _top2_margin(field)
			min_margin = minf(min_margin, margin)
			var same: bool = gpu.x == cpu.x and gpu.y == cpu.y
			if same:
				continue
			if margin < TIE_EPS:
				tie += 1
				if first_tie.is_empty():
					first_tie = "pixel(%d,%d) world=(%.4f,%.4f) gpu=%s cpu=%s margin=%.9f" % [
						i, j, wp.x, wp.y, str(gpu), str(cpu), margin]
			else:
				hard += 1
				if first_hard.is_empty():
					first_hard = "pixel(%d,%d) world=(%.4f,%.4f) gpu=%s cpu=%s margin=%.4f" % [
						i, j, wp.x, wp.y, str(gpu), str(cpu), margin]
	if use_warp:
		_expect(warp_changed * 100 >= total,
			"%s: the warp field really changed >=1%% of the dom labels (%d/%d)"
				% [label, warp_changed, total])
	if wrap_period > 0.0001:
		_expect(wrapped > total / 4,
			"%s: rectangle straddles the seam and really wraps (%d/%d pixels wrapped)"
				% [label, wrapped, total])
	_expect(alpha_bad == 0,
		"%s: offset encoding survives the RGBA8 target (alpha=255 on %d/%d pixels;"
			% [label, total - alpha_bad, total]
			+ " blend_mix would zero every channel when alpha is 0)")
	_expect(distinct.size() >= 20,
		"%s: readback carries a real dom field, not a constant (%d distinct cells)"
			% [label, distinct.size()])
	# 采样点阵的最小判定余量：这是「100% 逐像素比对在数值上可判定」的**先行条件**。
	# 只打印不断言 —— 它报告的是"这条断言有多容易被 float32/float64 的最后一位左右"，
	# 不是被测代码的性质。
	print("[cell-field-gpu-parity] %s: min top-2 w_raw margin over the lattice = %.6f"
			% [label, min_margin])
	# **严格 100%**：不因为 margin 小就放过任何一个像素（review 要求「100% match，
	# 发现不一致就去查映射或 shader，不许放宽」）。失败时的消息把 hard / tie-band
	# 分开报：hard > 0 = 真的错位了；只有 tie-band > 0 = 落在数值不可判定带上
	# （float32 GPU vs float64 CPU 的最后一位差异），此时 first 里带着 margin 供判断。
	# 实测：vaulkan 与 opengl3 两个后端的四个 pass 都是 0 hard、0 tie-band。
	var first_bad := first_hard if not first_hard.is_empty() else first_tie
	_expect(hard == 0 and tie == 0,
		"%s: GPU dom == DCHexCellField.dom_at on 100%% of the %d-pixel lattice"
			% [label, total] + " (%d hard, %d tie-band mismatch; first: %s)" % [
				hard, tie, "none" if first_bad.is_empty() else first_bad])


## 前两名 w_raw 之差。dom 只在它跨 0 时翻转，所以它同时是「这个像素的判定余量」。
func _top2_margin(field: Dictionary) -> float:
	var w: Vector3 = field["w_raw"]
	var hi := maxf(w.x, maxf(w.y, w.z))
	var lo := minf(w.x, minf(w.y, w.z))
	var mid := w.x + w.y + w.z - hi - lo
	return hi - mid


## Pass C：view 23 输出 band / 0.86。
func _check_band(image: Image) -> void:
	var total := VIEW_W * VIEW_H
	var max_band := -1.0
	var min_band := 2.0
	var bands := PackedFloat32Array()
	bands.resize(total)
	for j in VIEW_H:
		for i in VIEW_W:
			var band := image.get_pixel(i, j).r * BAND_MAX
			bands[j * VIEW_W + i] = band
			max_band = maxf(max_band, band)
			min_band = minf(min_band, band)
	bands.sort()
	var median := bands[total / 2]
	# AA 项 = 2/hex_size · max(|fwidth(v_world)|) · terrain_edge_screen_width_px()
	#      = 2/22 · 1 · 1.00 = 0.0909（1 像素 = 1 世界单位，LOW 档宽度 1.00）。
	var expected_aa := 2.0 / HEX_SIZE * WORLD_PER_PIXEL * 1.0
	print("[cell-field-gpu-parity] Pass C band: min=%.4f median=%.4f max=%.4f"
			% [min_band, median, max_band] + " expected AA term=%.4f" % expected_aa)
	_expect(max_band < 0.10,
		"Pass C (seam regression): max band %.4f < 0.10 — with the pre-fix code"
			% max_band
			+ " (fwidth taken on the WRAPPED coordinate) the seam column's derivative"
			+ " explodes and band clamps to PK_FIELD_BAND_MAX = 0.86, i.e. this fails")
	_expect(median > 0.0,
		"Pass C: median band %.4f > 0, so the max-band assertion is not vacuous"
			% median)
	_expect(absf(max_band - expected_aa) < 0.02,
		"Pass C: measured band %.4f tracks the documented AA term 2/hex·1px·1.00 = %.4f"
			% [max_band, expected_aa])


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


# ─────────────────────────────────────────────────────────────────────────
# RendererShaderWater._apply_shader_variant_prefix() 的 host 替身
# ─────────────────────────────────────────────────────────────────────────

## 只提供那条拼装路径真正读到的字段（字段名必须与 HexRenderer 一致，否则被测代码会在
## null 上炸）。字段集与 tests/world/terrain_shader_variant_test.gd 的 FakeShaderHost 相同
## —— 两处都只服务「前缀拼装」，不是「重现 renderer」。
class _ProbeShaderHost extends RefCounted:
	var _world = null
	var visual_quality: int = 0
	var _mobile_quality_tier_define: String = ""
	var split_land_water_passes: bool = true
	var _split_program_failed: bool = false
	var terrain_surface_debug_view: int = 0
	var terrain_cell_field_enabled: bool = false
	var shader_path: String = "res://shaders/world_map.gdshader"
	var WORLD_MAP_SHADER_PATH: String = "res://shaders/world_map.gdshader"
	var SPLIT_LAND_ONLY_DEFINE: String = ""
	var SPLIT_WATER_ONLY_DEFINE: String = ""
	var CloudShadowFieldScript = null

	func _init() -> void:
		var water_impl = preload("res://scripts/rendering/renderer_shader_water.gd")
		SPLIT_LAND_ONLY_DEFINE = water_impl.SPLIT_LAND_ONLY_DEFINE
		SPLIT_WATER_ONLY_DEFINE = water_impl.SPLIT_WATER_ONLY_DEFINE
		CloudShadowFieldScript = preload("res://scripts/rendering/cloud_shadow_field.gd")
