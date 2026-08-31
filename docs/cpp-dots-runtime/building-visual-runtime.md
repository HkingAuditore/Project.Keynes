# 建筑视觉运行时

建筑层是经济、科技和视野的只读消费者。`NativeEconomyRuntime` 只在完整
`building_commit` 结束后发布稀疏 CSR 镜像；`NativeCountryRuntime` 从
`TechnologyCatalog` 已完成的时代里程碑推导 `current_visual_era`。渲染器不读取正在
修改的建筑 slice，也不根据建筑文件名、年份、产出品或英文 ID 猜类别和时代。

## 数据契约

`DCWorldExt.get_building_visual_snapshot(requested_cells)` 在桥接边界排序、去重并检查
范围，返回与请求一一对齐的 `cell_indices/type_offsets/type_indices/counts`，空地块保留
零宽 CSR 行。`consume_building_visual_dirty_cells()` 和
`consume_country_visual_era_dirty_slots()` 只报告提交后的变化。镜像不写 PKEC、不进入
经济 state hash；生产、工资和库存变化不会触发视觉 generation。

`EconomyFacade.building_visual_catalog()` 是唯一类别入口。启动审计当前 395 个作者建筑，
类别优先级为显式 `visual.archetype.*` tag、`building_kind`、作者的
`economic_sector_id`；解析失败的类型被记录并跳过，不会以文件名推断。时代是 11 个
`TechnologyCatalog` 顺序时代，且每个时代必须有对应里程碑。普通科技、pending 科技和
未 ACK 的永久 modifier 都不会换代。

## 玩家情报与存档

`BuildingVisualIntelCache` 由 `WorldRuntimeHost` 持有。只有当前可见地块才接受建筑或
国家时代快照；隐藏地块保留最后一行，新增建设和外国时代变化不会泄露。再次可见时批量
刷新，关闭迷雾时把全图视为可见。缓存行保存精确数量供 Inspector 使用，同时保存
`log2(1+count)` 桶、主类别和时代供几何签名使用。

PKFG v2 保存稀疏情报 CSR：`building_intel_cells/country_slots/era_indices/type_offsets/
type_indices/counts`。写入前按 cell 排序；恢复先完整校验单调 offset、尾 offset、类型范围、
正 count 和时代范围，再一次性替换缓存，最后提交 `explored_arr`。无 version 的 PKFG v1
只恢复 explored 并清空建筑情报，绝不使用当前外国建筑填充缺失行。

## 渲染组织

`BuildingVisualLayer` 使用 16×16 cell render chunk。Macro 层是一个世界 quad，读取
RGBA8 `building_macro_lut`（密度、主类别、时代、occupied）和共享 glyph 语法。原有
`enum_atlas` 只有 16 位 cell ID，因此建筑层额外生成 R8 high-byte atlas，宏观 shader
组合 24 位索引，覆盖 500×400 桌面压力地图而不回绕。

Far/Mid/Near 共用一套 superset compound mesh；一个实例是主体、附属房、院落和产业
设施的复合体。数量在 `total=1` 时固定为 1，之后采用 `ceil(1.05*log2(1+total))`，类别用权重最大余数配额，布局使用
`world_seed/cell/archetype/rank/layout_version` 稳定 hash 和 8 候选 best-candidate。
主体避开水域和 river SDF；建筑采用统一朝向，地基始终位于图标下方，不使用随机旋转，类别差异由模块和材质轮廓表达；不声明不存在的道路 mask。Body、GroundDecal、
Landmark、Shadow 每 chunk 各至多一个 MultiMesh 节点，质量档和平台预算通过
`visible_instance_count` 与 resident chunk 淘汰控制。

实例使用 16-float buffer：2D transform 8、instance color 4、custom/style 4。Body 和
Shadow 直接共享同一 PackedFloat32Array，天气、积雪、fog、日照和地形法线均由 shader
采样，不逐实例更新或重建 buffer。隐藏地块 shader 只使用缓存的记忆材质，关闭实时雪雨。
Web 默认关闭长投影；Desktop q1/q2 使用解析 soft shadow，阴影长度受太阳高度和最大值
限制。Ground decal 紧贴 footprint，q0/Web 低档关闭。

