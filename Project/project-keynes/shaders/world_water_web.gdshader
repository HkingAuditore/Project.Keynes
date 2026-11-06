shader_type canvas_item;
// [pk-web-texture-budget] 与 world_map.gdshader 同一理由：光照全部自算、项目从不使用
// Light2D，缺 unshaded 会让 Godot 额外编译"受光"路径并隐式多占 1-2 个 fragment 纹理
// 单元。canvas_item 的其它全屏 shader（data_overlay / fog_of_war / country_border /
// hex_edge_overlay / world_map）都已带 unshaded，这里保持一致。
render_mode blend_mix, unshaded;

// Compact water pass for Web LOW/MID. HIGH uses world_map's PC water pipeline
// in a separate draw, with PK_WEB_WATER_ONLY. Both share Earth daylight and GGX.
// Seven material samplers; LOW keeps flat water, MID enables PBR and wave normals.
// Cell indexing, height packing and fog conventions match the terrain pass.
//
// [surface-array-edge 2026-11-02] 采样器 5→6：新增的 1 张是与陆地程序**同一个**
// sampler2DArray `terrain_surface_tex`（非 tiled 6 层静态地表打包，见 visual_tile_sampling）。
// 只读 layer4（edge_distance：R 格界距离 / BA 8 邻域水·湖占比）与 layer5（次生 cell id），
// 用来恢复 world_map 水面分支在 Web 预算下被裁掉的两段：
//   ① edge_mix —— 次生水格（海/湖/礁/海带交界）的连续混合权重；
//   ② shore_frac —— 岸线浅滩比例（烘焙 8 邻域占比，双线性过滤后是连续场）。
// 数据本来就在同一个 native tile bundle 里，所以这是**零新增烘焙**的画质回收，
// 也是"水色方块 + 硬边浅滩"变成连续过渡的全部原因。

#include "res://shaders/include/shader_quality.gdshaderinc"

// This compact program is prewarmed with the LOW compile tier.
#ifndef PK_QUALITY_LOW
#error "world_water_web.gdshader requires MOBILE_QUALITY_LOW / PK_SHADER_TIER_LOW"
#endif

// ═══════════════════════════════════════════════════════════════════════════
// 【世界 / 坐标系】与 uniforms.gdshaderinc:172-176 同名同义，只声明本 pass 用到的。
// varying 同 uniforms.gdshaderinc:688（vertex 写、fragment 读世界坐标）。
// ═══════════════════════════════════════════════════════════════════════════
varying vec2 v_world;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

// ═══════════════════════════════════════════════════════════════════════════
// 【Cell-index 间接寻址】与 uniforms.gdshaderinc:139-147 同源：
//   enum_lut / dyn_lut 必须 NEAREST；lut_dims 是 LUT 网格尺寸。
// world_map 还声明 map_index_atlas（此处由 visual_tile_sampling 按 tiled/legacy 二选一
// 声明）、height_tex（同上），所以下面两个 VT_USE_* 之外不重复声明。
// ═══════════════════════════════════════════════════════════════════════════
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);

// ═══════════════════════════════════════════════════════════════════════════
// 【烘焙水深】[web-high-features 2026-11-01 / 方案 B] R8 derived 的 water_depth：
// R=水深 [0,1]，0=岸/陆、1=最深。本文件不 include uniforms.gdshaderinc，所以自行
// 声明这个 bool；采样器 water_depth_tex 由 visual_tile_sampling 在 VT_USE_WATER_DEPTH 下声明。
// compact 水面程序因此 4→5 个材质 sampler（仍在 Web 预算内）。
// ═══════════════════════════════════════════════════════════════════════════
uniform bool has_water_depth_tex = false;

