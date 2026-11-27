shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D style_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
#ifndef PK_WEB_RESOURCE_MIN
// The compatibility program omits the dry plant tint, including its texture slot.
uniform sampler2D eco_lut : filter_nearest, repeat_disable;
#endif
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D memory_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float hex_size = 22.0;
uniform float camera_zoom = 1.0;
uniform float world_time = 0.0;
uniform bool fog_enabled = true;
uniform bool has_dynamic_lut = false;
uniform bool has_ecology_lut = false;
uniform int visual_quality = 1;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4101523;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;
uniform float vitality_dead_threshold = 0.04;
uniform float vitality_power = 0.65;
uniform float climate_response = 0.7;
uniform float snow_response = 0.85;
uniform float wind_strength = 0.35;
uniform float animal_motion = 0.55;
uniform float detailed_pixels = 12.0;
uniform float simple_pixels = 6.0;
uniform float fade_pixels = 2.0;
// 压低饱和度，使资源与地图色调融合（1 = 原色）。
uniform float palette_saturation = 0.80;
// 资源透镜：0 = 世界内实景，1 = 屏幕恒定尺寸的识别徽章；filter_style >= 0 时只显示该资源。
uniform float lens_amount = 0.0;
uniform float badge_px = 34.0;
uniform int filter_style = -1;
// The world view is decoration, not a signpost: no outlines or cast shadows by default,
// ground decals and submerged cues blend at low opacity, and extreme lumas are compressed.
uniform float decal_opacity = 0.42;
uniform float submerged_opacity = 0.55;
uniform float outline_strength = 0.0;
uniform float contact_shadow = 0.45;
uniform float cast_shadow = 0.0;
uniform float luma_compress = 0.75;
uniform vec2 luma_range = vec2(0.24, 0.64);
// 群落外沿的羽化与扰动；植株/晶体之间不再绘制封闭底板。
uniform float area_feather = 0.55;
uniform float area_edge_noise = 0.35;
uniform float plant_cluster_density = 1.30;
// [decal-ground-fit 2026-11-18] 贴花贴合地表的两档强度。
// slope_fit：坡面面积变形增益（0 = 关闭，回到"印在屏幕平面"）。
// ground_tint：贴花色温向脚下地表色靠拢的比例（0 = 保持独立配色）。
uniform float decal_slope_fit = 1.0;
uniform float decal_ground_tint = 0.45;
// Generated bitmap fauna (tools/resource_art): 4x2 top-down sprites per species, drawn
// as small realistic herds/shoals. Plants are NOT drawn here: they are continuous wild
// communities in ResourceGroundCover. Style LUT texel 2 = (unused, fauna layer+1, count).
uniform sampler2DArray art_fauna : filter_linear_mipmap, repeat_disable;
uniform bool art_fauna_bound = false;
uniform float art_animal_shadow = 0.35;
// Generated material atlas: layer 0 = albedo, layer 1 = RG normal/B height/A AO.
// One sampler covers geology props, ground resources and their lens badges.
uniform sampler2DArray art_material : filter_linear_mipmap, repeat_disable;
uniform bool art_material_bound = false;
uniform float material_normal_strength = 0.90;
uniform float material_shadow = 0.18;
// Generated materials carry a soft height field in normal-layer B. Fade their
// silhouette and surface normal by that height so decals meet terrain without
// a painted-on cutoff. Lower/medium keep the smoothstep but skip edge noise.
uniform float decal_edge_softness = 1.0;
uniform float decal_edge_noise = 0.65;
uniform float solid_edge_softness = 0.72;
uniform int herd_size_min = 3;
uniform int herd_size_max = 9;
// Body length of one animal, in hexes; herds fade out below animal_min_pixels.
uniform float animal_length_hex = 0.11;
uniform float animal_min_pixels = 3.0;
uniform float fish_length_hex = 0.035;
#ifndef PK_WEB_RESOURCE_MIN
#define VT_USE_HORIZON
#endif
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_HEIGHT
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform bool has_height_tex = false;
uniform bool has_flow_tex = false;
uniform float sea_level = 0.42;
uniform float river_clear_threshold = 0.54;
uniform bool terrain_normal_tex_bound = false;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_strength = 0.90;
uniform float terrain_horizon_cast_floor = 0.82;
uniform int terrain_horizon_debug_view = 0;
uniform bool gi_lut_bound = false;
uniform vec3 gi_horizon_lut[16];
uniform float gi_ao_strength = 0.90;
uniform float gi_ao_floor = 0.38;
uniform float gi_ao_smoothing = 0.75;
uniform float gi_bent_strength = 0.35;
uniform float gi_normal_floor = 0.85;
uniform vec2 wind_dir = vec2(1.0, 0.18);
uniform float weather_wind_boost = 0.0;
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/cloud_shadow.gdshaderinc"
#ifndef PK_WEB_RESOURCE_MIN
#define PK_WORLD_LIGHTING_FIELD
#endif
#include "res://shaders/include/world_lighting_field.gdshaderinc"
#include "res://shaders/include/fog_memory.gdshaderinc"
vec2 wrap_map_uv(vec2 uv) { return visual_static_wrap_uv(uv); }
// [web-resource-min] Web/GLES3 精简变体：地形地平线 GI 在 web 上恒为中性值
// （terrain_horizon_tex_bound 恒 false，见 include 文件头的逐条依据），因此整段
// 顶替掉，不再编译 4-tap × 8 方向 `gi_horizon_lut[nibbles[d]]` 动态下标循环。
// 桌面 / 移动端仍走下面这一行原 include，展开结果逐字不变。
#ifdef PK_WEB_RESOURCE_MIN
#include "res://shaders/include/resource_impostor_web_min.gdshaderinc"
#else
#include "res://shaders/include/terrain_horizon.gdshaderinc"
#endif

varying flat vec4 v_style;
varying flat vec4 v_material;
varying flat vec4 v_climate;
varying flat vec4 v_data;
varying flat vec4 v_art;
// Keep per-instance values in one flat slot to fit the 16-varying GLES3 budget.
varying flat vec4 v_instance_detail; // x = sub-style, y = instance kind, z = dryness, w = fog knowledge
varying flat vec3 v_bounce;
varying flat vec3 v_direct;
varying flat vec3 v_sun;
varying flat vec2 v_axis;
varying flat vec2 v_rank;

