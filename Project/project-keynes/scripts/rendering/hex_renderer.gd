# hex_renderer.gd v5
# 鍗曚竴鍏ㄥ睆 quad mesh + WorldData 鐨?4 寮犻珮鍒嗚鲸鐜囩汗鐞?+ world_map.gdshader v5銆?# 鎵€鏈夎瑙夌敱 heightmap/biome/moisture/flow 鍍忕礌绾у悎鎴愶紝娌℃湁 hex 閫昏緫銆?
class_name HexRenderer
extends Node2D

@export var hex_size: float = 22.0:
	set(v):
		hex_size = maxf(4.0, v)
		if is_inside_tree():
			_rebuild()

@export var shader_path: String = "res://shaders/world_map.gdshader"

# 鈹€鈹€鈹€ Hypsometric 鑹查樁锛堟捣闄嗗弻鍚戯紝浠庢繁鍒版祬锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Hypsometric Colors")
@export var color_deep_ocean: Color = Color(0.055, 0.13, 0.30)
@export var color_mid_ocean: Color = Color(0.11, 0.24, 0.42)
@export var color_shallow: Color = Color(0.22, 0.42, 0.56)
@export var color_coast_water: Color = Color(0.36, 0.62, 0.68)
@export var color_beach: Color = Color(0.85, 0.78, 0.55)
@export var color_lowland: Color = Color(0.62, 0.68, 0.42)
@export var color_hill: Color = Color(0.66, 0.55, 0.32)
@export var color_mountain: Color = Color(0.50, 0.42, 0.38)
@export var color_peak: Color = Color(0.65, 0.62, 0.60)
@export var color_snow: Color = Color(0.96, 0.96, 0.96)

# 鈹€鈹€鈹€ 鍙屽厜婧?hillshading 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Hillshading")
@export_range(0.0, 1.0, 0.01) var hillshade_strength: float = 0.45
@export_range(0.5, 24.0, 0.5) var hillshade_slope_gain: float = 8.0

# 鈹€鈹€鈹€ 娌虫祦 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# v6锛歠low_tex 鏄?SDF 鍙嶈窛绂荤紪鐮侊紙1=娌充腑蹇冿紝0=>=SDF_MAX_DIST_PX 杩滐級銆?# baker 鐨?SDF_MAX_DIST_PX = 8 鍍忕礌 鈮?0.4 hex_size銆?# threshold_low=澶栧湀 outline 璧风偣锛宼hreshold_high=鍐呭湀涓昏壊瀹屽叏銆?@export_group("Rivers")
@export_range(0.0, 1.0, 0.01) var river_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var river_threshold_low: float = 0.55
@export_range(0.0, 1.0, 0.01) var river_threshold_high: float = 0.85
@export var river_color: Color = Color(0.30, 0.50, 0.68)
@export var river_outline_color: Color = Color(0.16, 0.30, 0.45)

# 鈹€鈹€鈹€ 鍙€夌瓑楂樼嚎 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Contour Lines")
@export var contour_enabled: bool = false
@export_range(0.01, 0.20, 0.005) var contour_step: float = 0.05
@export_range(0.0, 0.40, 0.01) var contour_strength: float = 0.18
@export var contour_color: Color = Color(0.20, 0.16, 0.10)

# 鈹€鈹€鈹€ 娴峰哺鍏夋檿 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Coast Halo")
@export var coast_halo_color: Color = Color(0.78, 0.86, 0.88)
@export_range(0.0, 1.0, 0.01) var coast_halo_strength: float = 0.22

# 鈹€鈹€鈹€ 缇婄毊绾?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Atlas Paper")
@export var parchment_tint: Color = Color(0.96, 0.88, 0.74)
@export_range(0.0, 0.4, 0.01) var parchment_strength: float = 0.10
@export_range(0.0, 0.2, 0.01) var paper_grain_strength: float = 0.05

# 鈹€鈹€鈹€ 瀛ｈ妭 / 姘斿€欑郴缁燂紙姣忓抚鐢?main.gd 閫氳繃 set_*_phase 鎺ㄨ繘锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Climate")
@export_range(0.0, 0.4, 0.01) var season_temp_amp: float = 0.20
@export_range(0.0, 1.0, 0.01) var vegetation_season_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var dynamic_snow_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var ocean_current_strength: float = 0.88
@export_range(0.0, 0.20, 0.01) var wind_streak_strength: float = 0.05

