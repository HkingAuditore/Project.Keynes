shader_type canvas_item;
render_mode blend_mix;

// world_map.gdshader v9.atlas锛氶珮鍒嗚鲸鐜囧湴鐞嗕豢鐪熸覆鏌?//
// 杈撳叆绾圭悊锛?//   height_tex       (RG8 16-bit, hm_size, LINEAR)
//                     褰掍竴鍖栨捣鎷?[0, 1]锛岃В鐮?(R*256 + G) / 257
//   enum_atlas       (RGB8, derived_size, NEAREST)
//                     R = biome (TerrainType.TERRAIN id)
//                     G = vegetation (VegetationType.VEG id)
//                     B = cover (CoverType.CV id)
//   scalar_atlas     (RGBA8, derived_size, LINEAR)
//                     R = moisture
//                     G = flow_accum (log-scaled)
//                     B = latitude_norm 鈭?[0, 1]
//                     A = volcano_field
//   vector_atlas     (RGBA8, derived_size, LINEAR)
//                     RG = ocean_current (-1..1 mapped from 0..1)
//                     BA = wind_field    (-1..1 mapped from 0..1)
//
// 涓嶅啀鏈?hex 閫昏緫銆佷笉鍐嶅仛 domain warp銆傛暣寮犲湴鍥惧氨鏄繖 4 寮犺繛缁汗鐞嗙殑鍚堟垚銆?
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D enum_atlas   : filter_nearest, repeat_disable;
uniform sampler2D scalar_atlas : filter_linear,  repeat_disable;
uniform sampler2D vector_atlas : filter_linear,  repeat_disable;
// v9.fbm-opt锛氬叡浜?noise 璐村浘锛?56脳256 R8 tileable锛岀敱 MapBaker 鐑樼剻锛夈€?// value_noise(p) 鏀圭敤 texture(noise_tex, p / NOISE_TEX_SCALE).r 瀹炵幇锛?// 鍗?octave 浠?4脳 hash21 + smoothstep mix"闄嶄负 1 娆?bilinear fetch锛圙PU 纭欢鍔犻€燂級銆?uniform sampler2D noise_tex    : filter_linear_mipmap, repeat_enable;
const float NOISE_TEX_SCALE = 256.0;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform vec2 derived_resolution = vec2(1024.0, 768.0);

uniform float sea_level : hint_range(0.0, 1.0) = 0.42;

// 鈹€鈹€鈹€ Phase 1锛氬鑺傜浉浣?+ 姘斿€欏紓甯革紙姣忓抚鐢?WorldClock 椹卞姩锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// season_phase 鈭?[0, 4)锛?=鏄?1=澶?2=绉?3=鍐?// climate_anomaly 鈭?[-0.2, +0.2]锛氶暱鏈熸皵娓╁亸绉?// world_time锛氱疮绉鏁帮紝缁欐捣娲嬫磱娴佹祦绾瑰姩鐢荤敤锛圥hase 3锛?uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float climate_anomaly : hint_range(-0.5, 0.5) = 0.0;
uniform float world_time = 0.0;

// 鈹€鈹€鈹€ 浠诲姟 2/3锛氭樇澶滃惊鐜紙1 涓父鎴忓 = 1 娆″畬鏁存樇澶滐級 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// day_phase 鈭?[0, 1)锛?.0=鏃ュ嚭 0.25=姝ｅ崍 0.5=鏃ヨ惤 0.75=鍗堝銆?// 鐢?WorldClock.day_phase_changed 鈫?HexRenderer.set_day_phase 鎺ㄥ叆锛涢粯璁ら€愬抚鏇存柊锛?// 浠呭綋 WorldClock.day_phase_emit_step > 0 鏃舵墠鎸夌浉浣嶆闀胯妭娴併€?uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform bool day_night_enabled = true;
// 澶滄櫄鏁翠綋浜害鍘嬪埌鐧藉ぉ鐨?[min, max]锛涢粯璁?0.35~0.55锛堥渶姹?3.4锛?uniform float night_brightness_min : hint_range(0.0, 1.0) = 0.35;
uniform float night_brightness_max : hint_range(0.0, 1.0) = 0.55;

// 鈹€鈹€鈹€ Pass 2锛堜换鍔?2锛夛細TOD 鍏ㄥ眬鍏夌収 uniform锛堝崟涓€鏁版嵁婧愶級 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 鐢?TODProfile 缁?HexRenderer.apply_tod 鎺ㄥ叆銆傜姝㈠湪 shader 鍐呰嚜琛屼粠 day_phase
// 鎺ㄥ鑹叉俯 / 鏃ュ厜鏂瑰悜锛沝ay_phase 浠呯敤浜?绮煎厜鐩镐綅 / 浜戠Щ鐩镐綅"杩欑被鍔ㄧ敾銆?// tod_sun_dir锛氬垏绾跨┖闂翠笅鐨勫叆灏勫厜鏂瑰悜锛堝凡褰掍竴鍖栵紝z 涓哄浐瀹氶珮搴﹀垎閲忥級
uniform vec3  tod_sun_dir       = vec3(0.4, -0.7, 0.6);
uniform vec3  tod_sun_color     : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3  tod_ambient_color : source_color = vec3(0.65, 0.68, 0.75);
// night_factor 鈭?[0, 1]锛?=鐧藉ぉ 1=澶滄櫄锛涗緵鍦拌〃/姘翠綋/绮掑瓙鍋氫竴鑷寸殑澶滄櫄鏌撹壊
uniform float tod_night_factor  : hint_range(0.0, 1.0) = 0.0;
// tod_exposure锛氭渶缁?tonemap 鍓嶇殑鏇濆厜鍊嶇巼锛堣壓鏈寲璋冭妭鐢級
uniform float tod_exposure      : hint_range(0.2, 2.5) = 1.0;

// 鈹€鈹€鈹€ Pass 2 鏂板寮€鍏筹紙浠诲姟 4/6锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// water_sparkle_enabled锛氭按闈㈤珮棰戠布鍏夛紙NdotH Blinn-Phong锛夋€诲紑鍏炽€?// cloud_tod_tint_enabled锛氬彧缁欎簯闃村奖鐢紱浜戞湰浣撴覆鏌撳湪 weather_overlay.gdshader銆?uniform bool water_sparkle_enabled = true;
uniform bool cloud_tod_tint_enabled = true;

// 鈹€鈹€鈹€ Water Visual Overhaul锛堟湰杞級锛氭按浣撳瓙鐗规€х嫭绔嬪紑鍏充笌鍙傛暟 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 杩欑粍寮€鍏冲搴?requirements.md 鐨勯渶姹?1/2/4/5 鐨勭粏鍒嗗瓙绯荤粺锛屼繚璇?澶т竴閿叧"
// 锛坵ater_effect_enabled=false锛変箣澶栵紝杩樿兘閫愪釜鍒囨崲姣忎釜鏁堟灉銆?uniform bool  water_waves_enabled            = true;   // 缁熶竴娉㈡氮楂樺害鍦猴紙闇€姹?1锛?uniform bool  water_fresnel_enabled          = true;   // 鑿叉秴灏斿ぉ绌哄弽灏勶紙闇€姹?2锛?uniform bool  river_flow_enabled             = true;   // 娌虫祦娴佸姩鏉＄汗锛堥渶姹?4锛?uniform bool  caustics_enabled               = true;   // 鐝婄憵绀佺劍鏁ｏ紙闇€姹?5.1锛?uniform bool  shallow_transparency_enabled   = true;   // 娴呮捣/娴呮箹閫忓簳锛堥渶姹?5.3/5.4锛?uniform float water_gloss                    : hint_range(4.0, 128.0) = 34.0;
uniform bool  water_waves_enabled            = true;
uniform bool  water_fresnel_enabled          = true;
uniform bool  river_flow_enabled             = true;
uniform bool  caustics_enabled               = true;
uniform bool  shallow_transparency_enabled   = true;
uniform float water_gloss                    : hint_range(4.0, 128.0) = 34.0;
uniform float water_reflection_strength      : hint_range(0.0, 1.0) = 0.32;
uniform float river_flow_speed               : hint_range(0.0, 4.0) = 0.75;
uniform float river_flow_freq                : hint_range(0.02, 1.0) = 0.16;
uniform float caustics_strength              : hint_range(0.0, 1.0) = 0.32;
uniform float deep_ocean_contrast            : hint_range(0.5, 3.0) = 0.96;
uniform vec3  lake_water_color : source_color = vec3(0.20, 0.48, 0.56);
uniform float shallow_transparency_factor    : hint_range(0.0, 1.0) = 0.56;
uniform float water_cartoon_color_strength   : hint_range(0.0, 1.0) = 0.75;
uniform float water_transition_softness      : hint_range(0.0, 1.0) = 1.0;
uniform float estuary_plume_strength         : hint_range(0.0, 1.0) = 0.65;

// ShaderToy 鍚彂鐨勪袱灞傝瑙夊寮猴紙鍙傝€?3tyBRh "2D Stylized Water" 涓?dtKcWz
// "2D Ocean Waves"锛夛細
//  - water_domain_warp_strength锛氬湪姘磋壊閲囨牱鍓嶆妸涓栫晫鍧愭爣鍋氫竴娆?fbm 鎵洸锛?//    璁?"婀?娴?绀?钘? 鐨勪氦鐣屼笉鍐嶆槸瑙勬暣鐩寸嚎锛岃€屾槸鍍忔按琚悈鏁ｄ竴鏍风殑 wavy edge銆?//  - water_wave_line_strength锛氬師涓?妯悜娉㈢棔鏉＄汗"鎬诲己搴︼紱鏈疆锛圵ater Calm
//    Noise锛夐噸鐢ㄤ负"鏌斿拰鍣０鎬诲紑鍏?/ 寮哄害"锛? = 瀹屽叏鍏抽棴鍣０灞傦紱榛樿鍊间綆浜?1锛?//    闃叉姘撮潰閲嶆柊鍑虹幇楂樺姣斿瘑闆嗙汗鐞嗭級銆傚瓧娈靛悕淇濈暀鏄负浜嗕笉鐮村潖鏃㈡湁 .tscn 搴忓垪鍖栥€?uniform float water_domain_warp_strength : hint_range(0.0, 4.0) = 1.45;
uniform float water_domain_warp_strength : hint_range(0.0, 4.0) = 1.45;
uniform float water_wave_line_strength   : hint_range(0.0, 1.0) = 0.70;
// 鈹€鈹€鈹€ Water Calm Noise锛堟湰杞級锛氫綆瀵规瘮搴︽煍鍜屽櫔澹扮殑涓や釜缁嗗垎寮哄害 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// water_calm_noise_brightness  : 浜害鎵板姩灞傦紙澶у昂搴?fbm锛岄粯璁ょ害 卤5%锛夌殑寮哄害绯绘暟
// water_calm_noise_tint_strength: 鑹茬浉鎵板姩灞傦紙鏇翠綆棰?fbm 鍦ㄥ喎/鏆?tint 涔嬮棿
//                                 mix锛岄粯璁ょ害 卤2%锛夌殑寮哄害绯绘暟
uniform float water_calm_noise_brightness    : hint_range(0.0, 1.0) = 0.70;
uniform float water_calm_noise_tint_strength : hint_range(0.0, 1.0) = 0.70;
// biome 杞贩鍚堝崐寰勶紙涓栫晫鍧愭爣鍗曚綅锛岃秺澶ц繃娓″甫瓒婂锛? = 鍏抽棴杞贩鍚堬紝鍥為€€鍒扮‖鍒囷級
uniform float water_biome_blend_radius   : hint_range(0.0, 4.0) = 3.15;

// 鈹€鈹€鈹€ 浠诲姟 1锛氳瑙夋€诲紑鍏筹紙shader 渚у崰浣嶏紱鍏蜂綋鍒嗘敮鍦ㄥ悗缁换鍔℃帴鍏ワ級 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 澹版槑涓?uniform 鏄负浜嗚 CPU 渚?set_shader_parameter 姘歌繙鏈夋晥锛岄伩鍏嶅啓鍏ヤ竴涓?// 涓嶅瓨鍦ㄧ殑 uniform 鏃?Godot 鎶?warning銆俿hader 鍐呴儴閫愭娑堣垂杩欎簺寮€鍏炽€?uniform int visual_quality : hint_range(0, 2) = 2;
uniform int visual_quality : hint_range(0, 2) = 2;
uniform bool water_effect_enabled = true;
uniform bool ocean_current_enabled = true;
uniform bool extreme_weather_ground_effect_enabled = true;

// 瀛ｈ妭娓╁害鎸箙銆?.20 = 澶忓啲涔嬮棿 卤20% 娓╁害宸紝姣旇緝鏄捐憲浣嗕笉澶稿紶
uniform float season_temp_amp : hint_range(0.0, 0.4) = 0.20;
// 妞嶈鎹㈣壊鎬诲紑鍏充笌寮哄害
uniform float vegetation_season_strength : hint_range(0.0, 1.0) = 0.85;
// 鍔ㄦ€侀洩閲忥紙瀛ｈ妭鎬ч洩鐩栧彔鍔犲湪 biome SNOW 涔嬪锛夋€诲紑鍏充笌寮哄害
uniform float dynamic_snow_strength : hint_range(0.0, 1.0) = 0.85;
// 娲嬫祦鍔ㄧ敾鎬诲紑鍏充笌寮哄害
uniform float ocean_current_strength : hint_range(0.0, 1.0) = 0.88;
// Phase 6锛氶檰鍦伴杩瑰櫔澹帮紙娌跨洓琛岄鏂瑰悜鐨勮交寰潯绾癸紝璁╅甯﹀彲瑙嗗寲锛?uniform float wind_streak_strength : hint_range(0.0, 0.20) = 0.05;
uniform float wind_streak_strength : hint_range(0.0, 0.20) = 0.05;

// 鈹€鈹€鈹€ 浠诲姟 9锛氭磱娴?椋庡甫鍙鍖?toggle 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// ocean_current_debug锛? = 姝ｅ父娓叉煋锛堜綆瀵规瘮娴佺汗锛夛紱1 = 璋冭瘯妯″紡锛堥珮瀵规瘮甯︾澶存劅娴佸悜锛夈€?// 杩愯鏃剁敱 main.gd 鐨?F6 蹇嵎閿?/ 椤舵爮鎸夐挳鍒囨崲銆?uniform bool  ocean_current_debug = false;
uniform bool  ocean_current_debug = false;
// 瀛ｉ闄嗗湴椋庣汗澧炲己鍊嶇巼锛氬湪 MONSOON type 閿嬮潰瑕嗙洊鍖哄煙锛岄檰鍦扮殑 wind_streak
// 鎸箙 脳monsoon_wind_streak_boost锛堥粯璁?3.0锛夛紝灏嗛潪涓昏椋庢劅鎻愬崌涓轰富浣撶壒寰併€?uniform float monsoon_wind_streak_boost : hint_range(1.0, 6.0) = 3.0;
uniform float monsoon_wind_streak_boost : hint_range(1.0, 6.0) = 3.0;
// Milestone 2锛氭琚?/ 瑕嗙洊鐗╄酱鐨勮瑙夊己搴?uniform float vegetation_axis_strength : hint_range(0.0, 1.0) = 0.35;
uniform float vegetation_axis_strength : hint_range(0.0, 1.0) = 0.35;
uniform float cover_axis_strength : hint_range(0.0, 1.0) = 0.65;

