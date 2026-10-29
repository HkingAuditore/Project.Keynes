# M5-48 kind 14 诊断收敛：两个未完成项共用同一个前置条件

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-47](M5-47-kind14-diagnosis-still-open.md) 的收尾 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **根因链条走通到最后一步**；并发现它与「>32 真实世界样例」是**同一个阻塞** |

## 1. 诊断链条现在完整了

| # | 层 | 证据 | 结论 |
|---|---|---|---|
| 1 | **POD** | `pod_ok_keys=["ideology.effect.autonomous_logistics_l1"]` | ✅ 卡的效果程序解析成功 |
| 2 | **tag** | 移动 override 之后 `ring_empty` 由 4 → **0** | ✅ **卡片的 tag 真的匹配到了格** |
| 3 | **源集收集** | `ring_empty=0`、`no_tag=0` | ✅ 取到了源格 |
| 4 | **环形遍历** | `empty=4` | ❌ **最终 cells 为空** |

所以从「program 找不到」到「目标为空」，**只有最后一步没走通**。

## 2. 第 2 步是我自己的时序错误

第一次 `ring_empty=4` 时我以为是产品缺陷。**其实是夹具的 override 应用太晚**：

`TagSnapshot` 是**不可变快照**，惰性构建于首次使用。我把
`set_effect_metric_override_for_test(cell.trade_events)` 放在「装备前」，而那时快照已经被建好了。

把它移到 **epoch 打开之前**，tag 立刻匹配：

```
before:  no_tag=0  ring_empty=4  empty=0
after :  no_tag=0  ring_empty=0  empty=4
```

**这也是我第五次「第一遍读不完整」**——这一次是没确认「快照什么时候建」。

## 3. 第 4 步的根因：没有邻接表

`empty=4` 意味着 `dilate_cell_set` 返回了空。它需要
`_building_neighbors.size() == cells * 6`，而夹具没 `bind_map_data`。

## 4. 而 `bind_map_data` 用手写 stub 会**崩溃**

加上 stub 之后：

```
exit=-1073741819          ← 0xC0000005
```

这正是本仓库早已记录过的问题（`ideology_cell_layer_e2e_realworld_test.gd` 的注释：
「a hand-written stub crashes (`world_ext_economy.cpp:929-930`, `0xC0000005`)」）。

**所以第 4 步不能靠手写 stub 解决。**

## 5. 关键结论：两个未完成项是**同一个阻塞**

| 未完成项 | 需要什么 |
|---|---|
| **kind 14/15 端到端夹具** | 真实的 `MapData`（邻接表来自真实地图）|
| **>32 真实世界生产样例** | 真实生成世界 + **连片多格国家** |

两者都指向 **D4**：让生成/夹具产出**连片多格国家**。

**一旦有了真实世界 + 多格国家，这两项可以一起完成。**

## 6. 本轮交付

| 文件 | 说明 |
|---|---|
| `ideology_runtime.h/.cpp` | 三个新计数器：`targets_fanout_no_source`（kind 16）、`targets_fanout_ring_empty`（kind 14/15）、`targets_fanout_no_tag` |
| `ideology_kind14_diagnosis_test.gd` | 打印 8 个目标层计数器；**3 checks / 0**；明确注释为何不 `bind_map_data` |

## 7. 一个值得记下的操作教训

我第一次把计数器加到 `sources.empty()` 时，**打在了 kind 16 的那一行**——
两行文本与缩进完全相同（`if (sources.empty()) return false;`），正则无法区分。

`no_source=0` 一度让我以为「分支没进」。**改法是按行号定位，并给每个计数起一个属于它分支的名字**
（`_targets_fanout_no_source` vs `_targets_fanout_ring_empty`）。

**同名同形的两行代码，是本仓库里比变量名更容易骗人的东西。**

## 8. 下一步

D4 的具体做法（按用户 2026-10-28 的指示「生成连片的国家」）：
在生成/夹具里把某个国家的领土从单格扩到连片多格，然后用它同时验证
① kind 14/15 端到端 ② >32 真实世界样例。
