class_name ShrubVisualProfile
extends Resource

enum DetailKind {
	SHRUB,         # 0 灌木（默认）
	TREE,          # 1 阔叶/通用乔木
	GRASS,         # 2 草丛
	CONIFER,       # 3 针叶树（寒带/亚高山）
	PALM,          # 4 棕榈（热带海岸/暖湿）
	CACTUS,        # 5 仙人掌（干旱/荒漠）
	REED,          # 6 芦苇（湿地/河岸）
	ALPINE_FLOWER, # 7 高山花（高山草甸/苔原）
	ROCK,          # 8 岩石点缀（山地/荒地/裸露地）
	SNOW_MOUND,    # 9 雪堆（积雪/冻土/冰缘）
	DEAD_SNAG,     # 10 枯立木（低活力/胁迫区）
}

enum RotationMode {
	RANDOM_FULL,    # 岩石/草丛等无明确上下方向的点缀
	UPRIGHT,        # 树木/棕榈等保持竖向
	UPRIGHT_JITTER, # 竖向基础上给少量自然歪斜
}

enum SpawnDomain {
	LAND,  # 默认陆地点缀
	WATER, # 海草/海藻/珊瑚等水域点缀
	ANY,
}

@export var enabled: bool = true

@export_group("Global Defaults")
@export_enum("Shrub", "Tree", "Grass", "Conifer", "Palm", "Cactus", "Reed", "AlpineFlower", "Rock", "SnowMound", "DeadSnag") var detail_kind: int = DetailKind.SHRUB
@export_range(-16, 16, 1) var render_z_index: int = 1
@export_range(0.0, 300.0, 0.05) var density_scale: float = 1.55
@export_range(0.0, 3.0, 0.05) var wind_strength: float = 1.0

@export_group("Placement Semantics")
@export_enum("Land", "Water", "Any") var spawn_domain: int = SpawnDomain.LAND
@export_enum("RandomFull", "Upright", "UprightJitter") var rotation_mode: int = RotationMode.RANDOM_FULL
@export_range(0.0, 1.0, 0.01) var random_rotation_strength: float = 1.0
@export_range(0.0, 35.0, 0.5) var upright_jitter_degrees: float = 6.0

@export_group("Ecology Affinity Overrides")
@export var vegetation_weight_overrides: Dictionary = {}
@export var landform_weight_overrides: Dictionary = {}
@export var cover_weight_overrides: Dictionary = {}

@export_group("Color Override")
@export var base_color_override_enabled: bool = false
@export var base_color_override: Color = Color(0.18, 0.39, 0.19, 0.88)

@export_group("Desktop Quality")
@export_range(0.0, 2.0, 0.05) var desktop_density_multiplier_quality0: float = 0.55
@export_range(0.0, 2.0, 0.05) var desktop_density_multiplier_quality1: float = 1.0
@export_range(0.0, 2.0, 0.05) var desktop_density_multiplier_quality2: float = 1.35
@export var desktop_max_instances_quality0: int = 4500
@export var desktop_max_instances_quality1: int = 14000
@export var desktop_max_instances_quality2: int = 24000
@export var desktop_max_per_cell_quality0: int = 2
@export var desktop_max_per_cell_quality1: int = 5
@export var desktop_max_per_cell_quality2: int = 7
@export_range(2, 8, 1) var desktop_lobes_quality0: int = 4
@export_range(2, 8, 1) var desktop_lobes_quality1: int = 6
@export_range(2, 8, 1) var desktop_lobes_quality2: int = 8
@export_range(0.1, 1.5, 0.01) var desktop_size_scale_quality0: float = 0.92
@export_range(0.1, 1.5, 0.01) var desktop_size_scale_quality1: float = 1.0
@export_range(0.1, 1.5, 0.01) var desktop_size_scale_quality2: float = 1.04

