extends RefCounted
## [cell-field-web 2026-11-18] 解析格界（cell field）的 **boot 自检 + 自动回退**。
##
## 方案：`docs/plans/terrain-cell-field-web-plan.md` §3.5（自检设计）、§3.6（warmup 只
## 预热选中那一套）、§6 风险表。契约：`docs/plans/terrain-cell-field-contract.md` §6。
##
## ── 它解决什么 ────────────────────────────────────────────────────────────
## WebGL2 / 各家驱动上最危险的是三种**不报错**的失败（方案 §0）：
##   1. sampler 超出设备预算 ⇒ 第 9 张起被引擎内建白纹静默替换（槽位问题，由
##      `terrain_shader_variant_test` 的 sampler 普查守住，本文件**不**管）；
##   2. 纹理不完整（要求 mipmap 过滤但没有 mip 层级）⇒ 采样恒为 (0,0,0,1)，不报错；
##   3. `sampler2DArray` + `texelFetch(ivec3)` 在某些浏览器上行为异常 ⇒ 归属全错 /
##      全图同色。
## 本文件用一张**合成的小表**把 2、3 变成一次确定性的回读比对：全一致 ⇒ 记 pass，
## 否则记 fail 并回退旧路径 + 打一条遥测。这样线上某块显卡出问题时，是"自动降级"
## 而不是"玩家截图"。
##
## ── 结构（照抄 tests/world/cell_field_gpu_parity_probe.gd，本文件是它的产品化）──
##   SubViewport(32×32) + ColorRect + ShaderMaterial
##   → `shaders/debug/cell_field_web_probe.gdshader`（真 include hex_cell_field）
##   → 等两帧 `RenderingServer.frame_post_draw`
##   → `get_texture().get_image()` 回读
##   → 逐像素与 CPU 镜像 `DCHexCellField.dom_at()` + 合成表期望值对撞。
##
## ── 判定与回退（方案 §3.5「判定与回退」）────────────────────────────────────
##   结果写 Engine meta `pk_web_cell_field_boot`（`RendererShaderWater` 的那个常量，
##   boot 后固定）；按 adapter + 驱动版本 + 引擎构建号缓存到 `user://`（Web 上落
##   IndexedDB）；URL `?cellfield=off|on` 强制开关优先级最高。读取口与三态语义全部在
##   `RendererShaderWater`（运行期前缀拼装与预热共用同一个判定口，见 §3.6）。
##
## ── headless 的口径（**不能假绿，也不能假红**）──────────────────────────────
##   `--headless` 是 dummy 渲染器，`get_image()` 返回 null。此时本模块返回
##   `{ok: true, reason: "headless"}` 且**不写缓存、不上报 fail**，调用方
##   （`ensure_decided`）把它记成 `skipped`：Web / Compatibility 上 skipped 等于
##   **不启用**（诚实：既没有证据说能用，也没证据说不能用），桌面 Vulkan / 移动
##   本来就不需要自检，不受影响。headless 不是手机也不是浏览器，不能据此判失败。
##
## 用法：
##   var r: Dictionary = await CellFieldWebProbeScript.run(host)      # 裸探针
##   var d: Dictionary = await CellFieldWebProbeScript.ensure_decided(host)  # boot 判定

const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")
const FieldScript = preload("res://scripts/geography/hex_cell_field.gd")

const SHADER_PATH := "res://shaders/debug/cell_field_web_probe.gdshader"

# ── 合成表（方案 §3.5 第 1 条：8×6 格、4 层，每层内容已知，含一个金丝雀 texel）──
const TABLE_W := 8
const TABLE_H := 6
const LAYER_COUNT := 4
## 层号与契约 §3 / 方案 §3.1 同值。layer3 = `class_by_index`（index 空间，第 i 格放在
## (i % W, i / W)），本探针按它验证「按 index 查 biome」这条路。
const LAYER_CLASS := 0
const LAYER_STATE := 1
const LAYER_AUX := 2
const LAYER_BY_INDEX := 3

## 金丝雀 texel：值**唯一**（同层同通道里只有这一个 texel 是 211），所以「读到的不是
## 211/255」只能解释成纹理读错（不完整 / 未绑定 / 被白纹覆盖），不可能是读到了邻格。
const CANARY_X := 5
const CANARY_Y := 2
const CANARY_LAYER := LAYER_AUX
const CANARY_VALUE := 211
## 其余 texel 的 layer2.R（= fog_k，1.0 = 完全可见）。与金丝雀不同值即可。
const AUX_FOG_VALUE := 200

