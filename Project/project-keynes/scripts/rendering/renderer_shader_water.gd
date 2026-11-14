extends RefCounted

## Stateless collaborator for ShrubLayer.

static func _web_weather_layer_draw_allowed(host) -> bool:

	if not OS.has_feature("web"):
		return true
	if not host.PK_WEB_ENABLE_WEATHER_LAYER:
		return false
	return host.visual_quality >= 2 or host._mobile_quality_tier_define == "MOBILE_QUALITY_HIGH"


## 上一次推给天气层的门状态（只用于首帧/切档时打一行诊断）。


## 把「web + 是否高画质」推给 WeatherLayer 的画质门。
## 门状态在 WeatherLayer 内部与 fronts/LUT 条件取与，所以关着门时它不会被
## setup()/fronts 更新重新显示。画质设置、shader 档位切换都调这里。

static func _apply_weather_layer_render_gate(host) -> void:

	if host._weather_layer == null or not host._weather_layer.has_method("set_render_gate"):
		return
	var allowed: bool = _web_weather_layer_draw_allowed(host)
	host._weather_layer.set_render_gate(allowed)
	if OS.has_feature("web") and allowed != host._weather_gate_last_drawn:
		host._weather_gate_last_drawn = allowed
		print("[hex_renderer] web: WeatherLayer drawn=%s (visual_quality=%d tier=%s; web draws only at 高画质)" % [
			str(allowed), host.visual_quality, host._mobile_quality_tier_define])


# 每帧把 world_time 推进给 shader（驱动洋流流纹）
# 注意：这里只 push 一个 float uniform，几乎零开销

static func _visual_tiles_active(host) -> bool:

	return host._world != null and host._world.visual_tiles != null \
		and bool(host._world.visual_tiles.ready) \
		and String(host._world.visual_tiles.layout.mode) == "tiled"


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

## HIGH uses the PC surface code, with only WebGL sampler limits and split draws.
## HIGH 陆地 pass 不 include 水面管线（水面整段走 WATER_WEB_HIGH_PREFIX 的独立第二 pass），
## 启用 horizon 解码；noise_tex 恢复后两片共用同一采样器名额。
const WORLD_MAP_WEB_HIGH_BASE := PK_WEB_TEXTURE_BUDGET_DEFINE + "#define PK_WEB_PC_HIGH\n"
const WORLD_MAP_WEB_HIGH_PREFIX := WORLD_MAP_WEB_HIGH_BASE + "#define PK_WEB_SPLIT_WATER\n" \
	+ WORLD_MAP_WEB_LAND_ONLY_DEFINE + WORLD_MAP_WEB_HORIZON_DEFINE
const WATER_WEB_HIGH_PREFIX := WORLD_MAP_WEB_HIGH_BASE + "#define PK_WEB_WATER_ONLY\n"


static func _web_pc_high_active(host) -> bool:

	if not OS.has_feature("web") or not DCFeatureFlags.is_compatibility_renderer():
		return false
	# A runtime settings toggle must stay on the already compiled shared Web
	# program. Full PC HIGH is selected only when the page requested it before
	# world creation; compiling a new ANGLE program during play freezes the tab.
	if not Engine.has_meta("pk_web_pc_high_boot"):
		var requested = false
		if Engine.has_singleton("JavaScriptBridge"):
			var bridge: Object = Engine.get_singleton("JavaScriptBridge")
			if bridge != null:
				var raw: Variant = bridge.call("eval", "new URLSearchParams(window.location.search).get('quality') || ''")
				requested = String(raw).to_lower() == "high"
		Engine.set_meta("pk_web_pc_high_boot", requested)
	return host.visual_quality >= 2 and bool(Engine.get_meta("pk_web_pc_high_boot", false))



static func _cloud_shadow_direct_active(host) -> bool:

	return host.CloudShadowFieldScript.direct_mode_for_quality(
		host.visual_quality,
		OS.has_feature("mobile") or OS.has_feature("web"),
		host._mobile_quality_tier_define)


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
		return prefix + WATER_WEB_HIGH_PREFIX
	if kind == "web_min":
		# 紧凑水面程序：MAP_VISUAL_TILED 之外只有 WATER_PASS_PREFIX（_create_water_quad 追加）。
		return prefix
	if kind != "split":
		return prefix
	if host._mobile_quality_tier_define != "" and DCFeatureFlags.uses_shader_quality_tier():
		prefix += _shader_quality_define_prefix(host, host._mobile_quality_tier_define)
	else:
		prefix += _desktop_sky_quality_prefix(host)
	if DCFeatureFlags.is_compatibility_renderer():
		prefix += PK_WEB_TEXTURE_BUDGET_DEFINE
	if _cloud_shadow_direct_active(host):
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	prefix += host.SPLIT_WATER_ONLY_DEFINE
	return prefix


