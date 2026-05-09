# 需求文档：地图数据叠加层（Data Overlay）与 Debug 控制台

## 引言

当前项目的地图渲染只展示"成品地貌"（海陆、植被、雪盖、天气粒子），玩家/开发者无法直观看到驱动这些地貌的**底层数值场**——温度、降水、湿度、气候带、天气、植被健康度都藏在 `HexCell` 的属性里，只有在右键单击地块弹出右侧面板时才能看到单格数值。要做气候/植被调参、定位模拟异常、验证涌现耦合效果时，只能靠 F6/F7/F8 三个临时快捷键往控制台 `print`，效率极低。

本次功能面向**开发者与美术调参**，目标是：

1. 在地图上叠加一层**全地图范围的数据热力图（Data Overlay）**，可在多种数据通道间实时切换（温度、降水、气候带、湿度、天气强度、植被健康度等），并随模拟每日更新。
2. 引入一个可开合的**Debug 控制台面板**，把现有分散的 @export 开关、F6/F7/F8 快捷键、速度控制、overlay 切换、选中地块详情打印等统一收纳到一个 UI 里，便于在运行时快速切换与观测。
3. 不改变任何已有模拟逻辑和现有 UI（TopBar / RightPanel）的默认行为，Overlay 与 Debug 控制台都可一键关闭，回退到今天的视觉效果；开发者便捷性提升的同时不影响 QA / 玩家体验路径。

本次**仅**改造 UI、渲染（shader 叠加层）、以及把现有数据串起来的接入代码，**不**改动气候/天气/植被等模拟核心，**不**引入新的 per-cell 数据字段。

---

## 需求

### 需求 1：Data Overlay 基础框架（可切换的全地图热力图）

**用户故事：** 作为一名开发者，我希望能在运行时一键在地图上叠加不同的"数据热力图"（而不是地貌渲染），以便直观看到全地图温度/降水/湿度/气候/天气/植被健康度的空间分布与演化。

#### 验收标准

1. WHEN 项目启动 THEN 系统 SHALL 默认 overlay 模式为 `NONE`，地图显示与当前版本完全一致（无任何颜色叠加）。
2. WHEN 开发者通过 Debug 控制台或快捷键切换 overlay 模式 THEN 系统 SHALL 在地图表面叠加一层半透明的数据颜色图，覆盖整张地图所有非不可见 cell，且保持原地貌阴影与轮廓可辨（overlay alpha 0.6~0.8 可调）。
3. WHEN overlay 模式为 `NONE` THEN 系统 SHALL 跳过任何 overlay 相关的 shader 计算与纹理采样，不得产生可测量的帧时间开销（允许偏差 ≤ 0.3ms）。
4. WHEN overlay 模式切换至任一数据通道 THEN 系统 SHALL 在同一帧内完成 shader uniform 切换，不得闪烁或造成 > 1 帧卡顿。
5. IF 地图重新生成（按 R） THEN 系统 SHALL 保留当前 overlay 模式不重置，玩家/开发者再次生成地图可继续看到同一数据通道。

---

### 需求 2：六个可视化数据通道（温度 / 降水 / 气候带 / 湿度 / 天气 / 植被健康度）

**用户故事：** 作为一名气候系统调参者，我希望 overlay 层能够切换展示至少 6 个不同维度的数据通道，以便横向对比它们之间的耦合关系（比如看到雨影区的"降水低 + 植被枯"在空间上是否对齐）。

#### 验收标准

1. WHEN overlay 模式为 `TEMPERATURE` THEN 系统 SHALL 采样每个 cell 的 `HexCell.temperature`，按寒→暖（蓝→青→黄→红）色带映射，色带端点对应 `[0.0, 1.0]`。
2. WHEN overlay 模式为 `PRECIPITATION` THEN 系统 SHALL 按 `moisture_scale_at_phase × base_moisture` 估算当季降水，干→湿（橙→白→蓝）色带映射。
3. WHEN overlay 模式为 `CLIMATE_ZONE` THEN 系统 SHALL 按纬度 `|ny - 0.5|` 渲染 5 档气候带（热带/副热带/温带/副极地/极地）的离散色块，与右侧面板 `_climate_zone_name` 的档位一致。
4. WHEN overlay 模式为 `HUMIDITY` THEN 系统 SHALL 采样 `HexCell.moisture`（当前日湿度），干→湿（黄→绿→蓝）色带映射。
5. WHEN overlay 模式为 `WEATHER` THEN 系统 SHALL 采样 `current_state.weather` + `weather_intensity`，按 WeatherType 分类上色（如：CLEAR 透明，RAIN 蓝，SNOW 白，STORM 紫，DROUGHT 橙棕），强度决定不透明度。
6. WHEN overlay 模式为 `VEGETATION_VITALITY` THEN 系统 SHALL 采样 `HexCell.vegetation_vitality`，枯→繁（红→黄→绿）色带映射；水域 cell 不参与采样，渲染为中性灰色（或透明）。
7. WHEN 模拟推进一日 THEN 系统 SHALL 在下一次 HexRenderer 烘焙循环中（或独立 overlay data 纹理更新循环中）同步数据纹理，让 overlay 的颜色跟着模拟每日变化而变化。
8. IF 某个数据通道的采样字段尚未初始化（如 `vegetation_vitality == 0.7` 默认值） THEN 系统 SHALL 正常按默认值渲染，不得因"无数据"而降级为纯色或报错。

