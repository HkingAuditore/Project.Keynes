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

@export var enabled: bool = true

@export_group("Global Defaults")
@export_enum("Shrub", "Tree", "Grass", "Conifer", "Palm", "Cactus", "Reed", "AlpineFlower", "Rock", "SnowMound", "DeadSnag") var detail_kind: int = DetailKind.SHRUB
@export_range(-16, 16, 1) var render_z_index: int = 1
@export_range(0.0, 300.0, 0.05) var density_scale: float = 1.55
@export_range(0.0, 3.0, 0.05) var wind_strength: float = 1.0

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
@export_range(0.0, 1.0, 0.01) var vitality_dieback_noise_strength: float = 0.45
