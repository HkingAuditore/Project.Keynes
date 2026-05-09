# 实施计划

- [ ] 1. HexCell 字段与 ClimateProfile 开关扩展
  - 在 [`HexCell`](Project.Keynes/Project/project-keynes/scripts/hex_cell.gd) 上新增 `slp: float = 0.0`、`wind_speed: float = 0.0`、`wind_stress_curl: float = 0.0`、`ocean_psi: float = 0.0` 四个字段，注释说明物理意义并保证老存档默认值为 0
  - 在 [`ClimateProfile`](Project.Keynes/Project/project-keynes/scripts/data/climate_profile.gd) 上新增三个 `@export` 开关：`physical_circulation_enabled: bool = true`、`enable_terrain_aware_wind: bool = true`、`enable_ocean_heat_transport: bool = true`，并写明默认值与回退路径含义
  - _需求：1.1, 5.5, 6.2_

- [ ] 2. 海陆压力（SLP）求解器
  - 在 [`MapBaker`](Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd) 新增私有方法 `_solve_slp_field(map, season_phase) -> void`，按 hex 计算 SLP = 纬度基线（赤道低/副热带高/副极地低/极地高）+ 海陆性 × 季节调制（用 `cell.lat_temp` 与 `season_phase` 推导陆地夏低冬高），写入 `cell.slp`
  - 用 `MapData.get_cell_by_cube` + `HexUtils.CUBE_DIRECTIONS` 在 hex 6 邻域上做 1~3 次扩散平滑；水域 cell 平滑权重高（更趋近纬度基线），陆地 cell 保留更多大陆性差
  - _需求：1.1, 1.2, 1.3, 1.4, 1.5_

- [ ] 3. 物理化风场 hex 求解器
  - 在 `MapBaker` 新增 `_solve_wind_field_hex(map, season_phase) -> void`，对每个 cell 叠加：纬度基线 (`WindBelt.wind_at` 权重 0.3~0.5) + 压力梯度风 (`-∇slp` 在六边形 6 邻域上的离散梯度，使用六边形几何对应的方向向量) + 科氏偏转（北半球右偏南半球左偏，偏转角随 `|lat_signed|` 非线性增加）
  - 对海岸陆地 cell 叠加海陆季风分量（夏季向陆、冬季离陆，幅度 ∝ slp 海陆差，∝ 1/沿陆距离）
  - 当 `enable_terrain_aware_wind` 启用且 cell 是山地 → 对结果向量做地形偏转修正（不新建 buffer）
  - 输出写入 `cell.wind_vector`（单位向量）和 `cell.wind_speed`（物理量级）
  - _需求：2.1, 2.2, 2.3, 2.4, 2.6_

- [ ] 4. 风应力旋度 + 流函数（ψ）海盆求解器
  - 在 `MapBaker` 新增 `_solve_ocean_psi(map) -> void`：先计算每个水域 cell 的风应力 τ = wind_speed² × wind_dir，再用六边形 curl 算子求 `cell.wind_stress_curl`
  - 用 SOR（Successive Over-Relaxation）迭代解 `∇²ψ = -curl(τ) / β` 到稳态，β-plane 简化系数与 `lat_signed` 相关；陆地 hex 边界 `ψ = 0`
  - 在迭代算子中对水平输运项加非对称系数（Stommel 西边界强化），使解的等高线在西岸密集；记录残差日志
  - _需求：3.1, 3.2, 3.4, 5.2, 5.3, 6.3_

- [ ] 5. ψ → hex 流速 + 副极地 / 高纬热盐叠加
  - 在 `MapBaker` 新增 `_psi_to_ocean_current(map) -> void`：用 `u = -∂ψ/∂y, v = ∂ψ/∂x`（六边形差分）回算每个水域 cell 的 `cell.ocean_current`
  - 验证副热带海盆方向：北半球反气旋顺时针、南半球反气旋逆时针；副极地相反
  - 对 `lat_temp` 低于 `_UPWELLING_HIGHLAT_ABS` 阈值的高纬冷源 cell，叠加现有热盐 y 方向小幅修正（权重 ≤ 0.2）
  - _需求：3.3, 3.5, 3.6_

