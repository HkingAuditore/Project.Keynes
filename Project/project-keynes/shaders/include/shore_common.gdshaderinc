// shore_common.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   抽取 land_pipeline / water_pipeline 中重复了两份的 3×3 邻域 map_index_atlas
//   采样代码 + 海岸 halo 颜色合成 + roughness 端硬编码。
//   提供：
//     - struct ShoreSamples         ：邻域计数与归一化频率
//     - sample_shore_neighborhood   ：采样并填充 ShoreSamples
//     - struct ShoreHaloResult      ：halo 颜色 + 不透明度 + roughness target
//     - compute_shore_halo          ：把邻域、海拔带、河流流量综合成最终 halo
//
// 调用方（Who）
//   - land_pipeline.gdshaderinc::apply_land_color_overlays
//   - water_pipeline.gdshaderinc::apply_water_color_overlays
//
// 依赖（Why）
//   uniforms.gdshaderinc（map_index_atlas / derived_resolution / sea_level /
//     river_threshold_low/high / coast_halo_color / coast_halo_strength /
//     color_beach / color_coast_water / lake_water_color / river_color /
//     B_OCEAN / B_COAST / B_LAKE / B_REEF / B_KELP / B_SEA_ICE / visual_quality）
//
// 性能（Cost）
//   3×3 - 1 = 8 次 map_index_atlas 采样（visual_quality<=0 跳过 4 个对角，仅 4 次）。
//   原本 land/water 路径各采一次，现在仍然只采一次（互斥分支），但代码只写一份。
// ─────────────────────────────────────────────────────────────────────────

struct ShoreSamples {
	float nearby_water_cnt;
	float nearby_land_cnt;
	float nearby_lake_cnt;
	float nearby_ocean_cnt;
	float total_cnt;
	float inv_total;       // 1.0 / max(total_cnt, 1.0)
};

// ─── [cell-field 2026-11-18] 解析岸线输入（PK_CELL_FIELD）────────────────────
// 方案 §3.7：对偶三角形之外的任何格，到三角形内任一点的 gap 都 ≥ √3/2 ≈ 0.866，
// 所以 **gap ≤ 0.86（≈ 0.43 hex ≈ 9.5 wu）以内的岸线只看这三格就是精确的**。
// 于是「3×3 map_index 邻域」整段不需要：它 8 次采样，而且半径是按**纹素**给的
// ⇒ 同一份代码在桌面（1024 索引图）探 7 wu、移动端（512）探 14 wu，湖岸晕染宽度
// 差一倍。解析版的宽度只依赖世界单位（hex_size），两端必然一致。
// 关闭 PK_CELL_FIELD 时下面整块被预处理器剔除 ⇒ 与今日逐字节一致。
#ifdef PK_CELL_FIELD
// 岸线 / 湖岸带宽（hex 为单位）。0.43 hex = PK_FIELD_BAND_MAX / 2，正好是 §3.2 的带宽
// 上限（0.86 gap ⇒ 0.43 hex ⇒ hex_size=22 时 9.5 wu）。世界单位宽度 =
// PK_SHORE_BAND_HEX * hex_size，与索引图分辨率无关。
const float PK_SHORE_BAND_HEX = 0.43;

int shore_cell_biome(vec4 cls) { return int(cls.r * 255.0 + 0.5); }

// 到最近陆地格的 gap（gap 单位）。三格都是水 ⇒ 1e3（"岸在远处"哨兵，任何阈值都比它小）。
// 手写三连、用比较 + 三元选择，无循环无分支（§3.9）。
float shore_gap_from_field(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	float g = 1e3;
	g = terrain_static_biome_is_water(shore_cell_biome(e0)) ? g : min(g, f.gap.x);
	g = terrain_static_biome_is_water(shore_cell_biome(e1)) ? g : min(g, f.gap.y);
	g = terrain_static_biome_is_water(shore_cell_biome(e2)) ? g : min(g, f.gap.z);
	return g;
}

