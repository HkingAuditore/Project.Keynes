# 50x 吞吐诊断记录（2026-10-09）

目标：50 天/秒，即 worker 每日执行 ≤ 20 ms。本文记录本轮已确认的发现与待办，
「日瀑布」已把未归因的约 20 ms 拆清（见「筛查结果」），优化统一在此之后处理。

## 测量条件

- `tests/headless_perf_record.gd`，`seed=20260718 width=60 height=40 foreign_count=5 speed=50`，
  template_debug DLL（godot-cpp `/O2` + `DEBUG_ENABLED`）。
- 分阶段成本：`PK_ECONOMY_COST_CSV=<path>`（`EconomyCostProbe`，列为 `day,phase,work,ms`，探针嵌套计时，不能直接相加）。
- 日瀑布：`PK_RUNTIME_WATERFALL_CSV=<path>`；分析脚本 `tmp/analyze_waterfall.py <waterfall.csv> <min_day> [cost.csv]`。
- 地图规模：2400 格 × 134 商品 = 321600 条市场通道；第 2000 天仅 6 个格子有建筑，
  人口槽位 384，名人约 20。

| 场景 | worker execute ms/天 | 吞吐 |
|---|---|---|
| 用户编辑器录制（CORE，修复前） | 56.8 | 17.6 天/秒 |
| 无头 8000–8300 天（修复前） | 68.9 | 11.6 天/秒 |
| 无头 2000–2100 天（修复前） | 55.5 | 14.3 天/秒 |
| 无头 2000–2100 天（修复后） | 42.0 | 17.8 天/秒 |

## 已修复：`MarketResult::reset()` 漏清人物向量

`economy_runtime_results.cpp` 的 `reset()` 漏清 `person_needs` / `person_attributions` /
`person_demography`。每个市场的 `MarketResult` 跨天复用，三者无限累积：

- 性能：每日进入 `person_needs().swap()` 的行数从约 6000（第 0 天）线性涨到约 11 万（第 2000 天），
  8000 天推算约 35 万；person 阶段 1.7 → 27 ms/天。修复后 0.08 ms/天，`household.merge` 0.72 → 0.03 ms。
- 正确性：历史死亡事件每天重放 `record_person_demography`（名人被反复抽死）；
  人物 `epoch_consumption_expense` / `epoch_tax` 每天叠加全部历史；`person_needs` 去重用不稳定排序，可能留下旧行。
  修复会改变人物相关的确定性基线，存档格式不变。

新增 opt-in 探针：`person.epoch_swap`、`person.index.{needs,count,fill,sort}`。

## 待处理一：全量状态哈希

| 哈希 | 次/天 | ms/天 | 算法 |
|---|---|---|---|
| `pod_hash`（`RuntimeEconomyPodAuthority::state_hash`） | 1 | 6.78 | 人口逐槽 + 市场 4 列 `RuntimeChunkHash`（4 KB 页、Merkle 树、逐字节 FNV） |
| `ledger_hash`（`RuntimeEconomyLedgerState::computed_hash`） | 2 | 1.50 | 20+ 列逐元素 FNV（`economy_hash_lanes<false>`，零块跳过） |
| `native_hash`（`NativeEconomyRuntime::state_hash_internal`） | 1 | 0.36 | AGGREGATE_PUBLISH 的 `finish_ok` |

`pod_hash` 卡点：
1. 每日 `import_and_publish_committed_ledger` 执行 `_state = std::move(restored)`，
   `market_hash_pages` 随之换成空缓存，`RuntimeChunkHash` 每天走 reshape 全量重建。
2. 逐字节 FNV：约 7 MB 市场数据 ≈ 700 万次串行乘法；同数据 `ledger_hash` 单次约 0.75 ms，慢约 9 倍。
3. 每页 `make_shared<Page>` + 4 KB 拷贝。
4. 结果仅用于快照头 `state_hash`。

方向：跨导入保留分页缓存（memcmp 兜底保证正确）→ 按需/每 N 天计算 → 逐字/多路哈希（需 `VERSION=3` 与存档兼容）。

## 待处理二：每日收盘镜像与校验链

非绑定模式（`formula_owned_bound()==false`）每日路径（`native_simulation_host.cpp` 经济域）：

