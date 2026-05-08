# 画面表现优化 — 性能基线报告（模板）

> 关联文档：[`requirements.md`](requirements.md) · [`task-item.md`](task-item.md)
> 代码工程根：`Project/project-keynes/`
> 产出目标：量化"视觉优化前 vs 后"三组数据，确认"全开"帧时间 ≤ 基线的 130%

---

## 一、采集方法

1. **启动项目** → 保持默认 `cells = 2400`（60 × 40）、默认 `hex_size = 22.0`、默认 `seed = 0`
2. **打开 `Visual Overhaul` @export 组**，按下方三组配置逐一勾选
3. **每组稳态跑 30 秒**（让 PerfSampler 内置窗口完整采样一次），截取控制台 `[PerfSampler][HexRenderer]` 输出行
4. **记录三项**：
   - `avg_ms` — 平均帧时间（毫秒）
   - `p95_ms` — 95 分位帧时间（毫秒）
   - `fps` — avg_ms 反算 (= 1000 / avg_ms)
5. 启动采样：在 Inspector 勾选 `main.perf_sampler_enabled = true`（或改 `main.gd` 默认值）

## 二、三组配置矩阵

| 组别 | `visual_quality` | `day_night` | `water_effect` | `ocean_current` | `extreme_weather` |
|---|---|---|---|---|---|
| 基线（原始） | 2 | ✗ | ✗ | ✗ | ✗ |
| 全关（回退路径验证） | 0 | ✗ | ✗ | ✗ | ✗ |
| 全开（优化后完整体） | 2 | ✓ | ✓ | ✓ | ✓ |

## 三、实测数据（待填写）

| 组别 | avg_ms | p95_ms | fps | 备注 |
|---|---|---|---|---|
| 基线（原始） | _TBD_ | _TBD_ | _TBD_ | 刚启动 + 跑过两个季节后再采样 |
| 全关（回退路径） | _TBD_ | _TBD_ | _TBD_ | 视觉与"基线"应完全一致 |
| 全开（完整体） | _TBD_ | _TBD_ | _TBD_ | 若 avg_ms > 基线 × 1.30 即超标 |

**130% 上限检查**：

- `全开 avg_ms ÷ 基线 avg_ms = ___`（要求 ≤ 1.30）
- 若超标，预设降级方案：`visual_quality = 1`（水体粼光关闭、云层单 octave），再次采样

## 四、6 开关独立隔离回归 Matrix（待填写）

逐一把 6 个 `@export` 开关独立置为 `false` 再采样一次，确认模块可独立隔离不影响其他特性：

| 关闭的单项 | 视觉预期 | 实测结果 |
|---|---|---|
| `day_night_enabled = false` | 画面回到无昼夜色温（与基线地表色一致）| _TBD_ |
| `water_effect_enabled = false` | 水面无粼光/浪花/薄冰（但基础波纹 + 洋流流纹仍在）| _TBD_ |
| `ocean_current_enabled = false` | 海面不再有随时间推进的流纹 | _TBD_ |
| `extreme_weather_ground_effect_enabled = false` | BLIZZARD 不叠积雪，DROUGHT 不叠裂地纹理 | _TBD_ |
| `perf_sampler_enabled = false` | 不再有 `[PerfSampler]` 输出 | _TBD_ |
| `visual_quality = 0` | 云层退化为单圆盘；水面无粼光 | _TBD_ |

## 五、降级策略记录

当 130% 上限被突破时，按顺序执行：

1. `visual_quality = 2 → 1`：shader 中 `if (visual_quality >= 2)` 的分支整体跳过
   - 水面粼光关闭
   - 云层 fBm 降到单 octave（来自 `weather_overlay.gdshader` 的 `quality >= 2` 分支）
2. `visual_quality = 1 → 0`：
   - 云层退化为单圆盘 gaussian（与优化前完全一致）
   - 其他所有任务级优化特性跳过
3. 若仍超标，逐项手动关闭 `water_effect / ocean_current / extreme_weather`

## 六、结论（待填写）

- **130% 上限是否满足**：_TBD_
- **退化路径是否有效**（全关 ≈ 基线）：_TBD_
- **6 开关独立隔离是否全部通过**：_TBD_
- **建议默认视觉档位**：_TBD_（2 / 1 / 0）

---

_最后更新：请在填完实测数据后把本行替换为日期_