## [land-water-split 2026-11-02] 世界地图材质的统一 uniform 推送口。
## 陆地材质 _shader_mat 是权威；拆分后水面 program 必须与陆地**逐项同值**，否则两片
## 之间会有色差。这里把键值同时镜像给水面材质（只在它真的声明过该键时写，紧凑水的
## uniform 集合与主材质不同）。运行期 94 个 setter 的推送全部经过本函数，
## 保证 season / TOD / fog / 羊皮纸 / camera zoom / water 调参 / LUT 等不会只到一半。

static func _push_world_uniform(host, key: Variant, value: Variant) -> void:

	var key_name = StringName(key)
	if host._shader_mat != null:
		host._shader_mat.set_shader_parameter(key_name, value)
	if host._water_mat != null and not host._water_uniform_names.is_empty() \
			and host._water_uniform_names.has(key_name):
		host._water_mat.set_shader_parameter(key_name, value)



static func _global_sky_day_weight(host) -> float:

	if not host.day_night_enabled:
		return 1.0
	return smoothstep(-0.14, 0.14, sin(6.283185307179586 * host._day_phase))


static func configure_shader_clock(host, apply: Callable) -> void:

	host._apply_shader_clock = apply
	if host._apply_shader_clock.is_valid():
		host._apply_shader_clock.call(host.shader_days_per_game_year)



static func _push_eternal_daylight_uniforms(host) -> void:

	var min_elevation = deg_to_rad(host.eternal_min_elevation_deg)
	var max_hour_angle = deg_to_rad(host.eternal_max_hour_angle_deg)
	_push_world_uniform(host, "eternal_min_elevation_rad", min_elevation)
	_push_world_uniform(host, "eternal_max_hour_angle_rad", max_hour_angle)
	_push_water_lighting_uniforms(host)
	if host._building_visual_layer != null and host._building_visual_layer.has_method("set_eternal_daylight_parameters"):
		host._building_visual_layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	if host._weather_layer != null and host._weather_layer.has_method("set_eternal_daylight_parameters"):
		host._weather_layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	if host._fog_layer != null and host._fog_layer.has_method("set_eternal_daylight_parameters"):
		host._fog_layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	_for_each_vegetation_layer(host, func(layer) -> void:
		if layer.has_method("set_eternal_daylight_parameters"):
			layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	)
	_sync_detail_and_activity_materials(host)



static func _bind_world_lighting_profile(host) -> void:

	if host._sky_background != null:
		var bounds = host._world.world_bounds if host._world != null else Rect2()
		host._sky_background.setup(bounds, host.world_lighting_profile, host._day_phase, host.day_night_enabled)
	if host._shader_mat != null:
		host._push_world_lighting_profile()



static func _shader_declares_uniform(host, shader: Shader, uniform_name: StringName) -> bool:

	if shader == null:
		return false
	for uniform in shader.get_shader_uniform_list():
		if StringName(uniform.get("name", "")) == uniform_name:
			return true
	return false


const WATER_PARAM_NAMES: Array[StringName] = [
	&"water_effect_enabled",
	&"ocean_current_enabled",
	&"water_waves_enabled",
	&"water_fresnel_enabled",
	&"water_sparkle_enabled",
	&"caustics_enabled",
	&"shallow_transparency_enabled",
	&"water_flow_wave_density",
	&"water_flow_advection",
	&"water_flow_wave_amplitude",
	&"water_flow_crest_strength",
	&"water_mark_strength",
	&"water_mark_coverage",
	&"water_base_normal_strength",
	&"water_base_normal_scale",
	&"water_wave_shade_strength",
	&"water_ripple_strength",
	&"water_ripple_detail_mix",
	&"water_ripple_scale",
	&"water_flow_drift_base",
	&"water_flow_drift_current",
	&"water_mark_length",
	&"water_mark_speed",
	&"water_rough_min",
	&"water_rough_max",
	&"water_rough_scale",
	&"water_rough_coverage",
	&"ocean_current_strength",
	&"water_reflection_strength",
	&"water_sss_strength",
	&"water_sss_power",
	&"water_sss_color",
	&"caustics_strength",
	&"shallow_transparency_factor",
	&"deep_ocean_contrast",
	&"deep_ocean_color_richness",
	&"deep_ocean_current_tint_strength",
	&"deep_ocean_latitude_tint_strength",
	&"deep_ocean_abyss_tint_strength",
	&"deep_ocean_patch_boost",
	&"water_cartoon_color_strength",
	&"water_calm_noise_brightness",
	&"water_calm_noise_tint_strength",
	&"water_wave_line_strength",
	&"water_domain_warp_strength",
	&"water_biome_blend_radius",
	&"water_transition_softness",
	&"estuary_plume_strength",
	&"lake_water_color",
	&"river_flow_enabled",
	&"river_flow_speed",
	&"river_flow_freq",
	&"water_wave_patch_strength",
	&"water_wave_patch_scale",
	&"water_detail_normal_strength",
	&"water_detail_normal_scale",
	&"water_detail_normal_warp",
]

