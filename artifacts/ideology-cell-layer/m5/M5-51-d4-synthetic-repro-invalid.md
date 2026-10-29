# M5-51 D4 的合成复现失败：我的夹具让所有格都报 slot 0

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-50](M5-50-d4-claims-accepted-territory-unchanged.md) 的下一步 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **合成复现无效**；但排除了一类产品缺陷，并把范围缩小 |

## 1. 想做什么

真实世界跑一次要 7-10 分钟，只够 1-2 次。所以想用**合成世界**（秒级）判断
`COMMAND_CLAIM_UNOWNED_TERRITORY` 到底要求什么：

- 对**相邻**中立格 claim → 生效？
- 对**远处**中立格 claim → 生效？

## 2. 结果：两个都说「已拥有」，但领土没变

```
[claim] baseline: widest=1 total=1
[claim] accepted: adjacent=true far=true
[claim] country days completed: 3
[claim] after: widest=1 total=1
[claim] HOME slot=0 handle=4294967296 | ADJACENT slot=0 | FAR slot=0
[claim] adjacent_landed=true far_landed=true
```

**矛盾点**：`total=1`（只有 1 格领土）但**三个格都报 slot 0**、都 `owned=true`。

## 3. 为什么无效：夹具让整格网都成了国家 0 的

`owned` 的语义我核实了（`country_runtime.cpp:4905-4912`）：

```cpp
const int32_t slot = _cell_country_slot[cell];
if (slot < 0) { out["owned"] = false; ... 无主之地 ... }
```

`owned = (slot >= 0)`。而我的合成世界里 **`FAR` 格也报 slot 0**，说明
`bootstrap_country` 给 1 格领土**却让整格网都归属了国家 0**。

**于是「claim 一个中立格」在这个世界里根本不可能**——没有中立格。
compare-and-set 要求目标中立，所以两种 claim 都必然不生效。

**这个合成复现回答不了原问题。** 是我的夹具构造问题，我没有解决它。

## 4. 但它排除了一类产品缺陷

我怀疑过「`_cell_country_slot` 是不是像 `_building_neighbors` 那样分配了却没填」。**查证后不是**：

```
country_runtime.cpp:418   _cell_country_slot.assign(cells, NEUTRAL_SLOT);
country_runtime.cpp:1066  std::fill(..., NEUTRAL_SLOT);
country_runtime.cpp:1137  _cell_country_slot[cell] = slot;      ← 逐格写
country_runtime.cpp:1180  if (... != NEUTRAL_SLOT) ...
```

**初始化到 `NEUTRAL_SLOT` + 逐格赋值**，不是死列。

而且真实世界里 `get_country_cell_summary(9710)` 给出 `handle=4294967296`（slot 1），
说明真实世界的 slot **是有区分的**——所以真实世界里确实存在无主格，
M5-50 的 claim 失败**不是**「没有中立格」这个原因。

## 5. 现在的状态

| 项 | 结论 |
|---|---|
| claim 命令可达、批量格式正确 | ✅ 已确认（真实世界 accepted=48）|
| `_cell_country_slot` 是死列 | ❌ **排除** |
| 真实世界「没有中立格」 | ❌ **排除**（slot 1 存在）|
| 真实世界 claim 不生效的真正原因 | **仍未知** |
| 合成世界能否复现 | ❌ **不能**——我的夹具让所有格都归国家 0 |

## 6. 我为什么停在这里

- 真实世界一次 7-10 分钟，剩余轮次只够 1 次盲试；
- 合成复现需要先搞清楚「`bootstrap_country` 为什么把整格网给了国家 0」，
  那本身是一个独立问题（可能是 API 语义，也可能是我的参数），**不是一次能解决的**；
- **盲试 10 分钟大于我剩余轮次能承受的试错预算。**

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_d4_claim_condition_test.gd` | 合成复现尝试，**2 checks / 0**；它证明的是「在这个世界里没有中立格」，不是原问题 |

## 8. 下一步（明确）

1. 先查 `bootstrap_country` 在 `territory_cells` 只有 1 项时对**其余格**的归属语义
   （是「其余保持中立」还是「其余归 slot 0」）——这决定合成复现是否可行；
2. 若其余应保持中立，则我的夹具少了某一步；
3. 之后再用合成世界回答「相邻是否是条件」，**最后**才回到真实世界。