// gap → 世界单位岸距：沿格中心连线 gap = 2·d_b / hex_size（契约 §1，d_b = 到水陆格界的
// 距离）⇒ d_b = 0.5·gap·hex_size。超过带宽上限的值没有意义（第三格在三角形外时
// gap 恒 ≥ 0.866），先 clamp 再换算。
float shore_distance_wu(float shore_gap) {
	return 0.5 * min(shore_gap, PK_FIELD_BAND_MAX) * hex_size;
}

// 岸线接触度：1 = 贴岸，0 = 岸在 PK_SHORE_BAND_HEX 个 hex 之外。
float shore_contact_from_field(float shore_gap) {
	return 1.0 - smoothstep(0.0, PK_SHORE_BAND_HEX * hex_size, shore_distance_wu(shore_gap));
}

// 单格 class → (水, 湖, 海) 三指示。海 = OCEAN/COAST/REEF/KELP，与旧 8 邻域计数同口径
// （旧计数把海冰也算成水，但不计进海）。
vec3 shore_cell_water_kind(vec4 cls) {
	int b = shore_cell_biome(cls);
	bool water = (b == B_OCEAN) || (b == B_COAST) || (b == B_LAKE)
			|| (b == B_REEF) || (b == B_KELP) || (b == B_SEA_ICE);
	bool lake = (b == B_LAKE);
	bool ocean = (b == B_OCEAN) || (b == B_COAST) || (b == B_REEF) || (b == B_KELP);
	return vec3(water ? 1.0 : 0.0, lake ? 1.0 : 0.0, ocean ? 1.0 : 0.0);
}

// [cell-field 2026-11-18] 解析版邻域（水面侧，role=1）：不是"数邻居"，而是
//   ① 接触度 ← 世界单位岸距（shore_gap）
//   ② 水 / 湖 / 海占比 ← Σ w_raw（方案 §3.7：「shore_frac 改为 Σ w_raw」）
// 计数仍按 8 归一（total_cnt = 8），compute_shore_halo 的公式一个字都不用改。
ShoreSamples sample_shore_neighborhood_field(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	ShoreSamples s;
	vec3 kind_w = shore_cell_water_kind(e0) * f.w_raw.x
			+ shore_cell_water_kind(e1) * f.w_raw.y
			+ shore_cell_water_kind(e2) * f.w_raw.z;
	float contact = shore_contact_from_field(shore_gap_from_field(f, e0, e1, e2));
	s.total_cnt        = 8.0;
	s.inv_total        = 0.125;
	s.nearby_water_cnt = kind_w.x * 8.0;
	s.nearby_land_cnt  = contact * 8.0;
	s.nearby_lake_cnt  = kind_w.y * 8.0;
	s.nearby_ocean_cnt = kind_w.z * 8.0;
	return s;
}
#endif // PK_CELL_FIELD