// style_lut 的列寻址：夹到 [0, width-1]。见 vertex() 里 texelFetch 那段的说明。
int rv_style_col(int col, int width) {
	return clamp(col, 0, max(width - 1, 0));
}
varying flat vec4 v_sky;
varying flat vec3 v_terrain;
varying flat vec3 v_day;
// [canvas-varying-budget 2026-11-17] Adreno 的 canvas varying 上限只有 28（桌面 32）。
// 这份 shader 原来用了 29 个，**整份在真机上编译失败**：
//   SHADER ERROR: Too many varyings used in shader (29 used, maximum supported is 28)
//   ERROR: Shader compilation failed.  @ resource_visual_layer._ready
// 后果是资源/点缀全部退化成纯色方块（真机截图里的青蓝色块），而且每帧刷
// version_get_shader 为 null。三个 flat 标量合成一个 vec3，省两个名额。
varying flat vec3 v_misc;   // x = horizon visibility, y = transmission, z = radius_world
varying vec2 v_world_position;
#ifdef PK_WEB_RESOURCE_MIN
// [web-two-pass] 仅 web/GLES3：把「同一 fragment 里 5 条着色来源二选一」拆成两份程序。
// 实测（ANGLE/D3D11，与浏览器同一条 GLSL→HLSL→FXC 路径，见 tmp/next/resource_cliff_IMPL.md）：
//   一个 fragment 全塞      5 400–7 200 ms（浏览器 warmup_shader 实测 6 619 ms）
//   拆成 surface + geology  1 100 + 900 ≈ 2 000 ms
// 单独把任何一块换成常量都几乎不省（−0 ~ −1 500 ms，且被 ±30% 噪声吞掉）——这与 world_map
// 的结论一致：成本是「一个 fragment 里共存多条着色来源」的寄存器压力悬崖，不是行数。
//
// 两份程序各自只画自己那一族实例（按 batch 分流，见 resource_visual_layer.gd 的
// _material_for(family)），所以不会重复绘制，也不会出现 alpha 叠加两次的问题。
// batch 2（矿物 16/17/18）走 geology；batch 0/1/3/4（植物徽章 / 兽群 / 水下 / 地面贴花）走 surface。
//
// 下面的 PK_PROBE_NO_* 就是 A/B 探针用的同一组开关：探针测到的组合 = 上线的组合。
#if defined(PK_RES_WEB_PASS_GEOLOGY) || defined(PK_RES_WEB_PASS_SURFACE)
#ifdef PK_RES_WEB_PASS_GEOLOGY
// 只留矿床道具：rt_geology_solid（form 16/17/18）+ lens 徽章。
// rs_geology（form 19..25）在 web 世界里从不作为 prop 出现（visual_plan() 只给 PLAN_DECAL），
// 只在徽章图片里用过；geology pass 的徽章图片就是矿床本身，所以整段不编译。
#define PK_PROBE_NO_DECAL
#define PK_PROBE_NO_HERD
#define PK_PROBE_NO_SUBMERGED
#define PK_PROBE_NO_SUBJ_GROUND
// 本 pass 只画 family 2（矿物）实例，剪影分支不可达。
#define PK_PROBE_NO_SILHOUETTE
#endif
#ifdef PK_RES_WEB_PASS_SURFACE
// 只留「非矿床」的四条来源：地面贴花 / 位图兽群 / 水下贴花 / 徽章。
// rt_resource() 只剩 rt_badge_silhouette()（徽章里那张图），geology 两份语料都不编译。
#define PK_PROBE_NO_SUBJ_SOLID
#define PK_PROBE_NO_SUBJ_GROUND
#endif
#endif // PK_RES_WEB_PASS_*
#endif // PK_WEB_RESOURCE_MIN

float rv_hash(float n) {
	return fract(sin(n * 12.9898 + 78.233) * 43758.5453);
}

// Pull pure black / pure white towards the terrain's luma band, keeping chroma.
vec3 rv_compress_luma(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	float target = mix(luma_range.x, luma_range.y, clamp(l, 0.0, 1.0));
	return clamp(c + vec3((target - l) * luma_compress), vec3(0.0), vec3(1.0));
}

float rv_ellipse(vec2 p, vec2 extent) {
	return (length(p / extent) - 1.0) * min(extent.x, extent.y);
}

struct RvDaylightState {
	vec3 direct;
	vec3 sun;
	vec3 day;
};

struct RvHorizonState {
	float direct_visibility;
	vec4 sky;
	vec3 bounce;
};

// Procedural props and lens badges use the anchor sample. Ground decals, submerged
// cues and generated-material geology re-sample it per pixel at q2.
RvDaylightState rv_sample_daylight(vec2 map_uv) {
	RvDaylightState state;
	if (tod_debug_sun_position_enabled) {
		state.sun = normalize(tod_sun_dir);
		float d_day = smoothstep(-0.08, 0.22, state.sun.z);
		float d_dusk = smoothstep(-0.06, 0.14, state.sun.z) * (1.0 - smoothstep(0.14, 0.42, state.sun.z));
		vec3 sun_c = mix(EARTH_DAYLIGHT_NOON, EARTH_DAYLIGHT_DUSK, d_dusk);
		float moon = (1.0 - d_day) * 0.72;
		state.direct = sun_c * tod_exposure;
		state.day = vec3(d_day, smoothstep(0.0, 0.65, state.sun.z), moon);
	} else {
		EarthDaylight daylight = eval_earth_daylight(
			map_uv, clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0, day_night_enabled);
		state.sun = daylight.sun_dir;
		state.direct = daylight.sun_col * tod_exposure;
		state.day = vec3(daylight.local_day, daylight.sun_high, daylight.moon_strength);
	}
	return state;
}

RvHorizonState rv_sample_horizon(vec2 map_uv, vec3 sun) {
	RvHorizonState state;
	state.bounce = vec3(0.0);
#ifdef PK_WEB_RESOURCE_MIN
	// Compatibility/web-min has no baked horizon input by design.
	state.direct_visibility = 1.0;
	state.sky = vec4(0.0, 0.0, 1.0, 1.0);
#else
	if (world_lighting_active()) {
		vec4 wl = sample_world_lighting(map_uv);
		TerrainHorizonSample horizon = terrain_horizon_sample_gi_sky_only(map_uv);
		state.direct_visibility = wl.a;
		state.sky = vec4(horizon.bent_normal, horizon.sky_visibility);
		state.bounce = wl.rgb * world_lighting_radiance_scale * 0.18;
	} else {
		TerrainHorizonSample horizon = terrain_horizon_evaluate(map_uv, sun);
		state.direct_visibility = horizon.direct_visibility;
		state.sky = vec4(horizon.bent_normal, horizon.sky_visibility);
	}
#endif
	return state;
}

vec3 rv_terrain_normal_at(vec2 map_uv) {
	vec2 terrain_xy = terrain_normal_tex_bound
		? (visual_sample_terrain_normal(map_uv).rg * 2.0 - 1.0) * 0.65
		: vec2(0.0);
	return normalize(vec3(terrain_xy, 1.0));
}

// Same directional sky as vegetation; callers choose anchor or per-pixel inputs.
vec3 rv_ambient_from(vec3 normal, vec3 ambient_color, vec3 direct_color, vec3 sun_dir,
		vec3 day, vec4 sky) {
	vec3 mixed_n = mix(normal, sky.xyz, gi_bent_strength);
	vec3 amb_n = dot(mixed_n, mixed_n) > 0.000001 ? normalize(mixed_n) : normal;
	float ao = terrain_horizon_apply_normal(sky.w, normal, sky.xyz);
	vec3 directional_sky = sky_ambient_srgb(day.x, amb_n, ambient_color, direct_color, sun_dir);
	return directional_sky * ao * mix(1.0, 0.70, day.x)
		+ EARTH_MOONLIGHT * day.z * max(dot(normal, -sun_dir), 0.0) * 0.35 * tod_exposure;
}

vec3 rv_ambient_palette(float local_day) {
	float gain = (!day_night_enabled && !tod_debug_sun_position_enabled)
		? EARTH_ETERNAL_AMBIENT_GAIN : 1.0;
	return mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, local_day) * gain * tod_exposure;
}