## 水面参数的运行期推送：_shader_mat 还没创建（场景反序列化阶段）时安全跳过，
## 之后由 _push_water_params_to() 补推初值。

static func _push_water_param(host, key: StringName, value: Variant) -> void:

	if host._shader_mat != null:
		_push_world_uniform(host, key, value)


static func _assign_water_param(host, key: StringName, value: Variant) -> Variant:

	_push_water_param(host, key, value)
	return value


static func _assign_world_uniform(host, key: StringName, value: Variant) -> Variant:

	if host._shader_mat != null:
		_push_world_uniform(host, key, value)
	return value


static func _assign_shader_days_per_game_year(host, value: Variant) -> Variant:

	if host._apply_shader_clock.is_valid():
		host._apply_shader_clock.call(value)
	return value


static func _assign_weather_cloud_opacity(host, value: Variant) -> Variant:

	if host._weather_layer != null and is_instance_valid(host._weather_layer):
		host._weather_layer.set_cloud_opacity_scale(value)
	return value


static func _assign_cloud_shadow_debug_view(host, value: Variant) -> Variant:

	if host._cloud_shadow_field != null:
		host._cloud_shadow_field.set_debug_view(value)
	return value


static func _apply_surface_debug_view(host, was_split: bool) -> void:

	host._push_world_uniform("terrain_surface_debug_view", host.terrain_surface_debug_view)
	# [web-water-pass] 诊断色由 pass 1 整屏输出，水面 pass 必须整体让位。
	if host._water_mat != null:
		host._water_mat.set_shader_parameter(
			"terrain_surface_debug_view", host.terrain_surface_debug_view)
	# [land-water-split 2026-11-02] debug 视图必须回退单 program + 整张 quad
	# （13/14/16/17 等要全屏覆盖；gi_debug_view 只在陆地管线里，水面 program 复现不了）。
	# 拆分状态翻转时重编变体 + 重铺几何 + 重推全部 uniform。
	if was_split != host._split_active():
		host._refresh_split_configuration()


static func _apply_split_land_water_passes(host) -> void:
	# 重新允许尝试：上一次编译失败可能只是临时状态（shader 刚被编辑/驱动抖动）。
	host._split_program_failed = false
	host._water_pass_failed = false
	host._refresh_split_configuration()


## 调试控制台 / GM 面板用的两个总开关入口（属性本身已带内联 setter，这里只多刷一次光照 uniform）。

static func set_water_effect_enabled(host, v: bool) -> void:

	host.water_effect_enabled = v
	_push_water_lighting_uniforms(host)



static func set_ocean_current_enabled(host, v: bool) -> void:

	host.ocean_current_enabled = v
	_push_water_lighting_uniforms(host)



static func set_map_baker(host, baker) -> void:

	host._map_baker = baker



static func set_ocean_current_debug(host, v: bool) -> void:

	host._ocean_current_debug = v
	if host._shader_mat != null:
		host._push_world_uniform("ocean_current_debug", host._ocean_current_debug)
	# 方案 0：仅当切到 true 且贴图缺失时才 lazy bake upwelling_tex。
	if host._ocean_current_debug and host._world != null and host._world.upwelling_tex == null \
			and host._map_baker != null and host._map_baker.has_method("rebake_upwelling_tex_for_debug"):
		var t0 := Time.get_ticks_msec()
		if host._map_baker.rebake_upwelling_tex_for_debug(host._world):
			print("[VisualOverhaul] ocean_current_debug → lazy baked upwelling_tex in %dms"
					% (Time.get_ticks_msec() - t0))
		if host._shader_mat != null:
			host._push_world_uniform("ocean_upwelling_tex", host._world.upwelling_tex)



static func get_ocean_current_debug(host) -> bool:

	return host._ocean_current_debug


## 把全部水面参数一次推给指定材质（主地形材质 / 独立水面材质）。

static func _push_water_params_to(host, sm: ShaderMaterial) -> void:

	if sm == null:
		return
	for n in host.WATER_PARAM_NAMES:
		sm.set_shader_parameter(n, host.get(n))



