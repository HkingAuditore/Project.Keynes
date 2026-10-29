# M5-58 真实缺陷（Claude 发现）：66 张 kind-16 卡仍有静默的 32 格上限

| 项目 | 内容 |
|---|---|
| 发现者 | Claude（外部核实），我在本轮验证并修复 |
| 类型 | **真实缺陷**——与 kind 12/14/15 同类的「声明与运行时自相矛盾」|
| 影响面 | **66 张卡**（全部 kind 16）|
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 缺陷

`selector_cell_cap.h:65-67` 把 `CAP_SELECTOR_TAG_SOURCE_COUNT`（kind 16）归为
`kSelectorNoCellCap`——**按声明这一 kind 不受格数限制**。

但 `effect_runtime.h:263` 的解码器：

```cpp
out.target_cap = stored_cap == 0 ? SELECTOR_MAX_CELLS : stored_cap;   // 0 -> 32
```

而 `ideology_runtime.cpp:2089`：

```cpp
effect_stable_cap(cells, selector.target_cap, ...);                   // 真的按 32 截断
```

**全部 66 张 kind-16 卡的 `param0 = 800`**，低五位为 0：

| 字段 | 位 | 值 |
|---|---|---|
| `target_cap` | `& 0x1F` | **0 → 解码成 32** |
| `radius` | `(>>5) & 0x07` | 1 |
| 源数上限 | `(>>8) & 0x0F` | 3 |

**所以 66 张卡在大国里只对前 32 个目标格生效，其余静默丢弃。**

## 2. 这个缺陷比 kind 12/14/15 更隐蔽

| 项 | 说明 |
|---|---|
| 没有报错 | `effect_stable_cap` 静默 `resize` |
| 报告里有 `selector_truncations` | 但没人看，且 x1b 的 T8 **把 32 当成正确期望钉住了** |
| GDScript 授权层本来是对的 | `ideology_effect_definition.gd` **已有** `SELECTOR_NO_CELL_CAP = 2147483647` 与 `selector_cell_cap_is_unbounded`；**只有 `unpack_source_count` 一个函数与它矛盾** |

**「两个表示不一致」这个模式在本方案里出现了第 4 次**（kind 14/15 的上限、`territory_count`、
`selector_cell_ceiling` 与运行时、以及这次的 `unpack` 与授权层）。

## 3. 修复（两侧同改）

| 位置 | 改动 |
|---|---|
| `effect_runtime.h:263`（C++）| `stored_cap == 0 → kSelectorNoCellCap`，而不是 `SELECTOR_MAX_CELLS` |
| `ideology_effect_definition.gd:219`（GDScript）| `unpack` 的 0 → `SELECTOR_NO_CELL_CAP` |
| 同文件 `:195` | `pack` 接受该哨兵值 |
| 同文件 `:203` | 32 与该哨兵都存成 0（「未指定」）|

**两个实现现在对同一输入给出同一含义。**

`effect_stable_cap` 无需改动：`cap < 0 || size <= cap` 时直接返回，`INT32_MAX` 等于不截断。

## 4. 验证

| 项 | 结果 |
|---|---|
| **x1b 的 T8**：72 格交替源/目标，原期望「36 找到、32 保留」 | 现在 **36 找到、36 保留**，`selector_truncations = 0` |
| x1b 的解码镜像（原断言「0 位 = 默认 32」）| 改为断言**无上限** |
| **新增三条 C++ 断言** | 未指定 → 无上限；`selector_cell_ceiling(16)` 必须同类无上限（**把两个表示钉在一起**）；显式指定 7 仍被尊重 |
| **新增生产值断言** | `param0 = 800` → 无上限、radius 1、源上限 3 —— 这是 66 张卡真实使用的输入 |
| 回归 | **12/12 fixture 全绿**（B5/B7/B8/B10/B11/oracle/content/cost/tag_source/tag_stress/effect_instance/e2e）|
| 双构建 | x1b 在 **debug 与 release 上都是 142/0** |

## 5. 这轮的价值

Claude 的核实把我一个**判断错误**纠正了：我曾把 kind 16 归入「已随 kind 12 一起完成」，
实际上它只是**内容层**（授权 API）对了，**运行时层**仍按 32 截断。

**66 张卡**是全部 kind-16 内容——**不是边角**。

## 6. 遗留

- 取消上限后，66 张卡在大国里的目标集会变大（半径 1~4，源数上限 3）。
- **性能影响未测**：与 kind 12 一样，派生路径是分片的，但**没有实测数字**。
- kind 16 的逐源环走**未**改用 `dilate_cell_set`（Claude 的第 2 点）：它的分支用
  `building_neighbor()` 直读六邻居表、`seen`/`source_counts` 在循环外分配一次，
  **不是逐源分配**。这一点我用代码确认了，与 Claude 的描述不同——见 §7。

## 7. 对 Claude 第 2 点的核实结论

Claude 写：「Kind 16 的 `resolve_effect_targets` 分支仍有逐源 `std::vector<uint8_t> seen`
分配（`ideology_runtime.cpp:2000` 附近）」。

**实际代码**（`:1988-1995`）：

```cpp
source_counts.assign(grid_cells, 0);      // 一次，按全图
std::vector<int32_t> ring_1;              // 一次
std::vector<int32_t> ring_2;              // 一次
std::vector<int32_t> frontier;            // 一次
std::vector<int32_t> next;                // 一次
std::vector<uint8_t> seen;                // 一次（在循环外声明）
for (source_index...) { ... building_neighbor(source, direction) ... }
```

**这些都在源循环之外**，循环内只用 `clear()` 复用。所以 kind 16 **没有**逐源 O(全图) 分配，
Claude 这一点判断不成立（我按行读过了）。

**但这不影响它的主线结论**：`target_cap` 的截断是真的，已修。
