# resource_profile.gd
# Data-driven definition of a single natural resource type.
#
# Single source of truth for:
#   - identity (id + display name + icon)
#   - storage binding: which per-cell DataCore component holds this resource's
#     reserve (reserve_component, e.g. &"cell.res_biomass_reserve")
#   - capacity: per-resource scalar cap; the reserve is clamped to [0, capacity]
#   - generation / decay formula coefficients (fixed template, see below)
#   - initial deposit coefficients (used at map generation)
#
# Unified model: 可再生 / 不可再生 资源不分两种类型，差异完全由系数表达。
#   - 可再生（如 biomass）：gen_self > 0 → 趋近 capacity 的 logistic 增长。
#   - 不可再生（如 iron_ore）：gen_* ≈ 0（无自然再生），仅靠后续开采系统消耗。
#
# 每 tick（per cell）公式模板，由 C++ run_natural_resource_pass / GDScript fallback
# 严格 1:1 复刻。采用半隐式（IMEX）积分：把生成/衰减拆成「常数生产项 P」与「线性
# 损失率 L」，损失项隐式求解，因此对任意系数都 **无条件稳定**（单调趋近均衡，不会
# 过冲，也不会在 0↔capacity 之间横跳）：
#   tn            = clamp((temp - temp_lo) / (temp_hi - temp_lo), 0, 1)
#   m             = moisture                          # 已是 [0,1]
#   gen_climate   = gen_base   + gen_temp*tn   + gen_moisture*m
#   decay_climate = decay_base + decay_temp*tn + decay_moisture*m
#   P             = gen_climate + gen_self - decay_climate          # 净常数生产项（可负）
#   L             = capacity > 0 ? max(0, (gen_self + decay_self) / capacity) : 0
#   reserve'      = clamp((reserve + P) / (1 + L), 0, capacity)
# 均衡点 reserve* = capacity * P / (gen_self + decay_self)，与旧显式 Euler 一致；L 小时
# 1/(1+L) ≈ 1 - L，行为与旧式近似。注意：自系数极大（如 (gen_self+decay_self)/capacity ≥ 2）
# 时旧显式 Euler 会发散横跳，本半隐式则始终平滑收敛。
#
# 初始储量（map generation，仅 bake 时一次）—— 多因子「地块自身情况」适宜度。
# 由 MapGenerator._bootstrap_natural_resource_deposits 计算（仅 GDScript，无 C++ 副本）：
#   suit = init_base + init_temp*tn + init_moisture*m
#        + init_elevation * clamp(elevation, 0, 1)
#        + init_landform_weights[landform]            # 字典缺省 0
#        + init_vegetation_weights[vegetation]        # 字典缺省 0
#        + init_river   * (has_river 或 is_lake_seed ? 1 : 0)
#        + init_volcano * (has_volcano ? 1 : 0)
#        + init_noise   * noise01(cell_pos, init_noise_scale)   # noise01 ∈ [0,1]
#   reserve0 = capacity * clamp(suit, 0, 1)           # land_only 时水面格为 0
# 斑块化技巧（矿脉/油田）：负的 init_base + 正的 init_noise → 只在噪声峰值处出露稀疏矿脉。
# 所有新因子默认 0 / {} → 不设置时行为与旧「仅温度+湿度」公式完全一致（向后兼容）。
#
# One .tres per resource, collected by ResourceProfileRegistry.

class_name ResourceProfile
extends Resource

# ─── Identity ───────────────────────────────────────────────────────────

@export var id: StringName = &""              # 稳定标识，如 &"biomass"
@export var display_name: String = ""         # UI 显示名（中文）
@export var icon: Texture2D = null            # UI 图标（可空）

# ─── Storage binding ────────────────────────────────────────────────────
# 必须等于 component_schema.gd 中本资源储量字段的 `name`（dot 命名），
# 如 &"cell.res_biomass_reserve"。Registry 据此查表得到 C++ slot 名与 MapData 字段名。
@export var reserve_component: StringName = &""

@export var capacity: float = 1.0             # per-resource 储量上限
@export var land_only: bool = true            # true = 仅陆地格生成 / 演化（水面格保持 0）

# ─── Formula input normalization ────────────────────────────────────────
@export var temp_lo: float = -30.0            # 温度归一化下界（摄氏）
@export var temp_hi: float = 40.0             # 温度归一化上界（摄氏）

# ─── Generation coefficients ────────────────────────────────────────────
@export var gen_base: float = 0.0
@export var gen_temp: float = 0.0
@export var gen_moisture: float = 0.0
@export var gen_self: float = 0.0             # >0 → logistic（趋近 capacity 增长变慢）

# ─── Decay coefficients ─────────────────────────────────────────────────
@export var decay_base: float = 0.0
@export var decay_temp: float = 0.0
@export var decay_moisture: float = 0.0
@export var decay_self: float = 0.0           # >0 → 衰减与储量成正比

# ─── Initial deposit coefficients (map generation only) ─────────────────
@export var init_base: float = 0.0
@export var init_temp: float = 0.0
@export var init_moisture: float = 0.0

# ─── 扩展初始储量因子（「地块自身情况」，map generation 仅一次）──────────
# 默认 0 / {} → 不参与，保持与旧公式逐位一致（向后兼容）。
@export var init_elevation: float = 0.0          # × clamp(elevation,0,1)（矿/石偏高地用正、沉积偏低地用负）
@export var init_river: float = 0.0              # 河流或湖泊地块加成（淡水/黏土/野味偏好水边）
@export var init_volcano: float = 0.0            # 火山地块加成（地热）
# 地貌权重表：键 = LandformType.LF 序号(int)，值 = 适宜度加权。未列出的地貌按 0 计。
@export var init_landform_weights: Dictionary = {}
# 植被权重表：键 = VegetationType.VEG 序号(int)，值 = 适宜度加权。未列出的植被按 0 计。
@export var init_vegetation_weights: Dictionary = {}
# 空间噪声斑块化（矿脉/油田）：init_noise = 峰值权重，init_noise_scale = 频率（越大斑块越碎）。
@export var init_noise: float = 0.0
@export var init_noise_scale: float = 0.05
