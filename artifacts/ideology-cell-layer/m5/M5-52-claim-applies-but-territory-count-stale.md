# M5-52 真实缺陷：claim 改了格子归属，但领土计数没变

| 项目 | 内容 |
|---|---|
| 类型 | **真实缺陷**（领土记账与格子归属不一致）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 最小复现 | 合成 12×12 世界、1 国 1 格、2 条 claim、3 个国家日 → **5 秒** |
| 严重性 | 中高：`territory_count` 用于校验、状态哈希与存档 |

## 1. 决定性的一次对比

同一个夹具，**claim 之前**和**之后**各读一次 slot 列：

```
[claim] PRE slots:  HOME=0  ADJACENT=-1  FAR=-1      ← 正确：只有 HOME 有主
[claim] baseline:   widest=1 total=1
[claim] accepted:   adjacent=true far=true
[claim] country days completed: 3
[claim] HOME slot=0 ADJACENT=0 FAR=0                 ← claim 生效了：两格都归了国家 0
[claim] after:      widest=1 total=1                 ← 但计数完全没变
```

**两件事同时成立**：
- `get_country_cell_summary(FAR).country_slot` 从 **-1 变成 0** → **claim 确实应用了**
- `get_country_territory_counts()` 的 `widest` 与 `total` **仍是 1** → **计数没有跟上**

所以之前几轮「claim 不生效」的判断**是错的**——它生效了，只是**报告看不出来**。

## 2. 缺陷在哪一层

`country_runtime.cpp:3172-3199` 同时处理 `TRANSFER_TERRITORY` 与 `CLAIM_UNOWNED_TERRITORY`：

```cpp
if (old_owner >= 0) { --batch.countries.territory_count[old_owner]; ... }
if (target >= 0)    { ++batch.countries.territory_count[target]; ... }   // :3196 有增量
if (batch.direct_unique_territory) {
    batch.direct_cell_order.push_back(command.cell);
    batch.direct_cell_owners.push_back(target);                          // :3202 格子归属
}
```

**增量代码是存在的**，作用于 `batch.countries.territory_count`（暂存副本）。
而格子归属走的是**另一个字段** `batch.direct_cell_owners`。

观察到的结果是：**`direct_cell_owners` 被提交，`countries.territory_count` 没有**。

**所以这不是「忘了写 increment」，而是批次提交时两条路径不一致**：格子归属与领土计数是同一件事的两份表示，提交后它们脱离了。

## 3. 影响

| 用途 | 影响 |
|---|---|
| `get_country_territory_counts()` | **永久低报**：国家实际领土可以无限增长，报告永远是旧值 |
| 校验（`:3625`）| `active && territory_count <= 0` 会误判；本例计数为 1 所以没触发 |
| `state_hash`（`:9325`/`:9487`）| 哈希含 `territory_count` → **同一世界的哈希与实际领土不一致** |
| 存档（`:9871`）| `territory_count` 被持久化 → **读档后低报继续存在** |
| 本方案的「>32 样例」| **这就是为什么几轮都拿不到 >32 证据**——领土其实长过了，报告说没有 |

## 4. 我做了什么、没做什么

| 做 | 没做 |
|---|---|
| 用 5 秒复现证明了「apply 生效但计数不变」 | **没有修**：修法涉及批次提交的不变量，需要确认 `territory_count` 是否应改为从 CSR 重算，仓促改会动到存档与哈希 |
| 定位到 `:3172-3199` 的两条并行表示 | 没有把 `territory_count` 与 `direct_cell_owners` 的不变量写成断言 |
| 排除了「NEUTRAL_SLOT 语义错」「slot 列是死列」 | 没有验证所有 opcode 是否都有这个不一致 |

## 5. 建议的修法（未执行）

**首选**：提交时**从格子归属重算** `territory_count`，而不是维护第二份增量。
理由：`territory_count` 是完全由 `_cell_country_slot` 决定的派生量，维护两份必然脱离——
这正是本方案在 ADR01/ADR02 里对派生层的结论（派生量不跨存储维护）。

**次选**：保留增量，但加一条提交后断言 `territory_count[c] == count of _cell_country_slot == c`。
它会把缺陷变成崩溃而不是静默低报，但仍然是两份表示。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_d4_claim_condition_test.gd` | 最小复现，**2 checks / 0**；打印 PRE/POST slots |
| 本报告 | 缺陷描述、位置、影响、建议修法 |

## 7. 局限

- 只在**合成世界**复现；真实世界（M5-50）的 `accepted=48` 大概率是同一缺陷，但**未在同一轮内证实**。
- 未确认 `territory_count` 是否在别的路径被重算（若有，低报可能只在某些时机出现）。
- 未验证 `TRANSFER_TERRITORY` 是否有同样问题（它的 `old_owner` 也是真实国家，理论上走同一段代码，**很可能同样不一致**）。
