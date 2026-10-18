# 实际消费满意度验收（2026-10-18）

公式与适用性契约见[综合满意度运行时](./satisfaction-runtime.md)。本轮落实需求分档、稳定生活目标、
实际消费评分、类别预算、双重约束及 cohort 生活水平展示；收入实际购买力、稳定缺货估价、
经营资金扣除、商品品质分层与时代化社会发展评分仍为后续工作。

## 权威与边界

- C++ 保持唯一权威。GDScript 编译资源与展示派生查询，不写入模拟状态。
- basic / comfort / luxury 使用实际消费与生活目标；存款只直接评分储蓄。
- 生活目标按人口、计划基础量、市场实际 elapsed days、冻结环境和族群系数计算；不随财富、物价和预算缩量。
- 未形成消费需求的维度查询为 -1，内部存0；人口均值排除未适用者，职业聚合发布适用人口分母。
- 消费 / 财务 / 税负 / 发展预算70/20/5/5；职业权重在类别内归一。综合分受温饱10%与基本生活20%松弛约束。
- cohort 的七档生活水平按实际消费判定；格级建筑视觉分档保持既有规则。
- 购买顺序、交易、税款划转、商品消费、生存分母、N/P/I和调度不变。没有新状态列或存档布局；
  需求资源分档改变内容 catalog hash，因此不承诺旧内容存档继续兼容。

## 构建与专项测试

- Windows `template_debug` / `template_release`，`dev_build=no`，均编译成功。
- 两版 `tests/consumption_satisfaction_runtime_test.gd` 均49 checks / 0 failures。
- 覆盖有钱但舒适缺货、有钱但奢侈缺货、不适用的奢侈档、预算为零、基本生活约束、
  价格缩量后生活仍不足、类别预算、适用性及 explain 对齐。
- 专项结算 population / money / goods audit error 均为0。保存/恢复边界 hash 一致，
  满意度八维、综合分与短板列恢复及下一次结算重放一致。
- `tests/consumption_satisfaction_ui_test.gd`：headless 6 checks / 0 failures；带渲染截图7 checks / 0 failures。
  检查“不适用”文本、雷达留空、适用人口均值、消费说明与八行稳定展示。
- `economy_dossier_view_model_test.gd` Debug / Release 均通过；`inspector_responsive_layout_test.gd` 通过。
- `goods_storage_schema_test.gd` 的实际多 worker 派发（4 tasks）、worker/scalar state hash与event hash对等断言通过。
- economy skill 静态校验、六份同步 skill 的 quick_validate、`git diff --check` 通过。
- 未进行大型性能基准与正式开局人口长跑，没有 avg/p95/max 或人口长期平衡的实测结论。

可视检查使用正式 `player_session_theme`，示例为实际结算出的温饱100%、基本生活88.9%、
舒适0%、奢侈不适用、储蓄100%，生活档位为温饱。截图见
[卷宗示例](../../Project/project-keynes/tmp/consumption_satisfaction_ui.png)。

## 独立记录的既有回归失败

使用当前工作区原有 `dots_ext_family_choice_v56_r3` DLL，与新 DLL 对照相同脚本：

| 测试 | 新 DLL | 原 DLL |
| --- | --- | --- |
| `goods_storage_schema_test.gd` | 244 checks，2 failures | 相同2项：价格库存压力单周期口径、出生聚合至零资金失业 cohort |
| `economy_cadence_runtime_test.gd` | ECP2 mid-epoch resume cursor失败 | 相同失败 |
| 整世界保存恢复后下一期 hash | 综合满意度测试保留失败断言 | 单独运行保存重放子测试也复现 |

完整 `satisfaction_runtime_test.gd` 继续保留整世界 hash 断言，不把已知失败改成通过；
专项入口仅隔离这一项，仍完整验证边界 hash与满意度重放。历史证据见
[购买力版本验证记录](./satisfaction-purchasing-power-validation.md)。

`inspector_live_patch_test.gd` 另在未修改的 loading card 居中与进度回退用例失败；
本轮卷宗组件与响应式用例通过。本轮未修改 loading card。

原始输出位于仓库 `tmp/consumption_satisfaction_{debug,release}.json`、`tmp/satisfaction_*.json`，
构建输出位于 `tmp/satisfaction_build_{debug,release}.log`。

## 加载与存档

运行中的 Godot 未被终止。新 Windows 库为 `dots_ext_satisfaction_v56_r1`，
正式 `.gdextension` 与 SConstruct 默认输出名已同步。需重新启动 Godot/游戏后加载新版。
需求目录分档已经变化，建议新开一局验收；不修改旧档来绕过目录兼容校验。
