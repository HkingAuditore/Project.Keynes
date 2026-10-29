# M5-72 §10.1 的修复：我实现了、验证了、然后**回滚了**

| 项目 | 内容 |
|---|---|
| 目标 | 让「转移在飞的卡片不服务 NEW 等级」（方案 §10.1）|
| 结果 | **修复有效，但打破 14/28 个夹具 → 回滚** |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 当前状态 | 缺陷仍在（已记录），修法已验证可用 |

## 1. 我实现的修复

`collect_effect_activations` 原本只判 `state.location == INACTIVE || state.level < 0`，
然后直接用 `state.level` 查等级行。而 `start_transition` 在**请求时**就写 `state.level = target`。

改为：

```cpp
int32_t contribution_level = state.level;
if (state.transition.active != 0) {
    if (state.transition.previous_location == INACTIVE) return true;  // pending 装备：还没生效
    if (state.transition.previous_level < 0) return true;
    contribution_level = state.transition.previous_level;             // pending 升级：用旧等级
}
if (contribution_level < 0 || contribution_level >= definition.level_count) return true;
// ...用 contribution_level 查 _levels[level_begin + contribution_level]
```

**依据不是猜的**：同一个函数族里 `:5006-5007`（日常理解度累积）**已经**这么做：

```cpp
const int32_t growth_level = state->transition.active != 0
    ? state->transition.previous_level : state->level;
```

**同一张卡的两半，一半是对的。我把另一半改成与它一致。**

## 2. 修复确实有效（我实测了）

`ideology_pending_keeps_old_contribution_test` 的输出：

| | 修前 | 修后 |
|---|---|---|
| OUTCOME | **`NEW`** | **`OLD`** |
| pending 时的逐格 add | `0.08000183`（L2）| **`0.05000305`（L1）** |
| pending 装备时的 front | **84 行** | **0 行** |
| 检查 | 140 / 0 | **137 / 0** |

夹具里那条 `A1 [measured, OUTCOME A]: while PENDING the covered cell still carries the L1 add`
**首次变绿**。

## 3. 但它打破了 14 个夹具

全量校验：

```
VERIFY FAILED (15)
  b5_idle            6 failures
  b7_wide_territory 14
  b8_source_overlap  2
  b10_multi_country  4
  oracle            11
  b3_country         3
  save_before_layer 21
  save_transaction  25
  save_eligibility   6
  save_basis        20
  mechanism_equip    7
  mechanism_copier  18
  b12                2
  pending            (0 failures -- 它自己是对的)
```

### 为什么

**`start_transition` 在请求时就写 `location`**，而那 14 个夹具都是「装备 → 立刻读派生层」。
我的门让它们读到**空 front**。

**它们依赖的正是这个行为**——我在派单时就把它当作「已知事实」写给子 Agent（「`equip()` 立刻写 `location`」）。

## 4. 为什么回滚而不是修那 14 个夹具

| 选项 | 代价 |
|---|---|
| **修 14 个夹具** | 它们要为每次装备加 ack 握手再读；而且**已交付的证据要重新推导**——§14.3 的性能数字、B7 的 1600 格结果、B8/B10 的数值对照全部会变 |
| **回滚** | 缺陷仍在，但**已交付的证据不受影响**，且修法已验证可用、随时可上 |

**在剩 52 轮的情况下，重推全部证据的代价远超收益，而且会让「已验证」这个结论本身失效。**

**所以我选择回滚，并把测量与修法完整留档。**

## 5. 回滚后我做了什么

| 动作 | 说明 |
|---|---|
| 代码回滚 | 恢复原判据，但在注释里**写明这次测量**（OUTCOME 从 NEW 翻到 OLD、14 个夹具被打破）|
| 夹具恢复 | `C1` 恢复为「pending 装备时 front 仍有 84 行」，并注明「§10.1 的修复被测量过、然后回滚了；方案承诺记为 FINDING，**不记为正确**」|
| 复跑 | pending 夹具回到 **140 / 0**、`OUTCOME MEASURED: NEW` |

## 6. 这是一个**决策**，不是遗漏

| 谁需要定 | 定什么 |
|---|---|
| 方案负责人 | §10.1「尚未确认的装卡不产生贡献」**要不要生效** |
| 如果要 | 那 14 个夹具要加 ack，且**已交付的性能与数值证据要重新推导**——工作量是「重跑整个 M1–M5 的证据链」 |
| 如果不要 | 那就修改方案 §10.1，承认「装备请求时即生效」是设计 |

**我没有替用户做这个决定。**

## 7. 顺带确认的一条：`x9b` 有既有抖动

`ideology_x9b_family_target_worker_test` 在全量校验里偶发 1 个失败
（`country_worker_peer_results_pending`），单独跑是 22/0。**是既有的 worker 竞态抖动**，不是我改动引入的。
重跑全量即 `VERIFY OK`。

## 8. 本轮仍然净增的东西

| 项 | 状态 |
|---|---|
| `explain` 分解缺陷修复 | ✅ **保留**（失败会翻回原断言）|
| PKEF 越界读修复 | ✅ **保留**（含墓碑豁免）|
| 两个新夹具 | ✅ **81/0**、**356/0** |
| §10.1 的修法 | ⚠️ **已验证、已回滚、留档待决策** |
