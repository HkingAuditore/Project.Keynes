// hillshade_tod.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// [baked-surface 2026-11-01 / packed-surface 2026-11-01] 地形法线的唯一真源是生成期烘焙纹理。
//
//   terrain_baked_normal(uv, quality, crease) 是本文件对外暴露的唯一法线入口：
//     normal（非 tiled: terrain_surface_tex.layer0；tiled: visual_terrain_normal_tiles）：
//       RG = 粗法线 xy（0.5+n*0.5），BA = 近景高度细节坡度（encode_slope）
//     relief（非 tiled: terrain_surface_tex.layer1；tiled: visual_terrain_relief_tiles）：
//       RG = 粗段分地形细节坡度，BA = 细段分地形细节坡度
//   两张图层都由生成期 visual tile 烘焙逐 texel 求好；运行期只做 2 次采样 + 按缩放淡出，
//   **没有任何 height_tex 邻域差分**（桌面端与 Web 端一致）。这也是本次重构的核心诉求：
//   低画质档位不再靠"裁掉细节 / 走差分回退"省时间，而是与高画质共享同一套烘焙数据。
//   方案 A 之后非 tiled 的 normal+relief 是同一个 2 层 Texture2DArray 的 layer0/1，
//   但本文件的 4 个 helper 名与调用方式完全不变。
//
//   旧的运行期高度差分法线整条链路（双光源 hillshading、宽半径粗法线差分、
//   1-texel 细节差分、分地形程序化细节法线与 TOD PBR 旧入口）已整体删除，
//   不要再加回来：任何"运行时读 height_tex 邻域"的写法都属于本契约的违例。
//   旧存档 / 单 tile pass 失败时只允许退化到"仅粗法线"或平地法线，不做差分回退。
//
// biome_roughness(biome) 仍被 terrain_surface_detail 的材质粗糙度路径消费。
//
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：hillshade_* / terrain_erosion_* / camera_zoom / B_*。
//   - visual_tile_sampling.gdshaderinc：visual_sample_terrain_normal /
//     visual_sample_terrain_relief / decode_relief_slope / decode_relief_slope4 /
//     terrain_baked_normals（PK_TERRAIN_BAKED_NORMALS 作用域内）。
// ─────────────────────────────────────────────────────────────────────────

// 按 biome 查表粗糙度（需求 3.3）：雪/冰保持高反差、山地/丘陵/荒地更粗，避免像涂层
// [biome 材质全覆盖 2026-06-25] 补齐此前落到默认 0.55 的 11 种地形：湿地系略带含水反光、
// 岩石系接近全粗、灌丛/苔原干硬中粗、寒漠砾石中粗。纯 ALU 查表，零额外纹理采样。
float biome_roughness(int biome) {
	// 雪 / 冰川 / 海冰：高反差光滑面
	// [海冰反射 2026-06-25] 冰川/海冰是结晶冰，比积雪更镜面：从 0.22 降到 0.13；
	// 积雪是多重散射的哑光面，单独保留 0.30（略粗，避免与冰同质）。
	if (biome == B_GLACIER || biome == B_SEA_ICE) return 0.13;
	if (biome == B_SNOW) return 0.30;
	// 干燥沙 / 盐滩 / 寒漠：中粗砂砾
	if (biome == B_DESERT || biome == B_SALT_FLAT) return 0.58;
	if (biome == B_COLD_DESERT) return 0.62;
	// 密林：很粗（叶面多重漫反射）
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.88;
	// 草本：偏粗
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE) return 0.78;
	// 灌丛（含地中海硬叶）/ 苔原：干硬中粗
	if (biome == B_SHRUBLAND || biome == B_CHAPARRAL) return 0.76;
	if (biome == B_TUNDRA) return 0.72;
	// 裸岩碎石（山地/丘陵/荒地/方山）：接近全粗，消除低角度太阳下的"湿亮"高光
	if (biome == B_MOUNTAIN) return 0.96;
	if (biome == B_HILL) return 0.92;
	if (biome == B_BADLANDS || biome == B_MESA) return 0.92;
	// 湿地 / 水成地表：粗糙度压低 → 含水反光，与干燥地表区分（沼泽/泥炭最湿，冲积带次之）
	if (biome == B_SWAMP || biome == B_MOOR) return 0.52;
	if (biome == B_DELTA || biome == B_FLOODPLAIN) return 0.56;
	if (biome == B_OASIS) return 0.54;
	// 平原：中性偏粗
	if (biome == B_PLAIN) return 0.66;
	return 0.55;
}

