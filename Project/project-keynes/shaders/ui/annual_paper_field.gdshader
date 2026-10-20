shader_type canvas_item;
render_mode unshaded;

// 一张手工抄的纸：帘纹、纤维、纸浆厚薄、陈化斑、颗粒，以及左右两道撕口。
//
// 撕边有两个来源，靠 has_mask 切换：
//
// has_mask = 1（默认）——轮廓来自 assets/ui/annual_chronicle/paper_tear_mask.png。
//   那是从一张真实手撕纸抠出来的 alpha 蒙版，RGB 不是颜色而是数据：
//   A 硬轮廓、R 纸内侧到撕口的欧氏距离（已除以 mask_near_px）、G 纸外侧距离、
//   B 备用。轮廓只有一个权威来源，纸、投影、页眉遮罩共用同一张图。
//
// has_mask = 0 ——回退到程序化撕裂：纸层左右各比版面宽 tear_pad，着色器在 UV 上
//   算出一条抖动的边界，边界外 alpha 归零，桌面从缺口里透出来。三条尺度叠成
//   （慢的撕口走向、中的锯齿、逐像素的毛刺）。
//
// 两条路径并存是我们故意留的：蒙版加载失败或需要临时对比时，改一个 uniform 就能回去。

uniform vec4 paper_light : source_color = vec4(0.972, 0.938, 0.856, 1.0);
uniform vec4 paper_deep : source_color = vec4(0.900, 0.838, 0.708, 1.0);
uniform vec4 fibre_tint : source_color = vec4(1.0, 0.988, 0.962, 1.0);

uniform float mottle : hint_range(0.0, 1.0) = 0.55;    // 抄纸厚薄
uniform float laid : hint_range(0.0, 1.0) = 0.55;      // 帘纹
uniform float fibre : hint_range(0.0, 1.0) = 0.6;      // 纤维
uniform float speckle : hint_range(0.0, 1.0) = 0.3;    // 纸屑
uniform float grain : hint_range(0.0, 1.0) = 0.4;      // 颗粒
uniform float foxing : hint_range(0.0, 1.0) = 0.35;    // 陈化斑
uniform float vignette : hint_range(0.0, 1.0) = 0.1;
uniform float edge_shade : hint_range(0.0, 1.0) = 0.55; // 纸边吸光

uniform float grain_scale = 1.0;
uniform float settle : hint_range(0.0, 1.0) = 1.0;
uniform float seed = 0.0;

// 碎边：rect_px 是纸层实际像素尺寸（含两侧撕口留白），tear_pad 是留白宽度。
// 回退路径要用 tear_pad / tear_depth；蒙版路径只用 rect_px 算陈化带。
uniform vec2 rect_px = vec2(880.0, 1080.0);
uniform float tear_pad : hint_range(0.0, 40.0) = 0.0;
uniform float tear_depth : hint_range(0.0, 24.0) = 4.0;

