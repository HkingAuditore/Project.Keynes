# 手动存档2：发展成就科研证据漏记修复验收

## 原因与修复

Trigger 在接收事件时分配递增 effect ID，但按 `(effective_day, source_priority,
trigger_id, target_handle, fire_sequence)` 的业务顺序交付。因此待交付列表可以是 `[2, 1]`。
旧交付仅处理 ID 2 后，以 2 为数字高水位确认，主线程和 worker 都可能删除尚未交付的 ID 1。
对应成就已经是 ONE_SHOT completed，后续样本不会再次触发，最终表现为“条件早已达到，
国家却一直缺少永久研究证据”。真实农业/制造业触发器已在旧构建复现该错误。

修复保持业务排序，改用 `ACK_EFFECT_IDS` 确认实际交付集合。worker 同日确认合并为有界
ID 并集；只有没有待交付缺口时才能推进旧数字游标。主线程交付在背压时重试同一集合，
Country receipt 未完成前继续保护 Effect 事务。PKTR/TPD1 对账、待处理确认及补发命令均
覆盖保存恢复回归，没有改变科技目录、研究门槛或存档字段布局。

历史漏记由会话首次解除暂停后的 `reconcile_completed_research_signals()` 自动对账：
读取 Trigger 的已完成一次性发展成就和 Country 的当前查询副本，只重放永久证据缺失、
没有在途效果、且国家代次有效的条目。重放经过原有 Trigger → Effect → Country 命令
边界，不重置成就，不直接授予科技。恢复日期使用当前边界，代表来源采用当前所属地块；
不声称它是原始观测地点。已入账后再次对账不增添观测或效果。

## 手动存档2副本结果

原存档 SHA-256 在验收前后保持
`9B992B7451EDE7C5EDEDDDE7D49A3013C0545D034225B4D0E7F8FBC427D2B673`。
测试使用 `tmp/manual2_research_20261019/manual_2.pksv` 副本，关闭自动存档，未保存回玩家栏位。

| 项目 | 结果 |
| --- | --- |
| 玩家已完成但漏记的永久证据 | 8 → 0 |
| 玩家永久研究信号数 | 78 → 86 |
| 可研究科技 | 1 → 5 |
| 未发现科技 | 205 → 190 |
| 已揭示但未就绪科技 | 107 → 118 |
| 已掌握科技 | 保持 67，没有直接授予科技 |
| 自动对账范围 | 5 个国家共补发 28 条；其中玩家 8 条 |
| 再次对账 | 提交 0 条，玩家观测计数无增长 |

正式 GameFlow 恢复副本后无需测试脚本指定补发条目；首次运行交付泵自动报告提交 28 条。
最终 worker 的实际模拟提交日由 19729 推进到 19749，Country 研究状态同步推进；时钟由
19730 到 19750。以 worker 提交水位为验收依据，没有把时钟前进当作模拟完成。

最终权威经济审计：`available=true`、`day=19749`、`audit_incomplete=false`，人口、资金、
物资误差均为 0；`fatal=false`，`worker_fault_count=0`。这是已提交边界的增量审计
（`full_verification=false`），不宣称执行了额外的全量经济核算或性能基准。

机器结果与日志：

- `Project/project-keynes/tmp/manual2_research_replay.json`
- `tmp/research_ack_manual2_live_final.log`
- `tmp/research_ack_manual2_audit.log`
- `tmp/trigger_replay_manual2_1792367020.json`

## 构建与回归

Debug、Release GDExtension 构建均成功。项目当前使用独立库名
`dots_ext_research_ack_v56_r6`，SConstruct 默认输出名与 `.gdextension` 引用一致。
需要重启原有游戏进程才能使用新库；重新加载存档并解除暂停即会自动恢复漏记证据。

以下专项检查通过：

- `technology_development_delivery_test.gd`：真实成就逆序 ID、分批交付、Country receipt、
  历史状态分裂自动恢复、在途与已入账去重。
- `trigger_effect_id_ack_test.gd`：乱序部分确认与 PKTR 往返。
- `trigger_research_replay_test.gd`：仅允许已完成的发展成就补发，拒绝不合规输入。
- `runtime_trigger_pod_test.gd`、`runtime_trigger_save_roundtrip_test.gd`：POD 确认、
  合并背压和命令保存恢复。
- `technology_signal_delivery_test.gd`、`effect_trigger_handoff_test.gd`、
  `technology_breakthrough_trigger_test.gd`。
- `technology_catalog_test.gd`、技能 quick_validate、`git diff --check`。

科技完整 verifier 已执行，但停在既有 `technology_network_design_test.gd:355`：狩猎营地
产出生皮的目录断言失败。该用例断言后未自行退出，已终止本次测试进程；因此不把完整
verifier 描述为通过。未修改该目录或为此调整科技门槛。

无头正式场景日志另有既有 `resource_visual_context_missing` 渲染告警，以及退出时
RID/resource 清理告警；科研与模拟断言结果如上，不将其描述为全场景无告警验收。
