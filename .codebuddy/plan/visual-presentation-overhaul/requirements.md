# 需求文档 — 游戏画面表现系统性优化 (Visual Presentation Overhaul)

## 引言

### 背景
Project Keynes 目前的实时渲染画面存在系统性的表现力不足：

1. **天气表现粗糙**
   - 雨云仅为一个白色 radial-fade 圆盘叠加 `BLEND_MUL`，在截图上表现为大块生硬的"黑块/灰块"，没有体积感、没有软边、没有流动。
   - 降雨只有 ~80 个竖直雨点粒子，范围小、密度稀、看起来"只有一个点往下撒"。
   - 降雪（BLIZZARD）仅有粒子雪花，地面没有积雪视觉反馈。
   - 干旱（DROUGHT）/ 热浪（HEATWAVE）仅靠地形 shader 的轻微调色，缺乏裂地、热浪扭曲等标志性视觉语言。
   - 没有"云在地面的投影"随云层滚动的表现（现状的阴影是跟 front 圆心死死绑定的硬圆）。

2. **昼夜变化缺失**
   - `WorldClock` 只有"日/季/年"三层，没有"时辰/小时"概念，shader 也没有 `time_of_day` uniform；整个游戏永远是同一亮度、同一色温的"白天"。

3. **水体表现缺失**
   - 海洋、河流、湖泊共用同一套陆地 shader 的底色，没有粼光（specular highlight）、没有法线扰动、没有浪花带，也没有海岸冲刷的白边。
   - 洋流（ocean current）在底层数据中尚未建模/未可视化，玩家完全无法感知。

4. **风带 / 季风感知弱**
   - 风带模型 `wind_belt.gd` 数据已存在（信风 / 西风 / 极地东风 / ITCZ / 季风），但画面上没有任何指示：没有流线、没有粒子漂移、没有在云/雨角度上体现。

### 目标范围
本次优化是一次**系统性升级**，覆盖以下画面子系统：
- 天气视觉（雨 / 雪 / 雾 / 雷暴 / 干旱 / 热浪 / 季风）
- 昼夜循环（日照方向 / 色温 / 亮度 / 地表阴影）
- 水体材质（海洋 / 河流 / 湖泊 / 海岸带）
- 洋流与季风的"可感知"可视化
- 极端气候的地面反馈（积雪 / 裂地 / 热浪扭曲）

### 非目标（显式排除）
- 不改动地形生成算法（`map_generator.gd` 的高度/温度/湿度/植被逻辑保持不变）。
- 不引入 3D 几何，保持现有 2D Node2D + Shader + GPUParticles2D 架构。
- 不重写 `world_map.gdshader` 的地形着色主体逻辑，只做**增量扩展**（新增 uniform + 新增分支）。
- 不替换 `WeatherLayer` 的节点组织方式（`_overlay_quad / _shadow_root / _particles_root` 三级结构保留）。

### 关键约束
- **视觉风格基调（已决策）**：采用**风格化 PBR（Stylized PBR）**。即：保留 PBR 的物理光照逻辑（方向光 NdotL、菲涅尔、粗糙度控制的高光）与 HDR 色温叠加，但色彩、笔触、法线扰动幅度都做**艺术化简化**，与当前手绘地形插画风格（非真实系）兼容，不做电影级写实。
- **昼夜节奏（已决策）**：**1 个游戏季 = 1 次完整昼夜循环**。即 `day_phase` 在一个 `days_per_season`（默认 30 天）游戏周期内从 0 推进到 1 再回到 0，白天/夜晚各占约 15 个游戏日的时间感。
- **分层原则（已决策）**：**表现层不得掺和逻辑层**。所有洋流/风向/季风的**数据来源**必须来自 `MapGenerator` / `WorldData` / `WindBelt` 等逻辑层已有或新增的字段；渲染层（`world_map.gdshader` / `weather_overlay.gdshader` / `WeatherLayer` / `hex_renderer.gd`）只消费这些数据，禁止自行推导或决策气候逻辑。
- **性能底线**：优化后在 `cells=2400` 的默认地图上帧时间不得超过当前基线的 130%；`WeatherLayer._active_count == 0` 时应保持当前"整层 invisible + 停止 process"的省电路径。任务规划阶段必须包含**性能基线采样子任务**以量化该指标。
- **确定性**：所有"风动/云动/水波"的视觉噪声必须基于 `world_time`（或 `season_phase` / `day_phase`）驱动，不得引入不可重放的 `randf()` 抖动（离屏贴图生成阶段除外）。
- **Godot 版本**：沿用当前项目的 Godot 4.x + Forward Mobile + d3d12 渲染后端，不引入 Compositor/后期新插件。
- **命名一致性**：新增 uniform 命名需与现有 `world_time / world_origin / world_size / season_phase / weather_strength / climate_anomaly` 风格保持一致（snake_case，无匈牙利命名）。

