# 建筑视觉运行时

建筑层是经济、科技和视野的只读消费者。`NativeEconomyRuntime` 只在完整
`building_commit` 结束后发布稀疏 CSR 镜像；`NativeCountryRuntime` 从
`TechnologyCatalog` 已完成的时代里程碑推导 `current_visual_era`。渲染器不读取正在
修改的建筑 slice，也不根据建筑文件名、年份、产出品或英文 ID 猜类别和时代。

## 数据契约

`DCWorldExt.get_building_visual_snapshot(requested_cells)` 在桥接边界排序、去重并检查
范围，返回与请求一一对齐的 `cell_indices/type_offsets/type_indices/counts`，空地块保留
零宽 CSR 行。同一快照还带四列逐格 `PackedByteArray` 社会档位：

| 列 | 取值 | 来源 |
|---|---|---|
| `settlement_tiers` | 0–7 | `_settlements.tier`（人口规模） |
| `living_levels` | 0–6，255 = 无人口 | cohort 人口加权 composite 满意度，阈值与 `living_standard_level_for` 共用 `LIVING_STANDARD_THRESHOLDS_Q16` |
| `rich_buckets` | 0–3，255 = 无人口 | composite ≥ T[4]（生活水平 5 档及以上）的人口占比，按 5%/20%/40% 分桶 |
| `poor_buckets` | 0–3，255 = 无人口 | composite < T[1]（生活水平 0–1 档）的人口占比，同样分桶 |

后三列在 `publish_social_pressure_facts` 里与社会压力同一次扫描算出，并带滞回：生活水平
越过阈值 ±1.5%、占比越过阈值 ±2% 才移动一档、每次只移一档，因此在边界上抖动的 cohort
不会每天重绘地块。聚落等级变化和社会档位变化都通过 `mark_building_visual_cell` 进入脏格
（outbox 排序去重，未消费时以格数为上界）；`read_view_reset` 时整表重建。这三列只用于表现，
不写 PKEC、不进 state hash。`consume_building_visual_dirty_cells()` 和
`consume_country_visual_era_dirty_slots()` 只报告提交后的变化。镜像不写 PKEC、不进入
经济 state hash；生产、工资和库存变化不会触发视觉 generation。

ACTIVE（worker 权威）模式下，`get_building_visual_snapshot` 的时代必须读
`country_query_runtime()`（已提交读视图），不能读冻结的同步 Country；
`apply_committed_read_snapshot` 逐 slot 重算 `visual_era_index_for_slot`，变化时写入
visual-era 脏 slot 并递增 generation，`consume_country_visual_era_dirty_slots()` 才能驱动重绘。

`EconomyFacade.building_visual_catalog()` 是唯一类别入口。启动时审计全部作者建筑，
六大类（archetype）由视觉族决定。**视觉族**共 22 个（顺序即 C++ `Family` 枚举）：
`field paddy plantation pasture forage fishery mine quarry forestry saltworks wells
workshop food textile kiln metallurgy chemical machinery electronics energy knowledge
service`，规则表是 `data/rendering/building_visual_families.tres`
（`BuildingVisualFamilyTable`）。解析顺序：显式 `visual.family.<id>` tag → sector/kind →
生产气候档 → 生产资源 → 关键词（类型 id、产业链、产出品的子串，按表序）。当前 400 个作者
类型全部命中显式规则，fallback 为 0（`building_visual_catalog_test` 断言）。每个类型另派生：

- `type_to_scale`：`clamp(round(8 * sqrt(业主 + 雇员岗位)), 8, 255)`，岗位多的建筑占地更大；
- `type_to_grade`：建造用品的最高建造档（0 原始、1 古典、2 工业、3 钢构），决定该族 lot
  最多用到哪个时代带的造型，防止“石器时代的茅草作坊”在信息时代被画成玻璃塔，反之亦然。

这些表只在表现层，不新增 catalog 列，`building_catalog_hash` 与存档兼容哈希不变。时代是
11 个 `TechnologyCatalog` 顺序时代，且每个时代必须有对应里程碑。普通科技、pending 科技和
未 ACK 的永久 modifier 都不会换代。

