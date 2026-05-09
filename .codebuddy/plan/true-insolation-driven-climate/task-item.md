# 实施计划 — True Insolation-Driven Climate

> 基于 `requirements.md` 的 4 条需求，规划为 8 个连续可落地的编码任务。所有任务都在既有 `MapGenerator` / `ClimateProfile` / `HexCell` / `main.gd` 内增量改造，不引入新管理器类、不新增 GPU buffer。

- [ ] 1. 在 `ClimateProfile` 新增 true-insolation 开关与可配常量
   - 在 `climate_profile.gd` 新增导出字段：`true_insolation_enabled: bool = true`、`axial_tilt_deg: float = 23.5`、`insolation_season_gain: float = 1.0`、`insolation_daylen_amp: float = 0.35`。
   - 更新文件顶部 doc comment，说明本次 insolation 主路径何时启用、如何回退。
   - _需求：1.1, 1.6_

- [ ] 2. 重写 `_compute_insolation` 为"直射点 + cos_zenith + 连续日长"封闭公式
   - 新增 `_subsolar_lat_rad(season_phase)`，基于 `axial_tilt_deg` 与 `year_progress = fposmod(phase, 4)/4` 的正弦位移。
   - 改写 `_compute_insolation(ny, phase)`：`cos_zenith = max(0, cos(lat_rad - subsolar_lat_rad))`、`daylen_factor = 1 + amp * sin(2π·year_progress) * sign(lat_rad)`、`return clamp(cos_zenith * daylen_factor, 0, 1)`。
   - 新增 `_insolation_annual_mean(ny)`：一年 16 点数值采样，结果可缓存到局部数组（按 ny 分桶或每次 pass 开始前计算一张 `ny → mean` 表），避免每 cell 重算 16 次。
   - 在模块顶部注释中写明物理语义与 shader 端相位近似的差异（≤0.02 容差）。
   - _需求：1.2, 2.4_

- [ ] 3. 让温度季节偏移改用 insolation 派生（单一真值源）
   - 新增 `_insolation_season_offset(ny, phase, annual_mean_cache)`：`return insolation_season_gain * (insolation(ny, phase) - annual_mean(ny)) * season_temp_amp`。
   - 在 `refresh_climate_daily` Pass A 内，当 `true_insolation_enabled == true` 时用新函数替换 `_season_temp_offset_phase`；否则维持旧路径（回退）。
   - `temperature_breakdown["_temp_season_offset"]` 写入值随路径切换，并在选中面板显示时区分标签。
   - 把 `_insolation_temp_offset` 删除或改为转发调用，消除死代码。
   - _需求：1.3, 2.1, 2.2, 2.3_

- [ ] 4. 海冰 pass 改读 `insol_dev` 判别"冬季强度"
   - 在 `_apply_sea_ice_daily_pass` 内把原本依赖 `dist_to_winter` / 余弦相位的"冬季加成"改为 `insol_dev = (insol_now - insol_mean) / max(insol_mean, ε)`，`freeze_bonus = clamp(-insol_dev, 0, 1)`。
   - `T_form / T_melt` 阈值保持不变，但 `k_freeze *= (1 + freeze_bonus)`、`k_melt *= (1 + max(insol_dev, 0))`。
   - 当 `true_insolation_enabled == false` 时走旧路径；确保 QA 打点"单日翻转 > 3%"行为保持。
   - _需求：1.4_

- [ ] 5. 湿度季节倍率叠加 `insol_dev` 二次缩放
   - 在 `_moisture_scale_at_phase` 或其调用处乘 `(1 + 0.2 * insol_dev)`，使赤道季节湿度几乎不变、高纬夏冬差异放大。
   - 对应陆地 cell 的 `moisture_now` 写回路径不变；仅当 `true_insolation_enabled == true` 时启用该缩放。
   - _需求：1.5_

- [ ] 6. 引入观测季节标签与温度 EMA
   - 在 `HexCell.current_state` 约定三个字段：`temp_30d_mean`、`temp_365d_mean`、`temp_trend_30d`（EMA 差分）。
   - 在 `refresh_climate_daily` Pass A 末尾对每 cell 做一次 EMA 更新（`α_30 = 1/30`、`α_365 = 1/365`），首次出现时用 `temp_now` 初始化。
   - 新增纯函数 `observe_local_season(cell) -> {label, dev_norm, trend}`：结合 `dev = mean_30 - mean_365` 与 `trend` 映射为"春/夏/秋/冬/常年温暖"5 类标签。
   - _需求：3.1, 3.2, 3.4, 3.5_

- [ ] 7. 选中面板新增 2 行"太阳/观测季节"信息
   - 在 `main.gd` 的地块信息面板追加：
     - `"太阳: 直射点 ±XX.X°  日射相对年均 ±XX.X%"`（所有 cell）
     - `"季节(观测): X  —  近30日距年均 ±X.XX"`（所有 cell；赤道无显著季节时显示"常年温暖"）
   - HUD 顶部 `nominal_season_label` 输出继续保留，但文案改为"季节(日历): X"以与观测季节区分。
   - 所有字段读取走 `get(key, fallback)`，首次缺字段 WARN 一次。
   - _需求：3.3, 4.2_

- [ ] 8. 调试开关、启动日志与回归对照
   - 在 `main._unhandled_input` 新增 F9 一键切换 `true_insolation_enabled`（F8 仍控总涌现开关），切换后强制 `refresh_climate_daily` 一次。
   - `refresh_climate_daily` 首次调用且 `true_insolation_enabled == true` 时，打印 `[climate] insolation-driven path active: subsolar_lat=±X°, equator_annual_mean=X.XXX`。
   - 在开发者控制台或一个临时 `@tool` debug 函数中，提供"同种子运行 100 年 → 统计赤道 vs 高纬年温度振幅比"的打点，验证需求 4.3 的 3× 关系。
   - 确认 `enable_local_climate_coupling = false` + `true_insolation_enabled = true` 时温度季节偏移仍走 insolation、其余三项局部扰动跳过（验证 4.6 正交性）。
   - _需求：2.5, 4.1, 4.3, 4.4, 4.5, 4.6_
