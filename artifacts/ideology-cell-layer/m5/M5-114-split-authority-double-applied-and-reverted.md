# M5-114 分裂权威修好了，但它在普通配置里**把 Modifier 行应用了两次** —— 已回滚

| 项目 | 内容 |
|---|---|
| 修好的 | `0xFEF`（意识形态主线程 + Effect/Modifier worker）**能完成装备了** |
| 但它破坏了 | 三个**与 worker 无关**的夹具：Modifier 行被应用两次 |
| 处置 | **回滚该改动的 3 个 C++ 文件**，三个夹具立即恢复绿色 |
| 日期 | 2026-10-29，Asia/Hong_Kong |

## 1. 它修好了什么（这部分是真的）

**机制不是「没人结算」，而是「被抹掉」** —— 这个区分是本次最有价值的产出：

| 天 | 观测 |
|---|---|
| D | `EQUIP` 被接受 |
| D+1 | `transition_pending=1`、`statuses=[1]`（PLANNED）、`locations=[1]` |
| D+2 | `host.run_daily_tick` 之后 `statuses=[0]` —— **MISSING** |
| D+3… | `poll_pending_transition` 把 0 当失败 → `ideology_effect_transition_rejected` → 回滚 |
| D+25 | `locations=[0]`、front `installed=false`、`add=0.0` |

**`apply_runtime_effect_snapshot` 用 worker 的事务表替换 `_transactions`**，而那张表**按构造永远不携带本线程创建的事务** —— 所以那行在计划出来一天后就被抹掉。

**修好之后**：`statuses=[4]`（ACKED）、收据 **0**（原 13）、逐格对照 192 格 `max|Δadd| = 0.0`、`0xFFF` 参考腿 `split_settle.calls == 0`（**在它不该起作用的地方是惰性的** —— 它自己的夹具是这么说的）。

## 2. 但它破坏了三个无关夹具

```
ideology_mechanism_synergy_spirit_test      147 checks, 2 failures
  [FAIL] count rule: the tier's agriculture factor equals the catalog-derived value
         (got 1.060900 expected 1.030000)
  [FAIL] synergy release: that tier's factor is still applied

ideology_pending_keeps_old_contribution_test  159 checks, 1 failure
  [FAIL] A4 one-shot: the Modifier store holds EXACTLY ONE applied row for
         ideology.standardization after the settle and after two more days

ideology_card_content_test                  1625 checks, 5 failures
```

**`1.060900 = 1.03²` —— 加成被叠了两次。** 第二条说「恰好一行」而现在多于一行，是同一件事。

**根因判断**：行映射函数 `map_modifier_command_to_native` 被**抽成共享**（这一步本身是对的 —— 避免第二份拷贝漂移），但**结算路径也在普通配置里调用了它**，于是**本地适配器已经应用过的行又被应用了一次**。

**它的守卫是「EFFECT 归 worker 时才生效」**，而这几个夹具**没有 worker** —— **所以守卫没有拦住。**

## 3. 处置

**回滚了 3 个文件**：`effect_runtime.{h,cpp}`、`world_ext_effect.cpp`（用 `git checkout` 从索引恢复到 agent 之前的状态）。

**没有碰 `ideology_runtime.*`** —— schema 14 是另一个 agent 的、且是好的。

**回滚后三个夹具立即恢复**：147/0、159/0、1625/0。

**同时**：删掉它新增的夹具、从 `EXPECTED_FIXTURES` 移除、`EXPECTED_FIXTURE_COUNT` 65 → **64**。

## 4. 这一轮真正学到的东西

**「修好一个配置」和「不破坏其他配置」是两件事，而后者更难。**

它自己的夹具（46/0）证明 `0xFEF` 修好了；**而三个它没跑过的夹具证明普通配置被破坏了**。

**如果我只信它那份 46/0，我会把一个把加成加倍的回滚当成「又一处改进」交付。**

## 5. 最终状态（本轮结束时）

| 项 | 值 |
|---|---|
| 文档审计 | **VERIFY OK**（64 = 64、两个 DLL 身份匹配、0 过时计数）|
| 三个被破坏的夹具 | **已恢复**（147/0、159/0、1625/0）|
| 四个 schema-14 夹具 | **全绿**（72/0、424/0、460/0、379/0）|
| 内核 / country 检查 | **120/0**、**21/0** |
| **最后一次全量** | **`VERIFY FAILED (1)` —— 有一个夹具失败，我未能在剩余轮数内定位** |

**这一条必须留着**：**树不是我确认过的绿色。** 有一个夹具在最后一次全量里失败，而我查到的是「文档侧干净、三个被回滚影响的全绿、四个 schema-14 全绿」—— **失败者在这四组之外**。

## 6. 剩下要做的第一件事

**跑一次全量，看那一行 `- <fixture>: ...` 是什么。** 我的过滤管道把 `VERIFY FAILED (1):` 之后的那行漏掉了，这是我这一路第三次被自己的 grep 模式坑到 —— **过滤输出时，永远把 `- ` 开头的行也留下。**
