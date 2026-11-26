class_name WebShaderWarmup
extends RefCounted

## Web 启动期 shader 预热。
##
## 为什么需要：Compatibility(GLES3/WebGL2) 后端在**首次绘制**某个材质时才把 shader
## 交给驱动编译，而且 WebGL **没有 program binary 缓存** —— 每次刷新页面都要重编。
## 所以这些编译成本必须全部落在"玩家已经在等"的阶段，绝不能漏到游戏开始之后。
##
## 做法：菜单显示后立刻在后台开始预热，**每帧只提交一张**（早期实现把 6 张塞在同一帧，
## 那一帧整块冻住 17–22 秒，既没有进度也没法定位是谁贵）。每张编译耗时通过
## `warmup_shader` 事件上报，源码指纹一并带上；`warmup_plan` 给出"打算编哪几份"的全量
## 清单，运行期各图层用 `WebTelemetry.note_variant()` 回报自己真正创建的那份源码指纹，
## 两边对账就能发现"预热编了个不会被用到的变体"——这类错误完全静默，只能靠指纹抓。
##
## 不变量：**运行期会首次绘制的每一份 shader 源码都必须在这里原样编一遍**，前缀与
## 运行期逐字一致。已经踩过三次坑（都靠指纹发现）：
##   - 植被预热硬编码了 `MAP_VISUAL_TILED`，而 web 运行期不是 tiled；
##   - `resource_ground_cover` 只加档位宏，预热却给了空串；
##   - 植被的家族批次变体（FAR_ONLY + DETAIL_FAMILY_BATCH）根本没进过清单。
##
## 前缀的真源在各自的 owner 里，本文件只引用，不自己拼宏串：
##   - world_map（Web LOW 陆地程序）/ world_water_web（Web LOW 水面第二 pass）/
##     PC-HIGH 陆地与水面：`RendererShaderWater.web_warmup_program_prefixes()`
##     （[cell-field-web 2026-11-18] 三组前缀**统一**由它给出，因为它同时管 micro 开关与
##      PK_CELL_FIELD 的 boot 自检结论；本文件只转发，一个宏字面量都不写）
##     （world_map 那一段 = quality + texture_budget + world_min + [no_micro] + land_only
##      + horizon；[terrain-web-baked-surface-A 2026-11-01] normal+relief 合并进
##      terrain_surface_tex（B 方案固定 4 层：normal/relief/detail/occluder）后腾出的材质槽
##      还给 noise_tex，前缀里不再有"无噪声"宏；[B 2026-11-01] surface array 扩到 4 层
##      （detail/occluder）+ material array 第 5 层 micro + GI packed bounce 全部走
##      **已有 sampler**，所以前缀不变、仍 8 槽；水面 depth 的 VT 宏在 shader 源码里定义，
##      水面 pass 前缀也不变）
##   - 建筑 3 张：`BuildingVisualLayer.compose_shader_code()`
##   - resource_impostor：`ResourceVisualLayer.compose_shader_code()`
##   - 植被 body/shadow/family：`ShrubLayer.web_warmup_shader_codes()`
##   - country_border：本文件的常量
##   - fog：[O23 2026-11-18] 也走判定口了 —— `fog_prefix_active()` =
##     `FOG_PREFIX + WEB_FOG_RUNTIME_DEFINE` + `cell_field_prefix_for_variant(...)`，
##     因为运行期 fog_of_war_layer.gd::_load_shader() 会按 boot 自检结论追加
##     `#define PK_CELL_FIELD`（**拼在最后**，紧跟在 PK_WEB_FOG_RUNTIME 之后）。
##     少了这一段，Web 上迷雾会在"进游戏"时真编一次（冻帧）。
##   - weather：本文件的常量（与 WeatherLayer._load_overlay_shader 逐字一致）


