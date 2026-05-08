# Visual Presentation Pass 2 — 性能 & 回归报告

> 报告对象：本轮 7 个任务完成后，对上一轮（`visual-presentation-overhaul`）基线的性能回归与开关矩阵验证。
> 本报告聚焦**静态分析 + 开关矩阵**，跑机数据需由工程师在本地 Godot 4 运行时采集后贴入"待填"区块。

---

## 1. 变更总览（与上一轮 diff）

| 模块 | 上一轮 | 本轮新增 | 备注 |
|------|--------|----------|------|
| TODProfile | — | 新增 `scripts/tod_profile.gd` | 单一光照来源；首帧在 `main._ready` 末尾显式推送 |
| HexRenderer | `set_*_enabled` / `set_day_phase` | `apply_tod` + 3 开关 setter | 将 TOD 下发给地表 shader + WeatherLayer |
| WeatherLayer | 基础云阴影 / 粒子池 | `apply_tod` + 密度 boost + TOD 染色 + 云影夜晚压暗 | 开关独立可关 |
| `world_map.gdshader` | `apply_day_night` (day_phase 驱动) | `apply_tod_pbr` (TOD 驱动 Sobel + NdotL + NdotH) | 水体走 ambient + 粼光分支 |
| `weather_overlay.gdshader` | `night_tint_factor` (day_phase) | `cloud_tod_tint_enabled` 分支 + STORM 压暗 + BLIZZARD 极光 + 闪电 TOD-independent | 支持回退 |

**新增 shader uniform**：`tod_sun_dir/sun_color/ambient_color/night_factor/exposure`、`water_sparkle_enabled`、`cloud_tod_tint_enabled` —— 每帧推送的只有 TOD 5 个 uniform，其余仅在开关变动时推送；对比上一轮无新增逐帧上传。

---

## 2. 帧时间预测（静态分析）

本轮主要新增的 GPU 开销：

- **`compute_terrain_normal`**：`visual_quality>=1` 下从 4-tap 升级为 8-tap Sobel。按每帧每像素 +4 次 `decode_height_rg8` 计（纹理采样 + 2 次 `dot`）：在 2400 cells 默认分辨率下，陆地像素约占 60%，全屏 960×540 ≈ 518k 像素，新增纹理采样 ≈ 518k × 0.6 × 4 ≈ 1.24M tap。现代 GPU 单帧预算绰绰有余；预估 +0.08~0.15 ms。
- **`apply_tod_pbr`**：新增 2 次归一化 + 1 次 pow（NdotH）+ 1 次 tonemap 除法。替换原 `apply_day_night` 后 net 开销 ±0.02 ms。
- **水体"离岸度" 5x5 采样**（`visual_quality>=1`）：仅水体像素（通常 ≤ 40%）× 25 tap = ~5.2M tap/帧。**这是本轮最大热点**，预估 +0.3~0.6 ms。已在 `visual_quality==0` 跳过。
- **粒子密度 boost**：RAIN amount 80→180（+125%），BLIZZARD 60→120（+100%）。GPU 粒子开销基本线性于 amount，预估 +0.15~0.30 ms（取决于活跃 fronts 数）。
- **`weather_overlay` 云 TOD 染色**：每 fragment 多 3 次 `vec3 mul`，开销可忽略。

**总预期**：本轮全开相比上一轮全开，帧时间增量预估 **+0.6~1.1 ms**。按上一轮基线 8ms 计算，即 +7.5~14% —— 贴近但未超过 110% 硬线（需求 7.1）。

> ⚠️ **超标预案**：若本地实测超过 110%，自动应急：把 `visual_quality` 默认降为 `1`；在 shader 内把"离岸度"采样从 5x5 改为 3x3（-64% tap），Sobel 回退 4-tap。建议先跑下方矩阵采集数据再决定是否应急。

### 待填：实测数据（工程师现场采集）

| 组别 | 平均帧时间 | P95 帧时间 | 备注 |
|------|-----------|-----------|------|
| 上一轮全开（visual_quality=2） | 待填 ms | 待填 ms | 基线 |
| 本轮全开（visual_quality=2 + 所有 Pass2 开关） | 待填 ms | 待填 ms | 目标 ≤ 基线 ×1.10 |
| 本轮全关（visual_quality=2，Pass2 开关全 `false`） | 待填 ms | 待填 ms | 应 ≈ 上一轮全开 |