// 单点采样：把 8 邻居（高质量）/ 4 邻居（低质量）的 biome 类型分类计数。
// shore_frac = edge_distance.ba（烘焙的 8 邻域水 / 湖占比），由 fragment setup 一次采样后传入。
// [cell-field 2026-11-18] PK_CELL_FIELD 下 shore_frac 已经是解析量（world_map SETUP 的
// pk_cell_field_shore_frac：三格水格 / 湖格按 w_raw 累加），所以直接把占比展开成 8 计数，
// 3×3 map_index 环整段编译掉（方案 §2.3 / §3.7）。陆地侧用这条；水面侧的晕染宽度还要
// 岸距，改调上面的 sample_shore_neighborhood_field。
ShoreSamples sample_shore_neighborhood(vec2 uv, vec2 shore_frac) {
#ifdef PK_CELL_FIELD
	ShoreSamples s;
	s.total_cnt        = 8.0;
	s.inv_total        = 0.125;
	s.nearby_water_cnt = shore_frac.x * 8.0;
	s.nearby_land_cnt  = 8.0 - s.nearby_water_cnt;
	s.nearby_lake_cnt  = shore_frac.y * 8.0;
	s.nearby_ocean_cnt = max(s.nearby_water_cnt - s.nearby_lake_cnt, 0.0);
	return s;
#else
	ShoreSamples s;
	s.nearby_water_cnt = 0.0;
	s.nearby_land_cnt  = 0.0;
	s.nearby_lake_cnt  = 0.0;
	s.nearby_ocean_cnt = 0.0;
	s.total_cnt        = 0.0;

#if defined(PK_TERRAIN_STATIC_BAKED) || defined(PK_TERRAIN_STATIC_PACKED)
	// 8 邻域占比已在烘焙时按 texel 求好，双线性插值后过渡更连续。海占比取水 − 湖
	// （海冰邻居也算作海，与旧计数只差在极地冰缘的 halo 配色）。
	// [surface-array-edge 2026-11-02] 非 tiled 打包路径（surface array layer4.BA）同样走这里：
	// Web 陆地 / HIGH 水面因此从 8 次 map_index fetch 降为 0 次，海岸 halo 也变成连续量。
	if (terrain_static_baked) {
		s.nearby_water_cnt = shore_frac.x * 8.0;
		s.nearby_land_cnt  = 8.0 - s.nearby_water_cnt;
		s.nearby_lake_cnt  = shore_frac.y * 8.0;
		s.nearby_ocean_cnt = max(s.nearby_water_cnt - s.nearby_lake_cnt, 0.0);
		s.total_cnt = 8.0;
		s.inv_total = 0.125;
		return s;
	}
#endif
	vec2 texel = 1.0 / derived_resolution;
	for (int sy = -1; sy <= 1; sy++) {
		for (int sx = -1; sx <= 1; sx++) {
			if (sx == 0 && sy == 0) {
				continue;
			}
			bool is_diag = (sx != 0) && (sy != 0);
			if (visual_quality <= 0 && is_diag) {
				continue;
			}
			vec2 suv = wrap_map_uv(uv + vec2(float(sx), float(sy)) * texel);
			int sb = int(visual_sample_map_index(suv).r * 255.0 + 0.5);
			bool sw = (sb == B_OCEAN) || (sb == B_COAST) || (sb == B_LAKE)
					|| (sb == B_REEF)  || (sb == B_KELP)  || (sb == B_SEA_ICE);
			s.nearby_water_cnt += sw ? 1.0 : 0.0;
			s.nearby_land_cnt  += sw ? 0.0 : 1.0;
			s.nearby_lake_cnt  += (sb == B_LAKE) ? 1.0 : 0.0;
			s.nearby_ocean_cnt += ((sb == B_OCEAN) || (sb == B_COAST)
								|| (sb == B_REEF)  || (sb == B_KELP)) ? 1.0 : 0.0;
			s.total_cnt += 1.0;
		}
	}
	s.inv_total = 1.0 / max(s.total_cnt, 1.0);
	return s;
#endif // PK_CELL_FIELD
}

// ─── halo 结果容器：颜色 + 不透明度（已含 strength）+ roughness 目标 ───
struct ShoreHaloResult {
	vec3  halo_color;          // 最终海岸 halo 颜色（已混合 ocean/lake/estuary）
	float halo_weight;         // 已乘 coast_halo_strength 的最终 mix 权重 [0,1]
	float coast_t;             // 未含 strength 的 raw t（用于浪花/海冰等下游需要）
	float shore_w;             // 邻域水接触 smoothstep 后的权重（land 视角）
	float lake_side_w;
	float ocean_side_w;
	float estuary_flow;
	float roughness_target;    // halo 区域应该混入的 roughness（land/water 不同语义）
};