@export_group("Mobile Quality")
@export_range(0.0, 2.0, 0.05) var mobile_density_multiplier_quality0: float = 0.28
@export_range(0.0, 2.0, 0.05) var mobile_density_multiplier_quality1: float = 0.46
@export_range(0.0, 2.0, 0.05) var mobile_density_multiplier_quality2: float = 0.70
@export var mobile_max_instances_quality0: int = 900
@export var mobile_max_instances_quality1: int = 1800
@export var mobile_max_instances_quality2: int = 2600
@export var mobile_max_per_cell_quality0: int = 1
@export var mobile_max_per_cell_quality1: int = 2
@export var mobile_max_per_cell_quality2: int = 3
@export_range(2, 8, 1) var mobile_lobes_quality0: int = 3
@export_range(2, 8, 1) var mobile_lobes_quality1: int = 4
@export_range(2, 8, 1) var mobile_lobes_quality2: int = 5
@export_range(0.1, 1.5, 0.01) var mobile_size_scale_quality0: float = 0.78
@export_range(0.1, 1.5, 0.01) var mobile_size_scale_quality1: float = 0.92
@export_range(0.1, 1.5, 0.01) var mobile_size_scale_quality2: float = 0.98

@export_group("River Avoidance")
@export_range(0.0, 1.0, 0.01) var river_clear_threshold: float = 0.50
@export_range(0.0, 1.0, 0.01) var river_edge_density: float = 0.42

@export_group("Shape")
@export_range(0.0, 1.0, 0.01) var spawn_radius_factor: float = 0.78
@export_range(0.01, 0.5, 0.005) var min_size_factor: float = 0.095
@export_range(0.01, 0.5, 0.005) var max_size_factor: float = 0.19

@export_group("PCG Distribution")
@export_range(0.02, 1.0, 0.01) var patch_frequency: float = 0.095
@export_range(0.0, 1.0, 0.01) var patch_cutoff: float = 0.31
@export_range(0.5, 4.0, 0.05) var patch_contrast: float = 2.15
@export_range(0.0, 1.0, 0.01) var micro_gap_threshold: float = 0.12
@export_range(0.0, 2.0, 0.05) var world_noise_acceptance: float = 1.10
@export_range(0.0, 1.0, 0.01) var world_noise_mid_mix: float = 0.38
@export_range(0.0, 1.0, 0.01) var world_noise_fine_mix: float = 0.10
@export_range(0.0, 0.45, 0.01) var world_noise_warp_strength: float = 0.20
@export_range(0.0, 2.0, 0.05) var moisture_corridor_boost: float = 0.65
@export_range(0.0, 2.0, 0.05) var vitality_patch_boost: float = 0.55

@export_group("Climate Appearance")
@export_range(0.0, 1.0, 0.01) var dry_yellow_strength: float = 0.82
@export_range(0.0, 1.0, 0.01) var wet_green_strength: float = 0.48
@export_range(0.0, 1.0, 0.01) var lush_green_strength: float = 0.72
@export_range(0.0, 1.0, 0.01) var heat_red_strength: float = 0.55
@export_range(0.0, 1.0, 0.01) var autumn_red_strength: float = 0.42
@export_range(0.0, 1.0, 0.01) var temperature_color_strength: float = 0.78
@export_range(0.0, 1.0, 0.01) var moisture_color_strength: float = 0.82
@export_range(0.0, 1.0, 0.01) var snow_white_strength: float = 0.90
@export_range(0.0, 1.0, 0.01) var stress_hide_strength: float = 0.78
@export_range(0.0, 1.0, 0.01) var snow_hide_strength: float = 0.62
@export_range(0.0, 1.0, 0.01) var disappear_alpha_threshold: float = 0.08

@export_group("Vegetation Vitality")
@export_range(0.0, 1.0, 0.01) var vitality_dead_threshold: float = 0.12
@export_range(0.0, 1.0, 0.01) var vitality_sparse_threshold: float = 0.36
@export_range(0.0, 1.0, 0.01) var vitality_healthy_threshold: float = 0.72
@export_range(0.2, 4.0, 0.05) var vitality_density_power: float = 1.35
@export_range(0.2, 4.0, 0.05) var vitality_alpha_power: float = 1.10
@export_range(0.0, 1.0, 0.01) var vitality_size_min: float = 0.34
@export_range(0.5, 1.5, 0.01) var vitality_size_max: float = 1.08
@export_range(0.0, 1.0, 0.01) var vitality_low_color_strength: float = 0.72
@export_range(0.0, 1.0, 0.01) var vitality_high_color_strength: float = 0.42
@export_range(0.0, 1.0, 0.01) var vitality_color_contrast: float = 0.90
@export_range(0.0, 1.0, 0.01) var vitality_dieback_noise_strength: float = 0.45

