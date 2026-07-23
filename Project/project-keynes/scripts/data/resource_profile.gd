# resource_profile.gd
# Data-driven definition of a single natural resource type.
#
# Single source of truth for:
#   - identity (id + display name + icon)
#   - storage binding: which per-cell DataCore component holds this resource's
#     reserve (reserve_component, e.g. &"cell.res_timber_reserve")
#   - generation / decay / external-change formula coefficients (fixed template, see below)
#   - initial deposit coefficients (used at map generation)
#
# Unified model: 可再生 / 不可再生 资源不分两种类型，差异完全由系数表达。
#   - 可再生（如 timber）：gen_self > 0 且 decay_self > 0 → 自然收敛到动态平衡点。
#   - 不可再生（如 iron_ore）：gen_* / decay_* ≈ 0，日尺度静态；未来开采系统写 extra_change。
#
# 每 tick（per cell）公式模板，由 C++ run_natural_resource_pass / GDScript fallback
# 严格 1:1 复刻。采用半隐式（IMEX）积分：把生成/衰减拆成「常数生产项 P」与「线性
# 损失率 L」，损失项隐式求解，因此对任意系数都 **无条件稳定**（单调趋近均衡，不会
# 因硬上限 clamp 出现横跳）：
#   tn            = clamp((temp - temp_lo) / (temp_hi - temp_lo), 0, 1)
#                   # temp / temp_lo / temp_hi 均使用地图气候归一化单位 [0,1]
#   m             = moisture                          # 已是 [0,1]
#   gen_climate   = gen_base   + gen_temp*tn   + gen_moisture*m
#   decay_climate = decay_base + decay_temp*tn + decay_moisture*m
#   P             = gen_climate + gen_self - decay_climate
#   L             = max(0, decay_self)
#   reserve_ext   = max(0, reserve + extra_change)
#   reserve'      = max(0, (reserve_ext + P) / (1 + L))
# 当 P > 0 且 decay_self > 0 时，均衡点 reserve* = P / decay_self。extra_change 为
# 每地块每资源的外部一次性增减量；自然资源 pass 先应用一次再清零。dt_days>1 时
# 只对自然 P/L 做闭式 catchup，不会把外部变化乘以 stride。
#
# 初始储量（map generation，仅 bake 时一次）—— 多因子「地块自身情况」直接资源量。
# `init_*` 系数不是 0..1 百分比；它们直接相加成每 cell 的资源储量单位。
# 由 MapGenerator._bootstrap_natural_resource_deposits 计算（仅 GDScript，无 C++ 副本）：
#   suit = init_base + init_temp*tn + init_moisture*m
#        + init_elevation * clamp(elevation, 0, 1)
#        + init_landform_weights[landform]            # 字典缺省 0
#        + init_vegetation_weights[vegetation]        # 字典缺省 0
#        + init_river   * (has_river 或 is_lake_seed ? 1 : 0)
#        + init_volcano * (has_volcano ? 1 : 0)
#        + init_noise   * noise01(cell_pos, init_noise_scale)   # noise01 ∈ [0,1]
#        + init_province * 2*(province01(family)-0.55)
#        + init_belt     * 2*(ridge(family)-0.72)
#   reserve0 = max(0, suit) * init_reserve_scale
#              * ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
#                                                     # habitat 不匹配时为 0
# 可选 `init_excluded_terrain_ids/init_excluded_vegetation_ids` 在 habitat 之后进一步排除
# 某些地形/植被（例如林木排除沙漠/寒漠/极旱荒漠）。可选 `init_floor_reserve` 对剩余
# 有效 habitat 地块提供逐格基础储量，和 `init_min_coverage/init_min_reserve` 的「最适生
# 前 N% 保底」语义分离，适合表达“广泛存在但区域丰度不同”的资源。
# 可选 `init_min_coverage/init_min_reserve` 在每种资源完成全图 suit 计算后，按 suit
# 降序选择最适宜的前 N 个有效 habitat 地块并确保最低储量。它用于防止有限地图因连续
# 噪声/地质场截断而整图缺失关键资源；默认 0，不影响未配置资源，也不会随机均匀撒矿。
# 斑块化技巧（矿脉/油田）：负 base + 资源局部 noise + 同族地质省/矿带；共享场中心化，
# 省外和矿带外会压低储量，避免每个陆地地块集齐大多数矿种。
# 可选生态适宜度（作物/多年生/动物资源）：默认 init_climate_fit=0 且
# runtime_climate_fit_weight=0，不改变旧资源行为。
#   temp_fit     = 1 - clamp(abs(tn - climate_temp_opt) / climate_temp_tol, 0, 1)
#   moisture_fit = 1 - clamp(abs(m - climate_moisture_opt) / climate_moisture_tol, 0, 1)
#   climate_fit  = temp_fit * moisture_fit
#   suit += init_climate_fit * climate_fit
# 运行期可用 runtime_climate_fit_weight 让 gen_self 随适宜度减弱，并用 decay_stress 表达
# 干旱、过冷、过热、过湿造成的自然衰退：
#   runtime_fit = lerp(1, climate_fit, runtime_climate_fit_weight)
#   P += gen_self * runtime_fit - decay_stress * (1 - runtime_fit)
# 所有新因子默认 0 / {} → 不设置时行为与旧「仅温度+湿度」公式完全一致（向后兼容）。
#
# 动物等种群型资源可选用密度制约生态模型（ecology_capacity > 0）：
#   runtime_capacity = ecology_capacity * runtime_fit
#   seeded           = reserve + ecology_immigration * runtime_fit
#   growth_factor    = 1 + ecology_growth_rate * runtime_fit
#   reserve'         = growth_factor * seeded /
#                      (1 + (growth_factor - 1) * seeded / runtime_capacity)
#   acute_stress     = clamp((0.25 - raw_climate_fit) / 0.25, 0, 1)
#   reserve'        /= 1 + ecology_stress_mortality_rate * acute_stress
# Ordinary suboptimal habitat is already represented by the lower carrying
# capacity; explicit stress mortality is reserved for acutely unsuitable climate.
# 这是离散 Beverton-Holt 增长：低密度自然恢复，接近承载量时增长趋零，超过承载量
# 时自然下降；迁入项允许被开采到 0 的适生地缓慢恢复。dt_days 逐日迭代该非线性式，
# external extra_change 仍只在第一天前应用一次。静态大矿床无法用 float32 表示的小额变化
# 会保留在 extra_change 中跨周期累计。默认 capacity=0 保留上述 IMEX 公式。
#
# One .tres per resource, collected by ResourceProfileRegistry.

