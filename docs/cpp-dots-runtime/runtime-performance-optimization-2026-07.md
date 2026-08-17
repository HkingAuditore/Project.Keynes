# 运行时性能优化契约（2026-07）

本轮优化不改变经济、国家或气候的权威边界：经济状态仍只由
`NativeEconomyRuntime` 提交，气候/海洋模拟仍由 native daily graph
推进，Godot 仅保留对象 facade、MapData 可见镜像和视觉上传边界。
PKEC 继续使用 v19；以下缓存、generation stamp、探针和性能计数均为
transient，不进入存档、state hash 或 event hash。

## 经济热路径

- `speed_scale >= 20` 且
  `economy_high_speed_batching_enabled=true` 时，household 和 production
  相邻 range 使用确定性的 2 倍 batch；worker fan-out 仍不超过 6，
  merge 顺序仍为升序 cell/range。native `Dictionary` 数值读取显式支持
  浮点 `speed_scale` 与 `slice_budget_ms`，避免二者静默退回默认值。
- `executed_stage` 只描述本 slice 实际执行的主阶段。片内发生少量
  trade planning 不得覆盖 building、household 或 publish 的归因。
- BALANCED 认证近似的初始 Top-K 为 2。生存食品与御寒衣物永久精确；
  variant 数不超过 Top-K 时不构造 frontier。最多八个 variant 使用
  固定数组稳定插入选择，不在热路径分配或调用通用排序。
- 精确探针比较冻结价格下的预计支出和预计需求。任一误差超过 regret
  门槛时，本 market 当期精确回退；探针越界、certificate failure
  超过 25%，或连续两个 epoch 裁剪率低于 2% 时，进入配置的精确冷却。
- 生产默认现为 `BALANCED+ACTIVE`。`OFF/PROBE` 永久保留为精确基线和
  回滚路径；ACTIVE 的证书失败、探针越界与 cooldown 均继续自动走精确路径。
- 6400-cell ACTIVE household 的旧 heap corruption 已通过 thread-local
  market/staging-touch sink 和逐 task landing buffer 隔离修复；大世界 scalar
  containment 已退出，兼容字段 `approximation_large_world_scalar_guard` 恒为
  `false`。6400-cell worker/scalar A/B 使用相同 seed 得到相同 authority hash，
  人口/货币/货物误差均为 0；连续 6 次 worker soak 也保持相同结果。新增
  `market_worker_parallel_dispatches` 和 `last_completed_*` 快照，区分“允许 worker”
  与“实际发生并行 dispatch”。
- `household_market_breakdown_ms/work` 将每片细分为 prepare、worker、
  aggregate merge、trade merge、trace、other，以及四个有界收尾子阶段。该诊断
  让五个 rolling market dispatch 的真实热点可直接聚合，不改变 market range
  顺序、五日 cadence、账本提交或存档格式。
- 投资 sparse 候选覆盖率超过 95% 时直接遍历完整 country/type CSR，
  并通过 `investment_sparse_dense_fallbacks` 报告。

## Transient 缓存

- 资源 remaining/harvest/delta 使用 generation-stamped lane。本轮只初始化
  rolling settlement/building 可达 cell，并按 touched lane 构造发布结果。
  production worker 在各自 `ProductionResult` 收集 touched lane 与
  bio occupancy introductions，主线程按升序 cell 结果合并，禁止多个 worker
  并发扩容共享 touched vector 或 `_bio_introduce_keys`。
- CellSummary staging 使用 touched overlay；提交前保持 committed/staging
  隔离，失败时丢弃 overlay，成功 swap 后只同步上轮 touched cell。
- country epoch 烘焙 country-major 的 good、profession、variant 和
  building availability。家庭热循环使用 catalog 期 survival mask。
- 资本复核的 resource commitment、merchant cash 和 outstanding credit
  使用 review-generation stamp。只初始化当日 review cell 及其资源 lane，
  不再按 `resource_count * cell_count` 和 `cell_count` 全量清零。
- `building_commit.review_prepare` 预先生成升序
  `_investment_review_cell_indices`。后续 merchant finance 初始化、pending/existing
  聚合、候选评估和 continuation cursor 只访问同时满足 rolling phase、review
  phase 和正人口条件的 cell；非 review cell 不再扫描建筑组以刷新瞬态拒绝码。
  `investment_scheduled_review_cells` 与 `investment_review_cells` 分别报告计划量和
  实际执行量，两者在完整提交后必须相等。