## 拆分状态 / 覆盖 mesh 开关翻转后的统一重建入口：重新选 program 变体 + 重铺几何
## + 重推全部 uniform（其末尾会按新的拆分状态建/拆水面 pass）。

static func _refresh_split_configuration(host) -> void:

	if not host.is_inside_tree() or host._world_quad == null:
		return
	if host._map == null or host._world == null:
		return
	host._load_shader()
	host._apply_world_quad_geometry()
	if host._shader_mat != null:
		host._apply_uniforms()


## 水面 program shader 变体编不过 → 整条拆分回退单 program（推迟到下一帧，避免在
## _sync_water_quad 的内部重入 _apply_uniforms）。只用于非 Web；Web 保持既有的
## "land-only + 暗海蓝占位"降级。

static func _apply_split_program_fallback(host) -> void:

	if not host._split_program_failed:
		return
	if host._world_quad == null or host._shader_mat == null:
		return
	push_warning("[hex_renderer/land-water-split] water program failed to compile; "
		+ "falling back to the single terrain program")
	host._load_shader()
	if host._map == null or host._world == null:
		return
	host._apply_world_quad_geometry()
	if host._shader_mat != null:
		host._apply_uniforms()


## 建/拆 + 几何 + uniform 全量对齐。调用点只有 _apply_uniforms() 末尾：
## 材质重建（_load_shader）、画质换档（set_mobile_quality_tier）、set_map(_cooperative)
## 都会经过 _apply_uniforms，所以这里不需要额外的调用点。稳态下是几次引用比较。

static func _sync_water_quad(host) -> void:

	if not _water_pass_active(host) or host._world_quad == null or host._world == null \
			or host._water_pass_failed:
		_drop_water_quad(host)
		return
	_ensure_water_quad(host)


## 无条件保证「节点存在 + 几何/树序/变体正确 + uniform 全量推送」。
## 与平台判定（_water_pass_active）分开，是为了让测试能直接驱动这条创建路径
## （见 tests/world/web_water_pass_node_test.gd / land_water_split_node_test.gd）。

static func _ensure_water_quad(host) -> void:

	var kind = _resolved_water_program_kind(host)
	# tiled 布局切换会换掉 map_index/height 的 sampler **类型**（sampler2D ↔
	# sampler2DArray），variant 必须跟着重编；画质换档会换 MOBILE_QUALITY_* 前缀。
	# 两个维度任一变化都重建，不能复用旧的材质。稳态下是两次字符串比较。
	var prefix = _water_program_prefix(host, kind)
	if host._water_quad != null and (host._water_variant_prefix != prefix or host._water_variant_kind != kind):
		_drop_water_quad(host)
	if host._water_quad == null:
		_create_water_quad(host, prefix, kind)
	if host._water_quad == null or not is_instance_valid(host._water_quad):
		return
	host._water_quad.mesh = _water_quad_mesh(host, host._world_quad.mesh)
	host._water_quad.visible = host._world_quad.visible
	_apply_water_uniforms(host)


## 拆分时水面 mesh 用覆盖 mesh；未启用 / 构建失败 ⇒ 与陆地共享整张 quad。

static func _water_quad_mesh(host, fallback: Mesh) -> Mesh:

	if host._coverage_water_mesh != null:
		return host._coverage_water_mesh
	return fallback


## 拆掉第二 pass 的节点与材质。先隐藏再 queue_free：queue_free 到帧末才生效，
## 不隐藏的话换档那一帧还会按旧变体多画一次水面。

static func _drop_water_quad(host) -> void:

	if host._water_quad != null:
		host._water_quad.visible = false
		host._water_quad.queue_free()
		host._water_quad = null
	host._water_mat = null
	host._water_variant_prefix = ""
	host._water_variant_kind = ""
	host._water_program_kind = ""
	host._water_uses_world_map = false
	host._water_uniform_names.clear()



