# M3 开工记录：ramp 的真实结构与技术路径

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5（C=12 / D=41） |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 状态 | **分析完成，实现未开始** |
| 结论 | M3 的真正难点是 **metric 来源**，不是 ramp 的算术 |

## 1. M3 的批次构成

覆盖率工具报告的 24 个 `ramp_not_yet_supported` program，逐个查明：

```
salt_monopoly_l1..l3           chartered_route_l1..l3
silver_flow_l1..l3             manufactory_regulation_l1..l3
（以及另外 12 个，共 24）
```

**共同的三个特征：**
- `target_selector_kind = 12`（OWN_TERRITORY），已在上线支持列表内；
- `lifecycle = 0`（PERMANENT）；
- 唯一拦截原因是 `ramp_not_yet_supported`。

所以 M3 不需要新的 selector、不需要新的生命周期处理 —— **只需要让 ramp 的幅度可计算**。

## 2. ramp 的真实指令结构

以 `salt_monopoly_l1` 为例：

```
CONST(983)          # 983/65536 ≈ 0.015，比例
READ_METRIC(57)     # country.extractive_cell_count
CONST(655360)       # 10.0，上限
MIN                 # op = 8
```

即 **`min(metric_57, 10.0) × 0.015`**。

`op = 8` 是 `MIN`（`effect_runtime.h:59`），不是 READ_METRIC 的变体 —— 这一点首版容易读错。

## 3. 八个 metric 分两类，这才是难点

| metric id | 键 | 类别 |
|---:|---|---|
| 22 | `cell.unemployment_q16` | **逐格** |
| 24 | `cell.manufacturing_building_count` | **逐格** |
| 57 | `country.extractive_cell_count` | 国家级 |
| 59 | `country.chained_cell_count` | 国家级 |
| 63 | `country.silver_cell_count` | 国家级 |
| 67 | `country.distinct_specialized_good_count` | 国家级 |
| 69 | `country.treasury_reserve_ratio_pct` | 国家级 |
| 91 | `country.families_with_at_least_3_branches` | 国家级 |

**逐格 metric 与国家级 metric 的语义完全不同：**

- 逐格：同一国家的不同格可以有**不同** ramp 值 → 派生层必须逐格求值；
- 国家级：同一国家所有格**共享**同一个 ramp 值 → 每个国家只需算一次。

M3 的退出条件「同国不同格的 ramp 数值不同且正确」明确要求第一种。

## 4. 技术障碍：派生层没有 metric 载体

当前 ramp 的值走实例路径：

```cpp
// effect_runtime.cpp:491-562
std::vector<int64_t> next_metric_values;
next_metric_values.reserve(snapshot.instances.size() * metric_width);
instance.metric_base = static_cast<uint32_t>(next_metric_values.size());
```

**metric 值是按 instance 存的。** 派生层的 `DerivedCellContribution` 只有：

```cpp
struct DerivedCellContribution {
    uint64_t source_country;
    double sum_add;
    double product_nonzero;
    uint32_t zero_factor_count;
};
```

没有 ramp 载体，也没有 metric 输入。这就是 24 个 ramp 卡住的根本原因。

## 5. 可行路径（已确认接口存在）

`sample_effect_metrics(cell, metric_count, values, mask)`（`economy_runtime.h:8831`）是**按格采样**的，且已被 tag 求值使用（`economy_runtime_family_buff.cpp:1191`）。

所以 M3 的实现路径是：

1. 在 `DerivedCellContribution` 增加 ramp 描述（metric id、比例、上下限、操作），**而不是**先算成常数；
2. 物化器在遍历格时调用 `sample_effect_metrics(cell, ...)` 取得该格的 metric；
3. 按 ramp 指令序列求值得到该格的幅度；
4. 再折进 `sum_add` / `product_nonzero`。

关键约束：**不能把 ramp 折叠成常数**。方案 §15.5 明确写「保留 raw continuous revision，禁止条件阈值桶冻结幅度」——阈值桶会把连续值量化成离散档，那正是要避免的。

## 6. 我尚未完成的部分

| 项 | 状态 |
|---|---|
| 24 个 ramp 的 metric 分布 | ✅ 已查明 |
| 逐格 vs 国家级的分类 | ✅ 已查明 |
| 障碍定位（metric 按 instance 存） | ✅ 已确认 |
| `sample_effect_metrics` 可复用 | ✅ 已确认接口 |
| **`DerivedCellContribution` 的 ramp 字段设计** | ❌ 未做 |
| **物化器的 metric 采样接线** | ❌ 未做 |
| **逐格 ramp 求值器** | ❌ 未做 |
| **M3 的 6 个退出条件** | ❌ 全部未验证 |

## 7. 局限

- 本轮只做分析，**没有改任何代码**。
- 未检查 ramp 的 `CLAMP` / `MAX` / 其他 op 组合（只查了 `salt_monopoly_l1` 一条）。
- 未确认 `sample_effect_metrics` 在物化器的调用时机是否可用（它可能要求 epoch 已打开，而那正是反复出现的缺口）。
- 国家级 metric 的「每国算一次」优化未设计。

## 8. 复算方式

```powershell
# ramp program 清单
python -c "
import sys; sys.path.insert(0,'Project/project-keynes/tools/ideology')
import m1_backend_coverage as m
m.block_tres = m.Tres(m.EFFECTS)
p = [(r, m.block_tres.body(r)) for r in m.Tres.refs(m.block_tres.main(),'effects')]
t = m.load_tres_definitions(m.Tres(m.MOD_CATALOG))
f = m.build_facts(p, t)
print(len([x for x in f if x['reason']=='ramp_not_yet_supported']))
"
# metric 分类
# 见 Project/project-keynes/scripts/effect/effect_domain_catalog.gd:70-190
```