近景 Body、远景 Macro 与解析 Shadow 统一 include
`shaders/include/earth_daylight.gdshaderinc`。`HexRenderer` 向建筑层同步
`season_phase/day_phase/axial_tilt/day_night/TODProfile/debug sun`；Body 从
MultiMesh 实例世界中心换算稳定 map UV，Macro 直接使用世界 quad UV。夜侧采用冷蓝环境光，
窗光随 `pixel_night` 增强；解析阴影按当地太阳水平向量投射并在夜侧消失。所有变化只更新
共享材质 uniform，不改实例 transform/custom data。

## 聚落密度阶梯

早期版本用两套互不相干的离散档：数量按 `ceil(gain * log2(1 + total))`，尺寸按
`floor_log2(1 + 该 archetype 数量)` 取 12 级。这个设计有三个问题：档位边界全挤在十栋以下、
量程在数百栋就封顶（成熟城市与小镇无法区分）、以及**密度被算了两次**——数量和尺寸同时随密度
增长，底部于是又多又挤。

现在三个视觉维度由同一个连续量驱动，没有可见跳档：

```
density = clamp(log2(1 + total) / log2(1 + DENSITY_LADDER_TOP), 0, 1)
compounds    = clamp(round(COMPOUND_COUNT_MAX * density), 1, NEAR_CAP[quality])
baker scale  = hex_size * lerp(COMPOUND_SCALE_MIN, COMPOUND_SCALE_MAX, density)
spread scale = lerp(COMPOUND_SPREAD_MIN, COMPOUND_SPREAD_MAX, density)
```

`total` 是该格所有 BuildingGroup 的 `count` 之和。`DENSITY_LADDER_TOP=100000`
是达到完整表达的建筑总数；取 `round` 而非 `ceil` 保证 compound 数**永不超过实际建筑数**
（旧公式在 total=2 时会画 3 栋）。

注意后两列的主体不同：一列是**单栋**的宽度，一列是**整簇**的面积。

| total | density | compounds | 单栋占 hex 宽度 | 整簇占 hex 面积 |
|---|---|---|---|---|
| 1 | 0.060 | 1 | 8.9% | 0.9% |
| 15（正式开局） | 0.241 | 6 | 10.3% | 7.3% |
| 100 | 0.401 | 10 | 11.5% | 15.2% |
| 1 000 | 0.600 | 14 | 12.9% | 27.0% |
| 10 000 | 0.800 | 19 | 14.4% | 45.6% |
| 100 000 | 1.000 | 24 | 15.9% | 70.0% |

散布圆的面积与建筑面积之比（圆内填充率）随密度上升：15 栋时约 65%（松散一簇、有空隙），
1000 栋时约 82%，顶端约 100%（实心建成区）。这不是单独调出来的，是尺寸与环半径挂在同一个
density 上的自然结果。

占宽推导：建筑 quad 宽 2 单位、作者画面覆盖约 85%，Body/Shadow/GroundDecal 在 shader
顶点阶段统一乘 `COMPOUND_VISUAL_SCALE=0.144`，而 pointy-top hex 宽 `sqrt(3) * hex_size`，
故可见占宽为 `1.7 * baker_scale * COMPOUND_VISUAL_SCALE / sqrt(3)`。占面积为
`compounds * 占宽^2 / (sqrt(3)/2)`。上限由 `COMPOUND_MAX_HEX_WIDTH_FRACTION=0.16` 断言。

散布环沿用 `_best_candidate` 的 per-archetype 半径带（农业/采掘 0.54 最外、知识/服务 0.34
最内）作为形状，再乘 density 驱动的 spread scale。顶端最远触及为
`0.54 * COMPOUND_SPREAD_MAX + 半个建筑宽 = 0.759 * hex_size`，小于 hex 内切半径
`0.866 * hex_size`，因此最大都市也不会越界到邻格。覆盖率主要靠环张开与尺寸增长换取，
而不是线性堆实例。

尺寸改由**每格密度**驱动而非 per-archetype 数量，代价是同一格内不同产业的 compound 尺寸
一致，无法再表达「这一格以某产业为主」。这个信号原本也很弱（旧量程只有 8.0%→11.6%，
肉眼难辨），产业差异由图集轮廓与环带位置承担。

`building_visual_layer_test.gd` 用 `ladder anchor total=N` 系列断言钉住上表，并断言
compound 数不超过实际建筑数、簇触及半径小于内切半径。

