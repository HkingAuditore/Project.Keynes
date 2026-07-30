shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// fog_of_war.gdshader — 三态视野迷雾（体积云）
//
// 数据通路与天气云完全同构：map_index_atlas.GB 逐像素解出 cell.index，再经
// cell-index 间接寻址采 per-cell LUT。区别是迷雾不占用独立纹理 —— 它复用
// enum_lut 空闲的 A 通道（enum_lut 已从 RGB8 升为 RGBA8），因此主地形拿迷雾
// 值是零新增采样。
//
// 知识度 k（enum_lut.a）：
//   k = 0.0  未探索      → 厚云，完全不透明
//   k = 0.5  已探索未可见 → 薄纱 + 主地形去饱和灰化（灰化在 world_map 做）
//   k = 1.0  完全可见     → alpha 0，整个 fragment 早退
//   中间值 = 烘焙期 hex 邻域 blur 产生的柔化过渡带
//
// ── 云怎么画：分层 2.5D 云海 ─────────────────────────────────────────
//
// 迷雾必须在未探索区保持完全遮挡，但「完全遮挡」不等于一块不透明浮雕。这里把同一
// 个连续密度场分成三层：低层层云 deck、中层云体 body、高层云塔 top。低层负责玩法
// 遮挡，中高层负责可读的云团形状；三层共享连续宏观场，因此不会出现互相滑动的贴片。
//
//   · 形状    普通 FBM 宏观场 + 高频侵蚀；域扭曲保持低幅，避免流体涡纹
//   · 法线    低频宽缓宏观坡向 + 小振幅高频细节，避免尖脊和「揉皱锡纸」
//   · 自阴影  沿主光方向积分前方云体质量，得到柔和光学厚度，不比较硬高度差
//   · 散射    双指数直射透过 + 有理式多重散射 + 天空半球补光
//   · 合成    deck/body/top 分层提亮，最后做软色调映射，避免大片截成纯白
//   · 视差    屏幕空间假视差：用解析梯度一阶位移把三层轮廓按高度错开，零重采样
//   · 差速    高层塔云是独立风场（异种子/异速/异向），与低层底盘相对滑动
//   · 体积    高度 AO 压谷底直射 + 坡向轮廓光勾云团边缘 + S 曲线拉回中间调
//
// q2/q3 的探针只积分二维云体质量，不做每像素数十步体积 raymarch；但视觉模型已经
// 从「一张地形高度图」改为「有低层托底的分层云体」。
//
// ── 东西向环绕 ────────────────────────────────────────────────────────
// 地图东西向无限滚动，采样点会被 fog_wrap_world_x 折回一个周期内。普通噪声在周期
// 两端对不上，接缝处就是一条肉眼可见的竖线。所以**这个 shader 里所有噪声都必须
// 走可平铺版本**（cloud_*_tiled / cloud_cumulus_*），并且域缩放要先经
// fog_tileable_scale 微调，让环绕周期恰好落在整数格上。
//
// 光照走 earth_daylight 逐像素晨昏线（与地形/水面/植被/天气云同一真源），
// 所以迷雾会随昼夜被晨昏线扫过：正午冷白顶 + 蓝灰缝隙，黄昏暖橙侧光 + 长投影，
// 夜里只剩冷蓝环境光。
//
// ── 质量分档 ──────────────────────────────────────────────────────────
// 有效档 = min(编译期 tier 上限, 运行时 fog_quality)。编译期宏砍掉低端机的
// 整段代码，运行时 uniform 让桌面端低配也能降档。
//   q0 超低：1 octave，无光照 —— 纯色 + 一点起伏，最便宜。
//   q1 低  ：3 频段分层密度 + 平滑法线 + TOD。无扭曲/无自阴影。
//   q2 中  ：4 频段 + 1 层域扭曲 + 2 个质量探针 + 独立塔云场 + Powder/银边/透射。
//   q3 高  ：4 频段 + 2 层域扭曲 + 2 个质量探针 + 独立塔云场 + 天空 SH 环境光。
//
// q3 每像素 4 主场 + 4 扭曲 + 1 塔云 + 2×2 阴影 = 13 次噪声采样。
// 阴影探针只吃 2 个低频段：第 3 频段权重仅 4%，却要多付 1/3 的探针开销；
// 探针数 3 → 2 同理 —— 自阴影是软厚度，少一段远探针肉眼不可辨。
// ════════════════════════════════════════════════════════════════════════

uniform sampler2D enum_lut : filter_nearest, repeat_disable;        // A = 知识度 k
uniform vec2 lut_dims = vec2(0.0);
uniform bool has_terrain_edge_data = false;
uniform float terrain_ecotone_width : hint_range(0.0, 0.96) = 0.84;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
#define VT_USE_MAP_INDEX
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform float world_time = 0.0;
uniform float hex_world_diameter = 38.0;

uniform bool fog_enabled = true;
// 运行时质量档 0..3，会被编译期 tier 上限夹住。
uniform int fog_quality : hint_range(0, 3) = 3;

// ── TOD（earth_daylight 的依赖必须在 include 之前声明）────────────────
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale : hint_range(0.2, 1.5) = 1.0;
// 只在调试永昼覆盖时被 earth_daylight 读到；正式模式走逐像素太阳方向。
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/cloud_noise.gdshaderinc"
#include "res://shaders/include/cloud_volume.gdshaderinc"

// q0 的基础色。q1+ 走分层密度散射，使用 deck_color / cloud_albedo。
// world_map 的早退分支输出与 unexplored_color 匹配的常量色；一旦开了光照（q>=1）
// 两者必然对不齐，所以早退只在 q0 允许（见 FogOfWarLayer）。
uniform vec3 unexplored_color : source_color = vec3(0.52, 0.56, 0.64);
uniform vec3 explored_color : source_color = vec3(0.74, 0.78, 0.84);
uniform float explored_alpha : hint_range(0.0, 1.0) = 0.46;
// 未探索区云缝下面的低层层云。它承担玩法遮挡，不应被画成黑色峡谷。
uniform vec3 deck_color : source_color = vec3(0.58, 0.65, 0.76);
// 边界噪声位移（hex 直径倍数）。让迷雾边缘不贴着 hex 轮廓走。
uniform float edge_warp : hint_range(0.0, 2.0) = 0.55;
// 云翻腾速度，低于天气云但必须能在 1x 下读出缓慢形变；游戏倍速由图层时钟另乘。
uniform float churn_speed : hint_range(0.0, 1.0) = 0.20;
// 主云团的空间尺度，单位 = hex 直径。越大云团越大。
uniform float cloud_scale : hint_range(1.0, 20.0) = 3.2;
// 域扭曲只改变云缘走向，不参与法线，避免把低频扭曲放大成巨型坡面。
uniform float warp_amount : hint_range(0.0, 2.5) = 0.28;