// 鈹€鈹€鈹€ Milestone 3锛氬ぉ姘斿瓙绯荤粺锛堟渶澶?MAX_WEATHER_FRONTS 涓椿璺冮攱闈級 鈹€鈹€鈹€鈹€鈹€鈹€
// CPU 绔?hex_renderer.gd 姣?鏃?閫氳繃 set_weather_fronts 鎺ㄩ€?vec4 + float 鏁扮粍锛?//   weather_front_centers[i] = (center.x, center.y, radius, intensity 鈭?[0,1])
//   weather_front_types[i]   = WeatherType.WT id锛? 0 琛ㄧず璇?slot 绌猴紝shader 璺宠繃锛?//   weather_front_count      = 瀹為檯娲昏穬鏁帮紙鈮?MAX_WEATHER_FRONTS锛?// fragment 绔惊鐜亶鍘嗭紝瀵规瘡涓?front 绠楅珮鏂鐩?鈫?max-merge 鍙栨渶寮?鈫?鎸夌被鍨嬪彔鍔?overlay銆?const int MAX_WEATHER_FRONTS = 16;
const int MAX_WEATHER_FRONTS = 16;
uniform vec4 weather_front_centers[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_shapes[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_visuals[MAX_WEATHER_FRONTS];
uniform float weather_front_types[MAX_WEATHER_FRONTS];
uniform int weather_front_count = 0;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;

// 鈹€鈹€鈹€ Hypsometric 鑹查樁锛堟捣闄嗗弻鍚戯紝绛夐珮绾胯鑹诧級 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
uniform vec3 color_deep_ocean   : source_color = vec3(0.055, 0.13, 0.30);
uniform vec3 color_mid_ocean    : source_color = vec3(0.11, 0.24, 0.42);
uniform vec3 color_shallow      : source_color = vec3(0.22, 0.42, 0.56);
uniform vec3 color_coast_water  : source_color = vec3(0.36, 0.62, 0.68);
uniform vec3 color_beach        : source_color = vec3(0.85, 0.78, 0.55);
uniform vec3 color_lowland      : source_color = vec3(0.62, 0.68, 0.42);
uniform vec3 color_hill         : source_color = vec3(0.66, 0.55, 0.32);
uniform vec3 color_mountain     : source_color = vec3(0.45, 0.38, 0.34);
uniform vec3 color_peak         : source_color = vec3(0.55, 0.50, 0.46);
uniform vec3 color_snow         : source_color = vec3(0.96, 0.96, 0.96);

// 鈹€鈹€鈹€ 浠诲姟 6锛氭瀬绔ぉ姘斿湴琛ㄥ弽棣堬紙绉洩 / 瑁傚湴锛夆攢鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// compute_extreme_weather_mask() 渚濊禆 fbm()锛岃€?fbm 瀹氫箟鍦ㄦ湰鏂囦欢鍚庢銆?// GLSL 瑕佹眰鍏堝０鏄庡悗璋冪敤锛屾墍浠ユ妸鍑芥暟浣撴尓鍒?voronoi_cell / fbm 涔嬪悗銆?// 姝ゅ淇濈暀璇存槑娉ㄩ噴锛屼互渚胯鑰呮寜浠诲姟缂栧彿妫€绱㈠埌瀹炵幇浣嶇疆銆?
// 鈹€鈹€鈹€ 鍙屽厜婧?hillshading 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
uniform float hillshade_strength : hint_range(0.0, 1.0) = 0.45;
uniform float hillshade_slope_gain : hint_range(0.5, 24.0) = 8.0;
uniform vec2  hillshade_dir      = vec2(-0.55, -0.55);
uniform vec2  hillshade_fill_dir = vec2( 0.60,  0.40);

// 鈹€鈹€鈹€ 娌虫祦锛堜粠 flow accumulation锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
uniform float river_strength       : hint_range(0.0, 1.0) = 0.85;
uniform float river_threshold_low  : hint_range(0.0, 1.0) = 0.55;
uniform float river_threshold_high : hint_range(0.0, 1.0) = 0.85;
uniform vec3  river_color          : source_color = vec3(0.30, 0.50, 0.68);
uniform vec3  river_outline_color  : source_color = vec3(0.16, 0.30, 0.45);

// 鈹€鈹€鈹€ 鍙€夌瓑楂樼嚎 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
uniform bool  contour_enabled = false;
uniform float contour_step       : hint_range(0.01, 0.20) = 0.05;
uniform float contour_strength   : hint_range(0.0, 0.40) = 0.18;
uniform vec3  contour_color      : source_color = vec3(0.20, 0.16, 0.10);

// 鈹€鈹€鈹€ 娴峰哺鍏夋檿 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
uniform vec3  coast_halo_color    : source_color = vec3(0.78, 0.86, 0.88);
uniform float coast_halo_strength : hint_range(0.0, 1.0) = 0.22;

// 鈹€鈹€鈹€ 缇婄毊绾?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
uniform vec3  parchment_tint        : source_color = vec3(0.96, 0.88, 0.74);
uniform float parchment_strength    : hint_range(0.0, 0.4) = 0.10;
uniform float paper_grain_strength  : hint_range(0.0, 0.2) = 0.05;

const int B_OCEAN     = 0;
const int B_COAST     = 1;
const int B_PLAIN     = 2;
const int B_GRASSLAND = 3;
const int B_FOREST    = 4;
const int B_HILL      = 5;
const int B_MOUNTAIN  = 6;
const int B_DESERT    = 7;
const int B_TUNDRA    = 8;
const int B_SNOW      = 9;
const int B_SWAMP     = 10;
const int B_JUNGLE    = 11;
const int B_SAVANNA   = 12;
const int B_TAIGA     = 13;
const int B_STEPPE    = 14;
const int B_SHRUBLAND = 15;
const int B_MANGROVE  = 16;
const int B_GLACIER   = 17;
const int B_LAKE      = 18;
const int B_REEF      = 19;
const int B_SEA_ICE   = 20;
const int B_KELP      = 21;
const int B_DELTA     = 22;
const int B_OASIS     = 23;
const int B_SALT_FLAT = 24;
const int B_BADLANDS  = 25;

// 鈹€鈹€鈹€ Milestone 2锛歏egetationType.VEG id 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 涓?scripts/vegetation_type.gd 涓ユ牸鎸?enum 椤哄簭瀵归綈锛宻hader 绔寜 id 鐩存帴 if-else 娲捐壊銆?const int V_NONE                = 0;
const int V_POLAR_DESERT        = 1;
const int V_TUNDRA              = 2;
const int V_ALPINE_TUNDRA       = 3;
const int V_ALPINE_MEADOW       = 4;
const int V_TAIGA               = 5;
const int V_BOREAL_SHRUB        = 6;
const int V_TEMPERATE_DECIDUOUS = 7;
const int V_TEMPERATE_CONIFER   = 8;
const int V_TEMPERATE_GRASSLAND = 9;
const int V_TEMPERATE_STEPPE    = 10;
const int V_MEDITERRANEAN_SHRUB = 11;
const int V_SUBTROPICAL_FOREST  = 12;
const int V_SAVANNA             = 13;
const int V_TROPICAL_RAINFOREST = 14;
const int V_TROPICAL_DRY_FOREST = 15;
const int V_DESERT_SCRUB        = 16;
const int V_XERIC_DESERT        = 17;
const int V_OASIS_VEG           = 18;
const int V_MANGROVE            = 19;
const int V_SWAMP               = 20;
const int V_MARSH               = 21;
const int V_KELP_FOREST         = 22;
const int V_CORAL_REEF          = 23;

// 鈹€鈹€鈹€ Milestone 2锛欳overType.CV id 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const int CV_NONE       = 0;
const int CV_SNOW       = 1;
const int CV_GLACIER    = 2;
const int CV_SEA_ICE    = 3;
const int CV_PERMAFROST = 4;
const int CV_FLOODING   = 5;

// 鈹€鈹€鈹€ Milestone 3锛歐eatherType.WT id 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const int WT_CLEAR    = 0;
// 涓?scripts/weather_type.gd 涓ユ牸鎸?enum 椤哄簭瀵归綈銆?const int WT_CLEAR    = 0;
const int WT_RAIN     = 1;
const int WT_STORM    = 2;
const int WT_BLIZZARD = 3;
const int WT_DROUGHT  = 4;
const int WT_FOG      = 5;
const int WT_HEATWAVE = 6;
const int WT_MONSOON  = 7;

varying vec2 v_world;

// 鈹€鈹€鈹€ 鍣０ 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// hash21 / value_noise / fbm / voronoi_cell 宸叉娊鑷?common_noise.gdshaderinc銆?// 渚濊禆锛歯oise_tex + NOISE_TEX_SCALE锛堝凡鍦ㄦ湰鏂囦欢椤堕儴澹版槑锛夈€?#include "res://shaders/include/common_noise.gdshaderinc"
#include "res://shaders/include/common_noise.gdshaderinc"

vec2 weather_front_axis(vec4 shape) {
	vec2 ax = shape.xy;
	if (dot(ax, ax) <= 0.0001) {
		return vec2(1.0, 0.0);
	}
	return normalize(ax);
}

float weather_front_ellipse_distance(vec2 wp, vec2 center, float radius, vec4 shape) {
	vec2 ax = weather_front_axis(shape);
	vec2 ay = vec2(-ax.y, ax.x);
	vec2 local = wp - center;
	float major = max(radius * max(shape.z, 0.05), 0.001);
	float minor = max(radius * max(shape.w, 0.05), 0.001);
	return length(vec2(dot(local, ax) / major, dot(local, ay) / minor));
}

float weather_front_gaussian_coverage(vec2 wp, vec4 center_data, vec4 shape) {
	float radius = center_data.z;
	if (radius < 0.001) {
		return 0.0;
	}
	float ed = weather_front_ellipse_distance(wp, center_data.xy, radius, shape);
	if (ed > 1.6) {
		return 0.0;
	}
	float k = ed / 0.5;
	return clamp(center_data.w * exp(-0.5 * k * k), 0.0, center_data.w);
}

float compute_extreme_weather_mask(vec2 wp, int type_id) {
	float best = 0.0;
	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;
		int wt_i = int(wt_f + 0.5);
		if (wt_i != type_id) continue;
		vec4 c = weather_front_centers[i];
		vec4 shape = weather_front_shapes[i];
		vec4 visual = weather_front_visuals[i];
		float radius = c.z;
		if (radius < 0.001) continue;
		float ed = weather_front_ellipse_distance(wp, c.xy, radius, shape);
		float spread = mix(1.0, 1.20, visual.z);
		float d = ed / spread;
		if (d > 1.65) continue;
		float radial = 1.0 - smoothstep(0.60, 1.34 + visual.z * 0.18, d);
		float freq = (type_id == WT_BLIZZARD) ? 0.020 : 0.034;
		vec2 offset = (type_id == WT_BLIZZARD) ? vec2(13.0, -7.0) : vec2(-29.0, 41.0);
		float n = fbm((wp + offset) * freq, 2);
		float visual_amount = (type_id == WT_BLIZZARD) ? max(visual.y, visual.x * 0.72) : max(visual.x, c.w);
		float threshold = mix(0.48, 0.22, clamp(visual_amount, 0.0, 1.0)) + visual.z * 0.10;
		float density = smoothstep(threshold, threshold + 0.24, n);
		float mask = radial * mix(0.62, 1.0, density) * clamp(visual_amount, 0.0, 1.0);
		best = max(best, mask);
	}
	return best;
}

// 鈹€鈹€鈹€ 楂樺害瑙ｇ爜锛圧G8 16-bit锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

float decode_height_rg8(vec2 uv) {
	vec4 s = texture(height_tex, uv);
	return (s.r * 256.0 + s.g) / 257.0;
}

// 鈹€鈹€鈹€ 绛夐珮绾胯鑹诧紙hypsometric tint锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 娉ㄦ剰锛氱敤 is_water (biome 鍐冲畾) 鑰屼笉鏄?elev 鏉ュ垎鏀捣闄嗭紝鍚﹀垯浼氬洜涓?height_tex
// 鐨?barycentric 骞虫粦鎻掑€煎湪 hex 杈圭晫澶勬妸"姘?hex 浣?elev 鍋跺皵瓒婅繃 sea_level"
// 鐨勫儚绱犵敾鎴愰檰鍦扳€斺€旂粨鏋滃氨鏄捣宀稿畬鍏ㄨ劚绂?hex 褰㈢姸锛屾案杩滃钩婊戞洸绾裤€?
vec3 water_depth_gradient(float offshore_t, float elev) {
	float offshore_s = smoothstep(0.00, 1.00, clamp(offshore_t, 0.0, 1.0));
	float near_surface = smoothstep(0.08, 1.00, clamp(elev / max(sea_level, 0.001), 0.0, 1.0));
	float contrast_t = clamp((deep_ocean_contrast - 0.5) / 2.5, 0.0, 1.0);

	// Cartoon water palette: overlapping wide ramps, not isolated depth bands.
	// Coast -> turquoise shelf -> teal sea -> cobalt basin -> soft indigo abyss.
	float shelf_t = smoothstep(0.05, 0.46, offshore_s);
	float mid_t = smoothstep(0.28, 0.78, offshore_s);
	float basin_t = smoothstep(0.56, 1.00, offshore_s);
	float abyss_t = smoothstep(0.76, 1.00, offshore_s);

	vec3 coast_col = mix(color_shallow, color_coast_water, 0.88) * vec3(0.96, 1.06, 1.08);
	vec3 shelf_col = mix(color_coast_water, color_mid_ocean, 0.24) * vec3(0.82, 1.16, 1.18);
	vec3 mid_col = mix(color_mid_ocean, color_deep_ocean, 0.18) * vec3(0.88, 1.05, 1.18);
	vec3 basin_col = mix(color_mid_ocean, color_deep_ocean, 0.50) * vec3(0.76, 0.96, 1.22);
	vec3 abyss_col = mix(color_deep_ocean * vec3(0.86, 0.98, 1.24), color_deep_ocean * vec3(0.58, 0.72, 1.08), contrast_t);

	vec3 ocean_col = coast_col;
	ocean_col = mix(ocean_col, shelf_col, shelf_t * 0.92);
	ocean_col = mix(ocean_col, mid_col, mid_t * 0.78);
	ocean_col = mix(ocean_col, basin_col, basin_t * 0.68);
	ocean_col = mix(ocean_col, abyss_col, abyss_t * 0.58);

	// Broad deep-water chroma drift keeps large oceans layered while staying calm.
	vec3 blue_shift = mix(vec3(0.96, 1.02, 1.12), vec3(0.78, 0.92, 1.26), basin_t);
	vec3 violet_shift = mix(vec3(1.0), vec3(0.90, 0.86, 1.18), abyss_t);
	ocean_col *= mix(vec3(1.0), blue_shift, 0.20 * smoothstep(0.26, 1.0, offshore_s));
	ocean_col *= mix(vec3(1.0), violet_shift, 0.12 * abyss_t);

	vec3 shallow_lift = mix(shelf_col, coast_col, near_surface);
	return mix(ocean_col, shallow_lift, (1.0 - smoothstep(0.12, 0.42, offshore_s)) * near_surface * 0.36);
}

vec3 hypsometric_tint(float elev, bool is_water) {
	if (is_water) {
		float depth_t = 1.0 - clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
		float offshore_t = smoothstep(0.0, 1.0, depth_t);
		return water_depth_gradient(offshore_t, elev);
	}
	// 娴蜂笂锛氫粠娌欐哗鑹茶捣姝ワ紙涓嶅啀娣?coast_water锛夛紝淇濊瘉闄嗗湴杈圭紭 鈮?姘村煙棰滆壊锛?	// hex 娴峰哺杈圭晫瑙嗚涓婃竻鏅板彲瑙併€?	float t = clamp((elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	if (t < 0.10) return mix(color_beach, color_lowland, t / 0.10);
	// v10.2锛氫綆鍦扳啋涓橀櫟鈫掑北鍦版鍏ㄩ儴鎵╁锛岃鏇村 cell 钀藉湪"涓瓑娴锋嫈"鑹查樁
	// 鑰屼笉鏄鎺ㄥ埌 mountain/peak/snow 椤剁
	if (t < 0.55) return mix(color_lowland, color_hill, (t - 0.10) / 0.45);
	if (t < 0.85) return mix(color_hill, color_mountain, (t - 0.55) / 0.30);
	// peak鈫抯now 鎷愮偣 0.96 鈫?0.985锛歴now 鍙崰 top 1.5%
	// gradient `mix(peak, snow, (t-0.985)/0.015)` 璁╄竟鐣?cell锛坱=0.99锛夋墠鏈?30% 闆櫧
	if (t < 0.985) return mix(color_mountain, color_peak, (t - 0.85) / 0.135);
	return mix(color_peak, color_snow, (t - 0.985) / 0.015);
}

// 鈹€鈹€鈹€ biome 鑹茬浉璋冨埗锛堥珮搴﹁礋璐ｄ寒搴︼紝biome 璐熻矗鑹茬浉锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

vec3 biome_hue_modulate(vec3 base, int biome) {
	if (biome == B_FOREST)    return base * vec3(0.70, 1.05, 0.65);
	if (biome == B_GRASSLAND) return base * vec3(0.85, 1.05, 0.78);
	if (biome == B_DESERT)    return base * vec3(1.18, 1.02, 0.72);
	if (biome == B_TUNDRA)    return base * vec3(0.92, 1.00, 1.00);
	// SNOW biome 鐨?鐧?鐢卞悗缁?dynamic_snow_factor 缁熶竴澶勭悊锛堜笉鍦ㄨ繖閲屾贩鐧斤級锛?	// 閬垮厤鍜屽鑺傞洩鍙犲姞 鈫?鐪嬭捣鏉ヨ繃鏇濄€傝繖閲屽彧缁?SNOW 涓€涓交寰喎鑹茶皟搴曡壊銆?	if (biome == B_SNOW)      return base * vec3(0.92, 0.95, 1.00);
	if (biome == B_MOUNTAIN)  return base * vec3(1.00, 0.95, 0.95);
	if (biome == B_HILL)      return base * vec3(1.05, 1.00, 0.90);
	// Phase 9锛歋WAMP 鏆楅ケ鍜岀豢甯﹁摑璋?+ 鎻愬崌 base 鍋忛粍缁?	if (biome == B_SWAMP)     return base * vec3(0.55, 0.85, 0.62);
	// Phase 10锛歐hittaker 4
	// JUNGLE锛氭瀬娣遍ケ鍜岀豢锛堥洦鏋楅儊闂級
	if (biome == B_JUNGLE)    return base * vec3(0.50, 1.00, 0.55);
	// SAVANNA锛氶噾榛勮崏 + 涓€鐐规殩姗?	if (biome == B_SAVANNA)   return base * vec3(1.10, 1.00, 0.62);
	// TAIGA锛氬喎钃濊皟鏆楃豢锛堥拡鍙舵灄锛?	if (biome == B_TAIGA)     return base * vec3(0.62, 0.92, 0.78);
	// STEPPE锛氭祬榛勭豢锛屾瘮 GRASSLAND 鍑忓崐楗卞拰
	if (biome == B_STEPPE)    return base * vec3(1.00, 1.04, 0.82);
	// Phase 11
	// SHRUBLAND锛氱伆缁垮甫鍦熼粍锛堝湴涓捣骞叉€х亴涓涳級
	if (biome == B_SHRUBLAND) return base * vec3(1.05, 0.98, 0.78);
	// MANGROVE锛氭瀬娣遍ケ鍜岀豢甯﹁摑璋冿紙婀跨儹姘撮檰浜ょ晫锛?	if (biome == B_MANGROVE)  return base * vec3(0.50, 0.88, 0.65);
	// GLACIER锛氭瀬娣¤摑鐧?	if (biome == B_GLACIER)   return base * vec3(0.92, 0.98, 1.05);
	// Phase 14锛氬瑙傚湴鏍?	// DELTA锛氭缁挎枒椹筹紙婀挎鼎娌夌Н甯︼級
	if (biome == B_DELTA)     return base * vec3(0.78, 1.00, 0.65);
	// OASIS锛氶矞浜ケ鍜岀豢锛堟矙婕犱腑鐨勭敓鍛斤級
	if (biome == B_OASIS)     return base * vec3(0.55, 1.10, 0.55);
	// SALT_FLAT锛氭瀬娣￠粍鐧斤紙楂樺弽灏勶級
	if (biome == B_SALT_FLAT) return base * vec3(1.18, 1.15, 0.92);
	// BADLANDS锛氭绾㈡潯绾癸紙娌夌Н灞傦級
	if (biome == B_BADLANDS)  return base * vec3(1.20, 0.85, 0.60);
	return base;
}

// 鈹€鈹€鈹€ Phase 1锛氬鑺傜浉浣嶈緟鍔?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

// 鍗婄悆缈昏浆锛氬寳鍗婄悆鐢ㄥ師鐩镐綅锛屽崡鍗婄悆鐩镐綅 + 2 鈫?瀛ｈ妭浜掓崲
float hemi_phase(float phase, float lat_signed) {
	return (lat_signed >= 0.0) ? phase : mod(phase + 2.0, 4.0);
}

// 瀛ｈ妭娓╁害鍋忕Щ锛歝os((phase - 1) 脳 蟺/2) 脳 amp
// phase=0(鏄? 鈫?0锛沺hase=1(澶? 鈫?+amp锛沺hase=2(绉? 鈫?0锛沺hase=3(鍐? 鈫?-amp
float season_temp_offset(float phase) {
	return cos((phase - 1.0) * 1.5707963) * season_temp_amp;
}

// 褰撳墠瀹炴椂娓╁害锛歔0, 1]銆傚拰 map_generator._compute_temperature 鍚屽叕寮忥細
// lat_temp = pow(cos(lat_signed * 蟺/2), 1.2) - elev*0.5
// 鐒跺悗鍙?+ season_offset + climate_anomaly
float compute_current_temp(float elev, float lat_signed, float season_offset) {
	float lat_temp = pow(max(cos(lat_signed * 1.5707963), 0.0), 1.2);
	float alt_penalty = elev * 0.5;
	return clamp(lat_temp + season_offset + climate_anomaly - alt_penalty, 0.0, 1.0);
}

// 妞嶈瀛ｈ妭鑹茬浉锛? 鍏抽敭鑹叉寜鐩镐綅绾挎€ф彃鍊硷紙spring 鈫?summer 鈫?autumn 鈫?winter 鈫?spring锛?// 杩斿洖涔樻€?tint锛堝簲鐢ㄤ负 base * vegetation_seasonal_tint(...)锛?vec3 vegetation_seasonal_tint(float phase) {
	vec3 spring = vec3(0.95, 1.06, 0.92);  // 椴滃
	vec3 summer = vec3(0.80, 1.00, 0.72);  // 娣辩豢
	vec3 autumn = vec3(1.12, 0.92, 0.62);  // 鏆栭粍姗?	vec3 winter = vec3(0.78, 0.78, 0.86);  // 鐏板喎
	if (phase < 1.0) return mix(spring, summer, phase);
	if (phase < 2.0) return mix(summer, autumn, phase - 1.0);
	if (phase < 3.0) return mix(autumn, winter, phase - 2.0);
	return mix(winter, spring, phase - 3.0);
}