---

## 需求

### 需求 1：体积化、流动化的云层与雨云表现

**用户故事：** 作为玩家，我希望雨云看起来像"会飘、会变形、有厚度的云"，而不是一个固定的黑色圆盘，以便我一眼就能分辨出"这里正在下雨"而不是"贴图坏了"。

#### 验收标准

1. WHEN 一个 `WeatherFront` 的类型为 `RAIN / STORM / MONSOON / BLIZZARD` THEN 云层视觉 SHALL 由**多层 fBm 噪声**（至少 2 个 octave，偏移受 `world_time` 和 per-front 盛行风向驱动）取代现在的单张 radial-fade 圆盘。
2. WHEN 云层渲染 THEN 其**alpha 轮廓** SHALL 呈不规则边缘（噪声门限 + 柔和 smoothstep），且与 `front.radius` 平滑衔接，不得在 `front.radius` 边缘形成硬边。
3. WHEN `front.intensity` 变化时 THEN 云层的**厚度 / 暗度 / 覆盖率** SHALL 在 `[0, 1]` 的 intensity 范围内连续变化，不出现"要么看不见要么一片死黑"的开关式跳变。
4. WHEN 云层飘动 THEN 其采样坐标的 scroll 向量 SHALL 来自 `WindBelt.wind_at(ny_at_front, season_phase)` 的归一化风向（不同纬度的云飘动方向不同）。
5. WHEN 地图上存在任意云层 THEN 云层在地面 SHALL 投下**对应形状的阴影**（不再是"完美圆盘"），阴影的 alpha 与云层 alpha 使用同一张噪声结果以保证形状一致。
6. IF 玩家启用某个"经济/性能"降级开关（预留 `weather_overlay_quality` uniform，0/1/2 三档） THEN 云层 shader SHALL 在 quality=0 时退化为当前单层圆盘实现，在 quality=2 时启用完整 2 octave fBm。

---

### 需求 2：真实化的降水与极端天气粒子表现

**用户故事：** 作为玩家，我希望下雨时整个云层覆盖区都在"下雨"，暴雪时地面上能看到"变白"，干旱时地面会"裂"，以便我不需要看 UI 就能判断当前气候。

#### 验收标准

1. WHEN 一个 RAIN/STORM/MONSOON front 激活 THEN 雨滴粒子的 `amount` SHALL 随 `front.radius` 与 `front.intensity` **自适应放大**（当前写死 80 粒，需改为密度制：粒子密度 × 覆盖面积），在视觉上达到"整个云下面都在下雨"。
2. WHEN STORM 类型的 front 激活 THEN 粒子层 SHALL 额外叠加"闪电一瞬白屏/局部亮斑"效果（基于 `world_time` 驱动的低频闪烁，频率 < 1Hz，且不打断玩家的操作感）。
3. WHEN BLIZZARD front 激活 THEN `world_map.gdshader` 的地表着色 SHALL 在该区域内根据 `front.intensity` 叠加**积雪白色**（不是全局染白，而是受地形坡度/植被调制：平地/低地易积雪，陡坡/森林内部少积雪）。
4. WHEN DROUGHT front 激活 THEN 地表在该区域内 SHALL 叠加**裂地/偏黄枯化**的视觉反馈（通过噪声调制或 cracked-earth 贴图），当前仅做色相偏移的做法 SHALL 被替换为"色相偏移 + 裂纹噪声"。
5. WHEN HEATWAVE front 激活 THEN 该区域 SHALL 叠加一个非常轻微的**屏幕扭曲**（基于正弦 + 噪声的 UV 抖动，幅度 ≤ 2px），且扭曲强度随 `front.intensity` 缩放。
6. IF 玩家在"暂停"状态 THEN 所有粒子与噪声的时间驱动 SHALL 停止推进（天气 shader 应读取 `WorldClock.paused` 或 `WeatherLayer` 自身不再累加 `_world_time`）。