static func _create_water_quad(host, prefix: String, kind: String) -> void:

	# 刻意用 ResourceLoader.load 而不是 preload 常量：preload 是编译期的，桌面端
	# 也会把这份 shader 资源拉进依赖图。只有水面 pass 真的存在时才执行。
	var world_map_based = kind != "web_min"
	var water_path = host.WORLD_MAP_SHADER_PATH if world_map_based else host.WATER_SHADER_PATH
	var shader = ResourceLoader.load(
		water_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("HexRenderer: water pass shader missing at %s" % water_path)
		return
	var variant = shader.duplicate() as Shader
	# tiled 与否必须与 world_map 用同一个宏（visual_tile_sampling 据此在
	# sampler2D / sampler2DArray 之间二选一）；quality / texture-budget / WATER_ONLY
	# 已在 prefix 里。紧凑水面程序再追加自己的 WATER_PASS_PREFIX（字节契约）。
	variant.code = prefix + ("" if world_map_based else WATER_PASS_PREFIX) + shader.code
	# 编译自检：shader 语言层编不过时 get_shader_uniform_list() 返回空。桌面/移动
	# 此时**整条拆分回退单 program**（不能只回退一半：陆地 program 此时不带水面分支，
	# 只回退水会露出空洞）。Web 维持既有降级：不建第二 pass，屏幕是 pass 1 的暗海蓝
	# 占位色（可控、可读）。驱动层失败（FXC）这里抓不到，那种情况同样退回占位色。
	if variant.get_shader_uniform_list().is_empty():
		host._water_pass_failed = true
		push_error("HexRenderer: water pass shader failed to compile (%s, kind=%s, prefix=%s)"
			% [water_path, kind, prefix.replace("\n", "|")])
		if not OS.has_feature("web"):
			host._split_program_failed = true
			host.call_deferred("_apply_split_program_fallback")
		return
	host._water_variant_prefix = prefix
	host._water_variant_kind = kind
	host._water_program_kind = kind
	host._water_uses_world_map = world_map_based
	host._water_uniform_names.clear()
	for param in variant.get_shader_uniform_list():
		host._water_uniform_names[StringName(param.name)] = true
	host._water_mat = ShaderMaterial.new()
	host._water_mat.shader = variant
	host._water_quad = MeshInstance2D.new()
	host._water_quad.name = "WorldWaterQuad"
	# z_index 与 _world_quad 同为 0（CanvasItem 先按 z_index、再按树序绘制），树序由
	# move_child 钉死在 _world_quad 紧后面 ⇒ 水面盖住陆地、又被植被(z=1)/建筑(z=3)盖住。
	# 必须 move_child 而不是依赖 add_child 顺序：画质从 MID 换回 LOW 时本节点是**后来**
	# 才创建的，直接 add_child 会排到植被层后面 → 水面盖住整片植被。
	host._water_quad.z_index = 0
	# FPS 探针（toggle_world_shader_disabled）关闭主 shader 时，两片必须一起关。
	host._water_quad.material = null if host._shader_disabled_by_toggle else host._water_mat
	host.add_child(host._water_quad)
	if is_instance_valid(host._world_quad):
		host.move_child(host._water_quad, mini(host._world_quad.get_index() + 1, host.get_child_count() - 1))
	# 预热对账：label 必须与 WebShaderWarmup 清单里那份（文件名去扩展名）逐字一致，
	# 否则 material_variant 事件永远对不上 warmup_shader 的 fp。桌面/移动拆分变体
	# 没有预热条目（不在 web 上编），不打 label。
	match kind:
		"high":
			WebTelemetry.note_variant("world_water_high", variant.code)
		"web_min":
			WebTelemetry.note_variant("world_water_web", variant.code)
	print("[hex_renderer] water pass created (pass 2 of 2; kind=%s)" % kind)


## 水面 pass 的 uniform 全量推送。web_min（紧凑水面）刻意只有 16 个（4 sampler +
## 12 标量/vec），与 world_map 的 186 个无关：这是它的全部输入。
## [land-water-split 2026-11-02] 走 world_map 的水面 program（Web HIGH / 桌面拆分）
## 复用主材质的整表拷贝（与 Web HIGH 原有逻辑同一份），保证 season/TOD/fog/羊皮纸/
## 光照/wrap/cell LUT/water_depth/noise 与陆地**逐项同值**；之后运行期的增量变化由
## _push_world_uniform() 镜像。
## 分工：几何/调色板/迷雾在各自已有的推送点补推（_push_fog_uniforms /
## _push_cell_lut_dims / _sync_cell_lut_textures / setter），这里负责"材质重建后
## 一次性把全部输入对齐"，与 _apply_uniforms() 的职责一一对应。

static func _apply_water_uniforms(host) -> void:

	host.RendererLightingBindings._apply_water_uniforms(
		host._shader_mat,
		host._water_mat,
		host._water_uses_world_map,
		host._world,
		host.parchment_strength,
		host.parchment_tint,
		host.terrain_ecotone_width,
		host.terrain_surface_debug_view,
		host._push_visual_tile_layout_uniforms,
		host._push_water_fog_uniforms,
		host._push_water_lighting_uniforms,
		host._push_water_params_to,
		host._visual_tiles_active,
		host._wrap_period_x)



static func _push_water_lighting_uniforms(host) -> void:

	if host._water_mat == null:
		return
	host._water_mat.set_shader_parameter("visual_quality", host.visual_quality)
	host._water_mat.set_shader_parameter("season_phase", host._season_phase)
	host._water_mat.set_shader_parameter("day_phase", host._day_phase)
	host._water_mat.set_shader_parameter("axial_tilt_rad", deg_to_rad(host.axial_tilt_deg))
	host._water_mat.set_shader_parameter("day_night_enabled", host.day_night_enabled)
	host._water_mat.set_shader_parameter("water_effect_enabled", host.water_effect_enabled)
	host._water_mat.set_shader_parameter("ocean_current_enabled", host.ocean_current_enabled)
	host._water_mat.set_shader_parameter("tod_sun_dir", host._tod_sun_dir)
	host._water_mat.set_shader_parameter("tod_exposure", host._tod_exposure)
	host._water_mat.set_shader_parameter("tod_debug_sun_position_enabled", host._tod_debug_sun_position_enabled)
	host._water_mat.set_shader_parameter("tod_debug_sun_uv", host._tod_debug_sun_uv)
	host._water_mat.set_shader_parameter("tod_debug_sun_height_scale", host._tod_debug_sun_height_scale)
	host._water_mat.set_shader_parameter("eternal_min_elevation_rad", deg_to_rad(host.eternal_min_elevation_deg))
	host._water_mat.set_shader_parameter("eternal_max_hour_angle_rad", deg_to_rad(host.eternal_max_hour_angle_deg))



static func _configure_cloud_shadow_field(host) -> void:

	if host._cloud_shadow_field == null:
		return
	if host._weather_layer != null and not host._cloud_shadow_field.wind_lut_changed.is_connected(host._weather_layer.set_wind_luts):
		host._cloud_shadow_field.wind_lut_changed.connect(host._weather_layer.set_wind_luts)
	if host._world == null or host._map == null:
		host._cloud_shadow_field.clear_inputs()
		_push_cloud_shadow_material_inputs(host)
		return
	var tiled = _visual_tiles_active(host)
	host._cloud_shadow_field.set_tuning(
		host.cloud_shadow_strength_high,
		host.cloud_shadow_strength_mid,
		host.cloud_shadow_strength_low,
		host.cloud_shadow_coverage_gain,
		host.cloud_shadow_motion_speed,
		host.cloud_shadow_shape_contrast,
		host.cloud_shadow_noise_warp,
		host.cloud_shadow_mask_bias,
		host.cloud_shadow_cell_scale,
		host.cloud_shadow_world_scale,
		host.cloud_shadow_erosion,
		host.cloud_shadow_uv_scroll_gain,
		host.cloud_shadow_dynamic_detail_gain,
		host.cloud_shadow_dynamic_warp_gain,
		host.cloud_shadow_edge_softness,
		host.cloud_shadow_wind_influence)
	host._cloud_shadow_field.configure(
		host._world.world_bounds,
		host._world,
		host._map,
		host._world.visual_tiles if tiled else null,
		host._wrap_period_x(),
		host.visual_quality,
		host._mobile_quality_tier_define,
		_cloud_shadow_direct_active(host),
		2.0 * host.hex_size)
	host._cloud_shadow_field.set_world_time(host._world_time)
	host._cloud_shadow_field.set_night_factor(host._tod_night_factor if host.day_night_enabled else 0.0)
	host._cloud_shadow_field.set_debug_view(host.cloud_shadow_debug_view)



static func _push_cloud_shadow_tuning(host) -> void:

	if host._cloud_shadow_field == null:
		return
	host._cloud_shadow_field.set_tuning(
		host.cloud_shadow_strength_high,
		host.cloud_shadow_strength_mid,
		host.cloud_shadow_strength_low,
		host.cloud_shadow_coverage_gain,
		host.cloud_shadow_motion_speed,
		host.cloud_shadow_shape_contrast,
		host.cloud_shadow_noise_warp,
		host.cloud_shadow_mask_bias,
		host.cloud_shadow_cell_scale,
		host.cloud_shadow_world_scale,
		host.cloud_shadow_erosion,
		host.cloud_shadow_uv_scroll_gain,
		host.cloud_shadow_dynamic_detail_gain,
		host.cloud_shadow_dynamic_warp_gain,
		host.cloud_shadow_edge_softness,
		host.cloud_shadow_wind_influence)
	_push_cloud_shadow_material_inputs(host)



static func _push_cloud_shadow_material_inputs(host) -> void:

	if host._cloud_shadow_field == null:
		return
	var direct_enabled = _cloud_shadow_direct_active(host)
	var has_source: bool = host._cloud_shadow_field.has_weather_source()
	var field_texture: Texture2D = host._cloud_shadow_field.get_field_texture() if has_source else null
	var wrap_origin_uv: float = host._cloud_shadow_field.get_wrap_origin_uv()
	var wrap_period_uv: float = host._cloud_shadow_field.get_wrap_period_uv()
	for material in [host._shader_mat, host._water_mat]:
		if material == null or material.shader == null:
			continue
		if material.shader.code.contains("#define PK_CLOUD_SHADOW_DIRECT"):
			if field_texture != null:
				material.set_shader_parameter("cloud_shadow_tex", field_texture)
			material.set_shader_parameter("cloud_shadow_field_bound", direct_enabled and has_source)
			material.set_shader_parameter("cloud_shadow_strength", host._cloud_shadow_field.get_strength())
			material.set_shader_parameter("cloud_shadow_ambient_weight", host.cloud_shadow_ambient_weight)
			material.set_shader_parameter("cloud_shadow_water_scale", host.cloud_shadow_water_scale)
			material.set_shader_parameter("cloud_shadow_wrap_origin_uv", wrap_origin_uv)
			material.set_shader_parameter("cloud_shadow_wrap_period_uv", wrap_period_uv)
	if host._building_visual_layer != null and host._building_visual_layer.has_method("set_cloud_shadow_field"):
		host._building_visual_layer.set_cloud_shadow_field(field_texture, direct_enabled,
			wrap_origin_uv, wrap_period_uv)
	if host._resource_visual_layer != null and host._resource_visual_layer.has_method("set_cloud_shadow_field"):
		host._resource_visual_layer.set_cloud_shadow_field(field_texture, direct_enabled,
			wrap_origin_uv, wrap_period_uv)
	_for_each_vegetation_layer(host, func(layer: ShrubLayer) -> void:
		if layer.has_method("set_cloud_shadow_field"):
			layer.set_cloud_shadow_field(field_texture, direct_enabled,
				wrap_origin_uv, wrap_period_uv)
	)
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer) \
			and host._detail_family_layer.has_method("set_cloud_shadow_field"):
		host._detail_family_layer.set_cloud_shadow_field(field_texture, direct_enabled,
			wrap_origin_uv, wrap_period_uv)