// 撕口蒙版。mask_uv_rect = 纸层在蒙版里的子矩形（xy = 原点，zw = 缩放），
// 因为纸层比蒙版窄一圈（蒙版额外含投影衰减带）。
uniform sampler2D paper_mask_tex : filter_linear, repeat_disable;
uniform float has_mask : hint_range(0.0, 1.0) = 0.0;
uniform vec4 mask_uv_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float mask_near_px : hint_range(1.0, 32.0) = 12.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21) + seed);
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm4(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += vnoise(p) * amp;
		p *= 2.03;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	// 纸内像素坐标：颗粒与纤维按像素走，纸变宽时纹理不会被拉长。
	vec2 p = UV * rect_px;
	vec2 frag_px = FRAGCOORD.xy * grain_scale;

	// ── 纤维与纸浆 ───────────────────────────────────────────────────────
	// 抄纸厚薄：低频大块，决定这张纸"匀不匀"；再叠一层浆团。
	// 浆团用两个旋转过的单八度噪声相加 —— 单八度 value noise 的格子是轴对齐的，
	// 放大看会露出规整的方块。
	float pulp = fbm4(frag_px * 0.0024);
	float clump = vnoise(frag_px * 0.0210) * 0.58
			+ vnoise(vec2(frag_px.x * 0.0163 - frag_px.y * 0.0131,
					frag_px.y * 0.0192 + frag_px.x * 0.0107)) * 0.42;

	// 纤维不能用噪声直接当亮度 —— 那只会得到一坨云。管用的是噪声的等值线：
	// |noise - 0.5| 越小越接近某条等值线，把阈值定成"带宽 ≈ 1.5 像素"，
	// 就得到几十像素长、一两像素粗的丝。阈值必须和噪声的梯度匹配，
	// 定小了会细到亚像素，屏幕上直接消失。
	// 纤维：用"各向异性噪声 + 高阈值"而不是等值线。
	// 让噪声在 x 上很缓（格子几十像素）、在 y 上很急（格子不到一像素），
	// 再切最高的那一小段值域，得到的就是一两像素高、几十像素长的横向丝。
	float fib_a = smoothstep(0.80, 0.95, vnoise(vec2(frag_px.x * 0.0140, frag_px.y * 1.10)));
	float fib_b = smoothstep(0.82, 0.96, vnoise(vec2(frag_px.x * 0.0300 + 37.0, frag_px.y * 0.90)));
	float fib_c = smoothstep(0.82, 0.96, vnoise(vec2(frag_px.x * 1.05 + 71.0, frag_px.y * 0.0160)));
	// 纤维不是均匀铺满的，有的地方密、有的地方是光板。
	float fib_mask = smoothstep(0.26, 0.80, vnoise(frag_px * 0.0058 + 5.0));
	float strands = (fib_a * 0.24 + fib_b * 0.28 + fib_c * 0.48) * mix(0.10, 1.0, fib_mask);

	// 帘纹：抄纸竹帘留下的横纹。周期带相位漂移，否则整齐得像显示器的扫描线。
	float laid_phase = p.y * 0.310 + vnoise(vec2(p.x * 0.0022, p.y * 0.0042)) * 5.2;
	float laid_line = 0.5 + 0.5 * sin(laid_phase * 6.28318);

	vec3 base = mix(paper_deep.rgb, paper_light.rgb,
			clamp(0.52 + (pulp - 0.5) * 1.75 * mottle + (clump - 0.5) * 0.55 * mottle, 0.0, 1.0));
	base *= 1.0 + (laid_line - 0.5) * 0.026 * laid;
	// 亮纤维（被漂白的丝）与暗纤维（未化开的浆）各来一层。
	base = mix(base, fibre_tint.rgb, strands * 0.46 * fibre);
	float dark_strand = (1.0 - smoothstep(0.04, 0.20,
			vnoise(vec2(frag_px.x * 0.0180 + 123.0, frag_px.y * 1.05)))) * mix(0.10, 1.0, fib_mask);
	base = mix(base, paper_deep.rgb * vec3(0.84, 0.79, 0.70), dark_strand * 0.20 * fibre);

	// 纸屑：极稀疏的深点，是抄纸时没化开的浆疙瘩。
	float fleck = hash21(floor(frag_px * 0.5) + 17.0);
	base -= step(0.9987, fleck) * 0.075 * speckle;

	// 颗粒：两三像素一簇的"纸牙"，比逐像素噪声更像能摸到的东西。
	float tooth = (vnoise(frag_px * 0.62) - 0.5) * 0.62 + (hash21(floor(frag_px)) - 0.5) * 0.38;
	base *= 1.0 + tooth * 0.058 * grain;

	// 陈化：稀疏的暖色晕斑，越是靠边越重 —— 纸是从边缘开始旧的。
	// 这里的"边"用名义纸缘（tear_pad 那条线），不跟撕口轮廓走：撕口怎么咬，
	// 陈化带都不该跟着抖。vignette 另算，它是整张纸的全局压角。
	float fox = smoothstep(0.58, 0.93, fbm4(frag_px * 0.0042 + 19.0));
	float edge_inset = max(min(p.x - tear_pad, (rect_px.x - tear_pad) - p.x), 0.0);
	float edge_prox = 1.0 - smoothstep(0.0, 0.20 * rect_px.x, edge_inset);
	base = mix(base, base * vec3(0.918, 0.848, 0.735), fox * mix(0.45, 1.25, edge_prox) * 0.55 * foxing);

	// ── 撕边 ─────────────────────────────────────────────────────────────
	// 无条件采样：未绑定 sampler 时 Godot 给的是白图，(1,1,1,1) 在 has_mask=0
	// 的分支里根本不参与计算，但把它放进 if 里会让驱动看到非一致的纹理访问。
	vec4 tear_mask = texture(paper_mask_tex, mask_uv_rect.xy + UV * mask_uv_rect.zw);

	float alpha;
	float near_edge;
	if (has_mask > 0.5) {
		alpha = tear_mask.a;
		near_edge = tear_mask.r * mask_near_px;
	} else {
		// 三段抖动：撕口走向（慢）→ 锯齿（中）→ 毛刺（快）。
		float wobble = (vnoise(vec2(UV.y * 7.5, seed * 3.7)) - 0.5) * 1.10
				+ (vnoise(vec2(UV.y * 41.0, seed + 11.0)) - 0.5) * 0.95
				+ (vnoise(vec2(UV.y * 173.0, seed + 29.0)) - 0.5) * 0.34;
		// 映射到 [-0.22, 1] 并钳住：撕口主要往纸里咬，偶尔也会有几根纤维探出去；
		// 但不许越出纸层矩形，否则最外那几个像素会被矩形硬切出一道直线。
		float bite = tear_depth * clamp(0.42 + wobble * 0.45, -0.22, 1.0);
		// 再挖几道偶发的深口子 —— 撕纸不会一路匀着撕，总有一两处扯掉一大块。
		bite += step(0.86, vnoise(vec2(UV.y * 23.0, seed + 41.0))) * tear_depth * 0.55;
		// 逐行错开一两个像素，边界不会被水平像素网格规整成台阶。
		float burr = (hash21(vec2(floor(p.y), seed + 5.0)) - 0.5) * 3.2;
		float left_edge = tear_pad + bite + burr;
		float right_edge = rect_px.x - tear_pad - bite + burr;

		// 抗锯齿只给 0.7px：再软就不是"撕开"而是"晕开"了。
		alpha = smoothstep(left_edge - 0.7, left_edge + 0.7, p.x)
				* (1.0 - smoothstep(right_edge - 0.7, right_edge + 0.7, p.x));
		near_edge = min(p.x - left_edge, right_edge - p.x);
	}

	// 纸边吸光：断面一道细暗线，再往里一层薄薄的阴影，纸才像"有厚度"。
	base *= 1.0 - (1.0 - smoothstep(0.0, 1.4, near_edge)) * 0.105 * edge_shade;
	base *= 1.0 - (1.0 - smoothstep(0.0, 7.0, near_edge)) * 0.085 * edge_shade;

	// ── 整体 ─────────────────────────────────────────────────────────────
	vec2 edge = UV - 0.5;
	float v = length(edge * vec2(1.06, 0.94));
	base *= 1.0 - smoothstep(0.44, 1.06, v) * vignette;

	// settle 让开场时纸"慢慢压实"，从偏暗的一档走到正常纸色。
	base = mix(base * 0.955, base, settle);

	COLOR = vec4(base, alpha * COLOR.a);
}
