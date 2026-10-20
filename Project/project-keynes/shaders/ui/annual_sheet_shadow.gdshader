shader_type canvas_item;
render_mode unshaded;

// 长纸在桌面上的投影。四边都出影 —— 纸是有限高、跟着滚动位移走的一件实物，
// 上下两端也是撕开的，影子必须跟着那四道撕口走。
//
// 矩形关系：阴影矩形 = 纸层矩形四边各扩 spread_px，而纸层矩形四边又各扩一段
// 撕口留白，所以横向刚好等于蒙版的整幅宽（见 AnnualReportTokens.shadow_rect
// 与 mask_rect —— 两者左右边缘是同一个 x）。脚本因此直接把**阴影矩形**在蒙版里
// 的子矩形传进来，UV.x 就是蒙版的 u，不需要任何压缩。
//
// 距离直接用蒙版 G 通道。它是"纸外侧的欧氏距离"：不区分方向，右边缘、纸头、
// 纸尾、四个撕开的角都算得对。旧版横向取 G、纵向另算程序化撕口的距离再取 max，
// 斜角处会偏小；位图四边烘全之后这个近似可以扔掉了。
//
// 为什么撕口缺口里不是一块方影：alpha 只是"到纸缘的距离"的函数，离纸越近越浓、
// 向开口越淡，所以看到的是贴着一圈内壁的暗边，深度随咬口起伏。

uniform vec4 shade : source_color = vec4(0.03, 0.022, 0.014, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.62;
uniform float falloff : hint_range(0.6, 4.0) = 2.2;

// 回退路径（has_mask = 0）：纸缘在阴影矩形里的归一化位置（由脚本按 扩展像素 / 总宽 计算）。
uniform float inset : hint_range(0.01, 0.45) = 0.06;

// 蒙版路径。spread_px 是从纸缘向外衰减多远；mask_far_px 必须与构建脚本里的
// FAR_PX 一致，且 >= spread_px + 8，否则 G 在矩形边提前饱和，会留下恒定灰的方影。
uniform sampler2D paper_mask_tex : filter_linear, repeat_disable;
uniform float has_mask : hint_range(0.0, 1.0) = 0.0;
uniform float spread_px : hint_range(2.0, 120.0) = 33.0;
uniform float mask_far_px = 64.0;
uniform vec4 mask_uv_rect = vec4(0.0, 0.0, 1.0, 1.0);

// 纸层的像素尺寸与纸头纸尾的几何，用来把 UV 换算回纸层坐标再换算成蒙版行号。
uniform vec2 layer_size = vec2(880.0, 1080.0);
uniform float cap_pad_px : hint_range(0.0, 64.0) = 0.0;
uniform float mask_tex_px : hint_range(2.0, 8192.0) = 1080.0;
uniform float mask_cap_rows : hint_range(0.0, 512.0) = 96.0;
uniform float mask_edge_rows : hint_range(0.0, 512.0) = 72.0;

#include "res://shaders/include/annual_sheet_tear.gdshaderinc"

void fragment() {
	// 阴影矩形比纸层各边大 spread_px，先换算回纸层坐标（0 = 纸层上沿）。
	vec2 span = layer_size + vec2(spread_px * 2.0);
	vec2 local = UV * span - vec2(spread_px);

	// 无条件采样：未绑定 sampler 时拿到的是白图，has_mask=0 时不参与计算，
	// 但把它放进 if 里会让驱动看到非一致的纹理访问。
	// 纵向用与纸场同一套行号算术：纸头纸尾 1:1，中段镜像平铺。
	vec4 tear_mask = texture(paper_mask_tex, vec2(
		mask_uv_rect.x + UV.x * mask_uv_rect.z,
		annual_sheet_mask_v(local.y, layer_size.y, mask_tex_px,
				mask_cap_rows, cap_pad_px, mask_edge_rows)));

	float a;
	if (has_mask > 0.5) {
		// G 在纸内也是 >= 0 的，但纸内那一半被纸盖住了，看不见。
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