// ── q1+ 分层云海 ──
uniform vec3 cloud_albedo : source_color = vec3(0.97, 0.975, 1.0);
// 宏观法线只描述宽缓云丘；细节法线频率高但振幅小，负责近看时的锐利绒边。
uniform float cloud_relief : hint_range(0.0, 2.0) = 0.34;
uniform float cloud_detail_relief : hint_range(0.0, 0.5) = 0.08;
uniform float light_wrap : hint_range(0.0, 2.0) = 1.0;
uniform float sun_gain : hint_range(0.0, 3.0) = 0.68;
uniform float ms_gain : hint_range(0.0, 2.0) = 0.42;
uniform float ms_falloff : hint_range(0.1, 4.0) = 0.90;
uniform float ambient_gain : hint_range(0.0, 2.0) = 0.50;
uniform float valley_sky : hint_range(0.0, 1.0) = 0.68;
// 天光色相。现实中云的暗面偏**冷蓝**：天光来自 Rayleigh 散射，偏蓝，而它正是
// 暗部的主要照明。受光面暖白 + 暗面冷蓝的这一组对比，是云"看起来真"的一大半；
// 暗部做成中性灰就立刻假了。但也别过头 —— 冲到墨蓝就成了水下。
// 使用时会先归一化到亮度 1，所以这个值只改色相、不改明度。
uniform vec3 shadow_tint : source_color = vec3(0.84, 0.91, 1.0);
// 暗部转蓝的速度：ms_depth 乘上它得到「天光占比」。越大越早转蓝。
uniform float shadow_tint_depth : hint_range(0.0, 3.0) = 0.75;
// 自阴影积分范围与消光强度。两者都刻意压低，阴影应是软厚度，不是黑色沟槽。
uniform float shadow_reach : hint_range(0.0, 6.0) = 1.15;
uniform float shadow_absorb : hint_range(0.0, 20.0) = 3.2;
// Powder（糖粉效应）权重、银边强度、次表面透射强度。
uniform float powder_weight : hint_range(0.0, 1.0) = 0.28;
uniform float silver_gain : hint_range(0.0, 4.0) = 0.65;
uniform float sss_gain : hint_range(0.0, 2.0) = 0.25;
// HG 前向散射各向异性。
uniform float phase_g : hint_range(0.0, 0.95) = 0.58;
uniform float cloud_exposure : hint_range(0.4, 2.0) = 1.12;

// ── 体积感增强（视差 / 差速 / 轮廓光）──
// 屏幕空间假视差强度，单位 = hex 直径（屏幕四角处的高层云最大偏移）。俯视正交
// 相机没有真视差；这里用屏幕位置近似视线方向，把高层云沿视线路径错开。
// 它是纯屏幕函数，三块 wrap 副本取值一致，不会引入环绕接缝。
uniform float parallax_strength : hint_range(0.0, 2.0) = 0.80;
// 独立塔云场的漂移速度倍率：高层风比低层快，云顶相对云海底盘滑动（差速）。
uniform float top_shear_speed : hint_range(0.0, 2.0) = 0.75;
// 高度 AO 强度：压低谷底云缝的直射/反弹光，拉开云顶与云缝的明暗落差。
uniform float ao_strength : hint_range(0.0, 1.0) = 0.50;
// 坡向轮廓光强度：迎光坡提亮（背光坡另有小幅压暗，固定 0.16）。
uniform float rim_gain : hint_range(0.0, 2.0) = 0.55;
// 软色调映射后的 S 曲线对比度，0 = 不处理。
uniform float volume_contrast : hint_range(0.0, 0.6) = 0.22;
// 夜侧整体调光器：合成末端按 cloud_day 混入此倍率。夜云亮暗是艺术偏好，
// 与其分别拧环境光/月光/填充五六个旋钮，不如给一个总闸。1 = 夜昼同亮。
uniform float night_darkness : hint_range(0.2, 1.0) = 0.60;

varying vec2 v_world;

int effective_fog_quality() {
#if defined(MOBILE_QUALITY_LOW)
	return 0;
#elif defined(MOBILE_QUALITY_MID)
	return min(fog_quality, 1);
#elif defined(MOBILE_QUALITY_HIGH)
	return min(fog_quality, 2);
#else
	return clamp(fog_quality, 0, 3);
#endif
}

float fog_wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 fog_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = fog_wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

// cell-index 间接寻址（与 cell_indirect.gdshaderinc 同公式；此处内联，避免为了
// 一个 A 通道把 dyn/eco LUT 的 uniform 依赖全拖进来）。
int fog_decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 fog_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

