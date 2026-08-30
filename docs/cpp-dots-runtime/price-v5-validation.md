# Price V5 实施与验证（2026-08-30）

> 本文保留 V5 阶段记录；当前上限已升级为 V6 / PKEC49，见 [V6 实施与验收](price-v6-validation.md)。
> 旧版性能日志使用了错误的日推进辅助函数，不能用于性能验收。V6 对照重新逐日运行。

## 改动范围

- 删除商品目录的经济最低价，保留 `1` 价格子单位（0.0001/完整物资单位）的数值下界。
- 保留现有最高价、上涨锚点平方衰减、上界空间衰减和冻结的 N 日周期。
- 积压只衰减正成本压力，复用现有库存信号，不增加跨期状态。
- 非零调价被整数取整吞掉时移动一价格子单位，最终仍不越界。
- 居民、企业投入、建造、维护、生产者收购及单笔贸易/科研采购采用整数分组账单。
  基础费用在组内合并后向上取整，预算检查和实际扣款不允许免费交付。
- 旧 `min_price` 资源及 `good_min_price` 原生目录显式拒绝；PKEC v48 不加载旧存档，需要新游戏。
- Inspector/GM 的非零小金额显示四位小数；新增数值下界、最小步长、积压成本衰减、小额收费诊断。

分组边界及低余额含税预算的保守预留见
[定点数和账本公式](economy-fixed-point-ledger-formulas.md)。金额子单位不可细分，
不能据此保证一两个资金子单位的含税钱包总能买到商品。

## 正确性

对照基线是本次开始时的工作区，而非 Git HEAD；保留了用户已有的最高价、上涨衰减、
建筑、贸易及其他未提交改动。源码快照在 `tmp/price_v5/before.zip`，没有重置、stash 或提交用户文件。

| 验证 | 结果 |
| --- | --- |
| Windows template_debug / template_release，MSVC，`dev_build=no` | 构建成功 |
| `price_v5_numeric_test` | 分组与分拆账单、零值、最低价、预算反算、极值饱和、积压成本衰减通过 |
| `price_v5_runtime_test.gd` | 143 检查、0 失败；含混合税率与 0/1/2/10/10000 资金子单位钱包 |
| `goods_storage_schema_test.gd` | 227 检查、0 失败 |
| `economy_trade_runtime_test.gd` | PASS |
| `family_buff_runtime_test.gd` | PASS |
| `economy_cadence_runtime_test.gd` | PASS |
| 建筑回归 | 修改前后均为相同 40 项失败，没有新增；不能报告整套通过 |

Godot headless 的退出阶段存在基线已有的 RID/资源清理警告；上述通过状态来自测试结果，
不表示这些历史警告已修复。全仓静态检查还受已有 `tmp/perf_csv_analysis/node_modules`
空白错误及失效 submodule 路径影响；本次源文件应单独执行 `git diff --check`。

## 性能方法

`price_v5_bench.gd` 使用正式目录和原生阶段，但它是**没有建筑的合成居民市场测试**，
不代替完整游戏启动、渲染或玩家 FPS 测量。

- 原始工作区源码单独构建 Release；修改后也用 Release，两者使用隔离的扩展映射。
- 固定种子 4801，N=1/3/5，180 个实际游戏日，丢弃前 20 日；每场景五次，交替运行顺序。
- 场景：8 格库存充足、64 格缺货、1120 格库存充足、64 格低价低余额。
- 记录日调用 wall avg/p95/max、市场 worker 时长、价格阶段采样、消费、满足度、状态 hash、
  原生报告内存与守恒。价格规则本身会改变订单数量，故同时记录处理组件数。
- 新版诊断有 `last_completed_price_ms`；跨版本对照采用两版都有的原始 `price_ms` 采样。
  N>1 时该采样不等于完整世界周期价格 CPU 总和。
- 首版小额账单造成结算开销，已将常见 32 位正数乘积及账单累加内联；极值继续走宽整数饱和路径。

性能目标为 avg/p95 回退不超过 5%、max 不超过 10%。重复数据存于
`tmp/price_v5/measurements.jsonl`，原始日志为 `tmp/price_v5/perf_*.log`；最终结果在下方补充。
报告内存不是进程峰值 RSS，也不完整计入线程局部临时容量。

## 复现

```powershell
scons -C gdext platform=windows target=template_debug dev_build=no -j8
scons -C gdext platform=windows target=template_release dev_build=no -j8
scons -C gdext/tests -f SConstruct.price_v5
./tmp/price_v5/price_v5_numeric_test.exe
```

使用 Godot console，以 `Project/project-keynes` 为 `--path`，通过 `--headless --script`
运行上述 GDScript。微基准额外参数示例：
`-- cells=1120 days=120 period=5 scenario=glut`。编辑器默认加载 Debug DLL；
只有显式选择 Release 映射的隔离项目才可标为 Release 测量。