// ═══════════════════════════════════════════════════════════════════════════
// 【静态 edge 场】[surface-array-edge 2026-11-02] 与陆地程序共用 surface array 的
// layer4/layer5（见 visual_tile_sampling）。本文件不 include uniforms.gdshaderinc，
// 所以这两个 bool 与 ecotone 宽度在这里自行声明；采样器本身由 include 按 VT_USE_* 声明。
//   has_terrain_edge_data     ：layer4/5 是否烘出来了（运行期按 get_layers()>=6 推）
//   terrain_ecotone_width     ：与 uniforms.gdshaderinc 同默认值/同 hint
//   WATER_EDGE_LOW_SCALE      ：LOW 档的过渡带收缩系数，逐值对齐
//                               terrain_surface_detail.gdshaderinc 的 mobile_quality_scale
//                               （visual_quality<=0 ⇒ 0.58）。水面不读 visual_quality 分支，
//                               这样 LOW/MID 共用同一份编译产物、不会多一个变体。
// ═══════════════════════════════════════════════════════════════════════════
uniform bool has_terrain_edge_data = false;
uniform float terrain_ecotone_width = 0.84;
const float WATER_EDGE_LOW_SCALE = 0.58;

// ═══════════════════════════════════════════════════════════════════════════
// 【迷雾】口径与 uniforms.gdshaderinc:158-166 + renderer _push_fog_uniforms() 一致。
// [land-water-split 2026-11-02] 未探索像素改为**本 pass 自己画 fog_unexplored_color**，
// 不再 discard 让位。原因：陆 / 水拆成两张覆盖 mesh 之后，纯水 block 不由陆地 mesh
// 覆盖（Web 上迷雾层也可能被裁掉），如果这里让位，纯水区域的迷雾就会露出空洞。
// 颜色与陆地 program 同源（同一 uniform、同一值，由 _apply_water_uniforms 推送）：
// 两片画同色是幂等的，Web 现状视觉不变。
// ═══════════════════════════════════════════════════════════════════════════
uniform bool fog_gray_enabled = true;
uniform float fog_gray_strength : hint_range(0.0, 1.0) = 0.75;
uniform bool fog_early_out_enabled = false;
uniform float fog_early_out_k : hint_range(0.0, 0.5) = 0.02;
// 必须与 uniforms.gdshaderinc 的声明逐字一致（source_color hint / 默认值），否则
// 同色会差一个色彩空间转换。
uniform vec3 fog_unexplored_color : source_color = vec3(0.263, 0.290, 0.353);

// ═══════════════════════════════════════════════════════════════════════════
// 【羊皮纸】apply_global_adjustments 的最后一步；world_map 侧同名同 hint 同默认值，
// 由 renderer 的 @export 属性直推（_apply_uniforms():4447-4448，本 pass 在
// _apply_water_uniforms():1108-1109 推同一对属性）。
// 声明必须逐字与 uniforms.gdshaderinc:547-548 一致：source_color hint 会影响
// Godot 对传入 Color 的处理，两边不同就会差一个色。
// ═══════════════════════════════════════════════════════════════════════════
uniform vec3 parchment_tint : source_color = vec3(0.96, 0.88, 0.74);
uniform float parchment_strength : hint_range(0.0, 0.4) = 0.10;

// ═══════════════════════════════════════════════════════════════════════════
// 【调试视图让位】terrain_surface_debug_view != 0 时 pass 1 会整屏输出诊断色
// （world_map.gdshader:441-482），本 pass 必须整体让位，否则 GM 面板的 13/14/16/17
// 会被水面覆盖掉。1 个 int 换"诊断工具在 web 上仍然可用"是划算的。
// ═══════════════════════════════════════════════════════════════════════════
uniform int terrain_surface_debug_view = 0;

// All Web settings share this program. LOW retains the original flat water;
// MID/HIGH restore physical lighting and a small, wrap-safe wave normal.
uniform int visual_quality = 0;
uniform float world_time = 0.0;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4091;
uniform bool day_night_enabled = true;
uniform bool water_effect_enabled = true;
uniform bool ocean_current_enabled = true;
uniform sampler2D ocean_current_flow_tex : filter_linear_mipmap, repeat_enable;
uniform bool ocean_current_flow_tex_bound = false;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.6, -0.4, 0.7);
uniform float tod_exposure = 1.0;