- `building_commit.investment_prepare` 在 ready construction commit 之后单独完成
  finance、pending/existing/resource 聚合，再由后续 `investment` range 做候选
  评估与稳定提交。两者分别进入 `building_commit_breakdown_ms/work`，prepare
  可以在进入不可抢占的候选循环前按 cooperative budget 让出。

## Closing audit

`economy_closing_audit_mode` 支持 `FULL / PROBE / INCREMENTAL`：

- `FULL` 保留人口与 market-good 全扫描。
- `PROBE` 同时计算首触 shadow-delta ledger 与全量结果，全量结果权威。
- `INCREMENTAL` 使用首触 shadow-delta ledger；首日、restore 后和每 25 日执行
  完整复核。周期复核 mismatch 会在 committed swap 前失败并永久关闭
  本 session 的 incremental 路径。

每个 epoch 开始时使用 generation stamp 记录第一次被修改的 population/funds
slot 和 market-good lane；closing totals 从 opening totals 加这些 lane 相对 shadow
的真实差量得到。household/production worker 的 due-cell workset 在 dispatch 前由
主线程预登记，worker 不写共享 stamp/vector。非 worker 的贸易、命令和结构变化仍在
唯一 mutation site 登记。commit 后只更新 touched shadow；restore/bootstrap 重建
完整 shadow。`closing_audit_mismatch_ledger/lane` 报告第一个差异，
`*_touched_lanes` 与 `*_full_scan_entries` 用于判断 fast path 是否真实避免全扫描。

固定种子 200 日每日双审计与显式 INCREMENTAL 复测均为零 mismatch，
生产默认现已切到 `INCREMENTAL`。首日、restore/异常边界及每 25 日仍完整复核；
mismatch 在 committed swap 前失败并关闭本 session fast path。`PROBE/FULL`
永久保留为验证和回滚路径。

## Native daily / Godot 边界

- ACTIVE climate/ocean bundle 优先通过
  `get_native_climate_round_hot_state()` 和
  `get_native_ocean_physical_hot_state()` 读取紧凑 capsule。旧 DLL 或
  SHADOW/debug 路径继续使用完整 report。
- capsule 只携带 owner、round/generation、cursor/stage、ready/dirty 和
  boundary intent mask；不会复制 pass diag 或大字典。
- 植被 succession 的 native slot 仍是模拟权威。Godot 在同一升序循环
  同步 HexCell/MapData，随后一次 indexed dirty、一次 DCWorld 镜像、
  一次 detail scatter；不重复写回 DCWorldExt。

## 报告和门禁

性能报告导出实际 batch multiplier、节省的 dispatch、approximation
probe/cooldown、closing audit mode/fast/full/mismatch/full-scan entries
以及 audit touched/mismatch lane、scheduled review cells、sparse investment
dense fallback。读取已完成 epoch 的性能时应使用
`last_completed_*`。

当前按生产决策先启用 `BALANCED+ACTIVE`，但这不等于完整精度认证已经完成。
短 headless smoke 只证明生产路径可运行、守恒为零和 CSV 契约有效，不能替代
template_release、N=5、三种子、200 日 OFF/ACTIVE 对照；门禁失败时应显式回滚
到 `PROBE` 或 `OFF`。

2026-07-27 的 60×40、speed 50、seed 20260718、35 日 debug 对照中，丢弃前
20 日后 investment 平均由 5.760ms 降至 5.092ms，`t_sus_ms` 平均由
9.329ms 降至 8.111ms；continuation 平均仍为 30.929ms、investment P95
仍为 7.529ms，尚未通过生产性能门禁。该记录只证明 review-cell 稀疏调度有效，
不能替代 template_release 三种子 200 日验收。

同配置显式 INCREMENTAL 的 200 日单种子 A/B 中，拆出
`investment_prepare` 后，丢弃前 20 日的 continuation avg/P95/max 从
`25.249/31.858/45.447ms` 变为 `25.089/31.786/40.937ms`，investment 从
`4.427/7.426/8.390ms` 变为 `4.452/7.081/8.118ms`，`t_sus_ms` P95 从
`11.526ms` 降至 `10.960ms`；closing audit mismatch 与 fatal 均为零。
该结果支持保留 phase 拆分，但仍未通过 investment P95 `<=6ms` 和
`t_sus_ms` P95 `<=8ms` 门禁。一次 cell/signature living-cost cache 实验只有
约 20% 命中且 200 日 continuation/investment 均回退，已撤销，不属于当前路径。