// 瀛ｈ妭鎬ч洩鐩栵細缁煎悎"姘镐箙 SNOW biome"+"瀛ｈ妭闄嶆俯/楂樺北闆嚎"涓ら儴鍒嗐€傝繑鍥?[0, 1]銆?// - biome=SNOW 鈫?0.65 鍩虹锛堟案涔呴洩鍘燂級
// - 褰撳墠娓╁害 < 0.18 + 闄嗗湴 鈫?瀛ｈ妭闆紙鍐涓含搴︿篃瑕嗛洩锛?// - 楂樺湴 + 鍐锋俯搴?鈫?楂樺北闆嚎
float compute_snow_factor(int biome, float current_temp, float elev, bool is_water) {
	if (is_water) return 0.0;
	float factor = 0.0;
	// 1) 姘镐箙 SNOW biome 鍩虹
	if (biome == B_SNOW) factor = 0.65;
	// Phase 11锛欸LACIER 姘镐箙鍘氬啺闆熀纭€锛堟瘮 SNOW 杩橀珮锛岀函鐧借摑锛?	if (biome == B_GLACIER) factor = 0.80;
	// 2) 瀵掑喎鍦拌〃锛坱emp 瓒婁綆锛岄洩瓒婂帤锛夛紝浠呴檰鍦?	float cold_factor = smoothstep(0.18, 0.04, current_temp);
	factor = max(factor, cold_factor * 0.85);
	// 3) 楂樺北闆嚎锛坙and_h 瓒婇珮 + temp 瓒婁綆 鈫?闆秺鍘氾級锛岃涔炲姏椹墡缃楀紡鏁堝簲鍙鍖?	float land_h = (elev - sea_level) / max(1.0 - sea_level, 0.001);
	if (land_h > 0.40) {
		float alt_snow = smoothstep(0.40, 0.85, land_h) * smoothstep(0.40, 0.10, current_temp);
		factor = max(factor, alt_snow * 0.85);
	}
	return clamp(factor, 0.0, 1.0);
}

// 鈹€鈹€鈹€ Milestone 2锛氭琚酱鑹茬浉璋冨埗 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 杩斿洖涔樻€?tint锛堝洿缁?1.0 娴姩锛夛紝浠ｈ〃"鍦?biome 涓昏壊鍩虹涓婄殑妞嶈鍋忚壊"銆?// 璋冭壊绛栫暐锛?//   - 闃斿彾鏋?/ 闆ㄦ灄 / 浜氱儹甯︽灄 鈫?鐣ュ亸娣辩豢
//   - 閽堝彾鏋?/ 鍖楁柟鏋?        鈫?鍋忓ⅷ闈掔豢
//   - 鑽夋湰妞嶈               鈫?鍋忛粍缁?//   - 骞叉棻妞嶈               鈫?鍋忛粍瑜?//   - 鑻斿師 / 瑁稿湴            鈫?鍋忓喎鐏?// 浠呭湪"涓昏壊涓嶈兘瀹屾暣琛ㄨ揪妞嶈"鐨勫湴褰笂鐢熸晥锛圥LAIN/HILL/MOUNTAIN/PEAK/LOWLAND/
// GRASSLAND锛夛紝FOREST/JUNGLE/DESERT/SAVANNA/TAIGA 绛?biome 涓昏壊宸茬粡绮剧‘锛岃烦杩囥€?vec3 vegetation_tint(int veg) {
	if (veg == V_TROPICAL_RAINFOREST) return vec3(0.78, 1.10, 0.78);
	if (veg == V_SUBTROPICAL_FOREST)  return vec3(0.82, 1.08, 0.78);
	if (veg == V_TROPICAL_DRY_FOREST) return vec3(0.92, 1.06, 0.74);
	if (veg == V_TEMPERATE_DECIDUOUS) return vec3(0.86, 1.08, 0.76);
	if (veg == V_TEMPERATE_CONIFER)   return vec3(0.78, 1.00, 0.74);
	if (veg == V_TAIGA)               return vec3(0.74, 0.96, 0.74);
	if (veg == V_BOREAL_SHRUB)        return vec3(0.85, 0.98, 0.78);
	if (veg == V_TEMPERATE_GRASSLAND) return vec3(0.92, 1.06, 0.76);
	if (veg == V_TEMPERATE_STEPPE)    return vec3(1.05, 1.02, 0.74);
	if (veg == V_MEDITERRANEAN_SHRUB) return vec3(1.00, 0.96, 0.78);
	if (veg == V_SAVANNA)             return vec3(1.08, 1.00, 0.72);
	if (veg == V_DESERT_SCRUB)        return vec3(1.10, 1.00, 0.78);
	if (veg == V_XERIC_DESERT)        return vec3(1.14, 1.02, 0.74);
	if (veg == V_OASIS_VEG)           return vec3(0.86, 1.10, 0.78);
	if (veg == V_TUNDRA)              return vec3(0.92, 0.96, 0.92);
	if (veg == V_ALPINE_TUNDRA)       return vec3(0.92, 0.94, 0.94);
	if (veg == V_ALPINE_MEADOW)       return vec3(0.88, 1.05, 0.82);
	if (veg == V_POLAR_DESERT)        return vec3(0.96, 0.96, 0.98);
	if (veg == V_MANGROVE)            return vec3(0.78, 1.02, 0.80);
	if (veg == V_SWAMP)               return vec3(0.84, 1.02, 0.80);
	if (veg == V_MARSH)               return vec3(0.88, 1.04, 0.82);
	return vec3(1.0);
}

// 浠呭湪 biome 涓昏壊"鍦板舰涓诲銆佹琚俊鎭己澶?鏃舵墠鍏佽 vegetation 杞翠笂鑹层€?// FOREST/JUNGLE/DESERT/SAVANNA/TAIGA/... 涓昏壊宸茬粡绮剧‘琛ㄨ揪妞嶈锛岃烦杩囬伩鍏嶅弻鍊嶉ケ鍜屻€?bool biome_accepts_vegetation_tint(int biome) {
	return (biome == B_PLAIN
		|| biome == B_HILL
		|| biome == B_MOUNTAIN
		|| biome == B_GRASSLAND);
}

// 鈹€鈹€鈹€ Milestone 2锛氳鐩栫墿杞村彔鍔?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 杩斿洖 (rgb, alpha)锛沘lpha=0 琛ㄧず璇ヨ鐩栫墿鍦?fragment 鏈熬涓嶅簲鍙銆?// SNOW/SEA_ICE/GLACIER 宸茬粡琚?dynamic_snow / biome 涓昏矾寰勫鐞嗭紝杩欓噷鍙ˉ
// "鍘熺郴缁熸病涓撻棬澶勭悊"鐨勪袱涓細FLOODING锛堟按钃濆彔鍔狅級+ PERMAFROST锛堢伆闈掑井鏆楋級銆?// GLACIER 鍗充究 biome 宸茬粡澶勭悊涔熷啀琛ヤ竴灞傚喎钃濓紝寮哄寲涓庨珮灞遍洩绾跨殑瑙嗚宸紓銆?vec4 cover_overlay(int cover) {
	if (cover == CV_FLOODING)   return vec4(0.30, 0.45, 0.62, 0.45);
	if (cover == CV_PERMAFROST) return vec4(0.74, 0.78, 0.82, 0.10);
	if (cover == CV_GLACIER)    return vec4(0.86, 0.92, 0.96, 0.20);
	return vec4(0.0);
}

// 鈹€鈹€鈹€ Milestone 3 (split)锛氬湴褰?shader 鍙繚鐣?DROUGHT/HEATWAVE 鐨?multiplicative 璋冭壊 鈹€鈹€鈹€鈹€鈹€
// 鍏朵粬 weather 绫诲瀷锛圧AIN/STORM/FOG/BLIZZARD/MONSOON锛夊叏閮ㄧЩ鍒?WeatherLayer 鐙珛娓叉煋锛?// 杩欓噷鍙湪 max-merge 涓€冭檻"浼氭敼鍦拌〃鏈壊"鐨勪袱绉嶇被鍨嬨€?//
// 杩斿洖鍊硷細
//   rgb = 璋冭壊 multiplicative tint锛堟湰鏉?col * tint 灏辨槸瑕佺殑棰滆壊锛?//   a   = 瀹為檯鐢熸晥寮哄害锛堝凡涔?coverage * weather_strength锛夛紱0 = 褰撳墠 fragment 鏃?multiplicative 澶╂皵
vec4 sample_terrain_weather_tint(vec2 wp) {
	int best_type = WT_CLEAR;
	float best_coverage = 0.0;
	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;  // sentinel锛氱┖ slot
		int wt_i = int(wt_f + 0.5);
		// 鍙寫 multiplicative 绫诲瀷锛屽叾浣欎氦缁?WeatherLayer
		if (wt_i != WT_DROUGHT && wt_i != WT_HEATWAVE) continue;
		vec4 c = weather_front_centers[i];
		vec4 shape = weather_front_shapes[i];
		vec4 visual = weather_front_visuals[i];
		float ed = weather_front_ellipse_distance(wp, c.xy, c.z, shape);
		float spread = mix(1.0, 1.18, visual.z);
		float radial = 1.0 - smoothstep(0.62, 1.34 + visual.z * 0.18, ed / spread);
		float broken_edge = fbm((wp + c.xy * 0.13) * 0.030, 2);
		float coverage = radial * mix(0.70, 1.0, broken_edge) * clamp(max(c.w, visual.x), 0.0, 1.0);
		if (coverage > best_coverage) {
			best_coverage = coverage;
			best_type = wt_i;
		}
	}
	if (best_coverage <= 0.001) return vec4(0.0);
	// DROUGHT 寮哄害 0.30 / HEATWAVE 寮哄害 0.25锛堜笌鍘?weather_overlay_color 鏁板€间竴鑷达級
	vec3 tint;
	float base_alpha;
	if (best_type == WT_DROUGHT) {
		tint = vec3(1.18, 0.92, 0.65);
		base_alpha = 0.30;
	} else {  // WT_HEATWAVE
		tint = vec3(1.20, 1.00, 0.70);
		base_alpha = 0.25;
	}
	return vec4(tint, base_alpha * best_coverage * weather_strength);
}

// 鈹€鈹€鈹€ 閿愬埄绋嬪簭鍖栬创鍥撅紙涓嶄緷璧?hex锛屼笘鐣屽潗鏍囪繛缁級 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