# 鈹€鈹€鈹€ Milestone 2锛氭琚?/ 瑕嗙洊鐗╁弻閫氶亾锛堜笌 biome_tex 鍚屽垎杈ㄧ巼锛孨EAREST 閲囨牱锛?鈹€鈹€
# vegetation_axis_strength锛欻ILL/MOUNTAIN/PLAIN 绛?涓昏壊鍗曚竴"鐨勫湴褰笂锛屾寜鐪熷疄
# 妞嶈 id 缁?col 鍋氳交搴﹁壊鐩歌皟鍒躲€? 鍏抽棴銆?.0 瀹屽叏鏇挎崲鎴愭琚?tint 脳 鍘熻壊銆?# cover_axis_strength锛欶LOODING/PERMAFROST/GLACIER 绛夎鐩栫墿鍦?fragment 鏈熬鐨?# 鍙犲姞寮哄害锛圫NOW 浠嶈蛋鍘?dynamic_snow 璺緞锛岄伩鍏嶄笌 snow_factor 鍙屽彔锛夈€?@export_group("Axes (Milestone 2)")
@export_range(0.0, 1.0, 0.01) var vegetation_axis_strength: float = 0.35
@export_range(0.0, 1.0, 0.01) var cover_axis_strength: float = 0.65

# 鈹€鈹€鈹€ Milestone 3锛氬ぉ姘?overlay 鎬诲己搴︼紙0 鍏抽棴锛? 鍏ㄥ姏锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Weather (Milestone 3)")
@export_range(0.0, 1.0, 0.01) var weather_strength: float = 1.0

# 鈹€鈹€鈹€ Visual Overhaul锛堜换鍔?1锛夛細瑙嗚鎬诲紑鍏?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 杩欑粍鍙橀噺鐢?main.gd 閫氳繃 set_*() 鎺ㄨ繘锛泂hader 鍒嗘敮閫愭鍦ㄤ换鍔?3~9 涓帴鍏ャ€?# 榛樿鍊间笌 main.gd 涓€鑷达紝淇濊瘉 renderer 琚崟鐙皟璇曟椂涔熸湁鍚堢悊鍒濆€笺€?@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 2
@export var day_night_enabled: bool = true
@export var water_effect_enabled: bool = true
@export var ocean_current_enabled: bool = true
@export var extreme_weather_ground_effect_enabled: bool = true
@export var perf_sampler_enabled: bool = false

# 鈹€鈹€鈹€ Visual Pass 2锛歍OD 娑堣垂绔紑鍏?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 杩欎笁涓紑鍏崇敱 main.gd 鐨勫悓鍚?@export 鎺ㄨ繘锛屽埌杈?shader 鍐呭悓鍚?uniform銆?# water_sparkle_enabled锛氭按闈㈤珮棰戠布鍏夛紙浠诲姟 4锛?# rain_density_boost_enabled锛氱矑瀛愭暟閲忔彁鍗囷紙浠诲姟 5锛宺enderer 浠呰浆鍙戝埌 WeatherLayer锛?# cloud_tod_tint_enabled锛氫簯灞?TOD 鏌撹壊锛堜换鍔?6锛?@export_group("Pass 2")
@export var water_sparkle_enabled: bool = true
@export var rain_density_boost_enabled: bool = true
@export var cloud_tod_tint_enabled: bool = true

# 鈹€鈹€鈹€ Water Visual Overhaul锛堟湰杞級锛氭按浣撶粏鍒嗗紑鍏充笌鍙傛暟 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 鎵€鏈夊瓧娈电洿閫?shader 鍚屽悕 uniform锛涘叧闂嵆鍥為€€鍒颁笂涓€杞紙pass2锛夎〃鐜帮紝
# 鎬诲紑鍏?water_effect_enabled=false 鏃舵暣缁勫瓙鐗规€ц shader 绔煭璺€?@export_group("Water Overhaul")
@export var water_waves_enabled: bool = true
@export var water_fresnel_enabled: bool = true
@export var river_flow_enabled: bool = true
@export var caustics_enabled: bool = true
@export var shallow_transparency_enabled: bool = true
@export_range(4.0, 128.0, 0.5) var water_gloss: float = 34.0
@export_range(0.0, 1.0, 0.01) var water_reflection_strength: float = 0.32
@export_range(0.0, 4.0, 0.05) var river_flow_speed: float = 0.75
@export_range(0.02, 1.0, 0.01) var river_flow_freq: float = 0.16
@export_range(0.0, 1.0, 0.01) var caustics_strength: float = 0.32
@export_range(0.5, 3.0, 0.05) var deep_ocean_contrast: float = 0.96
@export var lake_water_color: Color = Color(0.20, 0.48, 0.56)
@export_range(0.0, 1.0, 0.01) var shallow_transparency_factor: float = 0.56
# ShaderToy 鍚彂鐨勮瑙夊寮猴紙杞竟杩囨浮 + 鏌斿拰鍣０灞傦級
# 璇存槑锛歚water_wave_line_strength` 鍦?Water Calm Noise 鏀归€犲悗璇箟鍙樹负
#       "鏌斿拰鍣０鎬诲紑鍏?寮哄害"锛? = 鍏筹紝1 = 榛樿鏌斿拰灞傦級銆傞粯璁ゅ€煎埢鎰忎綆浜?1锛?#       閬垮厤姘撮潰閲嶆柊鍑虹幇瀵嗛泦鏉＄汗鎴栭珮瀵规瘮鍣０銆?#       瀛楁鍚嶄繚鐣欐槸涓轰簡鍏煎鏃?.tscn 搴忓垪鍖栥€?@export_range(0.0, 4.0, 0.05) var water_domain_warp_strength: float = 1.45
@export_range(0.0, 1.0, 0.01) var water_wave_line_strength: float = 0.70
# 鏌斿拰鍣０鐨勪袱涓嫭绔嬬粏鍒嗗己搴︼細
#   brightness   鈫?澶у昂搴?fbm 浜害鎵板姩灞傦紙榛樿绾?卤5%锛?#   tint_strength 鈫?浣庡姣斿害鑹茬浉 fbm 灞傦紙鍐?鏆?tint mix锛岄粯璁ょ害 卤2%锛?@export_range(0.0, 1.0, 0.01) var water_calm_noise_brightness: float = 0.70
@export_range(0.0, 1.0, 0.01) var water_calm_noise_tint_strength: float = 0.70
@export_range(0.0, 4.0, 0.05) var water_biome_blend_radius: float = 3.15
@export_range(0.0, 1.0, 0.01) var water_cartoon_color_strength: float = 0.75
@export_range(0.0, 1.0, 0.01) var water_transition_softness: float = 1.0
@export_range(0.0, 1.0, 0.01) var estuary_plume_strength: float = 0.65

