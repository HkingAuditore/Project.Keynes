class_name ResourceVisualProfile
extends Resource

@export var enabled := true
@export_range(0.0, 2.0) var density_scale := 1.0
@export var desktop_instance_caps := PackedInt32Array([6000, 12000, 20000])
@export var mobile_instance_caps := PackedInt32Array([1000, 2000, 4000])
@export var per_cell_caps := PackedInt32Array([2, 4, 6])
@export var resource_types_per_cell := PackedInt32Array([1, 2, 3])
@export var resident_chunks_desktop := 128
@export var resident_chunks_mobile := 48
@export_range(0.05, 1.0) var observation_budget_ms := 0.30
@export_range(0.05, 1.0) var build_budget_ms := 0.45
@export_range(0.0, 1.0) var river_clear_threshold := 0.54
# 实景是美术点缀而非识别标志：小件主体（碎石/兽群/作物丛）直径，单位为格。
# 确切种类由资源透镜徽章承担。
@export_range(0.05, 1.0) var patch_diameter_hex := 0.40
# 植物/地力承担地表覆盖；矿物和动物只在较高门槛下作局部点缀。
@export_range(0.1, 1.5) var plant_diameter_hex := 0.78
@export_range(0.1, 1.5) var fertility_diameter_hex := 1.20
@export_range(1.0, 2.0) var plant_cluster_density := 1.30
@export_range(1, 4) var mineral_min_abundance_band := 3
@export_range(0.0, 1.0) var mineral_presence := 0.32
@export_range(0.0, 1.0) var animal_presence := 0.40
# 地面贴花（土壤/裸露矿斑/水下资源）直径；边缘为软噪声，视觉面积约为该值的 70%。
@export_range(0.1, 1.5) var decal_diameter_hex := 0.80
@export_range(0.0, 1.0) var decal_opacity := 0.60
@export_range(0.0, 1.0) var submerged_opacity := 0.50
# 水下：深水按 exp(-depth * falloff) 透光衰减；鱼群只在少数格子出现。
@export_range(0.0, 8.0) var water_depth_falloff := 2.6
@export_range(0.0, 1.0) var shoal_density := 0.30
# 小件主体的描边、接地阴影、投影强度。默认无描边无投影，避免“贴纸浮在地上”。
@export_range(0.0, 1.0) var outline_strength := 0.0
@export_range(0.0, 1.0) var contact_shadow := 0.45
@export_range(0.0, 1.0) var cast_shadow := 0.0
# 明度压缩：把纯黑煤、纯白盐拉回地表明度区间，避免成为全图最高对比的元素。
@export_range(0.0, 1.0) var luma_compress := 0.75
# 植株/晶体群落的外沿羽化与扰动；实体之间直接露出原地表，不再铺裸土底板。
@export_range(0.0, 1.0) var area_feather := 0.55
@export_range(0.0, 1.0) var area_edge_noise := 0.35
@export var luma_range := Vector2(0.24, 0.64)
@export_range(0.0, 1.0) var cluster_spread := 0.55
@export_range(0.0, 1.0) var patch_noise_strength := 0.55
@export_range(0.0, 1.0) var vitality_dead_threshold := 0.04
@export_range(0.1, 3.0) var vitality_power := 0.65
@export_range(0.0, 1.0) var climate_response := 0.7
@export_range(0.0, 1.0) var snow_response := 0.85
@export_range(0.0, 1.0) var wind_strength := 0.35
@export_range(0.0, 1.0) var animal_motion := 0.55
# 屏幕半径像素阈值：小件主体低于 simple 只保留主资源，低于 fade 消失（贴花更大，留得更久）。
@export var detailed_pixels := 9.0
@export var simple_pixels := 4.0
@export var fade_pixels := 1.5
# 压低饱和度以融入地图；资源透镜徽章的屏幕像素直径与淡入速度。
@export_range(0.2, 1.0) var palette_saturation := 0.80
@export var badge_px := 34.0
@export var lens_fade_seconds := 0.25
# Stable resource/signal IDs, never catalog indices. Supported keys: color,
# priority, size_scale. This table is presentation only.
@export var style_overrides: Dictionary = {}

func instance_cap(quality: int, mobile: bool) -> int:
	var caps := mobile_instance_caps if mobile else desktop_instance_caps
	return maxi(0, caps[clampi(quality, 0, caps.size() - 1)]) if not caps.is_empty() else 0

func cell_cap(quality: int) -> int:
	return maxi(1, per_cell_caps[clampi(quality, 0, per_cell_caps.size() - 1)])

func type_cap(quality: int) -> int:
	return clampi(resource_types_per_cell[clampi(quality, 0, resource_types_per_cell.size() - 1)], 1, 3)
