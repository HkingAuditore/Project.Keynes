# 开拓采购缺口传导验证（2026-10-17）

## 变更

- 原生 Economy 在周期边界从 PREPARING 队伍重建稀疏待购余额，扣除托管和采购中的货物，按稳定队伍顺序共享国家可用现金上限；财政与研究预算优先。
- 只读完整开工包预估允许记录无现货的可达候选；同组替代品只承担一份剩余需求。假设性 cargo 不进入实际货物账本。
- 一次性备货余额按库存天数/周期天数折成日需求，接入价格、库存与进口、采购配额、生产计划、就业和投资/上游需求传播。不会虚构提货、销售或重复累积 EMA。
- 采购完成、出发、取消和失效后，在下一次冻结边界重建并清除相应待购余额。
- 市场快照新增 `colonization_pending_demand` 与 `colonization_demand_daily`；复用既有 worker committed-read 发布路径。
- 修复需求传播 thread-local 种子去重 stamp 与 runtime-local generation 跨世界碰撞，避免新世界跳过真实需求。
- 权威仍归 C++ Economy；Country 仍拥有国库。无新钱包、存档字段、schema/catalog 版本或调度阶段。

## 结果

- Debug 与 Release 构建：成功。
- `colonization_demand_runtime_test.gd`：0 failures，覆盖零库存价格压力、商人库存/进口目标、零预算、多队共享预算、替代品、已购托管扣减、无虚构提货、取消清除，以及实际产出→采购→出发→待购量清零。
- worker_tasks_hint=1 / 4 的小型 fixture 状态哈希均为 `3016776242679234959`，待购量和全部市场快照字段一致。该小型 fixture 不强制多格并行；实际 Country worker 采购另由下项验证。
- `family_colonization_runtime_test.gd --worker-procurement-only`：0 failures，worker 采购、出发和守恒通过。
- 完整开拓测试集：13 failures，与上一次修复后的 13 个失败逐项相同，未增加失败。既有旧命令入口禁用、存档往返等问题未在本次范围内修复，完整测试集不能报告为通过。
- Economy / Country 静态检查与修改文件 `git diff --check`：通过。
- 最新存档副本经正式 `headless_save_replay.gd`：`ok=true`，权威提交日 `5302 → 5382`，共 80 日，`failures=[]`；已提交审计人口/资金/货物误差均为 0。恢复后的国家、经济均 bootstrapped，经济状态水位推进。
- 独立开拓落地探针确认目标地块出现同一家族分支、在途列表清空、worker faults=0。
- 原自动存档未改写，SHA256 仍为 `887F47A3EFC036E9D23BD76FAD08C498D1F48E4DC17BC8DD100C1BCC0E879924`。
- 正式回放使用 locked cadence，结束时 N/P/I 为 5/5/10；测量段吞吐约 36.99 权威日/秒。这是本机单次 debug 验证，无独立 release avg/p95/max 或多队压力性能基准，不作为性能改善声明。
- 既有无头测试退出仍有 Godot RID / ObjectDB 资源泄漏提示。

日志与构建输出保存在本目录。当前游戏进程需要重新启动后加载原存档，以使用新的原生库。