---

### 需求 3：昼夜循环系统（Day/Night Cycle）— 每季一循环

**用户故事：** 作为玩家，我希望随着"时间"推进能看到白天转向黄昏、夜晚再到清晨，以便游戏世界有呼吸感，而不是一直停留在"正午白光"。昼夜节奏应与季节节奏对齐——**一个季节内完整走一次昼夜循环**，让季节切换本身承担"年复一年"的时间感，昼夜承担"短周期"的呼吸感。

#### 验收标准

1. WHEN `WorldClock` 每帧推进 THEN 它 SHALL 新增一个**归一化 `day_phase` ∈ [0, 1)** 的派生属性，其中 `day_phase = fposmod(current_day, days_per_season) / days_per_season`，即**1 个季节（默认 30 游戏日）= 1 次完整昼夜循环**；相位分布：0.0 = 日出，0.25 = 正午，0.5 = 日落，0.75 = 午夜。
2. WHEN `main.gd` 把时间同步到 renderer THEN 除现有的 `season_phase` 之外 SHALL 同时传入 `day_phase`，并最终写入 `world_map.gdshader` 和 `weather_overlay.gdshader` 的 uniform。
3. WHEN shader 应用昼夜着色 THEN 地表 SHALL 在 `[日出 / 正午 / 黄昏 / 夜晚]` 四个时相之间做**色温 + 亮度**的连续插值（清晨/黄昏偏暖橙、正午偏白、夜晚偏冷蓝），插值方式为 `smoothstep`，不得出现时相切换的硬跳变。着色计算 SHALL 符合**风格化 PBR**约定：光源方向由 `day_phase` 推导，地表应用 NdotL 调制，但色温/粗糙度/饱和度曲线为艺术化手调而非真实物理值。
4. WHEN 夜晚 THEN 地表亮度 SHALL 降低至白天的 `[0.35, 0.55]` 区间（可调 uniform），且水体的粼光高光 SHALL 转为月光风格（蓝白、更集中）。
5. WHEN `day_phase` 推进 THEN 可选的**方向性阴影**（如山脉、森林的 drop-shadow）SHALL 根据"太阳方位角"旋转方向（正午阴影偏短且朝正下方，早晚阴影偏长且斜向），本期允许仅以"等效光照方向向量"体现在 shader 的 NdotL 项上，不要求额外 pass。
6. IF `day_phase` 更新频率过高导致性能下降 THEN WorldClock SHALL 限制 day_phase 的发射频率（例如每 0.005 phase 才推一次 uniform，相当于 x1 速度下约 0.15 秒一次），避免每帧都重写 shader 参数。
7. IF 玩家暂停游戏 THEN `day_phase` SHALL 停止推进，但最后一帧的 uniform 不被覆盖（画面保持在暂停那一刻的时相）。
8. WHEN 游戏速度切换到 x5 / x20 THEN `day_phase` SHALL 随之加速，但 shader uniform 的节流策略（验收标准 6）仍然生效，避免高倍速下瞬时刷参导致 CPU/GPU 通道过载。

---

### 需求 4：水体（海/河/湖）独立材质表现

**用户故事：** 作为玩家，我希望一眼就能在地图上区分海洋、湖泊、河流，以及看到水面反光在动，以便我对地理环境有直觉判断，而不是一片"同色蓝块"。

#### 验收标准

