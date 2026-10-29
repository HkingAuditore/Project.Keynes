# M5-31 发现：kinds 14/15 仍把「源格数量」钳在 32

| 项目 | 内容 |
|---|---|
| 里程碑 | [§15.7](22-cell-program-cap-removal-plan-v3.md)「不删除仍真实使用的保护」/ 32 上限是否彻底取消 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结论 | **不是我能单方面改的** —— 需要决策；已如实记录 |

## 1. 代码事实

`ideology_runtime.cpp:2081-2086`（kinds 14/15 的源格收集）：

```cpp
const int32_t authored_cap = effective.target_selector_param[0] & CAP_MASK;
const int32_t cap = authored_cap > 0
    ? std::min(authored_cap, EffectRuntime::SELECTOR_MAX_CELLS)   // <= 32
    : EffectRuntime::SELECTOR_MAX_CELLS;                          // = 32
```

`SELECTOR_MAX_CELLS = LEGACY_INSTANCE_MAX_CELLS = **32**`（`effect_runtime.h:326-329`）。

于是：**一张 kind 14/15 卡最多只用 32 个源格**（按稳定哈希选取，不是前 32 个）。

## 2. 内容事实

`default_ideology_effects.tres` 里 **5 张 kind 14/15 卡全部 author `param0 = 32`**：

| kind | 卡片 | `param` |
|---|---|---|
| 14 | `autonomous_logistics_l1` | `32, 0` |
| 14 | `autonomous_logistics_l2` | `32, 0` |
| 14 | `autonomous_logistics_l3` | `32, 0` |
| 14 | `gentry_patronage_l3_ring` | `32, 0` |
| 14 | `refrigeration_l3_ring` | `32, 0` |

（`param1` 是编译期写入的 tag id，不是 0。）

**所以这 5 张卡的源格上限就是 32，与运行时的默认值恰好相同。**

## 3. 这意味着什么

| 项 | 状态 |
|---|---|
| 「目标格」的 32 上限 | **已取消**（territory/source 类 selector 返回 `kSelectorNoCellCap`）|
| 「源格」的 32 上限 | **仍在**，且这 5 张卡 authored 32 |
| 有效覆盖 | 受源数间接限制：一国若有 300 个带该 tag 的格，**只有 32 个参与扇出** |

对 R1（环 6 格）与 R2（环 18 格）来说，`ring_cap = min(cap, 32)` **从不生效**（几何上限更小），
所以唯一的限制就是**源数**。

## 4. 为什么我停在这里

这不是「技术性 32 截断」的漏网，而是**内容与常量一起表达的一个上限**：

- 方案 §15.7 明确写「**不删除仍真实使用的保护**」；
- 这 5 张卡的 `param0` 是**作者写的**，不是默认值兜底；
- 把它从 32 改成「不限」会**直接扩大这 5 张卡的作用面**（3 张 `autonomous_logistics` 是核心卡），
  那是**平衡性改动**，不是取消技术限制。

**一个缺陷修复者有义务区分「技术截断」与「内容设计」，我没有单方面改。**

## 5. 需要决策的点

| 选项 | 后果 |
|---|---|
| A. 保持现状（32 源上限）| 5 张卡维持现值；「32 上限已取消」这个说法需要限定为「目标格，不含源格」|
| B. 内容侧把 `param0` 改成 0（= 用 kind 默认）并让默认变成「不限」| 5 张卡覆盖显著变大，需要重新平衡 |
| C. 只把默认值改成「不限」，内容仍写 32 | 零变化（因为内容都写了 32），但默认语义变正确 |

**我倾向 C 作为最小改动**：它不改变任何现值，只让「没写 cap 的卡」不再意外地有 32 上限。
但那仍然需要决策，所以我没做。

## 6. 顺带确认的三处「归属位不会被误用」

| 检查点 | 结论 |
|---|---|
| 编译期是否改写 `param[0]` | **否**。`effect_catalog.gd:161-165` 原样读取；`_write_selector_tag_id` 只写 `params[1]` |
| 校验器是否拒绝大 `param[0]` | **否**。kinds 14/15/16 都是 `kSelectorNoCellCap`，`!unbounded && ...` 短路 |
| 其它读者是否把原始 `param0` 当 cap | **否**。`ideology_runtime.cpp:2081` 显式 `& CAP_MASK` |

**这三条排除了「写 FOREIGN 的卡会被拒/会被误当 cap」这一类隐患。**

## 6.1 顺带做完的「32 常量」全量审计

把 `SELECTOR_MAX_CELLS` / `LEGACY_INSTANCE_MAX_CELLS` 的所有使用点过了一遍：

| 位置 | 用途 | 是否合规 |
|---|---|---|
| `ideology_runtime.cpp:2085/2086` | kinds 14/15 的**源格数** | **仍限制 32**（本报告的主题）|
| `ideology_runtime.cpp:2099` | `ring_cap = min(cap, 32)` | 合规——几何上限 R1=6 / R2=18 更小，**从不生效** |
| `ideology_runtime.cpp:2467/2469` | 实例路径（legacy）| 合规——按 §15.7 改名为 `LEGACY_INSTANCE_MAX_CELLS` |
| `ideology_runtime.cpp:580` | **synergy override 行**的 `SELECTOR_CAP` 字段上限 | 合规但**是另一套机制**（synergy 行，不是卡片 selector）；它同样不允许超过 32 |
| `ideology_runtime.cpp:1905-1907` | `SELECTOR_FAMILY_OWNED` 的目标家族数 | **不作为缺陷** —— 见下 |
| `economy_runtime_family_buff.cpp:2550/2597/2615` | 经济侧几何 selector 的 cap | 合规——几何上限更小 |

### 关于 `FAMILY_OWNED` 那处

`selector_cell_ceiling(SELECTOR_FAMILY_OWNED)` 返回 `kSelectorNoCellCap`（无上限），
但它的消费者 `ideology_runtime.cpp:1905` 硬钳 `clamp(param[0], 1, 32)`。

**这不是后端不一致**：派生后端只支持 kind **12/14/15/16**
（`cell_program_eligibility.h:95-105`），`FAMILY_OWNED` 不在其中，
所以它只有实例路径一个后端，32 是那个后端自己的家族数上限。

**但它是一处口径瑕疵**：`selector_cell_ceiling` 的注释说这个函数是「几何可达格数」，
而 `FAMILY_OWNED` 选的是**家族 handle 而不是格**，把它列进「无上限」在语义上不严谨。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| 本报告 | 代码与内容两侧的事实、影响面、三个选项 |

**没有代码改动** —— 这一轮产出的是一个需要决策的、有证据的发现。