## 玩家情报与存档

`BuildingVisualIntelCache` 由 `WorldRuntimeHost` 持有。只有当前可见地块才接受建筑或
国家时代快照；隐藏地块保留最后一行，新增建设和外国时代变化不会泄露。再次可见时批量
刷新，关闭迷雾时把全图视为可见。缓存行保存精确数量供 Inspector 使用，同时保存
`log2(1+count)` 桶、主类别、时代和四个社会档位（`settlement_tier/living_level/
rich_bucket/poor_bucket`）供几何签名使用；签名不变的格不会重新提交。没有建筑但 tier 1–7
的格（只住人的村落）保留在缓存里并绘制民居。

PKFG v3 保存稀疏情报 CSR：`building_intel_cells/country_slots/era_indices/type_offsets/
type_indices/counts`，加四列与 cell 对齐的 `building_intel_settlement_tiers/
living_levels/rich_buckets/poor_buckets`。写入前按 cell 排序；恢复先完整校验单调 offset、
尾 offset、类型范围、正 count、时代范围和社会列长度与取值，再一次性替换缓存，最后提交
`explored_arr`。v2 存档仍可读，社会档位记为未知（255），由数量估算 tier，下次可见时刷新。
无 version 的 PKFG v1 只恢复 explored 并清空建筑情报，绝不使用当前外国建筑填充缺失行。

## 渲染组织

表现目标是**真俯视的程序化聚落**：每栋建筑是一个独立实例，屋顶、墙面、投影和地面全部在
GPU 上按实时太阳、季节积雪和 11 个时代的材质程序化生成，零外部美术资产。

`BuildingVisualLayer` 使用 16×16 cell render chunk。远景 Macro 层是一个世界 quad，读取
RGBA8 `building_macro_lut`（密度、主类别、时代、occupied）和共享 glyph 语法。原有
`enum_atlas` 只有 16 位 cell ID，因此建筑层额外生成 R8 high-byte atlas，宏观 shader
组合 24 位索引，覆盖 500×400 桌面压力地图而不回绕。Macro 的照明与 Body 同一套公式
（L1 天光 + 方向光 × horizon 直射遮蔽 + 月光，增益同为 0.62/0.78/0.40），法线由字形屋面坡度
叠加地表坡度给出，投影像素沿 `-sun.xy` 拉长，因此 0.46–0.78 的交叉淡入区不再有亮度跳变；
`camera_zoom >= 0.78` 时整层直接 discard，不为不可见像素付地图索引/LUT/horizon 采样。

近景每 chunk 至多三个 MultiMesh 节点；Body 与 GroundDecal 共享单位 quad，Shadow 用凸包扇形网格：

| 节点 | shader | z | 内容 |
|---|---|---|---|
| GroundDecal | `building_ground_decal.gdshader` | 1 | 广场、街道、农田、水田、果园/草料地、牧场、庭院花园、矿坑、堆场、木料场、盐田、码头、光伏场、石器时代石圈 |
| Shadow | `building_shadow.gdshader` | 2 | 与 Body 共享 buffer 的投影 + 接触 AO（`blend_mul`） |
| Body | `building_compound.gdshader` | 3 | 屋顶、墙面立面、风车叶片、烟囱/冷却塔蒸汽 |

q0 与 Web 不生成 GroundDecal；Web 不生成 Shadow。LOD 是 Body 与 Shadow 材质上的同一个
`lod_fraction` uniform：缩放 < 0.82 为 0.28，< 1.30 为 0.62，否则 1.0；< 0.46 整体清空，
由 Macro 接管。Body 的淡出、投影的淡出与 Macro 的淡入共用同一组 zoom 阈值：
body `smoothstep(0.36, 0.54)`、shadow 同区间（再乘 `SHADOW_STRENGTH[quality]`）、
macro `smoothstep(0.78, 0.40)`，所以远景是"近景变淡 + 投影变淡 + 字形接手"的连续过渡，
不存在某一档突然失去光影。每个 body 在 color.a 里带它在本格重要度序（公共核心优先）中的名次
`(n+0.5)/N`，vertex 阶段把名次超过阈值的实例乘 0 塌成零面积，因此每个聚落都从外围小屋
开始变稀，换 LOD 只改一个 uniform，不碰 buffer、不逐 chunk 设置。

