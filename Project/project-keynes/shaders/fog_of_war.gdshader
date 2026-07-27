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
// ── 云怎么画：高度场云海，明确不做 raymarch ──────────────────────────
//
// 俯视地图能看见的本来就只有云海的**顶面**。沿视线积分（每像素几百次噪声）算出来
// 的云内部光路，屏幕上一点都体现不出来 —— 这个层几乎铺满全屏，那个代价换不到
// 对应的观感。所以走高度场：一次 FBM 拿到云顶高度与解析导数，再用**几个探针**
// 把散射模型该给的东西补齐。
//
//   · 形状    billow FBM（|2n-1|）给花椰菜状的圆头尖谷 + 多层域扭曲打散走向
//   · 自阴影  沿太阳水平方向 2~3 个高度探针，量「前方比我高多少」= 光要穿过的云量
//   · 消光    cloud_beer_ms 双指数，比单指数 Beer 的阴影通透（近似多重散射尾巴）
//   · Powder  修正迎光薄边（纯 Beer 会把云缘算得过亮）
//   · 银边    HG 相函数 × 薄处 × 迎光
//   · 3S 透射 薄云被背后的太阳点亮，是云"通透"而不是"石膏"的原因
//   · 天空遮蔽 塔顶看得见整片天空、谷底看不见 —— **云海的层次主要来自这一项**
//
// 明暗直接算进颜色里，不做「累积辐射再除回覆盖度」那种归一化：未探索区覆盖度恒为
// 1，除回去等于把所有明暗变化一起除掉，结果就是一整片灰。
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
//   q1 低  ：3 octaves + 法线漫反射 + 天空遮蔽 + TOD。无扭曲/无自阴影。
//   q2 中  ：4 octaves + 1 层域扭曲 + 2 探针自阴影 + Powder + 银边 + 3S。
//   q3 高  ：5 octaves + 2 层域扭曲 + 3 探针自阴影 + 天空 SH 环境光。
//
// q3 每像素约 5 + 4 + 3×3 = 18 次噪声 octave。
// ════════════════════════════════════════════════════════════════════════

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable; // G/B = cell.index 低/高字节
uniform sampler2D enum_lut : filter_nearest, repeat_disable;        // A = 知识度 k
uniform vec2 lut_dims = vec2(0.0);

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
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

// q0 / q1 的基础反照率。q2+ 走体积积分，用的是 cloud_albedo。
// world_map 的早退分支输出与 unexplored_color 匹配的常量色；一旦开了光照（q>=1）
// 两者必然对不齐，所以早退只在 q0 允许（见 FogOfWarLayer）。
uniform vec3 unexplored_color : source_color = vec3(0.52, 0.56, 0.64);
uniform vec3 explored_color : source_color = vec3(0.74, 0.78, 0.84);
uniform float explored_alpha : hint_range(0.0, 1.0) = 0.46;
// 边界噪声位移（hex 直径倍数）。让迷雾边缘不贴着 hex 轮廓走。
uniform float edge_warp : hint_range(0.0, 2.0) = 0.85;
// 云翻腾速度，约天气云的 1/4 —— 迷雾要显得沉重。
uniform float churn_speed : hint_range(0.0, 1.0) = 0.25;
// 主云团的空间尺度，单位 = hex 直径。越大云团越大。
uniform float cloud_scale : hint_range(1.0, 20.0) = 5.5;
// 域扭曲幅度（噪声格数）。不扭曲的 FBM 等值线是各向同性的糊团，打多少光都像烟；
// 扭曲之后才有卷曲、走向和撕扯的云缘。
uniform float warp_amount : hint_range(0.0, 2.5) = 0.875;