---

### 需求 3：Overlay 图例（Legend）与色带标尺

**用户故事：** 作为一名开发者，我希望 overlay 开启时屏幕上能看到一个小的图例/色带说明，以便知道"这个颜色对应多少度"或"这个颜色是什么气候带"。

#### 验收标准

1. WHEN overlay 模式 ≠ `NONE` THEN 系统 SHALL 在地图左下角显示一个图例面板，包含：通道名称（如"温度"）、色带条、色带两端的数值标签（如 `0.00` / `1.00`）。
2. WHEN overlay 模式为离散类型（`CLIMATE_ZONE` / `WEATHER`） THEN 系统 SHALL 在图例内以色块 + 标签列表形式显示每一档分类（热带/副热带/... 或 晴/雨/雪/...）。
3. WHEN overlay 模式为 `NONE` THEN 系统 SHALL 隐藏图例面板。
4. WHEN 选中某个地块 THEN 图例面板 SHALL 在其数值标注线上高亮该地块的当前值位置（如一个小三角形指针指向数值位置），让开发者能把"某格实际数值"与"色带颜色"直接对上。

---

### 需求 4：Debug 控制台面板（集中收纳调试选项）

**用户故事：** 作为一名调参者，我希望有一个可开合的 Debug 控制台面板，把分散在 F6/F7/F8 快捷键、@export 开关、overlay 切换里的调试选项都集中展示，以便快速切换状态观察效果而不必记忆快捷键。

#### 验收标准

1. WHEN 按下快捷键 `` ` `` （反引号 / 波浪号键，KEY_QUOTELEFT）或 `F1` THEN 系统 SHALL 切换 Debug 控制台的可见性。
2. WHEN Debug 控制台首次打开 THEN 系统 SHALL 默认停靠在屏幕左上（避开 TopBar）或右上（TopBar 下方），宽度 ≥ 320px，使用 ScrollContainer 包裹以支持内容溢出滚动。
3. WHEN Debug 控制台打开 THEN 系统 SHALL 在面板内显示以下分组（每组可折叠）：
   - **Overlay**：下拉/按钮组切换 7 个 overlay 模式（NONE + 6 个通道）+ alpha 强度滑条。
   - **模拟开关**：4 个按钮/复选框映射到现有涌现耦合开关（对应 F8 功能：`emergent_season_enabled` / `enable_local_climate_coupling` / `emergent_weather_coupling` / `fast_slow_layering_enabled` / `true_insolation_enabled`）。
   - **视觉开关**：6 个开关（`day_night_enabled` / `water_effect_enabled` / `ocean_current_enabled` / `ocean_current_debug`（对应 F6） / `extreme_weather_ground_effect_enabled` / `perf_sampler_enabled`）。
   - **诊断动作**：按钮触发 F7 的 ocean_heat 摘要打印；按钮触发选中地块 `temperature_breakdown` 详细打印；按钮清空当前选中。
4. WHEN 控制台内某个开关被点击 THEN 系统 SHALL 立即把新值同步到对应的 `ClimateProfile` / `HexRenderer` / `WeatherSystem` setter 方法，并在同帧反映到画面上，行为与现有 F6/F8 快捷键等价。
5. WHEN Debug 控制台关闭 THEN 系统 SHALL 保持所有当前开关状态不变（面板只是 UI 的可见性切换，不做"重置"）。
6. IF Debug 控制台打开时鼠标点击控制台内部 THEN 系统 SHALL 不触发地图地块选中（`_unhandled_input` 由 UI 截断），避免"点按钮顺便选格"的体验割裂。
7. WHEN 模拟系统的某个外部路径（如快捷键、season_changed）改变了控制台里同步的开关状态 THEN 控制台 SHALL 在下一次打开或每秒一次的 tick 中刷新 UI 状态，避免显示与真值脱节。

---

### 需求 5：实时数据监视（Telemetry）面板

**用户故事：** 作为一名性能优化者，我希望 Debug 控制台能显示一些"全局实时统计"（如当前 overlay 下全地图的 min/max/mean，或上次 fast tick 的毫秒耗时），以便一眼发现异常（比如温度全变负数、某个 SUS Job 卡顿）。

#### 验收标准

1. WHEN Debug 控制台打开 THEN 系统 SHALL 在专门的 "Telemetry" 分组内显示下列实时数值（每秒刷新一次，或每次 `day_changed` 触发一次）：
   - `fast_tick #N: Xms`（沿用 `main.gd` 里已有的 `_fast_tick_count` 与总耗时）
   - `SUS breakdown`：若 `perf_log_daily_breakdown` 开启，显示最近一次 tick 的 `sus / render / ui` 三段耗时。
   - `overlay stats`：若 overlay 模式 ≠ `NONE`，显示当前通道的全地图 min / max / mean / median（不少于 3 个统计值）。
