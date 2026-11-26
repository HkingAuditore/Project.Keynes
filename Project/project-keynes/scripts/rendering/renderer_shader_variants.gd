extends RefCounted

const RendererCloudShadowBinding = preload("res://scripts/rendering/renderer_cloud_shadow_binding.gd")

## Selects the shared land and water shader variants and their compile-time prefixes.


# 每帧把 world_time 推进给 shader（驱动洋流流纹）
# 注意：这里只 push 一个 float uniform，几乎零开销

static func _visual_tiles_active(host) -> bool:
	return RendererCloudShadowBinding._visual_tiles_active(host)


# ─── [web-world-min] world_map 的 web/GLES3 裁剪变体（前缀单一真源）───────────
# 为什么：浏览器（Intel UHD 770 + ANGLE/D3D11）上逐张计时的实测是 world_map 首次编译
# **22 613 ms**（旧的 6.7 s 数字已过时），仅次于 resource_impostor 的 27 424 ms。
# 成本几乎全在 include 展开体上——web-LOW 预处理后 3634 非注释行 / 148.3 KiB，是桌面
# 体的 81%，LOW 档只靠 PK_MOBILE_ANY 砍掉了 19%。本变体按「编译期已定 + 运行期常量已定
# ⇒ 不可达」删掉 LOW 档永远不执行的代码：2491 行 / 102.6 KiB，for 循环 17→4，
# tan/acos/exp/sqrt 归零。
# 只对「Compatibility 后端 + MOBILE_QUALITY_LOW 档」生效；中/高档 web 拿到的字节与
# 改动前完全一致（它们真的会跑 ctx.quality>=1 的水体分支）。
# 详见 shaders/include/world_map_web_min.gdshaderinc 文件头。
const PK_WEB_TEXTURE_BUDGET_DEFINE := "#define PK_WEB_TEXTURE_BUDGET\n"
const QUALITY_PREFIX_LOW := "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
const WORLD_MAP_WEB_MIN_DEFINE := "#define PK_WEB_WORLD_MIN\n"
## [web-world-no-micro] 真机实测（RTX 4080 + Chrome，已钉住 GPU）的 world_map 首次编译：
##   完整 web 变体                                      20 727 ms
##   只关 micro                                         2 153 ms
##   只关 land_base / modif / shade / global_adj 之一    1.25–2.15 s
##   十段全换常量                                        362 ms
## 也就是**整条陆地管线卡在阈值上**：任何一块拿掉都塌到 1–2 s，跟那一块本身多大关系不大
## （与 world_map 水面、resource_impostor 六路来源的"寄存器压力悬崖"同型）。
## 所以 web 上**永久**关掉 micro（微纹理细节）—— 十块里观感代价最小的一块，在 web 的低分辨率
## + LOW 档下几乎看不出，而它的结构/uniform 一个不动。
## 宏名沿用诊断探针名（`PK_PROBE_NO_MICRO`），好处是"测到的组合 = 上线的组合"，
## 真机回归时可以原样复现上面这张表。
const WORLD_MAP_WEB_NO_MICRO_DEFINE := "#define PK_PROBE_NO_MICRO\n"

## [terrain-web-baked-surface 2026-11-01 / -A 2026-11-01] Web 陆地程序的两个吸收宏：
##   PK_WEB_LAND_ONLY — 陆地程序不 include water.gdshaderinc（水面由独立第二 pass 画）；
##   PK_WEB_HORIZON   — 允许 LOW 档真正执行 horizon 解码（否则 MOBILE_QUALITY_LOW
##                      会把 terrain_horizon_evaluate() 编译成中性值）。
## 两者只对 world-min 变体（= Web 全部档位）和 PC-HIGH 陆地 pass 生效：桌面
## Compatibility 的中/高档没有水面第二 pass，不能被 LAND_ONLY 砍掉水面管线。
## [方案 A/B] normal+relief 合进 terrain_surface_tex（B 方案固定 4 层：normal/relief/detail/
## occluder）后腾出的 Web 材质槽给回了
## noise_tex（全平台统一声明/绑定），所以这里只剩这两个吸收宏。
const WORLD_MAP_WEB_LAND_ONLY_DEFINE := "#define PK_WEB_LAND_ONLY\n"
const WORLD_MAP_WEB_HORIZON_DEFINE := "#define PK_WEB_HORIZON\n"

## 共享 Web 陆地程序的 **NO_MICRO（kill-switch / 历史默认）变体**：7 个 define，
## 与 WORLD_MAP_WEB_PREFIX_MICRO 只差 `#define PK_PROBE_NO_MICRO`。C 收尾后 web 默认走
## MICRO；本常量仅用于 URL `micro=off|0|false` 回退、非 web（桌面 Compatibility）与
## 既有测试/回退口径。所有段共用同一批常量，不是"抄一份字面量"。
## 顺序（terrain_shader_variant_test 用 WATER_PASS_PREFIX + 4 个 define 链式校验）：
##   quality → texture_budget → world_min → no_micro → land_only → horizon
const WORLD_MAP_WEB_PREFIX := QUALITY_PREFIX_LOW + PK_WEB_TEXTURE_BUDGET_DEFINE \
	+ WORLD_MAP_WEB_MIN_DEFINE + WORLD_MAP_WEB_NO_MICRO_DEFINE \
	+ WORLD_MAP_WEB_LAND_ONLY_DEFINE + WORLD_MAP_WEB_HORIZON_DEFINE