# ── 采样几何（像素 → 预设世界坐标）────────────────────────────────────────
## hex 边长取生产默认值（`HexRenderer.hex_size` 默认 22）。**改这里必须同步 shader 侧
## 的默认 uniform** —— 两侧都从本常量推，不写第二份字面量。
const HEX_SIZE := 22.0
## 32×32 = 1024 像素。方案写 16×16 或 32×32：取大的那个，逐像素比对的覆盖更广，
## 成本是一次 32×32 的同步回读（微秒级），只在首次启动或构建号变化时发生。
const VIEW_PX := 32
## 1 像素 = 5 个世界单位 ⇒ 采样矩形 160×160 wu。**这个值由「行不越界」反推出来**：
## 行号 = offset row，不 posmod（越界 = padding），而主导格可能取到 `floor(r)+1`，
## 所以必须满足 `floor(r_max)+1 < TABLE_H`：r = (2/3·y)/hex_size，y_max = 160 时
## r_max ≈ 4.85 ⇒ row ≤ 5 < TABLE_H=6 ✓（取 6 wu/px 时 y_max=189、r_max≈5.7、row 会到 6）。
## 顺带：AA 项 = 2/hex_size·5·1.00 ≈ 0.45 < 0.84，带宽由 terrain_ecotone_width 主导。
const WORLD_PER_PIXEL := 5.0
## 世界矩形原点：y = 0 让所有采样点的 row 落在 [0, TABLE_H)；
## x 取负让 offset col 出现负值 ⇒ 顺带验证 pk_posmod 的负数分支（方案 §3.4 第 4 条）。
const WORLD_ORIGIN := Vector2(-70.5, 0.0)

## 合成表 GPU 侧的人为破坏档（测试用；生产恒为 ""）。
const CORRUPT_NONE := ""
const CORRUPT_CANARY := "canary"
const CORRUPT_BIOME := "biome"

# ── user:// 缓存（Web 上落 IndexedDB）─────────────────────────────────────────
const CACHE_PATH := "user://pk_web_cell_field_probe.cfg"
const CACHE_SECTION := "cell_field_probe"

## 判定结论字符串（与 RendererShaderWater 的三态常量同一份字面量；那边是对外契约，
## 这里只读不写）。用函数转发而不是复制常量，避免两处各写一份字符串。
static func _pass_verdict() -> String:
	return RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS


static func _fail_verdict() -> String:
	return RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL


static func _skipped_verdict() -> String:
	return RendererShaderWaterScript.CELL_FIELD_VERDICT_SKIPPED


# ─────────────────────────────────────────────────────────────────────────
# 合成 cell_table
# ─────────────────────────────────────────────────────────────────────────

## 合成表每个 texel 每通道的字节值。**确定性公式**，GPU 与 CPU 两侧各自算出同一个数：
## 期望值不是"把纹理读回来当答案"（那会变成自证），而是同一个公式的独立求值。
##
## 每层的语义按契约 §3 / 方案 §3.1：
##   layer0 class         R=biome(1..47，**不取 0** —— 0 与"读不到 / 黑纹理"混淆)
##                        G=vegetation  B=cover  A=landform
##   layer1 state         R=temp  G=wet  B=snow  A=vitality/sea_ice
##   layer2 aux           R=fog_k（金丝雀在其中一个 texel）  G=water_depth  B=flags  A=255
##   layer3 class_by_index 同 layer0 的通道语义，但内容是**另一套值**：biome 落在
##                        100..199，与 layer0 的 1..47 不重叠 ⇒ "读错层"一定会被抓到。
static func layer_byte(layer: int, channel: int, col: int, row: int) -> int:
	match layer:
		LAYER_CLASS:
			match channel:
				0: return 1 + _wrap_byte(col * 3 + row * 5)
				1: return _wrap_byte(col * 7 + row * 11 + 1)
				2: return _wrap_byte(col * 13 + row * 17 + 2)
				_: return _wrap_byte(col * 19 + row * 23 + 3)
		LAYER_STATE:
			match channel:
				0: return _wrap_byte(col * 29 + row * 31)
				1: return _wrap_byte(col * 37 + row * 41)
				2: return _wrap_byte(col * 43 + row * 47)
				_: return 255
		LAYER_AUX:
			match channel:
				0: return CANARY_VALUE if (col == CANARY_X and row == CANARY_Y) else AUX_FOG_VALUE
				1: return _wrap_byte(col * 53 + row * 59)
				2: return 0
				_: return 255
		LAYER_BY_INDEX:
			match channel:
				0: return 100 + _wrap_byte(col * 11 + row * 13) % 100
				1: return _wrap_byte(col * 17 + row * 19)
				2: return _wrap_byte(col * 23 + row * 29)
				_: return _wrap_byte(col * 31 + row * 37)
	return 0


