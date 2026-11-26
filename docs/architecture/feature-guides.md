# 专项开发约束

只在改到对应功能时读本页；通用规则在 [development-guide.md](development-guide.md)。
每节写该功能的数据归属、不能破坏的约束和必跑的验证入口。新增专项约束写在这里，不写进通用开发指南。

## 海岸平移性能复测

改地图绘制后，用 [海岸平移标准场景](../../tools/perf/coast_pan/README.md) 优先在同一台电脑、同画质下复测。真机采样按具体问题安排。场景版本固定地图、逐帧路线与水面开关顺序；改变协议时保留旧基准的版本标识。

## 脚本原生访问边界

`world_ext_binding_modules.json` 的 `script_dirs` 为 15 个绑定模块登记允许直接访问的目录或单个文件，路径相对 `Project/project-keynes`。正式脚本访问其他模块须经该模块的 facade；现有越界只是待迁移记录，不是永久许可。

`check_script_native_access.py` import 同目录 `world_ext_bindings.py` 的清单解析，扫描项目内全部 `.gd`，排除路径分段为 `tests`、`addons`、`.godot` 的目录；`tmp`、`tools` 内的 `.gd` 也按此范围检查。先跳过注释，区分代码和字符串；每处 `.绑定名(` 或内容恰好为绑定名的字符串算一个候选，不把字符串中的代码当调用。

候选只在 a 或 b 成立时计入。a：接收者是本文件直接由 `ClassDB.instantiate("DCWorldExt")` 赋值的变量、类型标注为 `DCWorldExt` 的变量或参数，或变量名匹配 `(?:^|_)(?:data_core_)?world_ext$|^_?ext$|^ext_obj$|^world$|^dc$`。直接调用、`has_method/call/callv/call_deferred` 的首个字符串参数，以及 `Callable(receiver, "绑定名")` 可识别接收者；点链取末端变量名。b：所有正式脚本中均无同名 `func name(` 定义。其他绑定名字符串仍按 b 判断，每个出现位置只计一次。a、b 都不成立时排除，`--audit` 输出两条规则各自的数量、交集和计入/排除各 10 条样例。

普通文件按完整目录边界匹配，不能用目录名前缀绕过。`*_facade.gd` 只继承最深的登记目录所属模块（例如 bakers 不继承 rendering 的 visual 权限）；若最深目录由多个模块共享，按 `<module>_` 文件名前缀选定所属模块，无法选定时不允许直接访问任何模块。

`script_native_access_baseline.json` 是 `{仓库相对文件: {模块: 越界次数}}`。新增文件/模块组合或超过该组合原次数均失败；减少时普通检查通过并提示收紧。`--write-baseline` 只用于首次生成或收紧，已有基线时也拒绝增加；不要通过删基线重新生成来接受新增越界。`--report` 给出 15 模块各自的越界文件数、次数和前五文件，已接入本地回归和 PR 的 `architecture-guards`。验证入口为该护栏、`test_architecture_guards.py`、`world_ext_bindings.py` 和 `check_world_ext_bindings.py`。

这是按词法和局部变量线索检查，不追踪跨文件返回类型、变量别名、运行时拼接或从变量传入的方法名，也不按作用域区分同名变量；同名脚本函数新增或删除会影响 b 的判定。计数不等于精确的运行时调用图，迁移前用 `--audit` 与实际代码复核。

## 原生扩展握手

`Project/project-keynes/data/native_binding_manifest.json` 是提交到仓库的 `DCWorldExt` 方法清单。绑定新增或删除后，在仓库根目录运行 `python3 tools/ci/world_ext_bindings.py --write-manifest` 重新生成；`check_world_ext_bindings.py` 会检查清单与静态绑定解析结果完全一致。启动会话时由 `NativeWorld.create()` 一次性把清单与 Godot 的 `ClassDB` 方法列表比较；类不存在时仍沿用没有扩展的回退行为，类已注册但握手失败时会明确报错并阻止进入会话。

Windows 编辑器锁住 DLL 时，可以用新文件名构建并切换加载映射，但切换前仍要先更新并提交这份清单，避免脚本与新 DLL 的接口版本不一致。

## 山地起伏调参与验收

生成高程归 `gdext/src/world_ext_generate_base.cpp`；山脊增量必须读冻结基底，
先用统一高度预算再收尾尖峰，不恢复按格逐点压缩或读已写邻格。
预算诊断通过 base/full 结果包的 `ridge_*` 字段检查；正常软收尾应不超过
陆地约 1%，高海平面也须保留正的山脊预算。初始 elevation 改动必须重新生成地图。

视觉地形参数归 `terrain_index_baker.gd::DEM_DEFAULTS` 与 `world_ext_bake.cpp`
对应 native 默认值；`project_keynes/rendering/dem/*` 可覆盖。
主脊振幅、波长、尖化指数分别使用 `ridge_amp_per_relief`、
`ridge_wavelength_hex`、`ridge_crest_exp`；谷深和谷壁使用
`valley_depth_per_relief`、`valley_wall_per_relief`，谷壁系数越大则同深度谷壁越窄陡。
`mountain_relief_floor`/`peak_relief_floor` 只对相应地貌提供最小起伏。
standalone、fused geometry、visual tile 都传 `cell_landform`，不得只修分块路径。
镜像项目的脚本和 Windows DLL 加载路径同时维护。

验证运行 `tests/world/mountain_relief_bake_test.gd`、
`tests/world/terrain_index_edge_bake_test.gd`、
`tests/runtime/native_generation_equivalence_test.gd`，
并检查 `tests/ui/visual_tile_native_bake_test.gd`。
验收需重启 Godot 后新生成地图，检查中远景主脊、近景谷壁、高原内部与海岸。
DLL 可通过 `DOTS_EXT_OUTPUT_BASENAME` 使用新文件名构建，避开现有编辑器锁定，
构建完成后再切换 `.gdextension` 的 debug/release 映射；不要结束用户编辑器进程。

### 烘焙期侵蚀 knobs（2026-11-18，19 项 + 1 诊断项）

默认值的**唯一来源**是 `terrain_index_baker.gd::DEM_DEFAULTS`（经 `dem_landform_knobs()` 并入融合几何 pass 的
knobs），可用 `project_keynes/rendering/dem/<去 dem_ 前缀>` 逐项覆盖。C++ 侧另有一套缺省值，
两边原值一致；**改默认只改 GDScript 表**。

| knob | 默认 | 单位 | 作用 |
|---|---|---|---|
| `dem_erosion_mode` | `"spl"` | — | `carve`/`spl`/`spl+carve`/`droplet`；C++ 缺省恒 `carve` |
| `dem_erosion_max_dim` | 1024 | px（长边） | 侵蚀计算栅格上限；基线长边超过它时按整数因子盒式下采样 |
| `dem_spl_iters` | 6 | 轮 | 把总侵蚀时间切成几步；只影响离散误差，不改宏观强度 |
| `dem_spl_k` | 0.50 | 无量纲（总侵蚀时间） | 下切总量；以 `spl_p99_drop ∈ [0.01, 0.08]` 标定 |
| `dem_spl_m` | 0.45 | — | 汇水面积指数（地貌学区间 0.4–0.6） |
| `dem_spl_min_area_hex` | 0.03 | hex² | 汇水面积低于它不下切（坡面交给限坡） |
| `dem_slope_limit_per_relief` | 5.0 | 高度/hex（× 局地起伏） | 坡限系数；默认与 carve 谷壁 `dem_valley_wall_per_relief` 相同 |
| `dem_slope_limit_relief_floor` | 0.04 | 高度 | 起伏下限，避免平原区坡限趋 0 |
| `dem_slope_limit_cap_per_relief` | 1.4 | 高度（× 局地起伏） | 单像素最大削减（= carve `dem_valley_depth_per_relief`） |
| `dem_crest_round` | 0.0 | 强度 | 凸脊磨圆；只取负值 Laplacian，不填谷 |
| `dem_dep_enabled` | `false` | — | P3a 输运受限沉积开关（默认关，等 A/B 裁决） |
| `dem_dep_kc` | 0.02 | — | 搬运能力系数（与 SPL 同面积指数） |
| `dem_dep_rate` | 0.5 | 比例/像素 | 超载部分每像素填回比例 |
| `dem_dep_min_area_hex` | 0.5 | hex² | 只在成形河道上沉积 |
| `dem_floor_widen` | `false` | — | P3b 谷底展宽开关（默认关） |
| `dem_floor_width_hex` | 0.04 | hex | 展宽半宽系数：半宽 = 它 · `A_hex^0.5` |
| `dem_floor_slope` | 0.002 | 高度/hex | 谷底横坡 |
| `dem_floor_min_area_hex` | 2.0 | hex² | 展宽起点汇水面积 |
| `dem_spl_carve_scale` | 0.40 | 比例 | 仅 `spl+carve`：叠加的浅刻谷按此比例缩放谷深 |
| `dem_erosion_pit_audit` | `false` | — | 诊断：让合并管线额外算 `pits_out`；不改地形，但会多一次填洼（约 60 ms） |

三条硬约束（动这些值之前先读）：

1. **长度 / 面积参数一律以 hex 为单位**（不是像素、不是归一化高度）：像素量由 C++ 乘 `hex_px` 换算，
   分辨率 / 平台（desktop 1024、Web 512–2048）变化时不改 knob。
2. **迭代次数（`dem_spl_iters`）只按分辨率分档，禁止按耗时自适应或提前退出**：同一 seed 必须逐位复现，
   机器负载只能改变耗时，不能改变地形结果。
3. **C++ 缺省永远是 `carve`**（逐位回退基线）；`spl` 只能由 GDScript `DEM_DEFAULTS` 显式开启，不改 C++。
   旧 `dem_valley_*` 在所有模式下语义不变；`dem_valley_river_outlet_flow` 在所有模式下都决定河心出口。

**回退方法**：把 `dem_erosion_mode` 改为 `"carve"`——改一行、**无需重编**（C++ 缺省本就是 `carve`）；
也可临时用 ProjectSettings 覆盖 `project_keynes/rendering/dem/erosion_mode = "carve"`。
`carve` 输出由 FNV-1a 32-bit hash 门禁守逐位一致（三组基线用例见
[terrain-erosion-spl-plan.md §6 P0](../plans/terrain-erosion-spl-plan.md)）。

侵蚀相关验收：`tests/world/erosion_spl_bake_test.gd` 的 A1–A11（不变量 / 确定性 / 分辨率无关 / 回退 / 沉积）、
A12（叠加验证：真实地图河心落谷率，当前实测 0.83 未达 0.95 门禁，属已知 FAIL），
加六个既有回归（`mountain_relief_bake_test`、`terrain_index_edge_bake_test`、`terrain_detail_continuity_test`、
`bake_encoder_cpp_parity_test`、`native_generation_equivalence_test`、`visual_tile_native_bake_test`）；
性能看「同图同次运行的 carve vs spl 成对对照」，不要只看单模式绝对值
（desktop `spl` 约 233–265 ms，同机多次运行波动约 ±15%；**全部是 `template_debug`，release 未测**）。

### 结构指标阈值与地图指纹基线（2026-11-18）

地形两计划跟进时，结构指标（M1 / M2b / M5）的三个阈值先后作废、而世界漂移当时没有任何门禁。由此固化两条规矩：

1. **结构指标必须先量基线再定阈值。** 判据要同时满足三件事：**同一版本内可对照**、**口径可测**、**方向已知**。
   反例都在本轮发生：`M1` 的门禁「Spearman ≤ −0.3」基于「基线预计 ≈ 0」的假设，实测基线是 −0.2863 / −0.3485；
   `M2b` 的「≤ 旧基线 ×2」拿旧实现的数字比新实现，而两版 `ridge_add` 根本不是一个场（幅值差 3–5 倍、
   高脊格集合 Jaccard 只有 0.31–0.43）；`M5` 的「`land_h > 0.6` 且局地起伏小」在本工程永远不成立
   （`sea_level = 0.64` 且 `E ≤ 1` ⇒ `land_h ≤ 0.36`），而换成 `M5_p90` 后又把「扩散磨小起伏」误判成「变平」。
   所以：**先在同一版本上把指标的分布跑出来、确认口径可测，再定阈值**；跨版本只能做同版本内对照
   （vs 零假设、vs 关 knob）或换 DLL 法并同时报告判据集合一致度，否则数字不可引用。
   结构指标新增/改口径时，判据先进测试的 `GATES` 表（`ridge_drainage_metrics_test.gd`，逐项 `hard` / `record`），
   不要用一个全局严格开关；未定口径的指标先记 `record`，定了再转 `hard`。
2. **改世界的 PR 必须重写指纹基线。** 世界指纹测试由 `tests/world/world_fingerprint.gd`（共用实现）+
   `tests/world/world_fingerprint_test.gd`（用例）+ `tests/world/baselines/world_fingerprint.json`（基线）组成，
   已挂在 `golden_day_hash_test` / `golden_external_advancers_test` / `native_generation_equivalence_test` 开头
   （世界不一致时直接报「世界指纹漂移」，而不是继续跑出一组无法比对的经济 hash）。
   有意改动生成结果（高程、地形、地貌、河流、`hydro_parent`）的 PR 必须在**同一提交**里用 `FINGERPRINT_WRITE=1`
   重写基线，并在提交说明附**分布差异摘要**（`land_h` p10/p50/p90/p99、terrain / landform 直方图、
   `river_count` / `lake_count` / `highland_river_count` / `peak_count` / `plateau_count` 的新旧值），
   否则下一个 PR 会看到一团无法归因的 drift。hash 严格、分布统计 5% 容差；精确 hash 只在**同平台同编译配置**下比，
   其他配置用 `FINGERPRINT_HASH=0` 只比统计。**覆盖边界（2026-11-18 S7 T2 已补）**：指纹现在盖 **cell 级 5 条数组
   + bake 的 `height_buffer`**（`SCHEMA_VERSION` 1→2，新增 `hashes.bake_height`（FNV-1a-64）、
   `stats.bake_h_p50/p90/p99`（陆地像素）与 `meta.bake`；分辨率由**常量** `BAKE_HM_MAX_DIM=1024` + bounds 长宽比推出，
   不依赖 `OS.has_feature()`，60×40 → **1024×606 = 620,544 px**、`wrap_period_x = 2286.307`；只对 **1 个种子**
   `BAKE_SEEDS=[20260718]` 烘）。验收实测：`dem_slope_limit_per_relief` 5.0→5.1 ⇒
   `hash DRIFT bake_height: baseline=14ff4f58e6917976 actual=0270977fe8927095`、exit 1，**其余 5 行 PASS 不受影响**，
   恢复后 hash 一致；指纹测试实测 **693–782 ms**（≤ 1.5 s 预算）。⇒ **改烘焙期侵蚀 / 限坡参数现在也会被这把锁抓到**。

诊断输出按需要临时导出即可，但一律用 **raw profile 键**（`ridge_debug_dump` → `ridge_add_arr`、
`dem_erosion_area_dump` → `area_hex_buffer`、`debug_dump_ridge_e0` → `e0_arr` / `ridge_e0_arr`、
`spl_steepest_receiver` 作消融键），**不要加进 `DEM_DEFAULTS` / `ClimateProfile` export**：
纯诊断、不改任何输出数组，避免把测试开关放进玩家可见的 profile。**默认零行为变化要用指纹证明**，见下一条。

### 同参照场比较与诊断开关（2026-11-18）

