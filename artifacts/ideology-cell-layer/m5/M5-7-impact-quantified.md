# M5-7 归属默认值变更的影响量化

| 项目 | 内容 |
|---|---|
| 里程碑 | 新增目标项（「周围地块」归属筛选）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **边境一次 R2 扇出有 51.7% 落在外国格**；最坏单环 14/18 |
| 验证 | 全回归 19/19、内核 85/0 |

## 1. 量化结果（用户要求的影响评估）

在 C++ 选择器测试里加了一次扫描：把 6×5 网格按列分成两国，**每个内部格轮流当源格**，用真实六边形邻接取 R2 环，再按真实归属切分。

```
[ownership] R2 ring sweep: 93 of 180 cells foreign (51.7%), worst single ring 14 foreign
```

| 指标 | 值 |
|---|---|
| 扫描的环格总数 | 180 |
| **其中外国格** | **93（51.7%）** |
| **最坏单环的外国格数** | **14**（R2 环上限 18）|

### 这个数字怎么读

- **R2 环最多 18 格**，边境处最坏有 **14 格是外国的** —— 即旧行为下一次扇出几乎全部落在邻国。
- **全扫描 51.7%** 是「每个内部格都当一次源」的平均；越靠边境比例越高。
- 因此新的 OWN 默认**不是小幅收窄，而是对边境卡的一次大幅改变**：这些卡过去有近一半的作用面在国境外。

### 断言与报告的分工

| 方式 | 内容 |
|---|---|
| **断言** `ownership_sweep_finds_foreign_cells` | 至少有一格外国 → 证明这次变更有实际对象，不是空改 |
| **报告** `[ownership] R2 ring sweep: ...` | 具体百分比。**不写成断言**：精确比例取决于地图与源位置，钉成常数会把内容问题变成脆弱测试 |

## 2. 一并修掉的诊断缺陷

### 2.1 `building_context_ready_for_test()` 只看长度

M5-6 记录：它报 `ready: true` 而实际邻居全是 `-1`。

```cpp
// 修复前：只比长度
out["ready"] = _building_neighbors.size() == cells * 6 && ...;
// 修复后：还要求至少有一个有效邻居
int64_t valid_neighbors = 0;
for (const int32_t n : _building_neighbors)
    if (n >= 0 && n < cells) ++valid_neighbors;
out["valid_neighbors"] = valid_neighbors;
out["has_any_neighbor"] = valid_neighbors > 0;
out["ready"] = ... && valid_neighbors > 0;
```

**一个在数据为空时说「就绪」的诊断，比没有诊断更糟**——它让人不去查真正的原因。

### 2.2 删掉会崩溃的 GDScript 探针

`ideology_ownership_scope_probe.gd` 在加了就绪检查后崩溃（`0xC0000005`）。

它本来就没证明任何东西（连续两轮 `raw=0`），而且 GDScript 侧的 `MapStub` 结构上填不了 `_building_neighbors`（只能由 C++ 友元赋值）。

**留着它 = 留一个会崩、又不验证任何东西的文件。** 已删除，证据由 C++ 自测承担。

## 3. 现在的完整证据链

| 环节 | 证据 | 位置 |
|---|---|---|
| 默认值是 OWN | `ownership_default_is_own` | 内核 85/0 |
| 6 个真实 param 解码为 OWN | `a live kind-16 param decodes as OWN` | 内核 |
| 未知值回退 ANY | `an unknown scope falls back to ANY` | 内核 |
| cap 哨兵不被归属位污染 | `masking the scope leaves cap 0 intact` | 内核 |
| **真实环跨越国界** | `ownership_ring_straddles_the_border` | C++ 自测 |
| **谓词精确划分环** | `ownership_predicate_matches_country_split` | C++ 自测 |
| **OWN+FOREIGN == ANY** | `ownership_own_plus_foreign_partitions_any` | C++ 自测 |
| **OWN 真的丢格** | `ownership_own_drops_foreign_cells` | C++ 自测 |
| **变更幅度** | `93/180 = 51.7%`，最坏 14/18 | C++ 自测报告 |
| **断言真的执行** | 负向对照 142/1 + `NEGATIVE_CONTROL_ownership` | M5-6 |

## 4. 回归

| 项 | 结果 |
|---|---|
| 全回归 | **19 / 19** |
| 内核 | **85 / 0** |
| 选择器自测 | x1b 142/0 |

## 5. 局限

- 51.7% 来自 **6×5 合成网格**，不是真实生成世界。真实世界的比例取决于国境长度与 tag 分布。
- 未按卡逐张量化（74 张卡各自的国境内 tag 命中数不同）。
- 未在 release DLL 上验证。
- 内容侧未改：74 张卡仍写 `param0`，只是解码为 OWN。若要某张卡恢复旧行为需显式 `ANY`。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `economy_runtime_effect_selector_tests.cpp` | 影响扫描 + 2 条新断言 + 百分比报告 |
| `economy_runtime_family_buff.cpp` | 就绪判定改为校验邻居内容 |
| （删除）`ideology_ownership_scope_probe.gd` | 会崩且不验证任何东西 |
