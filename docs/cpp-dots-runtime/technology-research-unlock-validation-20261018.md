# 最新存档科研停滞修复验收（2026-10-18）

## 现场与结论

只读检查最新 `autosave.pksv`，随后在 `tmp/technology_save_copy` 中复制存档，通过正式
`GameFlow.begin_load_game` 恢复路径续跑。原档与初始副本 SHA-256 均为
`D1E191A132ADDAEA51CB179F27576BE768DB0089ED203320D21918F10A3C7C79`，没有改写玩家存档。

第 18397 日，380 项科技中已掌握 90 项、已揭示未就绪 30 项、未发现 260 项，可研究为零。
国家研究证据只有 56 条，全部来自第 0 日；Trigger 已保存 5552 条未交付效果，最早科研突破
来自第 3 日。发展指标已有完成记录，却没有进入国家永久科研证据。

完整 ACTIVE 路径跳过原主线程 graph pulse，漏掉 Trigger → Effect → Country 的效果交付。
事件入队还可能挤满确认队列，高速 worker 连续获取整日边界又会使主线程非阻塞交付饥饿。
本次修复交付、确认背压及既有边界收件箱的公平服务；未修改科技目录、成本、门槛、ID 或
存档 schema。科技详情同时开放未知前沿的发现／研究条件解释，保留名称和效果遮罩。

## 正式存档路径结果

| 检查 | 结果 |
| --- | --- |
| 原档副本续跑 | 第 18397 → 18519 日（目标 120 日，等待在途交付收敛后结束） |
| 科技状态 | 未发现 165，已揭示未就绪 112，可研究 13，已掌握 90 |
| 永久研究证据 | 56 → 110 |
| 未交付 Trigger 效果 | 5552 → 1415，游标推进至 4224 |
| 人口／资金／物资守恒误差 | 0 / 0 / 0；fatal=false，worker_fault_count=0 |
| 保存到隔离目录 manual_1 | 成功 |
| 重载隔离 manual_1 并续跑 | 13 项可研究状态保留，积压继续降至 843 |
| 实际排入并研究一项恢复科技 | `tech.felt_making`（羊毛毡制）从状态 2 到 5，进度 3000000；已掌握 90 → 91 |
| 实际研究后的守恒 | 人口／资金／物资误差仍为 0，fatal=false |
| 最终 r4 构建保存并重载 | 已掌握 91 项保留，未交付效果降至 0；三项守恒仍为 0 |

续跑与实际研究的机器结果分别保存在 `tmp/technology_delivery_120d.json`、
`tmp/technology_delivery_reload.json`、`tmp/technology_delivery_enqueue.json`。
最终 r4 构建的实际研究／保存与重载记录为 `tmp/technology_delivery_final.json`、
`tmp/technology_delivery_final_reload.json`。最后一次重载恰逢另一个工作区编辑写入地图动效脚本，
日志包含 `map_activity_layer.gd:290` 的瞬时解析错误；该轮国家／经济恢复和科研状态如上，
不能将该轮日志描述成无脚本错误的全场景验收。该脚本随后单独 `--check-only` 验证退出码为 0，
未再出现解析错误。
UI 在 1280×720 实际渲染检查，截图为
`Project/project-keynes/tmp/technology_unknown_conditions.png`。条件列表可滚动，未知节点显示
证据、核心前置和匿名路线，不显示目标名称、成本或效果。

## 自动检查与限制

通过：科技目录编译、科研运行时、突破触发、科研采购、Modifier 激活、待生效调度、v2
研究资格、工作区烟测、刷新延迟、Effect/Trigger 交付，以及新增交付背压回归。
`runtime_trigger_pod_test.gd` 和 `runtime_trigger_save_roundtrip_test.gd` 同时覆盖满队列保留
ACK 位置、最大游标合并、待处理队列保存恢复后继续确认。
Debug 和 Release GDExtension 均构建，当前 Windows 库使用独立
`dots_ext_research_delivery_v56_r4` 名称，避免覆盖其他运行实例持有的旧库。`git diff --check` 通过。

已有两个目录检查仍失败，不能将完整 verifier 报为通过：

- `technology_network_design_test.gd:355` 预期狩猎营地产出生皮为 36，与当前内容不一致。
- `technology_content_binding_audit_test.gd` 报告既有建筑绑定／基础知识不一致，例如
  `early_iron_mine` 的 `tech.iron_smelting`，以及若干旧 `method_*` 建筑绑定。

这些断言读取的目录／建筑资源在本次没有改动；直接调整会改变目录身份并破坏现有存档兼容，
因此没有用删除断言或改科技门槛来掩盖它们。全目录语义审计没有发现无效、自引用或未来时代
路线引用，但仍列出 12 项冗余发现条件、2 项发现／路线重复信号和 30 项祖先信号复用，详见
`Project/project-keynes/tools/technology_tree/technology_gate_semantics_audit.md`。

50 日正式新局性能入口已尝试，但在世界生成阶段退出，未得到 CSV，不能据此宣称性能基准
通过或无回退。实际玩家存档续跑、守恒与保存恢复结果如上。部分无头／截图测试退出时仍有
Godot RID/resource 清理告警；未把这类退出告警计作断言失败。
