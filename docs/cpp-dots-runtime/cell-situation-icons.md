# 近景地块悬浮告警（2026-10-25）

正式玩家会话无需切换模式：地块投影宽度达到 80 px 后，其上方显示当前不良状态的
透明位图。缩至 72 px 以下隐藏并停止读取，避免阈值附近反复闪烁。默认半径 22 的
地块约在相机缩放 2.10 进入、1.89 退出。图标固定 25 px，同格最多八种，以三列排列；
悬停给出具体商品、最不满阶层、比例与本地最近结算日。移动/缩放不拦截地图输入。

## 数据来源与判定

八列顺序是 API/图集共同契约，`flags` 中 bit 与列索引一致。

| 列 | 告警 | 权威来源与显示阈值 |
| --- | --- | --- |
| 0 | 生活物资短缺 | 需求 tier 为 subsistence/basic 的商品，取最大 `last_shortage_q16`，缺口至少 25% |
| 1 | 工业品短缺 | 本格建筑实际生产投入/施工材料预留与商人库存之差，最大缺口至少 25%；无需求的空库存不报警 |
| 2 | 消费品短缺 | comfort/luxury 需求商品，取最大 `last_shortage_q16`，缺口至少 25% |
| 3 | 阶层不满 | 各政治阶层按本格人口加权的 composite 满意度，最低阶层低于约 40% |
| 4 | 干旱 | 已初始化天气 `DROUGHT` 且不是水域；慢性植被压力不冒充正在发生的旱灾 |
| 5 | 洪泛 | 已发布地表覆盖 `CoverType.CV.FLOODING` |
| 6 | 失业率高 | cohort 未就业人数 / 总人口，至少 20% |
| 7 | 建筑岗位空缺 | `(job_capacity - jobs_filled) / job_capacity`，至少 25%；复用 `group_job_totals` 的当前计划用工并排除停业建筑 |

同一商品同时出现在基本与舒适需求中时，居民短缺优先归生活物资。工业预留为已有
`max(production_input_reserve, construction_material_reserve)` 口径，与市场 Inspector
的家庭可用库存一致。工业用途可与居民用途同时受压，故三种告警不互斥。岗位空缺
也可能来自职业门槛或工资吸引力，tooltip 不把它断言为人口总量不足。

## 读取和渲染边界

- `gdext/src/economy_runtime_queries_situation.cpp` 实现 bounded read；由既有
  `committed_read` 和 `ReadQuery::SITUATION_VISUAL_SNAPSHOT` 分派进入 EconomyCommitView。
  worker 忙时订阅，返回 pending；消费层保留上一有效提交，不借机访问半结算状态。
- 输出 `cell_indices`、`flags`、`severity_q16`（每格八列）、`cause_good_ids`（每格三列）、
  `worst_class_ids`、`class_ids`、`state_days`、`economy_generation/sample_day`。
  天气列由 `DCViewAdapter` 补齐，经济查询不拥有或推算气候状态。
- `CellSituationLayer` 在 HUD Canvas 中绘制，共用一张图集、八个冷路径 AtlasTexture，
  不为每格/图标创建 Control 节点。tooltip 节点持久复用，既有地块悬停卡在其显示时让位。
  图案从 `IconCatalog` 的八个 `situation.*` 键读取，使用
  `assets/icons/paper/ui_situations_01.png` 彩铅剪纸图集；旧金属徽章图集不再加载。
- 每 0.25 秒最多查询一页 128 格；候选来自逆相机变换的视窗行列范围，中心优先，
  最多 1024 格，不扫描全图。稳定分页在后台日提交后继续轮转，不停留于第一页。
  最大候选数下完整遍历约 2 秒，常见近景视窗更快；配置在 `UITokens.MAP_SITUATION_*`。
- 相机移动仅逐帧重定位绘制；候选枚举/排序按查询节奏合并。只读当前可见格，
  查询、绘制、悬停均检查当前视野；视野撤销逐帧剔除已有显示。重新绑定世界清空缓存。
- 不添加地图 overlay mode、经济存储列、DataCore slot、存档版本、state hash 或模拟日任务。

## 美术与验证

图集：`assets/vfx/situation/situation_badges.png`，1774×887 RGBA，四列两行。
从左到右、从上到下依次为生活、工业、消费、不满、干旱、洪泛、失业、岗位空缺。
采用黑色珐琅底、黄铜边、象牙色符号与红色告警角标；来源/制作规格见同目录 README。
导入启用 mipmaps，AtlasTexture 按各格 alpha 包围盒裁取显示区域，不修改生成原图。

验证入口（均在 Godot project 下）：

- `--headless --script res://tests/economy/cell_situation_snapshot_test.gd`：真实结算、三类缺口、
  最差阶层、就业/岗位与权威摘要对照、输入边界、只读 hash 一致。
- `--headless --script res://tests/world/cell_situation_layer_test.gd`：远景零读取、视窗候选与
  批量上限、稳定分页、天气和经济同格共存、pending、防抖、视野和正式场景挂载。
- `--headless --script res://tests/economy/cell_situation_worker_test.gd`：正式 ACTIVE worker
  的 committed-read 批量消费与跨日刷新。
- `res://tests/world/cell_situation_visual_harness.tscn -- <absolute output directory>`：
  复用建筑视觉 fixture 和正式图标层，输出 near/tooltip/far 三张画面。中央八状态为
  人工注入的展示组合，截图不代表某次真实存档同时发生全部灾情。

`diagnostics()` 返回候选/缓存/图标数量、最近批量数、查询耗时、视窗枚举数；这些数字
仅供视觉诊断，不作为模拟调度或存档权威。