## 取模到 [0,256)。显式实现（不用 %)：GDScript 的 % 对负数返回负值，而这里所有输入
## 都可能为负（col 由世界坐标算出，允许负），两侧必须用**同一个**取模语义。
static func _wrap_byte(v: int) -> int:
	return v - 256 * int(floor(float(v) / 256.0))


## 合成 4 层 RGBA8 表。`corrupt` 只改**GPU 侧**那一份（期望值仍按 canonical 公式算），
## 所以它是「人为破坏 ⇒ 自检必须判 fail」的注入点：
##   CORRUPT_CANARY —— 把金丝雀写回普通 fog 值（= "纹理读不到 / 被白纹覆盖"的表现）；
##   CORRUPT_BIOME  —— 把 layer3.R 全写 0（= "按 index 查错了 / 层号错了"的表现）。
static func build_cell_table(corrupt: String = CORRUPT_NONE) -> Texture2DArray:
	var images: Array[Image] = []
	for layer in LAYER_COUNT:
		var img := Image.create_empty(TABLE_W, TABLE_H, false, Image.FORMAT_RGBA8)
		for row in TABLE_H:
			for col in TABLE_W:
				var value := Color(
					float(layer_byte(layer, 0, col, row)) / 255.0,
					float(layer_byte(layer, 1, col, row)) / 255.0,
					float(layer_byte(layer, 2, col, row)) / 255.0,
					float(layer_byte(layer, 3, col, row)) / 255.0)
				if corrupt == CORRUPT_CANARY and layer == CANARY_LAYER \
						and col == CANARY_X and row == CANARY_Y:
					value.r = float(AUX_FOG_VALUE) / 255.0
				elif corrupt == CORRUPT_BIOME and layer == LAYER_BY_INDEX:
					value.r = 0.0
				img.set_pixel(col, row, value)
		images.append(img)
	var table := Texture2DArray.new()
	# 不生成 mip：方案 §3.4 第 1 条要求 cell_table 是 filter_nearest 且无 mip 层级
	# （有 mip 时才可能被要求 mipmap 过滤，从而暴露"纹理不完整"那条静默坑）。
	table.create_from_images(images)
	return table


# ─────────────────────────────────────────────────────────────────────────
# 期望值（CPU 侧）
# ─────────────────────────────────────────────────────────────────────────

## 第 (px, py) 个像素的预设世界坐标。像素中心 = +0.5，与 C++ 烘焙
## （`world_ext_bake.cpp:1501,1505` 的 `origin + (pixel + 0.5) * step`）同一约定，
## 也与 shader 侧 `v_world = world_origin + UV * world_size`（UV 取像素中心）一致。
static func pixel_world(px: int, py: int) -> Vector2:
	return WORLD_ORIGIN + Vector2((float(px) + 0.5) * WORLD_PER_PIXEL,
			(float(py) + 0.5) * WORLD_PER_PIXEL)


## 该像素的期望字节：{col, row, biome, canary}。
##   col    —— `DCHexCellField.dom_at()`（CPU 镜像，与 shader 同一公式、平局次序 0>1>2）
##   biome  —— layer3 按 index 空间查出的 biome（index = row*W + col；表是满格，
##             所以 index 空间与 offset 空间落在同一个 texel 上，取的就是 (col,row)）
##   canary —— 金丝雀 texel 的 R
static func expected_pixel(px: int, py: int) -> Dictionary:
	var wp := pixel_world(px, py)
	# warp 恒传 Vector2.ZERO：本探针**不**定义 VT_USE_BOUNDARY_WARP ⇒ shader 侧
	# pk_boundary_warp_world() 恒返回 0（见 hex_cell_field.gdshaderinc 的 #else 分支）。
	var dom: Vector2i = FieldScript.dom_at(wp, HEX_SIZE, Vector2.ZERO, TABLE_H, TABLE_W)
	return {
		"col": dom.x,
		"row": dom.y,
		"biome": layer_byte(LAYER_BY_INDEX, 0, dom.x, dom.y),
		"canary": CANARY_VALUE,
	}


