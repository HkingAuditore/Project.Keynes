extends RefCounted
class_name DCWindHeatTransport

## Phase 3.3（master 手册 §6.4 - 被遗漏依赖项）：风温耦合 / 气团温度异常输运。
##
## **当前状态**：stub —— 函数体待从 map_generator.gd 整体搬迁。
##
## 拆出原因：风温耦合是"洋流热输运"的对称模块（air_mass_temp_anomaly 对应
## temperature_transport_anomaly），但实施过程中被遗漏在 map_generator.gd
## 主体里（line ~6610-6700，~90 行）。Phase 3.3 拆分时与 ocean/water_pass 和
## ocean/land_pass 同源处理，否则会出现：
##   simulation/ocean/*.gd 是 ocean 热输运
##   simulation/climate/wind_heat_transport.gd 是 wind/air 热输运
## 二者拆出后 climate pass_b 才能彻底脱离 map_generator.gd。
##
## ─── 待搬迁函数清单（master 手册 §6.4 PR-3.3.X 候选）─────────────
##
## - `_apply_wind_heat_transport_pass(map, cfg, season_phase)`        (~90 行)
##     沿 -wind_vector 方向回溯上游气团温度，混合后写入：
##       cell.air_mass_temp_anomaly       — 气团温度偏差
##       cell.temperature                 — 受耦合后的最终气温
##
## - 输入要求：
##     wind_vector / wind_speed 已由 PhysicalCirculationSolver.solve_wind_field 写入
##     temp_baseline / temperature 已由 climate_pass_a 写入
##
## - 输出语义：与 ocean.water_pass 对称（参考 docs/dots-master-execution-handbook.md §3.10.5）
##
## ─── 拆分原则 ──────────────────────────────────────────────────
## 1. 接收 (map, cfg, season_phase) 三参，不持有 generator 弱引用
## 2. 写入路径走 world.write_f32_indexed（PR-2.1.x 已就位）
## 3. C++ 化 hook：未来可加 use_gdext_wind_heat_transport flag（charter §7 P3）
##
## 当前文件保留为占位；具体 static func 在 PR-3.3.X 引入。

# 占位：实际 static func 等迁移过来
