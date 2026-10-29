# M5-71 修掉两个真实缺陷（含一处内存安全），并记录我引入又被抓到的一次回归

| 项目 | 内容 |
|---|---|
| 修复 | ① `explain` 的分解项漏掉派生项 ② PKEF 恢复路径的**越界读** |
| 新夹具 | `ideology_reader_consistency_test` **81/0**、`ideology_save_payload_robustness_test` **356/0** |
| 我的回归 | 越界读的第一版修复**打破了 4 个存档夹具**，被全量校验当场抓到 |
| 最终 | **VERIFY OK**（含 release）、28 夹具全绿、内核 103/0、门禁 7/7 |
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 修掉：`explain_modifier_stat` 报告了一个它无法解释的总数

### 缺陷

`ModifierRuntime::explain` 的分解项只遍历 `store.active`（`:2097-2121`），
而同一个 dict 里的 `effective_value`（`:2129`）**调用了合并派生层的函数**（`:1462-1479`）。

所以对一个被派生卡覆盖的格，它输出：

```
effective_value  = 1.050003051758
sum_add          = 0.0
product_factor   = 1.0
unclamped_value  = 1.0
```

**「值是 1.05，原因是：什么都没有。」** 任何基于它的 explain 提示框都会对整块派生贡献给出零个理由。

### 修复

派生项以**同一套算术**和**同一个 §5.5 零因子规则**并入分解，**并且单独暴露**：

| 新字段 | 含义 |
|---|---|
| `derived_add` | 派生层对这一格加了多少 |
| `derived_factor` | 派生层的因子 |
| `derived_present` | **区分「层里没有这一格」与「层贡献了 0」** —— 一个裸 0.0 做不到 |

### 验证方式：把夹具的断言**反过来**

夹具原本有两条断言**钉住这个缺陷**（「sum_add 不含派生项」「缺口恰等于派生 add」）。
修复后它们**自动变红**（`81 checks, 2 failures`），这正是修复生效的证据。我把它们改成原断言的**精确反面**：

```
[fixed] N1 explain decomposition: sum_add=0.050003051758 product_factor=1.000000000000
        unclamped=1.050003051758  vs effective_value=1.050003051758
=== 18.1 reader consistency: 81 checks, 0 failures ===
```

**三项全部一致了。**

## 2. 修掉：PKEF 恢复路径的越界读（内存安全）

### 缺陷

`effect_runtime.cpp:7452-7457` 在一条 `||` 链里**没有校验就索引** `_definitions[]`：

```cpp
!magnitude_scale_allowed_for_selector(
    _definitions[static_cast<size_t>(instance.program_id)].target_selector_kind, ...)
```

而 `instance.program_id` 是**从载荷读出来的**（`:7447`），范围检查却在 `:7519-7520`**之后**。
**若它是负数，`static_cast<size_t>` 变成巨大值 → 必然越界读。**

### 修复

把边界检查**提到索引之前**。`||` 短路保证不索引。

## 3. ⚠️ 我的第一版修复打破了 4 个夹具

第一版我直接在链首加了：

```cpp
instance.program_id < 0 ||
instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
```

全量校验立刻报 **`VERIFY FAILED (4)`**，而且**检查数还下降了**（359→340、205→203），
说明夹具**中途被跳过**——那是拒绝发生在不该发生的地方。

**根因：`program_id == -1` 是墓碑（已删除实例）的合法标记。**
`:7515` 自己就是这么读的：

```cpp
if (instance.generation != 0 || instance.program_id != -1 || ...)
    return failure("pkef_instance_tombstone_invalid");
```

**我的 `program_id < 0` 拒绝了所有墓碑。**

### 正确形式

```cpp
(instance.program_id != -1 &&          // -1 是墓碑标记，不是索引
 (instance.program_id < 0 ||
  instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
  !magnitude_scale_allowed_for_selector(...)))
```

`-1` 时整组为假（**跳过**，不索引）；真正越界时整组为真（拒绝）。修后 5 个夹具全部回到绿。

### 这条值得记

**加边界检查时，必须先确认那个「非法值」域里有没有合法的哨兵值。**
我按「负数一律非法」的直觉改，而 `-1` 在这个字段上是**有语义的**。
**4 个夹具与检查数下降一起把我拦住了——如果我只跑了单个夹具，可能就漏过去了。**

## 4. 顺带：健壮性夹具挖出 5 条存档完整性缺口

`ideology_save_payload_robustness_test`（356/0）枚举了 **27 层 PKID + 19 层 PKEF 校验**，
51 个拒绝案例全部精确匹配原因码。但它也**测出 5 条缺口**：

| 编号 | 缺口 | 后果 |
|---|---|---|
| **F1** | PKID 的 `last_day`（偏移 16）**不在 state hash 里** | 把 0 改成 1007 后 **`ok=true` 且运行时采纳 1007** |
| **F2** | PKID 的 `submit_order`（偏移 24）同样不在哈希里 | 被接受 |
| **F3** | **PKEF 完全没有载荷哈希** | `current_day` 改成 1006 被接受并成为运行时的一天 |
| **F4** | 采样 69 次单字节篡改，**14 次被接受** | `last_day`／`submit_order`／`_points_revision_seen`／`trade_paid_day`／六个 split ledger 字段／`offer.*`／`banned_bits` 都不在哈希里 |
| **F5** | 采样 38 次 PKEF 篡改，**16 次被接受** | 完整性是**逐行**的（事务有 FNV 计划哈希），其余没有 |

**F1 最严重**：一个被篡改的日期会被**采纳**。

**这不是本次改动引入的**——是既有状态。已记录，未修（修法是扩大哈希覆盖面或加整载荷哈希，属存档格式变更）。

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/modifier_runtime.cpp` | explain 并入并暴露派生项 |
| `gdext/src/effect_runtime.cpp` | 索引前边界检查（含墓碑豁免）|
| `tests/ideology/ideology_reader_consistency_test.gd` | **81/0**，N1 断言改为「一致」 |
| `tests/ideology/ideology_save_payload_robustness_test.gd` | **356/0**，5 条 `[FINDING]` |

## 6. 局限

- 生产消费者 `refresh_city_modifier_factors` 的**输出不可观测**（冻结进 `_epoch_cell_birth_factor_q16`，没有任何绑定暴露它）。代码上它必然经过 front（键是 `stat_bucket_version`、工作集来自 `collect_scope_ids`，正是 R4/R6 证明 front 感知的两条路径），**但夹具无法观测**。
- `get_modifier_report()` **没有** `layer_generation`／`layer_stat_version` 字段——**报告无法见证 front**（未修）。
- `list_modifiers` 在 front 覆盖 42 格时返回 **0 个 handle**（按设计，派生 (stat,cell) 没有 handle）。
