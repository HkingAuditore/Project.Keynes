# 需求文档 — True Insolation-Driven Climate（太阳辐照驱动的真涌现气候）

## 引言

在上一轮 `emergent-climate-coupling` 落地后，系统已经具备"逐日连续刷新 + 局部耦合 + 海冰逐日推进 + 快慢分层 + 一键回退"的基础设施。但回到玩家和模拟爱好者关心的本质问题——**"季节是不是因为太阳直射点变化所自发涌现的"**——答案仍然是**否**：

- `season_phase` 由 `day / days_per_season` 直接产生，是**时间计数器**，不是天文量。
- `refresh_climate_daily` 计算温度偏移时走的是 `_season_temp_offset_phase` 独立余弦公式，绕过了 `_compute_insolation`。
- `_compute_insolation` 目前仅被 `_insolation_temp_offset` 调用，而 `_insolation_temp_offset` 本身无调用点，相当于**死代码**。
- 温度、湿度、海冰、降水这四条曲线相位一致，**不是因为源自同一个日射场**，而是因为它们都各自读 `season_phase` 后写了 4 套独立余弦/查表。

本次重构的目标，是把"太阳—气候"的因果结构**物理化、唯一化、真涌现化**：

- 显式引入"太阳直射点纬度 `subsolar_lat`"作为唯一时间→空间的天文量，由 `season_phase` 派生。
- 把 `insolation(lat, season_phase)` 改造为"角度项 × 日长项 × 轨道缩放"的封闭公式，并成为**温度季节偏移、蒸发、海冰形成、降水季节强度**的**唯一**上游驱动；`_season_temp_offset_phase` 等旧独立曲线要么改为 insolation 的派生量，要么删除。
- 面板与 HUD 上的"当前季节"要改为**观测量**：从该纬度过去 N 天平均温度相位反推，而非从 `season_phase` 直读，从而让高纬季节幅度更大、赤道几乎无季节。

设计原则（硬约束）：

- **不新增 world tick、不新增管理器类**：仍由 `main._on_day_changed` 驱动。
- **单一真值源**：同一日 / 同一纬度下，温度、蒸发、海冰、降水读取的"季节信号"必须来自**同一个** `insolation` 值（经归一化派生），而不是 4 套独立公式。
- **物理可解释**：`subsolar_lat(t) = ε · sin(2π · year_progress)` 等中间量必须在 UI 或 debug 打点中可看到。
- **向后兼容**：所有新行为挂在 `ClimateProfile.true_insolation_enabled` 开关下，默认 **true**；关闭时完整回退到当前 `_season_temp_offset_phase` 路径，不污染 shader uniform 与存档。
- **零新 GPU buffer**：shader 端仍沿用现有 `season_phase / climate_anomaly` uniform，不新增纹理。
- **性能预算**：80×60 地图上 insolation 改造带来的逐日 pass 净开销 ≤ 1ms（应当略快，因为去掉了几个并行曲线的重复计算）。

---

## 需求

### 需求 1 — 引入太阳直射点与唯一 insolation 场

**用户故事：** 作为一名模拟爱好者，我希望在代码里看到"太阳直射点纬度"这个实体，它随游戏日历正弦移动（北回归线 ↔ 南回归线），并且全图所有气候派生量的"季节部分"都只从这一个 insolation 场读取，不再存在多条并行独立的季节曲线。

#### 验收标准

1. WHEN 系统启动 THEN `ClimateProfile` SHALL 暴露以下字段（默认值见括号）：
   - `true_insolation_enabled: bool = true`（主开关）
   - `axial_tilt_deg: float = 23.5`（黄赤交角，°）
   - `insolation_season_gain: float = 1.0`（把 insolation 归一化偏差映射到温度偏移的增益系数，用于微调）
   - `insolation_daylen_amp: float = 0.35`（日长项幅度，保留原常量但改为可配）
2. WHEN `map_generator.gd` 计算 insolation THEN 它 SHALL 使用以下封闭公式（并在模块注释中写明物理语义）：
   ```
   year_progress ∈ [0, 1) = fposmod(season_phase, 4.0) / 4.0
   subsolar_lat_rad       = axial_tilt_rad * sin(2π * year_progress)        # 直射点纬度
   lat_rad                = (ny - 0.5) * π                                 # 该 cell 的纬度
   cos_zenith             = max(0, cos(lat_rad - subsolar_lat_rad))         # 太阳高度角的余弦
   daylen_factor          = 1 + insolation_daylen_amp * sin(2π*year_progress) * sign(lat_rad)
   insolation             = clamp(cos_zenith * daylen_factor, 0, 1)
   ```
   其中半球反相通过 `sign(lat_rad)` 自然涌现，不再需要 `if lat_signed < 0: phase += 2` 的手动翻转。