## [C 2026-11-01] 共享 Web 陆地程序的 **micro 开启变体**（保留 terrain_material_tex
## layer4 的 micro 采样路径）。A/B 结论（2026-11-01，Edge 156 + ANGLE D3D11 / RTX 3070 Ti，
## 见 tmp/webbuild_ab/REPORT.md / verdict.json）：
##   world_map 首次编译：A(裁 micro，即 WORLD_MAP_WEB_PREFIX) 均值 5417ms
##   （5208–5615）vs B(micro=shared) 4582ms（4347–4880）→ micro 变体**不慢反快 -15%**；
##   总 warmup 36978ms → 34934ms（-5.5%），boot/menu 噪声内不变；21/21 张编译成功、
##   无 JS/GL 错误；历史上 20.7s 的寄存器压力悬崖在当前重构后的 shader 上**不复现**
##   （B 组 plan 指纹 26 字节恰为 NO_MICRO 定义行，证明两组编的是不同前缀）。
## 因此 web 上**默认启用**本变体；URL `?micro=off|0|false` 是 kill-switch，可回退到
## WORLD_MAP_WEB_PREFIX（NO_MICRO）。见 web_map_web_prefix_active()。
const WORLD_MAP_WEB_PREFIX_MICRO := QUALITY_PREFIX_LOW + PK_WEB_TEXTURE_BUDGET_DEFINE \
	+ WORLD_MAP_WEB_MIN_DEFINE \
	+ WORLD_MAP_WEB_LAND_ONLY_DEFINE + WORLD_MAP_WEB_HORIZON_DEFINE

## [C 2026-11-01] micro 开关的 boot 缓存（与 pk_web_pc_high_boot 同模式）：
## 值为「共享 Web 陆地程序是否含 micro 层」。web 默认 true；URL `micro=off|0|false`
## 回退 false（kill-switch）；`micro=shared|on` 显式 true（与默认等价）。非 web 恒 false
## （桌面 Compatibility 维持 NO_MICRO 旧变体，与本次 A/B 无关）。boot 后固定，避免
## 游戏中途切 URL 触发驱动重编（WebGL 没有 program binary 缓存）。
const PK_WEB_MICRO_BOOT_META: StringName = &"pk_web_micro_boot"

## URL `micro` 参数 → 是否启用 micro 的纯映射（无 OS 副作用，便于测试）：
##   off / 0 / false（大小写、空白不敏感）→ false（kill-switch）；
##   其它（含缺省 / unknown / shared / on）→ true（默认放开 micro，见上方 A/B 结论）。

static func micro_url_value_enabled(raw: String) -> bool:

	var value = String(raw).strip_edges().to_lower()
	if value == "off" or value == "0" or value == "false":
		return false
	return true


## 共享 Web 陆地程序是否启用 micro。非 web 恒 false；web 默认 true（A/B 结论），
## URL `micro=off|0|false` 回退。结果缓存在 Engine meta（boot 固定）；测试可用
## Engine meta 预置来模拟 web 的两种取值。

static func web_map_micro_url_enabled() -> bool:

	if Engine.has_meta(PK_WEB_MICRO_BOOT_META):
		return bool(Engine.get_meta(PK_WEB_MICRO_BOOT_META))
	if not OS.has_feature("web"):
		Engine.set_meta(PK_WEB_MICRO_BOOT_META, false)
		return false
	var raw = ""
	if Engine.has_singleton("JavaScriptBridge"):
		var bridge: Object = Engine.get_singleton("JavaScriptBridge")
		if bridge != null:
			raw = String(bridge.call("eval",
				"new URLSearchParams(window.location.search).get('micro') || ''"))
	var enable = micro_url_value_enabled(raw)
	Engine.set_meta(PK_WEB_MICRO_BOOT_META, enable)
	return enable


## 运行期与预热共用的「当前 Web 共享陆地程序前缀」：web 默认 = MICRO 变体；
## kill-switch / 非 web = WORLD_MAP_WEB_PREFIX（NO_MICRO）。两处必须都调这个函数
## （见 WebShaderWarmup.world_map_prefix_active），保证「预热 = 运行期」逐字节一致。

static func web_map_web_prefix_active() -> String:

	return WORLD_MAP_WEB_PREFIX_MICRO if web_map_micro_url_enabled() else WORLD_MAP_WEB_PREFIX


