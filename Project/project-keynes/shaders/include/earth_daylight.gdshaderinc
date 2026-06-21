// earth_daylight.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// [cylindrical-earth-daylight] 地球式昼夜（晨昏线）单一真源（single source of truth）。
//   职责（What）：用球面天文公式按"每个像素自己的经纬度"求太阳高度角 → 昼夜/晨昏，
//   并给出与之配套的「昼/晨昏/夜」色板。地形(brdf)、水面(water_pipeline)、
//   植被(shrub_layer) 全部统一 include 本文件，杜绝公式/色板在各处复制后漂移。
//
//   sin(h)=sin(lat)·sin(δ)+cos(lat)·cos(δ)·cos(H)
//     H(时角)=经度−正午经度(subsolar)；δ(赤纬)=季节。
//   经度 lon=uv.x·TAU 为周期量 → 东西晨昏线无缝环绕；lat_rad/decl 与
//   climate_season.compute_insolation_shader 同源 → "长昼半球"==高日照(暖)半球。
//
// 依赖（Why）：caller 必须在 include 本文件之前声明下列同名 uniform：
//   uniform float season_phase;     // 0=春 1=夏 2=秋 3=冬（mod 4）
//   uniform float day_phase;        // [0,1) 视觉昼夜相位（正午经度绕圈）
//   uniform float axial_tilt_rad;   // 地轴倾角(rad)，驱动季节赤纬
//   （地形/水面经 uniforms.gdshaderinc 提供；植被 shader 在自身 uniform 段声明。）
//   day_night_enabled 由各 eval 调用方以参数传入，本文件不直接读该 uniform。
//
// 成本（Cost）：纯 ALU，无纹理 fetch；compute_solar_elevation ≈ 2 sin + 2 cos + 杂项。
// ─────────────────────────────────────────────────────────────────────────
#ifndef EARTH_DAYLIGHT_INC
#define EARTH_DAYLIGHT_INC

const float EARTH_DAYLIGHT_TAU = 6.2831853;

// 昼/晨昏/夜色板：全图常量（不随全局相位漂移），与历史 brdf.make_lighting_context 同值。
const vec3 EARTH_DAYLIGHT_NOON = vec3(1.0, 0.97, 0.92);   // 正午暖白
const vec3 EARTH_DAYLIGHT_DUSK = vec3(1.0, 0.56, 0.31);   // 晨昏暖橙（暮光带）
const vec3 EARTH_NIGHT_AMBIENT = vec3(0.13, 0.16, 0.25);  // 夜侧冷蓝月光
const vec3 EARTH_DAY_AMBIENT   = vec3(0.60, 0.66, 0.77);  // 白昼天空环境光

// sin(太阳高度角)：见文件头公式。经度周期量 → uv.x=0 与 1 处 cos(H) 相等，晨昏线无缝。
float compute_solar_elevation(vec2 uv, float lat_signed) {
	float year_progress = mod(season_phase, 4.0) * 0.25;
	// 与 compute_insolation_shader 的 subsolar 同式：phase=0 → +tilt。
	float decl = axial_tilt_rad * cos(EARTH_DAYLIGHT_TAU * year_progress);
	float lat_rad = lat_signed * 1.5707963;            // 与 insolation lat_rad 同源
	float lon = uv.x * EARTH_DAYLIGHT_TAU;             // 经度（周期）→ 东西无缝
	float subsolar_lon = day_phase * EARTH_DAYLIGHT_TAU; // 正午经度随视觉昼夜相位绕圈
	float H = lon - subsolar_lon;
	return sin(lat_rad) * sin(decl) + cos(lat_rad) * cos(decl) * cos(H);
}

// sinh → local_day ∈ [0,1]：1=白昼 0=夜晚 (0,1)=晨昏过渡带（band 控柔度）。
float solar_day_factor(float sinh) {
	return smoothstep(-0.14, 0.14, sinh);
}

// 统一昼夜取样结果：昼夜系数 + 配套的「昼/晨昏」太阳色与「昼/夜」环境色。
struct EarthDaylight {
	float local_day;    // 1=昼 0=夜
	float pixel_night;  // 1 - local_day
	float sun_high;     // 太阳高悬程度（晨昏 0 → 正午 1），驱动暖橙↔暖白
	vec3 sun_col;       // 方向光颜色（晨昏暖橙 ↔ 正午暖白）
	vec3 amb_col;       // 环境光颜色（夜冷蓝 ↔ 昼天空）
};

// 给定像素 uv + 纬度，返回昼夜/晨昏统一光照量。enable_day_night=false → 退化为永昼。
// 各管线（PBR 地形 / 平面植被 / 水面）据此自行组装最终着色（线性 or sRGB、是否 tonemap）。
// 注：参数名刻意避开 uniform day_night_enabled，否则在已声明该 uniform 的 shader 里会重定义。
EarthDaylight eval_earth_daylight(vec2 uv, float lat_signed, bool enable_day_night) {
	float sinh = compute_solar_elevation(uv, lat_signed);
	EarthDaylight ed;
	ed.local_day = enable_day_night ? solar_day_factor(sinh) : 1.0;
	ed.pixel_night = 1.0 - ed.local_day;
	ed.sun_high = smoothstep(0.0, 0.32, sinh);
	ed.sun_col = mix(EARTH_DAYLIGHT_DUSK, EARTH_DAYLIGHT_NOON, ed.sun_high);
	ed.amb_col = mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, ed.local_day);
	return ed;
}

#endif // EARTH_DAYLIGHT_INC