#define PK_WEB_WATER_PBR
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/material_constants.gdshaderinc"
#include "res://shaders/include/tonemap.gdshaderinc"
#include "res://shaders/include/pbr_microfacet.gdshaderinc"

vec3 shade_water_web(vec3 albedo_srgb, vec2 uv, float ice) {
	EarthDaylight ed = eval_earth_daylight(uv, uv.y * 2.0 - 1.0, day_night_enabled);
	float longitude = earth_daylight_longitude_u(uv) * EARTH_DAYLIGHT_TAU;
	vec2 flow = vec2(0.8, 0.3);
	if (ocean_current_enabled && ocean_current_flow_tex_bound) {
		flow = textureLod(ocean_current_flow_tex, uv, 2.0).rg * 2.0 - 1.0;
	}
	vec2 d1 = length(flow) > 0.035 ? normalize(flow) : normalize(vec2(0.8, 0.3));
	float phase_a = longitude * 96.0 * d1.x + v_world.y * 0.18 * d1.y + world_time * 0.75;
	float footprint = max(fwidth(phase_a), 0.0);
	float wave = water_effect_enabled ? (1.0 - ice) * (1.0 - smoothstep(0.5, 2.5, footprint)) : 0.0;
	// Integer longitude frequencies preserve continuity across the world seam.
	vec2 slope = cos(phase_a) * d1 * 0.08;
	if (visual_quality >= 2) {
		vec2 d2 = normalize(vec2(-d1.y, d1.x) * 0.58 + d1 * 0.82);
		float phase_b = longitude * 173.0 * d2.x - v_world.y * 0.26 * d2.y - world_time * 0.53;
		slope += cos(phase_b) * d2 * 0.028;
	}
	vec3 N = normalize(vec3(slope * wave, 1.0));
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 L = ed.local_day >= ed.moon_strength ? ed.sun_dir : ed.moon_dir;
	vec3 H = normalize(L + V);
	float nl = max(dot(N, L), NDOTL_BIAS);
	float nv = max(N.z, NDOTL_BIAS);
	float roughness = mix(0.30, 0.72, ice);
	vec3 F = F_Schlick(F0_WATER, max(dot(V, H), 0.0));
	vec3 spec = D_GGX(max(dot(N, H), 0.0), roughness)
		* G_SmithGGX(nl, nv, roughness) * F / max(4.0 * nl * nv, 0.0001);
	vec3 sun = srgb_to_linear(ed.sun_col) * (SUN_INTENSITY_GAIN * ed.local_day)
		+ srgb_to_linear(ed.moon_col) * ed.moon_strength;
	vec3 albedo = srgb_to_linear(albedo_srgb);
	vec3 diffuse = (vec3(1.0) - F) * albedo * INV_PI;
	vec3 ambient = srgb_to_linear(earth_sky_sh(ed.amb_col, ed.sun_col, L, ed.local_day, N));
	vec3 reflected_sky = mix(vec3(0.20, 0.37, 0.52), ed.amb_col, clamp(N.z, 0.0, 1.0));
	vec3 lit = (diffuse + spec) * nl * sun + albedo * ambient
		+ srgb_to_linear(reflected_sky) * F * (1.0 - ice) * 1.8;
	lit *= mix(1.0, NIGHT_BRIGHTNESS_FLOOR, ed.pixel_night) * tod_exposure;
	return linear_to_srgb(apply_tonemap(lit));
}