## [cell-field-web 2026-11-18] Web 侧**四组**预热 program 的完整前缀（方案 §3.6 的
## 单一真源）。`WebShaderWarmup._collect_codes()` 只准调这个函数，不许自己拼宏串 ——
## 差异一个字节驱动就不认缓存，预热白做（该文件头部把这条列为硬纪律）。
##
## 「预热 = 运行期，逐字节一致」在这里由**构造**保证：四段前缀都用运行期同一批常量
## （WORLD_MAP_WEB_PREFIX* / WATER_PASS_PREFIX / *_WEB_HIGH_PREFIX）拼，并且场函数那一
## 段走 `cell_field_prefix_for_variant()` —— 与运行期 `_cell_field_active()` 读的是同一个
## 变体准入（W6 后恒真）+ 同一个 boot 结论（方案 §3.5/§3.6）。
##
## **载荷宏两侧不同，判定口只有一个**（W3/W6）：
##   · 陆地 world_map：`PK_CELL_FIELD`（CELL_FIELD_DEFINE，运行期 `_cell_field_prefix`）；
##   · 水面 world_water_web：`PK_WATER_FIELD_MATCHES_LAND`（运行期 web_min 分支由**同一个**
##     `_cell_field_prefix(host)` 的门控结果决定要不要拼）。
## 所以这里绝不能把"两段都用 CELL_FIELD_DEFINE"当成对称 —— 水面那一段的**存在性**跟陆地
## 同源、**字节**是它自己的载荷宏。`_collect_codes()` 的 world_water_web 条目还必须在
## 载荷宏之后拼 WATER_PASS_PREFIX：运行期 `_create_water_quad` 拼的是
## `prefix + WATER_PASS_PREFIX + shader.code`，而这个函数返回的正是那个 `prefix`。
##
## 参数口径（web 全档都一样，不需要 host）：
##   budget_variant = true —— Web 物理上只有 Compatibility 后端，一定定义
##                            PK_WEB_TEXTURE_BUDGET（W6 后 8 → PK 侧 6 个材质 sampler 槽）。
##   world_min      = true —— world_map 的 LOW 预热条目就是 PK_WEB_WORLD_MIN 降级程序
##                            （WORLD_MAP_WEB_PREFIX(_MICRO) 自带该宏）；
##                            水面 pass / PC-HIGH 不带 world-min。
## 两个参数自 W6 起都被 `cell_field_variant_allowed()` 忽略（函数体恒真），保留它们是为了
## 让"哪套变体允许带宏"继续只有**一个**出口，而不是在这里再写一遍平台判定。
## **只预热 boot 判定选中的那一套**：这里返回的字符串要么带载荷宏，要么不带，
## 不存在"新旧两份都预热"的组合（那会让首编时间翻倍，方案 §7 明确否决）。
static func web_warmup_program_prefixes() -> Dictionary:

	var enabled := cell_field_setting_enabled()
	# 水面 pass 的载荷宏（PK_WATER_FIELD_MATCHES_LAND）与陆地的 CELL_FIELD_DEFINE 是两份
	# 字面量，但**同一个门**（cell_field_prefix_for_variant）。先问门，再挑载荷 —— 顺序
	# 反过来就等于把判定写两遍，那正是 §3.7 禁止的分叉。
	var water_field_segment := "" if cell_field_prefix_for_variant(
			true, false, enabled).is_empty() else WATER_FIELD_MATCHES_LAND_DEFINE
	return {
		"world_map": web_map_web_prefix_active() \
			+ cell_field_prefix_for_variant(true, true, enabled),
		# 顺序必须与 _create_water_quad 一致：载荷宏在 WATER_PASS_PREFIX **之前**。
		"world_water_web": water_field_segment + WATER_PASS_PREFIX,
		"world_map_high": WORLD_MAP_WEB_HIGH_PREFIX \
			+ cell_field_prefix_for_variant(true, false, enabled),
		"world_water_high": WATER_WEB_HIGH_PREFIX \
			+ cell_field_prefix_for_variant(true, false, enabled),
	}

## HIGH uses the PC surface code, with only WebGL sampler limits and split draws.
## HIGH 陆地 pass 不 include 水面管线（水面整段走 WATER_WEB_HIGH_PREFIX 的独立第二 pass），
## 启用 horizon 解码；noise_tex 恢复后两片共用同一采样器名额。
const WORLD_MAP_WEB_HIGH_BASE := PK_WEB_TEXTURE_BUDGET_DEFINE + "#define PK_WEB_PC_HIGH\n"
const WORLD_MAP_WEB_HIGH_PREFIX := WORLD_MAP_WEB_HIGH_BASE + "#define PK_WEB_SPLIT_WATER\n" \
	+ WORLD_MAP_WEB_LAND_ONLY_DEFINE + WORLD_MAP_WEB_HORIZON_DEFINE
const WATER_WEB_HIGH_PREFIX := WORLD_MAP_WEB_HIGH_BASE + "#define PK_WEB_WATER_ONLY\n"


static func web_pc_high_boot_enabled() -> bool:
	if Engine.has_meta("pk_web_pc_high_boot"):
		return bool(Engine.get_meta("pk_web_pc_high_boot"))
	if not OS.has_feature("web") or not DCFeatureFlags.is_compatibility_renderer():
		return false
	var raw := ""
	if Engine.has_singleton("JavaScriptBridge"):
		var bridge: Object = Engine.get_singleton("JavaScriptBridge")
		if bridge != null:
			raw = String(bridge.call("eval", "new URLSearchParams(window.location.search).get('quality') || ''")).strip_edges().to_lower()
	var enabled := true if raw == "high" else (false if (raw == "low" or raw == "medium") else not DCFeatureFlags.is_mobile_web())
	Engine.set_meta("pk_web_pc_high_boot", enabled)
	return enabled


static func _web_pc_high_active(host) -> bool:
	if not OS.has_feature("web") or not DCFeatureFlags.is_compatibility_renderer():
		return false
	return host.visual_quality >= 2 and web_pc_high_boot_enabled()



static func _cloud_shadow_direct_active(host) -> bool:
	return RendererCloudShadowBinding._cloud_shadow_direct_active(host)


## 只对「Compatibility 后端 + MOBILE_QUALITY_LOW 档」启用裁剪。
## 中/高档 web 仍保留 ctx.quality>=1 的水体分支，绝不跟着裁（否则会掉水面细节）；
## 宏链万一接错，shader 侧 #ifndef PK_QUALITY_LOW 的 #error 会立刻炸出来。

static func _world_map_web_min_active(host) -> bool:

	return DCFeatureFlags.uses_shader_quality_tier() \
		and DCFeatureFlags.is_compatibility_renderer() \
		and host._mobile_quality_tier_define == "MOBILE_QUALITY_LOW" \
		and not _web_pc_high_active(host)


# ─── [web-water-pass] 水面第二 pass（web 专属）─────────────────────────────
# 为什么（实测）：world_map 的 fragment 里「陆地管线 + 水面管线」两个着色来源同时
# 存在时，ANGLE/D3D11 上 FXC 的联合编译是 **20 291 ms**；只留陆地 2 473 ms、只留
# 水面 1 089 ms；而把水面换成只有 25 行的"紧凑版"仍有 **17 264 ms**（无分支 mix 版
# 18 060 ms）——悬崖与第二个来源的行数无关，是寄存器压力型的非线性。唯一有效做法
# 是让那个 fragment 只剩一个着色来源：水面整屏 quad 改成第二个 pass。
# 详细对账见 shaders/world_water_web.gdshader 文件头。
const WATER_SHADER_PATH := "res://shaders/world_water_web.gdshader"
## web-LOW 水面 pass 的**完整**编译前缀（运行期与菜单期预热的唯一真源）。
## 与 WORLD_MAP_WEB_PREFIX 同构但**不含** PK_WEB_WORLD_MIN：那个宏只对 world_map 的
## 裁剪有意义，水面 pass 本身就是被拆出去的那一半。少一个宏 = 驱动缓存不命中 =
## 菜单期那 1.1 s 预热白做，所以只能有一份字面量。
const WATER_PASS_PREFIX := QUALITY_PREFIX_LOW + PK_WEB_TEXTURE_BUDGET_DEFINE