void vertex() {
	float cell = INSTANCE_CUSTOM.r;
	vec2 cell_uv = (vec2(mod(cell, lut_dims.x), floor(cell / lut_dims.x)) + 0.5) / lut_dims;
	vec4 memory = texture(memory_lut, cell_uv);
	float knowledge = fog_enabled ? texture(enum_lut, cell_uv).a : 1.0;
	float live = step(0.88, knowledge);
	vec4 current = texture(dyn_lut, cell_uv);
	v_climate = mix(memory, current, has_dynamic_lut ? live : 0.0);
#ifndef PK_WEB_RESOURCE_MIN
	vec4 ecology = texture(eco_lut, cell_uv);
	v_instance_detail.z = mix(1.0 - memory.a, ecology.g, has_ecology_lut ? live : 0.0);
#else
	v_instance_detail.z = 0.0;
#endif
	float style = INSTANCE_CUSTOM.g;
	// [style-lut-texel 2026-11-17] style_lut 是 4 列 × 64 行、列间没有 padding 的 RGBAF 表：
	//   col0 = (specular, material_cell+1, art_bound, metallic)
	//   col1 = 颜色   col2 = 动物/鱼位图   col3 = (form, family, sub_style, metallic)
	// 原先用 texture() 取 x=0.25 / x=0.75 —— 这两个 u **正好落在纹素边界上**
	// （0.25*4 = 1.0，0.75*4 = 3.0）。边界归谁由驱动决定：有的实现按
	// `round(u*W - 0.5)` 取整，正好命中 .5 时向偶数侧收敛 ⇒ 取到左列。
	//
	// 安卓真机上就是这样错位一格：颜色取到 col0（0.2~0.3, ≥1, 1）⇒ 所有道具变成
	// 过曝青色（实测 #72F6FC，R 停在 sRGB 0.45 而 G/B 顶满，正是 "两个分量 ≥1 + 一个
	// 0.2" 被日照压暗后的形状）；元数据取到 col2 ⇒ form=0 / family=0..N ⇒ 形体退化成
	// 铺满整个 quad 的有机斑块。两项叠加就是"地面点缀全成了纯色方块"。
	//
	// 改用 texelFetch：整数格寻址，不经过采样器，不受 filter / wrap / 半纹素约定影响。
	// 列号也夹一次 —— 越界 texelFetch 是 UB，而 style_lut 万一没绑（兜底 1×1 白纹）
	// 时列 1..3 就越界了，宁可整列退化成读第 0 列。
	ivec2 style_size = max(textureSize(style_lut, 0), ivec2(1, 1));
	int style_row = clamp(int(style + 0.5), 0, style_size.y - 1);
	v_style = texelFetch(style_lut, ivec2(rv_style_col(1, style_size.x), style_row), 0);
	v_material = texelFetch(style_lut, ivec2(rv_style_col(0, style_size.x), style_row), 0);
	vec4 meta = texelFetch(style_lut, ivec2(rv_style_col(3, style_size.x), style_row), 0);
	v_art = texelFetch(style_lut, ivec2(rv_style_col(2, style_size.x), style_row), 0);
	vec2 model_scale = vec2(length(MODEL_MATRIX[0].xy), length(MODEL_MATRIX[1].xy));
	vec2 model_px_scale = model_scale * camera_zoom;
	float radius_px_world = max(model_px_scale.x, model_px_scale.y);
	v_misc.z = max(model_scale.x, model_scale.y);
	float radius_px = mix(radius_px_world, badge_px * 0.5, clamp(lens_amount, 0.0, 1.0));
	v_data = vec4(meta.r, meta.g, INSTANCE_CUSTOM.b, live);
	v_instance_detail.w = knowledge;
	v_misc.y = COLOR.g;
	v_instance_detail.x = meta.b;
	v_rank = vec2(INSTANCE_CUSTOM.a, radius_px);
	vec2 center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	vec2 map_uv = visual_static_wrap_uv((center - world_origin) / max(world_size, vec2(0.0001)));
	RvDaylightState anchor_daylight = rv_sample_daylight(map_uv);
	v_sun = anchor_daylight.sun;
	v_direct = anchor_daylight.direct;
	v_day = anchor_daylight.day;
	RvHorizonState anchor_horizon = rv_sample_horizon(map_uv, v_sun);
	v_misc.x = anchor_horizon.direct_visibility;
	v_sky = anchor_horizon.sky;
	v_bounce = anchor_horizon.bounce;
	v_terrain = rv_terrain_normal_at(map_uv);
	v_axis = normalize(MODEL_MATRIX[0].xy);
	float kind_raw = COLOR.a + 0.01;
	float kind = floor(kind_raw);
	float carrier = step(fract(kind_raw), 0.25);
	v_instance_detail.y = kind;
	float present = step(0.10, knowledge);
	float lens = clamp(lens_amount, 0.0, 1.0);
	float lod = smoothstep(fade_pixels, simple_pixels, radius_px_world);
	float rank_alpha = mix(step(COLOR.r, 0.1), 1.0, smoothstep(simple_pixels, detailed_pixels, radius_px_world));
	if (meta.g > 0.5 && meta.g < 1.5 && v_art.y > 0.5 && art_fauna_bound) {
		// Herds read at real scale: fade by the on-screen length of one animal.
		float body_px = animal_length_hex * hex_size * camera_zoom;
		lod = smoothstep(animal_min_pixels * 0.6, animal_min_pixels, body_px);
		rank_alpha = 1.0;
	}
	float world_vis = lod * rank_alpha * step(kind, 3.5);
	// Lens badges: only each cell's primary resource (or the filtered one), thinned
	// by on-screen cell density so zoomed-out badges never pile into a blob. A
	// resource drawn as decal + prop owns exactly one badge (the carrier).
	float matches = filter_style >= 0 ? step(abs(style - float(filter_style)), 0.5) : 1.0;
	float keep = clamp(pow(hex_size * camera_zoom * 1.7 / max(badge_px, 1.0), 2.0), 0.0, 1.0);
	float thin = step(rv_hash(cell * 0.731 + 3.17), keep);
	float lens_vis = step(COLOR.r, 0.1) * matches * thin * carrier;
	v_style.a = mix(world_vis, lens_vis, lens) * present;
	vec2 lens_vertex_scale = vec2(
		badge_px * 0.5 / max(model_px_scale.x, 0.001),
		badge_px * 0.5 / max(model_px_scale.y, 0.001));
	VERTEX *= mix(vec2(1.0), lens_vertex_scale, lens);
	VERTEX *= step(0.001, v_style.a);
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

#include "res://shaders/include/resource_forms.gdshaderinc"
// [web-resource-min] resource_solid_forms 是 rs3_* 语料（42 KB / 793 行），整个工程里
// 只有本 shader include 它，而 rs3_* 被引用 0 次（rt_resource() 只用 rt_*/rs_geology）：
// 纯死代码，web 变体直接不编译。桌面仍照原样 include（逐字不变）。
#ifndef PK_WEB_RESOURCE_MIN
#include "res://shaders/include/resource_solid_forms.gdshaderinc"
#endif
#include "res://shaders/include/resource_topdown_forms.gdshaderinc"
#include "res://shaders/include/resource_decal_forms.gdshaderinc"

float rv_h1(float x) {
	return fract(sin(x * 127.1 + 311.7) * 43758.5453);
}

// A realistic herd/shoal of bitmap animals inside the instance quad, at true scale:
// `body_hex` is one animal's length in hexes. Animals graze in a loose spiral cluster
// facing roughly the same way. Straight RGB + coverage; `sh` = soft contact shadow.
vec4 rv_herd(vec2 p, float layer, float count, float seed, float band, float t, float motion_amp,
		float body_hex, float spread_scale, out float sh) {
	float hmin = float(clamp(herd_size_min, 1, 9));
	float hmax = float(clamp(herd_size_max, herd_size_min, 9));
	float pick = clamp(band / 4.0, 0.0, 1.0) * 0.5 + rv_h1(seed * 31.0) * 0.5;
	int n = int(clamp(hmin + floor(pick * (hmax - hmin + 1.0)), hmin, hmax));
	float cnt = clamp(count, 1.0, 8.0);
	// Sprite cell spans 2*sc in p units; the animal fills ~94% of its 128px cell.
	float sc = body_hex * hex_size / max(v_misc.z, 0.001) * 0.535;
	float spread = clamp(sc * 1.45 * sqrt(float(n)) * spread_scale, sc, 1.0 - sc);
	float lod = clamp(log2(128.0 / max(2.0 * sc * v_rank.y, 1.0)), 0.0, 5.0);
	vec2 sun_away = -normalize(v_sun.xy + vec2(0.0001));
	float herd_heading = rv_h1(seed * 11.3) * 6.2832;
	vec3 pm = vec3(0.0);
	float pa = 0.0;
	sh = 0.0;
	for (int i = 0; i < 9; i++) {
		if (i >= n) {
			break;
		}
		float fi = float(i);
		float h1 = rv_h1(seed * 91.7 + fi * 13.1 + 1.0);
		float h2 = rv_h1(seed * 53.3 + fi * 7.7 + 2.0);
		float h3 = rv_h1(seed * 17.9 + fi * 3.3 + 3.0);
		float h4 = rv_h1(seed * 29.1 + fi * 5.9 + 4.0);
		// Golden-angle spiral with jitter: a loose herd, no two animals on one spot.
		float ang = fi * 2.39996 + seed * 6.0 + (h1 - 0.5) * 0.9;
		vec2 c = vec2(cos(ang), sin(ang)) * spread * sqrt((fi + 0.5 + (h2 - 0.5) * 0.6) / float(n));
		float s_i = sc * (0.88 + 0.22 * h3);
		// Graze-and-walk: each animal loops a small path around its spot. u(t) = wt - sin(wt)
		// has speed w(1 - cos wt), so it periodically stops to graze, then ambles on.
		float w = (0.22 + 0.16 * h2) * motion_amp;
		float ph = h1 * 6.2832;
		float u = t * w - sin(t * w + ph) + ph;
		float speed = 1.0 - cos(t * w + ph);
		float loop_r = sc * (0.55 + 0.45 * h3) * step(0.001, motion_amp);
		float dir_sign = h4 < 0.5 ? -1.0 : 1.0;
		vec2 lp = vec2(cos(u * dir_sign), sin(u * dir_sign) * 0.55);
		vec2 lt = vec2(-sin(u * dir_sign), cos(u * dir_sign) * 0.55) * dir_sign;
		mat2 hr = rs_rot(herd_heading);
		c += hr * lp * loop_r;
		// Face the direction of travel; while grazing, drift back to the herd heading.
		vec2 tang = hr * lt;
		float travel = atan(tang.x, tang.y);
		float idle = herd_heading + (h4 - 0.5) * 1.2;
		float walk = smoothstep(0.25, 0.9, speed) * step(0.001, motion_amp);
		float dh = mod(travel - idle + 3.14159, 6.28318) - 3.14159;
		float heading = idle + dh * walk;
		// Stride: a gentle fore-aft stretch and sway while walking; head-down dip while grazing.
		float stride = sin(t * 7.0 + ph * 3.0) * walk;
		float graze = (1.0 - walk) * step(0.001, motion_amp) * (0.5 + 0.5 * sin(t * 0.9 + ph * 2.0));
		vec2 body_scale = vec2(1.0 + 0.03 * stride, 1.0 - 0.04 * abs(stride) - 0.06 * graze);
		mat2 rot = rs_rot(heading);
		vec2 q = rot * (p - c) / s_i / body_scale;
		q.x += 0.025 * stride * q.y;
		int idx = min(int(floor(rv_h1(seed * 7.3 + fi * 2.1 + 5.0) * cnt)), int(cnt) - 1);
		vec2 cell_origin = vec2(float(idx % 4), float(idx / 4));
		vec2 suv = vec2(q.x, -q.y) * 0.5 + 0.5;
		vec2 qs = rot * (p - c - sun_away * s_i * 0.22) / s_i;
		vec2 suv_s = vec2(qs.x, -qs.y) * 0.5 + 0.5;
		if (all(greaterThanEqual(suv_s, vec2(0.0))) && all(lessThanEqual(suv_s, vec2(1.0)))) {
			float sa = textureLod(art_fauna, vec3((cell_origin + suv_s) / vec2(4.0, 2.0), layer), lod + 1.0).a;
			sh = max(sh, sa);
		}
		if (any(lessThan(suv, vec2(0.0))) || any(greaterThan(suv, vec2(1.0)))) {
			continue;
		}
		vec4 tex = textureLod(art_fauna, vec3((cell_origin + suv) / vec2(4.0, 2.0), layer), lod);
		float a = tex.a;
		pm = pm * (1.0 - a) + tex.rgb * a;
		pa = pa * (1.0 - a) + a;
	}
	return vec4(pm / max(pa, 0.0001), pa);
}

bool rv_material_art_bound() {
	return art_material_bound && v_material.z > 0.5 && v_material.y > 0.5;
}

// One deterministic orientation/mirror per instance. The inverse-looking matrix is
// intentional: it maps form-space p into source-texture space, so the visible subject
// rotates by +angle while footprint collision remains axis-aligned.
mat2 rv_material_instance_xform(float seed) {
	float angle = rv_h1(seed * 37.17 + 3.11) * 6.2831853;
	float mirror = rv_h1(seed * 71.93 + 9.41) < 0.5 ? -1.0 : 1.0;
	return rs_rot(-angle) * mat2(vec2(mirror, 0.0), vec2(0.0, 1.0));
}

vec2 rv_material_uv(vec2 p) {
	// Atlas is 8x4 cells. p is top-down form space (+y = image top), while texture
	// v grows downward, so flip only v before selecting the cell.
	float cell = floor(v_material.y - 0.5);
	vec2 grid = vec2(8.0, 4.0);
	vec2 cell_xy = vec2(mod(cell, grid.x), floor(cell / grid.x));
	vec2 local_uv = clamp(vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5),
		vec2(0.0), vec2(1.0));
	return (cell_xy + local_uv) / grid;
}

