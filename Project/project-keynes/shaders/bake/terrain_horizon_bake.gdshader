// terrain_horizon_bake.gdshader
// ─────────────────────────────────────────────────────────────────────────
// [terrain-horizon-gpu 2026-07-03] 生成期 GPU 离屏烘焙 8 方向地平线仰角。
//
// 走引擎高层 canvas_item 材质管线（非 RenderingDevice .glsl），因此 PC / 移动端
// 同一路径、由引擎为各平台运行期编译，规避 compute/预编译 SPIR-V 的跨平台坑。
//
// 逐 texel 复刻 world_ext_bake.cpp::encode_bake_horizon_tex_data 的 marching：
//   对 8 个方向各步进 steps 步，维护最大 slope² = (dh·scale)² / dist²，
//   末尾 atan(sqrt(best)) 得仰角，量化到 4-bit，nibble-pack 进 RGBA8。
// 方向顺序 E, NE, N, NW, W, SW, S, SE，与 terrain_horizon.gdshaderinc 解码约定一致。
//
// 输出：SubViewport RGBA8，HexRenderer 回读为 ImageTexture 赋给 world.terrain_horizon_tex。
// ─────────────────────────────────────────────────────────────────────────
shader_type canvas_item;
// blend_disabled：本 shader 把 8 个方向的数据打进 RGBA **全部 4 通道**（A 通道也是数据，
// 非透明度）。默认 blend_mix 会按 alpha 混合、污染打包字节，必须禁用混合让 COLOR 原样写入
// RGBA8 target。unshaded：跳过 2D 光照 pass。
render_mode blend_disabled, unshaded;

// height_tex：world.height_tex（RG8 16-bit），解码 (R*256+G)/257 == 归一化海拔 [0,1]。
// filter_nearest + 按 texel 中心采样，取值与 CPU 逐 texel 读 height_buffer 等价。
uniform sampler2D height_tex : filter_nearest, repeat_disable;
uniform vec2 tex_dims = vec2(1024.0, 512.0);   // (W, H) 像素
uniform int steps = 128;                        // marching 步数
uniform float step_px = 8.0;                    // 每步像素距离
uniform float step_growth = 0.35;               // 二次增长率；近密远疏，0=固定步长
uniform int lowpass_radius = 1;                  // 1=Horizon 专用 3x3 高斯低通
uniform float max_horizon_angle = 1.309;        // 量化上限（rad），与运行期 shader 一致
uniform float bias = 0.004;                     // 归一高程 bias，抑制自遮蔽
uniform float height_world_scale = 176.0;       // 归一高程 → world units 的夸张倍率
uniform float sea_level = 0.42;                 // horizon-only 水面接收高度
uniform float texel_x = 1.0;                    // world units / texel（x）
uniform float texel_y = 1.0;                    // world units / texel（y）
// [terrain-horizon-wrap 2026-07-03] 真正经度环绕周期（world units）。柱状地图东西连续，
// 但 height_tex 覆盖的 world_bounds 含 padding（world_bounds.size.x = wrap_period_x + 约 4.87·hex），
// 所以不能按整图像素宽 %W 环绕，必须按此周期在世界经度空间折叠，才能与运行期 wrap_map_uv 对齐、
// 接缝无缝。0 → 退化为整图宽（旧行为，仅 wrap_period_x 缺省时兜底）。
uniform float wrap_period_x = 0.0;

vec2 horizon_dir(int d) {
	// E, NE, N, NW, W, SW, S, SE（与 C++ dir_x/dir_y 顺序 1:1）
	if (d == 0) return vec2(1.0, 0.0);
	if (d == 1) return vec2(0.70710678118654752, 0.70710678118654752);
	if (d == 2) return vec2(0.0, 1.0);
	if (d == 3) return vec2(-0.70710678118654752, 0.70710678118654752);
	if (d == 4) return vec2(-1.0, 0.0);
	if (d == 5) return vec2(-0.70710678118654752, -0.70710678118654752);
	if (d == 6) return vec2(0.0, -1.0);
	return vec2(0.70710678118654752, -0.70710678118654752);
}

int wrap_column(int x, int width) {
	if (x >= 0) {
		return x % width;
	}
	int r = (-x) % width;
	return (r == 0) ? 0 : (width - r);
}

float decode_height_raw(int sx, int sy) {
	int W = int(tex_dims.x + 0.5);
	int H = int(tex_dims.y + 0.5);
	int period_cols = (wrap_period_x > 1e-6)
		? clamp(int(floor(wrap_period_x / max(texel_x, 1e-6) + 0.5)), 1, W)
		: W;
	sx = wrap_column(sx, period_cols);
	sx = clamp(sx, 0, W - 1);
	sy = clamp(sy, 0, H - 1);
	vec2 uv = (vec2(float(sx), float(sy)) + vec2(0.5)) / tex_dims;
	vec4 s = texture(height_tex, uv);
	return max((s.r * 256.0 + s.g) / 257.0, sea_level);
}