## [land-water-split 2026-11-02] 桌面 / 移动的陆地 / 水面双 program 宏。Web 侧的
## PK_WEB_LAND_ONLY / PK_WEB_WATER_ONLY 前缀常量**一个字节都不动**，只有新增平台用这两个。
const SPLIT_LAND_ONLY_DEFINE := "#define PK_LAND_ONLY\n"
const SPLIT_WATER_ONLY_DEFINE := "#define PK_WATER_ONLY\n"
const WORLD_MAP_SHADER_PATH := "res://shaders/world_map.gdshader"

# ─── [cell-field 2026-11-18] 解析格界（方案 §3.10 / 契约 §4.3）───────────────
# 像素归属改由「世界坐标 + 一张连续扭曲场」解析算出，per-cell 属性走一张
# Texture2DArray（cell_table）。它**只是一个 define 前缀**，与 PK_LAND_ONLY /
# PK_WATER_ONLY 同一套拼装机制，不新开 shader 文件。
# 关闭时预处理器剔除全部新代码 ⇒ 与今日逐像素一致（截图 diff = 0 是验收项），
# 因此「关」的唯一正确实现是：一个字节都不拼进去（见 _cell_field_prefix）。
# 本常量是唯一真源 —— 两条拼装路径与测试都引用它，不许在别处写宏字面量。
const CELL_FIELD_DEFINE := "#define PK_CELL_FIELD\n"
## [cell-field-web 2026-11-18 / W3] Web LOW **水面第二 pass** 的「判据与陆地同源」宏。
##
## 为什么水面 pass 不用 PK_CELL_FIELD：它是**另一份独立编译**的 program，只含水面代码
## （`world_water_web.gdshader` 里没有陆地管线）。`PK_CELL_FIELD` 会把它拖回陆地分支的
## 符号与 uniform 集合；水面需要的只是"水陆判定、水深、海冰、岸距改读解析场"这一件事，
## 所以单独一个宏 —— 但**判定口必须与陆地完全相同**：谁走场函数由运行期唯一那个
## `_cell_field_prefix(host)` 决定，宏名只是两侧各自消费的载荷。
##
## 这就是方案 §3.7 第 1 条（两片 program 调同一个判定函数）在 GDScript 侧的实现：
## 陆地 program 拼 `CELL_FIELD_DEFINE`、水面 pass 拼本常量，两者由**同一个 if** 门控，
## 于是不可能出现"一侧带宏一侧不带"⇒ 海岸线上不会出现两片都不画的洞。
## 关 = 一个字节都不加（与 W3 之前逐字节一致，web_water_pass_node_test 的 ① 组守着）。
const WATER_FIELD_MATCHES_LAND_DEFINE := "#define PK_WATER_FIELD_MATCHES_LAND\n"
## 开关的项目设置键。命名遵循 `project_keynes/rendering/<子系>/<键>` 惯例
## （对照 visual_tile_layout.gd 的 map_tiles/mode、terrain_index_baker.gd 的 dem/）。
## **出货默认开**（2026-11-18 第二轮末尾打开）：`project.godot` 里显式写了
## `rendering/map_tiles/terrain_cell_field_enabled=true`，这里的 fallback 也是 `true`，
## 所以「读不到键」与「没有 project.godot」两种情形都不会把它悄悄关掉。
## 受限平台（Web / 桌面 Compatibility）仍要先过 boot 自检才启用，见下方的结论三态。
const CELL_FIELD_SETTING := "project_keynes/rendering/map_tiles/terrain_cell_field_enabled"


## 项目设置侧的解析格界开关（**默认 true**）。刻意不接受 host：它要被三处共用 ——
## renderer 的 export 初值（hex_renderer._init）、renderer 的公开转发
## （HexRenderer.cell_field_setting_enabled）与测试，三处必须读到同一个答案。
static func cell_field_setting_enabled() -> bool:

	return bool(ProjectSettings.get_setting(CELL_FIELD_SETTING, true))


# ─── [cell-field-web 2026-11-18] §3.5 启动自检 + 自动回退 ─────────────────────
# 三态结论 + 两个覆盖源，顺序固定（方案 §3.5「判定与回退」）：
#   1. URL `?cellfield=off|on` —— 最高优先级，线上排查用，跳过自检与缓存；
#   2. boot 自检结论（Engine meta）—— boot 期写一次后**固定**；
#   3. 未判定（meta 缺失）—— 桌面 Vulkan / 移动不需要自检 ⇒ 视为 pass；
#      Web / Compatibility 先自检再定 ⇒ 未判定一律**不启用**（见 cell_field_boot_allows）。
#
# meta 名与三态字面量是**跨模块契约**：`scripts/rendering/cell_field_web_probe.gd`
# 负责写，运行期前缀拼装（本文件）与预热（web_shader_warmup.gd）只读。
const PK_WEB_CELL_FIELD_BOOT_META: StringName = &"pk_web_cell_field_boot"
const CELL_FIELD_VERDICT_PASS := "pass"
const CELL_FIELD_VERDICT_FAIL := "fail"
const CELL_FIELD_VERDICT_SKIPPED := "skipped"
## URL 强制开关的**一次性**读取缓存（与 pk_web_pc_high_boot / PK_WEB_MICRO_BOOT_META
## 同模式）：`_cell_field_active()` 会在每次重建 program 时调到这里，不能每次都去 eval JS。
const PK_WEB_CELL_FIELD_FORCE_META: StringName = &"pk_web_cell_field_url_force"


