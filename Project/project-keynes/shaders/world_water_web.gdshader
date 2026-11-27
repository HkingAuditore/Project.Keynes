shader_type canvas_item;

uniform float world_time = 0.0;
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
// [cell-field-web 2026-11-18 / W3] 解析格界（场函数）路径的开关
// ─────────────────────────────────────────────────────────────────────────
// 宏 `PK_WATER_FIELD_MATCHES_LAND` —— 「本 pass 的水陆判据与**陆地 program**同源」。
//
// 为什么需要这个宏、而不是直接看 `PK_CELL_FIELD`：
//   方案 §3.7 第 1 条要求陆地与水面两个 program 调**同一个**判定函数。本 pass 与陆地
//   program 是两份**独立编译**的 shader，判据一旦不同源，海岸线上就会出现
//   「陆地 program 当水画」（或当陆地画）而「水面 pass 当陆地 discard」的 1 px 缝 ——
//   这正是"两片 program 都不画"的洞的成因。所以本 pass 走不走场函数**不能自己说了算**：
//   只能跟随陆地 program 的数据源。
//
// 注入点：`RendererShaderWater._water_program_prefix()` 的 `kind == "web_min"` 分支，
//   由与陆地变体**同一个判定口** `_cell_field_prefix(host)` 决定（那个函数同时也是
//   陆地变体拼 PK_CELL_FIELD 的唯一入口）。禁止在本 shader 里再自己判
//   `terrain_cell_field_enabled` / 平台 / 画质档 —— 那等于把同一个决定写两遍。
//
// 两条路的硬约束：
//   宏关 —— 预处理产物与 W3 之前**逐字节一致**：本文件的新代码全部包在
//           `#ifdef PK_WATER_FIELD_MATCHES_LAND` 里，一行都不进预处理产物。
//   宏开 —— 水陆判定 / 水深 / 海冰 / 岸距 / 水型软权重全部改用
//           `hex_cell_field.gdshaderinc` 的解析场，公式**照抄**桌面水面 P3
//           （water_pipeline / water / shore_common 的 PK_CELL_FIELD 分支），不另发明一套。
//
// 本文件为什么不 include terrain_surface_detail / shore_common / water：
//   那三份 include 会分别拖进 biome_color · biome_detail · 材质族 · noise_tex 一整条
//   依赖（本文件 376-380 行的旧注释早就为这件事给过理由），而本 pass 只需要其中几个
//   **纯函数**（无采样、无额外 uniform）。实测直接 include terrain_surface_detail 会以
//   `SHADER ERROR: Unknown identifier in expression: 'pixel_world_size'` 一类错误炸掉
//   整份精简程序。所以下面把需要的 8 个小函数（来自 4 份源文件）**逐字复制**过来，
//   并由 tests/world/web_water_pass_node_test.gd 逐函数与源文件比对（源文件改了而这里
//   没跟 ⇒ 红）。
// ═══════════════════════════════════════════════════════════════════════════
#ifdef PK_WATER_FIELD_MATCHES_LAND
// 本 pass 不 include uniforms.gdshaderinc，场函数要用的世界尺度 uniform 在这里声明，
// 取值来源与陆地 program 完全相同（hex_size ← host.hex_size、pixel_world_size ← 每帧
// 由 HexRenderer 推送、两个 wrap uniform 见本文件上方）。
uniform float hex_size = 22.0;
uniform float pixel_world_size = 1.0;
// visual_tile_sampling 在「不带 VT_USE_MAP_INDEX 且非 tiled」时会用 derived_resolution
// 定义 visual_static_texture_size()（那是 world_map 的 lat_norm 要的，本 pass 不调用）。
// 声明它只是为了那个函数体编得过，取值保留 uniforms.gdshaderinc:227 的默认值 ——
// 本程序里没有任何读者，多 1 个 vec2 uniform、0 个采样槽。
uniform vec2 derived_resolution = vec2(1024.0, 768.0);
// pixel_scale：`pk_hex_px()`（hex_cell_field 的门控选格会用到）。纯 ALU、零采样、
// 零新增采样槽 —— 它只定义一个"世界单位 ↔ 屏幕像素"的换算函数。
#include "res://shaders/include/pixel_scale.gdshaderinc"
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
// 【Cell-index 间接寻址】与 uniforms.gdshaderinc:166-196 同源：
//   enum_lut / dyn_lut 必须 NEAREST；lut_dims 是 LUT 网格尺寸。
// world_map 还声明 map_index_atlas（此处由 visual_tile_sampling 按 tiled/legacy 二选一
// 声明）、height_tex（同上），所以下面两个 VT_USE_* 之外不重复声明。
// [cell-field-web 2026-11-18 / W3] 场函数路径下这两张 LUT **整段删掉声明**（方案 §3.2
// 的同一条规则：删声明，而不是"保留声明只是不调用"）。漏改的残留引用会直接变成编译
// 错误，这正是想要的效果 —— 见下面 is_water / 水深 / 岸距三处改写。
// 宏关（今天的 Web LOW）时这两行与今天一字不差。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef PK_WATER_FIELD_MATCHES_LAND
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
#endif
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
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4091;
uniform bool day_night_enabled = true;
uniform bool water_effect_enabled = true;
uniform bool ocean_current_enabled = true;
uniform sampler2D ocean_current_flow_tex : filter_linear_mipmap, repeat_enable;
uniform bool ocean_current_flow_tex_bound = false;
// ── 海洋波浪参数：与 uniforms.gdshaderinc 同名同义同默认值（渲染器按名字推送，见 HexRenderer）──
uniform float ocean_current_strength : hint_range(0.0, 1.0) = 0.88;
uniform float water_flow_wave_density   : hint_range(0.25, 4.0) = 1.75;
uniform float water_flow_advection      : hint_range(0.0, 3.0)  = 1.15;
uniform float water_flow_wave_amplitude : hint_range(0.0, 3.0)  = 1.35;
uniform float water_flow_crest_strength : hint_range(0.0, 1.0)  = 0.38;
uniform float water_mark_strength      : hint_range(0.0, 2.0)  = 1.0;
uniform float water_mark_coverage      : hint_range(0.0, 2.0)  = 1.0;
uniform float water_ripple_strength     : hint_range(0.0, 3.0)  = 1.0;
uniform float water_ripple_detail_mix   : hint_range(0.0, 1.5)  = 0.5;
uniform float water_ripple_scale        : hint_range(0.3, 3.0)  = 1.0;
uniform float water_flow_drift_base     : hint_range(0.0, 100.0) = 30.0;
uniform float water_flow_drift_current  : hint_range(0.0, 300.0) = 100.0;
uniform float water_mark_length         : hint_range(0.3, 3.0)  = 1.0;
uniform float water_mark_speed          : hint_range(0.0, 4.0)  = 1.0;
uniform float water_rough_min           : hint_range(0.0, 1.0)  = 0.22;
uniform float water_rough_max           : hint_range(0.0, 2.0)  = 1.0;
uniform float water_rough_scale         : hint_range(0.25, 4.0) = 1.0;
uniform float water_rough_coverage      : hint_range(0.0, 1.0)  = 0.5;
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