vec4 rv_material_albedo(vec2 p) {
	return texture(art_material, vec3(rv_material_uv(p), 0.0));
}

vec4 rv_material_surface(vec2 p) {
	return texture(art_material, vec3(rv_material_uv(p), 1.0));
}

vec3 rv_material_local_normal(vec4 surface, mat2 material_xform) {
	vec2 nxy = (surface.rg * 2.0 - 1.0) * material_normal_strength;
	// Normals are gradients, so their components transform with the transpose.
	nxy = transpose(material_xform) * nxy;
	float nz = sqrt(max(1.0 - dot(nxy, nxy), 0.08));
	return normalize(vec3(nxy, nz));
}

vec3 rv_material_normal(vec4 surface, vec2 axis, vec3 terrain, mat2 material_xform) {
	vec3 local_n = rv_material_local_normal(surface, material_xform);
	vec2 nxy = local_n.xy;
	float nz = local_n.z;
	vec2 screen_n = vec2(nxy.x, -nxy.y);
	vec2 world_slope = axis * screen_n.x + vec2(-axis.y, axis.x) * screen_n.y;
	return normalize(vec3(world_slope + terrain.xy * nz, max(nz, 0.22)));
}

float rv_material_edge_noise(vec2 p, float seed, float amount) {
#ifdef PK_WEB_RESOURCE_MIN
	return 0.0;
#else
	if (amount <= 0.0001) {
		return 0.0;
	}
	vec2 q = p * vec2(3.7, 4.3) + vec2(seed * 19.3, seed * 7.1);
	// A pair of low-frequency waves gives every tier an irregular contact contour.
	// High quality adds one value-noise octave; lower tiers keep only the cheap waves.
	float macro = sin(q.x) * sin(q.y * 1.17 + 0.8);
	float broad = vf_vnoise(q * 1.15 + vec2(5.7, 1.3)) - 0.5;
	if (visual_quality < 2) {
		return (broad * 0.55 + macro * 0.28) * amount * 0.22;
	}
	float screen_detail = smoothstep(2.0, 8.0, v_rank.y);
	float fine = (vf_vnoise(q * 2.9 + vec2(seed * 31.1, 9.4)) - 0.5) * screen_detail;
	return (broad * 0.62 + fine * 0.38 + macro * 0.22) * amount * 0.26;
#endif
}