### 实例 ABI

两套实例都使用 16-float buffer：2D transform 8 + color 4 + custom 4，规范写在
`shaders/include/building_form.gdshaderinc`，C++ 侧编码在
`world_ext_building_visual.cpp` 末尾，两处必须一致。

- transform：`[ax*hl, -ay*hw, 0, px, ay*hl, ax*hw, 0, py]`。basis 列长度就是半长/半宽，
  shader 在 vertex 阶段自行把单位 quad 扩张到所需范围（屋顶倾斜、投影、风车叶片）。
- Body color：`(eave_h/16, ridge_h/16, (material+0.5)/16, rank)`，rank 是本格重要度名次
  `(n+0.5)/N`，供 LOD 使用。
- Body custom：`((era*6 + archetype)/65, seed, cell/(cell_count-1), (form+0.5)/32)`。
  form 用 /32 编码为新体量留余量，shader 统一用 `BF_FORM_SCALE` 解码。民居使用 service
  的 style；产业 lot 的 era 已按建造档截到该族允许的最新时代。
- Decal color：`(param, flag, 0, 1)`；decal custom.a 为 `(kind+0.5)/16`。广场与街道的
  param 是该格财富 `living_level/6`（未知为 0.5）；yard flag 1 = 棚户泥地；garden
  param = 财富、flag 1 = 泳池/水池；quay flag 1 = 混凝土码头；pasture/field flag 1 =
  篱笆；orchard flag 1 = 草料地（无树）。

Form 15 种（gable、hipped、cone、dome、flat、sawtooth、cross、courtyard、tower、
mound、windmill、chimney、greenhouse、cooling、tank），Material 16 种（thatch … stone），
Ground 14 种（plaza、road、field、pit、yard、solar、stone_ring、paddy、orchard、pasture、
garden、log_yard、salt_pan、quay）。

### Shader 要点

- Body：不做 ray march。屋顶从半坡高度做一次视差修正落到高度场上；墙面用解析求交
  （矩形 slab、圆形二次方程、十字取两盒并集、四合院取内院墙），山墙可升到屋面线，
  其余停在檐口。倾斜量为每单位高度向屏幕上方 0.30，露出一条立面。屋面数值法线 + 每材质程序化纹理（茅草纹、瓦/石板行、波纹铁皮、
  沥青、混凝土设备、玻璃幕墙塔的屋面设备、绿顶、铜绿……）。积雪只落在朝上屋面，
  湿润降低反照并加镜面。窗户在近景逐格点亮，远到像素以下时以平均窗光代替，夜间立面
  仍可读。四合院内院按时代铺石或种植。
- Shadow：与植被软边 blob 投影同一思路，形状在顶点阶段完成。专用 9 顶点扇形网格
  （中心 + 每个角按两条邻边各一个顶点）；背光侧边的顶点沿
  `-sun.xy / max(sun.z, 0.22) * 投影高度`（总长 ≤ 5）平移，正好围出足印扫掠的凸包，圆形
  体量用八边形近似。片元只取扫掠线上离像素最近的一点算一次足印距离做柔边（半影随距离
  变宽），再算一次接触 AO；夜侧只剩接触 AO。Body 与 Shadow 共享实例 buffer，网格不同。
- Decal：街道带噪声蜿蜒、端部淡出；铺装按时代从泥土车辙、卵石、碎石到沥青标线，贫穷
  格的街道比时代落后一档（极贫一直是土路）；农田按半球校正的季节显示作物，水田春季
  灌水、夏绿、秋黄并画田埂；广场在石器/农耕时代带夜间篝火，贫穷广场边缘磨回泥地，富裕
  广场中心有喷泉（时代 3 之前为纪念石台）。棚户泥地带积水，富人庭院有修剪绿篱与水池。