1. WHEN shader 渲染一个被判定为 `LF.DEEP_OCEAN / OCEAN / COAST / LAKE / RIVER` 的像素 THEN 它 SHALL 使用一条**独立的水体着色分支**，该分支至少包含：基底色（按深度/类型分层）、低频流动的法线扰动高光、基于 `world_time` 的 `fbm` 波浪噪声。
2. WHEN 像素属于 `DEEP_OCEAN` vs `OCEAN` vs `COAST` THEN 基底色 SHALL 呈现明显**深度梯度**（DEEP_OCEAN 最深蓝、COAST 偏绿松石 / 浅），而不是统一色。
3. WHEN 像素位于"海岸边 cell"（land-water 交界的一圈） THEN 该像素 SHALL 叠加**浪花白边**（通过到最近陆地的等效距离 + 正弦时间相位调制），模拟海浪拍岸的节奏感。
4. WHEN 像素属于 `LAKE` THEN 水面 SHALL 使用比海洋**更柔、更低频**的波纹（幅度更小、波速更慢），以视觉上区分于外海。
5. WHEN 像素属于 `RIVER`（`has_river == true`） THEN 河道的水色 SHALL 与其下游海/湖方向平滑过渡，不得出现河流底色与周围湖泊底色对不上的断层。
6. WHEN `day_phase` 处于白天 THEN 水面高光 SHALL 使用白/浅黄；WHEN 处于夜晚 THEN 高光 SHALL 使用冷蓝（与需求 3.4 保持一致）。
7. WHEN `BLIZZARD` 覆盖水面 THEN 对应水体 SHALL 叠加一层薄冰效果（偏白、反射更柔、波纹幅度减半），以呼应"冬季海冰"的直觉。
8. WHEN 水体渲染 THEN 新增的 fbm / normal 扰动 SHALL 复用现有 `noise_tex` uniform，不得因此引入新的大贴图 upload（避免显存/IO 成本升高）。

---

### 需求 5：洋流与季风的可视化（数据来自逻辑层）

**用户故事：** 作为玩家，我希望能肉眼看到"海水在往哪流"、"风从哪吹"，以便我能理解为什么某些海岸比其他地方更湿润、为什么季风季节的农业会变化。作为开发者，我希望**洋流数据来自地图数据层（MapGenerator / WorldData）**，渲染层只做可视化，不在 shader 或 WeatherLayer 中自行推导气候逻辑。

#### 验收标准

1. WHEN `MapGenerator` 生成地图 THEN 它 SHALL 为每个海洋单元（`is_water == true` 的 `HexCell`）写入一个**洋流向量 `ocean_current: Vector2`**（归一化方向 + 强度 0~1），字段存储于 `HexCell` 或等价的 `WorldData` 流场数组；陆地单元该字段为零向量。
2. WHEN `WorldData` 被 `HexRenderer` 消费 THEN 渲染层 SHALL 把洋流向量场**打包成一张低分辨率纹理**（如 RG16F 或 RGBA8 编码）作为新的 uniform（如 `ocean_current_tex`）上传给 `world_map.gdshader`；渲染层不得以任何形式重新推导洋流方向。
3. WHEN shader 渲染被标记为海洋的像素 THEN 它 SHALL 采样 `ocean_current_tex`，以该方向 scroll 一张流线噪声（复用 `noise_tex`），形成**低对比、持续流动的流线纹理**，视觉上表现为"缓慢流动的海水"；陆地像素不采样也不渲染流线。
4. WHEN 玩家开启"洋流可视化" toggle（UI 新增一个按钮 / 快捷键，默认关闭） THEN 海面流线 SHALL 切换为**更高对比度、带箭头感的明显流向图**，便于教学/调试；关闭时回到低对比模式。
5. WHEN 季风（MONSOON type front）激活 THEN 陆地上对应区域 SHALL 叠加一层**轻微的风吹流线**（复用 overlay 的 shader 分支，不新增粒子节点），方向取自 `WindBelt.wind_at(ny, season_phase)`（逻辑层已有函数），表现"季风带来的潮湿气流"。
6. WHEN `season_phase` 穿越季风反相边界（北半球夏/冬切换） THEN 低纬度陆地的"风纹"方向 SHALL 在 1~2 个游戏日内平滑反转（通过在 shader 中对 `season_phase` 附近做 smoothstep 插值两个季节的 `WindBelt.wind_at` 结果），不能瞬间 180° 跳变。
7. WHEN 风带可视化开启 THEN 画面上不同纬度带（ITCZ / 信风 / 西风 / 极地东风）SHALL 在海面各自显示**不同方向**的流线，玩家可以清晰看出纬度带划分。
8. IF 新增的流线/风纹渲染在低端设备上掉帧 THEN 系统 SHALL 提供关闭开关（与需求 5.4 的 toggle 合并），关闭后立刻回到当前无流线的水面。
9. IF `MapGenerator` 暂未实现洋流向量场 THEN 任务规划 SHALL 优先完成该逻辑层字段的实装（作为前置任务），而非让渲染层用 `WindBelt` 兜底推导。

