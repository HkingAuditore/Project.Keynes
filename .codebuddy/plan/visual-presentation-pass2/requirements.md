# 需求文档 — 画面表现第二轮深化（Visual Presentation Pass 2）

## 引言

上一轮（`visual-presentation-overhaul`）完成了昼夜循环、风格化 PBR 地表、多层 fBm 云、水体独立分支、极端天气地表反馈、洋流向量场等十项改造。实际运行后，用户针对「**氛围强度**」与「**光照一致性**」提出第二轮反馈：

1. 黑夜过暗导致玩家无法操作，白天占比主观上太短
2. 海面缺乏"波光粼粼"的高光与深浅层次，洋流只在近岸可见
3. 当前地表光照未充分利用高度图梯度，缺乏整体立体感
4. 雨雪粒子视觉密度不足，玩家感知不到天气事件
5. 云层 / 降水粒子 / 极端天气 overlay 的亮度独立于地表光照，夜晚云依然亮白、白天云缺少日光染色

核心问题可归结为：**项目目前没有一个统一的 Time-of-Day（TOD）全局光照中枢**——每个层各自用 `day_phase` 做局部 tint，导致整体不协调。本轮要建立一套**单一 TOD 光照参数源 → 多消费者**的体系，把地表、水体、云层、粒子、UI 都接到同一根「太阳」下。

本轮仍受上一轮《关键决策记录》硬约束：**风格化 PBR · 1 季 = 1 昼夜 · 洋流数据来自逻辑层 · 性能基线必采**。此外本轮新增一条硬约束：**TOD 参数必须单一来源**——任何层都不得自行解读 `day_phase` 的色温 / 方向 / 亮度，必须从 `TODProfile` 统一读取。

---

## 需求

### 需求 1：全局 TOD 光照中枢（TODProfile）

**用户故事：** 作为美术 / 玩家，我希望地表、水体、云、粒子、UI 的色温与亮度在一天内始终协调，以便看到一个整体性的"日光世界"而非各层颜色拼盘。

#### 验收标准

1. WHEN 项目启动 THEN 系统 SHALL 提供一个全局单例 `TODProfile`（GDScript autoload 或 `WorldClock` 的子组件），对外暴露稳定字段：`sun_dir: Vector3`、`sun_color: Color`、`ambient_color: Color`、`sky_tint: Color`、`exposure: float`、`night_factor: float ∈ [0,1]`
2. WHEN `WorldClock.day_phase` 变化达到节流阈值 THEN `TODProfile` SHALL 重新插值上述字段并发射 `tod_changed(profile)` 信号
3. WHEN `HexRenderer` / `WeatherLayer` / UI 时间栏 收到 `tod_changed` THEN 其 SHALL 把对应字段写入自身 shader uniform（如 `tod_sun_color`、`tod_ambient_color`、`tod_sun_dir`、`tod_night_factor`）
4. WHEN 任何 shader 需要昼夜信息 THEN 其 SHALL 从 TOD uniform 读取，禁止再从 `day_phase` 自行派生色温或日光方向（只读 `day_phase` 用于动画相位，如粼光相位、云移相位）
5. IF `day_night_enabled == false` THEN `TODProfile` SHALL 输出一组固定的"永昼"参数（`sun_dir=(0.4,-0.7,0.6)`、`sun_color=白`、`night_factor=0`），保证回退路径

---

### 需求 2：昼夜时间曲线与夜晚亮度重校

**用户故事：** 作为玩家，我希望白天占比更长、夜晚不至于伸手不见五指，同时日出 / 日落仍有氛围感，以便在夜晚仍能正常操作游戏。

#### 验收标准

1. WHEN 计算 `day_phase` 到「实际光照相位」的映射 THEN 系统 SHALL 应用一条可配置曲线（默认 `daylight_ratio = 0.65`），使「白天（高光照）段」覆盖 `day_phase ∈ [0.08, 0.73]`，「夜晚段」只占 `[0.80, 1.0] ∪ [0.0, 0.03]`，其余为黄昏 / 黎明过渡带
2. WHEN 处于夜晚段 THEN `TODProfile.night_factor` SHALL 在 `[night_factor_min, night_factor_max]` 之间取值，默认 `night_factor_min = 0.55`、`night_factor_max = 0.72`（比上一轮 0.35~0.55 更亮）
3. WHEN 处于夜晚段 THEN `sun_color` SHALL 退化为一条柔和的"月光"（冷白偏蓝 `Color(0.65, 0.72, 0.90)`），保留方向性阴影但幅度压低
4. WHEN 处于日出 / 日落过渡带 THEN `sun_color` SHALL 在 `1~2` 秒游戏时间内从暖橙渐变到正午白（或反向），避免上一轮观察到的"日出色温突然跳变"
5. WHEN 玩家修改 `daylight_ratio` / `night_factor_min` THEN 结果 SHALL 在下一帧生效且不需重启
6. IF `night_factor_min < 0.35` THEN 系统 SHALL 在日志中警告（避免用户误设回过暗模式）

---