- Tank（圆罐）：平顶圆柱，屋面画焊缝环与中央检修口，不开窗，投影取罐顶高度。
- 三个 shader 统一 include `shaders/include/earth_daylight.gdshaderinc`，在 vertex
  阶段求一次日照并用 flat varying 传给 fragment。`HexRenderer` 向建筑层同步
  `season_phase/day_phase/axial_tilt/day_night/TODProfile/debug sun`，所有变化只更新
  共享材质 uniform，不改实例 buffer。白天环境光增益 0.62、太阳 0.78、月光 0.40；夜侧
  环境光增益回到 1.0，使屋顶与地形同亮。
- [building-terrain-light 2026-10-18] **高画质（`visual_quality >= 2`）下 Body、Decal 与 Macro
  接入地形光照**，不再自成一套：地表法线在 vertex 按实例中心 map uv 采一次（flat varying，
  每实例 1 次 fetch；Macro 是整图 quad，没有实例可用，只能逐像素采），8 方向 horizon 在
  fragment 用逐像素重建的地图坐标调 `terrain_horizon_evaluate`，一次拿直射遮蔽 / 天空可见度 /
  bent normal。直射乘 `direct_visibility`，天光乘 `sky_visibility` 且方向改用 bent normal
  （`gi_bent_strength`），Decal 直接用坡面法线做 NdotL，Body 的屋面/墙面法线仍来自自身高度场
  的解析差分，只按 `building_terrain_tilt` 加上地形坡度（加而非插值，否则屋面彼此的夹角会被
  压平），Macro 用字形屋面坡度 + 地表坡度。亮度参数（`terrain_horizon_*` / `gi_*` /
  `gi_horizon_lut`）由 `HexRenderer` 从地形材质整组拷到建筑材质；legacy 绑
  `terrain_horizon_tex` / `terrain_normal_tex`，tiled 绑
  `visual_horizon_tiles` / `visual_terrain_normal_tiles` + 图块寻址 uniform 并换 shader
  代码（与 `ResourceVisualLayer` 同处理）。代价是每像素 4 次 horizon tap，只在高画质开启；
  低/中画质走中性值，与接入前逐位一致。Shadow pass 不参与：它没有直射项可遮，只有足印
  距离和接触 AO。
- 隐藏地块 shader 只使用缓存的记忆材质，去饱和并关闭实时雪雨。

## 聚落规划

`world_ext_building_visual.cpp` 里的 `plan_cells` 是唯一几何实现，**没有 GDScript
baker**。它逐格独立规划（blocker 与 RNG 都按格重置），所以一格的输出只取决于该格自己的
情报行和静态表。运行时入口是 `NativeBuildingVisualCache`（见下节“调度”）；
`DCWorldExt::bake_building_visual_chunk` 保留为同一规划器的同步多格包装，供测试和离线
工具使用，两条路径对同一输入逐位一致。扩展缺失或配置失败时层 fail-closed：只发出一次
stale DLL 诊断、停用近景几何，Macro 继续工作。

每个有情报（有建筑，或 tier 1–7 有人住）的陆地格按以下步骤生成一个聚落。核心原则：
**人口决定住宅骨架，产业决定用地，财富决定质量与贫富分区**；不保证每种建筑都出现。

1. **族权重**：每个类型的 `count * scale / 8` 累加到它的视觉族；同时记录族内最高建造档。
2. **产业用地（对数压缩）**：lot 总数
   `clamp(round(20 * log2(1+W) / log2(1+200000)), 1, LOT_CAP[quality])`，`W` 为全部族权重
   之和，`LOT_CAP = [6, 12, 20]`。按 `weight^0.75` 最大余数分给各族：大产业得到更多更大的
   lot，小产业可能一个都没有。lot 高度/尺寸按 `hscale = clamp(0.8 + 0.12·平均 scale +
   0.05·log2(每 lot 权重), 0.85, 1.9)` 放大（高度按 sqrt）。
