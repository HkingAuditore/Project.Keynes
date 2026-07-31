// terrain_horizon.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 8-direction baked heightfield horizon. The texture is RGBA8, with two 4-bit
// horizon-angle samples packed into each byte: E/NE, N/NW, W/SW, S/SE.
//
// [terrain-gi 2026-07-31] 同一张图现在派生三个量，共用同一次 4-tap 采样：
//   direct_visibility ：按太阳方位插值的直射光可见度（原有行为，公式逐字不变）
//   sky_visibility    ：cosine-weighted 天空可见度 V_sky（档 0 AO）
//   bent_normal       ：平均可见方向，给环境光定向（档 1）
// 纹理采样次数为零增量：解满 8 个 nibble 是纯 ALU，原本只解 2 个。
//
// V_sky 推导（详见 docs/cpp-dots-runtime/terrain-gi-bake.md）：
//   设仰角 θ 自水平面 0 到天顶 π/2，天顶角 z = π/2 - θ，则单个方位扇区内遮挡
//   仰角 h 以上的 cosine-weighted 可见部分为
//       ∫[z=0..π/2-h] cos(z)·sin(z) dz = ½·cos²(h)
//   半球归一化因子 ∫cos(z)dω = π，8 个扇区各占 Δφ = π/4，故
//       V_sky = Σ_d (π/4)·½·cos²(h_d) / π = (1/8)·Σ_d cos²(h_d)
//   即 HBAO/GTAO 的解析形式。h_d 只有 16 个离散取值，全部经 gi_horizon_lut 查表，
//   运行期不出现任何三角函数调用。
//
// bent_normal 推导：第 d 扇区可见锥自 h_d 张到 π/2，质心仰角取中点 m_d = (h_d+π/2)/2，
//   扇区权重即其可见度 cos²(h_d)：
//       bent = normalize( Σ_d cos²(h_d)·vec3(DIR_d.xy·cos(m_d), sin(m_d)) )
//
// gi_horizon_lut[n] = vec3(cos²(h_n), cos(m_n), sin(m_n))，h_n = n/15·max_angle。
// 由 HexRenderer 按 terrain_horizon_max_angle 预计算推送（见 _push_gi_horizon_lut）。
// gi_lut_bound=false 时全部 GI 派生量退化为中性（V_sky=1、bent=几何法线），
// 视觉与接入 GI 之前完全一致，因此旧材质/未更新的 renderer 不会变黑。
// ─────────────────────────────────────────────────────────────────────────

const float TERRAIN_HORIZON_TAU = 6.2831853;
const float TERRAIN_HORIZON_OCTANT = 0.78539816;
const float GI_INV_SQRT2 = 0.70710678;

// 方位顺序必须与 visual_tile_horizon_trace.glsl 的 DIRECTIONS 以及 C++
// encode_bake_horizon_tex_data 完全一致：E, NE, N, NW, W, SW, S, SE。
const vec2 GI_HORIZON_DIRECTIONS[8] = vec2[8](
	vec2(1.0, 0.0), vec2(GI_INV_SQRT2, GI_INV_SQRT2),
	vec2(0.0, 1.0), vec2(-GI_INV_SQRT2, GI_INV_SQRT2),
	vec2(-1.0, 0.0), vec2(-GI_INV_SQRT2, -GI_INV_SQRT2),
	vec2(0.0, -1.0), vec2(GI_INV_SQRT2, -GI_INV_SQRT2)
);

struct TerrainHorizonSample {
	float direct_visibility;  // 直射光可见度 [0,1]，1=完全受光
	float sky_visibility;     // 天空可见度 V_sky [0,1]，1=完全开阔
	vec3 bent_normal;         // 平均可见方向，+z 为天顶
	vec4 nearest_packed;      // 最近邻 texel 的原始 packed，供 GI occluder argmax
	bool has_data;            // horizon 已绑定；false 时上面三个量为中性值
};

float horizon_unpack_byte(vec4 packed, int channel_index) {
	if (channel_index == 0) return floor(packed.r * 255.0 + 0.5);
	if (channel_index == 1) return floor(packed.g * 255.0 + 0.5);
	if (channel_index == 2) return floor(packed.b * 255.0 + 0.5);
	return floor(packed.a * 255.0 + 0.5);
}

float horizon_unpack_nibble(vec4 packed, int dir_index) {
	int ch = dir_index / 2;
	float byte_v = horizon_unpack_byte(packed, ch);
	float hi = floor(byte_v / 16.0);
	float lo = byte_v - hi * 16.0;
	return ((dir_index % 2) == 0) ? hi : lo;
}