// ── 只为解码服务的地表静态贴图：height（RG=高程）与 map_index（GB=cell id）──
// 这两个 VT_USE_* 必须定义在 include 之前；tiled/legacy 的二选一由 include 内部的
// MAP_VISUAL_TILED 决定（与 world_map.gdshader:85-110 完全同一套约定）。
// [web-high-features 2026-11-01 / 方案 B] WATER_DEPTH：湖泊深度改用烘焙水深渲染，
// 海面仍用连续 elev（见 render_water_pipeline_web_min）。
#define VT_USE_HEIGHT
#define VT_USE_MAP_INDEX
#define VT_USE_WATER_DEPTH
// [surface-array-edge 2026-11-02] 5→6 槽：与陆地程序共用同一个 surface array；
// 只读 layer4/layer5（edge_distance / 次生 cell id），不声明 normal/relief/horizon。
#define VT_USE_TERRAIN_SURFACE_ARRAY
#define VT_USE_EDGE_DISTANCE
#define VT_USE_EDGE_NEIGHBOR
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

// cell_lut_uv()（唯一对外成员）+ decode_cell_index()/dyn_lut_nearest()（本文件不用，
// 编译器整段删掉）。依赖上面已声明的 dyn_lut / lut_dims / visual_sample_map_index。
#include "res://shaders/include/cell_indirect.gdshaderinc"

// ═══════════════════════════════════════════════════════════════════════════
// 【Biome / Cover id】只取本 pass 真正比较到的 7 个。
// 数值必须与 uniforms.gdshaderinc:570-644 逐值一致（CPU 端 terrain_type.gd /
// cover_type.gd 亦与之对齐）。tests/world/terrain_shader_variant_test.gd 有一条
// 逐值一致性断言守着这里，改一处必须改另一处。
// ═══════════════════════════════════════════════════════════════════════════
const int B_OCEAN   = 0;
const int B_COAST   = 1;
const int B_LAKE    = 18;
const int B_REEF    = 19;
const int B_SEA_ICE = 20;
const int B_KELP    = 21;
const int CV_SEA_ICE = 3;

// ═══════════════════════════════════════════════════════════════════════════
// 【次生水格】[surface-array-edge 2026-11-02] world_map 里这两件事分别由
// terrain_surface_detail.decode_edge_secondary_index() 与 terrain_static_biome_is_water()
// 完成；本 pass 没有 include 那个文件（它会拖进材质族/细节噪声一整条依赖），
// 所以在这里给等价的 6 行实现，语义逐字对齐：
//   - 次生 id 是 16-bit little-endian，0xFFFF = 无；
//   - "水的域"判定与陆地/水面 program 的 is_water 谓词同一组 biome。
// ═══════════════════════════════════════════════════════════════════════════
int water_edge_secondary_index(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(uv).rg;
	int cid = int(rg.r * 255.0 + 0.5) + int(rg.g * 255.0 + 0.5) * 256;
	return (cid >= 65535) ? -1 : cid;
}

bool water_edge_is_water(int biome) {
	return biome == B_OCEAN || biome == B_COAST || biome == B_LAKE
			|| biome == B_REEF || biome == B_KELP || biome == B_SEA_ICE;
}

// ═══════════════════════════════════════════════════════════════════════════
// 【wrap helper】逐字复制 uniforms.gdshaderinc:185-203（wrap_world_x / wrap_map_uv）。
// 只复制这两个：本 pass 不需要 wrap_world_pos（水面 web-min 的着色函数不消费 wp）。
// 逐字复制是硬要求——差一个 clamp 或 mod 就会在环绕缝/极区产生一像素宽的光带。
// test 里有一条"文本必须与 uniforms.gdshaderinc 逐字相同"的断言守着。
// ═══════════════════════════════════════════════════════════════════════════
float wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 wrap_map_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

