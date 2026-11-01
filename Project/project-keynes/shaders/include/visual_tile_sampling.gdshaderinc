// Shared static-map raster addressing. Consumers define only the VT_USE_*
// fields they need before including this file.
vec2 visual_static_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

#ifdef MAP_VISUAL_TILED
uniform vec2 visual_domain_origin = vec2(0.0);
uniform vec2 visual_domain_size = vec2(1.0);
uniform vec2 visual_grid_size = vec2(1.0);
uniform vec2 visual_interior_size = vec2(1.0);
uniform vec2 visual_layer_size = vec2(1.0);
uniform vec2 visual_logical_resolution = vec2(1.0);
uniform float visual_gutter_px = 2.0;

vec3 visual_tile_address(vec2 map_uv) {
	vec2 wp = world_origin + map_uv * world_size;
	if (wrap_period_x > 0.0001) {
		wp.x = wrap_origin_x + mod(wp.x - wrap_origin_x, wrap_period_x);
	}
	vec2 domain_uv = (wp - visual_domain_origin) / max(visual_domain_size, vec2(0.0001));
	if (wrap_period_x > 0.0001) {
		domain_uv.x = fract(domain_uv.x);
	} else {
		domain_uv.x = clamp(domain_uv.x, 0.0, 1.0 - 0.0000001);
	}
	domain_uv.y = clamp(domain_uv.y, 0.0, 1.0 - 0.0000001);
	vec2 scaled = domain_uv * visual_grid_size;
	vec2 tile_xy = min(floor(scaled), visual_grid_size - vec2(1.0));
	vec2 local01 = scaled - tile_xy;
	vec2 physical_px = vec2(visual_gutter_px) + local01 * visual_interior_size;
	float layer = tile_xy.y * visual_grid_size.x + tile_xy.x;
	return vec3(physical_px / visual_layer_size, layer);
}

vec2 visual_static_texture_size() {
	return visual_logical_resolution;
}
#endif