## 迷雾口径与主地形**同一批值**：fog_k 来自同一张 enum_lut 的 A 通道，
## fog_early_out / fog_gray 的开关也必须是同一份（_push_fog_uniforms 里调用）。
## [land-water-split 2026-11-02] fog_unexplored_color 必须推：拆 mesh 后纯水 block
## 没有陆地 pass 兜底，水面 program 要自己画同一个迷雾色（Web 紧凑水面程序同样声明
## 了这个 uniform）。两片画同色是幂等的。

static func _push_water_fog_uniforms(host) -> void:

	if host._water_mat == null:
		return
	host._water_mat.set_shader_parameter("fog_gray_enabled", host._fog_enabled)
	host._water_mat.set_shader_parameter(
		"fog_early_out_enabled", host._effective_fog_early_out())
	host._water_mat.set_shader_parameter("fog_unexplored_color", FogOfWarLayer.UNEXPLORED_COLOR)


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
		high_shader.code = ("#define MAP_VISUAL_TILED\n" if _visual_tiles_active(host) else "") \
			+ WORLD_MAP_WEB_HIGH_PREFIX + shader.code
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
	if prefix.is_empty():
		return shader
	var variant = shader.duplicate() as Shader
	variant.code = prefix + shader.code
	print("[hex_renderer/variant] tiled=%s quality=%s web_texture_budget=%s web_world_min=%s shader=%s" % [
		_visual_tiles_active(host), host._mobile_quality_tier_define,
		DCFeatureFlags.is_compatibility_renderer(), _world_map_web_min_active(host), source_path])
	return variant


