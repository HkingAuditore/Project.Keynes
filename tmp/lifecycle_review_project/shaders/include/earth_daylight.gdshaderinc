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
const vec3 EARTH_DAYLIGHT_DUSK = vec3(1.0, 0.74, 0.58);   // 晨昏暖琥珀白（避免橙色聚光）
const vec3 EARTH_NIGHT_AMBIENT = vec3(0.13, 0.16, 0.25);  // 夜侧冷蓝月光
const vec3 EARTH_DAY_AMBIENT   = vec3(0.60, 0.66, 0.77);  // 白昼天空环境光
const vec3 EARTH_MOONLIGHT     = vec3(0.48, 0.58, 0.82);  // 可读性优先的冷蓝月光
const float EARTH_MOON_GAIN    = 0.72;
// 永昼没有晨昏线提供运动参照：降低平铺天光、略抬方向光，使光向旋转能投射到坡面/植被/水面。
const float EARTH_ETERNAL_AMBIENT_GAIN = 0.88;
const float EARTH_ETERNAL_SUN_GAIN = 1.18;

float earth_daylight_longitude_u(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return fract(uv.x);
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	return fract((world_x - wrap_origin_x) / wrap_period_x);
}

float earth_daylight_declination() {
	if (tod_debug_sun_position_enabled) {
		return (clamp(tod_debug_sun_uv.y, 0.0, 1.0) * 2.0 - 1.0) * 1.5707963;
	}
	float year_progress = mod(season_phase, 4.0) * 0.25;
	return axial_tilt_rad * cos(EARTH_DAYLIGHT_TAU * year_progress);
}

float earth_daylight_subsolar_lon() {
	return (tod_debug_sun_position_enabled ? fract(tod_debug_sun_uv.x) : day_phase) * EARTH_DAYLIGHT_TAU;
}

float earth_daylight_scale_elevation_sin(float sinh) {
	float scale = max(tod_debug_sun_height_scale, 0.01);
	if (abs(scale - 1.0) <= 0.0001) {
		return sinh;
	}
	float elev = asin(clamp(sinh, -1.0, 1.0));
	return sin(clamp(elev * scale, -1.5707963, 1.5707963));
}

vec3 earth_daylight_scale_dir_elevation(vec3 d) {
	float scale = max(tod_debug_sun_height_scale, 0.01);
	if (abs(scale - 1.0) <= 0.0001) {
		return d;
	}
	float horiz_len = length(d.xy);
	float elev = atan(d.z, max(horiz_len, 1e-5));
	float scaled_elev = clamp(elev * scale, -1.5707963, 1.5707963);
	vec2 axis = (horiz_len > 1e-5) ? d.xy / horiz_len : vec2(1.0, 0.0);
	return vec3(axis * cos(scaled_elev), sin(scaled_elev));
}

// sin(太阳高度角)：见文件头公式。经度周期量 → 东西 tile 边界处 cos(H) 相等，晨昏线无缝。
float compute_solar_elevation(vec2 uv, float lat_signed) {
	float decl = earth_daylight_declination();
	float lat_rad = lat_signed * 1.5707963;            // 与 insolation lat_rad 同源
	float lon = earth_daylight_longitude_u(uv) * EARTH_DAYLIGHT_TAU; // 经度（周期）→ 东西无缝
	float subsolar_lon = earth_daylight_subsolar_lon(); // 正午经度随视觉昼夜相位绕圈
	float H = lon - subsolar_lon;
	float sinh = sin(lat_rad) * sin(decl) + cos(lat_rad) * cos(decl) * cos(H);
	return earth_daylight_scale_elevation_sin(sinh);
}