### 需求 3：高度图法线 + 方向光一致性

**用户故事：** 作为玩家，我希望陆地的立体感更强、山脉有清晰的向阳 / 背阳面，以便地形起伏一眼就能看懂。

#### 验收标准

1. WHEN `world_map.gdshader` 着色陆地片段 THEN 其 SHALL 在 fragment 中以 Sobel 或中心差分从 `height_tex` 计算 tangent-space 法线 `N`（已有 4-tap 采样，复用即可，升级到 8-tap Sobel 也允许）
2. WHEN 法线构造完成 THEN shader SHALL 以 `NdotL = max(dot(N, tod_sun_dir), 0)` 计算方向光漫反射，替代当前的"双光源 hillshade 色板乘法"
3. WHEN 法线构造完成 THEN shader SHALL 同时计算 `NdotH`（Blinn-Phong 半向量）做风格化高光，幅度受 `roughness_map`（可从 `biome` 查表得到：雪 / 冰 / 水光滑、沙 / 森林粗糙）调制
4. WHEN `day_night_enabled == false` THEN 法线计算仍保留、但日光方向使用 `TODProfile` 的"永昼"值（保证地形立体感与昼夜解耦）
5. WHEN 坡度法线 `|∇h| < epsilon`（近似平地） THEN shader SHALL 回退到无方向光的纯 albedo + ambient，避免平原出现噪声级的方向光伪影
6. IF `visual_quality == 0` THEN 法线计算 SHALL 退化为 4-tap 中心差分（与现有一致），不做 Sobel

---

### 需求 4：水面深浅梯度 + 粼光 + 洋流全覆盖可视化

**用户故事：** 作为玩家，我希望大洋中央就能看出洋流、白天海面"波光粼粼"、夜晚有月光鳞片，以便水体看起来有生命力。

#### 验收标准

1. WHEN 水体片段着色 THEN shader SHALL 根据 `distance_to_shore`（可由 `height_tex` 小于 `sea_level` 的程度近似或邻域采样估算）做深浅色梯度：`COAST → shallow blue → OCEAN → deep blue → DEEP_OCEAN → navy`
2. WHEN 水体片段着色且 `day_phase` 处于白天 THEN shader SHALL 在水面叠加"高频粼光"（基于 `noise_tex` 的 2 octave fBm + `NdotH` 半向量高光），粼光速度与 `day_phase` 解耦、仅跟 `world_time` 推进
3. WHEN 水体片段着色且 `day_phase` 处于夜晚 THEN 粼光 SHALL 切换为"月光鳞片"（冷蓝白色 + 更疏的噪声频率 + 幅度降为白天的 0.5）
4. WHEN `ocean_current_enabled == true` THEN 洋流流线 SHALL 在整个海域（DEEP_OCEAN / OCEAN / COAST）以统一强度出现，而不是像当前仅近岸可见——调整噪声采样频率与 scroll 振幅使流线在 DEEP_OCEAN 也清晰可辨
4. WHEN `ocean_current_debug == 1`（F6 toggle） THEN 流线对比度 SHALL 进一步增强为"带箭头感的流向图"
5. WHEN 水面法线存在波动 THEN 粼光高光 SHALL 使用"水面法线"（由 fBm 波法线生成）+ `tod_sun_dir` 计算 `NdotH`，保证粼光方向与全局太阳方向一致
6. IF `water_effect_enabled == false` THEN 水体回退到上一轮前的简单深浅色，不计算粼光与流线

---

### 需求 5：降水与极端天气粒子视觉强化

**用户故事：** 作为玩家，我希望下雨时能清楚看到雨丝、下雪时能看到雪花堆积的氛围，以便天气事件有存在感。

#### 验收标准

1. WHEN RAIN / STORM / MONSOON front 激活 THEN 粒子 `amount` SHALL 按"覆盖面积 × 密度"计算且下限从当前 `MIN` 提升（默认从约 80 提升到 180），雨丝方向受 `WindBelt.wind_at` 驱动呈现 15°~30° 倾斜
2. WHEN 雨丝渲染 THEN 其 SHALL 使用细长椭圆（`scale_y = 3 * scale_x`）替代当前圆点，颜色 `Color(0.85, 0.88, 0.96, 0.75)`，`BLEND_MODE_ADD` 让亮度更突出
3. WHEN BLIZZARD front 激活 THEN 雪花粒子 `amount` 下限 SHALL 提升到 120，大小随机化 0.5~1.4，速度更慢并带水平漂移（风驱动）
4. WHEN STORM front 激活 THEN 闪电节拍 SHALL 每 2~4 秒触发一次，持续 80~120ms，同时 overlay `storm_flash` uniform 抬升至 0.6 使整个屏幕短暂提亮（模拟全局闪光）
5. WHEN 粒子颜色最终输出 THEN 其 SHALL 乘以 `tod_sun_color × (1 - 0.5 * tod_night_factor)`，确保夜晚雨雪偏冷灰、白天偏暖白
6. IF `visual_quality == 0` THEN 粒子 `amount` 上限 SHALL 减半，BLEND_ADD 降级为 BLEND_MIX

