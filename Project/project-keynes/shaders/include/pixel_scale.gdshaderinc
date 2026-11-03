// pixel_scale.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：世界尺度 ↔ 屏幕像素尺度的**唯一**换算入口。
//
// [pixel-scale-detail 2026-11-03] 事件背景：地表的所有细节层（材质平铺 / micro /
// 程序化 biome 噪声）都是**固定世界尺度**，相机放大时被等比拉大，没有任何一层提供
// "屏幕像素级"的高频 —— 玩家在手机上放大后看到的就是被放大的像素颗粒。
// 要把细节补回来，所有"该不该出现细节"的门控都必须以
//   「一个纹素投影到几个屏幕像素」
// 为准。旧代码用 camera_zoom 近似放大倍数，漏掉了移动端 content_scale（≈1.375），
// 把纹素投影系统性低估 37%：远景淡出提前触发、近景细节迟迟不出现。
// ⇒ 从本文件起，任何随 zoom 变化的门控**禁止**再直接比较 camera_zoom。
//
// 唯一权威输入：uniform float pixel_world_size（声明在 uniforms.gdshaderinc）
//   = 1 / (camera_zoom × content_scale) = 一个**物理**像素覆盖的世界单位数，
//   已含移动端 content_scale，由 hex_renderer 逐帧推送。
//
// 依赖（caller 必须在 uniforms.gdshaderinc 之后 include 本文件）：
//   uniforms.gdshaderinc —— pixel_world_size / hex_size。
// 性能（PERF）：纯 ALU，无采样、无 uniform。pk_world_per_px_at 用 2 次导数。
// ─────────────────────────────────────────────────────────────────────────
#ifndef PK_PIXEL_SCALE_INC
#define PK_PIXEL_SCALE_INC

// 近景高频门控的两个端点（屏幕像素 / 纹素）。语义：某图层的纹素被放大到 2.5 px
// 时开始交叉淡入更细一级的细节，6 px 时完全交给更细一级。
//   2.5 px —— 肉眼开始能把纹素看成"方块"的门槛；
//   6.0 px —— 一级细节已经明显发糊，必须由更细一级接管。
// 两个端点都是"纹素投影"口径，与平台/分辨率无关（content_scale 已含在 uniform 里）。
const float PK_DETAIL_PX_START = 2.5;
const float PK_DETAIL_PX_FULL = 6.0;

// 一个世界单位在屏幕上占多少**物理**像素（= 真实放大倍数，含 content_scale）。
//
// 移动端推导（content_scale_mode=CANVAS_ITEMS，实测 2220×1080/440dpi ⇒ 1.375）：
//   pixel_world_size = 1 / (camera_zoom × 1.375)
//   ⇒ 桌面 camera_zoom 1.95 与移动端 camera_zoom 1.95 / 1.375 = 1.42 落在**同一个**
//   px/world 上，即两端看到的是同一个"纹素放大倍数"，观感一致。
// 这也是为什么阈值不需要再手写 1.375 之类的字面量：修正量在 uniform 里。
float pk_px_per_world_unit() {
	return 1.0 / max(pixel_world_size, 1e-6);
}

// 逐像素：一个屏幕像素覆盖多少世界单位（world units / px）。
//
// 用 dFdx/dFdy 而不是只信 uniform：导数天然包含全部变换（wrap 折返 / 未来的非等比
// 缩放 / 倾斜），也不会因为 uniform 晚一帧而错档。canvas_item 里导数合法，本工程
// 已有 fwidth(distance_to_edge) 先例（terrain_edge_secondary_weight_d）。
//
// 两处刻意的取舍：
//  1) 取两轴绝对值的**较大者**，而不是 length(vec2(dFdx(wp.x), dFdy(wp.y)))：
//     轴对齐缩放下 length 恒等于 √2×(1/px_per_world)（两根轴各贡献 1 份），
//     会把门控系统性低估 29% —— 正好把 content_scale 修复的收益抵消掉一半。
//     取 max 等价于 fwidth 的保守口径：各向异性时按"较粗"的那个方向走。
//  2) 夹在 [pixel_world_size, 4×]：像素级 warp / 周期折返会让个别像素的导数爆掉，
//     不夹会在屏幕上留下"条状细节带"。下界用 uniform 兜底 ⇒ uniform 未推送
//     （默认 1.0）时退化成"永不进近景"，不会突然全屏噪点；上界 4× 同理只允许
//     局部更保守、不允许更激进。
float pk_world_per_px_at(vec2 wp) {
	// 1e-6 兜底：pixel_world_size 若被误推 0，clamp 的上下界会退化成 [0,0]，
	// 反过来把细节权重打成 1（全屏噪点）。这里始终用一个正的下界。
	float floor_world_per_px = max(pixel_world_size, 1e-6);
	float world_per_px = max(abs(dFdx(wp.x)), abs(dFdy(wp.y)));
	// 退化导数（0 / NaN，例如 1px 宽的退化三角形）回落整帧稳定值。
	world_per_px = (world_per_px > 1e-8) ? world_per_px : floor_world_per_px;
	return clamp(world_per_px, floor_world_per_px, floor_world_per_px * 4.0);
}

// 逐像素：一个世界单位占多少屏幕像素。
float pk_px_per_world_at(vec2 wp) {
	return 1.0 / max(pk_world_per_px_at(wp), 1e-6);
}

// 整帧稳定值：一个 hex 在屏幕上占多少物理像素。
//
// "每 hex 占多少屏幕像素"是跨场景可比的口径（hex 是玩家眼里的世界刻度），
// 因此世界尺度细节层的"该不该出现"统一用它表达；移动端的 content_scale 修正
// 已经包含在 pk_px_per_world_unit() 里，阈值本身不需要再乘 1.375。
// 注意：hex_size 是每个世界自己的艺术常量（默认 22），hex_px 因此等价于
// px_per_world × 22 —— 门控刻度跟着 hex 走，而不是跟着 camera_zoom 走。
float pk_hex_px() {
	return hex_size * pk_px_per_world_unit();
}

// 近景高频交叉淡入权重 ∈ [0,1]：纹素世界尺寸为 texel_world 的图层，
// 其纹素投影越大越启用（2.5 px 起、6 px 满，见 PK_DETAIL_PX_*）。
//
// 远景（纹素被缩小 ⇒ 投影 < 2.5 px）恒为 0 ⇒ 调用方据此整段跳过采样分支，
// 远景零成本。所有分级细节层（micro 二级 / 程序化生物群系高频）共用本函数，
// 保证"多细的细节在什么放大倍数出现"只有一个定义。
float pk_near_detail_blend(vec2 wp, float texel_world) {
	return smoothstep(PK_DETAIL_PX_START, PK_DETAIL_PX_FULL,
			max(texel_world, 1e-6) * pk_px_per_world_at(wp));
}

#endif
