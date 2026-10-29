# M5-8 派生层逐格值可观测 + 发现 cell 0 缺陷

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) §15.7 前置 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **新增 `get_effective_stat_value` 桥**；发现 **cell 0 的派生贡献永不生效** |
| 验证 | 全回归 **19 / 19**（B7 升到 18 checks）|

## 1. 为什么先做可观测性，而不是直接删旧平面

M5-4 判定旧 v1 平面是死代码，§15.7 要求删除。我准备删时检查了它的 5 个调用者，发现其中 `ideology_effect_metric_publish_test.gd` 的断言测的是**真实语义**：

| 断言 | 抓什么 bug |
|---|---|
| `the entry carries the definition's operation`（ADD vs MULTIPLY）| 「+5% 被当成 ×1.05」|
| `the entry carries the command magnitude verbatim` | 幅度被改写 |
| `a cut definition yields a negative delta` | **「-8% 变成 +8%」**（符号必须来自定义，不能来自幅度）|

**删掉平面会同时丢掉这些覆盖。**

根因：派生层只暴露**计数**（`cell_count` / `stat_count`），没有任何桥能读出「某格某 stat 的贡献值」。所以那些断言无处可迁。

## 2. 新增的桥

```cpp
Dictionary get_effective_stat_value(stat_key, cell, entity_handle, base_value)
```

返回：
- `value` —— 走 **`ModifierRuntime::effective_value`**，即生产热路径的同一个调用
- `derived_add` / `derived_factor` / `derived_zero_factor_count`
- `derived_contributors` / `derived_source_country` / `derived_present`

分开报告「合并后的值」与「派生层自己的那一份」，测试才能区分「派生行生效」与「legacy bucket 生效」。

## 3. 用它验证：合并确实生效

```
cell 1: value=1.05000305175781  derived_add=0.05000305175781  derived_present=true
```

基准 1.0 + 派生 0.05 → 1.05。**派生行确实进入了合并。**

### 我做错的一处

第一版我传 `entity_handle = 国家 handle`，得到 `value: 1.0` 而 `derived_add: 0.05` 并列存在。

原因：生产读者用的是 `entity 0, group = cell`（`economy_runtime_family_buff.cpp:7127`）。传国家 handle 当 entity，`effective_value` 就完全跳过派生分支——**行在那儿但值为 1.0**。改成 `entity=0` 后立刻正确。

## 4. 发现的真实缺陷：cell 0 的派生贡献永不生效

```
cell 0: derived_present=true  derived_add=0.05000305175781  value=1.0
cell 1: derived_present=true  derived_add=0.05000305175781  value=1.05000305175781
```

**同一张卡、同一份贡献，cell 0 拿不到、cell 1 拿得到。**

### 根因

```cpp
// modifier_runtime.cpp:1443-1444
if (domain == ECONOMY && group_handle != 0 &&
        !_derived_cell_front.rows.empty()) {
```

`group_handle` 就是 cell（`:1434-1438` 的注释明确写着「every shipped reader passes the settlement cell as group_handle」）。而 **`group_handle != 0` 把 cell 0 排除了**。

派生行在 front 里存在（我的桥直接查 row 能找到），但合并时被这行守卫跳过。

### 为什么我没有直接改

去掉 `!= 0` 不安全：`effective_values` 内部**硬编码传 group 0 表示「无 group」**：

```cpp
// modifier_runtime.cpp:1480
const double value = effective_value(domain, stat_ids[i], entity_handle, 0, ...);
```

它的 3 个调用者（`economy_runtime.cpp:5579/5932/5982`）是批量读，语义上没有 cell。去掉守卫会让它们把 cell 0 的派生行算进每一个 stat。

**正确修法需要一个「无 group」哨兵**（如 `UINT64_MAX`）替代 0，并同步所有调用方。这是横跨多个读者的约定改动，不能在缺少分析时仓促做。

## 5. 影响评估

| 问题 | 影响 |
|---|---|
| cell 0 拿不到派生贡献 | 每张卡在其国家的**第一个格**上缺失效果 |
| 是否只影响 cell 0 | 是，`!= 0` 只排除 0 |
| 生产可见性 | 取决于 cell 0 是否落在该卡的目标集里；对角地图上可能小，对特定布局可能显著 |

**这是「32 上限」之外的一个独立正确性缺陷**，已记为高优先级开放项。

## 6. 回归

| 项 | 结果 |
|---|---|
| 全回归 | **19 / 19** |
| B7 | **18 / 0**（新增 3 条值断言）|

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `world_ext.h` / `world_ext_bind_methods.cpp` / `world_ext_modifier.cpp` | `get_effective_stat_value` 桥 |
| `ideology_b7_wide_territory_test.gd` | 3 条值断言 + cell 0 诊断输出 |

## 8. 局限

- **cell 0 缺陷未修**（需哨兵约定改造）。
- 旧平面**仍未删除**：`ideology_effect_metric_publish_test.gd` 的 3 类语义断言现在**有能力**迁移，但迁移本身未做。
- 未在 release DLL、真实生成世界验证。
