# 上游需求冷启动修复与验证

## 问题与实现

零石器工坊、零燧石采掘场时，下游工具短缺曾有两个传导断点：

1. `refresh_derived_business_demand` 只写出当前产品的一层投入，未将投入继续入队。
   采集品缺口能变成石器需求，但石器需求不能继续变成燧石需求。
2. 生产阶段的替代品需求保存在 `_epoch_substitute_business_demand`，下一轮取样前清空。
   检视器仍可显示石器的替代机会，而冻结的上游计算只看到另一 SKU 的企业需求 EMA。

修复位于 `gdext/src/economy_runtime_derived_demand.cpp`，仍由
`NativeEconomyRuntime` 唯一拥有并在原取样点执行：

- 派生投入继续入队；已展开商品不接受回边，阻止石器/燧石循环自我放大。
- 按现有建筑的投入槽，从真实企业需求 EMA 重建替代品种子。同槽候选先换算到
  有效投入量并取最大观测，再由建筑数量和已提交购买意愿限制日量；最后按候选效率
  换回实物量，扣除已有库存/供给。不同 owner-lot 的合法槽需求可以相加。
- 结果继续使用既有的价格压力、shadow anchor 和首座生产者启动报价。
  预测不是销量、提款、现金转移或物资生产；真实交易仍经过原建筑账本。
- 保留资金、利润、业主生计、建材、生产投入、科技与资源门槛。

没有迁移数据所有者：GDScript 仍负责编译目录、命令与界面；C++ 仍是经济状态权威。
没有增加持久列、公开 API、绑定、保存布局或调度阶段。Price V6、ECP2/schema60、
正式内容价格/配方/产量参数、N/P/I 默认策略不变。现有存档不需要本次修复专用迁移。

派生成员从原投资实现文件原样移到独立实现文件，使投资文件从本次直接修改后的
5804 行降到 5056 行，新文件 786 行；未提高行数基线。
移动前后成员函数正文 SHA-256 一致：
`92693b1f4775daddeafd82f6a77a8eba12fe7b807d126c00e8812a2ad8a33e98`。

## 回归夹具

入口：

```text
godot --headless --path Project/project-keynes --script res://tests/building/building_runtime_test.gd -- --supply-chain-only
godot --headless --path Project/project-keynes --script res://tests/building/building_runtime_test.gd -- --supply-chain-only --supply-chain-sparse
```

第一例没有任何初始建筑，石器和燧石库存均为零。家庭食物缺口必须在首轮穿过
未建造的采集品/石器生产链到达燧石，并形成价格响应，仍保持零实际燧石采购和零产出。
随后验证已提交 ECP2 往返及十二日完整经济哈希续跑。

第二例每个活跃格有 239 名采集者、1 名商人和 220 座采集营地；工具替代品与燧石
库存为零，其他生存/建材库存充足。资金为每人 60 货币，配方和价格使用正式目录。
只允许采集营地、石器工坊、燧石采掘场落地，保留全部工具替代候选。
夹具授予完整科技以隔离科技锁；不能据此声称验证了正式石器时代科技解锁流程。
初始失业率低于 25%，避免初始就业追赶替代需求证据。

两格版本和 1024 格但仅两格活跃的稀疏版本各运行 121 日；scalar/worker 逐日
完整经济哈希相同，逐日人口、货币、物资审计误差均为零。两版都在第 11 日看到真实
燧石产出、第 25 日看到真实石器产出，库存恢复后燧石价格可回落。
旧 DLL 在这个规模也可能经结构探索先验建厂，因此产出日期只证明闭环成立；
直接反例是旧 DLL 的四个多层/替代需求与价格断言失败，新 DLL 全部通过。

## 验证状态

日志位于 `.codex-temp/supply-chain-20261110/`。Debug/Release 均成功构建。
最终加载路径也单独运行定向回归，不能仅以构建文件存在作为加载成功证据。
最终 Windows 映射为 `dots_ext_supply_chain_v4` 的 Debug/Release；正在运行的 Godot
进程仍需重启才能加载新库。构建没有结束用户的编辑器进程。

| 检查 | 结果 |
|---|---|
| 定向链路 Debug / Release | 各 30 项，0 失败 |
| Release 稀疏 1024 格 | 30 项，0 失败；经济 live workset 恒为两格 |
| 三账守恒、scalar/worker | 各场景 121 日，每日全哈希一致 |
| ECP2 | 已提交完整状态往返，随后十二日全哈希一致 |
| economy_cadence_runtime_test | 131 项通过 |
| runtime_economy_stage_ops_soak_parity_test | 40 项通过 |
| colonization_demand_runtime_test | 83 项通过 |
| module API / C++ dependencies / module contracts | 均 0 违规；Country 直接写入为 0 |
| git diff --check | 通过 |

完整套件没有宣称全绿：

- `building_runtime_test` 有两个既有 owner-livelihood/solvent-workshop 断言失败，
  使用旧 `army_explore_v14` DLL 复跑同样失败；没有删除或放宽断言。
- `goods_storage_schema_test` 的一项旧断言期待 2x 产量，正式 profile 已为 1.5x；
  新旧 DLL 都失败。其余 245 项通过。
- `building_resource_chain_test` 的九项旧内容/资源夹具断言，新旧 DLL 同样失败。
- worker restart 的一次 Debug 运行有三项继承的 Ideology derived-front 断言失败；
  经济执行器本身继续提交且没有 fatal。初次 Debug、旧 Release 和最终加载的
  新 Release 运行均为 29 项、0 失败。保留该 Debug 失败记录，不将其算为全通过。
- skill 自带静态脚本仍引用已移动的 `tests/goods_storage_schema_test.gd`，因此在文件
  存在性检查处退出；上述测试按当前 `tests/economy/` 等实际路径直接运行。
- 全仓行数检查仍有其他工作的既有超限；本次涉及的两个经济实现文件均通过行数限制。

## 性能范围

使用 Windows template_release DLL，固定 N=1、P=5、I=10，记录第 4–120 日的
117 次整日经济调用 wall time，包含原循环其余工作；不是单个派生 pass 的 CPU 时间。
未使用历史 N=50/334 自动快进路径。内存为运行时 `memory_bytes`，不含进程总内存。

| Release 场景 | avg ms | p95 ms | max ms | runtime MiB |
|---|---:|---:|---:|---:|
| 旧 DLL，两格，scalar | 4.450 | 5.409 | 5.682 | 0.468 |
| 最终 v4，两格，scalar | 4.755 | 6.314 | 7.966 | 0.469 |
| 旧 DLL，两格，worker | 4.558 | 5.140 | 5.876 | 0.468 |
| 最终 v4，两格，worker | 4.554 | 5.202 | 5.580 | 0.469 |
| 最终 v4，1024 格/两格活跃，scalar | 6.198 | 10.212 | 13.440 | 30.795 |
| 最终 v4，1024 格/两格活跃，worker | 6.177 | 8.186 | 12.237 | 30.795 |

日志为 `final-baseline-release.log`、`v4-focused-release.log`、`v4-sparse-release.log`；
最终 Release worker restart 的 `v4-worker-restart-release.log` 为 29 项、0 失败。
Debug 定向回归在 Release 链接期间执行，其 wall time 受构建争用影响，不用于性能比较。
上述单次测量不证明完整地图的性能不变，尤其 scalar 的尾延迟有所增加。

两格、480 人的夹具不能代表完整地图、
正式科技进展或年十一存档的性能；稀疏版本只验证空地不进入业务活跃集合。
