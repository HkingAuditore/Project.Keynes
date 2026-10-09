# 50× 性能优化实施状态（2026-10-09）

目标仍是 100×64 后期世界每秒提交至少 50 个权威日。本文件记录已实现机制及
验证边界，不代表整套优化计划完成，也不代表达成性能验收。

## 已实现

| 部分 | 实现 | 验证 |
|---|---|---|
| 录制 | warmup 后按权威提交日去重，要求记录数严格相等，CORE 默认，补齐存档/暂停时间分类 | recorder 78 项通过；100×64 检查 50 条记录对应 50 个提交日 |
| 回放 | 使用 worker 提交水位推进和判断停滞，每帧读取紧凑报告 | 后期恢复、100/300/500/1000 日回放通过 |
| 财政存档 | 正确验证 TREASURY_SPEND 的 quantity 金额编码，不放宽其他操作契约 | 原始 day 26280 存档合法恢复，源文件保留 |
| 格式 | ECP2 ABI 3 / schema 54，显式 hash_version，运行 DLL 格式探测 | ABI 自检 8 项通过；旧档迁移后正常恢复通过 |
| 哈希 | 四个市场列 4 KiB 规范编码树，Native/POD 共享页；财政记录稳定摘要 | 单元测试及 300 日全量重建/原始记录摘要对照通过 |
| 校验 | shape/value 与 digest 分离，导出避免验证旧摘要；外部摘要验证拒绝缺失摘要 | 事务测试及恢复/对拍覆盖 |
| 聚合 | 冻结作用域内 living cost、owner quote、需求基础数据复用，命中需求基础数据直接引用 | 完整数值、饱和事件复算；100×64 新开局检查通过 |
| 探针 | CORE/DETAIL 统一累计比较字节、拷贝字节、重建页、复用页；报价/需求命中计数；审计影子工作量 | 计数语义见 performance-diagnostics-playbook |

默认开启 v2 哈希；市场页更新仍使用全字节比较作为漏标保护，**尚未完成完整 dirty
写入登记，因此不是只随变化量增长的最终路径**。原来其余状态字段遍历仍保留。
完整线性 ledger 仍每日导出；哈希页不可变并不等于全经济不可变提交视图。

## 正在验证的连续审计

`PK_ECONOMY_AUDIT_SHADOW_REUSE=1` 显式开启实验路径。它保留 worker 合并所需的
写前影子，登记跨 epoch 的 idle 写入，期初使用上次期末加边界差量，下一 epoch
只刷新 touched 影子。模式、恢复和结构尺寸变化继续重建。每 25 日完整复核保留。

`PK_ECONOMY_AUDIT_VERIFY_EVERY_DAY=1` 强制每日完整期初和期末对照。影子复用
500 日与连续审计 1000 日回放通过，审计未禁用，人口/货币/物资误差均为零。
国家—经济事务测试 43 项通过。30 日固定 cadence 的 compact/StageOps 对拍
190 项检查通过。本机制尚未转为默认路径；删除、复用、命令、跨域交易等边界覆盖完成前
不能将单个后期回放当成所有写入路径的覆盖证明。

增量审计不一致时记录差异、禁用快路并在发布前失败，不再静默发布校正后结果。
缓存/哈希复算及逐日全量审计均属于正确性诊断，吞吐不作为性能验收数据。

200 日 warmup + 3000 日测量的首轮在权威日 28778 后遇到
`country_economy_asset_peer_journal_identity_mismatch`，不能视为通过。
Host 恢复编号分配器原先只考虑 Host 待执行命令和 Country 回执，遗漏 Economy
持久化终态日志。已增加启动时日志最大请求编号水位，保留全部身份校验；长回放
重跑已越过原冲突日并提交到 29480 日。最终读取 live report 时观测到非零守恒
值，紧接着的下一阶段取证又为零；此轮仍保留为失败，不能据此宣告正确性通过。
已增加不可变期末审计视图，绑定审计日、generation 与 Effect 命令前 revision，
避免最终检查拼接不同阶段；正在复测。这不是完整的命令后 EconomyCommitView。
Country Host protocol 的 terminal-receipt 自检仍失败，修改前后均为
同一失败（42 项、1 失败）；新增编号水位/不回退和经济 transport 自检通过。

不可变审计摘要的 30 日复测通过。随后同一初始存档 warmup 200 日，测量
3000 日（26480→29480）完整通过，没有 fatal，三项期末审计差为零，增量审计
未禁用。端到端耗时 120.358 秒，**24.93 权威日/秒**；worker execute 为
119.880 秒，即平均 **39.96 ms/日**。此轮只有一次，地图为 60×40，开启连续
审计实验路径，保留正常周期复核与存档；不是 100×64 或 5 次重复验收。
性能目标仍未达到，不能把正确性通过解释为整套优化完成。

最后的审计摘要明确绑定 `before_effect_command_drain` revision。它不能证明
同一日随后执行的所有命令后的余额都已进入统一提交结果；该统一边界仍待实现。
结果与耗时证据：`tmp/perf_commit_audit_30.log`、
`tmp/perf_commit_audit_3000_measure.log`。原始存档 SHA256 复核未变化。

Debug 与 release 另名 DLL 均构建成功；release POD 自检 8 项通过，release
5 日 warmup + 30 日逐日完整审计回放通过。证据为
`tmp/perf_implementation_release_build.log`、`tmp/perf_release_pod_test.log`、
`tmp/perf_release_audit_30.log`。本次修改文件的 `git diff --check` 通过；Country
bundled 静态 verifier 的仓库级 diff 检查被原有 tmp/node_modules 的格式问题阻断，
未改动这些无关文件。完整图形验收及 release 长期吞吐验收仍未运行。

## 尚未实现和验收

- 完整共享变更登记、所有领域稳定列覆盖清单、仅重算 dirty 块。
- 审计连续基线默认启用及完整命令/财政/远征边界覆盖。
- EconomyCommitView、分页业务快照、只读消费者统一复用和每日深拷贝退出。
- 输入静态页/上下文 revision/动态日包细分及锁内构建退出。
- 临时数组 touched 清理，结构差量索引和稳定身份/generation 缓存契约。
- 剩余热点的确定性准备并行、统一线程池工作粒度。
- UI 刷新/视觉预算、事务可靠送达与原生异步存档 I/O。
- 200 日 warmup + 3000 日 × 5 的新开局/后期测量、10 分钟图形自动存档验收、
  200×128 与扩大实体压力测试。

当前已提供的后期存档实际是 **60×40、day 26280**，不是 100×64 后期世界。
所有迁移和回放使用副本。测试使用 `Project/perf-validation` 和另名构建 DLL，
原正在运行的游戏/编辑器没有被终止；其已经加载的 DLL 不会自动替换。
shutdown 仍出现 Godot resource/RID leak 提示，未将其当作已解决的问题。

迁移入口：`tools/runtime/Invoke-SaveMigration.ps1`。主要证据在
`tmp/perf_v2_normal_restore.log`、`tmp/perf_v2_verified_300.log`、
`tmp/perf_audit_shadow_500.log`、`tmp/perf_audit_continuous_1000.log`、
`tmp/perf_audit_transactions_test.log`、`tmp/perf_verified_newgame_50.log`。