# ─────────────────────────────────────────────────────────────────────────
# 探针主体
# ─────────────────────────────────────────────────────────────────────────

## 跑一次自检。**调用方必须 `await`**（内部等两帧回读）；headless 等同步返回的路径上
## `await` 一个普通值也是合法的（Godot 4 直接把值给你）。
##
## `host_or_config`：树里的 Node（取它的 SceneTree），或 Dictionary：
##   {"tree": SceneTree, "corrupt": CORRUPT_*}   —— 测试注入用。
##
## 返回契约（逐字，6 个键）：
##   ok:            bool    全部像素一致 = true
##   reason:        String  见下（boot 入口 ensure_decided 另有 "setting_off" /
##                          "forced_pass|forced_fail" / "desktop" / "cached_*" /
##                          "fresh_*" / "already_*"，那是缓存与优先级层）
##   first_mismatch: Array  空，或 [px, py, channel, expected_byte, got_byte]
##                          channel: 0=R(col 低) 1=G(col 高) 2=B(layer3 biome) 3=A(金丝雀)
##   adapter:       String  get_video_adapter_name()
##   driver:        String  驱动/API 版本（RenderingServer.get_video_adapter_api_version）
##   cached:        bool    run() 恒 false —— 裸探针不读写缓存（缓存只由 ensure_decided 管）
##
## run() 的 reason 取值：
##   "fresh"            全部像素一致
##   "mismatch"         GPU 与 CPU 镜像 / 合成表期望不一致（带 first_mismatch）
##   "rect_out_of_table" 采样矩形越出合成表的行范围（探针配置问题）
##   "rect_too_small"   采样矩形覆盖的格子太少（会让比对退化成恒真）
##   "image_size"       回读尺寸不对
##   "no_image"         真后端上读不回像素（*不是* headless —— headless 在前面就分支了）
##   "no_tree"          拿不到 SceneTree，等不了帧
##   "headless"         dummy 渲染器 / 无适配器名 ⇒ 不判定（调用方记 skipped）
static func run(host_or_config = null) -> Dictionary:
	var config := _normalize_config(host_or_config)
	var tree: SceneTree = config.get("tree", null)
	var corrupt := String(config.get("corrupt", CORRUPT_NONE))
	var adapter := adapter_name()
	var driver := driver_version()
	# ① headless / dummy 渲染器：读不回像素就**不判**（见文件头「headless 的口径」）。
	if not real_backend_available():
		return _result(true, "headless", [], adapter, driver)
	if tree == null:
		# 没有树就没法等帧；这是调用方的错，不能判 fail（会误伤真实能力），也不能
		# 判 pass（没有证据）。reason 会原样带回去，由调用方决定记 skipped。
		return _result(true, "no_tree", [], adapter, driver)

	# ② 合成资产 + 材质
	var table := build_cell_table(corrupt)
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string(SHADER_PATH)
	var material := ShaderMaterial.new()
	material.shader = shader
	var world_size := Vector2(float(VIEW_PX), float(VIEW_PX)) * WORLD_PER_PIXEL
	material.set_shader_parameter("world_origin", WORLD_ORIGIN)
	material.set_shader_parameter("world_size", world_size)
	material.set_shader_parameter("hex_size", HEX_SIZE)
	# 关回绕：本探针只验归属数学与查表，回绕接缝由 cell_field_gpu_parity_probe 的
	# Pass B 专门覆盖（那里的矩形骑在经线上）。关掉之后 CPU 侧的 wp 就是未回绕坐标，
	# 与 shader 的 wrap_world_pos()（period<=0 ⇒ 恒等）一致。
	material.set_shader_parameter("wrap_period_x", 0.0)
	material.set_shader_parameter("wrap_origin_x", 0.0)
	# 与生产同源：0.84 = uniforms.gdshaderinc 的 terrain_ecotone_width 默认值，
	# 也是 DCHexCellField.dom_at() 内部用的 PK_FIELD_BAND_DEFAULT。
	material.set_shader_parameter("terrain_ecotone_width", 0.84)
	material.set_shader_parameter("terrain_ecotone_noise", 0.0)
	material.set_shader_parameter("cell_table", table)
	material.set_shader_parameter("cell_table_size", Vector2(float(TABLE_W), float(TABLE_H)))
	material.set_shader_parameter("cell_table_bound", true)
	material.set_shader_parameter("cell_class_index_bound", true)
	material.set_shader_parameter("probe_canary_texel", Vector2(float(CANARY_X), float(CANARY_Y)))
	material.set_shader_parameter("probe_canary_layer", float(CANARY_LAYER))
	# 画质档 LOW：terrain_edge_screen_width_px() = 1.00（与生产 LOW 档同值），
	# 且 PK_QUALITY_LOW 不会进本探针的宏集合，只影响 AA 带宽（不影响 dom）。
	material.set_shader_parameter("visual_quality", 0)
	material.set_shader_parameter("pixel_world_size", WORLD_PER_PIXEL)

	# ③ 一次性视口（UPDATE_ONCE）：画一帧就够，读回后立刻拆掉。
	#
	# [probe-web-readback 2026-11-23] **这段只在桌面 Compatibility 上有意义。**
	# web（WebGL2）上读回来永远是整张空图（实测 nonzero_px=0/1024，真显卡
	# RTX 4080 / ANGLE D3D11 与软件渲染一致），而同一张 render target 再读一次
	# 会让帧循环互等卡死。所以 web 不走这里 —— 见 ensure_decided ⑤ 的 web 分支。
	var viewport := SubViewport.new()
	viewport.size = Vector2i(VIEW_PX, VIEW_PX)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var rect := ColorRect.new()
	rect.size = Vector2(float(VIEW_PX), float(VIEW_PX))
	rect.position = Vector2.ZERO
	rect.color = Color(1.0, 1.0, 1.0, 1.0)
	rect.material = material
	viewport.add_child(rect)
	tree.root.add_child(viewport)
	# 两帧：本帧提交绘制，下一帧驱动把 program 交出去；frame_post_draw 保证回读
	# 发生在 GPU 真正画完之后（方案 §3.5 第 3 条）。
	await tree.process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image: Image = null
	if viewport.get_texture() != null:
		image = viewport.get_texture().get_image()
	if is_instance_valid(viewport):
		viewport.queue_free()
	if image == null:
		# 真后端上读不回像素：这是探针自身的失败（不是 headless，前面已经排除），
		# 判 fail 而不是假绿 —— 没有证据就不能声称"能用"。
		return _result(false, "no_image", [], adapter, driver)

	# ④ 逐像素比对
	var mismatch := _compare(image)
	if not bool(mismatch.get("ok", false)):
		var reason := String(mismatch.get("reason", "mismatch"))
		return _result(false, reason, mismatch.get("first_mismatch", []), adapter, driver)
	return _result(true, "fresh", [], adapter, driver)