## 探针：world_map 的 land/water 双分支联合编译爆炸。
## 结论（已实测）：只留水 = 1 089 ms，只留陆地 = 2 473 ms，两个都在 = 20 291 ms；
## 把水面换成 25 行的"紧凑版"仍有 17 264 ms（无分支 mix 版 18 060 ms）⇒ 与行数无关。
## 正式修法已落地（[web-water-pass]）：水面**整段移出** world_map，改由
## `shaders/world_water_web.gdshader` 作第二 pass 绘制，两片合计 ≈ 3.6 s。
## 探针保留但置回 false（PROBE_WORLD_SPLIT 的成本拆分实验仍可能重跑）。
const PROBE_WORLD_SPLIT := false

## 探针：world_map **陆地管线**在真机（NVIDIA RTX 4080）上的逐块成本。
##
## 为什么必须在浏览器里做：本地 Godot 用 `--rendering-driver opengl3_angle` 走同一条
## GLSL→HLSL→FXC 链路，两种 GPU 都只有 1.7–2.6 s；而同一个卡在 Chrome 里是 16–18 s。
## 同链路差 6–9 倍 => 只有真机能给出这张表。
##
## 判读：某个 `wm_no_*` 掉到 ≤2.5 s ⇒ 那一块是病态点；
##       连 `wm_floor`（十段全换常量）都还是 16 s ⇒ 病根在 fragment 的 SETUP 段
##       （LUT 解码 / season_offset_unified / compute_current_temp）或整体规模。
const PROBE_WORLD_LAND_SPLIT := false

## 探针：那 18–20 秒到底是"world_map 这张 shader 贵"还是"本进程第一次编译 shader"。
## 判读：把一个 1×1 的最简 shader 排到清单第一位，
##   - 若它吃掉 ~18 s 而 world_map 掉到 ~2 s ⇒ 一次性成本，与哪张 shader 无关；
##   - 若它仍是几百 ms、world_map 仍是 18 s ⇒ 是 world_map 本身。
## 直接证据见真机逐块表：world_map 20 727（第 1 个编）/ 关掉任一块 1.25–2.15 s（第 2 个起），
## 以及本轮把 micro-off 变体排到第 1 位后它又变成 18 280 ms。
const PROBE_TRIVIAL_FIRST := true

## 本轮要测的探针块（宏名 = `PK_PROBE_NO_<TAG>`，落在 world_map 及其 include 里）。
## 每个探针都要单独编一张，所以清单越长菜单编译越久（最坏 16 s/条）。
const PROBE_LAND_BLOCKS := [
	"LAND_BASE", "MICRO", "MODIF", "SHADE", "GLOBAL_ADJ",
]

## 是否把植被 body/shadow/family 也预热（它们的编译同样落在 set_map / 家族批次首绘）。
const PK_WEB_WARM_VEGETATION := true

## `await_ready()` 的兜底上限。一张 shader 编译异常不应该把「开始游戏」永久锁死；
## 超时就带着不完整的预热继续（会多付一次游戏内编译，但会话能继续）。
## Full PC-quality programs can exceed the former two-minute deadline on ANGLE.
## Do not tear down the warmup host while its driver compilation is in flight.
const AWAIT_READY_TIMEOUT_MSEC := 600000

## 迷雾 / 国界这类层使用的前缀：只有质量档，没有纹理预算宏。
const FOG_PREFIX := "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"

## [O23 2026-11-18] 迷雾 web 变体的**静态**前缀 = 质量档 + 运行期画质宏。
## 顺序照 fog_of_war_layer.gd::_load_shader()：tier（web 上是 MOBILE_QUALITY_LOW +
## PK_SHADER_TIER_LOW）→ `PK_WEB_FOG_RUNTIME` → 最后才是场函数段（该段不是常量，
## 见 fog_prefix_active()）。"web 上是 LOW 档"沿用本文件既有前提（FOG_PREFIX 的注释），
## 与运行期 `set_mobile_quality_tier("MOBILE_QUALITY_LOW")` 同值。
const WEB_FOG_RUNTIME_DEFINE := "#define PK_WEB_FOG_RUNTIME\n"
const FOG_WEB_PREFIX := FOG_PREFIX + WEB_FOG_RUNTIME_DEFINE