# 鈹€鈹€鈹€ 鍏煎瀛楁锛堟棫 .tscn 鍐欒繃杩欎簺鍊硷紝淇濈暀鎺ユ敹浠ラ伩鍏嶅弽搴忓垪鍖栬鍛婏級 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
@export_group("Legacy (Unused)")
@export var hex_overscan: float = 1.45
@export var draw_rivers: bool = true
@export var domain_warp_amp: float = 0.0
@export var domain_warp_freq: float = 0.0
@export var warp_high_freq_mul: float = 0.0
@export var warp_high_freq_amp_ratio: float = 0.0
@export var boundary_blend_start: float = 0.0
@export var boundary_blend_end: float = 0.0
@export var boundary_blend_max: float = 0.0
@export var river_width_factor: float = 0.0
@export var coast_halo_outer_px: float = 0.0
@export var coast_halo_inner_px: float = 0.0
@export var beach_band_px: float = 0.0
@export var coast_dash_freq: float = 0.0
@export var coast_dash_strength: float = 0.0
@export var beach_color: Color = Color(0.86, 0.78, 0.52)
@export var coast_foam_color: Color = Color(0.78, 0.86, 0.88)
@export var coast_foam_outer_px: float = 0.0
@export var sdf_resolution: Vector2i = Vector2i(0, 0)
@export var global_darken: float = 0.0

var _world_quad: MeshInstance2D
var _shader_mat: ShaderMaterial
var _weather_layer: WeatherLayer = null  # v9.split锛氬ぉ姘旂嫭绔嬪眰
var _map: MapData = null
var _world: WorldData = null

# Phase 1锛氬鑺傜姸鎬侊紙姣忓抚/姣忓ぉ鐢?WorldClock 鎺ㄩ€侊級
var _season_phase: float = 1.0   # 0=spring 1=summer 2=autumn 3=winter
var _climate_anomaly: float = 0.0
# Phase 3锛氭磱娴佹祦绾瑰姩鐢荤疮绉椂闂?var _world_time: float = 0.0
# 浠诲姟 2锛氭樇澶滅浉浣?鈭?[0,1)锛岀敱 WorldClock 鑺傛祦鎺ㄩ€併€?# 0.0=鏃ュ嚭, 0.25=姝ｅ崍, 0.5=鏃ヨ惤, 0.75=鍗堝銆?var _day_phase: float = 0.25   # 鍒濆鍖栨鍗堬紝淇濊瘉鏂板湴鍥鹃粯璁ょ櫧澶╂晥鏋?
# Milestone 3锛氬ぉ姘斿瓙绯荤粺鏁扮粍涓婁紶
# 涓?shader 绔?weather_front_centers[MAX_WEATHER_FRONTS] 闀垮害涓ユ牸涓€鑷达紱
# 0 fronts 鏃朵粛濉弧 16 涓?zero-vec锛岄伩鍏?shader 绔秺鐣岄噰鏍枫€?const MAX_WEATHER_FRONTS := 16