## URL `cellfield` 参数 → 三态结论的**纯映射**（无 OS 副作用，便于测试）。
## 与 `micro_url_value_enabled()` 同构（同一套取值容忍度：大小写 / 空白不敏感）：
##   off / 0 / false → FAIL（强制回退旧路径，用于线上确认"是不是格界的问题"）
##   on  / 1 / true  → PASS（强制启用，用来在自检误判的机器上复现）
##   其它（含缺省 / unknown）→ ""（不强制，交给自检与缓存）
static func cellfield_url_verdict(raw: String) -> String:

	var value = String(raw).strip_edges().to_lower()
	if value == "off" or value == "0" or value == "false":
		return CELL_FIELD_VERDICT_FAIL
	if value == "on" or value == "1" or value == "true":
		return CELL_FIELD_VERDICT_PASS
	return ""


## 当前的 URL 强制结论（"" = 没有强制）。web 上读一次 URL 后缓存在 Engine meta：
## 游标只会读一次，并且非 web 恒为空串（桌面 / 移动没有 URL 可读）。
static func cell_field_url_forced_verdict() -> String:

	if Engine.has_meta(PK_WEB_CELL_FIELD_FORCE_META):
		return String(Engine.get_meta(PK_WEB_CELL_FIELD_FORCE_META))
	var raw := ""
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var bridge: Object = Engine.get_singleton("JavaScriptBridge")
		if bridge != null:
			raw = String(bridge.call("eval",
				"new URLSearchParams(window.location.search).get('cellfield') || ''"))
	var forced := cellfield_url_verdict(raw)
	Engine.set_meta(PK_WEB_CELL_FIELD_FORCE_META, forced)
	return forced


## boot 自检结论（"" = 未判定）。**只读**：写入口是 set_cell_field_boot_verdict()。
static func cell_field_boot_verdict() -> String:

	if not Engine.has_meta(PK_WEB_CELL_FIELD_BOOT_META):
		return ""
	return String(Engine.get_meta(PK_WEB_CELL_FIELD_BOOT_META))


static func cell_field_boot_decided() -> bool:

	return Engine.has_meta(PK_WEB_CELL_FIELD_BOOT_META)


## 写 boot 结论。**boot 后固定**：已有结论时是空操作并返回 false（方案 §3.5
## 「boot 后固定」——游戏中途切 URL 不该触发驱动重编）。
static func set_cell_field_boot_verdict(verdict: String) -> bool:

	if Engine.has_meta(PK_WEB_CELL_FIELD_BOOT_META):
		return false
	Engine.set_meta(PK_WEB_CELL_FIELD_BOOT_META, verdict)
	return true


## 清掉判定状态（只给测试 / GM 诊断用；生产路径没有任何调用点 —— 一旦判定就固定）。
static func reset_cell_field_boot_state() -> void:

	if Engine.has_meta(PK_WEB_CELL_FIELD_BOOT_META):
		Engine.remove_meta(PK_WEB_CELL_FIELD_BOOT_META)
	if Engine.has_meta(PK_WEB_CELL_FIELD_FORCE_META):
		Engine.remove_meta(PK_WEB_CELL_FIELD_FORCE_META)


## 自检结论是否允许启用（方案 §3.5 的「优先级」在这里唯一实现）。
## **meta 缺失按"未判定"处理**，绝不抛错：
##   桌面 Vulkan / 移动  → 不需要自检，视为 pass（v1 的旧行为不变）；
##   Web / Compatibility → 先跑自检再定，未判定期间保持旧路径（不能假绿）。
static func cell_field_boot_allows() -> bool:

	var forced := cell_field_url_forced_verdict()
	if forced == CELL_FIELD_VERDICT_FAIL:
		return false
	if forced == CELL_FIELD_VERDICT_PASS:
		return true
	var verdict := cell_field_boot_verdict()
	if verdict == CELL_FIELD_VERDICT_FAIL:
		return false
	if verdict == CELL_FIELD_VERDICT_PASS:
		return true
	return not DCFeatureFlags.is_compatibility_renderer()


## 某一套变体的 PK_CELL_FIELD 前缀片段（host-free 版本）。
## 运行期 `_cell_field_active(host)` 与预热 `web_warmup_program_prefixes()` **都**收敛到
## 这里的两条判定（变体准入 + boot 结论），于是「预热 = 运行期」是构造保证，不是巧合。
static func cell_field_prefix_for_variant(budget_variant: bool, world_min: bool,
		enabled: bool) -> String:

	if not enabled:
		return ""
	if not cell_field_variant_allowed(budget_variant, world_min):
		return ""
	if not cell_field_boot_allows():
		return ""
	return CELL_FIELD_DEFINE