## 逐像素比对 GPU 回读与 CPU 期望。返回 {ok, reason, first_mismatch}。
## 期望值只算一次（像素 → 世界坐标 → CPU 镜像 dom → layer3 biome / 金丝雀），然后：
##   ① 前置检查：采样矩形必须整块落在表内，且覆盖足够多的格子（否则"argmax 恒定"
##      也能全绿 —— 探针退化成恒真比失败更糟）；
##   ② 逐像素四通道比对，第一个不一致就返回（带坐标、通道、两侧数值）。
static func _compare(image: Image) -> Dictionary:
	if image.get_width() != VIEW_PX or image.get_height() != VIEW_PX:
		return {"ok": false, "reason": "image_size",
				"first_mismatch": [image.get_width(), image.get_height(), -1, VIEW_PX, VIEW_PX]}
	var wants: Array = []
	wants.resize(VIEW_PX * VIEW_PX)
	var distinct := {}
	for py in VIEW_PX:
		for px in VIEW_PX:
			var expected := expected_pixel(px, py)
			var col := int(expected["col"])
			var row := int(expected["row"])
			# row 不 posmod（越界 = padding），越界像素的 index 查表行为由驱动决定
			# —— 那是探针配置的问题，不能当成 GPU 错了，所以先整体检查再比对。
			if row < 0 or row >= TABLE_H:
				return {"ok": false, "reason": "rect_out_of_table",
						"first_mismatch": [px, py, -1, row, TABLE_H]}
			distinct[Vector2i(col, row)] = true
			wants[py * VIEW_PX + px] = [
				col & 255,
				(col >> 8) & 255,
				int(expected["biome"]),
				int(expected["canary"]),
			]
	if distinct.size() < 8:
		return {"ok": false, "reason": "rect_too_small",
				"first_mismatch": [0, 0, -1, 8, distinct.size()]}
	for py in VIEW_PX:
		for px in VIEW_PX:
			var want: Array = wants[py * VIEW_PX + px]
			var colour := image.get_pixel(px, py)
			var got := [
				int(round(colour.r * 255.0)),
				int(round(colour.g * 255.0)),
				int(round(colour.b * 255.0)),
				int(round(colour.a * 255.0)),
			]
			for channel in 4:
				if got[channel] == want[channel]:
					continue
				return {"ok": false, "reason": "mismatch",
						"first_mismatch": [px, py, channel, want[channel], got[channel]]}
	return {"ok": true, "reason": "fresh", "first_mismatch": []}


