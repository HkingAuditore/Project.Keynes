# 需求文档 — 风场与洋流的物理化（六边形精度）

## 引言

当前游戏的风场（[`_bake_wind_field`](Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd)）和洋流场（[`bake_ocean_currents_slice`](Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd)）都是**按像素逐点求值的纯纬度函数 + 微弱地形修正**：

- 风向只取决于 `ny`（[`WindBelt.wind_at`](Project.Keynes/Project/project-keynes/scripts/wind_belt.gd)），陆地存在不会反馈到风场；
- 洋流 = 风向 ⊕ Ekman ±45° + 海岸高度梯度 ×4 + 噪声 0.30，没有海盆闭合环流，没有西边界强化；
- 因此整张图呈现明显的水平条带，方向虽符合教科书，但与陆海/地形毫无视觉关联。

本次改造的目标：**让风与洋流从"一维纬度场"升级为"二维海陆耦合 + 海盆环流"的物理化简化模型**，在视觉与逻辑上都能体现：

1. 大陆季节性高低压（西伯利亚高压、阿留申低压等量级特征）；
2. 真正的地转风偏转、海陆季风的强弱不对称；
3. 海盆闭合环流 + 西边界强化（黑潮/湾流型东岸暖流、加州/秘鲁型东岸冷流）；
4. 沿岸 Ekman 抽吸与上升流位置由风+海岸朝向自然涌现，而非纯纬度阈值。

**性能约束**：现有按像素的烘焙路径已经成为切片化任务（[`OceanCurrentsJob`](Project.Keynes/Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd)），但在物理求解层做像素级求解不现实。本次明确**把核心物理求解器放在六边形格子（hex cell）上**——求解后再光栅化为 `wind_field_buffer` / `ocean_current_buffer` 等下游消费方需要的纹理。六边形规模通常比像素少 1~2 个数量级（典型 `derived_size` 数十万像素 vs 数千~数万 hex），求解成本可控。

**精度边界**：
- 物理求解只需到 hex 中心粒度；
- 像素 buffer 由 hex 场双线性 / 重心插值生成，保持 shader 视觉连续；
- 下游 [`HexCell.wind_vector`](Project.Keynes/Project/project-keynes/scripts/hex_cell.gd) / [`HexCell.ocean_current`](Project.Keynes/Project/project-keynes/scripts/hex_cell.gd) / [`HexCell.upwelling_strength`](Project.Keynes/Project/project-keynes/scripts/hex_cell.gd) 直接由 hex 求解器写出，省掉 [`_compute_ocean_currents`](Project.Keynes/Project/project-keynes/scripts/map_generator.gd) 的"像素回采到 hex"绕圈。

**复用优先**：现有 `OceanCurrentsJob`、[`SusScheduler`](Project.Keynes/Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd)、[`ClimateProfile`](Project.Keynes/Project/project-keynes/scripts/data/climate_profile.gd)、[`MapBaker`](Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd) 的 pending/commit 双缓冲机制全部保留；新算法以**替换烘焙函数内部实现**为主，不新增子系统或调度器。`WindBelt.wind_at` 保留作为"理论纬度基线"，求解器把它当初值/边界条件用，而不是直接输出。

---

## 需求

### 需求 1：六边形级海陆压力场

**用户故事：** 作为一名玩家，我希望大陆中心和海洋之间能形成季节性高/低压差异，以便在地图上看出"夏天大陆是热低压、冬天大陆是冷高压"这种现实地球级别的特征，并让风场围绕这些压力中心组织起来。

#### 验收标准

