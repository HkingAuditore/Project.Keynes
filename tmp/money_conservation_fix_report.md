# 第 10315 天货币守恒故障修复

## 取证与根因

原始证据：`tmp/runtime_forensics_economy_fatal.json` 和
`tmp/runtime_snapshots_economy_fatal_20261016_021032/`。原件未修改。
审计期是 10315，Host 最后提交日是 10314；人口及商品误差为零，货币误差为 -11166。

格子 4847 的七笔还贷为 4939、774、193、1、1439、325、3495，合计 11166。
这些组在现场仍保留债务并记录逾期；根据剩余期数递减后的字段可还原本期应还金额。
`repay_building_debt` 原先先扣业主现金，再向缓存商人槽位分账；没有活收款人时
分账返回零，但没有撤回扣款，也没有减少本金。这与现场差额完全吻合。
新建最小 native fixture 在原实现上稳定失败：
`merchant_debt_missing_receiver_burned_owner_cash`。

## 修复范围

- 商人迁移清空源槽位、新商人加入及 invariant repair 会标记派生 CSR 失效。
- compact 和 StageOps 生产入口在并行任务前按需刷新 CSR；非结构变化不重建。
- 还贷先验证活商人收款人；无收款人时现金和本金均保持原值。
- 商人分账忽略已失效、已转职的缓存槽位。
- C++ 继续独占账本权威；没有新增 GDScript 模拟，没有改变存档格式、货币发行、税率或 N/P/I。
- v39 同时保留工作区原有的 purchasing-power 修改。

## 验证

| 检查 | 结果 |
| --- | --- |
| 新还贷回归，修复前 | 失败，稳定复现现金被扣且债务未减 |
| 新还贷回归，修复后 | 通过，覆盖无收款人、商人替换、CSR 刷新及准确重试 |
| release DLL 还贷回归 | 通过 |
| template_debug / template_release | 编译成功 |
| income_tax_settlement_regression_test | 通过 |
| runtime_economy_pod_test | 通过 |
| runtime_authority_m5_m6_gate_test | 通过 |
| skill 静态检查 / git diff --check | 通过 |
| goods_storage_schema_test | 3 项失败，v38 对照完全相同 |
| economy_cadence_runtime_test | 2 项失败，v38 对照完全相同 |
| building_runtime_test --employment-only | 2 项失败，v38 对照完全相同 |

通用测试已有失败包括价格库存周期、worker hash、出生 cohort、节奏重现、ECP2 中途游标和就业报价。
未把这些已有失败改成通过，也未将其称为通过。

存读档另在 `tmp/money_save_roundtrip/` 隔离运行，正式 PKSV 写入、加载及经济/国家 hash
校验通过；两项时钟暂停状态断言失败。没有覆盖玩家存档。

额外实验用现场经济数据的**内存副本**裁剪两个超员角色并填充简化环境后续跑 301 天，
没有再次触发货币故障。这不是原会话重放，不能作为完整生产世界回归或恢复存档。
未进行 release 性能 avg/p95/max 基准；派生 dirty 标记不持久化，额外重建只发生在商人结构变化后。

## 当前故障会话

取证快照仅供诊断，不包含完整 PKSV 世界。它的原始恢复还会被两个建筑角色超员校验拒绝。
本次修复不会将已经 fatal 的半提交周期转成可正常保存的边界，也不伪造货币补偿。
新进程会加载 v39；已运行进程需要重新启动才能使用新 DLL。