vec3 procedural_biome_detail(int biome, vec2 wp) {
	if (biome == B_FOREST) {
		float vor = voronoi_cell(wp * 0.30);
		float n = fbm(wp * 0.40, 3);
		float modulator = mix(0.78, 1.15, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.92, 1.05, n);
		return vec3(modulator);
	}
	if (biome == B_GRASSLAND) {
		float n = fbm(wp * 0.18, 3);
		float micro = fbm(wp * 0.45, 1);  // v9.fbm-opt锛歮icro 卤0.05锛屽崟 octave 瓒冲
		return vec3(mix(0.85, 1.10, n) * mix(0.95, 1.05, micro));
	}
	if (biome == B_DESERT) {
		vec2 dune_dir = vec2(0.85, 0.30);
		float t = dot(wp, dune_dir) * 0.040;
		// v9.fbm-opt锛歴in 鍐呴儴鐨?phase 鎵板姩锛屽崟 octave 宸茬粡澶?娌欎笜璧板悜鏈夊彉鍖?
		float waves = sin(t + fbm(wp * 0.06, 1) * 5.0) * 0.5 + 0.5;
		float micro = fbm(wp * 0.30, 1);
		return vec3(mix(0.88, 1.10, waves) * mix(0.95, 1.05, micro));
	}
	if (biome == B_HILL) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.45, 1);  // v9.fbm-opt
		// v10.3锛氫笂闄?1.06脳1.04=1.10锛岄厤鍚?hillshade 鏈€澶?脳1.6
		return vec3(mix(0.85, 1.06, n) * mix(0.95, 1.04, micro));
	}
	if (biome == B_MOUNTAIN) {
		float n = fbm(wp * 0.30, 4);
		float vor = voronoi_cell(wp * 0.16);
		// v10.3锛氫笂闄愪粠 1.20脳1.10=1.32 闄嶅埌 1.05脳1.03=1.08
		// 閰嶅悎 hillshade max 1.45 鍚庢€绘斁澶?鈮?1.57锛宲eak 鑹?(0.55) 脳 1.57 = 0.86 鈫?鐏拌
		// 涓嶄細鍐?clamp 鎴愮函鐧?		return vec3(mix(0.72, 1.05, n) * mix(0.92, 1.03, smoothstep(0.05, 0.5, vor)));
	}
	if (biome == B_PLAIN) {
		float n = fbm(wp * 0.12, 3);
		float micro = fbm(wp * 0.40, 1);  // v9.fbm-opt
		return vec3(mix(0.92, 1.08, n) * mix(0.97, 1.03, micro));
	}
	if (biome == B_TUNDRA) {
		float n = fbm(wp * 0.16, 3);
		return vec3(mix(0.85, 1.08, n));
	}
	if (biome == B_SNOW) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.50, 1);  // v9.fbm-opt
		return vec3(mix(0.93, 1.04, n) * mix(0.98, 1.02, micro));
	}
	if (biome == B_SWAMP) {
		float pools = fbm(wp * 0.55, 3);
		float mud = fbm(wp * 0.18 + vec2(13.0, -7.0), 2);
		float pool_factor = smoothstep(0.55, 0.45, pools);
		float base_mod = mix(0.88, 1.08, mud);
		float pool_mod = mix(1.0, 0.78, pool_factor);
		return vec3(base_mod * pool_mod);
	}
	if (biome == B_JUNGLE) {
		// 闆ㄦ灄锛氬瘑闆嗕綆棰戞爲鍐犳枒 + 楂橀缁嗗彉寮?		float canopy = voronoi_cell(wp * 0.45);
		float n = fbm(wp * 0.55, 3);
		float micro = fbm(wp * 1.20, 1);  // v9.fbm-opt锛歮icro 卤0.05锛屽崟 octave 瓒冲
		float canopy_mod = mix(0.72, 1.08, smoothstep(0.05, 0.55, canopy));
		float n_mod = mix(0.92, 1.05, n);
		float micro_mod = mix(0.94, 1.04, micro);
		return vec3(canopy_mod * n_mod * micro_mod);
	}
	if (biome == B_SAVANNA) {
		// 绋€鏍戣崏鍘燂細閲戦粍鑽変綆棰?fbm + 鏁ｇ偣娣辩豢锛堟爲涓涳級voronoi
		float grass = fbm(wp * 0.16, 3);
		float trees = voronoi_cell(wp * 0.22);
		// trees 瓒婂皬 = 瓒婇潬杩戞爲涓涗腑蹇?鈫?棰滆壊鍘嬫殫鍔犵豢璋?		float tree_factor = smoothstep(0.05, 0.45, trees);
		float grass_mod = mix(0.85, 1.12, grass);
		float tree_mod = mix(0.62, 1.0, tree_factor);
		return vec3(grass_mod * tree_mod);
	}
	if (biome == B_TAIGA) {
		// 娉板姞锛欶OREST 鍚屾浣嗘洿鏆椼€佸姞鍐疯皟鐧界偣锛堢Н闆湭铻嶏級
		float vor = voronoi_cell(wp * 0.34);
		float n = fbm(wp * 0.40, 3);
		float patches = fbm(wp * 0.65 + vec2(11.0, 17.0), 2);
		float modulator = mix(0.70, 1.05, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.90, 1.04, n);
		float frost = smoothstep(0.78, 0.92, patches);
		modulator *= mix(1.0, 1.18, frost);
		return vec3(modulator);
	}
	if (biome == B_STEPPE) {
		// 鑽夊師锛氫腑棰戝共鑽夎捣浼?+ 寰彉寮傦紙姣?GRASSLAND 鍑忓崐鎸箙锛?		float n = fbm(wp * 0.14, 3);
		float micro = fbm(wp * 0.50, 1);  // v9.fbm-opt
		return vec3(mix(0.90, 1.06, n) * mix(0.96, 1.04, micro));
	}
	if (biome == B_SHRUBLAND) {
		// 鐏屼笡锛氫腑棰戞枒鐐癸紙鐏屾湪绨囷級+ 寰共鐕ョ矑
		float vor = voronoi_cell(wp * 0.36);
		float n = fbm(wp * 0.30, 3);
		float bush = mix(0.82, 1.05, smoothstep(0.05, 0.55, vor));
		float n_mod = mix(0.93, 1.06, n);
		return vec3(bush * n_mod);
	}
	if (biome == B_MANGROVE) {
		// 绾㈡爲鏋楋細SWAMP 鍚屾姘存醇浣嗘洿娣便€佸姞瀵嗛泦鏍戞牴 voronoi
		float pools = fbm(wp * 0.50, 3);
		float roots = voronoi_cell(wp * 0.55);
		float pool_factor = smoothstep(0.55, 0.40, pools);
		float root_mod = mix(0.78, 1.0, smoothstep(0.05, 0.45, roots));
		float pool_mod = mix(1.0, 0.70, pool_factor);
		return vec3(root_mod * pool_mod);
	}
	if (biome == B_GLACIER) {
		// 鍐板窛锛氫綆棰戣捣浼?+ 楂橀瑁傜汗锛坴oronoi 杈圭紭 = 鍐拌缂濓級
		float n = fbm(wp * 0.18, 3);
		float crack = voronoi_cell(wp * 0.70);
		float crack_factor = smoothstep(0.0, 0.18, crack);
		return vec3(mix(0.92, 1.06, n) * mix(0.78, 1.02, crack_factor));
	}
	if (biome == B_DELTA) {
		// 涓夎娲诧細鎵囧舰鍒嗘祦缁嗙汗锛堝緞鍚?+ 楂橀骞叉壈锛?		float n = fbm(wp * 0.35, 3);
		float fans = fbm(wp * 0.55 + vec2(13.0, -7.0), 2);
		float pools = smoothstep(0.55, 0.40, fans);
		float n_mod = mix(0.85, 1.10, n);
		float pool_mod = mix(1.0, 0.78, pools);
		return vec3(n_mod * pool_mod);
	}
	if (biome == B_OASIS) {
		// 缁挎床锛氫腑蹇冮矞缁?+ 鍛ㄥ洿娣￠粍娌欐笎鍙橈紙寰勫悜 fade 鐢?voronoi 璺濈鍦猴級
		float vor = voronoi_cell(wp * 0.40);
		float n = fbm(wp * 0.50, 3);
		// vor 瓒婂皬 = 瓒婇潬杩戞煇涓壒寰佺偣锛堢豢娲叉牳蹇冿級 鈫?椴滅豢
		float core = smoothstep(0.40, 0.05, vor);
		float n_mod = mix(0.92, 1.10, n);
		float core_mod = mix(0.85, 1.20, core);
		return vec3(n_mod * core_mod);
	}
	if (biome == B_SALT_FLAT) {
		// 鐩愭布锛氭瀬娣?+ 楂橀鐩愮粨鏅舵枒鐐癸紙灏?voronoi锛? 澶у昂搴﹂緹瑁?		float crystals = voronoi_cell(wp * 1.10);
		float crystal_factor = smoothstep(0.0, 0.15, crystals);
		float crack = voronoi_cell(wp * 0.30);
		float crack_factor = smoothstep(0.0, 0.10, crack);
		return vec3(mix(0.85, 1.10, crystal_factor) * mix(0.95, 1.02, crack_factor));
	}
	if (biome == B_BADLANDS) {
		// 鑽掑師锛氭í鍚戞矇绉眰鏉＄汗锛堢敤涓栫晫 y mod锛? 楂橀绮楃爞
		float bands = sin(wp.y * 0.45 + fbm(wp * 0.12, 2) * 4.0) * 0.5 + 0.5;
		float sand = fbm(wp * 0.40, 3);
		return vec3(mix(0.85, 1.18, bands) * mix(0.92, 1.06, sand));
	}
	return vec3(1.0);
}

// 鈹€鈹€鈹€ 鍙屽厜婧?hillshading锛坘ey + fill锛岃蒋闃村奖锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

float hillshading_two_lights(vec2 uv) {
	vec2 texel = 1.0 / hm_resolution;
	float l = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float u = decode_height_rg8(uv - vec2(0.0, texel.y));
	float d = decode_height_rg8(uv + vec2(0.0, texel.y));
	float dx = (r - l) * hillshade_slope_gain;
	float dy = (d - u) * hillshade_slope_gain;
	vec3 normal = normalize(vec3(-dx, -dy, 1.0));

	vec3 key_dir  = normalize(vec3(hillshade_dir.x,      hillshade_dir.y,      0.65));
	vec3 fill_dir = normalize(vec3(hillshade_fill_dir.x, hillshade_fill_dir.y, 0.50));

	float key  = max(dot(normal, key_dir),  0.0);
	float fill = max(dot(normal, fill_dir), 0.0) * 0.40;
	return key + fill;
}

// 鈹€鈹€鈹€ 浠诲姟 3锛氶鏍煎寲 PBR 鏄煎鐫€鑹茶緟鍔?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 鍏抽敭鍐崇瓥 1锛氫繚鐣?PBR 鐗╃悊鍏夌収娴佺▼锛堟柟鍚戝厜 NdotL + 鑿叉秴灏旀煍杈癸級锛屼絾鑹叉俯/楗卞拰搴?// 鏇茬嚎鎵嬭皟锛屼笉璧扮湡瀹炲€笺€傛墍鏈夊箙搴﹂兘鍘嬪湪"涓庣幇鏈夋墜缁橀鏍煎吋瀹?鐨勮寖鍥村唴銆?//
// 鍥涗釜鍏抽敭鏃剁浉锛?//   phase=0.0 鏃ュ嚭锛氬お闃充粠涓滄柟鍦板钩绾垮崌璧凤紝澶╄壊鏆栨
//   phase=0.25 姝ｅ崍锛氬お闃冲湪澶╅《锛堟帴杩戞涓婃柟锛夛紝澶╄壊鍋忕櫧
//   phase=0.5 鏃ヨ惤锛氬お闃冲洖鍒板湴骞崇嚎锛堣タ鏂癸級锛屽ぉ鑹叉殩姗欏亸绾?//   phase=0.75 鍗堝锛氬お闃冲湪鍦板钩绾夸互涓嬶紝澶╄壊鍐疯摑锛堟湀鍏夛級
//
// 杩斿洖"澶槼鏂瑰悜鍚戦噺"锛堜笘鐣屽潗鏍囩┖闂达紝XY 鏄按骞筹紝Z 鏄悜涓婅繎浼兼硶鍚戯級銆?// 姝ｅ崍 z 鎺ヨ繎 1锛堟涓婃柟锛夛紝鏃ュ嚭/鏃ヨ惤 z 鎺ヨ繎 0锛屽崍澶?z 涓鸿礋锛堝厜浠庝笅闈㈡潵锛?// 鍦ㄦ覆鏌撲笂琚В閲婁负"鏃犵洿鎺ュ厜"锛屽湴琛ㄧ敱鐜鍐疯壊琛ュ厜锛夈€?vec3 get_sun_dir(float phase) {
	// 涓€澶?360掳 鏃嬭浆锛歱hase鈫抋ngle锛?.0 璧风偣璁惧湪"鏃ュ嚭鍦板钩绾?
	float angle = phase * 6.2831853;  // 2蟺
	// 姘村钩 x锛?掳 鈫?+1锛堜笢锛夛紝0.5蟺 鈫?0锛堥《锛夛紝蟺 鈫?-1锛堣タ锛夛紝1.5蟺 鈫?0锛堝簳锛?	float sun_x = cos(angle - 1.5707963);   // shift锛歱hase=0 鏃?cos(-蟺/2)=0, sin(...)
	float sun_z = sin(angle - 1.5707963) + 1.0; // phase=0 鏃?z鈮? (鍦板钩绾? ... phase=0.25 鏃?z鈮? 鈫?褰掍竴鍖栧悗 ~1
	sun_z = sun_z - 1.0;  // 閲嶆柊骞崇Щ涓?[-1, 1]锛氭棩鍑?0, 姝ｅ崍 1, 鏃ヨ惤 0, 鍗堝 -1
	// y 鏂瑰悜鍋?0.15 鐨勫井鍋忥紙绋嶅亸鍗楋級锛岃创杩?澶槼杞ㄨ抗涓嶆槸瀹岀編绔栫洿闈?鐨勭洿瑙?	float sun_y = 0.15;
	return normalize(vec3(sun_x, sun_y, sun_z));
}

// 澶╃┖鏌撹壊锛氬洓鍏抽敭鑹?smoothstep 鎻掑€笺€傛墜璋冩洸绾匡紝涓嶈蛋鐗╃悊鍏夎氨銆?vec3 get_sky_tint(float phase) {
	vec3 sunrise = vec3(1.20, 0.88, 0.72);  // 鏆栨
	vec3 noon    = vec3(1.00, 1.00, 0.98);  // 杩戠櫧
	vec3 sunset  = vec3(1.18, 0.80, 0.62);  // 鏆栨鍋忕孩
	vec3 night   = vec3(0.55, 0.65, 0.92);  // 鍐疯摑锛堟湀鍏夛級
	if (phase < 0.25)
		return mix(sunrise, noon,   smoothstep(0.0,  0.25, phase));
	if (phase < 0.5)
		return mix(noon,    sunset, smoothstep(0.25, 0.5,  phase));
	if (phase < 0.75)
		return mix(sunset,  night,  smoothstep(0.5,  0.75, phase));
	return mix(night,   sunrise, smoothstep(0.75, 1.0,  phase));
}

// 鏁翠綋浜害绯绘暟锛氬闂村帇鍒?night_brightness_min ~ max 涔嬮棿锛岀櫧澶╀负 1.0銆?// 鏃ュ嚭/鏃ヨ惤杩囨浮鐢?smoothstep锛屼笉浼氬嚭鐜扮‖璺冲彉銆?float get_day_brightness(float phase) {
	// 鐧藉ぉ鍖洪棿 [0.0, 0.5]锛堟棩鍑衡啋鏃ヨ惤锛? 1.0锛涘鏅氬尯闂?[0.5, 1.0] 鍘嬫殫
	// 杩囨浮娈?卤0.06 phase 鍋氳蒋杩囨浮
	float day_mask = smoothstep(0.06, 0.0, abs(phase - 0.25) - 0.19);
	// 澶滈棿鍊硷細min~max 涔嬮棿鍐嶆寜 phase 鐩稿鍗堝 0.75 鐨勮窛绂诲井璋冿紙鍗堝鏈€鏆楋級
	float night_t = smoothstep(0.0, 0.25, abs(phase - 0.75));
	float night_brightness = mix(night_brightness_min, night_brightness_max, night_t);
	return mix(night_brightness, 1.0, day_mask);
}

// 椋庢牸鍖?PBR 鐫€鑹诧細瀵硅緭鍏?albedo 搴旂敤 NdotL + 鑿叉秴灏旀煍杈?+ 澶╄壊 tint + 澶滈棿鍘嬫殫銆?// 涓洪伩鍏嶅湪"娴烽潰/娌虫祦宸茬粡鑷甫绮煎厜"鐨勫湴鏂逛骇鐢熷弻閲嶉珮鍏夛紝杩欓噷鍙繑鍥?绾壊璋冨埗鍥犲瓙"锛?// 楂樺厜鐣欑粰姘翠綋鍒嗘敮鑷繁澶勭悊锛堜换鍔?8锛夈€?//
// terrain_normal 鐢?hillshading 鐨?dx/dy 杩戜技閲嶆瀯锛堝凡缁忕畻杩囷紝姝ゅ澶嶇敤 result锛夛紱
// 涓轰簡绠€鍖栨帴鍙ｏ紝杩欓噷鐩存帴鐢ㄤ竴涓?鍚戜笂娉曞悜 + 鍧″害鍋忕Щ"鐨勭瓑鏁堟硶鍚戙€?vec3 apply_day_night(vec3 albedo, float phase, vec2 slope_xy) {
	// 閲嶆瀯绠€鏄撴硶鍚戯細slope_xy 骞呭害灏忥紝娉曞悜浠嶈繎浼煎悜涓?	vec3 n = normalize(vec3(-slope_xy, 1.0));
	vec3 sun = get_sun_dir(phase);
	// NdotL锛氬お闃冲湪鍦板钩绾夸笅鏃朵細鏄礋鏁帮紝clamp 鍒?0 = 鏃犵洿鎺ュ厜
	float ndotl = max(dot(n, sun), 0.0);
	// 椋庢牸鍖?PBR锛歛mbient 0.55锛堟墜缁橀涓嶈拷姹?100% 鐗╃悊锛夛紝direct 0.45 脳 NdotL
	float lighting = 0.55 + 0.45 * ndotl;
	// 鑿叉秴灏旀煍杈癸細鐢?z 鍒嗛噺妯℃嫙"瑙嗚鍑犱箮鍨傜洿"锛屽灞卞潯鑳屽厜渚у仛杞诲井鎻愪寒
	// fresnel = pow(1.0 - NdotV, 3)锛?D canvas NdotV 杩戜技 n.z
	float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.0);
	lighting += fresnel * 0.08;
	// 澶╄壊 tint
	vec3 sky = get_sky_tint(phase);
	vec3 result = albedo * lighting * sky;
	// 鏁翠綋浜害锛堝闂村帇鏆楋級
	result *= get_day_brightness(phase);
	return result;
}

