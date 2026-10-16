# 开拓筹备回归调查（2026-10-16）

## 已证实的结论

- 截图中的 97% 是补给与建材的合计，所谓“口粮”包含食物、衣物及采集场工具。打制石器 0 是源地现货，不是缺口数量。
- 故障快照保留的 Country/Economy journal 中，玩家国家 `4294967296` 在第 7061 日的市场采购与第 7062 日的国库转出均为 COMPLETED。因此不能把截图中的旧“阶段 5”视为这笔交易永久不完成的证据。
- 开拓列表刷新 identity 原先只含句柄、状态和缺货标识；到期日改变但这些值不变时，tooltip 会继续展示旧采购阶段。测试已先失败、修复后通过。
- 本机 02:10:32 的图形游戏故障报告显示第 10315 日 `money_conservation_failed`，`money_error=-11166`，人口和货物误差为 0。Host 为 FAULTED，残留环境输入 4。
- 保存检查原先先等待残留输入，没有提前处理 FAULTED，因而把不能排空的故障误报为等待超时。测试已先失败、修复后通过；现在立即返回 `worker_faulted` 及原始 fault_code。

## 修改范围

只改只读 UI 刷新、存档失败诊断、测试及文档。没有修改原生采购、生产、物资需求、守恒条件、schema、调度或出发条件。工作区已有的 C++ 修改未被覆盖，也未被计为本次修复。

`colonization_probe.gd` 新增可选地图大小、目标搜索范围、阶段 5 保存测试、必须出发的断言与持久出发回执检查。回执避免后台写盘恢复模拟后，队伍在 await 期间已经抵达造成的漏报。探针的扶持选择也补上与 UI 一致的状态同步。

## 测试记录

| 测试 | 结果 | 日志 |
|---|---|---|
| Country/Economy ACTIVE 工作线程开拓采购 | 0 failures；采购入队并出发，人口/资金/货物检查通过 | `colonization_regression_before.log` |
| 默认正式开局，第 30 日后派遣 | 第 39 日出发 | `colonization_production_before.log` |
| 默认正式开局，第 1000 日后派遣 | 第 1015 日出发 | `colonization_late_before.log` |
| 默认正式开局，第 7000 日后派遣 25 人 | 第 7139 日接受，第 7155 日出发 | `colonization_day7000_before.log` |
| seed 172763467、100×64、5 外国，早期派遣 | 第 50 日 STARTED 回执，最终 code=0 | `colonization_player_map_early.log` |
| 阶段 5 保存，再观察是否出发 | 第 35 日保存成功，第 39 日 STARTED，最终 code=0 | `colonization_pending_save_verified.log` |
| UI 到期日变化、缺货标识不变 | 修复前失败；修复后通过，行节点保持复用 | `colonization_ui_before.log` / `colonization_ui_final.log` |
| FAULTED + 残留输入的保存边界 | 修复前错误返回 idle wait；修复后直接给出故障原因 | `save_fault_before.log` / `save_fault_after.log` |
| 完整旧 family_colonization_runtime_test | 13 failures；包含 legacy ingress 被禁和旧保存往返等问题，不能作为本次全通过证据 | `colonization_full_before.log` |
| seed 172763467、100×64，尝试推进到第 7000 日 | 在第 3778 日被家族扶持暂停阻断，未完成晚期验证 | `colonization_player_map.log` |

旧玩家自动存档的正式回放被 `modifier_restore_header_invalid` 拒绝；只在隔离目录测试，未覆盖玩家槽位。全部测试使用当前映射的 debug DLL，未报告为 release 性能测试。

## 仍未解决

没有复现同一支 26 人队伍永久停留在 97%，尚未证明最后一次优化导致打制石器断供。当前资金守恒故障也没有在本次修改中修复。不能将 UI 刷新和错误提示修复宣称为这两项原生问题的修复。

原始故障报告：`C:/Users/HkingAuditore/AppData/Roaming/Godot/app_userdata/ProjectKeynes/diagnostics/economy_fatal_20261016_021032_662246659.json`。

只读取证快照：`tmp/runtime_snapshots_economy_fatal_20261016_021032/`；它标记为 `forensics_only=true, restore_eligible=false`，不是健康存档，不能替代玩家存档恢复。

从快照读取的开拓队与相关交易记录另存于 `colonization_fatal_expeditions.json`、`colonization_fatal_peer_history.json`。