3. WHEN `refresh_climate_daily` 在 Pass A 计算当日温度 THEN `season_offset` SHALL 改为 `insolation_season_gain * (insolation(ny, phase) - insolation_annual_mean(ny)) * season_temp_amp_scale`，其中 `insolation_annual_mean(ny)` 是该纬度一年日射的时间平均（解析公式或 16 采样数值近似皆可），而不是继续调用 `_season_temp_offset_phase` 的独立余弦。
4. WHEN `_apply_sea_ice_daily_pass` 计算 `T_eff` 或"冬季判定"THEN 它 SHALL 通过 `insolation` 相对于该纬度年均值的**标准化偏差**（例如 `insol_dev = (insol_now - insol_mean) / insol_mean`）判别季节强弱，而不是再次重建余弦相位。
5. WHEN `_moisture_scale_at_phase` 计算湿度季节倍率 THEN 仍可保留查表式过渡以维持现有"干/湿季"设计，但其**触发与强度调制** SHALL 被 `insol_dev` 乘子（范围如 `1 + 0.2 * insol_dev`）二次缩放，保证"赤道常年湿度几乎不变、高纬夏冬差异更大"这条涌现性质。
6. WHEN `true_insolation_enabled == false` THEN 系统 SHALL 整体回退到当前 `_season_temp_offset_phase` 路径，`_apply_sea_ice_daily_pass` 沿用既有"冬季相位"判别，`_moisture_scale_at_phase` 不再乘 `insol_dev`，shader uniform 不变。

---

### 需求 2 — 删除/降级旧独立曲线，建立单一真值源

**用户故事：** 作为一名维护者，我希望代码里不再同时存在"两条季节温度曲线"（老 `_season_temp_offset_phase` 与新 insolation 派生），而是明确一条主、一条兜底，调用点清晰。

#### 验收标准

1. WHEN `true_insolation_enabled == true` THEN `refresh_climate_daily` / `_apply_ocean_heat_transport_pass` / 选中面板"季节偏移"显示行 SHALL 统一读取新 insolation 派生函数（例如 `_insolation_season_offset(ny, phase)`），而不再调用 `_season_temp_offset_phase`。
2. WHEN `true_insolation_enabled == true` THEN 项目 SHALL 保留 `_season_temp_offset_phase` 但仅作为**回退路径**使用，并在其函数注释中明确写"Legacy cosine path — only used when true_insolation_enabled == false"。
3. WHEN `_insolation_temp_offset` 被保留 THEN 它 SHALL 被重命名/重写为 `_insolation_season_offset`（或至少添加真实调用点），彻底消除"死代码"。
4. WHEN shader 侧需要与 CPU 端对齐 THEN 现有 shader uniform `season_phase` 继续驱动画面季节渐变（不修改 shader），但 CPU 端与 shader 端的"季节温度偏移"语义 SHALL 在一个集中注释里说明差异（CPU 走 insolation、shader 仍走相位余弦近似），并保证二者在四季中点附近差异 ≤ 0.02 归一化单位。
5. WHEN 开发者打开 `ClimateProfile.true_insolation_enabled` 调试开关 THEN 系统 SHALL 在控制台打印一次"[climate] insolation-driven path active: subsolar_lat=X°, annual_mean_sample=..."，便于确认主路径是否真正生效。

---

### 需求 3 — 季节标签改为观测量（派生而非驱动）

**用户故事：** 作为一名玩家，我希望 HUD 显示的"当前季节"不再由日历硬推，而是由该地气温过去 N 天的走势反推——这样高纬清楚看到四季，赤道显示"常年温暖无显著季节"，高山/极圈显示"夏/冬"占比极端不对称。

#### 验收标准

