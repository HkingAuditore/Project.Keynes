# Project.Keynes 长期项目记忆

## 关键架构
- 地图生成三阶段：① GDScript 发请求 → ② C++ 算完全部 → ③ C++ 返回、GDScript 解包。权威文档：`Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md`
- 详见 skill：`.codebuddy/skills/map-generation-pipeline/SKILL.md`

## 关键运行参数（实际值，非 map_config 默认）
- sea_level = 0.42（main.gd:116 实际值；map_config.gd:13 的 0.64 是死默认，被 main.gd 覆盖）
- num_continents = 2（main.gd:114）
- 地图尺寸预设：小40×28 / 当前60×40 / 大100×64 / 自定义上限500×400
- river_map_reference_cells = 15000（缩放基准，N>15000 才触发 river_map_scale）

## 已诊断的大地图生成问题（2026-06-30）
- 河流密集根因：channel_init=16 为 150×100 调参，预设尺寸(<15000)下缩放失效；N>15000 时指数 0.65 亚线性不足
- 高原密集根因：PLATEAU 无密度上限(PEAK/RIFT 有)；高原阈值不随地图缩放；噪声归一化采样使造山带特征数固定
- 诊断报告：`D:/Godot/ProjectKeynes/大地图河流与高原过度密集诊断报告.md`

## 已修复（density-fix 2026-06-30，需 rebuild DLL 验证）
- 河流：缩放指数 0.65→1.0；min_length 指数 0.75→1.0；river_headwater_init 6→10
- 高原：新增 plateau_max_land_ratio=0.25 面积占比上限（按连通分量面积降序保留，余下降级HILL）；plateau_max_relief 按 pow(15000/N,0.25) 收紧；plateau_min_land_h 0.25→0.35；PK_PLATFORM_UNDULATE 0.03→0.04
- up_count 未单独归一化（指数1.0已隐含等价归一化，SPL式inv对up_count无效）
- 改动文件：world_ext_generate.cpp、world_ext_internal.h、climate_profile.gd、computation-pipelines.md

## 自然资源系统（2026-06-30 规划阶段，未实现）
- 状态：已完成 plan，代码实现被回退（git stash@{0} "resource-system-implementation"），用户要求先看 plan 不应用
- 设计：仅 C++ native 节点（SCHEDULE_GRAPH 末尾 `resource` 节点）；字符串公式 + C++ 递归下降解析器；有序覆写表（priority desc 首匹配）；每资源一个 F32 slot；首次 tick 用 init_formula 初始化
- 首批资源：WOOD（可再生）/ IRON（不可再生）/ HORSE（可再生，依赖草原 vegetation==9）
- 变量集：temp/moist/elev/lat/river_flow/soil_moist/reserve/season/tick + terrain/landform/vegetation/cover/has_river/is_water
- plan 文件：`C:\Users\hkinghuang\.workbuddy\plans\blazing-forging-darwin.md`
- 待用户确认 plan 后再实现
- 注：截至 2026-07-09 实际已实现（28 种资源 + SoA + C++ pass + ResourceProfile/Registry），上述"未实现"状态已过时。

## 物资系统（2026-07-09 GDScript 方案已撤回，待重新设计为 C++ DOTS 架构）
- 撤回原因：用户要求物资必须进 C++ 参与 DOTS 计算，经济计算会频繁使用，需高性能架构；GDScript 离散容器方案（Array[MaterialStack]，不进 SoA）方向错误，已全部删除。
- 待重新设计：物资进 component_schema SoA slot + C++ pass；需解决"每格多种物资、种类动态"与 SoA"固定槽位连续值"的张力；价格 per-cell 浮动。
- 流程教训：写完 plan 必须先向用户展示并明确等待确认，不能依赖审批工具自动信号进入实现。
- 旧 plan 文件（已废弃）：`C:\Users\hkinghuang\.workbuddy\plans\cosmic-aurora-einstein.md`