// ── q1+ 云海高度场 ──
// 云的反照率。云是高反照率介质，**暗部必须由光照和自阴影拉出来**，
// 把 albedo 压暗只会得到一整片灰板 —— 那正是"看起来特别灰"的病因。
uniform vec3 cloud_albedo : source_color = vec3(0.97, 0.975, 1.0);
// 高度场起伏 → 法线倾斜程度。越大云越"鼓"。
uniform float cloud_relief : hint_range(0.0, 6.0) = 2.2;
// 法线平滑：高频 octave 对**梯度**的衰减率（见 cloud_cumulus_fbm_d 注释）。
// 1.0 = 真实梯度 = 每个 octave 等权 = 揉皱锡纸。越小法线越取自大形状。
uniform float normal_smooth : hint_range(0.15, 1.0) = 0.5;
// 漫反射 wrap。云的单次散射反照率≈1，背光面不可能像固体那样掉黑，wrap 要给足。
uniform float light_wrap : hint_range(0.0, 2.0) = 0.75;
// 云顶窗口：高度落在 [top_lo, top_hi] 之间映射成 0..1 的"塔高"，
// 天空遮蔽与顶部受光都吃这个值。窗口要盖住高度场的实际分布 ——
// 开太窄，峰顶会成片饱和成发光的白核。
uniform float top_lo : hint_range(0.0, 1.0) = 0.20;
uniform float top_hi : hint_range(0.0, 1.0) = 0.66;
// 直射增益。三项（direct + bounce + ambient）之和要让塔顶**刚好逼近白**。
uniform float sun_gain : hint_range(0.0, 3.0) = 0.55;
// 多重散射回填（GI）强度与随深度的衰减率。云暗部的亮度**主要来自这一项**，
// 不是环境光；调到 0 就会看到"没有 GI"的石头感。
// 衰减是有理式 1/(1+ms_falloff·d) 而非指数 —— 云处于扩散输运区，尾巴很厚，
// 这就是暗面"通透"的来源。ms_falloff 越大暗部越沉。
uniform float ms_gain : hint_range(0.0, 2.0) = 0.38;
uniform float ms_falloff : hint_range(0.1, 4.0) = 1.1;
// 环境光增益，以及谷底能看到的天空比例。
// valley_sky 压太低 = 缝隙全黑；真实云谷还被四周云壁二次照亮，不会那么暗。
uniform float ambient_gain : hint_range(0.0, 2.0) = 0.30;
uniform float valley_sky : hint_range(0.0, 1.0) = 0.40;
// 天光色相。现实中云的暗面偏**冷蓝**：天光来自 Rayleigh 散射，偏蓝，而它正是
// 暗部的主要照明。受光面暖白 + 暗面冷蓝的这一组对比，是云"看起来真"的一大半；
// 暗部做成中性灰就立刻假了。但也别过头 —— 冲到墨蓝就成了水下。
// 使用时会先归一化到亮度 1，所以这个值只改色相、不改明度。
uniform vec3 shadow_tint : source_color = vec3(0.78, 0.87, 1.0);
// 暗部转蓝的速度：ms_depth 乘上它得到「天光占比」。越大越早转蓝。
uniform float shadow_tint_depth : hint_range(0.0, 3.0) = 0.55;
// 夜侧/晨昏的天光地板。这两处 local_day 与 moon_strength 同时逼近 0，
// 主光会整个塌掉，只剩天光撑着 —— 不给下限就会比地形暗一大截。
uniform float night_floor : hint_range(0.0, 2.0) = 0.55;
// 自阴影探针距离（hex 直径倍数）与吸收强度。
// 探针间的高度差本身只有 0.1~0.2 量级，absorb 要够大才拉得出可见的投影。
uniform float shadow_reach : hint_range(0.0, 6.0) = 2.2;
// 探针间的高度差本身只有 0.1~0.2 量级，absorb 要够大才拉得出可见的投影。
uniform float shadow_absorb : hint_range(0.0, 20.0) = 9.0;
// Powder（糖粉效应）权重、银边强度、次表面透射强度。
uniform float powder_weight : hint_range(0.0, 1.0) = 0.45;
uniform float silver_gain : hint_range(0.0, 4.0) = 1.6;
uniform float sss_gain : hint_range(0.0, 2.0) = 0.55;
// HG 前向散射各向异性。
uniform float phase_g : hint_range(0.0, 0.95) = 0.66;

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
	vec2 gb = texture(map_index_atlas, uv).gb;
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

