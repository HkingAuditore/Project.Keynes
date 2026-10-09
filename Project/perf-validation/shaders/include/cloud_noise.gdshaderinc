// cloud_noise.gdshaderinc
// 云体噪声原语的唯一真源。
//
// 原先只存在于 weather_overlay.gdshader 内部；视野迷雾层（fog_of_war.gdshader）
// 也要画云，两份实现会随时间漂移，因此抽到这里共用。
//
// 全部是解析梯度噪声（Perlin-like，quintic 插值），无任何纹理噪声依赖 ——
// 调用方不需要绑定 noise_tex。
//
// 命名保持 cloud_ 前缀不变，weather_overlay 的既有调用点无需改写。

#ifndef PK_CLOUD_NOISE_INC
#define PK_CLOUD_NOISE_INC

vec2 cloud_hash22(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453123);
}

// Perlin-like 梯度噪声，quintic 插值 → 一阶导连续，放大后不出现方格棱。
float cloud_grad_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 ga = -1.0 + 2.0 * cloud_hash22(i + vec2(0.0, 0.0));
	vec2 gb = -1.0 + 2.0 * cloud_hash22(i + vec2(1.0, 0.0));
	vec2 gc = -1.0 + 2.0 * cloud_hash22(i + vec2(0.0, 1.0));
	vec2 gd = -1.0 + 2.0 * cloud_hash22(i + vec2(1.0, 1.0));
	float va = dot(ga, f - vec2(0.0, 0.0));
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float n = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
	return 0.5 + 0.5 * n;
}

// 旋转去相关 FBM（标准云体）。各 octave 间旋转 → 消除网格对齐的块状感。
float cloud_fbm(vec2 p, int octaves) {
	mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		sum += cloud_grad_noise(p) * amp;
		p = m * p;
		amp *= 0.5;
	}
	return sum;
}

// 带时间演化的 FBM：每 octave 旋转后加不同方向的时间漂移 → 云内部翻腾而非死板平移。
// 输出已归一化到 [0,1]。
float cloud_fbm_evolve(vec2 p, int octaves, float t) {
	mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	mat2 tm = mat2(vec2(0.76, 0.64), vec2(-0.64, 0.76));
	float sum = 0.0;
	float norm = 0.0;
	float amp = 0.5;
	vec2 sh = vec2(t * 0.17, -t * 0.13);
	vec2 wobble = vec2(sin(t * 0.23), cos(t * 0.19)) * 0.32;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		float fi = float(i);
		sum += cloud_grad_noise(p + sh + wobble * (0.55 + fi * 0.18)) * amp;
		norm += amp;
		p = m * p;
		sh = tm * sh * 0.62 + vec2(t * 0.015, -t * 0.011);
		wobble = tm * wobble;
		amp *= 0.5;
	}
	return clamp(sum / max(norm, 0.001), 0.0, 1.0);
}

// ── 可平铺 + 解析导数版（云海高度场用）──────────────────────────────
//
// 与上面几个函数的两点关键差别：
//
// 1) **x 方向可平铺。** 地图东西向无限滚动，采样点会被折回一个环绕周期内。
//    普通噪声在周期两端对不上，接缝处就是一条肉眼可见的竖线。这里把晶格的 x
//    坐标对 period_x 取模，于是噪声本身以 period_x 为周期。
//    调用方必须保证 period_x 是**整数**格数（见 fog_tileable_scale）。
//    period_x < 1 表示不环绕。
//
// 2) **octave 之间不旋转。** 旋转会破坏周期性，所以只能轴对齐地倍频 + 每层加
//    常量偏移。代价是可能出现轻微的网格走向，用域扭曲补偿。

vec3 cloud_grad_noise_tiled_d(vec2 p, float period_x) {
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
	vec2 ga = -1.0 + 2.0 * cloud_hash22(vec2(x0, i.y));
	vec2 gb = -1.0 + 2.0 * cloud_hash22(vec2(x1, i.y));
	vec2 gc = -1.0 + 2.0 * cloud_hash22(vec2(x0, i.y + 1.0));
	vec2 gd = -1.0 + 2.0 * cloud_hash22(vec2(x1, i.y + 1.0));
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float k1 = vb - va;
	float k2 = vc - va;
	float k3 = va - vb - vc + vd;
	float n = va + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
	vec2 dn = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
		+ du * vec2(k1 + k3 * u.y, k2 + k3 * u.x);
	return vec3(0.5 + 0.5 * n, 0.5 * dn);
}

// 只要值的版本。域扭曲与自阴影探针每像素要调十几次，走 _d 会白算一整套梯度。
float cloud_grad_noise_tiled(vec2 p, float period_x) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_x >= 1.0) {
		x0 = mod(x0, period_x);
		x1 = mod(x1, period_x);
	}
	vec2 ga = -1.0 + 2.0 * cloud_hash22(vec2(x0, i.y));
	vec2 gb = -1.0 + 2.0 * cloud_hash22(vec2(x1, i.y));
	vec2 gc = -1.0 + 2.0 * cloud_hash22(vec2(x0, i.y + 1.0));
	vec2 gd = -1.0 + 2.0 * cloud_hash22(vec2(x1, i.y + 1.0));
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float n = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
	return 0.5 + 0.5 * n;
}