1. `capture_committed_ledger_state`：新建局部账本，深拷贝人口/市场列，同步重建建筑/贸易/家族/资源 store，`recompute_hash()`（第 1 次 ledger_hash）。
2. `import_and_publish_committed_ledger` → `build_owned_state_from_ledger`：`valid()` = 形状校验 + `verify_external_digest()`（同线程第 2 次全量哈希），再整份构建 `RuntimeEconomyOwnedState` 并替换、释放旧状态。
3. `pod_hash` 全量重算。

`[economy-boundary-cost]`（第 1100–2000 天）：`formulas_ms` ≈ 11，`stages_ms` ≈ 7.8，**`mirror_ms` ≈ 17–19**。
镜像中已计时约 8.5 ms（pod_hash + ledger_hash + ledger_validate），其余约 9.5 ms 无探针（推测为大块分配/拷贝/释放）。

另：`opening_audit_full` 0.96 次/天（增量收盘且未开连续审计时强制全量期初），`audit_shadow_rebuild` 每天重建。

方向：去掉第 2 次哈希；默认连续审计（`PK_ECONOMY_AUDIT_SHADOW_REUSE=1` 语义，保留 25 天全量校验）；
抓取账本双缓冲复用；根本上消掉每日双拷贝（切绑定 N10 路径，或镜像按需化，需设计 fault 回滚点语义）。

## 待处理三：经济业务阶段（formulas ≈ 11 ms，图阶段 ≈ 7.8 ms）

| 阶段 | ms/天 | 备注 |
|---|---|---|
| employment | 1.92 | 6 个建筑格串行，单格约 320 µs，内含报价 |
| owner_opportunity_quote | 1.63 | 63 次/天，全部 memo 未命中，约 26 µs/次 |
| aggregate | 1.37 | 审计各段 + verify + watermark + trade_init + commit(0.90) |
| production | 1.32 | 6 次 compute 合计 1.27，疑似串行 |
| epoch_vectors | 1.11 | 向量很小，耗时疑在 `refresh_derived_business_demand`（待确认） |
| cohort_demand_preview | 0.93 | 22 次/天，memo 作用域短，基本未命中 |
| building_plan / building_commit / household / structural / family | 0.68 / 0.48 / 0.46 / 0.42 / 0.41 | |

方向：慢周期降频（报价、派生需求、投资）、跨天缓存 + 价格版本号、后期再评估并行门槛。
注意此块随建筑格子数线性增长；镜像/哈希随地图通道数增长，与发展程度无关。

## 筛查结果：日瀑布（第 2000–2100 天）

工具：`PK_RUNTIME_WATERFALL_CSV=<path>`（`runtime_day_waterfall.h`），每个日尝试一行，
段首尾相接，`residual` 按构造为 0。A 组只开瀑布（39.17 ms/天，与 worker EXECUTE 桶
39.18 ms/天一致 → EXECUTE 已被完整覆盖）；B/C 组叠加 cost CSV（38.1 / 40.6，探针开销在噪声内）。
无同日重试（failed_attempts=0）。

| 段 | ms/天 | 占比 | 构成（cost 探针，ms/天） |
|---|---|---|---|
| `econ.formulas` | 9.97 | 25% | 见「待处理三」；其中校验类 `opening_audit_full` 0.72、`native_hash` 0.33、`audit_shadow_rebuild` 0.21、`ledger_validate` 0.15 |
| `econ.mirror_publish` | 8.01 | 20% | `build.restore_slots` 2.16（含 `candidate.clear()` 零填 321600 通道，随后被列拷贝覆盖）、`build.committed_copy` 1.51（`candidate.committed = ledger` 整账本第 3 份拷贝）、`publish.state_assign` 1.50（释放旧 owned state）、`build.valid` 0.83（第 2 次 ledger_hash）、`publish.ledger_assign` 0.45（释放旧账本）、`build.columns` 0.41、`build.blocks` 0.17、未细分约 0.7 |
| `w.climate_writeback` | 7.68 | 20% | **`climate.snapshot.hash` 6.68**：`RuntimeClimateAuthority::snapshot()` 每日对整份气候 store 调 `state_hash()`（`temperature_history` 876000 float + `physics_state` 144 KB + 全部 lane，串行 FNV），而 plan 阶段已有 `_planned_state_hash`；`payload` 拷贝 0.78、ring 赋值 0.28 |
| `econ.pod_hash` | 6.61 | 17% | 见「待处理一」 |
| `climate_compute` | 3.10 | 8% | 气候 plan/commit 本体 |
| `econ.mirror_capture` | 2.46 | 6% | `capture.market` 1.34（4 列 × 321600 深拷贝）、`capture.hash` 0.76（第 1 次 ledger_hash）、`capture.blocks` 0.31 |
| `d.country` / `d.input_capture` / 其余 | 0.68 / 0.59 / 0.1 | 3% | |