// ═══════════════════════════════════════════════════════════════════════════
// 水面着色本体 —— 从 world_map.gdshader 拆分前那段 `#ifdef PK_WEB_WORLD_MIN` 里的
// render_water_pipeline_web_min() **原样搬迁**（该函数已随本次拆分从 world_map 删除；
// 迁移前的原文见 git 历史 / tmp/next/web_water_two_pass_IMPL.md）。
// 只删掉签名里那 8 个从未被函数体读取的形参（wp / uv / scals / lat_signed /
// current_temp / ocean_current_v / wind_v / pixel_noise），保留全部算式与常量。
// 这也是 web 上水面"没有波光/SSS/焦散/洋流条纹"的原因 —— web-LOW 档本来就没跑
// 这些子系统（waves_on=false、ctx.quality=0），视觉增量只存在于桌面。
//
// ⚠ 这里**一个 if 都不能有**。实测（当时还在 world_map 里）：把水面分支换成常量 →
// world_map 总编译 2 473 ms；换成带 if/else-if 的紧凑版本 → 17 264 ms。分歧分支
// 一旦出现在第二个大着色来源里，FXC 的优化时间就从"秒"跳到"十几秒"。本 pass 现在
// 是独立的 fragment，理论上没那么敏感，但仍保持全直线写法（编译器可降成 select），
// 免得将来有人把本 pass 合回主 shader 时重新踩同一个坑。
// [surface-array-edge 2026-11-02] 次生水格查表放在 fragment 的前导段（fragment()
// 里那段 `if (has_terrain_edge_data ...)`），本函数签名里只收它的结果（secondary_* /
// edge_mix / shore_frac），着色本体仍是零分支。
// ═══════════════════════════════════════════════════════════════════════════
vec3 render_water_pipeline_web_min(
		int biome,
		int cover,
		int secondary_biome,
		int secondary_cover,
		float edge_mix,
		float elev,
		float dyn_ice_frac,
		vec2 shore_frac,
		vec2 uv,
		vec4 water_depth_px) {
	// 深度：elev 是 [0,1] 的归一化高程，海面普遍很低，越浅越亮。
	// [web-high-features 2026-11-01 / 方案 B] 湖泊改用烘焙 water_depth（湖岸→湖心碗形，
	// 避免整片湖水同色）；海面仍用连续 elev 深度。全部 select/mix 直线写法，不引入
	// if/else —— 本 pass 的历史教训：第二个着色来源里的分歧分支会把 FXC 编译时间从
	// 秒级推到十几秒。
	// [finish-four 2026-11-01 / 收尾 C] 非 tiled 的 water_depth_tex 升级 RGBA8：
	// R=水深，G/B/A=湖/礁/海带 3×3 软权重。软权重只提升 w_lake/w_reef/w_kelp，不改
	// 几何/海冰/岸线逻辑；未绑定（引擎默认白纹理）时 soft_w 归零，GBA=0 的旧 R8 回退
	// 因此精确等价原来的二元 biome 权重。
	float wd_raw = water_depth_px.r;
	float wd = has_water_depth_tex ? wd_raw : -1.0;
	float lake_w = max((biome == B_LAKE) ? 1.0 : 0.0,
			(secondary_biome == B_LAKE) ? 1.0 : 0.0);
	float ocean_depth_t = clamp(elev * 3.5, 0.0, 1.0);
	float baked_depth_t = clamp(wd, 0.0, 1.0);
	float depth_t = mix(ocean_depth_t, baked_depth_t, lake_w * step(0.0, wd));
	vec3 col = mix(vec3(0.045, 0.115, 0.235), vec3(0.185, 0.400, 0.470), depth_t);
	// 次生水体（湖泊/内海交界）向主 biome 混合，保留边缘过渡。
	col = mix(col, col * 0.92 + vec3(0.02, 0.03, 0.02), clamp(edge_mix, 0.0, 0.5));
	vec4 soft_w = has_water_depth_tex ? water_depth_px : vec4(0.0);
	float w_coast = (biome == B_COAST) ? 1.0 : 0.0;
	float w_lake = max((biome == B_LAKE) ? 1.0 : 0.0, soft_w.g);
	float w_reef = max((biome == B_REEF) ? 1.0 : 0.0, soft_w.b);
	float w_kelp = max((biome == B_KELP) ? 1.0 : 0.0, soft_w.a);
	vec3 biome_tint =
		vec3(0.235, 0.470, 0.500) * w_coast +
		vec3(0.145, 0.320, 0.390) * w_lake +
		vec3(0.145, 0.430, 0.445) * w_reef +
		vec3(0.090, 0.240, 0.205) * w_kelp;
	float biome_w = clamp(w_coast + w_lake + w_reef + w_kelp, 0.0, 1.0);
	col = mix(col, biome_tint, biome_w * 0.48);
	// 岸线浅滩：shore_frac 是陆/水两侧的岸线占比。
	float shore = clamp(max(shore_frac.x, shore_frac.y), 0.0, 1.0);
	col = mix(col, vec3(0.290, 0.545, 0.560), shore * 0.45);
	// 海冰：biome / cover / 动态冰量取最大，再向近白色混合（同样无分支）。
	float ice_flag = max(
		max((biome == B_SEA_ICE) ? 1.0 : 0.0, (secondary_biome == B_SEA_ICE) ? 1.0 : 0.0),
		max((cover == CV_SEA_ICE) ? 1.0 : 0.0, (secondary_cover == CV_SEA_ICE) ? 1.0 : 0.0));
	float ice = max(clamp(dyn_ice_frac, 0.0, 1.0), ice_flag * 0.85);
	col = mix(col, vec3(0.840, 0.900, 0.950), ice);
	return col;
}