// 单个 octave 的「蓬松化」：billow = |2n-1| 的平滑版。
//
// 这是积云形状的来源。普通 FBM 的等值线是各向同性的糊团，出来是烟雾／大理石纹，
// 怎么打光都不像云。|2n-1| 在噪声极值处取到圆润的最大值、在 n=0.5 处形成折谷，
// 于是高处是一团团圆头（花椰菜），低处是尖锐的缝 —— 正是从上方看积云的样子。
// 用 sqrt(s²+ε) 而不是 abs() 是为了保住导数连续，否则谷底会出现一条条黑线。
//
// 返回 vec2(value, d(value)/ds)，调用方自己乘 ds/dp。
vec2 cloud_billow(float n01) {
	float s = n01 * 2.0 - 1.0;
	float ab = sqrt(s * s + 0.015);
	// 1.6 是把 |s| 的均值拉回与 n01 相当，免得混合时整体亮度跳变。
	return vec2(ab * 1.6, 1.6 * 2.0 * s / ab);
}

// 云海高度场：可平铺 + 蓬松 + 时间演化 + LOD 截断 + 解析导数的 FBM。
//
// lod_px = 一个屏幕像素在噪声域里跨越的距离（= fwidth(world) × 域缩放）。
// 缩小地图时高频 octave 的特征尺寸会掉到像素以下，直接采样等于对噪声做点采样，
// 屏幕上就是一片沙砾状的闪烁噪点。这里按 Nyquist 把跨不过一个像素的 octave
// 平滑淡出，并同步缩小归一化分母。
//
// 低频 octave 保持普通噪声（负责大尺度覆盖起伏），高频才转蓬松（负责花椰菜团）——
// 全部用 billow 会得到一层过于均匀的泡沫。
//
// ── grad_falloff：为什么导数必须额外衰减 ──────────────────────────
//
// FBM 第 i 层贡献 amp_i·noise(freq_i·p)，斜率是 amp_i·freq_i·dn。标准参数下
// amp = 0.5^(i+1)、freq = 2^i，**amp·freq 是常数** —— 每个 octave 对梯度的贡献
// 一模一样，于是梯度被最高频主导，本质上就是白噪声。直接拿它当法线，云会变成
// 一团揉皱的锡纸：满屏硬边高光，暗面断崖式掉黑。
//
// grad_falloff 给高频再乘一个几何衰减（0.5 = 每高一个 octave 斜率贡献减半），
// 于是法线取自「平滑后」的曲面：大形状决定明暗，细节只做轻微扰动。
// 返回的导数因此**不是** value 的真实梯度 —— 这是刻意的，着色要的就是平滑法线。
//
// 返回 vec3(value01, d/dp.x, d/dp.y)。
vec3 cloud_cumulus_fbm_d(
	vec2 p, int octaves, float t, float lod_px, float period_x, float grad_falloff
) {
	float sum = 0.0;
	float norm = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	float gd = 1.0;
	vec2 dsum = vec2(0.0);
	vec2 sh = vec2(t * 0.17, -t * 0.13);
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) { break; }
		float fade = 1.0 - smoothstep(0.30, 0.65, lod_px * freq);
		if (fade <= 0.002) { break; }
		float w = amp * fade;
		vec2 off = vec2(float(i) * 21.7, float(i) * -13.9);
		vec3 nd = cloud_grad_noise_tiled_d(p * freq + sh + off, period_x * freq);
		float bw = clamp(float(i) * 0.45 - 0.15, 0.0, 1.0);
		vec2 bl = cloud_billow(nd.x);
		sum += mix(nd.x, bl.x, bw) * w;
		dsum += mix(nd.yz, nd.yz * bl.y, bw) * (freq * w * gd);
		norm += w;
		freq *= 2.0;
		gd *= grad_falloff;
		sh = sh * 0.62 + vec2(t * 0.015, -t * 0.011);
		amp *= 0.5;
	}
	// 全部 octave 都被 LOD 砍掉时（极端缩小），场应当收敛到均值而不是 0，
	// 否则整层会突然跳成另一种颜色。
	if (norm <= 0.0001) {
		return vec3(0.45, 0.0, 0.0);
	}
	float inv = 1.0 / norm;
	return vec3(clamp(sum * inv, 0.0, 1.0), dsum * inv);
}

// 只要高度、不要法线的版本（自阴影探针用）。
float cloud_cumulus_fbm(vec2 p, int octaves, float t, float lod_px, float period_x) {
	float sum = 0.0;
	float norm = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	vec2 sh = vec2(t * 0.17, -t * 0.13);
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) { break; }
		float fade = 1.0 - smoothstep(0.30, 0.65, lod_px * freq);
		if (fade <= 0.002) { break; }
		float w = amp * fade;
		vec2 off = vec2(float(i) * 21.7, float(i) * -13.9);
		float n = cloud_grad_noise_tiled(p * freq + sh + off, period_x * freq);
		float bw = clamp(float(i) * 0.45 - 0.15, 0.0, 1.0);
		sum += mix(n, cloud_billow(n).x, bw) * w;
		norm += w;
		freq *= 2.0;
		sh = sh * 0.62 + vec2(t * 0.015, -t * 0.011);
		amp *= 0.5;
	}
	if (norm <= 0.0001) {
		return 0.45;
	}
	return clamp(sum / norm, 0.0, 1.0);
}

#endif