1. WHEN 系统执行 `bake_world` 或洋流/风场重烤 THEN 系统 SHALL 在 hex 域上为每个 cell 计算一个标量 `slp` (sea level pressure proxy, 单位 hPa 偏差或归一化 [-1, 1])，存储在 `HexCell` 上（新字段 `cell.slp` 或复用现有 air pressure 字段）。
2. WHEN 计算 `slp` THEN 系统 SHALL 同时考虑：(a) 纬度基线（赤道低压、副热带高压、副极地低压、极地高压）；(b) 海陆性质（陆地夏季降压、冬季升压；幅度按 `season_phase` 和当地 `lat_temp` 调制）；(c) 大陆性（远离海岸的内陆 cell 海陆效应更强，沿海 cell 更接近海洋基线）。
3. WHEN `season_phase` 变化（每个 SUS 洋流刷新周期开头） THEN 系统 SHALL 重新计算 `slp` 场，使夏冬大陆压力中心位置可见反转。
4. IF 某个 cell 是水域 THEN `slp` SHALL 主要取自纬度基线 + 弱季节调制，避免被周围陆地拖拽产生伪压力中心。
5. WHEN `slp` 计算完成 THEN 系统 SHALL 对其在 hex 邻域上做 1~3 次扩散平滑（box/diamond filter），消除单格噪点，让压力中心呈现连贯的等压区。

---

### 需求 2：地转风 + 海陆季风的物理化风场

**用户故事：** 作为一名玩家，我希望在大陆边缘看到风从高压吹向低压并被科氏力偏转的效应，以便地图上的风带不再是死板的水平条带，而是绕着压力中心弯曲，并体现夏季海风、冬季陆风。

#### 验收标准

1. WHEN 计算每个 hex 的风向 THEN 系统 SHALL 用以下叠加：(a) 纬度基线 = 现有 `WindBelt.wind_at(ny, season_phase)` 输出（仅作 30%~50% 权重的"自由大气"项）；(b) 压力梯度风 = `-∇slp` 在 hex 6 邻域上的有限差分；(c) 科氏偏转 = 北半球右偏、南半球左偏，偏转角随 `|lat_signed|` 从 0°（赤道）到 ~30°~45°（中高纬）非线性增加。
2. WHEN 压力梯度计算 THEN 系统 SHALL 使用 hex 的 6 邻域而非笛卡尔 4 邻域，使用六边形几何对应的离散梯度算子，保证不引入网格各向异性。
3. WHEN 一个陆地 cell 邻接海洋 cell THEN 系统 SHALL 在该 cell 处叠加额外的"海陆季风分量"：夏季吹向陆地、冬季吹离陆地，其幅度与 `slp` 海陆差正相关、与离海距离反相关。
4. WHEN 风向求解完成 THEN 系统 SHALL 同时输出 `cell.wind_vector` (Vector2) 与 `cell.wind_speed` (float, 物理量级)，下游 [`weather_system`](Project.Keynes/Project/project-keynes/scripts/weather_system.gd) advection 直读 hex 字段，不再需要 `WindBelt.monsoon_offset_at` 在 CPU 端二次融合。
5. WHEN 风向 hex 场需要转为像素 `wind_field_buffer` THEN 系统 SHALL 使用现有 [`pixel_to_cell_lookup`](Project.Keynes/Project/project-keynes/scripts/world_data.gd) 直接把 hex 风量化进每个像素（NEAREST 或 hex 重心插值），保留 RG8 编码与现有 shader 接口完全兼容。
6. IF 启用了 `ClimateProfile.enable_terrain_aware_wind` THEN 系统 SHALL 在山地 cell 处对风方向额外做"地形偏转"（背风侧降压、山脊抬升），但该项不得新增独立 buffer，应直接调制 `cell.wind_vector`。

---

### 需求 3：海盆闭合环流 + 西边界强化的物理化洋流

**用户故事：** 作为一名玩家，我希望看到副热带海盆中心出现真正的环形洋流（北半球顺时针、南半球逆时针），并且大陆东岸出现明显比西岸更强的暖流带（黑潮/湾流型），以便游戏的洋流图能直观体现现实世界的环流格局。

#### 验收标准