// Keep the interior opaque, but let the outer 15-30% dissolve through a noisy
// height+alpha band. This is what turns the authored silhouette into a contact edge
// instead of a pasted-on cutout. Badges bypass this pass and stay legible.
float rv_material_contact_edge(vec4 albedo, vec4 surface, vec2 p, float seed,
		bool ground, float softness) {
	float n = rv_material_edge_noise(p, seed, decal_edge_noise * (ground ? 1.0 : 0.72));
	float height_edge = smoothstep(ground ? 0.012 : 0.024, ground ? 0.34 : 0.30,
		surface.b + n);
	float alpha_edge = smoothstep(ground ? 0.018 : 0.025, ground ? 0.46 : 0.42,
		albedo.a + n * 0.82);
	float feathered = height_edge * alpha_edge;
	return mix(1.0, feathered, softness);
}

void fragment() {
	int form = int(v_data.x + 0.5);
	int family = int(v_data.y + 0.5);
	int sub_style = int(v_instance_detail.x + 0.5);
	int kind = int(v_instance_detail.y + 0.5);
	float seed = v_data.z;
	float live = v_data.w;
	float lens = clamp(lens_amount, 0.0, 1.0);
	bool material_art = rv_material_art_bound();
	// QuadMesh V is inverted relative to Canvas Y. The map is viewed straight down, so
	// every subject is drawn top-down (p.y up in form space, canvas y down on screen).
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float px_px = max(1.0 / max(v_rank.y, 1.0), 0.004);
	float health = pow(clamp(v_climate.a, 0.0, 1.0), vitality_power);
	float motion = world_time * live;
	vec3 tint = v_style.rgb;
	float snow = clamp(v_climate.b * snow_response, 0.0, 1.0);
	// Ground decals and submerged cues span enough terrain that anchor-only lighting
	// showed as a uniform tint. Re-sample the same inputs as ground cover per pixel at
	// q2; props, lens badges and lower tiers keep the cheaper anchor sample.
	bool pixel_surface_lighting = lens < 0.001 && visual_quality >= 2
		&& (kind == 2 || kind == 3 || (kind == 1 && material_art));
	vec3 light_dir = normalize(v_sun);
	vec3 direct_color = v_direct;
	vec3 day_state = v_day;
	vec4 sky_state = v_sky;
	float horizon_visibility = v_misc.x;
	vec3 bounce_light = v_bounce;
	vec3 terrain_normal = v_terrain;
	// [decal-ground-fit 2026-11-18] 逐像素地图 uv 提到分支外：贴花的坡度面积变形、
	// 地表色继承、云影与光照重采全部按像素位置求，不能沿用实例锚点
	// （否则一整块贴花上只有一个常量，那正是"平"的来源之一）。
	vec2 surface_uv = visual_static_wrap_uv(
		(v_world_position - world_origin) / max(world_size, vec2(0.0001)));
	if (pixel_surface_lighting) {
		RvDaylightState surface_daylight = rv_sample_daylight(surface_uv);
		light_dir = surface_daylight.sun;
		direct_color = surface_daylight.direct;
		day_state = surface_daylight.day;
		RvHorizonState surface_horizon = rv_sample_horizon(surface_uv, light_dir);
		horizon_visibility = surface_horizon.direct_visibility;
		sky_state = surface_horizon.sky;
		bounce_light = surface_horizon.bounce;
		terrain_normal = rv_terrain_normal_at(surface_uv);
	}
	vec2 cloud_map_uv = surface_uv;
	float cloud_visibility = cloud_shadow_direct_visibility(cloud_map_uv, day_state.x);
	vec3 direct_light = direct_color * day_state.x * horizon_visibility * cloud_visibility;
	vec3 ambient_color = rv_ambient_palette(day_state.x);
	// Flat-ground lighting shared by decals and submerged cues.
	float flat_diffuse = max(dot(terrain_normal, light_dir), 0.0);
	vec3 flat_light = rv_ambient_from(terrain_normal, ambient_color, direct_color,
		light_dir, day_state, sky_state) + bounce_light + direct_light * flat_diffuse * 0.78;

	// Subject = the full procedural drawing. In the world it is only drawn for small
	// props; while the lens is on it is also the picture inside every badge.
	vec3 subj_rgb = vec3(0.0);
	float subj_alpha = 0.0;
	float subj_combined = 0.0;
	bool art_animal = lens < 0.001 && kind == 1 && family == 1 && art_fauna_bound && v_art.y > 0.5;
	bool art_fish = lens < 0.001 && kind == 3 && family == 3 && art_fauna_bound && v_art.y > 0.5;
	if ((kind == 1 && !art_animal) || lens > 0.001) {
#ifdef PK_PROBE_NO_SUBJECT
		// [probe] A/B 探针：把整条 subject 管线（rt_resource → geology/ground/badge）
		// 换成常量。**只在定义了 PK_PROBE_NO_SUBJECT 时生效**，不定义时这段预处理
		// 输出与改动前逐字节相同（守卫行本身不进编译）。
		subj_rgb = tint * 0.58;
		subj_alpha = 0.60;
		subj_combined = 0.60;
#else
		float form_zoom = mix(1.0, 1.02, lens);
		vec2 pf = p * form_zoom;
		float px = px_px * form_zoom;
		// 风只移动枝叶轮廓，地面贴花与矿石不随风漂移。
		if (family == 0 && form != 26) {
			float wind_time = motion;
			vec2 w = normalize(wind_dir + vec2(0.0001));
			vec2 local_w = vec2(dot(w, v_axis), -dot(w, vec2(-v_axis.y, v_axis.x)));
			float gust = sin(wind_time * 1.25 + seed * 21.0 + pf.y * 2.8)
				+ 0.38 * sin(wind_time * 2.1 + seed * 9.0 + pf.x * 3.0);
			float amp = (wind_strength + weather_wind_boost * 0.6) * (form == 0 || form == 7 ? 0.085 : 0.045);
			pf -= local_w * gust * amp * (1.0 - lens * 0.65);
		}
		RSurf s = rs_empty();
		vec4 mat_albedo = vec4(0.0);
		vec4 mat_surface = vec4(0.5, 0.5, 0.0, 1.0);
		float material_edge = 1.0;
		if (material_art) {
			mat2 material_xform = rv_material_instance_xform(seed);
			vec2 material_p = material_xform * pf;
			mat_albedo = rv_material_albedo(material_p);
			mat_surface = rv_material_surface(material_p);
			material_edge = mix(1.0,
				rv_material_contact_edge(mat_albedo, mat_surface, material_p, seed, false,
					solid_edge_softness),
				step(lens, 0.5));
			s.albedo = mat_albedo.rgb;
			s.n = rv_material_local_normal(mat_surface, material_xform);
			s.h = mat_surface.b;
			s.ao = mix(1.0, mat_surface.a, 0.92);
			s.spec = v_material.r;
			s.metallic = v_material.a;
			s.rim = 0.10;
			s.floor_col = mat_albedo.rgb * 0.36;
			s.floor_a = mat_albedo.a * material_shadow * material_edge;
		} else {
#ifdef PK_WEB_RESOURCE_MIN
			// web 精简变体：family == 3 也交给 rt_resource() → rt_badge_silhouette()。
			// 水里真的会绘制的鱼群走 rv_herd() 位图兽群（art_fish），下面这段 4 鱼 + 8 鳍
			// 的绘制只在 lens 徽章里出现，整段不参与编译（含 2×rs_blade 内联）。
			s = rt_resource(pf, form, family, sub_style, tint, seed, px,
				family == 1 ? motion * animal_motion : motion, lens < 0.5);
#else
			if (family == 3) {
				// Badge picture of marine & freshwater fish: 4 curved silver-aqua fish in a shoal.
				vec3 fish_col = sub_style == 0 ? vec3(0.46, 0.80, 0.88) : vec3(0.56, 0.86, 0.74);
				for (int i = 0; i < 4; i++) {
					float fi = float(i);
					vec2 fc = i == 0 ? vec2(-0.18, -0.14) : (i == 1 ? vec2(0.20, -0.02) : (i == 2 ? vec2(-0.12, 0.22) : vec2(0.18, 0.28)));
					float fscale = i == 0 ? 1.05 : (i == 1 ? 0.92 : 0.78);
					vec2 fp = rs_rot(-0.42 + fi * 0.12) * ((pf - fc) / fscale);
					fp.x += sin(fp.y * 6.5 + motion * 1.2 + fi) * 0.04;
					rs_part(s, fp, vec2(0.0, -0.04), vec2(0.13, 0.32), fish_col * (0.92 + 0.08 * fi), 0.14, px);
					rs_blade(s, fp, vec2(0.0, 0.20), vec2(-0.14, 0.44), 0.075, fish_col * 0.78, 0.10, px);
					rs_blade(s, fp, vec2(0.0, 0.20), vec2(0.14, 0.44), 0.075, fish_col * 0.78, 0.10, px);
				}
				s.spec = 0.82;
				s.rim = 0.35;
			} else {
				s = rt_resource(pf, form, family, sub_style, tint, seed, px, family == 1 ? motion * animal_motion : motion, lens < 0.5);
			}
#endif // PK_WEB_RESOURCE_MIN
		}

		bool free_standing = family == 1 || form == 6 || form == 7 || form == 26 || form == 16 || form == 17 || form == 18;
		// Outlines are off in the world by default (they read as stickers); badges keep a firm one.
		float outline_k = mix((free_standing ? 0.55 : 0.28) * outline_strength, free_standing ? 0.55 : 0.28, lens);

		vec3 base = s.albedo;
#ifndef PK_WEB_RESOURCE_MIN
		bool detailed_view = visual_quality > 0 && v_rank.y >= detailed_pixels;
#endif

		if (family == 0 && form != 26) {
			float dry = clamp((0.35 - v_climate.g) * 1.4 + (1.0 - health) * 0.45 + v_instance_detail.z * 0.12, 0.0, 1.0);
			base = mix(base, vec3(0.54, 0.45, 0.26), dry * climate_response * 0.38);
		}
		float snow_mask = snow * (family == 1 ? 0.18 : (s.h < 0.08 ? 0.55 : 0.85)) * smoothstep(-0.1, 0.5, s.n.z);
		base = mix(base, vec3(0.84, 0.88, 0.92), snow_mask);

		// Mute towards the terrain's palette: saturated catalogue colours stay on badges only.
		float grey_albedo = dot(base, vec3(0.299, 0.587, 0.114));
		base = mix(vec3(grey_albedo), base, palette_saturation);
		base = mix(rv_compress_luma(base), base, lens);

		vec2 screen_n = vec2(s.n.x, -s.n.y);
		vec2 world_slope = v_axis * screen_n.x + vec2(-v_axis.y, v_axis.x) * screen_n.y;
		vec3 normal = normalize(vec3(world_slope + terrain_normal.xy * s.n.z, max(s.n.z, 0.22)));
		float diffuse = max(dot(normal, light_dir), 0.0);

		vec3 view_dir = vec3(0.0, 0.0, 1.0);
		vec3 half_dir = normalize(light_dir + view_dir);
		float ndoth = max(dot(normal, half_dir), 0.0);
		float shininess = mix(14.0, 44.0, s.metallic * 0.6 + s.spec * 0.4);
		float spec_factor = pow(ndoth, shininess) * s.spec * (1.0 - snow_mask * 0.7) * 0.7;
		vec3 spec_color = mix(vec3(1.0), base * 1.35, s.metallic) * s.spec_tint;

		float rim_factor = pow(1.0 - max(dot(normal, view_dir), 0.0), 2.0) * s.rim;
		vec3 unlit = base;
		vec3 diff_light = rv_ambient_from(normal, ambient_color, direct_color,
			light_dir, day_state, sky_state) + bounce_light + direct_light * (diffuse * 0.78 + rim_factor * 0.10);
		base = (base * diff_light + direct_light * spec_color * spec_factor * 0.35) * s.ao;
		base *= 0.92 + 0.22 * clamp(s.h * 2.0, 0.0, 1.0);

		float edge_line = 0.0;
		float alpha = mat_albedo.a * material_edge;
		if (!material_art) {
			edge_line = (1.0 - smoothstep(0.0, px * 2.2, -s.d)) * step(s.d, 0.0);
			base *= 1.0 - edge_line * outline_k;
		}
		// Lens badges stay readable at night.
		base = mix(base, unlit * (0.92 + 0.16 * diffuse), lens * 0.80);

		if (!material_art) {
			float aa = clamp(fwidth(s.d), px * 0.60, px * 2.5);
			alpha = 1.0 - smoothstep(-aa, aa, s.d);
		}
		if (family == 0 && form != 26) {
			alpha *= mix(0.28, 1.0, health) * smoothstep(vitality_dead_threshold * 0.3, vitality_dead_threshold, v_climate.a);
			alpha *= 1.0 - snow * 0.60;
		}
		if (form == 22) {
			alpha *= 0.88;
		}
		if (form == 19 || form == 20) {
			alpha *= 0.90;
		}
		if (form == 25) {
			alpha *= 0.84;
		}
		// Areas, not objects: feather the silhouette into the terrain and let the ground
		// show between plants / crust grains. Badges keep the crisp silhouette.
		bool area_form = !material_art && (
			(family == 0 && form != 6 && form != 7 && form != 26)
			|| form == 18 || form == 19 || form == 20 || form == 22);
		if (area_form) {
			float warp = (vf_vnoise(pf * 5.0 + seed * 7.0) - 0.5) * area_edge_noise;
			// 羽化群落外沿，不能对每片叶/晶体的距离场再羽化，否则小实体全部消失。
			float inner = 1.0 - smoothstep(max(0.30, 0.92 - area_feather), 0.96, length(pf) + warp);
			alpha *= mix(inner, 1.0, lens);
		}

		// Soft ground contact; the silhouette-derived cast shadow is opt-in (cast_shadow).
		// Flat areas have no height, so no contact ring either.
		float shadow = s.floor_a * contact_shadow * (area_form ? lens : 1.0);
#ifdef PK_WEB_RESOURCE_MIN
		// web：cast_shadow 在 profile 里就是 0.0（data/visual/resource_default.tres），uniform
		// 默认值同为 0.0；而且 detailed_view 还要 visual_quality > 0，web auto 档解出 0。
		// 两重运行期门都是关的 → 这段 silhouette cast shadow（含 dFdx/dFdy）不编译。
#else
		if (!material_art && detailed_view && free_standing && lens < 0.5 && cast_shadow > 0.001) {
			vec2 grad = vec2(dFdx(s.d), dFdy(s.d));
			vec2 away = -normalize(light_dir.xy + vec2(0.0001));
			float facing = clamp(dot(normalize(grad + vec2(0.00001)), away), 0.0, 1.0);
			float reach = clamp(0.10 / max(light_dir.z, 0.35), 0.04, 0.26);
			float cast = (1.0 - smoothstep(0.0, reach * facing + 0.01, s.d)) * step(0.0, s.d) * facing;
			shadow = max(shadow, cast * 0.32 * cast_shadow * smoothstep(-0.06, 0.15, light_dir.z));
		}
#endif

		float grey = dot(base, vec3(0.299, 0.587, 0.114));
		base = mix(vec3(grey) * 0.85, base, mix(0.25, 1.0, live));
		float combined = alpha + shadow * (1.0 - alpha);
		vec3 shadow_tint = mix(vec3(0.11, 0.13, 0.095), s.floor_col, 0.45);
		subj_rgb = mix(shadow_tint, base, alpha / max(combined, 0.0001));
		subj_alpha = alpha;
		subj_combined = combined;
#endif // PK_PROBE_NO_SUBJECT
	}

	// World appearance by instance kind.
	vec3 world_rgb = subj_rgb;
	float world_a = subj_combined;
	if (kind == 2) {
#ifdef PK_PROBE_NO_DECAL
		// [probe] 把 rd_ground_decal()（kind == 2 的唯一着色来源）换成常量。
		vec3 probe_col = tint * flat_light;
		world_rgb = probe_col;
		world_a = 0.42;
#else
		bool material_ground = material_art && (form == 19 || form == 20 || form == 21
			|| form == 22 || form == 23 || form == 25);
		// [decal-ground-fit 2026-11-18] 坡面面积变形。俯视正交投影下，斜面上 1 单位
		// 长度只投影成 nz 单位，所以屏幕上 1 单位对应地表 1/nz 单位。沿坡向把实例坐标
		// 除以 nz，图案在坡上自然压密、在坡脚摊开 —— 这是"铺在斜面上"与"印在屏幕
		// 平面上"的唯一几何差别。纯 ALU，不新增采样；slope_fit = 0 时完全关闭。
		vec2 p_fit = p;
		vec2 slope_fit = terrain_normal.xy * decal_slope_fit;
		float slope2 = dot(slope_fit, slope_fit);
		if (slope2 > 1e-6) {
			vec2 axis_y = vec2(-v_axis.y, v_axis.x);
			vec2 along = slope_fit * inversesqrt(slope2);
			vec2 across = vec2(-along.y, along.x);
			vec2 woff = v_axis * p.x + axis_y * p.y;
			woff = along * (dot(woff, along) / clamp(terrain_normal.z, 0.32, 1.0))
				+ across * dot(woff, across);
			p_fit = vec2(dot(woff, v_axis), dot(woff, axis_y));
		}
		mat2 material_xform = rv_material_instance_xform(seed);
		vec2 material_p = material_xform * p_fit;
		vec4 g = material_ground ? rv_material_albedo(material_p) : rd_ground_decal(p_fit, form, sub_style, tint, seed);
		vec3 col = g.rgb;
		float grey_albedo = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(grey_albedo), col, palette_saturation);
		col = rv_compress_luma(col);
		col = mix(col, vec3(0.84, 0.88, 0.92), snow * 0.55);
		// [decal-ground-fit] 地表颜色继承。贴花原先是与地表无关的独立位图，两张图
		// alpha 叠 60% —— 大脑读作"上面多了一层"。这里用已绑定的 height 推
		// hypsometric 地表色（低地沃土 → 高地灰褐），只取**相对色偏**（除以自身明度）
		// 调制贴花色温，不动明度，所以不会把深色材料洗灰。零新增采样。
		vec3 ground_shift = vec3(1.0);
		if (has_height_tex && decal_ground_tint > 0.001) {
			vec4 gsample = visual_sample_height(surface_uv);
			float gh = (gsample.r * 256.0 + gsample.g) / 257.0;
			float upland = smoothstep(sea_level + 0.02, 0.86, gh);
			vec3 ground_col = mix(vec3(0.66, 0.64, 0.40), vec3(0.76, 0.70, 0.58), upland);
			ground_shift = ground_col / max(dot(ground_col, vec3(0.299, 0.587, 0.114)), 0.02);
		}
		col *= mix(vec3(1.0), ground_shift, decal_ground_tint);
		float material_edge = 1.0;
		// Procedural decals already carry their alpha mask; generated ground art
		// replaces that mask with its height-feathered material coverage below.
		float material_coverage = g.a;
		if (material_ground) {
			vec4 surf = rv_material_surface(material_p);
			material_edge = rv_material_contact_edge(g, surf, material_p, seed, true,
				decal_edge_softness);
			// Never manufacture coverage outside the authored silhouette. The atlas
			// height already eases to zero inside that silhouette, so this feather
			// follows the mineral/soil edge instead of revealing the square cell.
			material_coverage = g.a * material_edge;
			vec3 material_normal = rv_material_normal(surf, v_axis, terrain_normal,
				material_xform);
			vec3 normal = normalize(mix(terrain_normal, material_normal,
				mix(1.0, material_edge, 0.72)));
			float diffuse = max(dot(normal, light_dir), 0.0);
			// [decal-ground-fit 2026-11-18] 法线进 ambient。原实现把 terrain_normal
			// 的 ambient 当作整块贴花的基线，等于向渲染器声明"你和脚下地面一样平"：
			// 贴花自身的起伏永远进不了天光项，只剩 direct 的一个乘性偏置。这里让
			// ambient 与 direct 都按贴花法线求，再与地形基线 mix —— 既拿到体积，
			// 也不会把深色材料（油、湿土）洗成灰。
			vec3 decal_amb = rv_ambient_from(normal, ambient_color, direct_color,
				light_dir, day_state, sky_state);
			vec3 decal_light = mix(flat_light,
				decal_amb + bounce_light + direct_light * diffuse * 0.78, 0.55);
			// 接触边阴影：原系数 0.08 在 contact_shadow=0.68 下只压暗 ~5%，
			// 等于没有接地。0.40 才能让贴花边缘"咬"进土里。
			col *= 1.0 - (1.0 - material_edge) * contact_shadow * 0.40;
			col *= decal_light * mix(1.0, surf.a, 0.80);
		} else {
			col *= flat_light;
		}
		float grey = dot(col, vec3(0.299, 0.587, 0.114));
		world_rgb = mix(vec3(grey) * 0.85, col, mix(0.25, 1.0, live));
		float strength = clamp(0.55 + v_rank.x * 0.15, 0.55, 1.0);
		world_a = material_coverage * decal_opacity * strength * (1.0 - snow * 0.45);
		if (form == 22) {
			// 地力以健康草被表达，干旱/低活力转黄、退隐，积雪下不铺绿色地毯。
			world_a *= smoothstep(vitality_dead_threshold, 0.65, v_climate.a) * (1.0 - snow * 0.80);
		}
#endif // PK_PROBE_NO_DECAL
	} else if (art_animal) {
#ifdef PK_PROBE_NO_HERD
		// [probe] 把 rv_herd() 的两处调用（art_animal / art_fish）换成常量。
		world_rgb = tint * flat_light;
		world_a = 0.50;
#else
		float sh = 0.0;
		vec4 herd = rv_herd(p, v_art.y - 1.0, v_art.z, seed, v_rank.x, motion, animal_motion * live, animal_length_hex, 1.0, sh);
		vec3 col = herd.rgb;
		float grey_albedo = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(grey_albedo), col, palette_saturation);
		col = mix(col, rv_compress_luma(col), 0.35);
		col = mix(col, vec3(0.84, 0.88, 0.92), snow * 0.18);
		col *= flat_light;
		float grey = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(grey) * 0.85, col, mix(0.25, 1.0, live));
		float shadow = sh * art_animal_shadow * (1.0 - herd.a);
		vec3 shadow_tint = vec3(0.09, 0.10, 0.08) * flat_light;
		float combined = herd.a + shadow;
		world_rgb = mix(shadow_tint, col, herd.a / max(combined, 0.0001));
		world_a = combined;