## [O23 2026-11-18] 迷雾 web 变体的**完整**前缀 = 静态段 + 场函数段。
##
## 场函数段为什么不能写进 `SHADERS` 的 const 字面量：它依赖 boot 自检结论与项目设置
## （`cell_field_prefix_for_variant` 是函数调用，GDScript 的 const 不允许）。所以迷雾
## 从"纯常量前缀"改成本文件的第二个"判定口"条目（第一个是 world_map/水面那三组）。
##
## 判定口与运行期**同一个**：RendererShaderWater 的 `cell_field_prefix_for_variant`
## （= 变体准入 ∧ boot 自检结论）＋ `cell_field_setting_enabled()`（= HexRenderer._init
## 读进 `terrain_cell_field_enabled` 的**同一个键** —— 也就是运行期
## `_cell_field_active(host)` 的第一个条件）。运行期第二个条件
## `_cell_field_active(host)` 的 host 开关在 boot 时刻就等于这个设置值，所以"预热 =
## 运行期"在这里是构造保证（GM 面板热切会重编，那是必然的一次代价，见方案 §4）。
## ⚠ `budget_variant` / `world_min` 两个形参自 W6 起被忽略（见
## `cell_field_variant_allowed`），迷雾不是 budget 变体、也不是 world-min，传
## (true, false) 只是沿用陆地那份调用形状；真正起作用的是开关与 boot 结论。
static func fog_prefix_active() -> String:
	return FOG_WEB_PREFIX + RendererShaderWaterScript.cell_field_prefix_for_variant(
			true, false, RendererShaderWaterScript.cell_field_setting_enabled())

const TIER_PREFIX := "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n#define PK_WEB_TEXTURE_BUDGET\n"

## world_map 专用前缀的**历史默认/kill-switch**常量（= micro 被裁的 NO_MICRO 变体）。
## 真源在 HexRenderer；这里引用常量而不是抄字面量，差一个字节驱动就不认缓存、预热白做。
## 注意：千万不要把 PK_WEB_WORLD_MIN 塞进 TIER_PREFIX —— 天气那条复用 TIER_PREFIX，
## 会跟着漂移。
## [C 2026-11-01] A/B 结论（Edge 156 + ANGLE D3D11，tmp/webbuild_ab/REPORT.md）支持
## 默认放开 micro：world_map 编译 5417→4582ms（-15%）、总 warmup -5.5%。因此 web 实际
## 预热前缀必须走 `world_map_prefix_active()`（转发 HexRenderer.web_map_web_prefix_active()）：
## 默认 = MICRO 变体（= 本常量去掉 PK_PROBE_NO_MICRO）；URL `micro=off|0|false` 时才是
## 本常量（kill-switch）。保留本常量给默认值回退/旧断言。
const WORLD_MAP_PREFIX := HexRenderer.WORLD_MAP_WEB_PREFIX


## 当前要预热的共享 Web 陆地程序前缀（与运行期 _apply_shader_variant_prefix 同源）。
## 两处都调 HexRenderer 的 active 函数，保证「预热 = 运行期」逐字节一致（含 micro 开关：
## web 默认 MICRO，URL micro=off 回退到 WORLD_MAP_PREFIX）。
static func world_map_prefix_active() -> String:
	return HexRenderer.web_map_web_prefix_active()


## [cell-field-web 2026-11-18] 三组 Web 前缀（world_map / 水面 pass / PC-HIGH 陆地+水面）
## 的真源在 RendererShaderWater。本文件只**转发**，一个宏字面量都不写：
## 那里同时管 micro 开关与 PK_CELL_FIELD 的 boot 结论，两处同源才谈得上"逐字节一致"。
## `HexRenderer` 没有转发这个函数（它只需要常量），所以直接 preload 实现脚本。
const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")
## boot 自检的入口（方案 §3.5：在主菜单 boot 阶段、warmup 之前跑）。
## [W6 2026-11-18] 桌面 Compatibility 的第二个调用点：`renderer_scene_services.gd::_ready`
## （首次构建世界材质之前）。本文件的 run() 对非 web 直接 return，覆盖不到那条路径。
const CellFieldWebProbeScript = preload("res://scripts/rendering/cell_field_web_probe.gd")