float decode_height_at(int sx, int sy) {
	if (lowpass_radius <= 0) {
		return decode_height_raw(sx, sy);
	}
	// 1-2-1 separable Gaussian, evaluated only in this derived visibility pass.
	// The authoritative eroded height texture remains unchanged for normals/rivers.
	float sum = 0.0;
	for (int oy = -1; oy <= 1; oy++) {
		float wy = (oy == 0) ? 2.0 : 1.0;
		for (int ox = -1; ox <= 1; ox++) {
			float wx = (ox == 0) ? 2.0 : 1.0;
			sum += decode_height_raw(sx + ox, sy + oy) * wx * wy;
		}
	}
	return sum * 0.0625;
}

float quant_angle(float angle) {
	float v = clamp(angle / max_horizon_angle, 0.0, 1.0);
	return floor(v * 15.0 + 0.5);   // [0, 15]
}

void fragment() {
	int W = int(tex_dims.x + 0.5);
	int H = int(tex_dims.y + 0.5);
	// ColorRect 全屏 → UV∈[0,1]，UV*dims 落在 texel 中心 (i+0.5) → floor 得整数索引 i。
	vec2 pix = UV * tex_dims;
	int x = int(floor(pix.x));
	int y = int(floor(pix.y));
	x = clamp(x, 0, W - 1);
	y = clamp(y, 0, H - 1);

	float h0 = decode_height_at(x, y);

	// 经度环绕周期（像素 / world）。wrap_period_x 缺省(0)时退化为整图宽（旧行为）。
	// period_px 通常略小于 W（≈978 vs 1024），差值即 world_bounds 的 padding。
	float period_px = (wrap_period_x > 1e-6) ? (wrap_period_x / texel_x) : tex_dims.x;

	float q[8];
	for (int d = 0; d < 8; d++) {
		vec2 dir = horizon_dir(d);
		float best_slope_sq = 0.0;
		for (int s = 1; s <= steps; s++) {
			float sf = float(s);
			float dist_px = step_px * (sf + 0.5 * step_growth * sf * (sf - 1.0));
			float sx_f = float(x) + dir.x * dist_px;
			int sy = int(floor(float(y) + dir.y * dist_px + 0.5));
			if (sy < 0 || sy >= H) {
				break;                       // y 方向不环绕，出界即停（与 C++ 一致）
			}
			// x 环绕：把目标列折回一个经度周期内的规范列（height 关于经度以 period 周期，
			// 折回列与原列同经度）。按 period_px（真实经度周期）而非整图宽 W 折叠。
			float sxw = sx_f - period_px * floor(sx_f / period_px);   // [0, period_px)
			int sx = int(floor(sxw + 0.5));
			if (sx >= W) { sx -= W; }        // period_px≈W 时的进位兜底
			if (sx < 0) { sx = 0; }
			float dh = decode_height_at(sx, sy) - h0 - bias;
			if (dh <= 0.0) {
				continue;                    // 下坡/同高不构成遮挡
			}
			// 水平距离按射线实际行进距离计算，而不是按圆柱最短经度距离折回。
			// 采样列可以 wrap；遮挡物距离不能 wrap，否则正东/正西扫线绕一圈时 dist≈0，
			// slope 会被放大到饱和，形成 ±180° 附近的异常条带阴影。
			float off_x_world = abs(dir.x * dist_px * texel_x);
			float off_y_world = abs(float(sy - y)) * texel_y;
			float wdist_sq = off_x_world * off_x_world + off_y_world * off_y_world;
			if (wdist_sq <= 1e-12) {
				continue;
			}
			float num = dh * height_world_scale;   // dh>0 → num>0
			float slope_sq = (num * num) / wdist_sq;
			if (slope_sq > best_slope_sq) {
				best_slope_sq = slope_sq;
			}
		}
		q[d] = quant_angle(atan(sqrt(best_slope_sq)));
	}

	// nibble-pack：高 4-bit / 低 4-bit 各承载一个方向；/255 精确写 8-bit UNORM。
	COLOR = vec4(
		(q[0] * 16.0 + q[1]) / 255.0,
		(q[2] * 16.0 + q[3]) / 255.0,
		(q[4] * 16.0 + q[5]) / 255.0,
		(q[6] * 16.0 + q[7]) / 255.0
	);
}