---

### 需求 6：整合、性能与可控性

**用户故事：** 作为开发者/调参玩家，我希望画面表现所有新增效果都可通过统一的 uniform / 开关调节，性能不显著退化，且改动是**分层的可回退的**，以便后续调优和 bugfix。

#### 验收标准

1. WHEN 功能上线 THEN 所有新增的视觉效果 SHALL 受以下全局 uniform 控制，并分别在 `main.gd` 的 `@export` 中暴露：
   - `visual_quality ∈ {0, 1, 2}`（低/中/高）
   - `day_night_enabled ∈ {true, false}`
   - `water_effect_enabled ∈ {true, false}`
   - `ocean_current_enabled ∈ {true, false}`
   - `extreme_weather_ground_effect_enabled ∈ {true, false}`（积雪/裂地/扭曲的地面反馈总开关）
2. WHEN 所有新开关关闭 THEN 画面 SHALL 退化到**当前版本的视觉效果**（即本次改动可被完整关闭回退）。
3. WHEN `cells=2400` 的默认地图稳定运行 30 秒 THEN 启用全部新效果后的平均帧时间 SHALL **不超过基线的 130%**；如果超过，相关效果 SHALL 优先退化到 `visual_quality=1` 的实现。
4. WHEN 没有任何活跃 front（`_active_count == 0`）且白天时相 THEN `WeatherLayer` SHALL 继续保持当前的"整层 invisible + 停止 process"的省电路径，不得因为新增了"空时仍要跑风纹"的逻辑而破坏这条快路径。
5. WHEN shader 增加新的分支与 uniform THEN 所有新代码 SHALL 位于现有三个 shader 文件（`world_map.gdshader` / `weather_overlay.gdshader` / 以及可选新增的**一个**水体/昼夜 shader include），不得引入 3 个以上新 shader 文件。
6. WHEN 任何一个视觉模块（云/雨/雪/水/昼夜/洋流）出 bug 导致画面异常 THEN 开发者 SHALL 可以通过关闭该模块对应的 `@export` 开关迅速隔离问题，无需回滚代码。
7. IF UI 上需要展示当前时辰 THEN `UI/TopBar/TimeLabel` 的文本格式 SHALL 从现在的 `"Y%d D%d %s"` 扩展为包含 day_phase 提示的形式（如 `"Y0 D9 Spring 14:00"`），或通过一个独立的 `DayPhaseLabel` 呈现。

---

## 关键决策记录（已确认）

以下事项在需求阶段由用户**明确决策**，作为后续任务规划和实现的硬约束：

1. **视觉风格基调** → **风格化 PBR**。保留 PBR 的光照逻辑（方向光 NdotL、菲涅尔、粗糙度高光），但色彩/笔触/法线扰动做艺术化简化，与当前手绘地形风格统一，不做电影级写实。
2. **day_phase 节奏** → **1 个游戏季 = 1 次完整昼夜循环**。映射公式为 `day_phase = fposmod(current_day, days_per_season) / days_per_season`；默认配置 `days_per_season = 30` 意味着 x1 速度下约 30 秒完整走一次昼夜。
3. **洋流数据来源** → **必须来自逻辑层（MapGenerator / WorldData）**。渲染层只消费，不推导。`MapGenerator` 需新增"洋流向量场"数据结构（每个海洋 cell 存 `ocean_current: Vector2`）；表现层不得掺和逻辑层。
4. **性能基线采样** → **需要**，作为任务规划阶段的独立前置子任务，先采集当前基线帧时间，再逐模块验证 130% 上限。