地形 S7 复核（同口径新旧对比 + 收益消融）又固化两条规矩，改判据 / 加诊断前先读：

1. **新旧比较必须使用同一参照场。** 同一指标名在两次实现里可能落在**不同的格子集合**上，直接算「旧值 vs 新值」
   等于中途换了一把尺子。反例就发生在本工程：脊抬升两版的 `ridge_add` 一个在 SPL 之后用最终 `E` 算、
   一个在 SPL 之前用 `E0` 算，幅值差 **3–5 倍**、场相关仅 **0.40–0.52**、高脊格集合的 **Jaccard 只有 0.31–0.43**
   ⇒ 由它导出的 M1 / M2b「旧基线 vs 新值」全部不可引用（结论一度被误读成「M2b 变差 5 → 41」，
   同口径实测是 **0.6667 → 0.6667 不变**）。做法：**两版共用同一个参照场**——S7 用「以 E0 为输入的 `ridge_add`」
   造判据集合，两版只在自己的最终 `E` / `hydro_parent` 上算指标；并**用 Jaccard 量化判据集合一致度**。
   集合换了就声明不可比、只做同版本内对照（vs 零假设、vs 关 knob），或换 DLL 法并同时报 Jaccard。
2. **诊断字段必须 opt-in、默认零行为变化，并以指纹证明。** 只加输出、只加开关也必须证明「默认路径逐位不变」，
   否则「诊断」会变成第二个变量源。S7 的两个做法可直接照抄：
   - `debug_dump_ridge_e0`（raw profile 键，默认 `false`）导出 `e0_arr` / `ridge_e0_arr`，开启时 elevation hash
     与默认**完全一致**（`51a893b7a6b45835` / `22149fd9ffeee585`，两种子）；`spl_steepest_receiver`
     （raw profile 键，默认 `true`）作消融键，`= 0` 确实改变地形（`4c944a48e0f8cb69`）⇒ 开关有效且默认不变。
   - 改了实现结构（G2 的河心注入路径）时，用**双编译差分**自证等价：`dem_spl_inject_cell_area = false` 逐位复现
     改动前的数字（X1 **0.7669 / 0.7809** 完全相同），另用「旧 header vs 新 header」双编译自检 **4 组指纹全同**。
   指纹入口与重写规则沿用上一条（改世界就 `FINGERPRINT_WRITE=1` 重写基线并附分布差异摘要）。

## 经济平衡调参

经济平衡调整先用 `tests/economy/economy_balance_soak.gd` 跑固定种子的正式多国开局，
用 `tools/analysis/compare_economy_balance.py` 对齐同种子、同日和各国/职业分布。
现金日流量须除以真实结算天数，累计发行按 epoch 去重；未发布快照不得填零。
本轮产出默认1.5x、派生维护2x、开局60货币/人、黄金/白银发行8/0.5货币/单位；
开局规划须读取真实 profile，软投入按基础100%加额外增产处理。
满意度公式更改应提升 `EconomyCatalog.SATISFACTION_MODEL_VERSION`，由内容身份拒绝
旧模型存档；只有新增持久列时才改字节 schema。当前模型为2、保存布局仍为60。
满意度**内容幅度**（政体、理念、事件、家族、科技的 bp）不属于公式改动：不必提升模型版本，
但要同步 `tests/economy/satisfaction_sources_runtime_test.gd` 的出厂表，并按
[满意度幅度梯](../cpp-dots-runtime/satisfaction-runtime.md) 取级——政体这类无成本、
全民、永久的来源，核心受益阶层应落在 ±450~750 bp，受损阶层至少 −450 bp。
政体还可挂任意 COUNTRY 定义（`regime.*.charter`）：条目用 MULTIPLY，每组至少写一条代价，
幅度按 2~8% 给，不要按满意度点数直觉放大；卡面「国策」行由
`RegimePresenter.charter_for()` 自动列出，加新条目不需要改 UI。
验收与边界见 [经济平衡记录](../cpp-dots-runtime/economy-balance-2026-11-08.md)。

改建筑的产出、投入或效率须运行 `tests/building/building_resource_chain_test.gd`（同族单调与跨字段校验）。

石器时代建材组必须通过 `construction_category_ids` 声明可替代材料；`primitive_lashing`
当前由 `bast_fiber`（玩家显示名“亚麻杆”）、`reed_bundle` 与 `raw_hide` 共同组成。

**起始科技即可营造的建筑，不得把需要研究的材料列为必需建材。** 八个起始科技能产出的货物
只有原木、生皮、毛皮、野味、采集植物食物、衣物、黄金、白银和科技值；`bast_fiber`
（`tech.wild_flax_collection`，3800 点）与 `reed_bundle`（`tech.reed_harvesting`，6800 点）
都要先研究，所以在开局六件套之外给它们排建材槽等于锁死那一栋。`raw_hide`（`tech.hunting`）
因此是石器绑扎槽唯一开局可达的兜底，默认价约为亚麻杆的 3.4 倍——有纤维时按有效成本择优会
自然让位，只在没有纤维时顶上。采集营地已改为纯 `primitive_construction` 单槽，不再依赖绑扎
材料；新增石器建筑时按同一条规则自查 `technology_tags` 与 `construction_category_ids` 的交集。

开局规划器会把种子建筑的候选建材写入 bootstrap 库存，**那只是第一座建筑的一次性补贴，
不能拿来证明该类建筑在开局可反复营造**——判据是"起始科技能否持续产出该货物"，不是
"出生地有没有被塞过一份"。修改该类建材时运行
`tests/ui/modern_economy_catalog_test.gd` 与 `tests/family/family_colonization_runtime_test.gd`，
保留“仅有芦苇也能完成建材组”的替代回归。

官营军事建筑在经济 `BuildingProfile` 声明建材组，国库报价和下单使用同一组候选与替代效率。
战士营地、木栅兵营和夯土城垣解锁后，各建材组都可用原木支付。木栅兵营的木材槽可用原木以
75% 效率替代。后续建筑沿用普通建筑的古典、工业和金属建材组，对应的电气设备和计算机仍是
专用设备。军事目录的 `materials` 记录同一份基础配方的首选材料。

建筑详情的亏损成因属于显示域：数据只读建筑已提交快照，不能在 UI 重新计算经营结果或写回
经济状态。`last_revenue` 是营业税后的实收，`last_operating_cost` 是原料、工资应付与维护成本；
营业税从 `last_business_tax_paid` 单独读取。图表展示时须将正营业税加回收入并计入总支出，
使「税前收入 − 含税支出」与已发布利润相等；成本堆叠必须保留原料、工资、维护和营业税分段。
亏损卡只在当前经营期确有负利润时渲染，停产状态只显示停产原因，不用零流量伪造亏损。
验证入口为 `tests/building/building_inspector_state_test.gd`、`tests/ui/ui_scene_structure_test.gd`，
以及 `tests/qa/cell_inspector_screenshot_qa.gd` 的建筑详情截图。

营造目录逐项显示单栋报价的建材。国库供料、待市购量和市场缺口来自同一份报价。
营造悬停卡先显示费用、工期与建材，产出、所需投入、岗位和可选增产使用目录结构化数据逐项显示。
既有建筑详情展示目录中的单栋基础建材，实际下单以当前营造报价选定的建材及数量为准。
实际开工率显示为百分比和满量程进度条，和岗位到岗人数、每栋实际产量分开呈现。
基础产量来自目录，实际产量来自已发布的经营期流水。

上游经济需求修复须运行
`tests/building/building_runtime_test.gd -- --supply-chain-only`。
派生计算实现归 `gdext/src/economy_runtime_derived_demand.cpp`，仍是同一个
`NativeEconomyRuntime` 成员；派生需求必须继续展开投入队列并阻止已访问回边。
工具等替代品的临时列在 epoch
取样前会清空，须由已提交的企业需求 EMA 和原投入槽活动上限重建冻结种子，
不能将预测写成真实销量、提款或资金。保留资源、库存、利润与业主生计门槛，
验证缺少下游与上游建筑时仍能形成原料价格和首座生产者机会；细节见
[经济公式](../cpp-dots-runtime/economy-fixed-point-ledger-formulas.md)。

## 自动建筑投资的资金预检

按实际提交顺序预演整个地块的投资组合：先迁人、注资和放贷，再依次付建材款。
转职带走的资金按所选家族的现金份额，或按无家族人口的剩余资金计算，不能用整个职业
人口组的平均值替代。后续项目必须看到前序项目已经迁走的人口和资金，以及更新后的家族份额。
若选定群体已无法提供足够的转职人口，或某笔建材款付不起，则在写入前保留能通过预检的前缀；
实际提交的余额断言不放宽。

预检是**快照证书**，写入读的是 live 状态，两者必须共用同一条现金规则
（`gdext/src/economy_family_move_cash.h::cohort_move_cash()`）；不要再在预检里另写一套份额公式。
写入前必须在 `investment_commit_portfolio` 内用 live 状态复算本腿转移，不满足就裁剪候选
（`allocated_count = 0` + `_building_investment_capital_limited`），不能先写后断言。
裁剪判据按分支写：抽空 sponsor 的分支只有 `carried < required_capital`；普通分支因为 backstop
读的是**移动后**余额，`carried` 抵消，等价于 `funds_before < required_capital`——写成
`funds_before < required - carried` 会留下 `required - carried <= funds_before < required` 的窗口，
重新触发同一 fatal。回归入口 `tests/building/building_portfolio_funds_regression_test.gd`
（含 top-up 窗口反例与无裁剪聚合守恒）。

## 建筑最近一次投资评估

受阻原因、投资评分和回本天数按建筑组保留最近一次实际评估结果。新批次初始化、
未到评估日期、跨日续算和未进入类型评估的跳过路径不得全局清空这些列；只有建筑类型
真正进入地块候选评估时，才重置该地块同类型建筑组的旧结果并写回新结果，允许解除受阻。
新增建筑从未评估状态开始；结构重排沿用原有按行搬迁，新世界和读档候选清理时不得继承
另一世界的结果。上述列仍为非持久化的展示诊断，读档后等待实际评估重新生成，不改变
投资周期、候选选择、资金结算、业务状态 hash 或存档格式。

原生回归 `EconomyTargetSelectorTests::run_building_investment_review` 经
`tests/ideology/ideology_target_selector_test.gd` 进入，覆盖批次和续算保留、跳过保留、
重新评估替换、解除受阻及建筑清理后重建。

启用投资评审分日执行时，旧批次中尚未评审的地块优先，当天到期的地块按原有顺序追加。
同一地块在待审队列里仅保留一次。同一天的投资准备使用本次待审地块的成员关系，
评估按队列顺序执行。跨日待审队列继续使用存档中的原有地块序列。

## 经济冻结输入与标签采样

`capture_country_epoch()` 仍在原结算边界冻结 Country 输入。科技可用性表、领土索引
及其拓扑 hash 由 `gdext/src/economy_runtime_country_cache.cpp` 维护，状态归同一个
`NativeEconomyRuntime`，私有字段在 `economy_runtime_internal_country_cache.h`。
这里只复用派生结果，不延长输入的有效期，也不改变结算频率、采样顺序或保存格式。

- 科技可用性必须精确比较国家数量、每国科技位表宽度、完整国家句柄数组和实际科技
  位表；结果表的大小和建筑类型索引端点也须有效。国家综合 generation 会因现金、
  税务或研究进度变化而增长，不能代替这些输入；科技指标自己的缓存身份也不能借用，
  因为科技测试入口可先更新那份指标。命中时复用物资、市场、职业、需求变体和建筑表。
- 领土索引必须精确比较国家数量、地块数量、完整国家句柄数组和完整归属数组，
  并检查索引形状。各国地块保持升序；拓扑 hash 的字节顺序和算法不变，
  只复用其结果，不能凭 hash 相等判定输入相同。
- 目录在两次 `configure()` 之间保持不变；重新配置先 `reset()`，连同新世界一起
  清空缓存及计数。读档候选安装和失败回滚均经
  `economy_runtime_restore_scratch.cpp::prepare_restore_candidate_scratch()` 使缓存失效；
  国家槽复用、领土转移、科技授权或撤销由实际输入比较触发重建。缓存及其计数
  不写入存档、OwnedState 或业务状态 hash。其他动态指标沿用各自原有刷新契约。

标签及效果输入准备归 `gdext/src/economy_runtime_family_effect_inputs.cpp`。
`rebuild_epoch_tag_snapshot()` 从本轮实际使用且有条件行的标签收集指标集合，
只采样这些条件需要的指标；声明需要标签但未给出具体列表时，仍覆盖全部有条件的标签。
直接指标查询保持自己的请求集合，按国家统计的专业化物资数量也保持独立的需求开关。
标签覆盖值、国家标签计数与不可变快照的整体发布顺序不变。可复用的线程内工作数组
每次按当前世界尺寸准备并清空，不得把上一个地块或世界的数值带入下一次采样。

建筑完整升级链所需的等级集合属于固定目录：`configure()` 成功解析目录后，在
`rebuild_building_upgrade_requirements()` 中整理一次。地块采样只遍历当地现存建筑，
空地直接为 0；同一级的多个类型只计一个等级，至少两个不同等级且全部存在才算完整。
新世界或重新配置会清空并重建；读档沿用已验证的同一目录，不保存这份派生表。
建筑新增、拆除和数量变化仍在采样时读取，不能缓存成旧地块答案。

报告字段的口径如下；它们仅用于诊断，不驱动模拟。精确比较计数时应在准备完成后读取，
不把并发读取的多个独立字段当作同一份已提交快照。

| 字段 | 含义 |
|---|---|
| `country_availability_cache_hits` / `country_availability_cache_rebuilds` | 自最近一次 reset 起，科技可用性复用和重建次数 |
| `country_territory_cache_hits` / `country_territory_cache_rebuilds` | 自最近一次 reset 起，领土索引及拓扑 hash 复用和重建次数；读档失效本身不清零 |
| `tag_snapshot_sampled_cells` | 最近一次标签位表准备实际采样的地块数 |
| `tag_snapshot_requested_metrics` | 该次标签位表准备所需的不同指标数，不是逐格采样次数 |
| `tag_catalog_metrics` | 该次准备中全标签目录引用的不同指标数；未运行标签位表分支时为 0 |
| `building_upgrade_catalog_builds` / `building_upgrade_catalog_rows` | 自 reset 起，固定建筑升级目录的整理次数及读过的类型行数；地块采样不增加 |
| `building_upgrade_catalog_bytes` | 固定等级集合的已分配空间，字节 |

现有 `PK_ECONOMY_COST_CSV` 可记录 `country_capture.*` 分项：snapshot、
technology_metrics、derived_metrics（领土、地理和家族指标）、tags、tax_snapshot、
availability、population_and_defaults、city_modifiers、country_modifiers、reserves、
cell_tax、building_factors_and_development。它们测量本次准备各段的墙钟时间；
提前返回时只有已走过的分项，不能把它们当成整日耗时。比较前后结果须使用相同探针、
相同完整采样日和输入；默认 CSV 按线程和日期汇总，最后未刷新的一日不计入比较，
`PK_ECONOMY_COST_CSV_FULL` 逐样本模式不用于吞吐量结论。

### 逐日需求缓存