- [ ] 6. 沿岸 Ekman 上升流（hex 域）
  - 在 `MapBaker` 新增 `_solve_upwelling_hex(map) -> void`：对每个海岸 cell（至少 1 个陆地邻居）计算 `coast_tangent = rotate90(-Σ land_neighbor_dir)`
  - `cell.upwelling_strength = dot(wind_dir, coast_tangent) × hemisphere_sign × wind_speed` 作为沿岸 Ekman 抽吸主项
  - 高纬冷沉点保留旧阈值语义作为额外叠加项
  - _需求：4.1, 4.2, 4.3_

- [ ] 7. hex → pixel 光栅化路径替换
  - 改造 [`_bake_wind_field`](Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd) 与 `bake_ocean_currents_slice`：当 `physical_circulation_enabled=true`，跳过原 ny-only 求值，改用 `pixel_to_cell_lookup` 直接把 `cell.wind_vector` / `cell.ocean_current` 量化为 RG8 写入 `wind_field_buffer` / `ocean_current_buffer`
  - `cell.upwelling_strength` 用 `pixel_to_cell_lookup` 写入 `ocean_upwelling_buffer` (R8)
  - 保留原算法分支作为 `physical_circulation_enabled=false` 的 fallback；切片化写入仍按现有 `slice_count / slice_budget_ms` 节奏
  - _需求：2.5, 3.7, 4.4, 5.5, 6.2_

- [ ] 8. OceanCurrentsJob 调度集成（hex 求解 + 切片光栅化）
  - 调整 [`OceanCurrentsJob`](Project.Keynes/Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd)：每个 period 第一片调用任务 2~6 的 hex 求解器（按预算分摊：slp+wind 在 slice 0、ψ 迭代分散到 slice 0~N/2、upwelling 在 slice N/2、其余 slice 做光栅化）
  - 单片严格遵守 `slice_budget_ms ≤ 5ms`；ψ 迭代每片 1~2 轮 SOR，一年内自然收敛
  - commit 阶段调用现有 `_compute_ocean_currents` → 改为直接信任 `cell.ocean_current`（已由 hex 求解器写出，跳过像素回采）
  - _需求：3.8, 5.1, 5.2, 5.3, 5.4, 5.6_

- [ ] 9. weather_system 与 shader 兼容核对 + NaN 守门
  - 核对 [`weather_system`](Project.Keynes/Project/project-keynes/scripts/weather_system.gd) 的 advection 路径：移除 `WindBelt.monsoon_offset_at` 在 CPU 端的二次融合，改为直读 `cell.wind_vector`；保证开关关闭时仍兼容旧路径
  - 在 commit 前对 `cell.wind_vector / cell.ocean_current / cell.slp` 做 NaN/Inf 扫描，发现异常自动回退到 `WindBelt.wind_at + Ekman ±45°` 路径并打印告警
  - 验证 shader 端 `wind_field_buffer` / `ocean_current_buffer` 编码格式（RG8、`vector_atlas_tex` 通道映射）零改动
  - _需求：2.4, 6.4, 边界条件: 下游耦合 / shader 兼容_

- [ ] 10. Overlay 调试支持
  - 在 [`OverlayMode`](Project.Keynes/Project/project-keynes/scripts/rendering/overlay_mode.gd) 新增三个枚举值：`SLP`、`WIND_STRESS_CURL`、`OCEAN_PSI`
  - 在 [`data_overlay_baker`](Project.Keynes/Project/project-keynes/scripts/rendering/data_overlay_baker.gd) 增加对应的 `cell.slp` / `cell.wind_stress_curl` / `cell.ocean_psi` 渲染分支（颜色映射用现成的 viridis/coolwarm 渐变工具），不新增渲染管线
  - _需求：6.1_

