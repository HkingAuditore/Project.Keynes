# 全国所得税停机修复验证（2026-09-20）

## 原因与改动

玩家日志曾在 committed day 11 报 `country_fiscal_peer_escrow_insufficient`。
修复前 `economy_rolling_runtime_test.gd` 在 day 0 可复现同一错误。
分格所得税扣款没有在财政提交时汇总到国家 escrow；Country 转账校验仍看到批初补贴
预留余额。`commit_fiscal()` 现在在转账前一次性写入未用补贴与实收税款之和。

真实玩家定额所得税补测进一步复现 `money_conservation_failed`，差额为已扣的 20。
Economy peer 终态完成后，Country 入库和只读国库快照尚未对本轮审计可见。
现在 worker 消费财政终态时复用 `finish_worker_country_asset()`（原 cohort-cash
终态函数）提交并发布 Country。转账路由与 `total_cash()` 都按实际 Country worker
grant 选路，避免兼容写禁令更新滞后时写入或读取旧同步国库。

税率/税基公式、存档 schema、经济 cadence 不变，Country/Economy 权威仍在 C++。
本次不绕过托管余额或守恒校验。

## 已通过

- Debug 与 Release GDExtension 构建。
- Godot headless editor parse；改动文件 `git diff --check`。
- `income_tax_settlement_regression_test.gd`：百分比和定额所得税分别连续 12 日；
  国库增加量精确等于所得税累计实收，其余四税种为零，逐日人口/货币/商品审计通过。
- `income_tax_player_regression.tscn`：正式玩家 ACTIVE/StageOps 启动，运行中通过
  `PlayerController` 提交全国所得税政策。10% 与定额 1 分别继续 50 个权威提交日；
  回执 Committed，政策快照正确，实收入库分别为 1,636,023 和 980（整数货币单位），
  三项守恒误差为零。日志：`tmp/tax_visibility_percent_console.log`、
  `tmp/tax_visibility_absolute_console.log`。
- 财政 reservation/continuation：57 checks，0 failures。
- Country/Economy transaction：43 checks，0 failures。
- Country peer bridge：106 checks，0 failures。
- Country runtime、Modifier runtime 专项通过。

## 未通过与限制

- 现有 rolling 综合测试越过原财政停机后，在旧 PKEC 存档检查失败，随后恢复测试崩溃。
- 现有 trade 综合测试有存档、路由、守恒等断言失败；UI smoke 的加速推进天数断言失败。
  本次没有修改这些测试或宣称全套回归通过。
- 标准 headless-perf 完成 50 个测量提交日，`ledger_failures=0`、`fatal=false`、
  三项守恒误差为零；但测得 16.911 日/秒，未通过 50 日/秒门槛，退出码 9。
  CSV 有 110 行，亦不满足 wrapper 的严格 50 行要求。该次与其他专项测试并行，使用
  Debug DLL，没有同机隔离基线，不能用来认定性能提升或退化。
  日志为 `tmp/headless_perf_20260920_223121_income_fiscal_fix.log`。
- 未进行 release 性能 A/B 或完整存档/标量与 worker hash 长程验收；不据此宣布整项迁移放行。
