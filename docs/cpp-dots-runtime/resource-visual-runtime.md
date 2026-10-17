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

- 陆生植物（family 0，木材除外）：世界视图不再生成实例，由 `ResourceGroundCover`
  全屏地被群落表达（见文末 2026-10-17 节）；实例层只保留透镜徽章（PLAN_BADGE）。
- 陆生动物：真实比例位图兽群（3–9 头），见文末 2026-10-17 节。
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

- `tests/resource_visual_layer_test.gd`：60 项目录、观测/存档、分布、预算、绘制契约检查。
- `tests/resource_ground_cover_test.gd`：23 项地被 LUT 编码、优先级、上传节流、包裹 quad 检查。
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

## 2026-10-17 植物群落地被与真实比例兽群

目标：植物物种（小麦、玉米等）以大片野生群落融入地表，而不是孤立标志物；
动物以写实、小比例的位图兽群表达。精确识别仍由透镜徽章承担。

### 地被（ResourceGroundCover）

- `scripts/rendering/resource_ground_cover.gd` + `shaders/resource_ground_cover.gdshader`：
  一张覆盖世界（含东西包裹副本）的 quad，是资源层第 0 个子节点，绘在资源实例与树冠之下。
  零逐格几何；像素按与 FogOfWar/data overlay 相同的 map index → cell 解码查 `cover_lut`。
- `cover_lut`（RGBA8，nearest，每格一像素）：R = 主层×16 + 副层，G/B = 主/副丰度，
  A = 踪迹种类×64 + 强度。主副层取观测中档位最高的两个植物物种；丰度 `0.62 + 0.14×band`，
  聚落 core 按 `ground_cover_settlement_clear` 清空。仅在资源观测变化、`notify_cells`、存档恢复/
  `set_context` 时写入，按 `ground_cover_upload_hz`（默认 4Hz）节流整张上传。
  LUT 只来自观测（雾战记忆），未探索格永远为空。
- 纹理按世界坐标平铺（`ground_cover_tile_hex`），周期量对齐包裹周期，相邻同种格连成一片；
  格边由噪声扭曲（`edge_warp_hex`）、簇状噪声（`clump_*`）和高质量下 3 点邻格采样软化。
  副种按噪声斑块混入；风向/阵风轻微摇曳；放牧物种在地被下画踩踏小径/拱土/驼蹄印踪迹层。
- 气候：可见格读实时 `dyn_lut`（与实例 shader 相同 `enum_lut.a ≥ 0.88` 规则），隐藏格读
  `memory_lut` 最后观测。干旱转黄、活力低时变疏、积雪掩埋（最多压低 85% 覆盖）。
- 光照：同 `earth_daylight` 日照/天空 SH/terrain horizon；`cover_saturation/cover_gain/cover_grade/
  light_gain/light_neutralize` 把中性位图对齐地形调色板（取景内 HSV 与地形差 <0.03）。
  q≥1 采样法线/AO，q2 加反平铺采样与冠层自阴影；移动端在编译期去掉这些分支。
  使用 height 贴图裁掉水面与河道；远景降不透明度，透镜开启时按 `lens_dim` 变暗。

### 兽群

`rv_herd` 从 `fauna_atlas` （4×2 姿态/毛色）取位图，每群 `herd_size_min..max`（3–9）头，
黄金角螺旋分布、共享朝向，带接地影。体长 `animal_length_hex`（0.055 hex），实例半径
`clamp(animal_length×4, 0.12, 0.45)` hex；单头低于 `animal_min_pixels` 时整群淡出。
鱼群体长 0.035 hex。GPU 回归的 48px 夹具中动物仅 1px，故测试内放大体长以测量动作。

### 美术管线

- 来源：Codex 内置图像生成（prompt 记录在 `tools/resource_art/build.py` 与 `manifest.json`），
  原图在 `assets/textures/resource_art/source/`（`.gdignore`，不入包）。
- `python tools/resource_art/build.py [--check]`：方形裁切→半偏移交叉无缝化→亮度对齐地形→
  透明区颜色外扩（避免 mip/VRAM 压缩把灰色渗进叶片）→推导法线/高度/AO。
  输出 `cover_albedo.png`（16 层 512²：13 植物 + 3 踪迹）、`cover_normal.png`、
  `fauna_atlas.png`（9 层 512×256）。层序是与 shader LUT 的稳定契约。
- 导入：`2d_array_texture`，albedo/fauna 为 VRAM 压缩，法线无损。`ResourceArtLibrary`
  在导入缺失时运行时切片 PNG 回退。更换某物种：替换 source 原图并重跑 build.py。

### 性能（RTX 4080 / Vulkan Mobile / 1440×1000，40×28 seed 20260727）

- 整帧 GPU：资源层关 ≈ 1.0–1.14ms，开 ≈ 1.10ms（噪声内，增量 ≤ 0.1ms）。
- CPU（8000 格 perf 夹具）：地被开/关 p50 1.08/1.07ms；上传 ≤ 0.3ms、每秒最多 4 次。
  该夹具 p95 ≈ 2.2ms 由 `observation_budget_ms = 1.0`（资源 tres，早于本次改动）决定，
  超过测试的 1.0ms 阈值；与地被无关。
- 植物不再占用实例预算（同场景实例数 ≈ 259）。