int fog_decode_edge_secondary(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(fog_wrap_uv(uv)).rg;
	int lo = int(rg.r * 255.0 + 0.5);
	int hi = int(rg.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

float fog_bayer2_digit(vec2 bit_xy) {
	if (bit_xy.y < 0.5) {
		return (bit_xy.x < 0.5) ? 0.0 : 2.0;
	}
	return (bit_xy.x < 0.5) ? 3.0 : 1.0;
}

const float FOG_DITHER_THRESHOLD_MARGIN = 0.18;

float fog_mobile_dither_uv_threshold(vec2 uv, vec2 wp) {
	vec2 atlas_dims = visual_static_texture_size();
	vec2 pixel_xy = floor(fog_wrap_uv(uv) * atlas_dims);
	if (wrap_period_x > 0.0001 && world_size.x > 0.0001) {
		float period_px = max(
				8.0,
				round((atlas_dims.x * wrap_period_x / world_size.x) / 8.0) * 8.0);
		float phase = (fog_wrap_world_x(wp.x) - wrap_origin_x) / wrap_period_x;
		pixel_xy.x = floor(fract(phase) * period_px);
	}
	vec2 p = mod(pixel_xy, 8.0);
	float value = 16.0 * fog_bayer2_digit(mod(p, 2.0))
			+ 4.0 * fog_bayer2_digit(mod(floor(p * 0.5), 2.0))
			+ fog_bayer2_digit(floor(p * 0.25));
	float raw_threshold = (value + 0.5) / 64.0;
	return mix(
			FOG_DITHER_THRESHOLD_MARGIN,
			1.0 - FOG_DITHER_THRESHOLD_MARGIN,
			raw_threshold);
}

float fog_edge_secondary_weight(vec2 uv, int q) {
	if (!has_terrain_edge_data || terrain_ecotone_width <= 0.0001) {
		return 0.0;
	}
	float edge_distance = visual_sample_edge_distance(fog_wrap_uv(uv)).r;
	float one_screen_pixel = max(fwidth(edge_distance), 1.0 / 255.0);
	float quality_scale;
#if defined(MOBILE_QUALITY_LOW)
	quality_scale = 0.58;
#elif defined(MOBILE_QUALITY_MID)
	quality_scale = 0.82;
#elif defined(MOBILE_QUALITY_HIGH)
	quality_scale = 0.94;
#else
	quality_scale = (q <= 0) ? 0.68 : ((q == 1) ? 0.82 : ((q == 2) ? 0.92 : 1.0));
#endif
	float width = clamp(terrain_ecotone_width * quality_scale, one_screen_pixel, 0.98);
	float analytic = 0.5 * (1.0 - smoothstep(0.0, width, edge_distance));
	float aa = 0.5 * (1.0 - smoothstep(0.0, one_screen_pixel, edge_distance));
	return max(analytic, aa);
}

// 把域缩放微调到「环绕周期恰好等于 4 的整数倍个噪声格」。
//
// 可平铺噪声靠的是把晶格 x 坐标对周期取模，前提是周期必须是**整数**格；再取 4 的
// 倍数，是为了让 1/2、1/4 频率的域扭曲层也落在整数格上。不做这件事，东西向环绕的
// 接缝处就是一条明显的竖线。缩放被改动的幅度通常 < 1%，云团大小的变化看不出来。
//
// 返回 vec2(修正后的缩放, 周期格数)；周期 0 表示地图不环绕。
vec2 fog_tileable_scale(float base_scale) {
	if (wrap_period_x <= 0.0001) {
		return vec2(base_scale, 0.0);
	}
	float cells = max(8.0, round(wrap_period_x * base_scale * 0.25) * 4.0);
	return vec2(cells / wrap_period_x, cells);
}

// 时间演化的可平铺梯度噪声。与单纯给 p 加偏移不同，这里让每个晶格角点的梯度
// 以不同速度和方向旋转，因此等值线会原地生成、消散和重组；先折叠 x 晶格坐标，
// 仍能保证东西向周期完全一致。seed 只改变旋转速率，t=0 时保持静态场原貌。
vec2 fog_evolving_gradient(vec2 lattice, float t, float seed) {
	vec2 h = cloud_hash22(lattice);
	vec2 g = -1.0 + 2.0 * h;
	float direction = (h.x < 0.5) ? -1.0 : 1.0;
	float rate = (0.34 + 0.32 * h.y) * (0.88 + 0.09 * seed);
	float angle = t * rate * direction;
	float cs = cos(angle);
	float sn = sin(angle);
	return vec2(cs * g.x - sn * g.y, sn * g.x + cs * g.y);
}

vec3 fog_grad_noise_tiled_evolve_d(vec2 p, float period_x, float t, float seed) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_x >= 1.0) {
		x0 = mod(x0, period_x);
		x1 = mod(x1, period_x);
	}
	vec2 ga = fog_evolving_gradient(vec2(x0, i.y), t, seed);
	vec2 gb = fog_evolving_gradient(vec2(x1, i.y), t, seed);
	vec2 gc = fog_evolving_gradient(vec2(x0, i.y + 1.0), t, seed);
	vec2 gd = fog_evolving_gradient(vec2(x1, i.y + 1.0), t, seed);
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float k1 = vb - va;
	float k2 = vc - va;
	float k3 = va - vb - vc + vd;
	float n = va + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
	vec2 dn = ga + u.x * (gb - ga) + u.y * (gc - ga)
		+ u.x * u.y * (ga - gb - gc + gd)
		+ du * vec2(k1 + k3 * u.y, k2 + k3 * u.x);
	return vec3(0.5 + 0.5 * n, 0.5 * dn);
}

float fog_grad_noise_tiled_evolve(vec2 p, float period_x, float t, float seed) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_x >= 1.0) {
		x0 = mod(x0, period_x);
		x1 = mod(x1, period_x);
	}
	vec2 ga = fog_evolving_gradient(vec2(x0, i.y), t, seed);
	vec2 gb = fog_evolving_gradient(vec2(x1, i.y), t, seed);
	vec2 gc = fog_evolving_gradient(vec2(x0, i.y + 1.0), t, seed);
	vec2 gd = fog_evolving_gradient(vec2(x1, i.y + 1.0), t, seed);
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	return 0.5 + 0.5 * (
		va + u.x * (vb - va) + u.y * (vc - va)
		+ u.x * u.y * (va - vb - vc + vd)
	);
}

// 域扭曲：让 FBM 从"各向同性的糊团"变成有卷曲、有走向的云。
//
// 频率必须取 2 的负幂（1/2、1/4），否则子频率下的周期不再是整数格，接缝就回来了。
// q3 叠第二层，扭曲的扭曲 —— 这是云缘出现撕扯、翻卷的来源。
vec2 fog_domain_warp(vec2 p, float t, float period_n, int q) {
	float w0 = fog_grad_noise_tiled_evolve(
		p * 0.5 + vec2(0.0, t * 0.05), period_n * 0.5, t * 0.32, 0.0
	);
	float w1 = fog_grad_noise_tiled_evolve(
		p * 0.5 + vec2(5.2, 1.3 - t * 0.04), period_n * 0.5, t * 0.29, 1.0
	);
	vec2 pw = p + (vec2(w0, w1) - vec2(0.5)) * (2.0 * warp_amount);
	if (q >= 3) {
		float w2 = fog_grad_noise_tiled_evolve(
			pw * 0.25 + vec2(-3.1, 8.4), period_n * 0.25, t * 0.21, 2.0
		);
		float w3 = fog_grad_noise_tiled_evolve(
			pw * 0.25 + vec2(11.9, -2.6), period_n * 0.25, t * 0.24, 3.0
		);
		pw += (vec2(w2, w3) - vec2(0.5)) * (1.6 * warp_amount);
	}
	return pw;
}

struct FogCloudShape {
	float macro;
	float deck;
	float body;
	float top;
	float veil;
	float height;
	float thickness;
	vec2 broad_grad;
	vec2 detail_grad;
};

float fog_octave_fade(float lod_px, float frequency) {
	return 1.0 - smoothstep(0.30, 0.65, lod_px * frequency);
}