// [tod-latitude-sun 2026-06-25] 逐像素太阳方向（近似点光源）。
// 用与 compute_solar_elevation 完全同源的 decl / lat_rad / 时角 H，把太阳在该像素「本地
// ENU 切平面」里的方向解析出来，再转成 shader 空间单位向量 (x=东, y=北[屏幕+y], z=上)。
// [N-S 符号修正 2026-06-25] y 取 +north：屏幕 +y = 北（由纬度映射决定，详见函数体内注释）。
//   sun_enu = (东=-cosδ·sinH, 北=cosφ·sinδ−sinφ·cosδ·cosH, 上=sinφ·sinδ+cosφ·cosδ·cosH)
// 关键性质：返回向量为单位向量，水平分量长度 = cos(h)、垂直分量 = sin(h)：
//   - 太阳高悬(subsolar 附近) → 近竖直 → 坡面受光均匀 → 短影 / 弱方向感
//   - 太阳低垂(高纬 / 近晨昏)  → 近水平 → 坡面明暗强烈 → 长影 / 强方向感
// 不同纬度 φ 与时角 H 各异 → 各像素阴影方向与长度天然不同（这正是"点光源式太阳"诉求）。
// up 分量与 compute_solar_elevation 完全相等（= sinh），昼夜/晨昏判定可直接复用 .z。
vec3 compute_sun_dir_enu(vec2 uv, float lat_signed) {
	float decl = earth_daylight_declination();
	float lat_rad = lat_signed * 1.5707963;
	float lon = earth_daylight_longitude_u(uv) * EARTH_DAYLIGHT_TAU;
	float subsolar_lon = earth_daylight_subsolar_lon();
	float H = lon - subsolar_lon;
	float sphi = sin(lat_rad);
	float cphi = cos(lat_rad);
	float sdec = sin(decl);
	float cdec = cos(decl);
	float cH = cos(H);
	float sH = sin(H);
	float up    = sphi * sdec + cphi * cdec * cH;   // = sin(h)
	float east  = -cdec * sH;                        // 本地东向分量
	float north = cphi * sdec - sphi * cdec * cH;    // 本地北向分量
	// [N-S 符号修正 2026-06-25] 屏幕 y 约定以纬度映射为准：world_map 里
	//   lat_norm 随 uv.y 增大而增大、lat_signed=+1(北极) 落在 uv.y 最大处=屏幕底部(+y)，
	//   即【屏幕 +y = 北】（与地形法线 N.y 同空间：N.y>0 也指向 +y=北）。
	// 旧代码误以为 +y=南而把 north 取负塞进 .y → 太阳南北方向整体反向（太阳在北时北坡反而变暗）。
	// 正确做法：north 直接进 .y（北 = +y），与地形法线、纬度日照保持同一约定。
	vec3 d = earth_daylight_scale_dir_elevation(vec3(east, north, up));
	float len = length(d);
	return (len > 1e-5) ? d / len : vec3(0.0, 0.0, 1.0);
}

// 关闭昼夜时使用年度太阳轨迹：season_phase 本身由游戏日期驱动，天然服从倍速与暂停。
// 方位一年恰好转一圈；高度只由直射点纬度（太阳赤纬）决定，不读取日相位/视觉晨昏线。
vec3 compute_global_parallel_sun_dir() {
	// 调试场景的永昼方位/高度滑块沿用既有 tod_sun_dir；正式玩家模式未开启该覆盖，
	// 因而仍进入下面与游戏日期绑定的年度自动轨迹。
	if (tod_debug_sun_position_enabled) {
		float debug_len = length(tod_sun_dir);
		return (debug_len > 1e-5) ? tod_sun_dir / debug_len : vec3(0.0, 0.0, 1.0);
	}
	float year_progress = mod(season_phase, 4.0) * 0.25;
	// 地形法线/阴影采样使用的是“从受光点指向光源”的方向；年度轨迹此前少了半圈，
	// 结果正好表现为七月北坡背阴、一月南坡背阴。补上 PI 只翻转永昼水平光向。
	float azimuth = EARTH_DAYLIGHT_TAU * year_progress + 1.5707963;
	float declination = earth_daylight_declination();
	float latitude_ratio = clamp(abs(declination) / max(abs(axial_tilt_rad), 1e-4), 0.0, 1.0);
	// 春秋分 70°、南北至日 30°：扩大季节阴影长度差，同时避开近地平线的极端投影。
	float elevation = radians(70.0 - 40.0 * latitude_ratio);
	vec3 d = vec3(cos(azimuth) * cos(elevation), sin(azimuth) * cos(elevation), sin(elevation));
	float len = length(d);
	return (len > 1e-5) ? d / len : vec3(0.0, 0.0, 1.0);
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
	float moon_strength;// 夜侧月光主光强度，晨昏平滑淡入
	vec3 sun_col;       // 方向光颜色（晨昏暖橙 ↔ 正午暖白）
	vec3 amb_col;       // 环境光颜色（夜冷蓝 ↔ 昼天空）
	vec3 sun_dir;       // [tod-latitude-sun] 逐像素太阳方向（shader 空间单位向量，含纬度/时角）
	vec3 moon_dir;      // 与太阳相对的月光方向
	vec3 moon_col;
};