static func web_program_prefixes() -> Dictionary:
	return RendererShaderWaterScript.web_warmup_program_prefixes()


## [cell-field-web 2026-11-18] PK_CELL_FIELD（解析格界）在 Web 上的预热不是"另加一条"，
## 而是**同一个函数多出一段**：
##   · 变体准入由 `RendererShaderWater.cell_field_variant_allowed()` 管 —— W6 起它恒真
##     （budget 排除随 W2 的旧三槽退役、world-min 排除随场函数正交一起撤销），所以真正
##     决定"这一段加不加"的只剩 boot 自检结论与项目设置开关；
##   · boot 自检结论（`pk_web_cell_field_boot`）在这里生效：fail / skipped 就一段都不加；
##   · 三组前缀（world_map / world_water_web / PC-HIGH）**统一**由
##     `RendererShaderWater.web_warmup_program_prefixes()` 给出，本文件不写宏串；
##   · **载荷宏两侧不同**：world_map 与 PC-HIGH 两片拼 `PK_CELL_FIELD`，水面第二 pass
##     （world_water_web）拼 `PK_WATER_FIELD_MATCHES_LAND` —— 存在性同源、字节各自为政，
##     后者顺序是 `MATCHES_LAND + WATER_PASS_PREFIX`（与 `_create_water_quad` 一致）。
## ⇒ 任何时刻实际预热的只有 boot 判定选中的那一套，绝不新旧同时编（方案 §7 否决）。
##   两套装的是**同一批 label**（文件名去扩展名），所以 label 不能靠名字区分新旧：
##   区分靠 `warmup_plan` 里的源码指纹（fp）。运行期 `note_variant()` 报的也是同一个
##   label，两边 fp 相等才算"预热到了" —— 名字相同而 fp 不同正是要抓的那种错。

## 全量预热清单。
## [cell-field-web 2026-11-18 / W6] world_map / world_water_web 两条**刻意不再带
## `prefix` 字段**：它们的运行期前缀不是一个常量，而是
## `RendererShaderWater.web_warmup_program_prefixes()` 的返回值（含 micro 开关、boot
## 自检结论、以及水面那份载荷宏）。曾经放在这里的文档值（`WORLD_MAP_PREFIX`（= NO_MICRO
## 变体）与 `WATER_PASS_PREFIX`）在 W6 之后与真源**不再是同一个字节串**（默认 web 是
## MICRO 变体、水面还要加载荷宏），留着只会让读者和断言一起读到一个错的答案。
## ⇒ 纪律：这两条的 prefix 只有真源一个出处，断言也必须读真源（terrain_shader_variant_test
## 的 warmup↔runtime 对账就是这么做的），不许在本文件里再写"看起来像"的常量。
const SHADERS := [
	{"path": "res://shaders/world_map.gdshader"},
	# [web-water-pass] 水面的第二 pass。**必须**跟在 world_map 之后：两片是同一张
	# 地图的两次绘制，运行期也总是成对出现（hex_renderer._sync_water_quad）。
	# 少了这一条，那 1.1 s 的编译会落进世界首帧。
	{"path": "res://shaders/world_water_web.gdshader"},
	# 迷雾层的前缀与 hex_renderer 不同：它不带 PK_WEB_TEXTURE_BUDGET
	# （那个宏只由 hex_renderer._apply_shader_variant_prefix 追加）。
	# [O23 2026-11-18] **刻意不再带 `prefix` 字段**：运行期 fog_of_war_layer.gd::
	# _load_shader() 在 PK_WEB_FOG_RUNTIME 之后还会追加 `#define PK_CELL_FIELD`
	# （判定口 = RendererShaderWater._cell_field_active），所以它的完整前缀不是常量。
	# 唯一出处是 `fog_prefix_active()`（真源常量 + 同一个判定口）；这里再留一个"看起来
	# 像"的常量只会让读者和断言一起读到错的答案（与 world_map / 水面两条同一个纪律）。
	{"path": "res://shaders/fog_of_war.gdshader"},
	{"path": "res://shaders/weather_overlay.gdshader",
		"prefix": "#define PK_WEB_WEATHER_MIN\n" + TIER_PREFIX},
	{"path": "res://shaders/country_border.gdshader", "prefix": ""},
	# 建筑外观：PC-Web 默认启用建筑投影，这里一并预热 building_shadow，避免进世界首次绘制现编。
	{"path": "res://shaders/building_compound.gdshader", "compose": "building"},
	{"path": "res://shaders/building_shadow.gdshader", "compose": "building"},
	{"path": "res://shaders/building_ground_decal.gdshader", "compose": "building"},
	{"path": "res://shaders/building_macro.gdshader", "compose": "building"},
	# resource_impostor 不在这里列：web 上它是**两份**程序
	# （PK_RES_WEB_PASS_SURFACE / _GEOLOGY，实测 1 211 + 1 522 ms；不拆是 5 681–6 429 ms），
	# 由 ResourceVisualLayer.web_warmup_shader_codes() 一次性给出，避免清单里出现
	# 两条同 path 的条目、也不在这里重复拼宏串。
	# resource_ground_cover 只加档位宏、不加 PK_SHADER_TIER_LOW：运行期
	# `resource_ground_cover.gd` 的 `_select_shader()` 在 web 上只 prepend
	# `#define MOBILE_QUALITY_LOW\n`。给空串就会预热到桌面变体、进游戏再真编一次。
	{"path": "res://shaders/resource_ground_cover.gdshader",
		"prefix": "#define MOBILE_QUALITY_LOW\n"},
	{"path": "res://shaders/trade_vehicle.gdshader", "prefix": ""},
	{"path": "res://shaders/data_overlay.gdshader", "prefix": ""},
	# 雨幕/雪幕：天气事件发生时才第一次可见，也就是说编译会落在游戏中的某一帧。
	{"path": "res://shaders/weather_cell_curtain.gdshader", "prefix": ""},
]