// 主形状由低频建立云丘，高频侵蚀边缘。法线明确拆成宽缓宏观坡向与低振幅锐利细节。
FogCloudShape fog_sample_shape(
	vec2 p, float t, float period_n, float lod_px, float cover, int q, vec2 parallax_p
) {
	vec2 drift = vec2(t * 0.12, -t * 0.08);
	// 每个频段使用不同方向/振幅的周期摆动。线性 drift 只会让整张场平移；
	// 相对 wobble 才会持续改变 octave 干涉关系，使云团内部翻卷、合并和分裂。
	vec2 wobble = vec2(sin(t * 0.55), cos(t * 0.43)) * 0.34;
	vec2 cross_wobble = vec2(-wobble.y, wobble.x);
	float f0 = fog_octave_fade(lod_px, 0.5);
	float f1 = fog_octave_fade(lod_px, 1.0);
	float f2 = fog_octave_fade(lod_px, 2.0);
	float f3 = (q >= 2) ? fog_octave_fade(lod_px, 4.0) : 0.0;

	vec3 n0 = fog_grad_noise_tiled_evolve_d(
		p * 0.5 + drift * 0.42 + vec2(7.1, -3.4),
		period_n * 0.5, t * 0.46, 0.0
	);
	vec3 n1 = fog_grad_noise_tiled_evolve_d(
		p + drift * 0.76 + cross_wobble * 0.10 + vec2(-11.8, 5.6),
		period_n, t * 0.68, 1.0
	);
	vec3 n2 = fog_grad_noise_tiled_evolve_d(
		p * 2.0 + drift * 1.16 - wobble * 0.30 + vec2(19.7, 13.2),
		period_n * 2.0, t * 0.97, 2.0
	);
	vec3 n3 = vec3(0.5, 0.0, 0.0);
	if (q >= 2 && f3 > 0.002) {
		n3 = fog_grad_noise_tiled_evolve_d(
			p * 4.0 - drift * 1.42 + (wobble - cross_wobble) * 0.34
				+ vec2(-31.4, 22.9),
			period_n * 4.0, t * 1.31, 3.0
		);
	}

	float w0 = 0.56 * f0;
	float w1 = 0.32 * f1;
	float w2 = 0.10 * f2;
	float w3 = 0.02 * f3;
	float norm = max(w0 + w1 + w2 + w3, 0.0001);
	float macro = (n0.x * w0 + n1.x * w1 + n2.x * w2 + n3.x * w3) / norm;

	float detail_norm = max(f2 * 0.78 + f3 * 0.22, 0.0001);
	float detail = (n2.x * f2 * 0.78 + n3.x * f3 * 0.22) / detail_norm;
	float shaped = clamp(macro + (detail - 0.5) * 0.10, 0.0, 1.0);

	// 宏观坡向只取 1/2、1 倍频，不再乘三条窄层级阈值的导数；后者会在每个
	// deck/body/top 等高线上制造尖脊。限制极端梯度，保证大轮廓始终宽缓。
	float broad_norm = max(f0 * 0.72 + f1 * 0.28, 0.0001);
	vec2 broad_grad = (
		n0.yz * (0.5 * f0 * 0.72)
		+ n1.yz * (f1 * 0.28)
	) / broad_norm;
	float broad_len = length(broad_grad);
	broad_grad *= min(1.0, 0.65 / max(broad_len, 0.0001));

	// 覆盖越低阈值越高：迷雾边界只剩破碎云团；满迷雾区则有连续低层托底。
	float cut = mix(0.69, 0.34, cover);

	// 视差剪切：field(p + o) ≈ field(p) + ∇field·o。用已有的解析宏观梯度把同一朵
	// 云的三层轮廓在屏幕上错开 —— deck 贴地不动，body 半偏移，top 全偏移。
	// 零重采样、纯 ALU；俯视正交相机本就没有真视差，这是最便宜的替代。
	float shaped_body = clamp(shaped + dot(broad_grad, parallax_p * 0.45), 0.0, 1.0);
	float shaped_top = clamp(shaped + dot(broad_grad, parallax_p), 0.0, 1.0);

	float deck = smoothstep(cut - 0.14, cut + 0.18, shaped);
	float body = smoothstep(cut + 0.00, cut + 0.30, shaped_body);
	float top = smoothstep(cut + 0.12, cut + 0.42, shaped_top);
	float veil = smoothstep(0.72, 1.0, cover) * mix(0.72, 1.0, deck);

	// 独立塔云场（q2+）：不同种子、不同漂移方向与速度的高层场，只从 deck 托底
	// 之上长出来（gate）。云顶因此能相对低层滑动 —— 高层风更快的差速，是俯视
	// 云海「有厚度」而非「一张噪声图」的最强线索。单次采样、不带导数：
	// top 的高频细节本来就由主场 shaped_top 提供，塔云场只需给出漂移的大形状。
	if (q >= 2) {
		vec2 tower_p = p + parallax_p
			+ vec2(t * 0.23, -t * 0.16) * top_shear_speed
			+ vec2(47.3, -19.1);
		float tower_field = fog_grad_noise_tiled_evolve(tower_p, period_n, t * 0.71, 5.0);
		float tower_gate = smoothstep(cut - 0.10, cut + 0.16, shaped);
		top = max(top, smoothstep(cut + 0.16, cut + 0.44, tower_field) * tower_gate * 0.85);
	}

	// 2、4 倍频保留空间上的锐度，但用独立的小振幅进入法线；这样细节清楚，
	// 又不会把高频坡度放大成锡纸或岩石褶皱。LOD 砍掉 octave 时自然归零。
	vec2 detail_grad = (
		n2.yz * (2.0 * f2 * 0.78)
		+ n3.yz * (4.0 * f3 * 0.22)
	) / detail_norm;
	float detail_mask = clamp(deck * 0.20 + body * 0.46 + top * 0.34, 0.0, 1.0);
	detail_grad *= detail_mask;
	float detail_len = length(detail_grad);
	detail_grad *= min(1.0, 1.60 / max(detail_len, 0.0001));

	FogCloudShape s;
	s.macro = macro;
	s.deck = deck;
	s.body = body;
	s.top = top;
	s.veil = veil;
	s.height = clamp(0.20 + deck * 0.22 + body * 0.34 + top * 0.20, 0.0, 1.0);
	s.thickness = clamp(veil * 0.24 + deck * 0.30 + body * 0.32 + top * 0.14, 0.0, 1.0);
	s.broad_grad = broad_grad;
	s.detail_grad = detail_grad;
	return s;
}