#ifdef VT_USE_HEIGHT
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_height_tiles : filter_linear, repeat_disable;
vec4 visual_sample_height(vec2 uv) { return texture(visual_height_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D height_tex : filter_linear, repeat_disable;
vec4 visual_sample_height(vec2 uv) { return texture(height_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

// [packed-surface 2026-11-01 / surface-array-edge 2026-11-02] 非 tiled 的 world_map 地形 /
// 水面程序把整张静态地表打包成一个 sampler2DArray `terrain_surface_tex`，比多张 2D 省采样槽
// （Web 预算 8 槽的根因就是这些 2D 图）。层契约（固定 6 层，MapBaker.SURFACE_ARRAY_LAYERS）：
//   layer0 = normal    RG 粗法线 xy（0.5+n*0.5），BA 近景高度细节坡度（encode_slope）
//   layer1 = relief    RG 粗段 / BA 细段分地形细节坡度（encode_slope）
//   layer2 = detail    R = baked 细节噪声（BGA=0）
//   layer3 = occluder  两个 16-bit cell id（必须 texelFetch）
//   layer4 = edge_distance  R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比（LINEAR）
//   layer5 = edge_neighbor  RG 次生 cell id（必须 texelFetch）；B = water_depth R；A 预留
// 使用方在 include 前定义 VT_USE_TERRAIN_SURFACE_ARRAY（陆地与两个水面程序都定义）；
// 各 VT_USE_* 只决定读哪一层，**不新增 sampler**。tiled 桌面不走这条：normal/relief 是
// 两个不同分辨率（relief 是 relief_scale 倍）的数组，不能同 array。
#if !defined(MAP_VISUAL_TILED) && defined(VT_USE_TERRAIN_SURFACE_ARRAY)
uniform sampler2DArray terrain_surface_tex : filter_linear, repeat_disable;
#define TS_LAYER_NORMAL   0.0
#define TS_LAYER_RELIEF   1.0
#define TS_LAYER_DETAIL   2.0
#define TS_LAYER_OCCLUDER 3.0
#define TS_LAYER_EDGE_DISTANCE 4.0
#define TS_LAYER_EDGE_NEIGHBOR 5.0
// 运行期实际层数（2 = 旧的两层图；3 = +detail；4 = +occluder；6 = +edge 两层）。
uniform int terrain_surface_layer_count = 2;
uniform bool terrain_detail_layer_bound = false;
uniform bool terrain_occluder_layer_bound = false;
// layer4/5 是否真的烘出来了 ⇒ 次生生态过渡 / crease / 海岸占比是否可用。
// false（旧图 / 单 tile 烘焙失败 / 层数不足）时下面的 edge helper 返回中性值，
// **绝不采样越界层**（GLES3 对越界 layer 的返回值未定义）。
uniform bool terrain_edge_layers_bound = false;
#endif

#ifdef VT_USE_TERRAIN_NORMAL
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_terrain_normal_tiles : filter_linear, repeat_disable;
vec4 visual_sample_terrain_normal(vec2 uv) { return texture(visual_terrain_normal_tiles, visual_tile_address(uv)); }
#elif defined(VT_USE_TERRAIN_RELIEF)
#ifndef VT_USE_TERRAIN_SURFACE_ARRAY
#error "non-tiled packed normal+relief requires VT_USE_TERRAIN_SURFACE_ARRAY (terrain_surface_tex)"
#endif
vec4 visual_sample_terrain_normal(vec2 uv) {
	return texture(terrain_surface_tex, vec3(visual_static_wrap_uv(uv), TS_LAYER_NORMAL));
}
#else
uniform sampler2D terrain_normal_tex : filter_linear, repeat_disable;
vec4 visual_sample_terrain_normal(vec2 uv) { return texture(terrain_normal_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

// 运行期不再有任何"高度差分法线"：法线/细节坡度一律来自生成期烘焙纹理。
// 非 tiled 且 NORMAL+RELIEF 同时定义时，relief 就是上面打包 array 的 layer1。
#ifdef VT_USE_TERRAIN_RELIEF
#ifndef VT_USE_TERRAIN_NORMAL
#error "VT_USE_TERRAIN_RELIEF requires VT_USE_TERRAIN_NORMAL (packed terrain_surface_tex layer contract)"
#endif
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_terrain_relief_tiles : filter_linear, repeat_disable;
vec4 visual_sample_terrain_relief(vec2 uv) { return texture(visual_terrain_relief_tiles, visual_tile_address(uv)); }
#else
vec4 visual_sample_terrain_relief(vec2 uv) {
	return texture(terrain_surface_tex, vec3(visual_static_wrap_uv(uv), TS_LAYER_RELIEF));
}
#endif
#endif

// 烘焙法线 + relief 同时可用时定义（tiled: MAP_VISUAL_TILED && NORMAL && RELIEF；
// 非 tiled: NORMAL && RELIEF）。decode 函数与运行期门控 tiled/non-tiled 共用，
// 所以不能再塞进 PK_TERRAIN_STATIC_BAKED 块。
#if defined(VT_USE_TERRAIN_NORMAL) && defined(VT_USE_TERRAIN_RELIEF)
#define PK_TERRAIN_BAKED_NORMALS
uniform bool terrain_baked_normals = false;
// 与 pk_relief::encode_slope 互逆：v = sign(e)·e²·RANGE。
const float TERRAIN_RELIEF_ENCODE_RANGE = 3.0;
vec2 decode_relief_slope(vec2 enc) {
	vec2 e = enc * 2.0 - 1.0;
	return sign(e) * e * e * TERRAIN_RELIEF_ENCODE_RANGE;
}
vec4 decode_relief_slope4(vec4 enc) {
	vec4 e = enc * 2.0 - 1.0;
	return sign(e) * e * e * TERRAIN_RELIEF_ENCODE_RANGE;
}
#endif

// [static-bake 2026-10-10 / surface-array-edge 2026-11-02] 运行期不变的逐像素地表量由
// visual tile 烘焙写入：edge_distance.r 格界距离、.g 沟谷 crease、.ba 8 邻域水/湖占比。
// 两条路径都算"静态烘焙就绪"，各自用 terrain_static_baked 在运行期确认本张图：
//   tiled 桌面        → PK_TERRAIN_STATIC_BAKED（数组 + water_depth，走 visual_tile_address）
//   非 tiled 打包数组  → PK_TERRAIN_STATIC_PACKED（edge 层在同一个 surface array 里）
// 它**不再**表示法线是否可用——法线一律看 terrain_baked_normals（PK_TERRAIN_BAKED_NORMALS）。
#if defined(MAP_VISUAL_TILED) && defined(VT_USE_TERRAIN_RELIEF) && defined(VT_USE_TERRAIN_NORMAL) && defined(VT_USE_TERRAIN_DETAIL) && defined(VT_USE_WATER_DEPTH) && defined(VT_USE_EDGE_DISTANCE)
#define PK_TERRAIN_STATIC_BAKED
uniform bool terrain_static_baked = false;
#elif !defined(MAP_VISUAL_TILED) && defined(VT_USE_TERRAIN_SURFACE_ARRAY) && defined(VT_USE_EDGE_DISTANCE) && defined(VT_USE_EDGE_NEIGHBOR)
#define PK_TERRAIN_STATIC_PACKED
uniform bool terrain_static_baked = false;
#endif

#ifdef VT_USE_HORIZON
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_horizon_tiles : filter_nearest, repeat_disable;
#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
// Vulkan 后端：horizon 的 4 字节按 RG16 存（VisualTileSet._field_texture_format），
// 两次 textureGather 拿到 2×2 全部 texel。GLES3 没有 gather，保留 RGBA8 + 4 次采样。
#define PK_HORIZON_GATHER
// RG16 → 与 RGBA8 布局相同的 4 字节（R=字节 0/1，G=字节 2/3，小端）。
vec4 horizon_bytes_from_rg16(vec2 rg) {
	vec2 w = floor(rg * 65535.0 + 0.5);
	vec2 hi = floor(w * (1.0 / 256.0));
	vec2 lo = w - hi * 256.0;
	return vec4(lo.x, hi.x, lo.y, hi.y) * (1.0 / 255.0);
}
vec4 visual_sample_horizon(vec2 uv) {
	return horizon_bytes_from_rg16(texture(visual_horizon_tiles, visual_tile_address(uv)).rg);
}
// 返回 uv 所在 2×2 足迹（与双线性同一足迹，gutter 保证不跨层）及其插值分数 f。
void visual_gather_horizon(vec2 uv, out vec4 p00, out vec4 p10, out vec4 p01, out vec4 p11,
		out vec2 f) {
	vec3 addr = visual_tile_address(uv);
	f = fract(addr.xy * visual_layer_size - 0.5);
	vec4 r = textureGather(visual_horizon_tiles, addr, 0);
	vec4 g = textureGather(visual_horizon_tiles, addr, 1);
	// gather 分量顺序：x=(i0,j1) y=(i1,j1) z=(i1,j0) w=(i0,j0)
	p00 = horizon_bytes_from_rg16(vec2(r.w, g.w));
	p10 = horizon_bytes_from_rg16(vec2(r.z, g.z));
	p01 = horizon_bytes_from_rg16(vec2(r.x, g.x));
	p11 = horizon_bytes_from_rg16(vec2(r.y, g.y));
}
#else
vec4 visual_sample_horizon(vec2 uv) { return texture(visual_horizon_tiles, visual_tile_address(uv)); }
#endif
#else
uniform sampler2D terrain_horizon_tex : filter_nearest, repeat_disable;
// [web-resource-min] resource_impostor 的 web 精简变体不再采样地平线（uniform 声明保留，
// 运行期仍会 set_shader_parameter），采样点整段省掉。
#ifndef PK_WEB_RESOURCE_MIN
vec4 visual_sample_horizon(vec2 uv) { return texture(terrain_horizon_tex, visual_static_wrap_uv(uv)); }
#endif
#endif
#endif

// [terrain-gi 2026-07-31] 遮挡源 cell id：RG=主导遮挡源低/高字节，BA=次遮挡源低/高字节，
// 0xFFFF=无有效遮挡源。**必须 NEAREST**，对 cell id 做任何插值都会得到垃圾 cell。
#ifdef VT_USE_GI_OCCLUDER
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_gi_occluder_tiles : filter_nearest, repeat_disable;
vec4 visual_sample_gi_occluder(vec2 uv) { return texture(visual_gi_occluder_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D gi_occluder_tex : filter_nearest, repeat_disable;
vec4 visual_sample_gi_occluder(vec2 uv) { return texture(gi_occluder_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_MAP_INDEX
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_map_index_tiles : filter_nearest, repeat_disable;
vec4 visual_sample_map_index(vec2 uv) { return texture(visual_map_index_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
vec4 visual_sample_map_index(vec2 uv) { return texture(map_index_atlas, visual_static_wrap_uv(uv)); }
#endif
#ifndef MAP_VISUAL_TILED
vec2 visual_static_texture_size() { return vec2(textureSize(map_index_atlas, 0)); }
#endif
#endif

#ifdef VT_USE_FLOW
// [归因修正 2026-08-05] 早年记录的"WebGL2 单通道纹理建不起来→兜底 4×4 白纹"实为**纹理
// 单元撞车**：GLES3 canvas 内建纹理占顶部单元（MAX-7 高光…MAX-2 灯光图集），材质 sampler
// 从 unit 1 分配，flow 是第 9 张落在 unit 9，每帧被高光槽的 4×4 默认白纹覆盖——与格式无关
// （R8/RG8/RGBA8 全试过）。材质 sampler 必须 ≤8，见 uniforms.gdshaderinc budget 注释。
// 仍不能靠"没绑就采样得 0"降级：绑定与否由 CPU 侧显式推这个标志。
uniform bool has_flow_tex = false;
// [height-flow-pack 2026-08-06] Legacy + Tiled 统一：flow 打在 height 纹理的 B 通道
//（RGBA8；RG=16-bit height）。不再声明独立 flow_tex / visual_flow_tiles。
// 须同时定义 VT_USE_HEIGHT。
vec4 visual_sample_flow(vec2 uv) {
	vec4 h = visual_sample_height(uv);
	return vec4(h.b, 0.0, 0.0, 1.0);
}
// [flow-diag] 采样器实际看到的尺寸，以及绕过过滤/wrap 的整数取样。这是唯一能从 GPU 侧
// 证伪"纹理绑对了"的手段：CPU 侧 get_size()/get_format() 在兜底发生时依然全部正常，
// 只有 textureSize() 会报 4×4（引擎默认白纹理的尺寸）。2026-08 Web 整图发蓝就是这样定位的。
#ifdef MAP_VISUAL_TILED
ivec2 visual_flow_texture_size() { return textureSize(visual_height_tiles, 0).xy; }
float visual_flow_texel(vec2 uv) {
	vec3 addr = visual_tile_address(uv);
	ivec3 sz = textureSize(visual_height_tiles, 0);
	// GLES3/WebGL2 不接受 ivec3(vec2,int) 构造（桌面 glslang 放行），必须显式先转 ivec2，
	// 否则 MAP_VISUAL_TILED 变体在 Compatibility 上整 shader 编译失败（2026-08-05 探针实锤）。
	ivec2 txy = ivec2(clamp(addr.xy * vec2(sz.xy), vec2(0.0), vec2(sz.xy) - vec2(1.0)));
	ivec3 tc = ivec3(txy, int(addr.z));
	return texelFetch(visual_height_tiles, tc, 0).b;
}
#else
ivec2 visual_flow_texture_size() { return textureSize(height_tex, 0); }
float visual_flow_texel(vec2 uv) {
	ivec2 sz = textureSize(height_tex, 0);
	vec2 wuv = visual_static_wrap_uv(uv);
	ivec2 tc = ivec2(clamp(wuv * vec2(sz), vec2(0.0), vec2(sz) - vec2(1.0)));
	return texelFetch(height_tex, tc, 0).b;
}
#endif
#endif

#ifdef VT_USE_WATER_DEPTH
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_water_depth_tiles : filter_linear, repeat_disable;
vec4 visual_sample_water_depth(vec2 uv) { return texture(visual_water_depth_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D water_depth_tex : filter_linear, repeat_disable;
vec4 visual_sample_water_depth(vec2 uv) { return texture(water_depth_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_TERRAIN_DETAIL
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_terrain_detail_tiles : filter_linear, repeat_disable;
vec4 visual_sample_terrain_detail(vec2 uv) { return texture(visual_terrain_detail_tiles, visual_tile_address(uv)); }
#else
// [web-high-features 2026-11-01 / 方案 B] 非 tiled 的 detail 改读 terrain_surface_tex
// layer2（world UV），不再声明 2D terrain_detail_tex —— 省出的槽留给水面/GI 之外的东西，
// 陆地程序 sampler 数保持不变。layer_count<3（方案 A 的 2 层旧图/fallback）返回中性
// 0.5 ⇒ 解码后恒等 1.0，等价于"没有 detail"。
#ifndef PK_TERRAIN_BAKED_NORMALS
#error "non-tiled VT_USE_TERRAIN_DETAIL requires the packed terrain_surface_tex layers"
#endif
#ifndef VT_USE_TERRAIN_SURFACE_ARRAY
#error "non-tiled VT_USE_TERRAIN_DETAIL requires VT_USE_TERRAIN_SURFACE_ARRAY"
#endif
vec4 visual_sample_terrain_detail(vec2 uv) {
	if (terrain_surface_layer_count < 3) {
		return vec4(0.5);
	}
	return texture(terrain_surface_tex, vec3(visual_static_wrap_uv(uv), TS_LAYER_DETAIL));
}
#endif
#endif

#ifdef VT_USE_TERRAIN_DETAIL
// [web-high-features 2026-11-01 / B] detail 层是否可用：tiled = 2D 纹理已绑，
// 非 tiled = surface array 的 layer_count>=3。运行期门控，调用方据此决定是否早退到
// 程序化配方（visual_quality 门控在外层，LOW 行为不变）。
bool terrain_detail_available() {
#ifdef MAP_VISUAL_TILED
	return has_terrain_detail_tex;
#else
	return terrain_detail_layer_bound;
#endif
}
#endif

#ifdef PK_TERRAIN_PACKED_BOUNCE
// [web-high-features 2026-11-01 / 方案 B] 非 tiled Web/Compatibility 的 GI 弹射遮挡源：
// 从 terrain_surface_tex layer3 取两个 16-bit cell id。**必须 texelFetch**（cell id 不能
// 插值）；GLES3/WebGL2 不接受 ivec3(vec2,int) 构造，必须显式 ivec3(tx,ty,layer)。
// layer_count<4 时返回 0xFFFF 哨兵（两个 cell id 全无效 ⇒ 无弹射）。
vec4 visual_sample_packed_occluder(vec2 uv) {
	if (terrain_surface_layer_count < 4) {
		return vec4(1.0);
	}
	ivec2 sz = textureSize(terrain_surface_tex, 0).xy;
	vec2 wuv = visual_static_wrap_uv(uv);
	ivec2 tx = ivec2(clamp(wuv * vec2(sz), vec2(0.0), vec2(sz) - vec2(1.0)));
	return texelFetch(terrain_surface_tex, ivec3(tx, int(TS_LAYER_OCCLUDER)), 0);
}
#endif

#ifdef VT_USE_EDGE_NEIGHBOR
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_edge_neighbor_tiles : filter_nearest, repeat_disable;
vec4 visual_sample_edge_neighbor(vec2 uv) { return texture(visual_edge_neighbor_tiles, visual_tile_address(uv)); }
#elif defined(VT_USE_TERRAIN_SURFACE_ARRAY)
// [surface-array-edge 2026-11-02] 次生 cell id 走 terrain_surface_tex layer5 的 RG。
// **必须 texelFetch**：这张 array 是 filter_linear，对 id 做任何插值都会得到垃圾 cell；
// 写法与 visual_sample_packed_occluder 一致（GLES3 不接受 ivec3(vec2,int) 构造）。
// terrain_edge_layers_bound=false（旧图 / 烘失败）→ 0xFFFF 哨兵 ⇒ decode 返回 -1，
// 次生混合整条关闭、退化为硬主 cell 边界，而不是采样越界层。
vec4 visual_sample_edge_neighbor(vec2 uv) {
	if (!terrain_edge_layers_bound) {
		return vec4(1.0);
	}
	ivec2 sz = textureSize(terrain_surface_tex, 0).xy;
	vec2 wuv = visual_static_wrap_uv(uv);
	ivec2 tx = ivec2(clamp(wuv * vec2(sz), vec2(0.0), vec2(sz) - 1.0));
	return texelFetch(terrain_surface_tex, ivec3(tx, int(TS_LAYER_EDGE_NEIGHBOR)), 0);
}
#else
uniform sampler2D terrain_edge_neighbor_tex : filter_nearest, repeat_disable;
vec4 visual_sample_edge_neighbor(vec2 uv) { return texture(terrain_edge_neighbor_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_EDGE_DISTANCE
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_edge_distance_tiles : filter_linear, repeat_disable;
vec4 visual_sample_edge_distance(vec2 uv) { return texture(visual_edge_distance_tiles, visual_tile_address(uv)); }
#elif defined(VT_USE_TERRAIN_SURFACE_ARRAY)
// [surface-array-edge 2026-11-02] layer4：R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比。
// LINEAR 采样（距离与占比都是连续量，双线性正是"方块变连续"的来源）。
// 中性值 = 距离 1.0（权重 0）、无 crease、无海岸占比 —— 等价于"没有 edge 数据"。
vec4 visual_sample_edge_distance(vec2 uv) {
	if (!terrain_edge_layers_bound) {
		return vec4(1.0, 0.0, 0.0, 0.0);
	}
	return texture(terrain_surface_tex, vec3(visual_static_wrap_uv(uv), TS_LAYER_EDGE_DISTANCE));
}
#else
uniform sampler2D terrain_edge_distance_tex : filter_linear, repeat_disable;
vec4 visual_sample_edge_distance(vec2 uv) { return texture(terrain_edge_distance_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

// [surface-array-edge 2026-11-02] 无噪声、无 fwidth 的静态次生权重：只吃 edge_distance.r。
// 与 terrain_edge_secondary_weight_d 的移动端分支同一公式（那里也改调本函数），
// 供没有 noise_tex / 没有 terrain_surface_detail 的程序（Web compact 水面）复用。
float terrain_static_edge_weight(float distance_to_edge, float width) {
	float w = clamp(width, 1.0 / 255.0, 0.98);
	return 0.5 * (1.0 - smoothstep(0.0, w, distance_to_edge));
}