1. WHEN 系统执行洋流烘焙 THEN 系统 SHALL 在水域 hex 上求解一个 2D 流函数 `psi`（stream function），其源项为风应力旋度 `curl(τ)`，τ ≈ 风速² × 风向单位向量。
2. WHEN 求解 `psi` THEN 系统 SHALL 使用迭代法（Gauss-Seidel / SOR / Jacobi）若干次（例如 30~80 次），把 `∇²psi = -curl(τ) / β`（β-plane 简化）压到稳态；陆地 hex 上 `psi = 0`（边界条件），保证海盆闭合。
3. WHEN 求得 `psi` THEN 系统 SHALL 通过 `u = -∂psi/∂y, v = +∂psi/∂x` 在 hex 上回算流速 `(u, v)`，写入 `cell.ocean_current`。
4. WHEN 求解 `psi` THEN 系统 SHALL 引入 **β-效应西边界强化**：在迭代算子中对水平输运项加一个与 `lat_signed` 相关的非对称系数（Stommel 模型最简形式），使解出的 `psi` 等高线在海盆西岸密集、东岸稀疏，对应西边界流速比东边界大约 3~10 倍。
5. WHEN 海盆 cell 受到风应力 THEN 系统 SHALL 使解的环流方向在副热带（`lat_signed * sl < 0`，即低中纬主体）形成北半球顺时针、南半球逆时针的反气旋；副极地形成相反方向气旋。
6. IF 某海盆 cell 是高纬冷源（`lat_temp` 低于阈值） THEN 系统 SHALL 仍保留现有热盐辅助项作为 `psi` 求解后的 y 方向小幅修正（权重 ≤ 0.2），避免改造前的"高纬冷沉"语义彻底消失。
7. WHEN `cell.ocean_current` 写入完毕 THEN 系统 SHALL 用现有 `pixel_to_cell_lookup` + 切片化逻辑光栅化为 `ocean_current_buffer` (RG8)；像素 buffer 仅作为渲染消费品，不再参与物理求解。
8. WHEN 旧的像素级 `bake_ocean_currents_slice` 内部实现被替换 THEN 系统 SHALL 保留 [`OceanCurrentsJob`](Project.Keynes/Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd) 的 `period_ticks / slice_count / pending+commit` 切片机制：hex 求解只在每轮第一片做一次（一次性 ≤ 期望预算），后续片只做 hex→pixel 光栅化的切片化分块，单片 elapsed_ms 仍 ≤ `slice_budget_ms`（4ms）。

---

### 需求 4：沿岸上升流 / 下沉流由风+海岸朝向涌现

**用户故事：** 作为一名玩家，我希望沿岸上升流（如秘鲁沿岸、加州沿岸、本格拉沿岸）能从风场和海岸朝向自然涌现，以便上升流的位置和强度在不同季节会随风带迁移而变化，而不是死锁在某些纬度阈值上。

#### 验收标准

1. WHEN 系统计算 `cell.upwelling_strength` THEN 系统 SHALL 对每个海岸 hex（与至少 1 个陆地邻居相接）计算 `dot(wind_dir, coast_tangent_along)` × 半球符号 × 风速，作为沿岸 Ekman 抽吸量；正值=上升流、负值=下沉。
2. WHEN 计算 `coast_tangent_along` THEN 系统 SHALL 用海岸 hex 的陆地邻居方向向量之和（取反并旋转 90°）近似海岸切向，避免依赖像素级 8 邻域。
3. IF 某 cell 是高纬冷沉点（保留现有 `_UPWELLING_HIGHLAT_ABS` 阈值语义） THEN 系统 SHALL 把高纬下沉作为**额外叠加项**写入 `cell.upwelling_strength`，与沿岸抽吸合成。
4. WHEN `cell.upwelling_strength` 计算完毕 THEN 系统 SHALL 用现有 `pixel_to_cell_lookup` 光栅化到 `ocean_upwelling_buffer` (R8)，与现有 shader / 海冰逻辑零改动对接。

---

### 需求 5：性能预算与切片化

**用户故事：** 作为一名开发者，我希望物理化求解不会让单日 SUS tick 卡顿，以便玩家在快速推日时仍能保持稳定帧率。

#### 验收标准