// ─── 唯一法线入口（桌面 + Web 共用）─────────────────────────────────────
// 返回 (几何法线, 沟谷折痕)；crease 由调用方从已采样的 edge_distance.g 传入。
// 细节坡度分粗段（波长 >= 32·scale）与细段两组，各自只在屏幕上够宽时淡入，
// 代替原先逐倍频的屏幕波长淡出；近景高度细节（normal.ba）保留原来的拉近门控。
// quality 只影响近景细节倍率（0.55 / 0.35），不再按档位硬砍细节：
// Web LOW 也必须吃到烘焙 relief（这是本轮用户诉求），代价只是 1-2 次已绑定采样。
vec4 terrain_baked_normal(vec2 uv, int quality, float crease) {
#ifdef PK_TERRAIN_BAKED_NORMALS
	if (terrain_baked_normals) {
		vec4 n = visual_sample_terrain_normal(uv);
		vec2 nxy = (n.rg * 2.0 - 1.0) * hillshade_coarse_strength;
		float nz = sqrt(max(1e-4, 1.0 - clamp(dot(nxy, nxy), 0.0, 0.998)));
		vec2 s = nxy / max(nz, 0.2);
		// 近景高度细节：normal.ba（烘焙的 encode_slope）。
		if (hillshade_detail_enabled && hillshade_detail_strength > 0.0) {
			float qf = (quality >= 2) ? 0.55 : 0.35;
			float near = smoothstep(1.35, 2.10, camera_zoom);
			s += decode_relief_slope(n.ba) * hillshade_detail_strength * qf * near;
		}
		// 分地形 relief 粗/细段：非 tiled 为 terrain_surface_tex.layer1（RG/BA），tiled 为数组。
		float k_relief = 0.0;
		if (terrain_relief_tex_bound && terrain_erosion_strength > 0.0001) {
			float scale = max(terrain_erosion_world_size, 1.0) / 72.0;
			vec4 r = decode_relief_slope4(visual_sample_terrain_relief(uv));
			float fade_coarse = smoothstep(3.0, 7.0, 48.0 * scale * camera_zoom);
			float fade_fine = smoothstep(3.0, 7.0, 14.0 * scale * camera_zoom);
			s += (r.xy * fade_coarse + r.zw * fade_fine) * terrain_erosion_strength;
			k_relief = fade_coarse;
		}
		return vec4(normalize(vec3(s, 1.0)), crease * k_relief);
	}
#endif // PK_TERRAIN_BAKED_NORMALS
	// 兜底：只有单张粗法线纹理（单 tile 烘焙 pass 失败后的 RG8 旧包），或什么都没有。
	// 这里同样不做任何高度差分——旧存档的粗法线仍是生成期烘出来的。
	// 必须排除 tiled：tiled 用 sampler2DArray，static_ready=false 时数组可能是空/未初始化
	// 的，采样会读出垃圾法线；tiled 静态烘焙在 set_map 前完成，未就绪时直接给平地法线。
#if defined(VT_USE_TERRAIN_NORMAL) && !defined(MAP_VISUAL_TILED)
	if (terrain_normal_tex_bound) {
		vec2 nxy = (visual_sample_terrain_normal(uv).rg * 2.0 - 1.0)
				* hillshade_coarse_strength;
		float nz = sqrt(max(1e-4, 1.0 - clamp(dot(nxy, nxy), 0.0, 0.998)));
		return vec4(normalize(vec3(nxy / max(nz, 0.2), 1.0)), 0.0);
	}
#endif // VT_USE_TERRAIN_NORMAL && !MAP_VISUAL_TILED
	return vec4(0.0, 0.0, 1.0, 0.0);
}