#endif // PK_PROBE_NO_HERD
	} else if (art_fish) {
#ifdef PK_PROBE_NO_HERD
		world_rgb = tint * flat_light;
		world_a = 0.50;
#else
		float sh = 0.0;
		vec4 shoal = rv_herd(p, v_art.y - 1.0, v_art.z, seed, v_rank.x, motion * 1.6, 1.8 * live, fish_length_hex, 0.8, sh);
		vec3 col = mix(shoal.rgb, vec3(0.16, 0.30, 0.36), 0.40) * flat_light;
		float strength = clamp(0.55 + v_rank.x * 0.15, 0.55, 1.0);
		world_rgb = col;
		world_a = shoal.a * clamp(submerged_opacity * 1.5, 0.0, 0.85) * strength * mix(0.6, 1.0, live) * clamp(v_misc.y, 0.0, 1.0);
#endif // PK_PROBE_NO_HERD
	} else if (kind == 3 && material_art && (form == 21 || form == 25)) {
		mat2 material_xform = rv_material_instance_xform(seed);
		vec2 material_p = material_xform * p;
		vec4 g = rv_material_albedo(material_p);
		vec4 surf = rv_material_surface(material_p);
		float material_edge = rv_material_contact_edge(g, surf, material_p, seed, true,
			decal_edge_softness);
		float material_coverage = g.a * material_edge;
		vec3 material_normal = rv_material_normal(surf, v_axis, terrain_normal,
			material_xform);
		vec3 normal = normalize(mix(terrain_normal, material_normal,
			mix(1.0, material_edge, 0.72)));
		float diffuse = max(dot(normal, light_dir), 0.0);
		float response = clamp(1.0 + (diffuse - flat_diffuse) * 0.55, 0.45, 1.35);
		vec3 col = mix(g.rgb, vec3(0.10, 0.22, 0.25), form == 21 ? 0.48 : 0.30);
		col *= 1.0 - (1.0 - material_edge) * contact_shadow * 0.08;
		col *= flat_light * response * mix(1.0, surf.a, 0.55);
		float strength = clamp(0.55 + v_rank.x * 0.15, 0.55, 1.0);
		world_rgb = col;
		world_a = material_coverage * submerged_opacity * strength * mix(0.6, 1.0, live) * clamp(v_misc.y, 0.0, 1.0);
	} else if (kind == 3) {
#ifdef PK_PROBE_NO_SUBMERGED
		// [probe] 把 rd_submerged()（kind == 3 的程序化水下贴花）换成常量。
		world_rgb = tint * flat_light;
		world_a = 0.40;
#else
		vec4 w = rd_submerged(p, form, family, sub_style, seed, motion);
		world_rgb = w.rgb * flat_light;
		float strength = clamp(0.55 + v_rank.x * 0.15, 0.55, 1.0);
		world_a = w.a * submerged_opacity * strength * mix(0.6, 1.0, live) * clamp(v_misc.y, 0.0, 1.0);
#endif // PK_PROBE_NO_SUBMERGED
	} else if (kind >= 4) {
		world_a = 0.0;
	}
	float horizon_cast = clamp((1.0 - horizon_visibility) * day_state.x, 0.0, 1.0);
	float cast_floor = mix(1.0, terrain_horizon_cast_floor, 0.70);
	cast_floor = mix(1.0, cast_floor, mix(1.0, sky_state.w, gi_ao_strength));
	world_rgb *= mix(1.0, cast_floor, horizon_cast);

	vec3 color = world_rgb;
	float out_alpha = world_a;