`NEAR_CAP` 从 `[4, 8, 12]` 提到 `[8, 16, 24]`，16x16 最坏情况实例预算相应从 3072 涨到
6144。该 fixture 是 256 个相邻格各 10 万栋的极端假设，不描述任何真实地图。

以下常量必须与 `world_ext_building_visual.cpp` 逐一同步：`DENSITY_LADDER_TOP` /
`kDensityLadderTop`、`COMPOUND_COUNT_MAX` / `kCompoundCountMax`、
`COMPOUND_SCALE_MIN|MAX` / `kCompoundScaleMin|Max`、
`COMPOUND_SPREAD_MIN|MAX` / `kCompoundSpreadMin|Max`、`NEAR_CAP` / `kNearCap`。

## 地名层序

建筑 Body 的绝对 z 为 3，会盖住格内其他内容。`SettlementLabelLayer` 因此显式取
`z_as_relative=false` 与 `z_index=LABEL_Z_INDEX=7`，让地名压在建筑、天气(4)、数据叠加(5)
与国界(6)之上；选中高亮(10)与迷雾(12)仍然遮挡地名。

## DLL 同步

数量、尺寸、散布都属于 baker 输出的实例 transform，**修改 C++ 侧后必须重新编译 dots_ext
DLL 才会在生产路径生效**（`gdext/rebuild.bat`，编译前需关闭 Godot 编辑器；debug 与
release 两个目标都要出，headless 测试加载的是 debug）。

`building_visual_native_bridge_test.gd` 的 `C++ building chunk baker returns packed
geometry`（7 个 compound）与 `C++ 16x16 stress bake`（6144 实例）直接校验原生阶梯，
DLL 过期时这两条会失败，可作为探测器。注意 `water cells never create building geometry`
在新旧公式下 total=32 都得 7，**无法**用来判断 DLL 是否过期。

## 作者图集与视觉风格

战略地图是正俯视、扁平几何纯色的表现（参考 `ShrubLayer` 的程序化 archetype 网格）。
建筑主体因此使用作者图集，而不是写实厚涂或 3/4 等距资产：

- 图集为 12 列 × 6 行、每格 160px，共 72 个 slot。索引为
  `art_era_band * 18 + archetype * 3 + variant`，`column = index % 12`、
  `row = index / 12`；C++ baker、GDScript fallback 和
  `building_compound.gdshader` 三处必须一致。
- 运行时时代仍由 TechnologyCatalog 里程碑决定。图集只把权威时代映射到四个美术带：
  early 0–1、masonry 2–5、industrial 6–7、modern 8–10。这些断点与程序化回退的
  `_style_palette` 完全相同，因此在作者图集和回退之间切换不会改变某个时代的读法。
  渲染层启动时校验 manifest 的 `runtime_era_to_band` 与 shader 映射逐项一致，
  否则拒绝加载。
- 四个带之间必须存在**几何**差异而非仅换配色：early 用深前坡、无窗、加宽地基的土木
  形体，masonry 引入陶瓦屋脊、窗与烟囱，industrial 用锯齿/筒拱与金属附属，modern
  用平顶、玻璃带与天线/碟。
- `variant` 是风格槽位而非语义声明。作者可用 `visual.profile.<n>` 语义标签固定
  （与既有 `visual.archetype.*` 同一通道，不新增 catalog 列，因此
  `building_catalog_hash` 与存档兼容哈希不变）；未标注时按类型下标稳定 hash 分配，
  保证相邻类型不共用轮廓。
- 双通道资产：albedo 为 RGB 扁平色 + A 轮廓；surface 为
  R 朝上积雪接受度、G 湿润响应、B 窗光自发光、A 环境遮蔽/占位。积雪只落在朝上屋顶
  面，墙体保留本色。
- 资产**不得**烘焙阴影。假阴影由 `building_shadow` 解析 pass 拥有；manifest 的
  `baked_shadow` 必须为 `false`，测试会同时检查画面内是否存在低 alpha 暗色裙边。
- 朝向固定正俯视、地基位于图标下沿；屋脊为水平线，前后坡各为一条扁平色带。
- 加载 fail-closed 到程序化 glyph：manifest 缺失、形状不符、纹理尺寸不匹配或时代映射
  不一致时，`use_authored_atlas` 保持 `false`，建筑仍可渲染，并在
  `diagnostics().authored_atlas_reason` 暴露原因。