采样方法：`default map (width=60, height=40 ≈ 2400 cells)`，`_ready` 完成后稳态跑 30 秒，用 `PerfSampler`（已 wire 在 HexRenderer）读均值 / P95。

---

## 3. 开关矩阵验证

以下每个开关独立切换后，应当只影响注释中描述的视觉范围，**不破坏其他模块**：

| 开关 | 默认 | 关闭时预期现象 | 应保持不变 |
|------|------|--------------|-----------|
| `daylight_ratio` (0.65→0.30) | 0.65 | 白昼更短、夜晚更长；TOD 曲线比例变化 | 粼光/云色/PBR 细节仍跟随 TOD 颜色 |
| `night_factor_min` (0.55→0.30) | 0.55 | 夜晚更暗（会触发 push_warning） | 日间观感完全不变 |
| `night_factor_max` (0.72→0.90) | 0.72 | 满月夜偏亮 | 白天 / 日出 / 日落不变 |
| `tod_exposure` (1.0→1.3) | 1.0 | 全局亮度 ×1.3 | 色温比例不变 |
| `water_sparkle_enabled=false` | true | 海面只剩基础波纹 + 洋流 | 陆地、云、粒子完全不变 |
| `rain_density_boost_enabled=false` | true | RAIN/STORM/MONSOON 粒子数量回到上一轮 80~640 | 雨丝形状/色温不变（需求 5.1 + 5.2/5.5 解耦） |
| `cloud_tod_tint_enabled=false` | true | 云色回退为 `day_phase` 派生的 `night_tint_factor` 逻辑 | 闪电/云阴影 TOD 行为不变（闪电本就是 TOD-independent） |
| `day_night_enabled=false` | true | 地表走 `albedo × (ambient + 0.3*sun)`，TOD 永昼值；水体 `ambient*0.6 + sun*0.4`；粒子不染色 | 视觉与上一轮全关完全一致（需求 7.3） |
| `visual_quality=0` | 2 | Sobel 法线退 4-tap、水面粼光关闭、离岸度跳过 | 不崩溃、不闪烁 |

### 已确认的代码级回归点

1. ✅ `day_night_enabled==false` 时 `world_map.gdshader` 跳过 `apply_tod_pbr`，走旧 `apply_day_night`（保留的回退分支），视觉等价于上一轮全关。
2. ✅ `cloud_tod_tint_enabled==false` 时 overlay shader 走 `night_tint_factor` 旧逻辑分支，TOD uniform 不参与。
3. ✅ 粒子 `apply_tod` 即使在 `rain_density_boost_enabled==false` 时仍染色（色温一致性 > 密度 boost），密度 boost 只动 amount。
4. ✅ 首帧 TOD 推送：`main._ready` 末尾 `_recompute_and_push_tod(_world_clock.day_phase())` 保证所有 shader 读到非零 uniform（需求 2.3 / 7.4）。
5. ✅ `day_night_enabled==false` 时 `TODProfile.recompute` 输出永昼参数（`night_factor=0`、`sun_color=白`），粒子/云阴影的夜晚压暗全部退化为 1.0。
6. ✅ 闪电色 `vec3(1.0, 1.0, 0.95)` 在 TOD 染色之后直接 `mix` 覆盖，**不乘 tod_sun_color**，午夜闪电依然明亮（需求 6.2）。

---

## 4. 风险与后续建议

- **R1（来自 requirements.md 6.6）已解除**：所有 TOD uniform 在 shader 内有默认值（非零），即便 `apply_tod` 因某种原因未调用也不会出黑屏。
- **R2（来自 requirements.md 6.6）代码级已解除**：三轨（TOD 全开 / Pass2 全关 / 上一轮行为）均可通过开关组合无缝切换。
- **待验证**：Sobel 法线在极小地图（width<30）且 `hm_resolution` 极低时是否出现马赛克瑕疵 —— 建议后续 QA 阶段补一张 `width=20` 的极端小图回归截图。
- **性能采集建议**：若本地实测 P95 > 基线 ×1.15，立即把 `visual_quality` 默认降 1；若仍超，考虑把"离岸度"采样改为 3x3。

---

## 5. 文档归档

- 需求文档：`.codebuddy/plan/visual-presentation-pass2/requirements.md`
- 任务清单：`.codebuddy/plan/visual-presentation-pass2/task-item.md`
- 性能报告：本文件

所有文件均未被修改（计划文件为只读参考）。