按性质归类（A 组 39.2 ms/天）：

- **全量哈希/校验 ≈ 16.2 ms（41%）**：pod_hash 6.6 + 气候快照哈希 6.7 + ledger_hash×2 1.5 + 审计/校验 1.4。
- **整份拷贝/分配/释放 ≈ 8.9 ms（23%）**：镜像构建零填 + 三份账本拷贝 + 两次大对象释放 + 气候快照拷贝。
- **经济业务公式 ≈ 8.6 ms（22%）**，气候计算 3.1 ms（8%），其他域 1.4 ms。

结论：原先未归因的约 20 ms 主要是 **气候写回快照的冗余全量哈希（6.7）** 与 **镜像内部的零填/第 3 份拷贝/释放（约 6.5）**；
与业务规模无关、随地图通道数（2400 格 × 134 商品）线性增长。

## 已修复：冗余哈希与镜像整份重建（第 1–3 项）

1. **气候写回快照**：`RuntimeClimateAuthority` 新增 `_committed_state_hash`（commit / adopt / restore 同步，
   播种与 reset 归零）；`snapshot_into(out)` 拷贝赋值进 ring 槽位复用容量，`state_hash` 只取已知值，
   ACTIVE 下为 0（唯一读者是写回诊断字典，存档 `serialize` 自算）。
2. **经济镜像**：新增 `import_and_publish_captured_ledger(ledger&)`——同线程刚抓取并算过 `ledger_hash` 的账本
   只做形状校验；同形 `_state` 原地导入（市场列 `write_values` 只写变化 lane，非市场部分 `clear_except_market`
   后按账本重填）；去掉 `state.committed` 第 3 份拷贝（它只作导出时“块缺失”回退，而块的有无与 `_state` 自身一致）；
   发布账本与 host 常驻抓取缓冲 `_economy_mirror_capture_scratch` 交换复用。`&&` 入口保留完整摘要校验（自测依赖）。
3. **pod_hash**：随 2 自然变为增量——市场列对象跨天不变，`RuntimeChunkHash::update(EconomyTrackedColumn)`
   只处理变更登记的脏页。

正确性：`PK_ECONOMY_HASH_VERIFY=1`（增量 vs 全量重建）+ 新增 `PK_ECONOMY_MIRROR_VERIFY=1`
（原地导入后导出账本哈希必须等于发布账本）跑 650 天无失配；`runtime_economy_pod_test` 8/8、
`runtime_climate_save_roundtrip_test` 40/40、`runtime_climate_parity_test` 175/175 通过。
`production_climate_runtime_test` 6 项失败在 HEAD 基线 DLL 上同样失败，与本轮无关。

| 段（第 2000–2100 天） | 修复前 ms/天 | 修复后 ms/天 |
|---|---|---|
| `w.climate_writeback` | 7.43 | 0.39 |
| `econ.pod_hash` | 6.35 | 0.13 |
| `econ.mirror_publish` | 7.75 | 1.64 |
| `econ.mirror_capture` | 2.49 | 1.96 |
| EXECUTE 合计 | 38.1 | **21.3** |
| 吞吐 | 18.8 天/秒 | **27.0 天/秒** |

`econ.formulas` 同期 9.7 → 11.9、`climate_compute` 3.0 → 3.9，代码未动；第 4 项确认是锁步驱动下 worker 每天空睡所致（见下）。

## 已定位：`input_wait` 是无头驱动锁步的产物（第 4 项）

修复 1–3 后 worker 桶为 execute 21.2 + input_wait 12.7 ms/天。排查结论：

- **生产路径没有这一项。** 用户编辑器录制（50x）同一桶为 execute 56.8 + **input_wait 0.04** ms/天。
  玩家场景里 `WorldClock.day_changed` 的写回是“有就取”，随即采集下一日输入，主线程可领先 worker
  至多 4 天（`RuntimeEnvironmentInputRing::SLOT_COUNT`），满了才走 `climate_input_capacity_day_barrier`。
- **无头驱动是逐日锁步。** `headless_perf_record.gd` 每提交一日输入，就 `await process_frame` 轮询到
  worker 提交该输入日为止，再进入下一日。worker 每天算完即空等：驱动下一帧才看到提交（约 4.9 次轮询/天），
  再跑 `_consume_runtime_commit_if_ready`（约 3.4 ms/天）、`run_daily_tick`、`finish_daily_tick`。
  日瀑布稳态 0 次同日重试，`INPUT_WAIT` 全部来自“环境 ring 为空”那处等待。
