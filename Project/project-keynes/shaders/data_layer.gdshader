shader_type canvas_item;
render_mode blend_mix;

// ══════════════════════════════════════════════════════════════════
// data_layer.gdshader — 玩家「数据图层」分块设色 overlay（2026-07-23）
//
// 机制完全复用 weather_overlay 的逐格间接寻址：map_index_atlas 的 G/B 通道
// 存 cell.index（低/高字节），shader 解码后按 (cid%lw, cid/lw) 采样 per-cell
// data_lut（由 MapDataLayerOverlay 在 GDScript 侧烘焙，RGBA8，rgb=显示色，a=存在度）。
//
// 半透明 tint 盖在地形上（overlay_alpha≈0.7），地形底图仍可透出；位于地形
// quad(z=0) 之上、WeatherLayer(z=4) 之下（z_index=3），云层仍压在最上。
// ═══════════════════════════��══════════════════════════════════════

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable; // R=biome ; G/B=cell.index 低/高字节
uniform sampler2D data_lut : filter_nearest, repeat_disable;          // 逐格 RGBA8：rgb=显示色，a=存在度
uniform vec2 lut_dims = vec2(0.0);

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float hex_world_diameter = 38.0;
uniform float overlay_alpha : hint_range(0.0, 1.0) = 0.7;
uniform bool show_hex_edge = true;
uniform vec3 edge_color = vec3(1.0, 0.97, 0.90);
uniform float edge_alpha : hint_range(0.0, 0.5) = 0.10;

varying vec2 v_world;

vec2 wx_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

// 与 weather_overlay.wx_decode_cell_index 同公式（map_index_atlas.GB = 低/高字节）。
int decode_cell_index(vec2 uv) {
	vec2 gb = texture(map_index_atlas, wx_wrap_uv(uv)).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

vec4 sample_lut(int cid) {
	return texture(data_lut, cell_lut_uv(cid));
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 uv = wx_wrap_uv((v_world - world_origin) / world_size);
	int cid = decode_cell_index(uv);
	COLOR = vec4(0.0);

	if (cid >= 0) {
		vec4 col = sample_lut(cid);
		if (col.a > 0.002) {
			vec3 out_col = col.rgb;
			float out_a = clamp(col.a * overlay_alpha, 0.0, 1.0);

			// 极细「分块」边：比较邻域 cell.index 是否变化（仅 x/y 两方向，开销低）。
			if (show_hex_edge) {
				vec2 cstep = hex_world_diameter / max(world_size, vec2(0.001));
				vec2 uvx = wx_wrap_uv((v_world - world_origin) / world_size + vec2(cstep.x, 0.0));
				vec2 uvy = wx_wrap_uv((v_world - world_origin) / world_size + vec2(0.0, cstep.y));
				int ncx = decode_cell_index(uvx);
				int ncy = decode_cell_index(uvy);
				float edge = 0.0;
				if (ncx != cid || ncy != cid) { edge = 1.0; }
				out_col = mix(out_col, edge_color, edge * 0.55);
				out_a = max(out_a, edge * edge_alpha);
			}

			COLOR = vec4(out_col, out_a);
		}
	}
}