## PK_CELL_FIELD 是否进当前 program 的编译前缀。**陆地与水面两条拼装路径都必须调它**：
## 方案 §3.7 —— is_water 由两边同一份场函数判定，一边带宏一边不带，海岸线上就会出现
## 「两片都 discard」的洞。所以这里做成单一判定口，而不是每个拼装点各写一个 if。
##
## [cell-field-web 2026-11-18 / W6] 最终形态 = 开关 ∧ boot 自检结论。原来的两条变体排除
## （budget / world-min）已随 W2（旧三槽从声明里删掉）与「world-min 与场函数正交」失效，
## 见 cell_field_variant_allowed() 的注释。变体准入那一步保留调用只是**形式**（恒真），
## 目的是让"哪套变体允许带宏"这件事继续只有一个出口，将来若再加排除不必改两处。
static func _cell_field_active(host) -> bool:

	if not host.terrain_cell_field_enabled:
		return false
	# ① 变体准入：W6 之后恒真（两个参数都被忽略），保留调用以维持单一出口与调用点形状。
	if not cell_field_variant_allowed(
			DCFeatureFlags.is_compatibility_renderer(), _world_map_web_min_active(host)):
		return false
	# ② [cell-field-web 2026-11-18] boot 自检结论（方案 §3.5）：Web / Compatibility 上
	# 必须自检过且不是 fail；桌面 Vulkan / 移动不需要自检，视为 pass（见
	# cell_field_boot_allows）。meta 缺失 = 未判定：受限平台上先跑自检再定，期间保持旧路径
	# ——桌面 Compatibility 的调用点见 renderer_scene_services.gd::_ready（首次建世界材质之前）。
	return cell_field_boot_allows()


## 变体准入（纯函数，便于测试与文档）：
##   budget_variant = 该变体会定义 PK_WEB_TEXTURE_BUDGET（8 槽设备预算）；
##   world_min      = 该变体是 PK_WEB_WORLD_MIN 降级程序。
## 两个参数都**保留但已忽略**：函数体现在恒为 true，调用点与测试真值表的形状不变。
##
## [cell-field-web 2026-11-18 / W6] 原来的两个排除都已失效：
## ① budget 变体：旧三槽（map_index_atlas / enum_lut / dyn_lut）在
##    `PK_CELL_FIELD_NO_LEGACY_LUT` 下**从声明里删掉**，四个 Web/Compat 前缀实测 8 → **6**
##    槽，不再是第 9 张白纹。以前那条"8 槽装不下 cell_table ⇒ 静默渲染损坏"的硬约束
##    随着 W2 的声明退役自动消失（terrain_shader_variant_test 的四套前缀普查每条都等值
##    断言 OFF=8 / PK=6，比"排除变体"更强：槽位真数出来）。
## ② world-min：`world_map.gdshader` 里 `#undef PK_CELL_FIELD` 的归一化已删除，world-min
##    与场函数正交（前者只把水面着色源搬到第二 pass）。terrain_shader_variant_test 现在
##    直接编译 `WORLD_MAP_WEB_PREFIX + PK_CELL_FIELD` 这份变体，编不过就红。
## 剩下唯一需要保留的是 §1.2 之外的兜底：`PK_WEB_WORLD_MIN` 变体本身仍走第二 pass 水面，
## 与场函数互不影响 —— 那条不变量由 WORLD_MAP_WEB_PREFIX* 的字节断言 + 水面 pass 前缀
## 不含 world-min 两条守着，不需要在这里排除整类变体。
static func cell_field_variant_allowed(budget_variant: bool, world_min: bool) -> bool:

	# 两个参数刻意保留在签名里（调用点与测试真值表的形状不变），但不再参与判定：
	# W6 之前这里返回 `not budget_variant and not world_min`。GDScript 的
	# unused_parameter 警告默认关闭，所以不需要额外的抑制注释。
	return true


## PK_CELL_FIELD 的前缀片段：开 = 一个 define 行，关 = 空串。
## 关时必须**恰好**是空串 —— 前缀字节契约（terrain_shader_variant_test 守着）要求
## 「关 = 与今日逐字节相同」，多一个换行都算破坏。
static func _cell_field_prefix(host) -> String:

	return CELL_FIELD_DEFINE if _cell_field_active(host) else ""


## [land-water-split 2026-11-02] 拆分总闸：全平台默认开；debug 视图与
## （Compatibility + tiled）自动回退单 program。同时被陆地变体（PK_LAND_ONLY）
## 与水面 pass（_water_pass_active）共同引用 —— 两处必须同源，否则会半边拆分。

static func _split_active(host) -> bool:

	if not host.split_land_water_passes:
		return false
	if host._split_program_failed:
		return false
	if host.terrain_surface_debug_view != 0:
		return false
	# 桌面 GLES3 的 tiled 诊断路径：预算 8 槽装不下两张 program 的完整采样集，
	# 且该组合只在桌面手工选 Compatibility 时出现，回退单 program。
	if DCFeatureFlags.is_compatibility_renderer() and _visual_tiles_active(host):
		return false
	return true


## 水面第二 pass 是否应该存在。Web 的既有判定原样保留（作为拆分判定的子集）：
## 只有 world-min（LOW）与 PC-HIGH 这两份 world_map 变体才把水面像素交给第二 pass；
## Web MID 的 world_map 自己画水（今天的行为，不新增 program）。
## 桌面 / 移动：拆分激活即始终有水面 pass（陆地 program 只画陆地）。

static func _water_pass_active(host) -> bool:

	if not _split_active(host):
		return false
	if OS.has_feature("web"):
		return DCFeatureFlags.is_compatibility_renderer() \
			and (_world_map_web_min_active(host) or _web_pc_high_active(host))
	return true


## 测试 / 诊断用强制水面 program 种类（"" = 按平台判定）。生产路径恒为 ""。

## 当前水面 pass 的源码种类（见 _water_program_kind 注释）。"" = 当前不应存在水面 pass。

static func _resolved_water_program_kind(host) -> String:

	if not host._forced_water_program_kind.is_empty():
		return host._forced_water_program_kind
	if _web_pc_high_active(host):
		return "high"
	if _world_map_web_min_active(host):
		return "web_min"
	if not OS.has_feature("web") and _water_pass_active(host):
		return "split"
	return ""