# ─── 会话级状态 ────────────────────────────────────────────────────────────
# 预热是**后台协程**：菜单先变成可操作，「开始游戏」/ autotest 再各自等它就绪。
# 用静态状态而不是信号，是因为调用方（main_menu）既想"立刻继续"，又想"等到它好"。
static var _running := false
static var _finished := false
static var _total_ms := 0
static var _done_count := 0
static var _total_count := 0
## 单张耗时（label → ms），给 UI / 事件流复用。
static var _per_shader_ms: Dictionary = {}
## 已预热的源码指纹（label → fp），运行期 `material_variant` 用它自查。
static var _warmed_fp: Dictionary = {}


## 运行期查询：这个 label 的源码指纹是否已经预热过。
## 返回 false 就说明"这一份会在游戏里编"，是冻结帧的根因。
static func is_warmed(label: String, code: String) -> bool:
	var fp = _warmed_fp.get(label)
	if fp == null:
		return false
	return String(fp) == WebTelemetry.code_fingerprint(code)


static func is_running() -> bool:
	return _running


static func is_finished() -> bool:
	return _finished or not OS.has_feature("web")


static func total_ms() -> int:
	return _total_ms


## 只读计数，给菜单进度条用。
##
## 为什么不复用 `progress()`：它每次都 duplicate 一份 `per_shader_ms`，拿来逐帧轮询
## 等于每帧分配一个字典。UI 每帧只需要知道"完成了几张 / 一共几张"，所以单独给两个
## 返回 int 的读取口 —— 零分配、零副作用，编译逻辑一行都没动。
static func done_count() -> int:
	return _done_count


static func total_count() -> int:
	return _total_count


## 清单是否已经建好（`begin()` 的第一次同步段就跑完了 `_collect_codes()`）。
## 为 false 时 `total_count()` 还是 0，此时**没有任何真实进度可显示**。
static func has_plan() -> bool:
	return _total_count > 0


static func progress() -> Dictionary:
	return {
		"done": _done_count,
		"total": _total_count,
		"total_ms": _total_ms,
		"per_shader_ms": _per_shader_ms.duplicate(),
	}