3. **住宅（人口骨架）**：tier 未知时由建筑数估算 `1 + floor(log2(1+total)/2)`（≤7）。
   民居数 `HOUSE_COUNT[tier] = [0,3,6,10,15,20,26,32]`，截到 `HOUSE_CAP[quality] =
   [6,16,30]`；民居形态随 tier 从农舍、联排、合院/排屋到板楼、塔楼，每户财富在格财富 ±0.15
   内抖动，决定屋面材料与庭院（贫穷用茅草/土、富裕用瓦/石板并带花园）。
4. **贫富分区**：`villa = round(rich/3 · (1 + tier/3))`（≤4），`shanty = round(poor/3 ·
   (1 + tier/2))`（≤5）；农耕及更早时代的不平等系数为 0.35。别墅带花园和水池，棚户是
   杂乱小屋加泥地。
5. **环带**：slot 按环排序后依次放置——0 公共（知识/服务）→ 1 富人区 → 2 民居与轻工
   （作坊/食品/纺织）→ 3 重工（窑业到电子）→ 4 棚户 → 5 采掘与能源 → 6 农林牧渔；
   同环内按 `frac` 交错，所以民居与商铺混排。
6. **骨架**：中心在格心附近抖动并避开河流；石器时代为环形营地（无街道），其余按 tier
   生成 1–4 条街，广场半径 `0.65 + 0.22·tier`；路宽与退线随时代变宽。水田与渔业 lot 优先
   沿朝向河流的街道排布，田、水田与码头地面豁免河流检测。
7. **排布**：每条街两侧各两排 frontage 游标；lot 依次尝试离中心最近的游标、每个游标沿街
   探 4 步，全部失败时该游标只前进一步。碰撞用 OBB + 外接圆粗筛，同时检查 hex 边界和
   river SDF。连续 4 个 slot 失败视为该格已满。
8. **族造型**：22 个族各有 builder，按时代带（石器 0、农耕 1、古典 2–3、近世 4–5、工业 6–7、
   原子 8、信息 9–10）组合体量与地面，并被建造档截断：例如水田的谷仓与灌水田块、纺织的
   锯齿厂房、冶金的高炉与圆罐、油井的井架与储罐、盐业的盐田、码头的木栈道/混凝土岸线。
9. **外环农田**：农业族权重占比越高，外环补的田块越多
   （`FIELD_FILL_CAP[quality] = [0, 8, 16]` × sqrt(占比)），地面类型随族（田、水田、果园、
   牧场、草料地）。
10. **街道**：至少一到两条出口街通到 hex 边缘（tier ≥ 5 时全部通出），其余街道截到最远 lot。

每格的 body 按重要度降序（同重要度按 lot 内顺序，主屋顶先于烟囱）排列并写入名次，地面
按 order 排列；chunk 内按 cell 升序拼接。chunk 超过 cap 时按名次截断（`select_by_rank`，
同名次按输入顺序补满），每个聚落保留核心。同步包装在 cap 装不下时每格最多规划两倍公平
份额（`2 * cap / 有效格数`），输出：`ok/path/instance_count/decal_instance_count/lot_count/
house_count/villa_count/shanty_count/field_count/family_lots(22)/candidate_count/
river_rejected/buffer/decal_buffer/far_count/elapsed_ms`。同步包装的可选输入：
`type_to_family/type_to_scale/type_to_grade`（为空或与 `type_to_archetype` 等长）和
`settlement_tiers/living_levels/rich_buckets/poor_buckets`（为空或与 cell 等长）；缺省时
族按 archetype 回退、scale 为 8、grade 不截断、社会档位按未知处理。

布局 hash 只依赖 `cell/族或 slot 种类/rank/layout_seed`，同一输入逐位确定。

## 地名层序

建筑 Body 的绝对 z 为 3，会盖住格内其他内容。`SettlementLabelLayer` 因此显式取
`z_as_relative=false` 与 `z_index=LABEL_Z_INDEX=7`，让地名压在建筑、天气(4)、数据叠加(5)
与国界(6)之上；选中高亮(10)与迷雾(12)仍然遮挡地名。

## DLL 同步