- 领先不破坏数据契约：经济日输入挂在环境快照（`RuntimeEnvironmentSnapshot::economy_input`）里随 FIFO 逐日走；
  写回 ring 是最新值语义，跳过中间日的写回在生产里同样发生。

修复：驱动新增 `pipeline_depth`（默认 3，`0` = 旧锁步），轮询条件改为 worker 提交到
`输入日 - pipeline_depth` 即可；提交前先按 `wait_for_climate_consumed(0)` 等 ring 有空位（`capacity_waits` 计数），
与玩家场景容量背压同义。一次观察可能跨多个提交，吞吐改按提交日差（`committed_days`）除以 worker 提交时间戳差。

| 第 2000–2100 天 | 锁步（depth 0） | 流水（depth 3） |
|---|---|---|
| worker execute ms/天 | 21.2 | **18.3** |
| worker input_wait ms/天 | 12.7 | **0.06** |
| `econ.formulas` / `climate_compute` | 11.9 / 3.9 | 10.2 / 3.1 |
| 权威吞吐 | 27.1 天/秒 | **50.5 天/秒**（检查点通过） |

execute 一并下降：锁步下 worker 线程每天空睡约 13 ms，醒来后缓存/频率都是冷的；连续供给时保持热态。
所以锁步口径下的 formulas 抬升是测量伪影，不是代码回退。

剩余余量很薄：worker 18.3 ms/天，p90 20.1、最大 23.4 ms，离 20 ms 预算只有约 1.7 ms；
业务公式随建筑格子数线性增长，后期地图会重新越线。下一步优先“待处理三”（formulas 10.2 ms）。

注意：玩家场景每日主线程开销约 10 ms（日调度约 4 + 提交消费约 2.5 + 快照 ACK 约 3.5，录制均值），
50 天/秒时占主线程约一半；图形端到端仍需在编辑器里复测。

## 后期卡点（第 8000–8200 天）

编辑器 50x 录制（第 5601–10519 天，扣除两段暂停）：worker 等输入 0.05 ms/天，吞吐只由 worker 计算决定；
execute 从第 5000 天的 22.6 ms 涨到第 8000 天后的约 27 ms（36.7 天/秒），气候 plan 稳定在约 2.85 ms，增量全在经济。
无头复现（预热 8000 天，开探针）合计 25.4 ms/天：`econ.formulas` 14.7、`climate_compute` 4.2、镜像抓取 2.4 + 发布 1.9。

按成本性质分三类（探针嵌套，组内不重复计）：

1. **与经济活动无关的全表校验 ≈ 3.2 ms**：`opening_audit_full` 1.0（`economy_runtime_epoch.cpp:1096–1111`，
   未设 `PK_ECONOMY_AUDIT_SHADOW_REUSE=1` 时每次增量收盘都迫使次日期初全扫 321600 通道，约 96% 的天）、
   `audit_shadow_rebuild` 0.28、`ledger_hash` 1.1（20 余列全量 FNV，没有分页/脏页）、`native_hash` 0.44、
   `ledger_validate` 0.22、`pod_hash` 0.15。
2. **每日非绑定镜像的拷贝/导入 ≈ 3.1 ms**：`capture.market` 0.74、`capture.blocks` 0.47、
   `import.market_in_place` 1.27（逐通道比较写）、`import.blocks` 0.33、`import.validate` 0.30。
3. **业务公式里的重复试算**：
   - `owner_opportunity_quote` 2.68 ms，每天 81 次未缓存计算、每次约 33 µs：`optimal_at_scale`
     （`economy_runtime.cpp:10953`）在 0..16/16 共 17 档规模上各跑一次完整 `finalize_at_scale`，
     有软投入时再搜一轮，单次报价 18–36 次试算；每次试算又对每个产出重算 `output_retention_target`。
     memo 命中 26 / 未命中 48 次/天，另约 33 次（生产恢复、实物估值、人口流动）不经 memo；
     key 含雇佣过程中会变的 `filled`、owner 资金和同市全部商人状态。
   - 就业 1.76 ms（6 格，约 290 µs/格）：`LivingCostMemoScope` 开在每格内
     （`economy_runtime_building_employment.cpp:895`），报价/生活成本 memo 跨格清空；
     计划阶段则整段共用一个作用域（`economy_runtime.cpp:19491`）。
   - `cohort_demand_preview` 1.27 ms（24 次/天、命中率 75%）：单次 needs × variants × components 全目录扫描；
     `refresh_derived_business_demand` 每个活跃格新开作用域（`economy_runtime_building_investment.cpp:1129`）。
   - 生产 1.74 ms：worker 走 `run_building_production_drain`（`economy_runtime.cpp:20016`）逐格串行，
     并行版只在 slice 路径；6 格时并行收益有限。
   - 其余：`structural` 1.34（3 条命令后仍做商人区间重建 + 就业对账）、`commit` 1.26
     （`commit_food_flow_snapshot` 扫全部 2400 格）、`family.form` 扫全部格子。