#ifndef PK_PROBE_NO_BADGE
	if (lens > 0.001) {
		// Shape-coded recognition badge: circle = animal, rounded square = plant,
		// hexagon = mineral. The ring colour repeats the category; the picture inside is
		// the same subject drawn on the map, so the badge teaches the map and vice versa.
		float bd = rt_badge_sdf(p, family);
		float inside = 1.0 - smoothstep(-px_px, px_px, bd);
		float ring = 1.0 - smoothstep(0.0, px_px * 1.5, abs(bd + 0.075) - 0.075);
		float rim = 1.0 - smoothstep(0.0, px_px * 1.2, abs(bd - 0.03) - 0.03);
		float halo = (1.0 - smoothstep(0.0, 0.12, bd)) * step(0.0, bd);
		vec3 backing = mix(vec3(0.43, 0.47, 0.48), vec3(0.28, 0.32, 0.34), smoothstep(0.1, 0.8, length(p)));
		vec3 badge_rgb = mix(backing, subj_rgb, clamp(subj_alpha, 0.0, 1.0));
		badge_rgb = mix(badge_rgb, rt_badge_ring(family), ring);
		vec3 out_rgb = vec3(0.02, 0.03, 0.03);
		float out_a = halo * 0.38;
		out_rgb = mix(out_rgb, vec3(0.96), rim);
		out_a = max(out_a, rim);
		out_rgb = mix(out_rgb, badge_rgb, inside);
		out_a = max(out_a, inside);
		color = mix(world_rgb, out_rgb, lens);
		out_alpha = mix(world_a, out_a, lens);
	}