# Shader quality tier（mobile/web）：由 player_game / main._push_visual_toggles 推过来。
# 空字符串 = 桌面端 / 不 prepend define。可选值 "MOBILE_QUALITY_LOW" / "MID" / "HIGH"。


static func set_mobile_quality_tier(host, tier_define: String) -> void:

	var veg_tier = _mobile_quality_tier_from_define(host, tier_define)
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_quality(host.visual_quality, veg_tier if not tier_define.is_empty() else -1)
	_for_each_vegetation_layer(host, func(layer: ShrubLayer) -> void:
		layer.set_mobile_quality_tier(veg_tier)
	)
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer) and host._map != null:
		host._detail_family_layer.configure(host._detail_layers, host.detail_scatter_family_renderer_enabled)
		if host.detail_scatter_family_renderer_enabled and host._camera_view_initialized:
			host._queue_missing_prefetch_detail_chunks()
			host._reactivate_deferred_detail_chunks()
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget()
	if host._weather_layer != null and host._weather_layer.has_method("set_mobile_quality_tier"):
		host._weather_layer.set_mobile_quality_tier(tier_define)
	if host._fog_layer != null:
		host._fog_layer.set_mobile_quality_tier(tier_define)
		host._apply_fog_early_out()
	if host._mobile_quality_tier_define == tier_define:
		return
	host._mobile_quality_tier_define = tier_define
	# web：?tier=high 这类 QA 档也算「高画质」，档位变化后重算天气层画质门。
	_apply_weather_layer_render_gate(host)
	# 重新加载 shader 让 #define 生效（hot toggle 时也走这条）
	if host._shader_mat != null:
		host._load_shader()
		# 关键：_load_shader 创建了新 ShaderMaterial 实例（disk source_mat.duplicate()），
		# 原本的 atlas uniform (height_tex/enum_atlas/dyn_atlas_smooth_atlas 等) 都是 null。
		# 必须重新 push 所有 uniform，否则 fragment 拿到 null texture → 输出全白 / 失败。
		# bug fix（log_next.txt 2026-06-15 14:13 shader.dyn_atlas_smooth=<null> 即症状）。
		if host._map != null and host._world != null and host._shader_mat != null:
			host._apply_uniforms()
	_configure_cloud_shadow_field(host)
	_push_cloud_shadow_material_inputs(host)