## 探针的 6 键返回契约（见 run() 的注释）。
static func _result(ok: bool, reason: String, first_mismatch: Array, adapter: String,
		driver: String, cached: bool = false) -> Dictionary:
	return {
		"ok": ok,
		"reason": reason,
		"first_mismatch": first_mismatch,
		"adapter": adapter,
		"driver": driver,
		"cached": cached,
	}


static func _normalize_config(host_or_config) -> Dictionary:
	if host_or_config is Dictionary:
		return (host_or_config as Dictionary).duplicate()
	var tree: SceneTree = null
	if host_or_config is SceneTree:
		tree = host_or_config as SceneTree
	elif host_or_config is Node:
		var node := host_or_config as Node
		if node.is_inside_tree():
			tree = node.get_tree()
	elif host_or_config == null:
		var main := Engine.get_main_loop()
		if main is SceneTree:
			tree = main as SceneTree
	return {"tree": tree, "corrupt": CORRUPT_NONE}


# ─────────────────────────────────────────────────────────────────────────
# boot 判定：URL 强制 → 缓存 → 真跑；结论写 Engine meta（boot 后固定）
# ─────────────────────────────────────────────────────────────────────────

## boot 期调一次。**调用方必须 `await`**（真跑自检时要等帧）。
## 幂等：已经有结论就原样返回，不读 URL、不跑 GPU、不改缓存。
##
## 返回 6 键契约 + `verdict`，`reason` 描述走的是哪条分支：
##   "already_<verdict>"  已判定（boot 后固定）
##   "setting_off"        `PK_CELL_FIELD` 项目设置关着 ⇒ 不判、零成本
##   "forced_pass|forced_fail"  URL `?cellfield=on|off`（优先级最高）
##   "desktop"            桌面 Vulkan / 移动不需要自检 ⇒ pass
##   "headless"           读不回像素 ⇒ skipped（不写缓存、不报 fail）
##   "cached_pass|cached_fail"  user:// 缓存命中（键 = adapter+驱动+构建号）
##   "fresh_pass|fresh_fail"    真跑
static func ensure_decided(host = null) -> Dictionary:
	var adapter := adapter_name()
	var driver := driver_version()
	var water := RendererShaderWaterScript
	# ① boot 后固定：已经有结论就不再判定（否则游戏中途切 URL 会触发驱动重编）。
	if water.cell_field_boot_decided():
		return _decided(water.cell_field_boot_verdict(), "already_" + water.cell_field_boot_verdict(),
				adapter, driver, false, [], false)
	# ② 项目设置关着（v1 默认）：不判、不写、零成本。
	if not water.cell_field_setting_enabled():
		return _decided(_skipped_verdict(), "setting_off", adapter, driver, false, [], false)
	# ③ URL 强制开关：优先级高于自检与缓存，用于线上排查（方案 §3.5 末条）。
	var forced := water.cell_field_url_forced_verdict()
	if not forced.is_empty():
		water.set_cell_field_boot_verdict(forced)
		return _decided(forced, "forced_" + forced, adapter, driver, false, [])
	# ④ 桌面 Vulkan / 移动不需要自检（方案 §3.5「判定与回退」：视为 pass）。
	if not DCFeatureFlags.is_compatibility_renderer():
		water.set_cell_field_boot_verdict(_pass_verdict())
		return _decided(_pass_verdict(), "desktop", adapter, driver, false, [])
	# ⑤ [probe-web-readback 2026-11-23] web：WebGL 读不回 render target。
	#    实测（RTX 4080 / ANGLE D3D11，与软件渲染一致）回读是整张空图，且同一张
	#    render target 再读一次会让帧循环互等卡死。也就是说自检在 web 上**拿不到
	#    任何证据**。按方案 §3.5 这该记 skipped，但 skipped 在受限平台等于不启用 ⇒
	#    web 永远停在旧画布路径：玩家看到的格界网点/锯齿就是它，而且这个"降级"
	#    从上线起就一直默默发生。这里改成显式取舍：web 直接判 pass 并留一条
	#    warning（可被 `?cellfield=off` 覆盖），桌面 Compatibility 仍然照旧真跑自检
	#    —— 那边回读是好的，护栏在那里仍然有效。
	if OS.has_feature("web"):
		water.set_cell_field_boot_verdict(_pass_verdict())
		push_warning("[cell-field/web] WebGL 读不回 render target，跳过自检直接启用解析格界"
				+ "（?cellfield=off 可强制回退旧画布路径）")
		return _decided(_pass_verdict(), "web_no_readback", adapter, driver, false, [])
	# ⑤ 读不回像素（headless / dummy）：记 skipped，**不写缓存、不报 fail**。
	if not real_backend_available():
		water.set_cell_field_boot_verdict(_skipped_verdict())
		return _decided(_skipped_verdict(), "headless", adapter, driver, false, [])
	# ⑥ 同一设备 + 同一驱动 + 同一构建号：直接用上次结论（方案 §3.5 / §6 缓存在
	#    IndexedDB 里，改一次驱动版本或换构建号就自动失效）。
	var cached := read_cache()
	if not cached.is_empty():
		var cached_verdict := String(cached.get("verdict", ""))
		if cached_verdict == _pass_verdict() or cached_verdict == _fail_verdict():
			water.set_cell_field_boot_verdict(cached_verdict)
			return _decided(cached_verdict, "cached_" + cached_verdict, adapter, driver, true,
					cached.get("first_mismatch", []))
	# ⑦ 真跑
	var tree: SceneTree = null
	if host is Node and (host as Node).is_inside_tree():
		tree = (host as Node).get_tree()
	elif host is SceneTree:
		tree = host as SceneTree
	var probe: Dictionary = await run({"tree": tree})
	var ok := bool(probe.get("ok", false))
	var reason := String(probe.get("reason", ""))
	# headless / 没有树：保持旧行为（skipped），不能假绿也不能假红。
	if reason == "headless" or reason == "no_tree":
		water.set_cell_field_boot_verdict(_skipped_verdict())
		return _decided(_skipped_verdict(), reason, adapter, driver, false, [])
	var verdict := _pass_verdict() if ok else _fail_verdict()
	water.set_cell_field_boot_verdict(verdict)
	var first: Array = probe.get("first_mismatch", [])
	write_cache(verdict, first)
	_report_verdict(verdict, probe, first)
	return _decided(verdict, "fresh_" + verdict, adapter, driver, false, first)