---

### 需求 6：云层与 overlay 接入 TOD

**用户故事：** 作为玩家，我希望夜晚的云看起来是"月光下的暗云"而非"白天明亮的云"，以便云与地表的色调一致。

#### 验收标准

1. WHEN `weather_overlay.gdshader` 片段着色 THEN 其 SHALL 从 uniform 读取 `tod_sun_color` / `tod_ambient_color` / `tod_night_factor`
2. WHEN 云色输出 THEN 其 SHALL 为 `cloud_base_color * tod_sun_color * (1 - 0.6 * tod_night_factor) + tod_ambient_color * 0.3`，即白天云接日光、夜晚云退到环境色
3. WHEN STORM 类型 front THEN 云底色 SHALL 额外压暗 30%（乌云），闪电亮斑仍保持白色（因为闪电本身是发光源）
4. WHEN BLIZZARD 类型 front THEN 云底色 SHALL 偏冷白，夜晚叠加柔和蓝绿色（极光暗示），夜晚 `tod_night_factor > 0.5` 时开启这一分支
5. WHEN 云阴影（投影在地表的那层 Sprite） THEN 其 `modulate` SHALL 乘 `tod_night_factor` 的反比——夜晚云阴影几乎不可见（因为夜晚地表本就暗）
6. IF `weather_overlay_quality == 0` THEN 仍使用单层圆盘但颜色依然走 TOD tint（保持一致性，只省 fBm 成本）

---

### 需求 7：性能基线保持 + 回归测试

**用户故事：** 作为开发者，我希望这一轮深化不让帧时间再劣化 10% 以上，以便保持上一轮门禁结果有效。

#### 验收标准

1. WHEN 本轮任务完成 THEN 系统 SHALL 在 `cells=2400` 默认地图稳态 30 秒跑三组对照：「上一轮全开」/「本轮全开」/「本轮全关」
2. WHEN 对比「本轮全开」与「上一轮全开」 THEN 平均帧时间 SHALL ≤ 上一轮的 110%，P95 SHALL ≤ 上一轮 P95 的 115%
3. IF 超过上述阈值 THEN `visual_quality` 强制降到 1 且在 shader 内关闭"高频粼光"与"8-tap Sobel 法线"
4. WHEN 把 `@export day_night_enabled` 关闭 THEN 视觉 SHALL 回到上一轮全关状态（TOD 输出永昼参数）
5. WHEN 所有新开关单独切换 THEN 每个模块 SHALL 可独立隔离不影响其他特性（新开关清单：`daylight_ratio`、`tod_exposure`、`water_sparkle_enabled`、`rain_density_boost_enabled`、`cloud_tod_tint_enabled`）
6. WHEN 本轮结束 THEN `.codebuddy/plan/visual-presentation-pass2/perf-report.md` SHALL 写入三组数据对照

---

## 关键决策记录（已确认）

| # | 决策点 | 选定方向 | 本轮硬约束 |
|---|--------|----------|-----------|
| 1 | 光照模型 | 风格化 PBR（沿用上一轮） | 物理流程（NdotL、NdotH、菲涅尔）保留，只在艺术化上手调 |
| 2 | 昼夜节奏 | 1 季 = 1 昼夜（沿用上一轮） | 本轮只重塑"白天 / 夜晚 / 黄昏"在一天中的占比曲线，不改周期 |
| 3 | 数据分层 | 洋流 / 风场数据来自逻辑层（沿用上一轮） | 粼光 / 波浪噪声可由 shader 程序化生成（这类数据无逻辑意义） |
| 4 | 性能基线 | 必采 | 本轮门禁：帧时间 ≤ 上一轮 110% |
| 5 | TOD 单一来源 | `TODProfile` 作为唯一 source of truth | 任何层都不得自己从 `day_phase` 推导色温 / 日光方向 |

## 非目标（本轮显式不做）

- 不实现完整的体积云 / 体积雾（成本过高，风格化原型不需要）
- 不实现体积光柱 / 上帝光（Godrays）
- 不引入延迟渲染管线切换（当前 2D canvas 管线足够）
- 不对地图生成逻辑做任何改动（高度 / 温度 / 湿度 / 植被 / 洋流都沿用上一轮）
- 不新增 per-cell 的光照烘焙（保持实时计算）

## 风险与开放项

| # | 风险 | 缓解 |
|---|------|------|
| R1 | 8-tap Sobel 在 2048×1536 高度图上成本未知 | 用 `visual_quality` 开关退化为 4-tap；先采样实测 |
| R2 | 粒子 `amount` 提升到 180 可能在弱机上掉帧 | 由 `visual_quality==0` 回到 80 |
| R3 | `TODProfile` 重构可能打破上一轮已接好的 `day_phase` 消费者 | 保留 `day_phase` uniform 不删，仅新增 `tod_*` uniform；两套并行，消费者逐个迁移 |
| R4 | 用户对"白天占比"主观偏好不同 | 通过 `daylight_ratio` export 暴露，不写死 |