#endif // PK_PROBE_NO_BADGE
#ifndef PK_WEB_RESOURCE_MIN
	// 调试视图：uniform 默认 0，只有 set_terrain_horizon_debug_view() 会推非 0。
	// web 变体里 v_horizon 恒为 1，留着它只会把整张图刷白，所以整段不编译。
	if (lens < 0.001 && terrain_horizon_debug_view > 0) {
		color = vec3(terrain_horizon_debug_view == 1
			? (1.0 - horizon_visibility) * day_state.x
			: horizon_visibility);
	}
#endif
	if ((family == 0 || kind == 2) && has_height_tex && lens < 1.0) {
		// 扩大的植被/地力斑必须沿实际河岸裁切，不能只检查群落中心。
		// [decal-ground-fit] 与坡度变形/地表色用同一个逐像素 uv，避免两套 wrap 约定
		// 在东西包裹缝两侧裁出不一致的岸线。
		vec4 ground = visual_sample_height(surface_uv);
		float height = (ground.r * 256.0 + ground.g) / 257.0;
		float land = smoothstep(sea_level - 0.002, sea_level + 0.002, height);
		float river = has_flow_tex ? 1.0 - smoothstep(river_clear_threshold - 0.08, river_clear_threshold, ground.b) : 1.0;
		out_alpha *= mix(land * river, 1.0, lens);
	}
	// [res-fog-memory 2026-11-18] 与地形、植被**同一份**灰化：同一片未发现区里
	// 道具、贴花、植株、地表必须是同一个纸白。
	color = pk_fog_memory_wash(color, v_instance_detail.w, 0.94);
	COLOR = vec4(color, out_alpha * v_style.a);
}
