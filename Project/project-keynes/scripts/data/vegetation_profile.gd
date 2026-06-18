# vegetation_profile.gd
# Data-driven configuration for a single vegetation type.
#
# Single source of truth for:
#   - identity (veg_type enum value + Chinese display name)
#   - eco-physics: transpiration / albedo / eco_score
#   - climate-adaptation: ideal_temp / ideal_moist + Gaussian tolerance
#   - succession chain: next_richer / next_harsher (-1 = chain tail)
#
# One .tres per VegetationType.VEG value, collected by VegetationProfileRegistry.
# Consumers: VegetationType (facade), MapGenerator (succession passes),
# UI (hex_info_panel), ecosystem scoring (Phase 8).

class_name VegetationProfile
extends Resource

# ─── Identity ───────────────────────────────────────────────────────────

@export var veg_type: int = 0              # VegetationType.VEG value
@export var display_name_cn: String = "无植被"

# ─── Eco-physics ────────────────────────────────────────────────────────

@export var transpiration: float = 0.0     # [0, 1], moisture donated to neighbors
@export var albedo: float = 0.30           # [0, 1], reflectivity (snow/sand high)
@export var eco_score: float = 0.0         # typically -0.8 ~ +1.2, drives base_moisture drift

# ─── Climate adaptation ─────────────────────────────────────────────────
# climate_compat_score() uses a 2-D Gaussian:
#   score = exp(-0.5 * ((dt/tt)^2 + (dm/mt)^2))
# Lower tolerance = pickier about climate deviation.

@export var ideal_temp: float = 0.5        # [0, 1], climate center
@export var ideal_moist: float = 0.5       # [0, 1], climate center
@export var temp_tolerance: float = 0.28   # Gaussian sigma for temp (vegetation-survival-rebalance 方案 D：整体 1.6× 扩大，避免正常季节波动就进入负漂区)
@export var moist_tolerance: float = 0.28  # Gaussian sigma for moist

# ─── Succession chain ───────────────────────────────────────────────────
# -1 = chain tail (no further transition in this direction). Self-reference
# (next == veg_type) is also treated as chain tail by the facade.

@export var next_richer: int = -1          # long-term climate boon → upgrade
@export var next_harsher: int = -1         # long-term climate hardship → downgrade

# ─── map-visual-overhaul-v1：四季换色 LUT（shader 着色用） ──────────────
# season_color_lut：4 项 [春, 夏, 秋, 冬] 色相偏移色（叠乘到 base 着色，1.0,1.0,1.0,1.0 = 不偏移）。
#   shader 端按当前半球的 season_phase ∈ [0,4) 做 4 段 cubic mix，南北半球反相。
#   常青 / 热带 / 沙漠 / 苔原等不四季换色的类型可直接保持四项一致。
#   默认 [W, W, W, W]（全 1.0），即不偏移；具体数值由 vegetation .tres 资源单独配置。
# anomaly_color_shift：climate_anomaly 升高时叠加的额外色相偏移（用于苔原带北移、
#   森林带边界推移等长期气候视觉信号）。默认 (0,0,0,0) = 无偏移。
@export var season_color_lut: Array[Color] = [
	Color(1.0, 1.0, 1.0, 1.0),  # 春
	Color(1.0, 1.0, 1.0, 1.0),  # 夏
	Color(1.0, 1.0, 1.0, 1.0),  # 秋
	Color(1.0, 1.0, 1.0, 1.0),  # 冬
]
@export var anomaly_color_shift: Color = Color(0.0, 0.0, 0.0, 0.0)


# map-visual-overhaul-v1：判断当前 season_color_lut 是否仍是默认全白（4 个 1,1,1,1）。
# Registry 加载完 .tres 后用此判断决定是否套用按 veg_type 的"生态合理默认 LUT"。
# .tres 资源若手动配置过，会与默认值不同 → 不覆盖。
func is_season_lut_default() -> bool:
	if season_color_lut == null or season_color_lut.size() != 4:
		return true
	for c in season_color_lut:
		if not (
			is_equal_approx(c.r, 1.0)
			and is_equal_approx(c.g, 1.0)
			and is_equal_approx(c.b, 1.0)
		):
			return false
	return true