## 后台启动。重复调用安全（只有第一次真正跑）。
static func begin(host: Node) -> void:
	if _running or _finished or not OS.has_feature("web"):
		return
	if host == null or not host.is_inside_tree():
		return
	_running = true
	run(host)


## The default Web page starts in Auto/LOW. Compile the expensive PC HIGH
## programs only when the URL explicitly requests them; ANGLE compiles on the
## browser main thread, so an unconditional 30-second shader looks like a dead tab.
static func requested_quality() -> int:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return 0
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return 0
	var raw: Variant = bridge.call("eval", "new URLSearchParams(window.location.search).get('quality') || ''")
	match String(raw).to_lower():
		"high": return 2
		"medium": return 1
		_: return 0


## 等预热结束。非 web / 已经结束 / 从未启动都立即返回。
static func await_ready(host: Node) -> void:
	if is_finished() or host == null:
		return
	if not _running:
		begin(host)
		if not _running:
			return
	var tree := host.get_tree()
	var deadline_msec := Time.get_ticks_msec() + AWAIT_READY_TIMEOUT_MSEC
	while _running and tree != null:
		if Time.get_ticks_msec() >= deadline_msec:
			push_warning("[web-warmup] await_ready timeout after %d ms (done %d/%d); continuing"
				% [AWAIT_READY_TIMEOUT_MSEC, _done_count, _total_count])
			return
		await tree.process_frame


## 预热主体。逐张编译、逐张上报 —— 这是唯一能定位"谁最贵"的地方。
static func run(host: Node) -> void:
	if not OS.has_feature("web") or host == null or not host.is_inside_tree():
		_finished = true
		_running = false
		return
	var started := Time.get_ticks_msec()
	var layer := CanvasLayer.new()
	layer.name = "WebShaderWarmup"
	layer.layer = -128
	host.add_child(layer)
	# [cell-field-web 2026-11-18] PK_CELL_FIELD 是**编译期** define，选哪一套变体必须在这里
	# 定下来（方案 §3.5：主菜单 boot 阶段、预热之前）。关着 / 桌面 / 缓存命中时这一步只是
	# 几次 meta 读取；只有"首次启动 + Web"才会真的跑一次 32×32 的离屏自检。
	# 顺序很重要：必须在 _collect_codes() **之前**，否则清单已经按旧结论建好了。
	await CellFieldWebProbeScript.ensure_decided(host)
	var codes := _collect_codes()
	_total_count = codes.size()
	# 先把"打算编哪几份、每份的源码指纹/前缀"一次性报出去。前缀直接暴露出来：
	# "预热编了个不带宏的变体"这类错是静默的，只有把它发出来才能一眼看出。
	var plan: Array = []
	for entry in codes:
		var code_text := String(entry.get("code", ""))
		plan.append({"label": entry.get("label", "?"),
			"fp": WebTelemetry.code_fingerprint(code_text),
			"len": code_text.length(),
			"head": code_text.substr(0, 96).replace("\n", "|")})
	WebTelemetry.emit("warmup_plan", {"entries": plan})
	WebTelemetry.flush()
	var sum_ms := 0
	for entry in codes:
		if not is_instance_valid(layer) or not host.is_inside_tree():
			break
		var label := String(entry.get("label", "?"))
		var code := String(entry.get("code", ""))
		var fp := WebTelemetry.code_fingerprint(code)
		WebTelemetry.emit("warmup_shader_begin", {"label": label, "fp": fp, "idx": _done_count + 1})
		WebTelemetry.flush()
		_warmed_fp[label] = fp
		var began := Time.get_ticks_msec()
		var variant := Shader.new()
		variant.code = code
		var mat := ShaderMaterial.new()
		mat.shader = variant
		var rect := ColorRect.new()
		rect.size = Vector2(1.0, 1.0)
		rect.position = Vector2(0.0, 0.0)
		# 1x1 + alpha 0：仍然进入绘制列表（驱动会编译），但视觉上不可见。
		rect.color = Color(1.0, 1.0, 1.0, 0.0)
		rect.material = mat
		layer.add_child(rect)
		# 两帧：本帧提交绘制，下一帧驱动把 program 交出去并可以 release。
		var tree := host.get_tree()
		if tree != null:
			await tree.process_frame
			await tree.process_frame
		var took := Time.get_ticks_msec() - began
		sum_ms += took
		_per_shader_ms[label] = took
		_done_count += 1
		WebTelemetry.emit("warmup_shader", {
			"label": label,
			"dur": took,
			"fp": fp,
			"idx": _done_count,
			"total": _total_count,
		})
		# 菜单阶段还没有 WorldRuntimeHost，没人替我们 flush —— 不在这里冲一次，
		# 预热的分项耗时就要等进世界之后才到得了事件流（也就没法做进度条）。
		WebTelemetry.flush()
		if is_instance_valid(rect):
			rect.queue_free()
	_total_ms = sum_ms
	if is_instance_valid(layer):
		layer.queue_free()
	_finished = true
	_running = false
	WebTelemetry.emit("warmup", {
		"shaders": _total_count,
		"dur": Time.get_ticks_msec() - started,
		"sum_shader_ms": sum_ms,
	})