// 鈹€鈹€鈹€ Pass 2锛堜换鍔?3锛夛細TOD 椹卞姩鐨勯鏍煎寲 PBR 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
// 鎶?day_phase 娲剧敓鐨勬湰鍦版棩鍏夋暟鎹叏閮ㄦ浛鎹负 TODProfile uniform锛涙硶绾胯绠楀崌绾?// 涓?Sobel 3x3锛坴isual_quality>=1锛夋垨淇濈暀 4-tap锛坴isual_quality==0锛岄渶姹?3.6锛夈€?//
// 鍏抽敭鏀瑰姩锛堝搴旈渶姹?3.1~3.6锛夛細
//   1. 娉曠嚎 N 鏉ヨ嚜 height_tex 鐨?Sobel/Center-Diff锛屾瘮 hillshading_two_lights 鏇村己
//   2. 鍏夌収鏂瑰悜 = tod_sun_dir锛岃壊娓?= tod_sun_color锛岀幆澧?= tod_ambient_color
//   3. 楂樺厜 = Blinn-Phong NdotH锛宺oughness 鎸?biome 鍒嗙被锛堥洩鍏夋粦銆佹．鏋楃矖绯欙級
//   4. 骞冲湴閫€鍖栵細|鈭噃| < epsilon 鏃惰烦杩囨柟鍚戝厜锛堥伩鍏嶅櫔澹颁吉褰憋級
//   5. 鏈€缁堜箻 tod_exposure 骞跺仛鑹烘湳鍖?tonemap
//   6. day_night_enabled=false 鏃?caller 璺宠繃鏈嚱鏁帮紝鍥為€€鍒?apply_day_night 璺緞
//
// 杩斿洖锛歅BR 鏌撹壊鍚庣殑 RGB锛坈aller 璐熻矗 clamp锛夈€?
// 浠?height_tex 閲囨牱寰楀埌 tangent-space 娉曠嚎锛圫obel 3x3 鎴?4-tap 涓績宸垎锛?vec3 compute_terrain_normal(vec2 uv, int quality) {
	vec2 texel = 1.0 / hm_resolution;
	if (quality <= 0) {
		// 浣庤川锛?-tap 涓績宸垎锛堜笌鍘?hillshading 涓€鑷达級
		float l0 = decode_height_rg8(uv - vec2(texel.x, 0.0));
		float r0 = decode_height_rg8(uv + vec2(texel.x, 0.0));
		float u0 = decode_height_rg8(uv - vec2(0.0, texel.y));
		float d0 = decode_height_rg8(uv + vec2(0.0, texel.y));
		float dx0 = (r0 - l0) * hillshade_slope_gain;
		float dy0 = (d0 - u0) * hillshade_slope_gain;
		return normalize(vec3(-dx0, -dy0, 1.0));
	}
	// 楂樿川锛歋obel 3x3锛? 閲囨牱锛屾柟鍚戞€ф洿绋筹級
	float hLU = decode_height_rg8(uv + vec2(-texel.x, -texel.y));
	float hU2 = decode_height_rg8(uv + vec2( 0.0,     -texel.y));
	float hRU = decode_height_rg8(uv + vec2( texel.x, -texel.y));
	float hL2 = decode_height_rg8(uv + vec2(-texel.x,  0.0));
	float hR2 = decode_height_rg8(uv + vec2( texel.x,  0.0));
	float hLD = decode_height_rg8(uv + vec2(-texel.x,  texel.y));
	float hD2 = decode_height_rg8(uv + vec2( 0.0,      texel.y));
	float hRD = decode_height_rg8(uv + vec2( texel.x,  texel.y));
	// Sobel X锛歔[-1,0,1],[-2,0,2],[-1,0,1]] / 8锛沋 杞疆
	float gx = ((hRU + 2.0 * hR2 + hRD) - (hLU + 2.0 * hL2 + hLD)) * 0.125;
	float gy = ((hLD + 2.0 * hD2 + hRD) - (hLU + 2.0 * hU2 + hRU)) * 0.125;
	gx *= hillshade_slope_gain;
	gy *= hillshade_slope_gain;
	return normalize(vec3(-gx, -gy, 1.0));
}

// 鎸?biome 鏌ヨ〃绮楃硻搴︼紙闇€姹?3.3锛夛細闆?鍐板厜婊戙€佹矙涓瓑銆佹．鏋?鑽夊師绮楃硻
float biome_roughness(int biome) {
	if (biome == B_SNOW || biome == B_GLACIER || biome == B_SEA_ICE) return 0.22;
	if (biome == B_DESERT || biome == B_SALT_FLAT) return 0.58;
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.88;
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE) return 0.78;
	if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS) return 0.65;
	return 0.55;
}

// 涓诲叆鍙ｏ細TOD 椹卞姩鐨?PBR銆俰s_water 鏃惰涓婂眰鐩存帴璺宠繃銆?vec3 apply_tod_pbr(vec3 albedo, vec2 uv, int biome, int quality) {
	// 1. 娉曠嚎
	vec3 N = compute_terrain_normal(uv, quality);
	// 2. 鍧″害锛氬钩鍦伴€€鍖栧垽瀹?	float slope_mag = length(vec2(N.x, N.y));

	// 3. 鏂瑰悜鍏?Lambert锛堥渶姹?3.2锛?	vec3 L = normalize(tod_sun_dir);
	float ndotl = max(dot(N, L), 0.0);
	float direct_amp = hillshade_strength + 0.55;
	vec3 diffuse = tod_sun_color * ndotl * direct_amp;

	// 4. Blinn-Phong 楂樺厜锛堥渶姹?3.3锛?	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 H = normalize(L + V);
	float roughness = biome_roughness(biome);
	float shininess = mix(128.0, 4.0, roughness);
	float spec_amp = mix(0.25, 0.02, roughness);
	float ndoth = max(dot(N, H), 0.0);
	float spec = pow(ndoth, shininess) * spec_amp;
	vec3 specular = tod_sun_color * spec;

	vec3 ambient = tod_ambient_color;

	// 5. 骞冲湴閫€鍖栵紙闇€姹?3.5锛?	if (slope_mag < 0.015) {
		return albedo * (ambient + tod_sun_color * 0.3) * tod_exposure;
	}

	// 6. 椋庢牸鍖栧悎鎴?	vec3 lit = albedo * (ambient + diffuse) + specular;

	// 7. 澶滄櫄鍘嬫殫
	float night_scale = mix(1.0, 0.55, tod_night_factor);
	lit *= night_scale;

	// 8. 鏇濆厜 + 鑹烘湳鍖?tonemap锛堢畝鏄?Reinhard锛?	lit *= tod_exposure;
	lit = lit / (1.0 + lit * 0.35);
	return lit;
}

// 鈹€鈹€鈹€ Water Visual Overhaul锛氭按浣撳嚱鏁颁笌甯搁噺宸叉娊鑷?water.gdshaderinc 鈹€鈹€鈹€鈹€鈹€鈹€
// 鍐呭锛欸erstner-Lite 甯搁噺 + water_surface_height / sample_water_normal /
//       water_domain_warp / water_shade_lines / water_calm_brightness /
//       water_calm_tint / water_biome_weights
// 渚濊禆锛歝ommon_noise.gdshaderinc锛坒bm/value_noise/voronoi_cell/hash21锛夈€?//       enum_atlas sampler 涓?B_LAKE/B_REEF/B_KELP/B_SEA_ICE 甯搁噺锛堝潎鍦ㄦ湰鏂囦欢涓婃柟澹版槑锛夈€?#include "res://shaders/include/water.gdshaderinc"

void vertex() {
	v_world = VERTEX;
}