## 水面 program 的编译前缀。Web 两类沿用既有常量（字节契约）；桌面 / 移动按
## [MAP_VISUAL_TILED] + [MOBILE_QUALITY_*] + [PK_WEB_TEXTURE_BUDGET（仅 Compatibility）]
## + "#define PK_WATER_ONLY\n" 拼装（与陆地变体同一套顺序，便于测试逐段断言）。
static func _water_program_prefix(host, kind: String) -> String:

	var prefix = "#define MAP_VISUAL_TILED\n" if _visual_tiles_active(host) else ""
	if kind == "high":
		# [cell-field 2026-11-18] 与陆地 HIGH 变体（_apply_shader_variant_prefix 的
		# pc_high 提前返回分支）用**同一段**后缀，所以两边永远同源。
		# [W6 2026-11-18] HIGH 前缀含 PK_WEB_TEXTURE_BUDGET，而 W2 让 PK 变体降到 6 槽 ⇒
		# 这条排除已解除（见 cell_field_variant_allowed 的注释①），这里现在**真的**可能
		# 拼出 PK_CELL_FIELD。载荷宏仍是陆地那份 CELL_FIELD_DEFINE：HIGH 水面 pass 走的是
		# world_map.gdshader 里的水面代码，不是紧凑的 world_water_web。
		return prefix + WATER_WEB_HIGH_PREFIX + _cell_field_prefix(host)
	if kind == "web_min":
		# 紧凑水面程序：MAP_VISUAL_TILED 之外只有 WATER_PASS_PREFIX（_create_water_quad 追加）。
		# [cell-field-web 2026-11-18 / W3] 载荷宏 PK_WATER_FIELD_MATCHES_LAND 必须在这里
		# 注入（return 之前），因为 _create_water_quad 拼的是
		#   variant.code = prefix + ("" if world_map_based else WATER_PASS_PREFIX) + shader.code
		# ⇒ 最终字节序是 [MAP_VISUAL_TILED] [MATCHES_LAND] [WATER_PASS_PREFIX] [source]。
		# 预热侧（web_warmup_program_prefixes 的 world_water_web 项）必须拼出**同一个顺序、
		# 同一批字面量**，差一个字节驱动就不认 program 缓存、菜单期那 1.1 s 白做。
		#
		# 判定口是 `_cell_field_prefix(host)` —— **陆地 program 的那一个**，不是这里再判一次
		# budget / world-min / 平台 / 画质。方案 §3.7：两片 program 各判一套 ⇒ 海岸线两侧
		# 归属不同 ⇒ 出现"两片都不画"的洞。所以这里只**转发**陆地的结论，本分支不出现
		# 任何 `is_compatibility_renderer` / `_world_map_web_min_active`。
		if not _cell_field_prefix(host).is_empty():
			prefix += WATER_FIELD_MATCHES_LAND_DEFINE
		return prefix
	if kind != "split":
		return prefix
	if host._mobile_quality_tier_define != "" and DCFeatureFlags.uses_shader_quality_tier():
		prefix += _shader_quality_define_prefix(host, host._mobile_quality_tier_define)
		if host._mobile_quality_tier_define == "MOBILE_QUALITY_LOW" and host._graphics_details.water_detail == 0:
			prefix += "#define PK_WATER_FLAT_LOW\n"
	else:
		prefix += _desktop_sky_quality_prefix(host)
	if DCFeatureFlags.is_compatibility_renderer():
		prefix += PK_WEB_TEXTURE_BUDGET_DEFINE
	if _cloud_shadow_direct_active(host):
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	prefix += host.SPLIT_WATER_ONLY_DEFINE
	# [cell-field 2026-11-18] 放在**最后**：既有 define 的顺序一个字节都不动（字节契约），
	# 而「关 = 空串」时这条语句本身不产生任何字节。陆地侧的同名调用在
	# _apply_shader_variant_prefix 末尾，两处顺序都是「… → WATER/LAND_ONLY → CELL_FIELD」。
	# [W6 2026-11-18] 桌面 Compatibility 也会走上面加 PK_WEB_TEXTURE_BUDGET 的那一行，而
	# 变体准入已恒真 ⇒ 这里不再"恒为空串"：Compatibility 的水面 pass 也会带宏（6 槽仍够）。
	prefix += _cell_field_prefix(host)
	return prefix


## [land-water-split 2026-11-02] 只给世界地图主材质加拆分宏（world_material 理论上
## 可以指向别的 shader，那种情况不能被误加 PK_LAND_ONLY）。

static func _is_world_map_shader_path(host, path: String) -> bool:

	if path == host.WORLD_MAP_SHADER_PATH or path == host.shader_path:
		return true
	return not path.is_empty() and path.get_file() == "world_map.gdshader"



static func _desktop_sky_quality_prefix(host) -> String:

	if OS.has_feature("web") or DCFeatureFlags.is_compatibility_renderer() \
			or not host._mobile_quality_tier_define.is_empty():
		return ""
	match host.visual_quality:
		1:
			return "#define PK_SKY_QUALITY_MID\n"
		2:
			return "#define PK_SKY_QUALITY_HIGH\n"
	return ""