## 收集要编译的源码。前缀一律向 owner 取，不在这里自己拼。
static func _collect_codes() -> Array:
	var out: Array = []
	# [C 2026-11-01] world_map 共享程序的前缀要跟着 micro URL 诊断开关走；运行期
	# _apply_shader_variant_prefix 用同一个 HexRenderer.web_map_web_prefix_active()，
	# 两边逐字节一致，A/B 时预热才不会白编。
	# [cell-field-web 2026-11-18] 三组 Web 前缀（world_map / 水面 pass / PC-HIGH 两片）
	# 一律向 RendererShaderWater 的**同一个函数**取，本文件不拼任何宏：
	# 那里同时管 micro 开关与 PK_CELL_FIELD 的 boot 结论，「预热 = 运行期」才是构造保证。
	var web_prefixes := web_program_prefixes()
	var shared_map_prefix := String(web_prefixes.get("world_map", world_map_prefix_active()))
	if PROBE_TRIVIAL_FIRST:
		# 最简 canvas_item：只为吃掉"本进程第一次编译"的一次性成本。
		out.append({"label": "probe_trivial_first", "code":
			"shader_type canvas_item;\nvoid fragment() { COLOR = vec4(1.0); }\n"})
	for entry in SHADERS:
		var path := String(entry.get("path", ""))
		var shader := ResourceLoader.load(path, "Shader",
			ResourceLoader.CACHE_MODE_IGNORE) as Shader
		if shader == null:
			continue
		var entry_prefix := String(entry.get("prefix", ""))
		if path == "res://shaders/world_map.gdshader":
			# 共享陆地程序：web 默认 MICRO 变体（A/B 结论），URL micro=off|0|false 回退；
			# [W6] 再加上场函数段（boot 结论 / 项目设置决定加不加）。
			entry_prefix = shared_map_prefix
		elif path == "res://shaders/world_water_web.gdshader":
			# [cell-field-web 2026-11-18 / W3+W6] 水面第二 pass 的前缀同样来自单一真源：
			# 运行期在 _create_water_quad 里拼的是
			#   _water_program_prefix(host, "web_min") + WATER_PASS_PREFIX + shader.code
			# 而真源给出的那一段已经把两者按同一顺序串好了（载荷宏 PK_WATER_FIELD_MATCHES_LAND
			# 在前、WATER_PASS_PREFIX 在后），所以这里**直接整段取**，不要再拆开拼。
			entry_prefix = String(web_prefixes.get("world_water_web",
				HexRenderer.WATER_PASS_PREFIX))
		elif path == "res://shaders/fog_of_war.gdshader":
			# [O23 2026-11-18] 迷雾：静态段 + 场函数段（后者按 boot 自检结论 / 项目设置选）。
			# 见 fog_prefix_active() 的注释：判定口与运行期 _load_shader() 完全同源，
			# 场函数宏**拼在最后**（PK_WEB_FOG_RUNTIME 之后），与运行期逐字节同序。
			entry_prefix = fog_prefix_active()
		var code := entry_prefix + shader.code
		if String(entry.get("compose", "")) == "building":
			code = BuildingVisualLayer.compose_shader_code(shader, false)
		out.append({"label": path.get_file().get_basename(), "code": code})
	# resource_impostor 的 web 两份程序（surface / geology）：owner 自己给出源码。
	var pc_world := FileAccess.get_file_as_string("res://shaders/world_map.gdshader")
	# [cell-field-web 2026-11-18] PC-HIGH 两片的前缀也走同一个函数（原先在这里直接拼
	# HexRenderer 的常量；行为逐字节不变，但 PK_CELL_FIELD 的 boot 结论现在自动生效）。
	out.append({"label": "world_map_high",
		"code": String(web_prefixes.get("world_map_high",
			HexRenderer.WORLD_MAP_WEB_HIGH_PREFIX)) + pc_world})
	out.append({"label": "world_water_high",
		"code": String(web_prefixes.get("world_water_high",
			HexRenderer.WATER_WEB_HIGH_PREFIX)) + pc_world})
	var res_codes := ResourceVisualLayer.web_warmup_shader_codes()
	for key in res_codes.keys():
		out.append({"label": String(key), "code": String(res_codes[key])})
	if PK_WEB_WARM_VEGETATION:
		var names := ShrubLayer.web_warmup_shader_codes()
		for key in names.keys():
			out.append({"label": "veg_%s" % String(key), "code": String(names[key])})
	if PROBE_WORLD_LAND_SPLIT:
		# 每一块单独编一张，用来在真机（NVIDIA）上取逐块表。定义落在 world_map 及其
		# include 里现成的 `#ifndef PK_PROBE_NO_*` 守卫上；无宏时预处理逐字节不变。
		var wland := ResourceLoader.load("res://shaders/world_map.gdshader", "Shader",
			ResourceLoader.CACHE_MODE_IGNORE) as Shader
		if wland != null:
			for tag in PROBE_LAND_BLOCKS:
				out.append({
					"label": "wm_no_%s" % String(tag).to_lower(),
					"code": shared_map_prefix + "#define PK_PROBE_NO_%s\n" % String(tag) + wland.code,
				})
			# floor：十段全换常量。若它仍是 16 s ⇒ 病根不在陆地管线，而在 SETUP 段/整体规模。
			var floor_prefix := shared_map_prefix
			for tag in ["LAND_BASE", "MICRO", "MODIF", "COLOR_OVL", "MAT_OVL", "SHADE",
					"BRDF", "TOD_RELIEF", "CAST_SHADOW", "GLOBAL_ADJ"]:
				floor_prefix += "#define PK_PROBE_NO_%s\n" % String(tag)
			out.append({"label": "wm_floor", "code": floor_prefix + wland.code})
	if PROBE_WORLD_SPLIT:
		# 同一份 world_map 源码 + 额外 define：落在 shader 里现成的
		# `#ifndef PK_PROBE_*` 守卫上，无宏时预处理结果与改动前逐字节相同。
		var wm := ResourceLoader.load("res://shaders/world_map.gdshader", "Shader",
			ResourceLoader.CACHE_MODE_IGNORE) as Shader
		if wm != null:
			out.append({"label": "wm_no_land",
				"code": shared_map_prefix + "#define PK_PROBE_NO_LAND\n" + wm.code})
			out.append({"label": "wm_no_water",
				"code": shared_map_prefix + "#define PK_PROBE_NO_WATER\n" + wm.code})
	if not RendererShaderWaterScript.web_pc_high_boot_enabled():
		var light: Array = []
		for entry in out:
			if not String(entry.get("label", "")).ends_with("_high"):
				light.append(entry)
		out = light
	return out


## 给测试 / 诊断用：清空会话状态（重新加载菜单时才需要）。
static func reset() -> void:
	_running = false
	_finished = false
	_total_ms = 0
	_done_count = 0
	_total_count = 0
	_per_shader_ms.clear()
	_warmed_fp.clear()
