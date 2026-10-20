shader_type canvas_item;
render_mode unshaded;

// 长纸在桌面上的投影。纸是从画面外接进来的，上下不出影，只做左右两道软边。
//
// 投影的矩形就是蒙版矩形（annual_report_tokens.mask_rect），UV 恒等 —— 这样
// 纹理外缘的 G 值（纸外侧距离）已经饱和，alpha 恒为 0，**阴影矩形的边界天然看不见**。
// 如果只把阴影铺到纸层那么宽，撕口外面就会出现一圈边界锐利的方形灰影。
//
// 为什么撕口缺口里不是一块方影：alpha 只是"到撕口轮廓的距离"的函数，离纸越近越浓、
// 向开口越淡，所以看到的是贴着一圈内壁的暗边，深度随咬口起伏。
//
// inset 那条对称路径是 has_mask = 0 时的回退。

uniform vec4 shade : source_color = vec4(0.03, 0.022, 0.014, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.62;
uniform float falloff : hint_range(0.6, 4.0) = 2.2;

// 回退路径：纸缘在阴影矩形里的归一化位置（由脚本按 扩展像素 / 总宽 计算）。
uniform float inset : hint_range(0.01, 0.45) = 0.06;

// 蒙版路径。spread_px 是从撕口轮廓向外衰减多远；mask_far_px 必须与构建脚本里的
// FAR_PX 一致，且 >= spread_px + 8，否则 G 在矩形边提前饱和，会留下恒定灰的方影。
uniform sampler2D paper_mask_tex : filter_linear, repeat_disable;
uniform float has_mask : hint_range(0.0, 1.0) = 0.0;
uniform float spread_px : hint_range(2.0, 120.0) = 33.0;
uniform float mask_far_px = 64.0;

void fragment() {
	// 无条件采样：未绑定 sampler 时拿到的是白图，has_mask=0 时不参与计算。
	vec4 tear_mask = texture(paper_mask_tex, UV);

	float a;
	if (has_mask > 0.5) {
		float d_out = tear_mask.g * mask_far_px;
		a = strength * pow(clamp(1.0 - d_out / max(spread_px, 1.0), 0.0, 1.0), falloff);
	} else {
		float d = 0.0;
		if (UV.x < inset) {
			d = (inset - UV.x) / inset;
		} else if (UV.x > 1.0 - inset) {
			d = (UV.x - (1.0 - inset)) / inset;
		}
		a = strength * pow(max(0.0, 1.0 - d), falloff);
	}
	COLOR = vec4(shade.rgb, a * COLOR.a);
}