Profile 字段：`ground_cover_enabled/opacity/tile_hex/edge_warp_hex/clump_scale_hex/clump_strength/taps/
normal_strength/shadow/lens_dim/far_opacity/settlement_clear/upload_hz`，
`herd_size_min/max`、`animal_length_hex`、`animal_min_pixels`、`animal_trace_opacity`。
QA 截图：`tests/resource_visual_world_qa.gd`（非 headless）输出 `tmp/resource_visual_qa/plants_*`、
`cover_{lens,drought,snow,night,zoom_*}`、`animals_*`。

## 2026-10-17 第二轮：单树树冠位图、可见兽群与地被体积感

### 单树树冠位图（crown_atlas）

- 原图：`assets/textures/resource_art/source/crown/{broadleaf,conifer,palm,shrub}.png`，每张是图像生成的
  4×2 透明底单树树冠精灵表（不是无缝林冠贴图）。`build.py` 中 `CROWNS` 列表定义层序
  （0 阔叶、1 针叶、2 棕榈、3 灌丛），每格 `CROWN_CELL = 256`。
- `build.py` 生成 `crown_atlas.png`（1024×2048，4 层，VRAM 压缩）与 `crown_normal.png`（无损，
  RG = 法线、B = 高度、A = AO；由距离场穹顶 + 簇团浮雕推导）。`crown_tone()` 把不透明像素平均亮度
  归一到 0.5，让气候调色板决定最终明度；`bleed_alpha()` 也用于地被与兽群图层，避免 mip 渗灰。
- shader：`vegetation_forms.gdshaderinc` 的 `#ifdef VF_CROWN_ART` 块（只有 `ShrubLayer` 主体 shader
  定义该宏，阴影等其他 includer 不增加采样器）。`vf_crown_sample` 用元素 id 选变体与旋转，
  `textureGrad` 显式梯度，回旋法线并叠加穹顶法线；`vf_crown_fill` 在树冠重叠区内填实，避免透明像素
  打穿到地面。阔叶/灌丛保留枝干骨架与落叶期行为，针叶/棕榈直接走位图路径。
- 着色：`vegetation_impostor.gdshaderinc` 中 `s.art.a > 0` 时取位图色相、保留气候调色板明度
  （`crown_art_palette` 混合），因此物候、干旱、积雪仍然生效。
- 绑定：`ShrubLayer._bind_crown_art()` 在 `_ensure_resources` 中执行；family 材质由 `duplicate(true)`
  继承。位图缺失时 `crown_art_bound = false`，回退到原程序化树冠。
- 远景：元素小于 3px 时仍退化为 `vf_far`，位图采样只在近景发生。

### 兽群

- 体长 `animal_length_hex` 0.055 → 0.11，`animal_motion` 1.0；`herd_radius_hex()` 上限放宽到 0.55 hex。
- `rv_herd` 每头动物独立“吃草—走动”循环（`u = wt - sin(wt)` 产生走停节奏）：行走时朝向跟随位移
  方向，吃草时回到群体朝向；步态拉伸/摆动 + 低头吃草的身体下沉。

### 地被体积感与假 GI（resource_ground_cover.gdshader）

- q≥1 粗略投影（零额外采样，同树木 blob 阴影思路）：法线图即模糊株丛高度的坡度，空隙处法线
  背向太阳即表示太阳一侧有株丛，据此在空隙画暗影（低太阳时更长）。已移除早期的向太阳高度
  探测（`sun_occ`，2 次法线采样）与模糊覆盖投影（1 次 albedo 采样）。
- 假 GI：高度 AO `depth_ao = mix(0.80, 1.12, pow(h, 0.6))`、terrain horizon 弯曲法线与天空可见度
  （强度 `gi_ao_strength × 0.6`）、薄叶透射、地形谷地投影下限。
- 亮度校准：`cover_grade = (1.05, 1.0, 0.72)`，`light_gain = 1.62`；QA 取景内覆盖像素 HSV 明度
  0.403 vs 裸地形 0.423（差 ≤ 0.02）。
- 气候：可见格读实时 `dyn_lut`（`enum_lut` 雾战规则），积雪压低最多 85% 覆盖。
- 温度物候：地被读 `climate.r`（温度），阈值与 `vegetation_climate.gdshaderinc` 一致——温和湿润→嫩绿，
  降温过渡（0.16–0.58）→秋金，寒冷（<0.38）→冬枯并变疏（最多 −35%），冷色去饱和，酷热计入干旱。
  变色保留位图亮度；世界空间噪声抖动 ±0.04 让相邻格不同时翻转。强度由 `climate_response` 控制。
- 树冠位图色相权重随气候调色板的“绿度”衰减（最低 15%）：秋金/红叶/枯黄/寒冷灰完整显示，
  叶片细节仍由 `s.tone` 保留。
  `ResourceGroundCover.memory_climate_only` 仅供 QA 截取干旱/积雪对照图。

### 性能（RTX 4080 / Vulkan Mobile / 1440×1000）

- world QA 整帧 GPU：资源层关 ≈ 0.80–1.00ms，开 ≈ 0.90–1.12ms（增量约 0.1ms）。
- 树冠位图的成本计入植被层，尚未单独 A/B；可切换 `crown_art_bound` 对比。
