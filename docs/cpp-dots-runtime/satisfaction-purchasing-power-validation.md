# 舒适/奢侈购买力验证（2026-10-16）

实现和边界见 [综合满意度运行时](./satisfaction-runtime.md)。C++ 仍是唯一评分权威；
GDScript 只传递配置及展示已有八维列。基础消费、温饱、市场需求、资金与商品划转、
结算节奏和 PKEC v55 字节布局不变。沿用本地基础篮子成本指数；它并非一次性购买
整个月实物库存的成交承诺。部分缺货的成本处理也沿用现有规则。

## 本次验证

- Windows `template_debug` / `template_release` 均编译成功，`dev_build=no`。
- 两版均运行 `res://tests/purchasing_power_runtime_test.gd`：71 checks / 0 failures。
- 覆盖 0/1/2/3/6/10/20 个月初始资金，消费后存款口径，30 天分母，单调性、区间中值、
  饱和、物价翻倍、空市场、配置覆盖、职业零权重、综合维度、温饱闸门及 explain。
- 每个购买力结算用例的 population/money/goods audit error 都为 0。
- PKEC 保存/恢复边界 state hash 完全相同，八维和综合列完全相同；下一次结算的满意度
  列也相同，双方账本审计为 0。整世界下一期 hash 的旧问题见下文。
- `goods_storage_schema_test.gd` 中 worker/scalar market state hash 与 event hash
  对等断言通过，并实际派发了多个 worker tasks。
- economy skill 静态验证脚本与本次修改的 `git diff --check` 通过。
- 无新增状态列/矩阵；评分只增加 O(1) 标量运算。未运行大型性能基准，没有 avg/p95/max
  或新增内存占用的实测结论。功能测试使用现有 locked-cycle 路径，不使用历史 N=50/334。

## 旧 DLL 上同样复现的广泛回归失败

新旧 DLL 在相同测试脚本与配置下进行比较：

- `satisfaction_runtime_test.gd`：整个世界保存/恢复后的下一期 hash 不一致；边界 hash
  及满意度列恢复与重放通过。旧 `dots_ext_hotloop_v37` 上仅运行存档子测试也复现全世界
  下一期 hash 失败。未在本次修改中修复其他系统的重放差异。
- `economy_cadence_runtime_test.gd`：两版都失败于注入 timing 后 N/P/I 可重复性，以及
  ECP2 mid-epoch resume cursor 两项。
- `goods_storage_schema_test.gd`：两版都是 244 checks / 3 failures，具体为价格库存压力
  单周期口径、注入 cadence 后 worker hash、出生聚合到零资金失业 cohort。

原有综合测试保留整世界 hash 断言；专项测试明确只检查此次购买力相关的存档与重放，
没有把上述失败改成通过。输出位于仓库 `tmp/purchasing_power_*.json` 和两份构建日志。

## 加载

运行中的 Godot 仍持有旧 DLL，未中断进程。本次新 DLL 使用
`dots_ext_purchasing_power_v38`，SConstruct 默认输出名及正式 `.gdextension` 引用已同步。
重新启动 Godot/游戏后加载新版；已有存档在下一次市场结算刷新两项分数。