# ─────────────────────────────────────────────────────────────────────────
# Shading（法线辅助着色）：复用地形烘焙宏观法线 terrain_normal_tex + 高度图 height_tex，
# 配合 billboard UV 推导的伪法线，做 NdotL 方向光 / 边缘光 / 接触 AO / 谷地 AO。
# 全部在 shrub_layer 内嵌 shader 内材质驱动求解；与地形/水面同源调用 earth_daylight。
# ─────────────────────────────────────────────────────────────────────────
@export_group("Shading (Normal-assisted)")
@export var shading_enabled: bool = true
# 地形宏观法线对整株倾斜的影响（让站在坡上的植被随坡面受光），未烘焙法线时自动退化。
@export_range(0.0, 1.5, 0.01) var terrain_normal_influence: float = 0.65
# billboard 伪法线强度：越大左右/上下的体积明暗越强（迎光面亮、背光面暗）。
@export_range(0.0, 2.0, 0.01) var pseudo_normal_strength: float = 0.85
# 方向光（NdotL）直射贡献强度。
@export_range(0.0, 1.5, 0.01) var sun_shade_strength: float = 0.55
# 环境光下限（对齐地形 AMBIENT_FLOOR_LAND=0.18），避免背光面死黑。
@export_range(0.0, 0.6, 0.01) var ambient_floor: float = 0.18
# 边缘光（fresnel 风格）：背光轮廓轻微提亮，增加体积感。
@export_range(0.0, 0.6, 0.01) var rim_light_strength: float = 0.12
# 接触阴影：近根部（UV.y 低）压暗强度与作用高度。
@export_range(0.0, 1.0, 0.01) var contact_ao_strength: float = 0.42
@export_range(0.0, 0.8, 0.01) var contact_ao_height: float = 0.32
# 谷地 AO：用 height_tex 邻域差判断凹陷（谷/坑）→ 压暗。仅高画质档采样邻域。
@export_range(0.0, 1.0, 0.01) var terrain_valley_ao_strength: float = 0.40
@export_range(0.5, 16.0, 0.1) var terrain_valley_ao_gain: float = 6.0

# ─────────────────────────────────────────────────────────────────────────
# Cast Shadow（投影）：独立低 z 的 shadow pass，用「软边椭圆 blob」网格（非复用植株网格）。
# 顶点把单位圆映射为沿本实例经纬度太阳背光方向拉伸的椭圆（足印半径 + 随太阳低度数拉长）；
# 片元用径向距离做柔边。夜侧/太阳高悬时自动收敛。每次重建一次 buffer 拷贝（非逐帧）；
# 按画质分档（桌面 q>=1 开启；移动端默认关）。
# ─────────────────────────────────────────────────────────────────────────
@export_group("Cast Shadow")
@export var cast_shadow_enabled: bool = true
@export var cast_shadow_on_mobile: bool = false
@export var shadow_color: Color = Color(0.05, 0.06, 0.08, 1.0)
@export_range(0.0, 1.0, 0.01) var shadow_strength: float = 0.28
@export_range(0.0, 4.0, 0.05) var shadow_length_scale: float = 1.0
@export_range(0.1, 5.0, 0.05) var shadow_max_length: float = 1.4
# 太阳高度角低于此值（近晨昏/夜）时阴影淡出，避免无限拉长。
@export_range(0.02, 1.0, 0.01) var shadow_min_sun_elevation: float = 0.16
# 足部半径（局部单位，×实例 size = 世界足印）：阴影根部的椭圆短轴/接触圆盘大小。
@export_range(0.1, 1.5, 0.01) var shadow_foot_radius: float = 0.55
# 软边起点（0..1 径向）：r 小于此值为实心核心，向边缘平滑淡出 → 越小越柔。
@export_range(0.0, 0.95, 0.01) var shadow_edge_softness: float = 0.25