void fragment() {
	vec2 wp = v_world;
	vec2 uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));

	float elev = decode_height_rg8(uv);

	// v9.atlas锛氭妸 3 寮?atlas 涓€娆￠噰鏍疯В鐮佸埌灞€閮ㄥ彉閲忥紝鍚庣画閫昏緫璇昏繖浜涘彉閲?	vec4 enums = texture(enum_atlas,   uv);
	vec4 scals = texture(scalar_atlas, uv);
	vec4 vects = texture(vector_atlas, uv);

	int biome = int(enums.r * 255.0 + 0.5);
	int veg   = int(enums.g * 255.0 + 0.5);
	int cover = int(enums.b * 255.0 + 0.5);
	float moist     = scals.r;
	float lat_norm  = scals.b;
	float vol_intensity_atlas = scals.a;
	vec2 ocean_current_v = vects.rg * 2.0 - 1.0;
	vec2 wind_v          = vects.ba * 2.0 - 1.0;

	// flow + river_edge_warp 浠呭湪闄嗗湴鐨?river 鍒嗘敮鎵嶇敤锛岃繖閲屾帹杩熷埌 _if (!is_water)_ 璁＄畻锛?	// 缁欐按闈?fragment 鐩存帴鐪佹帀 2 涓?fbm + 1 涓?texture sample锛堢害 30-50% 鍍忕礌锛夈€?
	// is_water 鐢?biome 鍐冲畾锛坔ex 鐪熺悊鏉ユ簮锛夛紝涓嶆槸 elev 骞虫粦鎻掑€?	// SEA_ICE 瑙嗚涓婄畻"姘?锛坋lev 鏄按浣嶏級锛屼絾閫氳鎬х畻闄嗗湴锛堢帺娉曞眰锛?	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

	// 鈹€鈹€鈹€ Phase 1锛氬鑺傜浉浣?+ 褰撳墠娓╁害锛堟瘡甯х敱 WorldClock 椹卞姩锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
	// lat_norm 宸插湪 fragment 椤堕儴浠?scalar_atlas.b 瑙ｅ嚭锛坴9.atlas锛?	float lat_signed = lat_norm * 2.0 - 1.0;            // [-1, 1]
	float eff_phase = hemi_phase(season_phase, lat_signed);
	float season_offset = season_temp_offset(eff_phase);
	float current_temp = compute_current_temp(elev, lat_signed, season_offset);

	// 1. Hypsometric base锛堟捣闄嗗弻鍚戠瓑楂樼嚎璁捐壊锛?	vec3 col = hypsometric_tint(elev, is_water);

	if (!is_water) {
		// 2. biome 鑹茬浉璋冨埗
		col = biome_hue_modulate(col, biome);
		// 2.5. 妞嶈瀛ｈ妭鑹茬浉锛堝弬涓庣殑 biome锛氭俯甯?+ 瀵掑甫妫灄銆?		// JUNGLE 涓€骞村父缁夸笉鍙備笌锛汥ESERT/SAVANNA/STEPPE 鑽夋湰鍙樺寲宸茬粡鍦?detail 閲岋級
		if (biome == B_FOREST || biome == B_GRASSLAND || biome == B_HILL || biome == B_PLAIN
				|| biome == B_TAIGA) {
			vec3 veg_tint = vegetation_seasonal_tint(eff_phase);
			col = mix(col, col * veg_tint, vegetation_season_strength);
		} else if (biome == B_SAVANNA || biome == B_STEPPE) {
			// 鑽夊師 / 绋€鏍戣崏鍘燂細鎸箙鍑忓崐锛堝共婀垮瀵规瘮杩滀笉濡傛俯甯︽．鏋楁槑鏄撅級
			vec3 veg_tint = vegetation_seasonal_tint(eff_phase);
			col = mix(col, col * veg_tint, vegetation_season_strength * 0.5);
		}
		// 3. 閿愬埄绋嬪簭鍖栬创鍥撅紙鍚屼竴 biome 鍦ㄤ笉鍚屼綅缃湅璧锋潵涓嶅悓锛?		col *= procedural_biome_detail(biome, wp);
		// 3.5. Milestone 2锛氭琚酱璋冨埗
		// 浠呭湪涓昏壊鍗曚竴鐨勫湴褰?(PLAIN/HILL/MOUNTAIN/GRASSLAND) 涓婂惎鐢紝
		// 璁?涓橀櫟 + 闃斿彾鏋?鍜?涓橀櫟 + 鏋佹棻娌欐紶"鍦ㄩ鑹蹭笂鑳藉尯鍒嗗紑銆?		if (vegetation_axis_strength > 0.001
				&& veg != V_NONE
				&& biome_accepts_vegetation_tint(biome)) {
			vec3 v_tint = vegetation_tint(veg);
			col = mix(col, col * v_tint, vegetation_axis_strength);
		}
	}

	// 4. Hillshading锛堥檰鍦板己闃村奖锛涙捣闈㈢敤浣庨绾圭悊浠ｆ浛 + Phase 3 娲嬫祦娴佺汗鍔ㄧ敾锛?	if (!is_water) {
		// v10.4锛歭ight 鏉ヨ嚜 key+fill锛岀悊璁轰笂闄?鈮?1.2锛屽繀椤?saturate 鍒?[0,1]
		float light = clamp(hillshading_two_lights(uv), 0.0, 1.0);
		col *= mix(1.0 - hillshade_strength, 1.0 + hillshade_strength, light);

		// Data-driven land wind streaks.
		vec2 wind = wind_v;
		if (length(wind) > 0.05 && wind_streak_strength > 0.001) {
			vec2 wind_norm_dir = normalize(wind);
			vec2 perp = vec2(-wind_norm_dir.y, wind_norm_dir.x);
			float along = dot(wp, wind_norm_dir) * 0.016;
			float across = dot(wp, perp) * 0.115;
			float lane = fbm(vec2(along + world_time * 0.018, across), 2);
			float fine = fbm(vec2(along * 2.7 + 19.0, across * 0.72 - world_time * 0.012), 1);
			float streak = smoothstep(0.40, 0.78, lane * 0.70 + fine * 0.30);
			float monsoon_cov = 0.0;
			for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
				if (i >= weather_front_count) break;
				int wt_i = int(weather_front_types[i] + 0.5);
				if (wt_i != WT_MONSOON) continue;
				vec4 c = weather_front_centers[i];
				vec4 shape = weather_front_shapes[i];
				vec4 visual = weather_front_visuals[i];
				float ed = weather_front_ellipse_distance(wp, c.xy, c.z, shape);
				float cov = 1.0 - smoothstep(0.62, 1.36 + visual.z * 0.18, ed);
				monsoon_cov = max(monsoon_cov, cov * max(visual.x, visual.y));
			}
			float boost = mix(1.0, monsoon_wind_streak_boost, monsoon_cov);
			vec3 wind_tint = mix(vec3(0.96, 1.00, 1.03), vec3(0.84, 0.94, 1.04), monsoon_cov);
			col *= mix(vec3(1.0), wind_tint, wind_streak_strength * boost * 0.65);
			col *= 1.0 + (streak - 0.5) * wind_streak_strength * boost * 1.8;
		}
	} else if (is_water) {
		// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?		// Water Biome Soft Blend锛堝弬鑰?ShaderToy 2D Stylized Water 鏍蜂緥锛?		//
		// 鏃у疄鐜扮殑鏍规湰闂锛歀AKE/REEF/KELP/SEA_ICE/OCEAN 姣忎釜 biome 鏄簰鏂?		// if/else 鍒嗘敮锛屼氦鐣?1 鍍忕礌纭垏锛岃€屼笖姣忓垎鏀唴閮介噸绠椾竴濂?搴曡壊 脳 fbm"锛?		// 瀵艰嚧娴锋磱鍜屾捣鑽夋灄涔嬮棿鐨勮繃娓″儚璐磋姳銆?		//
		// 鏂板仛娉曪細
		// 1) 鐢?water_biome_weights 鐨?3脳3 閭诲煙璁℃暟寰楀埌杞潈閲嶃€?		// 2) 鍏堢畻缁熶竴"娣辨祬姊害搴曡壊"锛堥渶姹?3.1/3.2 鐨勪笁娈电宀歌壊锛夈€?		// 3) 鍚?biome 鐗瑰緛鑹?/ 鐗瑰緛绾圭悊 鐢?weight 绱姞 mix 鍒板簳鑹蹭笂銆?		// 4) 鍩熸壄鏇诧紙water_domain_warp锛夎鎵€鏈?biome 鐗瑰緛绾圭悊娌垮悓涓€姘存祦琚悈鏁ｏ紝
		//    杩涗竴姝ユā绯婅竟鐣屻€?		// 5) 鏉＄汗锛坵ater_shade_lines锛変綔涓哄叏灞€涓€灞傝鐩栵紝浼犺揪 2D stylized water 鐨?鍔ㄦ劅"銆?		// 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

		// (A) 涓栫晫鍧愭爣鍩熸壄鏇诧紙缁欐墍鏈夊悗缁?fbm/voronoi 閲囨牱浣跨敤锛?		// 杞贩鍚堝崐寰勫悓鏃剁害鏉熸壄鏇插己搴︼紝閬垮厤杈圭晫鍣０鎶婄壒娈婃按浣撹繃搴︽嫋鍏ラ檰鍦版垨绐勬渤閬撱€?		float water_boundary_softness = clamp(water_biome_blend_radius / 2.2, 0.0, 1.0);
		float warp_for_water = water_domain_warp_strength * mix(0.45, 1.0, water_boundary_softness);
		vec2 wpw = water_domain_warp(wp, world_time, warp_for_water);

		// (B) 缁熶竴娣辨祬姊害搴曡壊锛堢宀稿害 offshore锛屼唬鏇挎棫鐨勪笁娈?if锛?		float offshore = 0.0;
		{
			vec2 tx = 1.0 / hm_resolution;
			float deep_cnt = 0.0;
			if (visual_quality >= 1) {
				for (int oy = -2; oy <= 2; oy++) {
					for (int ox = -2; ox <= 2; ox++) {
						float eh = decode_height_rg8(uv + vec2(float(ox), float(oy)) * tx);
						deep_cnt += step(eh, sea_level - 0.02);
					}
				}
				offshore = clamp(deep_cnt / 25.0, 0.0, 1.0);
			} else {
				for (int oy = -1; oy <= 1; oy++) {
					for (int ox = -1; ox <= 1; ox++) {
						float eh = decode_height_rg8(uv + vec2(float(ox), float(oy)) * tx);
						deep_cnt += step(eh, sea_level - 0.02);
					}
				}
				offshore = clamp(deep_cnt / 9.0, 0.0, 1.0);
			}
		}
		float depth_t = 1.0 - clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
		float offshore_depth = clamp(offshore * 0.68 + smoothstep(0.00, 0.68, depth_t) * 0.32, 0.0, 1.0);
		vec3 tier_color = water_depth_gradient(offshore_depth, elev);
		float water_fill_w = smoothstep(0.02, 0.82, 0.58 + offshore_depth * 0.34);
		// Let the stylized water palette dominate, while still preserving subtle terrain shading below it.
		col = mix(col, tier_color, water_fill_w);
		float lagoon_lift = 1.0 - smoothstep(0.10, 0.56, offshore_depth);
		col = mix(col, col * vec3(0.90, 1.07, 1.10), lagoon_lift * 0.14);

		// (C) 鍏ㄥ眬浣庨姘磋壊璧蜂紡锛堟墍鏈夋按浣撳叡浜悓涓€灞?ripple锛岃竟鐣屾棤鎰燂級
		// 浣跨敤涓ゅ眰浣庨 fbm锛氫竴灞傛彁浜殫锛屽彟涓€灞傚彧缁欐繁娴峰喎鏆栬壊鐩稿彉鍖栥€?		float base_ripple = fbm(wpw * 0.008 + vec2(31.0, 7.0), 2);
		float deep_ripple = fbm(wpw * 0.0038 + vec2(-47.0, 23.0), 2);
		float deep_layer_w = smoothstep(0.36, 1.0, offshore_depth);
		col *= 1.0 + (base_ripple - 0.5) * mix(0.050, 0.082, deep_layer_w);
		vec3 deep_variation = mix(vec3(0.92, 1.03, 1.14), vec3(1.08, 0.94, 1.05), deep_ripple);
		col *= mix(vec3(1.0), deep_variation, deep_layer_w * 0.115);
		vec3 cartoon_chroma = mix(vec3(0.78, 1.20, 1.18), vec3(0.70, 0.96, 1.38), smoothstep(0.12, 1.0, offshore_depth));
		col *= mix(vec3(1.0), cartoon_chroma, water_cartoon_color_strength * 0.26);
		if (visual_quality >= 1 && water_cartoon_color_strength > 0.001) {
			float color_block = fbm(wpw * 0.0048 + vec2(world_time * 0.010, -world_time * 0.006), 2);
			vec3 block_tint = mix(vec3(0.80, 1.16, 1.15), vec3(0.92, 0.93, 1.24), color_block);
			col *= mix(vec3(1.0), block_tint, water_cartoon_color_strength * mix(0.10, 0.18, deep_layer_w));
		}

		// (D) biome 杞潈閲?		vec4 bw;
		if (water_biome_blend_radius > 0.001) {
			float blend_radius_eff = water_biome_blend_radius * mix(1.0, 1.45, water_transition_softness);
			bw = water_biome_weights(uv, 1.0 / hm_resolution, blend_radius_eff);
		} else {
			// 杞贩鍚堝叧闂?鈫?閫€鍖栦负"褰撳墠鍍忕礌 biome 鍗?1"
			bw = vec4(
				biome == B_LAKE    ? 1.0 : 0.0,
				biome == B_REEF    ? 1.0 : 0.0,
				biome == B_KELP    ? 1.0 : 0.0,
				biome == B_SEA_ICE ? 1.0 : 0.0
			);
		}
		// Radius-aware smooth weights: wider radii use a lower entry threshold so
		// neighboring water biomes feather in gently instead of popping at one texel.
		float transition_soft = clamp(max(water_boundary_softness, water_transition_softness), 0.0, 1.0);
		float blend_entry = mix(0.28, 0.05, transition_soft);
		float blend_full = mix(0.92, 0.56, transition_soft);
		float w_lake = smoothstep(blend_entry, blend_full, bw.x);
		float w_reef = smoothstep(blend_entry, blend_full, bw.y);
		float w_kelp = smoothstep(blend_entry, blend_full, bw.z);
		float w_ice  = smoothstep(blend_entry, blend_full, bw.w);
		// Keep stacked special-water weights bounded so overlapping borders stay soft
		// without over-tinting or producing decal-like saturated seams.
		float special_sum = max(w_lake + w_reef + w_kelp + w_ice, 1.0);
		w_lake /= special_sum;
		w_reef /= special_sum;
		w_kelp /= special_sum;
		w_ice  /= special_sum;

		float open_ocean_w = clamp(
			(1.0 - w_lake - w_reef * 0.62 - w_kelp * 0.78 - w_ice)
					* smoothstep(0.26, 0.92, offshore_depth),
			0.0,
			1.0
		);
		if (open_ocean_w > 0.001 && water_cartoon_color_strength > 0.001) {
			int ocean_patch_oct = (visual_quality >= 2) ? 3 : 2;
			float gyre_a = fbm(wpw * 0.0056 + vec2(13.0, -31.0), ocean_patch_oct);
			float gyre_b = fbm(wpw * 0.012 + vec2(-29.0, 47.0), 1);
			if (visual_quality >= 1) {
				gyre_b = fbm(wpw * 0.012 + vec2(world_time * 0.012, -world_time * 0.007), 2);
			}
			float gyre_mix = smoothstep(0.20, 0.86, gyre_a * 0.72 + gyre_b * 0.28);
			vec3 cobalt_patch = vec3(0.018, 0.16, 0.48);
			vec3 teal_patch = vec3(0.020, 0.32, 0.54);
			vec3 violet_patch = vec3(0.045, 0.13, 0.52);
			vec3 ocean_patch = mix(cobalt_patch, teal_patch, gyre_mix);
			ocean_patch = mix(ocean_patch, violet_patch, smoothstep(0.70, 1.0, offshore_depth) * (1.0 - gyre_mix) * 0.55);
			float patch_w = open_ocean_w * water_cartoon_color_strength * mix(0.34, 0.58, gyre_mix);
			col = mix(col, ocean_patch, patch_w);
			col *= 1.0 + (gyre_mix - 0.5) * open_ocean_w * water_cartoon_color_strength * 0.18;
		}

		// (E) LAKE 鐗瑰緛鍙犲姞锛氬钩闈欍€佷綆瀵规瘮銆佸亸闈掔豢鐨勬箹姘村眰
		// visual_quality=0 淇濈暀鑹插僵鍒嗗眰锛岃烦杩囩浜屽眰缁嗚妭鍣０锛?=2 浣跨敤瀹屾暣鍙屽眰鏌斿櫔澹般€?		int water_detail_oct = (visual_quality >= 2) ? 2 : 1;
		if (w_lake > 0.001) {
			vec3 lake_cartoon = mix(lake_water_color, vec3(0.13, 0.66, 0.72), water_cartoon_color_strength * 0.55);
			vec3 lake_surface = mix(water_depth_gradient(offshore_depth * 0.72, elev), lake_cartoon, 0.66);
			float lake_depth_t = smoothstep(0.04, 0.46, depth_t);
			vec3 lake_deep = lake_cartoon * vec3(0.72, 0.90, 0.96);
			vec3 lake_col = mix(lake_surface, lake_deep, lake_depth_t * 0.42);
			float lake_ripple = fbm(wpw * 0.018 + vec2(7.0, -19.0), water_detail_oct);
			float lake_glass = 0.5;
			if (visual_quality >= 1) {
				lake_glass = fbm(wpw * 0.006 + vec2(-23.0, 11.0), water_detail_oct);
			}
			lake_col *= 1.0 + (lake_ripple - 0.5) * 0.026 + (lake_glass - 0.5) * 0.016;
			lake_col = mix(lake_col, lake_surface, 0.18);
			col = mix(col, lake_col, w_lake * 0.92);
		}

		// (F) REEF 鐗瑰緛鍙犲姞锛氭祬闈掔豢 + 澶у昂搴︾強鐟氭枒锛屼繚鎸侀€忔槑娓呮緢鑰岄潪楂橀璐磋姳
		if (w_reef > 0.001) {
			float reef_depth = clamp(offshore_depth * 0.36 + depth_t * 0.16, 0.0, 1.0);
			vec3 reef_lagoon = mix(vec3(0.38, 0.82, 0.78), vec3(0.32, 0.94, 0.84), water_cartoon_color_strength * 0.55);
			vec3 reef_outer = mix(water_depth_gradient(clamp(offshore_depth * 0.82, 0.0, 1.0), elev), vec3(0.14, 0.58, 0.68), 0.34);
			vec3 reef_base = mix(reef_lagoon, reef_outer, smoothstep(0.12, 0.88, reef_depth));
			float coral_soft = 0.5;
			float reef_sheen = 0.5;
			if (visual_quality >= 1) {
				float coral_spots = voronoi_cell(wpw * 0.24);
				coral_soft = smoothstep(0.04, 0.74, coral_spots);
			}
			if (visual_quality >= 2) {
				reef_sheen = fbm(wpw * 0.018 + vec2(17.0, 29.0), 2);
			}
			vec3 coral_tint = mix(vec3(0.32, 0.74, 0.67), vec3(0.22, 0.58, 0.60), smoothstep(0.30, 0.88, offshore_depth));
			vec3 reef_col = mix(reef_base * 1.035, coral_tint, coral_soft * 0.16);
			reef_col *= 1.0 + (reef_sheen - 0.5) * 0.022;
			float reef_edge_feather = mix(0.66, 0.88, 1.0 - smoothstep(0.22, 0.92, offshore_depth));
			float reef_mix_w = w_reef * reef_edge_feather;
			col = mix(col, reef_col, reef_mix_w);
		}

		// (G) KELP 鐗瑰緛鍙犲姞锛氭繁缁胯缁熶竴姘磋壊鍖呰９锛岄『娲嬫祦褰㈡垚瀹借蒋甯︾姸鏄庢殫
		if (w_kelp > 0.001) {
			vec3 kelp_base = mix(water_depth_gradient(offshore_depth, elev), vec3(0.06, 0.36, 0.30), 0.62);
			vec2 oc_k = ocean_current_v;
			vec2 oc_norm = (length(oc_k) > 0.05) ? normalize(oc_k) : vec2(1.0, 0.0);
			vec2 perp_k = vec2(-oc_norm.y, oc_norm.x);
			float along_k = dot(wpw, oc_norm) * 0.030;
			float across_k = dot(wpw, perp_k) * 0.095;
			float kelp_streak = 0.5;
			if (visual_quality >= 1) {
				kelp_streak = fbm(vec2(along_k + world_time * 0.035, across_k), water_detail_oct);
			}
			float kelp_patch = fbm(wpw * 0.018 + vec2(5.0, -41.0), water_detail_oct);
			vec3 kelp_col = mix(kelp_base, vec3(0.05, 0.28, 0.23), kelp_patch * 0.26);
			kelp_col *= mix(0.94, 1.045, kelp_streak);
			col = mix(col, kelp_col, w_kelp * 0.86);
		}

		// (H) SEA_ICE 鐗瑰緛鍙犲姞锛氬喎钃濈櫧鍐扮洊 + 浣庡姣旇绾癸紝璺宠繃鍔ㄦ€佹按绾硅瑷€
		if (w_ice > 0.001) {
			vec3 ice_base = mix(water_depth_gradient(offshore_depth * 0.65, elev), vec3(0.84, 0.91, 0.95), 0.82);
			float crack_factor = 0.55;
			if (visual_quality >= 1) {
				float crack = voronoi_cell(wpw * 0.34);
				crack_factor = smoothstep(0.03, 0.18, crack);
			}
			float ice_noise = fbm(wpw * 0.12 + vec2(-9.0, 31.0), water_detail_oct);
			vec3 ice_col = mix(ice_base * 0.82, ice_base * 1.04, crack_factor);
			ice_col *= mix(0.96, 1.035, ice_noise);
			col = mix(col, ice_col, w_ice * 0.94);
		}

		// (I) 娴呮按 / 娴呮箹閫忔槑灞傦細鍙湪杩戝哺銆佹祬婀栧拰娴呯杞诲井閫忓簳锛屾繁娴蜂繚鎸佸帤閲嶃€?		// 浣跨敤 offshore_depth 涓庢按浣撹蒋鏉冮噸杩炵画鎺у埗寮哄害锛岄伩鍏嶅浐瀹氭贩鍏ラ檰鍦拌壊閫犳垚鑴忚竟銆?		if (shallow_transparency_enabled && visual_quality >= 1) {
			float depth_clarity = 1.0 - smoothstep(0.28, 0.86, offshore_depth);
			float coastal_clarity = (biome == B_COAST) ? 1.0 : 0.0;
			float lake_clarity = w_lake * (1.0 - smoothstep(0.16, 0.62, depth_t));
			float reef_clarity = w_reef * 0.42;
			float kelp_guard = 1.0 - w_kelp * 0.70;
			float ice_guard = 1.0 - w_ice;
			float clarity_w = clamp(
				(coastal_clarity * 0.62 + lake_clarity * 0.46 + reef_clarity) * depth_clarity,
				0.0,
				0.72
			) * kelp_guard * ice_guard * shallow_transparency_factor;
			if (clarity_w > 0.001) {
				vec3 substrate_col = mix(color_lowland, color_beach, coastal_clarity * 0.70 + reef_clarity * 0.35);
				substrate_col = mix(substrate_col, lake_water_color * 0.78, w_lake * 0.55);
				vec3 clear_water_col = mix(col, substrate_col, 0.20 + depth_clarity * 0.18);
				clear_water_col = mix(clear_water_col, col * vec3(0.94, 1.02, 1.04), 0.35);
				col = mix(col, clear_water_col, clarity_w);
			}
		}

		// Data-driven ocean current streaks. Keep direction fixed to vector_atlas.rg;
		// avoid phase-crossfaded flow-map advection that reads as rotating swirls.
		if (ocean_current_enabled && visual_quality >= 1) {
			vec2 oc = ocean_current_v;
			float flow_mag = clamp(length(oc), 0.0, 1.0);
			vec2 oc_dir = (flow_mag > 0.035) ? normalize(oc) : normalize(wind_v + vec2(0.0001, 0.0));
			vec2 oc_side = vec2(-oc_dir.y, oc_dir.x);
			float along = dot(wp, oc_dir) * mix(0.010, 0.024, water_cartoon_color_strength) + world_time * 0.035;
			float across = dot(wp, oc_side) * mix(0.060, 0.105, water_cartoon_color_strength);
			int current_oct = (visual_quality >= 2) ? 2 : 1;
			float lane_low = fbm(vec2(along, across), current_oct);
			float lane_high = fbm(vec2(along * 2.8 + 17.0, across * 0.55 - 31.0), 1);
			float current_lane = smoothstep(0.38, 0.80, lane_low * 0.72 + lane_high * 0.28);
			float non_static = clamp(1.0 - w_ice - w_lake * 0.85, 0.0, 1.0);
			float current_w = ocean_current_strength * non_static * mix(0.48, 1.0, smoothstep(0.08, 0.74, offshore_depth));
			current_w = clamp(current_w * mix(0.45, 1.0, flow_mag), 0.0, 1.0);
			float streak_amp = ocean_current_debug ? 0.82 : mix(0.24, 0.42, water_cartoon_color_strength);
			vec3 current_tint = mix(vec3(0.78, 1.08, 1.16), vec3(0.50, 0.76, 1.25), smoothstep(0.34, 1.0, offshore_depth));
			vec3 current_shadow = mix(vec3(1.03, 0.99, 0.92), vec3(0.84, 0.94, 1.10), smoothstep(0.20, 1.0, offshore_depth));
			col *= mix(1.0, 1.0 + (current_lane - 0.50) * streak_amp, current_w);
			col *= mix(vec3(1.0), mix(current_shadow, current_tint, current_lane), current_w * 0.20);
			if (ocean_current_debug) {
				vec3 dir_tint = vec3(0.5 + oc_dir.x * 0.5, 0.5 + oc_dir.y * 0.3, 0.5 - oc_dir.x * 0.5);
				col = mix(col, dir_tint, 0.28 * ocean_current_strength * non_static);
			}
		}
		float river_sdf_water = texture(scalar_atlas, uv).g;
		if (estuary_plume_strength > 0.001 && river_sdf_water > river_threshold_low * 0.58) {
			vec2 plume_vec = ocean_current_v + wind_v * 0.24;
			vec2 plume_dir = (length(plume_vec) > 0.05) ? normalize(plume_vec) : vec2(1.0, 0.0);
			vec2 plume_step = plume_dir * (1.0 / hm_resolution) * mix(3.0, 7.0, water_transition_softness);
			float tail_a = texture(scalar_atlas, clamp(uv - plume_step, vec2(0.0), vec2(1.0))).g;
			float tail_b = texture(scalar_atlas, clamp(uv - plume_step * 1.8, vec2(0.0), vec2(1.0))).g;
			float plume_src = max(river_sdf_water, max(tail_a * 0.82, tail_b * 0.62));
			float plume_noise = 0.5;
			if (visual_quality >= 1) {
				plume_noise = fbm(wpw * 0.055 + plume_dir * world_time * 0.065, water_detail_oct);
			}
			float plume = smoothstep(river_threshold_low * 0.72, river_threshold_high, plume_src);
			plume *= mix(0.88, 1.14, plume_noise);
			plume *= clamp(1.0 - w_ice - w_lake * 0.22, 0.0, 1.0);
			vec3 plume_col = mix(
				river_color * vec3(1.12, 1.10, 1.02),
				color_coast_water * vec3(0.84, 1.14, 1.20),
				smoothstep(0.12, 0.70, offshore_depth)
			);
			col = mix(col, plume_col, clamp(plume * estuary_plume_strength * 0.55, 0.0, 0.55));
		}
	}
	// Water Visual Overhaul锛氭按浣撶粺涓€娉㈡氮 + 鍏夌収 + 娴姳 + 鐒︽暎銆?	// 鍏ㄩ儴鍙?water_effect_enabled 鎬诲紑鍏虫帶鍒讹紱鍏虫帀鍗冲洖閫€鍒颁笂闈㈢殑鍩虹姘翠綋鐫€鑹层€?	if (is_water && water_effect_enabled) {
		// 鈹€鈹€ 0. 鎸夋按浣撶被鍨嬬‘瀹氭尝娴垎妗ｏ紙闇€姹?1.4/1.5/1.6/1.7锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		// SEA_ICE 涓嶅弬涓庢尝娴紱LAKE 缁嗗瘑灏忔尝锛汻EEF 琚鍓婂急锛涘叾浠栨捣鍩熸爣鍑嗗箙搴︺€?		float wave_amp_scale  = 1.0;
		float wave_freq_scale = 1.0;
		float current_align_w = 0.0;  // 娉㈡柟鍚戜笌娲嬫祦鍚戦噺鐨勫榻愭潈閲?		if (biome == B_LAKE) {
			wave_amp_scale = 0.22;
			wave_freq_scale = 0.82;
			current_align_w = 0.0;
		} else if (biome == B_REEF) {
			wave_amp_scale = 0.42;
			wave_freq_scale = 0.78;
			current_align_w = 0.36;
		} else if (biome == B_KELP) {
			wave_amp_scale = 0.36;
			wave_freq_scale = 0.70;
			current_align_w = 0.40;
		} else if (biome == B_OCEAN || biome == B_COAST) {
			wave_amp_scale = 0.72;
			wave_freq_scale = 0.76;
			current_align_w = 0.46;
		} else {
			// SEA_ICE 绛夛細绂佺敤娉㈡氮
			wave_amp_scale = 0.0;
		}
		// visual_quality==0 閫€鍖栵細浠?1 鍒嗛噺涓绘柟鍚戯紙闇€姹?1.8锛?		int wave_q = (visual_quality >= 1) ? 1 : 0;
		// 鎶?wp 娌挎磱娴佹柟鍚戝仛鏇存槑鏄剧殑瀹藉昂搴﹀亸杞紝璁╂尝娴瑙変笂璺熼殢娲嬫祦鑰岄潪鐙珛婕傛诞銆?		vec2 wave_wp = wp;
		if (ocean_current_enabled && current_align_w > 0.001) {
			vec2 current_dir = (length(ocean_current_v) > 0.05) ? normalize(ocean_current_v) : vec2(1.0, 0.0);
			float current_push = current_align_w * mix(0.85, 1.45, ocean_current_strength);
			wave_wp = wp + current_dir * current_push + ocean_current_v * current_align_w * 0.80;
		}
		// 姘撮潰娉曠嚎锛堜緵娴姳杩戝哺鏀惧ぇ浣跨敤鍓嶅厛绠椾竴娆★級
		bool waves_on = water_waves_enabled && wave_amp_scale > 0.001;
		vec3 N_water = sample_water_normal(
			wave_wp, world_time, wave_amp_scale, wave_freq_scale, wave_q, waves_on
		);

		// 鈹€鈹€ 0.5. 娴峰哺 SDF锛堝湪 shader 鍐呭澶勭敤鍒帮細杩戝哺 N 鏀惧ぇ / 娴姳 / 閫忓簳 / 娌冲彛锛?鈹€鈹€
		float coast_sdf = abs(elev - sea_level);
		// 杩戝哺姘存祬锛屾硶绾挎壈鍔ㄥ彧鍋氳交寰斁澶э紝閬垮厤娴峰哺绾块檮杩戝嚭鐜板瘑闆嗕寒绾广€?		if (waves_on && coast_sdf < 0.05 && (biome == B_OCEAN || biome == B_COAST)) {
			float near_shore_boost = 1.0 + 0.12 * (1.0 - smoothstep(0.0, 0.05, coast_sdf));
			N_water.xy *= near_shore_boost;
			N_water = normalize(N_water);
		}

		// 鈹€鈹€ 1. 鏂瑰悜鍏夋极鍙嶅皠 + Blinn-Phong 楂樺厜锛堥渶姹?2.1/2.2锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		// tod_sun_dir 宸插湪鍒囩嚎绌洪棿涓嬪綊涓€鍖栵紱姘撮潰娉曠嚎浜?z-up銆?		vec3 L = normalize(tod_sun_dir);
		vec3 V = vec3(0.0, 0.0, 1.0);
		vec3 H = normalize(L + V);
		float NdotL = max(dot(N_water, L), 0.0);
		float NdotH = max(dot(N_water, H), 0.0);
		// 婀栨硦浣跨敤鏇撮攼鍒╀絾鏇村急鐨勯珮鍏夛紝鍏朵粬姘翠綋淇濇寔瀹借€屾煍鐨勫弽鍏夈€?		float gloss_eff = water_gloss;
		float spec_mul = 0.72;
		if (biome == B_LAKE) {
			gloss_eff = 72.0;
			spec_mul = 0.42;
		}
		float spec_term = pow(NdotH, gloss_eff);
		// 澶滄櫄楂樺厜鍘嬪埌 0.18脳锛堟湀鍏夛級锛岀櫧澶?0.50锛岄伩鍏嶉珮棰戦棯鐐规姠鐪笺€?		float specular_strength = mix(0.50, 0.18, tod_night_factor) * spec_mul;
		vec3 specular = tod_sun_color * spec_term * specular_strength;
		// 婕弽灏勫彧鍋氳交寰彁浜紝淇濈暀娉㈤潰璧蜂紡浣嗕笉鐢熸垚寮轰寒绾广€?		col *= 1.0 + NdotL * 0.10;
		col += specular;

		// 鈹€鈹€ 2. 鑿叉秴灏斿ぉ绌哄弽灏勶紙闇€姹?2.3/2.4锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		if (water_fresnel_enabled) {
			float F;
			if (visual_quality <= 1) {
				// 浣庤川锛氬父閲忚彶娑呭皵
				F = 0.30;
			} else {
				F = pow(1.0 - clamp(N_water.z, 0.0, 1.0), 5.0);
			}
			// sky tint锛氱敱 tod_ambient_color 娲剧敓锛岀櫧澶╁亸娴呰摑锛屽鏅氱敤 ambient 鏈韩
			vec3 sky_tint = tod_ambient_color * mix(1.15, 0.70, tod_night_factor);
			col = mix(col, sky_tint, F * water_reflection_strength);
		}

		// 鈹€鈹€ 3. 娴峰哺婊氬姩娴姳锛堥渶姹?6.1/6.2/6.3/6.4锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		if (biome == B_COAST || biome == B_OCEAN) {
			float foam_mask_raw = 1.0 - smoothstep(0.0, 0.045, coast_sdf);
			if (foam_mask_raw > 0.001) {
				// 涓绘氮锛氭部 coast_sdf 鎺ㄨ繘鐨勬粴鍔ㄧ浉浣嶏紝浣庨鎱㈤€燂紝閬垮厤褰㈡垚瀵嗛泦鐧界嚎銆?				float local_noise = 0.5;
				if (visual_quality >= 1) {
					int foam_oct = (visual_quality >= 2) ? 2 : 1;
					local_noise = fbm(wp * 0.10 + vec2(world_time * 0.08, -world_time * 0.06), foam_oct);
				}
				float main_phase = coast_sdf * 130.0 - world_time * 1.10 + local_noise * 1.20;
				float main_wave = sin(main_phase) * 0.5 + 0.5;
				// 瀛愭氮鍙綔涓烘煍鍜岀牬纰庯紱浣庣敾璐ㄨ烦杩囧瓙娴紝淇濈暀涓€鏉℃煍鍜屼富娴€?				float sub_wave = 0.5;
				if (visual_quality >= 1) {
					float sub_phase = coast_sdf * 240.0 - world_time * 1.65 + local_noise * 0.75;
					sub_wave = sin(sub_phase) * 0.5 + 0.5;
				}
				float wave_stack = main_wave * 0.82 + sub_wave * 0.18;
				// 椋庨€熸墿瀹芥氮鑺卞甫锛堥渶姹?6.4锛夛細闀垮害 [0, 1.4]锛屾墿瀹?0~25%
				float wind_mag = clamp(length(wind_v), 0.0, 1.4);
				float wind_widen = 1.0 + wind_mag * 0.18;
				float foam_mask = 1.0 - smoothstep(0.0, 0.045 * wind_widen, coast_sdf);
				float foam = smoothstep(0.70, 0.97, wave_stack) * foam_mask * 0.28;
				// 娴《娉℃搏鍙仛杞诲井鎻愪寒锛岄伩鍏嶆捣宀稿舰鎴愬埡鐪奸棯绾裤€?				float crest = smoothstep(0.93, 1.0, main_wave) * foam_mask * 0.16;
				col = mix(col, vec3(0.90, 0.95, 0.98), clamp(foam + crest, 0.0, 0.42));
			}
		}

		// 鈹€鈹€ 4. 绮煎厜楂樺厜锛堜繚鐣欎絾澶у箙闄嶅箙锛岄伩鍏嶄笌 Blinn-Phong 閲嶅锛?鈹€鈹€鈹€鈹€鈹€鈹€
		// 鏇翠綆棰戙€佹洿楂橀槇鍊笺€佹洿浣庡己搴︼細鍙暀涓嬬█鐤忔煍鍜岄棯鐑侊紝涓嶅啀褰㈡垚纰庣幓鐠冪偣闃点€?		if (day_night_enabled && visual_quality >= 1 && water_sparkle_enabled) {
			float sparkle_freq = 0.085;
			float sparkle_speed_day = 0.32;
			int sparkle_oct = (visual_quality >= 2) ? 2 : 1;
			float sparkle = fbm(wp * sparkle_freq + vec2(world_time * sparkle_speed_day, -world_time * 0.20), sparkle_oct);
			float spark_mask = smoothstep(0.88, 0.985, sparkle);
			vec3 day_sparkle_col = vec3(1.03, 1.02, 0.96);
			vec3 night_sparkle_col = vec3(0.76, 0.86, 1.03);
			vec3 sparkle_col = mix(day_sparkle_col, night_sparkle_col, tod_night_factor);
			float base_intensity = 0.028;
			float intensity = mix(base_intensity, base_intensity * 0.45, tod_night_factor);
			float night_freq_scale = mix(1.0, 0.55, tod_night_factor);
			spark_mask *= night_freq_scale;
			col = mix(col, col * sparkle_col, spark_mask * intensity);
		}

		// 鈹€鈹€ 4.5. Water Calm Noise锛氬ぇ灏哄害浣庡姣斿害鏌斿拰鍣０ 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		// 浠ｆ浛鍘熲€? 灞?sin 妯悜娉㈢棔鏉＄汗鈥濓細鏀逛负 2 灞?fbm 鍙犲姞鈥斺€斾竴灞傜浜害锛?		// 涓€灞傜鍐?鏆栬壊鐩革紱浣庣敾璐ㄨ烦杩囧姩鎬佹煍鍣０锛屼紭鍏堜繚鐣欐按鑹叉笎鍙樹笌杈圭晫鏌斿寲銆?		if (water_wave_line_strength > 0.001 && waves_on && visual_quality >= 1) {
			// biome 骞呭害璋冨埗锛氭箹娉婄暐寮便€佹捣钘诲緢寮便€佹捣鍐颁笉鍙犲姞鍔ㄦ€佹煍鍣０銆?			float calm_amp_mul = 1.0;
			if (biome == B_LAKE) {
				calm_amp_mul = 0.65;
			} else if (biome == B_KELP) {
				calm_amp_mul = 0.28;
			} else if (biome == B_SEA_ICE) {
				calm_amp_mul = 0.0;
			}
			// 浜害鎵板姩灞傦紙榛樿绾?卤3%锛?			float calm = water_calm_brightness(wave_wp, world_time);
			float bright_amp = water_wave_line_strength
					* water_calm_noise_brightness * calm_amp_mul;
			col *= mix(1.0, 1.0 + calm * 0.045, clamp(bright_amp, 0.0, 1.0));

			// 鑹茬浉鎵板姩灞傦紙榛樿绾?卤1%锛寁isual_quality >= 1 鎵嶅惎鐢紱>=2 鎻愬崌 octaves锛?			int tint_oct = (visual_quality >= 2) ? 3 : 2;
			float tint_mix = water_calm_tint(wave_wp, world_time, tint_oct);
			vec3 TINT_COLD = vec3(0.97, 0.99, 1.03);
			vec3 TINT_WARM = vec3(1.03, 1.015, 0.97);
			vec3 tint = mix(TINT_COLD, TINT_WARM, tint_mix);
			float tint_amp = water_wave_line_strength
					* water_calm_noise_tint_strength * calm_amp_mul;
			col *= mix(vec3(1.0), tint, 0.035 * clamp(tint_amp, 0.0, 1.0));
		}
		// 鈹€鈹€ 5. 鐝婄憵绀佺劍鏁ｏ紙闇€姹?5.1/5.2锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		if (biome == B_REEF && caustics_enabled && visual_quality >= 1
				&& day_night_enabled && tod_night_factor < 0.5) {
			int caustics_oct = (visual_quality >= 2) ? 2 : 1;
			float caustics = fbm(wp * 0.35 + vec2(world_time * 0.08, -world_time * 0.12), caustics_oct);
			float caustics_mask = smoothstep(0.55, 0.75, caustics);
			float day_factor = 1.0 - tod_night_factor;
			vec3 caustic_col = tod_sun_color * 1.15;
			col = mix(col, col + caustic_col * 0.35, caustics_mask * caustics_strength * day_factor);
		}

		// 鈹€鈹€ 6. 閫忔槑灞傚悗澶勭悊锛氬熀纭€姘磋壊闃舵宸插畬鎴愰€忓簳娣峰悎锛岃繖閲屽彧琛ヤ竴灞傚緢寮辩殑娓呮緢鎰熴€?		// 涓嶅啀浜屾娣峰叆 beach/lowland锛岄伩鍏嶆祬姘磋闄嗗湴鑹叉薄鏌撴垨娣辨捣琚敊璇彁浜€?		if (shallow_transparency_enabled && visual_quality >= 1) {
			float coast_clear = 0.0;
			if (biome == B_COAST || biome == B_LAKE || biome == B_REEF) {
				coast_clear = 1.0 - smoothstep(0.0, 0.035, coast_sdf);
			}
			if (coast_clear > 0.001) {
				vec3 clarity_tint = col * vec3(0.96, 1.02, 1.05);
				col = mix(col, clarity_tint, coast_clear * shallow_transparency_factor * 0.18);
			}
		}

		// 鈹€鈹€ 7. BLIZZARD 钖勫啺锛堜繚鐣欏師 Pass2 琛屼负锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
		if (extreme_weather_ground_effect_enabled && weather_front_count > 0) {
			float ice_mask = compute_extreme_weather_mask(wp, WT_BLIZZARD);
			if (ice_mask > 0.001) {
				vec3 thin_ice = vec3(0.82, 0.88, 0.92);
				col = mix(col, thin_ice, clamp(ice_mask * 0.70, 0.0, 0.70));
			}
		}
	}

	// 5. 娌虫祦锛堜粎闄嗗湴锛涙祦閲忛┍鍔ㄥ搴︼級
	if (!is_water) {
		// 娌冲哺杈圭紭浣跨敤鏇村銆佹洿浣庨鐨勬壈鍔紝閬垮厤缁嗘渤鍙樻垚閿娇鍣０绾裤€?		// visual_quality=0 鐩存帴璇?atlas锛岃烦杩?2 娆?fbm 娌冲哺鎵板姩浠ヤ繚鐣欐€ц兘銆?		vec2 river_edge_warp = vec2(0.0);
		if (visual_quality >= 1) {
			river_edge_warp = vec2(
				fbm(wp * 0.075 + vec2(7.0, -3.0), 1),
				fbm(wp * 0.075 + vec2(-11.0, 5.0), 1)
			) - 0.5;
		}
		float flow = texture(scalar_atlas, uv + river_edge_warp * 0.0024).g;
		float river_t_raw = smoothstep(river_threshold_low, river_threshold_high, flow);
		float river_t = river_t_raw;
		float outline_t = smoothstep(river_threshold_low * 0.78, river_threshold_low, flow)
				* (1.0 - smoothstep(river_threshold_high, min(river_threshold_high + 0.22, 1.0), flow));
		// 娌冲鍛煎惛椤瑰彧鍋氳交寰綆棰戝彉鍖栵紝淇濇寔鐙獎娌抽亾娓呮櫚浣嗕笉闂儊銆?		if (river_t > 0.001 && river_flow_enabled && river_flow_speed > 0.001 && visual_quality >= 1) {
			float pulse = 1.0 + 0.055 * sin(dot(wp, vec2(0.35, 0.42)) - world_time * 0.55);
			river_t = clamp(river_t * pulse, 0.0, 1.0);
		}
		float river_depth_w = smoothstep(0.18, 1.0, river_t_raw);
		vec3 river_surface = mix(river_color * vec3(1.10, 1.08, 1.02), color_mid_ocean, 0.18);
		vec3 river_deep = mix(river_color * vec3(0.72, 0.84, 0.98), color_deep_ocean, 0.20);
		vec3 river_body = mix(river_surface, river_deep, river_depth_w * 0.42);
		vec3 river_edge_col = mix(river_outline_color, river_color * vec3(0.82, 0.95, 1.05), 0.32);
		col = mix(col, river_edge_col, outline_t * 0.50 * river_strength);
		col = mix(col, river_body, river_t * river_strength);

		// Water Visual Overhaul锛氭渤娴侀『鍧℃祦鍔ㄦ槑鏆椼€傚杞潯绾规部涓嬫父鏂瑰悜绉诲姩锛岄伩鍏嶅皬娌宠楂橀鍣０鍚炴帀銆?		// visual_quality=1 浣跨敤鍗曞眰鏉＄汗锛?=2 浣跨敤瀹屾暣鍙屽眰娴佺汗銆?		if (river_t > 0.001
				&& river_flow_enabled
				&& river_flow_speed > 0.001
				&& visual_quality >= 1) {
			vec2 texel = 1.0 / hm_resolution;
			float hl = decode_height_rg8(uv - vec2(texel.x, 0.0));
			float hr = decode_height_rg8(uv + vec2(texel.x, 0.0));
			float hu = decode_height_rg8(uv - vec2(0.0, texel.y));
			float hd = decode_height_rg8(uv + vec2(0.0, texel.y));
			vec2 grad = vec2(hr - hl, hd - hu);
			float slope_mag = length(grad);
			if (slope_mag > 0.002) {
				vec2 fbm_smooth = vec2(
					fbm(wp * 0.045, 1) - 0.5,
					fbm(wp * 0.045 + vec2(21.0, -13.0), 1) - 0.5
				) * 0.11;
				vec2 flow_dir = normalize(-grad + fbm_smooth);
				vec2 flow_perp = vec2(-flow_dir.y, flow_dir.x);
				float along = dot(wp, flow_dir) * river_flow_freq;
				float across = dot(wp, flow_perp) * river_flow_freq * 0.42;
				vec2 flow_uv = vec2(along + world_time * river_flow_speed * 0.42, across);
				int river_flow_oct = (visual_quality >= 2) ? 2 : 1;
				float flow_streak = fbm(flow_uv, river_flow_oct);
				vec3 flow_tint = river_body * mix(0.92, 1.09, flow_streak);
				col = mix(col, flow_tint, river_t * river_strength * 0.28);
			}
		}
	}

	// 6. 娴峰哺 / 婀栧哺 / 娌冲彛鏌斿拰杩囨浮
	// 鏃ч€昏緫鍙寜 abs(elev - sea_level) 鐢荤粏绾匡紝瀹规槗鍦ㄥ北鍦般€侀洩鍦版垨妫灄鏃佸舰鎴愮‖浜竟銆?	// 杩欓噷缁撳悎閭诲煙姘撮檰鎺ヨЕ銆佹捣鎷斿甫瀹藉拰娌虫祦娴侀噺锛岃宀哥嚎鎴愪负涓€鏉℃煍鍜屾祬鑹茶繃娓″甫銆?	// visual_quality=0 鍙噰鏍峰崄瀛?4 閭诲煙锛?=1 浣跨敤瀹屾暣 8 閭诲煙銆?	vec2 shore_texel = 1.0 / hm_resolution;
	float nearby_water_cnt = 0.0;
	float nearby_land_cnt = 0.0;
	float nearby_lake_cnt = 0.0;
	float nearby_ocean_cnt = 0.0;
	float shore_sample_cnt = 0.0;
	for (int sy = -1; sy <= 1; sy++) {
		for (int sx = -1; sx <= 1; sx++) {
			if (sx == 0 && sy == 0) {
				continue;
			}
			bool is_diag_shore_sample = (sx != 0) && (sy != 0);
			if (visual_quality <= 0 && is_diag_shore_sample) {
				continue;
			}
			vec2 suv = clamp(uv + vec2(float(sx), float(sy)) * shore_texel, vec2(0.0), vec2(1.0));
			int sb = int(texture(enum_atlas, suv).r * 255.0 + 0.5);
			bool sw = (sb == B_OCEAN) || (sb == B_COAST) || (sb == B_LAKE)
					|| (sb == B_REEF) || (sb == B_KELP) || (sb == B_SEA_ICE);
			nearby_water_cnt += sw ? 1.0 : 0.0;
			nearby_land_cnt += sw ? 0.0 : 1.0;
			nearby_lake_cnt += (sb == B_LAKE) ? 1.0 : 0.0;
			nearby_ocean_cnt += ((sb == B_OCEAN) || (sb == B_COAST) || (sb == B_REEF) || (sb == B_KELP)) ? 1.0 : 0.0;
			shore_sample_cnt += 1.0;
		}
	}
	float shore_inv = 1.0 / max(shore_sample_cnt, 1.0);
	float shore_contact = is_water ? (nearby_land_cnt * shore_inv) : (nearby_water_cnt * shore_inv);
	float shore_w = smoothstep(0.06, 0.42, shore_contact);
	float sea_band = 1.0 - smoothstep(0.0, is_water ? 0.065 : 0.040, abs(elev - sea_level));
	float lake_side_w = smoothstep(0.08, 0.42, nearby_lake_cnt * shore_inv);
	float ocean_side_w = smoothstep(0.08, 0.42, nearby_ocean_cnt * shore_inv);
	float estuary_flow = 0.0;
	if (!is_water) {
		estuary_flow = smoothstep(river_threshold_low * 0.90, river_threshold_high, scals.g) * ocean_side_w;
	}
	float coast_t = clamp(max(sea_band * 0.55, shore_w * 0.72) + estuary_flow * 0.30, 0.0, 1.0);
	vec3 ocean_halo = mix(coast_halo_color, color_beach * vec3(0.82, 0.92, 1.02), 0.36);
	vec3 lake_halo = mix(coast_halo_color * vec3(0.84, 1.05, 1.12), lake_water_color * vec3(1.06, 1.08, 1.03), 0.40);
	vec3 estuary_halo = mix(river_color, color_coast_water, 0.58) * vec3(0.96, 1.03, 1.06);
	vec3 shore_halo = mix(ocean_halo, lake_halo, lake_side_w * (1.0 - ocean_side_w * 0.45));
	shore_halo = mix(shore_halo, estuary_halo, estuary_flow * 0.55);
	float halo_strength = coast_halo_strength * mix(0.34, 0.62, shore_w) * (is_water ? 0.86 : 1.0);
	col = mix(col, shore_halo, coast_t * halo_strength);

	// 7. 鍙€夌瓑楂樼嚎锛堥檰鍦帮級
	if (contour_enabled && !is_water) {
		float contour_phase = fract(elev / max(contour_step, 0.001));
		float dist = abs(contour_phase - 0.5);
		float contour_t = smoothstep(0.50, 0.42, dist);
		col = mix(col, contour_color, contour_t * contour_strength);
	}

	// 7.5. Phase 1锛氬姩鎬侀洩鐩栵紙瀛ｈ妭鎬э級鈥?鏀惧湪 hillshade 涔嬪悗璁╅洩鏈韩甯﹂槾褰?	if (!is_water) {
		float snow_factor = compute_snow_factor(biome, current_temp, elev, is_water) * dynamic_snow_strength;
		// 闆湰韬交寰殢鍦板舰鍣０鎵撴暎锛堥伩鍏嶉摵婊℃鏉匡級
		// v9.fbm-opt锛氬崟 octave 鍣０宸茶冻澶熺粰闆潰鎵撴暎鎰燂紝2 oct 宸埆涓嶅彲瑙?		float snow_noise = fbm(wp * 0.18 + vec2(63.0, -29.0), 1);
		snow_factor *= mix(0.85, 1.10, snow_noise);
		snow_factor = clamp(snow_factor, 0.0, 1.0);
		vec3 snow_color = vec3(0.94, 0.95, 0.97);
		col = mix(col, snow_color, snow_factor);
	}

	// 7.55. 浠诲姟 6锛欱LIZZARD 绉洩澧炲己锛堝湪瀛ｈ妭闆洊涔嬪悗鍙犲姞锛屾毚椋庨洩鍖哄煙鏇寸櫧锛?	// 鏉冮噸鍙楀潯搴?+ 妞嶈璋冨埗锛氬钩鍦?浣庢琚珮鏉冮噸锛岄櫋鍧?妫灄鍐呴儴浣庢潈閲嶏紙闆Н涓嶄綇锛夈€?	if (extreme_weather_ground_effect_enabled
			&& !is_water
			&& weather_front_count > 0) {
		float blizz_mask = compute_extreme_weather_mask(wp, WT_BLIZZARD);
		if (blizz_mask > 0.001) {
			// 鍧″害鏉冮噸锛氶櫋鍧￠洩绉笉浣忥紙鍧″害澶?鈫?鏉冮噸浣庯級
			vec2 texel = 1.0 / hm_resolution;
			float hl = decode_height_rg8(uv - vec2(texel.x, 0.0));
			float hr = decode_height_rg8(uv + vec2(texel.x, 0.0));
			float hu = decode_height_rg8(uv - vec2(0.0, texel.y));
			float hd = decode_height_rg8(uv + vec2(0.0, texel.y));
			float slope_mag = length(vec2(hr - hl, hd - hu)) * hillshade_slope_gain;
			float slope_w = 1.0 - smoothstep(0.35, 0.85, slope_mag);  // 闄″潯 鈫?0.15锛屽钩鍦?鈫?1.0
			// 妞嶈鏉冮噸锛氬瘑鏋楋紙TAIGA/DECIDUOUS/CONIFER/RAINFOREST锛夊唴閮ㄦ爲鍐犻伄闆?鈫?鏉冮噸鍘嬪埌 0.35
			float veg_w = 1.0;
			if (veg == V_TAIGA
					|| veg == V_TEMPERATE_DECIDUOUS
					|| veg == V_TEMPERATE_CONIFER
					|| veg == V_TROPICAL_RAINFOREST
					|| veg == V_SUBTROPICAL_FOREST) {
				veg_w = 0.35;
			} else if (veg == V_BOREAL_SHRUB
					|| veg == V_MEDITERRANEAN_SHRUB
					|| veg == V_TROPICAL_DRY_FOREST) {
				veg_w = 0.65;
			}
			float w = blizz_mask * slope_w * veg_w;
			vec3 fresh_snow = vec3(0.97, 0.98, 1.00);
			col = mix(col, fresh_snow, clamp(w, 0.0, 0.92));
		}
	}

	// 7.6. Milestone 2锛氳鐩栫墿杞村彔鍔狅紙FLOODING / PERMAFROST / GLACIER锛?	// SNOW / SEA_ICE 宸茶 dynamic_snow / biome 涓昏矾寰勫鐞嗭紝鍑芥暟鍐呰繑鍥?0 璺宠繃銆?	if (cover_axis_strength > 0.001) {
		vec4 ov = cover_overlay(cover);
		if (ov.a > 0.001) {
			// FLOODING 浠呭湪闄嗗湴涓婃湁鎰忎箟锛汸ERMAFROST / GLACIER 鍚岀悊
			if (!is_water) {
				col = mix(col, ov.rgb, ov.a * cover_axis_strength);
			}
		}
	}

	// 7.65. Milestone 3 (split)锛氬湴褰?shader 鍙鐞?DROUGHT/HEATWAVE 鐨?multiplicative 璋冭壊
	// 鍏朵粬 weather 绫诲瀷锛圧AIN/STORM/FOG/BLIZZARD/MONSOON锛夌敱 WeatherLayer 鐙珛娓叉煋銆?	if (weather_front_count > 0 && weather_strength > 0.001) {
		vec4 wov = sample_terrain_weather_tint(wp);
		float wa = wov.a;
		if (wa > 0.001) {
			col = mix(col, col * wov.rgb, clamp(wa, 0.0, 0.85));
			// HEATWAVE 鍔犵儹姘旀壄鏇诧紙鐢?wov.rgb.g > 0.95 鍖哄垎 HEATWAVE 涓?DROUGHT锛?			// v9.fbm-opt锛氭壄鏇叉尟骞呮湰鏉?卤0.05锛屽崟 octave 瀹屽叏澶熺敤
			if (wov.rgb.g > 0.95) {
				float heat = fbm(wp * 0.30 + vec2(0.0, world_time * 1.2), 1);
				col *= 1.0 + (heat - 0.5) * 0.10 * wa;
			}
		}
	}

	// 7.66. 浠诲姟 6锛欴ROUGHT 瑁傚湴鍙犲姞锛堝湪 multiplicative 璋冭壊涔嬪悗鍋氱汗鐞嗗彔鍔狅級
	// 涓庡鑺傛€?DROUGHT 璋冭壊浜掕ˉ锛氳皟鑹茶鏁村潡鍦板彉鏋粍锛岃繖閲屽啀鍙?	// 涓€灞?voronoi 杈圭紭寰楀埌"榫熻"缃戞牸锛岃骞叉棻琛ㄧ幇浠?鑹插潡"鍗囩骇涓?璐ㄦ劅"銆?	if (extreme_weather_ground_effect_enabled
			&& !is_water
			&& weather_front_count > 0) {
		float drought_mask = compute_extreme_weather_mask(wp, WT_DROUGHT);
		if (drought_mask > 0.001) {
			// voronoi 杈圭紭锛歝ell 涓績璺濈 鈫?缃戞牸绾匡紙瓒婃帴杩?cell 杈圭晫鍊艰秺灏忥級
			float crack = voronoi_cell(wp * 0.42);
			float crack_factor = smoothstep(0.0, 0.12, crack);  // 杈圭晫澶?= 0锛堟繁鑹茶缂濓級
			// 瑁傜紳鑹诧細娣辨鍋忕孩锛堢劍鍦熸劅锛?			vec3 crack_color = vec3(0.38, 0.28, 0.20);
			col = mix(col, crack_color, drought_mask * (1.0 - crack_factor) * 0.55);
			// 鍙犲姞涓€灞備綆棰戝湡榛?tint锛屽寮?瑁傚湴搴曡壊"
			vec3 dry_earth = vec3(0.80, 0.70, 0.48);
			col = mix(col, col * dry_earth, drought_mask * 0.30);
		}
	}

	// 7.7. Phase 14锛氱伀灞辩孩鍏?+ 鐑熸煴锛堝湪 paper grain 涔嬪墠鍙犲姞锛屽厤琚緤鐨焊鍘嬫殫锛?	// vol_intensity 宸插湪 fragment 椤堕儴浠?scalar_atlas.a 瑙ｅ嚭
	float vol_intensity = vol_intensity_atlas;
	if (vol_intensity > 0.01) {
		// 绾㈠厜鏅曪細闈犺繎鐏北涓績 鈫?鏆栨绾?		vec3 lava_color = vec3(1.10, 0.45, 0.20);
		col = mix(col, col * lava_color, vol_intensity * 0.55);
		// 涓績楂樺厜锛歷ol_intensity > 0.7 = 鐏北鍙ｆ湰浣擄紝鍔犱寒榛?		float core = smoothstep(0.55, 0.95, vol_intensity);
		col = mix(col, vec3(1.0, 0.78, 0.30), core * 0.55);
		// 鐑熸煴锛氬瀭鐩存柟鍚戦珮棰?fbm锛屽悜涓婇鍔紙鐢?world_time 鎺ㄨ繘锛?		// 鐑熸煴 anchor 鍦ㄧ伀灞变腑蹇冿紱鐢?vol_intensity 褰?mask
		float plume_mask = smoothstep(0.10, 0.55, vol_intensity);
		float plume_y = wp.y + world_time * 6.0;
		float plume = fbm(vec2(wp.x * 0.40, plume_y * 0.18), 3);
		float plume_factor = smoothstep(0.55, 0.85, plume) * plume_mask;
		col = mix(col, vec3(0.55, 0.50, 0.48), plume_factor * 0.65);
	}

	// 8. 缇婄毊绾?+ paper grain
	col = mix(col, col * parchment_tint, parchment_strength);
	// v9.fbm-opt锛歱aper_grain_strength 閫氬父 < 0.10锛屽崟 octave 宸茶冻澶燂紝鑲夌溂涓嶅彲鍒嗚鲸
	float grain = fbm(wp * 0.45 + vec2(91.0, -7.0), 1);
	col *= mix(1.0 - paper_grain_strength, 1.0 + paper_grain_strength, grain);

	// 9. 浠诲姟 3锛氶鏍煎寲 PBR 鏄煎鐫€鑹诧紙鍦ㄧ緤鐨焊涔嬪悗锛屼繚璇?tint 涓嶈缇婄毊绾告姽鎺夛級
	// day_night_enabled=false 鏃跺畬鍏ㄧ煭璺紝鍥為€€鍒板師鏈夌潃鑹茶矾寰勶紙闇€姹?6.2锛夈€?	if (day_night_enabled) {
		// Pass 2锛堜换鍔?3锛夛細闄嗗湴璧?TOD 椹卞姩鐨?PBR锛圫obel 娉曠嚎 + NdotL + NdotH + tonemap锛夈€?		// 姘翠綋浠嶄繚鐣欐棫 apply_day_night 鐨勫ぉ鑹?tint锛岀布鍏夌敱姘翠綋鍒嗘敮鑷澶勭悊锛堜换鍔?4锛夈€?		if (is_water) {
			// 姘撮潰鍙渶瑕佷竴涓煍鍜岀殑鐜/鏃ュ厜 tint锛岄伩鍏嶄笌绮煎厜鍙犲姞杩囦寒
			col = col * (tod_ambient_color * 0.6 + tod_sun_color * 0.4);
			col *= mix(1.0, 0.55, tod_night_factor);
			col *= tod_exposure;
		} else {
			col = apply_tod_pbr(col, uv, biome, visual_quality);
		}
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