class_name ResourceProfile
extends Resource

# ─── Identity ───────────────────────────────────────────────────────────

@export var id: StringName = &""              # 稳定标识，如 &"timber"
@export var display_name: String = ""         # UI 显示名（中文）
@export var icon: Texture2D = null            # UI 图标（可空）
## Deposits always exist physically. These tags only control whether a cell's
## deposit is visible; extractor buildings carry separate availability tags.
@export var discovery_technology_tags: PackedStringArray = PackedStringArray()

# ─── Storage binding ────────────────────────────────────────────────────
# 必须等于 component_schema.gd 中本资源储量字段的 `name`（dot 命名），
# 如 &"cell.res_timber_reserve"。Registry 据此查表得到 C++ slot 名与 MapData 字段名。
@export var reserve_component: StringName = &""

## legacy preserves old profiles while generated modern content uses the
## explicit habitat contract. `coastal_or_marine` lets one resource exist on
## both shore land and marine water while extractors still consume only their
## own cell's reserve.
@export_enum("legacy", "land", "marine_water", "freshwater", "coastal_land",
	"coastal_or_marine", "any") \
var habitat_mode: String = "legacy"
@export var land_only: bool = true            # legacy compatibility only

# ─── Formula input normalization ────────────────────────────────────────
@export_range(0.0, 1.0, 0.01) var temp_lo: float = 0.0 # 地图气候温度下界 [0,1]
@export_range(0.0, 1.0, 0.01) var temp_hi: float = 1.0 # 地图气候温度上界 [0,1]

# ─── Generation coefficients ────────────────────────────────────────────
@export var gen_base: float = 0.0
@export var gen_temp: float = 0.0
@export var gen_moisture: float = 0.0
@export var gen_self: float = 0.0             # >0 → 常数自然补充项（可受 climate_fit 调制）

# ─── Decay coefficients ─────────────────────────────────────────────────
@export var decay_base: float = 0.0
@export var decay_temp: float = 0.0
@export var decay_moisture: float = 0.0
@export var decay_self: float = 0.0           # >0 → 线性自然损失率；平衡点约为 P / decay_self