# map-visual-overhaul-v1：按 veg_type 给 24 个植被类型注入"生态合理"的四季默认 LUT。
# 设计原则：
#   * 常青针叶 / 热带常青 / 极地裸地 → 四季近似稳定（仅微弱明度差）。
#   * 温带阔叶 / 落叶林 → 春翠绿、夏深绿、秋金黄、冬枯褐。
#   * 草原 / 草甸 → 春萌、夏盛、秋黄、冬枯。
#   * 苔原 / 高山苔原 → 夏短暂泛绿、其余冷褐灰。
#   * 沙漠 / 灌木 → 雨季泛绿、旱季偏黄白。
#   * 水生植被（红树 / 海带 / 珊瑚）→ 几乎不换色，仅明度微差。
# 数值意义：每项 = 叠乘到 base 着色的色相偏移（1.0,1.0,1.0,1.0 表示不偏移）。
# 维度顺序固定：[春, 夏, 秋, 冬]。
func apply_default_season_lut() -> void:
	match veg_type:
		0:  # NONE：不染色
			season_color_lut = [
				Color(1.0, 1.0, 1.0, 1.0),
				Color(1.0, 1.0, 1.0, 1.0),
				Color(1.0, 1.0, 1.0, 1.0),
				Color(1.0, 1.0, 1.0, 1.0),
			]
			anomaly_color_shift = Color(0.0, 0.0, 0.0, 0.0)
		1:  # POLAR_DESERT：终年极冷裸地，仅微弱明度差
			season_color_lut = [
				Color(0.96, 0.96, 1.00, 1.0),
				Color(1.02, 1.02, 1.04, 1.0),
				Color(0.96, 0.94, 0.96, 1.0),
				Color(0.94, 0.95, 1.00, 1.0),  # [v1-hotfix-darkness] 冬：仅微调更冷白
			]
			anomaly_color_shift = Color(0.04, 0.02, -0.04, 0.0)  # 升温→偏暖（雪退去裸土）
		2, 3:  # TUNDRA / ALPINE_TUNDRA：夏短暂泛绿
			season_color_lut = [
				Color(0.92, 0.96, 0.86, 1.0),  # 春末雪退
				Color(0.86, 1.05, 0.78, 1.0),  # 夏短绿
				Color(1.05, 0.92, 0.72, 1.0),  # 秋早冷褐
				Color(0.92, 0.94, 1.00, 1.0),  # [v1-hotfix-darkness] 冬：抬亮 + 冷色相，雪由 snow_blur 处理
			]
			anomaly_color_shift = Color(0.04, 0.06, -0.06, 0.0)  # 升温→苔原带北移、绿期延长
		4:  # ALPINE_MEADOW：高山草甸，夏盛、冬雪
			season_color_lut = [
				Color(0.95, 1.10, 0.84, 1.0),
				Color(0.78, 1.16, 0.72, 1.0),
				Color(1.18, 0.94, 0.62, 1.0),
				Color(0.94, 0.95, 0.99, 1.0),  # [v1-hotfix-darkness] 冬：高山草甸冬日仅冷化
			]
			anomaly_color_shift = Color(0.02, 0.04, -0.04, 0.0)
		5:  # TAIGA：寒带针叶林，常青但冬天暗一些
			season_color_lut = [
				Color(0.84, 1.00, 0.80, 1.0),
				Color(0.78, 1.02, 0.78, 1.0),
				Color(0.80, 0.96, 0.74, 1.0),
				Color(0.92, 0.96, 0.96, 1.0),  # [v1-hotfix-darkness] 冬：针叶林仍偏绿，仅冷化亮度
			]
			anomaly_color_shift = Color(-0.02, 0.04, -0.04, 0.0)
		6:  # BOREAL_SHRUB：北方灌木，秋色明显
			season_color_lut = [
				Color(0.92, 1.04, 0.84, 1.0),
				Color(0.84, 1.08, 0.78, 1.0),
				Color(1.20, 0.86, 0.58, 1.0),  # 秋黄红
				Color(0.94, 0.95, 0.99, 1.0),  # [v1-hotfix-darkness] 冬：枯枝但不变黑
			]
			anomaly_color_shift = Color(0.02, 0.02, -0.04, 0.0)
		7:  # TEMPERATE_DECIDUOUS：温带落叶林，四季最明显
			season_color_lut = [
				Color(0.94, 1.16, 0.82, 1.0),  # 春嫩绿
				Color(0.70, 1.08, 0.62, 1.0),  # 夏深绿
				Color(1.32, 0.84, 0.40, 1.0),  # 秋金黄
				Color(0.94, 0.95, 0.99, 1.0),  # [v1-hotfix-darkness] 冬：裸枝仅冷化，雪由 snow_blur 处理
			]
			anomaly_color_shift = Color(0.04, 0.00, -0.06, 0.0)
		8:  # TEMPERATE_CONIFER：温带针叶，常青
			season_color_lut = [
				Color(0.84, 1.02, 0.80, 1.0),
				Color(0.78, 1.04, 0.76, 1.0),
				Color(0.84, 0.96, 0.74, 1.0),
				Color(0.93, 0.97, 0.97, 1.0),  # [v1-hotfix-darkness] 冬：常青针叶林仅微冷化
			]
			anomaly_color_shift = Color(-0.02, 0.04, -0.04, 0.0)
		9, 10:  # GRASSLAND / STEPPE：温带草原，干湿轮换
			season_color_lut = [
				Color(0.96, 1.18, 0.84, 1.0),  # 春萌
				Color(0.82, 1.16, 0.68, 1.0),  # 夏盛
				Color(1.24, 0.96, 0.54, 1.0),  # 秋黄
				Color(0.96, 0.94, 0.92, 1.0),  # [v1-hotfix-darkness] 冬：偏冷褐而非压暗
			]
			anomaly_color_shift = Color(0.06, -0.02, -0.04, 0.0)  # 升温→旱化偏黄
		11:  # MEDITERRANEAN_SHRUB：地中海灌木，干夏
			season_color_lut = [
				Color(0.96, 1.12, 0.82, 1.0),
				Color(1.10, 1.00, 0.66, 1.0),  # 夏旱黄
				Color(1.04, 0.98, 0.74, 1.0),
				Color(0.94, 1.02, 0.96, 1.0),  # [v1-hotfix-darkness] 冬雨绿，B 抬冷化
			]
			anomaly_color_shift = Color(0.08, -0.02, -0.06, 0.0)
		12:  # SUBTROPICAL_FOREST：亚热带常绿，弱季节
			season_color_lut = [
				Color(0.86, 1.10, 0.80, 1.0),
				Color(0.80, 1.10, 0.76, 1.0),
				Color(0.92, 1.04, 0.74, 1.0),
				Color(0.92, 1.02, 0.94, 1.0),  # [v1-hotfix-darkness] 冬：亚热带常绿仅冷化
			]
			anomaly_color_shift = Color(0.02, 0.02, -0.04, 0.0)
		13:  # SAVANNA：干湿明显
			season_color_lut = [
				Color(0.94, 1.10, 0.74, 1.0),  # 雨季初绿
				Color(0.86, 1.14, 0.70, 1.0),  # 雨季盛
				Color(1.22, 0.98, 0.54, 1.0),  # 旱季黄
				Color(1.04, 0.98, 0.92, 1.0),  # [v1-hotfix-darkness] 旱末：冷调干黄而非深褐
			]
			anomaly_color_shift = Color(0.06, -0.02, -0.06, 0.0)
		14:  # TROPICAL_RAINFOREST：常青、几乎无季节
			season_color_lut = [
				Color(0.78, 1.10, 0.78, 1.0),
				Color(0.76, 1.12, 0.78, 1.0),
				Color(0.80, 1.10, 0.78, 1.0),
				Color(0.86, 1.06, 0.92, 1.0),  # [v1-hotfix-darkness] 冬：B 略提冷化
			]
			anomaly_color_shift = Color(0.04, -0.02, -0.04, 0.0)  # 升温→旱化色相
		15:  # TROPICAL_DRY_FOREST：旱季落叶
			season_color_lut = [
				Color(0.96, 1.12, 0.74, 1.0),
				Color(0.84, 1.10, 0.70, 1.0),
				Color(1.18, 0.94, 0.58, 1.0),
				Color(1.00, 0.96, 0.92, 1.0),  # [v1-hotfix-darkness] 冬：热带旱季冷化褐黄
			]
			anomaly_color_shift = Color(0.06, -0.02, -0.06, 0.0)
		16, 17:  # DESERT_SCRUB / XERIC_DESERT：沙漠灌丛/极旱
			season_color_lut = [
				Color(1.04, 1.04, 0.76, 1.0),
				Color(1.14, 1.02, 0.74, 1.0),
				Color(1.10, 1.00, 0.74, 1.0),
				Color(1.00, 1.02, 0.94, 1.0),  # [v1-hotfix-darkness] 冬：沙漠冬日略冷
			]
			anomaly_color_shift = Color(0.06, 0.00, -0.06, 0.0)
		18:  # OASIS_VEG：绿洲，全年偏绿
			season_color_lut = [
				Color(0.86, 1.12, 0.80, 1.0),
				Color(0.80, 1.14, 0.74, 1.0),
				Color(0.94, 1.06, 0.72, 1.0),
				Color(0.92, 1.04, 0.94, 1.0),  # [v1-hotfix-darkness] 冬：绿洲全年偏绿，B 抬冷化
			]
			anomaly_color_shift = Color(0.04, -0.02, -0.04, 0.0)
		19:  # MANGROVE：红树林，水陆交界，弱季节
			season_color_lut = [
				Color(0.84, 1.08, 0.80, 1.0),
				Color(0.80, 1.10, 0.78, 1.0),
				Color(0.90, 1.04, 0.76, 1.0),
				Color(0.92, 1.02, 0.94, 1.0),  # [v1-hotfix-darkness] 冬：红树林仅冷化
			]
			anomaly_color_shift = Color(0.02, 0.02, -0.04, 0.0)
		20, 21:  # SWAMP / MARSH：沼泽湿地
			season_color_lut = [
				Color(0.88, 1.08, 0.78, 1.0),
				Color(0.80, 1.12, 0.72, 1.0),
				Color(1.02, 0.98, 0.70, 1.0),
				Color(0.94, 0.96, 0.98, 1.0),  # [v1-hotfix-darkness] 冬：沼泽冬枯抬亮、冷化
			]
			anomaly_color_shift = Color(0.04, 0.00, -0.04, 0.0)
		22:  # KELP_FOREST：海带林，几乎不换色
			season_color_lut = [
				Color(0.92, 1.04, 0.92, 1.0),
				Color(0.90, 1.04, 0.92, 1.0),
				Color(0.92, 1.02, 0.92, 1.0),
				Color(0.92, 1.00, 0.96, 1.0),  # [v1-hotfix-darkness] 冬：海带林几乎不变
			]
			anomaly_color_shift = Color(0.02, -0.02, -0.02, 0.0)
		23:  # CORAL_REEF：珊瑚礁，几乎不换色
			season_color_lut = [
				Color(1.02, 1.00, 0.96, 1.0),
				Color(1.04, 1.00, 0.94, 1.0),
				Color(1.02, 1.00, 0.96, 1.0),
				Color(1.00, 1.00, 0.98, 1.0),  # 已合理，保持
			]
			anomaly_color_shift = Color(0.04, -0.04, -0.06, 0.0)  # 升温→白化偏粉
		24:  # CLOUD_FOREST：云雾林，常青高湿，弱季节
			season_color_lut = [
				Color(0.78, 1.12, 0.82, 1.0),
				Color(0.74, 1.14, 0.80, 1.0),
				Color(0.82, 1.08, 0.78, 1.0),
				Color(0.86, 1.06, 0.92, 1.0),  # 冬：仅冷化
			]
			anomaly_color_shift = Color(0.02, 0.02, -0.04, 0.0)
		25:  # MONSOON_FOREST：季风林，干湿季半落叶
			season_color_lut = [
				Color(0.92, 1.12, 0.74, 1.0),  # 雨季初绿
				Color(0.82, 1.12, 0.70, 1.0),  # 雨季盛
				Color(1.20, 0.94, 0.56, 1.0),  # 旱季落叶金黄
				Color(1.02, 0.96, 0.90, 1.0),  # 旱末冷化
			]
			anomaly_color_shift = Color(0.06, -0.02, -0.06, 0.0)
		26:  # SEAGRASS：海草床，水下几乎不换色
			season_color_lut = [
				Color(0.90, 1.04, 0.90, 1.0),
				Color(0.88, 1.06, 0.88, 1.0),
				Color(0.92, 1.02, 0.90, 1.0),
				Color(0.92, 1.00, 0.96, 1.0),
			]
			anomaly_color_shift = Color(0.02, -0.02, -0.02, 0.0)
		27:  # PEAT_BOG：泥炭沼，凉湿，秋枯明显
			season_color_lut = [
				Color(0.90, 1.06, 0.76, 1.0),
				Color(0.82, 1.10, 0.70, 1.0),
				Color(1.08, 0.94, 0.62, 1.0),  # 秋枯赭黄
				Color(0.94, 0.96, 0.98, 1.0),  # 冬冷化
			]
			anomaly_color_shift = Color(0.04, 0.00, -0.05, 0.0)
		_:
			# 未知 veg_type → 保持默认全白（不偏移）
			pass
