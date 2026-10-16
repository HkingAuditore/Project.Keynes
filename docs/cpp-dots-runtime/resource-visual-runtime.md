# 地块资源实景

资源层是现有渲染系统的只读消费者。`ResourceVisualCatalog` 审计完整的
`ResearchSignalCatalog.compile_native_catalog()`（包括 NETWORK_SIGNAL_ROWS）和
`ResourceProfileRegistry`：20 种生物、31 类资源、51 个稳定 ID。
牛、羊、猪、山羊、马、骆驼、牦牛分别读取自己的占领位；不得由牧场容量推断物种。

## 客观存在与玩家认知

可见地块上，未识别的矿物和物种也有实景；名称、说明、资源面板及筛选仍遵守现有发现规则。
实景不授予科技发现或科研信号。野生动物总储量只表达踪迹，动物个体数只是视觉示意。

`BuildingVisualIntelCache.resource_observations` 是独立于建筑 CSR 的逐格观测表。
仅采样当前发布的可见 MapData；无建筑地块也保留资源。隐藏格不更新储量、占领或气候，
shader 保留最后观测并冻结动作；旧存档不以当前隐藏状态补齐未知资源。
每行包含 51 字节存在/丰度档和 RGBA 气候（温度、湿度、雪、植被活力）。
生物只表达有无；储量除以 `reference_reserve()`，按 0.25/0.70/1.50 分档，
边界有 10% 滞回，归零立即清除。字段名、参考量和生境掩码在目录构建时缓存。

## 地表点缀与资源透镜

`HexRenderer -> ResourceVisualLayer` 复用分块 MultiMesh、独立样式 LUT 和只读观测。
世界视图使用较小的俯视实景，精确识别由资源透镜徽章承担；筛选时透镜自动开启。
透镜按动物圆形、植物圆角方形、矿物六边形分类，保留完整造型及夜间可读性。

每种资源的视觉计划由 `visual_plan()` 决定：

- 陆生植物/动物：小型主体；植物只绘制独立叶冠、穗丛，空隙直接露出原地表。
- 岩石/矿脉/结晶：低覆盖率碎矿砂贴花加小型露头；盐、硝石和硫磺不带封闭底盘。
- 土地容量、黏土、沙、踪迹、陆地油气：柔和贴地痕迹。可耕容量不画已经耕作的田垄。
- 木材：森林本身表达木材，世界视图不叠原木，仅保留透镜徽章。
- 水下油气和鱼群：稀疏半透明 MultiMesh 线索，按水深衰减，鱼群由独立密度控制。

矿物主体默认直径 0.40 hex，动物额外乘 1.15；植物独立使用 0.78 hex，地力贴花 1.20 hex，
其他贴花 quad 直径 0.80 hex。植物群落内密度乘 1.30，仍保留独立叶冠之间的地面空隙。
实景矿物至少丰度档 3（约 0.70 倍参考储量），并按格/资源稳定抽样 32%；动物抽样 40%。
抽样只判定一次，不放入候选点重试循环。植物与地力不受此门槛限制。
观测、资源面板和储量不变；手动透镜或筛选绕过实景门槛，透镜切换使分块重新选取资源。
`area_feather/area_edge_noise` 只处理群落外沿，不能对每片叶或每颗晶体的 SDF
再次大幅羽化，否则小实体会消失。植株间不再使用裸土透明度参数铺设底板。

共五类批次：植物、动物、矿物、水下、地面贴花。资源根节点 z=0，保留相对 z 且
**不得 top_level**；它必须处于 HexRenderer 的绘制子树内，遵守其 show_behind_parent。
主体和环绕副本相对 z=1，树冠 z=2，建筑 z=3；贴花批次排在同层主体之前。
仅将资源改成绝对 z 并不足以维持父级绘制子树之间的遮挡关系。

实例 ABI 为 16 float：transform2D 8 + COLOR 4 + CUSTOM 4。
COLOR 为优先序、透水光、重要度、实例 kind；kind 整数 1/2/3/4 对应主体/贴花/水下/仅徽章，
小数 +0.5 表示不是徽章载体。CUSTOM 为精确 cell index、style index、静态种子和丰度档。
单个资源的贴花与主体只拥有一个徽章载体；格 ID 不经过旧 16 位地图索引。

## 光照与动态

资源与树木共用 `earth_daylight.gdshaderinc`，并复用地形的
`visual_tile_sampling.gdshaderinc` 和 `terrain_horizon.gdshaderinc`。
逐实例 vertex 采样地形法线与 horizon，传递直射可见度、天空可见度和 bent normal；
fragment 组合主体法线与地形坡度，用 `earth_sky_sh()` 做定向天空光和轻微法线 AO 修正。
高光与直射受山体遮蔽影响，接地阴影与材质不再凭空自亮；透镜仍独立保证可读性。

`ResourceVisualLayer.set_terrain_lighting()` 从地形材质同步 horizon/GI 参数。
配置资源、调节 GI 和异步 horizon bake 完成时均重新绑定。
Legacy 读取 Texture2D，tiled 按实际布局编译 MAP_VISUAL_TILED 变体并绑定 Texture2DArray；
正确处理 Mobile/Forward 的 RG16 horizon 与 Compatibility 的 RGBA8。
未绑定 horizon 时回退中性光照。法线/遮蔽数据都来自既有烘焙，不新增烘焙 pass。