// 阴影探针只取 2 个低频段的值，不计算导数。返回前方云体质量而不是硬高度差。
// 自阴影要的是软厚度：2x 高频段权重本来只有 4%，砍掉肉眼不可辨，探针开销省 1/3。
float fog_shadow_mass(
	vec2 p, float t, float period_n, float lod_px, float cover
) {
	vec2 drift = vec2(t * 0.12, -t * 0.08);
	vec2 wobble = vec2(sin(t * 0.55), cos(t * 0.43)) * 0.34;
	vec2 cross_wobble = vec2(-wobble.y, wobble.x);
	float f0 = fog_octave_fade(lod_px, 0.5);
	float f1 = fog_octave_fade(lod_px, 1.0);
	float n0 = fog_grad_noise_tiled_evolve(
		p * 0.5 + drift * 0.42 + vec2(7.1, -3.4),
		period_n * 0.5, t * 0.46, 0.0
	);
	float n1 = fog_grad_noise_tiled_evolve(
		p + drift * 0.76 + cross_wobble * 0.10 + vec2(-11.8, 5.6),
		period_n, t * 0.68, 1.0
	);
	float norm = max(f0 * 0.68 + f1 * 0.32, 0.0001);
	float macro = (n0 * f0 * 0.68 + n1 * f1 * 0.32) / norm;
	float cut = mix(0.69, 0.34, cover);
	float body = smoothstep(cut - 0.01, cut + 0.31, macro);
	float top = smoothstep(cut + 0.11, cut + 0.43, macro);
	return clamp(body * 0.72 + top * 0.28, 0.0, 1.0);
}

vec3 fog_soft_tonemap(vec3 x) {
	// ACES fitted：保留云顶高光层次，不让大面积直接 clamp 成纯白。
	x = max(x * cloud_exposure, vec3(0.0));
	return clamp(
		(x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14),
		vec3(0.0),
		vec3(1.0)
	);
}

void vertex() {
	// VERTEX 此时是 mesh 局部坐标 = 世界坐标（quad 顶点按 world_bounds 写入）。
	// 与 data_overlay.gdshader 同约定：不走 canvas_item 默认 UV，避免
	// 「自定义 UV 是否传到 fragment 取决于 texture slot 绑定」这个坑。
	v_world = VERTEX;
}