`gdext/src/economy_runtime_demand_basis.cpp` 为当日工资、生产留存和家庭市场共用的
需求计算结果分配紧凑行。建筑和市场按各自的结算顺序登记，重合格使用同一行。
就业后的预填仍重新计算建筑格，随后生产与家庭市场才能复用这份结果。直接执行到
工作集之外时，执行器按实际地块登记。工作线程只读索引、写自己负责的行。未登记或
无效格可用已有计算直接得到结果，由执行器负责增设行和扩容。

开始新的一日时清空格到行的对应关系，保留已分配空间供下一日复用。同日续算或更换
执行器沿用现有结果。重配、重新开局、读档安装和失败回滚释放缓存，随后按恢复的输入
重新计算。缓存属于经济内部的临时工作数据。

稳定边界的 `get_economy_report().demand_basis_cache` 给出 `sample_day`、
`allocated_slots`（已分配的整行容量）、`registered_cells`（当日已分行地块数）和
`valid_cells`（当日已写好结果的地块数）。`values_bytes` 是五类结果的容量字节数，
`index_bytes` 包括格号索引和行的有效标记，两项均计入 `memory_bytes`。

验证入口为 `tests/ideology/ideology_target_selector_test.gd`（调用
`economy_runtime_country_cache_tests.cpp`、`economy_runtime_building_metrics_tests.cpp`
和 `economy_runtime_effect_selector_tests.cpp`
中的原生用例）、`tests/ideology/ideology_tag_snapshot_stress_test.gd`、
`tests/runtime/runtime_inline_save_restore_test.gd` 及
`tests/runtime/runtime_large_ecp2_save_test.gd`；还须按开发指南完成失败回滚、
重复运行一致及与改前结果的对照。测试声明集中在 `economy_runtime_test_access.h`，
生产入口头只保留既有 friend，不增加脚本绑定。

当前 ECP2（ABI 4、schema 63）必须携带 PKEC 64 的动员段 37，归入人口域；
即使没有动员记录，writer 也写入零记录段。缺段不能证明空表，恢复必须在修改候选前
明确拒绝。候选准备先清空原对象的动员表，再安装保存的全部行，防止另一世界的数据
残留。已有直接 PKEC 62 读取路径无此段时初始化为空；这不是旧 PKSV 迁移许可。
`tests/economy/economy_stratum_save_restore_test.gd` 用正式捕获/恢复入口核对全部
13 个保存字段、完整状态 hash、冷热目标、合法空段、缺段拒绝和坏校验值拒绝。

生产者当期/上期可售数量与商人实际买入数量影响下一日投入购买和家族机会报价，属于
必须保存并参与完整状态摘要的计算输入。PKEC64 的 SIGNALS 每行增加四个 i64，恢复时
检查非负及买入量不超过可售量；空候选先清空四列，避免暖恢复掩盖漏项。已有62/63
结构读取默认这些列为0，仍须匹配当前目录；ECP263 严格要求当前格式。
`economy_runtime_producer_continuation_tests.cpp` 通过真实写入/解码入口核对冷恢复与暖清理。

Economy 与 Modifier 均由后台执行时，启动前按已验证的请求配置选择专用加成读取副本；
不能用尚未授予的旧权限判断，否则冷启动会误读主线程显示副本。普通实例由 Modifier
每日阶段发布；Ideology 的地块派生加成不在实例快照内，必须在既有经济输入边界内
完成生成后一并复制到同一读取副本，包括清空结果和版本。复制不重新计算、不生成
新的权威结果。`get_effective_stat_value` 检查实际计算副本并报告来源，日内忙时返回
pending；`ideology_worker_derived_pump_test.gd` 比较每格实际数值与主线程参考。

黄金诊断读取必须位于完整每日边界内，并从当前公式数据的所有者获取完整人口和市场列。
开局接管前的 POD 账本镜像只包含部分人口列，不能用它代替完整列做散列；是否恰好完成
接管不应改变当天诊断。`economy_golden.cpp` 保持原字段、顺序及 POD 日戳，仅统一
真实数据来源；无生产运行时的纯 POD 用例仍读取自身状态。此诊断不推进或修改模拟。

财政回执的 `terminal_requests` 是尚未消费的终态队列长度，不是累计完成次数。
Country 在后台、Economy 在主线程执行时，财政请求完成后必须先通过宿主应用
Country 账目并发布不可变读视图，再确认消费回执；确认会同时删除请求与终态，
不能让它早于国家落账。此路径沿用 `run_economy_slice_internal()` 持有的执行边界，
不得从未持锁的入口直接调用。`economy_fiscal_reservation_continuation_test.gd`
核对已预留金额、国家现金的精确扣减、请求清空和重复脉冲不重复扣款；
不依赖观察一个可能在同次调用内消失的终态队列项。

## 移动端帧预算与分块显示

- Android/iOS 默认由现有 native worker 执行十二域日计划，主线程负责输入和已提交
  结果的显示。`RuntimeClockBinding` 在启动后立即同步暂停/速度，后续订阅控制变化；
  不用 UI 刷新或等待时长唤醒。`PK_MOBILE_NATIVE_WORKER=0` 显式诊断旧 inline 路径，
  `=1` 或未设置走后台；通用 `PK_NATIVE_DAILY_INLINE=1` 仍可显式选 inline。
  执行方式不能改变日序、输入、命令日期、存档边界或结果。验证：
  `tests/runtime/mobile_runtime_worker_test.gd` 比较 Android/iOS 平台选择、实际执行器、
  暂停恢复及 30 日全部已有摘要；`-- --reference-inline` 生成同输入的 inline 对照。
  完整对照命令：`python3 tools/ci/check_mobile_runtime_consistency.py --godot /opt/homebrew/bin/godot --log-dir <新目录> --workers 2`，同时核对原生库/源码身份、观察覆盖和实际压力。

- Android/iOS 的 `WorldClock.sim_budget_ms()` 与桌面一样使用配置的帧预算，不按
  快进倍速放大。倍速仍是目标天数，过载时实际推进放慢；不跳过游戏日，不改变
  同日继续、命令日期或结算屏障。单个同步日调用不能被这个预算中断。Web 保留
  原来的独立预算策略。验证：`tests/runtime/mobile_clock_budget_test.gd`、
  `tests/runtime/runtime_clock_overload_recovery_test.gd` 及 game 下的时钟绑定/事件测试。
- 植被初次补齐只走现有分块队列。原生散布不可用时，在同一个块内用脚本生成；
  没有植被也是有效且可缓存的结果，不能按等待时长或零实例数触发整图重建。
  验证：`tests/ui/detail_scatter_budget_slice_test.gd`、`detail_scatter_visibility_test.gd`。
- 触摸端显式低画质关闭 2D MSAA；自动、中、高档保留 2×，避免默认视图的边缘
  闪烁回归。地图纹理密度仍为低/中/高 12/16/20、自动 16，界面缩放和实际绘制
  分辨率不是同一件事。验证：`tests/rendering/mobile_msaa_policy_test.gd` 和
  `tests/ui/visual_tile_layout_test.gd`。

## 地图自然点缀

- `world_decoration_manifest.tres` 的散布、实例布局、气候和画质由既有植被层管理。主体轮廓取
  `crown_atlas.png` 的 alpha，所有外形和视距共用该图集，近景按画质采样匹配的法线图。
  风摆、物候、雪、光照和投影仍由渲染材质计算。
- 新贴图从 `assets/textures/resource_art/source/crown/` 经 `tools/resource_art/build.py`
  打包。修改图集顺序时同步 `vf_bitmap_cell()` 和导入层数。用
  `tests/world/vegetation_pixel_normal_render_test.gd` 实际渲染全部外形，
  另跑 `vegetation_form_scatter_test.gd`、`vegetation_family_layer_test.gd`
  和 `tests/rendering/veg_variant_parity_probe.gd`。

## 天气与光照 Shader

- 每个水面像素共用一次太阳方向来算主光和水面高光。夜色仍按原来的太阳高度计算，
  保留调试高度缩放的口径。每个陆地或水面像素的直射光和环境光共用一次云影取样，
  仍使用各自的遮蔽强度。

- 天气雨雪幕的天气/视野 LUT 在实例内恒定，放在顶点读取后用 flat varying 传递；
  完全不可见的实例收成退化三角形，透明边缘不进入雨雪计算。雪花候选可按最大
  晕圈、投影短轴和完整摆动范围提前排除，但必须保留原来的位置、摆动、形状计算
  顺序。用 `tests/rendering/weather_curtain_culling_test.gd` 在真实图形环境逐像素
  对照未裁剪的 5×5 邻域；`-- --reference=<改前 shader 绝对路径>` 另对照完整改前效果。

- 降雪散点归 weather_cell_curtain.gdshader：全格位置随机与独立摆动必须配合
  邻格补画，不能把随机偏移再次乘小系数缩回格心。查找坐标的旋转不应旋转
  雪花投影形状；桌面与移动/Web 使用同一散点算法，保留天气 LUT、视野门控、
  三层视差。修改时检查五种宏变体的三层空间分布、连续帧和跨格完整性，
  以更大邻域逐像素对照验证查找范围；同步性能验证项目的 shader。