扩大植株/地力覆盖时，不能只检查群落中心。fragment 使用既有 height 贴图的 RG 高度与
B 河体通道裁切植物/地面贴花的海岸及实际河道；动物和小型矿石保留中心落地判定，
避免岸边的立体主体被地面水线切成半透明。透镜徽章绕过裁切，水下线索保持原路径。
资源 shader 的材质由已有形态函数生成，不再采样 ResourceVisualAtlas；将图集槽位让给
地形法线、horizon 和 height，共八个 sampler，避免 Compatibility 纹理单元冲突。
地力以不规则草被表达，随湿度/活力转黄或退隐，雪下不铺绿色地毯。

动作由 GPU 静态种子、共享时间和观测可见性驱动，无逐实例 CPU transform 更新或寻路：

- 植物随现有风向与 weather_wind_boost 摆动，个体相位错开，叶冠和穗部有局部变化。
- 动物有分相位的停走、短距离移动、迈步、头颈动作和轻微呼吸。
- 矿石、结晶、土壤和倒木保持静止；隐藏区域 live=0，所有动作冻结。

## 分布、预算和存档

稳定候选点由世界 seed、格和资源 ID 决定；连续世界噪声控制聚簇。
复用实际河体采样、pixel→cell lookup 与聚落 core bucket，拒绝错误水陆域和聚落核心。
目前没有精确树冠占地或全局道路遮罩；树冠遮挡由绘制层级处理。

默认轮选各类主要资源，重要矿物、丰度和稳定噪声决定优先级，筛选项优先。
默认屏幕半径阈值 detailed/simple/fade 为 9/4/1.5px；远景只保留主要资源，亚像素淡出。
环绕副本共享 MultiMesh，离屏不提交。观测 0.30ms、建块 0.45ms，内存纹理最高 10Hz 上传。
资源准备耗时计入已有 detail drain 预算，共享植被上传机会，避免独立上传峰值叠加。

| 档位 | 桌面实例上限 | 移动实例上限 | 每格实例上限 | 每格资源类型 |
|---|---:|---:|---:|---:|
| 低 | 6000 | 1000 | 2 | 1 |
| 中 | 12000 | 2000 | 4 | 2 |
| 高 | 20000 | 4000 | 6 | 3 |

驻留块桌面 128、移动 48。移动使用独立 mobile_quality_tier。
所有外观参数来自 `ResourceVisualProfile` / `data/visual/resource_default.tres`。
资源观测不写入经济/国家状态或它们的 hash。

PKFG v4 在原 v3 建筑情报上追加 `resource_intel_cells/style_ids/bands/climates`。
格 ID 单调、类型和值域、长度、稳定 ID 和气候有限性必须完整验证后原子替换缓存。
v1–v3 可加载，资源记忆为空，重新可见时补齐。

## 验证入口

- `tests/resource_visual_layer_test.gd`：56 项目录、观测/存档、分布、预算、绘制契约检查。
- `tests/resource_visual_render_regression.gd`：17 项真 GPU 检查，覆盖植株/晶体空隙、
  植物/动物动态、静态矿石、隐藏冻结、horizon 明暗、中性回退、Legacy/tiled 一致性、
  HexRenderer 同父级下的树冠遮挡、地力活力/积雪响应、扩大群落河岸裁切、透镜完整轮廓。图像在 tmp/resource_visual_qa/integration/。
- `tests/resource_visual_world_qa.gd`：正式新游戏流程，现有植被/建筑/水面同屏与资源开关对照。
- `tests/resource_visual_gallery.gd`：完整目录、日夜积雪和独立 20k GPU shader 压测。
- `tests/resource_visual_perf_test.gd -- --large`：20 万格观测与分块 CPU 预算检查。

2026-10-16 融合修正已在 RTX 4080、Godot 4.6.2、OpenGL Compatibility 与 D3D12 Mobile
执行 GPU 回归（此前各 14 项通过；新增地力/河岸检查后各 17 项）及正式新游戏场景。性能必须同时记录设备、后端和场景，
隔离 shader 压测不能代替完整世界帧率。退出时仍存在项目已有 RID/ObjectDB 释放告警；
视觉测试通过不代表这些退出告警已修复。

## 2026-10-16 植被优先的密度调整

树木/普通植被与资源是独立生成路径；资源不占用 detail 全局实例预算，也没有反向扣减树木。
两者只共享分块构建/上传时间。为保证氛围，调整现有 profile 的适生密度和群落数量：

| Profile | density_scale 前→后 | 树丛/地表元素范围 前→后 |
|---|---|---|
| tree | 0.72→1.02 | 6–15→8–20 树冠 |
| conifer | 0.68→0.90 | 7–18→9–22 树冠 |
| palm | 0.54→0.70 | 保留原形态 |
| monsoon_tree | 0.50→0.68 | 5–13→7–18 树冠 |
| cloud_forest_tree | 0.52→0.70 | 7–16→9–21 树冠 |
| grass | 1.25→1.55 | 4–9→6–12 草丛 |
| shrub | 1.55→1.75 | 3–6→4–8 枝丛 |

同时提高对应桌面 profile 的每格/总量余量。全局桌面/移动预算、移动 profile 上限、
气候适配、活力、林线、地形权重、聚落和河流避让均沿用原机制，不改模拟植被量。
40×28、seed 20260727、RTX 4080 / D3D12 Mobile / 1440×1000 的同流程实景对照中，
资源实例由 549 降至 226，近景活跃植被实例由 845 增至 1127；这是该样本的渲染数量，
不是全图生态数量或一般性能保证。前后图位于 tmp/vegetation_density_qa/before 和 after。