void fragment() {
	// canvas_item 的 fragment 禁用 return（见 data_overlay.gdshader 注释），
	// 全部用嵌套 if 表达，默认完全透明。
	vec4 out_color = vec4(0.0);

	if (fog_enabled && lut_dims.x >= 1.0) {
		int q = effective_fog_quality();
		vec2 wp = vec2(fog_wrap_world_x(v_world.x), v_world.y);
		float t = world_time * churn_speed;

		// 边界域扭曲：只影响"在哪儿取 k"，不影响 k 本身，因此 hex 轮廓被打散成
		// 有机曲线，而每格的语义状态仍然精确。
		// 同样要走可平铺噪声，否则环绕接缝上的迷雾边界会错开一截。
		vec2 warped = wp;
		if (edge_warp > 0.001) {
			vec2 ews = fog_tileable_scale(0.0042);
			vec2 np = wp * ews.x;
			float wa = cloud_grad_noise_tiled(np, ews.y);
			float wb = cloud_grad_noise_tiled(np + vec2(17.3, -9.1), ews.y);
			warped += (vec2(wa, wb) - vec2(0.5)) * 2.0 * edge_warp * hex_world_diameter;
		}

		vec2 uv = fog_wrap_uv((warped - world_origin) / world_size);
		int cid = fog_decode_cell_index(uv);
		// cid < 0 是极地外侧的烘焙 padding：不可交互，按未探索处理，顺带把
		// 人造边界藏进云里。
		float k = 0.0;
#if defined(PK_MOBILE_ANY)
		// Mobile DitherUV selects one visual cell before the LUT lookup. This keeps
		// the old distant transition character without paying for two LUT samples.
		int visual_cid = cid;
		if (visual_cid >= 0) {
			float edge_w = fog_edge_secondary_weight(uv, q);
			if (edge_w > 0.0001) {
				int secondary_id = fog_decode_edge_secondary(uv);
				if (secondary_id >= 0
						&& fog_mobile_dither_uv_threshold(uv, warped) < edge_w) {
					visual_cid = secondary_id;
				}
			}
			k = texture(enum_lut, fog_cell_lut_uv(visual_cid)).a;
		}
#else
		k = (cid >= 0) ? texture(enum_lut, fog_cell_lut_uv(cid)).a : 0.0;
		if (cid >= 0) {
			float edge_w = fog_edge_secondary_weight(uv, q);
			if (edge_w > 0.0001) {
				int secondary_id = fog_decode_edge_secondary(uv);
				if (secondary_id >= 0) {
					float secondary_k = texture(enum_lut, fog_cell_lut_uv(secondary_id)).a;
					k = mix(k, secondary_k, edge_w);
				}
			}
		}
#endif

		float fog_amount = 1.0 - clamp(k, 0.0, 1.0);
		if (fog_amount > 0.02) {
			// thick 在未探索区收敛到 1；alpha 必须能真正到 1.0，否则 world_map
			// 的早退会露出底下未绘制的内容。
			float thick = smoothstep(0.52, 0.95, fog_amount);
			float presence = smoothstep(0.04, 0.52, fog_amount);

			// 噪声域尺度（已按环绕周期对齐到整数格）+ 该域下一个屏幕像素的跨度
			// （喂给 FBM 做 LOD 截断）。
			vec2 sc = fog_tileable_scale(1.0 / max(hex_world_diameter * cloud_scale, 0.001));
			float scale = sc.x;
			float period_n = sc.y;
			vec2 p = wp * scale;
			float lod_px = max(fwidth(v_world.x), fwidth(v_world.y)) * scale;

			vec3 col;
			float alpha;

			if (q <= 0) {
				// ── q0 超低：无导数、无光照。只要一层柔和起伏把纯色打散。
				vec2 q0_drift = vec2(t * 0.17, -t * 0.13);
				float n = fog_grad_noise_tiled_evolve(
					p + q0_drift, period_n, t * 0.68, 0.0
				);
				float shade = mix(0.86, 1.14, n);
				col = mix(explored_color, unexplored_color, thick) * shade;
				float thin_a = explored_alpha * presence * mix(0.76, 1.10, n);
				alpha = mix(clamp(thin_a, 0.0, 1.0), 1.0, thick);
			} else {
				// q1 与 q2+ 都要 TOD，先算一次。
				vec2 map_uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));
				float lat_signed = clamp(map_uv.y * 2.0 - 1.0, -1.0, 1.0);
				EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);

				// ── 主光：太阳与月亮分别着色后平滑相加 ─────────────────
				// 旧版直接 step(日/月) 会在晨昏线上瞬间翻转法线受光与阴影方向。
				// 高空云在太阳落到地平线以下后仍能被照亮，所以太阳可见带也应比地表
				// local_day 更宽；这段额外宽度正是火烧云出现的区域。
				float sun_elev = ed.sun_dir.z;
				float cloud_day = day_night_enabled
					? smoothstep(-0.46, 0.34, sun_elev)
					: 1.0;
				float sun_strength = day_night_enabled
					? smoothstep(-0.42, 0.24, sun_elev)
					: 1.0;
				float twilight = smoothstep(-0.50, -0.02, sun_elev)
					* (1.0 - smoothstep(0.14, 0.56, sun_elev));
				float moon_strength = ed.moon_strength
					* (1.0 - smoothstep(0.18, 0.78, sun_strength));
				vec3 sun_key_col = ed.sun_col * sun_strength;
				float moon_luma = dot(ed.moon_col, vec3(0.2126, 0.7152, 0.0722));
				vec3 moon_cloud_col = mix(ed.moon_col, vec3(moon_luma), 0.38);
				vec3 moon_key_col = moon_cloud_col * moon_strength;
				vec3 key_col = sun_key_col + moon_key_col;
				float key_amt = clamp(sun_strength + moon_strength, 0.0, 1.0);
				float sun_share = sun_strength / max(sun_strength + moon_strength, 0.0001);

				vec3 sun_d = ed.sun_dir;
				sun_d.z = max(sun_d.z, 0.08);
				vec3 sun_L = normalize(sun_d);
				vec3 moon_d = ed.moon_dir;
				moon_d.z = clamp(moon_d.z, 0.08, 0.72);
				vec3 moon_L = normalize(moon_d);

				// 主光轴：方向性效果不再「翻转」，而是按日/月光强比连续混合。
				//   · 自阴影：永远沿太阳水平轴（全天连续）；深夜由 daylight_shadow
				//     压到 0.16，月轴阴影本就不可见 —— 切换它只会制造翻转线。
				//   · 轮廓光/暮光坡向：本模拟 moon_dir = -sun_dir，月轴恰为日轴
				//     镜像；对同一坡度分别算「向日/向月」两套权重按 use_sun_axis
				//     混合，50/50 处方向性自然中和 —— 数学上严格连续，无衰减缝。
				// 混合带刻意拉宽（±0.45 光强差 ≈ 整个晨昏区）：镜像混合本身严格连续，
				// 唯一可见残留是「权重互换太快」—— 带越宽，迎/背光坡的明暗互换
				// 越摊薄，肉眼越读不出这条带。昼/夜两端仍各自收敛到纯日/纯月。
				float use_sun_axis = smoothstep(-0.45, 0.45, sun_strength - moon_strength);
				float sun_hlen = length(sun_L.xy);
				vec2 sun_axis_s = (sun_hlen > 1e-3)
					? sun_L.xy / sun_hlen
					: normalize(vec2(0.62, -0.38));
				float moon_hlen = length(moon_L.xy);
				vec2 moon_axis_s = (moon_hlen > 1e-3) ? moon_L.xy / moon_hlen : -sun_axis_s;
				vec2 axis_blend = mix(moon_axis_s, sun_axis_s, use_sun_axis);
				float axis_len = length(axis_blend);
				float sun_horiz = clamp(mix(moon_hlen, sun_hlen, use_sun_axis), 0.0, 1.0);
				float sun_up = max(mix(moon_L.z, sun_L.z, use_sun_axis), 0.0);
				vec3 L = normalize(vec3((axis_blend / max(axis_len, 1e-4)) * sun_horiz, sun_up));

				// 屏幕空间假视差：正交俯视没有真视差，用屏幕位置近似视线方向。
				// 纯屏幕函数 ⇒ 三块 wrap 副本取值完全一致，不会在环绕接缝处错开；
				// 镜头平移 / 云特征横穿屏幕时，高层云相对低层剪切滑动。
				vec2 scr_uv = FRAGCOORD.xy * SCREEN_PIXEL_SIZE;
				float scr_aspect = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 1e-6);
				vec2 view_dir = (scr_uv - vec2(0.5)) * vec2(scr_aspect, 1.0) * 2.0;
				vec2 parallax_p = view_dir * parallax_strength * hex_world_diameter * scale;

				float cover = clamp(fog_amount * 1.15, 0.0, 1.0);
				vec2 pw = (q >= 2) ? fog_domain_warp(p, t, period_n, q) : p;
				FogCloudShape shape = fog_sample_shape(
					pw, t, period_n, lod_px, cover, q, parallax_p
				);

				// ── 光照 ───────────────────────────────────────────────
				vec3 N = normalize(vec3(
					-(
						shape.broad_grad * cloud_relief
						+ shape.detail_grad * cloud_detail_relief
					),
					1.0
				));
				float sun_ndl = dot(N, sun_L);
				float moon_ndl = dot(N, moon_L);
				// 动态包裹光：正午太阳近顶光，N·L 本身就平，给足包裹保持柔和；
				// 太阳越低光越擦着云丘走，包裹收紧 → 同一片云在晨昏出现强方向性
				// 明暗。这是「TOD 角度变化读得出来」的主要来源。
				float dyn_wrap = mix(0.42, light_wrap, smoothstep(-0.10, 0.55, sun_elev));
				float sun_diffuse = clamp((sun_ndl + dyn_wrap) / (1.0 + dyn_wrap), 0.0, 1.0);
				float moon_diffuse_raw = clamp(
					(moon_ndl + light_wrap) / (1.0 + light_wrap),
					0.0,
					1.0
				);
				// 月光漫反射不能完全压平：深夜它是唯一主光，全平会把夜云糊成一块
				// 纯色蓝布。保留中等方向性勾出云丘起伏，但仍远弱于太阳的方向性。
				float moon_diffuse = mix(0.62, moon_diffuse_raw, 0.42);

				// 云丘坡向（轮廓光/暮光共用）。注意符号：高度场梯度指向坡上，
				// 迎光坡的梯度指向**远离**太阳的一侧，即 edge_face < 0 才是迎光坡
				// （与 N·L 一致：N 的水平分量 = -grad）。
				vec2 slope_g = shape.broad_grad + shape.detail_grad * 0.40;
				float slope_len = length(slope_g);
				float edge_face = (slope_len > 1e-3)
					? dot(slope_g / slope_len, sun_axis_s)
					: 0.0;
				// 向日坡权重；向月坡是其精确镜像（moon_dir=-sun_dir ⇒ 1-sun_face_s）。
				// 按光强比混合后，晨昏线两侧同一面坡的受光权重连续过渡。
				float sun_face_s = clamp(0.5 - 0.5 * edge_face, 0.0, 1.0);
				float sun_face = mix(1.0 - sun_face_s, sun_face_s, use_sun_axis);

				// 自阴影积分的是前方云体质量。低处权重大、塔顶权重小，形成柔和厚度，
				// 但不再把「前方比我高」直接画成黑色峡谷。
				float horizon_mass = 0.0;
				if (q >= 2 && shadow_reach > 0.001) {
					// 固定 2 探针：近端 f=0.5 决定阴影形状，远端 f=1.0 提供厚度。
					// 软阴影模型下第 3 段远探针的贡献肉眼不可辨。
					float reach = (shadow_reach / max(cloud_scale, 0.001))
						* clamp(sun_horiz / max(sun_up, 0.28), 0.35, 3.0);
					for (int i = 0; i < 2; i++) {
						float f = float(i + 1) * 0.5;
						float mass = fog_shadow_mass(
							pw + sun_axis_s * (reach * f),
							t,
							period_n,
							lod_px,
							cover
						);
						horizon_mass += mass * (1.0 - 0.32 * f);
					}
					horizon_mass *= 0.5;
				}
				float local_mass = clamp(shape.body * 0.72 + shape.top * 0.28, 0.0, 1.0);
				float excess_mass = max(0.0, horizon_mass - local_mass * 0.58);
				float directional_mass = mix(horizon_mass, excess_mass, 0.62);
				float valley_weight = mix(0.92, 0.32, shape.height);
				float optical_shadow = directional_mass * valley_weight * shadow_absorb;
				// 日光消失后不能让质量阴影恢复到满强度：真实夜云主要由天空/月光
				// 扩散照亮，深夜只留下很弱的厚度遮蔽（0.16 下限）。
				float daylight_shadow = smoothstep(0.08, 0.72, sun_strength);
				// 阴影轴全天固定为太阳水平轴（见主光轴注释），场天然连续，
				// 不再需要任何翻转线遮蔽；twilight 只做轻微压暗。
				float shadow_strength = mix(0.16, 1.0, daylight_shadow)
					* mix(1.0, 0.62, twilight);
				optical_shadow *= shadow_strength;
				float light_t = (q >= 2) ? cloud_beer_ms(optical_shadow) : 1.0;
				float density = max(shape.deck * 0.55, shape.body);
				float powder = (q >= 2) ? cloud_powder(density, powder_weight) : 1.0;

				// 银边只落在中层云体的软边，不再覆盖整块低层云海。
				float body_edge = smoothstep(0.05, 0.42, shape.body)
					* (1.0 - smoothstep(0.56, 0.96, shape.body));
				float sun_silver = 0.0;
				float moon_silver = 0.0;
				if (q >= 2) {
					sun_silver = cloud_phase(sun_L.z, phase_g) * body_edge * light_t
						* smoothstep(-0.10, 0.70, sun_ndl) * silver_gain;
					moon_silver = cloud_phase(moon_L.z, phase_g) * body_edge * light_t
						* smoothstep(-0.10, 0.70, moon_ndl) * silver_gain * 0.16;
				}

				vec3 tint_n = shadow_tint
					/ max(dot(shadow_tint, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
				// 地表晨昏只需在太阳几何落山附近过渡；高空云仍能看见地平线下的
				// 散射光，因此单独使用更宽的 cloud_day，不能直接照搬 ed.amb_col。
				// 夜侧环境光先抬亮、去饱和：EARTH_NIGHT_AMBIENT 是给地形剪影用的
				// 深蓝，直接照云会得到一块饱和死蓝布；真实夜云是被月光与天光
				// 照亮的暗灰蓝，内部仍有可读起伏。
				vec3 night_amb = mix(
					EARTH_NIGHT_AMBIENT,
					vec3(dot(EARTH_NIGHT_AMBIENT, vec3(0.2126, 0.7152, 0.0722))),
					0.35
				) * 1.28;
				vec3 cloud_ambient_col = mix(
					night_amb,
					EARTH_DAY_AMBIENT,
					cloud_day
				);
				// EARTH_NIGHT_AMBIENT 本身已经偏蓝；深夜若再完整叠 shadow_tint，
				// 会双重染蓝成水下色。夜侧只保留少量冷色偏移，白昼再恢复完整 tint。
				vec3 cloud_tint = mix(vec3(1.0), tint_n, mix(0.22, 1.0, cloud_day));
				vec3 sky_col = cloud_ambient_col * cloud_tint;
				float sky = mix(valley_sky, 1.0, shape.height);
				vec3 ambient = sky_col * sky * ambient_gain;
				if (q >= 3) {
					vec3 sky_N = normalize(vec3(
						-shape.broad_grad * cloud_relief * 0.34,
						1.0
					));
					vec3 key_palette = mix(moon_cloud_col, ed.sun_col, sun_share);
					float sky_key_amt = key_amt * mix(0.20, 1.0, sun_share);
					ambient = earth_sky_sh(sky_col, key_palette, L, sky_key_amt, sky_N)
						* sky * ambient_gain;
				}
				float moon_fill_strength = moon_strength
					* (1.0 - smoothstep(0.12, 0.62, sun_strength));
				ambient += moon_cloud_col * moon_fill_strength
					* mix(0.085, 0.125, shape.height);

				// 多重散射用厚尾有理式；越深越从主光色漂向冷天光。
				float ms_depth = (1.0 - shape.height) * 0.55
					+ shape.thickness * 0.28
					+ optical_shadow * 0.10;
				float tint_t = clamp(ms_depth * shadow_tint_depth, 0.0, 1.0);
				vec3 bounce_col = mix(
					key_col,
					sky_col * mix(0.72, 1.0, key_amt),
					tint_t
				);
				vec3 bounce = bounce_col * (ms_gain / (1.0 + ms_falloff * ms_depth));

				float sss = (q >= 2)
					? exp(-shape.thickness * 2.2) * light_t * body_edge * sss_gain
					: 0.0;
			vec3 direct = sun_key_col * (
				sun_diffuse * light_t * powder * sun_gain + sun_silver
				) + moon_key_col * (
					moon_diffuse * light_t * mix(1.0, powder, 0.35) * sun_gain * 0.36
					+ moon_silver
				);

				// 高度 AO：云缝谷底比云顶少吃直射与反弹 —— 明暗落差是体积感的另一半。
				// 只压直射/反弹，不动天空环境光，谷底仍被天光托住，不会死黑。
				direct *= mix(1.0 - ao_strength * 0.90, 1.0, shape.height);
				bounce *= mix(1.0 - ao_strength * 0.55, 1.0, shape.height);

				// 暮光穿过更长的大气路径后偏金橙；只落在**朝向太阳**的坡面、云塔
				// 与软边上。不带朝向的 fire_mask 会把晨昏带均匀刷成一圈描边光晕
				// （像贴上去的）；低角度阳光没有道理照亮背光坡。
				float fire_warmth = smoothstep(-0.16, 0.12, sun_elev);
				vec3 fire_color = mix(
					vec3(1.38, 0.56, 0.05),
					vec3(1.28, 0.96, 0.18),
					fire_warmth
				);
				float fire_mask = twilight * (
					shape.deck * 0.03
					+ shape.body * 0.15
					+ shape.top * 0.30
					+ body_edge * 0.26
				);
				fire_mask *= mix(0.22, 1.0, sun_face) * mix(0.55, 1.0, sun_diffuse);
				vec3 fire_scatter = fire_color * fire_mask * (0.13 + light_t * 0.12);

				// 三层不能共用一套「albedo × light」：那只是在一张表面上换颜色，
				// 法线再强也没有前后层次。低层以天光/回填为主，中层吃柔和直射，
				// 云顶获得最强直射与最弱深度衰减，再按嵌套密度从下往上合成。
				vec3 deck_albedo = deck_color;
				vec3 body_albedo = mix(deck_color, cloud_albedo, 0.68);
				vec3 top_albedo = cloud_albedo;
				float warm_albedo = twilight * clamp(
					shape.body * 0.12 + shape.top * 0.23 + body_edge * 0.18,
					0.0,
					0.34
				);
				// 与 fire_scatter 同向：暖色反照率只染迎光侧，背光侧保持冷灰。
				warm_albedo *= mix(0.45, 1.0, sun_face);
				body_albedo = mix(body_albedo, vec3(1.0, 0.72, 0.25), warm_albedo * 0.72);
				top_albedo = mix(top_albedo, vec3(1.0, 0.82, 0.38), warm_albedo);

				vec3 deck_light = ambient * 1.08 + bounce * 1.04 + direct * 0.30;
				vec3 body_light = ambient * 0.96 + bounce * 0.90 + direct * 0.82;
				vec3 top_light = ambient * 1.02 + bounce * 0.68 + direct * 1.20;
				float body_depth = shape.body * (1.0 - shape.top) * (0.35 + optical_shadow * 0.18);
				vec3 deck_radiance = deck_albedo * deck_light;
				vec3 body_radiance = body_albedo * body_light * mix(1.0, 0.84, body_depth);
				vec3 top_radiance = top_albedo * top_light * mix(1.0, 1.07, shape.top);
				float body_w = smoothstep(0.04, 0.92, shape.body) * 0.86;
				float top_w = smoothstep(0.03, 0.90, shape.top) * 0.82;

				// 低层只用柔和天光托底；这是未探索区完全遮挡时仍像云海、而不是
				// 黑色空洞的关键。它是加法散射，不是逐像素 max() 硬地板。
				vec3 deck_fill = sky_col * (0.08 + shape.veil * 0.10);
				col = mix(deck_radiance, body_radiance, body_w);
				col = mix(col, top_radiance, top_w)
					+ deck_fill
					+ fire_scatter
					+ key_col * (sss * 0.24 + shape.top * 0.055);

				// 坡向轮廓光（q2+）：迎光坡提亮、背光坡微压（迎光坡 = edge_face < 0）。
				// 向日/向月两套轮廓权重互为镜像，按 use_sun_axis 混合：翻转线上
				// 迎/背权重相等、方向性自然中和 —— 严格连续，无衰减缝。
				// 太阳越低轮廓光越强（掠射角拉长迎光坡），正午收敛。
				if (q >= 2) {
					float rim_band = smoothstep(0.06, 0.38, slope_len)
						* clamp(shape.body * 0.55 + shape.top * 0.75, 0.0, 1.0);
					float rim_strength = mix(0.25, 1.0, key_amt)
						* mix(1.35, 1.0, smoothstep(-0.05, 0.60, sun_elev))
						* mix(0.45, 1.0, sun_share);
					float rim_pos_sun = smoothstep(0.15, 0.85, -edge_face) * rim_band;
					float rim_neg_sun = smoothstep(0.15, 0.85, edge_face) * rim_band;
					float rim_pos = mix(rim_neg_sun, rim_pos_sun, use_sun_axis);
					float rim_neg = mix(rim_pos_sun, rim_neg_sun, use_sun_axis);
					col = col * (1.0 - rim_neg * 0.16 * rim_strength)
						+ key_col * (rim_pos * rim_gain * 0.55 * rim_strength);
				}

				// 夜侧整体调光：深夜（cloud_day=0）乘 night_darkness，白昼不变。
				col *= mix(night_darkness, 1.0, cloud_day);
				col = fog_soft_tonemap(col);
				// S 曲线把被 ACES 压平的中间调重新拉开：亮云顶更挺、暗云缝更沉。
				// 夜侧强度略降：深夜只剩环境光，满强度 S 曲线仍会把夜云压死黑。
				col = mix(
					col,
					col * col * (3.0 - 2.0 * col),
					volume_contrast * mix(0.65, 1.0, cloud_day)
				);
				col *= mix(0.94, 1.06, clamp(shape.body * 0.45 + shape.top * 0.55, 0.0, 1.0));

				// 过渡带按分层云体透明；满迷雾区仍严格 alpha=1，保证玩法信息不泄漏。
				float cloud_opacity = clamp(
					shape.veil * 0.38
					+ shape.deck * 0.40
					+ shape.body * 0.18
					+ shape.top * 0.08,
					0.0,
					1.0
				);
				float thin_a = explored_alpha * presence * mix(0.16, 1.0, cloud_opacity);
				alpha = mix(clamp(thin_a, 0.0, 1.0), 1.0, thick);
			}

			out_color = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
		}
	}

	COLOR = out_color;
}