# 鈹€鈹€鈹€ 浠诲姟 1锛氭€ц兘閲囨牱鍣紙30 绉掔獥鍙ｅ唴 avg + P95锛?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 缁熻绐楀彛閫氳繃 ring buffer锛屼笉鍒嗛厤锛涙瘡 REPORT_INTERVAL_SEC 鎵撳嵃涓€娆＄粨鏋溿€?# 榛樿鍏抽棴锛屽彧鏈?perf_sampler_enabled == true 鏃舵墠缁熻涓庢墦鍗般€?class PerfSampler:
	const REPORT_INTERVAL_SEC: float = 30.0
	const MAX_SAMPLES: int = 1800  # 30s 脳 60fps
	var _samples: PackedFloat32Array
	var _write_idx: int = 0
	var _count: int = 0
	var _elapsed: float = 0.0
	var _label: String = "PerfSampler"

	func _init() -> void:
		_samples = PackedFloat32Array()
		_samples.resize(MAX_SAMPLES)

	func set_label(l: String) -> void:
		_label = l

	func push_frame_ms(frame_ms: float) -> void:
		_samples[_write_idx] = frame_ms
		_write_idx = (_write_idx + 1) % MAX_SAMPLES
		if _count < MAX_SAMPLES:
			_count += 1
		_elapsed += frame_ms / 1000.0
		if _elapsed >= REPORT_INTERVAL_SEC:
			_report()
			_elapsed = 0.0

	func reset() -> void:
		_write_idx = 0
		_count = 0
		_elapsed = 0.0

	func _report() -> void:
		if _count <= 0:
			return
		var sorted := PackedFloat32Array()
		sorted.resize(_count)
		for i in range(_count):
			sorted[i] = _samples[i]
		var arr := Array(sorted)
		arr.sort()
		var total: float = 0.0
		for v in arr:
			total += float(v)
		var avg: float = total / float(_count)
		var p95_idx: int = clampi(int(float(_count) * 0.95), 0, _count - 1)
		var p95: float = float(arr[p95_idx])
		var avg_fps: float = 1000.0 / maxf(avg, 0.001)
		print_rich(
			"[color=cyan][%s][/color] 30s samples=%d  avg=%.2fms (%.1f FPS)  P95=%.2fms" %
			[_label, _count, avg, avg_fps, p95]
		)

var _perf_sampler: PerfSampler = null

func _ready() -> void:
	_world_quad = MeshInstance2D.new()
	_world_quad.name = "WorldQuad"
	_world_quad.z_index = 0
	add_child(_world_quad)
	# v9.split锛氬ぉ姘旇〃鐜板眰
	_weather_layer = WeatherLayer.new()
	_weather_layer.name = "WeatherLayer"
	add_child(_weather_layer)
	_load_shader()
	if _map != null and _world != null:
		_rebuild()
	set_process(true)

# 姣忓抚鎶?world_time 鎺ㄨ繘缁?shader锛堥┍鍔ㄦ磱娴佹祦绾癸級
# 娉ㄦ剰锛氳繖閲屽彧 push 涓€涓?float uniform锛屽嚑涔庨浂寮€閿€
func _process(delta: float) -> void:
	if _shader_mat == null:
		return
	_world_time += delta
	_shader_mat.set_shader_parameter("world_time", _world_time)
	# 浠诲姟 1锛氭€ц兘閲囨牱锛堜粎褰?perf_sampler_enabled 涓?true 鏃跺惎鐢級
	if _perf_sampler != null:
		_perf_sampler.push_frame_ms(delta * 1000.0)