// [water-wave-marks 2026-11-06] 离散浪头笔触（与桌面 water.gdshaderinc 同一函数，无 noise_tex）。
vec3 web_hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// 一层离散浪脊笔触，返回法线梯度 / 高度 / 覆盖强度。
vec4 web_mark_layer(vec2 wp, float cell, float shear, vec2 dirv,
		float cover, float t, float rate, float travel,
		float width_frac, float len_frac, float fp, float seed) {
	bool wrapped = wrap_period_x > 0.0001;
	float n_cells = wrapped ? max(floor(wrap_period_x / cell + 0.5), 1.0) : 1.0;
	float cw = wrapped ? wrap_period_x / n_cells : cell;
	vec2 q = vec2((wp.x + shear * wp.y) / cw, wp.y / cell);
	vec2 ci = floor(q);
	vec2 f = q - ci;
	vec2 id = vec2(wrapped ? mod(ci.x, n_cells) : ci.x, ci.y) + vec2(seed, seed * 1.37);
	// 生命周期序号参与哈希：同一格每个周期长出不同的笔触（与桌面同）。
	float ph = t * rate + web_hash32(id * 0.731 + 5.3).x;
	float life = fract(ph);
	vec2 cyc = vec2(mod(floor(ph), 997.0));
	vec3 ha = web_hash32(id + cyc * vec2(7.13, 3.77));
	float present = smoothstep(cover, cover - 0.10, ha.z);
	if (present <= 0.0) {
		return vec4(0.0);
	}
	vec3 hb = web_hash32((id + cyc * vec2(7.13, 3.77)) * 1.713 + 31.7);
	// 平台式包络：生命中段近满强度，前后各 22% 淡入淡出（旧的 (4x(1-x))² 大部分时间很暗）。
	float env = clamp(min(life, 1.0 - life) * 4.5, 0.0, 1.0);
	env = env * env * (3.0 - 2.0 * env);
	// 格内位置：留 30% 边距，再靠边缘淡出兜住被格线裁掉的部分。
	vec2 dq = f - vec2(0.30 + 0.40 * ha.x, 0.30 + 0.40 * ha.y);
	vec2 d = vec2(dq.x * cw - shear * dq.y * cell, dq.y * cell);
	float e = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	// 每格方向抖动 ±0.15 rad（小角度近似，不用 sin/cos）：丝基本顺流，只轻微散开。
	float a = (hb.y - 0.5) * 0.80;
	float ca = 1.0 - 0.5 * a * a;
	float sa = a - a * a * a * 0.1666667;
	vec2 dd = vec2(dirv.x * ca - dirv.y * sa, dirv.x * sa + dirv.y * ca);
	d -= dd * ((life - 0.5) * travel * cell);
	float uu = dot(d, dd);
	float ss = dot(d, vec2(-dd.y, dd.x));
	float L = len_frac * cell * (0.65 + 0.7 * hb.z);
	float w_nom = width_frac * cell;
	float w = max(w_nom, fp * 1.1);
	float aa = smoothstep(0.30, 1.10, w_nom / max(fp, 1e-4));
	float curve = (hb.z - 0.5) * 2.0 * ss * ss / (L * 2.4);
	float xu = (uu - curve) / w;
	float b = max(1.0 - xu * xu, 0.0);
	float b2 = b * b;
	float lm = clamp(1.0 - abs(ss) / L, 0.0, 1.0);
	lm = lm * lm * (3.0 - 2.0 * lm);
	float k = present * env * smoothstep(0.0, 0.14, e) * aa * lm;
	float xt = (uu - curve + 1.7 * w) / (1.4 * w);
	float c = max(1.0 - xt * xt, 0.0);
	float c2 = c * c;
	float h = (b2 - 0.40 * c2) * k;
	float dh = (-4.0 * xu * b / w * (b > 0.0 ? 1.0 : 0.0)
			+ 0.40 * 4.0 * xt * c / (1.4 * w) * (c > 0.0 ? 1.0 : 0.0)) * k;
	return vec4(dd * dh, h, b2 * k);
}


// [water-base-ripple 2026-11-06] 底层细节海面（连续涟漪）。Web 水面 pass 没有 noise_tex
// 采样器（材质槽预算已满），所以用纯 ALU 的哈希值噪声 + 解析梯度（五次 smootherstep 插值，
// 梯度连续、无小面）。x 向格数取整 ⇒ 环绕缝连续。返回 xy = 对世界坐标的梯度，z = 起伏（零均值）。
vec3 web_ripple(vec2 wp, float cell, vec2 drift, float seed, float shear) {
	bool wrapped = wrap_period_x > 0.0001;
	float n_cells = wrapped ? max(floor(wrap_period_x / cell + 0.5), 1.0) : 1.0;
	float cw = wrapped ? wrap_period_x / n_cells : cell;
	vec2 q = vec2(wp.x / cw + shear * wp.y / cell, wp.y / cell) + drift;   // 斜切打破轴对齐格线
	vec2 ci = floor(q);
	vec2 f = q - ci;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f - 1.0) * (f - 1.0);
	float x0 = wrapped ? mod(ci.x, n_cells) : ci.x;
	float x1 = wrapped ? mod(ci.x + 1.0, n_cells) : ci.x + 1.0;
	float a = web_hash32(vec2(x0, ci.y) + seed).x;
	float b = web_hash32(vec2(x1, ci.y) + seed).x;
	float c = web_hash32(vec2(x0, ci.y + 1.0) + seed).x;
	float d = web_hash32(vec2(x1, ci.y + 1.0) + seed).x;
	float h = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
	vec2 dq = vec2((b - a + (a - b - c + d) * u.y) * du.x,
			(c - a + (a - b - c + d) * u.x) * du.y);
	return vec3(dq.x / cw, (dq.y + shear * dq.x) / cell, h - 0.5);
}