static func _apply_shader_variant_prefix(host, shader: Shader, source_path: String) -> Shader:

	if shader == null:
		return null
	if _web_pc_high_active(host):
		var high_shader = shader.duplicate() as Shader
		# [cell-field 2026-11-18] 与水面 HIGH 前缀（_water_program_prefix 的 "high" 分支）
		# 用**同一段**后缀，所以两边永远同源。
		# [W6 2026-11-18] HIGH 前缀含 PK_WEB_TEXTURE_BUDGET，但 W2 已把 PK 变体降到 6 槽 ⇒
		# 这条排除解除，`high_cell_field` 现在真的可能非空（见 cell_field_variant_allowed）。
		var high_cell_field := "" if not _is_world_map_shader_path(host, source_path) \
			else _cell_field_prefix(host)
		high_shader.code = ("#define MAP_VISUAL_TILED\n" if _visual_tiles_active(host) else "") \
			+ WORLD_MAP_WEB_HIGH_PREFIX + high_cell_field + shader.code
		WebTelemetry.note_variant("world_map_high", high_shader.code)
		return high_shader
	var prefix = ""
	if _visual_tiles_active(host):
		prefix += "#define MAP_VISUAL_TILED\n"
	if _is_world_map_shader_path(host, source_path):
		prefix += _desktop_sky_quality_prefix(host)
	if _cloud_shadow_direct_active(host) and _is_world_map_shader_path(host, source_path):
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	# mobile/web 共用 MOBILE_QUALITY_* 编译期档（由 set_mobile_quality_tier 推送）。
	if host._mobile_quality_tier_define != "" and DCFeatureFlags.uses_shader_quality_tier():
		prefix += _shader_quality_define_prefix(host, host._mobile_quality_tier_define)
	# [pk-web-texture-budget] Compatibility(GLES3/WebGL2) 后端只保证 16 个
	# fragment 纹理单元；world_map.gdshader 是按桌面 Forward+/Mobile(32+) 预算
	# 声明的 sampler 数量，超预算会在链接期报
	# "texture image units count exceeds MAX_TEXTURE_IMAGE_UNITS(16)" 并整体
	# 渲染失败。裁掉若干装饰性 sampler（terrain_micro / bounce_lut / upwelling /
	# detail/edge/normal/water_depth/gi_occluder 等）。2026-08-06 起主地形不再
	# 声明 eco_lut，腾出的槽给 terrain_material_tex；同日 height+flow 合并再省 1 槽。
	if DCFeatureFlags.is_compatibility_renderer():
		prefix += PK_WEB_TEXTURE_BUDGET_DEFINE
		# [web-world-min] 只有 LOW 档才有裁过的变体。顺序必须与
		# WORLD_MAP_WEB_PREFIX(_MICRO) 完全一致（quality → texture_budget → world_min →
		# [no_micro] → land_only → horizon），否则运行期与预热前缀不同 → 驱动缓存不命中。
		# [terrain-web-baked-surface] 两个吸收宏跟着 world-min 变体走：Web 上该变体就是
		# 全部档位；桌面 Compatibility 的 MID/HIGH 仍走完整水面管线（没有第二 pass）。
		# [C 2026-11-01] micro 默认**放开**（A/B 实测更快 -15%，见 WORLD_MAP_WEB_PREFIX_MICRO
		# 注释）；只有 URL kill-switch（micro=off|0|false）或非 web 时才追加
		# PK_PROBE_NO_MICRO。两条分支分别与 WORLD_MAP_WEB_PREFIX_MICRO / WORLD_MAP_WEB_PREFIX
		# 逐字节一致，预热用同一函数（WebShaderWarmup.world_map_prefix_active）。
		if _world_map_web_min_active(host):
			prefix += WORLD_MAP_WEB_MIN_DEFINE
			if not web_map_micro_url_enabled():
				prefix += WORLD_MAP_WEB_NO_MICRO_DEFINE
			prefix += WORLD_MAP_WEB_LAND_ONLY_DEFINE + WORLD_MAP_WEB_HORIZON_DEFINE
	# [land-water-split 2026-11-02] 桌面 / 移动拆分：主材质只画陆地（水面第二 pass）。
	# 与 Web 的关系：Web 的 land-only 宏由上面的字节契约常量给出，这里绝不追加
	# PK_LAND_ONLY，保证 Web 变体前缀逐字不变、预热指纹仍对得上。
	if not OS.has_feature("web") and _water_pass_active(host) and _is_world_map_shader_path(host, source_path):
		prefix += host.SPLIT_LAND_ONLY_DEFINE
	# [cell-field 2026-11-18] 解析格界（方案 §3.10）：放在**最后**，因为它是给全平台 /
	# 全档位用的最后一段，且既有 define 的顺序（quality → texture_budget → world_min →
	# [no_micro] → land_only → horizon / LAND_ONLY）一个字节都不动 —— 那段顺序是驱动缓存
	# 与预热指纹的契约。关的时候 _cell_field_prefix() 返回空串 ⇒ 上面的 prefix 与今日
	# 逐字节相同（这是「关 = 逐像素一致」在代码层的唯一保证）。
	# [W6 2026-11-18] 上面加了 PK_WEB_TEXTURE_BUDGET 的分支（Web 全档 + 桌面 Compatibility）
	# 现在**也会**带这个宏：变体准入已恒真，槽位由 8→6 的普查兜住（不再是第 9 张白纹）。
	# 只给 world_map 源码加：别的材质不认识这个宏。
	if _is_world_map_shader_path(host, source_path):
		prefix += _cell_field_prefix(host)
	if prefix.is_empty():
		return shader
	var variant = shader.duplicate() as Shader
	variant.code = prefix + shader.code
	print("[hex_renderer/variant] tiled=%s quality=%s web_texture_budget=%s web_world_min=%s shader=%s" % [
		_visual_tiles_active(host), host._mobile_quality_tier_define,
		DCFeatureFlags.is_compatibility_renderer(), _world_map_web_min_active(host), source_path])
	return variant



static func _shader_quality_define_prefix(host, tier_define: String) -> String:

	# 只给「档位」宏，**绝不**在这里重复 #define PK_QUALITY_* / PK_MOBILE_ANY：
	# shader_quality.gdshaderinc 已经按档位展开出这些别名，再定义一次会让 Godot 的
	# shader 预处理器报重复定义 → shader type '' → 材质退回默认白纹理。
	# web 上的表现就是"切到中/高画质地面全白"（低画质因为曾经修过所以正常）。
	match tier_define:
		"MOBILE_QUALITY_LOW":
			return QUALITY_PREFIX_LOW
		"MOBILE_QUALITY_HIGH":
			return "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n"
		_:
			return "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n"