void vertex() {
	// 与 world_map.gdshader:167-169 逐字相同：两块 quad 共用同一个 ArrayMesh，
	// 又是同一个父节点的直接子节点（都无自身变换），所以 v_world 逐像素相等。
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// 调试视图整屏归 pass 1（见 uniform 处注释）。
	if (terrain_surface_debug_view > 0) {
		discard;
	}

	// ── SETUP：坐标 + cell 索引（与 world_map:184-241 同源，采样顺序刻意不同：
	// 先把"是不是水"判掉再取 height/dyn，非水像素只花 2 次 fetch 就 discard）──
	vec2 uv = wrap_map_uv((v_world - world_origin) / world_size);
	vec4 map_px = visual_sample_map_index(uv);
	int cell_id = int(map_px.g * 255.0 + 0.5) + int(map_px.b * 255.0 + 0.5) * 256;
	cell_id = (cell_id >= 65535) ? -1 : cell_id;

	int biome;
	int cover;
	float fog_k;
	float dyn_ice_frac;
	// world_map 在 PK_QUALITY_LOW 下把"次生水体查表"整段裁掉
	// （world_map 的 `#if !defined(PK_QUALITY_LOW)` 块）。本 pass 是独立 fragment、
	// 只有水面一个着色来源，不存在那次 20 s 联合编译悬崖，所以 [surface-array-edge
	// 2026-11-02] 起在水面像素上**恢复**该查表（见下方 edge 块），默认仍是主 cell。
	int secondary_biome;
	int secondary_cover;
	float static_edge_mix = 0.0;
	if (cell_id >= 0) {
		vec4 elut = texture(enum_lut, cell_lut_uv(cell_id));
		biome = int(elut.r * 255.0 + 0.5);
		cover = int(elut.b * 255.0 + 0.5);
		fog_k = elut.a;
		dyn_ice_frac = texture(dyn_lut, cell_lut_uv(cell_id)).a;
		secondary_biome = biome;
		secondary_cover = cover;
	} else {
		// 地图外 padding：world_map 把它表现为海冰（world_map:274-278 / 337）。
		biome = B_SEA_ICE;
		cover = 0;
		fog_k = 1.0;
		dyn_ice_frac = 1.0;
		secondary_biome = B_SEA_ICE;
		secondary_cover = 0;
	}

	// 逐字复制 world_map:303-304 的水格判定（同一张 enum_lut、同一个字节）。
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
	if (!is_water) {
		discard;
	}
	// [land-water-split 2026-11-02] 未探索像素改由本 pass 画 fog_unexplored_color
	// （与陆地 program 同一 uniform 值），不再 discard —— 纯水 block 在分 mesh 后
	// 没有陆地 pass 兜底，让位会露出迷雾空洞。早期退出仍然保留：直接跳过整条水面
	// 着色，只写一个常量色。
	if (fog_early_out_enabled && (fog_k <= fog_early_out_k)) {
		COLOR = vec4(fog_unexplored_color, 1.0);
	} else {
		// 水深 → 归一高程（height.RG = 16-bit，解码同 world_map:208-209）。
		vec4 height_px = visual_sample_height(uv);
		float elev = (height_px.r * 256.0 + height_px.g) / 257.0;
		// [收尾 C] water_depth 升级 RGBA8 后一次采样同时给出 R=深度与 G/B/A 软权重。
		vec4 water_depth_px = visual_sample_water_depth(uv);
		// [surface-array-edge 2026-11-02] 岸线占比 + 次生水格（world_map 水面分支被预算裁掉的
		// 那两段，算式逐项对齐 world_map.gdshader 的 `water_secondary_*` / `shore_frac`）：
		//   ① 权重用**连续**距离场，不转 DitherUV ⇒ 水色方块变成连续过渡；
		//   ② 次生格只在"同样在水域"时接管 ⇒ 海/湖交界不会被陆地色污染；
		//   ③ shore_frac 是烘焙的 8 邻域水·湖占比，双线性过滤后是连续场 ⇒ 浅滩不再硬边。
		// has_terrain_edge_data=false（旧图 / 烘失败 / 层数不足）时整段跳过，行为退回
		// C 回合：edge_mix=0、shore_frac=0。layer4/5 的采样在 helper 内部另有
		// terrain_edge_layers_bound 门控，绝不采样越界层。
		vec2 shore_frac = vec2(0.0);
		if (has_terrain_edge_data && cell_id >= 0) {
			vec4 edge_px = visual_sample_edge_distance(uv);
			shore_frac = edge_px.ba;
			float edge_w = terrain_static_edge_weight(
					edge_px.r, terrain_ecotone_width * WATER_EDGE_LOW_SCALE);
			if (edge_w > 0.0001) {
				int secondary_id = water_edge_secondary_index(uv);
				if (secondary_id >= 0) {
					vec4 secondary_enum = texture(enum_lut, cell_lut_uv(secondary_id));
					int candidate_biome = int(secondary_enum.r * 255.0 + 0.5);
					if (water_edge_is_water(candidate_biome)) {
						secondary_biome = candidate_biome;
						secondary_cover = int(secondary_enum.b * 255.0 + 0.5);
						static_edge_mix = edge_w;
					}
				}
			}
		}

		vec3 col = render_water_pipeline_web_min(
			biome, cover, secondary_biome, secondary_cover,
			static_edge_mix, elev, dyn_ice_frac, shore_frac, uv, water_depth_px);
		if (visual_quality >= 1) {
			col = shade_water_web(col, uv, clamp(dyn_ice_frac, 0.0, 1.0));
		}

		// 已探索但当前不可见 → 去饱和 + 压暗。逐字复制 world_map:423-427。
		if (fog_gray_enabled) {
			float gray_amt = (1.0 - smoothstep(0.5, 1.0, fog_k)) * fog_gray_strength;
			col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))) * 0.82, gray_amt);
		}

		// apply_global_adjustments 的 web-min 收口：只有羊皮纸 tint 一项真正生效
		// （tonemap 在 PK_WEB_WORLD_MIN 下被裁掉；paper grain 的 grain 恒 0.5 ⇒ 乘子 ≡1）。
		col = mix(col, col * parchment_tint, parchment_strength);
		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
	}
}