资产由 `tools/building_visuals/author_building_atlas.py` 确定性生成，同时输出 54 个
可替换的 SVG 源、两张图集 PNG 和带源/输出 sha256 的 manifest。`--from-svg` 用
Inkscape 光栅化美术手改的 SVG，缺少 CLI 时直接失败而不静默退化。

## 画质与植被协调

`building_compound.gdshader` 的 style LUT 为 66 行（11 时代 × 6 类），共享材质图集和
mask 图集。雪量由动态 LUT 的 snow cover、pseudo normal、时代材质保持率和 mask 共同决定；
湿润只改变材质响应，不写回经济或环境状态。建筑层输出每格 settlement core bucket，
`ShrubLayer` 在候选生成时拒绝 core 内点；同一 bucket 不重建植被，隐藏外国建设也不改变
本地植被外观。

## 调度和性能闸门

脏格先合并到情报缓存，再按 signature 映射到 chunk。镜头中心和新可见地块优先；每帧
最多上传一个 chunk（Web 低档每两帧一个），offscreen dirty 只记 generation。Desktop
resident 上限 128、Web 48；Body 上限 q0/q1/q2 为 6k/18k/36k，Web 为 1.2k/3k/6k。

层提供 `diagnostics()`：resident、队列、实例数、宏观上传数、chunk bake 最近值/峰值、
原生调用/失败次数、`native_required`、`gdscript_fallback_enabled` 和
`bulk_encoder_required`。桌面与已加载 GDExtension 的默认路径是
`DCWorldExt::bake_building_visual_chunk`：C++ 负责 CSR 读取、六类聚合、对数配额、
best-candidate 布局、河流排除、重要度裁剪和 16-float buffer 编码；Godot 层只负责调度、
结果校验以及 `MultiMesh`/材质资源上传。`allow_gdscript_baker_fallback` 默认是
`false`；native 方法缺失或失败时生产路径 fail-closed，只发出一次 stale DLL 诊断并
停用几何。只有兼容性测试或旧 DLL 调试显式打开这个开关，才会调用 GDScript baker。

GDScript baker 仅保留给显式兼容测试或旧 DLL 调试，不能作为桌面/Web 默认性能实现。
历史回退压测在 16×16、每格 12 个复合体时约 53 ms；该数字只描述
GDScript fallback，不代表当前 C++ 路径。当前 native bridge 的同规格 30 次压力夹具
（16×16、3072 个复合体、24576 个候选）测得 avg `0.9096 ms`、p95 `1.0237 ms`、
max `1.0467 ms`；层专项小 fixture（4×4 地图、2 个有情报格、6 个复合体）为
`0.0399 ms`。这些是本机样本，不是跨设备性能保证；完整地图和目标设备仍需单独记录。
任何 native bake 超过 1.5 ms 都会置位
`bulk_encoder_required`，用于后续 profile/批量编码优化诊断，不会自动切回 GDScript。

## 验证入口

专项脚本：

- `tests/building_visual_catalog_test.gd`：395 类型、11 时代和里程碑审计。
- `tests/building_visual_native_bridge_test.gd`：CSR 聚合、排序、时代组合和 state hash。
- `tests/building_visual_intel_cache_test.gd`：可见性、PKFG v2/v1、原子失败和桶稳定性。
- `tests/building_visual_layer_test.gd`：shader/材质、三批次、LOD、河流排除、确定性和
  24 位宏观索引。
- `tests/building_visual_atlas_test.gd`：作者图集契约——72 slot 齐备、索引公式与网格
  顺序、时代映射与 shader 一致、无烘焙阴影、每个时代带 18 个轮廓互异、全 72 slot 互异、
  扁平色阶（distinct tone ratio < 0.06）以及渲染层确实启用了图集。

重新生成资产：

```powershell
python tools\building_visuals\author_building_atlas.py
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --import
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --script res://tests/building_visual_atlas_test.gd
```

这些测试不改变 DataCore 或 PKEC。图形截图仍需在真实渲染设备上执行；headless 仅验证
资源装载、脚本解析和数据/缓冲确定性。