static func _decided(verdict: String, reason: String, adapter: String, driver: String,
		cached: bool, first_mismatch: Array, log_boot := true) -> Dictionary:
	var out := _result(verdict == _pass_verdict(), reason, first_mismatch, adapter, driver, cached)
	out["verdict"] = verdict
	# 每次真的**做了决定**都留一行（桌面 Compatibility 没有遥测通道，只能看日志）。
	# "already_*"（重复调用）与 "setting_off"（默认关，零成本路径）不刷屏。
	if log_boot:
		print("[cell-field-web-probe] boot reason=%s verdict=%s adapter=%s driver=%s cached=%s"
				% [reason, verdict, adapter, driver, str(cached)])
	return out


## 结论的统一出口：一行固定前缀日志（桌面 Compatibility 只能靠日志取证）+ 一条遥测。
## Web 上走 `WebTelemetry`（页面 `POST /_log`，服务端落 `tmp/web_events.jsonl`）；
## 非 web / 无桥时 emit 内部就是 no-op，只剩那行 print。
##   `cell_field_probe`      —— 每次**新判**都发，带 verdict（自检通过率要靠它统计，
##                              方案 §8.1 说 Web 是否默认开启要看一版遥测）；
##   `cell_field_probe_fail` —— plan §3.5 明确要求的失败事件，只在 fail 时发。
static func _report_verdict(verdict: String, probe: Dictionary, first_mismatch: Array) -> void:
	var payload := {
		"adapter": String(probe.get("adapter", "")),
		"driver": String(probe.get("driver", "")),
		"verdict": verdict,
		"first_mismatch": first_mismatch,
		"build": engine_build_id(),
	}
	print("[cell-field-web-probe] verdict=%s adapter=%s driver=%s first_mismatch=%s build=%s"
			% [verdict, payload["adapter"], payload["driver"], str(first_mismatch),
			payload["build"]])
	var telemetry := WebTelemetry
	telemetry.emit("cell_field_probe", payload)
	if verdict == _fail_verdict():
		telemetry.emit("cell_field_probe_fail", payload)
	# 菜单阶段还没有 WorldRuntimeHost 替我们 flush，这里必须自己冲一次，
	# 否则这条最该看到的遥测要等进世界之后才到事件流。
	telemetry.flush()


