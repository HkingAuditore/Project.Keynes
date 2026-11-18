// fog_memory.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 已探索但当前不可见 → "褪色的记忆"。
//
// 真源是 world_map.gdshader 的 fog_gray 分支（[fog-memory-wash 2026-11-17] 定下的
// 「提亮 + 去饱和，往纸色靠」，不是压暗）。植被 / 资源原来各写各的、资源甚至完全
// 不做，于是同一片未发现区里地形已经变成纸白、植株和矿斑还是全彩深色 —— 作者报的
// 「点缀物没有跟着一起灰」。
//
// 这里抽成**纯函数**（零 uniform、零纹理），三个消费者各自 include：
//   · world_map.gdshader        —— 陆地/水面基色
//   · vegetation_impostor.gdshaderinc —— 植株 albedo
//   · resource_impostor.gdshader      —— 道具/贴花颜色
//
// 参数：
//   col      调用方的最终颜色（已含光照）
//   k        enum_lut.a 的知识度：0 未探索 / 0.5 已探索未可见 / 1 可见
//   strength 同 fog_gray_strength（0..1）。三处必须同值，默认 0.75。
//
// ⚠ 这里的 0.5 / 0.86 / 0.10 / 纸色 (0.88,0.86,0.82) 与 fog_gray 分支逐字一致。
//   改这里就是同时改三层，不要再在各自的 shader 里另写一份。
// ─────────────────────────────────────────────────────────────────────────
#ifndef PK_FOG_MEMORY_INC
#define PK_FOG_MEMORY_INC

vec3 pk_fog_memory_wash(vec3 col, float k, float strength) {
	float amt = (1.0 - smoothstep(0.5, 1.0, k)) * strength;
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	// [fog-memory-tone 2026-11-18] 记忆色是**固定的墨灰**，只保留 5% 原亮度。
	// 从 l 直接推导（旧式 `vec3(l)*1.02`）有两个后果：
	//   · 深色植株/矿斑的 memory 也跟着暗（l≈0.02 ⇒ memory≈0.02），灰化等于没发生；
	//   · 亮地形停在 0.88 的白上，和点缀物差得更远。
	// 取屏幕 sRGB 0.25（≈64 级）对应的线性值 0.048：作者要的"墨灰"。
	// 混合权重 0.95 让亮地表被压深、深色点缀物被提亮，两端落到同一个墨灰上。
	vec3 memory = mix(vec3(l), vec3(0.048, 0.047, 0.043), 0.95);
	return mix(col, memory, amt);
}

#endif // PK_FOG_MEMORY_INC