## 后期修复 A/C/D 与结果

- **A 连续审计默认开启**（`NativeEconomyRuntime::audit_shadow_reuse_enabled`，`=0` 退回）：
  期初不再每日全扫 321600 通道，影子只刷新 touched 通道；`day % 25 == 0` 的全量期初复核与
  期末全量复核保留（10078 天中 404 次期初全量）。
- **C 账本哈希延迟**：每日非绑定镜像 `capture_committed_ledger_state(..., compute_ledger_hash=false)`
  发布 `ledger_hash == 0` 的账本；`import_and_publish_captured_ledger` 只在跳过摘要校验时接受 0，
  `&&` 导入与自测仍要求摘要。读者按需计算：`encode_ecp1` 写入现算哈希（已有非零哈希时仍校验一致），
  `PK_ECONOMY_MIRROR_VERIFY` 用 `computed_hash()` 对照。
- **D 删除 17 档规模搜索**：`optimal_at_scale` 的结果只写入 `OwnerOpportunityQuote::optimal_*`，
  没有任何读者；删除字段与网格后，单次报价只剩 1–2 次 `finalize_at_scale`，决策不变。
- **B 未落地**：报价内留存目标缓存在 D 之后无重复可省；就业 memo 作用域提到格外会让
  未入 key 的劳动信号产生过期命中，且格间无复用；布尔生存调用本已命中 memo。

验证：四个对拍开关（逐日审计、镜像、哈希、memo）同开跑第 1500–1800 天，无 fatal、三项误差为 0、
无对拍报错；pod 8/8、气候存档往返 40/40、经济对拍 26/26、权威 soak 12/12、气候对拍 175/175、
30 日 StageOps 对拍 190/190。单独 StageOps soak（第 3 天哈希不一致）与 `modern_economy_runtime_test`
（科技授予建造选项）在改动前 DLL 上同样失败，为既有问题。

后期第 8000–8199 天，`pipeline_depth=0`（无并发干扰）、不开成本探针：

| | worker execute | econ.formulas | mirror_capture | climate |
|---|---|---|---|---|
| 改动前 | 19.24 ms/天 | 10.85 | 1.78 | 3.35 |
| A+C+D | 16.87 ms/天 | 8.81 | 1.06 | 3.54 |

注意：新开局测试地图到第 8000 天人口仅 120、活跃经济格 6、无可比科技解锁，远轻于玩家后期世界，
上表不代表真实后期。

**玩家存档回放（`tools/runtime/Invoke-SaveReplay.ps1`，18:32 autosave，第 4431–4931 天）**：
该存档人口 1214、建筑组 46、可建建筑类型 57、家族 14。旧 DLL 下经济公式 16.06 ms/天，比测试地图同日段
（11.23）重约 43%。玩家路径走 `publish_owned_committed_mirror`（POD 自有镜像），每日 `export_committed_ledger`
仍做全量账本哈希约 1.1 ms，C 最初只覆盖了测试脚本走的非绑定镜像；现该路径也以 `compute_hash=false` 发布未摘要账本。

| | total | econ.formulas | mirror_publish | climate（参照） |
|---|---|---|---|---|
| 改动前 | 25.01 | 16.06 | 2.43 | 4.00 |
| A+C+D + 玩家路径哈希 | 19.55 | 11.93 | 1.26 | 3.90 |

worker 上限约 40 → 51 天/秒（该日段）。四个对拍开关同开回放 300 天通过；回放中自动存档成功。
第 8000 天后多城市局面尚无存档，未测。性能结论以存档回放为准，不以新开局测试地图为准。