// 向量化解包：4 条 ALU 拿到全部 8 个 nibble 索引，顺序即 GI_HORIZON_DIRECTIONS 的顺序。
void horizon_unpack_all(vec4 packed, out int nibbles[8]) {
	vec4 bytes = floor(packed * 255.0 + 0.5);
	vec4 hi = floor(bytes * 0.0625);
	vec4 lo = bytes - hi * 16.0;
	nibbles[0] = int(hi.r); nibbles[1] = int(lo.r);
	nibbles[2] = int(hi.g); nibbles[3] = int(lo.g);
	nibbles[4] = int(hi.b); nibbles[5] = int(lo.b);
	nibbles[6] = int(hi.a); nibbles[7] = int(lo.a);
}

float horizon_angle_by_index(vec4 packed, int dir_index) {
	int idx = dir_index;
	if (idx < 0) idx += 8;
	if (idx >= 8) idx -= 8;
	return (horizon_unpack_nibble(packed, idx) / 15.0) * terrain_horizon_max_angle;
}

float horizon_angle_from_packed(vec4 packed, float sector) {
	int i0 = int(floor(sector));
	float t = fract(sector);
	float h0 = horizon_angle_by_index(packed, i0);
	float h1 = horizon_angle_by_index(packed, i0 + 1);
	return mix(h0, h1, t);
}

// 单个 texel 的天空可见度 (1/8)Σcos²(h_d) 与未归一化 bent normal。两者共用同一次
// nibble 解包与同一组查表：cos²(h_d) 既是 V_sky 的被加项，也是 bent 的扇区权重。
// 分开算会把 8 次解包做两遍，而它们本来就是同一个循环的两个累加器。
void horizon_gi_from_packed(vec4 packed, out float visibility, out vec3 bent) {
	int nibbles[8];
	horizon_unpack_all(packed, nibbles);
	float sum = 0.0;
	bent = vec3(0.0);
	for (int d = 0; d < 8; d++) {
		vec3 entry = gi_horizon_lut[nibbles[d]];
		sum += entry.x;
		bent += entry.x * vec3(GI_HORIZON_DIRECTIONS[d] * entry.y, entry.z);
	}
	visibility = clamp(sum * 0.125, 0.0, 1.0);
}

// 只要 V_sky 的 caller（调试视图等）。
float horizon_sky_visibility_from_packed(vec4 packed) {
	float v;
	vec3 unused_bent;
	horizon_gi_from_packed(packed, v, unused_bent);
	return v;
}