## Ocean 物理 cell-range 切片（2026-07-07，设计态待本地验收）
- 范围：ocean_currents(32.5%) 四 leaf pass（SLP/WIND/PSI/UPWELLING）的 cell-range 切片 + GDScript stage 内游标。
- 状态：Item1(C++ 缓存 slot-id/LUT/邻居) + Item2a(C++ 切片) + Item2b(GDScript 游标,默认关) + Item3(文档同步) 全部已落代码/文档，但**本环境无法 rebuild/PROBE，均设计态**。
- 关键设计：SLP 持久 `_phys_slp_buf` 跨切片累积，全局归约 gate 在 `end_idx==n_cells`；WIND coast/sea BFS 抽 `_phys_ensure_wind_coast` 指纹缓存；**PSI 不做 cell-range**（Gauss-Seidel 全扫掠）；游标仅 `_PHYS_STAGE_NONE→SLP` 归零，stage 名/fallback 不变。
- 验收门槛（用户本地）：rebuild + bit-equal + 零 fallback + 每切片 p95/max<1ms + 轨迹无漂移；未达前 `_phys_cell_slice_enabled=false`。
- 不在范围：native_daily_sim(51.5%) 的节点级 cell-range 属 §7 后续；weather 节点 7.77ms 全局最大尖峰是其目标。
- 权威设计：`tmp/cutting_native_daily_ocean.md` §7.7.1–§7.7.5。

## Git 工作流注意（2026-07-09）
- **Godot 锁 dll**：Godot 编辑器运行时会锁定 `addons/dots_ext/bin/windows/*.dll`，导致 `git pull/checkout/reset` 触碰这些文件时报 `unable to unlink old ... Invalid argument`。更新仓库前必须完全退出 Godot 进程（tasklist 中的 `Godot_v4*`）。
- **误提交 ~ 临时文件**：远程误提交了 `bin/windows/~dots_ext.windows.template_debug.x86_64.dll`（Godot 生成的 `~` 备份 dll，被 git 跟踪）。这是垃圾文件，应在远程清理、本地避免提交；Godot 退出后才可删/写。
- **本地改动==远程时的安全同步**：当本地未提交改动内容哈希已 == 远程最新（同源工作），`git pull` 仍会被 `local changes would be overwritten` 保护拒绝。已验证 work==remote 后可直接 `git reset --hard origin/master`（不丢真实改动）；或 stash→pull→stash pop。本次即此路径完成 master 快进到 60c3cb0。

## 产业链设计现状（2026-07-14）
- 规模：**30 资源 / 136 物资 / 182 建筑 / 361 边**，最大链深 Tier 17（construction_components）
- need 体系：15 个 need，staple_food/protein 各 5 variants，**luxury 仅 2 variants（jewelry, beverages）**（用户锁定不扩）
- 食物链分双轨：① 通用 `grain`（subsistence_food 4 层链：gathering→smallholding→3-field→improved→mechanized） ② 4 种原粮（corn/rice/wheat/potatoes）各自 T1+T2 加工链
- **wheat_grain 是孤儿**：`wheat_farm`(陶器)→wheat_grain 仅 `grain_plant`(信息) 消费，6 个时代无消费者
- 替代机制（`input_category_ids`）已实现（C++ `select_input_candidate` in economy_runtime.cpp:4038-4074，按「库存充足度 > 价格/效率 > stable_id」选最优），**但食物链 0 栋建筑启用**；21+ 栋建筑启用（主要是 tools 类）
- 4 原粮已共享 `category_id="primary"`（与矿石/盐/黏土等 16 种共享），改 category 会失去 primary 成员资格；当前 `primary` 用作输入的 0 栋 → 0 风险
- 时代断层：5 个直接断层（paper→packaging 影响 9 栋、salt 影响 1 栋、fertilizer+machinery 影响 1 栋）。详见 `docs/产业链时代断层分析报告.md`
- 73% 建筑集中在信息时代（`tech.legacy_modern_economy`），蒸汽 8.2%、其他时代 <5%
- 62% 物资仅 1 个生产者（单点故障）
- review 报告：`C:\Users\hkinghuang\.workbuddy\plans\toasty-cascade-darwin.md`（720 行，未实施任何 .tres 改动）
- 4 类物资 category 拼写重复待清理：`textile`(11) / `textiles`(1) / `raw_materials`(1)