vec3 shade_water_web(vec3 albedo_srgb, vec2 uv, float ice, EarthDaylight ed, vec3 L, float terrain_visibility) {
	float longitude = earth_daylight_longitude_u(uv) * EARTH_DAYLIGHT_TAU;
	vec2 flow = vec2(0.0);
	if (ocean_current_enabled && ocean_current_flow_tex_bound) {
		flow = textureLod(ocean_current_flow_tex, uv, 2.0).rg * 2.0 - 1.0;
	}
	// [water-wave-marks 2026-11-06] 与桌面同构：背景浪向 / 海况分区用整数经向频率的低频正弦
	// （环绕缝连续、零纹理采样）。
	float flow_mag = length(flow);
	float cur = sqrt(smoothstep(0.015, 0.16, flow_mag)) * clamp(ocean_current_strength * 1.15, 0.0, 1.0);
	vec2 flow_dir = flow / max(flow_mag, 1e-3);
	float ice_free = 1.0 - smoothstep(0.08, 0.48, clamp(ice, 0.0, 1.0));
	float fp = max(length(dFdx(v_world)), length(dFdy(v_world)));
	float bg_ang = sin(longitude * 5.0 + v_world.y * 0.0019 + world_time * 0.011) * 0.95
			+ sin(longitude * 13.0 - v_world.y * 0.0031 + 1.3 - world_time * 0.007) * 0.30 + 0.35;
	vec2 bgd = vec2(cos(bg_ang), sin(bg_ang));
	float w_flow = clamp(cur * 1.25, 0.0, 1.0);
	vec2 dirv = normalize(bgd * (1.0 - w_flow) + flow_dir * w_flow);
	float zone_a = 0.5 + 0.5 * sin(longitude * 7.0 + v_world.y * 0.0021 + world_time * 0.031);
	float zone_b = 0.5 + 0.5 * sin(longitude * 11.0 - v_world.y * 0.0033 + 1.7 - world_time * 0.023);
	float zs = smoothstep(0.22, 0.78, zone_a * 0.55 + zone_b * 0.45);
	// 海况强度场（与桌面同义）：单尺度哈希值噪声，平静 / 风浪分区。
	float rs = max(water_rough_scale, 0.05);
	float rough_n = web_ripple(v_world, 300.0 * rs, vec2(world_time * 0.0040, -world_time * 0.0027) / rs, 211.0, 0.31).z * 1.0 + 0.5;
	float rough_c = mix(0.75, 0.25, clamp(water_rough_coverage, 0.0, 1.0));
	float rough = smoothstep(rough_c - 0.20, rough_c + 0.20, rough_n);
	// 格尺寸 / 流速倍率：默认值下均为 1，与桌面一致。
	float sc = 1.27 / max(water_flow_wave_density * 0.7254, 0.05);
	float rate_s = water_flow_advection / 1.15;
	float rsc = sc * max(water_ripple_scale, 0.05);
	// 底层涟漪：两相位 flowmap + 每周期换哈希种子（不循环）。位移 = 背景浪向 × drift_base +
	// 洋流向量 × drift_current（世界单位 / 周期），必须大于一个格宽才是净流动而非原地淡入淡出。
	vec2 adv_big = bgd * water_flow_drift_base + flow * water_flow_drift_current;
	float big_cell = 52.0 * rsc;
	float rate_big = 0.04 * rate_s;
	float rph0 = fract(world_time * rate_big);
	float rph1 = fract(rph0 + 0.5);
	float rw0 = 1.0 - abs(1.0 - 2.0 * rph0);
	float rw1 = 1.0 - rw0;
	vec3 ra = web_ripple(v_world, big_cell, -adv_big * rph0 / big_cell,
			71.0 + mod(floor(world_time * rate_big), 997.0) * 13.7, 0.47);
	vec3 rb = web_ripple(v_world, big_cell, -adv_big * rph1 / big_cell + vec2(0.37, 0.11),
			71.0 + mod(floor(world_time * rate_big + 0.5), 997.0) * 13.7 + 5.0, 0.47);
	vec3 r1 = (ra * rw0 + rb * rw1) * inversesqrt(rw0 * rw0 + rw1 * rw1);
	float rip_k = 6.5 * water_ripple_strength;
	vec2 slope = r1.xy * rip_k;
	float height = r1.z * 0.6 * water_ripple_strength;
	if (visual_quality >= 1) {
		// 小尺度：纯平移（成本控制），只用全局常量方向漂移。任何逐像素量（洋流 / 缓变浪向）× 时间
		// 的位移都会无限累积、在格边界撕裂，所以这一层在 Web 上不跟洋流。
		vec2 adv_small = vec2(0.30, -0.52);
		float small_cell = 23.0 * rsc;
		vec3 r2 = web_ripple(v_world, small_cell, -adv_small * (world_time * 0.11 * rate_s) * (23.0 / small_cell), 133.0, -0.39);
		slope += r2.xy * rip_k * water_ripple_detail_mix;
		height += r2.z * 0.45 * water_ripple_strength;
	}
	// 恢复两层非顺流浪脊；细长洋流丝保持关闭。
	float cov_k = max(water_mark_coverage, 0.0);
	float mlen = max(water_mark_length, 0.05);
	float mark_rate = rate_s * water_mark_speed;
	vec4 la = web_mark_layer(v_world, 66.0 * sc, 0.21, dirv,
			clamp(mix(0.20, 0.66, zs) * mix(0.25, 1.25, rough) * cov_k, 0.0, 0.95),
			world_time, 0.07 * mark_rate, 0.50, 0.105, 0.42 * mlen, fp, 3.0);
	slope += la.xy * (0.9 * water_mark_strength);
	height += la.z;
	if (visual_quality >= 1) {
		vec2 dirb = vec2(dirv.x * 0.64 - dirv.y * 0.77, dirv.x * 0.77 + dirv.y * 0.64);
		vec4 lb = web_mark_layer(v_world, 34.0 * sc, -0.27, dirb,
				clamp(mix(0.58, 0.18, zs) * mix(0.30, 1.20, rough) * cov_k, 0.0, 0.95),
				world_time, 0.12 * mark_rate, 0.65, 0.11, 0.36 * mlen, fp, 11.0);
		slope += lb.xy * (0.68 * water_mark_strength);
		height += lb.z * 0.80;
	}
	float wave = water_effect_enabled ? ice_free : 0.0;
	// 法线强度：平静区 = water_rough_min，风浪区 = water_rough_max（与桌面同义）。
	slope *= mix(0.90, 1.20, cur) * 0.70 * water_flow_wave_amplitude * mix(water_rough_min, water_rough_max, rough);
	vec3 N = normalize(vec3(-slope * wave, 1.0));
	// 波高参与着色：波峰波谷明暗与浪尖碎白；冰面 wave=0 自动无效果。
	float height_a = clamp(height * mix(0.90, 1.20, cur) * mix(0.35, 1.0, rough), -1.0, 1.0);
	albedo_srgb *= 1.0 + height_a * 0.34 * wave;
	float crest = smoothstep(0.30, 0.72, height_a) * wave;
	albedo_srgb = mix(albedo_srgb, vec3(0.72, 0.84, 0.88), crest * water_flow_crest_strength * 1.6);
	vec3 V = vec3(0.0, 0.0, 1.0);
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
	vec3 ambient = sky_ambient_linear(ed.local_day, N, ed.amb_col, ed.sun_col, L);
	vec3 reflected_sky = mix(vec3(0.20, 0.37, 0.52), ed.amb_col, clamp(N.z, 0.0, 1.0));
	vec3 lit = (diffuse + spec) * nl * sun * terrain_visibility + albedo * ambient
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
// [surface-array-edge 2026-11-02] 与陆地程序共用同一个 surface array；本 pass
// 不声明 normal/relief/horizon，只按需读其中的层。
#define VT_USE_TERRAIN_SURFACE_ARRAY
#ifndef MAP_VISUAL_TILED
#define PK_WEB_SURFACE_HORIZON
#endif
#ifdef PK_WATER_FIELD_MATCHES_LAND
// [cell-field-web 2026-11-18 / W3] 场函数路径的采样集合（方案 §3.7）：
//   VT_USE_CELL_TABLE    —— per-cell class/state/aux 三层表。这 1 个 sampler 顶掉
//                           map_index_atlas + enum_lut + dyn_lut + water_depth_tex 四个。
//   VT_USE_BOUNDARY_WARP —— 扭曲场（非 tiled 读 terrain_surface_tex layer6，**不新增槽**）。
//   ✗ MAP_INDEX          —— 不再有读者：格界由 pk_hex_cell_field 解析算出。
//   ✗ WATER_DEPTH        —— 不再有读者：水深改 cell_table layer2.G。
//   ✗ EDGE_DISTANCE / EDGE_NEIGHBOR —— 岸距解析、次生水格取权重第二名，两者都不再被读。
// ⇒ 场函数路径的 sampler 清单 = height_tex + terrain_surface_tex +
//   ocean_current_flow_tex + cell_table = **4**（OFF 是 7，见测试的逐项断言）。
#define VT_USE_CELL_TABLE
#define VT_USE_BOUNDARY_WARP
#else
#define VT_USE_MAP_INDEX
#define VT_USE_WATER_DEPTH
// [surface-array-edge 2026-11-02] 5→6 槽：只读 layer4/layer5（edge_distance / 次生
// cell id），不声明 normal/relief/horizon。
#define VT_USE_EDGE_DISTANCE
#define VT_USE_EDGE_NEIGHBOR
#endif
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

uniform bool tod_latitude_sun_enabled = true;
uniform float tod_sun_relief_max_up = 0.88;
#ifdef PK_WEB_SURFACE_HORIZON
uniform float terrain_horizon_strength = 1.20;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_max_angle = 1.309;
#include "res://shaders/include/terrain_horizon_shadow.gdshaderinc"
#endif

// cell_lut_uv()（唯一对外成员）+ decode_cell_index()/dyn_lut_nearest()（本文件不用，
// 编译器整段删掉）。依赖上面已声明的 dyn_lut / lut_dims / visual_sample_map_index。
// [cell-field-web 2026-11-18] 场函数路径下整段不 include：这个文件的三个函数全部建立在
// map_index / dyn_lut 之上，上面删掉声明之后它自己就编不过（方案 §3.2 的连带项）。
#ifndef PK_WATER_FIELD_MATCHES_LAND
#include "res://shaders/include/cell_indirect.gdshaderinc"
#endif

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
// [cell-field-web 2026-11-18 / W3] 场函数路径下这两个函数**整段不编译**：次生水格改由
// 解析场的「权重第二名格」给出（pk_cell_field_rank(f, 1)），既不读 edge_neighbor 层，
// 也不再有任何 map_index 引用（visual_sample_edge_neighbor 在那边根本没声明）。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef PK_WATER_FIELD_MATCHES_LAND
int water_edge_secondary_index(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(uv).rg;
	int cid = int(rg.r * 255.0 + 0.5) + int(rg.g * 255.0 + 0.5) * 256;
	return (cid >= 65535) ? -1 : cid;
}

bool water_edge_is_water(int biome) {
	return biome == B_OCEAN || biome == B_COAST || biome == B_LAKE
			|| biome == B_REEF || biome == B_KELP || biome == B_SEA_ICE;
}
#endif

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
// [cell-field-web 2026-11-18 / W3] 解析格界：include 顺序 + 逐字复制的纯函数
// ═══════════════════════════════════════════════════════════════════════════
#ifdef PK_WATER_FIELD_MATCHES_LAND
// 场函数要「未回绕」的世界坐标（它内部自己 wrap，AA 导数必须取自未回绕坐标 ——
// review 2026-11-18 第 1 条）。逐字复制 uniforms.gdshaderinc:250-252。
vec2 wrap_world_pos(vec2 wp) {
	return vec2(wrap_world_x(wp.x), wp.y);
}

// ── 逐字复制自 terrain_surface_detail.gdshaderinc:44-59 ────────────────────
// 为什么不 include 那一份：它会拖进 biome_color / biome_detail / 材质族 / noise_tex
// 一整条依赖，本 pass 只需要这两个纯函数（无采样、无新增 uniform）。
// tests/world/web_water_pass_node_test.gd 逐 token 与源文件比对，漂移即红。
bool terrain_static_biome_is_water(int biome) {
	return biome == B_OCEAN || biome == B_COAST || biome == B_LAKE
			|| biome == B_REEF || biome == B_KELP || biome == B_SEA_ICE;
}

float terrain_edge_screen_width_px() {
#if defined(PK_MOBILE_ANY)
	if (visual_quality >= 2) { return 1.25; }
	if (visual_quality >= 1) { return 1.00; }
	return 1.00;
#else
	if (visual_quality >= 2) { return 1.75; }
	if (visual_quality >= 1) { return 1.25; }
	return 1.00;
#endif
}

// 契约 §4.3 的 include 顺序：pixel_scale（已在上方）→ terrain_surface_detail 的两个
// 纯函数（紧邻上方）→ hex_cell_field。场函数只做 ALU + texelFetch，可放进任何控制流。
#include "res://shaders/include/hex_cell_field.gdshaderinc"

// ── 逐字复制自 shore_common.gdshaderinc:44-71（PK_CELL_FIELD 块）───────────
// 方案 §3.7：对偶三角形之外的任何格到三角形内任一点的 gap 都 ≥ √3/2 ≈ 0.866，所以
// **gap ≤ 0.86（≈ 0.43 hex ≈ 9.5 wu）以内的岸线只看这三格就是精确的**。于是「3×3
// map_index 邻域」整段不需要；解析版的宽度只依赖世界单位（hex_size），与索引图分辨率
// 无关 ⇒ 桌面 1024 / 移动 512 得到完全相同的岸线宽度。
//
// 岸线 / 湖岸带宽（hex 为单位）。0.43 hex = PK_FIELD_BAND_MAX / 2，正好是 §3.2 的
// 带宽上限（0.86 gap ⇒ 0.43 hex ⇒ hex_size=22 时 9.5 wu）。
const float PK_SHORE_BAND_HEX = 0.43;

int shore_cell_biome(vec4 cls) { return int(cls.r * 255.0 + 0.5); }

// 到最近陆地格的 gap（gap 单位）。三格都是水 ⇒ 1e3（"岸在远处"哨兵，任何阈值都比它小）。
// 手写三连、用比较 + 三元选择，无循环无分支（方案 §3.9）。
float shore_gap_from_field(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	float g = 1e3;
	g = terrain_static_biome_is_water(shore_cell_biome(e0)) ? g : min(g, f.gap.x);
	g = terrain_static_biome_is_water(shore_cell_biome(e1)) ? g : min(g, f.gap.y);
	g = terrain_static_biome_is_water(shore_cell_biome(e2)) ? g : min(g, f.gap.z);
	return g;
}

// gap → 世界单位岸距：沿格中心连线 gap = 2·d_b / hex_size（契约 §1，d_b = 到水陆格界的
// 距离）⇒ d_b = 0.5·gap·hex_size。超过带宽上限的值没有意义（第三格在三角形外时
// gap 恒 ≥ 0.866），先 clamp 再换算。
float shore_distance_wu(float shore_gap) {
	return 0.5 * min(shore_gap, PK_FIELD_BAND_MAX) * hex_size;
}

// 岸线接触度：1 = 贴岸，0 = 岸在 PK_SHORE_BAND_HEX 个 hex 之外。
float shore_contact_from_field(float shore_gap) {
	return 1.0 - smoothstep(0.0, PK_SHORE_BAND_HEX * hex_size, shore_distance_wu(shore_gap));
}

// ── 逐字复制自 water.gdshaderinc:542-559（PK_CELL_FIELD 块）────────────────
// 水型是**类别量**：三格 class + 锐化权重 w 直接给出软权重（方案 §3.3 / §3.8）。
// 取代旧 water_biome_weights() 的 3×3 map_index 邻域（9 次采样），也取代
// water_depth.gba 的烘焙 3×3 软权重 —— 两者都是"把 per-cell 类别量扇出成 per-pixel"
// 的旧通道。零新增采样：三格 class 在 SETUP 已经 texelFetch 过。
// weights = field.w（Σ=1）；e0/e1/e2 = 三格 class。
// 返回口径与旧 3×3 版一致（各水型占比，Σ ≤ 1）⇒ 调用方公式不变。
vec4 water_biome_weights_field(vec3 weights, vec4 e0, vec4 e1, vec4 e2) {
	int b0 = int(e0.r * 255.0 + 0.5);
	int b1 = int(e1.r * 255.0 + 0.5);
	int b2 = int(e2.r * 255.0 + 0.5);
	float lake = ((b0 == B_LAKE) ? weights.x : 0.0)
			+ ((b1 == B_LAKE) ? weights.y : 0.0)
			+ ((b2 == B_LAKE) ? weights.z : 0.0);
	float reef = ((b0 == B_REEF) ? weights.x : 0.0)
			+ ((b1 == B_REEF) ? weights.y : 0.0)
			+ ((b2 == B_REEF) ? weights.z : 0.0);
	float kelp = ((b0 == B_KELP) ? weights.x : 0.0)
			+ ((b1 == B_KELP) ? weights.y : 0.0)
			+ ((b2 == B_KELP) ? weights.z : 0.0);
	float ice  = ((b0 == B_SEA_ICE) ? weights.x : 0.0)
			+ ((b1 == B_SEA_ICE) ? weights.y : 0.0)
			+ ((b2 == B_SEA_ICE) ? weights.z : 0.0);
	return vec4(lake, reef, kelp, ice);
}

// 该 offset 行是否落在真实地图内（逐字复制 world_map.gdshader:334-350 的
// pk_field_row_in_bounds，只改前缀避免与那份同名）。row 越界（南北边界之外）的 texel
// 是 padding 哨兵 —— pk_cell_table_fetch 只把 R 填成 B_SEA_ICE，其余通道为 0，连续量
// 按它混合会得到 0.08 这种假温度/假雪。返回 0/1，供权重遮罩与 dyn_valid 使用。
float web_field_row_in_bounds(ivec2 c) {
	return step(0.0, float(c.y)) * step(float(c.y), float(pk_cell_map_h - 1));
}
#endif // PK_WATER_FIELD_MATCHES_LAND

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
		vec4 water_depth_px,
		float water_depth_valid) {
	// 深度：elev 是 [0,1] 的归一化高程，海面普遍很低，越浅越亮。
	// [web-high-features 2026-11-01 / 方案 B] 湖泊改用烘焙 water_depth（湖岸→湖心碗形，
	// 避免整片湖水同色）；海面仍用连续 elev 深度。全部 select/mix 直线写法，不引入
	// if/else —— 本 pass 的历史教训：第二个着色来源里的分歧分支会把 FXC 编译时间从
	// 秒级推到十几秒。
	// [finish-four 2026-11-01 / 收尾 C] 非 tiled 的 water_depth_tex 升级 RGBA8：
	// R=水深，G/B/A=湖/礁/海带 3×3 软权重。软权重只提升 w_lake/w_reef/w_kelp，不改
	// 几何/海冰/岸线逻辑；未绑定（引擎默认白纹理）时 soft_w 归零，GBA=0 的旧 R8 回退
	// 因此精确等价原来的二元 biome 权重。
	// [cell-field-web 2026-11-18 / W3] 数据源改成**参数**而不是"读 has_water_depth_tex
	// uniform"：场函数路径下 R/GBA 是 cell_table 的 aux.G + water_biome_weights_field
	// 合成出来的，那个 uniform（= world.water_depth_tex != null）与它无关。宏关时调用点
	// 传 `has_water_depth_tex ? 1.0 : 0.0` ⇒ 与今天的取值逐个浮点相同。
	float wd_raw = water_depth_px.r;
	float wd = (water_depth_valid > 0.5) ? wd_raw : -1.0;
	float lake_w = max((biome == B_LAKE) ? 1.0 : 0.0,
			(secondary_biome == B_LAKE) ? 1.0 : 0.0);
	float ocean_depth_t = clamp(elev * 3.5, 0.0, 1.0);
	float baked_depth_t = clamp(wd, 0.0, 1.0);
	float depth_t = mix(ocean_depth_t, baked_depth_t, lake_w * step(0.0, wd));
	vec3 col = mix(vec3(0.045, 0.115, 0.235), vec3(0.185, 0.400, 0.470), depth_t);
	// 次生水体（湖泊/内海交界）向主 biome 混合，保留边缘过渡。
	col = mix(col, col * 0.92 + vec3(0.02, 0.03, 0.02), clamp(edge_mix, 0.0, 0.5));
	vec4 soft_w = (water_depth_valid > 0.5) ? water_depth_px : vec4(0.0);
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

	vec2 uv = wrap_map_uv((v_world - world_origin) / world_size);

	int biome;
	int cover;
	float fog_k;
	float dyn_ice_frac;
	// 次生水体：宏关时来自 world_map 那条"次生水体查表"（PK_QUALITY_LOW 下 world_map
	// 自己把这段裁掉，但本 pass 是独立 fragment、只有水面一个着色来源，不存在那次
	// 20 s 联合编译悬崖，所以 [surface-array-edge 2026-11-02] 起在水面像素上**恢复**
	// 该查表）；宏开时来自解析场的"权重第二名格"。
	int secondary_biome;
	int secondary_cover;
	float static_edge_mix = 0.0;

#ifdef PK_WATER_FIELD_MATCHES_LAND
	// ═══════════════════════════════════════════════════════════════════════
	// SETUP（场函数路径）：与陆地 program 同一份数据、同一个判定函数
	// ═══════════════════════════════════════════════════════════════════════
	// 数据源必须与陆地 program 逐项同值：同一个 cell_table、同一份 warp 场、同一个
	// terrain_ecotone_width —— renderer_lighting_bindings.gd:116-128 推的就是这一组
	// （它旁边那段注释正是"两片 program 的判定错开 ⇒ 海岸线出 1-px 洞"）。
	if (!cell_table_bound) {
		// 没有 per-cell 表（未 bake / 旧存档）⇒ 场函数无从判定水陆。**整片 discard**：
		// 下层（陆地 program）自己会画出它的水色，本 pass 宁可不画也不要画错。
		discard;
	}
	// 入参必须是**未回绕**的顶点世界坐标（AA 带宽的导数取自它，review 2026-11-18 第 1 条）。
	// 采样记账（LOW 档程序，但连续量按三格插值）：warp 1 + class 3 + state 3 + aux 3
	// + height 1 + ocean_current_flow 1 = 12 次；三张 per-cell 表都是 texelFetch、全命中
	// 缓存（60×40 级别的表），比陆地 program 的 13 次还少。
	HexCellField field = pk_hex_cell_field_default(v_world);
	vec4 fe0 = vec4(0.0);
	vec4 fe1 = vec4(0.0);
	vec4 fe2 = vec4(0.0);
	pk_cell_field_classes(field, fe0, fe1, fe2);
	ivec2 field_dom_c = pk_cell_field_dom_offset(field);
	// padding 行（南北边界之外）没有真实格：把它们的权重清零后，在真实格之间重新归一
	// —— 与 world_map.gdshader 的 `field_w_valid / field_valid` 逐式相同。
	float field_inb0 = web_field_row_in_bounds(field.c0);
	float field_inb1 = web_field_row_in_bounds(field.c1);
	float field_inb2 = web_field_row_in_bounds(field.c2);
	vec3 field_w_valid = field.w_raw * vec3(field_inb0, field_inb1, field_inb2);
	float field_valid = field_w_valid.x + field_w_valid.y + field_w_valid.z;
	float dyn_valid = step(0.5, field_valid);
	vec3 field_w = (field_valid > 1e-5)
			? field_w_valid / field_valid : field.w_raw;
	// 类别三元组取**主导格**的 layer0（与今天 enum_lut[主 cell] 同语义；padding 行由
	// pk_cell_table_fetch 的哨兵给出 B_SEA_ICE / 0 / 0，与今天 cid < 0 的三个赋值一致）。
	vec4 field_cls_dom = pk_field_class_of(field, fe0, fe1, fe2);
	biome = pk_byte_of(field_cls_dom.r);
	cover = pk_byte_of(field_cls_dom.b);
	// ── state / aux 三格按 w_raw 插值（**连续量**用 w_raw，契约 §3.3）──────────────
	// 旧路径这两个量是"逐格常量"（dyn_lut.A / water_depth.R 都按主 cell NEAREST 取），
	// 所以在格界上是硬台阶；三格插值把它们变成跨格连续的场 —— 海冰边缘、湖泊碗形都不
	// 再沿格界跳一级。padding 格的哨兵已被上面的 field_w 归零，不会混进来。
	// 与 world_map 的 pk_field_blend_state / compute_offshore_depth 三格分支同一公式。
	vec4 field_st0 = pk_cell_state_at(field.c0);
	vec4 field_st1 = pk_cell_state_at(field.c1);
	vec4 field_st2 = pk_cell_state_at(field.c2);
	vec4 field_ax0 = pk_cell_aux_at(field.c0);
	vec4 field_ax1 = pk_cell_aux_at(field.c1);
	vec4 field_ax2 = pk_cell_aux_at(field.c2);
	vec4 field_state = field_st0 * field_w.x + field_st1 * field_w.y + field_st2 * field_w.z;
	vec4 field_aux = field_ax0 * field_w.x + field_ax1 * field_w.y + field_ax2 * field_w.z;
	// fog_k 是**类别量** ⇒ 只读主导格、不插值（契约 D3：三格未探索 ≡ 主导格未探索）；
	// padding 主导格视作全知（取 1.0，与今天 cid < 0 时 fog_k = 1.0 一致）。
	float field_fog_dom = (field.dom == 0) ? field_ax0.r
			: ((field.dom == 1) ? field_ax1.r : field_ax2.r);
	fog_k = mix(1.0, field_fog_dom, web_field_row_in_bounds(field_dom_c));
	// 海冰比例 = layer1.A（连续量）。padding 像素 dyn_valid=0 ⇒ 取 1.0（整片海冰），
	// 与今天 cid < 0 时 dyn_ice_frac = 1.0 逐值一致。
	dyn_ice_frac = mix(1.0, field_state.a, dyn_valid);
	// 次生水格 = 权重**第二**的那一格（桌面水面 P3 用的同一个 pk_cell_field_rank）。
	vec4 field_rank1_cls = pk_cell_field_ranked_class(field, 1, fe0, fe1, fe2);
	int field_rank1_biome = pk_byte_of(field_rank1_cls.r);
	bool field_second_water = terrain_static_biome_is_water(field_rank1_biome);
	secondary_biome = field_second_water ? field_rank1_biome : biome;
	secondary_cover = field_second_water ? pk_byte_of(field_rank1_cls.b) : cover;
	// 混合权重取 rank-1 的 **w_raw**（连续量，§3.3）—— 与桌面 water_pipeline 的
	// pk_cell_field_ranked_weight_raw(f, 1) 同一表达式。
	static_edge_mix = field_second_water
			? pk_cell_field_ranked_weight_raw(field, 1) : 0.0;

	// ── 水陆判定：与陆地 program **同一个函数、同一份数据**（方案 §3.7 第 1 条）──
	// 海岸线因此就是「dom 在水 / 陆之间切换」的那条弯曲等值线，两片 program 不可能各说各话。
	bool is_water = pk_cell_field_is_water_dom(field, fe0, fe1, fe2);
	// ── 关于「下层 program 放宽 ε」（方案 §3.7 末条 / contract §9.1-ε）──────────
	// 规则是「画在**下层**的 program 放宽 ε，上层严格」：两片各自编译，恰好落在
	// is_water 等值线上的像素可能一边判水一边判陆；只要**下层放宽**，那个 1 px 争议带
	// 就会被下层（陆地）覆盖住，不会出现"两边都不画"的洞。
	//
	// Web 上的绘制顺序（证据；行号取 2026-11-18 时的状态，代码片段可直接 grep 定位）：
	//   renderer_scene_services.gd:91-94  先建 _world_quad（陆地 program，z_index = 0）：
	//       `host._world_quad = MeshInstance2D.new()` / `host._world_quad.z_index = 0`
	//       / `host.add_child(host._world_quad)`
	//   renderer_shader_water.gd:935     `host._water_quad.z_index = 0`（同 z，树序决胜）；
	//   renderer_shader_water.gd:940     `host.move_child(host._water_quad,
	//                                       mini(host._world_quad.get_index() + 1, …))`
	//                                    紧邻注释（:932）原文「水面盖住陆地、又被灌草(1)/
	//                                    建筑(2)/树冠(3)盖住」。
	//   这两处都没有按平台分支 ⇒ Web 与桌面走的是同一段代码、同一个顺序
	//   （本文件的测试也钉着 quad.get_index() == world_quad.get_index() + 1，且断言
	//     z_index→move_child 这段代码里没有 has_feature 分支）。
	// ⇒ **陆地在下、水面在上**，ε 放宽属于陆地 program（world_map.gdshader 的
	//   PK_LAND_ONLY 分支：is_water = is_water && (field_edge_gap >= PK_FIELD_SHORE_EPS)）。
	//   本 pass 是上层，必须**严格**：放宽会让争议带露出下层的水色常量，反而是一条
	//   可见的缝。这里刻意不加任何 ε。
	if (!is_water) {
		discard;
	}
#else
	// ── SETUP（legacy 路径）：坐标 + cell 索引（与 world_map:184-241 同源，采样顺序
	// 刻意不同：先把"是不是水"判掉再取 height/dyn，非水像素只花 2 次 fetch 就 discard）
	vec4 map_px = visual_sample_map_index(uv);
	int cell_id = int(map_px.g * 255.0 + 0.5) + int(map_px.b * 255.0 + 0.5) * 256;
	cell_id = (cell_id >= 65535) ? -1 : cell_id;

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
#endif

	// [land-water-split 2026-11-02] 未探索像素改由本 pass 画 fog_unexplored_color
	// （与陆地 program 同一 uniform 值），不再 discard —— 纯水 block 在分 mesh 后
	// 没有陆地 pass 兜底，让位会露出迷雾空洞。早期退出仍然保留：直接跳过整条水面
	// 着色，只写一个常量色。
#ifdef PK_WATER_FIELD_MATCHES_LAND
	// [cell-field 2026-11-18] 与 world_map 的 PK 分支同式（契约 D3）：「三格均未探索」才
	// 早退，而 edge_gap ≥ PK_FIELD_BAND_MAX ⇒ 邻格权重为 0，主导格未探索就等于整块未探索；
	// 整条过渡带（edge_gap < 带宽）永远不早退。故 frame_gap 在这里先算出来复用。
	float field_edge_gap = pk_cell_field_edge_gap(field);
	bool fog_hidden = fog_early_out_enabled
			&& (fog_k <= fog_early_out_k)
			&& (field_edge_gap >= PK_FIELD_BAND_MAX);
#else
	bool fog_hidden = fog_early_out_enabled && (fog_k <= fog_early_out_k);
#endif
	if (fog_hidden) {
		COLOR = vec4(fog_unexplored_color, 1.0);
	} else {
		// 水深 → 归一高程（height.RG = 16-bit，解码同 world_map:208-209）。
		vec4 height_px = visual_sample_height(uv);
		float elev = (height_px.r * 256.0 + height_px.g) / 257.0;
		vec2 shore_frac = vec2(0.0);
		vec4 water_depth_px = vec4(0.0);
		float water_depth_valid = 0.0;
#ifdef PK_WATER_FIELD_MATCHES_LAND
		// ── 水深 / 水型软权重（桌面 P3 的同一套公式）────────────────────────────
		// 水深 = cell_table layer2.G（三格按 w_raw 插值的连续量，与 world_map 的
		// compute_offshore_depth 三格分支同式）—— 与今天 surface array layer5.B 是
		// 同一份 C++ per-cell 深度、同一 8bit 精度，只是改成从 offset 空间的小表取
		// （契约 D6）；插值后不再有逐格色阶。
		float field_wd = field_aux.g;
		// 水型软权重 = 三格 class 的锐化权重（桌面 water_biome_weights_field，零新增采样）。
		// 通道顺序对齐旧 water_depth_px：.g = 湖、.b = 礁、.a = 海带 ⇒ vec4(深度, 湖, 礁, 海带)。
		vec4 field_bw = water_biome_weights_field(field.w, fe0, fe1, fe2);
		water_depth_px = vec4(field_wd, field_bw.x, field_bw.y, field_bw.z);
		water_depth_valid = 1.0;
		// ── 岸距：解析计算，替代旧的 map_index 环形邻域采样（方案 §3.7）────────────
		// 旧路径读 layer4.BA（烘焙的 8 邻域水·湖**占比**）当"岸线浅滩"，它的宽度按纹素
		// 给（桌面 1024 探 ≈7 wu、移动 512 探 ≈14 wu，同一份代码差一倍），而且对水像素
		// 来说开阔海域恒为 1.0 —— 名字是"岸"、实际把整个洋面拉向浅滩色。
		// 解析版换成**世界单位岸距**（桌面 shore_common 的 shore_contact_from_field）：
		//   1 = 贴岸，0 = 岸在 PK_SHORE_BAND_HEX(=0.43) 个 hex 之外，
		// 宽度只依赖 hex_size ⇒ 与索引图分辨率无关。两个分量填同值（旧的两分量是
		// 水/湖两种占比，解析岸距只有一个量）。
		float field_shore_gap = shore_gap_from_field(field, fe0, fe1, fe2);
		shore_frac = vec2(shore_contact_from_field(field_shore_gap));
#else
		// [收尾 C] water_depth 升级 RGBA8 后一次采样同时给出 R=深度与 G/B/A 软权重。
		water_depth_px = visual_sample_water_depth(uv);
		water_depth_valid = has_water_depth_tex ? 1.0 : 0.0;
		// [surface-array-edge 2026-11-02] 岸线占比 + 次生水格（world_map 水面分支被预算裁掉的
		// 那两段，算式逐项对齐 world_map.gdshader 的 `water_secondary_*` / `shore_frac`）：
		//   ① 权重用**连续**距离场，不转 DitherUV ⇒ 水色方块变成连续过渡；
		//   ② 次生格只在"同样在水域"时接管 ⇒ 海/湖交界不会被陆地色污染；
		//   ③ shore_frac 是烘焙的 8 邻域水·湖占比，双线性过滤后是连续场 ⇒ 浅滩不再硬边。
		// has_terrain_edge_data=false（旧图 / 烘失败 / 层数不足）时整段跳过，行为退回
		// C 回合：edge_mix=0、shore_frac=0。layer4/5 的采样在 helper 内部另有
		// terrain_edge_layers_bound 门控，绝不采样越界层。
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
#endif

		vec3 col = render_water_pipeline_web_min(
			biome, cover, secondary_biome, secondary_cover,
			static_edge_mix, elev, dyn_ice_frac, shore_frac, uv, water_depth_px,
			water_depth_valid);
		if (visual_quality >= 1) {
			// [water-flow-waves 2026-11-06] 旧版只传 dyn_ice_frac，静态 B_SEA_ICE /
			// CV_SEA_ICE 冰格（动态冰量可能为 0）照样画海浪。这里复算与
			// render_water_pipeline_web_min 完全同源的完整冰量再交给光照/波浪。
			float static_ice = max(
				max((biome == B_SEA_ICE) ? 1.0 : 0.0,
					(secondary_biome == B_SEA_ICE) ? 1.0 : 0.0),
				max((cover == CV_SEA_ICE) ? 1.0 : 0.0,
					(secondary_cover == CV_SEA_ICE) ? 1.0 : 0.0));
			float ice_full = clamp(max(clamp(dyn_ice_frac, 0.0, 1.0),
					static_ice * 0.85), 0.0, 1.0);
			float lat_norm = earth_daylight_latitude_norm(uv.y, visual_static_texture_size().y);
			EarthDaylight ed = eval_earth_daylight(uv, lat_norm * 2.0 - 1.0, day_night_enabled);
			vec3 light_dir = earth_daylight_key_dir(ed, tod_sun_dir,
				tod_latitude_sun_enabled || !day_night_enabled, tod_sun_relief_max_up);
			float terrain_visibility = 1.0;
#ifdef PK_WEB_SURFACE_HORIZON
			terrain_visibility = terrain_horizon_web_visibility(uv, light_dir);
#endif
			terrain_visibility = mix(terrain_visibility, 1.0, smoothstep(0.22, 0.72, ice_full));
			col = shade_water_web(col, uv, ice_full, ed, light_dir, terrain_visibility);
		}

		// 已探索但当前不可见 → "褪色的记忆"（提亮+去饱和，向纸色靠）。
		// 与 world_map 同公式：那边改了压暗为提亮之后，这里必须同步，
		// 否则 web 的水面仍会出现近黑的脏环。
		if (fog_gray_enabled) {
			float gray_amt = (1.0 - smoothstep(0.5, 1.0, fog_k)) * fog_gray_strength;
			float mem_l = dot(col, vec3(0.299, 0.587, 0.114));
			vec3 memory = vec3(mem_l) * vec3(1.02, 1.00, 0.96);
			memory = mix(memory, vec3(0.88, 0.86, 0.82), 0.22);
			memory = max(memory, vec3(mem_l) * 0.86 + 0.10);
			col = mix(col, memory, gray_amt);
		}

		// apply_global_adjustments 的 web-min 收口：只有羊皮纸 tint 一项真正生效
		// （tonemap 在 PK_WEB_WORLD_MIN 下被裁掉；paper grain 的 grain 恒 0.5 ⇒ 乘子 ≡1）。
		col = mix(col, col * parchment_tint, parchment_strength);
		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
	}
}