- 云影和天气云平流沿用局地风 LUT + 双相位有界位移，禁止直接用当前风乘总运行时间。
  LOW/MID/HIGH 必须编译期裁剪并在切档时重建材质、重绑 LUT；云影按档缩小 field，
  天气云低/中与移动/Web 使用轻量梯度噪声，高档光照复用屏幕导数，不重复求云密度。
  修改时运行 `tests/rendering/cloud_weather_quality_test.gd`；预算与 GPU 证据见
  [云 Shader 分档验证](../cpp-dots-runtime/cloud-weather-shader-quality-2026-11-09.md)。
  云影场在天气发布边界上传风 LUT，经 `wind_lut_changed` 共享给天气云；新旧风只在
  显示端按 `weather_lerp` 过渡，不新增仿真状态。机制与验证见
  [云影的世界空间连续性](../cpp-dots-runtime/vision-fog-and-borders.md#云影的世界空间连续性)。

- 永昼视觉日照统一使用 `earth_daylight.gdshaderinc::compute_eternal_visual_sun_dir`，高度以当地当日正午为基线，日内时角在 ±70° 浮动并保留 10° 下限；默认一个游戏年完成两个 Shader 日，按实际游戏日历进度映射。水面 specials 和各实例层不能另算全局光向。修改时运行 `tests/ui/dynamic_eternal_day_direction_test.gd`（`-- --render-noon` 验证实际 shader）及地被光照测试，GM 覆盖仍优先。
  Shader 日/游戏年的比例在 HexRenderer 的 `shader_days_per_game_year` 调整，默认2，允许0和小数；renderer 经窄 Callable 配置 WorldClock，默认相位按累计年进度映射，跨年不重置小数比例。
  永昼最大时角和最低高度在 HexRenderer 的“永昼太阳”分组通过 `eternal_max_hour_angle_deg` / `eternal_min_elevation_deg` 调整（默认 70°/10°）；setter 统一换算弧度并推送各材质，初始化/重建时重放，不随日相位重复推送。

## 电脑和手机画质设置

- 主菜单与暂停菜单共用 `GraphicsQualityOptions`。预设位于
  `graphics_quality_settings.gd`，单项修改从当前预设复制显示值并切到自定义。
  `GameSettings` 保存预设及自定义选项到 `user://settings.cfg`，用同一份解析结果
  应用帧率上限。地图贴图烘焙仍读取原预设，地图清晰度单独决定陆地/水面绘制尺寸。
- 地图清晰度低于 100% 时，`terrain_render_scale.gd` 只缩放陆地和水面平面，
  合成图放回地图原绘制位置。选区与地图标记按地图区域的原始分辨率绘制，相机和普通界面留在窗口。切回
  100% 归还两个平面；水面材质重建后也放入当前绘制目标。渲染验证使用
  `tests/rendering/terrain_render_scale_test.gd`，检查图层顺序、缩放、平移和调整窗口。
- 迷雾清晰度、天气表现、植被与点缀密度、水面、云影分别由各渲染层应用；
  关闭云影仍保留天气云的风场输入。切档验证入口为
  `tests/game/game_settings_service_test.gd` 和 `tests/rendering/cloud_weather_quality_test.gd`。
- 每次天气发布编码一次逐格风图。天气表按地图行列重排，云影和天气云按格编号使用同一份
  字节。显示世界按地图、尺寸和发布时间交付这份数据。各贴图保留自己的过渡端点，云影
  在尺寸与字节相同时复用当前风纹理。单独预览可以直接从地图编码。
  `tests/world/weather_table_layout_test.gd` 检查首读、换图和字节，
  `tests/ui/cell_lut_incremental_test.gd` 检查同帧合批。
- `tests/game/player_scene_handoff_probe.gd` 通过 `GameFlow` 进入正式场景。场景切换失败和
  会话配置失败由 `player_start_failed` 报告，世界生成失败读宿主已记录的原因。探针将
  开局失败写入记录并以失败退出。性能对照要求起止结算日都有逐帧样本。真实窗口测量在
  探针及分析器上使用 `--require-rendered`，并检查实际画面设置及绘制完成间隔。

## 逐格弹射色 LUT

- `MapBaker` 的颜色表、枯黄/积雪/备用色和水面枚举是唯一参数来源。原生 `encode_cell_luts` 的 `bounce_only` 请求只接收 enum/dyn 字节和这些值，不读取或写入模拟状态。
- 两次颜色插值通过 builtin ptrcall 调用引擎的 `Color.lerp`，与脚本使用同一实现，避免 godot-cpp 本地内联因编译器融合乘加而差 1 字节。权重按脚本 double 计算，由引擎转 float；颜色分量最后转 double 做 clamp、乘 255 和整数截断。逐字节测试以保留的 `_publish_bounce_lut_gd` 原实现为准。
- 完整重建包含 `lut_w * lut_h` 的全部槽位与尾部填充，仍要发布同值完整重建；局部更新只处理原 dirty 列表，重复允许、越界忽略，未请求位置不变。短输入不得改变 cache 或 texture。
- 原生主 LUT 编码失败或扩展不可用时仍走完整 GDScript 路径。贴图上传位置、对象原地更新和天气发布顺序不变；`bounce_lut_ms` 包含实际编码与上传，不以 headless 或测试模式跳过工作。
- `tests/ui/bounce_lut_native_test.gd` 覆盖实际 dispatcher、完整 GDScript 路径、全部地形字节、雪/活力组合、padding、局部更新、缓存/贴图恢复和短输入。

## 时代晋升

- 时代晋升规则统一放在 `EraAdvancementCatalog`：科技 45% 必达（`TECH_COMPLETION_RATIO`，2026-11-19 由 60% 下调），人口/已落成建筑/本时代贸易三选二；经济门槛为目标时代基数加每地块要求。物资篮子按时代倍率放大，筹备基数与逐格量相加。`EraAdvancementService` 仅在开始时冻结物资订单，原生采购与 Country 原子消耗保持既有路径；条件投影运行 `tests/game/module_projection_boundaries_test.gd`，玩家界面运行 `tests/game/player_country_ui_smoke_test.gd`。已启动订单（含旧存档）沿用保存的冻结数量。

## 军事界面命令

地块军事页和营造目录的军事分类共用建筑悬停卡。建材数量取经济报价，逐项缺口取同格市场库存。
已开工项目显示快照发布的剩余工期。兵营的当前日维护费按现存各档座数汇总，建成后的读数使用目标档；
城防和军校的升级预览使用目标档的日维护费。

军事纯 C++ 热路径的行为约束见
[`military-performance-redesign-20261114.md`](../plans/military-performance-redesign-20261114.md)：
采购周边按中心首次访问计算，首次物流准备前的断供探测仍返回 false；普通采购保留前
19 个 BFS 项，维护和断供探测遍历完整半径三行。工资按国家、驻军格、部队槽升序付款，
缺钱时优先级不变；战争汇总使用交战之后的当日所有权、控制、人口和聚落等级。
交战反向索引必须随每次部队关联、销毁、槽位复用更新，成功读档后从权威字段重建。
这些派生索引和计数不进 PKMI v7，也不进哈希。

战线删除用反向位置表保持原 swap-pop 顺序，日末排序和每次修改的 revision 不变。
驻军人数查询只有在链表完整覆盖实际驻军位置时使用位置索引；旧档允许的不完整或错位链
保留原全量扫描。采购候选格按已验证链上的位置收集、排序去重，不按士兵是否活动或当前
位置另行筛除，确保包含旧档原先可见的非空 head；未准备或形状异常时走原遍历。

市场结构只在一次 `step_day` 的同一个冻结输入内复用，每个维护、采购、征用步骤仍分别
从原始可售量开始。步骤结束后公开临时列清空；缓存停放的列和输入引用不跨日存活。
不能将注释里的“每日上限”解释为允许合并原本独立的步骤额度。直接调用 `run_wars`
仍捕获自己的输入和国家收入；每日入口已捕获一次时才走复用内部体。

战斗 Plan 在单次调用内按部队分别复用原攻击、原防御、忽略防御工事比例，每项独立标记。
首次仍调用原函数，遍历与整数运算不变；不能替换成规则不同的显示用战力缓存。结果不供
Replay 使用、不跨调用存活，诊断计数在 Plan 后一次汇入报告。当前循环仍为串行；未来
并行化须先明确这个临时表的归属与同步。

在途采购量保留原四字段键与转换后的金额行，只对非负且总和可由 int64 表示的键建立
单次查询表。表的遍历顺序不参与需求或采购输出；负值或总和溢出风险仍走原排序与加法，
不裁剪输入、不修正旧算术规则。商品换算、训练排序、付款额度及需求发出顺序保持不变。
该表随既有 thread_local 暂存保留容量和旧内容，但每次有效采购计算先清空，不跨调用复用结果。

`MilitaryReport` 的 `supply_ring_requests/cache_hits/centers_built/cells_visited`
分别计实际行请求、缓存命中、新建中心和 BFS 取出格数；`payroll_lots_visited`、
`payroll_holders_visited` 计读取 lot 和有效付款对象组；`war_cells_visited` 计每日汇总扫描格数；
`engagement_index_slots_visited`、`engagement_members_cleared` 计重建所扫槽和关闭所清成员。
全部随 `step_day` 清零，直接调用内部步骤的测试可手动清报告。纯 C++ bench 输出累计/首日
两组计数；Godot 的既有报告映射尚未添加这些字段。验证要求逐日哈希、逐条意图顺序及完整
存档字节对照，不能只比较终态哈希或平均耗时。

- 军事兵种份额：玩家局部修改经 `MilitaryFacade.submit` 将稳定 id 解析为完整 `int_pairs` 后提交；原生 `config.set` 是整表替换。改动此链路时运行 `tests/ui/military_config_command_test.gd`，避免空命令或清除其他兵种配比。
- 军事部队编成：地块军事页从格快照中的本国驻军 lots 形成 `army.create` 请求；PlayerController 复核本国领土与占领状态，GDScript 不直接改写驻军或部队。入口与请求契约见 `docs/ui/military-cell-tab.md`。

- 军事部队视野：玩家部队的位置从已提交的 `get_military_render_snapshot()` 读取，作为低预算移动源交给 `VisionSolver`；城市/领土源仍拥有更高预算。军事 `render_revision` 变化时由 Host 合并触发一次视野刷新，不在 Military 内写 `MapData.visible_arr`，也不新增存档段。验证用 `tests/ui/vision_solver_test.gd` 的部队源覆盖，并在真实运行时检查部队移动后的 `vision_revision`。
- 玩家自动探路：任务、观察点、返程和战斗暂停归 `MilitaryCore`（`military_core_explore.cpp`，PKMI v4 section 23）；`army.explore` 只接受 Host 安装的玩家 observer。探路 passability 独立于普通 `find_path()`，战争状态也不进入他国控制格；每国每日 8 个规划槽、16 次 A*，并保留至少 16 次共享路径预算给区域控制。`run_movement()` 逐实际进入格产生 trail，Host 在 `_prepare_military_exploration_day()` 只合并 `MapData.explored_arr`，visible/fog 仍由既有 `_refresh_vision()` 生成；保存前必须 flush trail，失败拒绝保存。验证入口：`tests/military/military_auto_exploration_test.gd`、`tests/military/military_dossier_test.gd`、`tests/runtime/military_index_continuation_test.gd`、`tests/qa/military_dossier_screenshot_qa.gd`。

## GM 屏蔽与叙事弹窗

阶层动员由后台评价，选择与结果由后台按生效日结算。地图告警与弹窗读取同一份已发布事实。
让步和收买按原生报价计算，首都和仅余城市不能弃城。经济接受选择后写入叙事史册。相关回归入口为
`tests/game/narrative_event_runtime_test.gd`、`tests/game/narrative_popup_suppression_test.gd`
和 `tests/economy/economy_stratum_save_restore_test.gd`。

城市独立经 `CREATE_COUNTRY` 生效。国家提交时为新国家追加全零的研究信号位图行和两个空证据区间。
经济在同一天冻结国家快照，校验位图行数与国家槽位数一致。理念读取昨日提交的民意，民意可以只覆盖
当前国家槽位表的前缀，须逐槽校验国家身份。新国家按理念初始规则建行，收到首份实际民意时建立积分基线。
验证入口为 `tests/runtime/runtime_inline_coordinator_save_test.gd`。

- GM 的 `ui.suppress_popups` 由后台按生效日处理。后台为待答剧情选择可用的默认选项，年报奖励结算后
  跳过强制开卷，历史年报仍可查阅。时代大典只影响演出。时代奖励、家族创立和理念抽取沿用各自的确认规则。
  该设置与 `ui.hide_all_except_gm` 和正常剧情暂停选项独立，生效设置与待生效请求一起保存。
  确认段出现这份设置时写入版本 2，旧确认段仍可读。读档在接受整份运行存档前校验确认段。
  前台读取后台发布的状态，负责呈现和转交玩家选择。回归入口为 `tests/game/narrative_popup_suppression_test.gd`。

叙事事件额度统一为每格每游戏年**一次**：周期抽样、事实触发、普通 AI 事件共用
`NarrativeEventService` 的入队检查和展示检查。队列出队时丢弃当年已超额的普通事件，
全局弹窗间隔未到则等待；定时后续事件可以越过等待项，且不消耗年度额度。
AI 定时后续请求携带 `scheduled_followup`，生成结果重新进入定时队列，
不得提前展示，也不得将普通 AI 预热结果当作定时后续豁免。

- **弹窗静置**：玩家开着国家卷宗、营造、家族或军务档案、派遣、议和、史册、年报、GM 面板或时代纸笺时，
  叙事提示响一次，等当前窗口关闭后再显示后台发布的同一个选项。要求回应的事件由后台停在日末。
  窗口清单在 `GameUIManager.is_player_workspace_open()` 中维护。关窗通过 `notify_workspace_closed()`
  延后一拍重查，支持同一次操作关旧窗并开新窗。地块看板和暂停菜单沿用各自的显示规则。
  回归入口为 `tests/game/narrative_window_deferral_test.gd`。

AI 事件有三个入口：脉冲预热、事实驱动（`GameplayEventBus` 白名单 `AI_FACT_HINTS`）
和定时后续预取，共用 `ai_min_request_gap_days`（默认 60 日）节流与单条在途；概率按
`situation_pressure_score()` 从基础值抬到上限。回执统一走
`NarrativeEventService.accept_ai_generation()`：超过 `ai_max_staleness_days` 或读档后
迟到一律丢弃，落地时重新采样地块上下文，避免文案与到达时的世界状态错位。
状态探针（`NarrativeStateProbe`，首批粮食紧缺/民生不满/连旱）在条件维持 `dwell_days`
后预取，回执复核失败则入 `_ai_event_pool`，等同一状态复现时出池；池子随 `pknr` 存读档。
AI 叙事文本只写处境与后果，不写气温/价格/库存/人口/百分比/日期这类读数（prompt 明确约束；
「三人」「三成」这类数量词照常写），validator 仅把温度读数改写成 `{temperature}` 占位符，不删句子；
`custom_label` 例外，仍写幅度与时长。
回归同上。

叙事事件触发扫描保留居民汇总查询；`NarrativeEventService.choose_option` 执行选项时，
须通过 `sample_cell_context(..., include_cohort_details=true)` 取得真实居民句柄，
现金效果经 EconomyFacade 向原生经济/国家权威提交守恒转账，在后续结算边界生效。
回归见 `tests/game/narrative_event_runtime_test.gd` 的寒潮 3% 国库援助用例；
汇总快照没有 `handles/populations`，不能据此选择转账收款人。

## 家族派遣面板

无家族移民队的报价与派遣命令都使用显式的整数 `family_handle = 0`。
玩家命令校验不能把 0 误判为缺参，也不能把省略句柄当作无家族移民。

派遣面板以 `(source_cell, family_handle)` 标识来源行，目标已选时直接按地点分组展示
当地家族。全国进行中入口与详情都复用 PlayerController 查询，按日事件和回执更新；
不新增轮询或显示侧人口修改。筹备人数由 Economy 在推进时取计划人数与实际可派人数
的较小值，随后重新规划采购与进度分母；军人、最后族人及最后商人的限制共用同一计算。
已成交物资及在途采购沿用原托管/续接，不从 UI 退货或补账。回归用
`tests/country/colonization_planner_context_test.gd`、`colonization_workbench_ui_test.gd`
及 `tests/family/family_colonization_runtime_test.gd -- --population-shrink-only`。
旧套件基线限制见 current-state；机制契约见家族开拓运行时文档。

工作区开着时地图左键归派发界面独占，这条对**所有页签**成立：`handle_map_cell` 不论当前停在
「开拓」还是「派遣进展」都必须消费这次点选，进展页先切回派发列表再按原有步骤规则解释
（`_show_quotes()` 后走 `map_stage()`），不得直接 `return false`。`game_ui_manager.show_cell_panel`
会把被面板接管的点击整口吞掉，返回 false 不会退回普通 Inspector，玩家看到的只是「点新目的地
毫无反应」。派遣/取消成功后 `set_command_result` 会自动切到「派遣进展」，旧实现只在该页吞掉
点击，于是连续派遣只有第一支成功（2026-11-21 玩家上报）。回归用
`tests/country/colonization_multi_dispatch_ui_test.gd`（目的地入口、排队结算回执、顶栏全国列表
三条路径各派两支）与 `tests/family/family_colonization_multi_dispatch_test.gd`（原生侧两个不同
目标各建一支队、同目标仍按设计返回 `colonization_duplicate_target`）。

在途载荷里的人不是孤儿：`cohort_handle == 0` 且登记在 `family_expedition_person_handles()`
中的要人由载荷持有，`PERSON_COMMIT` 不得按「cohort 无效」退场；任何权威真的要退场时必须走
`retire_person`，由它在释放 slot 前摘掉载荷引用并修正后续 `person_begin`。回归用
`family_colonization_runtime_test.gd -- --transit-person-only`；死句柄进存档会让整份 PKEC
读档失败（`save_family_expedition_person_invalid`），不允许再以「加校验拒存档」应对。

## 国库收支展示

玩家看到的国库收支默认是近 30 日日均，总览页可切换近 7 日/近 30 日。数据入口仍是
`CountryViewModel.sample_fiscal_history()`，每已提交日同时采样财政快照与国家摘要里的
国库现金；不要从 `EconomyFiscalHistory` 的逐日展示序列直接求和，未结算日会沿用上次
结算值。滚动窗口只汇总去重后的真实结算事件，并用现金首尾差校准净额，未细分差额
进入「其他国库变动」。历史不足时按实际覆盖天数折算，少于两个现金样本则回退到最近
一次结算。顶栏悬停与总览共用 `EconomyDossierViewModel.cashflow_from_history()`。
定向回归运行 `tests/economy/economy_fiscal_history_rolling_test.gd`、
`tests/ui/hud_status_card_test.gd` 和 `tests/economy/economy_dossier_view_model_test.gd`。

## 军事现金回执与审计

军事 D+1 `SPEND_CASH` 的现有 reserve/collect 适配器是现金中性的：reserve 扣国库，
collect 将同额加回国库，不能因回执非零就登记 Economy `explicit_money_burn`。
军事维护真实终端支出尚未接入。审计窗口外已完成的资产变化也不能直接搬成下一
epoch 的 mint/burn；先判断 opening snapshot 是否已包含该变化。回归运行
`tests/economy/military_deferred_cash_conservation_test.gd`，同时验证真实待回执行恢复、
防重、后续经济结算与三项守恒；只观察军事回执成功不足以证明账目正确。

## 军事预算份额与季节地形重推

后台保存总预算、军饷、维持和采购四项份额。季节仅改变地表覆盖时，`MilitaryFacade.set_terrain()`
向原生提交新地表数据，原生保留已生效的军事政策。地图形状或邻居表变化时才重置地图相关状态。
`tests/runtime/military_index_continuation_test.gd` 执行原生军务自检，覆盖同拓扑地表重推和 PKMI
读档后的预算一致性。

## 科技详情栏效果优先级

详情卡的 `DetailBlock` 顺序固定为：摘要 →【掌握后效果】→ 进度条 → 事实条（时代/领域/研究成本/
路线）→【研究条件】→ 前置 → 后继 → 应用 → 按钮。效果块必须排在进度条、事实条和条件区之前：
后期科技的条件区能顶到十几行（时代门槛 + 每条前置 + 每条研究路线），效果被推到滚动之外就是
玩家说的「压在后面」。摘要行保留作「一眼扫完」的合并行，但它和逐条效果必须走
`technology_network_presentation` 同一个格式化口径（`modifier_delta_fraction`：认 `operation`
乘算、`_bp` 基点量纲、`_add` 绝对加量），详情卡不许自己再写一份 `value * 100`——那样会与摘要行
自相矛盾（例如地主「+40000%」、训练时长「+90%」）。定向回归
`tests/technology/technology_detail_card_effect_priority_test.gd` 与
`tests/technology/technology_effect_text_units_test.gd`。

科技卡片从公开目录读取按结构化效果生成的摘要。摘要和详情共用中文名称解析，商品、建筑、职业
和资源名称取自内容目录，地理产出效果同时标明适用地理与产业。

## 科技前置

科技前置修改只写 `data/technology/technology_network.json`，同步知识基础、前置理由和静态连线；
开局赠送的生存技能除外，正式研究须依赖早期知识机构。资源或发展信号不能绕过这一基础，
也不能替代取样工具、用火、窑烧、繁育等不可替代知识；新增硬边后保留原有时代与稳定 ID，
只按真实前置做最小拓扑重排，不能以时代标签充当普通科技的统一研究锁。
运行 `tests/technology/technology_knowledge_foundation_test.gd` 验证铁矿辨识、露头煤辨识和市场制度的
锁定及入队；权威与内容身份规则见 [科技运行时](../cpp-dots-runtime/technology-tree-runtime.md)。
全树知识闭包、静态连线及玉米实践领域回归运行
`python tools/technology_tree/test_prerequisite_foundations.py`。

## 科技内容节奏审计（2026-11-08）

新建或再平衡科技解锁前，先阅读 `docs/architecture/design.md` 和本指南，明确目录仍归 `technology_network.json`、建筑/物资/自然资源仍归各自 Profile，科技路线只负责研究资格，建筑完整门槛由直接科技与 `required_technology_tags` 合并而成。不要以应用交汇卡、目录标注时代或软投入伪造硬解锁。

全量审计使用 `Project/project-keynes/tools/technology_tree/rebalance_content_pacing.py`，审查416个稳定科技ID与459建筑、167物资、31自然资源的绑定和理论生产闭包；完整逐项决策及变化前后时代计数见 `Project/project-keynes/tools/technology_tree/technology_content_pacing_audit.md` 与 `content_pacing_revision.json`。本轮石器/农耕研究从75/67调整到56/51，王国/帝国为57/43；没有加入运行时时代锁或新的运行时信号。

核查顺序：Godot `build_technology_network_authoring.gd` 规范化；`run_content_pacing_checks.py` 串行运行 design、binding、closure、construction、industry、catalog、research、activation、application 测试；运行离线9个负例测试；成功后用 `--refresh-manifest` 刷新稳定目录指纹，生成并 `--check` 科技树报告。每次修改科技绑定后都重做全量闭包；逐时代同代假设不足以证明直接先修祖先可达。

## 部队指挥 UI（2026-11-10）

预览草稿归 `PlayerController`，命令仍走军事 facade；`MilitaryDossier` 固定指挥区通过
`GameUIManager.update_military_arm_order` 事件更新。move/area 确认前重验路径，失败保留草稿；
探路草稿只生成中心 + 半径的 `cells`，不调用 `preview_path()`，中心不可直达仍可提交。每日只写值，
同身份刷新不重建节点。交互与验证边界见 `docs/ui/military-army-controls.md`。

军事 UI 的显示层改动保持同一边界：主军事卷宗、地块军事页、部队/战线档案只读
`MilitaryViewModel` / `CellInspectorViewModel`；地图工具条只切换 `MilitaryMapLayers` 的
单层可见性，不直接查询或写入 MilitaryCore。按钮使用语义纸贴图标、44px 以上热区和显式
焦点链；训练行只展示目标兵种、人数、进度和剩余天数，不把“源自某职业”当成玩家决策字段。

地图军事视觉也只在表现层扩展：部队纸旗、交战纸章和 frontier grain 位图由
`MilitaryArmyTokenLayer` / `MilitaryBattleLayer` / `MilitaryFrontLayer` /
`MilitaryOccupationLayer` 的 shader 消费，不改变快照字段、军事状态、迷雾判定或存档。
真实渲染必须用 `military_formation_map_visual_harness.gd` 验证；仅通过 headless 不代表 shader
在图形后端可用。

## 军需市场需求（2026-11-08）

军事缺货预测走 Military intent 17 → Economy opcode 36 的既有 D+1 命令桥。每批先 reset 再按真实 SKU/市场格写入缺口；不要伪造销售、消费、财政扣款或库存。Economy 在 epoch 冻结时核对国家句柄、归属与可用国库资金，扣除其他公共采购承诺，并按 10 天窗口折算到通用采购需求。最新快照复用已保存/哈希的 pending command 队列，派生日需求缓存不入档，不增加保存 schema。验证入口：`tests/runtime/military_procurement_demand_test.gd`、`military_procurement_pod_test.gd`。

## 库存命令与结算审计

OwnedState 已应用的 ADD_STOCK / REMOVE_STOCK 命令，在经济侧接回结果时必须通知
`audit_touch_market_lane`，再保留原有显式增减记账。通知只登记变化位置，不重新写库存或
再次计算成交量；同一轮同一位置去重。两轮之间的库存修改也必须进入下一轮期初总量，
不能在清空当轮计数后丢失。`economy_runtime_command_audit_tests.cpp` 使用真实命令应用与
结果接回路径检查闲置期、活动期、限量移除、下一轮与恢复后的派生状态。

## 主线程服务完成与工作线程唤醒

`complete_main_boundary_service` 清除自身请求位时持有工作线程等待使用的
`_control_mutex`，释放锁后通知。原子位操作不能替代这一互斥约束：完成操作若插进
“检查条件”与“进入等待”之间，通知会丢失。Trigger 和 Ideology 各清自己的位，重复完成
无副作用。Trigger 的界面侧队列为空且没有延期交付时，轮询不用抢经济日锁。资源、军事和
Trigger 收尾都完成后，主线程先用原请求日期重试已排队的 Ideology 刷新，再确认当天收尾。
正常帧继续服务尚未完成的请求。架构检查抽取生产唤醒方法验证线程交错，收尾重试由
`tests/runtime/ideology_day_continuation_test.gd` 验证。

分域洋流任务先从 `get_climate_physics_commit_info()` 取得已安装快照的地图标识、格数、日期和版本。
需要开始一轮绘制时才调用 `get_climate_physics_read_view()`，核对两次读取的提交身份，再校验绘制所需数组。
风场和洋流切片沿用同一份数组，最后一片之后才统一提交。`OceanCurrentsJob` 管理绘制轮次，
`MapBaker` 管理这份数组、待提交的像素和地图的像素索引。换图或更换来源时丢弃未提交的像素。
快照的地图或格数不匹配时保留上一次显示，恢复匹配后可在同一季重画。版本或数组的开画校验失败时，
保留已显示的结果和季节刷新位置。验证入口是
`tests/runtime/ocean_currents_visual_query_test.gd`。

## 地图显示更新

`WorldRuntimeHost.publication_reader` 决定何时领取已发布的批次。零间隔表示每个处理帧检查。
固定间隔使用单调时钟，迟到时一次读取积累的结果，下次检查继续沿原定时间。年报和军事状态也在到期时检查。
普通面板首次刷新前保留开局或存档日期。普通面板和地图分别记录待显示的日期。
领取日记录时安装气候、视野与界面共用的地块分类。原生显示桥为贴图保留最近已领取的一份只读发布，
前台积累上次贴图应用后所有变化格、分类格及整图标记。只带日期的批次保留原有待显示内容。
帧预算允许更新时，显示桥先核对本局地图、日期、提交编号和格数，再复制生态贴图专用的过渡年龄
和上日活力。连续推迟贴图期间继续领取日记录和回执。宿主负责连接帧信号、发布贴图和记录耗时。
合并后用已安装的最新气候、视野、风场和分类数据编码，提交前一张与最新一张天气图，
天气表和云影共用该批风图。每日地图数据必须为每格提供过渡年龄和上日活力。
读取失败会返回具体原因，例如日期、提交编号或格数不匹配、贴图列长度错误、分配缓冲区失败。
宿主在首次失败时记录日期和原因，保留当前贴图和待处理数据，下次可提交时按整图重画。
暂停日期期间也能恢复，普通面板继续显示已领取的日期。
玩家场景在独立的 `MapViewport` 中绘制地图，窗口叠加最近一次画出的地图和原尺寸界面。
`draw_enabled` 控制地图出图，`ui_refresh_enabled` 控制普通面板接收合并更新。两者默认开启。
国家面板和顶栏状态的定时刷新也遵守界面开关。暂停刷新时积累变化，恢复后即使游戏日期没动也能更新。
地图窗口拥有最近画出的视野、选格坐标和日期，随换局解除绑定。宿主通过信号通知领取日期和贴图提交结果。
地图图层判断可见范围前先同步相机和窗口尺寸。画面落后时，地块面板先显示所点击的位置，相应画面画出后才读取详细资料。
换局、读档和关闭都丢弃上一个世界的待显示数据和缓存画面。同一世界重启执行器时保留积压，
用日期判定地图发布先后，并使用与该日期一起交付的编号取数。

桌面和移动设备的 30 / 60 帧档使用实际生效的上限，自适应档随现有设置在两者之间切换。
绘制间隔连续超出档位时，地图更新逐步拉开到每四帧一次。帧内已用时间和最近贴图开销
共同决定本帧是否可以应用，预留一成帧时间。每三次按时绘制缩短一帧间距。
跟随屏幕和不限档由原有同步设置控制。
视野实际变化时优先提交贴图，并在同次绘制前刷新边界、建筑情报及标签。
保存通过宿主的视野同步入口，在采集建筑情报前处理已发布的视野变化。

### 无界面性能记录

`tests/game/headless_perf_record.gd` 从 `simulation_day_records` 导出逐日 CSV，
每个结算日写一行。`commit_interval_ms` 由连续两日的后台提交时刻相减得出，
包括两次提交之间的等待。零预热时第 1 天没有前一日的提交时刻，因此该格留空。
逐日文件的 `t_sus_ms` 留空，因为后台发布记录没有逐日的前台 SUS 样本。
同目录的 `publications_*.csv` 保留实际读取批次的前台耗时与当时的运行诊断，
缺少完整前台样本的批次仍记录最后结算日及其版本号，未测耗时留空。逐日统计只使用结算日文件。
需要逐阶段耗时时可用性能工具的 `full` 档记录后台分段耗时。

性能结果声明 `recorder_method`。有预热的运行使用后台提交时刻计算吞吐率，零预热运行
使用从开跑到前台收到最后一日的时长。改变计时边界或样本定义时更新方法标识。
`tools/perf/perf_change_check.py` 只对同一记录方法计算性能差异，并单独校验逐日结果。
未声明方法的旧脚本通过文件内容判断是否相同。

回归入口 `tests/game/perf_recorder_publication_test.gd` 让第 6、7 天在同一批交付，
固定检查第 6 至 55 天都有一行。

## 海拔和风向专题图

`WorldRuntimeOverlay` 合并刷新请求，并在原有间隔到期后检查当前图。海拔图读 `MapData` 的海拔列，
风向图读风的两个方向分量和风速。原生显示桥保留上次贴图对应的数组引用和内容标记。
海拔在地图绑定和原生整列写回时登记内容标记。气候在已有的逐格校验中登记最终风值的标记，
并在三列都写回后一起发布。同一组值即使分属不同求解或写回也有相同标记。
图层到期时只比对固定数量的数组存储和标记。脚本直接编辑或替换数组后，旧标记会因存储
不同而失效。没有原生显示桥、列形状不符，或存储已变而缺少可比标记时，沿用原刷新路径，
诊断记录 `inputs_unavailable`。

切换图层、地图或显示资源，或者格子编号、索引贴图的绑定、输出尺寸或纹理有效性发生变化时，
重新生成共享纹理。跳过刷新时保留当前纹理和统计。读档从新会话第一次打开的图层开始建立基准，
内容标记和贴图检查均属于显示，存档与模拟摘要不包含它们。其他专题图继续按原有刷新规则处理。

## 资源视觉的变化通知与逐帧工作

`MapData.resource_visual_inputs_changed(flags, cells)` 在数据数组安装后发布；空 `cells` 表示整图。`BANDS=1` 对应资源储量、生物占领和适生区，`CLIMATE=2` 对应温度、湿度、积雪和活力记忆，`GEOMETRY=4` 对应水陆和海拔。原生 slot→MapData 发布统一经过 `resource_visual_publication.h`；原生及脚本视野只通知新可见格，生成/GM 的生物占领发布也通知。通知只入队，接收者在下一帧读取完整批次，不在发布调用中采样。

`resource_visual_work_queue.gd` 合并整图请求并保留扫描位置，扫描中再次发布会安排补扫；稀疏变化去重，连续稀疏变化仍给整图扫描四分之一的取项机会。初始化、配置、视野模式或资源记忆替换安排一次完整扫描，扫描结束后无变化不再采样。隐藏格不读现值，再次可见时补采；气候独立发布只刷新已有记忆的气候值，不重建 51 项丰度，也不触发实例重建。

## 大图每日计算与地表绘制

- 陆地与水面的覆盖网格用每行连续的小块组成矩形。保留原分类、边缘外扩、
  边界裁切与环绕副本，三角形统计取实际生成数量。
- 使用解析格界的迷雾层在提交绘制前跳过被完全遮住的地表。先判断整屏，再检查
  镜头内的地图块。判断读取与迷雾贴图同批发布的知识度字节，把扭曲、相邻格混合
  和屏幕取样范围计入。剩下的区域各合成一份陆地和水面网格，利用原来的材质与
  绘制顺序；画面范围或视野更新时，在当帧提交新的绘制区域。用
  `tests/rendering/terrain_draw_coverage_test.gd` 验证覆盖范围，再在真实图形
  环境对照雾边、横向环绕、移动镜头和视野揭开的首帧。
- 同一遮挡判断覆盖雾层下方的植被、资源道具和建筑批次。植被和建筑在上传时记录实例的位置
  和尺寸，绘制前把叶片缩放、投影外伸、屋顶和地面贴花计入。资源道具复用引擎的
  绘制范围，透镜放大的徽章保留。只有本帧在
  画面内的整个范围被不透明雾挡住才跳过该批次。地被和建筑底图用同一批可见矩形
  裁剪绘制范围，保留原材质、贴图坐标和绘制顺序。图层自身的可见状态、细节档和
  实例数据由原图层继续维护。定向测试见 `tests/rendering/detail_fog_culling_test.gd`。

- 资源恢复先按输入顺序加入有经济活动的格子，再按当天荒地批次的步长递增访问。已处理日和本日步数仍由每格的日历游标决定，只有资源发布成功才记日。
- 宿主完整验证日输入，再把数组移入只读队列。逐日计划核对这份输入的日期和版本，读档重启用同样验证过的帧重建队列。校验仍拒绝非有限值、非法邻接及水路环。水路的每条下游路径只需证明一次。`runtime_climate_input_hash.cpp` 按 64 位字归并现有参与校验的数组，含数组长度和末尾字节。后台和独立重算走同一摘要定义，CLM2 的状态校验由 ClimateStore 负责。
- 同一轮中相同纬度复用日照和昼长计算。天气邻接几何按坐标、邻接和环绕宽度的精确值复用。空气输送、天气场与大尺度天气推进只分配互不重叠的格子，等一轮结果齐全才开始下一步。
- 后台天气求解使用冻结的温度、位置与边界计算热赤道。启用物理环流时优先使用后台当日的场，其他情况下保留原脚本采样的温度来源与计算精度。物理场以只读数据随日提交发布，风轨迹只在日期和输入版本相符时复用。CLM2 继续保存完整物理状态。
- 纯地形或纯地貌的标签在每次冻结时按类别预先求值。其他标签按实际需要采样，线程按完整的 64 位标签组分工，所有组算完再按原顺序合计国家结果。测试覆盖值归到同一份输入，格子级覆盖仍在写入标签时应用。日末按请求的指标编号汇总，每格的主产商品供所有相邻格复用。资源等数值列按块比较，仍以原来的连续变化段登记。
- 地表贴图制作按横坐标复用环绕噪声的位置。高度计算可分行，各行写入独立区域，全部行完成后才计算河流和海岸并交付贴图。
- 地形主 shader 共用同一像素的次生地块资料，供迷雾、陆地和水面使用。半分辨率迷雾只在对应纹理可见时更新。画面验证覆盖迷雾早退、远近缩放和陆水分开绘制。

`ResourceVisualLayer.prepare_frame` 与 `drain_one_upload` 合用 `ResourceVisualProfile.frame_budget_ms`（默认 0.8 ms）。原有 observation/build 各自预算仍为上限；只为本帧真实到期的纹理上传预留时间，预算用完保留游标/队列。构建在样式之间、五个批次打包之间可续接；单次 GPU 上传不可中断。地表、记忆和几何上传按轮次取得机会，各自频率上限与几何批次 FIFO 不变，持续到期的地表不能饿死几何。性能验收仍为每帧 prepare+upload 的 p95 ≤1 ms，并核对固定帧数内的实际完工量。

样式选择、密度、位置、实例内容和画质规则不变。固定目录的类型、形态和默认优先级在配置时整理；profile 标量与嵌套覆盖每个同步片段重读，非空覆盖先复制小数组，不污染共用目录。候选分数有限且互不相等时用数值排序；精确同分、NaN 或 Inf 保留原排序算法及其取舍。

丰度观察的字段名、生物位、适生区及参考储量在配置时整理成只读列，重新配置必须全部
清空重建；实际储量数组只在同步观察调用内借用，隐藏地块仍不读现值。

`NativeResourceVisualBuilder` 仅计算样式选择和单样式布局，输入为值和数组，不持有地图、
世界、节点或回调。`resource_visual_native_slice.gd` 在单个同步构建片段内创建它，大数组
引用随片段结束释放，跨帧只留原单格进度。向量与数学内置函数走引擎同源运算，标量保持
原逐步舍入，整数哈希显式回绕；最终实例浮点数组按字节对照。扩展缺失、旧版或自定义
输入不受支持时仍走完整 GDScript 算法；原生入口拒绝前不得部分追加输出。

`WorldData.pixel_owner_indices/pixel_owner_present` 是烘焙时与原像素对象表一起发布的派生列，
额外占每像素 9 字节，不入存档。null 像素与非 null 但编号无效的对象必须区分；原 biome
数据优先级不变。整数组替换自动使数值列失效；显式原地修改像素对象表或对象 index 时须
调用 `invalidate_pixel_owner_snapshot()`，直到重烘后才恢复原生路径。生产路径仅在三处
烘焙发布点写表，其余只读；不能声称能自动检测任意 Array 原地改写。

`resource_visual_chunk_inputs.gd` 在现有相机遍历中统计当前区域首次未知的可见格。只在
该区域输入齐备后创建新构建任务，不越过相机/全局上限顺序，不等待整张地图。取出观察
任务时先完成计数再检查隐藏，避免中途隐藏留下永久等待；已知隐藏记忆立即可用。
切换视角不取消已有任务，重配、恢复与 GM 边界重建派生计数，持续变化仍沿用公平重做队列。

构建中再次变化只合并重做请求，允许已完成前缀继续；每轮按当前相机顺序处理尚未做过的脏块，避免一个持续变化块独占构建。第一批安装时推进该块的已发布版本（即使是空批），后续拒绝比它旧的批，接受同版本其余批。隐藏格仍不采集现值，几何只读取已观察的记忆；上传轮次不放开迷雾显示约束。

验证入口为 `tests/economy/resource_visual_layer_test.gd`、`resource_ground_cover_test.gd`、`resource_visual_update_test.gd`、`resource_visual_perf_test.gd`（常规及 `--large`）；更新测试检查完整实例数组、记忆/地表纹理、空闲停止、定点变化、隐藏/重新可见及恢复。`resource_visual_trace.gd` 可原样放进改前与改后目录，输出六个变化阶段的完整实例/样式/记忆/纹理字节作前后对照。CPU 测试不能替代图形环境下的 shader/画面检查。
`resource_visual_native_test.gd` 对照原生与脚本的选择、占位和实例字节；
`resource_visual_observation_reference_test.gd` 对照原观察算法；
`resource_visual_chunk_inputs_test.gd` 检查初次输入就绪、隐藏和生命周期。显式 release 库
检查同时运行原生资源布局与 bounce 字节用例，普通 headless 测试默认加载的是 debug 库。

## 加载期目录准备

`LoadingCatalogContext` 只属于一次 `MapGenerator.generate` 请求，以该请求的
`LoadingFrameGate` 区分下一次生成；不向后续世界保留源编译结果。Economy、Modifier、
Effect 的同步公开入口与协作入口共用一份编译实现。协作入口在实际资源/目录行循环中
按 4 ms 工作预算让出帧，取消返回失败且不保存半成品；预算只控制完成时间，不裁掉数据。

默认资源在一次生成请求内只读，生成期间不得热改默认目录；下一次生成建立新上下文。
默认经济目录在 Effect、Modifier、Country、Economy 配置之间复用。显式 FamilyEffect /
FamilyTrait / Modifier / Effect 资源在可让帧工作开始前用 `duplicate_deep(DEEP_DUPLICATE_ALL)` 取得独立副本（含外部 .tres 子资源），并按全部保存属性建立内容键；
同一资源实例被修改后必须重新编译。默认输入与显式覆盖各有独立身份，不能仅凭实例编号
或参数为空就把不同内容视为相同。缓存仅保存成功结果，每个消费者拿到独立 Dictionary。

Effect 源 Resource 在协作构建时也使用私有副本。目录构建完成后才调用原生安装接口。
Effect 每次等待结束都检查本次请求是否取消。取消时返回 `null`，由调用方读取
`context.canceled` 并回收上下文。目录校验失败时仍由 `_reject()` 记录具体原因。
国家开局准备在开始经济配置前、协作配置返回后检查同一请求的取消状态。主动退出沿世界关闭流程回收，
配置错误日志只用于仍在进行的请求。`runtime_loading_exit_test.gd` 覆盖配置期间关闭。
同步调用方仍使用原公开 API。`loading_catalog_cooperative_test.gd` 比较同步/协作全部
目录列、Effect 扩展与显示文字，并覆盖调用方修改返回值、同实例覆盖输入修改、
开始前取消与中途取消。大型理念源资源通过 ResourceLoader 自带的异步加载入口准备，
由请求上下文保留引用，避免同一请求多次解析；不在自建线程里访问共享资源或运行时。
取消时不等待文件读取。`loading_resource_request.gd` 在引擎报告完成后取走结果并释放请求，
其临时待回收表只持加载请求，不持生成器、世界或取消闸门。暖快照六个文件也走同一回收
入口：取消或任一失败立刻拒绝整批，其余请求自行完成后回收；齐备后才发布缓存。
显示目录准备也在真实行循环中让帧，原生安装保持原来的主线程顺序。所有规则安装完成
后即释放上下文的目录产物和源资源，不把它们保留到游戏运行期。

默认 Effect 的预编译列和扩展数据一起保存在 `effect_extensions.res`。来源校验通过后，每个默认会话拿到独立副本。仅含扩展数据的旧快照、缺失或过期快照、显式规则覆盖继续使用源编译器。

原生密集地图在生成时已算出六个方向的邻接格，脚本按原有地图顺序绑定编号时可直接使用这批数据。作者地图及读档仍经通用索引入口。分块地形的下一次原生烘焙可以在上一块上传后立即开始；主线程每帧最多上传一块，上传前检查取消和地图代数。

## 运行时诊断字段与主线程抑制门（2026-11-16）

- 诊断字段必须写入。只声明 + 导出、从不赋值的计数器比没有更坏：它把「这一步没跑」伪装成事实（`cell_layer_collect_count/_rows/_ideas` 就这样误导过一轮排查）。新增诊断要么在产生它的那一步写，要么不要导出。
- 主线程域门只认 `domain_main_thread_suppressed()`。外部读 `main_thread_suppressed_domain_mask` / `authority_window_domain_mask`（启动回复、`get_runtime_thread_report()`、`thread_report`、perf snapshot）；`authoritative_domain_mask` 只回答「worker 已证明拥有哪些域」，不能回答「主线程是否该跑」。请求了却拿不到的域会静默永久丢失，`authority_window_blocker` 是它的名字。
- `drain_derived_cell_layer(day)` 必须传在建的那一天。`reset:true` + `reason:"day_changed"` 表示这次调用丢弃了别的天的折叠，`error` 是被漏掉的 step 错误。
- reconcile 失败必须落 `last_error` 并计进 `effect_reconcile_failures`；不要用局部 `std::string ignored` 接住。
- 新增导出键时不要往 `runtime_pod_protocol.h` / `native_simulation_host.h` 里加字段（两者已超 `check_size_ratchet.py` 基线），放模块自己的内部头文件，见 `world_ext_simulation_host_internal.h`。


## 固定经济游戏日、预约命令与冷启动读档

- 正式经济每天对所有存活经济地块结算一次，开局首日及新出现人口的地块也只算一天。
  生产、消费、价格与按日平滑不以本机耗时选择 1/3/5 日近似。计时与工作量估计仅供诊断。
- 规划采用配置的固定 5—15 日周期，投资采用固定 10—30 日周期并长于规划；默认 10/30 日。
  日期、地块顺序和周期位置继续保存。旧周期强制键仅用于明确的历史近似夹具，不进入正式配置。
- Country 普通操作仍排到最早尚未封好的日期；明确预约的批次设置 `preserve_effective_days`，
  不能提前。入队在同一锁内回传实际日期，GM 回执使用该日期；已封好的日期只能向后调整。
- Country worker 的领土变更仅在正式提交后进入读视图，发布游标必须连续递增。
  领土补丁失配时补齐完整归属，再由 `country_committed` 刷新视野和国界。
  详见[视野迷雾与国界线](../cpp-dots-runtime/vision-fog-and-borders.md)。
- 开局两种国家创建路径均把开局国家放在第一个稳定槽位，吞并也不重排槽位。
  PKCN16 已保存这个顺序；冷启动恢复和只读副本安装须从它重建 `starting_country_slot`，
  配置及重置须清除旧值。不能依靠曾经执行过 bootstrap 的旧对象残留内存。
- Climate ACTIVE 的普通慢层刷新由输入采集按固定游戏日期触发，周期30日时为31、61……日。
  `SeasonRefreshSystem.run_due_round_for_capture` 复用 CLM2 已保存的完成边界，采用时钟的
  `输入日+1` 约定；同日重试不能重算。调度器探测次数、帧预算和冷启动不能改变到期日。
  刷新完整完成后才采集环境；非 worker 与显式 legacy-signal 对照路径仍沿用原入口。
- 一致性验收逐日比较正式周期下全部模块、完整经济状态、收支和命令实际效果；
  冷启动恢复至少跨过规划/投资及气候慢层边界，不能只测保存后的第一天或终值。

## 季节输入日期与经济恢复周期

玩家场景在显示开局加载画面时冻结日历，正式开局从第 0 天开始。后台计算第 D 天的天气时，气温和海冰的经过天数、天气季节和慢层刷新统一使用该份输入的日历日期。普通时钟、重试、提前准备和年报补发都要先取得 D−1 日已经写回地图的气候状态。新世界按实际地图种子生成年度气候变化，读档从保存的随机状态继续。

后台负责整日结算时，音乐和剧情在当天提交后读取事件。每个订阅者都能读取同一份已完成的事件记录，按各自读到的编号确认进度。读取期间其他日期可以继续发布，已借出的记录须保留到最后一个读者用完。

自动时钟按帧继续当天未算完的物种更新。手动按日推进时，同一次调用须用原日期和输入完成全部地块，再允许提交下一天，确保地图物种分布和国家获得科研线索的日期一致。

无画面会话在 100 倍及以上快进时缩短主线程休眠间隔，以便及时处理每日结果。暂停、降速和结束会话时释放这项设置。测速按实际提交的连续游戏日计时，逐日校验另跑，避免把校验本身的开销算入快进速度。

待发送的输入保留原日期。帧处理先接收已提交结果，再重试该输入。原生宿主用等待方的锁发布输入队列和日期，避免后台错过唤醒。`worker_time_input_wait_us` 保留原来的合计，环境输入为空、输入已到后的日尾等待、日内输入重试分别记在 `worker_time_environment_wait_us`、`worker_time_main_tail_wait_us` 和 `worker_time_input_retry_wait_us`。输入和日尾同时未准备好时，先记作环境输入等待。

后台气候的海域编号和海岸缓存按邻接及海陆分类判断是否有效。同类地形互换仍用实际地形运行气候计算；读档与依赖变化时可重建。经济储量的已提交副本按发布游标检查发生写入的数据页，独立维护其他读取游标，仍按原字节顺序生成存档和校验值。

完整后台会话的地图显示每个模拟日更新生态过渡与当前和上一份天气像素。渲染器把同一帧的数据合成一次纹理发布，并在天气插值更新之前完成。帧内未上传的数据属于当前显示世界，规则与事件仍在每日提交时接收。

`WorldClock.day_changed(d)` 的普通输入采集使用 `d-1`；CLM2 的季节完成日期保持
WorldClock 日期。因此输入31对应完成日期32，并非两个日期基准。提前准备输入时，
植被重复计算的判断必须使用该输入的日期，不能读可能领先或落后的显示时钟。
跨调用完成的季节轮也必须保存同一个输入日期；未完成时阻止发布，后续继续同一天，
不能跳到下一个输入日消费旧字段。4096只是单次调用已有切片上限，不是失败次数上限；
测试用有限4100次续算验证可继续、完成后不再启动同一轮。真正不收敛仍应停留并报告，
不靠任意重试次数或带旧数据推进来掩盖。

规划和投资周期及相位是存档模拟状态。profile 为新世界提供初始值，读档以保存值为准，
确保相同存档得到相同继续结果；调整现有世界须另设计明确的迁移或玩法命令。生产、消费、
价格逐日是固定计算规则，正常格式存档的市场周期为1，不受 profile 的慢周期更改影响。
PKEC62/63容忍仅用于直接分段解码的结构兼容检查，不代表历史PKSV可读；正式ECP2只收63。

Country `preserve_effective_days` 表示逐条保留提供的日期，并不让整批共享一个日期；
未指定的行打包为0，按入队边界移到最早可执行日。混排验证在
`country_late_command_reschedule_test.gd`；Country-only 不推进经济轮次的检查在财政续算用例。
`cell_tier` / `cell_next_review_day` 目前保留为存档及诊断列，不再决定每日结算参与范围；
删除每日维护需另做存档和状态摘要迁移，不在此轮改变。

## 地图绘制中的共享计算

水面、迷雾和天气各自管理一张用于显示的数值纹理。共用的 `render_data_table.gd` 在独立画布中绘制一次，调用者按输入变化刷新。只有回归测试需要把结果读回 CPU。

- 水波查找表初次分配或重新挂入场景时填满三页。之后一次绘制只覆盖周期变化的一页或连续两页，固定页保留原值。水面从同一张纹理取角点，按当前时间算波形与斜率。移动低档与纹理数量受限的水面程序直接计算角点。
- 迷雾每 0.25 个云形演变秒预先算好前后两个时刻，绘制时连续混合。切到最低档会释放纹理。半分辨率迷雾把数值纹理挂在实际使用它的子视口内。地表材质启用浓雾遮挡时，迷雾必须完全盖住它省略的像素。
- 天气在 `WorldData` 发布天气或切换地图时准备两份相邻数据。天气类型取当前值，风先解码为带方向的分量，再混合空间与时间。兼容模式沿用直接取值。
- 陆地保留三格底色，细纹取主材质，在两种材质交界处渐淡。植被复用已经选出的树冠轮廓，并让同株云影在顶点间过渡。建筑在顶点读取同栋共用的雨雪、可见状态与夜灯，地形光照仍按像素计算。

比较性能时固定镜头、动画时间、分辨率和各项画质。把水波换周期、天气发布和云雾更新计入帧时间。主要回归入口为 `tests/rendering/render_data_tables_test.gd`、`tests/world/fog_cell_field_test.gd` 和 `tests/world/vegetation_pixel_normal_render_test.gd`。

## 贴图导入形态与运行时读取

导出包只带**导入产物**，不带已导入文件的源文本，而且 `export_presets.cfg` 的
`include_filter` 对已导入文件无效（实测：给 `shaders/compute/*.glsl` 加了过滤器，导出日志里
仍然只有 `.glsl.import`，源文件没进包）。所以：

- 运行时读 `res://…` 文本前，先确认该扩展名没有 importer。`.json` / `.txt` / `.gdshader`
  这类没有 importer 的文件会按原样打包；`.glsl` 有 glsl importer（产出 `RDShaderFile`），
  源文本不打包。
- 计算着色器走 `load()` 拿导入后的 `RDShaderFile.get_spirv()`；需要现场编译时才回退到
  `FileAccess.get_file_as_string`（仅编辑器/未导入环境可用）。现实现见
  `scripts/rendering/visual_tile_horizon_baker.gd::_create_shader_bundle`。
- 纸贴图集按 VRAM 压缩导入（`compress/mode=1`），任何 `Image.convert/resize/blend_rect`
  之前必须 `is_compressed() → decompress()`，否则 release 下图层被静默丢弃。现实现见
  `scripts/ui/icon_catalog.gd::_paper_building_texture`。
- 用 `MultiMesh` 打包 instance buffer 的临时对象也必须先赋 `.mesh` 再设 `instance_count`，
  否则引擎每次都报 `multimesh->mesh.is_null()`。现实现见
  `scripts/rendering/shrub/chunk_refresh.gd` 的 GDScript fallback 路径。

## 电脑和手机画质设置

- 主菜单与暂停菜单共用 `GraphicsQualityOptions`。预设位于
  `graphics_quality_settings.gd`，单项修改从当前预设复制显示值并切到自定义。
  `GameSettings` 保存预设及自定义选项到 `user://settings.cfg`，用同一份解析结果
  应用帧率上限。地图贴图烘焙仍读取原预设，地图清晰度单独决定陆地/水面绘制尺寸。
- 地图清晰度低于 100% 时，`terrain_render_scale.gd` 只缩放陆地和水面平面，
  合成图放回地图原绘制位置。选区与地图标记按地图区域的原始分辨率绘制，相机和普通界面留在窗口。切回
  100% 归还两个平面；水面材质重建后也放入当前绘制目标。渲染验证使用
  `tests/rendering/terrain_render_scale_test.gd`，检查图层顺序、缩放、平移和调整窗口。
- 半屏浓雾按地表最终显示在主画布上的位置裁剪。低清晰度地表额外保留线性放大可能采到的一圈像素。地被和建筑底图复用同一组可见区域。水波和迷雾各自的数值纹理跟随使用它的绘制节点，切换清晰度时会在新视口里先于地表或雾层更新。
- 迷雾清晰度、天气表现、植被与点缀密度、水面、云影分别由各渲染层应用；
  关闭云影仍保留天气云的风场输入。切档验证入口为
  `tests/game/game_settings_service_test.gd` 和 `tests/rendering/cloud_weather_quality_test.gd`。

- 画质/省电开关只能关**动画与强度**，不能关**静态数据**。`has_flow_tex` 是静态河网的总闸
  （height 贴图 B 通道 = 河流 SDF；`scals.g = has_flow_tex ? height.b : 0`），只能由
  `RendererMaterialPublish.flow_channel_ready()` 按「height 就绪 + flow_buffer 覆盖全图」
  判定；`DCFeatureFlags.water_flowmap_enabled()`（移动端默认关）只允许影响流速蠕动与海洋
  环流漂移。同类开关接入共享通道前，先确认该通道的**所有消费者**只是装饰动画。回归入口：
  `tests/rendering/terrain_river_flow_gate_test.gd`。

- 雨雪幕按当前天气类型的绘制标记及插值后的强度判断是否完全透明。雾和闪电按
  各自的阈值跳过；雨雪在低强度时仍可能有可见贡献，保留原形状计算。两个项目的
  雨雪 Shader 一起更新。高档水面的细碎闪光随屏幕上尺寸平滑淡出，保留较宽的反光。

## 玩家可见时间文案（2026-11-19）

时间点与时长是两种口径，不要混用。

- 时间点（结算日、完工日、抵达日、创立日、信号首次记录日、停战与冷却到期日、事件与史册日期）
  一律走 `WorldClock.date_text_for_day(day, days_per_year)`；有时钟引用就传
  `clock.days_per_year()`，没有时钟的 view model 与 AI 提示词按默认 365 天换算。输出固定为
  `1年2月14日`；日索引是 0 起（第 0 日 = `1年1月1日`），不要把已加过 1 的显示日再传进去。
- 顶栏、GM 面板、年鉴这类已经拿到年/月/日字段的地方直接格式化成 `%d年%d月%d日`，不要再各写
  一套日索引换算；新增面板优先接 `WorldClock.date_text_for_day`。
- 时长保留 `N 日`：已战、剩余、工期、近 N 日、可支撑 N 日、N 日后触发。为了去掉“第”把时长
  改写成日期会读成错误的时间点；战争计数写成「已战 N 日」，不写「第 N 日」。
- 事件弹窗与史册的 `date_text` 由 `scripts/narrative/narrative_calendar.gd` 转交 WorldClock；
  无时钟路径也按默认年长换算，不再退回「第 N 日」。
- 回归入口：`tests/ui/player_top_bar_fit_test.gd`（顶栏日期不裁字）、
  `tests/ui/hud_status_card_test.gd` 与 `tests/economy/economy_dossier_view_model_test.gd`
  （结算日文案）、`tests/game/narrative_event_runtime_test.gd`（事件日期）。

## 近景地块告警与人口页

地图批次和单格人口快照共用原生阶层满意度聚合，按本格各政治阶层的人数加权，
以最低阶层的综合满意度判定告警。人口页可见时，地图同格的「阶层不满」取面板已呈现
的 `class_discontent`，并显示该人口快照的本地结算日。退出人口页后，地图保留同格较新的
阶层结果，直到收到更新代次的地图批次。地图批次按格拒绝回退，天气告警独立刷新。

悬停和点选共用浮标命中与视野检查。PlayerController 以浮标归属选格，议和、军令和军务
拾取优先级沿用正式会话。回归入口为 `cell_situation_snapshot_test.gd`、
`cell_situation_layer_test.gd` 和 `cell_situation_worker_test.gd`。

## 故障诊断基建（2026-11-19）

改动任何 `fail()` / `error = "..."` / 诊断上报前，先读这一节。台账是唯一真相，
代码是它的实现，不是反过来。

- **新增或改名一个 error 字符串 = 先登记台账**。`gdext/src/**/*.cpp` 里任何
  `error = "..."` / `fail("...")` / `set_restore_rejected_reason("...")` 都会被
  `tools/ci/check_fault_taxonomy.py --strict` 扫到；未登记就红。补登记用
  `--bootstrap-missing`（只增不改，先以 `kind=unknown` 入库），再人工补
  `kind/stage/witness/playbook`，最后 `--write-doc` 重生成 `docs/runtime/invariants.md`。
  **不要**靠放宽正则或加白名单前缀绕过。
- `kind=fatal` 的条目必须在 `gdext/src/fault_taxonomy.h` 里有 assert_id 绑定，
  `--check-cpp-ids` 会核。ID（`INV-<MODULE>-<NNNN>`）永不复用；合并断言时保留
  `status=retired` 的墓碑。
- `fatal_context_report()` 的 `witness` 只放 POD 标量，字段名与台账 `witness` schema
  一一对应。既有扁平键（`investment_row` / `construction_row` / `investment_legs`）
  是旧日志与旧 fixture 的契约，**只增不改**。
- `.pkinc` 是诊断产物：不进 PKEC/PKSV、不参与状态哈希、不可当存档加载。
  格式契约见 `docs/runtime/incident-bundle-schema.md`；生产者
  `scripts/game/incident_bundle.gd` + `incident_cell_slice.gd`（拆两文件是因为单文件
  会顶到 size ratchet 的 800 行上限），消费者 `tools/ci/inspect_incident.py` 与
  `tests/runtime/incident_replay.gd`。
- **现场里拿不到的字段如实记 `missing:`，不许造数**。当前如实记 missing 的有
  `commands.structural/ledger`、`pending_construction` 的物料需求、`hashes.economy_state_hash`、
  `hashes.ledger_hash`、`world.formal_start`。要给它们补数据，先在对应模块的 facade 上加
  薄包装（不要在 `scripts/game` 直调别的模块的原生绑定，`check_script_native_access` 会拦）。
- 全量 PKEC 现场**按需**：默认只写 `.pkinc`；要全量用 `PK_FORENSICS_FULL=1` 或调用方
  传 `extra.full_snapshot=true`（GM 手动导出走这条）。别再把「每次 fatal 一份 40 MB」
  写回默认路径。
- 重放的 `reproduced` 判据是「同一 reason + witness 关键字段逐一相等」。被排除的字段
  必须出现在 `uncompared` 里可审计；不许为了让自己绿而扩大排除列表。
- 提交前核验：`.\tools\ci\verify.ps1 -Quick`（static，约 20 s）。它里面有两条 `known-red`
  是本轮之前的既有漂移（`check_cpp_deps.py` / `check_size_ratchet.py`），`-Strict` 下才判失败；
  新引入的失败不许塞进 known-red。
- `tools/ci` 里读源码的脚本一律显式 `encoding="utf-8"`。中文 Windows 的 locale 默认是 GBK，
  不写编码就会在 UTF-8 源码上抛 `UnicodeDecodeError`（`check_module_contracts.py` 与
  `check_cpp_deps.py` 就是这么坏的，本轮已修）。
- `kind=fatal` 是**有硬性条件的登记**：`witness` 非空且值只能是 i32/i64/f64/bool/str，
  `playbook` ≥3 步且每步非空，`stage`/`owner` 非空；缺一项 `--strict` 就退出 1 并点名
  （`INV-XXX-0001 (reason): 缺什么`）。无历史豁免、无白名单，2026-11-19 起对每一条新登记生效。
- `--review` 是**审阅清单，不是门禁**：列出 `kind=unknown` 但名字像停机点的条目
  （含 `_fatal`/`_drift`/`_mismatch`/`_violat`/`_rejected`/`_must`/`_invalid`），给首次出现的
  `文件:行` 并按文件分组计数；它不参与 `--strict`、不改退出码。列表长是正常的，别为好看调窄。
- **抓不到的限制（如实记账）**：`--bootstrap-missing` 只会写 `kind=unknown`，所以"该标 fatal
  却标成 unknown"这条门禁看不见；也不做启发式猜测兜底——猜错会逼人瞎标，比诚实的 unknown 更贵。

## 地图悬停展板与地名层（2026-11-20）

改 `scripts/rendering/settlement_label_layer.gd`、`scripts/ui/cell_board*.gd`、
`scenes/ui/cell_board.tscn`、`CellHoverCard` 或任何「悬停某格显示什么」的功能时看这节。

- **指针语义只有一处**：`CellHoverCard` 的 `hover_cell_changed(cell_index)`（-1 = 无）是唯一
  的悬停格广播源。它已经处理了指针静止、速度抑制、指针是否落在 UI 上、相机平移/缩放、
  暂停、触摸、安全区与迷雾可见性。新增消费者只许订阅这条信号，不许自己再读
  `get_mouse_position()` 或复判这六件事——两套判定一定会互相打脸（卡片退场、纸签还在）。
- **停稳门槛分两级**：地名纸签跟着卡片走（130ms 静止）；左侧展板自己再加 300ms 停留，
  因为展板要开两个原生 per-cell 快照。`CellHoverCard.SETTLE_MSEC` 与
  `CellBoard.DWELL_MSEC` 的差值就是这两级。
- **原生 read-view 是有限资源**：每个 `(query, cell)` 订阅占一条，上限 128 条、TTL 5s。
  逐格 hover 都去查会把它打满，进而拖慢经济线程。所以：只对已定居格查、按 `cell:day`
  缓存、未就绪时按 `pending` 重试而不是拿旧值冒充当日、展板只在停稳后查一次。
  新增 per-cell 读数接入展板前先确认它在 read-view 里、并且能容忍 `ok=false / busy=true`。
- **地名 LOD 的口径**：繁荣等级就是人口档（2 乡村 / 3 小镇 / 4 县城 / 5 城市 / 6 都市），
  所以「远看只显示少数几个」与「远看只显示大城」是同一件事。缩放阈值四档被
  `tests/country/settlement_label_layer_test.gd` 锁住；要改档位就同时改测试与本节。
  首都通过 `set_player_capital_cell()` 豁免筛选，由
  `world_runtime_visual_adapter._player_capital_cell()` 在视觉刷新时从
  `country_facade.snapshot(handle)["capital_cell"]` 推一次，不进每帧路径。
- **环向地图只画一份拷贝**：`nearest_display_world` 取最近拷贝后不要再叠加 ±period 的
  第二份，否则接缝上会出现两枚同名纸签（曾真实出现）。
- **展板内容不外溢**：纸片用 `PKPaperPopup`，内容放内层 `MarginContainer` 留出撕纸边的位置；
  绝不用 `add_theme_stylebox_override("panel", ...)` 覆盖——那会把撕纸边顶成圆角纯色板。
  表头写列名不写标题，空表整张纸片不渲染，行数按可用高度三段压缩（5 行 → 3 行 → 只留市价）。
- **展板可覆盖左侧工具栏**：展板靠 HUD 左边缘放置，不沿用地图安全区的工具栏横向留白；
  物资与阶层纸面宽 520、正文 18px，列宽与图标一起放大。垂直方向仍避开顶栏和底栏，
  可用高度不足 650 时阶层压到三行，不足 510 时只留物资；不通过整体缩小文字适配。
- **展板与图例工具栏互斥**：`game_ui/overlays.gd` 订阅展板实际 `visibility_changed`，
  调用 `MapOverlayToolbar.set_board_obscured()`。展板入场时工具栏纸片用 `UIAnimation`
  在 120ms 内淡出并立即禁用整棵子树的鼠标交互；展板 130ms 退场完成后才启动 180ms 恢复淡入。
  减少动效时立即切换，快速重入取消旧退场，暂停期间动画仍完成。不改工具栏根节点的可见性，
  避免覆盖派遣等工作区的显隐控制；保留当前分类和地图图层请求。
  回归入口：`tests/ui/cell_board_toolbar_transition_test.gd` 与带渲染的
  `tests/ui/cell_board_screenshot_qa.gd`。
- **悬停物种**：`CellHoverViewModel` 经 `CellInspectorViewModel.local_species_badges()` 复用地理档案的
  `bio_occupancy_bits_arr`、物种目录和玩家已完成科技识别规则，不把资源储量当成物种占据。
  图标集中在 `IconCatalog` 的 `bio.*` 语义映射；缺少专用动物位图时复用动物图标并配物种名称。
  卡片资源下方按图标与名称的自然宽度紧排全部已识别物种，放不下时换行，空集合整行隐藏；
  槽位复用，卡片高度、阴影、
  屏幕边缘翻转及展板避让随实际行数调整，不新增悬停查询或模拟写入。
- **数据口径**：市价表的五类物资是「五个角色各挑一个还没被选走的物资」，不是「同一物资
  重复五次」；未解锁物资（`good_technology_available == 0`）与本地尚无价格的物资不参与。
  民情表的影响力 = `population + owner_employed × opinion_owner_influence_weight(2)
  + funds / opinion_funds_per_influence(1000000)`，与理念系统同源；组织度按职业读，
  缺失时留空轨道，不写 0%。

## 物种出现保底（2026-11-20）

每个 `bio.*` 物种默认仍按目录包络（气候、湿度、海拔、植被掩码、地貌标志、载体资源）播种。播种结果里
`occupied=0` 的物种会走保底阶梯（`scripts/geography/map_generation/bio_occupancy_guarantee.gd`，
在融合 boot pass 与逐段 bootstrap 两条生成路径后都会检查）：逐级放宽只对该物种生效的播种输入，并向
原生 `run_bio_seed_pass` 重发请求，顺序固定为 ① 去掉植被掩码 ② 去掉地貌标志（河湖/湿地/高地/干旱等）
③ 去掉载体资源 ④ 气候带放宽到 persist 容差内（温度/湿度 0.11、海拔 0.075，必须小于
`gdext/src/world_ext_bio.cpp` 的 `kPersistClimateMargin = 0.12`）⑤ 气候全放开（`map_extremes`）。
被放宽的物种同时把 `fill_keep` 收到 ≤0.08、`max_cost` 收到 ≤3，只留小片残存种群。
小图上生态行会（食物/放牧/纤维/特产）仍可能把格位占满，此时最后一步 `manual_relict` 直接按
“离该物种气候中心最近、且未达每格 3 物种上限”的陆地格补一格，只放宽行会互斥、不突破格位上限。

保底残存格可能落在目录气候带外，而每日 pass 的 `persist_ok` 会按目录边界剔除植株。因此
`_bio_occupancy_base_knobs()` 建缓存时调用 `realize_bounds()`：把每个物种的气候边界放宽到覆盖它
**实际占领格**的气候值（纯函数于占领位集 + 地图气候数组，同存档在任何会话重算结果相同）。保底播种
成功后作废 knobs 缓存并重置原生 configure，使生成当次与读档后的日推进使用同一份地图本地边界，
读档前后逐日行为一致。日常推进的植被/地貌标志/载体仍用目录定义，扩散仍受原规则约束；阶梯只改播种
请求，已播上的物种结果不变。

日志新增 `[bio-occupancy]   relax <signal> level=<id>` 与
`[bio-occupancy] guarantee attempts=N relaxed=N by_level={...} unplaceable=[...]`。
`unplaceable` 只应出现在地图完全不含该物种气候带的极端世界（例如没有任何河流/湿地的全干旱图上的芦苇）；
正常 earth_like 世界不应出现。

回归：`tests/world/bio_coverage_guarantee_test.gd` 在 10×8（玩家可选最小尺寸）与 14×10 上断言
每个物种至少一格、单格不超过三个物种、保底残存格连续三日 persist 后仍在、同 seed 两次生成逐字节一致；
`tests/world/bio_guarantee_ladder_test.gd` 用假的 `run_seed` 回调覆盖“只放宽失败物种、原 knobs 不被污染、
阶梯用尽时报告 unplaceable”的纯逻辑。

## 天气场分类与降水频率（2026-11-20）

围绕「降水极其频繁」的治理，天气场的四个环节改了口径并在生产 profile 里标定。
改动的入口全部在 `gdext/src/runtime_climate_pass_math.h` / `runtime_climate_passes_weather.cpp`
与 GDScript 镜像 `scripts/weather/{field_solver_physics,field_solver,feedback,weather_system}.gd`。

### 1. `convergence` 是「有符号净流入」，不是「风向一致度」

旧实现是半波整流均值 `mean_d max(0, cos(self→nb, wind_nb))`：六角格 6 个等间隔方向上
它恒在 0.29–1.25，**与风场有没有辐合无关** —— 均匀流（零辐散）实测读 0.3333。
证据与回归：`tests/world/weather_convergence_metric_test.gd`（均匀风必须读 0、辐合中心 1.0、辐散中心 0）。

新口径（`wf_wind_convergence_net_idx_{xy,cached}`）：

```
w_d     = clamp(|v_nb| / 1.2, 0, 1.25)
inflow  = Σ_d max(0,  cos_in_d) · w_d
outflow = Σ_d max(0, -cos_in_d) · w_d
conv    = clamp((inflow - outflow) / (inflow + outflow), 0, 1)
```

均匀流 ⇒ 0；辐合中心 ⇒ 1；辐散 ⇒ 钳 0。**没有引入 gain 系数**（`weather_convergence_gain`
仍是 dead，别拿它当缩放）；分布整体左移：p50 0.376 → **0.016**、p90 0.537 → 0.458、p95 0.612 → 0.636。

口径由 `PK_CLIMATE_CONVERGENCE_LEGACY` 选择：未设置 = net（生产默认）；`1` = 旧口径（仅诊断回退）。
解析在 knob 构造处完成（`weather_convergence_metric_from_switch`），进 kernel 的只有
`WeatherFieldKnobs.convergence_metric`，保证 slice / thread / native-daily 同口径。

**四份镜像必须同步**：`wf_wind_convergence_net_idx_xy`、`wf_wind_convergence_net_idx_cached`、
`field_solver_physics.gd::wind_convergence_for_cell`、`::wind_convergence_idx`。
注意 GDScript 的 legacy 分支**刻意保留**了旧缺陷（没有 speed 权重），只有 net 分支与 C++ 对齐；
这个镜像差异在退役 legacy 时消失。

### 2. 六个消费者阈值按新分位标定

net 的 p50 只有 0.016，旧阈值是按 0.376 的假基线定的 —— 不重标定会让「锋生门几乎永远关着、
海面释放门永远为 0」，真实辐合完全传不出去。现行值：

| 消费者 | 现值 | 依据 |
|---|---|---|
| `frontal_convergence = smoothstep(a,b,conv)` | **(0.02, 0.46)** | 新 p50 处闭合、p90 处全开 |
| `drv_cv = (conv−c)/d`（海面释放门） | **(0.02, 0.44)** | (p50, p90−p50) |
| `strat_drive += conv*k` | **0.70** | 保持旧 p90 处贡献 0.60×0.537/0.458 |
| `river_forcing_proxy` / `up_forcing_proxy` | **0.76** | 同比归一 |
| `dynamic_forcing = conv*0.65` | **0.76** | 同上 |
| `wf_apply_frontal_convergence_boost_idx::CONVERGENCE_THRESHOLD` | **0.64** | 新 p95 |

这些是**物理常数**，两种口径共用；W9 退役 legacy 后不存在混用问题。

### 3. RAIN 判定是四项合取，不是单阈值

旧实现 `precip > 0.040`（陆）/`0.032`（水）**无条件**通过，等于「下一点就报雨」。
现在四项同时满足才算降水：

```
precip > gate && effective_cloud > mp_cloud_gate
       && precip_cloud_mass > 0.35·mp_cloud_gate && vapor > mp_vapor_gate
```

- `gate`：`ClimateProfile.weather_precip_classify_gate_land/water`（生产 **0.095 / 0.076**，
  取自新口径下陆地降水率的 p80）。改这个 profile 就能改行为，不用重编。
- `mp_cloud_gate`：**0.18（水）/ 0.10（陆）**。原 0.22/0.12 是「弱分支」的门，变硬条件后需要下调，
  否则 20% 可见云量的暖湿海面会被判无云（`weather_field_solver_test` 的 marine 用例就是这条）。
- **STORM 与 MONSOON 也必须先过 `meaningful_precip`**。否则它们的判据（`precip>0.065/0.053` + 云门）
  比 RAIN 更松，会出现「RAIN 2.6% / MONSOON 13.8%」的排序倒挂。

分类口径用 `weather_target_type`（分类器原始输出）；`weather_type` 要过类型过渡状态机，
headless 短窗口里会停在 prev，不能拿来当验收读数。

### 4. 温度距平是分类输入，与 distribute 的温度扰动上限是两件事

- `wx->temp_anomaly = cell_temp − cell_temp_30d`（`world_ext_simulation_host_save.cpp`）。
  在此之前这条 lane 从未赋值 ⇒ 分类器距平恒 0 ⇒ DROUGHT/HEATWAVE 结构性不可达。
- `weather_classify_anomaly_cap`（**0.12**）只钳分类输入；
  `weather_temp_anomaly_cap`（**0.025**）是 distribute 阶段改温度幅度的上限。**不可互换**，
  混用会把天气对温度的扰动放大 5 倍。

### 5. 降水空间平滑与「面积 = 1/集中度」

`weather_field_precip_spatial_smooth` 现在由 `ClimateProfile` 显式下发（此前 C++ 吃默认 0.30、
GDScript 硬编码 0.30/0.09，两边从未同步）。生产保持 **0.30**。

反直觉但已被实测确认：**在硬降水率门下，平滑会压缩降水面积**（0.30→24.76%、0→32.46%），
因为它削峰摊薄、让更多格子跌回门下。不要用「关平滑」来降面积。

面积不是自由参数：`area = mean_P / P̄_rainy = 1/conc`，且 `P̄_rainy ≤ soft_cap(0.16)` ⇒
**`area ≥ mean_P / 0.16`**。任何面积目标都必须附 `ΣP / mean_P / P̄_rainy / conc / 下界` 五个数，
单独一个百分比不构成验收（`tests/world/weather_frequency_probe.gd` 会判这三条自洽性）。

另外：`soft_cap` 本身**在压缩总降水**，抬它会让雨更猛也更多（0.16→0.20 使陆地降水格 24.76%→30.80%），
不是「同量水重新分配」。

## 玩家 UI 文案精简

- 状态标题已表达结论时，tooltip 不再附同义解释；干旱、洪泛只显示状态名。
- 数值告警保留具体对象、程度及数据日期；禁用原因、后果、量程和图例语义必须保留。
- 工具栏用短标题表达用途；风向/洋流保留颜色与强度映射，不重复“显示各地区当前……”；
  军需路线、区域任务等范围含义写入标题。
- 空资源不插入“自然资源”空节；未识别资源的科技限制仍显示。条件列表不再附“完成以下条件”引导。
- 删除说明时同步收缩提示框、隐藏空注脚。地块告警按内容尺寸贴边定位，不保留固定 270px 宽度。
- 年报复制全文使用展示单位；不附重复的原始整数账目和内部缩放因子。

## 生物分布图标

生物覆盖层的条目由 `ResearchSignalCatalog.BIO_OCCUPANCY_BY_ID` 定义，图标键直接保留 `bio.*` 物种身份；具体纸贴只在 `IconCatalog` 映射。已有作物图标复用商品纸贴，动物和蚕使用 `species_01.png` 的独立裁切。禁止将具体物种统一映射到作物、牲畜或植被类别图标。缺失映射须通过 `IconCatalog.has_icon()` 发出诊断。

新增图集须在 `assets/icons/paper/manifest.json` 记录语义、裁切与参考图，以支持 `tools/art/build_paper_icon_atlases.py` 重建。回归入口为 `tests/ui/icon_catalog_audit_test.gd`，同时检查全部物种的覆盖、独立图标身份及像素重复。

- 顶栏悬停卡须单独检查 `hud_status_view_model.gd`，不能只查经济总览。统计窗口已在页头、
  净额标签中标明时，不再附“按最近 N 日折算”“多日结算不会堆在一天”等计算说明。
  有效收支无需空态脚注，未发布快照的错误原因仍保留；价格指数保留成本基准，删除加权公式。

## 战争迷雾的连续遮罩

- `PK_CELL_FIELD` 迷雾显示用连续三格权重；坐标扰动在原始格心平滑归零以保护中心状态。禁止在格心附近局部切回锐化权重，这会在连续场上形成规则斑点。涉及极地 padding 的三角形仍沿用原有锐化，避免全可见地图边缘混入未知行。
- 三角形、权重与边缘起伏分别在 `shaders/include/cell_field_overlays.gdshaderinc` 的 `pk_overlay_fog_tri`、`pk_overlay_fog_weights`、`pk_overlay_fog_edge_k` 定义，迷雾和天气门控共用。复用原两次噪声给过渡带增加凹凸，保留不规则云缘；`k<=0.05` 和全可见端不受影响，以维持遮挡证明。噪声频率由 `FogOfWarLayer.FOG_WARP_FREQ` 推送，默认 `0.010`；不新增噪声采样、纹理采样或绘制通道。
- 保留原有扭曲长度上限与地形早退强制不透明约束；不改逐格玩法视野或存档。三格候选范围不变，既有浓雾裁剪的保守范围仍适用。
- 回归：真实渲染运行 `tests/world/fog_cell_field_test.gd`、`tests/world/weather_overlay_field_test.gd`、`tests/rendering/fog_continuous_mask_test.gd`、`tests/rendering/render_data_tables_test.gd`；覆盖证明运行 `tests/rendering/terrain_draw_coverage_test.gd`。
- 连续遮罩测试接受 `-- --baseline=<旧 shader 绝对路径> --output=<输出目录>`，在固定视野、时刻、画质和分辨率下输出前后图及 ABBA 顺序的 GPU 耗时；基线必须是修改前文件，不得从修改后的着色器构造弱化版替代。

## 建筑差异化与精简

- 同代独立建筑须提供实际原料、能源、地理或经营组织选择，或被真实系统消费的独立服务。不同名字、单纯放大岗位/配方/产量、工具品质门槛及产业链标注不能单独构成新功能。
- 只有通用科技点产出的同代知识机构合并。研究效率、贸易速度、减灾等科技 Modifier 属于已完成科技，不能当成其解锁建筑的服务；删除建筑时保留有消费者的科技效果，移除只指向已删产业家族的空目标效果，不把专属大倍率叠到所有通用科研机构。
- 地理条件必须在建筑条件字节码或本地自然资源列中实际执行，不能仅靠 `geography.*` 标签。水力设施须真实检查河流；纺织必须消费纤维，不能用土地资源直接生产布。多产品路线须比较副产物比例，不能把不同产品组合误判为单纯规模变化。
- 删除的是作者目录中的独立类型，不是研究后自动退役旧建筑。保留的早期设施继续可建可营运。精简记录中的 `absorbed_by` 表示保留的玩法路线，不是旧存档建筑别名。
- 删除前逐项核对 BuildingProfile 的同链前驱、GoodProfile 的生产许可、科技 expected/content/support bindings 和应用交汇、Modifier 家族目标、发展成就主体、Trigger selector 及开局规划。前驱应接回原有较早阶段，不可产生自环、跨链或同阶前驱。删除最后一个生产者时同步撤掉该科技对商品的生产许可；不伪造另一个建筑的直接解锁。
- `data/technology/technology_network.json` 仍是科技唯一作者源；按当前存活资源同步受影响绑定，经 `tools/technology_tree/normalize_network.gd` 重建摘要。同步稳定 ID/内容清单并运行 `tools/prebake_loading_catalogs.gd`，不只删除 `.tres` 或修改 UI。目录身份变化沿用严格存档哈希拒绝，不静默套用新目录。
- 每次增加或恢复建筑须通过 `tests/building/building_distinction_test.gd`（同代科研、配方/产品组合/岗位/地理去重、已删 ID、发展成就主体、保留科技效果），以及受影响的作物链、开局、建筑运行、每日确定性和目录加载回归。旧生成脚本不得绕过精简记录把已删类型重新加入目录。