// 给定像素 uv + 纬度，返回昼夜/晨昏统一光照量。enable_day_night=false → 全局平行光永昼。
// 各管线（PBR 地形 / 平面植被 / 水面）据此自行组装最终着色（线性 or sRGB、是否 tonemap）。
// 注：参数名刻意避开 uniform day_night_enabled，否则在已声明该 uniform 的 shader 里会重定义。
EarthDaylight eval_earth_daylight(vec2 uv, float lat_signed, bool enable_day_night) {
	vec3 sdir = enable_day_night ? compute_sun_dir_enu(uv, lat_signed) : compute_global_parallel_sun_dir();
	float sinh = sdir.z;  // = sin(太阳高度角)，与 compute_solar_elevation 等价（同源公式）
	EarthDaylight ed;
	ed.sun_dir = sdir;
	ed.local_day = enable_day_night ? solar_day_factor(sinh) : 1.0;
	ed.pixel_night = 1.0 - ed.local_day;
	ed.sun_high = smoothstep(0.0, 0.32, sinh);
	ed.moon_strength = enable_day_night
		? smoothstep(0.02, 0.28, -sinh) * EARTH_MOON_GAIN
		: 0.0;
	ed.sun_col = mix(EARTH_DAYLIGHT_DUSK, EARTH_DAYLIGHT_NOON, ed.sun_high);
	ed.amb_col = mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, ed.local_day);
	if (!enable_day_night) {
		ed.sun_col *= EARTH_ETERNAL_SUN_GAIN;
		ed.amb_col *= EARTH_ETERNAL_AMBIENT_GAIN;
	}
	ed.moon_dir = -sdir;
	ed.moon_col = EARTH_MOONLIGHT;
	return ed;
}

// ─────────────────────────────────────────────────────────────────────────
// [sky-sh-ambient] L1 球谐天光（次级方向化补光）— 地形/水面/植被统一真源。
//   动机（Why）：原 amb_col 是「平铺」环境光（不随法线变化）→ 太阳低垂/夜侧时方向光衰减，
//   场景失去体积感。天空本身是一块大面积低强度光源（天顶冷亮、近地暖暗、太阳方位更亮）。
//   用 L1（线性）球谐近似该半球辐照：amb(N) = DC + 梯度·N。给坡面/植株/水波在弱直射时
//   仍有方向性明暗 → 体积感。它【替换】平铺 amb_col（DC≈原值，保总亮度），不是额外叠加。
//   成本（Cost）：纯 ALU（1 normalize + 几次 mix/dot），无纹理 fetch。
//
//   坐标约定：shader 空间 N=(东, 北[屏幕+y], 上[朝相机]) 与 sun_dir 同空间；+z=天顶。
//   三段构成（即 L1 SH 的 DC + z 带 + 水平带）：
//     1) 垂直色温梯度 tint：天顶偏冷、近地偏暖（乘子均值≈1，不改整体亮度）。
//     2) 半球遮蔽 hemi：朝下面看到的天空更少 → 略暗（EARTH_SKY_GROUND_DIM）。
//     3) 太阳方位散射：朝太阳水平方向的面获微弱暖补光（随 local_day 白昼淡入）。
// ─────────────────────────────────────────────────────────────────────────
const vec3  EARTH_SKY_ZENITH_TINT = vec3(0.88, 0.96, 1.12); // 天顶冷蓝乘子（均值≈1）
const vec3  EARTH_SKY_NADIR_TINT  = vec3(1.12, 1.00, 0.86); // 近地暖反照乘子（均值≈1）
const float EARTH_SKY_VERTICAL    = 0.16;  // 垂直色温梯度强度（0=回退平铺）
const float EARTH_SKY_GROUND_DIM  = 0.86;  // 朝下面相对天顶的亮度下限（半球遮蔽）
const float EARTH_SKY_SUNWRAP     = 0.10;  // 太阳方位散射补光强度（白昼）

// 显式参数版（任意域可调用）：amb/sun 为色板域颜色，sun_dir 为单位向量，N 为表面法线。
vec3 earth_sky_sh(vec3 amb_col, vec3 sun_col, vec3 sun_dir, float local_day, vec3 N) {
	vec3 n = normalize(N);
	float up = n.z * 0.5 + 0.5;                              // 0=朝下 1=天顶
	vec3 tint = mix(EARTH_SKY_NADIR_TINT, EARTH_SKY_ZENITH_TINT, up);
	tint = mix(vec3(1.0), tint, EARTH_SKY_VERTICAL);        // 强度=0 → 乘子退回 1（平铺）
	float hemi = mix(EARTH_SKY_GROUND_DIM, 1.0, up);
	vec3 amb = amb_col * tint * hemi;
	float az = clamp(dot(n.xy, sun_dir.xy), -1.0, 1.0) * 0.5 + 0.5; // 朝太阳方位 →1
	amb += sun_col * (az * EARTH_SKY_SUNWRAP * local_day);
	return max(amb, vec3(0.0));
}

// 便捷版（消费方已有 EarthDaylight）：与 earth_sky_sh 同算法。
vec3 eval_earth_sky_sh(EarthDaylight ed, vec3 N) {
	return earth_sky_sh(ed.amb_col, ed.sun_col, ed.sun_dir, ed.local_day, N);
}

#endif // EARTH_DAYLIGHT_INC