1. WHEN `OceanCurrentsJob` 执行一轮（period_ticks=60 天，slice_count=60 片） THEN 单片 `elapsed_ms` SHALL ≤ 5ms（与现有 4ms 预算同量级，给迭代求解器留 25% buffer）。
2. WHEN 系统进行 hex 域物理求解 THEN 求解器 SHALL 把工作切分为：(a) `slp` 场计算（O(N_hex)）；(b) `psi` 迭代求解（O(N_iter × N_water_hex)）；(c) hex→pixel 光栅化（O(N_pixel)）。前两步合计单轮 ≤ 50ms（一次性，分摊到第一个 slice 或自身切片）；第三步直接复用并贴合现有 slice_count 切片节奏。
3. IF `psi` 迭代单次预算不足 THEN 系统 SHALL 支持把迭代分散到多个 slice（例如 60 个 slice 每片做 1~2 轮 SOR），保证一年 / 一个 period_ticks 内自然收敛。
4. WHEN hex 数量在常规地图（数千~一万左右）下 THEN 完整一轮（slp + psi + 光栅化） SHALL 在主线程占用 ≤ 300ms 总时间（分摊到 60 片，约 5ms/片）。
5. WHEN 项目启用 `ClimateProfile.enable_ocean_heat_transport = false` THEN 系统 SHALL 跳过 `psi` 求解，直接用纬度基线写出 hex `ocean_current`，保留旧"零成本"路径作为低端硬件 fallback。
6. WHEN 求解器启动 THEN 系统 SHALL 复用现有 `pixel_to_cell_lookup` / `water_cell_pixel_lists` / `cell_pixel_lists`，不引入新的全图反向索引；六边形邻接信息直接走 [`HexUtils.CUBE_DIRECTIONS`](Project.Keynes/Project/project-keynes/scripts/hex_utils.gd) + `MapData.get_cell_by_cube`。

---

### 需求 6：可调试 / 可观测 / 可回退

**用户故事：** 作为一名开发者，我希望能在游戏内 overlay 直接看到 `slp` 场、风应力旋度、`psi` 等高线，以便快速验证物理求解是否符合预期，并保留旧算法路径以便对照。

#### 验收标准

1. WHEN 我打开 overlay 调试界面 THEN 系统 SHALL 暴露至少 3 个新调试 overlay：`SLP`（海平面气压）、`WIND_STRESS_CURL`（风应力旋度）、`OCEAN_PSI`（流函数等高线），它们 SHALL 走现有 [`OverlayMode`](Project.Keynes/Project/project-keynes/scripts/rendering/overlay_mode.gd) + [`data_overlay_baker`](Project.Keynes/Project/project-keynes/scripts/rendering/data_overlay_baker.gd) 路径，不新增渲染管线。
2. WHEN `ClimateProfile.physical_circulation_enabled = false` THEN 系统 SHALL 走旧的 ny-only `WindBelt.wind_at + Ekman ±45°` 路径，方便回归对照（默认值开启新算法）。
3. WHEN 求解器报告 `psi` 迭代残差 THEN 系统 SHALL 把残差打印到日志（每轮一次），方便观察是否收敛。
4. IF 物理化算法在某次烤制中产生 NaN / Inf THEN 系统 SHALL 在 commit 前检测并自动回退到 `WindBelt.wind_at + Ekman ±45°` 路径，确保游戏不崩。

---

## 边界条件与风险记录

- **存档兼容**：新增的 `cell.slp` / `cell.wind_speed` 等字段需要在 [`HexCell`](Project.Keynes/Project/project-keynes/scripts/hex_cell.gd) 上声明默认值，老存档加载时自动初始化为 0；下游 weather/overlay 对新字段缺失要有兜底。
- **下游耦合**：[`weather_system`](Project.Keynes/Project/project-keynes/scripts/weather_system.gd) 当前依赖 `WindBelt.monsoon_offset_at` 做 CPU 端融合，本次需求改为它直接读 `cell.wind_vector`，需要核对 advection 调用路径。
- **shader 兼容**：`wind_field_buffer` / `ocean_current_buffer` 编码与采样格式（RG8、`vector_atlas_tex` BA/RG 通道）必须保持，shader 端零改动。
- **不在本次范围**：3D 多层洋流、Ekman 螺旋、潮汐、Madden-Julian 振荡等真正的高阶气候动力学不做。这是一份"工程级简化物理"，核心目的是让风/洋流可见地受陆海与地形影响，并涌现出黑潮/湾流型东岸强流。