func _load_shader() -> void:
	var shader := ResourceLoader.load(shader_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("HexRenderer: shader not found at %s" % shader_path)
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = shader
	_world_quad.material = _shader_mat

# 鈹€鈹€鈹€ 瀵瑰鎺ュ彛 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

func set_map(map: MapData, world: WorldData = null) -> void:
	_map = map
	_world = world
	if is_inside_tree():
		_rebuild()

func get_world_bounds() -> Rect2:
	if _world != null:
		return _world.world_bounds
	if _map != null and _map.cell_count() > 0:
		return MapBaker.compute_world_bounds(_map.width, _map.height, hex_size)
	return Rect2()

# Phase 1锛氳 main.gd 鍦?WorldClock day_changed 鏃舵帹杩?shader 瀛ｈ妭鐩镐綅
func set_season_phase(phase: float) -> void:
	_season_phase = phase
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("season_phase", _season_phase)

func set_climate_anomaly(v: float) -> void:
	_climate_anomaly = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("climate_anomaly", _climate_anomaly)

# 浠诲姟 2锛氭樇澶滅浉浣嶃€傜敱 main.gd 鎺ユ敹 WorldClock.day_phase_changed 淇″彿鍚庤浆鍙戙€?# 鍚屾椂鍐欏叆鍦板舰 shader 涓?weather overlay shader锛堜袱鑰呴兘闇€瑕佹樇澶滅浉浣嶃€備絾鍚庤€?# 浠呯敤浜庤皟鏁翠簯鑹?闂數浜害锛屽湪浠诲姟 4 涓帴鍏ワ級銆?func set_day_phase(v: float) -> void:
	_day_phase = fposmod(v, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_phase", _day_phase)
	if _weather_layer != null:
		_weather_layer.set_day_phase(_day_phase)

# 鈹€鈹€鈹€ 浠诲姟 1锛氳瑙夋€诲紑鍏?setter 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 鍏ㄩ儴 setter 鍏卞悓绾﹀畾锛?#   1) 鎶?@export 瀛楁鏈韩鏀规帀锛屼究浜?Editor 鐩戣锛?#   2) 鎶婂搴?uniform 鎺ㄥ埌 shader锛堝悕瀛椾笌鍚庣画浠诲姟 shader 鍒嗘敮鍖归厤锛夛紱
#   3) 鎶婂紑鍏冲悓姝ョ粰 WeatherLayer锛堝鏋滆寮€鍏冲奖鍝嶅ぉ姘斿眰锛夈€?func set_visual_quality(q: int) -> void:
	visual_quality = clampi(q, 0, 2)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("visual_quality", visual_quality)
	if _weather_layer != null:
		_weather_layer.set_visual_quality(visual_quality)

func set_day_night_enabled(v: bool) -> void:
	day_night_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_night_enabled", day_night_enabled)
	if _weather_layer != null:
		_weather_layer.set_day_night_enabled(day_night_enabled)

func set_water_effect_enabled(v: bool) -> void:
	water_effect_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_effect_enabled", water_effect_enabled)

func set_ocean_current_enabled(v: bool) -> void:
	ocean_current_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ocean_current_enabled", ocean_current_enabled)

# 浠诲姟 9锛歰cean_current_debug toggle 鈥斺€?F6 蹇嵎閿?/ UI 椤舵爮鎸夐挳鍧囧啓杩欓噷銆?# debug=true 鏃?shader 姘村垎鏀妸娴佺嚎鎸箙鎷夊ぇ 2.5脳 骞跺彔鍔犳柟鍚戞彁绀鸿壊锛?# debug=false 鍥炲埌姝ｅ父浣庡姣旀祦绾匡紝瑙嗚涓婁笌闈?debug 妯″紡鏃犲樊寮傘€?var _ocean_current_debug: bool = false

func set_ocean_current_debug(v: bool) -> void:
	_ocean_current_debug = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ocean_current_debug", _ocean_current_debug)

func get_ocean_current_debug() -> bool:
	return _ocean_current_debug

func set_extreme_weather_ground_effect_enabled(v: bool) -> void:
	extreme_weather_ground_effect_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"extreme_weather_ground_effect_enabled",
			extreme_weather_ground_effect_enabled
		)
	if _weather_layer != null:
		_weather_layer.set_extreme_weather_ground_effect_enabled(
			extreme_weather_ground_effect_enabled
		)

func set_perf_sampler_enabled(v: bool) -> void:
	perf_sampler_enabled = v
	if perf_sampler_enabled:
		if _perf_sampler == null:
			_perf_sampler = PerfSampler.new()
			_perf_sampler.set_label("HexRenderer")
		else:
			_perf_sampler.reset()
	else:
		_perf_sampler = null

# 鈹€鈹€鈹€ Pass 2锛堜换鍔?2锛夛細apply_tod + 鏂板寮€鍏?setter 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# apply_tod 鏄€淭OD 鍗曚竴鏉ユ簮鈥濈殑蹇呯粡涔嬭矾锛氭妸 TODProfile 鐨?6 涓瓧娈靛啓鍒?# 鍦拌〃 shader 涓?WeatherLayer 鐨?overlay shader銆傞甯у繀椤绘樉寮忚皟鐢ㄤ互閬垮厤
# shader 璇诲埌闆跺€硷紙闇€姹?1.3 / 7.4锛夈€?func apply_tod(profile: TODProfile) -> void:
	if profile == null:
		return
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_sun_dir", profile.sun_dir)
		_shader_mat.set_shader_parameter(
			"tod_sun_color",
			Vector3(profile.sun_color.r, profile.sun_color.g, profile.sun_color.b)
		)
		_shader_mat.set_shader_parameter(
			"tod_ambient_color",
			Vector3(profile.ambient_color.r, profile.ambient_color.g, profile.ambient_color.b)
		)
		_shader_mat.set_shader_parameter("tod_night_factor", profile.night_factor)
		_shader_mat.set_shader_parameter("tod_exposure", profile.exposure)
	if _weather_layer != null and _weather_layer.has_method("apply_tod"):
		_weather_layer.apply_tod(profile)

# Pass 2锛氭按闈㈤珮棰戠布鍏夊紑鍏筹紙浠诲姟 4锛?func set_water_sparkle_enabled(v: bool) -> void:
	water_sparkle_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_sparkle_enabled", water_sparkle_enabled)

# Pass 2锛氶洦闆矑瀛愬瘑搴︽彁鍗囧紑鍏筹紙浠诲姟 5锛夛紝浠?WeatherLayer 闇€瑕?func set_rain_density_boost_enabled(v: bool) -> void:
	if _weather_layer != null and _weather_layer.has_method("set_rain_density_boost_enabled"):
		_weather_layer.set_rain_density_boost_enabled(v)

# Pass 2锛氫簯灞?TOD 鏌撹壊寮€鍏筹紙浠诲姟 6锛?func set_cloud_tod_tint_enabled(v: bool) -> void:
	cloud_tod_tint_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("cloud_tod_tint_enabled", cloud_tod_tint_enabled)
	if _weather_layer != null and _weather_layer.has_method("set_cloud_tod_tint_enabled"):
		_weather_layer.set_cloud_tod_tint_enabled(v)

# 鈹€鈹€鈹€ Water Visual Overhaul锛氬瓙鐗规€?setter 缁?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 姣忎釜 setter 鍙仛"瀛楁鍐欏洖 + shader uniform 鍚屾"锛岃 main.gd 鑳介€愪釜鍒囨崲銆?func set_water_waves_enabled(v: bool) -> void:
	water_waves_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_waves_enabled", water_waves_enabled)

func set_water_fresnel_enabled(v: bool) -> void:
	water_fresnel_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_fresnel_enabled", water_fresnel_enabled)

func set_river_flow_enabled(v: bool) -> void:
	river_flow_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("river_flow_enabled", river_flow_enabled)

func set_caustics_enabled(v: bool) -> void:
	caustics_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("caustics_enabled", caustics_enabled)

func set_shallow_transparency_enabled(v: bool) -> void:
	shallow_transparency_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"shallow_transparency_enabled",
			shallow_transparency_enabled
		)