// role: 0=land halo（contact = water 邻居）, 1=water halo（contact = land 邻居）
//
// 参数差异（为保持 v9 视觉等价）：
//   - role=0 (land) : sea_band 阈值 0.040、halo_strength_mul=1.00、estuary 启用
//   - role=1 (water): sea_band 阈值 0.065、halo_strength_mul=0.86、estuary=0
//   - estuary_flow 仅 land 路径消费 scals.g（flow_accum）
ShoreHaloResult compute_shore_halo(
		ShoreSamples s,
		float elev,
		float flow_accum,        // scals.g；water 路径传 0.0 即可
		int   role) {
	ShoreHaloResult r;

	float shore_contact = (role == 0)
			? (s.nearby_water_cnt * s.inv_total)
			: (s.nearby_land_cnt  * s.inv_total);
	r.shore_w      = smoothstep(0.06, 0.42, shore_contact);
	r.lake_side_w  = smoothstep(0.08, 0.42, s.nearby_lake_cnt  * s.inv_total);
	r.ocean_side_w = smoothstep(0.08, 0.42, s.nearby_ocean_cnt * s.inv_total);

	float sea_band_thresh = (role == 0) ? 0.040 : 0.065;
	float sea_band = 1.0 - smoothstep(0.0, sea_band_thresh, abs(elev - sea_level));

	r.estuary_flow = 0.0;
	if (role == 0) {
		r.estuary_flow = smoothstep(river_threshold_low * 0.90, river_threshold_high, flow_accum)
						* r.ocean_side_w;
	}

	r.coast_t = clamp(
		max(sea_band * 0.55, r.shore_w * SHORE_HALO_WEIGHT_MAX) + r.estuary_flow * 0.30,
		0.0, 1.0);

	// ── halo 颜色合成（land/water 共用） ─────────────────────────────────
	vec3 ocean_halo   = mix(coast_halo_color, color_beach * vec3(0.82, 0.92, 1.02), 0.36);
	vec3 lake_halo    = mix(coast_halo_color * vec3(0.84, 1.05, 1.12),
							lake_water_color * vec3(1.06, 1.08, 1.03), 0.40);
	vec3 estuary_halo = mix(river_color, color_coast_water, 0.58) * vec3(0.96, 1.03, 1.06);

	vec3 halo = mix(ocean_halo, lake_halo, r.lake_side_w * (1.0 - r.ocean_side_w * 0.45));
	halo      = mix(halo, estuary_halo, r.estuary_flow * 0.55);
	r.halo_color = halo;

	// ── halo 强度：land=1.00 倍，water=0.86 倍（保持 v9 视觉） ─────────
	float strength_mul = (role == 0) ? 1.00 : 0.86;
	float halo_strength = coast_halo_strength * mix(0.34, 0.62, r.shore_w) * strength_mul;
	r.halo_weight = clamp(r.coast_t * halo_strength, 0.0, 1.0);

	// ── roughness target：仅 water 路径在原代码中显式覆盖；land 留中性值 ─
	r.roughness_target = (role == 0) ? 0.55 : 0.42;
	return r;
}

// ─── [coast-smooth 2026-06-26] 平滑海岸覆盖场 ─────────────────────────────
// 海岸"丑"的根因：水陆拓扑仍是权威主 cell 的硬域边（is_water 取自 enum_lut；视觉 DitherUV
// 明确禁止跨水陆选择），而河流是连续 SDF → 单靠枚举会呈六边形阶梯，远丑于河流。
// 用 linear 滤波的 water_depth_tex（0=内陆/岸、1=最深；GPU 双线性 → 跨水陆边界平滑过渡，且内陆恒 0
// 能正确区分"海岸"与 P1 后同样贴 sea_level 的"内陆平原"，elev 做不到）取 0→1 连续覆盖场，其阈值
// 等高线比硬六边形边平滑。返回 <0 表示纹理未绑定 → 调用方旁路回退旧硬边。
// 注（2026-06-26）：原 5-tap 空间平均已按需求取消，仅依赖硬件双线性滤波（单次采样）。
float coast_water_coverage(vec2 uv) {
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] PK 变体不读 water_depth 数组（方案 §2.3）：水深与岸距一律来自
	// cell_table layer2.g + 解析场，返回 -1 让调用方走"覆盖场不可用"的回退分支（与纹理
	// 未绑定同义）。此函数目前在整条管线里没有调用点，保留签名只是不给未来调用者埋坑。
	return -1.0;
#elif !defined(VT_USE_WATER_DEPTH)
	// [pk-web-texture-budget] water_depth tile 已裁掉：调用方按"纹理未绑定"旁路回退旧硬边。
	return -1.0;
#else
	if (!has_water_depth_tex) {
		return -1.0;
	}
	return visual_sample_water_depth(uv).r;
#endif
}