布局、实例编码和缓存 worker 都在 C++ 中，**修改 `world_ext_building_visual.cpp` 或
`building_visual_cache.h` 后必须重新编译
dots_ext DLL 才会在生产路径生效**（`gdext/rebuild.bat` 或
`scons platform=windows target=template_debug dev_build=no` 与 `target=template_release`；
headless 测试加载的是 debug）。另一个 Godot 进程持有 DLL 时链接会报拒绝访问，可先把旧
DLL 改名再链接。shader 修改不需要重编。

## 画质与植被协调

雪量由动态 LUT 的 snow cover、法线朝向和每种材质的积雪保持率共同决定；湿润只改变材质
响应，不写回经济或环境状态。建筑层输出每格 settlement core bucket，`ShrubLayer` 在
候选生成时拒绝 core 内点；同一 bucket 不重建植被，隐藏外国建设也不改变本地植被外观。

## 调度：后台逐格规划 + 主线程只上传

视觉计算不得挤占模拟。布局只在后台算、只算变化的格子，主线程只做提交和上传。

`NativeBuildingVisualCache`（`building_visual_cache.h`，RefCounted）持有一个专用
`std::thread` worker，模式与 `EconomyCsvRecorder` 相同：mutex + condition variable，worker
只读 `configure` 时拷入的 POD（cell 世界坐标、类型→archetype/族/scale/grade 表、river
flow 场），**不触碰任何 Godot API**。API：

| 方法 | 线程 | 作用 |
|---|---|---|
| `configure(config)` | 主 | 停 worker、清空缓存、拷静态表、算每 chunk 包围盒、重启 worker |
| `submit_cells(rows)` | 主 | CSR 行（cell/era/is_water/types/counts，可选四列社会档位）；按输入 hash（含社会档位）跳过未变格，变化格 generation+1 并入队 |
| `set_quality(q)` | 主 | 所有缓存格 generation+1 重新入队（旧几何在新结果就绪前保留） |
| `take_ready_chunks()` | 主 | 返回自上次以来所有格都已规划完的 chunk |
| `chunks_in_rect(rect, center, limit)` | 主 | 按包围盒选非空 chunk，按距离排序截到 limit |
| `build_chunk(chunk, cap)` | 主 | 拼接 chunk 内各格缓存好的已编码实例（memcpy），超 cap 按名次截断 |
| `wait_idle(ms)` / `pending_cells()` / `diagnostics()` / `shutdown()` | 主 | 测试同步、计数、停 worker |

一致性：每格有 `input_gen/output_gen`。worker 取任务时拷走输入与 gen，规划不持锁；提交时
gen 不等（规划期间又被提交或换画质）则丢弃结果，该格已经重新入队。chunk 的 pending
计数归零才进入 ready 列表，所以一个 chunk 不会因多个格陆续完成而反复上传。行变空且
tier 为 0/未知的格在提交空结果后从缓存删除；有人住但没有建筑的格保留并绘制民居。

`BuildingVisualLayer` 的数据流：

1. `update_intel(changed_cells)`：`BuildingVisualIntelCache.apply_snapshot` 已经只报告几何
   签名（时代、类型、`log2` 数量桶、社会档位）变化的格；层只为这些格组 CSR 调一次
   `submit_cells`，同时改 Macro 像素（密度取建筑数与 `tier/8` 的较大者）。没有逐 chunk
   遍历全部格的 GDScript 循环。
2. `_process`：`take_ready_chunks()` 中驻留或在预取范围内的 chunk 进入上传队列；每帧按
   离镜头距离最多上传 4 个、预算 1.5 ms。上传复用 chunk 已有的 MultiMesh 节点，只改
   `instance_count` 和 `buffer`。
3. `set_camera_view`：一次 `chunks_in_rect` 决定驻留集合，新进入的 chunk 直接从缓存拼接
   上传，不再重算布局；只在 zoom 变化时更新 `camera_zoom` uniform。

