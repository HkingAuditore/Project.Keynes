shader_type canvas_item;
render_mode unshaded;

// 页眉 / 页脚遮罩：一片从纸色到透明的竖直渐变，内容滚到它下面时被纸"吃掉"，
// 看不到任何分割线。
//
// 原来这块渐变是父节点 _draw() 里拿 18 段 draw_rect 铺的。两个问题：
//   1) 整纸宽的矩形会盖住撕口缺口 —— 缺口里本该透出桌面，却被一条纸色横带填平；
//   2) 18 段在 125% 缩放下能看到量化带。
// 搬进着色器后渐变是连续的，且末端乘蒙版的 A 通道，轮廓与撕口完全一致。
//
// 不做"矩形内缩"：draw_rect 第一档 alpha = 1.0 的纯色直边会落在纸面上，
// 而它画的是纯色 CHRONICLE_SHEET_LIGHT，与纸着色器画出的带 grain/foxing 的
// 纸色并不相等 —— 那正是纸缘出现竖直切口的原因。

uniform vec4 paper_color : source_color = vec4(0.965, 0.925, 0.835, 1.0);
uniform float ramp_pow : hint_range(0.5, 4.0) = 1.6;
// 0 = 页眉（不透明在上）；1 = 页脚（不透明在下）。
uniform float flip : hint_range(0.0, 1.0) = 0.0;

// 撕口蒙版：只取 A 通道做轮廓裁切。mask_uv_rect 是本节点在蒙版里的子矩形
// （xy = 原点，zw = 缩放）。
uniform sampler2D paper_mask_tex : filter_linear, repeat_disable;
uniform float has_mask : hint_range(0.0, 1.0) = 0.0;
uniform vec4 mask_uv_rect = vec4(0.0, 0.0, 1.0, 1.0);

void fragment() {
	float t = mix(UV.y, 1.0 - UV.y, step(0.5, flip));
	float alpha = pow(1.0 - t, ramp_pow);
	// 无条件采样：未绑定 sampler 时拿到白图，has_mask = 0 时靠 mix 忽略它。
	vec4 tear_mask = texture(paper_mask_tex, mask_uv_rect.xy + UV * mask_uv_rect.zw);
	alpha *= mix(1.0, tear_mask.a, step(0.5, has_mask));
	COLOR = vec4(paper_color.rgb, alpha * COLOR.a);
}