// ─── 统一 4-tap 采样 ─────────────────────────────────────────────────────
// Packed nibbles cannot be hardware-linearly filtered: filtering bytes before unpacking
// creates invalid high/low nibble blends and visible contour/moire artifacts. Use NEAREST
// sampler and manually bilinear-filter decoded quantities instead.
//
// direct 在解码后做手动 bilinear；sky 与 bent 共用同一组按 gi_ao_smoothing 向箱式
// 低通靠拢的权重（见下方 GI 段落）。
// nearest_packed 取最近邻的原始字节：档 2 的遮挡源 argmax 必须与烘焙期同源，
// 绝不能用滤波结果，否则 4 个 tap 的 argmax 方向可能互不相同。
TerrainHorizonSample sample_terrain_horizon(vec2 uv, vec3 light_dir) {
	TerrainHorizonSample result;
	result.direct_visibility = 1.0;
	result.sky_visibility = 1.0;
	result.bent_normal = vec3(0.0, 0.0, 1.0);
	result.nearest_packed = vec4(0.0);
	result.has_data = false;

	if (!terrain_horizon_tex_bound) {
		return result;
	}

	#ifdef MAP_VISUAL_TILED
	vec2 dims = visual_logical_resolution;
	vec2 world_p = world_origin + uv * world_size;
	if (wrap_period_x > 0.0001) {
		world_p.x = wrap_origin_x + mod(world_p.x - wrap_origin_x, wrap_period_x);
	}
	vec2 domain_uv = clamp((world_p - visual_domain_origin) /
		max(visual_domain_size, vec2(0.0001)), vec2(0.0), vec2(1.0));
	vec2 p = domain_uv * dims - vec2(0.5);
	#else
	vec2 dims = vec2(textureSize(terrain_horizon_tex, 0));
	vec2 p = wrap_map_uv(uv) * dims - vec2(0.5);
	#endif
	vec2 b = floor(p);
	vec2 f = fract(p);
	vec2 inv_dims = 1.0 / max(dims, vec2(1.0));

	#ifdef MAP_VISUAL_TILED
	vec2 uv00 = (visual_domain_origin + (b + vec2(0.5, 0.5)) * inv_dims *
		visual_domain_size - world_origin) / world_size;
	vec2 uv10 = (visual_domain_origin + (b + vec2(1.5, 0.5)) * inv_dims *
		visual_domain_size - world_origin) / world_size;
	vec2 uv01 = (visual_domain_origin + (b + vec2(0.5, 1.5)) * inv_dims *
		visual_domain_size - world_origin) / world_size;
	vec2 uv11 = (visual_domain_origin + (b + vec2(1.5, 1.5)) * inv_dims *
		visual_domain_size - world_origin) / world_size;
	#else
	vec2 uv00 = wrap_map_uv((b + vec2(0.5, 0.5)) * inv_dims);
	vec2 uv10 = wrap_map_uv((b + vec2(1.5, 0.5)) * inv_dims);
	vec2 uv01 = wrap_map_uv((b + vec2(0.5, 1.5)) * inv_dims);
	vec2 uv11 = wrap_map_uv((b + vec2(1.5, 1.5)) * inv_dims);
	#endif

	vec4 p00 = visual_sample_horizon(uv00);
	vec4 p10 = visual_sample_horizon(uv10);
	vec4 p01 = visual_sample_horizon(uv01);
	vec4 p11 = visual_sample_horizon(uv11);
	result.has_data = true;

	// 最近邻 texel：step 是选择而非插值，packed 字节保持原值。
	float sx = step(0.5, f.x);
	float sy = step(0.5, f.y);
	result.nearest_packed = mix(mix(p00, p10, sx), mix(p01, p11, sx), sy);

	// ── 直射可见度（沿用原公式，逐字不变）────────────────────────────────
	vec2 sun_xy = light_dir.xy;
	float sun_h_len = length(sun_xy);
	if (sun_h_len > 1e-4) {
		sun_xy /= sun_h_len;
		float angle = atan(sun_xy.y, sun_xy.x);
		if (angle < 0.0) {
			angle += TERRAIN_HORIZON_TAU;
		}
		float sector = angle / TERRAIN_HORIZON_OCTANT;
		float h00 = horizon_angle_from_packed(p00, sector);
		float h10 = horizon_angle_from_packed(p10, sector);
		float h01 = horizon_angle_from_packed(p01, sector);
		float h11 = horizon_angle_from_packed(p11, sector);
		float horizon_angle = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
		float sun_elev = atan(max(light_dir.z, 0.0) / max(sun_h_len, 1e-4));
		float shadow = smoothstep(sun_elev - terrain_horizon_softness,
				sun_elev + terrain_horizon_softness, horizon_angle);
		// Do not hard-skip below the horizon: the day/night terminator is soft, so horizon
		// shadow must fade with sun height too. A hard z<=0 return creates a visible seam.
		float horizon_day_w = smoothstep(-0.14, 0.18, light_dir.z);
		result.direct_visibility =
			clamp(1.0 - shadow * terrain_horizon_strength * horizon_day_w, 0.0, 1.0);
	}

	// ── 天空可见度与 bent normal ───────────────────────────────────────────
	if (gi_lut_bound && gi_ao_strength > 0.0) {
		float v00; vec3 b00; horizon_gi_from_packed(p00, v00, b00);
		float v10; vec3 b10; horizon_gi_from_packed(p10, v10, b10);
		float v01; vec3 b01; horizon_gi_from_packed(p01, v01, b01);
		float v11; vec3 b11; horizon_gi_from_packed(p11, v11, b11);

		// AO 是低频量，而它的来源——视觉高度场——含有逐 texel 的高频残差。按原样做
		// 双线性会把这些残差原封不动搬进 V_sky，与地表细节纹理叠加后读作"很碎"。
		// 把权重从双线性向等权 1/4 靠拢，等价于在 2×2 texel 上做箱式低通：采样数不变，
		// 却滤掉了 AO 里本就不该有的最高频成分。gi_ao_smoothing=0 精确退回双线性。
		vec2 fw = mix(f, vec2(0.5), gi_ao_smoothing);
		float w00 = (1.0 - fw.x) * (1.0 - fw.y);
		float w10 = fw.x * (1.0 - fw.y);
		float w01 = (1.0 - fw.x) * fw.y;
		float w11 = fw.x * fw.y;

		float v = v00 * w00 + v10 * w10 + v01 * w01 + v11 * w11;
		// 先按强度插值到中性，再整体抬到 gi_ao_floor 之上。地形 AO 描述的是"看得到多少
		// 天空"，而真实峡谷底部仍然有来自岩壁的多次散射，几何遮蔽算出的 0 并不是它应有
		// 的亮度；没有下限时封闭地形会被压成死黑。gi_ao_strength=0 时 v_scaled 恒为 1，
		// 结果精确等于 1.0，与接入 GI 之前逐位一致。
		float v_scaled = mix(1.0, v, gi_ao_strength);
		result.sky_visibility = clamp(mix(gi_ao_floor, 1.0, v_scaled), 0.0, 1.0);

		// bent normal 与 V_sky 共用同一组权重。旧实现只取最近邻 texel，块状边界会在
		// 环境光方向上跳变；现在滤波是顺带的，因为四个 tap 的 bent 已经算出来了。
		// 这里返回纯几何量，与表面法线的混合由 BRDF 侧按 gi_bent_strength 完成，
		// 避免同一个强度参数在两处各混一次。
		if (gi_bent_strength > 0.0) {
			vec3 bent = b00 * w00 + b10 * w10 + b01 * w01 + b11 * w11;
			if (dot(bent, bent) > 1e-6) {
				result.bent_normal = normalize(bent);
			}
		}
	}
	return result;
}