Desktop resident 上限 128、Web 48；Body 上限 q0/q1/q2 为 6k/18k/36k（扣除其他驻留 chunk
后作为单 chunk cap）。层 `diagnostics()` 报告 resident、上传队列、实例数、宏观上传数、
`chunk_uploads`、`last/max_submit_ms`、`last/max_upload_frame_ms`、`native_failures`、
`lod_fraction`，并在 `cache` 键下附 worker 统计（cached/queued/planned/unchanged/stale、
`worker_plan_us_avg/max`、`last/max_build_us`）。

本机样本（debug DLL，非跨设备保证），native bridge 压力夹具为 16×16 格全部 10 万栋，
远超任何真实地图：

| 项 | 线程 | 耗时 |
|---|---|---|
| 单格规划 | worker | avg 约 60 µs，max 约 180 µs（256 格合计约 15 ms，全在后台） |
| `submit_cells` 256 格 / 改 1 格 | 主 | 约 0.08 ms / 约 0.02 ms |
| `build_chunk` 拼接 6144 实例（超 cap 名次截断） | 主 | 中位约 0.07 ms，max 约 0.28 ms |

旧同步路径同一夹具每 chunk 主线程约 9.4 ms。改 1 格只重算 1 格（约 60 µs，后台）。截图台
66 格真实混合产业的 worker 平均约 43 µs/格。60×40 新开局 headless 50 天：建筑视觉脏格
每天 0–1 格，吞吐 69 天/秒，与改动前的 62–74 天/秒区间一致。

## 验证入口

专项脚本：

- `tests/building_visual_catalog_test.gd`：全部作者类型可解析且无 fallback、22 族全部有
  类型、族抽查、scale/grade 随岗位与建造品单调、11 时代和里程碑审计。
- `tests/building_visual_native_bridge_test.gd`：CSR 聚合、排序、时代组合、社会档位列
  对齐与取值范围、state hash、body/decal buffer 步长、水格无建筑、确定性、int64 饱和与
  16×16 压力上界；tier 越高民居越多、贫富桶带来别墅与棚户、主导产业族拿到最多 lot、
  建筑越多 lot 不减、只住人的格也画民居；缓存与同步规划器逐位一致、超 cap 名次截断、
  未变行不重算、改 1 格只重算 1 格、生活水平档位变化只重算该格、人走后空格被移除，并
  打印 worker 与主线程耗时。
- `tests/building_visual_intel_cache_test.gd`：可见性、社会档位签名、PKFG v3 往返与
  v2/v1 迁移、原子失败和桶稳定性。
- `tests/building_visual_layer_test.gd`：无 GDScript baker、worker 规划、ready chunk 驻留、
  三批次、Shadow 共享 buffer、未变行跳过、画质往返逐位一致且复用节点、单格增量重算、
  社会档位变化只重算变化行、`lod_fraction` 与名次、水格与 hex 边界、TOD uniform（含
  decal）和 24 位宏观索引。
- `tests/_tmp_building_art_harness.tscn`：美术截图台。11 列时代 × 6 行地方经济（稻作小村、
  麦作农镇、纺织城、矿冶镇、富裕首府、积雪渔林盐业；各行带 tier 与贫富档），走真实层与
  DLL，输出总览、近景、城市、夜景、黄昏截图；`detail` 输出单格特写，`wealth` 改为在
  时代 5 横扫生活水平与贫富：

```powershell
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --path Project\project-keynes --resolution 1600x900 res://tests/_tmp_building_art_harness.tscn -- <out_dir> [detail|wealth]
```

这些测试不改变 DataCore 或 PKEC。截图台需要真实渲染设备；headless 只验证资源装载、
脚本解析和数据/缓冲确定性。


## Resource scenery and PKFG v4

PKFG now writes version 4, preserving all v3 building columns and adding independent resource observations in `BuildingVisualIntelCache.resource_observations`. Empty building rows do not remove resource observations. Versions 1-3 remain readable with initially unknown resource memory. Physical scenery is visible before identification; knowledge gates still apply to names and filters. See [resource visual runtime](resource-visual-runtime.md) for the rendering, lighting, budgets and atomic-restore contract.