1. WHEN 选中一个陆地/水体 cell THEN 面板"当前季节"SHALL 通过以下规则派生：
   - 维护 `HexCell.current_state["temp_30d_mean"]`（30 日低通）与 `temp_365d_mean`（年均），每日 EMA 更新（`α_30 ≈ 1/30, α_365 ≈ 1/365`）。
   - 当前季节分类：`dev = temp_30d_mean - temp_365d_mean`，按 `dev / season_temp_amp` 归一化到 [-1, 1]，结合其 30 天趋势 `ΔEMA` 的正负，映射到 春（升 / 近均）、夏（高 / 近顶）、秋（降 / 近均）、冬（低 / 近底）四个观测标签。
   - 面板显示 `"季节（观测）: X  —  近30日温度距年均 ±X.XX"`。
2. WHEN 赤道带 cell（|lat| < 0.15）被选中 THEN 系统 SHALL 在观测 `|dev| < 0.02` 时显示"常年温暖（无显著季节）"，而不是强行标春夏秋冬之一。
3. WHEN HUD 顶部需要一个全局季节标签（现有 `nominal_season_label` 输出）THEN 它 SHALL 保留作为"名义日历季节"但改标注为 "(calendar)"，与选中地块的 "(observed)" 标签区分开，让玩家能一眼看出"这是日历推出来的"和"这是当地气候推出来的"不一定一致。
4. WHEN `true_insolation_enabled == false` THEN 观测季节派生 SHALL 仍然可用（纯读取快层温度，与 insolation 是否启用无关），作为长期稳定可用的诊断工具。
5. WHEN 全图每日刷新 THEN `temp_30d_mean / temp_365d_mean` 的更新 SHALL 纳入 `refresh_climate_daily` Pass A 末尾，开销 ≤ 0.3ms（80×60 图）。

---

### 需求 4 — 诊断、验证与回归

**用户故事：** 作为开发者，我希望能快速验证"这套 insolation 路径确实在工作、确实比旧路径更物理"，并且可以一键回退对比。

#### 验收标准

1. WHEN 开发者按下已有的 F8 或新建 F9 一键切换 THEN 系统 SHALL 切换 `true_insolation_enabled`（F8 保持管涌现总开关；F9 单独管 true-insolation），切换后立即强制一次 `refresh_climate_daily`，面板温度分解行能即时刷新。
2. WHEN 选中 cell THEN 面板 SHALL 额外新增一行：
   `"太阳: 直射点 ±XX.X°  日射相对年均 ±XX.X%"`
   以显示 `subsolar_lat` 与 `insol_dev`，让"因果链"可见。
3. WHEN 100 游戏年加速运行 THEN 高纬 cell（|lat| > 0.7）的年温度振幅 SHALL ≥ 赤道 cell（|lat| < 0.15）的 3 倍，证明 insolation 驱动正确产生了"季节幅度随纬度增大"的涌现现象。
4. WHEN 同种子切换 `true_insolation_enabled` 前后 THEN 年平均温度/湿度图 SHALL 偏差 ≤ 2%（保证新路径不污染气候基线，只改变季节分布）。
5. WHEN `refresh_climate_daily` 首次运行 THEN 控制台 SHALL 额外打印一次 "[climate] subsolar_lat today=±XX.X°, insolation_annual_mean_equator=X.XXX, sampled_grid=NxM"，便于开发期排错。
6. WHEN `enable_local_climate_coupling == false` AND `true_insolation_enabled == true` THEN 系统 SHALL 仍能正常运行，仅温度季节偏移使用 insolation，其余三项局部扰动跳过（证明两套开关是正交的）。

---

## 边界与非目标（out of scope）

- 不引入真实轨道离心率、章动、岁差；`subsolar_lat` 仅用 `axial_tilt * sin(2π·year_progress)` 的正弦近似。
- 不引入真实日长公式（含极昼极夜 acos 边界）；`daylen_factor` 仍沿用 `1 + amp * sin(2π·year_progress) * sign(lat)` 的线性近似，若未来需要真实极昼极夜再升级。
- 不修改 shader 端 `season_phase` uniform 语义，画面季节渐变仍由 shader 本地余弦近似驱动（CPU 与 shader 之间允许 ≤0.02 的轻微相位差）。
- 不改 biome 决策树，也不动 `_decide_terrain` 的触发频率；本次只改"季节信号来源"。
- 不新增新管理器类、不拆分 `map_generator.gd`；所有改动在现有文件内完成。
- 不处理昼夜循环（"一日内"的日出日落）；本次仅处理"年内季节"尺度。