func set_water_gloss(v: float) -> void:
	water_gloss = clampf(v, 4.0, 128.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_gloss", water_gloss)

func set_water_reflection_strength(v: float) -> void:
	water_reflection_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_reflection_strength",
			water_reflection_strength
		)

func set_river_flow_speed(v: float) -> void:
	river_flow_speed = clampf(v, 0.0, 4.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("river_flow_speed", river_flow_speed)

func set_river_flow_freq(v: float) -> void:
	river_flow_freq = clampf(v, 0.02, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("river_flow_freq", river_flow_freq)

func set_caustics_strength(v: float) -> void:
	caustics_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("caustics_strength", caustics_strength)

func set_deep_ocean_contrast(v: float) -> void:
	deep_ocean_contrast = clampf(v, 0.5, 3.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("deep_ocean_contrast", deep_ocean_contrast)

func set_lake_water_color(c: Color) -> void:
	lake_water_color = c
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("lake_water_color", lake_water_color)

func set_shallow_transparency_factor(v: float) -> void:
	shallow_transparency_factor = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"shallow_transparency_factor",
			shallow_transparency_factor
		)

# ShaderToy 鍚彂锛氫笁涓柊瑙嗚 setter锛堝煙鎵洸 / 椋庢牸鍖栨尝鐥?/ biome 杞贩鍚堬級
func set_water_domain_warp_strength(v: float) -> void:
	water_domain_warp_strength = clampf(v, 0.0, 4.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_domain_warp_strength",
			water_domain_warp_strength
		)

func set_water_wave_line_strength(v: float) -> void:
	water_wave_line_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_wave_line_strength",
			water_wave_line_strength
		)

func set_water_calm_noise_brightness(v: float) -> void:
	water_calm_noise_brightness = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_calm_noise_brightness",
			water_calm_noise_brightness
		)

func set_water_calm_noise_tint_strength(v: float) -> void:
	water_calm_noise_tint_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_calm_noise_tint_strength",
			water_calm_noise_tint_strength
		)

func set_water_biome_blend_radius(v: float) -> void:
	water_biome_blend_radius = clampf(v, 0.0, 4.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_biome_blend_radius",
			water_biome_blend_radius
		)

func set_water_cartoon_color_strength(v: float) -> void:
	water_cartoon_color_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_cartoon_color_strength",
			water_cartoon_color_strength
		)

func set_water_transition_softness(v: float) -> void:
	water_transition_softness = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_transition_softness",
			water_transition_softness
		)

func set_estuary_plume_strength(v: float) -> void:
	estuary_plume_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"estuary_plume_strength",
			estuary_plume_strength
		)

# Upload active weather fronts to both the terrain shader and the weather layer.
func set_weather_fronts(fronts: Array) -> void:
	if _shader_mat != null:
		var centers := PackedVector4Array()
		var shapes := PackedVector4Array()
		var visuals := PackedVector4Array()
		var types := PackedFloat32Array()
		centers.resize(MAX_WEATHER_FRONTS)
		shapes.resize(MAX_WEATHER_FRONTS)
		visuals.resize(MAX_WEATHER_FRONTS)
		types.resize(MAX_WEATHER_FRONTS)
		var n: int = mini(fronts.size(), MAX_WEATHER_FRONTS)
		for i in range(MAX_WEATHER_FRONTS):
			if i < n:
				var f = fronts[i]
				centers[i] = Vector4(f.center.x, f.center.y, f.radius, f.intensity)
				var ax: Vector2 = f.normalized_axis()
				shapes[i] = Vector4(ax.x, ax.y, f.major_scale, f.minor_scale)
				visuals[i] = Vector4(f.cloud_amount, f.precip_amount, f.dissolve_amount, f.life_progress)
				types[i] = float(f.type)
			else:
				centers[i] = Vector4.ZERO
				shapes[i] = Vector4(1.0, 0.0, 1.0, 1.0)
				visuals[i] = Vector4.ZERO
				types[i] = -1.0
		_shader_mat.set_shader_parameter("weather_front_centers", centers)
		_shader_mat.set_shader_parameter("weather_front_shapes", shapes)
		_shader_mat.set_shader_parameter("weather_front_visuals", visuals)
		_shader_mat.set_shader_parameter("weather_front_types", types)
		_shader_mat.set_shader_parameter("weather_front_count", n)
	if _weather_layer != null:
		_weather_layer.set_weather_fronts(fronts)