static func _mobile_quality_tier_from_define(host, tier_define: String) -> int:

	match tier_define:
		"MOBILE_QUALITY_LOW":
			return 0
		"MOBILE_QUALITY_HIGH":
			return 2
		_:
			return 1



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



static func _for_each_vegetation_layer(host, callable: Callable) -> void:

	for layer in host._detail_layers:
		if layer != null:
			callable.call(layer)


## Player scene assembly supplies the independent read-only trade layer.

static func configure_trade_visuals(host, layer: TradeActivityLayer) -> void:

	host._trade_visual_layer = layer
	if is_instance_valid(layer):
		layer.set_terrain_lighting(host._world, host._shader_mat)
		_sync_trade_daylight(host)


## Military formations are also a read-only map visual. Register them through
## the renderer so they consume the same daylight/horizon state as terrain and
## trade convoys instead of maintaining a second lighting authority.

static func configure_military_visuals(host, layer: MilitaryArmyTokenLayer) -> void:

	host._military_visual_layer = layer
	if is_instance_valid(layer):
		layer.set_visual_quality(host.visual_quality)
		layer.set_terrain_lighting(host._world, host._shader_mat)
		_sync_military_daylight(host)



static func _instance_daylight_parameters(host) -> Dictionary:

	return {
		"season_phase": host._season_phase,
		"day_phase": host._day_phase,
		"axial_tilt_rad": deg_to_rad(host.axial_tilt_deg),
		"day_night_enabled": host.day_night_enabled,
		"tod_debug_sun_position_enabled": host._tod_debug_sun_position_enabled,
		"tod_debug_sun_uv": host._tod_debug_sun_uv,
		"tod_debug_sun_height_scale": host._tod_debug_sun_height_scale,
		"eternal_min_elevation_rad": deg_to_rad(host.eternal_min_elevation_deg),
		"eternal_max_hour_angle_rad": deg_to_rad(host.eternal_max_hour_angle_deg),
		"tod_sun_dir": host._tod_sun_dir,
		"tod_exposure": host._tod_exposure,
	}



static func _sync_trade_daylight(host) -> void:

	if not is_instance_valid(host._trade_visual_layer):
		return
	host._trade_visual_layer.set_daylight_parameters(
		_instance_daylight_parameters(host))



static func _sync_military_daylight(host) -> void:

	if not is_instance_valid(host._military_visual_layer):
		return
	host._military_visual_layer.set_daylight_parameters(
		_instance_daylight_parameters(host))



static func _sync_detail_and_activity_materials(host) -> void:

	_sync_trade_daylight(host)
	_sync_military_daylight(host)
	if is_instance_valid(host._military_visual_layer):
		host._military_visual_layer.set_visual_quality(host.visual_quality)
	if host.detail_scatter_family_renderer_enabled and host._detail_family_layer != null \
			and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.sync_dynamic_materials()



static func set_simulation_speed_multiplier(host, multiplier: float) -> void:

	host._simulation_speed_multiplier = maxf(0.0, multiplier)
	host._clock_speed_multiplier = host._simulation_speed_multiplier



static func set_clock_running(host, running: bool) -> void:

	host._clock_running = running