// ─── 兼容入口 ───────────────────────────────────────────────────────────
// 只需要直射遮蔽的 caller（water debug view 等）继续用这个；主 BRDF 路径应改用
// sample_terrain_horizon 一次拿全三个量，避免同一 uv 采两遍 horizon。
float terrain_horizon_direct_visibility(vec2 uv, vec3 light_dir) {
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID)
	return 1.0;
#else
	if (!terrain_horizon_tex_bound || visual_quality < 1 || terrain_horizon_strength <= 0.0) {
		return 1.0;
	}
	return sample_terrain_horizon(uv, light_dir).direct_visibility;
#endif
}

// 档位门控后的完整入口。直射遮蔽在移动端 LOW/MID 与 visual_quality<1 时关闭（与旧行为一致），
// 但 AO 比直射遮蔽便宜——它不需要按太阳方位插值，也不参与 cast shadow 叠层——所以移动端 MID
// 仍然保留 AO 与 bent normal，只有 LOW 档整体退化为中性。
TerrainHorizonSample terrain_horizon_evaluate(vec2 uv, vec3 light_dir) {
#if defined(MOBILE_QUALITY_LOW)
	TerrainHorizonSample neutral;
	neutral.direct_visibility = 1.0;
	neutral.sky_visibility = 1.0;
	neutral.bent_normal = vec3(0.0, 0.0, 1.0);
	neutral.nearest_packed = vec4(0.0);
	neutral.has_data = false;
	return neutral;
#else
	TerrainHorizonSample s = sample_terrain_horizon(uv, light_dir);
	#if defined(MOBILE_QUALITY_MID)
	s.direct_visibility = 1.0;
	#else
	if (visual_quality < 1 || terrain_horizon_strength <= 0.0) {
		s.direct_visibility = 1.0;
	}
	#endif
	return s;
#endif
}

// 倾斜法线修正：完整 GTAO 内积分需要在每个扇区做法线投影，代价偏高。这里用 bent normal
// 与几何法线的夹角做一次余弦加权近似，gi_normal_floor 防止陡坡被过度压暗。
//
// 这是**二阶修正，必须保持轻微**。方向性本身已经由 sky_sh_ambient_brdf 沿 bent normal
// 查天光完成了；这里再乘一次同源的方向项属于重复计入。更要命的是传进来的几何法线含有
// 逐 texel 的细节与微噪扰动，而 bent normal 是 4-bit × 8 扇区的量化量，两者点乘会在像素
// 频率上剧烈摆动——floor 定得低（早期 0.55）时这一项单独就能制造近 45% 的亮度噪声，
// 是"很碎"的主因。默认把 floor 抬到 0.85，只留一点陡坡的层次。
float terrain_horizon_apply_normal(float sky_visibility, vec3 geometric_normal, vec3 bent_normal) {
	if (gi_normal_floor >= 1.0) {
		return clamp(sky_visibility, 0.0, 1.0);
	}
	float align = clamp(dot(normalize(geometric_normal), normalize(bent_normal)), 0.0, 1.0);
	return clamp(sky_visibility * mix(gi_normal_floor, 1.0, align), 0.0, 1.0);
}
