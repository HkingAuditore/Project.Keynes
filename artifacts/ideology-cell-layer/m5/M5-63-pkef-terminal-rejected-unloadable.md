# M5-63 真实缺陷（存档格式）：在「世代取代拒绝」之后、重试之前存档的档**无法读回**

| 项目 | 内容 |
|---|---|
| 发现者 | §11.7 时点 2 的夹具（子 Agent），我在本轮核实并修复 |
| 类型 | **存档格式缺陷**——写出来的档自己读不回来 |
| 严重性 | 高：不是「数值错」，是**存档不可用** |
| 位置 | `effect_runtime.cpp:7668-7672` 与 `:2548` |

## 1. 缺陷

`upsert_instance_pod` 在实例世代变化时重置计数器（`:2548`）：

```cpp
instance.fire_sequence = 0;
instance.input_revision = 0;
...
```

**同一段**里它把被取代世代的未决事务标为 REJECTED（`:2536-2547`）：

```cpp
transaction.status = REJECTED;
apply_rejected_instance_transition(transaction);
```

而 `apply_rejected_instance_transition`（`:4394-4413`）**完全不碰 `transaction.transition_*`**——
它只把实例重新调度，且 `instance_transition == TRANSITION_NONE` 时直接返回。
所以被拒事务的 `transition_fire_sequence` 是**创建事务时**写下的（例如 1）。

于是这一对数据是：

| 字段 | 值 |
|---|---|
| `transaction.transition_fire_sequence` | **1**（创建时，作为历史证据）|
| `instance.fire_sequence` | **0**（被世代重置）|

而恢复时（`:7670-7672`）：

```cpp
transaction.transition_fire_sequence > source_instance.fire_sequence
    -> return failure("pkef_transaction_transition_invalid");
```

**1 > 0 → 拒绝。所以在这个窗口存的档永远读不回来。**

夹具实测：

```
[sv2/FINDING] a PKEF captured between the supersession rejection and the retry fire
              restores=false reason=pkef_transaction_transition_invalid
```

## 2. 为什么这条不变量的本意不适用于终态行

那条检查问的是「实例还拥有这个转移引用的计数器吗」，目的是**阻止一个陈旧转移被应用**。

但 **REJECTED 是终态，永远不会被应用**：
`apply_rejected_instance_transition` 的注释明写「Domain rejection is not a lifecycle decision.
Preserve the last ACKed state and make the transition **retryable** with a new fire sequence」——
重试是一条**新事务**，不是这条。

所以「陈旧计数器」的两条检查对 REJECTED 行没有意义。

## 3. 修复（我做的）

只豁免**两条陈旧计数器检查**，结构检查全部保留：

```cpp
const bool terminal_rejected = transaction.status == REJECTED;
if ((instance_transition == TRANSITION_NONE) != (transition_fire_sequence == 0) ||
    ... stack-count 与 max_stacks 的结构检查 ...
    (!terminal_rejected &&
     (transition_input_revision > source_instance.input_revision ||
      transition_fire_sequence > source_instance.fire_sequence)))
    return failure("pkef_transaction_transition_invalid");
```

**为什么这样最小且充分**（我逐条核过）：

| 检查 | 对 REJECTED 行 |
|---|---|
| `(NONE) != (fire != 0)` | 被拒行 `instance_transition` **非 NONE**（APPLY/UPDATE 等），`fire == 1` → `false != false` → **通过**，不需要豁免 |
| APPLY/UPDATE 的 `stack_count ∈ (0, max_stacks]` | 创建时成立，世代重置**不碰** `transition_stack_count` → **通过** |
| DEACTIVATE/RETIRE 的 `stack_count == 0` | 同上 |
| **两条陈旧计数器** | **只有这两条会失败** ← 精确豁免 |

所以修复面是**两行布尔**。

**但我要修正自己一处过强的说法。** 我先写成「结构性的损坏检测一条没放松」——**这不准确**：
`transition_fire_sequence > source_instance.fire_sequence` **本身就是一条损坏检测**，
我对 REJECTED 行放开它，就意味着**一个被篡改成 999 的终态 REJECTED 行现在会被接受**。

准确的trade-off是：

| 保留 | 放开 |
|---|---|
| 转移种类与 stack_count 的一致性、`max_stacks` 上界、`NONE` ↔ `fire==0` 等价性、状态与 mask 的一致性 | 终态 REJECTED 行的 `transition_input_revision` / `transition_fire_sequence` 越界 |

**放开的那一类行的危险是「不被应用」而不是「被错误应用」**——所以风险是「历史证据被篡改不会被发现」，
不是「错误的转移被执行」。我认为这个trade-off值得，因为另一侧是**存档完全不可用**。

**更干净的替代做法（我没有采用）**：世代变化时**不把 `fire_sequence` 重置为 0**，让它继续单调递增。
那样终态行的 `1 <= fire_sequence` 永远成立，不变量可以完全保留。
我不用它的原因是 `fire_sequence` 参与幂等/去重，改它的清零行为影响面远超这次缺陷。**这一条留作可选的更优解。**

## 4. 与既有代码的一致性

- `:6294`、`:6464` 也调用 `apply_rejected_instance_transition`，说明「拒绝后保留转移证据」是有意的设计，不是这次引入的偶发行为。
- 我没有改 `capture`（`:7300-7348`）：它写的是**真实发生过**的 fire 序号，是对的。
- 我也没有改 `:2548` 的重置：世代取代后实例从 0 重新计数是对的。**错的是恢复时把「历史证据」当「活引用」校验。**

## 5. 我做了什么、没做什么

| 做 | 没做 |
|---|---|
| 核实了三处代码（`:2548`、`:4394-4413`、`:7668-7672`） | **没有构建验证**——当时还有子 Agent 在跑 Godot，构建会抢 DLL |
| 确认豁免面精确到两行 | 没有放宽任何结构检查 |
| 写清为什么终态行不需要这两条 | 没有改 capture 或世代重置 |

## 6. 待验证

**修复的验证需要一次构建**，届时要做三件事：

1. `ideology_save_transaction_states_test.gd` 的 `[sv2/FINDING]` 行应从 `restores=false` 变为 **`restores=true`**
2. 该夹具本身仍应 **314 / 0**（它断言「两种结果都接受」，所以修复不会让它变红——**这既是好事也是隐患：它不能证明修复生效**，必须看 FINDING 行）
3. 全域回归 + release 重建 + `verify_delivery.py --with-release`

**第 2 点值得注意**：夹具为了让「未来修复不能让夹具说谎」而接受两种结果，代价是**它自己无法证明修复已生效**。所以我必须直接读 FINDING 行，不能只看检查数。

## 7. 这条缺陷的意义

§11.7 的价值就在这里：**它不是「再测一遍数值」，而是去测那些「没人想到会坏」的时刻。**
时点 2 的第一批尝试就撞出一个「存档写得出、读不回」的缺陷——而这在任何只测 happy path 的夹具里都不会出现。