测试地图上 worker 上限约 52 → 59 天/秒。测量注意：
- 成本探针本身每天约多 6 ms（同窗口开探针 25.4 → 21.7），只用于分项，不用于总量。
- 流水线 headless 后期由测量脚本主线程限速（worker 每天等输入 5–10 ms，execute 因并发升到约 21 ms），
  其“天/秒”不代表编辑器；比较 worker 成本用 lockstep 的 `worker_time_execute_us`。
- 流水线预热原按“观察次数”计数，一次观察可覆盖多天，测量窗口会漂到第 9880 天之后；
  已改为按提交天数计数。

## 后期存档 manual_1（第 13725 天）：建筑行引用与逐格热点

回放条件：`Invoke-SaveReplay.ps1 -Slot manual_1 -SavePath tmp\late_manual1_2044.pksv -Days 500 -Speed 50`，
`PK_SAVE_REPLAY_WARMUP_DAYS=50`，测量窗口第 13774–14274 天。确定性基准：第 14279 天
`state_hash = -5115214988943276475`（550 天 / 预热 10 时第 14289 天 `-6043686903789493819`）。
回放偶尔提前一天停在 14278/14277，此时哈希不同属正常，需按同一天比对。

| | worker execute | 天/秒（含存档暂停） |
|---|---|---|
| 本节改动前（owner 分桶后） | ≈ 24 ms/天 | 33–41 |
| 本节改动后 | 19.97–20.35 ms/天 | 48.0–48.1 |

改动（全部逐位等价，哈希不变）：

1. **`startup_producer_select` 作用域缓存**：`StartupProducerMemoScope` 以 `{cell, good, cover_depth}` 为 key，
   `PK_ECONOMY_MEMO_VERIFY=1` 时命中即重算比对。
2. **生产 owner→group CSR**：`run_building_production_cell` 原先对每个 payroll owner 全扫格内建筑组
   （owner × group），改为一次计数排序得到 `owner_group_offsets/owner_groups`，遍历顺序与原扫描一致。
   生产 5.0 → 3.0 ms/天。
3. **只读建筑行改用 `building_view()`**：可写 `building_at()` 每次都会为 60 列各登记一次租约条目，
   析构时逐列比较；就业的 `hire_order` 排序比较器、建筑提交、计划等纯读路径大量创建可写引用。
   新增 `building_view(row) const`，读路径一律用它；写路径由编译器把关（常量视图赋值不能通过编译）。
   building_commit 3.2 → 0.6 ms/天，就业 3.4 → 1.8–2.1 ms/天，building_plan 1.2 → 0.9。
   建筑列 `audit_role` 为 None，preimage 实测为 0，开销全在租约本身。
4. **生产 maint_tax**：维护/营业补贴循环先用视图过门槛再取可写引用；利润率与补贴改为
   `write_scalar` 单列写；利润率循环包 `LivingCostMemoScope`（该段之后的 signals 才写价格）。
5. **就业 owner 互换**：目标组在扫描来源候选时不变，`owner_opportunity_quote(target)` 每个目标只算一次，
   每次访问仍累加同样的饱和计数。

验证：550 天四开关（memo / 哈希 / 镜像 / 逐日审计）回放通过，`ok=true`、三项误差 0。
pod 8/8、经济对拍 26/26、StageOps 对拍 190/190 通过；`building_runtime_test`（53 项失败）、
`economy_rolling_runtime_test`（17 项失败）、`economy_goods_lifecycle_audit_test`（134 个 no_reachable_producer）
在 16:56 旧 DLL 上失败集合完全相同，为既有问题。回放中 `save_country_checkpoint_day_mismatch`
自动存档警告在所有历史回放日志中都存在，与本节无关。

剩余热点（带探针，ms/天，探针嵌套不可相加）：生产 ≈ 2.8、`epoch_vectors` ≈ 2.3（含 startup_producer_select ≈ 1–2）、
`aggregate` ≈ 2.2（其中 `ledger_export` ≈ 1.5，`.market` 每日整份复制 5 条 321600 通道向量 ≈ 0.9；`native_hash` ≈ 0.55）、
就业 ≈ 1.8–2.1（`owner_mobility_income`/`owner_opportunity_quote` 每次约 6 µs）、`cohort_demand_preview` ≈ 1.3、
household ≈ 1.2。生产中写循环仍每组取可写引用（working_capital、retention、process_main）。

## 未完成

- release 对 debug A/B：编辑器内 Godot 只加载 template_debug 映射，未测。
- 编辑器 50x 复录后期（第 8000 天后）确认 execute 降幅；编辑器内主线程空闲，应接近 worker 上限。