func _rebuild() -> void:
	if _world_quad == null:
		return
	if _map == null or _world == null or _map.cell_count() == 0:
		_world_quad.mesh = null
		return

	_world_quad.mesh = _build_world_quad_mesh(_world.world_bounds)
	if _shader_mat == null:
		return
	_apply_uniforms()

func _build_world_quad_mesh(bounds: Rect2) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	var verts := PackedVector2Array([
		p,
		p + Vector2(s.x, 0.0),
		p + s,
		p + Vector2(0.0, s.y),
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _apply_uniforms() -> void:
	var sm := _shader_mat
	var bounds := _world.world_bounds

	# v9.atlas锛氬師 10 寮?sampler 鍘嬫垚 4 寮狅紙height + 3 atlas锛? 鍏变韩 noise_tex
	sm.set_shader_parameter("height_tex",   _world.height_tex)
	sm.set_shader_parameter("enum_atlas",   _world.enum_atlas_tex)
	sm.set_shader_parameter("scalar_atlas", _world.scalar_atlas_tex)
	sm.set_shader_parameter("vector_atlas", _world.vector_atlas_tex)
	# v9.fbm-opt锛氭妸鍏变韩 noise_tex 鍠傜粰鍦板舰 shader锛屾浛鎹?value_noise 鍐呴儴鐨?4脳 hash21
	sm.set_shader_parameter("noise_tex",    _world.noise_tex)

	sm.set_shader_parameter("world_origin", bounds.position)
	sm.set_shader_parameter("world_size", bounds.size)
	sm.set_shader_parameter("hm_resolution", Vector2(_world.hm_size.x, _world.hm_size.y))
	sm.set_shader_parameter("derived_resolution", Vector2(_world.derived_size.x, _world.derived_size.y))
	sm.set_shader_parameter("sea_level", _world.sea_level)

	# 瀛ｈ妭/姘斿€?uniform锛堟瘡娆￠噸寤烘椂鍚屾鍒濆€硷紝姣忓ぉ / 姣忓勾鐢?main.gd 鎺ㄨ繘锛?	sm.set_shader_parameter("season_phase", _season_phase)
	sm.set_shader_parameter("climate_anomaly", _climate_anomaly)
	sm.set_shader_parameter("world_time", _world_time)
	# 浠诲姟 2锛氭妸褰撳墠 day_phase 鍚屾鍒版柊鍒涘缓鐨勬潗璐ㄤ笂
	sm.set_shader_parameter("day_phase", _day_phase)
	sm.set_shader_parameter("season_temp_amp", season_temp_amp)
	sm.set_shader_parameter("vegetation_season_strength", vegetation_season_strength)
	sm.set_shader_parameter("dynamic_snow_strength", dynamic_snow_strength)
	sm.set_shader_parameter("ocean_current_strength", ocean_current_strength)
	sm.set_shader_parameter("wind_streak_strength", wind_streak_strength)
	sm.set_shader_parameter("vegetation_axis_strength", vegetation_axis_strength)
	sm.set_shader_parameter("cover_axis_strength", cover_axis_strength)

	# Milestone 3锛氶粯璁ゅ～绌?weather 鏁扮粍 + 璁惧叏灞€ weather 寮哄害
	sm.set_shader_parameter("weather_strength", weather_strength)

	# 浠诲姟 1锛氳瑙夋€诲紑鍏?uniform锛坰hader 绔敤 #define 椋庢牸 if 鍒嗘敮娑堣垂锛?	sm.set_shader_parameter("visual_quality", visual_quality)
	sm.set_shader_parameter("day_night_enabled", day_night_enabled)
	sm.set_shader_parameter("water_effect_enabled", water_effect_enabled)
	sm.set_shader_parameter("ocean_current_enabled", ocean_current_enabled)
	sm.set_shader_parameter(
		"extreme_weather_ground_effect_enabled",
		extreme_weather_ground_effect_enabled
	)
	# Pass 2锛堜换鍔?2锛夛細鎶?Pass 2 寮€鍏充篃鍚屾鍒版柊寤烘潗璐ㄤ笂
	sm.set_shader_parameter("water_sparkle_enabled", water_sparkle_enabled)
	sm.set_shader_parameter("cloud_tod_tint_enabled", cloud_tod_tint_enabled)
	sm.set_shader_parameter("ocean_current_debug", _ocean_current_debug)

	# Water Visual Overhaul锛氶娆″缓鏉愯川蹇呴』鎶婃湰杞?uniform 鍏ㄩ儴鍒濆鍖栵紝
	# 鍚﹀垯 main.gd 鐨?setter 鍦?_push_visual_toggles 涔嬪墠鐨勫抚閲屼細璇诲埌 0 鍊笺€?	sm.set_shader_parameter("water_waves_enabled", water_waves_enabled)
	sm.set_shader_parameter("water_fresnel_enabled", water_fresnel_enabled)
	sm.set_shader_parameter("river_flow_enabled", river_flow_enabled)
	sm.set_shader_parameter("caustics_enabled", caustics_enabled)
	sm.set_shader_parameter("shallow_transparency_enabled", shallow_transparency_enabled)
	sm.set_shader_parameter("water_gloss", water_gloss)
	sm.set_shader_parameter("water_reflection_strength", water_reflection_strength)
	sm.set_shader_parameter("river_flow_speed", river_flow_speed)
	sm.set_shader_parameter("river_flow_freq", river_flow_freq)
	sm.set_shader_parameter("caustics_strength", caustics_strength)
	sm.set_shader_parameter("deep_ocean_contrast", deep_ocean_contrast)
	sm.set_shader_parameter("lake_water_color", lake_water_color)
	sm.set_shader_parameter("shallow_transparency_factor", shallow_transparency_factor)
	sm.set_shader_parameter("water_domain_warp_strength", water_domain_warp_strength)
	sm.set_shader_parameter("water_wave_line_strength", water_wave_line_strength)
	sm.set_shader_parameter("water_calm_noise_brightness", water_calm_noise_brightness)
	sm.set_shader_parameter("water_calm_noise_tint_strength", water_calm_noise_tint_strength)
	sm.set_shader_parameter("water_biome_blend_radius", water_biome_blend_radius)
	sm.set_shader_parameter("water_cartoon_color_strength", water_cartoon_color_strength)
	sm.set_shader_parameter("water_transition_softness", water_transition_softness)
	sm.set_shader_parameter("estuary_plume_strength", estuary_plume_strength)

	# v9.split锛歸eather 琛ㄧ幇灞備笌鍦板舰 shader 鍏变韩鍚屼竴缁?weather uniform锛?	# 鎸備笂 enum_atlas 褰撴捣闄嗗垽鏂€乶oise_tex 缁?weather overlay shader 澶嶇敤
	if _weather_layer != null:
		_weather_layer.setup(bounds, _world.enum_atlas_tex, _world.noise_tex)
		_weather_layer.set_weather_strength(weather_strength)
	set_weather_fronts([])

	# Hypsometric 鑹查樁
	sm.set_shader_parameter("color_deep_ocean", color_deep_ocean)
	sm.set_shader_parameter("color_mid_ocean", color_mid_ocean)
	sm.set_shader_parameter("color_shallow", color_shallow)
	sm.set_shader_parameter("color_coast_water", color_coast_water)
	sm.set_shader_parameter("color_beach", color_beach)
	sm.set_shader_parameter("color_lowland", color_lowland)
	sm.set_shader_parameter("color_hill", color_hill)
	sm.set_shader_parameter("color_mountain", color_mountain)
	sm.set_shader_parameter("color_peak", color_peak)
	sm.set_shader_parameter("color_snow", color_snow)

	# Hillshading
	sm.set_shader_parameter("hillshade_strength", hillshade_strength)
	sm.set_shader_parameter("hillshade_slope_gain", hillshade_slope_gain)

	# Rivers
	sm.set_shader_parameter("river_strength", river_strength)
	sm.set_shader_parameter("river_threshold_low", river_threshold_low)
	sm.set_shader_parameter("river_threshold_high", river_threshold_high)
	sm.set_shader_parameter("river_color", river_color)
	sm.set_shader_parameter("river_outline_color", river_outline_color)

	# Contour
	sm.set_shader_parameter("contour_enabled", contour_enabled)
	sm.set_shader_parameter("contour_step", contour_step)
	sm.set_shader_parameter("contour_strength", contour_strength)
	sm.set_shader_parameter("contour_color", contour_color)

	# Coast halo
	sm.set_shader_parameter("coast_halo_color", coast_halo_color)
	sm.set_shader_parameter("coast_halo_strength", coast_halo_strength)

	# Atlas
	sm.set_shader_parameter("parchment_tint", parchment_tint)
	sm.set_shader_parameter("parchment_strength", parchment_strength)
	sm.set_shader_parameter("paper_grain_strength", paper_grain_strength)