# ─── Initial deposit coefficients (map generation only) ─────────────────
@export var init_base: float = 0.0
@export var init_temp: float = 0.0
@export var init_moisture: float = 0.0
## Content-level abundance multiplier applied after suitability is resolved.
## It changes deposit quantity without changing deposit presence or topology.
@export_range(0.1, 100.0, 0.1) var init_reserve_scale: float = 1.0
## TerrainType.TERRAIN ids excluded after habitat filtering during bootstrap.
## Empty by default for backward compatibility.
@export var init_excluded_terrain_ids: PackedInt32Array = PackedInt32Array()
## VegetationType.VEG ids excluded after habitat filtering during bootstrap.
## Empty by default for backward compatibility.
@export var init_excluded_vegetation_ids: PackedInt32Array = PackedInt32Array()
## Minimum reserve for every non-excluded valid habitat cell. This is separate
## from init_min_coverage/init_min_reserve, which only boosts the best cells.
@export_range(0.0, 10000000.0, 1.0) var init_floor_reserve: float = 0.0
@export_range(0.0, 1.0, 0.001) var init_min_coverage: float = 0.0
@export_range(0.0, 100000000.0, 1.0) var init_min_reserve: float = 0.0
## Exact share of valid habitat retained as deposits. Unlike
## init_min_coverage, this is both a floor and a cap; 0 keeps legacy behavior.
@export_range(0.0, 1.0, 0.001) var init_target_coverage: float = 0.0
## World reserve density per valid habitat cell before CELL_AREA_RESOURCE_SCALE.
## When positive together with init_target_coverage, bootstrap normalizes total
## reserve to valid_cell_count * this value * cell-area scale. Coverage can
## therefore change concentration without accidentally changing world supply.
@export_range(0.0, 100000000.0, 1.0) var init_target_reserve_density: float = 0.0
## Optional retained-deposit mean for resources whose total should follow
## occupied habitat rather than whole-world habitat (for example fisheries).
## Mineral profiles should prefer init_target_reserve_density.
@export_range(0.0, 100000000.0, 1.0) var init_target_mean_reserve: float = 0.0
## Shapes enrichment inside the retained region without changing its coverage
## or total reserve. Values above 1 concentrate more reserve in the best cells.
@export_range(0.1, 8.0, 0.1) var init_richness_exponent: float = 1.0
## Additional dispersed small/micro deposits outside the enriched core.
## Their reserve is carved out of the same world total rather than added to it.
@export_range(0.0, 1.0, 0.001) var init_micro_coverage: float = 0.0
@export_range(0.0, 0.5, 0.001) var init_micro_reserve_share: float = 0.0
@export_range(0.0, 100000000.0, 1.0) var init_micro_min_reserve: float = 0.0

# ─── 扩展初始储量因子（「地块自身情况」，map generation 仅一次）──────────
# 默认 0 / {} → 不参与，保持与旧公式逐位一致（向后兼容）。
@export var init_elevation: float = 0.0          # × clamp(elevation,0,1)（矿/石偏高地用正、沉积偏低地用负）
@export var init_river: float = 0.0              # 河流或湖泊地块加成（淡水/黏土/野味偏好水边）
@export var init_volcano: float = 0.0            # 火山地块加成（地热）
@export var init_ocean_current: float = 0.0       # × clamp(length(ocean_current),0,1)
@export var init_upwelling: float = 0.0           # × clamp(upwelling_strength,0,1)
@export var init_estuary: float = 0.0             # × 河口及其近岸营养扩散强度
# 地貌权重表：键 = LandformType.LF 序号(int)，值 = 适宜度加权。未列出的地貌按 0 计。
@export var init_landform_weights: Dictionary = {}
# 植被权重表：键 = VegetationType.VEG 序号(int)，值 = 适宜度加权。未列出的植被按 0 计。
@export var init_vegetation_weights: Dictionary = {}
# 空间噪声斑块化（矿脉/油田）：init_noise = 峰值权重，init_noise_scale = 频率（越大斑块越碎）。
@export var init_noise: float = 0.0
@export var init_noise_scale: float = 0.05
## Shared low-frequency province and ridge fields correlate deposits in the
## same geological family; init_noise remains the resource-local patch field.
@export var geology_family_id: StringName = &""
@export var init_province: float = 0.0
@export var init_province_scale: float = 0.012
@export var init_belt: float = 0.0
@export var init_belt_scale: float = 0.035

# ─── Optional climate suitability (bootstrap + daily pass) ───────────────
# climate_*_opt/tol 作用在归一化后的 tn/moisture 上。
@export var climate_temp_opt: float = 0.5
@export var climate_temp_tol: float = 1.0
@export var climate_moisture_opt: float = 0.5
@export var climate_moisture_tol: float = 1.0
@export var init_climate_fit: float = 0.0
@export var runtime_climate_fit_weight: float = 0.0
@export var decay_stress: float = 0.0

# ─── Optional density-dependent ecology dynamics ────────────────────────
@export_range(0.0, 1000000.0, 1.0) var ecology_capacity: float = 0.0
@export_range(0.0, 1.0, 0.001) var ecology_growth_rate: float = 0.0
@export_range(0.0, 1000.0, 0.01) var ecology_immigration: float = 0.0
@export_range(0.0, 1.0, 0.001) var ecology_stress_mortality_rate: float = 0.0
