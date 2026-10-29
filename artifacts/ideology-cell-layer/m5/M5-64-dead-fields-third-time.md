# M5-64 三项死字段缺陷（第三个在这里第三次出现）

| 项目 | 内容 |
|---|---|
| 发现者 | §11.7 时点 5/6 的夹具（子 Agent），我在本轮逐条核实 |
| 类型 | **死字段**——存在、被导出、永远不会被写 |
| 共同点 | 与本会话此前的 `_cell_layer_rebuild_visits`、`cell_layer_contribs_passed`、`_cell_layer_rebuild_skips` 完全同类 |

## 1. 派生层的 basis 身份恒为 0（最严重）

`DerivedCellFront`（`derived_cell_layer.h:79-92`）有完整身份：

```cpp
uint64_t world_identity = 0;
uint64_t map_generation = 0;
uint64_t generation = 0;
int64_t  sample_day = -1;
uint64_t epoch_id = 0;
uint64_t execution_contract_hash = 0;
```

构建处在 `ideology_runtime.cpp:7051-7053` 从这些成员取值。**而它们在 `gdext/src` 里从未被赋值**：

| 成员 | 声明 | 引用总数 | **真实赋值** |
|---|---|---:|---:|
| `_derived_world_identity`（`:1149`）| `= 0` | 2 | **0** |
| `_derived_map_generation`（`:1150`）| `= 0` | 2 | **0** |
| `_derived_epoch_id`（`:1151`）| `= 0` | 2 | **0** |
| `_execution_contract_hash`（`:1058`）| `= 0` | 2 | **0** |

（2 = 1 处声明 + 1 处读取；**没有任何一处写入**）

### 后果

`get_derived_cell_layer_report()["epoch_id"]` **恒为 0**，所以：

> **一个读者无法问「这个 front 是不是我这个 epoch 的」。**

方案 §9.6 明确要求候选绑定包含 `(world, map, authority_epoch, … map generation …, sample_day, epoch_id, …)`。
这些字段**定义了但没接线**，所以「候选是否过期」这个问题在 front 自身层面**不可回答**。

**为什么现在还没炸**：`install` 的 no-op 判定用的是 `content_digest`（内容相同则跳过），
所以「同一内容跨 epoch」不会误装。但「不同内容」时，front 无法自证它属于哪个 epoch。

### 我为什么不修

**我不知道预期的数据源**：`epoch_id` 来自经济运行时的 epoch，`map_generation` 来自地图层，
`execution_contract_hash` 来自执行契约——把这三样接进 ideology runtime 是**接线工程**，
不是「补一个赋值」。

**编一个值比留 0 更糟**：留 0 是「明显的空缺」，编一个是「看起来有值的错」。

所以我把它记为**已知缺口**并写清要接什么线。

## 2. 两个导出但从未写入的计数器

| 计数器 | 引用 | 写入 |
|---|---:|---:|
| `_cell_layer_rebuild_skips`（导出为 `cell_layer_rebuild_skips`）| 2 | **0（只有声明）** |
| `cell_layer_collect_count` / `_rows` / `_ideas` | 报告字段 | **成员不存在**（0 引用）|

**这与我在 M5-7 修过的 `_cell_layer_rebuild_visits` 完全同类**：导出、永远是 0、谁都能拿它做断言然后得到「没发生」的假结论。

已用 `cell_layer_rebuild_visits`、`cell_layer_rebuild_steps`、`derived_rebuild_pending` 作替代（这三个是真的）。

## 2.1 第四条：`ExternalEffectCommandPod::source_id` 也是死字段

| 事实 | 证据 |
|---|---|
| ideology 写它两处 | `ideology_runtime.cpp:1463`（协同，**稳定 id**）、`:1717`（卡片层级 `tier_source_id`）|
| `effect_runtime.cpp` **从不读它** | 唯一的写是 `:2139`；`:5663` 用的是 `source_instance->id` |

**后果不只是浪费一个字段**：如果它被读，协同的 APPLY 与 REMOVE 会共享同一个 `source_id`，
撤销就能匹配成功。正因为它是死的，协同效果才**永久泄漏**（详见 M5-68 §6.1）。

**所以这是本会话第一个「死字段导致了真实功能缺陷」的例子**——前三次只是让断言不可靠。

## 3. 第三条：`begin_or_reuse_economy_input_epoch` 返回**别名**字典

`world_ext_economy.cpp:680` 把 `_economy_capture_cached_report` **按引用**交回给 GDScript。
下一次 `run_economy_slice` 会**原地重写**它，所以夹具里保留的返回值**过一天就丢掉 `ok`**。

**修法（夹具侧）**：调用处 `.duplicate(true)`。这条已被时点 5/6 的夹具踩到并写进报告。

## 4. 这已经是本会话第 3 次「死字段」

| 次 | 字段 | 症状 |
|---|---|---|
| 1 | `_cell_layer_rebuild_visits` | 导出但从不递增 → 夹具报**假失败** |
| 2 | `_cell_layer_contribs_passed` | 一次性重建被删后从不写 → 谁断言谁得「0」 |
| 3 | **本次四项** | basis 身份恒 0；`rebuild_skips` 恒 0 |

**共同点：报告里有一个字段，代码里没有一次写入。**

## 5. 一条可复用的检查

**任何「报告里读到的字段」，都要能指出它在哪里被写。**

我可以用一条命令做这件事：

```
对每个导出字段名，grep 对应成员，统计「真实赋值」数；为 0 的就是死字段。
```

本次就是这样发现的（`assignments=0`）。**建议把它做成 CI 检查**：报告字段必须至少有一处写入，
否则报错。这比事后逐个踩要省得多。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| 本报告 | 四项死字段 + 一条别名返回 + 可复用检查 |

**本轮没有修改产品代码来"修"这些字段**——接线工程需要知道数据源，不是补一行赋值能解决的。
