shader_type canvas_item;
render_mode unshaded;

// 2.5D 立体地形重光照、昼夜流转、四季更替与全域穿云着色器
// (2.5D Relit Terrain Relief: Dynamic Sun, Raymarched Mountain Shadows, Four Seasons & Full-Map Interleaved Clouds)
//
// 核心特性：
// 1. 34px 欧氏距离场软边（Soft Shoreline SDF）：彻底消除陆地与海洋之间的生硬切边与亮白描边，实现浅海大陆架 -> 湿润滩涂 -> 内陆植被的丝滑柔和过渡。
// 2. 无缝涡流积云贴图（cloud_noise_tex）：彻底消除 Mobile 渲染器过程噪声的方格伪影。
// 3. 全域云海 + 高度穿插 + max Opacity + 软外边界：云层覆盖整张地图（包括无陆地的海域与海峡），在低地与海面上空飘浮并投下云影，在崇山雪峰间按海拔穿插绕行，外边界柔和消隐。

uniform sampler2D nhao_tex : filter_linear;
uniform sampler2D cloud_noise_tex : filter_linear, repeat_enable;
uniform int layer_kind = 5;
uniform float reveal_progress : hint_range(0.0, 1.0) = 1.0;
uniform float motion_scale : hint_range(0.0, 1.0) = 1.0;
uniform float uv_inset : hint_range(1.0, 1.25) = 1.05;
uniform vec3 tint_shift = vec3(1.0, 1.0, 1.0);
uniform float time_offset = 0.0;
uniform float has_nhao : hint_range(0.0, 1.0) = 1.0;
uniform float flip_x_sign = 1.0;
uniform float flip_y_sign = 1.0;

vec2 grad2_u32(ivec2 ip) {
	uint ux = uint(ip.x + 32768);
	uint uy = uint(ip.y + 32768);
	uint h = ux * 374761393u + uy * 668265263u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h ^= (h >> 16u);
	float ang = float(h & 1023u) * 0.006135923;
	return vec2(cos(ang), sin(ang));
}

float perlin_noise(vec2 p) {
	vec2 fl = floor(p);
	ivec2 i = ivec2(fl);
	vec2 f = p - fl;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n00 = dot(grad2_u32(i), f);
	float n10 = dot(grad2_u32(i + ivec2(1, 0)), f - vec2(1.0, 0.0));
	float n01 = dot(grad2_u32(i + ivec2(0, 1)), f - vec2(0.0, 1.0));
	float n11 = dot(grad2_u32(i + ivec2(1, 1)), f - vec2(1.0, 1.0));
	return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y) * 0.7071 + 0.5;
}

float uv_bounds_mask(vec2 uv) {
	return step(0.001, uv.x) * step(uv.x, 0.999) * step(0.001, uv.y) * step(uv.y, 0.999);
}

// 采样无缝预烘焙涡流积云贴图（消除一切过程噪声格子，形态自然舒展）
float sample_cumulus_cloud(vec2 uv, float t) {
	vec2 wind1 = vec2(t * 0.014, -t * 0.009);
	vec2 wind2 = vec2(t * 0.022, -t * 0.013);
	vec3 s_warp = texture(cloud_noise_tex, fract(uv * 0.75 + wind1 * 0.6)).rgb;
	vec2 warp = (s_warp.gb - 0.5) * 0.14;

	float c_main = texture(cloud_noise_tex, fract(uv * 1.12 + warp + wind1)).r;
	float c_puff = texture(cloud_noise_tex, fract(uv * 1.80 - warp * 0.7 + wind2 + vec2(0.37, 0.61))).g;
	float c_wisp = texture(cloud_noise_tex, fract(uv * 3.00 + wind2 * 1.3)).b;

	float combined = c_main * 0.54 + c_puff * 0.32 + c_wisp * 0.14;
	return smoothstep(0.49, 0.70, combined);
}

