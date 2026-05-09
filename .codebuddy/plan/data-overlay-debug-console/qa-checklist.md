# 手动 QA 清单：Data Overlay & Debug 控制台

> 关联文档：
> - [requirements.md](./requirements.md)
> - [task-item.md](./task-item.md)
>
> 用法：依次执行下列步骤，发现差异即在条目末打勾或贴失败现象/截图。
> 所有步骤都在 Editor / Debug Build 下完成；Release Build 仅做冒烟（启动后按 ` 看面板能否唤出）。

---

## 0. 启动冒烟

- [ ] 启动后地图正常生成，无 `push_warning`/`push_error` 关于 overlay/debug 的报错。
- [ ] 默认 `_overlay_mode == NONE`，地图视觉与改造前一致（验收 1.1）。
- [ ] 默认 `DebugConsole.visible == false`、`OverlayLegend.visible == false`。

## 1. Data Overlay 基础（需求 1）

- [ ] 按 `` ` `` 打开 Debug 控制台 → 切到 `温度` → 全图出现冷暖色叠加，原地形仍可辨（验收 1.2）。
- [ ] 滑动 `透明度` 滑条 0.0 ↔ 1.0，效果连续变化无闪烁。
- [ ] 切回 `关闭`，地图回到改造前；DataOverlayLayer.visible 自动变 false。
- [ ] 在 NONE 与 TEMPERATURE 之间快速连切 10 次（< 200ms 间隔），无残影、无 shader 报错（验收 6.4）。
- [ ] 按 R 重新生成地图，overlay 模式保留为之前选中的通道，色带仍正确显示新地图数据（验收 1.5）。

## 2. 六个数据通道（需求 2）

> 每个通道至少留一张截图作为视觉基线（截图建议保存到 `.codebuddy/plan/data-overlay-debug-console/screens/`）。

- [ ] **TEMPERATURE**：高纬度（地图上下边缘）冷蓝、赤道暖红，与右侧面板"当前温度"读数一致。
- [ ] **PRECIPITATION**：山脉迎风/背风的雨影对比可见；选中地块时 Legend 指针位置与"当季降水 / 1.5"基本对齐。
- [ ] **CLIMATE_ZONE**：5 档色带从中线向两极递进；Legend 显示 5 个分类色块。
- [ ] **HUMIDITY**：湖泊/沿海湿润，沙漠区干燥；色带方向与 Legend 一致。
- [ ] **WEATHER**：开启 RAIN/STORM/HEATWAVE 等天气时对应区域显色，CLEAR cell 透明；强度越高越不透明。
- [ ] **VEGETATION_VITALITY**：水域显示中性灰（半透明），陆地按 `vegetation_vitality` 红→绿渐变。

- [ ] 等模拟推进 ≥ 30 天，overlay 颜色随 `temperature/moisture/weather` 变化（验收 2.7）。

## 3. Legend（需求 3）

- [ ] overlay != NONE 时左下角出现 Legend；NONE 时隐藏。
- [ ] 连续通道 Legend 显示色带 + 两端数值；离散通道显示色块列表。
- [ ] 选中地块（左键点击非 UI 区域）后，Legend 在色带上出现白色指针；位置与该 cell 数值匹配。
- [ ] 关闭右键面板（X）或切到 NONE，指针自动隐藏。

## 4. Debug 控制台（需求 4）

- [ ] 按 `` ` `` 与 `F1` 都能切换控制台显隐。
- [ ] 控制台内点击 OptionButton/CheckBox/Slider，**不会**触发地图选中（验收 4.6）。
- [ ] **模拟开关**：勾选 / 反选任一项，应能在控制台同时反映出与 F8 一致的视觉变化（温度图、海冰、天气随之刷新）。
- [ ] **视觉开关**：
  - `day_night_enabled` 关闭后地图无昼夜亮度起伏。
  - `ocean_current_debug` 等价于 F6 高对比流线。
  - `perf_sampler_enabled` 开启后 30s 后控制台输出 `[PerfSampler]` 日志。
- [ ] **诊断动作**：3 个按钮对应输出与 F7 / 选中地块温度分解 / 清空选中等价。
- [ ] 在另一处通过 F6 / F8 改变开关后，控制台 1Hz 内将 CheckBox 状态同步到真值（验收 4.7）。
- [ ] 关闭控制台后再打开，所有开关状态保留（不会被重置）。

## 5. Telemetry（需求 5）

- [ ] 控制台打开时 Telemetry 行 1 显示 `fast_tick #N: Xms`，N 与 X 随模拟推进而增长。
- [ ] `overlay bake: …ms` 在 NONE 下保持上次值（暂停态语义可接受），切到 TEMPERATURE 后更新为合理值（典型 < 5ms）。
- [ ] 离散通道下 Telemetry 显示每档 cell 计数（如 `热带 120 / 副热带 380 / ...`）。
- [ ] 模拟暂停（Space）后 Telemetry 数值冻结，不出现 NaN/`--`。
- [ ] 大地图（120×80）下 overlay bake 单次 ≤ 1Hz，不出现帧时间峰值。

## 6. 边界 / 回退（需求 6）

- [ ] 启动到 `_ready` 之间打开控制台（理论上不可能，作为冒烟），如能进入则面板应正常显示空状态。
- [ ] 在 ClimateProfile 暂时缺字段（人为破坏 .tres 路径）下打开控制台，CheckBox 置灰，无 crash。
- [ ] 修改 `data_overlay.gdshader` 故意写错语法 → 启动时控制台 Overlay 分组上方出现红色 `overlay disabled: ...` Label（验收 6.5）。

---

## 7. 性能回归对比（成功标准 3）

> 目标：overlay = NONE 时帧时间相对改造前偏差 ≤ 0.3ms。

测试步骤：
1. 用同一 seed（如 `initial_seed=12345`）生成 80×60 地图；
2. 关闭 overlay、关闭 DebugConsole，让模拟跑 365 天（x20）；
3. 启用 `perf_sampler_enabled`，记录 30 秒内的 `fast_tick` 平均毫秒（标记 `Baseline-After`）。
4. 把 commit checkout 到本次改造前 commit（HEAD~1 ... 改造起点），重复步骤 1-3，标记 `Baseline-Before`。

| 指标 | Before | After | 偏差 | 通过 |
|------|--------|-------|------|------|
| 30s 平均 fast_tick (ms) | _填_ | _填_ | _填_ | ≤ 0.3ms ? |
| P95 fast_tick (ms)      | _填_ | _填_ | _填_ | ≤ 0.5ms ? |
| 30s 平均帧率            | _填_ | _填_ | _填_ | ≤ 1fps   |

> 结果填入后归档到本目录 `perf-after.md`（如本轮无显著回归则可省略单独 doc，仅在本表完成）。

---

## 8. 已知限制（不在本轮范围）

- Overlay 数据始终是当前帧快照，不做历史回放（与"非目标"一致）。
- `CLIMATE_ZONE` 在 baker 端用了基于 cell.r/q 的近似 ny；与右面板的"|ny - 0.5|"5 档分档结果一致，但若以后 MapData 暴露真实 ny，应把 `_latitude_hint` 替换为它。
- `Release Build` 下控制台默认关闭，但快捷键仍生效（沙盒玩法）。
