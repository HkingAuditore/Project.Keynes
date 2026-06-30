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
# 初始储量（map generation，仅 bake 时一次）：
#   suitability = clamp(init_base + init_temp*tn + init_moisture*m, 0, 1)
#   reserve0    = capacity * suitability          # land_only 时水面格为 0
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