# ─────────────────────────────────────────────────────────────────────────
# 缓存键 / 设备身份
# ─────────────────────────────────────────────────────────────────────────

## 缓存键 = adapter + 驱动版本 + 引擎构建号（方案 §3.5 / §6）。
## 纯函数：三项任一变化都必须 miss，便于测试逐项验证。
static func cache_key(adapter: String, driver: String, build: String) -> String:
	return "%s|%s|%s" % [adapter.strip_edges(), driver.strip_edges(), build.strip_edges()]


static func adapter_name() -> String:
	if not RenderingServer.has_method("get_video_adapter_name"):
		return ""
	return String(RenderingServer.get_video_adapter_name())


## 驱动 / API 版本（Vulkan: 驱动版本串；GLES3: "OpenGL ES 3.0 ..." 之类）。
## 浏览器升级会改这一串 ⇒ 缓存自动失效（方案 §6「缓存的结论过期」那条风险）。
static func driver_version() -> String:
	if not RenderingServer.has_method("get_video_adapter_api_version"):
		return ""
	return String(RenderingServer.get_video_adapter_api_version())


## 引擎构建号：版本串 + git hash。**构建号变了就重新检查**（方案 §3.5）。
static func engine_build_id() -> String:
	var info := Engine.get_version_info()
	return "%s+%s" % [String(info.get("string", "")), String(info.get("hash", ""))]


static func current_cache_key() -> String:
	return cache_key(adapter_name(), driver_version(), engine_build_id())


## 读缓存。键不匹配（换了显卡 / 驱动 / 构建号）⇒ 返回空字典 = miss。
static func read_cache() -> Dictionary:
	var config := ConfigFile.new()
	if config.load(CACHE_PATH) != OK:
		return {}
	if not config.has_section(CACHE_SECTION):
		return {}
	var key := String(config.get_value(CACHE_SECTION, "key", ""))
	if key.is_empty() or key != current_cache_key():
		return {}
	var verdict := String(config.get_value(CACHE_SECTION, "verdict", ""))
	if verdict.is_empty():
		return {}
	return {
		"verdict": verdict,
		"adapter": String(config.get_value(CACHE_SECTION, "adapter", "")),
		"driver": String(config.get_value(CACHE_SECTION, "driver", "")),
		"build": String(config.get_value(CACHE_SECTION, "build", "")),
		"first_mismatch": config.get_value(CACHE_SECTION, "first_mismatch", []),
	}


## 写缓存（Web 上 `user://` 由引擎落到 IndexedDB）。写失败不影响判定。
static func write_cache(verdict: String, first_mismatch: Array = []) -> void:
	var config := ConfigFile.new()
	config.set_value(CACHE_SECTION, "key", current_cache_key())
	config.set_value(CACHE_SECTION, "verdict", verdict)
	config.set_value(CACHE_SECTION, "adapter", adapter_name())
	config.set_value(CACHE_SECTION, "driver", driver_version())
	config.set_value(CACHE_SECTION, "build", engine_build_id())
	config.set_value(CACHE_SECTION, "first_mismatch", first_mismatch)
	config.set_value(CACHE_SECTION, "at_unix", int(Time.get_unix_time_from_system()))
	config.save(CACHE_PATH)


## 只在测试 / 诊断里用：清掉缓存文件。
static func clear_cache() -> void:
	if FileAccess.file_exists(CACHE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE_PATH))


## 有真实渲染后端吗？dummy（headless）渲染器读不回像素，且拿不到适配器名。
## 与 `cell_field_gpu_parity_probe.gd::_real_backend_available()` 同一判据。
static func real_backend_available() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not adapter_name().is_empty()