// 域扭曲：让 FBM 从"各向同性的糊团"变成有卷曲、有走向的云。
//
// 频率必须取 2 的负幂（1/2、1/4），否则子频率下的周期不再是整数格，接缝就回来了。
// q3 叠第二层，扭曲的扭曲 —— 这是云缘出现撕扯、翻卷的来源。
vec2 fog_domain_warp(vec2 p, float t, float period_n, int q) {
	float w0 = cloud_grad_noise_tiled(p * 0.5 + vec2(0.0, t * 0.05), period_n * 0.5);
	float w1 = cloud_grad_noise_tiled(p * 0.5 + vec2(5.2, 1.3 - t * 0.04), period_n * 0.5);
	vec2 pw = p + (vec2(w0, w1) - vec2(0.5)) * (2.0 * warp_amount);
	if (q >= 3) {
		float w2 = cloud_grad_noise_tiled(pw * 0.25 + vec2(-3.1, 8.4), period_n * 0.25);
		float w3 = cloud_grad_noise_tiled(pw * 0.25 + vec2(11.9, -2.6), period_n * 0.25);
		pw += (vec2(w2, w3) - vec2(0.5)) * (3.0 * warp_amount);
	}
	return pw;
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
		float k = (cid >= 0) ? texture(enum_lut, fog_cell_lut_uv(cid)).a : 0.0;

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
				float n = cloud_cumulus_fbm(p, 1, t, lod_px, period_n);
				float shade = mix(0.86, 1.14, n);
				col = mix(explored_color, unexplored_color, thick) * shade;
				float thin_a = explored_alpha * presence * mix(0.76, 1.10, n);
				alpha = mix(clamp(thin_a, 0.0, 1.0), 1.0, thick);
			} else {
				// q1 与 q2+ 都要 TOD，先算一次。
				vec2 map_uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));
				float lat_signed = clamp(map_uv.y * 2.0 - 1.0, -1.0, 1.0);
				EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);

				// ── 主光：夜侧切月光 ───────────────────────────────────
				// 地形/水面/植被走的都是这套（见 brdf.make_lighting_context）。
				// 雾层不跟着切，就会出现「地形有月光、云漆黑」的割裂。
				// 月在太阳对侧 → moon_dir = -sun_dir；压低仰角，让午夜仍读得出云脊。
				vec3 moon_d = -ed.sun_dir;
				moon_d.z = min(moon_d.z, 0.72);
				// 日月方向近乎相反，不做向量线性混合，避免晨昏中点归一化零向量。
				float use_day_key = step(ed.moon_strength, ed.local_day);
				vec3 key_dir = mix(normalize(moon_d), ed.sun_dir, use_day_key);
				// key_col 已含强度（昼 local_day / 夜 moon_strength），下游直接乘。
				vec3 key_col = ed.sun_col * ed.local_day + ed.moon_col * ed.moon_strength;
				float key_amt = max(ed.local_day, ed.moon_strength);

				vec2 sun_h = key_dir.xy;
				float sun_horiz = clamp(length(sun_h), 0.0, 1.0);
				vec2 sun_axis = (sun_horiz > 1e-4) ? sun_h / sun_horiz : normalize(vec2(0.62, -0.38));
				float sun_up = max(key_dir.z, 0.0);
				// z 朝上，与 earth_daylight 的 sun_dir 同一约定。抬一个下限，
				// 免得主光压到地平线以下时光照方向退化。
				vec3 L = normalize(vec3(sun_axis * max(sun_horiz, 0.001), max(sun_up, 0.10)));

				float cover = clamp(fog_amount * 1.15, 0.0, 1.0);
				int oct = (q >= 3) ? 5 : ((q >= 2) ? 4 : 3);

				// ── 形状 ───────────────────────────────────────────────
				// 域扭曲 + billow FBM 高度场。低频 octave 给大尺度覆盖起伏，
				// 高频转 billow 做花椰菜团（见 cloud_cumulus_fbm_d）。
				vec2 pw = (q >= 2) ? fog_domain_warp(p, t, period_n, q) : p;
				vec3 hd = cloud_cumulus_fbm_d(pw, oct, t, lod_px, period_n, normal_smooth);
				float h = hd.x;
				vec2 grad = hd.yz * scale; // 噪声域导数 → 世界域梯度

				// 覆盖度直接当阈值：未探索区阈值压到底 → 连成整片云甲板；过渡带
				// 阈值抬高 → 只有峰值冒得出来 → 破碎的孤立云团。迷雾边界因此是
				// 参差的云缘而不是一条渐变带。
				float thr = mix(0.74, 0.02, cover);
				float density = smoothstep(thr, thr + 0.26, h);
				// 塔高：天空遮蔽与顶部受光都吃这个。用固定窗口而不是跟着 thr 走，
				// 否则未探索区（thr 压到底）会整片饱和成"全是塔顶"。
				float top = cloud_remap(h, top_lo, top_hi);

				// ── 光照 ───────────────────────────────────────────────
				vec3 N = normalize(vec3(
					-grad * (cloud_relief * hex_world_diameter * cloud_scale), 1.0
				));
				float ndl = dot(N, L);
				// wrap diffuse。云的单次散射反照率≈1，光子在云里弹几十次才出来，
				// 背光面根本不会像固体那样掉到黑，所以 wrap 要给足。
				float diffuse = clamp((ndl + light_wrap) / (1.0 + light_wrap), 0.0, 1.0);

				// 自阴影：沿太阳水平方向取 2~3 个高度探针，量「前方比我高多少」，
				// 那就是光到达此处前要穿过的云量。这是不做 raymarch 还能拿到
				// 云团互相投影的关键；太阳越低探针越远 → 黄昏的长投影。
				float occl = 0.0;
				if (q >= 2 && shadow_reach > 0.001) {
					int taps = (q >= 3) ? 3 : 2;
					// reach 以 hex 直径为单位，换算到噪声域正好是 /cloud_scale。
					float reach = (shadow_reach / max(cloud_scale, 0.001))
						* clamp(sun_horiz / max(sun_up, 0.30), 0.35, 3.0);
					// 遮挡比较必须落在**同一频段**：探针取 3 octave，若拿它去减 4~5
					// octave 的 h，差值会被 h 独有的高频主导，出来是斑点噪声而不是
					// 方向性投影。所以参考高度也用 3 octave 重算一遍。
					float h_ref = cloud_cumulus_fbm(pw, 3, t, lod_px, period_n);
					for (int i = 0; i < 3; i++) {
						if (i >= taps) { break; }
						float f = float(i + 1) / float(taps);
						// 探针在已扭曲的域里偏移：严格说该重算扭曲，但扭曲是低频的，
						// 这点误差换掉每个探针两次噪声。
						float hk = cloud_cumulus_fbm(
							pw + sun_axis * (reach * f), 3, t, lod_px, period_n
						);
						occl += max(0.0, hk - h_ref) * (1.0 - 0.25 * f);
					}
					occl /= float(taps);
				}
				// 双指数 Beer：单指数会把阴影压成死黑，那是烟不是云。
				float light_t = cloud_beer_ms(occl * shadow_absorb);
				float powder = (q >= 2) ? cloud_powder(density, powder_weight) : 1.0;

				// 银边 / 前向散射：薄、迎光、且光能透进来的地方发亮。
				// 俯视时视线近似朝上，散射角基本就是太阳高度角。
				float silver = 0.0;
				if (q >= 2) {
					silver = cloud_phase(L.z, phase_g) * (1.0 - density) * light_t
						* smoothstep(-0.05, 0.65, ndl) * silver_gain;
				}

				// ── 两个照明体，冷暖分明 ───────────────────────────────
				// key = 太阳/月亮：暖（夜里是冷蓝月光），有方向，被自阴影衰减。
				// sky = 天光：Rayleigh 散射 → 强烈偏蓝，无方向，被天空遮蔽衰减。
				// 归一化 tint 到亮度 1，让 shadow_tint 纯粹改色相 —— 否则一调颜色
				// 就顺带把整个暗部压暗，没法独立调。
				vec3 tint_n = shadow_tint
					/ max(dot(shadow_tint, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
				vec3 sky_col = ed.amb_col * tint_n;

				// 天空遮蔽：塔顶看得见整片天空，谷底看不见。
				// **云海的层次主要来自这一项**，不是来自法线。
				float sky = mix(valley_sky, 1.0, top);
				vec3 ambient = sky_col * sky * ambient_gain;
				if (q >= 3) {
					// 天空 SH：朝上的云顶偏天顶蓝，侧面偏地平色，比常数环境光有层次。
					// 色板跟着主光走（夜侧给月色），与 brdf 的 sun_palette 同约定，
					// 否则午夜的方位补光会拿白昼太阳色去染云。
					vec3 key_palette = mix(ed.moon_col, ed.sun_col, ed.local_day);
					ambient = earth_sky_sh(sky_col, key_palette, L, key_amt, N)
						* sky * (ambient_gain * 1.15);
				}

				// 多重散射回填（GI）。云最容易被做错的地方，三个要点：
				//
				// 1) **衰减律不能用指数。** 指数是 Beer 定律，描述的是单次散射的直接
				//    透射。但云的单次散射反照率≈1，光子要弹几十次才出来，这属于
				//    **扩散输运**，衰减尾巴比指数厚得多，用有理式 1/(1+k·d) 近似。
				//    用 exp() 会把云画成不透光的石头 —— 现实里云的暗面是通透发亮的，
				//    这正是"暗部 GI 对不上现实"的来源。
				// 2) **不吃 N·L。** 邻近云体的二次照明与局部法线无关。
				//
				// 深度 = 离云顶多深 + 自阴影厚度。
				float ms_depth = (1.0 - top) + occl * shadow_absorb * 0.18;

				// 3) **颜色要随深度从主光色漂向天光色。** 水滴是 Mie 散射，几乎不分
				//    波长，所以在云里弹来弹去的光本身不会变蓝；但它随深度快速衰减，
				//    越深的地方天光（偏蓝）占的比重越大。现实中云暗面因此是冷蓝的。
				//    整条 MS 都用主光色 = 暗部一路暖灰 = 假。
				//    只换色相不换亮度：拿 key 的亮度去乘归一化后的天光色。
				float tint_t = clamp(ms_depth * shadow_tint_depth, 0.0, 1.0);
				float key_lum = dot(key_col, vec3(0.2126, 0.7152, 0.0722));
				vec3 bounce_col = mix(key_col, key_lum * tint_n, tint_t);
				vec3 bounce = bounce_col * (ms_gain / (1.0 + ms_falloff * ms_depth));

				// 次表面透射（"3S"）：光从背后穿过云体 —— 云"通透"而不是
				// "一块石膏"的另一半原因。衰减率取得比较低，让它能渗进较厚的地方，
				// 只在真正的云芯才熄灭。
				float sss = (q >= 2) ? exp(-density * 1.8) * light_t * sss_gain : 0.0;

				vec3 direct = key_col * (diffuse * light_t * powder * sun_gain + silver);
				col = cloud_albedo * (ambient + bounce + direct) + key_col * sss * 0.35;
				// 夜侧 / 晨昏地板。这两处 local_day 与 moon_strength 同时逼近 0，
				// key_col 整个塌掉，画面只剩天光撑着。地形在这里靠的是**不打折的**
				// amb_col（见 brdf.make_lighting_context），而雾层的环境光还要再乘
				// sky × ambient_gain ≈ 0.14，于是晨昏线上云比地形暗一大截。
				// 地板走 sky_col，所以补上来的是冷蓝而不是灰。白昼收窄到 1/3 —— 那时
				// 算出来的颜色远高于地板，不会把云缝的层次抹平。
				float floor_w = mix(night_floor, night_floor * 0.35, ed.local_day);
				col = max(col, cloud_albedo * sky_col * floor_w);

				// 过渡带的薄纱：厚度跟着 density 走，于是边界是破碎云团的轮廓。
				float thin_a = explored_alpha * presence * mix(0.42, 1.15, density);
				alpha = mix(clamp(thin_a, 0.0, 1.0), 1.0, thick);
			}

			out_color = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
		}
	}

	COLOR = out_color;
}