void fragment() {
	vec2 uv = (UV - 0.5) * uv_inset + 0.5;
	vec2 px = TEXTURE_PIXEL_SIZE;
	float t = (TIME + time_offset) * motion_scale;

	vec4 paper = texture(TEXTURE, clamp(uv, vec2(0.0), vec2(1.0))) * uv_bounds_mask(uv);

	if (layer_kind < 5) {
		float light = dot(paper.rgb, vec3(0.3, 0.59, 0.11));
		float green = smoothstep(0.94, 1.06, paper.g / max(paper.r, 0.01)) * (1.0 - smoothstep(0.72, 0.86, light));
		float warm = smoothstep(1.07, 1.20, paper.r / max(paper.g, 0.01));
		float ridge = smoothstep(0.75, 0.88, light) * (1.0 - green);
		float mask = 1.0;
		if (layer_kind == 0) { paper.rgb = vec3(0.10, 0.16, 0.16); paper.a *= 0.30; }
		if (layer_kind == 1) { paper.rgb = mix(vec3(0.79, 0.72, 0.53), paper.rgb, 0.20); }
		if (layer_kind == 2) mask = green;
		if (layer_kind == 3) mask = warm;
		if (layer_kind == 4) mask = ridge;
		paper.a *= mask;
		COLOR = paper;
	} else {
		// =========================================================================
		// 1. 太阳旋转轨迹（昼夜流转）与四季相位
		// =========================================================================
		float day_angle = t * 0.22 + 0.48;
		float sun_az = day_angle * 1.1 - 0.40;
		float sun_elev = sin(day_angle);
		float day_factor = smoothstep(-0.25, 0.25, sun_elev);
		float twilight_factor = exp(-pow((sun_elev - 0.05) / 0.30, 2.0));
		float night_factor = smoothstep(0.05, -0.35, sun_elev);

		vec2 sun_xy = vec2(cos(sun_az), sin(sun_az));
		vec3 L = normalize(vec3(sun_xy * 0.78, 0.62));

		float season_phase = fract(t * 0.024 + 0.10);
		float spring_w = smoothstep(0.25, 0.0, abs(season_phase - 0.0)) + smoothstep(0.25, 0.0, abs(season_phase - 1.0));
		float summer_w = smoothstep(0.25, 0.0, abs(season_phase - 0.25));
		float autumn_w = smoothstep(0.26, 0.0, abs(season_phase - 0.50));
		float winter_w = smoothstep(0.26, 0.0, abs(season_phase - 0.75));

		// =========================================================================
		// 2. 解码 34px 欧氏距离场软边 (shore_field)、三维法线 (N)、高度 (H) 与遮蔽 (AO)
		// =========================================================================
		vec4 nhao = vec4(0.5, 0.5, 0.0, 0.5);
		if (has_nhao > 0.5) {
			nhao = texture(nhao_tex, clamp(uv, vec2(0.0), vec2(1.0)));
		}
		// shore_field in [0, 1] 对应海岸线外 18px 到海岸线内 16px 的平滑欧氏距离过渡
		float shore_field = clamp(nhao.a * 2.0, 0.0, 1.0) * uv_bounds_mask(uv);
		// 陆地软边不透明度：在海岸线内侧 0..14px 之间柔和渐入，彻底压制原图外圈亮黄生硬描边
		float soft_land_alpha = smoothstep(0.46, 0.96, shore_field) * smoothstep(0.05, 0.55, paper.a);
		// 内陆过渡权重：0=岸线浅滩，1=完全进入内陆
		float inland_blend = smoothstep(0.58, 0.98, shore_field);

		float inland_occ = clamp((nhao.a - 0.50) * 2.0, 0.0, 1.0) * 0.68;
		float AO = 1.0 - inland_occ * inland_blend;

		vec2 raw_n = (nhao.rg * 2.0 - 1.0) * vec2(flip_x_sign, flip_y_sign) * inland_blend;
		vec3 N = normalize(vec3(raw_n * 1.25, 0.65));
		float H = nhao.b * uv_bounds_mask(uv) * soft_land_alpha;

		// =========================================================================
		// 3. 高山光线步进阴影 (Mountain-Only Raymarched Cast Shadows)
		// =========================================================================
		vec2 ray_step_uv = L.xy * vec2(flip_x_sign, flip_y_sign) * px * 11.0;
		float ray_rise = mix(0.058, 0.042, twilight_factor);
		float shadow_occ = 0.0;
		if (has_nhao > 0.5 && shore_field > 0.04) {
			for (int s = 1; s <= 8; s++) {
				float fs = float(s);
				vec2 sample_uv = uv + ray_step_uv * fs;
				float h_step = texture(nhao_tex, clamp(sample_uv, vec2(0.0), vec2(1.0))).b * uv_bounds_mask(sample_uv);
				float caster_h = h_step * smoothstep(0.45, 0.62, h_step);
				float diff = caster_h - (H + fs * ray_rise);
				if (diff > 0.0) {
					shadow_occ = max(shadow_occ, clamp(diff * 4.2, 0.0, 1.0));
				}
			}
		}
		float cast_shadow = smoothstep(0.02, 0.35, shadow_occ);

		// =========================================================================
		// 4. 陆地色彩、海岸软边消隐与四季演进
		// =========================================================================
		vec3 base_rgb = paper.rgb * tint_shift;
		// 将原图岸边 1~10px 的刺眼亮黄描边柔和压暗并融向浅海青绿与湿润沙岸
		vec3 coastal_tint = mix(vec3(0.18, 0.40, 0.42), vec3(0.52, 0.56, 0.44), smoothstep(0.46, 0.88, shore_field));
		base_rgb = mix(coastal_tint, base_rgb, inland_blend);

		float luma = dot(base_rgb, vec3(0.299, 0.587, 0.114));
		float river_mask = smoothstep(0.015, 0.075, paper.b - max(paper.r * 0.96, paper.g * 0.92)) * inland_blend;
		float forest_mask = smoothstep(0.018, 0.085, paper.g - max(paper.r * 0.98, paper.b)) * (1.0 - smoothstep(0.68, 0.84, luma)) * inland_blend;

		if (forest_mask > 0.01) {
			float canopy_var = texture(cloud_noise_tex, fract(uv * 3.5)).b;
			vec3 spring_foliage = vec3(0.44, 0.66, 0.33);
			vec3 autumn_foliage = mix(vec3(0.84, 0.55, 0.20), vec3(0.70, 0.26, 0.16), smoothstep(0.25, 0.78, canopy_var + H * 0.3));
			vec3 winter_foliage = vec3(0.34, 0.45, 0.37);

			base_rgb = mix(base_rgb, spring_foliage, forest_mask * spring_w * 0.38);
			base_rgb = mix(base_rgb, autumn_foliage, forest_mask * autumn_w * 0.72);
			base_rgb = mix(base_rgb, winter_foliage, forest_mask * winter_w * 0.42);
		}

		if (winter_w > 0.02) {
			float winter_snow_line = mix(0.82, 0.54, winter_w);
			float winter_snow = smoothstep(winter_snow_line - 0.06, winter_snow_line + 0.08, H + N.z * 0.05 - N.y * 0.04)
				* (1.0 - river_mask * 0.9) * winter_w;
			base_rgb = mix(base_rgb, vec3(0.93, 0.95, 0.98), winter_snow * 0.45);
		}

		// =========================================================================
		// 5. 2.5D 法线漫反射、山脊轮廓金光、河道流光与星夜聚落灯火
		// =========================================================================
		float ndotl = dot(N, L);
		float sun_slope = smoothstep(-0.15, 0.85, ndotl) * (1.0 - cast_shadow * 0.76);

		vec3 warm_sun_mult = mix(vec3(1.18, 1.12, 1.00), vec3(1.28, 0.92, 0.66), twilight_factor * 0.85);
		warm_sun_mult = mix(warm_sun_mult, vec3(0.68, 0.80, 1.05), night_factor);

		vec3 cool_shade_mult = mix(vec3(0.58, 0.64, 0.72), vec3(0.50, 0.44, 0.58), twilight_factor * 0.75);
		cool_shade_mult = mix(cool_shade_mult, vec3(0.32, 0.40, 0.56), night_factor);

		vec3 light_multiplier = mix(cool_shade_mult * AO, warm_sun_mult, sun_slope);
		vec3 lit_land = base_rgb * light_multiplier;

		float ridge_highlight = clamp(dot(raw_n, L.xy), 0.0, 1.0) * (1.0 - cast_shadow) * smoothstep(0.28, 0.75, H);
		lit_land += vec3(0.98, 0.86, 0.62) * ridge_highlight * (0.14 + twilight_factor * 0.12) * (1.0 - night_factor * 0.6);

		if (river_mask > 0.01) {
			float flow_noise = texture(cloud_noise_tex, fract(uv * 2.8 + vec2(t * 0.04, -t * 0.03))).b;
			float flow_wave = sin((uv.x * 52.0 - uv.y * 38.0) + t * 2.8 + flow_noise * 4.0);
			float flow_glint = smoothstep(0.48, 0.98, flow_wave) * river_mask;
			vec3 water_glint_col = mix(vec3(0.76, 0.93, 0.98), vec3(1.0, 0.84, 0.58), twilight_factor);
			lit_land = mix(lit_land, water_glint_col, flow_glint * 0.48);
		}

		if (night_factor > 0.05 && inland_blend > 0.35) {
			float habitability = smoothstep(0.10, 0.22, H) * (1.0 - smoothstep(0.32, 0.48, H)) * (1.0 - river_mask);
			float cluster = texture(cloud_noise_tex, fract(uv * 1.7 + vec2(0.13, 0.29))).a;
			float spark = smoothstep(0.76, 0.86, perlin_noise(uv * 64.0)) * smoothstep(0.58, 0.76, cluster);
			float twinkle = 0.72 + 0.28 * sin(t * 3.5 + uv.x * 40.0 + uv.y * 30.0);
			lit_land += vec3(1.0, 0.76, 0.34) * spark * habitability * night_factor * twinkle * 2.0;
		}

		// =========================================================================
		// 6. 舆图测绘扫描展开
		// =========================================================================
		if (reveal_progress < 0.999) {
			float contour = clamp(length(raw_n) * 0.85 + (1.0 - AO) * 1.2, 0.0, 1.0);
			float hatch = smoothstep(0.75, 0.96, sin((uv.x * 140.0 + uv.y * 140.0))) * smoothstep(0.35, 0.75, H);
			vec3 blueprint_base = mix(vec3(0.10, 0.21, 0.24), vec3(0.22, 0.34, 0.34), H);
			vec3 blueprint_ink = vec3(0.89, 0.78, 0.52);
			vec3 blueprint_col = mix(blueprint_base, blueprint_ink, clamp(contour * 0.85 + hatch * 0.28 + river_mask * 0.45, 0.0, 1.0));

			float sweep_coord = uv.x * 0.58 + (1.0 - uv.y) * 0.22 + H * 0.20;
			float sweep_t = clamp((reveal_progress * 1.32 - sweep_coord) / 0.18, 0.0, 1.0);
			float front_glow = 4.0 * sweep_t * (1.0 - sweep_t);

			lit_land = mix(blueprint_col, lit_land, sweep_t);
			lit_land = mix(lit_land, vec3(0.99, 0.88, 0.56), front_glow * 0.58);
		}

		// =========================================================================
		// 7. 海岸外部大陆架浅海柔边、太阳投射长影与拍岸浪花
		// =========================================================================
		vec2 sun_sea_ofs = -L.xy * vec2(flip_x_sign, flip_y_sign) * px * mix(12.0, 6.0, day_factor);
		vec2 uv_sh = uv + sun_sea_ofs;
		float sh_shore = clamp(texture(nhao_tex, clamp(uv_sh, vec2(0.0), vec2(1.0))).a * 2.0, 0.0, 1.0) * uv_bounds_mask(uv_sh);
		float drop_shadow = max(smoothstep(0.35, 0.85, sh_shore) * 0.55, cast_shadow * 0.70) * (1.0 - soft_land_alpha);

		// 18px 宽广平滑的大陆架浅海绿松石过渡与拍岸涟漪
		float coast_shelf = smoothstep(0.02, 0.58, shore_field) * (1.0 - soft_land_alpha * 0.85);
		float wave_warp = (texture(cloud_noise_tex, fract(uv * 2.4 + vec2(t * 0.03, -t * 0.02))).b - 0.5) * 0.38;
		float dist_metric = clamp(1.0 - shore_field * 1.4, 0.0, 1.0);
		float ripple_phase = dist_metric * 3.2 - t * 0.52 + wave_warp;
		float ripple_rings = smoothstep(0.74, 0.96, sin(ripple_phase * 6.2831853))
			* smoothstep(0.05, 0.25, shore_field)
			* (1.0 - smoothstep(0.45, 0.75, shore_field));

		vec3 sea_fx_col = vec3(0.015, 0.04, 0.055);
		float sea_fx_alpha = drop_shadow * 0.46;

		float shelf_alpha = coast_shelf * 0.54 * (1.0 - drop_shadow * 0.45);
		vec3 shelf_col = mix(vec3(0.11, 0.28, 0.31), vec3(0.24, 0.48, 0.47), smoothstep(0.05, 0.55, shore_field));
		sea_fx_col = mix(sea_fx_col, shelf_col, shelf_alpha / max(sea_fx_alpha + shelf_alpha, 0.001));
		sea_fx_alpha = clamp(sea_fx_alpha + shelf_alpha * 0.78, 0.0, 1.0);

		float ripple_alpha = ripple_rings * 0.42 * (1.0 - drop_shadow * 0.45);
		sea_fx_col = mix(sea_fx_col, vec3(0.84, 0.82, 0.70), ripple_alpha / max(sea_fx_alpha + ripple_alpha, 0.001));
		sea_fx_alpha = clamp(sea_fx_alpha + ripple_alpha, 0.0, 1.0);

		// =========================================================================
		// 8. 全域覆盖 + 地形高度穿插 + 软外边界的体积云层 (Full-Map Clouds with max Opacity)
		// =========================================================================
		vec2 centered_uv = (UV - 0.5) * 2.0;
		float radial_fade = 1.0 - smoothstep(0.56, 0.96, length(centered_uv * vec2(0.95, 0.92)));
		vec2 box_margin = min(UV, 1.0 - UV);
		float rect_fade = smoothstep(0.015, 0.15, min(box_margin.x, box_margin.y));
		float outer_boundary_fade = radial_fade * rect_fade * smoothstep(0.0, 0.35, reveal_progress);

		float cloud_alt = 0.50;
		float cloud_d = sample_cumulus_cloud(uv, t);

		// 云层在低海拔陆地与海面上投下移动云影
		vec2 cloud_sh_uv = uv + L.xy * vec2(flip_x_sign, flip_y_sign) * max(cloud_alt - H, 0.0) * 0.085;
		float cloud_sh_d = sample_cumulus_cloud(cloud_sh_uv, t) * smoothstep(cloud_alt + 0.04, cloud_alt - 0.12, H) * outer_boundary_fade;
		lit_land *= 1.0 - cloud_sh_d * 0.34 * day_factor;

		float sea_cloud_sh = cloud_sh_d * (1.0 - soft_land_alpha) * 0.28 * day_factor;
		sea_fx_col = mix(sea_fx_col, vec3(0.01, 0.025, 0.035), sea_cloud_sh / max(sea_fx_alpha + sea_cloud_sh, 0.001));
		sea_fx_alpha = max(sea_fx_alpha, sea_cloud_sh);

		// 地形高度穿插：海洋 (H = 0) 与低海拔平原上空完整显示云朵，崇山雪峰 (H > 0.65) 破云而出
		float height_interleave = smoothstep(0.66, 0.42, H);
		float cloud_alpha = cloud_d * height_interleave * outer_boundary_fade * 0.82;

		float surface_alpha = max(soft_land_alpha, sea_fx_alpha);
		float land_weight = soft_land_alpha / max(surface_alpha, 0.0001);
		vec3 surface_rgb = mix(sea_fx_col, lit_land, clamp(land_weight, 0.0, 1.0));

		float cloud_lit_s = sample_cumulus_cloud(uv - L.xy * vec2(flip_x_sign, flip_y_sign) * 0.014, t);
		float cloud_self_light = clamp((cloud_d - cloud_lit_s) * 2.2 + 0.66, 0.0, 1.0);
		vec3 cloud_top = mix(vec3(0.98, 0.96, 0.92), vec3(1.0, 0.82, 0.62), twilight_factor * 0.72);
		cloud_top = mix(cloud_top, vec3(0.58, 0.70, 0.88), night_factor);
		vec3 cloud_bot = mix(vec3(0.66, 0.74, 0.80), vec3(0.48, 0.40, 0.52), twilight_factor * 0.72);
		cloud_bot = mix(cloud_bot, vec3(0.24, 0.33, 0.48), night_factor);
		vec3 cloud_rgb = mix(cloud_bot, cloud_top, cloud_self_light);

		float final_alpha = max(surface_alpha, cloud_alpha);
		float sum_weight = surface_alpha * (1.0 - cloud_alpha) + cloud_alpha;
		vec3 final_rgb = (surface_rgb * surface_alpha * (1.0 - cloud_alpha) + cloud_rgb * cloud_alpha) / max(sum_weight, 0.0001);

		COLOR = vec4(clamp(final_rgb, vec3(0.0), vec3(1.0)), clamp(final_alpha, 0.0, 1.0));
	}
}