2. WHEN overlay 模式为离散类型 THEN Telemetry SHALL 显示每档分类的 cell 数量（如 `热带 120 / 副热带 380 / ...`）。
3. WHEN 模拟暂停 THEN Telemetry 的数值 SHALL 冻结在最后一次快照，不得显示 NaN / "--" 或乱码。
4. IF 计算 overlay 统计本身消耗 ≥ 1ms THEN 系统 SHALL 按 1Hz 节流（而非每帧计算），确保 Telemetry 不会变成性能瓶颈。

---

### 需求 6：边界情况与回退

**用户故事：** 作为一名 QA，我希望任何调试功能都不会因"地图尚未生成"、"选中地块为 null"、"数据为 NaN"等边界情况而崩溃或污染玩家路径。

#### 验收标准

1. WHEN 项目在"未生成地图"状态下（如 `_current_map == null`）打开 Debug 控制台 THEN 系统 SHALL 正常显示面板，所有需要 map 的按钮置灰或弹出提示"请先生成地图"，不得报错。
2. IF 某个 cell 的数据字段读出 NaN / Inf（历史存档、未初始化等异常） THEN overlay shader SHALL 把该 cell 渲染为中性灰色，并在 Telemetry 里以黄色文字计数一次"invalid cells: N"。
3. WHEN 项目打包为 Release THEN 系统 SHALL **仍**保留 Debug 控制台与 Overlay（因为本项目定位为气候沙盒，Debug 即玩法一部分），但控制台默认关闭、快捷键保留，不在 TopBar 显示入口按钮。
4. IF 用户反复快速切换 overlay 模式（如连按快捷键） THEN 系统 SHALL 在 200ms 内完成全部切换且不残留上一次的 uniform 状态。
5. WHEN overlay 或 Debug 控制台代码报错（如 shader 编译失败） THEN 系统 SHALL 在日志打印明确错误 + 自动把 overlay 回退到 `NONE`，不得让主场景进入黑屏或卡死。

---

## 非目标（Out of Scope）

为了保持本次任务可控，以下内容**不**在范围内，需要时单独立项：

- 不改动现有的 `main.tscn` 中 `TopBar` / `RightPanel` 结构。
- 不新增 per-cell 的数据字段；所有 overlay 通道都基于现有 `HexCell` / `WorldData` / `WorldClock` 可读字段。
- 不做 overlay 数据的历史时间轴（时间回放）；数据始终是"当前帧"的快照。
- 不做 3D 透视/高度图可视化；保持当前 2D 六边形 + 顶视角。
- 不改造现有的 F6/F7/F8 快捷键逻辑（它们继续有效，只是 Debug 控制台成为更便捷的等价入口）。
- 不处理多语言（中/英切换）；文字暂用中文，沿用 RightPanel 的语言风格。

---

## 成功标准

- 开发者在运行时能够在 ≤ 2 秒内（通过 UI 点击或快捷键）切换到任一数据通道的 overlay 并看到全地图可读的颜色分布。
- 打开 Debug 控制台后，现有通过 F6/F7/F8 + @export 分散暴露的调试开关，**至少 80% 可通过控制台 UI 操控**，且一次 toggle 响应时间 ≤ 16ms（1 帧）。
- Overlay 模式为 `NONE` 时，帧时间与本次改造前对比偏差 ≤ 0.3ms（无回归）。
- 所有需求的 EARS 验收标准均可被手动 QA 清单覆盖；每个数据通道至少有一张截图作为视觉基线。
