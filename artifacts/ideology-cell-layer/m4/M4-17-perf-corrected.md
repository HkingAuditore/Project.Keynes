# M4-17 §14.3 性能门禁：更正读数，拆分明细

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.3 |
| 取代 | **M4-16 的 FAIL 判定**（读错了累积字段） |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | 2400 格 **PASS**；6400 格 `materialise` **1.28 ms，超门槛 28%** |

## 1. 我上一轮报错了一个 FAIL

M4-16 报告「`rebuild_ms` 3.52 ms，门槛的 3.5 倍」——**这是误读**。

```cpp
// ideology_runtime.cpp:6873 与 :6881
_cell_layer_rebuild_ms += elapsed_ms(rebuild_started);   // 累加！
```

`cell_layer_rebuild_ms` 是**全天累积**，跨越 10 次访问，不是单次 slice 的成本。

**一个字段叫 `_ms` 而被逐次累加，读它的人（我）会自然当成单次耗时。这个命名本身值得改。**

## 2. 更正后的数据（n=5 中位数）

| 指标 | 2400 格 | 6400 格 |
|---|---:|---:|
| `city_factor_ms` | 0.0020 | 0.0019 |
| **`collect_ms`**（收集贡献） | 0.2755 | **0.6825** |
| **`materialise_ms`**（折叠+建 front） | 0.4328 | **1.2833** |
| `rebuild_ms` 总计 | 3.3593 | 8.8694 |
| 访问次数 | 10 | 10 |
| 总计/访问 | 0.3359 | 0.8869 |
| `tag_build_ms` | 15.31 | **41.33** |

## 3. 门槛判定（更正）

### 3.1 §14.3「单次派生 native slice ≤1 ms」

| 规模 | 单次全量物化成本 | 判定 |
|---|---:|---|
| 2400 格（生产默认） | **0.4328 ms** | **PASS** |
| 6400 格（单国全国） | **1.2833 ms** | **FAIL（超 28%）** |

**判定依据是 `collect + materialise` 在同一次访问内完成的成本**，不是 `总计/访问`：
6400 格的 `0.8869` 之所以更小，是因为**只有部分访问做了全量构建**，其余是近乎零的跳过。
用平均值会**低估**最坏那次 slice。

### 3.2 其余硬条件

| 条件 | 判定 |
|---|---|
| `truncated=0` | PASS |
| 逐格 Effect 实例 = 0 | PASS |
| 无随 S 增长的整图 seen 清零 | PASS（`own_tag_rejected=0`）|
| B5 零增量 | 未测 |

## 4. 成本结构（这是本轮真正的新信息）

```
2400 格：collect 0.2755 + materialise 0.4328 = 0.708 ms
6400 格：collect 0.6825 + materialise 1.2833 = 1.966 ms
```

| 部分 | 2400 → 6400 | 增长率 |
|---|---|---|
| collect | 0.2755 → 0.6825 | 2.48× |
| materialise | 0.4328 → 1.2833 | 2.97× |
| 格数 | 2.67× | — |

**两部分都近似线性**，materialise 略快于格数增长（2.97 vs 2.67，可能来自 hash map 扩容）。
**没有 O(n²)。**

## 5. 分片该切哪里

- **2400 格不需要分片**（0.43 ms，门槛内）；
- **6400 格需要**，而且要切的是 **materialise**（1.28 ms），collect（0.68 ms）本身在门槛内。

**因此上一轮「分片物化」的方向是对的，但边界应落在 materialise 的 (stat, cell) 折叠循环上，不是国家循环。**

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `ideology_runtime.cpp` | 新增 `cell_layer_collect_ms` / `cell_layer_materialise_ms` 两个分割计时 |
| `ideology_runtime.h` | `_derived_collect_ms` / `_derived_materialise_ms`；分片状态字段 |
| `ideology_perf_gate_test.gd` | 报 `总计 / 访问次数 / 每次`，并显式说明累积语义 |
| 本报告 | 更正与拆分 |

## 7. 局限

- 未测「派生成本叠加在 city factor 上」的最坏日（夹具先跑日后装卡）。
- `tag_build_ms` 41.33 ms 仍是全量重建，§15.6 的 per-tag changed words 未做。
- 未测峰值内存、B5、release DLL。

## 8. 教训

**一个表示「累积耗时」的字段用了 `_ms` 后缀，而单次成本才是门槛关心的量。**
我因此报出了一个假的 FAIL，并在上一轮据此提出「分片物化」——方向恰好正确，但理由是错的。
数据必须拆到「单次」才能与门槛比较。
